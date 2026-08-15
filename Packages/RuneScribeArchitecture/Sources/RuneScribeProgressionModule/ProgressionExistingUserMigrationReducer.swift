import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

struct ExistingUserMigrationReductionOutput: Sendable {
    let projection: ProgressionProjection
    let seedRecords: [ExistingUserMigrationSeedRecord]
    let distinctTokens: [DistinctTokenRecord]
    let pendingReveal: PendingRevealRecord?
    let delta: ProgressionStateDeltaSummary
}

enum ProgressionExistingUserMigrationReducer {
    private static let cipherStatisticID = StatisticID(
        rawValue: "stat.cipher.created-or-imported.unique"
    )!
    private static let archivistIDs: [AchievementID] = [
        AchievementID(rawValue: "achievement.archivist-1")!,
        AchievementID(rawValue: "achievement.archivist-2")!,
    ]

    private struct Candidate {
        let contentID: ProgressionContentID
        let groupID: GrantGroupID
        let tier: ProgressionDurableRevealTier
        let isPrimary: Bool
        var sources: Set<ProgressionGrantSource>
    }

    static func replay(
        record: ExistingUserMigrationRecord,
        seedRecords: [ExistingUserMigrationSeedRecord],
        to initialProjection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ExistingUserMigrationReductionOutput {
        let ciphers = try seedRecords.map {
            try ExistingUserMigrationCipherDTO(
                cipherToken: $0.cipherToken,
                origin: $0.origin
            )
        }
        guard ciphers.count == Int(record.cipherCount) else {
            throw ProgressionDomainError.invalidRecord(
                "existing-user-migration-seed-evidence"
            )
        }
        let output: ExistingUserMigrationReductionOutput
        if record.handoffSchemaVersion ==
            ExistingUserMigrationPageDTO.currentHandoffSchemaVersion
        {
            guard let pageCount = record.pageCount,
                  try aggregateDigest(
                    ciphers: ciphers,
                    pageCount: pageCount
                  ) == record.snapshotDigest
            else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-seed-evidence"
                )
            }
            output = try applyCanonical(
                ciphers: ciphers,
                snapshotSchemaVersion: record.snapshotSchemaVersion,
                handoffSchemaVersion: record.handoffSchemaVersion,
                pageCount: pageCount,
                transactionID: record.transactionID,
                snapshotDigest: record.snapshotDigest,
                completedAt: record.completedAt,
                to: initialProjection,
                bundle: bundle
            )
        } else {
            let snapshot = try ExistingUserMigrationSnapshotDTO(ciphers: ciphers)
            guard snapshot.schemaVersion == record.snapshotSchemaVersion,
                  try ProgressionDeterminism.encodedIntegrityDigest(snapshot) ==
                    record.snapshotDigest
            else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-seed-evidence"
                )
            }
            output = try apply(
                snapshot: snapshot,
                transactionID: record.transactionID,
                snapshotDigest: record.snapshotDigest,
                completedAt: record.completedAt,
                to: initialProjection,
                bundle: bundle
            )
        }
        guard case let .existingUserMigration(replayed)? = output.projection.records[
            "existing-user-migration|1"
        ], replayed.snapshotSchemaVersion == record.snapshotSchemaVersion,
            replayed.transactionID == record.transactionID,
            replayed.snapshotDigest == record.snapshotDigest,
            replayed.cipherCount == record.cipherCount,
            replayed.handoffSchemaVersion == record.handoffSchemaVersion,
            replayed.pageCount == record.pageCount,
            replayed.completedAt == record.completedAt,
            replayed.grantTransactionID == record.grantTransactionID,
            replayed.revealBundle == record.revealBundle
        else {
            throw ProgressionDomainError.invalidRecord(
                "existing-user-migration-replay-mismatch"
            )
        }
        return output
    }

    static func apply(
        snapshot: ExistingUserMigrationSnapshotDTO,
        transactionID: UUID,
        snapshotDigest: String,
        completedAt: Date,
        to initialProjection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ExistingUserMigrationReductionOutput {
        guard snapshot.schemaVersion == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              snapshot.ciphers.count <= ExistingUserMigrationSnapshotDTO.maximumCipherCount,
              try ProgressionDeterminism.encodedIntegrityDigest(snapshot) == snapshotDigest
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-baseline")
        }
        return try applyCanonical(
            ciphers: snapshot.ciphers,
            snapshotSchemaVersion: snapshot.schemaVersion,
            handoffSchemaVersion: nil,
            pageCount: nil,
            transactionID: transactionID,
            snapshotDigest: snapshotDigest,
            completedAt: completedAt,
            to: initialProjection,
            bundle: bundle
        )
    }

    static func applyPaged(
        ciphers: [ExistingUserMigrationCipherDTO],
        pageCount: UInt32,
        transactionID: UUID,
        aggregateDigest: String,
        completedAt: Date,
        to initialProjection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ExistingUserMigrationReductionOutput {
        guard ciphers.count > ExistingUserMigrationSnapshotDTO.maximumCipherCount,
              ciphers.count <= Int(UInt32.max),
              try self.aggregateDigest(
                ciphers: ciphers,
                pageCount: pageCount
              ) == aggregateDigest
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-baseline")
        }
        return try applyCanonical(
            ciphers: ciphers,
            snapshotSchemaVersion: ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
            handoffSchemaVersion:
                ExistingUserMigrationPageDTO.currentHandoffSchemaVersion,
            pageCount: pageCount,
            transactionID: transactionID,
            snapshotDigest: aggregateDigest,
            completedAt: completedAt,
            to: initialProjection,
            bundle: bundle
        )
    }

    static func aggregateDigest(
        ciphers: [ExistingUserMigrationCipherDTO],
        pageCount: UInt32
    ) throws -> String {
        guard ciphers.count <= Int(UInt32.max) else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-count")
        }
        let maximum = ExistingUserMigrationSnapshotDTO.maximumCipherCount
        let expectedPageCount = ciphers.isEmpty
            ? 1
            : ((ciphers.count - 1) / maximum) + 1
        guard pageCount == UInt32(expectedPageCount), pageCount >= 2 else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-page-count")
        }
        var material = Data("existing-user-migration-paged-v2".utf8)
        append(UInt32(ciphers.count), to: &material)
        append(pageCount, to: &material)
        for (index, start) in stride(from: 0, to: ciphers.count, by: maximum)
            .enumerated()
        {
            let end = min(start + maximum, ciphers.count)
            let page = try ExistingUserMigrationSnapshotDTO(
                ciphers: Array(ciphers[start ..< end])
            )
            append(UInt32(index), to: &material)
            material.append(try digestBytes(
                ProgressionDeterminism.encodedIntegrityDigest(page)
            ))
        }
        return RuntimeIntegrityDigest.sha256Hex(material)
    }

    private static func applyCanonical(
        ciphers: [ExistingUserMigrationCipherDTO],
        snapshotSchemaVersion: UInt16,
        handoffSchemaVersion: UInt16?,
        pageCount: UInt32?,
        transactionID: UUID,
        snapshotDigest: String,
        completedAt: Date,
        to initialProjection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ExistingUserMigrationReductionOutput {
        guard snapshotSchemaVersion == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              Set(ciphers.map(\.cipherToken)).count == ciphers.count,
              ProgressionDeterminism.isIntegrityDigest(snapshotDigest),
              initialProjection.metadata.appliedEventCount == 0,
              initialProjection.metadata.processedEventCount == 0,
              initialProjection.metadata.distinctTokenCount == 0,
              initialProjection.records["existing-user-migration|1"] == nil,
              case let .revealQueueState(queue)? = initialProjection.records[
                "reveal-queue-state"
              ], queue.pendingCount == 0
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-baseline")
        }

        let canonical = ciphers.sorted {
            if $0.cipherToken != $1.cipherToken {
                return $0.cipherToken < $1.cipherToken
            }
            return $0.origin.rawValue < $1.origin.rawValue
        }
        guard canonical == ciphers else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-order")
        }

        var projection = initialProjection
        let generation = projection.metadata.activeGeneration
        let nextRevisionResult = projection.metadata.revision.addingReportingOverflow(1)
        guard !nextRevisionResult.overflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        let revision = nextRevisionResult.partialValue
        let cipherCount = UInt64(canonical.count)
        let grantTransactionID = existingUserMigrationGrantTransactionID(transactionID)

        let seeds = canonical.enumerated().map { index, cipher in
            ExistingUserMigrationSeedRecord(
                generation: generation,
                cipherToken: cipher.cipherToken,
                origin: cipher.origin,
                sourcePageIndex: handoffSchemaVersion == nil
                    ? nil
                    : UInt32(
                        index / ExistingUserMigrationSnapshotDTO.maximumCipherCount
                    )
            )
        }
        let distinct = canonical.map {
            DistinctTokenRecord(
                generation: generation,
                statisticID: cipherStatisticID,
                bucketID: nil,
                canonicalToken: $0.cipherToken.rawValue,
                firstAppliedRevision: revision
            )
        }
        for record in seeds { try record.validate() }
        for record in distinct { try record.validate() }

        try projection.upsert(.statisticCounter(StatisticCounterRecord(
            generation: generation,
            statisticID: cipherStatisticID,
            bucketID: nil,
            value: cipherCount
        )))

        var candidates: [ProgressionContentID: Candidate] = [:]
        var completedAchievementCount = 0
        for achievementID in archivistIDs {
            guard let achievement = bundle.catalog.achievement(id: achievementID) else {
                throw ProgressionDomainError.invalidRecord("existing-user-archivist-missing")
            }
            let evaluation = ProgressionRuleEvaluator.evaluate(
                achievement.rule,
                facts: ProgressionRuleFacts(projection: projection)
            )
            guard evaluation.isSatisfied else { continue }
            try projection.upsert(.achievementCompletion(AchievementCompletionRecord(
                generation: generation,
                achievementID: achievementID,
                completedAt: completedAt,
                sourceExistingUserMigrationTransactionID: transactionID
            )))
            completedAchievementCount += 1
            try applyGrantGroup(
                achievement.rewardGrantGroupID,
                source: .achievement(achievementID),
                transactionID: grantTransactionID,
                grantedAt: completedAt,
                bundle: bundle,
                projection: &projection,
                candidates: &candidates
            )
        }

        try recomputeDerivedStatistics(bundle: bundle, projection: &projection)
        try updateAchievementProgress(bundle: bundle, projection: &projection)

        let reveal = try makeReveal(
            candidates: candidates,
            generation: generation,
            transactionID: transactionID,
            grantTransactionID: grantTransactionID,
            createdRevision: revision,
            createdAt: completedAt
        )
        if let reveal {
            try projection.upsert(.revealQueueState(ProgressionRevealQueueStateRecord(
                generation: generation,
                pendingCount: 1,
                headRevealID: reveal.revealID,
                tailRevealID: reveal.revealID
            )))
        }

        let migration = ExistingUserMigrationRecord(
            generation: generation,
            snapshotSchemaVersion: snapshotSchemaVersion,
            transactionID: transactionID,
            snapshotDigest: snapshotDigest,
            cipherCount: UInt32(canonical.count),
            handoffSchemaVersion: handoffSchemaVersion,
            pageCount: pageCount,
            completedAt: completedAt,
            grantTransactionID: grantTransactionID,
            revealBundle: reveal.map(CatalogMigrationRecord.UpgradeRevealBundle.init(reveal:))
        )
        try projection.upsert(.existingUserMigration(migration))
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = completedAt
        projection.metadata.distinctTokenCount = cipherCount
        try projection.metadata.validate()

        let ownedRewardCount = candidates.count
        return ExistingUserMigrationReductionOutput(
            projection: projection,
            seedRecords: seeds,
            distinctTokens: distinct,
            pendingReveal: reveal,
            delta: ProgressionStateDeltaSummary(
                changedStatisticCount: canonical.isEmpty ? 0 : 1,
                completedAchievementCount: UInt16(completedAchievementCount),
                completedMilestoneCount: 0,
                grantedContentCount: UInt16(ownedRewardCount),
                grantedEntitlementCount: 0,
                queuedRevealCount: reveal == nil ? 0 : 1
            )
        )
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func digestBytes(_ value: String) throws -> Data {
        guard ProgressionDeterminism.isIntegrityDigest(value) else {
            throw ProgressionDomainError.invalidRecord(
                "existing-user-migration-page-digest"
            )
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(32)
        var index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index ..< end], radix: 16) else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-page-digest"
                )
            }
            bytes.append(byte)
            index = end
        }
        return Data(bytes)
    }

    private static func applyGrantGroup(
        _ grantGroupID: GrantGroupID,
        source: ProgressionGrantSource,
        transactionID: GrantTransactionID,
        grantedAt: Date,
        bundle: ValidatedProgressionCatalogBundle,
        projection: inout ProgressionProjection,
        candidates: inout [ProgressionContentID: Candidate]
    ) throws {
        guard let group = bundle.catalog.grantGroup(id: grantGroupID),
              group.revealTier == .artifact
        else { throw ProgressionDomainError.invalidRecord("existing-user-grant-group") }
        let generation = projection.metadata.activeGeneration
        for item in group.items.sorted(by: { $0.contentID.rawValue < $1.contentID.rawValue }) {
            guard let content = bundle.catalog.content(id: item.contentID),
                  content.availability != .included
            else { throw ProgressionDomainError.unknownContent(item.contentID.rawValue) }
            let grant = GrantRecord(
                generation: generation,
                grantGroupID: grantGroupID,
                contentID: item.contentID,
                source: source,
                transactionID: transactionID,
                grantedAt: grantedAt
            )
            let logical = ProgressionLogicalRecord.grant(grant)
            guard projection.records[logical.identity] == nil else {
                throw ProgressionDomainError.recordIdentityCollision(logical.identity)
            }
            try projection.upsert(logical)
            let ownershipIdentity = "ownership|\(item.contentID.rawValue)"
            let wasOwned = projection.records[ownershipIdentity] != nil
            if case let .ownership(existing)? = projection.records[ownershipIdentity] {
                var keys = Set(existing.sourceGrantKeys)
                keys.insert(logical.identity)
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: generation,
                    contentID: item.contentID,
                    sourceGrantKeys: Array(keys),
                    grantedAt: existing.grantedAt
                )))
            } else {
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: generation,
                    contentID: item.contentID,
                    sourceGrantKeys: [logical.identity],
                    grantedAt: grantedAt
                )))
            }
            guard !wasOwned else { continue }
            let incoming = Candidate(
                contentID: item.contentID,
                groupID: grantGroupID,
                tier: .artifact,
                isPrimary: item.contentID == group.primaryContentID,
                sources: [source]
            )
            if var prior = candidates[item.contentID] {
                prior.sources.insert(source)
                candidates[item.contentID] = prior
            } else {
                candidates[item.contentID] = incoming
            }
        }
    }

    private static func makeReveal(
        candidates: [ProgressionContentID: Candidate],
        generation: String,
        transactionID: UUID,
        grantTransactionID: GrantTransactionID,
        createdRevision: UInt64,
        createdAt: Date
    ) throws -> PendingRevealRecord? {
        let sorted = candidates.values.sorted { lhs, rhs in
            let left = (lhs.isPrimary ? 1 : 0, lhs.groupID.rawValue, lhs.contentID.rawValue)
            let right = (rhs.isPrimary ? 1 : 0, rhs.groupID.rawValue, rhs.contentID.rawValue)
            return left > right
        }
        guard let primary = sorted.first else { return nil }
        let sources = sorted.reduce(into: Set<ProgressionGrantSource>()) {
            $0.formUnion($1.sources)
        }
        let reveal = PendingRevealRecord(
            generation: generation,
            revealID: RevealID(
                rawValue: "reveal.migration.1.\(transactionID.uuidString.lowercased())"
            )!,
            transactionID: grantTransactionID,
            createdRevision: createdRevision,
            createdAt: createdAt,
            state: .queued,
            acknowledgedAt: nil,
            tier: primary.tier,
            primaryContentID: primary.contentID,
            secondaryContentIDs: sorted.dropFirst().map(\.contentID),
            sourceAchievementIDs: sources.compactMap {
                guard case let .achievement(id) = $0 else { return nil }
                return id
            },
            sourceRuleIDs: []
        )
        try reveal.validate()
        return reveal
    }

    private static func recomputeDerivedStatistics(
        bundle: ValidatedProgressionCatalogBundle,
        projection: inout ProgressionProjection
    ) throws {
        let owned = Set(projection.records(matching: { logical -> ProgressionContentID? in
            guard case let .ownership(record) = logical else { return nil }
            return record.contentID
        }))
        let completed = Set(projection.records(matching: { logical -> AchievementID? in
            guard case let .achievementCompletion(record) = logical else { return nil }
            return record.achievementID
        }))
        for statistic in bundle.catalog.statistics where statistic.storage == .derived {
            let value: UInt64
            switch statistic.dimension {
            case .contentID:
                value = UInt64(owned.filter {
                    bundle.catalog.content(id: $0)?.countsAsArtifact == true
                }.count)
            case .achievementID:
                value = UInt64(completed.count)
            default:
                value = 0
            }
            try projection.upsert(.statisticCounter(StatisticCounterRecord(
                generation: projection.metadata.activeGeneration,
                statisticID: statistic.statisticID,
                bucketID: nil,
                value: value
            )))
        }
    }

    private static func updateAchievementProgress(
        bundle: ValidatedProgressionCatalogBundle,
        projection: inout ProgressionProjection
    ) throws {
        let completed = Set(projection.records(matching: { logical -> AchievementID? in
            guard case let .achievementCompletion(record) = logical else { return nil }
            return record.achievementID
        }))
        for achievement in bundle.catalog.achievements {
            let target = UInt64(achievement.progress.target)
            let current: UInt64
            if completed.contains(achievement.achievementID) {
                current = target
            } else if achievement.progress.statisticID.rawValue ==
                "stat.achievement.completed-count"
            {
                let excluded = Set(achievement.progress.excludeAchievementIDs ?? [])
                current = min(UInt64(completed.subtracting(excluded).count), target)
            } else if case let .statisticCounter(counter)? = projection.records[
                "counter|\(achievement.progress.statisticID.rawValue)|-"
            ] {
                current = min(counter.value, target)
            } else {
                current = 0
            }
            try projection.upsert(.achievementProgress(AchievementProgressRecord(
                generation: projection.metadata.activeGeneration,
                achievementID: achievement.achievementID,
                current: current,
                target: target
            )))
        }
    }
}
