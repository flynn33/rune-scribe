import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ProgressionRepositoryIDs {
    static let recordDecodeCode = ProgressionRejectionCode(
        rawValue: "progression.record-decode"
    )!
    static let recordReferenceCode = ProgressionRejectionCode(
        rawValue: "progression.record-reference"
    )!
    static let metadataCollection = ModuleStateCollectionID(rawValue: "progression-metadata")!
    static let projectionCollection = ModuleStateCollectionID(rawValue: "progression-projection")!
    static let distinctCollection = ModuleStateCollectionID(rawValue: "progression-distinct")!
    static let revealQueueCollection = ModuleStateCollectionID(rawValue: "progression-reveal-queue")!
    static let existingUserMigrationSeedCollection = ModuleStateCollectionID(
        rawValue: "progression-existing-user-migration-seeds"
    )!
    static let quarantineCollection = ModuleStateCollectionID(rawValue: "progression-quarantine")!
    static let activeMetadataRecord = ModuleStateRecordID(rawValue: "active")!
    static let rebuildStageMarkerRecord = ModuleStateRecordID(rawValue: "rebuild-stage")!
    static let existingUserMigrationStageMarkerRecord = ModuleStateRecordID(
        rawValue: "existing-user-migration-stage"
    )!

    static func eventCollection(_ generation: String) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: "progression-events.\(generation)")!
    }

    static func eventOrderCollection(_ generation: String) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: "progression-event-order.\(generation)")!
    }

    static func semanticCollection(_ generation: String) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: "progression-semantic.\(generation)")!
    }

    static func recoveryEventCollection(_ generation: String) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: "progression-recovery-events.\(generation)")!
    }

    static func revealAcknowledgementCollection(
        _ generation: String
    ) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: "progression-reveal-ack.\(generation)")!
    }

    static func commandCollection(_ generation: String) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: "progression-commands.\(generation)")!
    }

    static func eventRecordID(_ eventID: EventID) -> ModuleStateRecordID {
        ModuleStateRecordID(rawValue: "event.\(eventID.rawValue.uuidString.lowercased())")!
    }

    static func semanticRecordID(_ digest: String) -> ModuleStateRecordID {
        ModuleStateRecordID(rawValue: "semantic.\(digest)")!
    }

    static func distinctTokenRecordID(_ record: DistinctTokenRecord) -> ModuleStateRecordID {
        let identity = "\(record.statisticID.rawValue)|\(record.bucketID?.rawValue ?? "-")|\(record.tokenDigest)"
        let identityDigest = ProgressionDeterminism.digest128(identity)
        return ModuleStateRecordID(
            rawValue: "distinct.\(record.generation).\(identityDigest)"
        )!
    }

    static func eventOrderRecordID(_ revision: UInt64) -> ModuleStateRecordID {
        let digits = String(revision)
        let padded = String(repeating: "0", count: 20 - digits.count) + digits
        return ModuleStateRecordID(rawValue: "order.\(padded)")!
    }

    static func recoveryEventRecordID(_ revision: UInt64) -> ModuleStateRecordID {
        let digits = String(revision)
        let padded = String(repeating: "0", count: 20 - digits.count) + digits
        return ModuleStateRecordID(rawValue: "candidate.\(padded)")!
    }

    static func queuedRevealRecordID(_ reveal: PendingRevealRecord) -> ModuleStateRecordID {
        queuedRevealRecordID(reveal.revealID, generation: reveal.generation)
    }

    static func existingUserMigrationSeedRecordID(
        _ record: ExistingUserMigrationSeedRecord
    ) -> ModuleStateRecordID {
        ModuleStateRecordID(
            rawValue: "migration-seed.\(record.generation).\(ProgressionDeterminism.digest128(record.cipherToken.rawValue))"
        )!
    }

    static func queuedRevealRecordID(
        _ revealID: RevealID,
        generation: String
    ) -> ModuleStateRecordID {
        let revealDigest = ProgressionDeterminism.digest128(revealID.rawValue)
        return ModuleStateRecordID(
            rawValue: "reveal.\(generation).\(revealDigest)"
        )!
    }

    static func acknowledgedRevealRecordID(_ revealID: RevealID) -> ModuleStateRecordID {
        ModuleStateRecordID(
            rawValue: "ack.\(ProgressionDeterminism.digest128(revealID.rawValue))"
        )!
    }

    static func commandRecordID(_ transactionID: UUID) -> ModuleStateRecordID {
        ModuleStateRecordID(
            rawValue: "command.\(transactionID.uuidString.lowercased())"
        )!
    }

    static func quarantineRecordID(_ record: QuarantineRecord) -> ModuleStateRecordID {
        ModuleStateRecordID(
            rawValue: "quarantine.\(record.sourceRecordDigest).\(record.sourceRevision)"
        )!
    }

    static func shardRecordID(_ shard: ProgressionProjectionShard) -> ModuleStateRecordID {
        shardRecordID(
            generation: shard.generation,
            category: shard.category,
            shardIndex: shard.shardIndex
        )
    }

    static func shardRecordID(
        generation: String,
        category: ProgressionDiagnosticRecordCategory,
        shardIndex: UInt16
    ) -> ModuleStateRecordID {
        ModuleStateRecordID(
            rawValue: "shard.\(generation).\(category.rawValue).\(shardIndex)"
        )!
    }
}

private func distinctIdentity(_ record: DistinctTokenRecord) -> String {
    "\(record.generation)|\(record.statisticID.rawValue)|\(record.bucketID?.rawValue ?? "-")|\(record.tokenDigest)"
}

private func commandReceiptRequiresCleanup(_ operationIdentifier: String) -> Bool {
    operationIdentifier == "progression.recovery.rebuild" ||
        operationIdentifier == "progression.catalog.upgrade"
}

private struct ProgressionQueuedRevealReferenceError: Error {
    let label: String
}

private struct ProgressionAcknowledgedRevealReferenceError: Error {
    let label: String
}

private struct ProgressionCanonicalRevealCandidate {
    let contentID: ProgressionContentID
    let grantGroupID: GrantGroupID
    let tier: ProgressionDurableRevealTier
    let isPrimary: Bool
    var sources: Set<ProgressionGrantSource>
}

private enum ProgressionRecoveryCandidateSource: String, Sendable {
    case order
    case processed
}

private struct ProgressionRecoveryCandidatePath: Sendable {
    var cumulativeDigest: String?
    var choices: [UInt64: ProgressionRecoveryCandidateSource]
}

struct ProgressionPhysicalRecord: Equatable, Sendable {
    let key: ModuleStateRecordKey
    let revision: UInt64
    let updatedAt: Date
    let integrityDigest: Data
}

struct ProgressionProjection: Equatable, Sendable {
    var metadata: ProgressionMetadataRecord
    var records: [String: ProgressionLogicalRecord]
    var physicalMetadata: ProgressionPhysicalRecord?
    var physicalShards: [String: ProgressionPhysicalRecord]
    var bootstrapRuntimeTimestamp: Date?

    init(
        metadata: ProgressionMetadataRecord,
        records: [ProgressionLogicalRecord],
        physicalMetadata: ProgressionPhysicalRecord? = nil,
        physicalShards: [String: ProgressionPhysicalRecord] = [:],
        bootstrapRuntimeTimestamp: Date? = nil
    ) throws {
        try metadata.validate()
        var indexed: [String: ProgressionLogicalRecord] = [:]
        for record in records {
            try record.validate()
            guard record.generation == metadata.activeGeneration else {
                throw ProgressionDomainError.invalidRecord("inactive-projection-record")
            }
            if let existing = indexed[record.identity] {
                guard existing == record else {
                    throw ProgressionDomainError.recordIdentityCollision(record.identity)
                }
                throw ProgressionDomainError.invalidRecord("duplicate-logical-record")
            }
            indexed[record.identity] = record
        }
        self.metadata = metadata
        self.records = indexed
        self.physicalMetadata = physicalMetadata
        self.physicalShards = physicalShards
        self.bootstrapRuntimeTimestamp = bootstrapRuntimeTimestamp
    }

    mutating func upsert(_ record: ProgressionLogicalRecord) throws {
        try record.validate()
        guard record.generation == metadata.activeGeneration else {
            throw ProgressionDomainError.invalidRecord("projection-generation")
        }
        records[record.identity] = record
    }

    mutating func remove(identity: String) {
        records.removeValue(forKey: identity)
    }

    func logicalRecords() -> [ProgressionLogicalRecord] {
        records.values.sorted { $0.identity < $1.identity }
    }

    func shards() throws -> [String: ProgressionProjectionShard] {
        let groups = Dictionary(grouping: logicalRecords()) { record in
            ProgressionProjectionLayout.shardIdentity(
                generation: metadata.activeGeneration,
                category: record.category,
                shardIndex: ProgressionProjectionLayout.shardIndex(for: record)
            )
        }
        var result: [String: ProgressionProjectionShard] = [:]
        for category in ProgressionProjectionLayout.projectedCategories {
            for shardIndex in 0 ..< ProgressionProjectionLayout.shardCount(for: category) {
                let identity = ProgressionProjectionLayout.shardIdentity(
                    generation: metadata.activeGeneration,
                    category: category,
                    shardIndex: shardIndex
                )
                let shard = ProgressionProjectionShard(
                    generation: metadata.activeGeneration,
                    category: category,
                    shardIndex: shardIndex,
                    records: groups[identity] ?? []
                )
                try shard.validate()
                result[identity] = shard
            }
        }
        return result
    }

    func records<T>(matching transform: (ProgressionLogicalRecord) -> T?) -> [T] {
        logicalRecords().compactMap(transform)
    }
}

struct ProgressionLocatedRecord<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let physical: ProgressionPhysicalRecord
}

struct ProgressionRepositoryState: Equatable, Sendable {
    var projection: ProgressionProjection
    var nextPendingReveal: ProgressionLocatedRecord<PendingRevealRecord>?
    var inactiveShards: [String: ProgressionLocatedRecord<ProgressionProjectionShard>]
    var health: ModuleStateHealthSnapshot
}

struct ProgressionRecoveryAnchor: Equatable, Sendable {
    let metadata: ProgressionMetadataRecord
    let physicalMetadata: ProgressionPhysicalRecord
    let health: ModuleStateHealthSnapshot
    let quarantinedProjectionRecordCount: UInt64
    let recoverableDirectQuarantineCount: UInt64
    let directRecoveryPermitted: Bool
    let recoveredCatalogMigration: CatalogMigrationRecord?
    let recoveredExistingUserMigration: ExistingUserMigrationRecord?
    let recoveredRevealQueueState: ProgressionRevealQueueStateRecord?
    let recoveredRevealValidationRecords: [ProgressionLogicalRecord]
}

struct ProgressionCommitAdditions: Sendable {
    var processedEvent: ProcessedEventRecord?
    var appliedEventOrder: ProgressionAppliedEventOrderRecord?
    var semanticRecord: ProgressionSemanticDedupeRecord?
    var distinctTokenUpserts: [DistinctTokenRecord]
    var pendingRevealUpserts: [PendingRevealRecord]
    var acknowledgedRevealUpsert: PendingRevealRecord?
    var queuedRevealDeletes: [ProgressionLocatedRecord<PendingRevealRecord>]
    var commandReceipt: ProgressionCommandReceiptRecord?

    init(
        processedEvent: ProcessedEventRecord? = nil,
        appliedEventOrder: ProgressionAppliedEventOrderRecord? = nil,
        semanticRecord: ProgressionSemanticDedupeRecord? = nil,
        distinctTokenUpserts: [DistinctTokenRecord] = [],
        pendingRevealUpserts: [PendingRevealRecord] = [],
        acknowledgedRevealUpsert: PendingRevealRecord? = nil,
        queuedRevealDeletes: [ProgressionLocatedRecord<PendingRevealRecord>] = [],
        commandReceipt: ProgressionCommandReceiptRecord? = nil
    ) {
        self.processedEvent = processedEvent
        self.appliedEventOrder = appliedEventOrder
        self.semanticRecord = semanticRecord
        self.distinctTokenUpserts = distinctTokenUpserts
        self.pendingRevealUpserts = pendingRevealUpserts
        self.acknowledgedRevealUpsert = acknowledgedRevealUpsert
        self.queuedRevealDeletes = queuedRevealDeletes
        self.commandReceipt = commandReceipt
    }
}

struct ProgressionGenerationCopySummary: Equatable, Sendable {
    let processedEventCount: UInt64
    let terminalProcessedEventDigest: String?
    let acknowledgedRevealCount: UInt64
    let acknowledgedRevealDigest: String?
    let commandReceiptCount: UInt64
    let commandReceiptDigest: String?
}

struct ProgressionQuarantineDiagnostics: Equatable, Sendable {
    let recordDecodeCount: UInt64
    let recordReferenceCount: UInt64
    let integrityCount: UInt64
}

private struct ProgressionProjectionIntegrityIssue: Error {
    let categories: Set<ProgressionDiagnosticRecordCategory>
    let label: String
}

private struct ProgressionProcessedRecoveryAudit {
    var appliedCount: UInt64 = 0
    var terminalCount: UInt64 = 0
    var terminalDigest: String?
}

private struct ProgressionDigestCountAudit {
    var count: UInt64 = 0
    var digest: String?
}

private struct ProgressionDirectRecoveryAudit {
    let processed: ProgressionProcessedRecoveryAudit
    let orderCount: UInt64
    let semanticCount: UInt64
    let distinctCount: UInt64
    let acknowledgementCount: UInt64
    let acknowledgementDigest: String?
    let commandCount: UInt64
    let commandDigest: String?
}

private struct ProgressionPlannedStageMutation {
    let mutation: ModuleStateMutation
    let alreadyPresent: Bool
}

struct ProgressionRepository: Sendable {
    static let namespaceSchemaVersion: UInt32 = 1

    let client: any ProgressionStateClient

    func loadOrInitialize(
        bundle: ValidatedProgressionCatalogBundle,
        initialProjection: ProgressionProjection
    ) async throws -> ProgressionRepositoryState {
        let health = try await client.prepare(schemaVersion: Self.namespaceSchemaVersion)
        guard health.accessDisposition == .readWrite else {
            throw ModuleStateStoreError.quarantined
        }

        let metadata = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        )
        if metadata == nil {
            guard health.recordCount == 0, health.quarantinedRecordCount == 0 else {
                _ = try? await client.quarantine(
                    diagnosticCode: "progression.metadata-missing-nonempty"
                )
                throw ProgressionDomainError.unsafeNonemptyInitialization
            }
            try await initialize(bundle: bundle, projection: initialProjection)
        }
        try await sealInitializationIfNeeded()
        do {
            let loaded = try await loadExisting(bundle: bundle)
            return try await resumeCatalogUpgradeCleanupIfNeeded(loaded, bundle: bundle)
        } catch ProgressionDomainError.catalogMismatch {
            let stored = try await loadRawExisting()
            guard stored.projection.metadata.catalogID == bundle.catalog.catalogID,
                  stored.projection.metadata.catalogVersion < bundle.catalog.catalogVersion
            else { throw ProgressionDomainError.catalogMismatch }
            do {
                try validateStoredProjectionForUpgrade(
                    stored.projection,
                    bundle: bundle
                )
            } catch {
                try await quarantineActiveProjection(stored.projection, error: error)
                throw error
            }
            if stored.health.quarantinedRecordCount ==
                stored.projection.metadata.knownInactiveQuarantineCount
            {
                do {
                    try await validateProjectionLedgerProvenance(
                        stored.projection,
                        bundle: bundle
                    )
                } catch {
                    try await quarantineActiveProjection(stored.projection, error: error)
                    throw error
                }
                try await validateActiveAppliedLedger(stored.projection, bundle: bundle)
            }
            if stored.health.quarantinedRecordCount !=
                stored.projection.metadata.knownInactiveQuarantineCount
            {
                let anchor = try await recoveryAnchor(bundle: bundle)
                let (expectedQuarantineCount, overflow) = anchor.metadata
                    .knownInactiveQuarantineCount.addingReportingOverflow(
                        anchor.recoverableDirectQuarantineCount
                    )
                guard !overflow,
                      anchor.quarantinedProjectionRecordCount == 0,
                      anchor.directRecoveryPermitted,
                      anchor.health.quarantinedRecordCount == expectedQuarantineCount
                else { throw ProgressionDomainError.catalogMismatch }
            }
            return try await ProgressionCatalogUpgradeCoordinator.upgrade(
                bundle: bundle,
                repository: self,
                storedState: stored
            )
        }
    }

    func loadExisting(
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionRepositoryState {
        var rawState = try await loadRawExisting()
        let projection = rawState.projection
        guard projection.metadata.catalogID == bundle.catalog.catalogID,
              projection.metadata.catalogVersion == bundle.catalog.catalogVersion
        else { throw ProgressionDomainError.catalogMismatch }
        do {
            try validateProjection(projection, bundle: bundle)
            try await validateProjectionLedgerProvenance(
                projection,
                bundle: bundle
            )
        } catch {
            try await quarantineActiveProjection(
                projection,
                error: error
            )
            throw error
        }
        let queueState = try revealQueueState(in: projection)
        do {
            rawState.nextPendingReveal = try await validateActiveRevealQueue(
                queueState,
                generation: projection.metadata.activeGeneration,
                validationRecords: projection.records,
                bundle: bundle
            ).first
        } catch is ProgressionQueuedRevealReferenceError {
            throw ProgressionDomainError.invalidRecord("reveal-queue-record-reference")
        } catch is ProgressionAcknowledgedRevealReferenceError {
            throw ProgressionDomainError.invalidRecord("reveal-queue-record-reference")
        } catch {
            if let physical = projection.physicalShards[
                ProgressionProjectionLayout.shardIdentity(
                    generation: projection.metadata.activeGeneration,
                    category: .pendingReveal,
                    shardIndex: 0
                )
            ], let stored = try? await client.fetch(
                collectionID: physical.key.collectionID,
                recordID: physical.key.recordID
            ) {
                try? await quarantineInvalid(
                    stored,
                    category: .pendingReveal,
                    code: ProgressionRepositoryIDs.recordDecodeCode
                )
            }
            throw error
        }
        rawState.health = try await client.health()
        guard rawState.health.quarantinedRecordCount ==
                projection.metadata.knownInactiveQuarantineCount
        else { throw ModuleStateStoreError.quarantined }
        return rawState
    }

    func loadRawExisting() async throws -> ProgressionRepositoryState {
        let health = try await client.health()
        guard health.accessDisposition == .readWrite else {
            throw ModuleStateStoreError.quarantined
        }
        guard let metadataPhysical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        ) else { throw ProgressionDomainError.missingMetadata }
        let metadata: ProgressionMetadataRecord = try await decodeDirectRecord(
            metadataPhysical,
            category: .metadata,
            invalidLabel: "metadata-corrupt"
        ) {
            guard metadataPhysical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: metadataPhysical.schemaVersion)
                )
            }
            let decoded = try ProgressionDeterminism.decoder().decode(
                ProgressionMetadataRecord.self,
                from: metadataPhysical.payload
            )
            try decoded.validate()
            guard metadataPhysical.key.collectionID ==
                    ProgressionRepositoryIDs.metadataCollection,
                  metadataPhysical.key.recordID == ProgressionRepositoryIDs.activeMetadataRecord
            else { throw ProgressionDomainError.invalidRecord("metadata-identity") }
            return decoded
        }

        var logicalRecords: [ProgressionLogicalRecord] = []
        var physicalShards: [String: ProgressionPhysicalRecord] = [:]
        var storedShards: [ModuleStateRecord] = []
        let bootstrapRuntimeTimestamp = metadata.initializedAt
        for category in ProgressionProjectionLayout.projectedCategories {
            for shardIndex in 0 ..< ProgressionProjectionLayout.shardCount(for: category) {
                let recordID = ProgressionRepositoryIDs.shardRecordID(
                    generation: metadata.activeGeneration,
                    category: category,
                    shardIndex: shardIndex
                )
                guard let physical = try await client.fetch(
                    collectionID: ProgressionRepositoryIDs.projectionCollection,
                    recordID: recordID
                ) else {
                    throw ProgressionDomainError.invalidRecord("active-projection-incomplete")
                }
                let shard: ProgressionProjectionShard = try await decodeDirectRecord(
                    physical,
                    category: category,
                    invalidLabel: "active-projection-corrupt"
                ) {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    let decoded = try ProgressionDeterminism.decoder().decode(
                        ProgressionProjectionShard.self,
                        from: physical.payload
                    )
                    try decoded.validate()
                    guard decoded.generation == metadata.activeGeneration,
                          decoded.category == category,
                          decoded.shardIndex == shardIndex,
                          physical.key.recordID == ProgressionRepositoryIDs.shardRecordID(decoded)
                    else { throw ProgressionDomainError.invalidRecord("projection-shard-identity") }
                    return decoded
                }
                let identity = ProgressionProjectionLayout.shardIdentity(
                    generation: shard.generation,
                    category: shard.category,
                    shardIndex: shard.shardIndex
                )
                guard physicalShards[identity] == nil else {
                    throw ProgressionDomainError.recordIdentityCollision(identity)
                }
                physicalShards[identity] = physicalRecord(physical)
                storedShards.append(physical)
                logicalRecords.append(contentsOf: shard.records)
            }
        }
        let projection: ProgressionProjection
        do {
            projection = try ProgressionProjection(
                metadata: metadata,
                records: logicalRecords,
                physicalMetadata: physicalRecord(metadataPhysical),
                physicalShards: physicalShards,
                bootstrapRuntimeTimestamp: bootstrapRuntimeTimestamp
            )
        } catch {
            for physical in storedShards {
                try? await quarantineInvalid(
                    physical,
                    category: .quarantine,
                    code: ProgressionRepositoryIDs.recordReferenceCode
                )
            }
            throw error
        }
        return ProgressionRepositoryState(
            projection: projection,
            nextPendingReveal: nil,
            inactiveShards: [:],
            health: health
        )
    }

    func recoveryAnchor(
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionRecoveryAnchor {
        let health = try await client.health()
        guard health.accessDisposition == .readWrite,
              let metadataPhysical = try await client.fetch(
                  collectionID: ProgressionRepositoryIDs.metadataCollection,
                  recordID: ProgressionRepositoryIDs.activeMetadataRecord
              )
        else { throw ModuleStateStoreError.quarantined }
        let metadata: ProgressionMetadataRecord = try await decodeDirectRecord(
            metadataPhysical,
            category: .metadata,
            invalidLabel: "recovery-metadata-corrupt"
        ) {
            guard metadataPhysical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: metadataPhysical.schemaVersion)
                )
            }
            let decoded = try ProgressionDeterminism.decoder().decode(
                ProgressionMetadataRecord.self,
                from: metadataPhysical.payload
            )
            try decoded.validate()
            return decoded
        }
        guard metadata.catalogID == bundle.catalog.catalogID,
              metadata.catalogVersion <= bundle.catalog.catalogVersion
        else { throw ProgressionDomainError.catalogMismatch }

        var recoveredCatalogMigration: CatalogMigrationRecord?
        var recoveredExistingUserMigration: ExistingUserMigrationRecord?
        do {
            let shard = try await recoveryShard(
                category: .catalogMigration,
                metadata: metadata
            )
            let migrations = shard.value.records.compactMap {
                logical -> CatalogMigrationRecord? in
                guard case let .catalogMigration(record) = logical else { return nil }
                return record
            }
            guard migrations.count == 1,
                  migrations[0].catalogVersion == metadata.catalogVersion
            else {
                throw ProgressionDomainError.invalidRecord(
                    "recovery-catalog-migration"
                )
            }
            if metadata.catalogVersion < bundle.catalog.catalogVersion {
                try ProgressionCatalogCompatibility.validateAddOnlyUpgrade(
                    from: migrations[0].compatibilityFingerprints,
                    to: ProgressionCatalogCompatibility.fingerprints(for: bundle)
                )
            }
            recoveredCatalogMigration = migrations[0]
            let existingUserMigrations = shard.value.records.compactMap {
                logical -> ExistingUserMigrationRecord? in
                guard case let .existingUserMigration(record) = logical else { return nil }
                return record
            }
            guard existingUserMigrations.count <= 1 else {
                throw ProgressionDomainError.invalidRecord(
                    "recovery-existing-user-migration"
                )
            }
            recoveredExistingUserMigration = existingUserMigrations.first
        } catch {
            guard metadata.catalogVersion == bundle.catalog.catalogVersion else {
                throw ProgressionDomainError.catalogMismatch
            }
            recoveredCatalogMigration = nil
            recoveredExistingUserMigration = nil
        }

        var quarantinedProjectionRecordCount: UInt64 = 0
        for category in ProgressionProjectionLayout.projectedCategories {
            for shardIndex in 0 ..< ProgressionProjectionLayout.shardCount(for: category) {
                let recordID = ProgressionRepositoryIDs.shardRecordID(
                    generation: metadata.activeGeneration,
                    category: category,
                    shardIndex: shardIndex
                )
                do {
                    _ = try await client.fetch(
                        collectionID: ProgressionRepositoryIDs.projectionCollection,
                        recordID: recordID
                    )
                } catch let error as ModuleStateStoreError {
                    switch error {
                    case .quarantined, .integrityMismatch, .unreadable, .corrupt:
                        let (next, overflow) = quarantinedProjectionRecordCount
                            .addingReportingOverflow(1)
                        guard !overflow else {
                            throw ProgressionDomainError.invalidRecord(
                                "recovery-quarantine-count"
                            )
                        }
                        quarantinedProjectionRecordCount = next
                    default:
                        throw error
                    }
                }
            }
        }
        let recoveredRevealQueueState: ProgressionRevealQueueStateRecord?
        let recoveredRevealValidationRecords: [ProgressionLogicalRecord]
        let recoveredQueuedRevealIDs: Set<RevealID>
        let pendingQueueRecoveryPermitted: Bool
        do {
            let shard = try await recoveryShard(category: .pendingReveal, metadata: metadata)
            let states = shard.value.records.compactMap {
                logical -> ProgressionRevealQueueStateRecord? in
                guard case let .revealQueueState(record) = logical else { return nil }
                return record
            }
            guard states.count == 1 else {
                throw ProgressionDomainError.invalidRecord("recovery-reveal-queue-state")
            }
            let queued = try await validateActiveRevealQueue(
                states[0],
                generation: metadata.activeGeneration,
                validationRecords: [:],
                bundle: bundle,
                validateReferences: false
            )
            recoveredRevealQueueState = states[0]
            recoveredRevealValidationRecords = []
            recoveredQueuedRevealIDs = Set(queued.map { $0.value.revealID })
            pendingQueueRecoveryPermitted = true
        } catch {
            recoveredRevealQueueState = nil
            recoveredRevealValidationRecords = []
            recoveredQueuedRevealIDs = []
            pendingQueueRecoveryPermitted = false
        }
        let directAudit = try await recoveryDirectIndexAudit(
            metadata: metadata,
            bundle: bundle
        )
        let refreshedHealth = try await client.health()
        let expectedTerminalCount = metadata.processedEventCount
            .subtractingReportingOverflow(metadata.appliedEventCount)
        let availableAppliedSources = directAudit.processed.appliedCount
            .addingReportingOverflow(directAudit.orderCount)
        guard !expectedTerminalCount.overflow,
              !availableAppliedSources.overflow,
              directAudit.processed.terminalCount <= expectedTerminalCount.partialValue,
              directAudit.processed.appliedCount <= metadata.appliedEventCount,
              directAudit.orderCount <= metadata.appliedEventCount,
              directAudit.acknowledgementCount <= metadata.acknowledgedRevealCount,
              directAudit.commandCount <= metadata.commandReceiptCount
        else { throw ProgressionDomainError.invalidRecord("recovery-direct-index") }

        var directDeficitCount: UInt64 = 0
        for deficit in [
            metadata.appliedEventCount - directAudit.processed.appliedCount,
            metadata.appliedEventCount - directAudit.orderCount,
            positiveDeficit(metadata.appliedEventCount, directAudit.semanticCount),
            positiveDeficit(metadata.distinctTokenCount, directAudit.distinctCount),
            expectedTerminalCount.partialValue - directAudit.processed.terminalCount,
            metadata.acknowledgedRevealCount - directAudit.acknowledgementCount,
            metadata.commandReceiptCount - directAudit.commandCount,
        ] {
            let next = directDeficitCount.addingReportingOverflow(deficit)
            guard !next.overflow else {
                throw ProgressionDomainError.invalidRecord("recovery-direct-index-count")
            }
            directDeficitCount = next.partialValue
        }
        let (knownAndProjection, baseOverflow) = metadata.knownInactiveQuarantineCount
            .addingReportingOverflow(quarantinedProjectionRecordCount)
        guard !baseOverflow,
              refreshedHealth.quarantinedRecordCount >= knownAndProjection
        else { throw ProgressionDomainError.invalidRecord("recovery-direct-index-count") }
        let unexplainedQuarantineCount = refreshedHealth.quarantinedRecordCount -
            knownAndProjection
        let loggedDerivedQuarantineCount = try await recoverableLoggedQuarantineCount(
            metadata: metadata,
            queuedRevealIDs: recoveredQueuedRevealIDs
        )
        let irreconstructibleIndexesMatch =
            directAudit.processed.terminalCount == expectedTerminalCount.partialValue &&
            directAudit.processed.terminalDigest == metadata.terminalProcessedEventDigest &&
            directAudit.acknowledgementCount == metadata.acknowledgedRevealCount &&
            directAudit.acknowledgementDigest == metadata.acknowledgedRevealDigest &&
            directAudit.commandCount == metadata.commandReceiptCount &&
            directAudit.commandDigest == metadata.commandReceiptDigest
        let recoverableScratchStageExists: Bool
        if let marker = try? await rebuildStageMarker() {
            recoverableScratchStageExists =
                marker.value.sourceGeneration == metadata.activeGeneration &&
                marker.value.sourceRevision <= metadata.revision &&
                marker.value.destinationGeneration != metadata.activeGeneration
        } else {
            recoverableScratchStageExists = false
        }
        let permittedDirectQuarantineCount = directDeficitCount.addingReportingOverflow(
            loggedDerivedQuarantineCount
        )
        guard !permittedDirectQuarantineCount.overflow,
              !pendingQueueRecoveryPermitted ||
                unexplainedQuarantineCount <= permittedDirectQuarantineCount.partialValue ||
                (recoverableScratchStageExists && irreconstructibleIndexesMatch)
        else { throw ProgressionDomainError.invalidRecord("recovery-direct-index-count") }
        let recoverableDirectQuarantineCount =
            unexplainedQuarantineCount
        return ProgressionRecoveryAnchor(
            metadata: metadata,
            physicalMetadata: physicalRecord(metadataPhysical),
            health: refreshedHealth,
            quarantinedProjectionRecordCount: quarantinedProjectionRecordCount,
            recoverableDirectQuarantineCount: recoverableDirectQuarantineCount,
            directRecoveryPermitted:
                pendingQueueRecoveryPermitted &&
                irreconstructibleIndexesMatch &&
                availableAppliedSources.partialValue >= metadata.appliedEventCount,
            recoveredCatalogMigration: recoveredCatalogMigration,
            recoveredExistingUserMigration: recoveredExistingUserMigration,
            recoveredRevealQueueState: recoveredRevealQueueState,
            recoveredRevealValidationRecords: recoveredRevealValidationRecords
        )
    }

    func recoverableTitleSelection(
        metadata: ProgressionMetadataRecord
    ) async throws -> TitleSelectionRecord? {
        do {
            let shard = try await recoveryShard(
                category: .titleSelection,
                metadata: metadata
            )
            let selections = shard.value.records.compactMap {
                logical -> TitleSelectionRecord? in
                if case let .titleSelection(record) = logical { return record }
                return nil
            }
            guard selections.count == 1 else { return nil }
            return selections[0]
        } catch let error as ModuleStateStoreError {
            switch error {
            case .quarantined, .integrityMismatch, .unreadable, .corrupt:
                return nil
            default:
                throw error
            }
        } catch is ProgressionDomainError {
            return nil
        }
    }

    func commit(
        before: ProgressionRepositoryState,
        after proposedProjection: ProgressionProjection,
        additions: ProgressionCommitAdditions,
        transactionID: UUID
    ) async throws -> ModuleStateTransactionResult {
        var projection = proposedProjection
        projection.metadata.terminalProcessedEventDigest =
            before.projection.metadata.terminalProcessedEventDigest
        projection.metadata.acknowledgedRevealDigest =
            before.projection.metadata.acknowledgedRevealDigest
        projection.metadata.commandReceiptDigest =
            before.projection.metadata.commandReceiptDigest
        if let event = additions.processedEvent, event.outcome != .applied {
            projection.metadata.terminalProcessedEventDigest =
                ProgressionDeterminism.xorDigest(
                    before.projection.metadata.terminalProcessedEventDigest,
                    with: try ProgressionDeterminism.encodedIntegrityDigest(event)
                )
        }
        if let acknowledged = additions.acknowledgedRevealUpsert {
            projection.metadata.acknowledgedRevealDigest = ProgressionDeterminism.xorDigest(
                before.projection.metadata.acknowledgedRevealDigest,
                with: try ProgressionDeterminism.canonicalAcknowledgementDigest(acknowledged)
            )
        }
        if let receipt = additions.commandReceipt {
            projection.metadata.commandReceiptDigest = ProgressionDeterminism.xorDigest(
                before.projection.metadata.commandReceiptDigest,
                with: try ProgressionDeterminism.encodedIntegrityDigest(receipt)
            )
        }
        try projection.metadata.validate()
        guard projection.metadata.catalogID == before.projection.metadata.catalogID,
              projection.metadata.catalogVersion == before.projection.metadata.catalogVersion,
              projection.metadata.activeGeneration == before.projection.metadata.activeGeneration,
              additions.pendingRevealUpserts.count <= 2,
              additions.queuedRevealDeletes.count <= 1
        else { throw ProgressionDomainError.invalidRecord("commit-metadata") }

        let nextRevision = before.projection.metadata.revision.addingReportingOverflow(1)
        let nextProcessedEventCount = before.projection.metadata.processedEventCount
            .addingReportingOverflow(1)
        let nextDistinctTokenCount = before.projection.metadata.distinctTokenCount
            .addingReportingOverflow(UInt64(additions.distinctTokenUpserts.count))
        let nextCommandReceiptCount = before.projection.metadata.commandReceiptCount
            .addingReportingOverflow(1)
        let nextAcknowledgedRevealCount = before.projection.metadata
            .acknowledgedRevealCount.addingReportingOverflow(
                additions.acknowledgedRevealUpsert == nil ? 0 : 1
            )
        if let event = additions.processedEvent {
            guard transactionID == event.eventID.rawValue else {
                throw ProgressionDomainError.transactionIdentityCollision
            }
            switch event.outcome {
            case .applied:
                guard !nextRevision.overflow,
                      projection.metadata.revision == nextRevision.partialValue,
                      projection.metadata.lastMutationAt == event.envelope.occurredAt,
                      event.appliedRevision == projection.metadata.revision,
                      additions.appliedEventOrder?.appliedRevision == event.appliedRevision,
                      additions.appliedEventOrder?.eventID == event.eventID,
                      additions.appliedEventOrder?.envelope == event.envelope,
                      additions.appliedEventOrder?.cumulativeDigest ==
                        projection.metadata.appliedEventDigest,
                      before.projection.metadata.appliedEventCount < UInt64.max,
                      projection.metadata.appliedEventCount ==
                        before.projection.metadata.appliedEventCount + 1,
                      !nextProcessedEventCount.overflow,
                      projection.metadata.processedEventCount ==
                        nextProcessedEventCount.partialValue,
                      !nextDistinctTokenCount.overflow,
                      projection.metadata.distinctTokenCount ==
                        nextDistinctTokenCount.partialValue,
                      projection.metadata.acknowledgedRevealCount ==
                        before.projection.metadata.acknowledgedRevealCount,
                      projection.metadata.commandReceiptCount ==
                        before.projection.metadata.commandReceiptCount,
                      projection.metadata.knownInactiveQuarantineCount ==
                        before.projection.metadata.knownInactiveQuarantineCount,
                      projection.metadata.lastAppliedRevision == event.appliedRevision,
                      projection.metadata.initializedAt ==
                        before.projection.metadata.initializedAt,
                      event.transactionID == GrantTransactionID(
                        rawValue: "transaction.\(event.eventID.rawValue.uuidString.lowercased())"
                      ),
                      event.semanticDigest == additions.semanticRecord?.digest,
                      additions.semanticRecord?.firstEventID == event.eventID,
                      additions.semanticRecord?.canonicalMaterial.isEmpty == false,
                      additions.acknowledgedRevealUpsert == nil,
                      additions.queuedRevealDeletes.isEmpty,
                      additions.commandReceipt == nil
                else { throw ProgressionDomainError.invalidRecord("applied-event-commit") }
            case .duplicate, .ignoredIneligible, .rejectedPermanent:
                guard projection.records == before.projection.records,
                      projection.metadata.catalogID == before.projection.metadata.catalogID,
                      projection.metadata.catalogVersion ==
                        before.projection.metadata.catalogVersion,
                      projection.metadata.activeGeneration ==
                        before.projection.metadata.activeGeneration,
                      projection.metadata.revision == before.projection.metadata.revision,
                      projection.metadata.lastMutationAt ==
                        before.projection.metadata.lastMutationAt,
                      projection.metadata.initializedAt ==
                        before.projection.metadata.initializedAt,
                      projection.metadata.appliedEventCount ==
                        before.projection.metadata.appliedEventCount,
                      projection.metadata.lastAppliedRevision ==
                        before.projection.metadata.lastAppliedRevision,
                      projection.metadata.appliedEventDigest ==
                        before.projection.metadata.appliedEventDigest,
                      !nextProcessedEventCount.overflow,
                      projection.metadata.processedEventCount ==
                        nextProcessedEventCount.partialValue,
                      projection.metadata.distinctTokenCount ==
                        before.projection.metadata.distinctTokenCount,
                      projection.metadata.acknowledgedRevealCount ==
                        before.projection.metadata.acknowledgedRevealCount,
                      projection.metadata.commandReceiptCount ==
                        before.projection.metadata.commandReceiptCount,
                      projection.metadata.knownInactiveQuarantineCount ==
                        before.projection.metadata.knownInactiveQuarantineCount,
                      additions.appliedEventOrder == nil,
                      additions.semanticRecord == nil,
                      additions.distinctTokenUpserts.isEmpty,
                      additions.pendingRevealUpserts.isEmpty,
                      additions.acknowledgedRevealUpsert == nil,
                      additions.queuedRevealDeletes.isEmpty,
                      additions.commandReceipt == nil
                else { throw ProgressionDomainError.invalidRecord("terminal-event-commit") }
            }
        } else if let receipt = additions.commandReceipt {
            let isRevealPresentationCommand = receipt.operationIdentifier ==
                "progression.reveal.mark-presented"
            let revealPresentationMutationIsValid = if isRevealPresentationCommand {
                projection.records == before.projection.records &&
                    additions.pendingRevealUpserts.count <= 1 &&
                    additions.acknowledgedRevealUpsert == nil &&
                    additions.queuedRevealDeletes.isEmpty
            } else {
                additions.pendingRevealUpserts.isEmpty
            }
            guard !nextRevision.overflow,
                  projection.metadata.revision == nextRevision.partialValue,
                  projection.metadata.lastMutationAt == receipt.completedAt,
                  projection.metadata.initializedAt ==
                    before.projection.metadata.initializedAt,
                  projection.metadata.appliedEventCount ==
                    before.projection.metadata.appliedEventCount,
                  projection.metadata.lastAppliedRevision ==
                    before.projection.metadata.lastAppliedRevision,
                  projection.metadata.appliedEventDigest ==
                    before.projection.metadata.appliedEventDigest,
                  projection.metadata.processedEventCount ==
                    before.projection.metadata.processedEventCount,
                  projection.metadata.distinctTokenCount ==
                    before.projection.metadata.distinctTokenCount,
                  !nextCommandReceiptCount.overflow,
                  projection.metadata.commandReceiptCount ==
                    nextCommandReceiptCount.partialValue,
                  !nextAcknowledgedRevealCount.overflow,
                  projection.metadata.acknowledgedRevealCount ==
                    nextAcknowledgedRevealCount.partialValue,
                  projection.metadata.knownInactiveQuarantineCount ==
                    before.projection.metadata.knownInactiveQuarantineCount,
                  receipt.resultRevision == projection.metadata.revision,
                  additions.appliedEventOrder == nil,
                  additions.semanticRecord == nil,
                  additions.distinctTokenUpserts.isEmpty,
                  additions.processedEvent == nil,
                  (additions.acknowledgedRevealUpsert == nil) ==
                    additions.queuedRevealDeletes.isEmpty,
                  revealPresentationMutationIsValid
            else { throw ProgressionDomainError.invalidRecord("command-commit") }
        } else {
            throw ProgressionDomainError.invalidRecord("commit-authority")
        }

        let oldShards = try before.projection.shards()
        let newShards = try projection.shards()
        var mutations: [ModuleStateMutation] = []

        if projection.metadata != before.projection.metadata {
            let metadataPayload = try encode(projection.metadata)
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.metadataCollection,
                    recordID: ProgressionRepositoryIDs.activeMetadataRecord
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: metadataPayload,
                expectedRevision: expectation(before.projection.physicalMetadata)
            )))
        }

        for identity in Set(oldShards.keys).union(newShards.keys).sorted() {
            let old = oldShards[identity]
            let new = newShards[identity]
            guard old != new else { continue }
            if let new {
                let key = ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.projectionCollection,
                    recordID: ProgressionRepositoryIDs.shardRecordID(new)
                )
                mutations.append(.upsert(ModuleStateUpsert(
                    key: key,
                    schemaVersion: Self.namespaceSchemaVersion,
                    payload: try encode(new),
                    expectedRevision: expectation(before.projection.physicalShards[identity])
                )))
            } else if let old, let physical = before.projection.physicalShards[identity] {
                mutations.append(.delete(ModuleStateDelete(
                    key: ModuleStateRecordKey(
                        collectionID: ProgressionRepositoryIDs.projectionCollection,
                        recordID: ProgressionRepositoryIDs.shardRecordID(old)
                    ),
                    expectedRevision: .exact(physical.revision)
                )))
            }
        }

        if let event = additions.processedEvent {
            try event.validate()
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.eventCollection(
                        projection.metadata.activeGeneration
                    ),
                    recordID: ProgressionRepositoryIDs.eventRecordID(event.eventID)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(event),
                expectedRevision: .absent
            )))
        }

        if let order = additions.appliedEventOrder {
            try order.validate()
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.eventOrderCollection(
                        projection.metadata.activeGeneration
                    ),
                    recordID: ProgressionRepositoryIDs.eventOrderRecordID(order.appliedRevision)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(order),
                expectedRevision: .absent
            )))
        }

        if let semantic = additions.semanticRecord {
            try semantic.validate()
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.semanticCollection(
                        projection.metadata.activeGeneration
                    ),
                    recordID: ProgressionRepositoryIDs.semanticRecordID(semantic.digest)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(semantic),
                expectedRevision: .absent
            )))
        }

        for token in additions.distinctTokenUpserts.sorted(by: {
            distinctIdentity($0) < distinctIdentity($1)
        }) {
            try token.validate()
            guard token.generation == projection.metadata.activeGeneration else {
                throw ProgressionDomainError.invalidRecord("distinct-token-generation")
            }
            if let prior = try await distinctToken(token) {
                guard prior == token else {
                    throw ProgressionDomainError.recordIdentityCollision(distinctIdentity(token))
                }
                continue
            }
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.distinctCollection,
                    recordID: ProgressionRepositoryIDs.distinctTokenRecordID(token)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(token),
                expectedRevision: .absent
            )))
        }

        for reveal in additions.pendingRevealUpserts.sorted(by: {
            $0.revealID < $1.revealID
        }) {
            try reveal.validate()
            guard reveal.generation == projection.metadata.activeGeneration,
                  reveal.state != .acknowledged
            else {
                throw ProgressionDomainError.invalidRecord("reveal-generation")
            }
            let prior = try await queuedReveal(
                reveal.revealID,
                generation: reveal.generation
            )
            if let prior, prior.value == reveal { continue }
            if let prior, prior.value.revealID != reveal.revealID {
                throw ProgressionDomainError.recordIdentityCollision(reveal.revealID.rawValue)
            }
            if let receipt = additions.commandReceipt,
               receipt.operationIdentifier == "progression.reveal.mark-presented"
            {
                guard let prior,
                      prior.value.state == .queued,
                      reveal.state == .presented,
                      reveal.presentedAt == receipt.completedAt,
                      reveal.acknowledgedAt == nil,
                      reveal.generation == prior.value.generation,
                      reveal.revealID == prior.value.revealID,
                      reveal.transactionID == prior.value.transactionID,
                      reveal.createdRevision == prior.value.createdRevision,
                      reveal.createdAt == prior.value.createdAt,
                      reveal.tier == prior.value.tier,
                      reveal.primaryContentID == prior.value.primaryContentID,
                      reveal.secondaryContentIDs == prior.value.secondaryContentIDs,
                      reveal.sourceAchievementIDs == prior.value.sourceAchievementIDs,
                      reveal.sourceRuleIDs == prior.value.sourceRuleIDs,
                      reveal.nextRevealID == prior.value.nextRevealID
                else {
                    throw ProgressionDomainError.invalidRecord(
                        "reveal-presentation-transition"
                    )
                }
            }
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.revealQueueCollection,
                    recordID: ProgressionRepositoryIDs.queuedRevealRecordID(reveal)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(reveal),
                expectedRevision: expectation(prior?.physical)
            )))
        }

        if let acknowledged = additions.acknowledgedRevealUpsert {
            try acknowledged.validate()
            guard acknowledged.state == .acknowledged else {
                throw ProgressionDomainError.invalidRecord("reveal-acknowledgement")
            }
            if let prior = try await acknowledgedReveal(
                acknowledged.revealID,
                generation: projection.metadata.activeGeneration
            ) {
                guard prior.value == acknowledged else {
                    throw ProgressionDomainError.recordIdentityCollision(
                        acknowledged.revealID.rawValue
                    )
                }
            } else {
                mutations.append(.upsert(ModuleStateUpsert(
                    key: ModuleStateRecordKey(
                        collectionID: ProgressionRepositoryIDs.revealAcknowledgementCollection(
                            projection.metadata.activeGeneration
                        ),
                        recordID: ProgressionRepositoryIDs.acknowledgedRevealRecordID(
                            acknowledged.revealID
                        )
                    ),
                    schemaVersion: Self.namespaceSchemaVersion,
                    payload: try encode(acknowledged),
                    expectedRevision: .absent
                )))
            }
        }

        for queued in additions.queuedRevealDeletes {
            guard additions.acknowledgedRevealUpsert?.revealID == queued.value.revealID,
                  queued.value.state == .presented,
                  queued.physical.key.recordID == ProgressionRepositoryIDs.queuedRevealRecordID(
                    queued.value
                  )
            else { throw ProgressionDomainError.invalidRecord("reveal-delete-without-ack") }
            mutations.append(.delete(ModuleStateDelete(
                key: queued.physical.key,
                expectedRevision: .exact(queued.physical.revision)
            )))
        }

        if let receipt = additions.commandReceipt {
            try receipt.validate()
            let commandTransactionID = ProgressionDeterminism.transactionUUID(
                "runtime-operation|\(receipt.operationIdentifier)|\(receipt.operationID)"
            )
            guard commandTransactionID == transactionID else {
                throw ProgressionDomainError.transactionIdentityCollision
            }
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.commandCollection(
                        projection.metadata.activeGeneration
                    ),
                    recordID: ProgressionRepositoryIDs.commandRecordID(transactionID)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(receipt),
                expectedRevision: .absent
            )))
        }

        guard !mutations.isEmpty else {
            throw ModuleStateStoreError.invalidRequest
        }
        try validateTransactionBounds(mutations)
        let transaction = try ModuleStateTransaction(
            transactionID: transactionID,
            mutations: mutations
        )
        return try await client.transact(transaction)
    }

    func promoteStagedGeneration(
        before: ProgressionRepositoryState,
        stagedProjection proposedProjection: ProgressionProjection,
        stagedReveals: [PendingRevealRecord],
        receipt: ProgressionCommandReceiptRecord,
        transactionID: UUID,
        rebuildStageMarker: ProgressionLocatedRecord<ProgressionRebuildStageMarkerRecord>? = nil,
        allowsCatalogUpgrade: Bool = false
    ) async throws -> ModuleStateTransactionResult {
        try receipt.validate()
        guard proposedProjection.metadata.terminalProcessedEventDigest ==
                before.projection.metadata.terminalProcessedEventDigest,
              proposedProjection.metadata.acknowledgedRevealDigest ==
                before.projection.metadata.acknowledgedRevealDigest,
              proposedProjection.metadata.commandReceiptDigest ==
                before.projection.metadata.commandReceiptDigest
        else { throw ProgressionDomainError.invalidRecord("rebuild-index-commitment") }
        var stagedProjection = proposedProjection
        stagedProjection.metadata.commandReceiptDigest = ProgressionDeterminism.xorDigest(
            before.projection.metadata.commandReceiptDigest,
            with: try ProgressionDeterminism.encodedIntegrityDigest(receipt)
        )
        try stagedProjection.metadata.validate()
        let nextRevision = before.projection.metadata.revision.addingReportingOverflow(1)
        guard !nextRevision.overflow,
              stagedProjection.metadata.catalogID == before.projection.metadata.catalogID,
              (allowsCatalogUpgrade
                ? stagedProjection.metadata.catalogVersion >
                    before.projection.metadata.catalogVersion
                : stagedProjection.metadata.catalogVersion ==
                    before.projection.metadata.catalogVersion),
              stagedProjection.metadata.activeGeneration != before.projection.metadata.activeGeneration,
              stagedProjection.metadata.revision == nextRevision.partialValue,
              stagedProjection.metadata.lastMutationAt == receipt.completedAt,
              stagedProjection.metadata.processedEventCount ==
                before.projection.metadata.processedEventCount,
              stagedProjection.metadata.terminalProcessedEventDigest ==
                before.projection.metadata.terminalProcessedEventDigest,
              stagedProjection.metadata.distinctTokenCount ==
                before.projection.metadata.distinctTokenCount,
              stagedProjection.metadata.acknowledgedRevealCount ==
                before.projection.metadata.acknowledgedRevealCount,
              stagedProjection.metadata.acknowledgedRevealDigest ==
                before.projection.metadata.acknowledgedRevealDigest,
              before.projection.metadata.commandReceiptCount < UInt64.max,
              stagedProjection.metadata.commandReceiptCount ==
                before.projection.metadata.commandReceiptCount + 1,
              stagedProjection.metadata.knownInactiveQuarantineCount >=
                before.projection.metadata.knownInactiveQuarantineCount,
              receipt.resultRevision == stagedProjection.metadata.revision,
              ProgressionDeterminism.transactionUUID(
                  "runtime-operation|\(receipt.operationIdentifier)|\(receipt.operationID)"
              ) == transactionID
        else { throw ProgressionDomainError.invalidRecord("rebuild-promotion") }

        for (_, shard) in try stagedProjection.shards() {
            guard try await projectionShard(
                generation: shard.generation,
                category: shard.category,
                shardIndex: shard.shardIndex
            )?.value == shard else {
                throw ProgressionDomainError.invalidRecord("rebuild-stage-incomplete")
            }
        }
        for reveal in stagedReveals {
            guard try await queuedReveal(
                reveal.revealID,
                generation: reveal.generation
            )?.value == reveal else {
                throw ProgressionDomainError.invalidRecord("rebuild-reveal-stage-incomplete")
            }
        }
        try validateStagedRevealQueue(
            projection: stagedProjection,
            reveals: stagedReveals
        )

        var mutations: [ModuleStateMutation] = [
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.metadataCollection,
                    recordID: ProgressionRepositoryIDs.activeMetadataRecord
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(stagedProjection.metadata),
                expectedRevision: expectation(before.projection.physicalMetadata)
            )),
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.commandCollection(
                        stagedProjection.metadata.activeGeneration
                    ),
                    recordID: ProgressionRepositoryIDs.commandRecordID(transactionID)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(receipt),
                expectedRevision: .absent
            )),
        ]
        if let rebuildStageMarker {
            guard rebuildStageMarker.value.sourceGeneration ==
                    before.projection.metadata.activeGeneration,
                  rebuildStageMarker.value.sourceRevision ==
                    before.projection.metadata.revision,
                  rebuildStageMarker.value.destinationGeneration ==
                    stagedProjection.metadata.activeGeneration,
                  rebuildStageMarker.value.operationID == receipt.operationID,
                  rebuildStageMarker.value.correlationID == receipt.correlationID,
                  rebuildStageMarker.value.operationIdentifier == receipt.operationIdentifier,
                  rebuildStageMarker.value.operationTimestamp == receipt.completedAt
            else { throw ProgressionDomainError.invalidRecord("rebuild-stage-marker-context") }
            mutations.append(.delete(ModuleStateDelete(
                key: rebuildStageMarker.physical.key,
                expectedRevision: .exact(rebuildStageMarker.physical.revision)
            )))
        }
        try validateTransactionBounds(mutations)
        return try await client.transact(try ModuleStateTransaction(
            transactionID: transactionID,
            mutations: mutations
        ))
    }

    func prepareExistingUserMigrationStage(
        source: ProgressionRepositoryState,
        delivery: ExistingUserMigrationDeliveryDTO,
        snapshotDigest: String,
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionLocatedRecord<ExistingUserMigrationStageMarkerRecord> {
        guard metadata.operationIdentifier.rawValue ==
                "progression.migration.existing-user.apply",
              delivery.snapshot.schemaVersion ==
                ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              ProgressionDeterminism.isIntegrityDigest(snapshotDigest)
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-operation")
        }
        let transactionID = delivery.transactionID.rawValue
        let destinationGeneration = ProgressionDeterminism.digest128(
            "existing-user-migration-generation|\(source.projection.metadata.catalogID.rawValue)|\(source.projection.metadata.catalogVersion.rawValue)|\(ExistingUserMigrationRecord.migrationVersion)|\(transactionID.uuidString.lowercased())|\(snapshotDigest)"
        )
        let desired = ExistingUserMigrationStageMarkerRecord(
            sourceGeneration: source.projection.metadata.activeGeneration,
            sourceRevision: source.projection.metadata.revision,
            destinationGeneration: destinationGeneration,
            snapshotSchemaVersion: delivery.snapshot.schemaVersion,
            transactionID: transactionID,
            snapshotDigest: snapshotDigest,
            cipherCount: UInt32(delivery.snapshot.ciphers.count),
            operationID: metadata.operationID.rawValue,
            correlationID: metadata.correlationID.rawValue,
            operationIdentifier: metadata.operationIdentifier.rawValue,
            operationTimestamp: metadata.timestampUTC
        )
        try desired.validate()

        if let existing = try await existingUserMigrationStageMarker() {
            if existing.value == desired { return existing }
            guard existing.value.transactionID != transactionID else {
                throw ProgressionDomainError.transactionIdentityCollision
            }
            if existing.value.destinationGeneration !=
                source.projection.metadata.activeGeneration
            {
                try await cleanupInactiveGeneration(
                    existing.value.destinationGeneration,
                    activeGeneration: source.projection.metadata.activeGeneration,
                    operationID: "existing-user-migration-stale.\(metadata.operationID.rawValue)"
                )
            }
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "existing-user-migration-stage-clear|\(metadata.operationID.rawValue)|\(existing.physical.revision)"
                ),
                mutations: [.delete(ModuleStateDelete(
                    key: existing.physical.key,
                    expectedRevision: .exact(existing.physical.revision)
                ))]
            ))
        }

        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
        )
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "existing-user-migration-stage-create|\(transactionID.uuidString.lowercased())|\(snapshotDigest)"
            ),
            mutations: [.upsert(ModuleStateUpsert(
                key: key,
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(desired),
                expectedRevision: .absent
            ))]
        ))
        guard let created = try await existingUserMigrationStageMarker(),
              created.value == desired
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-stage-create")
        }
        return created
    }

    func prepareExistingUserMigrationPageStage(
        source: ProgressionRepositoryState,
        delivery: ExistingUserMigrationPageDeliveryDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionLocatedRecord<ExistingUserMigrationStageMarkerRecord> {
        let page = delivery.page
        guard metadata.operationIdentifier.rawValue ==
                "progression.migration.existing-user.page.apply",
              page.handoffSchemaVersion ==
                ExistingUserMigrationPageDTO.currentHandoffSchemaVersion,
              ProgressionDeterminism.isIntegrityDigest(page.aggregateDigest)
        else {
            throw ProgressionDomainError.invalidRecord(
                "existing-user-migration-page-operation"
            )
        }
        let transactionID = delivery.transactionID.rawValue
        let destinationGeneration = ProgressionDeterminism.digest128(
            "existing-user-migration-generation|\(source.projection.metadata.catalogID.rawValue)|\(source.projection.metadata.catalogVersion.rawValue)|\(ExistingUserMigrationRecord.migrationVersion)|\(transactionID.uuidString.lowercased())|\(page.aggregateDigest)"
        )
        let desired = ExistingUserMigrationStageMarkerRecord(
            sourceGeneration: source.projection.metadata.activeGeneration,
            sourceRevision: source.projection.metadata.revision,
            destinationGeneration: destinationGeneration,
            snapshotSchemaVersion: page.snapshot.schemaVersion,
            transactionID: transactionID,
            snapshotDigest: page.aggregateDigest,
            cipherCount: page.totalCipherCount,
            handoffSchemaVersion: page.handoffSchemaVersion,
            pageCount: page.pageCount,
            operationID: metadata.operationID.rawValue,
            correlationID: metadata.correlationID.rawValue,
            operationIdentifier: metadata.operationIdentifier.rawValue,
            operationTimestamp: metadata.timestampUTC
        )
        try desired.validate()

        if let existing = try await existingUserMigrationStageMarker() {
            if existing.value.transactionID == transactionID,
               existing.value.sourceGeneration == desired.sourceGeneration,
               existing.value.sourceRevision == desired.sourceRevision,
               existing.value.destinationGeneration == desired.destinationGeneration,
               existing.value.snapshotSchemaVersion == desired.snapshotSchemaVersion,
               existing.value.snapshotDigest == desired.snapshotDigest,
               existing.value.cipherCount == desired.cipherCount,
               existing.value.handoffSchemaVersion == desired.handoffSchemaVersion,
               existing.value.pageCount == desired.pageCount
            {
                return existing
            }
            guard existing.value.transactionID != transactionID else {
                throw ProgressionDomainError.transactionIdentityCollision
            }
            if existing.value.destinationGeneration !=
                source.projection.metadata.activeGeneration
            {
                try await cleanupInactiveGeneration(
                    existing.value.destinationGeneration,
                    activeGeneration: source.projection.metadata.activeGeneration,
                    operationID:
                        "existing-user-migration-stale.\(metadata.operationID.rawValue)"
                )
            }
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "existing-user-migration-stage-clear|\(metadata.operationID.rawValue)|\(existing.physical.revision)"
                ),
                mutations: [.delete(ModuleStateDelete(
                    key: existing.physical.key,
                    expectedRevision: .exact(existing.physical.revision)
                ))]
            ))
        }

        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
        )
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "existing-user-migration-page-stage-create|\(transactionID.uuidString.lowercased())|\(page.aggregateDigest)"
            ),
            mutations: [.upsert(ModuleStateUpsert(
                key: key,
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(desired),
                expectedRevision: .absent
            ))]
        ))
        guard let created = try await existingUserMigrationStageMarker(),
              created.value == desired
        else {
            throw ProgressionDomainError.invalidRecord(
                "existing-user-migration-page-stage-create"
            )
        }
        return created
    }

    func stageExistingUserMigration(
        projection: ProgressionProjection,
        seedRecords: [ExistingUserMigrationSeedRecord],
        distinctTokens: [DistinctTokenRecord],
        pendingReveal: PendingRevealRecord?,
        marker: ProgressionLocatedRecord<ExistingUserMigrationStageMarkerRecord>,
        existing: ProgressionRepositoryState
    ) async throws {
        guard marker.value.destinationGeneration == projection.metadata.activeGeneration,
              marker.value.cipherCount == UInt32(seedRecords.count),
              marker.value.cipherCount == UInt32(distinctTokens.count)
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-stage-context")
        }
        try await stage(
            projection,
            distinctTokens: distinctTokens,
            pendingReveals: pendingReveal.map { [$0] } ?? [],
            operationID: "existing-user-migration.\(marker.value.transactionID.uuidString.lowercased())",
            existing: existing
        )

        var plan: [ProgressionPlannedStageMutation] = []
        for seed in seedRecords.sorted(by: { $0.cipherToken < $1.cipherToken }) {
            try seed.validate()
            guard seed.generation == projection.metadata.activeGeneration else {
                throw ProgressionDomainError.invalidRecord("existing-user-migration-seed-generation")
            }
            let prior = try await existingUserMigrationSeed(seed)
            if let prior, prior != seed {
                throw ProgressionDomainError.recordIdentityCollision(seed.cipherToken.rawValue)
            }
            plan.append(ProgressionPlannedStageMutation(
                mutation: .upsert(ModuleStateUpsert(
                    key: ModuleStateRecordKey(
                        collectionID: ProgressionRepositoryIDs
                            .existingUserMigrationSeedCollection,
                        recordID: ProgressionRepositoryIDs
                            .existingUserMigrationSeedRecordID(seed)
                    ),
                    schemaVersion: Self.namespaceSchemaVersion,
                    payload: try encode(seed),
                    expectedRevision: .absent
                )),
                alreadyPresent: prior != nil
            ))
        }
        plan.sort { $0.mutation.key < $1.mutation.key }
        for (index, batch) in try stageMutationBatches(plan).enumerated() {
            if batch.allSatisfy(\.alreadyPresent) { continue }
            guard batch.allSatisfy({ !$0.alreadyPresent }) else {
                throw ProgressionDomainError.invalidRecord(
                    "partial-existing-user-migration-stage"
                )
            }
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "existing-user-migration-seed-stage|\(marker.value.transactionID.uuidString.lowercased())|\(index)"
                ),
                mutations: batch.map(\.mutation)
            ))
        }
        try await validateExistingUserMigrationSeedSnapshot(
            generation: projection.metadata.activeGeneration,
            expectedCount: marker.value.cipherCount,
            expectedDigest: marker.value.snapshotDigest,
            handoffSchemaVersion: marker.value.handoffSchemaVersion,
            pageCount: marker.value.pageCount
        )
    }

    func promoteExistingUserMigration(
        before: ProgressionRepositoryState,
        stagedProjection: ProgressionProjection,
        pendingReveal: PendingRevealRecord?,
        marker: ProgressionLocatedRecord<ExistingUserMigrationStageMarkerRecord>
    ) async throws -> ModuleStateTransactionResult {
        let records = stagedProjection.records(matching: {
            logical -> ExistingUserMigrationRecord? in
            guard case let .existingUserMigration(record) = logical else { return nil }
            return record
        })
        guard records.count == 1 else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-record")
        }
        let migration = records[0]
        let nextRevision = before.projection.metadata.revision.addingReportingOverflow(1)
        guard !nextRevision.overflow,
              marker.value.sourceGeneration == before.projection.metadata.activeGeneration,
              marker.value.sourceRevision == before.projection.metadata.revision,
              marker.value.destinationGeneration == stagedProjection.metadata.activeGeneration,
              marker.value.transactionID == migration.transactionID,
              marker.value.snapshotSchemaVersion == migration.snapshotSchemaVersion,
              marker.value.snapshotDigest == migration.snapshotDigest,
              marker.value.cipherCount == migration.cipherCount,
              marker.value.handoffSchemaVersion == migration.handoffSchemaVersion,
              marker.value.pageCount == migration.pageCount,
              marker.value.operationTimestamp == migration.completedAt,
              stagedProjection.metadata.catalogID == before.projection.metadata.catalogID,
              stagedProjection.metadata.catalogVersion == before.projection.metadata.catalogVersion,
              stagedProjection.metadata.activeGeneration !=
                before.projection.metadata.activeGeneration,
              stagedProjection.metadata.revision == nextRevision.partialValue,
              stagedProjection.metadata.lastMutationAt == migration.completedAt,
              stagedProjection.metadata.initializedAt ==
                before.projection.metadata.initializedAt,
              before.projection.metadata.appliedEventCount == 0,
              before.projection.metadata.processedEventCount == 0,
              before.projection.metadata.distinctTokenCount == 0,
              stagedProjection.metadata.appliedEventCount == 0,
              stagedProjection.metadata.processedEventCount == 0,
              stagedProjection.metadata.distinctTokenCount == UInt64(migration.cipherCount),
              stagedProjection.metadata.acknowledgedRevealCount ==
                before.projection.metadata.acknowledgedRevealCount,
              stagedProjection.metadata.commandReceiptCount ==
                before.projection.metadata.commandReceiptCount,
              stagedProjection.metadata.knownInactiveQuarantineCount ==
                before.projection.metadata.knownInactiveQuarantineCount
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-promotion")
        }
        try stagedProjection.metadata.validate()
        for (_, shard) in try stagedProjection.shards() {
            guard try await projectionShard(
                generation: shard.generation,
                category: shard.category,
                shardIndex: shard.shardIndex
            )?.value == shard else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-stage-incomplete"
                )
            }
        }
        if let pendingReveal {
            guard try await queuedReveal(
                pendingReveal.revealID,
                generation: pendingReveal.generation
            )?.value == pendingReveal else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-reveal-incomplete"
                )
            }
        }
        try validateStagedRevealQueue(
            projection: stagedProjection,
            reveals: pendingReveal.map { [$0] } ?? []
        )
        try await validateExistingUserMigrationSeedSnapshot(
            generation: stagedProjection.metadata.activeGeneration,
            expectedCount: migration.cipherCount,
            expectedDigest: migration.snapshotDigest,
            handoffSchemaVersion: migration.handoffSchemaVersion,
            pageCount: migration.pageCount
        )

        let mutations: [ModuleStateMutation] = [
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.metadataCollection,
                    recordID: ProgressionRepositoryIDs.activeMetadataRecord
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(stagedProjection.metadata),
                expectedRevision: expectation(before.projection.physicalMetadata)
            )),
            .delete(ModuleStateDelete(
                key: marker.physical.key,
                expectedRevision: .exact(marker.physical.revision)
            )),
        ]
        try validateTransactionBounds(mutations)
        return try await client.transact(try ModuleStateTransaction(
            transactionID: marker.value.transactionID,
            mutations: mutations
        ))
    }

    func existingUserMigrationSeeds(
        generation: String
    ) async throws -> [ExistingUserMigrationSeedRecord] {
        var result: [ExistingUserMigrationSeedRecord] = []
        var cursor: ModuleStateScanCursor?
        repeat {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: ProgressionRepositoryIDs.existingUserMigrationSeedCollection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            for physical in page.records {
                guard physical.key.recordID.rawValue.hasPrefix(
                    "migration-seed.\(generation)."
                ) else { continue }
                let record: ExistingUserMigrationSeedRecord = try await decodeDirectRecord(
                    physical,
                    category: .distinctToken,
                    invalidLabel: "existing-user-migration-seed-corrupt"
                ) {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    let decoded = try ProgressionDeterminism.decoder().decode(
                        ExistingUserMigrationSeedRecord.self,
                        from: physical.payload
                    )
                    try decoded.validate()
                    guard decoded.generation == generation,
                          ProgressionRepositoryIDs.existingUserMigrationSeedRecordID(decoded) ==
                            physical.key.recordID
                    else {
                        throw ProgressionDomainError.invalidRecord(
                            "existing-user-migration-seed-identity"
                        )
                    }
                    return decoded
                }
                result.append(record)
            }
            cursor = page.nextCursor
        } while cursor != nil
        let sorted = result.sorted { $0.cipherToken < $1.cipherToken }
        guard Set(sorted.map(\.cipherToken)).count == sorted.count else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-seed-duplicate")
        }
        return sorted
    }

    func stageExistingUserMigrationSeedRecords(
        _ records: [ExistingUserMigrationSeedRecord],
        generation: String,
        operationID: String
    ) async throws {
        var plan: [ProgressionPlannedStageMutation] = []
        for seed in records.sorted(by: { $0.cipherToken < $1.cipherToken }) {
            try seed.validate()
            guard seed.generation == generation else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-seed-generation"
                )
            }
            let prior = try await existingUserMigrationSeed(seed)
            if let prior, prior != seed {
                throw ProgressionDomainError.recordIdentityCollision(seed.cipherToken.rawValue)
            }
            plan.append(ProgressionPlannedStageMutation(
                mutation: .upsert(ModuleStateUpsert(
                    key: ModuleStateRecordKey(
                        collectionID: ProgressionRepositoryIDs
                            .existingUserMigrationSeedCollection,
                        recordID: ProgressionRepositoryIDs
                            .existingUserMigrationSeedRecordID(seed)
                    ),
                    schemaVersion: Self.namespaceSchemaVersion,
                    payload: try encode(seed),
                    expectedRevision: .absent
                )),
                alreadyPresent: prior != nil
            ))
        }
        plan.sort { $0.mutation.key < $1.mutation.key }
        for (index, batch) in try stageMutationBatches(plan).enumerated() {
            if batch.allSatisfy(\.alreadyPresent) { continue }
            guard batch.allSatisfy({ !$0.alreadyPresent }) else {
                throw ProgressionDomainError.invalidRecord(
                    "partial-existing-user-migration-stage"
                )
            }
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "existing-user-migration-seed-stage|\(operationID)|\(index)"
                ),
                mutations: batch.map(\.mutation)
            ))
        }
    }

    func validateExistingUserMigrationSeedSnapshot(
        generation: String,
        expectedCount: UInt32,
        expectedDigest: String,
        handoffSchemaVersion: UInt16? = nil,
        pageCount: UInt32? = nil
    ) async throws {
        let records = try await existingUserMigrationSeeds(generation: generation)
        guard records.count == Int(expectedCount) else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-seed-count")
        }
        let ciphers = try records.map {
            try ExistingUserMigrationCipherDTO(
                cipherToken: $0.cipherToken,
                origin: $0.origin
            )
        }
        let actualDigest: String
        if handoffSchemaVersion ==
            ExistingUserMigrationPageDTO.currentHandoffSchemaVersion
        {
            guard let pageCount else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-seed-page-count"
                )
            }
            actualDigest = try ProgressionExistingUserMigrationReducer.aggregateDigest(
                ciphers: ciphers,
                pageCount: pageCount
            )
        } else {
            guard handoffSchemaVersion == nil, pageCount == nil else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-seed-handoff"
                )
            }
            actualDigest = try ProgressionDeterminism.encodedIntegrityDigest(
                ExistingUserMigrationSnapshotDTO(ciphers: ciphers)
            )
        }
        guard actualDigest == expectedDigest else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-seed-digest")
        }
    }

    func prepareRebuildStage(
        source: ProgressionRepositoryState,
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionLocatedRecord<ProgressionRebuildStageMarkerRecord> {
        guard metadata.operationIdentifier.rawValue == "progression.recovery.rebuild" else {
            throw ProgressionDomainError.invalidRecord("rebuild-stage-operation")
        }
        let destinationGeneration = ProgressionDeterminism.digest128(
            "rebuild-generation|\(source.projection.metadata.catalogID.rawValue)|\(source.projection.metadata.catalogVersion.rawValue)|\(metadata.operationIdentifier.rawValue)|\(metadata.operationID.rawValue)"
        )
        let desired = ProgressionRebuildStageMarkerRecord(
            sourceGeneration: source.projection.metadata.activeGeneration,
            sourceRevision: source.projection.metadata.revision,
            destinationGeneration: destinationGeneration,
            operationID: metadata.operationID.rawValue,
            correlationID: metadata.correlationID.rawValue,
            operationIdentifier: metadata.operationIdentifier.rawValue,
            operationTimestamp: metadata.timestampUTC
        )
        try desired.validate()

        if let existing = try await rebuildStageMarker() {
            if existing.value == desired { return existing }
            if existing.value.destinationGeneration !=
                source.projection.metadata.activeGeneration
            {
                try await cleanupRecoveryEventCandidates(
                    generation: existing.value.destinationGeneration,
                    operationID: metadata.operationID.rawValue
                )
                try await cleanupInactiveGeneration(
                    existing.value.destinationGeneration,
                    activeGeneration: source.projection.metadata.activeGeneration,
                    operationID: metadata.operationID.rawValue
                )
            }
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "rebuild-stage-marker-clear|\(metadata.operationID.rawValue)|\(existing.physical.revision)"
                ),
                mutations: [.delete(ModuleStateDelete(
                    key: existing.physical.key,
                    expectedRevision: .exact(existing.physical.revision)
                ))]
            ))
        }

        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.rebuildStageMarkerRecord
        )
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "rebuild-stage-marker-create|\(metadata.operationID.rawValue)"
            ),
            mutations: [.upsert(ModuleStateUpsert(
                key: key,
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(desired),
                expectedRevision: .absent
            ))]
        ))
        guard let created = try await rebuildStageMarker(), created.value == desired else {
            throw ProgressionDomainError.invalidRecord("rebuild-stage-marker-create")
        }
        return created
    }

    func stage(
        _ projection: ProgressionProjection,
        distinctTokens: [DistinctTokenRecord],
        pendingReveals: [PendingRevealRecord],
        operationID: String,
        existing: ProgressionRepositoryState
    ) async throws {
        let shards = try projection.shards().values.sorted {
            ProgressionRepositoryIDs.shardRecordID($0)
                < ProgressionRepositoryIDs.shardRecordID($1)
        }
        var plan: [ProgressionPlannedStageMutation] = []
        for shard in shards {
            let identity = ProgressionProjectionLayout.shardIdentity(
                generation: shard.generation,
                category: shard.category,
                shardIndex: shard.shardIndex
            )
            let prior = try await projectionShard(
                generation: shard.generation,
                category: shard.category,
                shardIndex: shard.shardIndex
            )
            if let prior {
                guard prior.value == shard else {
                    throw ProgressionDomainError.recordIdentityCollision(identity)
                }
            }
            plan.append(ProgressionPlannedStageMutation(
                mutation: .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.projectionCollection,
                    recordID: ProgressionRepositoryIDs.shardRecordID(shard)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(shard),
                expectedRevision: .absent
                )),
                alreadyPresent: prior != nil
            ))
        }

        for token in distinctTokens.sorted(by: { distinctIdentity($0) < distinctIdentity($1) }) {
            try token.validate()
            guard token.generation == projection.metadata.activeGeneration else {
                throw ProgressionDomainError.invalidRecord("staged-distinct-generation")
            }
            let prior = try await distinctToken(token)
            if let prior {
                guard prior == token else {
                    throw ProgressionDomainError.recordIdentityCollision(distinctIdentity(token))
                }
            }
            plan.append(ProgressionPlannedStageMutation(
                mutation: .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.distinctCollection,
                    recordID: ProgressionRepositoryIDs.distinctTokenRecordID(token)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(token),
                expectedRevision: .absent
                )),
                alreadyPresent: prior != nil
            ))
        }
        for reveal in pendingReveals.sorted(by: { $0.revealID < $1.revealID }) {
            try reveal.validate()
            guard reveal.generation == projection.metadata.activeGeneration else {
                throw ProgressionDomainError.invalidRecord("staged-reveal-generation")
            }
            let prior = try await queuedReveal(
                reveal.revealID,
                generation: reveal.generation
            )
            if let prior {
                guard prior.value == reveal else {
                    throw ProgressionDomainError.recordIdentityCollision(reveal.revealID.rawValue)
                }
            }
            plan.append(ProgressionPlannedStageMutation(
                mutation: .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.revealQueueCollection,
                    recordID: ProgressionRepositoryIDs.queuedRevealRecordID(reveal)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(reveal),
                expectedRevision: .absent
                )),
                alreadyPresent: prior != nil
            ))
        }

        plan.sort { $0.mutation.key < $1.mutation.key }
        let batches = try stageMutationBatches(plan)
        for (batchIndex, batch) in batches.enumerated() {
            if batch.allSatisfy(\.alreadyPresent) { continue }
            guard batch.allSatisfy({ !$0.alreadyPresent }) else {
                throw ProgressionDomainError.invalidRecord("partial-rebuild-stage-batch")
            }
            let transaction = try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "rebuild-stage|\(operationID)|\(batchIndex)"
                ),
                mutations: batch.map(\.mutation)
            )
            _ = try await client.transact(transaction)
        }
    }

    func stageDistinctTokens(
        _ tokens: [DistinctTokenRecord],
        generation: String,
        operationID: String,
        appliedRevision: UInt64
    ) async throws {
        var plan: [ProgressionPlannedStageMutation] = []
        for token in tokens.sorted(by: { distinctIdentity($0) < distinctIdentity($1) }) {
            try token.validate()
            guard token.generation == generation else {
                throw ProgressionDomainError.invalidRecord("staged-distinct-generation")
            }
            let prior = try await distinctToken(token)
            if let prior, prior != token {
                throw ProgressionDomainError.recordIdentityCollision(distinctIdentity(token))
            }
            plan.append(ProgressionPlannedStageMutation(
                mutation: .upsert(ModuleStateUpsert(
                    key: ModuleStateRecordKey(
                        collectionID: ProgressionRepositoryIDs.distinctCollection,
                        recordID: ProgressionRepositoryIDs.distinctTokenRecordID(token)
                    ),
                    schemaVersion: Self.namespaceSchemaVersion,
                    payload: try encode(token),
                    expectedRevision: .absent
                )),
                alreadyPresent: prior != nil
            ))
        }
        plan.sort { $0.mutation.key < $1.mutation.key }
        let batches = try stageMutationBatches(plan)
        for (index, batch) in batches.enumerated() {
            if batch.allSatisfy(\.alreadyPresent) { continue }
            guard batch.allSatisfy({ !$0.alreadyPresent }) else {
                throw ProgressionDomainError.invalidRecord("partial-distinct-stage-batch")
            }
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "rebuild-token-stage|\(operationID)|\(appliedRevision)|\(index)"
                ),
                mutations: batch.map(\.mutation)
            ))
        }
    }

    func stageAppliedLedger(
        processed: ProcessedEventRecord,
        order: ProgressionAppliedEventOrderRecord,
        semantic: ProgressionSemanticDedupeRecord,
        generation: String,
        operationID: String
    ) async throws {
        try processed.validate()
        try order.validate()
        try semantic.validate()
        guard processed.outcome == .applied,
              processed.eventID == order.eventID,
              processed.envelope == order.envelope,
              processed.envelopeDigest == order.envelopeDigest,
              processed.semanticDigest == semantic.digest,
              semantic.firstEventID == processed.eventID,
              processed.appliedRevision == order.appliedRevision
        else { throw ProgressionDomainError.invalidRecord("staged-applied-ledger") }
        var mutations: [ModuleStateMutation] = []
        if let prior = try await processedEvent(processed.eventID, generation: generation) {
            guard prior == processed else {
                throw ProgressionDomainError.recordIdentityCollision(
                    processed.eventID.rawValue.uuidString.lowercased()
                )
            }
        } else {
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.eventCollection(generation),
                    recordID: ProgressionRepositoryIDs.eventRecordID(processed.eventID)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(processed),
                expectedRevision: .absent
            )))
        }
        if let prior = try await appliedEventOrderRecord(
            order.appliedRevision,
            generation: generation
        ) {
            guard prior == order else {
                throw ProgressionDomainError.recordIdentityCollision(
                    String(order.appliedRevision)
                )
            }
        } else {
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.eventOrderCollection(generation),
                    recordID: ProgressionRepositoryIDs.eventOrderRecordID(order.appliedRevision)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(order),
                expectedRevision: .absent
            )))
        }
        if let prior = try await semanticRecord(semantic.digest, generation: generation) {
            guard prior == semantic else {
                throw ProgressionDomainError.recordIdentityCollision(semantic.digest)
            }
        } else {
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.semanticCollection(generation),
                    recordID: ProgressionRepositoryIDs.semanticRecordID(semantic.digest)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(semantic),
                expectedRevision: .absent
            )))
        }
        guard !mutations.isEmpty else { return }
        try validateTransactionBounds(mutations)
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "rebuild-applied-ledger|\(operationID)|\(order.appliedRevision)"
            ),
            mutations: mutations
        ))
    }

    func stageTerminalProcessedRecord(
        _ record: ProcessedEventRecord,
        generation: String,
        operationID: String
    ) async throws {
        try record.validate()
        guard record.outcome != .applied else {
            throw ProgressionDomainError.invalidRecord("staged-terminal-event")
        }
        if let prior = try await processedEvent(record.eventID, generation: generation) {
            guard prior == record else {
                throw ProgressionDomainError.recordIdentityCollision(
                    record.eventID.rawValue.uuidString.lowercased()
                )
            }
            return
        }
        let mutation = ModuleStateMutation.upsert(ModuleStateUpsert(
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.eventCollection(generation),
                recordID: ProgressionRepositoryIDs.eventRecordID(record.eventID)
            ),
            schemaVersion: Self.namespaceSchemaVersion,
            payload: try encode(record),
            expectedRevision: .absent
        ))
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "rebuild-terminal-ledger|\(operationID)|\(record.eventID.rawValue.uuidString.lowercased())"
            ),
            mutations: [mutation]
        ))
    }

    func queueTail(
        in state: ProgressionRepositoryState
    ) async throws -> PendingRevealRecord? {
        let queue = try revealQueueState(in: state.projection)
        guard let tailID = queue.tailRevealID else { return nil }
        guard let tail = try await queuedReveal(
            tailID,
            generation: state.projection.metadata.activeGeneration
        )?.value,
        tail.nextRevealID == nil
        else { throw ProgressionDomainError.invalidRecord("reveal-queue-tail-missing") }
        return tail
    }

    func validatedRevealQueueHead(
        in projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionLocatedRecord<PendingRevealRecord>? {
        try await validateActiveRevealQueue(
            revealQueueState(in: projection),
            generation: projection.metadata.activeGeneration,
            validationRecords: projection.records,
            bundle: bundle
        ).first
    }

    func validatedRevealQueueRecords(
        in projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> [ProgressionLocatedRecord<PendingRevealRecord>] {
        try await validateActiveRevealQueue(
            revealQueueState(in: projection),
            generation: projection.metadata.activeGeneration,
            validationRecords: projection.records,
            bundle: bundle
        )
    }

    func structurallyValidatedRevealQueueRecords(
        in projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> [ProgressionLocatedRecord<PendingRevealRecord>] {
        try await validateActiveRevealQueue(
            revealQueueState(in: projection),
            generation: projection.metadata.activeGeneration,
            validationRecords: [:],
            bundle: bundle,
            validateReferences: false
        )
    }

    func validatePreservedRevealReferences(
        _ records: [ProgressionLocatedRecord<PendingRevealRecord>],
        against projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws {
        for located in records {
            do {
                try await validateQueuedRevealReferences(
                    located.value,
                    validationRecords: projection.records,
                    bundle: bundle,
                    metadataOverride: projection.metadata,
                    ledgerGenerationOverride: projection.metadata.activeGeneration
                )
            } catch {
                try await quarantineQueuedRevealReference(located)
                throw ProgressionQueuedRevealReferenceError(
                    label: "queued-reveal-reference"
                )
            }
        }
    }

    func validateAcknowledgementReferences(
        generation: String,
        against projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws {
        var cursor: ModuleStateScanCursor?
        repeat {
            let page = try await acknowledgementPage(
                generation: generation,
                validationRecords: projection.records,
                bundle: bundle,
                validateReferences: true,
                metadataOverride: projection.metadata,
                ledgerGenerationOverride: projection.metadata.activeGeneration,
                cursor: cursor
            )
            cursor = try await refreshedCursor(page.next)
        } while cursor != nil
    }

    func cleanupInactiveGeneration(
        _ generation: String,
        activeGeneration: String,
        operationID: String
    ) async throws {
        guard ProgressionDeterminism.isDigest(generation),
              ProgressionDeterminism.isDigest(activeGeneration),
              generation != activeGeneration
        else {
            throw ProgressionDomainError.invalidRecord("cleanup-generation")
        }
        var shardDeletes: [ModuleStateMutation] = []
        for category in ProgressionProjectionLayout.projectedCategories {
            for shardIndex in 0 ..< ProgressionProjectionLayout.shardCount(for: category) {
                let recordID = ProgressionRepositoryIDs.shardRecordID(
                    generation: generation,
                    category: category,
                    shardIndex: shardIndex
                )
                do {
                    if let physical = try await client.fetch(
                        collectionID: ProgressionRepositoryIDs.projectionCollection,
                        recordID: recordID
                    ) {
                        shardDeletes.append(.delete(ModuleStateDelete(
                            key: physical.key,
                            expectedRevision: .exact(physical.revision)
                        )))
                    }
                } catch let error as ModuleStateStoreError {
                    switch error {
                    case .quarantined, .integrityMismatch, .unreadable, .corrupt:
                        continue
                    default:
                        throw error
                    }
                }
            }
        }
        if !shardDeletes.isEmpty {
            try validateTransactionBounds(shardDeletes)
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "rebuild-cleanup-shards|\(operationID)|\(generation)"
                ),
                mutations: shardDeletes
            ))
        }
        try await cleanupCollection(
            ProgressionRepositoryIDs.distinctCollection,
            recordPrefix: "distinct.\(generation).",
            operationID: operationID
        )
        try await cleanupCollection(
            ProgressionRepositoryIDs.revealQueueCollection,
            recordPrefix: "reveal.\(generation).",
            operationID: operationID
        )
        try await cleanupCollection(
            ProgressionRepositoryIDs.existingUserMigrationSeedCollection,
            recordPrefix: "migration-seed.\(generation).",
            operationID: operationID
        )
        for collection in [
            ProgressionRepositoryIDs.eventCollection(generation),
            ProgressionRepositoryIDs.eventOrderCollection(generation),
            ProgressionRepositoryIDs.semanticCollection(generation),
            ProgressionRepositoryIDs.revealAcknowledgementCollection(generation),
            ProgressionRepositoryIDs.commandCollection(generation),
        ] {
            try await cleanupCollection(
                collection,
                recordPrefix: "",
                operationID: operationID
            )
        }
    }

    func completeCatalogUpgradeCleanup(
        _ state: ProgressionRepositoryState,
        completedAt: Date,
        operationID: String,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionRepositoryState {
        guard case let .catalogMigration(migration)? = state.projection.logicalRecords()
            .first(where: {
                if case .catalogMigration = $0 { return true }
                return false
            }),
            migration.priorGeneration != nil,
            migration.cleanupCompletedAt == nil
        else { return state }
        var projection = state.projection
        let (revision, overflow) = projection.metadata.revision.addingReportingOverflow(1)
        guard !overflow else { throw ProgressionDomainError.invalidRecord("revision-overflow") }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = completedAt
        try projection.upsert(.catalogMigration(CatalogMigrationRecord(
            generation: migration.generation,
            migrationVersion: migration.migrationVersion,
            catalogVersion: migration.catalogVersion,
            transactionID: migration.transactionID,
            completedAt: migration.completedAt,
            compatibilityFingerprints: migration.compatibilityFingerprints,
            upgradeRevealBundle: migration.upgradeRevealBundle,
            priorCatalogVersion: migration.priorCatalogVersion,
            priorGeneration: migration.priorGeneration,
            cleanupCompletedAt: completedAt
        )))
        let identity = ProgressionProjectionLayout.shardIdentity(
            generation: projection.metadata.activeGeneration,
            category: .catalogMigration,
            shardIndex: 0
        )
        guard let priorShard = state.projection.physicalShards[identity],
              let shard = try projection.shards()[identity]
        else { throw ProgressionDomainError.invalidRecord("catalog-cleanup-shard") }
        let mutations: [ModuleStateMutation] = [
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.metadataCollection,
                    recordID: ProgressionRepositoryIDs.activeMetadataRecord
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(projection.metadata),
                expectedRevision: expectation(state.projection.physicalMetadata)
            )),
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.projectionCollection,
                    recordID: ProgressionRepositoryIDs.shardRecordID(shard)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(shard),
                expectedRevision: .exact(priorShard.revision)
            )),
        ]
        try validateTransactionBounds(mutations)
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "catalog-upgrade-cleanup-complete|\(operationID)"
            ),
            mutations: mutations
        ))
        return try await loadExisting(bundle: bundle)
    }

    func projectionShard(
        generation: String,
        category: ProgressionDiagnosticRecordCategory,
        shardIndex: UInt16
    ) async throws -> ProgressionLocatedRecord<ProgressionProjectionShard>? {
        let recordID = ProgressionRepositoryIDs.shardRecordID(
            generation: generation,
            category: category,
            shardIndex: shardIndex
        )
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.projectionCollection,
            recordID: recordID
        ) else { return nil }
        let located: ProgressionLocatedRecord<ProgressionProjectionShard> =
            try await decodeDirectRecord(
                physical,
                category: category,
                invalidLabel: "projection-shard-corrupt"
            ) {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let shard = try ProgressionDeterminism.decoder().decode(
                    ProgressionProjectionShard.self,
                    from: physical.payload
                )
                try shard.validate()
                guard ProgressionRepositoryIDs.shardRecordID(shard) ==
                        physical.key.recordID
                else { throw ProgressionDomainError.invalidRecord("projection-shard-identity") }
                return ProgressionLocatedRecord(
                    value: shard,
                    physical: physicalRecord(physical)
                )
            }
        guard located.value.generation == generation,
              located.value.category == category,
              located.value.shardIndex == shardIndex
        else { throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue) }
        return located
    }

    private func rebuildStageMarker() async throws ->
        ProgressionLocatedRecord<ProgressionRebuildStageMarkerRecord>?
    {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.rebuildStageMarkerRecord
        ) else { return nil }
        return try await decodeDirectRecord(
            physical,
            category: .metadata,
            invalidLabel: "rebuild-stage-marker-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let value = try ProgressionDeterminism.decoder().decode(
                ProgressionRebuildStageMarkerRecord.self,
                from: physical.payload
            )
            try value.validate()
            guard physical.key.collectionID == ProgressionRepositoryIDs.metadataCollection,
                  physical.key.recordID == ProgressionRepositoryIDs.rebuildStageMarkerRecord
            else { throw ProgressionDomainError.invalidRecord("rebuild-stage-marker-identity") }
            return ProgressionLocatedRecord(
                value: value,
                physical: physicalRecord(physical)
            )
        }
    }

    private func existingUserMigrationStageMarker() async throws ->
        ProgressionLocatedRecord<ExistingUserMigrationStageMarkerRecord>?
    {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
        ) else { return nil }
        return try await decodeDirectRecord(
            physical,
            category: .metadata,
            invalidLabel: "existing-user-migration-stage-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let value = try ProgressionDeterminism.decoder().decode(
                ExistingUserMigrationStageMarkerRecord.self,
                from: physical.payload
            )
            try value.validate()
            guard physical.key.collectionID == ProgressionRepositoryIDs.metadataCollection,
                  physical.key.recordID ==
                    ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
            else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-stage-identity"
                )
            }
            return ProgressionLocatedRecord(
                value: value,
                physical: physicalRecord(physical)
            )
        }
    }

    private func existingUserMigrationSeed(
        _ candidate: ExistingUserMigrationSeedRecord
    ) async throws -> ExistingUserMigrationSeedRecord? {
        let recordID = ProgressionRepositoryIDs.existingUserMigrationSeedRecordID(candidate)
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.existingUserMigrationSeedCollection,
            recordID: recordID
        ) else { return nil }
        let record: ExistingUserMigrationSeedRecord = try await decodeDirectRecord(
            physical,
            category: .distinctToken,
            invalidLabel: "existing-user-migration-seed-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let decoded = try ProgressionDeterminism.decoder().decode(
                ExistingUserMigrationSeedRecord.self,
                from: physical.payload
            )
            try decoded.validate()
            guard ProgressionRepositoryIDs.existingUserMigrationSeedRecordID(decoded) ==
                    physical.key.recordID
            else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-seed-identity"
                )
            }
            return decoded
        }
        guard record.generation == candidate.generation,
              record.cipherToken == candidate.cipherToken
        else { throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue) }
        return record
    }

    func queuedReveal(
        _ revealID: RevealID,
        generation: String
    ) async throws -> ProgressionLocatedRecord<PendingRevealRecord>? {
        let recordID = ProgressionRepositoryIDs.queuedRevealRecordID(
            revealID,
            generation: generation
        )
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.revealQueueCollection,
            recordID: recordID
        ) else { return nil }
        let located: ProgressionLocatedRecord<PendingRevealRecord> = try await decodeDirectRecord(
            physical,
            category: .pendingReveal,
            invalidLabel: "queued-reveal-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                PendingRevealRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard record.state != .acknowledged,
                  ProgressionRepositoryIDs.queuedRevealRecordID(record) == physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("queued-reveal-identity") }
            return ProgressionLocatedRecord(
                value: record,
                physical: physicalRecord(physical)
            )
        }
        guard located.value.generation == generation,
              located.value.revealID == revealID
        else { throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue) }
        return located
    }

    func acknowledgedReveal(
        _ revealID: RevealID,
        generation: String
    ) async throws -> ProgressionLocatedRecord<PendingRevealRecord>? {
        let recordID = ProgressionRepositoryIDs.acknowledgedRevealRecordID(revealID)
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.revealAcknowledgementCollection(generation),
            recordID: recordID
        ) else { return nil }
        let located: ProgressionLocatedRecord<PendingRevealRecord> = try await decodeDirectRecord(
            physical,
            category: .pendingReveal,
            invalidLabel: "acknowledged-reveal-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                PendingRevealRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard record.state == .acknowledged,
                  record.generation == generation,
                  ProgressionRepositoryIDs.acknowledgedRevealRecordID(record.revealID) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("acknowledged-reveal-identity") }
            return ProgressionLocatedRecord(
                value: record,
                physical: physicalRecord(physical)
            )
        }
        guard located.value.revealID == revealID else {
            throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue)
        }
        return located
    }

    func validatedAcknowledgedReveal(
        _ revealID: RevealID,
        generation: String,
        projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionLocatedRecord<PendingRevealRecord>? {
        guard let located = try await acknowledgedReveal(
            revealID,
            generation: generation
        ) else { return nil }
        do {
            try await validateQueuedRevealReferences(
                located.value,
                validationRecords: projection.records,
                bundle: bundle
            )
        } catch {
            try await quarantineQueuedRevealReference(located)
            throw ProgressionAcknowledgedRevealReferenceError(
                label: "acknowledged-reveal-reference"
            )
        }
        return located
    }

    func processedEvent(
        _ eventID: EventID,
        generation: String
    ) async throws -> ProcessedEventRecord? {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.eventCollection(generation),
            recordID: ProgressionRepositoryIDs.eventRecordID(eventID)
        ) else { return nil }
        let record: ProcessedEventRecord = try await decodeDirectRecord(
            physical,
            category: .processedEvent,
            invalidLabel: "processed-event-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                ProcessedEventRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard ProgressionRepositoryIDs.eventRecordID(record.eventID) == physical.key.recordID
            else {
                throw ProgressionDomainError.invalidRecord("processed-event-identity")
            }
            return record
        }
        guard record.eventID == eventID else {
            throw ProgressionDomainError.recordIdentityCollision(physical.key.recordID.rawValue)
        }
        return record
    }

    func semanticRecord(
        _ digest: String,
        generation: String
    ) async throws -> ProgressionSemanticDedupeRecord? {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.semanticCollection(generation),
            recordID: ProgressionRepositoryIDs.semanticRecordID(digest)
        ) else { return nil }
        let record: ProgressionSemanticDedupeRecord = try await decodeDirectRecord(
            physical,
            category: .processedEvent,
            invalidLabel: "semantic-record-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                ProgressionSemanticDedupeRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard ProgressionRepositoryIDs.semanticRecordID(record.digest) == physical.key.recordID
            else {
                throw ProgressionDomainError.invalidRecord("semantic-record-identity")
            }
            return record
        }
        guard record.digest == digest else {
            throw ProgressionDomainError.recordIdentityCollision(physical.key.recordID.rawValue)
        }
        return record
    }

    func distinctToken(_ candidate: DistinctTokenRecord) async throws -> DistinctTokenRecord? {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.distinctCollection,
            recordID: ProgressionRepositoryIDs.distinctTokenRecordID(candidate)
        ) else { return nil }
        let record: DistinctTokenRecord = try await decodeDirectRecord(
            physical,
            category: .distinctToken,
            invalidLabel: "distinct-token-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                DistinctTokenRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard ProgressionRepositoryIDs.distinctTokenRecordID(record) == physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("distinct-token-identity") }
            return record
        }
        guard distinctIdentity(record) == distinctIdentity(candidate) else {
            throw ProgressionDomainError.recordIdentityCollision(distinctIdentity(candidate))
        }
        return record
    }

    func appliedEventOrderPage(
        generation: String,
        cursor: ModuleStateScanCursor?
    ) async throws -> (records: [ProgressionAppliedEventOrderRecord], next: ModuleStateScanCursor?) {
        let request = try ModuleStateScanRequest(
            collectionID: ProgressionRepositoryIDs.eventOrderCollection(generation),
            limit: ModuleStateScanRequest.maximumLimit,
            cursor: cursor
        )
        let page = try await client.scan(request)
        var priorRevision: UInt64?
        var values: [ProgressionAppliedEventOrderRecord] = []
        for physical in page.records {
            let value: ProgressionAppliedEventOrderRecord = try await decodeDirectRecord(
                physical,
                category: .processedEvent,
                invalidLabel: "applied-event-order-corrupt"
            ) {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let decoded = try ProgressionDeterminism.decoder().decode(
                    ProgressionAppliedEventOrderRecord.self,
                    from: physical.payload
                )
                try decoded.validate()
                guard physical.key.recordID == ProgressionRepositoryIDs.eventOrderRecordID(
                    decoded.appliedRevision
                ) else { throw ProgressionDomainError.invalidRecord("applied-event-order") }
                return decoded
            }
            guard priorRevision.map({ $0 < value.appliedRevision }) ?? true else {
                try await quarantineInvalid(
                    physical,
                    category: .processedEvent,
                    code: ProgressionRepositoryIDs.recordDecodeCode
                )
                throw ProgressionDomainError.invalidRecord("applied-event-order")
            }
            priorRevision = value.appliedRevision
            values.append(value)
        }
        if let next = page.nextCursor {
            guard next.collectionID == ProgressionRepositoryIDs.eventOrderCollection(generation),
                  next != cursor,
                  cursor.map({
                      $0.observedStoreRevision == next.observedStoreRevision &&
                          $0.afterRecordID < next.afterRecordID
                  }) ?? true
            else { throw ProgressionDomainError.invalidRecord("event-order-cursor") }
        }
        return (values, page.nextCursor)
    }

    func appliedEventOrderRecord(
        _ revision: UInt64,
        generation: String
    ) async throws -> ProgressionAppliedEventOrderRecord? {
        let recordID = ProgressionRepositoryIDs.eventOrderRecordID(revision)
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.eventOrderCollection(generation),
            recordID: recordID
        ) else { return nil }
        let value: ProgressionAppliedEventOrderRecord = try await decodeDirectRecord(
            physical,
            category: .processedEvent,
            invalidLabel: "applied-event-order-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let decoded = try ProgressionDeterminism.decoder().decode(
                ProgressionAppliedEventOrderRecord.self,
                from: physical.payload
            )
            try decoded.validate()
            guard decoded.appliedRevision == revision,
                  ProgressionRepositoryIDs.eventOrderRecordID(decoded.appliedRevision) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("applied-event-order-identity") }
            return decoded
        }
        return value
    }

    func captureRecoveryEventCandidates(
        from sourceGeneration: String,
        to destinationGeneration: String,
        operationID: String
    ) async throws {
        guard sourceGeneration != destinationGeneration,
              ProgressionDeterminism.isDigest(sourceGeneration),
              ProgressionDeterminism.isDigest(destinationGeneration)
        else { throw ProgressionDomainError.invalidRecord("recovery-candidate-generation") }

        try await captureOrderCandidates(
            from: sourceGeneration,
            to: destinationGeneration,
            operationID: operationID
        )
        try await captureProcessedCandidates(
            from: sourceGeneration,
            to: destinationGeneration,
            operationID: operationID
        )
        try await reconcileRecoveryEventCandidates(
            sourceGeneration: sourceGeneration,
            destinationGeneration: destinationGeneration,
            operationID: operationID
        )
    }

    func recoveryEventCandidatePage(
        generation: String,
        cursor: ModuleStateScanCursor?
    ) async throws -> (
        records: [ProgressionRecoveryEventCandidateRecord],
        next: ModuleStateScanCursor?
    ) {
        let collection = ProgressionRepositoryIDs.recoveryEventCollection(generation)
        let page = try await client.scan(try ModuleStateScanRequest(
            collectionID: collection,
            limit: ModuleStateScanRequest.maximumLimit,
            cursor: cursor
        ))
        var records: [ProgressionRecoveryEventCandidateRecord] = []
        for physical in page.records {
            let record: ProgressionRecoveryEventCandidateRecord = try await decodeDirectRecord(
                physical,
                category: .processedEvent,
                invalidLabel: "recovery-event-candidate-corrupt"
            ) {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let decoded = try ProgressionDeterminism.decoder().decode(
                    ProgressionRecoveryEventCandidateRecord.self,
                    from: physical.payload
                )
                try decoded.validate()
                guard decoded.generation == generation,
                      ProgressionRepositoryIDs.recoveryEventRecordID(
                          decoded.appliedRevision
                      ) == physical.key.recordID
                else {
                    throw ProgressionDomainError.invalidRecord(
                        "recovery-event-candidate-identity"
                    )
                }
                return decoded
            }
            records.append(record)
        }
        try validateCursor(page.nextCursor, prior: cursor, collection: collection)
        return (records, page.nextCursor)
    }

    func cleanupRecoveryEventCandidates(
        generation: String,
        operationID: String
    ) async throws {
        try await cleanupCollection(
            ProgressionRepositoryIDs.recoveryEventCollection(generation),
            recordPrefix: "",
            operationID: operationID
        )
    }

    func quarantineAppliedEventOrder(
        revision: UInt64,
        generation: String
    ) async throws {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.eventOrderCollection(generation),
            recordID: ProgressionRepositoryIDs.eventOrderRecordID(revision)
        ) else { return }
        try await quarantineInvalid(
            physical,
            category: .processedEvent,
            code: ProgressionRepositoryIDs.recordReferenceCode
        )
    }

    func quarantineProcessedEvent(
        eventID: EventID,
        generation: String
    ) async throws {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.eventCollection(generation),
            recordID: ProgressionRepositoryIDs.eventRecordID(eventID)
        ) else { return }
        try await quarantineInvalid(
            physical,
            category: .processedEvent,
            code: ProgressionRepositoryIDs.recordReferenceCode
        )
    }

    func processedEventPage(
        generation: String,
        cursor: ModuleStateScanCursor?
    ) async throws -> (records: [ProcessedEventRecord], next: ModuleStateScanCursor?) {
        let collection = ProgressionRepositoryIDs.eventCollection(generation)
        let page = try await client.scan(try ModuleStateScanRequest(
            collectionID: collection,
            limit: ModuleStateScanRequest.maximumLimit,
            cursor: cursor
        ))
        var values: [ProcessedEventRecord] = []
        for physical in page.records {
            let value: ProcessedEventRecord = try await decodeDirectRecord(
                physical,
                category: .processedEvent,
                invalidLabel: "processed-event-corrupt"
            ) {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let decoded = try ProgressionDeterminism.decoder().decode(
                    ProcessedEventRecord.self,
                    from: physical.payload
                )
                try decoded.validate()
                guard ProgressionRepositoryIDs.eventRecordID(decoded.eventID) ==
                        physical.key.recordID
                else { throw ProgressionDomainError.invalidRecord("processed-event-identity") }
                return decoded
            }
            values.append(value)
        }
        try validateCursor(page.nextCursor, prior: cursor, collection: collection)
        return (values, page.nextCursor)
    }

    func acknowledgementPage(
        generation: String,
        validationRecords: [String: ProgressionLogicalRecord],
        bundle: ValidatedProgressionCatalogBundle,
        validateReferences: Bool = true,
        metadataOverride: ProgressionMetadataRecord? = nil,
        ledgerGenerationOverride: String? = nil,
        cursor: ModuleStateScanCursor?
    ) async throws -> (
        records: [ProgressionLocatedRecord<PendingRevealRecord>],
        next: ModuleStateScanCursor?
    ) {
        let collection = ProgressionRepositoryIDs.revealAcknowledgementCollection(generation)
        let page = try await client.scan(try ModuleStateScanRequest(
            collectionID: collection,
            limit: ModuleStateScanRequest.maximumLimit,
            cursor: cursor
        ))
        var values: [ProgressionLocatedRecord<PendingRevealRecord>] = []
        for physical in page.records {
            let value: ProgressionLocatedRecord<PendingRevealRecord> =
                try await decodeDirectRecord(
                    physical,
                    category: .pendingReveal,
                    invalidLabel: "acknowledged-reveal-corrupt"
                ) {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    let decoded = try ProgressionDeterminism.decoder().decode(
                        PendingRevealRecord.self,
                        from: physical.payload
                    )
                    try decoded.validate()
                    guard decoded.state == .acknowledged,
                          decoded.generation == generation,
                          ProgressionRepositoryIDs.acknowledgedRevealRecordID(
                              decoded.revealID
                          ) == physical.key.recordID
                    else {
                        throw ProgressionDomainError.invalidRecord(
                            "acknowledged-reveal-identity"
                        )
                    }
                    return ProgressionLocatedRecord(
                        value: decoded,
                        physical: physicalRecord(physical)
                    )
                }
            if validateReferences {
                do {
                    try await validateQueuedRevealReferences(
                        value.value,
                        validationRecords: validationRecords,
                        bundle: bundle,
                        metadataOverride: metadataOverride,
                        ledgerGenerationOverride: ledgerGenerationOverride
                    )
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .pendingReveal,
                        code: ProgressionRepositoryIDs.recordReferenceCode
                    )
                    throw ProgressionAcknowledgedRevealReferenceError(
                        label: "acknowledged-reveal-reference"
                    )
                }
            }
            values.append(value)
        }
        try validateCursor(page.nextCursor, prior: cursor, collection: collection)
        return (values, page.nextCursor)
    }

    func commandReceiptPage(
        generation: String,
        maximumResultRevision: UInt64,
        cursor: ModuleStateScanCursor?
    ) async throws -> (records: [ProgressionCommandReceiptRecord], next: ModuleStateScanCursor?) {
        let collection = ProgressionRepositoryIDs.commandCollection(generation)
        let page = try await client.scan(try ModuleStateScanRequest(
            collectionID: collection,
            limit: ModuleStateScanRequest.maximumLimit,
            cursor: cursor
        ))
        var values: [ProgressionCommandReceiptRecord] = []
        for physical in page.records {
            let value: ProgressionCommandReceiptRecord = try await decodeDirectRecord(
                physical,
                category: .metadata,
                invalidLabel: "command-receipt-corrupt"
            ) {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let decoded = try ProgressionDeterminism.decoder().decode(
                    ProgressionCommandReceiptRecord.self,
                    from: physical.payload
                )
                try decoded.validate()
                let transactionID = ProgressionDeterminism.transactionUUID(
                    "runtime-operation|\(decoded.operationIdentifier)|\(decoded.operationID)"
                )
                guard ProgressionRepositoryIDs.commandRecordID(transactionID) ==
                        physical.key.recordID,
                      decoded.resultRevision <= maximumResultRevision,
                      decoded.cleanupGeneration != generation,
                      !commandReceiptRequiresCleanup(decoded.operationIdentifier) ||
                        decoded.cleanupGeneration != nil
                else { throw ProgressionDomainError.invalidRecord("command-receipt-identity") }
                return decoded
            }
            values.append(value)
        }
        try validateCursor(page.nextCursor, prior: cursor, collection: collection)
        return (values, page.nextCursor)
    }

    func stageAcknowledgement(
        _ record: PendingRevealRecord,
        generation: String,
        operationID: String
    ) async throws {
        try record.validate()
        guard record.state == .acknowledged, record.generation == generation else {
            throw ProgressionDomainError.invalidRecord("staged-acknowledgement")
        }
        if let prior = try await acknowledgedReveal(record.revealID, generation: generation) {
            guard prior.value == record else {
                throw ProgressionDomainError.recordIdentityCollision(record.revealID.rawValue)
            }
            return
        }
        let mutation = ModuleStateMutation.upsert(ModuleStateUpsert(
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.revealAcknowledgementCollection(
                    generation
                ),
                recordID: ProgressionRepositoryIDs.acknowledgedRevealRecordID(record.revealID)
            ),
            schemaVersion: Self.namespaceSchemaVersion,
            payload: try encode(record),
            expectedRevision: .absent
        ))
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "rebuild-ack|\(operationID)|\(record.revealID.rawValue)"
            ),
            mutations: [mutation]
        ))
    }

    func stageCommandReceipt(
        _ receipt: ProgressionCommandReceiptRecord,
        generation: String,
        operationID: String
    ) async throws {
        try receipt.validate()
        guard receipt.cleanupGeneration != generation,
              !commandReceiptRequiresCleanup(receipt.operationIdentifier) ||
                receipt.cleanupGeneration != nil
        else {
            throw ProgressionDomainError.invalidRecord("staged-command-receipt")
        }
        let transactionID = ProgressionDeterminism.transactionUUID(
            "runtime-operation|\(receipt.operationIdentifier)|\(receipt.operationID)"
        )
        let recordID = ProgressionRepositoryIDs.commandRecordID(transactionID)
        if let existing = try await storedCommandReceipt(
            recordID: recordID,
            generation: generation
        ) {
            guard existing == receipt else {
                throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue)
            }
            return
        }
        let mutation = ModuleStateMutation.upsert(ModuleStateUpsert(
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.commandCollection(generation),
                recordID: recordID
            ),
            schemaVersion: Self.namespaceSchemaVersion,
            payload: try encode(receipt),
            expectedRevision: .absent
        ))
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "rebuild-command|\(operationID)|\(recordID.rawValue)"
            ),
            mutations: [mutation]
        ))
    }

    func copyGenerationScopedRecords(
        from sourceGeneration: String,
        to destinationGeneration: String,
        appliedEventCount: UInt64,
        sourceRevision: UInt64,
        sourceProjection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle,
        validateAcknowledgementReferences: Bool = true,
        operationID: String
    ) async throws -> ProgressionGenerationCopySummary {
        guard sourceGeneration != destinationGeneration,
              ProgressionDeterminism.isDigest(sourceGeneration),
              ProgressionDeterminism.isDigest(destinationGeneration)
        else { throw ProgressionDomainError.invalidRecord("generation-copy") }

        var cursor: ModuleStateScanCursor?
        var terminalProcessedEventCount: UInt64 = 0
        var terminalProcessedEventDigest: String?
        repeat {
            let page = try await processedEventPage(
                generation: sourceGeneration,
                cursor: cursor
            )
            for record in page.records {
                if record.outcome == .applied {
                    guard try await processedEvent(
                        record.eventID,
                        generation: destinationGeneration
                    ) == record else {
                        throw ProgressionDomainError.invalidRecord(
                            "generation-copy-applied-event"
                        )
                    }
                } else {
                    do {
                        try await validateTerminalProcessedRecord(
                            record,
                            generation: sourceGeneration,
                            semanticGeneration: destinationGeneration,
                            bundle: bundle
                        )
                    } catch {
                        try await quarantineProcessedEvent(
                            eventID: record.eventID,
                            generation: sourceGeneration
                        )
                        throw error
                    }
                    let (nextCount, overflow) = terminalProcessedEventCount
                        .addingReportingOverflow(1)
                    guard !overflow else {
                        throw ProgressionDomainError.invalidRecord("generation-copy-count")
                    }
                    terminalProcessedEventCount = nextCount
                    terminalProcessedEventDigest = ProgressionDeterminism.xorDigest(
                        terminalProcessedEventDigest,
                        with: try ProgressionDeterminism.encodedIntegrityDigest(record)
                    )
                    try await stageTerminalProcessedRecord(
                        record,
                        generation: destinationGeneration,
                        operationID: operationID
                    )
                }
            }
            cursor = try await refreshedCursor(page.next)
        } while cursor != nil

        let (processedEventCount, countOverflow) = appliedEventCount
            .addingReportingOverflow(terminalProcessedEventCount)
        guard !countOverflow else {
            throw ProgressionDomainError.invalidRecord("generation-copy-count")
        }

        var acknowledgedRevealCount: UInt64 = 0
        var acknowledgedRevealDigest: String?
        cursor = nil
        repeat {
            let page = try await acknowledgementPage(
                generation: sourceGeneration,
                validationRecords: sourceProjection.records,
                bundle: bundle,
                validateReferences: validateAcknowledgementReferences,
                cursor: cursor
            )
            for located in page.records {
                let (nextCount, overflow) = acknowledgedRevealCount
                    .addingReportingOverflow(1)
                guard !overflow else {
                    throw ProgressionDomainError.invalidRecord("generation-copy-count")
                }
                acknowledgedRevealCount = nextCount
                let record = located.value
                acknowledgedRevealDigest = ProgressionDeterminism.xorDigest(
                    acknowledgedRevealDigest,
                    with: try ProgressionDeterminism.canonicalAcknowledgementDigest(record)
                )
                try await stageAcknowledgement(PendingRevealRecord(
                    generation: destinationGeneration,
                    revealID: record.revealID,
                    transactionID: record.transactionID,
                    createdRevision: record.createdRevision,
                    createdAt: record.createdAt,
                    state: record.state,
                    presentedAt: record.presentedAt,
                    acknowledgedAt: record.acknowledgedAt,
                    tier: record.tier,
                    primaryContentID: record.primaryContentID,
                    secondaryContentIDs: record.secondaryContentIDs,
                    sourceAchievementIDs: record.sourceAchievementIDs,
                    sourceRuleIDs: record.sourceRuleIDs,
                    nextRevealID: record.nextRevealID
                ), generation: destinationGeneration, operationID: operationID)
            }
            cursor = try await refreshedCursor(page.next)
        } while cursor != nil

        var commandReceiptCount: UInt64 = 0
        var commandReceiptDigest: String?
        cursor = nil
        repeat {
            let page = try await commandReceiptPage(
                generation: sourceGeneration,
                maximumResultRevision: sourceRevision,
                cursor: cursor
            )
            for receipt in page.records {
                let (nextCount, overflow) = commandReceiptCount.addingReportingOverflow(1)
                guard !overflow else {
                    throw ProgressionDomainError.invalidRecord("generation-copy-count")
                }
                commandReceiptCount = nextCount
                commandReceiptDigest = ProgressionDeterminism.xorDigest(
                    commandReceiptDigest,
                    with: try ProgressionDeterminism.encodedIntegrityDigest(receipt)
                )
                try await stageCommandReceipt(
                    receipt,
                    generation: destinationGeneration,
                    operationID: operationID
                )
            }
            cursor = try await refreshedCursor(page.next)
        } while cursor != nil

        return ProgressionGenerationCopySummary(
            processedEventCount: processedEventCount,
            terminalProcessedEventDigest: terminalProcessedEventDigest,
            acknowledgedRevealCount: acknowledgedRevealCount,
            acknowledgedRevealDigest: acknowledgedRevealDigest,
            commandReceiptCount: commandReceiptCount,
            commandReceiptDigest: commandReceiptDigest
        )
    }

    func commandReceipt(
        metadata: RuntimeOperationMetadata,
        commandDigest: String,
        generation: String,
        requiresCleanupGeneration: Bool = false
    ) async throws -> ProgressionCommandReceiptRecord? {
        let transactionID = ProgressionDeterminism.transactionUUID(
            "runtime-operation|\(metadata.operationIdentifier.rawValue)|\(metadata.operationID.rawValue)"
        )
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.commandCollection(generation),
            recordID: ProgressionRepositoryIDs.commandRecordID(transactionID)
        ) else { return nil }
        let receipt: ProgressionCommandReceiptRecord = try await decodeDirectRecord(
            physical,
            category: .metadata,
            invalidLabel: "command-receipt-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let receipt = try ProgressionDeterminism.decoder().decode(
                ProgressionCommandReceiptRecord.self,
                from: physical.payload
            )
            try receipt.validate()
            let storedTransactionID = ProgressionDeterminism.transactionUUID(
                "runtime-operation|\(receipt.operationIdentifier)|\(receipt.operationID)"
            )
            guard ProgressionRepositoryIDs.commandRecordID(storedTransactionID) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("command-receipt-identity") }
            return receipt
        }
        let activeMetadata = try await activeMetadataForDirectContext()
        guard activeMetadata.activeGeneration == generation,
              receipt.resultRevision <= activeMetadata.revision,
              receipt.cleanupGeneration != generation,
              !requiresCleanupGeneration || receipt.cleanupGeneration != nil
        else {
            try await quarantineInvalid(
                physical,
                category: .metadata,
                code: ProgressionRepositoryIDs.recordReferenceCode
            )
            throw ProgressionDomainError.invalidRecord("command-receipt-reference")
        }
        guard receipt.operationID == metadata.operationID.rawValue,
              receipt.correlationID == metadata.correlationID.rawValue,
              receipt.operationIdentifier == metadata.operationIdentifier.rawValue,
              receipt.commandDigest == commandDigest
        else { throw ProgressionDomainError.transactionIdentityCollision }
        return receipt
    }

    func quarantineDiagnostics(
        health: ModuleStateHealthSnapshot
    ) async throws -> ProgressionQuarantineDiagnostics {
        var cursor: ModuleStateScanCursor?
        var decodeCount: UInt64 = 0
        var referenceCount: UInt64 = 0
        var decodedCount: UInt64 = 0
        repeat {
            let request = try ModuleStateScanRequest(
                collectionID: ProgressionRepositoryIDs.quarantineCollection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            )
            let page = try await client.scan(request)
            for physical in page.records {
                let record: QuarantineRecord
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    record = try ProgressionDeterminism.decoder().decode(
                          QuarantineRecord.self,
                          from: physical.payload
                    )
                    try record.validate()
                    guard ProgressionRepositoryIDs.quarantineRecordID(record) ==
                            physical.key.recordID
                    else { throw ProgressionDomainError.invalidRecord("quarantine-identity") }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .quarantine,
                        code: ProgressionRepositoryIDs.recordDecodeCode
                    )
                    throw ProgressionDomainError.invalidRecord("quarantine-record-corrupt")
                }
                let (nextDecoded, decodedOverflow) = decodedCount.addingReportingOverflow(1)
                guard !decodedOverflow else {
                    throw ProgressionDomainError.invalidRecord("quarantine-count-overflow")
                }
                decodedCount = nextDecoded
                switch record.diagnosticCode {
                case ProgressionRepositoryIDs.recordDecodeCode:
                    let (next, overflow) = decodeCount.addingReportingOverflow(1)
                    guard !overflow else {
                        throw ProgressionDomainError.invalidRecord("quarantine-count-overflow")
                    }
                    decodeCount = next
                case ProgressionRepositoryIDs.recordReferenceCode:
                    let (next, overflow) = referenceCount.addingReportingOverflow(1)
                    guard !overflow else {
                        throw ProgressionDomainError.invalidRecord("quarantine-count-overflow")
                    }
                    referenceCount = next
                default:
                    break
                }
            }
            try validateCursor(
                page.nextCursor,
                prior: cursor,
                collection: ProgressionRepositoryIDs.quarantineCollection
            )
            cursor = page.nextCursor
        } while cursor != nil

        let recognized = decodeCount.addingReportingOverflow(referenceCount)
        guard !recognized.overflow else {
            throw ProgressionDomainError.invalidRecord("quarantine-count-overflow")
        }
        let accounted = min(decodedCount, recognized.partialValue)
        let integrityCount = health.quarantinedRecordCount > accounted
            ? health.quarantinedRecordCount - accounted
            : 0
        return ProgressionQuarantineDiagnostics(
            recordDecodeCount: decodeCount,
            recordReferenceCount: referenceCount,
            integrityCount: integrityCount
        )
    }

    func preflightDerivedIndexesForCleanup(
        generation: String,
        replacementGeneration: String,
        expectedQueuedRevealIDs: Set<RevealID>
    ) async throws {
        guard ProgressionDeterminism.isDigest(generation),
              ProgressionDeterminism.isDigest(replacementGeneration),
              generation != replacementGeneration
        else {
            throw ProgressionDomainError.invalidRecord("derived-index-generation")
        }
        try await preflightSemanticIndex(
            generation: generation,
            replacementGeneration: replacementGeneration
        )
        try await preflightDistinctIndex(
            generation: generation,
            replacementGeneration: replacementGeneration
        )
        try await preflightRevealQueueIndex(
            generation: generation,
            expectedRevealIDs: expectedQueuedRevealIDs
        )
    }

    private func storedCommandReceipt(
        recordID: ModuleStateRecordID,
        generation: String
    ) async throws -> ProgressionCommandReceiptRecord? {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.commandCollection(generation),
            recordID: recordID
        ) else { return nil }
        return try await decodeDirectRecord(
            physical,
            category: .metadata,
            invalidLabel: "command-receipt-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let receipt = try ProgressionDeterminism.decoder().decode(
                ProgressionCommandReceiptRecord.self,
                from: physical.payload
            )
            try receipt.validate()
            let transactionID = ProgressionDeterminism.transactionUUID(
                "runtime-operation|\(receipt.operationIdentifier)|\(receipt.operationID)"
            )
            guard ProgressionRepositoryIDs.commandRecordID(transactionID) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("command-receipt-identity") }
            return receipt
        }
    }

    private func captureOrderCandidates(
        from sourceGeneration: String,
        to destinationGeneration: String,
        operationID: String
    ) async throws {
        let collection = ProgressionRepositoryIDs.eventOrderCollection(sourceGeneration)
        var cursor: ModuleStateScanCursor?
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            var restarted = false
            for physical in page.records {
                let order: ProgressionAppliedEventOrderRecord
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    order = try ProgressionDeterminism.decoder().decode(
                        ProgressionAppliedEventOrderRecord.self,
                        from: physical.payload
                    )
                    try order.validate()
                    guard ProgressionRepositoryIDs.eventOrderRecordID(order.appliedRevision) ==
                            physical.key.recordID
                    else { throw ProgressionDomainError.invalidRecord("applied-event-order") }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .processedEvent,
                        code: ProgressionRepositoryIDs.recordDecodeCode
                    )
                    cursor = nil
                    restarted = true
                    break
                }
                try await stageRecoveryEventCandidate(
                    ProgressionRecoveryEventCandidateRecord(
                        generation: destinationGeneration,
                            appliedRevision: order.appliedRevision,
                            envelope: order.envelope,
                            sourceCumulativeDigest: order.cumulativeDigest,
                            hasProcessedSource: false
                    ),
                    operationID: operationID,
                    sourceGeneration: sourceGeneration
                )
            }
            if restarted { continue }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else { return }
            cursor = try await refreshedCursor(next)
        }
    }

    private func captureProcessedCandidates(
        from sourceGeneration: String,
        to destinationGeneration: String,
        operationID: String
    ) async throws {
        let collection = ProgressionRepositoryIDs.eventCollection(sourceGeneration)
        var cursor: ModuleStateScanCursor?
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            var restarted = false
            for physical in page.records {
                let processed: ProcessedEventRecord
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    processed = try ProgressionDeterminism.decoder().decode(
                        ProcessedEventRecord.self,
                        from: physical.payload
                    )
                    try processed.validate()
                    guard ProgressionRepositoryIDs.eventRecordID(processed.eventID) ==
                            physical.key.recordID
                    else { throw ProgressionDomainError.invalidRecord("processed-event-identity") }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .processedEvent,
                        code: ProgressionRepositoryIDs.recordDecodeCode
                    )
                    cursor = nil
                    restarted = true
                    break
                }
                guard processed.outcome == .applied,
                      let appliedRevision = processed.appliedRevision
                else { continue }
                try await stageRecoveryEventCandidate(
                    ProgressionRecoveryEventCandidateRecord(
                        generation: destinationGeneration,
                        appliedRevision: appliedRevision,
                        envelope: processed.envelope,
                        sourceCumulativeDigest: nil,
                        hasProcessedSource: true
                    ),
                    operationID: operationID,
                    sourceGeneration: sourceGeneration
                )
            }
            if restarted { continue }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else { return }
            cursor = try await refreshedCursor(next)
        }
    }

    private func stageRecoveryEventCandidate(
        _ candidate: ProgressionRecoveryEventCandidateRecord,
        operationID: String,
        sourceGeneration _: String
    ) async throws {
        try candidate.validate()
        let collection = ProgressionRepositoryIDs.recoveryEventCollection(candidate.generation)
        let recordID = ProgressionRepositoryIDs.recoveryEventRecordID(
            candidate.appliedRevision
        )
        if let physical = try await client.fetch(collectionID: collection, recordID: recordID) {
            let existing: ProgressionRecoveryEventCandidateRecord = try await decodeDirectRecord(
                physical,
                category: .processedEvent,
                invalidLabel: "recovery-event-candidate-corrupt"
            ) {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let decoded = try ProgressionDeterminism.decoder().decode(
                    ProgressionRecoveryEventCandidateRecord.self,
                    from: physical.payload
                )
                try decoded.validate()
                guard decoded.generation == candidate.generation,
                      decoded.appliedRevision == candidate.appliedRevision,
                      ProgressionRepositoryIDs.recoveryEventRecordID(
                        decoded.appliedRevision
                      ) == physical.key.recordID
                else {
                    throw ProgressionDomainError.invalidRecord(
                        "recovery-event-candidate-identity"
                    )
                }
                return decoded
            }
            guard existing.generation == candidate.generation,
                  existing.appliedRevision == candidate.appliedRevision,
                  existing.sourceCumulativeDigest == nil ||
                    candidate.sourceCumulativeDigest == nil ||
                    existing.sourceCumulativeDigest == candidate.sourceCumulativeDigest
            else { throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue) }
            let merged: ProgressionRecoveryEventCandidateRecord
            if existing.eventID == candidate.eventID,
               existing.envelope == candidate.envelope,
               existing.envelopeDigest == candidate.envelopeDigest
            {
                merged = try ProgressionRecoveryEventCandidateRecord(
                    generation: candidate.generation,
                    appliedRevision: candidate.appliedRevision,
                    envelope: candidate.envelope,
                    sourceCumulativeDigest: existing.sourceCumulativeDigest ??
                        candidate.sourceCumulativeDigest,
                    hasProcessedSource: existing.hasProcessedSource ||
                        candidate.hasProcessedSource,
                    conflictingProcessedEnvelope: existing.conflictingProcessedEnvelope ??
                        candidate.conflictingProcessedEnvelope
                )
            } else if existing.conflictingProcessedEnvelope == candidate.envelope,
                      candidate.sourceCumulativeDigest == nil,
                      candidate.hasProcessedSource
            {
                return
            } else if existing.sourceCumulativeDigest != nil,
                      candidate.sourceCumulativeDigest == nil,
                      candidate.hasProcessedSource
            {
                merged = try ProgressionRecoveryEventCandidateRecord(
                    generation: candidate.generation,
                    appliedRevision: candidate.appliedRevision,
                    envelope: existing.envelope,
                    sourceCumulativeDigest: existing.sourceCumulativeDigest,
                    hasProcessedSource: true,
                    conflictingProcessedEnvelope: candidate.envelope
                )
            } else if candidate.sourceCumulativeDigest != nil,
                      existing.sourceCumulativeDigest == nil,
                      existing.hasProcessedSource
            {
                merged = try ProgressionRecoveryEventCandidateRecord(
                    generation: candidate.generation,
                    appliedRevision: candidate.appliedRevision,
                    envelope: candidate.envelope,
                    sourceCumulativeDigest: candidate.sourceCumulativeDigest,
                    hasProcessedSource: true,
                    conflictingProcessedEnvelope: existing.envelope
                )
            } else {
                throw ProgressionDomainError.recordIdentityCollision(recordID.rawValue)
            }
            guard merged != existing else { return }
            let mutation = ModuleStateMutation.upsert(ModuleStateUpsert(
                key: physical.key,
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(merged),
                expectedRevision: .exact(physical.revision)
            ))
            _ = try await client.transact(try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(
                    "recovery-event-candidate-merge|\(operationID)|\(candidate.generation)|\(candidate.appliedRevision)|\(candidate.hasProcessedSource ? "processed" : "order")"
                ),
                mutations: [mutation]
            ))
            return
        }
        let mutation = ModuleStateMutation.upsert(ModuleStateUpsert(
            key: ModuleStateRecordKey(collectionID: collection, recordID: recordID),
            schemaVersion: Self.namespaceSchemaVersion,
            payload: try encode(candidate),
            expectedRevision: .absent
        ))
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "recovery-event-candidate|\(operationID)|\(candidate.generation)|\(candidate.appliedRevision)"
            ),
            mutations: [mutation]
        ))
    }

    private func reconcileRecoveryEventCandidates(
        sourceGeneration: String,
        destinationGeneration: String,
        operationID: String
    ) async throws {
        let metadata = try await activeMetadataForDirectContext()
        guard metadata.activeGeneration == sourceGeneration else {
            throw ProgressionDomainError.invalidRecord("recovery-candidate-source")
        }

        var cursor: ModuleStateScanCursor?
        var paths = [ProgressionRecoveryCandidatePath(
            cumulativeDigest: nil,
            choices: [:]
        )]
        var count: UInt64 = 0
        var lastRevision: UInt64?
        repeat {
            let page = try await recoveryEventCandidatePage(
                generation: destinationGeneration,
                cursor: cursor
            )
            for candidate in page.records {
                guard lastRevision.map({ $0 < candidate.appliedRevision }) ?? true else {
                    throw ProgressionDomainError.invalidRecord(
                        "recovery-candidate-order"
                    )
                }
                let nextCount = count.addingReportingOverflow(1)
                guard !nextCount.overflow else {
                    throw ProgressionDomainError.invalidRecord(
                        "recovery-candidate-count"
                    )
                }
                count = nextCount.partialValue
                lastRevision = candidate.appliedRevision

                var expanded: [ProgressionRecoveryCandidatePath] = []
                for path in paths {
                    let orderDigest = recoveryCumulativeDigest(
                        prior: path.cumulativeDigest,
                        revision: candidate.appliedRevision,
                        envelope: candidate.envelope,
                        envelopeDigest: candidate.envelopeDigest
                    )
                    let orderMatchesCheckpoint = candidate.sourceCumulativeDigest == nil ||
                        candidate.sourceCumulativeDigest == orderDigest

                    if let processedEnvelope = candidate.conflictingProcessedEnvelope {
                        if orderMatchesCheckpoint {
                            var orderPath = path
                            orderPath.cumulativeDigest = orderDigest
                            orderPath.choices[candidate.appliedRevision] = .order
                            expanded.append(orderPath)
                        }
                        var processedPath = path
                        processedPath.cumulativeDigest = recoveryCumulativeDigest(
                            prior: path.cumulativeDigest,
                            revision: candidate.appliedRevision,
                            envelope: processedEnvelope,
                            envelopeDigest: try ProgressionDeterminism.encodedDigest(
                                processedEnvelope
                            )
                        )
                        processedPath.choices[candidate.appliedRevision] = .processed
                        expanded.append(processedPath)
                    } else if candidate.sourceCumulativeDigest != nil,
                              candidate.hasProcessedSource,
                              !orderMatchesCheckpoint
                    {
                        var processedPath = path
                        processedPath.cumulativeDigest = orderDigest
                        processedPath.choices[candidate.appliedRevision] = .processed
                        expanded.append(processedPath)
                    } else if orderMatchesCheckpoint {
                        var nextPath = path
                        nextPath.cumulativeDigest = orderDigest
                        expanded.append(nextPath)
                    }
                }
                guard !expanded.isEmpty,
                      expanded.count <= 16,
                      expanded.allSatisfy({ $0.choices.count <= 64 })
                else {
                    throw ProgressionDomainError.invalidRecord(
                        "recovery-candidate-ambiguity"
                    )
                }
                paths = expanded
            }
            cursor = try await refreshedCursor(page.next)
        } while cursor != nil

        guard count == metadata.appliedEventCount,
              lastRevision == metadata.lastAppliedRevision
        else {
            throw ProgressionDomainError.invalidRecord("recovery-candidate-count")
        }
        let anchoredPaths = paths.filter {
            $0.cumulativeDigest == metadata.appliedEventDigest
        }
        guard anchoredPaths.count == 1, let anchored = anchoredPaths.first else {
            throw ProgressionDomainError.invalidRecord(
                "recovery-candidate-ambiguous-anchor"
            )
        }

        cursor = nil
        repeat {
            let page = try await recoveryEventCandidatePage(
                generation: destinationGeneration,
                cursor: cursor
            )
            for candidate in page.records {
                guard let choice = anchored.choices[candidate.appliedRevision] else {
                    guard candidate.conflictingProcessedEnvelope == nil else {
                        throw ProgressionDomainError.invalidRecord(
                            "recovery-candidate-unresolved"
                        )
                    }
                    continue
                }
                let resolved: ProgressionRecoveryEventCandidateRecord
                switch choice {
                case .order:
                    guard let conflicting = candidate.conflictingProcessedEnvelope else {
                        throw ProgressionDomainError.invalidRecord(
                            "recovery-candidate-order-choice"
                        )
                    }
                    try await quarantineProcessedEvent(
                        eventID: conflicting.eventID,
                        generation: sourceGeneration
                    )
                    resolved = try ProgressionRecoveryEventCandidateRecord(
                        generation: destinationGeneration,
                        appliedRevision: candidate.appliedRevision,
                        envelope: candidate.envelope,
                        sourceCumulativeDigest: candidate.sourceCumulativeDigest,
                        hasProcessedSource: false
                    )
                case .processed:
                    try await quarantineAppliedEventOrder(
                        revision: candidate.appliedRevision,
                        generation: sourceGeneration
                    )
                    resolved = try ProgressionRecoveryEventCandidateRecord(
                        generation: destinationGeneration,
                        appliedRevision: candidate.appliedRevision,
                        envelope: candidate.conflictingProcessedEnvelope ??
                            candidate.envelope,
                        sourceCumulativeDigest: nil,
                        hasProcessedSource: true
                    )
                }
                try await replaceRecoveryEventCandidate(
                    resolved,
                    operationID: operationID
                )
            }
            cursor = try await refreshedCursor(page.next)
        } while cursor != nil
    }

    private func replaceRecoveryEventCandidate(
        _ candidate: ProgressionRecoveryEventCandidateRecord,
        operationID: String
    ) async throws {
        let collection = ProgressionRepositoryIDs.recoveryEventCollection(candidate.generation)
        let recordID = ProgressionRepositoryIDs.recoveryEventRecordID(
            candidate.appliedRevision
        )
        guard let physical = try await client.fetch(
            collectionID: collection,
            recordID: recordID
        ) else {
            throw ProgressionDomainError.invalidRecord("recovery-candidate-missing")
        }
        let existing = try ProgressionDeterminism.decoder().decode(
            ProgressionRecoveryEventCandidateRecord.self,
            from: physical.payload
        )
        try existing.validate()
        guard existing != candidate else { return }
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "recovery-candidate-resolve|\(operationID)|\(candidate.generation)|\(candidate.appliedRevision)"
            ),
            mutations: [.upsert(ModuleStateUpsert(
                key: physical.key,
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(candidate),
                expectedRevision: .exact(physical.revision)
            ))]
        ))
    }

    private func recoveryCumulativeDigest(
        prior: String?,
        revision: UInt64,
        envelope: DomainEventEnvelope,
        envelopeDigest: String
    ) -> String {
        ProgressionDeterminism.digest128(
            "\(prior ?? "genesis")|\(revision)|\(envelope.eventID.rawValue.uuidString.lowercased())|\(envelopeDigest)"
        )
    }

    private func orderLedgerIsComplete(generation: String) async throws -> Bool {
        let metadata = try await activeMetadataForDirectContext()
        guard metadata.activeGeneration == generation else {
            throw ProgressionDomainError.invalidRecord("order-ledger-generation")
        }
        let collection = ProgressionRepositoryIDs.eventOrderCollection(generation)
        var cursor: ModuleStateScanCursor?
        var count: UInt64 = 0
        var priorRevision: UInt64?
        var cumulativeDigest: String?
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            for physical in page.records {
                let order: ProgressionAppliedEventOrderRecord
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    order = try ProgressionDeterminism.decoder().decode(
                        ProgressionAppliedEventOrderRecord.self,
                        from: physical.payload
                    )
                    try order.validate()
                    guard ProgressionRepositoryIDs.eventOrderRecordID(
                        order.appliedRevision
                    ) == physical.key.recordID,
                    priorRevision.map({ $0 < order.appliedRevision }) ?? true
                    else {
                        throw ProgressionDomainError.invalidRecord("applied-event-order")
                    }
                    let expectedDigest = ProgressionDeterminism.digest128(
                        "\(cumulativeDigest ?? "genesis")|\(order.appliedRevision)|\(order.eventID.rawValue.uuidString.lowercased())|\(order.envelopeDigest)"
                    )
                    guard order.cumulativeDigest == expectedDigest else {
                        return false
                    }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .processedEvent,
                        code: ProgressionRepositoryIDs.recordReferenceCode
                    )
                    return false
                }
                let next = count.addingReportingOverflow(1)
                guard !next.overflow else {
                    throw ProgressionDomainError.invalidRecord("order-ledger-count")
                }
                count = next.partialValue
                priorRevision = order.appliedRevision
                cumulativeDigest = order.cumulativeDigest
            }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else {
                return count == metadata.appliedEventCount &&
                    priorRevision == metadata.lastAppliedRevision &&
                    cumulativeDigest == metadata.appliedEventDigest
            }
            cursor = next
        }
    }

    private func refreshedCursor(
        _ cursor: ModuleStateScanCursor?
    ) async throws -> ModuleStateScanCursor? {
        guard let cursor else { return nil }
        let health = try await client.health()
        return ModuleStateScanCursor(
            collectionID: cursor.collectionID,
            afterRecordID: cursor.afterRecordID,
            observedStoreRevision: health.storeRevision
        )
    }

    private func preflightRevealQueueIndex(
        generation: String,
        expectedRevealIDs: Set<RevealID>
    ) async throws {
        let collection = ProgressionRepositoryIDs.revealQueueCollection
        let prefix = "reveal.\(generation)."
        var cursor: ModuleStateScanCursor?
        var observed = Set<RevealID>()
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            var restarted = false
            for physical in page.records where physical.key.recordID.rawValue.hasPrefix(prefix) {
                let record: PendingRevealRecord
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    record = try ProgressionDeterminism.decoder().decode(
                        PendingRevealRecord.self,
                        from: physical.payload
                    )
                    try record.validate()
                    guard record.state != .acknowledged,
                          record.generation == generation,
                          ProgressionRepositoryIDs.queuedRevealRecordID(record) ==
                            physical.key.recordID
                    else {
                        throw ProgressionDomainError.invalidRecord(
                            "queued-reveal-identity"
                        )
                    }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .pendingReveal,
                        code: ProgressionRepositoryIDs.recordDecodeCode
                    )
                    cursor = nil
                    observed.removeAll(keepingCapacity: true)
                    restarted = true
                    break
                }
                guard expectedRevealIDs.contains(record.revealID),
                      observed.insert(record.revealID).inserted
                else {
                    try await quarantineInvalid(
                        physical,
                        category: .pendingReveal,
                        code: ProgressionRepositoryIDs.recordReferenceCode
                    )
                    cursor = nil
                    observed.removeAll(keepingCapacity: true)
                    restarted = true
                    break
                }
            }
            if restarted { continue }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else {
                guard observed == expectedRevealIDs else {
                    throw ProgressionDomainError.invalidRecord("queued-reveal-index")
                }
                return
            }
            cursor = try await refreshedCursor(next)
        }
    }

    private func preflightSemanticIndex(
        generation: String,
        replacementGeneration: String
    ) async throws {
        let collection = ProgressionRepositoryIDs.semanticCollection(generation)
        var cursor: ModuleStateScanCursor?
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            var restarted = false
            for physical in page.records {
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    let record = try ProgressionDeterminism.decoder().decode(
                        ProgressionSemanticDedupeRecord.self,
                        from: physical.payload
                    )
                    try record.validate()
                    guard ProgressionRepositoryIDs.semanticRecordID(record.digest) ==
                            physical.key.recordID,
                          try await semanticRecord(
                            record.digest,
                            generation: replacementGeneration
                          ) == record
                    else {
                        throw ProgressionDomainError.invalidRecord(
                            "semantic-record-reference"
                        )
                    }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .processedEvent,
                        code: ProgressionRepositoryIDs.recordReferenceCode
                    )
                    cursor = nil
                    restarted = true
                    break
                }
            }
            if restarted { continue }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else { return }
            cursor = next
        }
    }

    private func recoveryDirectIndexAudit(
        metadata: ProgressionMetadataRecord,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionDirectRecoveryAudit {
        let generation = metadata.activeGeneration
        let processed = try await scanRecoveryAudit(
            collection: ProgressionRepositoryIDs.eventCollection(generation),
            category: .processedEvent,
            initial: ProgressionProcessedRecoveryAudit()
        ) { result, physical in
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                ProcessedEventRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard ProgressionRepositoryIDs.eventRecordID(record.eventID) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("processed-event-identity") }
            switch record.outcome {
            case .applied:
                try incrementRecoveryCount(&result.appliedCount)
            case .duplicate, .ignoredIneligible, .rejectedPermanent:
                try incrementRecoveryCount(&result.terminalCount)
                result.terminalDigest = ProgressionDeterminism.xorDigest(
                    result.terminalDigest,
                    with: try ProgressionDeterminism.encodedIntegrityDigest(record)
                )
            }
        }
        let orderCount = try await scanRecoveryAudit(
            collection: ProgressionRepositoryIDs.eventOrderCollection(generation),
            category: .processedEvent,
            initial: UInt64(0)
        ) { result, physical in
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                ProgressionAppliedEventOrderRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard ProgressionRepositoryIDs.eventOrderRecordID(record.appliedRevision) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("applied-event-order-identity") }
            try incrementRecoveryCount(&result)
        }
        let semanticCount = try await scanRecoveryAudit(
            collection: ProgressionRepositoryIDs.semanticCollection(generation),
            category: .processedEvent,
            initial: UInt64(0)
        ) { result, physical in
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                ProgressionSemanticDedupeRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard ProgressionRepositoryIDs.semanticRecordID(record.digest) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("semantic-record-identity") }
            try incrementRecoveryCount(&result)
        }
        let distinctPrefix = "distinct.\(generation)."
        let distinctCount = try await scanRecoveryAudit(
            collection: ProgressionRepositoryIDs.distinctCollection,
            category: .distinctToken,
            initial: UInt64(0)
        ) { result, physical in
            guard physical.key.recordID.rawValue.hasPrefix(distinctPrefix) else { return }
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                DistinctTokenRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard record.generation == generation,
                  ProgressionRepositoryIDs.distinctTokenRecordID(record) == physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("distinct-token-identity") }
            try incrementRecoveryCount(&result)
        }
        let acknowledgement = try await scanRecoveryAudit(
            collection: ProgressionRepositoryIDs.revealAcknowledgementCollection(generation),
            category: .pendingReveal,
            invalidCode: ProgressionRepositoryIDs.recordReferenceCode,
            initial: ProgressionDigestCountAudit()
        ) { result, physical in
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                PendingRevealRecord.self,
                from: physical.payload
            )
            try record.validate()
            guard record.state == .acknowledged,
                  record.generation == generation,
                  ProgressionRepositoryIDs.acknowledgedRevealRecordID(record.revealID) ==
                    physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("acknowledged-reveal-identity") }
            try incrementRecoveryCount(&result.count)
            result.digest = ProgressionDeterminism.xorDigest(
                result.digest,
                with: try ProgressionDeterminism.canonicalAcknowledgementDigest(record)
            )
        }
        let commands = try await scanRecoveryAudit(
            collection: ProgressionRepositoryIDs.commandCollection(generation),
            category: .metadata,
            initial: ProgressionDigestCountAudit()
        ) { result, physical in
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let record = try ProgressionDeterminism.decoder().decode(
                ProgressionCommandReceiptRecord.self,
                from: physical.payload
            )
            try record.validate()
            let transactionID = ProgressionDeterminism.transactionUUID(
                "runtime-operation|\(record.operationIdentifier)|\(record.operationID)"
            )
            guard ProgressionRepositoryIDs.commandRecordID(transactionID) ==
                    physical.key.recordID,
                  record.resultRevision <= metadata.revision,
                  record.cleanupGeneration != generation,
                  !commandReceiptRequiresCleanup(record.operationIdentifier) ||
                    record.cleanupGeneration != nil
            else { throw ProgressionDomainError.invalidRecord("command-receipt-identity") }
            try incrementRecoveryCount(&result.count)
            result.digest = ProgressionDeterminism.xorDigest(
                result.digest,
                with: try ProgressionDeterminism.encodedIntegrityDigest(record)
            )
        }
        return ProgressionDirectRecoveryAudit(
            processed: processed,
            orderCount: orderCount,
            semanticCount: semanticCount,
            distinctCount: distinctCount,
            acknowledgementCount: acknowledgement.count,
            acknowledgementDigest: acknowledgement.digest,
            commandCount: commands.count,
            commandDigest: commands.digest
        )
    }

    private func recoverableLoggedQuarantineCount(
        metadata: ProgressionMetadataRecord,
        queuedRevealIDs: Set<RevealID>
    ) async throws -> UInt64 {
        let generation = metadata.activeGeneration
        let semanticCollection = ProgressionRepositoryIDs.semanticCollection(generation)
        let candidateCollection = ProgressionRepositoryIDs.recoveryEventCollection(generation)
        let scratchCollections: Set<ModuleStateCollectionID>
        if let marker = try? await rebuildStageMarker(),
           marker.value.sourceGeneration == generation,
           marker.value.sourceRevision <= metadata.revision,
           marker.value.destinationGeneration != generation
        {
            let destination = marker.value.destinationGeneration
            scratchCollections = [
                ProgressionRepositoryIDs.eventCollection(destination),
                ProgressionRepositoryIDs.eventOrderCollection(destination),
                ProgressionRepositoryIDs.semanticCollection(destination),
                ProgressionRepositoryIDs.recoveryEventCollection(destination),
                ProgressionRepositoryIDs.revealAcknowledgementCollection(destination),
                ProgressionRepositoryIDs.commandCollection(destination),
            ]
        } else {
            scratchCollections = []
        }
        let expectedRevealDigests = Set(queuedRevealIDs.map { revealID in
            ProgressionDeterminism.digest128(
                "\(ProgressionRepositoryIDs.revealQueueCollection.rawValue)|\(ProgressionRepositoryIDs.queuedRevealRecordID(revealID, generation: generation).rawValue)"
            )
        })
        var cursor: ModuleStateScanCursor?
        var count: UInt64 = 0
        repeat {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: ProgressionRepositoryIDs.quarantineCollection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            for physical in page.records {
                guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                    throw ProgressionDomainError.unsupportedRecordSchema(
                        UInt16(clamping: physical.schemaVersion)
                    )
                }
                let record = try ProgressionDeterminism.decoder().decode(
                    QuarantineRecord.self,
                    from: physical.payload
                )
                try record.validate()
                guard ProgressionRepositoryIDs.quarantineRecordID(record) ==
                        physical.key.recordID
                else { throw ProgressionDomainError.invalidRecord("quarantine-identity") }
                let isReplayDerived = record.sourceCollectionID == semanticCollection ||
                    record.sourceCollectionID == candidateCollection ||
                    scratchCollections.contains(record.sourceCollectionID) ||
                    (record.sourceCollectionID == ProgressionRepositoryIDs.distinctCollection &&
                        record.category == .distinctToken) ||
                    (record.sourceCollectionID ==
                        ProgressionRepositoryIDs.revealQueueCollection &&
                        record.category == .pendingReveal &&
                        !expectedRevealDigests.contains(record.sourceRecordDigest))
                guard isReplayDerived else { continue }
                let next = count.addingReportingOverflow(1)
                guard !next.overflow else {
                    throw ProgressionDomainError.invalidRecord(
                        "recovery-quarantine-count"
                    )
                }
                count = next.partialValue
            }
            try validateCursor(
                page.nextCursor,
                prior: cursor,
                collection: ProgressionRepositoryIDs.quarantineCollection
            )
            cursor = page.nextCursor
        } while cursor != nil
        return count
    }

    private func scanRecoveryAudit<Result>(
        collection: ModuleStateCollectionID,
        category: ProgressionDiagnosticRecordCategory,
        invalidCode: ProgressionRejectionCode = ProgressionRepositoryIDs.recordDecodeCode,
        initial: Result,
        consume: (inout Result, ModuleStateRecord) async throws -> Void
    ) async throws -> Result {
        var cursor: ModuleStateScanCursor?
        var result = initial
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            var restarted = false
            for physical in page.records {
                do {
                    try await consume(&result, physical)
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: category,
                        code: invalidCode
                    )
                    result = initial
                    cursor = nil
                    restarted = true
                    break
                }
            }
            if restarted { continue }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else { return result }
            cursor = next
        }
    }

    private func incrementRecoveryCount(_ count: inout UInt64) throws {
        let (next, overflow) = count.addingReportingOverflow(1)
        guard !overflow else {
            throw ProgressionDomainError.invalidRecord("recovery-direct-index-count")
        }
        count = next
    }

    private func positiveDeficit(_ expected: UInt64, _ actual: UInt64) -> UInt64 {
        expected > actual ? expected - actual : 0
    }

    private func preflightDistinctIndex(
        generation: String,
        replacementGeneration: String
    ) async throws {
        let collection = ProgressionRepositoryIDs.distinctCollection
        let prefix = "distinct.\(generation)."
        var cursor: ModuleStateScanCursor?
        while true {
            let page = try await client.scan(try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            ))
            var restarted = false
            for physical in page.records where physical.key.recordID.rawValue.hasPrefix(prefix) {
                do {
                    guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                        throw ProgressionDomainError.unsupportedRecordSchema(
                            UInt16(clamping: physical.schemaVersion)
                        )
                    }
                    let record = try ProgressionDeterminism.decoder().decode(
                        DistinctTokenRecord.self,
                        from: physical.payload
                    )
                    try record.validate()
                    let replacement = DistinctTokenRecord(
                        generation: replacementGeneration,
                        statisticID: record.statisticID,
                        bucketID: record.bucketID,
                        canonicalToken: record.canonicalToken,
                        firstAppliedRevision: record.firstAppliedRevision
                    )
                    guard record.generation == generation,
                          ProgressionRepositoryIDs.distinctTokenRecordID(record) ==
                            physical.key.recordID,
                          try await distinctToken(replacement) == replacement
                    else {
                        throw ProgressionDomainError.invalidRecord(
                            "distinct-token-reference"
                        )
                    }
                } catch {
                    try await quarantineInvalid(
                        physical,
                        category: .distinctToken,
                        code: ProgressionRepositoryIDs.recordReferenceCode
                    )
                    cursor = nil
                    restarted = true
                    break
                }
            }
            if restarted { continue }
            try validateCursor(page.nextCursor, prior: cursor, collection: collection)
            guard let next = page.nextCursor else { return }
            cursor = next
        }
    }

    private func validateTerminalProcessedRecord(
        _ record: ProcessedEventRecord,
        generation: String,
        semanticGeneration: String? = nil,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws {
        try record.validate()
        switch record.outcome {
        case .applied:
            throw ProgressionDomainError.invalidRecord("terminal-event-applied")
        case .duplicate:
            guard case let .accepted(event) = ProgressionEventValidator.validate(
                record.envelope,
                bundle: bundle
            ), record.semanticDigest == event.semanticDigest,
            let semantic = try await semanticRecord(
                event.semanticDigest,
                generation: semanticGeneration ?? generation
            ), semantic.canonicalMaterial == event.semanticMaterial,
            semantic.firstEventID != record.eventID
            else {
                throw ProgressionDomainError.invalidRecord(
                    "terminal-duplicate-semantics"
                )
            }
        case .ignoredIneligible:
            guard case .ignored = ProgressionEventValidator.validate(
                record.envelope,
                bundle: bundle
            ), record.semanticDigest == nil
            else {
                throw ProgressionDomainError.invalidRecord("terminal-ignored-semantics")
            }
        case .rejectedPermanent:
            let validation = ProgressionEventValidator.validate(
                record.envelope,
                bundle: bundle
            )
            let isCatalogRejection: Bool
            if case let .rejected(code) = validation {
                isCatalogRejection = record.rejectionCode == code &&
                    record.semanticDigest == nil
            } else {
                isCatalogRejection = false
            }
            let isSemanticCollision: Bool
            if case let .accepted(event) = validation,
               record.rejectionCode == ProgressionEventValidator.semanticCollision,
               record.semanticDigest == event.semanticDigest,
               let semantic = try await semanticRecord(
                   event.semanticDigest,
                   generation: semanticGeneration ?? generation
               )
            {
                isSemanticCollision = semantic.canonicalMaterial != event.semanticMaterial
            } else {
                isSemanticCollision = false
            }
            guard isCatalogRejection || isSemanticCollision else {
                throw ProgressionDomainError.invalidRecord("terminal-rejection-semantics")
            }
        }
    }

    func validateActiveAppliedLedger(
        _ projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws {
        let metadata = projection.metadata
        let generation = metadata.activeGeneration
        var cursor: ModuleStateScanCursor?
        var count: UInt64 = 0
        var priorRevision: UInt64?
        var cumulativeDigest: String?

        repeat {
            let page = try await appliedEventOrderPage(
                generation: generation,
                cursor: cursor
            )
            for order in page.records {
                guard priorRevision.map({ $0 < order.appliedRevision }) ?? true else {
                    try await quarantineAppliedEventOrder(
                        revision: order.appliedRevision,
                        generation: generation
                    )
                    throw ProgressionDomainError.invalidRecord("active-ledger-order")
                }
                guard case .accepted = ProgressionEventValidator.validate(
                    order.envelope,
                    bundle: bundle
                ) else {
                    try await quarantineAppliedEventOrder(
                        revision: order.appliedRevision,
                        generation: generation
                    )
                    throw ProgressionDomainError.invalidRecord("active-ledger-event")
                }
                let expectedDigest = ProgressionDeterminism.digest128(
                    "\(cumulativeDigest ?? "genesis")|\(order.appliedRevision)|\(order.eventID.rawValue.uuidString.lowercased())|\(order.envelopeDigest)"
                )
                guard order.cumulativeDigest == expectedDigest else {
                    try await quarantineAppliedEventOrder(
                        revision: order.appliedRevision,
                        generation: generation
                    )
                    throw ProgressionDomainError.invalidRecord("active-ledger-digest")
                }
                let next = count.addingReportingOverflow(1)
                guard !next.overflow else {
                    throw ProgressionDomainError.invalidRecord("active-ledger-count")
                }
                count = next.partialValue
                priorRevision = order.appliedRevision
                cumulativeDigest = order.cumulativeDigest
            }
            cursor = page.next
        } while cursor != nil

        guard count == metadata.appliedEventCount,
              priorRevision == metadata.lastAppliedRevision,
              cumulativeDigest == metadata.appliedEventDigest
        else { throw ProgressionDomainError.invalidRecord("active-ledger-completeness") }

        cursor = nil
        repeat {
            let page = try await appliedEventOrderPage(
                generation: generation,
                cursor: cursor
            )
            for order in page.records {
                guard case let .accepted(event) = ProgressionEventValidator.validate(
                    order.envelope,
                    bundle: bundle
                ) else {
                    throw ProgressionDomainError.invalidRecord("active-ledger-event")
                }
                let expectedProcessed = ProcessedEventRecord(
                    envelope: event.envelope,
                    envelopeDigest: event.envelopeDigest,
                    semanticDigest: event.semanticDigest,
                    outcome: .applied,
                    transactionID: GrantTransactionID(
                        rawValue: "transaction.\(event.envelope.eventID.rawValue.uuidString.lowercased())"
                    ),
                    appliedRevision: order.appliedRevision
                )
                guard let processed = try await processedEvent(
                    order.eventID,
                    generation: generation
                ) else {
                    throw ProgressionDomainError.invalidRecord("active-ledger-processed-missing")
                }
                guard processed == expectedProcessed else {
                    try await quarantineProcessedEvent(
                        eventID: order.eventID,
                        generation: generation
                    )
                    throw ProgressionDomainError.invalidRecord("active-ledger-processed")
                }
                let expectedSemantic = ProgressionSemanticDedupeRecord(
                    canonicalMaterial: event.semanticMaterial,
                    firstEventID: event.envelope.eventID
                )
                guard try await semanticRecord(
                    expectedSemantic.digest,
                    generation: generation
                ) == expectedSemantic else {
                    try await quarantineSemanticRecord(
                        digest: expectedSemantic.digest,
                        generation: generation
                    )
                    throw ProgressionDomainError.invalidRecord("active-ledger-semantic")
                }
            }
            cursor = page.next
        } while cursor != nil

        var processedCount: UInt64 = 0
        var appliedProcessedCount: UInt64 = 0
        var terminalProcessedDigest: String?
        var processedCursor: ModuleStateScanCursor?
        repeat {
            let page = try await processedEventPage(
                generation: generation,
                cursor: processedCursor
            )
            for record in page.records {
                switch record.outcome {
                case .applied:
                    guard case let .accepted(event) = ProgressionEventValidator.validate(
                        record.envelope,
                        bundle: bundle
                    ), record.semanticDigest == event.semanticDigest
                    else {
                        try await quarantineProcessedEvent(
                            eventID: record.eventID,
                            generation: generation
                        )
                        throw ProgressionDomainError.invalidRecord(
                            "active-ledger-applied-semantics"
                        )
                    }
                case .duplicate, .ignoredIneligible, .rejectedPermanent:
                    do {
                        try await validateTerminalProcessedRecord(
                            record,
                            generation: generation,
                            bundle: bundle
                        )
                    } catch {
                        try await quarantineProcessedEvent(
                            eventID: record.eventID,
                            generation: generation
                        )
                        throw error
                    }
                    terminalProcessedDigest = ProgressionDeterminism.xorDigest(
                        terminalProcessedDigest,
                        with: try ProgressionDeterminism.encodedIntegrityDigest(record)
                    )
                }
                let nextProcessed = processedCount.addingReportingOverflow(1)
                guard !nextProcessed.overflow else {
                    throw ProgressionDomainError.invalidRecord("active-ledger-count")
                }
                processedCount = nextProcessed.partialValue
                if record.outcome == .applied {
                    let nextApplied = appliedProcessedCount.addingReportingOverflow(1)
                    guard !nextApplied.overflow else {
                        throw ProgressionDomainError.invalidRecord("active-ledger-count")
                    }
                    appliedProcessedCount = nextApplied.partialValue
                }
            }
            processedCursor = page.next
        } while processedCursor != nil
        guard processedCount == metadata.processedEventCount,
              appliedProcessedCount == metadata.appliedEventCount,
              terminalProcessedDigest == metadata.terminalProcessedEventDigest
        else { throw ProgressionDomainError.invalidRecord("active-ledger-processed-count") }
    }

    private func validateStoredProjectionForUpgrade(
        _ projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws {
        let migrations = projection.logicalRecords().compactMap {
            logical -> CatalogMigrationRecord? in
            guard case let .catalogMigration(record) = logical else { return nil }
            return record
        }
        guard migrations.count == 1 else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.catalogMigration],
                label: "upgrade-migration-baseline"
            )
        }
        let priorKeys = Set(migrations[0].compatibilityFingerprints.map(\.stableKey))
        let catalog = bundle.catalog
        let priorStatisticIDs = Set(priorKeys.compactMap { key -> StatisticID? in
            guard key.hasPrefix("statistic:") else { return nil }
            return StatisticID(rawValue: String(key.dropFirst("statistic:".count)))
        })
        let priorAchievementIDs = Set(priorKeys.compactMap { key -> AchievementID? in
            guard key.hasPrefix("achievement:") else { return nil }
            return AchievementID(rawValue: String(key.dropFirst("achievement:".count)))
        })
        let priorContentIDs = Set(priorKeys.compactMap { key -> ProgressionContentID? in
            guard key.hasPrefix("content:") else { return nil }
            return ProgressionContentID(rawValue: String(key.dropFirst("content:".count)))
        })
        let priorCodexIDs = Set(priorContentIDs.compactMap { contentID -> CodexID? in
            guard catalog.content(id: contentID)?.kind == .codex else { return nil }
            return CodexID(rawValue: contentID.rawValue)
        })

        var counters: [String: StatisticCounterRecord] = [:]
        var contentUses: [String: StatisticContentUseRecord] = [:]
        var progress: [AchievementID: AchievementProgressRecord] = [:]
        var completions = Set<AchievementID>()
        var milestones = Set<RuleID>()
        var grants: [String: GrantRecord] = [:]
        var ownership: [ProgressionContentID: OwnershipRecord] = [:]
        var entitlements: [UnlockID: ProgressionEntitlementRecord] = [:]

        for logical in projection.logicalRecords() {
            switch logical {
            case let .statisticCounter(record):
                guard priorStatisticIDs.contains(record.statisticID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "upgrade-statistic-reference"
                    )
                }
                counters[logical.identity] = record
            case let .statisticContentUse(record):
                guard priorStatisticIDs.contains(record.statisticID),
                      record.contentIDs.allSatisfy(priorContentIDs.contains)
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "upgrade-content-use-reference"
                    )
                }
                contentUses[logical.identity] = record
            case let .achievementProgress(record):
                guard priorAchievementIDs.contains(record.achievementID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.achievementProgress],
                        label: "upgrade-achievement-progress-reference"
                    )
                }
                progress[record.achievementID] = record
            case let .achievementCompletion(record):
                guard priorAchievementIDs.contains(record.achievementID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.achievementCompletion],
                        label: "upgrade-achievement-completion-reference"
                    )
                }
                completions.insert(record.achievementID)
            case let .milestoneCompletion(record):
                guard priorKeys.contains("milestone:\(record.ruleID.rawValue)") else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.milestoneCompletion],
                        label: "upgrade-milestone-reference"
                    )
                }
                milestones.insert(record.ruleID)
            case let .grant(record):
                guard priorKeys.contains(
                    "grant-item:\(record.grantGroupID.rawValue):\(record.contentID.rawValue)"
                ) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant],
                        label: "upgrade-grant-reference"
                    )
                }
                grants[logical.identity] = record
            case let .ownership(record):
                guard priorContentIDs.contains(record.contentID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.ownership],
                        label: "upgrade-ownership-reference"
                    )
                }
                ownership[record.contentID] = record
            case let .entitlement(record):
                guard priorContentIDs.contains(record.contentID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.entitlement],
                        label: "upgrade-entitlement-reference"
                    )
                }
                entitlements[record.entitlementID] = record
            case .encounter, .titleSelection, .revealQueueState, .catalogMigration,
                 .existingUserMigration:
                continue
            }
        }

        for (grantKey, grant) in grants {
            guard ownership[grant.contentID]?.sourceGrantKeys.contains(grantKey) == true else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.grant, .ownership],
                    label: "upgrade-grant-ownership-link"
                )
            }
            switch grant.source {
            case .migration:
                break
            case let .achievement(id):
                guard completions.contains(id) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .achievementCompletion],
                        label: "upgrade-grant-achievement-link"
                    )
                }
            case let .milestone(id):
                guard milestones.contains(id) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .milestoneCompletion],
                        label: "upgrade-grant-milestone-link"
                    )
                }
            }
        }
        for (contentID, record) in ownership {
            guard record.sourceGrantKeys.allSatisfy({ grants[$0]?.contentID == contentID }) else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.ownership, .grant],
                    label: "upgrade-ownership-grant-link"
                )
            }
        }
        for entitlement in entitlements.values {
            guard ownership[entitlement.contentID] != nil else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.entitlement, .ownership],
                    label: "upgrade-entitlement-ownership-link"
                )
            }
        }
        for achievementID in completions {
            guard let groupID = catalog.achievement(id: achievementID)?.rewardGrantGroupID else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.achievementCompletion],
                    label: "upgrade-achievement-reward-reference"
                )
            }
            let prefix = "grant-item:\(groupID.rawValue):"
            for key in priorKeys where key.hasPrefix(prefix) {
                let rawContentID = String(key.dropFirst(prefix.count))
                let grantKey = "grant|\(groupID.rawValue)|\(rawContentID)|achievement.\(achievementID.rawValue)"
                guard grants[grantKey] != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.achievementCompletion, .grant],
                        label: "upgrade-achievement-reward-incomplete"
                    )
                }
            }
        }
        for ruleID in milestones {
            guard let groupID = catalog.milestone(id: ruleID)?.grantGroupID else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.milestoneCompletion],
                    label: "upgrade-milestone-reward-reference"
                )
            }
            let prefix = "grant-item:\(groupID.rawValue):"
            for key in priorKeys where key.hasPrefix(prefix) {
                let rawContentID = String(key.dropFirst(prefix.count))
                let grantKey = "grant|\(groupID.rawValue)|\(rawContentID)|milestone.\(ruleID.rawValue)"
                guard grants[grantKey] != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.milestoneCompletion, .grant],
                        label: "upgrade-milestone-reward-incomplete"
                    )
                }
            }
        }

        for statisticID in priorStatisticIDs {
            guard let statistic = catalog.statistic(id: statisticID) else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.statisticCounter],
                    label: "upgrade-statistic-definition"
                )
            }
            switch statistic.storage {
            case .bucketedDistinctSet:
                for codexID in priorCodexIDs {
                    guard counters[
                        "counter|\(statisticID.rawValue)|\(codexID.rawValue)"
                    ] != nil else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.statisticCounter],
                            label: "upgrade-counter-baseline"
                        )
                    }
                }
            case .distinctSet, .derived:
                guard counters["counter|\(statisticID.rawValue)|-"] != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "upgrade-counter-baseline"
                    )
                }
            }
            if statistic.storage == .derived {
                let expected: UInt64
                switch statistic.dimension {
                case .contentID:
                    expected = UInt64(ownership.keys.filter {
                        catalog.content(id: $0)?.countsAsArtifact == true
                    }.count)
                case .achievementID:
                    expected = UInt64(completions.count)
                default:
                    expected = 0
                }
                guard counters["counter|\(statisticID.rawValue)|-"]?.value == expected else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "upgrade-derived-counter-value"
                    )
                }
            }
        }
        for (identity, use) in contentUses {
            let counterID = identity.replacingOccurrences(of: "content-use|", with: "counter|")
            guard counters[counterID]?.value == UInt64(use.contentIDs.count) else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.statisticCounter],
                    label: "upgrade-content-use-count"
                )
            }
        }
        for achievementID in priorAchievementIDs {
            guard let definition = catalog.achievement(id: achievementID),
                  let record = progress[achievementID]
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.achievementProgress],
                    label: "upgrade-achievement-progress-missing"
                )
            }
            let expected: UInt64
            if completions.contains(achievementID) {
                expected = record.target
            } else if definition.progress.statisticID.rawValue ==
                "stat.achievement.completed-count"
            {
                let excluded = Set(definition.progress.excludeAchievementIDs ?? [])
                expected = min(UInt64(completions.subtracting(excluded).count), record.target)
            } else {
                expected = min(
                    counters["counter|\(definition.progress.statisticID.rawValue)|-"]?.value ?? 0,
                    record.target
                )
            }
            guard record.target == UInt64(definition.progress.target),
                  record.current == expected
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.achievementProgress],
                    label: "upgrade-achievement-progress-value"
                )
            }
        }
    }

    func validateHistoricalReplayExactness(
        from stored: ProgressionProjection,
        to replayed: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws {
        do {
            let migrations: [CatalogMigrationRecord] = stored.logicalRecords().compactMap {
                logical in
                guard case let .catalogMigration(value) = logical else { return nil }
                return value
            }
            guard migrations.count == 1 else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.catalogMigration],
                    label: "upgrade-replay-migration"
                )
            }
            let migration = migrations[0]
            let priorKeys = Set(migration.compatibilityFingerprints.map { $0.stableKey })
            let priorAchievementIDs = Set(priorKeys.compactMap { key -> AchievementID? in
                guard key.hasPrefix("achievement:") else { return nil }
                return AchievementID(rawValue: String(key.dropFirst("achievement:".count)))
            })
            let priorStatisticIDs = Set(priorKeys.compactMap { key -> StatisticID? in
                guard key.hasPrefix("statistic:") else { return nil }
                return StatisticID(rawValue: String(key.dropFirst("statistic:".count)))
            })
            let priorRuleIDs = Set(priorKeys.compactMap { key -> RuleID? in
                guard key.hasPrefix("milestone:") else { return nil }
                return RuleID(rawValue: String(key.dropFirst("milestone:".count)))
            })
            let priorContentIDs = Set(priorKeys.compactMap {
                key -> ProgressionContentID? in
                guard key.hasPrefix("content:") else { return nil }
                return ProgressionContentID(rawValue: String(key.dropFirst("content:".count)))
            })
            let priorGrantItems = Set(priorKeys.filter { $0.hasPrefix("grant-item:") })

            func requireEquivalent(
                _ logical: ProgressionLogicalRecord,
                categories: Set<ProgressionDiagnosticRecordCategory>,
                label: String
            ) throws {
                guard let current = replayed.records[logical.identity],
                      try ProgressionProjectionComparison.hasEquivalentLogicalRecord(
                        logical,
                        current
                      )
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: categories,
                        label: label
                    )
                }
            }

            for logical in stored.logicalRecords() {
                switch logical {
                case let .statisticCounter(record):
                    guard let definition = bundle.catalog.statistic(
                        id: record.statisticID
                    ) else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.statisticCounter],
                            label: "upgrade-replay-statistic-reference"
                        )
                    }
                    if definition.storage != .derived {
                        try requireEquivalent(
                            logical,
                            categories: [.statisticCounter],
                            label: "upgrade-replay-statistic-value"
                        )
                    }
                case .statisticContentUse:
                    try requireEquivalent(
                        logical,
                        categories: [.statisticCounter],
                        label: "upgrade-replay-content-use"
                    )
                case let .achievementProgress(record):
                    guard let achievement = bundle.catalog.achievement(
                        id: record.achievementID
                    ), let statistic = bundle.catalog.statistic(
                        id: achievement.progress.statisticID
                    ) else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.achievementProgress],
                            label: "upgrade-replay-progress-reference"
                        )
                    }
                    if statistic.storage != .derived {
                        try requireEquivalent(
                            logical,
                            categories: [.achievementProgress],
                            label: "upgrade-replay-progress-value"
                        )
                    }
                case .achievementCompletion:
                    try requireEquivalent(
                        logical,
                        categories: [.achievementCompletion],
                        label: "upgrade-replay-achievement-completion"
                    )
                case .milestoneCompletion:
                    try requireEquivalent(
                        logical,
                        categories: [.milestoneCompletion],
                        label: "upgrade-replay-milestone-completion"
                    )
                case .grant:
                    try requireEquivalent(
                        logical,
                        categories: [.grant],
                        label: "upgrade-replay-grant"
                    )
                case .ownership:
                    try requireEquivalent(
                        logical,
                        categories: [.ownership],
                        label: "upgrade-replay-ownership"
                    )
                case .entitlement:
                    try requireEquivalent(
                        logical,
                        categories: [.entitlement],
                        label: "upgrade-replay-entitlement"
                    )
                case .encounter:
                    try requireEquivalent(
                        logical,
                        categories: [.encounter],
                        label: "upgrade-replay-encounter"
                    )
                case .titleSelection:
                    try requireEquivalent(
                        logical,
                        categories: [.titleSelection],
                        label: "upgrade-replay-title"
                    )
                case .revealQueueState:
                    try requireEquivalent(
                        logical,
                        categories: [.pendingReveal],
                        label: "upgrade-replay-reveal-queue"
                    )
                case .catalogMigration:
                    continue
                case .existingUserMigration:
                    try requireEquivalent(
                        logical,
                        categories: [.catalogMigration],
                        label: "upgrade-replay-existing-user-migration"
                    )
                }
            }

            for logical in replayed.logicalRecords() where stored.records[logical.identity] == nil {
                let isPriorIdentity: Bool
                let categories: Set<ProgressionDiagnosticRecordCategory>
                switch logical {
                case let .statisticContentUse(record):
                    isPriorIdentity = priorStatisticIDs.contains(record.statisticID)
                    categories = [.statisticCounter]
                case let .achievementCompletion(record):
                    isPriorIdentity = priorAchievementIDs.contains(record.achievementID)
                    categories = [.achievementCompletion]
                case let .milestoneCompletion(record):
                    isPriorIdentity = priorRuleIDs.contains(record.ruleID)
                    categories = [.milestoneCompletion]
                case let .grant(record):
                    let itemKey = "grant-item:\(record.grantGroupID.rawValue):\(record.contentID.rawValue)"
                    let priorSource: Bool = switch record.source {
                    case .migration: true
                    case let .achievement(id): priorAchievementIDs.contains(id)
                    case let .milestone(id): priorRuleIDs.contains(id)
                    }
                    isPriorIdentity = priorGrantItems.contains(itemKey) && priorSource
                    categories = [.grant]
                case let .ownership(record):
                    isPriorIdentity = priorContentIDs.contains(record.contentID)
                    categories = [.ownership]
                case let .entitlement(record):
                    isPriorIdentity = priorContentIDs.contains(record.contentID)
                    categories = [.entitlement]
                case let .encounter(record):
                    if let contentID = ProgressionContentID(
                        rawValue: record.codexID.rawValue
                    ) {
                        isPriorIdentity = priorContentIDs.contains(contentID)
                    } else {
                        isPriorIdentity = false
                    }
                    categories = [.encounter]
                default:
                    isPriorIdentity = false
                    categories = []
                }
                guard !isPriorIdentity else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: categories,
                        label: "upgrade-replay-missing-prior-fact"
                    )
                }
            }
        } catch {
            try await quarantineActiveProjection(stored, error: error)
            throw error
        }
    }

    private func validateProjectionLedgerProvenance(
        _ projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws {
        let generation = projection.metadata.activeGeneration
        let existingUserMigrations = projection.records(matching: {
            logical -> ExistingUserMigrationRecord? in
            guard case let .existingUserMigration(record) = logical else { return nil }
            return record
        })
        guard existingUserMigrations.count <= 1 else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.catalogMigration],
                label: "existing-user-migration-provenance"
            )
        }
        let existingUserMigration = existingUserMigrations.first
        var achievementCompletions: [AchievementID: AchievementCompletionRecord] = [:]
        var milestoneCompletions: [RuleID: MilestoneCompletionRecord] = [:]
        for logical in projection.logicalRecords() {
            switch logical {
            case let .achievementCompletion(record):
                achievementCompletions[record.achievementID] = record
                if let sourceEventID = record.sourceEventID {
                    guard let processed = try await processedEvent(
                        sourceEventID,
                        generation: generation
                    ), processed.outcome == .applied,
                       let appliedRevision = processed.appliedRevision,
                       let order = try await appliedEventOrderRecord(
                        appliedRevision,
                        generation: generation
                       ), order.eventID == processed.eventID,
                       order.envelope == processed.envelope,
                       order.envelopeDigest == processed.envelopeDigest,
                       appliedRevision <= (projection.metadata.lastAppliedRevision ?? 0),
                       appliedRevision != projection.metadata.lastAppliedRevision ||
                        order.cumulativeDigest == projection.metadata.appliedEventDigest,
                       processed.envelope.occurredAt == record.completedAt,
                       case .accepted = ProgressionEventValidator.validate(
                        processed.envelope,
                        bundle: bundle
                       )
                    else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.achievementCompletion],
                            label: "achievement-completion-provenance"
                        )
                    }
                } else {
                    guard let migration = existingUserMigration,
                          record.sourceExistingUserMigrationTransactionID ==
                            migration.transactionID,
                          record.completedAt == migration.completedAt,
                          (record.achievementID.rawValue == "achievement.archivist-1" ||
                            record.achievementID.rawValue == "achievement.archivist-2")
                    else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.achievementCompletion, .catalogMigration],
                            label: "achievement-migration-provenance"
                        )
                    }
                }
            case let .milestoneCompletion(record):
                milestoneCompletions[record.ruleID] = record
                guard let processed = try await processedEvent(
                    record.sourceEventID,
                    generation: generation
                ), processed.outcome == .applied,
                   let appliedRevision = processed.appliedRevision,
                   let order = try await appliedEventOrderRecord(
                    appliedRevision,
                    generation: generation
                   ), order.eventID == processed.eventID,
                   order.envelope == processed.envelope,
                   order.envelopeDigest == processed.envelopeDigest,
                   appliedRevision <= (projection.metadata.lastAppliedRevision ?? 0),
                   appliedRevision != projection.metadata.lastAppliedRevision ||
                    order.cumulativeDigest == projection.metadata.appliedEventDigest,
                   processed.envelope.occurredAt == record.completedAt,
                   case .accepted = ProgressionEventValidator.validate(
                    processed.envelope,
                    bundle: bundle
                   )
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.milestoneCompletion],
                        label: "milestone-completion-provenance"
                    )
                }
            default:
                continue
            }
        }

        for logical in projection.logicalRecords() {
            guard case let .grant(record) = logical else { continue }
            let expectedTransactionID: GrantTransactionID
            let expectedGrantedAt: Date
            switch record.source {
            case .migration:
                continue
            case let .achievement(achievementID):
                guard let completion = achievementCompletions[achievementID] else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .achievementCompletion],
                        label: "achievement-grant-provenance"
                    )
                }
                if let sourceEventID = completion.sourceEventID {
                    expectedTransactionID = GrantTransactionID(
                        rawValue: "transaction.\(sourceEventID.rawValue.uuidString.lowercased())"
                    )!
                } else if let migration = existingUserMigration,
                          completion.sourceExistingUserMigrationTransactionID ==
                            migration.transactionID
                {
                    expectedTransactionID = migration.grantTransactionID
                } else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .achievementCompletion, .catalogMigration],
                        label: "achievement-grant-migration-provenance"
                    )
                }
                expectedGrantedAt = completion.completedAt
            case let .milestone(ruleID):
                guard let completion = milestoneCompletions[ruleID] else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .milestoneCompletion],
                        label: "milestone-grant-provenance"
                    )
                }
                expectedTransactionID = GrantTransactionID(
                    rawValue: "transaction.\(completion.sourceEventID.rawValue.uuidString.lowercased())"
                )!
                expectedGrantedAt = completion.completedAt
            }
            guard record.transactionID == expectedTransactionID,
                  record.grantedAt == expectedGrantedAt
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.grant],
                    label: "grant-event-provenance"
                )
            }
        }
    }

    private func quarantineSemanticRecord(
        digest: String,
        generation: String
    ) async throws {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.semanticCollection(generation),
            recordID: ProgressionRepositoryIDs.semanticRecordID(digest)
        ) else { return }
        try await quarantineInvalid(
            physical,
            category: .processedEvent,
            code: ProgressionRepositoryIDs.recordReferenceCode
        )
    }

    private func validateProjection(
        _ projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws {
        let catalog = bundle.catalog
        let codexIDs = Set(catalog.content.compactMap { definition -> CodexID? in
            guard definition.kind == .codex else { return nil }
            return CodexID(rawValue: definition.contentID.rawValue)
        })
        var counters: [String: StatisticCounterRecord] = [:]
        var contentUses: [String: StatisticContentUseRecord] = [:]
        var progress: [AchievementID: AchievementProgressRecord] = [:]
        var completions = Set<AchievementID>()
        var milestones = Set<RuleID>()
        var grants: [String: GrantRecord] = [:]
        var ownership: [ProgressionContentID: OwnershipRecord] = [:]
        var entitlements: [UnlockID: ProgressionEntitlementRecord] = [:]
        var titleSelection: TitleSelectionRecord?
        var queueState: ProgressionRevealQueueStateRecord?
        var migrations: [CatalogMigrationRecord] = []
        var existingUserMigrations: [ExistingUserMigrationRecord] = []

        for logical in projection.logicalRecords() {
            switch logical {
            case let .statisticCounter(record):
                guard let definition = catalog.statistic(id: record.statisticID),
                      (definition.storage == .bucketedDistinctSet) == (record.bucketID != nil),
                      record.bucketID.map(codexIDs.contains) ?? true
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "statistic-reference"
                    )
                }
                counters[logical.identity] = record
            case let .statisticContentUse(record):
                guard let definition = catalog.statistic(id: record.statisticID),
                      definition.storage != .derived,
                      (definition.storage == .bucketedDistinctSet) == (record.bucketID != nil),
                      record.bucketID.map(codexIDs.contains) ?? true
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "content-use-reference"
                    )
                }
                for contentID in record.contentIDs {
                    guard let content = catalog.content(id: contentID) else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.statisticCounter],
                            label: "content-use-unknown-content"
                        )
                    }
                    switch definition.dimension {
                    case .artifactID:
                        guard content.countsAsArtifact else {
                            throw ProgressionProjectionIntegrityIssue(
                                categories: [.statisticCounter],
                                label: "content-use-artifact"
                            )
                        }
                    case .codexID:
                        guard content.kind == .codex else {
                            throw ProgressionProjectionIntegrityIssue(
                                categories: [.statisticCounter],
                                label: "content-use-codex"
                            )
                        }
                    case .contentID:
                        break
                    case .achievementID, .cipherToken, .messageToken, .packageToken,
                         .relationshipToken:
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.statisticCounter],
                            label: "content-use-dimension"
                        )
                    }
                }
                contentUses[logical.identity] = record
            case let .achievementProgress(record):
                guard let definition = catalog.achievement(id: record.achievementID),
                      record.target == UInt64(definition.progress.target),
                      progress[record.achievementID] == nil
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.achievementProgress],
                        label: "achievement-progress-reference"
                    )
                }
                progress[record.achievementID] = record
            case let .achievementCompletion(record):
                guard catalog.achievement(id: record.achievementID) != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.achievementCompletion],
                        label: "achievement-completion-reference"
                    )
                }
                completions.insert(record.achievementID)
            case let .milestoneCompletion(record):
                guard catalog.milestone(id: record.ruleID) != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.milestoneCompletion],
                        label: "milestone-completion-reference"
                    )
                }
                milestones.insert(record.ruleID)
            case let .grant(record):
                guard let group = catalog.grantGroup(id: record.grantGroupID),
                      group.items.contains(where: { $0.contentID == record.contentID }),
                      catalog.content(id: record.contentID) != nil
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant],
                        label: "grant-reference"
                    )
                }
                switch record.source {
                case let .migration(version):
                    guard version == catalog.migration.migrationVersion,
                          record.grantGroupID == catalog.migration.startingGrantGroupID
                    else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.grant],
                            label: "migration-grant-reference"
                        )
                    }
                case let .achievement(achievementID):
                    guard catalog.achievement(id: achievementID)?.rewardGrantGroupID ==
                            record.grantGroupID
                    else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.grant],
                            label: "achievement-grant-reference"
                        )
                    }
                case let .milestone(ruleID):
                    guard catalog.milestone(id: ruleID)?.grantGroupID == record.grantGroupID
                    else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.grant],
                            label: "milestone-grant-reference"
                        )
                    }
                }
                grants[logical.identity] = record
            case let .ownership(record):
                guard catalog.content(id: record.contentID) != nil,
                      ownership[record.contentID] == nil
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.ownership],
                        label: "ownership-reference"
                    )
                }
                ownership[record.contentID] = record
            case let .entitlement(record):
                guard let definition = catalog.content(id: record.contentID),
                      definition.kind == .entitlement,
                      record.entitlementID.rawValue == record.contentID.rawValue,
                      entitlements[record.entitlementID] == nil,
                      (definition.availability == .included) == (record.source == .included)
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.entitlement],
                        label: "entitlement-reference"
                    )
                }
                entitlements[record.entitlementID] = record
            case let .encounter(record):
                guard codexIDs.contains(record.codexID),
                      record.artifactIDs.allSatisfy({ artifactID in
                          guard let contentID = ProgressionContentID(rawValue: artifactID.rawValue)
                          else { return false }
                          return catalog.content(id: contentID)?.countsAsArtifact == true
                      })
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.encounter],
                        label: "encounter-reference"
                    )
                }
            case let .titleSelection(record):
                guard titleSelection == nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.titleSelection],
                        label: "title-selection-duplicate"
                    )
                }
                titleSelection = record
            case let .revealQueueState(record):
                guard queueState == nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.pendingReveal],
                        label: "reveal-queue-state-duplicate"
                    )
                }
                queueState = record
            case let .catalogMigration(record):
                migrations.append(record)
            case let .existingUserMigration(record):
                existingUserMigrations.append(record)
            }
        }

        guard progress.count == catalog.achievements.count else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.achievementProgress],
                label: "projection-baseline-progress"
            )
        }
        guard titleSelection != nil else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.titleSelection],
                label: "projection-baseline-title"
            )
        }
        guard queueState != nil else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.pendingReveal],
                label: "projection-baseline-reveal"
            )
        }
        guard migrations.count == 1,
              migrations[0].migrationVersion == catalog.migration.migrationVersion,
              migrations[0].catalogVersion == catalog.catalogVersion,
              migrations[0].completedAt != nil,
              migrations[0].compatibilityFingerprints ==
                (try ProgressionCatalogCompatibility.fingerprints(for: bundle))
        else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.catalogMigration],
                label: "projection-baseline-migration"
            )
        }
        guard projection.metadata.initializedAt != nil else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.metadata],
                label: "projection-baseline-metadata"
            )
        }
        guard existingUserMigrations.count <= 1 else {
            throw ProgressionProjectionIntegrityIssue(
                categories: [.catalogMigration],
                label: "existing-user-migration-duplicate"
            )
        }
        if let existingUserMigration = existingUserMigrations.first {
            let cipherStatisticIdentity =
                "counter|stat.cipher.created-or-imported.unique|-"
            guard counters[cipherStatisticIdentity]?.value ?? 0 >=
                    UInt64(existingUserMigration.cipherCount)
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.catalogMigration, .statisticCounter],
                    label: "existing-user-migration-counter"
                )
            }
            let permitted = Set([
                AchievementID(rawValue: "achievement.archivist-1")!,
                AchievementID(rawValue: "achievement.archivist-2")!,
            ])
            let seededCompletions = projection.records(matching: {
                logical -> AchievementCompletionRecord? in
                guard case let .achievementCompletion(record) = logical,
                      record.sourceExistingUserMigrationTransactionID != nil
                else { return nil }
                return record
            })
            var expectedSeededCompletions = Set<AchievementID>()
            if existingUserMigration.cipherCount >= 5 {
                expectedSeededCompletions.insert(
                    AchievementID(rawValue: "achievement.archivist-1")!
                )
            }
            if existingUserMigration.cipherCount >= 20 {
                expectedSeededCompletions.insert(
                    AchievementID(rawValue: "achievement.archivist-2")!
                )
            }
            guard Set(seededCompletions.map(\.achievementID)) ==
                    expectedSeededCompletions,
                  seededCompletions.allSatisfy({
                permitted.contains($0.achievementID) &&
                    $0.sourceExistingUserMigrationTransactionID ==
                        existingUserMigration.transactionID &&
                    $0.completedAt == existingUserMigration.completedAt
            }) else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.catalogMigration, .achievementCompletion],
                    label: "existing-user-migration-completion"
                )
            }
        }

        for statistic in catalog.statistics {
            switch statistic.storage {
            case .bucketedDistinctSet:
                for codexID in codexIDs {
                    guard counters["counter|\(statistic.statisticID.rawValue)|\(codexID.rawValue)"] != nil
                    else {
                        throw ProgressionProjectionIntegrityIssue(
                            categories: [.statisticCounter],
                            label: "counter-baseline"
                        )
                    }
                }
            case .distinctSet, .derived:
                guard counters["counter|\(statistic.statisticID.rawValue)|-"] != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "counter-baseline"
                    )
                }
            }
            if statistic.storage == .derived {
                let expected: UInt64
                switch statistic.dimension {
                case .contentID:
                    expected = UInt64(ownership.keys.filter {
                        catalog.content(id: $0)?.countsAsArtifact == true
                    }.count)
                case .achievementID:
                    expected = UInt64(completions.count)
                default:
                    expected = 0
                }
                guard counters[
                    "counter|\(statistic.statisticID.rawValue)|-"
                ]?.value == expected else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.statisticCounter],
                        label: "derived-counter-value"
                    )
                }
            }
        }
        for achievement in catalog.achievements {
            guard let record = progress[achievement.achievementID] else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.achievementProgress],
                    label: "achievement-progress-missing"
                )
            }
            let expected: UInt64
            if completions.contains(achievement.achievementID) {
                expected = record.target
            } else if achievement.progress.statisticID.rawValue ==
                "stat.achievement.completed-count"
            {
                let excluded = Set(achievement.progress.excludeAchievementIDs ?? [])
                expected = min(
                    UInt64(completions.subtracting(excluded).count),
                    record.target
                )
            } else {
                expected = min(
                    counters[
                        "counter|\(achievement.progress.statisticID.rawValue)|-"
                    ]?.value ?? 0,
                    record.target
                )
            }
            guard record.current == expected else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.achievementProgress],
                    label: "achievement-progress-value"
                )
            }
        }
        for (identity, use) in contentUses {
            let counterID = identity.replacingOccurrences(of: "content-use|", with: "counter|")
            guard counters[counterID]?.value == UInt64(use.contentIDs.count) else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.statisticCounter],
                    label: "content-use-count"
                )
            }
        }
        for (grantKey, grant) in grants {
            guard ownership[grant.contentID]?.sourceGrantKeys.contains(grantKey) == true else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.grant, .ownership],
                    label: "grant-ownership-link"
                )
            }
            switch grant.source {
            case .migration:
                break
            case let .achievement(achievementID):
                guard completions.contains(achievementID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .achievementCompletion],
                        label: "grant-without-achievement"
                    )
                }
            case let .milestone(ruleID):
                guard milestones.contains(ruleID) else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.grant, .milestoneCompletion],
                        label: "grant-without-milestone"
                    )
                }
            }
        }
        for achievementID in completions {
            guard let achievement = catalog.achievement(id: achievementID),
                  let group = catalog.grantGroup(id: achievement.rewardGrantGroupID)
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.achievementCompletion],
                    label: "achievement-reward-reference"
                )
            }
            for item in group.items {
                let key = "grant|\(group.grantGroupID.rawValue)|\(item.contentID.rawValue)|achievement.\(achievementID.rawValue)"
                guard grants[key] != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.achievementCompletion, .grant],
                        label: "achievement-reward-incomplete"
                    )
                }
            }
        }
        for ruleID in milestones {
            guard let milestone = catalog.milestone(id: ruleID),
                  let group = catalog.grantGroup(id: milestone.grantGroupID)
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.milestoneCompletion],
                    label: "milestone-reward-reference"
                )
            }
            for item in group.items {
                let key = "grant|\(group.grantGroupID.rawValue)|\(item.contentID.rawValue)|milestone.\(ruleID.rawValue)"
                guard grants[key] != nil else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.milestoneCompletion, .grant],
                        label: "milestone-reward-incomplete"
                    )
                }
            }
        }
        for (contentID, record) in ownership {
            guard record.sourceGrantKeys.allSatisfy({ grants[$0]?.contentID == contentID }) else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.ownership, .grant],
                    label: "ownership-grant-link"
                )
            }
            if catalog.content(id: contentID)?.kind == .entitlement {
                guard let entitlementID = UnlockID(rawValue: contentID.rawValue),
                      entitlements[entitlementID]?.contentID == contentID
                else {
                    throw ProgressionProjectionIntegrityIssue(
                        categories: [.ownership, .entitlement],
                        label: "ownership-entitlement-link"
                    )
                }
            }
        }
        for entitlement in entitlements.values {
            guard ownership[entitlement.contentID] != nil else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.entitlement, .ownership],
                    label: "entitlement-ownership-link"
                )
            }
        }
        if let selectedTitleID = titleSelection?.selectedTitleID {
            guard let contentID = ProgressionContentID(rawValue: selectedTitleID.rawValue),
                  catalog.content(id: contentID)?.kind == .title,
                  ownership[contentID] != nil
            else {
                throw ProgressionProjectionIntegrityIssue(
                    categories: [.titleSelection],
                    label: "selected-title-reference"
                )
            }
        }
    }

    private func validateStagedRevealQueue(
        projection: ProgressionProjection,
        reveals: [PendingRevealRecord]
    ) throws {
        let state = try revealQueueState(in: projection)
        guard UInt16(exactly: reveals.count) == state.pendingCount,
              Set(reveals.map(\.revealID)).count == reveals.count
        else { throw ProgressionDomainError.invalidRecord("rebuild-reveal-count") }
        let indexed = Dictionary(uniqueKeysWithValues: reveals.map { ($0.revealID, $0) })
        if state.pendingCount == 0 {
            guard indexed.isEmpty else {
                throw ProgressionDomainError.invalidRecord("rebuild-reveal-empty")
            }
            return
        }
        guard var currentID = state.headRevealID else {
            throw ProgressionDomainError.invalidRecord("rebuild-reveal-head")
        }
        var visited = Set<RevealID>()
        while true {
            guard visited.insert(currentID).inserted,
                  let record = indexed[currentID],
                  record.state != .acknowledged,
                  record.generation == projection.metadata.activeGeneration
            else { throw ProgressionDomainError.invalidRecord("rebuild-reveal-chain") }
            if let next = record.nextRevealID {
                currentID = next
            } else {
                guard currentID == state.tailRevealID,
                      visited.count == indexed.count
                else { throw ProgressionDomainError.invalidRecord("rebuild-reveal-tail") }
                return
            }
        }
    }

    private func resumeCatalogUpgradeCleanupIfNeeded(
        _ state: ProgressionRepositoryState,
        bundle: ValidatedProgressionCatalogBundle
    ) async throws -> ProgressionRepositoryState {
        let migrations = state.projection.logicalRecords().compactMap {
            logical -> CatalogMigrationRecord? in
            guard case let .catalogMigration(value) = logical else { return nil }
            return value
        }
        guard migrations.count == 1,
              let priorGeneration = migrations[0].priorGeneration,
              migrations[0].cleanupCompletedAt == nil,
              let completedAt = migrations[0].completedAt
        else { return state }
        let operationID = "catalog-upgrade-resume.\(migrations[0].transactionID.uuidString.lowercased())"
        try await cleanupRecoveryEventCandidates(
            generation: state.projection.metadata.activeGeneration,
            operationID: operationID
        )
        try await cleanupInactiveGeneration(
            priorGeneration,
            activeGeneration: state.projection.metadata.activeGeneration,
            operationID: operationID
        )
        return try await completeCatalogUpgradeCleanup(
            state,
            completedAt: completedAt,
            operationID: operationID,
            bundle: bundle
        )
    }

    private func recoveryShard(
        category: ProgressionDiagnosticRecordCategory,
        metadata: ProgressionMetadataRecord
    ) async throws -> ProgressionLocatedRecord<ProgressionProjectionShard> {
        let recordID = ProgressionRepositoryIDs.shardRecordID(
            generation: metadata.activeGeneration,
            category: category,
            shardIndex: 0
        )
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.projectionCollection,
            recordID: recordID
        ) else { throw ProgressionDomainError.invalidRecord("recovery-shard-missing") }
        return try await decodeDirectRecord(
            physical,
            category: category,
            invalidLabel: "recovery-shard-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let decoded = try ProgressionDeterminism.decoder().decode(
                ProgressionProjectionShard.self,
                from: physical.payload
            )
            try decoded.validate()
            guard decoded.generation == metadata.activeGeneration,
                  decoded.category == category,
                  decoded.shardIndex == 0,
                  ProgressionRepositoryIDs.shardRecordID(decoded) == physical.key.recordID
            else { throw ProgressionDomainError.invalidRecord("recovery-shard-identity") }
            return ProgressionLocatedRecord(
                value: decoded,
                physical: physicalRecord(physical)
            )
        }
    }

    private func validateActiveRevealQueue(
        _ state: ProgressionRevealQueueStateRecord,
        generation: String,
        validationRecords: [String: ProgressionLogicalRecord],
        bundle: ValidatedProgressionCatalogBundle,
        validateReferences: Bool = true
    ) async throws -> [ProgressionLocatedRecord<PendingRevealRecord>] {
        guard state.pendingCount > 0 else { return [] }
        guard var currentID = state.headRevealID else {
            throw ProgressionDomainError.invalidRecord("reveal-queue-head")
        }
        var visited = Set<RevealID>()
        var records: [ProgressionLocatedRecord<PendingRevealRecord>] = []
        for index in 0 ..< Int(state.pendingCount) {
            guard visited.insert(currentID).inserted,
                  let located = try await queuedReveal(currentID, generation: generation)
            else { throw ProgressionDomainError.invalidRecord("reveal-queue-chain") }
            if validateReferences {
                do {
                    try await validateQueuedRevealReferences(
                        located.value,
                        validationRecords: validationRecords,
                        bundle: bundle
                    )
                } catch {
                    try await quarantineQueuedRevealReference(located)
                    throw ProgressionQueuedRevealReferenceError(
                        label: "queued-reveal-reference"
                    )
                }
            }
            if let acknowledged = try await acknowledgedReveal(
                located.value.revealID,
                generation: generation
            ) {
                if validateReferences {
                    do {
                        try await validateQueuedRevealReferences(
                            acknowledged.value,
                            validationRecords: validationRecords,
                            bundle: bundle
                        )
                    } catch {
                        try await quarantineQueuedRevealReference(acknowledged)
                        throw ProgressionAcknowledgedRevealReferenceError(
                            label: "acknowledged-reveal-reference"
                        )
                    }
                }
                try await quarantineQueuedRevealReference(located)
                throw ProgressionQueuedRevealReferenceError(
                    label: "queued-reveal-already-acknowledged"
                )
            }
            records.append(located)
            if index == Int(state.pendingCount) - 1 {
                guard located.value.nextRevealID == nil,
                      located.value.revealID == state.tailRevealID
                else { throw ProgressionDomainError.invalidRecord("reveal-queue-tail") }
            } else {
                guard let next = located.value.nextRevealID else {
                    throw ProgressionDomainError.invalidRecord("reveal-queue-short")
                }
                currentID = next
            }
        }
        guard visited.count == Int(state.pendingCount) else {
            throw ProgressionDomainError.invalidRecord("reveal-queue-count")
        }
        return records
    }

    private func validateQueuedRevealReferences(
        _ reveal: PendingRevealRecord,
        validationRecords: [String: ProgressionLogicalRecord],
        bundle: ValidatedProgressionCatalogBundle,
        metadataOverride: ProgressionMetadataRecord? = nil,
        ledgerGenerationOverride: String? = nil
    ) async throws {
        let contentIDs = [reveal.primaryContentID] + reveal.secondaryContentIDs
        let achievementSources = Set(reveal.sourceAchievementIDs.map {
            ProgressionGrantSource.achievement($0)
        })
        let milestoneSources = Set(reveal.sourceRuleIDs.map {
            ProgressionGrantSource.milestone($0)
        })
        let revealSources = achievementSources.union(milestoneSources)
        guard !revealSources.isEmpty else {
            throw ProgressionDomainError.invalidRecord("queued-reveal-source-empty")
        }

        var sourceEventIDs = Set<EventID>()
        var sourceMigrationTransactionIDs = Set<UUID>()

        for achievementID in reveal.sourceAchievementIDs {
            guard bundle.catalog.achievement(id: achievementID) != nil,
                  case let .achievementCompletion(completion)? = validationRecords[
                    "achievement-completion|\(achievementID.rawValue)"
                  ]
            else { throw ProgressionDomainError.invalidRecord("queued-reveal-achievement") }
            if let sourceEventID = completion.sourceEventID {
                sourceEventIDs.insert(sourceEventID)
            } else if let transactionID =
                completion.sourceExistingUserMigrationTransactionID
            {
                sourceMigrationTransactionIDs.insert(transactionID)
            } else {
                throw ProgressionDomainError.invalidRecord(
                    "queued-reveal-achievement-provenance"
                )
            }
        }
        for ruleID in reveal.sourceRuleIDs {
            guard bundle.catalog.milestone(id: ruleID) != nil,
                  case let .milestoneCompletion(completion)? = validationRecords[
                    "milestone-completion|\(ruleID.rawValue)"
                  ]
            else { throw ProgressionDomainError.invalidRecord("queued-reveal-rule") }
            sourceEventIDs.insert(completion.sourceEventID)
        }

        let grants = validationRecords.values.compactMap { logical -> GrantRecord? in
            guard case let .grant(record) = logical else { return nil }
            return record
        }
        var matchedSources = Set<ProgressionGrantSource>()
        var maximumTierRank = 0
        var primaryTierRanks = Set<Int>()
        for contentID in contentIDs {
            guard let content = bundle.catalog.content(id: contentID),
                  content.availability != .included,
                  case let .ownership(ownership)? = validationRecords[
                    "ownership|\(contentID.rawValue)"
                  ],
                  ownership.contentID == contentID
            else { throw ProgressionDomainError.invalidRecord("queued-reveal-content") }

            let matching = grants.filter { grant in
                grant.contentID == contentID &&
                    revealSources.contains(grant.source) &&
                    ownership.sourceGrantKeys.contains(
                        ProgressionLogicalRecord.grant(grant).identity
                    )
            }
            guard !matching.isEmpty else {
                throw ProgressionDomainError.invalidRecord("queued-reveal-grant")
            }
            for grant in matching {
                guard let group = bundle.catalog.grantGroup(id: grant.grantGroupID),
                      group.items.contains(where: { $0.contentID == contentID })
                else { throw ProgressionDomainError.invalidRecord("queued-reveal-grant-group") }
                matchedSources.insert(grant.source)
                let rank = revealTierRank(group.revealTier)
                maximumTierRank = max(maximumTierRank, rank)
                if contentID == reveal.primaryContentID { primaryTierRanks.insert(rank) }
            }
        }
        let storedTierRank = revealTierRank(reveal.tier)
        guard matchedSources == revealSources,
              maximumTierRank == storedTierRank,
              primaryTierRanks.contains(storedTierRank)
        else { throw ProgressionDomainError.invalidRecord("queued-reveal-tier-source") }

        let metadata: ProgressionMetadataRecord
        if let metadataOverride {
            metadata = metadataOverride
        } else {
            metadata = try await activeMetadataForDirectContext()
        }
        if reveal.revealID.rawValue.hasPrefix("reveal.migration.") {
            let components = reveal.revealID.rawValue.split(separator: ".")
            let migrations = validationRecords.values.compactMap {
                logical -> ExistingUserMigrationRecord? in
                guard case let .existingUserMigration(record) = logical else { return nil }
                return record
            }
            guard components.count == 4,
                  components[0] == "reveal",
                  components[1] == "migration",
                  components[2] == "1",
                  UUID(uuidString: String(components[3])) != nil,
                  migrations.count == 1,
                  sourceEventIDs.isEmpty,
                  sourceMigrationTransactionIDs == Set([migrations[0].transactionID]),
                  reveal.revealID.rawValue ==
                    "reveal.migration.1.\(migrations[0].transactionID.uuidString.lowercased())",
                  reveal.transactionID == migrations[0].grantTransactionID,
                  reveal.createdAt == migrations[0].completedAt,
                  reveal.createdRevision > 0,
                  reveal.createdRevision <= metadata.revision,
                  migrations[0].revealBundle ==
                    CatalogMigrationRecord.UpgradeRevealBundle(reveal: reveal),
                  grants.filter({ revealSources.contains($0.source) }).allSatisfy({ grant in
                      grant.transactionID == reveal.transactionID &&
                        grant.grantedAt == reveal.createdAt
                  })
            else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-reveal-provenance"
                )
            }
        } else if reveal.revealID.rawValue.hasPrefix("reveal.upgrade.") {
            let components = reveal.revealID.rawValue.split(separator: ".")
            guard components.count == 4,
                  components[0] == "reveal",
                  components[1] == "upgrade",
                  let fromVersion = UInt64(components[2]),
                  let toVersion = UInt64(components[3]),
                  fromVersion > 0,
                  fromVersion < toVersion,
                  toVersion == bundle.catalog.catalogVersion.rawValue
            else { throw ProgressionDomainError.invalidRecord("upgrade-reveal-identity") }
            let migrations = validationRecords.values.compactMap {
                logical -> CatalogMigrationRecord? in
                guard case let .catalogMigration(record) = logical else { return nil }
                return record
            }
            guard migrations.count == 1,
                  migrations[0].catalogVersion == bundle.catalog.catalogVersion,
                  migrations[0].priorCatalogVersion?.rawValue == fromVersion,
                  migrations[0].upgradeRevealBundle ==
                    CatalogMigrationRecord.UpgradeRevealBundle(reveal: reveal),
                  let completedAt = migrations[0].completedAt,
                  reveal.createdAt == completedAt,
                  reveal.transactionID == GrantTransactionID(
                    rawValue: "transaction.\(migrations[0].transactionID.uuidString.lowercased())"
                  ),
                  reveal.createdRevision > 0,
                  reveal.createdRevision <= metadata.revision
            else { throw ProgressionDomainError.invalidRecord("upgrade-reveal-provenance") }
        } else {
            guard sourceMigrationTransactionIDs.isEmpty,
                  sourceEventIDs.count == 1,
                  let eventID = sourceEventIDs.first,
                  reveal.revealID.rawValue ==
                    "reveal.\(eventID.rawValue.uuidString.lowercased())",
                  reveal.transactionID == GrantTransactionID(
                    rawValue: "transaction.\(eventID.rawValue.uuidString.lowercased())"
                  ),
                  let processed = try await processedEvent(
                    eventID,
                    generation: ledgerGenerationOverride ?? reveal.generation
                  ), processed.outcome == .applied,
                  let appliedRevision = processed.appliedRevision,
                  appliedRevision == reveal.createdRevision,
                  appliedRevision <= (metadata.lastAppliedRevision ?? 0),
                  processed.envelope.occurredAt == reveal.createdAt,
                  let order = try await appliedEventOrderRecord(
                    appliedRevision,
                    generation: ledgerGenerationOverride ?? reveal.generation
                  ), order.eventID == eventID,
                  order.envelope == processed.envelope,
                  order.envelopeDigest == processed.envelopeDigest,
                  appliedRevision != metadata.lastAppliedRevision ||
                    order.cumulativeDigest == metadata.appliedEventDigest
            else { throw ProgressionDomainError.invalidRecord("queued-reveal-provenance") }
            guard grants.filter({ revealSources.contains($0.source) }).allSatisfy({ grant in
                grant.transactionID == reveal.transactionID && grant.grantedAt == reveal.createdAt
            }) else {
                throw ProgressionDomainError.invalidRecord("queued-reveal-grant-provenance")
            }
            let canonicalBundle = try canonicalEventRevealBundle(
                eventID: eventID,
                transactionID: reveal.transactionID,
                createdAt: reveal.createdAt,
                validationRecords: validationRecords,
                bundle: bundle
            )
            guard canonicalBundle == CatalogMigrationRecord.UpgradeRevealBundle(
                reveal: reveal
            ) else {
                throw ProgressionDomainError.invalidRecord(
                    "queued-reveal-candidate-set"
                )
            }
        }
    }

    private func canonicalEventRevealBundle(
        eventID: EventID,
        transactionID: GrantTransactionID,
        createdAt: Date,
        validationRecords: [String: ProgressionLogicalRecord],
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> CatalogMigrationRecord.UpgradeRevealBundle {
        var candidates: [ProgressionContentID: ProgressionCanonicalRevealCandidate] = [:]
        let upgradeContentIDs = Set(validationRecords.values.flatMap {
            logical -> [ProgressionContentID] in
            guard case let .catalogMigration(migration) = logical,
                  let upgrade = migration.upgradeRevealBundle
            else { return [] }
            return [upgrade.primaryContentID] + upgrade.secondaryContentIDs
        })
        let grants = validationRecords.values.compactMap { logical -> GrantRecord? in
            guard case let .grant(record) = logical else { return nil }
            return record
        }.sorted {
            ProgressionLogicalRecord.grant($0).identity <
                ProgressionLogicalRecord.grant($1).identity
        }
        for grant in grants {
            guard grant.transactionID == transactionID,
                  grant.grantedAt == createdAt,
                  completionEventID(for: grant.source, in: validationRecords) == eventID,
                  !upgradeContentIDs.contains(grant.contentID),
                  let content = bundle.catalog.content(id: grant.contentID),
                  content.availability != .included,
                  let group = bundle.catalog.grantGroup(id: grant.grantGroupID),
                  group.items.contains(where: { $0.contentID == grant.contentID }),
                  group.revealTier != .none,
                  case let .ownership(ownership)? = validationRecords[
                    "ownership|\(grant.contentID.rawValue)"
                  ],
                  ownership.grantedAt == createdAt,
                  ownership.sourceGrantKeys.contains(
                    ProgressionLogicalRecord.grant(grant).identity
                  )
            else { continue }

            let incoming = ProgressionCanonicalRevealCandidate(
                contentID: grant.contentID,
                grantGroupID: grant.grantGroupID,
                tier: durableRevealTier(group.revealTier),
                isPrimary: grant.contentID == group.primaryContentID,
                sources: [grant.source]
            )
            if var existing = candidates[grant.contentID] {
                existing.sources.insert(grant.source)
                if canonicalRevealCandidateSortsBefore(incoming, existing) {
                    candidates[grant.contentID] = ProgressionCanonicalRevealCandidate(
                        contentID: incoming.contentID,
                        grantGroupID: incoming.grantGroupID,
                        tier: incoming.tier,
                        isPrimary: incoming.isPrimary,
                        sources: existing.sources
                    )
                } else {
                    candidates[grant.contentID] = existing
                }
            } else {
                candidates[grant.contentID] = incoming
            }
        }
        let sorted = candidates.values.sorted(by: canonicalRevealCandidateSortsBefore)
        guard let primary = sorted.first else {
            throw ProgressionDomainError.invalidRecord("queued-reveal-candidate-empty")
        }
        let sources = sorted.reduce(into: Set<ProgressionGrantSource>()) {
            $0.formUnion($1.sources)
        }
        return CatalogMigrationRecord.UpgradeRevealBundle(
            tier: primary.tier,
            primaryContentID: primary.contentID,
            secondaryContentIDs: sorted.dropFirst().map(\.contentID),
            sourceAchievementIDs: sources.compactMap { source in
                guard case let .achievement(id) = source else { return nil }
                return id
            },
            sourceRuleIDs: sources.compactMap { source in
                guard case let .milestone(id) = source else { return nil }
                return id
            }
        )
    }

    private func completionEventID(
        for source: ProgressionGrantSource,
        in validationRecords: [String: ProgressionLogicalRecord]
    ) -> EventID? {
        switch source {
        case .migration:
            return nil
        case let .achievement(id):
            guard case let .achievementCompletion(completion)? = validationRecords[
                "achievement-completion|\(id.rawValue)"
            ] else { return nil }
            return completion.sourceEventID
        case let .milestone(id):
            guard case let .milestoneCompletion(completion)? = validationRecords[
                "milestone-completion|\(id.rawValue)"
            ] else { return nil }
            return completion.sourceEventID
        }
    }

    private func canonicalRevealCandidateSortsBefore(
        _ lhs: ProgressionCanonicalRevealCandidate,
        _ rhs: ProgressionCanonicalRevealCandidate
    ) -> Bool {
        let left = (
            revealTierRank(lhs.tier),
            lhs.isPrimary ? 1 : 0,
            lhs.grantGroupID.rawValue,
            lhs.contentID.rawValue
        )
        let right = (
            revealTierRank(rhs.tier),
            rhs.isPrimary ? 1 : 0,
            rhs.grantGroupID.rawValue,
            rhs.contentID.rawValue
        )
        return left > right
    }

    private func durableRevealTier(
        _ tier: ProgressionCatalogRevealTier
    ) -> ProgressionDurableRevealTier {
        switch tier {
        case .none: .none
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        }
    }

    private func quarantineQueuedRevealReference(
        _ located: ProgressionLocatedRecord<PendingRevealRecord>
    ) async throws {
        guard let physical = try await client.fetch(
            collectionID: located.physical.key.collectionID,
            recordID: located.physical.key.recordID
        ), physical.revision == located.physical.revision
        else { throw ProgressionDomainError.invalidRecord("queued-reveal-revision") }
        try await quarantineInvalid(
            physical,
            category: .pendingReveal,
            code: ProgressionRepositoryIDs.recordReferenceCode
        )
    }

    private func revealTierRank(_ tier: ProgressionCatalogRevealTier) -> Int {
        switch tier {
        case .none: 0
        case .micro: 1
        case .artifact: 2
        case .codex: 3
        case .mastery: 4
        }
    }

    private func revealTierRank(_ tier: ProgressionDurableRevealTier) -> Int {
        switch tier {
        case .none: 0
        case .micro: 1
        case .artifact: 2
        case .codex: 3
        case .mastery: 4
        }
    }

    private func revealQueueState(
        in projection: ProgressionProjection
    ) throws -> ProgressionRevealQueueStateRecord {
        guard case let .revealQueueState(record)? = projection.records[
            "reveal-queue-state"
        ] else { throw ProgressionDomainError.invalidRecord("reveal-queue-state-missing") }
        try record.validate()
        return record
    }

    private func initialize(
        bundle: ValidatedProgressionCatalogBundle,
        projection: ProgressionProjection
    ) async throws {
        let migrationVersion = bundle.catalog.migration.migrationVersion
        let transactionID = ProgressionDeterminism.transactionUUID(
            "progression-bootstrap|\(bundle.catalog.catalogID.rawValue)|\(bundle.catalog.catalogVersion.rawValue)|\(migrationVersion)"
        )
        var mutations: [ModuleStateMutation] = [
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.metadataCollection,
                    recordID: ProgressionRepositoryIDs.activeMetadataRecord
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(projection.metadata),
                expectedRevision: .absent
            )),
        ]
        let projectionShards = try projection.shards()
        for shard in projectionShards.values.sorted(by: {
            ProgressionRepositoryIDs.shardRecordID($0)
                < ProgressionRepositoryIDs.shardRecordID($1)
        }) {
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.projectionCollection,
                    recordID: ProgressionRepositoryIDs.shardRecordID(shard)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(shard),
                expectedRevision: .absent
            )))
        }
        try validateTransactionBounds(mutations)
        let transaction = try ModuleStateTransaction(
            transactionID: transactionID,
            mutations: mutations
        )
        do {
            _ = try await client.transact(transaction)
        } catch let originalError {
            if let loaded = try? await loadRawExisting(),
               loaded.projection.metadata == projection.metadata,
               loaded.projection.records == projection.records,
               loaded.projection.physicalShards.count == projectionShards.count
            {
                return
            }
            throw originalError
        }
    }

    private func sealInitializationIfNeeded() async throws {
        let state = try await loadRawExisting()
        guard state.projection.metadata.initializedAt == nil else { return }
        guard let initializedAt = state.projection.physicalMetadata?.updatedAt else {
            throw ProgressionDomainError.invalidRecord("initialization-seal-metadata")
        }
        var projection = state.projection
        projection.metadata.initializedAt = initializedAt
        for logical in projection.logicalRecords() {
            switch logical {
            case let .catalogMigration(record):
                try projection.upsert(.catalogMigration(CatalogMigrationRecord(
                    generation: record.generation,
                    migrationVersion: record.migrationVersion,
                    catalogVersion: record.catalogVersion,
                    transactionID: record.transactionID,
                    completedAt: record.completedAt ?? initializedAt,
                    compatibilityFingerprints: record.compatibilityFingerprints,
                    upgradeRevealBundle: record.upgradeRevealBundle,
                    priorCatalogVersion: record.priorCatalogVersion,
                    priorGeneration: record.priorGeneration,
                    cleanupCompletedAt: record.cleanupCompletedAt
                )))
            case let .grant(record):
                guard case .migration = record.source, record.grantedAt == nil else { continue }
                try projection.upsert(.grant(GrantRecord(
                    generation: record.generation,
                    grantGroupID: record.grantGroupID,
                    contentID: record.contentID,
                    source: record.source,
                    transactionID: record.transactionID,
                    grantedAt: initializedAt
                )))
            case let .ownership(record):
                guard record.grantedAt == nil else { continue }
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: record.generation,
                    contentID: record.contentID,
                    sourceGrantKeys: record.sourceGrantKeys,
                    grantedAt: initializedAt
                )))
            case let .entitlement(record):
                guard record.source == .included, record.grantedAt == nil else { continue }
                try projection.upsert(.entitlement(ProgressionEntitlementRecord(
                    generation: record.generation,
                    entitlementID: record.entitlementID,
                    contentID: record.contentID,
                    source: record.source,
                    grantedAt: initializedAt
                )))
            default:
                continue
            }
        }
        var mutations: [ModuleStateMutation] = [
            .upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.metadataCollection,
                    recordID: ProgressionRepositoryIDs.activeMetadataRecord
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(projection.metadata),
                expectedRevision: expectation(state.projection.physicalMetadata)
            )),
        ]
        let oldShards = try state.projection.shards()
        let newShards = try projection.shards()
        for identity in newShards.keys.sorted() where oldShards[identity] != newShards[identity] {
            guard let shard = newShards[identity],
                  let physical = state.projection.physicalShards[identity]
            else { throw ProgressionDomainError.invalidRecord("initialization-seal-shard") }
            mutations.append(.upsert(ModuleStateUpsert(
                key: ModuleStateRecordKey(
                    collectionID: ProgressionRepositoryIDs.projectionCollection,
                    recordID: ProgressionRepositoryIDs.shardRecordID(shard)
                ),
                schemaVersion: Self.namespaceSchemaVersion,
                payload: try encode(shard),
                expectedRevision: .exact(physical.revision)
            )))
        }
        try validateTransactionBounds(mutations)
        let migrations = projection.logicalRecords().compactMap {
            logical -> CatalogMigrationRecord? in
            guard case let .catalogMigration(value) = logical else { return nil }
            return value
        }
        guard migrations.count == 1 else {
            throw ProgressionDomainError.invalidRecord("initialization-seal-migration")
        }
        _ = try await client.transact(try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "progression-initialization-seal|\(projection.metadata.catalogID.rawValue)|\(projection.metadata.catalogVersion.rawValue)|\(migrations[0].migrationVersion)"
            ),
            mutations: mutations
        ))
    }

    private func quarantineInvalid(
        _ physical: ModuleStateRecord,
        category: ProgressionDiagnosticRecordCategory,
        code: ProgressionRejectionCode
    ) async throws {
        let sourceDigest = ProgressionDeterminism.digest128(
            "\(physical.key.collectionID.rawValue)|\(physical.key.recordID.rawValue)"
        )
        let record = QuarantineRecord(
            category: category,
            sourceCollectionID: physical.key.collectionID,
            sourceRecordDigest: sourceDigest,
            sourceRevision: physical.revision,
            diagnosticCode: code,
            detectedAt: physical.updatedAt
        )
        let mutation = ModuleStateMutation.upsert(ModuleStateUpsert(
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.quarantineCollection,
                recordID: ProgressionRepositoryIDs.quarantineRecordID(record)
            ),
            schemaVersion: Self.namespaceSchemaVersion,
            payload: try encode(record),
            expectedRevision: .absent
        ))
        let transaction = try ModuleStateTransaction(
            transactionID: ProgressionDeterminism.transactionUUID(
                "quarantine|\(sourceDigest)|\(physical.revision)"
            ),
            mutations: [mutation]
        )
        _ = try await client.transact(transaction)
        _ = try await client.quarantineRecord(
            collectionID: physical.key.collectionID,
            recordID: physical.key.recordID,
            expectedRevision: physical.revision,
            diagnosticCode: code.rawValue
        )
    }

    private func activeMetadataForDirectContext() async throws -> ProgressionMetadataRecord {
        guard let physical = try await client.fetch(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        ) else { throw ProgressionDomainError.missingMetadata }
        return try await decodeDirectRecord(
            physical,
            category: .metadata,
            invalidLabel: "metadata-corrupt"
        ) {
            guard physical.schemaVersion == Self.namespaceSchemaVersion else {
                throw ProgressionDomainError.unsupportedRecordSchema(
                    UInt16(clamping: physical.schemaVersion)
                )
            }
            let metadata = try ProgressionDeterminism.decoder().decode(
                ProgressionMetadataRecord.self,
                from: physical.payload
            )
            try metadata.validate()
            guard physical.key.collectionID == ProgressionRepositoryIDs.metadataCollection,
                  physical.key.recordID == ProgressionRepositoryIDs.activeMetadataRecord
            else { throw ProgressionDomainError.invalidRecord("metadata-identity") }
            return metadata
        }
    }

    private func decodeDirectRecord<Value>(
        _ physical: ModuleStateRecord,
        category: ProgressionDiagnosticRecordCategory,
        invalidLabel: String,
        _ decode: () throws -> Value
    ) async throws -> Value {
        do {
            return try decode()
        } catch {
            try await quarantineInvalid(
                physical,
                category: category,
                code: ProgressionRepositoryIDs.recordDecodeCode
            )
            throw ProgressionDomainError.invalidRecord(invalidLabel)
        }
    }

    private func validateCursor(
        _ next: ModuleStateScanCursor?,
        prior: ModuleStateScanCursor?,
        collection: ModuleStateCollectionID
    ) throws {
        guard let next else { return }
        guard next.collectionID == collection,
              next != prior,
              prior.map({
                  $0.observedStoreRevision == next.observedStoreRevision &&
                      $0.afterRecordID < next.afterRecordID
              }) ?? true
        else { throw ProgressionDomainError.invalidRecord("ledger-cursor") }
    }

    private func quarantineActiveProjection(
        _ projection: ProgressionProjection,
        error: Error
    ) async throws {
        guard let issue = error as? ProgressionProjectionIntegrityIssue else { return }
        for category in issue.categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            let identity = ProgressionProjectionLayout.shardIdentity(
                generation: projection.metadata.activeGeneration,
                category: category,
                shardIndex: 0
            )
            guard let physical = projection.physicalShards[identity],
                  let stored = try? await client.fetch(
                      collectionID: physical.key.collectionID,
                      recordID: physical.key.recordID
                  )
            else { continue }
            try await quarantineInvalid(
                stored,
                category: category,
                code: ProgressionRepositoryIDs.recordReferenceCode
            )
        }
    }

    private func cleanupCollection(
        _ collectionID: ModuleStateCollectionID,
        recordPrefix: String,
        operationID: String
    ) async throws {
        var cursor: ModuleStateScanCursor?
        var observedRevision: UInt64?
        while true {
            let request = try ModuleStateScanRequest(
                collectionID: collectionID,
                limit: ModuleStateScanRequest.maximumLimit,
                cursor: cursor
            )
            let page = try await client.scan(request)
            guard page.records.allSatisfy({ $0.key.collectionID == collectionID }),
                  page.records.map(\.key) == page.records.map(\.key).sorted()
            else { throw ProgressionDomainError.invalidRecord("cleanup-scan-page") }
            if let observedRevision,
               let next = page.nextCursor,
               next.observedStoreRevision != observedRevision
            {
                throw ProgressionDomainError.invalidRecord("cleanup-scan-revision")
            }
            let matching = page.records.filter {
                $0.key.recordID.rawValue.hasPrefix(recordPrefix)
            }.prefix(ModuleStateTransaction.maximumMutations)
            if !matching.isEmpty {
                let mutations = matching.map { record in
                    ModuleStateMutation.delete(ModuleStateDelete(
                        key: record.key,
                        expectedRevision: .exact(record.revision)
                    ))
                }
                let identity = matching.map {
                    "\($0.key.recordID.rawValue):\($0.revision)"
                }.joined(separator: "|")
                _ = try await client.transact(try ModuleStateTransaction(
                    transactionID: ProgressionDeterminism.transactionUUID(
                        "rebuild-cleanup|\(operationID)|\(collectionID.rawValue)|\(ProgressionDeterminism.digest128(identity))"
                    ),
                    mutations: mutations
                ))
                cursor = nil
                observedRevision = nil
                continue
            }
            guard let next = page.nextCursor else { return }
            guard next.collectionID == collectionID,
                  next != cursor,
                  cursor.map({ $0.afterRecordID < next.afterRecordID }) ?? true
            else { throw ProgressionDomainError.invalidRecord("cleanup-scan-cursor") }
            observedRevision = next.observedStoreRevision
            cursor = next
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try ProgressionDeterminism.encoder().encode(value)
        guard data.count <= 1_048_576 else {
            throw ModuleStateStoreError.payloadTooLarge(maximumBytes: 1_048_576)
        }
        return data
    }

    private func validateTransactionBounds(_ mutations: [ModuleStateMutation]) throws {
        guard !mutations.isEmpty, mutations.count <= ModuleStateTransaction.maximumMutations else {
            throw ModuleStateStoreError.transactionTooLarge(
                maximumMutations: ModuleStateTransaction.maximumMutations
            )
        }
        let bytes = mutations.reduce(0) { $0 + mutationPayloadBytes($1) }
        guard bytes <= 8_388_608 else {
            throw ModuleStateStoreError.payloadTooLarge(maximumBytes: 8_388_608)
        }
    }

    private func stageMutationBatches(
        _ plan: [ProgressionPlannedStageMutation]
    ) throws -> [[ProgressionPlannedStageMutation]] {
        var batches: [[ProgressionPlannedStageMutation]] = []
        var current: [ProgressionPlannedStageMutation] = []
        var currentBytes = 0
        for item in plan {
            let bytes = mutationPayloadBytes(item.mutation)
            guard bytes <= 8_388_608 else {
                throw ModuleStateStoreError.payloadTooLarge(maximumBytes: 8_388_608)
            }
            if !current.isEmpty,
               (current.count == ModuleStateTransaction.maximumMutations ||
                currentBytes + bytes > 8_388_608)
            {
                batches.append(current)
                current = []
                currentBytes = 0
            }
            current.append(item)
            currentBytes += bytes
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private func mutationPayloadBytes(_ mutation: ModuleStateMutation) -> Int {
        switch mutation {
        case let .upsert(value): value.payload.count
        case .delete: 0
        }
    }

    private func expectation(
        _ physical: ProgressionPhysicalRecord?
    ) -> ModuleStateRevisionExpectation {
        physical.map { .exact($0.revision) } ?? .absent
    }

    private func physicalRecord(_ record: ModuleStateRecord) -> ProgressionPhysicalRecord {
        ProgressionPhysicalRecord(
            key: record.key,
            revision: record.revision,
            updatedAt: record.updatedAt,
            integrityDigest: record.integrityDigest
        )
    }
}
