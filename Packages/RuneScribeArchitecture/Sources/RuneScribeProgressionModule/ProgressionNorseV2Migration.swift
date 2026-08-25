import Foundation
import RuneScribeContracts

enum ProgressionNorseV2Migration {
    private struct RevealCandidate {
        let contentID: ProgressionContentID
        let groupID: GrantGroupID
        let tier: ProgressionDurableRevealTier
        let isPrimary: Bool
    }

    static func applies(
        from: ProgressionCatalogVersion,
        to: ProgressionCatalogVersion
    ) -> Bool {
        from.rawValue == 1 && to.rawValue == 2
    }

    static func isCurrentCatalog(_ catalog: ProgressionCatalog) -> Bool {
        catalog.catalogVersion.rawValue >= 2
    }

    static func canonicalContentID(
        _ contentID: ProgressionContentID,
        catalog: ProgressionCatalog
    ) -> ProgressionContentID? {
        if catalog.content(id: contentID) != nil { return contentID }
        guard isCurrentCatalog(catalog),
              let raw = legacyContentAliases[contentID.rawValue],
              let canonical = ProgressionContentID(rawValue: raw),
              catalog.content(id: canonical) != nil
        else { return nil }
        return canonical
    }

    static func canonicalArtifactID(
        _ artifactID: ArtifactID,
        catalog: ProgressionCatalog
    ) -> ArtifactID? {
        guard let contentID = ProgressionContentID(rawValue: artifactID.rawValue),
              let canonical = canonicalContentID(contentID, catalog: catalog),
              catalog.content(id: canonical)?.countsAsArtifact == true
        else { return nil }
        return ArtifactID(rawValue: canonical.rawValue)
    }

    static func canonicalArtifactIDs(
        _ artifactIDs: [ArtifactID],
        catalog: ProgressionCatalog
    ) throws -> [ArtifactID] {
        var values = Set<ArtifactID>()
        for artifactID in artifactIDs {
            guard let canonical = canonicalArtifactID(artifactID, catalog: catalog) else {
                throw ProgressionDomainError.unknownContent(artifactID.rawValue)
            }
            values.insert(canonical)
        }
        return values.sorted()
    }

    static func migrateProjectionFacts(
        from old: ProgressionProjection,
        in projection: inout ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws {
        guard applies(from: old.metadata.catalogVersion, to: catalog.catalogVersion) else {
            return
        }
        try preserveCompletions(from: old, in: &projection)
        try migrateContentUse(from: old, in: &projection, catalog: catalog)
        try migrateEncounters(from: old, in: &projection, catalog: catalog)
        try migrateGrantsAndOwnership(from: old, in: &projection, catalog: catalog)
        try preserveEntitlements(from: old, in: &projection)
        try recomputeArtifactCount(in: &projection, catalog: catalog)
    }

    static func mappedGrantIdentity(
        _ record: GrantRecord,
        catalog: ProgressionCatalog
    ) -> String? {
        guard let contentID = mappedGrantContentID(record, catalog: catalog) else {
            return nil
        }
        return "grant|\(record.grantGroupID.rawValue)|\(contentID.rawValue)|\(record.source.key)"
    }

    static func mappedGrant(
        _ record: GrantRecord,
        generation: String,
        catalog: ProgressionCatalog
    ) -> GrantRecord? {
        guard let contentID = mappedGrantContentID(record, catalog: catalog) else {
            return nil
        }
        return GrantRecord(
            generation: generation,
            grantGroupID: record.grantGroupID,
            contentID: contentID,
            source: record.source,
            transactionID: record.transactionID,
            grantedAt: record.grantedAt
        )
    }

    static func mappedOwnership(
        _ record: OwnershipRecord,
        oldProjection: ProgressionProjection,
        generation: String,
        catalog: ProgressionCatalog
    ) throws -> OwnershipRecord {
        var contentID: ProgressionContentID?
        var sourceGrantKeys = Set<String>()
        for oldKey in record.sourceGrantKeys {
            guard case let .grant(oldGrant)? = oldProjection.records[oldKey],
                  let mapped = mappedGrant(
                    oldGrant,
                    generation: generation,
                    catalog: catalog
                  )
            else { throw ProgressionDomainError.invalidRecord("catalog-v2-ownership-map") }
            guard contentID == nil || contentID == mapped.contentID else {
                throw ProgressionDomainError.invalidRecord("catalog-v2-ownership-split")
            }
            contentID = mapped.contentID
            sourceGrantKeys.insert(ProgressionLogicalRecord.grant(mapped).identity)
        }
        guard let contentID else {
            throw ProgressionDomainError.invalidRecord("catalog-v2-ownership-empty")
        }
        return OwnershipRecord(
            generation: generation,
            contentID: contentID,
            sourceGrantKeys: Array(sourceGrantKeys),
            grantedAt: record.grantedAt
        )
    }

    static func canonicalContentUse(
        _ record: StatisticContentUseRecord,
        generation: String,
        catalog: ProgressionCatalog
    ) throws -> StatisticContentUseRecord {
        var canonical = Set<ProgressionContentID>()
        for contentID in record.contentIDs {
            guard let mapped = canonicalContentID(contentID, catalog: catalog) else {
                throw ProgressionDomainError.unknownContent(contentID.rawValue)
            }
            canonical.insert(mapped)
        }
        return StatisticContentUseRecord(
            generation: generation,
            statisticID: record.statisticID,
            bucketID: record.bucketID,
            contentIDs: Array(canonical)
        )
    }

    static func canonicalEncounter(
        _ record: EncounterRecord,
        generation: String,
        catalog: ProgressionCatalog
    ) throws -> EncounterRecord {
        var observations: [ArtifactID: EncounterRecord.ArtifactObservation] = [:]
        for observation in record.artifactObservations {
            guard let artifactID = canonicalArtifactID(
                observation.artifactID,
                catalog: catalog
            ) else {
                throw ProgressionDomainError.unknownContent(observation.artifactID.rawValue)
            }
            if var current = observations[artifactID] {
                current.firstEncounteredAt = min(
                    current.firstEncounteredAt,
                    observation.firstEncounteredAt
                )
                current.lastEncounteredAt = max(
                    current.lastEncounteredAt,
                    observation.lastEncounteredAt
                )
                let sum = current.encounterCount.addingReportingOverflow(
                    observation.encounterCount
                )
                guard !sum.overflow else {
                    throw ProgressionDomainError.invalidRecord(
                        "catalog-v2-encounter-overflow"
                    )
                }
                current.encounterCount = min(sum.partialValue, record.encounterCount)
                current.provenanceStatus = mergeProvenance(
                    current.provenanceStatus,
                    observation.provenanceStatus
                )
                observations[artifactID] = current
            } else {
                observations[artifactID] = EncounterRecord.ArtifactObservation(
                    artifactID: artifactID,
                    firstEncounteredAt: observation.firstEncounteredAt,
                    lastEncounteredAt: observation.lastEncounteredAt,
                    encounterCount: observation.encounterCount,
                    provenanceStatus: observation.provenanceStatus
                )
            }
        }
        let canonical = EncounterRecord(
            generation: generation,
            codexID: record.codexID,
            artifactObservations: Array(observations.values),
            firstEncounteredAt: record.firstEncounteredAt,
            lastEncounteredAt: record.lastEncounteredAt,
            encounterCount: record.encounterCount,
            provenanceStatus: record.provenanceStatus
        )
        try canonical.validate()
        return canonical
    }

    static func canonicalReveal(
        _ reveal: PendingRevealRecord,
        generation: String,
        catalog: ProgressionCatalog
    ) throws -> PendingRevealRecord {
        let shape = try canonicalRevealShape(
            tier: reveal.tier,
            primaryContentID: reveal.primaryContentID,
            secondaryContentIDs: reveal.secondaryContentIDs,
            sourceAchievementIDs: reveal.sourceAchievementIDs,
            sourceRuleIDs: reveal.sourceRuleIDs,
            catalog: catalog
        )
        let canonical = PendingRevealRecord(
            generation: generation,
            revealID: reveal.revealID,
            transactionID: reveal.transactionID,
            createdRevision: reveal.createdRevision,
            createdAt: reveal.createdAt,
            state: reveal.state,
            presentedAt: reveal.presentedAt,
            acknowledgedAt: reveal.acknowledgedAt,
            tier: shape.tier,
            primaryContentID: shape.primaryContentID,
            secondaryContentIDs: shape.secondaryContentIDs,
            sourceAchievementIDs: reveal.sourceAchievementIDs,
            sourceRuleIDs: reveal.sourceRuleIDs,
            nextRevealID: reveal.nextRevealID
        )
        try canonical.validate()
        return canonical
    }

    static func canonicalRevealBundle(
        _ bundle: CatalogMigrationRecord.UpgradeRevealBundle,
        catalog: ProgressionCatalog
    ) throws -> CatalogMigrationRecord.UpgradeRevealBundle {
        let shape = try canonicalRevealShape(
            tier: bundle.tier,
            primaryContentID: bundle.primaryContentID,
            secondaryContentIDs: bundle.secondaryContentIDs,
            sourceAchievementIDs: bundle.sourceAchievementIDs,
            sourceRuleIDs: bundle.sourceRuleIDs,
            catalog: catalog
        )
        return CatalogMigrationRecord.UpgradeRevealBundle(
            tier: shape.tier,
            primaryContentID: shape.primaryContentID,
            secondaryContentIDs: shape.secondaryContentIDs,
            sourceAchievementIDs: bundle.sourceAchievementIDs,
            sourceRuleIDs: bundle.sourceRuleIDs
        )
    }

    static func revealContentSignature(_ reveal: PendingRevealRecord) -> String {
        ([reveal.primaryContentID] + reveal.secondaryContentIDs)
            .map(\.rawValue)
            .sorted()
            .joined(separator: "|")
    }

    private static func preserveCompletions(
        from old: ProgressionProjection,
        in projection: inout ProgressionProjection
    ) throws {
        let generation = projection.metadata.activeGeneration
        for logical in old.logicalRecords() {
            switch logical {
            case let .achievementCompletion(record):
                let value: AchievementCompletionRecord
                if let external = record.sourceExternalMergeTransactionID {
                    value = AchievementCompletionRecord(
                        generation: generation,
                        preservingProvenance: record,
                        completedAt: record.completedAt,
                        sourceExternalMergeTransactionID: external
                    )
                } else if let eventID = record.sourceEventID {
                    value = AchievementCompletionRecord(
                        generation: generation,
                        achievementID: record.achievementID,
                        completedAt: record.completedAt,
                        sourceEventID: eventID
                    )
                } else if let transactionID =
                    record.sourceExistingUserMigrationTransactionID
                {
                    value = AchievementCompletionRecord(
                        generation: generation,
                        achievementID: record.achievementID,
                        completedAt: record.completedAt,
                        sourceExistingUserMigrationTransactionID: transactionID
                    )
                } else {
                    throw ProgressionDomainError.invalidRecord("catalog-v2-completion")
                }
                try projection.upsert(.achievementCompletion(value))
                let progressIdentity = "achievement-progress|\(record.achievementID.rawValue)"
                guard case var .achievementProgress(progress)? = projection.records[
                    progressIdentity
                ] else {
                    throw ProgressionDomainError.invalidRecord(
                        "catalog-v2-completion-progress"
                    )
                }
                progress.current = progress.target
                try projection.upsert(.achievementProgress(progress))
            case let .milestoneCompletion(record):
                let value: MilestoneCompletionRecord
                if let external = record.sourceExternalMergeTransactionID {
                    value = MilestoneCompletionRecord(
                        generation: generation,
                        preservingProvenance: record,
                        completedAt: record.completedAt,
                        sourceExternalMergeTransactionID: external
                    )
                } else if let eventID = record.sourceEventID {
                    value = MilestoneCompletionRecord(
                        generation: generation,
                        ruleID: record.ruleID,
                        completedAt: record.completedAt,
                        sourceEventID: eventID
                    )
                } else {
                    throw ProgressionDomainError.invalidRecord("catalog-v2-completion")
                }
                try projection.upsert(.milestoneCompletion(value))
            default:
                continue
            }
        }
    }

    private static func migrateContentUse(
        from old: ProgressionProjection,
        in projection: inout ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws {
        let generation = projection.metadata.activeGeneration
        for logical in old.logicalRecords() {
            guard case let .statisticContentUse(record) = logical else { continue }
            let prior = try canonicalContentUse(
                record,
                generation: generation,
                catalog: catalog
            )
            var canonical = Set(prior.contentIDs)
            if case let .statisticContentUse(current)? = projection.records[logical.identity] {
                canonical.formUnion(current.contentIDs)
            }
            let value = StatisticContentUseRecord(
                generation: generation,
                statisticID: record.statisticID,
                bucketID: record.bucketID,
                contentIDs: Array(canonical)
            )
            try value.validate()
            try projection.upsert(.statisticContentUse(value))
            try projection.upsert(.statisticCounter(StatisticCounterRecord(
                generation: generation,
                statisticID: record.statisticID,
                bucketID: record.bucketID,
                value: UInt64(value.contentIDs.count)
            )))
        }
    }

    private static func migrateEncounters(
        from old: ProgressionProjection,
        in projection: inout ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws {
        let generation = projection.metadata.activeGeneration
        for logical in old.logicalRecords() {
            guard case let .encounter(record) = logical else { continue }
            let canonical = try canonicalEncounter(
                record,
                generation: generation,
                catalog: catalog
            )
            try projection.upsert(.encounter(canonical))
        }
    }

    private static func migrateGrantsAndOwnership(
        from old: ProgressionProjection,
        in projection: inout ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws {
        let generation = projection.metadata.activeGeneration
        var mappedGrantKeys: [String: String] = [:]
        for logical in old.logicalRecords() {
            guard case let .grant(record) = logical,
                  let mapped = mappedGrant(
                    record,
                    generation: generation,
                    catalog: catalog
                  )
            else {
                if case .grant = logical {
                    throw ProgressionDomainError.invalidRecord("catalog-v2-grant-map")
                }
                continue
            }
            try mapped.validate()
            let mappedLogical = ProgressionLogicalRecord.grant(mapped)
            mappedGrantKeys[logical.identity] = mappedLogical.identity
            try projection.upsert(mappedLogical)
        }

        struct OwnershipFacts {
            var sourceGrantKeys = Set<String>()
            var grantedAt: Date?
        }
        var facts: [ProgressionContentID: OwnershipFacts] = [:]
        for logical in old.logicalRecords() {
            guard case let .ownership(record) = logical else { continue }
            for oldKey in record.sourceGrantKeys {
                guard let mappedKey = mappedGrantKeys[oldKey],
                      case let .grant(mappedGrant)? = projection.records[mappedKey]
                else {
                    throw ProgressionDomainError.invalidRecord("catalog-v2-ownership-map")
                }
                var value = facts[mappedGrant.contentID] ?? OwnershipFacts()
                value.sourceGrantKeys.insert(mappedKey)
                value.grantedAt = earliest(value.grantedAt, record.grantedAt)
                facts[mappedGrant.contentID] = value
            }
        }
        for (contentID, value) in facts {
            var sourceGrantKeys = value.sourceGrantKeys
            var grantedAt = value.grantedAt
            if case let .ownership(current)? = projection.records[
                "ownership|\(contentID.rawValue)"
            ] {
                sourceGrantKeys.formUnion(current.sourceGrantKeys)
                grantedAt = earliest(grantedAt, current.grantedAt)
            }
            let ownership = OwnershipRecord(
                generation: generation,
                contentID: contentID,
                sourceGrantKeys: Array(sourceGrantKeys),
                grantedAt: grantedAt
            )
            try ownership.validate()
            try projection.upsert(.ownership(ownership))
        }
    }

    private static func preserveEntitlements(
        from old: ProgressionProjection,
        in projection: inout ProgressionProjection
    ) throws {
        for logical in old.logicalRecords() {
            guard case let .entitlement(record) = logical else { continue }
            try projection.upsert(.entitlement(ProgressionEntitlementRecord(
                generation: projection.metadata.activeGeneration,
                copying: record,
                grantedAt: record.grantedAt
            )))
        }
    }

    private static func recomputeArtifactCount(
        in projection: inout ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws {
        let count = projection.logicalRecords().reduce(into: UInt64(0)) { value, logical in
            guard case let .ownership(record) = logical,
                  catalog.content(id: record.contentID)?.countsAsArtifact == true
            else { return }
            value += 1
        }
        try projection.upsert(.statisticCounter(StatisticCounterRecord(
            generation: projection.metadata.activeGeneration,
            statisticID: StatisticID(rawValue: "stat.ownership.artifact-count")!,
            bucketID: nil,
            value: count
        )))
    }

    private static func mappedGrantContentID(
        _ record: GrantRecord,
        catalog: ProgressionCatalog
    ) -> ProgressionContentID? {
        guard let group = catalog.grantGroup(id: record.grantGroupID) else { return nil }
        if group.items.contains(where: { $0.contentID == record.contentID }) {
            return record.contentID
        }
        let key = "\(record.grantGroupID.rawValue)|\(record.contentID.rawValue)"
        guard let raw = legacyGrantRoutes[key],
              let contentID = ProgressionContentID(rawValue: raw),
              group.items.contains(where: { $0.contentID == contentID })
        else { return nil }
        return contentID
    }

    private static func add(
        _ group: ProgressionGrantGroup,
        to candidates: inout [ProgressionContentID: RevealCandidate]
    ) {
        let tier = durableTier(group.revealTier)
        for item in group.items {
            let incoming = RevealCandidate(
                contentID: item.contentID,
                groupID: group.grantGroupID,
                tier: tier,
                isPrimary: item.contentID == group.primaryContentID
            )
            if let current = candidates[item.contentID],
               !revealSortsBefore(incoming, current)
            {
                continue
            }
            candidates[item.contentID] = incoming
        }
    }

    private struct RevealShape {
        let tier: ProgressionDurableRevealTier
        let primaryContentID: ProgressionContentID
        let secondaryContentIDs: [ProgressionContentID]
    }

    private static func canonicalRevealShape(
        tier: ProgressionDurableRevealTier,
        primaryContentID: ProgressionContentID,
        secondaryContentIDs: [ProgressionContentID],
        sourceAchievementIDs: [AchievementID],
        sourceRuleIDs: [RuleID],
        catalog: ProgressionCatalog
    ) throws -> RevealShape {
        let storedContentIDs = [primaryContentID] + secondaryContentIDs
        if storedContentIDs.allSatisfy({ catalog.content(id: $0) != nil }) {
            return RevealShape(
                tier: tier,
                primaryContentID: primaryContentID,
                secondaryContentIDs: secondaryContentIDs
            )
        }
        guard isCurrentCatalog(catalog),
              storedContentIDs.allSatisfy({ contentID in
                  catalog.content(id: contentID) != nil ||
                    legacyContentAliases[contentID.rawValue] != nil
              })
        else {
            throw ProgressionDomainError.invalidRecord("catalog-v2-reveal")
        }

        let groups = try revealSourceGroups(
            sourceAchievementIDs: sourceAchievementIDs,
            sourceRuleIDs: sourceRuleIDs,
            catalog: catalog
        )
        var legacyCandidates: [ProgressionContentID: RevealCandidate] = [:]
        for group in groups { try addLegacy(group, to: &legacyCandidates) }
        let orderedLegacy = legacyCandidates.values.sorted(by: revealSortsBefore)
        guard let legacyPrimary = orderedLegacy.first,
              tier == legacyPrimary.tier,
              primaryContentID == legacyPrimary.contentID,
              secondaryContentIDs == orderedLegacy.dropFirst().map(\.contentID).sorted()
        else {
            throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-legacy-shape")
        }

        var currentCandidates: [ProgressionContentID: RevealCandidate] = [:]
        for group in groups { add(group, to: &currentCandidates) }
        let orderedCurrent = currentCandidates.values.sorted(by: revealSortsBefore)
        guard let currentPrimary = orderedCurrent.first else {
            throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-empty")
        }
        return RevealShape(
            tier: currentPrimary.tier,
            primaryContentID: currentPrimary.contentID,
            secondaryContentIDs: orderedCurrent.dropFirst().map(\.contentID)
        )
    }

    private static func revealSourceGroups(
        sourceAchievementIDs: [AchievementID],
        sourceRuleIDs: [RuleID],
        catalog: ProgressionCatalog
    ) throws -> [ProgressionGrantGroup] {
        var groups: [ProgressionGrantGroup] = []
        for achievementID in sourceAchievementIDs {
            guard let achievement = catalog.achievement(id: achievementID),
                  let group = catalog.grantGroup(id: achievement.rewardGrantGroupID)
            else { throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-source") }
            groups.append(group)
        }
        for ruleID in sourceRuleIDs {
            guard let milestone = catalog.milestone(id: ruleID),
                  let group = catalog.grantGroup(id: milestone.grantGroupID)
            else { throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-source") }
            groups.append(group)
        }
        guard !groups.isEmpty else {
            throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-empty")
        }
        return groups
    }

    private static func addLegacy(
        _ currentGroup: ProgressionGrantGroup,
        to candidates: inout [ProgressionContentID: RevealCandidate]
    ) throws {
        guard let legacy = legacyRevealGroups[currentGroup.grantGroupID.rawValue] else {
            add(currentGroup, to: &candidates)
            return
        }
        guard let primary = ProgressionContentID(rawValue: legacy.primary),
              legacy.items.contains(legacy.primary)
        else { throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-legacy-group") }
        let tier = durableTier(currentGroup.revealTier)
        for rawValue in legacy.items {
            guard let contentID = ProgressionContentID(rawValue: rawValue) else {
                throw ProgressionDomainError.invalidRecord("catalog-v2-reveal-legacy-group")
            }
            let incoming = RevealCandidate(
                contentID: contentID,
                groupID: currentGroup.grantGroupID,
                tier: tier,
                isPrimary: contentID == primary
            )
            if let current = candidates[contentID],
               !revealSortsBefore(incoming, current)
            {
                continue
            }
            candidates[contentID] = incoming
        }
    }

    private static func revealSortsBefore(
        _ lhs: RevealCandidate,
        _ rhs: RevealCandidate
    ) -> Bool {
        let left = (
            tierRank(lhs.tier), lhs.isPrimary ? 1 : 0,
            lhs.groupID.rawValue, lhs.contentID.rawValue
        )
        let right = (
            tierRank(rhs.tier), rhs.isPrimary ? 1 : 0,
            rhs.groupID.rawValue, rhs.contentID.rawValue
        )
        return left > right
    }

    private static func durableTier(
        _ value: ProgressionCatalogRevealTier
    ) -> ProgressionDurableRevealTier {
        switch value {
        case .none: .none
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        }
    }

    private static func tierRank(_ value: ProgressionDurableRevealTier) -> Int {
        switch value {
        case .none: 0
        case .micro: 1
        case .artifact: 2
        case .codex: 3
        case .mastery: 4
        }
    }

    private static func earliest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (left?, right?): min(left, right)
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private static func mergeProvenance(
        _ lhs: DomainEventProvenanceStatus,
        _ rhs: DomainEventProvenanceStatus
    ) -> DomainEventProvenanceStatus {
        provenanceRank(lhs) >= provenanceRank(rhs) ? lhs : rhs
    }

    private static func provenanceRank(_ value: DomainEventProvenanceStatus) -> Int {
        switch value {
        case .absent: 0
        case .verified: 1
        case .unverified: 2
        case .unsupported: 3
        case .invalid: 4
        }
    }

    private static let legacyContentAliases: [String: String] = [
        "relic.norse.runestone.weathered": "relic.norse.runestone-tablet",
        "relic.norse.raven-medallion": "relic.norse.dragonwood-plaque",
        "relic.norse.ironbound-shield": "relic.norse.stormforged-stele",
        "relic.norse.sealed-parchment": "relic.norse.dragonwood-plaque",
        "relic.norse.runestone.blackstone": "relic.norse.stormforged-stele",
        "relic.norse.runestone.frozen": "relic.norse.runestone-tablet",
        "seal.norse.knotwork": "seal.norse.valknut",
        "seal.norse.forge-flame": "seal.norse.ravenshield",
        "seal.norse.raven": "seal.norse.ravenshield",
        "seal.norse.longship": "seal.norse.wolkin",
        "seal.norse.forge-hammer": "seal.norse.mjolnir",
        "seal.norse.echo-rune": "seal.norse.yggdrasil",
        "crest.norse.forge-master": "crest.norse.raven-mastery",
    ]

    private static let legacyGrantRoutes: [String: String] = [
        "grant-group.base.norse.included|relic.norse.runestone.weathered":
            "relic.norse.runestone-tablet",
        "grant-group.base.norse.included|seal.norse.knotwork": "seal.norse.valknut",
        "grant-group.base.norse.included|seal.norse.forge-flame":
            "seal.norse.ravenshield",
        "grant-group.first-inscription|seal.norse.raven": "seal.norse.mjolnir",
        "grant-group.first-dispatch|relic.norse.raven-medallion":
            "relic.norse.dragonwood-plaque",
        "grant-group.correspondent|seal.norse.longship": "seal.norse.wolkin",
        "grant-group.courier-1|seal.norse.forge-hammer": "seal.norse.yggdrasil",
        "grant-group.courier-2|relic.norse.ironbound-shield":
            "relic.norse.stormforged-stele",
        "grant-group.archivist-2|relic.norse.sealed-parchment": "seal.norse.berserk",
        "grant-group.codex.norse.echo-five|seal.norse.echo-rune":
            "seal.norse.yggdrasil",
        "grant-group.codex.norse.mastery|relic.norse.runestone.blackstone":
            "crest.norse.raven-mastery",
        "grant-group.codex.norse.mastery|crest.norse.forge-master":
            "title.norse.master-of-runes",
    ]

    private static let legacyRevealGroups: [String: (items: [String], primary: String)] = [
        "grant-group.first-inscription": (
            ["seal.norse.raven"], "seal.norse.raven"
        ),
        "grant-group.first-dispatch": (
            ["relic.norse.raven-medallion"], "relic.norse.raven-medallion"
        ),
        "grant-group.correspondent": (
            ["seal.norse.longship"], "seal.norse.longship"
        ),
        "grant-group.courier-1": (
            ["seal.norse.forge-hammer"], "seal.norse.forge-hammer"
        ),
        "grant-group.courier-2": (
            ["relic.norse.ironbound-shield"], "relic.norse.ironbound-shield"
        ),
        "grant-group.archivist-2": (
            ["title.archivist", "relic.norse.sealed-parchment"], "title.archivist"
        ),
        "grant-group.codex.norse.echo-five": (
            ["seal.norse.echo-rune"], "seal.norse.echo-rune"
        ),
        "grant-group.codex.norse.mastery": (
            ["relic.norse.runestone.blackstone", "crest.norse.forge-master"],
            "relic.norse.runestone.blackstone"
        ),
    ]
}
