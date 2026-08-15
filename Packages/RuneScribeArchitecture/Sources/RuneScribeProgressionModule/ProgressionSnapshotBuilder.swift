import Foundation
import RuneScribeContracts

private struct ProgressionArchiveSummary {
    var first: Date
    var last: Date
    var count: UInt64
    var provenance: DomainEventProvenanceStatus
}

enum ProgressionSnapshotBuilder {
    static func snapshot(
        state: ProgressionRepositoryState,
        bundle: ValidatedProgressionCatalogBundle,
        capturedAt: Date,
        providerAvailabilityByCodexID: [
            CodexID: ProgressionProviderAvailability
        ] = [:]
    ) throws -> ProgressionSnapshotDTO {
        let projection = state.projection
        let ownership = ownershipRecords(projection)
        let encounters = encounterRecords(projection)
        let selectedTitleID = titleSelection(projection)?.selectedTitleID
        let queueState = revealQueueState(projection)

        let codexGates = try bundle.catalog.orderedJourneyNodes.compactMap {
            node -> ProgressionCodexGateDTO? in
            guard let content = bundle.catalog.content(id: node.contentID),
                  content.kind == .codex,
                  let codexID = CodexID(rawValue: node.contentID.rawValue)
            else { return nil }
            let unlockedAt = durableGrantedAt(
                ownership[node.contentID],
                projection: projection
            )
            let evaluation: ProgressionRuleEvaluation
            let components: [ProgressionGateComponentDTO]
            if let ruleID = node.gateRuleID,
               let milestone = bundle.catalog.milestone(id: ruleID)
            {
                let facts = ProgressionRuleFacts(projection: projection)
                evaluation = ProgressionRuleEvaluator.evaluate(
                    milestone.rule,
                    facts: facts
                )
                components = try milestone.progressComponents.enumerated().map {
                    index, component in
                    try gateComponent(
                        component,
                        index: index,
                        ruleID: milestone.ruleID,
                        facts: facts,
                        catalog: bundle.catalog
                    )
                }
                guard components.lazy.filter(\.isComplete).count ==
                    Int(evaluation.completedComponentCount),
                    components.count == Int(evaluation.requiredComponentCount)
                else {
                    throw ProgressionDomainError.invalidRecord(
                        "journey-component-evaluation-mismatch"
                    )
                }
            } else {
                evaluation = ProgressionRuleEvaluation(
                    isSatisfied: unlockedAt != nil,
                    current: unlockedAt == nil ? 0 : 1,
                    target: 1,
                    completedComponentCount: unlockedAt == nil ? 0 : 1,
                    requiredComponentCount: 1
                )
                components = [
                    try ProgressionGateComponentDTO(
                        componentID: "journey.\(codexID.rawValue).included",
                        label: "Included",
                        current: unlockedAt == nil ? 0 : 1,
                        target: 1,
                        isComplete: unlockedAt != nil
                    ),
                ]
            }
            guard evaluation.isSatisfied == (unlockedAt != nil) else {
                throw ProgressionDomainError.invalidRecord("journey-ownership-mismatch")
            }
            return try ProgressionCodexGateDTO(
                codexID: codexID,
                presentation: presentation(content),
                journeyOrder: node.order,
                completedRuleCount: evaluation.completedComponentCount,
                requiredRuleCount: evaluation.requiredComponentCount,
                progress: ProgressionNumericProgressDTO(
                    current: evaluation.current,
                    target: evaluation.target
                ),
                components: components,
                unlockedAt: unlockedAt
            )
        }

        let achievements = try bundle.catalog.achievements.map { definition in
            let progress = achievementProgress(definition.achievementID, projection: projection)
            let completion = achievementCompletion(
                definition.achievementID,
                projection: projection
            )
            let hidden = definition.visibility == .hiddenUntilProgress &&
                progress.current == 0 && completion == nil
            return try ProgressionAchievementDTO(
                achievementID: definition.achievementID,
                presentation: ProgressionPresentationDTO(
                    displayName: definition.displayName,
                    summary: hidden ? nil : definition.description,
                    fallbackSystemImageName: definition.fallbackSystemImage
                ),
                completedRuleCount: completion == nil ? 0 : 1,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(
                    current: progress.current,
                    target: progress.target
                ),
                completedAt: completion?.completedAt,
                isHidden: hidden,
                localPointWeight: definition.localPointWeight,
                rewards: try rewardSummary(
                    grantGroupID: definition.rewardGrantGroupID,
                    catalog: bundle.catalog
                )
            )
        }

        let statistics = try projection.records(matching: { logical -> StatisticCounterRecord? in
            if case let .statisticCounter(record) = logical { return record }
            return nil
        }).map { record in
            guard let definition = bundle.catalog.statistic(id: record.statisticID) else {
                throw ProgressionDomainError.invalidRecord("snapshot-statistic-reference")
            }
            return ProgressionStatisticDTO(
                statisticID: record.statisticID,
                presentation: try ProgressionPresentationDTO(
                    displayName: definition.displayName,
                    summary: nil,
                    fallbackSystemImageName: "chart.bar"
                ),
                codexID: record.bucketID,
                value: record.value
            )
        }

        let ownershipDTOs = try bundle.catalog.content.map { definition in
            let reference = try contentReference(definition)
            let encounter = encounterSummary(
                definition.contentID,
                encounters: encounters
            )
            let owned = ownership[definition.contentID]
            let grantedAt = durableGrantedAt(owned, projection: projection)
            let firstEncounteredAt: Date?
            if let encounteredAt = encounter?.first,
               let grantedAt,
               grantedAt < encounteredAt
            {
                firstEncounteredAt = nil
            } else {
                firstEncounteredAt = encounter?.first
            }
            let state: ProgressionContentOwnershipState
            var renderState: ProgressionContentRenderState
            if owned != nil {
                state = .owned
                renderState = .genericFallback
            } else if encounter != nil {
                state = .encountered
                renderState = .genericFallback
            } else {
                state = .locked
                renderState = .locked
            }
            let providerAvailability: ProgressionProviderAvailability
            if state == .owned,
               let codexID = definition.codexID,
               let parentContentID = ProgressionContentID(rawValue: codexID.rawValue),
               ownership[parentContentID] != nil
            {
                providerAvailability = providerAvailabilityByCodexID[codexID] ??
                    .unavailable
            } else {
                providerAvailability = .unavailable
            }
            if state == .owned {
                switch providerAvailability {
                case .unavailable, .eligible:
                    renderState = .genericFallback
                case .active:
                    renderState = .providerAvailable
                case .failed:
                    renderState = .providerFailed
                }
            }
            return try ProgressionOwnershipDTO(
                kind: contentKind(definition.kind),
                reference: reference,
                presentation: presentation(definition),
                state: state,
                firstEncounteredAt: firstEncounteredAt,
                grantedAt: grantedAt,
                sourceRuleIDs: sourceRuleIDs(owned, projection: projection),
                providerAvailability: providerAvailability,
                renderState: renderState
            )
        }

        let encounterDTOs = try encounters.values.map { record in
            try ProgressionEncounterDTO(
                codexID: record.codexID,
                firstEncounteredAt: record.firstEncounteredAt,
                lastEncounteredAt: record.lastEncounteredAt,
                encounterCount: record.encounterCount,
                provenanceStatus: record.provenanceStatus
            )
        }
        let archive = try archiveEntries(
            encounters: encounters,
            ownership: ownership,
            projection: projection,
            catalog: bundle.catalog
        )
        let titles = try bundle.catalog.content.compactMap { definition -> ProgressionTitleDTO? in
            guard definition.kind == .title,
                  let titleID = TitleID(rawValue: definition.contentID.rawValue)
            else { return nil }
            return try ProgressionTitleDTO(
                titleID: titleID,
                presentation: presentation(definition),
                isOwned: ownership[definition.contentID] != nil,
                isSelected: titleID == selectedTitleID
            )
        }
        let entitlementIDs = projection.records(matching: {
            if case let .entitlement(record) = $0 { return record.entitlementID }
            return nil
        })
        let nextReveal = try state.nextPendingReveal.map {
            try revealSummary($0.value, catalog: bundle.catalog)
        }

        return try ProgressionSnapshotDTO(
            revision: projection.metadata.revision,
            capturedAt: capturedAt,
            availability: availability(for: state.health),
            storeHealth: state.health.loadState,
            catalogID: projection.metadata.catalogID,
            catalogVersion: projection.metadata.catalogVersion,
            codexGates: codexGates,
            achievements: achievements,
            statistics: statistics,
            ownership: ownershipDTOs,
            encounters: encounterDTOs,
            archive: archive,
            titles: titles,
            selectedTitleID: selectedTitleID,
            pendingRevealCount: queueState.pendingCount,
            nextReveal: nextReveal,
            entitlementIDs: entitlementIDs,
            gameCenterMirrorStatus: .notConfigured
        )
    }

    static func entitlements(
        state: ProgressionRepositoryState,
        capturedAt: Date
    ) throws -> ProgressionEntitlementSnapshotDTO {
        let records = state.projection.records(matching: {
            if case let .entitlement(record) = $0 { return record }
            return nil
        })
        return try ProgressionEntitlementSnapshotDTO(
            revision: state.projection.metadata.revision,
            capturedAt: capturedAt,
            includedUnlockIDs: records.filter { $0.source == .included }.map(\.entitlementID),
            earnedUnlockIDs: records.filter { $0.source == .earned }.map(\.entitlementID)
        )
    }

    static func diagnostics(
        state: ProgressionRepositoryState,
        bundle: ValidatedProgressionCatalogBundle,
        quarantineDiagnostics: ProgressionQuarantineDiagnostics,
        capturedAt: Date
    ) throws -> ProgressionDiagnosticsSummaryDTO {
        let grouped = Dictionary(grouping: state.projection.logicalRecords(), by: \.category)
        var durableCounts = grouped.mapValues { UInt64($0.count) }
        durableCounts[.metadata] = 1
        durableCounts[.processedEvent] = state.projection.metadata.processedEventCount
        durableCounts[.distinctToken] = state.projection.metadata.distinctTokenCount
        durableCounts[.pendingReveal] = UInt64(
            revealQueueState(state.projection).pendingCount
        )
        if state.health.quarantinedRecordCount > 0 {
            durableCounts[.quarantine] = state.health.quarantinedRecordCount
        }
        let counts = try durableCounts.sorted { $0.key.rawValue < $1.key.rawValue }.map {
            category, count in
            try ProgressionDiagnosticRecordCountDTO(
                category: category,
                count: min(count, ProgressionDiagnosticRecordCountDTO.maximumRecordCount)
            )
        }
        let hashes = [
            ProgressionDiagnosticHashDTO(
                kind: .catalog,
                digest: bundle.integrityMetadata.catalogSHA256
            ),
            ProgressionDiagnosticHashDTO(
                kind: .eventCatalog,
                digest: bundle.integrityMetadata.eventCatalogSHA256
            ),
        ]
        var errors: [ProgressionDiagnosticErrorDTO] = []
        if quarantineDiagnostics.recordDecodeCount > 0 {
            errors.append(try ProgressionDiagnosticErrorDTO(
                category: .recordDecode,
                count: min(
                    quarantineDiagnostics.recordDecodeCount,
                    ProgressionDiagnosticErrorDTO.maximumErrorCount
                ),
                mostRecentCode: ProgressionRepositoryIDs.recordDecodeCode
            ))
        }
        if quarantineDiagnostics.recordReferenceCount > 0 {
            errors.append(try ProgressionDiagnosticErrorDTO(
                category: .recordReference,
                count: min(
                    quarantineDiagnostics.recordReferenceCount,
                    ProgressionDiagnosticErrorDTO.maximumErrorCount
                ),
                mostRecentCode: ProgressionRepositoryIDs.recordReferenceCode
            ))
        }
        if quarantineDiagnostics.integrityCount > 0 {
            errors.append(try ProgressionDiagnosticErrorDTO(
                category: .integrity,
                count: min(
                    quarantineDiagnostics.integrityCount,
                    ProgressionDiagnosticErrorDTO.maximumErrorCount
                ),
                mostRecentCode: nil
            ))
        }
        return try ProgressionDiagnosticsSummaryDTO(
            capturedAt: capturedAt,
            availability: availability(for: state.health),
            storeHealth: state.health.loadState,
            catalogID: bundle.catalog.catalogID,
            catalogVersion: bundle.catalog.catalogVersion,
            stateNamespaceSchemaVersion: ProgressionRepository.namespaceSchemaVersion,
            logicalRecordSchemaVersion: ProgressionRecordConstants.schemaVersion,
            pendingOutboxCount: 0,
            recordCounts: counts,
            hashes: hashes,
            errors: errors
        )
    }

    private static func archiveEntries(
        encounters: [CodexID: EncounterRecord],
        ownership: [ProgressionContentID: OwnershipRecord],
        projection: ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws -> [ProgressionArchiveEntryDTO] {
        var summaries: [ProgressionContentID: ProgressionArchiveSummary] = [:]
        for encounter in encounters.values {
            guard let codexContentID = ProgressionContentID(rawValue: encounter.codexID.rawValue)
            else { continue }
            merge(
                contentID: codexContentID,
                first: encounter.firstEncounteredAt,
                last: encounter.lastEncounteredAt,
                count: encounter.encounterCount,
                provenance: encounter.provenanceStatus,
                into: &summaries
            )
            for observation in encounter.artifactObservations {
                guard let contentID = ProgressionContentID(
                    rawValue: observation.artifactID.rawValue
                ) else {
                    continue
                }
                merge(
                    contentID: contentID,
                    first: observation.firstEncounteredAt,
                    last: observation.lastEncounteredAt,
                    count: observation.encounterCount,
                    provenance: observation.provenanceStatus,
                    into: &summaries
                )
            }
        }
        return try summaries.map { contentID, summary in
            guard let definition = catalog.content(id: contentID) else {
                throw ProgressionDomainError.unknownContent(contentID.rawValue)
            }
            let isOwned = ownership[contentID] != nil
            return try ProgressionArchiveEntryDTO(
                kind: contentKind(definition.kind),
                reference: contentReference(definition),
                presentation: presentation(definition),
                supportState: summary.provenance == .unsupported ? .unsupported : .known,
                ownershipState: isOwned ? .owned : .encountered,
                renderState: .genericFallback,
                firstEncounteredAt: summary.first,
                lastEncounteredAt: summary.last,
                encounterCount: summary.count,
                provenanceStatus: summary.provenance
            )
        }
    }

    private static func merge(
        contentID: ProgressionContentID,
        first: Date,
        last: Date,
        count: UInt64,
        provenance: DomainEventProvenanceStatus,
        into summaries: inout [ProgressionContentID: ProgressionArchiveSummary]
    ) {
        if let prior = summaries[contentID] {
            summaries[contentID] = ProgressionArchiveSummary(
                first: min(prior.first, first),
                last: max(prior.last, last),
                count: prior.count.addingReportingOverflow(count).overflow
                    ? UInt64.max : prior.count + count,
                provenance: mergeProvenance(prior.provenance, provenance)
            )
        } else {
            summaries[contentID] = ProgressionArchiveSummary(
                first: first,
                last: last,
                count: count,
                provenance: provenance
            )
        }
    }

    private static func availability(
        for health: ModuleStateHealthSnapshot
    ) -> ProgressionModuleAvailability {
        guard health.accessDisposition == .readWrite else { return .unavailable }
        guard health.quarantinedRecordCount == 0,
              health.loadState != .quarantined
        else { return .degraded }
        switch health.loadState {
        case .loaded, .migrated:
            return .available
        case .absent:
            return .degraded
        case .quarantined:
            return .degraded
        case .unreadable, .corrupt:
            return .unavailable
        }
    }

    private static func rewardSummary(
        grantGroupID: GrantGroupID,
        catalog: ProgressionCatalog
    ) throws -> ProgressionRewardSummaryDTO {
        guard let group = catalog.grantGroup(id: grantGroupID) else {
            throw ProgressionDomainError.invalidRecord("snapshot-grant-group")
        }
        var codexIDs: [CodexID] = []
        var artifactIDs: [ArtifactID] = []
        var entitlementIDs: [UnlockID] = []
        var titleIDs: [TitleID] = []
        var crestIDs: [CrestID] = []
        for item in group.items {
            guard let definition = catalog.content(id: item.contentID) else {
                throw ProgressionDomainError.unknownContent(item.contentID.rawValue)
            }
            switch definition.kind {
            case .codex:
                codexIDs.append(CodexID(rawValue: item.contentID.rawValue)!)
            case .entitlement:
                entitlementIDs.append(UnlockID(rawValue: item.contentID.rawValue)!)
            case .title:
                titleIDs.append(TitleID(rawValue: item.contentID.rawValue)!)
            case .crest:
                crestIDs.append(CrestID(rawValue: item.contentID.rawValue)!)
            case .frame, .relic, .script, .seal:
                artifactIDs.append(ArtifactID(rawValue: item.contentID.rawValue)!)
            }
        }
        return try ProgressionRewardSummaryDTO(
            codexIDs: codexIDs,
            contentIDs: artifactIDs,
            entitlementIDs: entitlementIDs,
            titleIDs: titleIDs,
            crestIDs: crestIDs
        )
    }

    private static func revealSummary(
        _ record: PendingRevealRecord,
        catalog: ProgressionCatalog
    ) throws -> ProgressionRevealSummaryDTO {
        guard let primary = catalog.content(id: record.primaryContentID) else {
            throw ProgressionDomainError.unknownContent(record.primaryContentID.rawValue)
        }
        return try ProgressionRevealSummaryDTO(
            revealID: record.revealID,
            transactionID: record.transactionID,
            createdAt: record.createdAt,
            state: record.state == .presented ? .presented : .pending,
            tier: revealTier(record.tier),
            rarity: rewardRarity(primary.rarity),
            primaryRewardID: contentReference(primary),
            primaryRewardPresentation: presentation(primary),
            secondaryRewardIDs: try record.secondaryContentIDs.map { contentID in
                guard let definition = catalog.content(id: contentID) else {
                    throw ProgressionDomainError.unknownContent(contentID.rawValue)
                }
                return try contentReference(definition)
            },
            sourceAchievementIDs: record.sourceAchievementIDs,
            sourceRuleIDs: record.sourceRuleIDs
        )
    }

    private static func ownershipRecords(
        _ projection: ProgressionProjection
    ) -> [ProgressionContentID: OwnershipRecord] {
        Dictionary(uniqueKeysWithValues: projection.records(matching: {
            if case let .ownership(record) = $0 { return (record.contentID, record) }
            return nil
        }))
    }

    private static func encounterRecords(
        _ projection: ProgressionProjection
    ) -> [CodexID: EncounterRecord] {
        Dictionary(uniqueKeysWithValues: projection.records(matching: {
            if case let .encounter(record) = $0 { return (record.codexID, record) }
            return nil
        }))
    }

    private static func titleSelection(
        _ projection: ProgressionProjection
    ) -> TitleSelectionRecord? {
        projection.records(matching: {
            if case let .titleSelection(record) = $0 { return record }
            return nil
        }).first
    }

    private static func revealQueueState(
        _ projection: ProgressionProjection
    ) -> ProgressionRevealQueueStateRecord {
        projection.records(matching: {
            if case let .revealQueueState(record) = $0 { return record }
            return nil
        }).first!
    }

    private static func achievementProgress(
        _ achievementID: AchievementID,
        projection: ProgressionProjection
    ) -> AchievementProgressRecord {
        if case let .achievementProgress(record)? = projection.records[
            "achievement-progress|\(achievementID.rawValue)"
        ] { return record }
        preconditionFailure("Validated projection is missing achievement progress")
    }

    private static func gateComponent(
        _ component: ProgressionProgressComponent,
        index: Int,
        ruleID: RuleID,
        facts: ProgressionRuleFacts,
        catalog: ProgressionCatalog
    ) throws -> ProgressionGateComponentDTO {
        let rule: ProgressionRule
        let label: String
        switch component.type {
        case .achievement:
            guard let achievementID = component.achievementID,
                  let definition = catalog.achievement(id: achievementID)
            else {
                throw ProgressionDomainError.invalidRecord("journey-component-achievement")
            }
            rule = .achievementCompleted(achievementID)
            label = definition.displayName
        case .ownership:
            guard let contentID = component.contentID,
                  let definition = catalog.content(id: contentID)
            else {
                throw ProgressionDomainError.invalidRecord("journey-component-ownership")
            }
            rule = .contentOwned(contentID)
            label = definition.displayName
        case .statistic:
            guard let statisticID = component.statisticID,
                  let target = component.target,
                  let definition = catalog.statistic(id: statisticID)
            else {
                throw ProgressionDomainError.invalidRecord("journey-component-statistic")
            }
            rule = .distinctCountAtLeast(
                statisticID: statisticID,
                threshold: target,
                bucketID: component.bucketID
            )
            label = definition.displayName
        case .allContentUsed:
            guard let statisticID = component.statisticID,
                  let bucketID = component.bucketID,
                  let contentIDs = component.contentIDs,
                  let codex = catalog.content(
                      id: ProgressionContentID(rawValue: bucketID.rawValue)!
                  )
            else {
                throw ProgressionDomainError.invalidRecord("journey-component-content-use")
            }
            rule = .allListedContentUsed(
                statisticID: statisticID,
                bucketID: bucketID,
                contentIDs: contentIDs
            )
            label = "Use all \(codex.displayName) artifacts"
        case .bucketThreshold:
            guard let statisticID = component.statisticID,
                  let minimumBuckets = component.minimumBuckets,
                  let minimumValue = component.minimumValuePerBucket,
                  let definition = catalog.statistic(id: statisticID)
            else {
                throw ProgressionDomainError.invalidRecord("journey-component-buckets")
            }
            rule = .bucketCountAtLeast(
                statisticID: statisticID,
                minimumBuckets: minimumBuckets,
                minimumValuePerBucket: minimumValue
            )
            label = definition.displayName
        }
        let evaluation = ProgressionRuleEvaluator.evaluate(rule, facts: facts)
        return try ProgressionGateComponentDTO(
            componentID: "\(ruleID.rawValue).component.\(index + 1)",
            label: label,
            current: evaluation.current,
            target: evaluation.target,
            isComplete: evaluation.isSatisfied
        )
    }

    private static func achievementCompletion(
        _ achievementID: AchievementID,
        projection: ProgressionProjection
    ) -> AchievementCompletionRecord? {
        if case let .achievementCompletion(record)? = projection.records[
            "achievement-completion|\(achievementID.rawValue)"
        ] { return record }
        return nil
    }

    private static func durableGrantedAt(
        _ ownership: OwnershipRecord?,
        projection: ProgressionProjection
    ) -> Date? {
        ownership?.grantedAt ?? (ownership == nil ? nil : projection.bootstrapRuntimeTimestamp)
    }

    private static func sourceRuleIDs(
        _ ownership: OwnershipRecord?,
        projection: ProgressionProjection
    ) -> [RuleID] {
        guard let ownership else { return [] }
        return ownership.sourceGrantKeys.compactMap { key in
            guard case let .grant(record)? = projection.records[key],
                  case let .milestone(ruleID) = record.source
            else { return nil }
            return ruleID
        }
    }

    private static func encounterSummary(
        _ contentID: ProgressionContentID,
        encounters: [CodexID: EncounterRecord]
    ) -> (first: Date, last: Date)? {
        var first: Date?
        var last: Date?
        for encounter in encounters.values {
            let matchesCodex = encounter.codexID.rawValue == contentID.rawValue
            let artifact = encounter.artifactObservations.first(where: {
                $0.artifactID.rawValue == contentID.rawValue
            })
            guard matchesCodex || artifact != nil else { continue }
            let candidateFirst = artifact?.firstEncounteredAt ?? encounter.firstEncounteredAt
            let candidateLast = artifact?.lastEncounteredAt ?? encounter.lastEncounteredAt
            first = min(first ?? candidateFirst, candidateFirst)
            last = max(last ?? candidateLast, candidateLast)
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    private static func presentation(
        _ definition: ProgressionContentDefinition
    ) throws -> ProgressionPresentationDTO {
        try ProgressionPresentationDTO(
            displayName: definition.displayName,
            summary: definition.notes,
            fallbackSystemImageName: fallbackSystemImage(definition.kind)
        )
    }

    private static func contentReference(
        _ definition: ProgressionContentDefinition
    ) throws -> ProgressionContentReference {
        switch definition.kind {
        case .codex: .codex(CodexID(rawValue: definition.contentID.rawValue)!)
        case .crest: .crest(CrestID(rawValue: definition.contentID.rawValue)!)
        case .entitlement: .entitlement(UnlockID(rawValue: definition.contentID.rawValue)!)
        case .title: .title(TitleID(rawValue: definition.contentID.rawValue)!)
        case .frame, .relic, .script, .seal:
            .artifact(ArtifactID(rawValue: definition.contentID.rawValue)!)
        }
    }

    private static func contentKind(
        _ kind: ProgressionCatalogContentKind
    ) -> ProgressionContentKind {
        switch kind {
        case .codex: .codex
        case .crest: .crest
        case .entitlement: .entitlement
        case .frame: .frame
        case .relic: .relic
        case .script: .script
        case .seal: .seal
        case .title: .title
        }
    }

    private static func fallbackSystemImage(
        _ kind: ProgressionCatalogContentKind
    ) -> String {
        switch kind {
        case .codex: "book.closed"
        case .crest: "shield"
        case .entitlement: "lock.open"
        case .frame: "rectangle"
        case .relic: "shippingbox"
        case .script: "textformat"
        case .seal: "seal"
        case .title: "person.text.rectangle"
        }
    }

    private static func revealTier(
        _ tier: ProgressionDurableRevealTier
    ) -> ProgressionRevealTier {
        switch tier {
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        case .none: preconditionFailure("Validated reveal cannot use none tier")
        }
    }

    private static func rewardRarity(
        _ rarity: ProgressionContentRarity
    ) -> ProgressionRewardRarity {
        switch rarity {
        case .forged: .forged
        case .inscribed: .inscribed
        case .rare: .rare
        case .mythic: .mythic
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
}
