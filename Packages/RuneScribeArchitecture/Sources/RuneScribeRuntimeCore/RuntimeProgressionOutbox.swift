import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts

public enum RuntimeProgressionOutboxRecordState: String, Codable, CaseIterable, Sendable {
    case pending
    case ready
    case inFlight
    case acknowledged
    case permanentlyRejected
}

public enum RuntimeProgressionOutboxSubmissionError: Error, Equatable, Sendable {
    case conflictingBatch
    case conflictingShareCompletion
    case missingPriorBatch
    case invalidOperationContext
    case shareCompletionJournalFull
}

public struct RuntimeProgressionOutboxSnapshot: Equatable, Sendable {
    public let pendingCount: UInt64
    public let readyCount: UInt64
    public let inFlightCount: UInt64
    public let nextRetryAt: Date?

    public init(
        pendingCount: UInt64,
        readyCount: UInt64,
        inFlightCount: UInt64,
        nextRetryAt: Date?
    ) {
        self.pendingCount = pendingCount
        self.readyCount = readyCount
        self.inFlightCount = inFlightCount
        self.nextRetryAt = nextRetryAt
    }
}

public struct RuntimeProgressionOutboxClient: Sendable {
    private let gateway: RuntimeProgressionOutbox
    private let lease: ModuleContextLease
    private let sourceModuleID: ModuleIdentifier

    init(
        gateway: RuntimeProgressionOutbox,
        lease: ModuleContextLease,
        sourceModuleID: ModuleIdentifier
    ) {
        self.gateway = gateway
        self.lease = lease
        self.sourceModuleID = sourceModuleID
    }

    public func submit(
        _ fact: ProgressionEventFact
    ) async throws -> ProgressionOutboxReceipt {
        try await lease.requireActive()
        let result = try await gateway.submit(fact, sourceModuleID: sourceModuleID)
        try await lease.requireActive()
        return result
    }

    public func submitBatch(
        _ batch: ProgressionEventFactBatch,
        context: RuntimePersistableOperationContext
    ) async throws -> ProgressionOutboxBatchReceipt {
        try await lease.requireActive()
        let result = try await gateway.submitBatch(
            batch,
            context: context,
            sourceModuleID: sourceModuleID
        )
        try await lease.requireActive()
        return result
    }

    public func issueBackgroundContext(
        for purpose: RuntimeBackgroundOperationPurpose
    ) async throws -> RuntimePersistableOperationContext {
        try await lease.requireActive()
        let context = try await gateway.issueBackgroundContext(for: purpose)
        try await lease.requireActive()
        return context
    }

    public func acknowledgeBatch(
        _ receipt: ProgressionOutboxBatchReceipt,
        context: RuntimePersistableOperationContext
    ) async throws {
        try await lease.requireActive()
        try await gateway.acknowledgeBatch(
            receipt,
            context: context,
            sourceModuleID: sourceModuleID
        )
        try await lease.requireActive()
    }

    /// Authoritative Runtime terminal records that may be replayed to Core
    /// after module activation. Core uses this opaque identity set to retain
    /// only prepared share linkage that still has a possible redelivery.
    public func outstandingShareCompletionArtifactIDs() async throws
        -> Set<ShareArtifactID>
    {
        try await lease.requireActive()
        let artifactIDs = try await gateway
            .outstandingShareCompletionArtifactIDs()
        try await lease.requireActive()
        return artifactIDs
    }

    func journalShareCompletion(
        _ evidence: ShareArtifactCompletionEvidenceDTO
    ) async throws {
        try await lease.requireActive()
        try await gateway.journalShareCompletion(evidence)
        try await lease.requireActive()
    }

    func reserveShareCompletion(for artifactID: ShareArtifactID) async throws {
        try await lease.requireActive()
        try await gateway.reserveShareCompletion(for: artifactID)
        try await lease.requireActive()
    }

    func cancelShareCompletionReservation(
        for artifactID: ShareArtifactID
    ) async {
        await gateway.cancelShareCompletionReservation(for: artifactID)
    }
}

actor RuntimeProgressionOutbox {
    private struct Record: Codable, Equatable, Sendable {
        let envelope: DomainEventEnvelope
        let producerOperationID: RuntimeOperationID?
        let factSlot: ProgressionFactSlot?
        var state: RuntimeProgressionOutboxRecordState
        var attemptCount: UInt16
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var diagnosticCode: ProgressionRejectionCode?
    }

    private struct BatchReceiptRecord: Codable, Equatable, Sendable {
        let contextID: RuntimeOperationID
        let contextDigest: Data
        let batchIndex: UInt32
        let totalBatchCount: UInt32
        let totalFactCount: UInt32
        let batchDigest: Data
        let sourceModuleID: ModuleIdentifier
        let correlationID: CorrelationID
        let durableAt: Date
        let events: [ProgressionOutboxEventReceipt]
        var acknowledgedAt: Date?
    }

    private struct ShareCompletionRecord: Codable, Equatable, Sendable {
        let artifactID: ShareArtifactID
        let reservedAt: Date
        var evidence: ShareArtifactCompletionEvidenceDTO?
        var attemptCount: UInt16
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
    }

    private struct OperationContextAuthorityClaims: Codable, Sendable {
        let schemaVersion: UInt16
        let operationID: RuntimeOperationID
        let correlationID: RuntimeCorrelationID
        let occurredAtUTC: Date
        let operationIdentifier: RuntimeOperationIdentifier
        let runtimeGeneration: UInt64
        let authorityNonce: UUID
        let authorityScope: RuntimeOperationContextAuthorityScope
    }

    private static let namespace = ModuleStateNamespace(
        moduleID: "com.runescribe.runtime.progression-outbox"
    )
    private static let contextAuthorityNamespace = ModuleStateNamespace(
        moduleID: "com.runescribe.runtime.operation-context-authority"
    )
    private static let collectionID = ModuleStateCollectionID(
        rawValue: "progression.outbox"
    )!
    private static let receiptCollectionID = ModuleStateCollectionID(
        rawValue: "progression.outbox-receipts"
    )!
    private static let shareCompletionCollectionID = ModuleStateCollectionID(
        rawValue: "share-completion-journal"
    )!
    private static let contextAuthorityCollectionID = ModuleStateCollectionID(
        rawValue: "operation-context-authority"
    )!
    private static let contextAuthorityRecordID = ModuleStateRecordID(
        rawValue: "authority-key-v1"
    )!
    private static let schemaVersion: UInt32 = 1
    private static let maximumBatchSize = ModuleStateScanRequest.maximumLimit
    private static let maximumShareCompletionCount = 64
    private static let maximumRetryDelay: TimeInterval = 3_600

    private let state: RuntimeModuleStateGateway
    private let dispatcher: RuntimeOperationDispatcher
    private let environment: RuntimeEnvironment
    private var runtimeGeneration: UInt64 = 0
    private var contextAuthority: RuntimeOperationContextAuthenticator?
    private var contextAuthorityScope: RuntimeOperationContextAuthorityScope = .runtimeGeneration
    private var runtimeIsActive = false
    private var isReplaying = false
    private var retryTask: Task<Void, Never>?
    private var scheduledRetryAt: Date?
    private var isReplayingShareCompletions = false
    private var shareCompletionRetryTask: Task<Void, Never>?
    private var scheduledShareCompletionRetryAt: Date?

    init(
        state: RuntimeModuleStateGateway,
        dispatcher: RuntimeOperationDispatcher,
        environment: RuntimeEnvironment
    ) {
        self.state = state
        self.dispatcher = dispatcher
        self.environment = environment
    }

    func activateRuntime() async {
        runtimeGeneration &+= 1
        runtimeIsActive = true
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = nil
        do {
            _ = try await state.runtimePrepare(
                namespace: Self.namespace,
                schemaVersion: Self.schemaVersion
            )
            _ = try await state.runtimePrepare(
                namespace: Self.contextAuthorityNamespace,
                schemaVersion: Self.schemaVersion
            )
            try await loadOrCreateContextAuthorityKey()
        } catch {
            installEphemeralContextAuthorityKey()
            return
        }
        // Reservation cleanup is independent from context authority recovery.
        // A cleanup interruption must never replace a valid persistent key.
        try? await discardIncompleteShareCompletionReservations()
    }

    func runtimeDidStart() {
        guard runtimeIsActive else { return }
        Task { await replayReady() }
        Task { await replayShareCompletions() }
    }

    func progressionDidActivate() {
        guard runtimeIsActive else { return }
        Task { await replayReady() }
    }

    func outstandingShareCompletionArtifactIDs() async throws
        -> Set<ShareArtifactID>
    {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return Set(
            try await loadAllShareCompletionRecords().compactMap { _, record in
                record.evidence == nil ? nil : record.artifactID
            }
        )
    }

    func deactivateRuntime() {
        runtimeIsActive = false
        contextAuthority = nil
        contextAuthorityScope = .runtimeGeneration
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = nil
        shareCompletionRetryTask?.cancel()
        shareCompletionRetryTask = nil
        scheduledShareCompletionRetryAt = nil
    }

    /// Runtime is the first trusted owner of a normalized terminal share
    /// callback. Persisting that exact evidence here closes the crash window
    /// before UI can forward it to Core.
    func reserveShareCompletion(for artifactID: ShareArtifactID) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        let key = shareCompletionKey(for: artifactID)
        if let stored = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        ) {
            let existing: ShareCompletionRecord = try decode(
                stored.payload,
                as: ShareCompletionRecord.self
            )
            guard existing.artifactID == artifactID,
                  existing.evidence == nil
            else {
                throw RuntimeProgressionOutboxSubmissionError
                    .conflictingShareCompletion
            }
            return
        }
        let existing = try await loadAllShareCompletionRecords()
        guard existing.count < Self.maximumShareCompletionCount else {
            throw RuntimeProgressionOutboxSubmissionError
                .shareCompletionJournalFull
        }
        let record = ShareCompletionRecord(
            artifactID: artifactID,
            reservedAt: environment.now(),
            evidence: nil,
            attemptCount: 0,
            lastAttemptAt: nil,
            nextAttemptAt: nil
        )
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(record),
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        do {
            _ = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
        } catch {
            guard let stored = try? await state.runtimeFetch(
                namespace: Self.namespace,
                key: key
            ), let expectedPayload = try? encode(record),
                  stored.payload == expectedPayload
            else { throw error }
        }
    }

    func cancelShareCompletionReservation(
        for artifactID: ShareArtifactID
    ) async {
        let key = shareCompletionKey(for: artifactID)
        guard let stored = try? await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        ), let record = try? decode(
                  stored.payload,
                  as: ShareCompletionRecord.self
              ), record.artifactID == artifactID,
              record.evidence == nil
        else { return }
        try? await compact(key: key, expectedRevision: stored.revision)
    }

    private func discardIncompleteShareCompletionReservations() async throws {
        let reservations = try await loadAllShareCompletionRecords().filter {
            $0.1.evidence == nil
        }
        guard !reservations.isEmpty else { return }
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: reservations.map { stored, _ in
                .delete(
                    ModuleStateDelete(
                        key: stored.key,
                        expectedRevision: .exact(stored.revision)
                    )
                )
            }
        )
        do {
            _ = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
        } catch {
            let remaining = try await loadAllShareCompletionRecords()
                .filter { $0.1.evidence == nil }
            guard remaining.isEmpty else { throw error }
        }
    }

    func journalShareCompletion(
        _ evidence: ShareArtifactCompletionEvidenceDTO
    ) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try verify(evidence.operationContext)
        let key = shareCompletionKey(for: evidence.artifactID)
        if let stored = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        ) {
            let existing: ShareCompletionRecord = try decode(
                stored.payload,
                as: ShareCompletionRecord.self
            )
            guard existing.artifactID == evidence.artifactID else {
                throw RuntimeProgressionOutboxSubmissionError
                    .conflictingShareCompletion
            }
            if let existingEvidence = existing.evidence {
                guard existingEvidence == evidence else {
                    throw RuntimeProgressionOutboxSubmissionError
                        .conflictingShareCompletion
                }
                Task { await replayShareCompletions() }
                return
            }
            var completed = existing
            completed.evidence = evidence
            completed.nextAttemptAt = environment.now()
            do {
                _ = try await persistShareCompletion(
                    completed,
                    key: key,
                    expectedRevision: stored.revision
                )
            } catch {
                guard let recovered = try? await state.runtimeFetch(
                    namespace: Self.namespace,
                    key: key
                ), let expectedPayload = try? encode(completed),
                      recovered.payload == expectedPayload
                else { throw error }
            }
            Task { await replayShareCompletions() }
            return
        }
        let existing = try await loadAllShareCompletionRecords()
        guard existing.count < Self.maximumShareCompletionCount else {
            throw RuntimeProgressionOutboxSubmissionError
                .shareCompletionJournalFull
        }
        let record = ShareCompletionRecord(
            artifactID: evidence.artifactID,
            reservedAt: environment.now(),
            evidence: evidence,
            attemptCount: 0,
            lastAttemptAt: nil,
            nextAttemptAt: environment.now()
        )
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(record),
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        do {
            _ = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
        } catch {
            guard let stored = try? await state.runtimeFetch(
                namespace: Self.namespace,
                key: key
            ), let expectedPayload = try? encode(record),
                  stored.payload == expectedPayload
            else { throw error }
        }
        Task { await replayShareCompletions() }
    }

    func submit(
        _ fact: ProgressionEventFact,
        sourceModuleID: ModuleIdentifier
    ) async throws -> ProgressionOutboxReceipt {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        let durableAt = try RuntimePersistableOperationContext
            .normalizedOccurredAtUTC(environment.now())
        let eventID = EventID(rawValue: environment.nextUUID())
        let correlationID = CorrelationID(rawValue: environment.nextUUID())
        let envelope = try DomainEventEnvelope(
            schemaVersion: 1,
            eventID: eventID,
            correlationID: correlationID,
            eventType: fact.eventType,
            sourceModuleID: sourceModuleID,
            occurredAt: durableAt,
            eligibility: fact.eligibility,
            payload: fact.payload
        )
        let record = Record(
            envelope: envelope,
            producerOperationID: nil,
            factSlot: nil,
            state: .ready,
            attemptCount: 0,
            lastAttemptAt: nil,
            nextAttemptAt: durableAt,
            diagnosticCode: nil
        )
        let key = recordKey(for: eventID)
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(record),
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        let result = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
        let receipt = try ProgressionOutboxReceipt(
            eventID: eventID,
            correlationID: correlationID,
            durableAt: durableAt,
            outboxRevision: result.storeRevision
        )
        Task { await replayReady() }
        return receipt
    }

    func issueBackgroundContext(
        for purpose: RuntimeBackgroundOperationPurpose
    ) throws -> RuntimePersistableOperationContext {
        try issueContext(
            operationIdentifier: RuntimeOperationIdentifier(
                "progression.background.\(purpose.rawValue)"
            )
        )
    }

    func issueOperationContext(
        from metadata: RuntimeOperationMetadata
    ) throws -> RuntimePersistableOperationContext {
        try makeContext(
            operationID: metadata.operationID,
            correlationID: metadata.correlationID,
            occurredAtUTC: metadata.timestampUTC,
            operationIdentifier: metadata.operationIdentifier,
            runtimeGeneration: metadata.runtimeGeneration
        )
    }

    func issueOperationContext(
        operationID: RuntimeOperationID,
        correlationID: RuntimeCorrelationID,
        occurredAtUTC: Date,
        operationIdentifier: RuntimeOperationIdentifier,
        runtimeGeneration: UInt64
    ) throws -> RuntimePersistableOperationContext {
        try makeContext(
            operationID: operationID,
            correlationID: correlationID,
            occurredAtUTC: occurredAtUTC,
            operationIdentifier: operationIdentifier,
            runtimeGeneration: runtimeGeneration
        )
    }

    func submitBatch(
        _ batch: ProgressionEventFactBatch,
        context: RuntimePersistableOperationContext,
        sourceModuleID: ModuleIdentifier
    ) async throws -> ProgressionOutboxBatchReceipt {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }

        try verify(context)

        let contextDigest = try digest(context)
        let batchDigest = try digest(batch)
        let receiptKey = batchReceiptKey(
            contextID: context.runtimeOperationID,
            batchIndex: batch.batchIndex
        )
        if let stored = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: receiptKey
        ) {
            let receiptRecord: BatchReceiptRecord = try decode(
                stored.payload,
                as: BatchReceiptRecord.self
            )
            guard receiptRecord.contextDigest == contextDigest,
                  receiptRecord.batchDigest == batchDigest,
                  receiptRecord.sourceModuleID == sourceModuleID,
                  receiptRecord.batchIndex == batch.batchIndex,
                  receiptRecord.totalBatchCount == batch.totalBatchCount,
                  receiptRecord.totalFactCount == batch.totalFactCount
            else {
                throw RuntimeProgressionOutboxSubmissionError.conflictingBatch
            }
            return try makeReceipt(from: receiptRecord, revision: stored.revision)
        }

        if batch.batchIndex > 0 {
            let previousKey = batchReceiptKey(
                contextID: context.runtimeOperationID,
                batchIndex: batch.batchIndex - 1
            )
            guard let previous = try await state.runtimeFetch(
                namespace: Self.namespace,
                key: previousKey
            ) else {
                throw RuntimeProgressionOutboxSubmissionError.missingPriorBatch
            }
            let previousReceipt: BatchReceiptRecord = try decode(
                previous.payload,
                as: BatchReceiptRecord.self
            )
            guard previousReceipt.contextDigest == contextDigest,
                  previousReceipt.sourceModuleID == sourceModuleID,
                  previousReceipt.totalBatchCount == batch.totalBatchCount,
                  previousReceipt.totalFactCount == batch.totalFactCount
            else {
                throw RuntimeProgressionOutboxSubmissionError.conflictingBatch
            }
        }

        guard let correlationUUID = UUID(
            uuidString: context.runtimeCorrelationID.rawValue
        ) else {
            throw RuntimeProgressionOutboxSubmissionError.invalidOperationContext
        }
        let durableAt = try RuntimePersistableOperationContext
            .normalizedOccurredAtUTC(environment.now())
        let correlationID = CorrelationID(rawValue: correlationUUID)
        var eventReceipts: [ProgressionOutboxEventReceipt] = []
        var mutations: [ModuleStateMutation] = []
        eventReceipts.reserveCapacity(batch.facts.count)
        mutations.reserveCapacity(batch.facts.count + 1)

        for slotted in batch.facts {
            let eventID = EventID(rawValue: environment.nextUUID())
            let envelope = try DomainEventEnvelope(
                schemaVersion: 1,
                eventID: eventID,
                correlationID: correlationID,
                eventType: slotted.fact.eventType,
                sourceModuleID: sourceModuleID,
                occurredAt: context.runtimeOccurredAtUTC,
                eligibility: slotted.fact.eligibility,
                payload: slotted.fact.payload
            )
            let record = Record(
                envelope: envelope,
                producerOperationID: context.runtimeOperationID,
                factSlot: slotted.slot,
                state: .ready,
                attemptCount: 0,
                lastAttemptAt: nil,
                nextAttemptAt: durableAt,
                diagnosticCode: nil
            )
            let key = recordKey(for: eventID)
            mutations.append(
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(record),
                        expectedRevision: .absent
                    )
                )
            )
            eventReceipts.append(
                ProgressionOutboxEventReceipt(slot: slotted.slot, eventID: eventID)
            )
        }

        let receiptRecord = BatchReceiptRecord(
            contextID: context.runtimeOperationID,
            contextDigest: contextDigest,
            batchIndex: batch.batchIndex,
            totalBatchCount: batch.totalBatchCount,
            totalFactCount: batch.totalFactCount,
            batchDigest: batchDigest,
            sourceModuleID: sourceModuleID,
            correlationID: correlationID,
            durableAt: durableAt,
            events: eventReceipts,
            acknowledgedAt: nil
        )
        mutations.append(
            .upsert(
                ModuleStateUpsert(
                    key: receiptKey,
                    schemaVersion: Self.schemaVersion,
                    payload: try encode(receiptRecord),
                    expectedRevision: .absent
                )
            )
        )
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: mutations
        )
        let result = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
        guard let receiptRevision = result.mutations.last?.revision else {
            throw ModuleStateStoreError.corrupt
        }
        let receipt = try makeReceipt(
            from: receiptRecord,
            revision: receiptRevision
        )
        Task { await replayReady() }
        return receipt
    }

    func acknowledgeBatch(
        _ receipt: ProgressionOutboxBatchReceipt,
        context: RuntimePersistableOperationContext,
        sourceModuleID: ModuleIdentifier
    ) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try verify(context)
        guard receipt.matches(context: context) else {
            throw RuntimeProgressionOutboxSubmissionError.conflictingBatch
        }
        let key = batchReceiptKey(
            contextID: receipt.contextID,
            batchIndex: receipt.batchIndex
        )
        guard let stored = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        ) else {
            return
        }
        let record: BatchReceiptRecord = try decode(
            stored.payload,
            as: BatchReceiptRecord.self
        )
        let contextDigest = try digest(context)
        guard stored.revision >= receipt.outboxRevision,
              record.contextID == receipt.contextID,
              record.contextDigest == contextDigest,
              record.batchIndex == receipt.batchIndex,
              record.sourceModuleID == sourceModuleID,
              record.correlationID == receipt.correlationID,
              record.durableAt == receipt.durableAt,
              record.events == receipt.events
        else {
            throw RuntimeProgressionOutboxSubmissionError.conflictingBatch
        }
        if record.acknowledgedAt == nil {
            var acknowledged = record
            acknowledged.acknowledgedAt = environment.now()
            _ = try await persistBatchReceipt(
                acknowledged,
                key: key,
                expectedRevision: stored.revision
            )
        }
        try await compactReceiptsIfAllAcknowledged(
            contextID: record.contextID,
            contextDigest: record.contextDigest,
            totalBatchCount: record.totalBatchCount,
            totalFactCount: record.totalFactCount,
            sourceModuleID: sourceModuleID
        )
    }

    func snapshot() async throws -> RuntimeProgressionOutboxSnapshot {
        let records = try await loadAllRecords()
        let shareCompletions = try await loadAllShareCompletionRecords()
        var counts: [RuntimeProgressionOutboxRecordState: UInt64] = [:]
        var nextRetryAt: Date?
        for (_, record) in records {
            counts[record.state, default: 0] += 1
            if let candidate = record.nextAttemptAt,
               nextRetryAt == nil || candidate < nextRetryAt!
            {
                nextRetryAt = candidate
            }
        }
        return RuntimeProgressionOutboxSnapshot(
            pendingCount: counts[.pending, default: 0]
                + UInt64(shareCompletions.count),
            readyCount: counts[.ready, default: 0],
            inFlightCount: counts[.inFlight, default: 0],
            nextRetryAt: nextRetryAt
        )
    }

    private func replayShareCompletions() async {
        guard runtimeIsActive, !isReplayingShareCompletions else { return }
        isReplayingShareCompletions = true
        defer { isReplayingShareCompletions = false }
        shareCompletionRetryTask?.cancel()
        shareCompletionRetryTask = nil
        scheduledShareCompletionRetryAt = nil

        let records: [(ModuleStateRecord, ShareCompletionRecord)]
        do {
            records = try await loadAllShareCompletionRecords()
        } catch ModuleStateStoreError.corrupt,
                ModuleStateStoreError.quarantined,
                ModuleStateStoreError.integrityMismatch {
            return
        } catch {
            scheduleShareCompletionRetry(
                at: environment.now().addingTimeInterval(1)
            )
            return
        }

        let now = environment.now()
        var earliestFutureRetry: Date?
        for (stored, record) in records {
            guard runtimeIsActive else { return }
            guard record.evidence != nil else { continue }
            if let retryAt = record.nextAttemptAt, retryAt > now {
                earliestFutureRetry = minDate(earliestFutureRetry, retryAt)
                continue
            }
            do {
                try await deliverShareCompletion(record: record, stored: stored)
            } catch {
                let retryAt = environment.now().addingTimeInterval(
                    retryDelay(afterAttempt: record.attemptCount)
                )
                earliestFutureRetry = minDate(earliestFutureRetry, retryAt)
            }
        }
        if let earliestFutureRetry {
            scheduleShareCompletionRetry(at: earliestFutureRetry)
        }
    }

    private func deliverShareCompletion(
        record: ShareCompletionRecord,
        stored: ModuleStateRecord
    ) async throws {
        guard let evidence = record.evidence else { return }
        let attempt = record.attemptCount == UInt16.max
            ? UInt16.max
            : record.attemptCount + 1
        let attemptAt = environment.now()
        var inFlight = record
        inFlight.attemptCount = attempt
        inFlight.lastAttemptAt = attemptAt
        inFlight.nextAttemptAt = attemptAt.addingTimeInterval(
            retryDelay(afterAttempt: attempt)
        )
        let inFlightRevision = try await persistShareCompletion(
            inFlight,
            key: stored.key,
            expectedRevision: stored.revision
        )
        let client = try await dispatcher.shareCompletionCommandClient()
        let result = try await client.send(
            CompleteShareArtifactCommand(evidence: evidence),
            to: RuntimeApplicationEndpointCatalog.completeShareArtifact,
            idempotencyKey: RuntimeIdempotencyKey(
                "share-completion-\(evidence.artifactID.rawValue.uuidString.lowercased())"
            )
        )
        switch result {
        case .released, .deliveryRecorded:
            try await compact(
                key: stored.key,
                expectedRevision: inFlightRevision
            )
        case .retainedForRetry:
            scheduleShareCompletionRetry(
                at: inFlight.nextAttemptAt ?? environment.now()
            )
        }
    }

    func replayReady() async {
        guard runtimeIsActive, !isReplaying else { return }
        isReplaying = true
        defer { isReplaying = false }
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = nil

        let records: [(ModuleStateRecord, Record)]
        do {
            records = try await loadAllRecords()
        } catch ModuleStateStoreError.corrupt,
                ModuleStateStoreError.quarantined,
                ModuleStateStoreError.integrityMismatch {
            return
        } catch {
            scheduleRetry(at: environment.now().addingTimeInterval(1))
            return
        }

        let now = environment.now()
        var earliestFutureRetry: Date?
        for (stored, record) in records {
            guard runtimeIsActive else { return }
            switch record.state {
            case .acknowledged, .permanentlyRejected:
                try? await compact(stored: stored)
            case .pending:
                do {
                    _ = try await persist(
                        record: setting(record, state: .ready),
                        key: stored.key,
                        expectedRevision: stored.revision
                    )
                } catch {}
            case .ready, .inFlight:
                if let retryAt = record.nextAttemptAt, retryAt > now {
                    if earliestFutureRetry == nil || retryAt < earliestFutureRetry! {
                        earliestFutureRetry = retryAt
                    }
                    continue
                }
                do {
                    try await deliver(record: record, stored: stored)
                } catch {
                    let retryAt = environment.now().addingTimeInterval(
                        retryDelay(afterAttempt: record.attemptCount)
                    )
                    earliestFutureRetry = minDate(earliestFutureRetry, retryAt)
                }
            }
        }
        if let earliestFutureRetry { scheduleRetry(at: earliestFutureRetry) }
    }

    private func deliver(record: Record, stored: ModuleStateRecord) async throws {
        let attempt = record.attemptCount == UInt16.max
            ? UInt16.max
            : record.attemptCount + 1
        let attemptAt = environment.now()
        let nextAttemptAt = attemptAt.addingTimeInterval(retryDelay(afterAttempt: attempt))
        var inFlight = record
        inFlight.state = .inFlight
        inFlight.attemptCount = attempt
        inFlight.lastAttemptAt = attemptAt
        inFlight.nextAttemptAt = nextAttemptAt
        inFlight.diagnosticCode = nil
        let inFlightRevision = try await persist(
            record: inFlight,
            key: stored.key,
            expectedRevision: stored.revision
        )

        let client = try await dispatcher.progressionOutboxCommandClient()
        let result = try await client.send(
            inFlight.envelope,
            to: RuntimeProgressionEndpointCatalog.applyEvent,
            idempotencyKey: RuntimeIdempotencyKey(
                inFlight.envelope.eventID.rawValue.uuidString.lowercased()
            )
        )
        switch result {
        case .applied, .duplicate, .ignoredIneligible:
            var acknowledged = inFlight
            acknowledged.state = .acknowledged
            acknowledged.nextAttemptAt = nil
            let terminalRevision = try await persist(
                record: acknowledged,
                key: stored.key,
                expectedRevision: inFlightRevision
            )
            try await compact(key: stored.key, expectedRevision: terminalRevision)
        case .rejectedPermanent(let reason):
            var rejected = inFlight
            rejected.state = .permanentlyRejected
            rejected.nextAttemptAt = nil
            rejected.diagnosticCode = reason
            let terminalRevision = try await persist(
                record: rejected,
                key: stored.key,
                expectedRevision: inFlightRevision
            )
            try await compact(key: stored.key, expectedRevision: terminalRevision)
        case .deferredUnsupportedSchema:
            try await retain(
                record: inFlight,
                key: stored.key,
                expectedRevision: inFlightRevision,
                diagnosticCode: ProgressionRejectionCode(
                    rawValue: "deferred.unsupported-schema"
                )!
            )
        case .deferredStoreUnavailable:
            try await retain(
                record: inFlight,
                key: stored.key,
                expectedRevision: inFlightRevision,
                diagnosticCode: ProgressionRejectionCode(
                    rawValue: "deferred.store-unavailable"
                )!
            )
        }
    }

    private func retain(
        record: Record,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64,
        diagnosticCode: ProgressionRejectionCode
    ) async throws {
        var retained = record
        retained.state = .ready
        retained.diagnosticCode = diagnosticCode
        _ = try await persist(
            record: retained,
            key: key,
            expectedRevision: expectedRevision
        )
        scheduleRetry(at: retained.nextAttemptAt ?? environment.now())
    }

    private func persist(
        record: Record,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64
    ) async throws -> UInt64 {
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(record),
                        expectedRevision: .exact(expectedRevision)
                    )
                ),
            ]
        )
        let result = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
        guard let revision = result.mutations.first?.revision else {
            throw ModuleStateStoreError.corrupt
        }
        return revision
    }

    private func persistBatchReceipt(
        _ receipt: BatchReceiptRecord,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64
    ) async throws -> UInt64 {
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(receipt),
                        expectedRevision: .exact(expectedRevision)
                    )
                ),
            ]
        )
        let result = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
        guard let revision = result.mutations.first?.revision else {
            throw ModuleStateStoreError.corrupt
        }
        return revision
    }

    private func persistShareCompletion(
        _ record: ShareCompletionRecord,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64
    ) async throws -> UInt64 {
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try encode(record),
                        expectedRevision: .exact(expectedRevision)
                    )
                ),
            ]
        )
        let result = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
        guard let revision = result.mutations.first?.revision else {
            throw ModuleStateStoreError.corrupt
        }
        return revision
    }

    private func compactReceiptsIfAllAcknowledged(
        contextID: RuntimeOperationID,
        contextDigest: Data,
        totalBatchCount: UInt32,
        totalFactCount: UInt32,
        sourceModuleID: ModuleIdentifier
    ) async throws {
        guard totalBatchCount > 0,
              totalBatchCount <= UInt32(
                  ProgressionEventFactBatch.maximumBatchesPerOperation
              )
        else {
            throw ModuleStateStoreError.corrupt
        }
        var storedReceipts: [ModuleStateRecord] = []
        storedReceipts.reserveCapacity(Int(totalBatchCount))
        for batchIndex in 0 ..< totalBatchCount {
            let key = batchReceiptKey(
                contextID: contextID,
                batchIndex: batchIndex
            )
            guard let stored = try await state.runtimeFetch(
                namespace: Self.namespace,
                key: key
            ) else {
                return
            }
            let receipt: BatchReceiptRecord = try decode(
                stored.payload,
                as: BatchReceiptRecord.self
            )
            guard receipt.contextID == contextID,
                  receipt.contextDigest == contextDigest,
                  receipt.batchIndex == batchIndex,
                  receipt.totalBatchCount == totalBatchCount,
                  receipt.totalFactCount == totalFactCount,
                  receipt.sourceModuleID == sourceModuleID
            else {
                throw RuntimeProgressionOutboxSubmissionError.conflictingBatch
            }
            guard receipt.acknowledgedAt != nil else { return }
            storedReceipts.append(stored)
        }
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: storedReceipts.map { stored in
                .delete(
                    ModuleStateDelete(
                        key: stored.key,
                        expectedRevision: .exact(stored.revision)
                    )
                )
            }
        )
        _ = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
    }

    private func compact(stored: ModuleStateRecord) async throws {
        try await compact(key: stored.key, expectedRevision: stored.revision)
    }

    private func compact(
        key: ModuleStateRecordKey,
        expectedRevision: UInt64
    ) async throws {
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .delete(
                    ModuleStateDelete(
                        key: key,
                        expectedRevision: .exact(expectedRevision)
                    )
                ),
            ]
        )
        _ = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
    }

    private func loadAllRecords() async throws -> [(ModuleStateRecord, Record)] {
        var output: [(ModuleStateRecord, Record)] = []
        var cursor: ModuleStateScanCursor?
        repeat {
            let request = try ModuleStateScanRequest(
                collectionID: Self.collectionID,
                limit: Self.maximumBatchSize,
                cursor: cursor
            )
            let page = try await state.runtimeScan(namespace: Self.namespace, request: request)
            for stored in page.records {
                do {
                    output.append((stored, try decode(stored.payload)))
                } catch {
                    _ = try? await state.runtimeQuarantine(
                        namespace: Self.namespace,
                        diagnosticCode: "outbox-record-decode-failed"
                    )
                    throw ModuleStateStoreError.corrupt
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        return output.sorted { lhs, rhs in
            if lhs.1.envelope.occurredAt != rhs.1.envelope.occurredAt {
                return lhs.1.envelope.occurredAt < rhs.1.envelope.occurredAt
            }
            if lhs.1.producerOperationID != rhs.1.producerOperationID {
                return (lhs.1.producerOperationID?.rawValue ?? "")
                    < (rhs.1.producerOperationID?.rawValue ?? "")
            }
            if lhs.1.factSlot != rhs.1.factSlot {
                return (lhs.1.factSlot?.rawValue ?? 0)
                    < (rhs.1.factSlot?.rawValue ?? 0)
            }
            return lhs.1.envelope.eventID < rhs.1.envelope.eventID
        }
    }

    private func loadAllShareCompletionRecords() async throws
        -> [(ModuleStateRecord, ShareCompletionRecord)]
    {
        var output: [(ModuleStateRecord, ShareCompletionRecord)] = []
        var cursor: ModuleStateScanCursor?
        repeat {
            let request = try ModuleStateScanRequest(
                collectionID: Self.shareCompletionCollectionID,
                limit: Self.maximumBatchSize,
                cursor: cursor
            )
            let page = try await state.runtimeScan(
                namespace: Self.namespace,
                request: request
            )
            for stored in page.records {
                do {
                    let record: ShareCompletionRecord = try decode(
                        stored.payload,
                        as: ShareCompletionRecord.self
                    )
                    guard stored.key == shareCompletionKey(
                        for: record.artifactID
                    ) else { throw ModuleStateStoreError.corrupt }
                    if let evidence = record.evidence {
                        try verify(evidence.operationContext)
                        guard evidence.artifactID == record.artifactID,
                              evidence.report.isTerminal
                        else { throw ModuleStateStoreError.corrupt }
                    } else {
                        guard record.attemptCount == 0,
                              record.lastAttemptAt == nil,
                              record.nextAttemptAt == nil
                        else { throw ModuleStateStoreError.corrupt }
                    }
                    output.append((stored, record))
                } catch {
                    _ = try? await state.runtimeQuarantine(
                        namespace: Self.namespace,
                        diagnosticCode: "share-completion-record-invalid"
                    )
                    throw ModuleStateStoreError.corrupt
                }
            }
            cursor = page.nextCursor
        } while cursor != nil
        guard output.count <= Self.maximumShareCompletionCount else {
            throw ModuleStateStoreError.corrupt
        }
        return output.sorted { lhs, rhs in
            let left = lhs.1.evidence?.operationContext.runtimeOccurredAtUTC
                ?? lhs.1.reservedAt
            let right = rhs.1.evidence?.operationContext.runtimeOccurredAtUTC
                ?? rhs.1.reservedAt
            if left != right { return left < right }
            return lhs.1.artifactID.rawValue.uuidString
                < rhs.1.artifactID.rawValue.uuidString
        }
    }

    private func issueContext(
        operationIdentifier: RuntimeOperationIdentifier
    ) throws -> RuntimePersistableOperationContext {
        guard runtimeIsActive, runtimeGeneration > 0 else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        let operationUUID = environment.nextUUID()
        return try makeContext(
            operationID: RuntimeOperationID(
                "\(operationUUID.uuidString.lowercased())-background"
            ),
            correlationID: RuntimeCorrelationID(
                environment.nextUUID().uuidString.lowercased()
            ),
            occurredAtUTC: environment.now(),
            operationIdentifier: operationIdentifier,
            runtimeGeneration: runtimeGeneration
        )
    }

    private func makeContext(
        operationID: RuntimeOperationID,
        correlationID: RuntimeCorrelationID,
        occurredAtUTC: Date,
        operationIdentifier: RuntimeOperationIdentifier,
        runtimeGeneration: UInt64
    ) throws -> RuntimePersistableOperationContext {
        guard let contextAuthority else {
            throw ModuleStateStoreError.unavailable
        }
        let normalizedOccurredAtUTC = try RuntimePersistableOperationContext
            .normalizedOccurredAtUTC(occurredAtUTC)
        let nonce = environment.nextUUID()
        let claims = OperationContextAuthorityClaims(
            schemaVersion: 1,
            operationID: operationID,
            correlationID: correlationID,
            occurredAtUTC: normalizedOccurredAtUTC,
            operationIdentifier: operationIdentifier,
            runtimeGeneration: runtimeGeneration,
            authorityNonce: nonce,
            authorityScope: contextAuthorityScope
        )
        let tag = contextAuthority.authenticationCode(for: try encode(claims))
        return try RuntimePersistableOperationContext(
            operationID: operationID,
            correlationID: correlationID,
            occurredAtUTC: normalizedOccurredAtUTC,
            operationIdentifier: operationIdentifier,
            runtimeGeneration: runtimeGeneration,
            authorityNonce: nonce,
            authorityTag: tag,
            authorityScope: contextAuthorityScope
        )
    }

    private func verify(_ context: RuntimePersistableOperationContext) throws {
        guard let contextAuthority else {
            throw ModuleStateStoreError.unavailable
        }
        let claims = OperationContextAuthorityClaims(
            schemaVersion: 1,
            operationID: context.runtimeOperationID,
            correlationID: context.runtimeCorrelationID,
            occurredAtUTC: context.runtimeOccurredAtUTC,
            operationIdentifier: context.runtimeOperationIdentifier,
            runtimeGeneration: context.issuingRuntimeGeneration,
            authorityNonce: context.runtimeAuthorityNonce,
            authorityScope: context.authorityScope
        )
        let isValid = contextAuthority.isValidAuthenticationCode(
            context.runtimeAuthorityTag,
            for: try encode(claims)
        )
        guard isValid else {
            throw RuntimeProgressionOutboxSubmissionError.invalidOperationContext
        }
    }

    private func loadOrCreateContextAuthorityKey() async throws {
        let key = contextAuthorityRecordKey()
        if let stored = try await state.runtimeFetch(
            namespace: Self.contextAuthorityNamespace,
            key: key
        ) {
            try installContextAuthorityKey(from: stored.payload)
            return
        }

        let keyData = randomContextAuthorityKeyData()
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: keyData,
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        do {
            _ = try await state.runtimeTransact(
                namespace: Self.contextAuthorityNamespace,
                transaction: transaction
            )
            try installContextAuthorityKey(from: keyData)
        } catch {
            guard let stored = try await state.runtimeFetch(
                namespace: Self.contextAuthorityNamespace,
                key: key
            ) else {
                throw error
            }
            try installContextAuthorityKey(from: stored.payload)
        }
    }

    private func installContextAuthorityKey(from data: Data) throws {
        guard data.count == 32 else { throw ModuleStateStoreError.corrupt }
        contextAuthority = RuntimeOperationContextAuthenticator(keyData: data)
        contextAuthorityScope = .persistent
    }

    private func installEphemeralContextAuthorityKey() {
        contextAuthority = RuntimeOperationContextAuthenticator(
            keyData: randomContextAuthorityKeyData()
        )
        contextAuthorityScope = .runtimeGeneration
    }

    private func randomContextAuthorityKeyData() -> Data {
        RuntimeOperationContextAuthenticator.randomKeyData()
    }

    private func contextAuthorityRecordKey() -> ModuleStateRecordKey {
        ModuleStateRecordKey(
            collectionID: Self.contextAuthorityCollectionID,
            recordID: Self.contextAuthorityRecordID
        )
    }

    private func recordKey(for eventID: EventID) -> ModuleStateRecordKey {
        ModuleStateRecordKey(
            collectionID: Self.collectionID,
            recordID: ModuleStateRecordID(
                rawValue: eventID.rawValue.uuidString.lowercased()
            )!
        )
    }

    private func batchReceiptKey(
        contextID: RuntimeOperationID,
        batchIndex: UInt32
    ) -> ModuleStateRecordKey {
        let digest = RuntimeCryptographicDigest.sha256(
            Data(contextID.rawValue.utf8)
        )
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ModuleStateRecordKey(
            collectionID: Self.receiptCollectionID,
            recordID: ModuleStateRecordID(
                rawValue: "batch-\(hex)-\(batchIndex)"
            )!
        )
    }

    private func shareCompletionKey(
        for artifactID: ShareArtifactID
    ) -> ModuleStateRecordKey {
        ModuleStateRecordKey(
            collectionID: Self.shareCompletionCollectionID,
            recordID: ModuleStateRecordID(
                rawValue: artifactID.rawValue.uuidString.lowercased()
            )!
        )
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode(_ data: Data) throws -> Record {
        try decode(data, as: Record.self)
    }

    private func decode<Value: Decodable>(
        _ data: Data,
        as _: Value.Type
    ) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Value.self, from: data)
    }

    private func digest<Value: Encodable>(_ value: Value) throws -> Data {
        RuntimeCryptographicDigest.sha256(try encode(value))
    }

    private func makeReceipt(
        from stored: BatchReceiptRecord,
        revision: UInt64
    ) throws -> ProgressionOutboxBatchReceipt {
        try ProgressionOutboxBatchReceipt(
            contextID: stored.contextID,
            batchIndex: stored.batchIndex,
            eventIDsBySlot: Dictionary(
                uniqueKeysWithValues: stored.events.map { ($0.slot, $0.eventID) }
            ),
            correlationID: stored.correlationID,
            durableAt: stored.durableAt,
            outboxRevision: revision
        )
    }

    private func setting(
        _ record: Record,
        state: RuntimeProgressionOutboxRecordState
    ) -> Record {
        var copy = record
        copy.state = state
        return copy
    }

    private func retryDelay(afterAttempt attempt: UInt16) -> TimeInterval {
        let exponent = min(Int(attempt), 12)
        return min(pow(2, Double(exponent)), Self.maximumRetryDelay)
    }

    private func scheduleRetry(at date: Date) {
        guard runtimeIsActive else { return }
        if let scheduledRetryAt, scheduledRetryAt <= date { return }
        retryTask?.cancel()
        scheduledRetryAt = date
        let delay = max(0, date.timeIntervalSince(environment.now()))
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self?.replayReady()
        }
    }

    private func scheduleShareCompletionRetry(at date: Date) {
        guard runtimeIsActive else { return }
        if let scheduledShareCompletionRetryAt,
           scheduledShareCompletionRetryAt <= date
        {
            return
        }
        shareCompletionRetryTask?.cancel()
        scheduledShareCompletionRetryAt = date
        let delay = max(0, date.timeIntervalSince(environment.now()))
        shareCompletionRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self?.replayShareCompletions()
        }
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }
}
