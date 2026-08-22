import Foundation
import RuneScribeContracts
import RuneScribeProgressionSyncDomain

public struct RuntimeProgressionCounterFact: Codable, Equatable, Hashable, Sendable {
    public let statisticID: StatisticID
    public let codexID: CodexID?
    public let value: UInt64

    public init(statisticID: StatisticID, codexID: CodexID?, value: UInt64) {
        self.statisticID = statisticID
        self.codexID = codexID
        self.value = value
    }
}

public enum RuntimeProgressionStatisticTransport: String, Codable, CaseIterable, Sendable {
    case deviceCounter = "device-counter"
    case distinctToken = "distinct-token"
    case derivedOmitted = "derived-omitted"
}

public struct RuntimeProgressionStatisticSchema: Codable, Equatable, Hashable, Sendable {
    public let statisticID: StatisticID
    public let transport: RuntimeProgressionStatisticTransport
    public let requiresCodexBucket: Bool

    public init(
        statisticID: StatisticID,
        transport: RuntimeProgressionStatisticTransport,
        requiresCodexBucket: Bool
    ) {
        self.statisticID = statisticID
        self.transport = transport
        self.requiresCodexBucket = requiresCodexBucket
    }
}

public struct RuntimeProgressionDistinctTokenFact: Codable, Equatable, Hashable, Sendable {
    public let statisticID: StatisticID
    public let codexID: CodexID?
    /// A one-way SHA-256 value. The canonical Progression token never crosses
    /// the runtime boundary.
    public let opaqueTokenDigest: String
    public let firstObservedAt: Date

    public init(
        statisticID: StatisticID,
        codexID: CodexID?,
        opaqueTokenDigest: String,
        firstObservedAt: Date
    ) throws {
        guard opaqueTokenDigest.utf8.count == 64,
              opaqueTokenDigest.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
              }),
              firstObservedAt.timeIntervalSinceReferenceDate.isFinite
        else { throw ModuleStateStoreError.invalidRequest }
        self.statisticID = statisticID
        self.codexID = codexID
        self.opaqueTokenDigest = opaqueTokenDigest
        self.firstObservedAt = firstObservedAt
    }
}

public struct RuntimeProgressionAchievementFact: Codable, Equatable, Hashable, Sendable {
    public let achievementID: AchievementID
    public let current: UInt64
    public let target: UInt64
    public let completedAt: Date?

    public init(
        achievementID: AchievementID,
        current: UInt64,
        target: UInt64,
        completedAt: Date?
    ) {
        self.achievementID = achievementID
        self.current = current
        self.target = target
        self.completedAt = completedAt
    }
}

public struct RuntimeProgressionMilestoneFact: Codable, Equatable, Hashable, Sendable {
    public let ruleID: RuleID
    public let completedAt: Date

    public init(ruleID: RuleID, completedAt: Date) {
        self.ruleID = ruleID
        self.completedAt = completedAt
    }
}

public struct RuntimeProgressionGrantFact: Codable, Equatable, Hashable, Sendable {
    public let grantID: GrantTransactionID
    public let contentID: String
    public let firstGrantedAt: Date
    public let provenanceMaterial: String?

    public init(
        grantID: GrantTransactionID,
        contentID: String,
        firstGrantedAt: Date,
        provenanceMaterial: String?
    ) {
        self.grantID = grantID
        self.contentID = contentID
        self.firstGrantedAt = firstGrantedAt
        self.provenanceMaterial = provenanceMaterial
    }
}

public struct RuntimeProgressionEncounterFact: Codable, Equatable, Hashable, Sendable {
    public let codexID: CodexID
    public let artifactIDs: [ArtifactID]
    public let firstEncounteredAt: Date
    public let lastEncounteredAt: Date
    public let encounterCount: UInt64

    public init(
        codexID: CodexID,
        artifactIDs: [ArtifactID],
        firstEncounteredAt: Date,
        lastEncounteredAt: Date,
        encounterCount: UInt64
    ) {
        self.codexID = codexID
        self.artifactIDs = artifactIDs.sorted()
        self.firstEncounteredAt = firstEncounteredAt
        self.lastEncounteredAt = lastEncounteredAt
        self.encounterCount = encounterCount
    }
}

/// Durable Progression facts exported by Progression itself. Runtime maps this
/// neutral value to Cloud records; Cloud types never enter Progression.
public struct RuntimeProgressionExternalProjection: Codable, Equatable, Sendable {
    public let catalogVersion: UInt64
    public let localRevision: UInt64
    public let initializedAt: Date
    public let counters: [RuntimeProgressionCounterFact]
    public let distinctTokens: [RuntimeProgressionDistinctTokenFact]
    public let achievements: [RuntimeProgressionAchievementFact]
    public let milestones: [RuntimeProgressionMilestoneFact]
    public let grants: [RuntimeProgressionGrantFact]
    public let ownedContentIDs: [String]
    public let unlockIDs: [UnlockID]
    public let titleIDs: [TitleID]
    public let encounters: [RuntimeProgressionEncounterFact]
    public let selectedTitleID: TitleID?
    public let selectedTitleUpdatedAt: Date?
    public let knownStatisticIDs: [StatisticID]
    public let knownAchievementIDs: [AchievementID]
    public let knownMilestoneRuleIDs: [RuleID]
    public let knownContentIDs: [String]
    public let knownArtifactIDs: [ArtifactID]
    public let knownUnlockIDs: [UnlockID]
    public let knownTitleIDs: [TitleID]
    public let statisticSchemas: [RuntimeProgressionStatisticSchema]
    public let knownCodexIDs: [CodexID]

    public init(
        catalogVersion: UInt64,
        localRevision: UInt64,
        initializedAt: Date,
        counters: [RuntimeProgressionCounterFact],
        distinctTokens: [RuntimeProgressionDistinctTokenFact] = [],
        achievements: [RuntimeProgressionAchievementFact],
        milestones: [RuntimeProgressionMilestoneFact],
        grants: [RuntimeProgressionGrantFact],
        ownedContentIDs: [String],
        unlockIDs: [UnlockID],
        titleIDs: [TitleID],
        encounters: [RuntimeProgressionEncounterFact],
        selectedTitleID: TitleID?,
        selectedTitleUpdatedAt: Date? = nil,
        knownStatisticIDs: [StatisticID] = [],
        knownAchievementIDs: [AchievementID] = [],
        knownMilestoneRuleIDs: [RuleID] = [],
        knownContentIDs: [String] = [],
        knownArtifactIDs: [ArtifactID] = [],
        knownUnlockIDs: [UnlockID] = [],
        knownTitleIDs: [TitleID] = [],
        statisticSchemas: [RuntimeProgressionStatisticSchema] = [],
        knownCodexIDs: [CodexID] = []
    ) {
        self.catalogVersion = catalogVersion
        self.localRevision = localRevision
        self.initializedAt = initializedAt
        self.counters = counters
        self.distinctTokens = distinctTokens.sorted {
            ($0.statisticID.rawValue, $0.codexID?.rawValue ?? "", $0.opaqueTokenDigest)
                < ($1.statisticID.rawValue, $1.codexID?.rawValue ?? "", $1.opaqueTokenDigest)
        }
        self.achievements = achievements
        self.milestones = milestones
        self.grants = grants
        self.ownedContentIDs = ownedContentIDs.sorted()
        self.unlockIDs = unlockIDs.sorted()
        self.titleIDs = titleIDs.sorted()
        self.encounters = encounters.sorted { $0.codexID < $1.codexID }
        self.selectedTitleID = selectedTitleID
        self.selectedTitleUpdatedAt = selectedTitleUpdatedAt
        self.knownStatisticIDs = knownStatisticIDs.sorted()
        self.knownAchievementIDs = knownAchievementIDs.sorted()
        self.knownMilestoneRuleIDs = knownMilestoneRuleIDs.sorted()
        self.knownContentIDs = knownContentIDs.sorted()
        self.knownArtifactIDs = knownArtifactIDs.sorted()
        self.knownUnlockIDs = knownUnlockIDs.sorted()
        self.knownTitleIDs = knownTitleIDs.sorted()
        self.statisticSchemas = statisticSchemas.sorted {
            $0.statisticID < $1.statisticID
        }
        self.knownCodexIDs = knownCodexIDs.sorted()
    }
}

public struct RuntimeProgressionExternalMergeDelivery: Equatable, Sendable {
    public let deliveryID: UUID
    public let sourceLocalRevision: UInt64
    public let projection: RuntimeProgressionExternalProjection
    public let operationMetadata: RuntimeOperationMetadata

    init(
        deliveryID: UUID,
        sourceLocalRevision: UInt64,
        projection: RuntimeProgressionExternalProjection,
        operationMetadata: RuntimeOperationMetadata
    ) {
        self.deliveryID = deliveryID
        self.sourceLocalRevision = sourceLocalRevision
        self.projection = projection
        self.operationMetadata = operationMetadata
    }
}

public struct RuntimeProgressionExternalSyncClient: Sendable {
    private let submitOperation: @Sendable (
        ProgressionSnapshotDTO,
        RuntimeProgressionExternalProjection
    ) async throws -> RuntimeProgressionExternalMergeDelivery?
    private let deliveriesOperation: @Sendable () async throws
        -> AsyncStream<RuntimeProgressionExternalMergeDelivery>
    private let acknowledgeOperation: @Sendable (
        UUID,
        ProgressionSnapshotDTO,
        RuntimeProgressionExternalProjection
    ) async throws -> Void

    init(coordinator: RuntimeCloudGameCenterCoordinator, lease: ModuleContextLease) {
        submitOperation = { snapshot, projection in
            try await lease.requireActive()
            let delivery = try await coordinator.submitProgressionSnapshot(
                snapshot,
                projection: projection
            )
            try await lease.requireActive()
            return delivery
        }
        deliveriesOperation = {
            try await lease.requireActive()
            let source = try await coordinator.progressionMergeDeliveries()
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
                let task = Task {
                    for await delivery in source {
                        do {
                            try await lease.requireActive()
                            continuation.yield(delivery)
                        } catch {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
        acknowledgeOperation = { deliveryID, snapshot, projection in
            try await lease.requireActive()
            try await coordinator.acknowledgeProgressionMerge(
                deliveryID: deliveryID,
                snapshot: snapshot,
                projection: projection
            )
            try await lease.requireActive()
        }
    }

    init(
        submit: @escaping @Sendable (
            ProgressionSnapshotDTO,
            RuntimeProgressionExternalProjection
        ) async throws -> RuntimeProgressionExternalMergeDelivery?,
        deliveries: @escaping @Sendable () async throws
            -> AsyncStream<RuntimeProgressionExternalMergeDelivery>,
        acknowledge: @escaping @Sendable (
            UUID,
            ProgressionSnapshotDTO,
            RuntimeProgressionExternalProjection
        ) async throws -> Void
    ) {
        submitOperation = submit
        deliveriesOperation = deliveries
        acknowledgeOperation = acknowledge
    }

    public func submit(
        _ snapshot: ProgressionSnapshotDTO,
        projection: RuntimeProgressionExternalProjection
    ) async throws -> RuntimeProgressionExternalMergeDelivery? {
        try await submitOperation(snapshot, projection)
    }

    public func mergeDeliveries() async throws
        -> AsyncStream<RuntimeProgressionExternalMergeDelivery>
    {
        try await deliveriesOperation()
    }

    public func acknowledge(
        deliveryID: UUID,
        updatedSnapshot: ProgressionSnapshotDTO,
        updatedProjection: RuntimeProgressionExternalProjection
    ) async throws {
        try await acknowledgeOperation(deliveryID, updatedSnapshot, updatedProjection)
    }
}

enum RuntimeProgressionExternalProjectionMapper {
    static func projection(
        from snapshot: ProgressionSnapshotDTO,
        authoritative: RuntimeProgressionExternalProjection,
        deviceID: CloudOpaqueIdentifier?,
        baseReplica: CloudProgressionReplica? = nil,
        pendingGameCenterReports: [CloudPendingGameCenterReport] = [],
        selectedCodex: CloudCodexSelection? = nil,
        selectedTitle: CloudTitleSelection? = nil
    ) throws -> RuntimeCloudProgressionProjection {
        guard snapshot.availability == .available,
              let catalogVersion = snapshot.catalogVersion,
              catalogVersion.rawValue == authoritative.catalogVersion,
              snapshot.codexGates.contains(where: { $0.unlockedAt != nil })
        else { throw ModuleStateStoreError.unavailable }

        let localRevision = try logicalClock(after: authoritative.localRevision)
        let unlockedGates = snapshot.codexGates.filter { $0.unlockedAt != nil }
        let availableCodexIDs = Set(unlockedGates.map(\.codexID))
        let baseCodexID = CodexID(rawValue: "codex.norse")!
        let fallbackCodexID = availableCodexIDs.contains(baseCodexID)
            ? baseCodexID
            : unlockedGates.min {
            ($0.journeyOrder, $0.codexID.rawValue)
                < ($1.journeyOrder, $1.codexID.rawValue)
        }!.codexID
        let availableTitleIDs = Set(authoritative.titleIDs)
        let timestamp = snapshot.capturedAt

        let localReplica = try CloudProgressionReplica(
            catalogVersion: catalogVersion.rawValue,
            logicalClock: localRevision,
            achievementCompletions: try authoritative.achievements.compactMap { value in
                guard let completedAt = value.completedAt else { return nil }
                return try CloudAchievementCompletion(
                    achievementID: value.achievementID,
                    firstCompletedAt: completedAt
                )
            },
            milestoneCompletions: try authoritative.milestones.map {
                try CloudMilestoneCompletion(ruleID: $0.ruleID, firstCompletedAt: $0.completedAt)
            },
            grants: try authoritative.grants.compactMap { value in
                guard let contentID = CloudProgressionContentID(rawValue: value.contentID)
                else { return nil }
                return try CloudGrant(
                    grantID: value.grantID,
                    contentID: contentID,
                    firstGrantedAt: value.firstGrantedAt,
                    provenanceReference: value.provenanceMaterial.map(opaqueIdentifier)
                )
            },
            ownedContentIDs: authoritative.ownedContentIDs.compactMap(
                CloudProgressionContentID.init(rawValue:)
            ),
            unlockIDs: authoritative.unlockIDs,
            titleIDs: authoritative.titleIDs,
            encounters: try authoritative.encounters.map { value in
                try CloudEncounter(
                    encounterID: opaqueIdentifier("encounter|\(value.codexID.rawValue)"),
                    codexID: value.codexID,
                    artifactIDs: value.artifactIDs,
                    firstEncounteredAt: value.firstEncounteredAt,
                    lastEncounteredAt: value.lastEncounteredAt,
                    encounterCount: value.encounterCount
                )
            },
            deviceCounterShards: try deviceID.map { deviceID in
                let schemaByID = Dictionary(
                    uniqueKeysWithValues: authoritative.statisticSchemas.map {
                        ($0.statisticID, $0)
                    }
                )
                return try authoritative.counters.compactMap { value in
                    if let schema = schemaByID[value.statisticID],
                       schema.transport != .deviceCounter
                    {
                        return nil
                    }
                    return try CloudDeviceCounterShard(
                        statisticID: value.statisticID,
                        codexID: value.codexID,
                        deviceID: deviceID,
                        value: value.value,
                        lastUpdatedAt: timestamp
                    )
                }
            } ?? [],
            distinctStatisticTokens: try authoritative.distinctTokens.map { value in
                try CloudDistinctStatisticToken(
                    statisticID: value.statisticID,
                    codexID: value.codexID,
                    token: CloudOpaqueIdentifier(rawValue: value.opaqueTokenDigest)!,
                    firstObservedAt: value.firstObservedAt
                )
            },
            achievementProgress: try authoritative.achievements.map { value in
                try CloudAchievementProgress(
                    achievementID: value.achievementID,
                    current: value.current,
                    target: value.target,
                    lastUpdatedAt: value.completedAt ?? timestamp
                )
            },
            selectedCodex: selectedCodex,
            selectedTitle: selectedTitle,
            pendingGameCenterReports: pendingGameCenterReports
        )

        let replica: CloudProgressionReplica
        if let baseReplica {
            let context = try CloudProgressionMergeContext(
                localAccountScope: nil,
                remoteAccountScope: nil,
                serviceAvailability: .available,
                availableCodexIDs: availableCodexIDs,
                fallbackCodexID: fallbackCodexID,
                availableTitleIDs: availableTitleIDs,
                knownStatisticIDs: Set(authoritative.knownStatisticIDs),
                knownAchievementIDs: Set(authoritative.knownAchievementIDs),
                knownMilestoneRuleIDs: Set(authoritative.knownMilestoneRuleIDs),
                knownContentIDs: Set(authoritative.knownContentIDs),
                knownArtifactIDs: Set(authoritative.knownArtifactIDs),
                knownUnlockIDs: Set(authoritative.knownUnlockIDs),
                achievementTargets: Dictionary(
                    uniqueKeysWithValues: authoritative.achievements.map {
                        ($0.achievementID, $0.target)
                    }
                ),
                validatesCatalogMembership: true,
                statisticSchemas: cloudStatisticSchemas(authoritative.statisticSchemas),
                knownCodexIDs: Set(authoritative.knownCodexIDs),
                knownTitleIDs: Set(authoritative.knownTitleIDs),
                now: timestamp
            )
            replica = try CloudProgressionMergeEngine.mergeValidated(
                local: baseReplica,
                remote: localReplica,
                context: context
            )
        } else {
            replica = localReplica
        }

        return try RuntimeCloudProgressionProjection(
            replica: replica,
            localRevision: localRevision,
            availableCodexIDs: availableCodexIDs,
            fallbackCodexID: fallbackCodexID,
            availableTitleIDs: availableTitleIDs,
            knownStatisticIDs: Set(authoritative.knownStatisticIDs),
            knownAchievementIDs: Set(authoritative.knownAchievementIDs),
            knownMilestoneRuleIDs: Set(authoritative.knownMilestoneRuleIDs),
            knownContentIDs: Set(authoritative.knownContentIDs),
            knownArtifactIDs: Set(authoritative.knownArtifactIDs),
            knownUnlockIDs: Set(authoritative.knownUnlockIDs),
            achievementTargets: Dictionary(
                uniqueKeysWithValues: authoritative.achievements.map {
                    ($0.achievementID, $0.target)
                }
            ),
            knownCodexIDs: Set(authoritative.knownCodexIDs),
            knownTitleIDs: Set(authoritative.knownTitleIDs),
            statisticSchemas: cloudStatisticSchemas(authoritative.statisticSchemas)
        )
    }

    static func externalProjection(
        from replica: CloudProgressionReplica,
        localRevision: UInt64,
        initializedAt: Date
    ) throws -> RuntimeProgressionExternalProjection {
        var counters: [String: RuntimeProgressionCounterFact] = [:]
        for shard in replica.deviceCounterShards {
            let key = "\(shard.statisticID.rawValue)|\(shard.codexID?.rawValue ?? "")"
            let existing = counters[key]?.value ?? 0
            let (sum, overflow) = existing.addingReportingOverflow(shard.value)
            guard !overflow else { throw CloudProgressionSchemaError.invalidCounter }
            counters[key] = RuntimeProgressionCounterFact(
                statisticID: shard.statisticID,
                codexID: shard.codexID,
                value: sum
            )
        }
        let completionByID = Dictionary(
            uniqueKeysWithValues: replica.achievementCompletions.map {
                ($0.achievementID, $0.firstCompletedAt)
            }
        )
        let achievements = replica.achievementProgress.map {
            RuntimeProgressionAchievementFact(
                achievementID: $0.achievementID,
                current: $0.current,
                target: $0.target,
                completedAt: completionByID[$0.achievementID]
            )
        }
        return RuntimeProgressionExternalProjection(
            catalogVersion: replica.catalogVersion,
            localRevision: localRevision,
            initializedAt: initializedAt,
            counters: Array(counters.values),
            distinctTokens: try replica.distinctStatisticTokens.map {
                try RuntimeProgressionDistinctTokenFact(
                    statisticID: $0.statisticID,
                    codexID: $0.codexID,
                    opaqueTokenDigest: $0.token.rawValue,
                    firstObservedAt: $0.firstObservedAt
                )
            },
            achievements: achievements,
            milestones: replica.milestoneCompletions.map {
                RuntimeProgressionMilestoneFact(
                    ruleID: $0.ruleID,
                    completedAt: $0.firstCompletedAt
                )
            },
            grants: replica.grants.map {
                RuntimeProgressionGrantFact(
                    grantID: $0.grantID,
                    contentID: $0.contentID.rawValue,
                    firstGrantedAt: $0.firstGrantedAt,
                    provenanceMaterial: $0.provenanceReference?.rawValue
                )
            },
            ownedContentIDs: replica.ownedContentIDs.map(\.rawValue),
            unlockIDs: replica.unlockIDs,
            titleIDs: replica.titleIDs,
            encounters: replica.encounters.map {
                RuntimeProgressionEncounterFact(
                    codexID: $0.codexID,
                    artifactIDs: $0.artifactIDs,
                    firstEncounteredAt: $0.firstEncounteredAt,
                    lastEncounteredAt: $0.lastEncounteredAt,
                    encounterCount: $0.encounterCount
                )
            },
            selectedTitleID: replica.selectedTitle?.titleID,
            selectedTitleUpdatedAt: replica.selectedTitle?.updatedAt
        )
    }

    static func sanitizedBaseReplica(
        _ replica: CloudProgressionReplica,
        authoritative: RuntimeProgressionExternalProjection
    ) throws -> CloudProgressionReplica {
        var corroboratedGrantDateByKey: [String: Date] = [:]
        for grant in authoritative.grants {
            guard let provenance = grant.provenanceMaterial else { continue }
            let key = "\(grant.contentID)|\(opaqueIdentifier(provenance).rawValue)"
            corroboratedGrantDateByKey[key] = min(
                corroboratedGrantDateByKey[key] ?? grant.firstGrantedAt,
                grant.firstGrantedAt
            )
        }
        let grants = try replica.grants.compactMap { grant -> CloudGrant? in
            guard let provenance = grant.provenanceReference else { return nil }
            let key = "\(grant.contentID.rawValue)|\(provenance.rawValue)"
            guard let corroboratedDate = corroboratedGrantDateByKey[key],
                  authoritative.ownedContentIDs.contains(grant.contentID.rawValue)
            else { return nil }
            return try CloudGrant(
                grantID: grant.grantID,
                contentID: grant.contentID,
                firstGrantedAt: min(grant.firstGrantedAt, corroboratedDate),
                provenanceReference: provenance
            )
        }
        let authoritativeAchievementByID = Dictionary(
            uniqueKeysWithValues: authoritative.achievements.map {
                ($0.achievementID, $0)
            }
        )
        let achievementProgress = replica.achievementProgress.filter { value in
            guard let fact = authoritativeAchievementByID[value.achievementID]
            else { return false }
            return value.target == fact.target && value.current <= fact.current
        }
        return try CloudProgressionReplica(
            catalogVersion: replica.catalogVersion,
            logicalClock: replica.logicalClock,
            grants: grants,
            deviceCounterShards: replica.deviceCounterShards,
            achievementProgress: achievementProgress,
            quarantineDiagnostics: replica.quarantineDiagnostics
        )
    }

    static func opaqueIdentifier(_ material: String) -> CloudOpaqueIdentifier {
        CloudOpaqueIdentifier(
            rawValue: RuntimeIntegrityDigest.sha256Hex(Data(material.utf8))
        )!
    }

    private static func cloudStatisticSchemas(
        _ schemas: [RuntimeProgressionStatisticSchema]
    ) -> [StatisticID: CloudStatisticMergeSchema] {
        Dictionary(uniqueKeysWithValues: schemas.map { schema in
            let representation: CloudStatisticMergeRepresentation
            switch schema.transport {
            case .deviceCounter: representation = .deviceCounter
            case .distinctToken: representation = .distinctToken
            case .derivedOmitted: representation = .derivedOmitted
            }
            return (
                schema.statisticID,
                CloudStatisticMergeSchema(
                    representation: representation,
                    requiresCodexBucket: schema.requiresCodexBucket
                )
            )
        })
    }

    private static func logicalClock(after revision: UInt64) throws -> UInt64 {
        let (value, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { throw CloudProgressionSchemaError.invalidLogicalClock }
        return value
    }
}
