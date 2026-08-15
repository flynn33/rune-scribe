import Foundation
@_spi(RuntimeExistingUserMigrationAuthority) import RuneScribeContracts

public enum RuntimeExistingUserMigrationHandoffError: Error, Equatable, Sendable {
    case snapshotCollision
    case corruptRecord
}

enum RuntimeExistingUserMigrationHandoffState: String, Codable, Sendable {
    case assembling
    case ready
    case inFlight
    case terminal
}

public struct RuntimeExistingUserMigrationClient: Sendable {
    private let gateway: RuntimeExistingUserMigrationHandoff
    private let lease: ModuleContextLease
    private let sourceModuleID: ModuleIdentifier

    init(
        gateway: RuntimeExistingUserMigrationHandoff,
        lease: ModuleContextLease,
        sourceModuleID: ModuleIdentifier
    ) {
        self.gateway = gateway
        self.lease = lease
        self.sourceModuleID = sourceModuleID
    }

    /// Durably hands off one canonical migration snapshot. Progression
    /// availability does not affect acceptance once Runtime persistence commits.
    public func submit(
        _ snapshot: ExistingUserMigrationSnapshotDTO
    ) async throws -> ExistingUserMigrationHandoffReceipt {
        try await lease.requireActive()
        let receipt = try await gateway.submit(
            snapshot,
            sourceModuleID: sourceModuleID
        )
        try await lease.requireActive()
        return receipt
    }

    /// Hands off the complete privacy-safe Core snapshot. The schema-v1 path
    /// remains byte-for-byte compatible through 4,096 ciphers; larger inputs
    /// use Runtime-owned, bounded schema-v2 pages.
    public func submit(
        ciphers: [ExistingUserMigrationCipherDTO]
    ) async throws -> ExistingUserMigrationPagedHandoffReceipt {
        try await lease.requireActive()
        let receipt = try await gateway.submit(
            ciphers: ciphers,
            sourceModuleID: sourceModuleID
        )
        try await lease.requireActive()
        return receipt
    }
}

actor RuntimeExistingUserMigrationHandoff {
    private struct Record: Codable, Sendable {
        let snapshotDigest: Data
        let receipt: ExistingUserMigrationHandoffReceipt
        var snapshot: ExistingUserMigrationSnapshotDTO?
        var state: RuntimeExistingUserMigrationHandoffState
        var attemptCount: UInt16
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var terminalResult: ExistingUserMigrationApplyResult?
    }

    private struct PagedRecord: Codable, Sendable {
        let aggregateDigest: String
        let receipt: ExistingUserMigrationPagedHandoffReceipt
        var state: RuntimeExistingUserMigrationHandoffState
        var nextPageIndex: UInt32
        var attemptCount: UInt16
        var lastAttemptAt: Date?
        var nextAttemptAt: Date?
        var terminalResult: ExistingUserMigrationApplyResult?
    }

    private static let namespace = ModuleStateNamespace(
        moduleID: "com.runescribe.runtime.existing-user-migration-handoff"
    )
    private static let collectionID = ModuleStateCollectionID(
        rawValue: "progression.existing-user-migration"
    )!
    private static let recordID = ModuleStateRecordID(rawValue: "schema-v1")!
    private static let pagedRecordID = ModuleStateRecordID(
        rawValue: "schema-v2-manifest"
    )!
    private static let schemaVersion: UInt32 = 1
    private static let maximumRetryDelay: TimeInterval = 3_600

    private let state: RuntimeModuleStateGateway
    private let dispatcher: RuntimeOperationDispatcher
    private let environment: RuntimeEnvironment
    private var runtimeIsActive = false
    private var storageIsPrepared = false
    private var isReplaying = false
    private var retryTask: Task<Void, Never>?
    private var scheduledRetryAt: Date?
    private var isReplayingPaged = false
    private var pagedRetryTask: Task<Void, Never>?
    private var scheduledPagedRetryAt: Date?

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
        runtimeIsActive = true
        storageIsPrepared = false
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = nil
        pagedRetryTask?.cancel()
        pagedRetryTask = nil
        scheduledPagedRetryAt = nil
        do {
            try await prepareStorage()
        } catch {
            storageIsPrepared = false
        }
    }

    func runtimeDidStart() {
        guard runtimeIsActive else { return }
        Task {
            await replayReady()
            await replayPagedReady()
        }
    }

    func progressionDidActivate() {
        guard runtimeIsActive else { return }
        Task {
            await replayReady()
            await replayPagedReady()
        }
    }

    func deactivateRuntime() {
        runtimeIsActive = false
        storageIsPrepared = false
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = nil
        pagedRetryTask?.cancel()
        pagedRetryTask = nil
        scheduledPagedRetryAt = nil
    }

    func submit(
        _ snapshot: ExistingUserMigrationSnapshotDTO,
        sourceModuleID: ModuleIdentifier
    ) async throws -> ExistingUserMigrationHandoffReceipt {
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard sourceModuleID == RuneScribeModuleIDs.core else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: sourceModuleID,
                capability: RuneScribeCapabilities.progressionMigrationSubmit
            )
        }
        try await prepareStorage()

        let snapshotData = try encode(snapshot)
        guard snapshotData.count <= RuntimeModuleStateGateway.maximumPayloadBytes else {
            throw ModuleStateStoreError.payloadTooLarge(
                maximumBytes: RuntimeModuleStateGateway.maximumPayloadBytes
            )
        }
        let snapshotDigest = RuntimeCryptographicDigest.sha256(snapshotData)
        let key = Self.recordKey
        if let stored = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        ) {
            let record = try decode(stored.payload)
            try validateExisting(
                record,
                snapshot: snapshot,
                snapshotDigest: snapshotDigest
            )
            Task { await replayReady() }
            return record.receipt
        }

        let transactionID = ExistingUserMigrationTransactionID(
            rawValue: environment.nextUUID()
        )
        let receipt = try ExistingUserMigrationHandoffReceipt(
            transactionID: transactionID,
            snapshotSchemaVersion: snapshot.schemaVersion,
            cipherCount: UInt32(snapshot.ciphers.count),
            durableAt: environment.now()
        )
        let record = Record(
            snapshotDigest: snapshotDigest,
            receipt: receipt,
            snapshot: snapshot,
            state: .ready,
            attemptCount: 0,
            lastAttemptAt: nil,
            nextAttemptAt: receipt.durableAt,
            terminalResult: nil
        )
        let payload = try encode(record)
        guard payload.count <= RuntimeModuleStateGateway.maximumPayloadBytes else {
            throw ModuleStateStoreError.payloadTooLarge(
                maximumBytes: RuntimeModuleStateGateway.maximumPayloadBytes
            )
        }
        let transaction = try ModuleStateTransaction(
            transactionID: transactionID.rawValue,
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: payload,
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
            let originalError = error
            if let stored = try? await state.runtimeFetch(
                namespace: Self.namespace,
                key: key
            ) {
                let recovered = try decode(stored.payload)
                try validateExisting(
                    recovered,
                    snapshot: snapshot,
                    snapshotDigest: snapshotDigest
                )
                Task { await replayReady() }
                return recovered.receipt
            }
            throw originalError
        }
        Task { await replayReady() }
        return receipt
    }

    func submit(
        ciphers: [ExistingUserMigrationCipherDTO],
        sourceModuleID: ModuleIdentifier
    ) async throws -> ExistingUserMigrationPagedHandoffReceipt {
        guard ciphers.count <= Int(UInt32.max) else {
            throw ExistingUserMigrationContractError.tooManyAggregateCiphers(
                maximum: UInt32.max
            )
        }
        let canonical = ciphers.sorted {
            if $0.cipherToken != $1.cipherToken {
                return $0.cipherToken < $1.cipherToken
            }
            return $0.origin.rawValue < $1.origin.rawValue
        }
        guard Set(canonical.map(\.cipherToken)).count == canonical.count else {
            throw ExistingUserMigrationContractError.duplicateCipherToken
        }
        if canonical.count <= ExistingUserMigrationSnapshotDTO.maximumCipherCount {
            return try ExistingUserMigrationPagedHandoffReceipt(
                schemaV1: await submit(
                    try ExistingUserMigrationSnapshotDTO(ciphers: canonical),
                    sourceModuleID: sourceModuleID
                )
            )
        }
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard sourceModuleID == RuneScribeModuleIDs.core else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: sourceModuleID,
                capability: RuneScribeCapabilities.progressionMigrationSubmit
            )
        }
        try await prepareStorage()

        let pages = try stride(
            from: 0,
            to: canonical.count,
            by: ExistingUserMigrationSnapshotDTO.maximumCipherCount
        ).map { start in
            let end = min(
                start + ExistingUserMigrationSnapshotDTO.maximumCipherCount,
                canonical.count
            )
            return try ExistingUserMigrationSnapshotDTO(
                ciphers: Array(canonical[start ..< end])
            )
        }
        let aggregateDigest = try pagedAggregateDigest(
            pages: pages,
            totalCipherCount: UInt32(canonical.count)
        )
        let key = Self.pagedRecordKey
        var storedManifest = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        )
        var manifest: PagedRecord
        if let storedManifest {
            manifest = try decodePaged(storedManifest.payload)
            try validateExistingPaged(
                manifest,
                aggregateDigest: aggregateDigest,
                totalCipherCount: UInt32(canonical.count),
                pageCount: UInt32(pages.count)
            )
            if manifest.state == .terminal {
                return manifest.receipt
            }
        } else {
            let transactionID = ExistingUserMigrationTransactionID(
                rawValue: environment.nextUUID()
            )
            let receipt = try ExistingUserMigrationPagedHandoffReceipt(
                transactionID: transactionID,
                handoffSchemaVersion:
                    ExistingUserMigrationPageDTO.currentHandoffSchemaVersion,
                snapshotSchemaVersion:
                    ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
                cipherCount: UInt32(canonical.count),
                pageCount: UInt32(pages.count),
                durableAt: environment.now()
            )
            manifest = PagedRecord(
                aggregateDigest: aggregateDigest,
                receipt: receipt,
                state: .assembling,
                nextPageIndex: 0,
                attemptCount: 0,
                lastAttemptAt: nil,
                nextAttemptAt: nil,
                terminalResult: nil
            )
            storedManifest = try await insertPagedManifest(manifest)
        }

        for (index, page) in pages.enumerated() {
            try await persistPage(
                page,
                pageIndex: UInt32(index)
            )
        }

        if manifest.state == .assembling {
            guard let storedManifest else {
                throw RuntimeExistingUserMigrationHandoffError.corruptRecord
            }
            manifest.state = .ready
            manifest.nextPageIndex = 0
            manifest.nextAttemptAt = environment.now()
            do {
                _ = try await persistPaged(
                    manifest,
                    expectedRevision: storedManifest.revision
                )
            } catch {
                let originalError = error
                if let recovered = try? await state.runtimeFetch(
                    namespace: Self.namespace,
                    key: key
                ) {
                    let decoded = try decodePaged(recovered.payload)
                    try validateExistingPaged(
                        decoded,
                        aggregateDigest: aggregateDigest,
                        totalCipherCount: UInt32(canonical.count),
                        pageCount: UInt32(pages.count)
                    )
                    guard decoded.state != .assembling else {
                        throw originalError
                    }
                    manifest = decoded
                } else {
                    throw originalError
                }
            }
        }
        Task { await replayPagedReady() }
        return manifest.receipt
    }

    func replayReady() async {
        guard runtimeIsActive, storageIsPrepared, !isReplaying else { return }
        isReplaying = true
        defer { isReplaying = false }
        retryTask?.cancel()
        retryTask = nil
        scheduledRetryAt = nil

        let stored: ModuleStateRecord
        let record: Record
        do {
            guard let candidate = try await state.runtimeFetch(
                namespace: Self.namespace,
                key: Self.recordKey
            ) else { return }
            stored = candidate
            record = try decode(candidate.payload)
        } catch {
            scheduleRetry(at: environment.now().addingTimeInterval(1))
            return
        }

        guard record.state != .terminal else { return }
        if let retryAt = record.nextAttemptAt, retryAt > environment.now() {
            scheduleRetry(at: retryAt)
            return
        }
        do {
            try await deliver(record: record, stored: stored)
        } catch {
            scheduleRetry(
                at: environment.now().addingTimeInterval(
                    retryDelay(afterAttempt: record.attemptCount)
                )
            )
        }
    }

    private func deliver(record: Record, stored: ModuleStateRecord) async throws {
        guard let snapshot = record.snapshot else {
            throw RuntimeExistingUserMigrationHandoffError.corruptRecord
        }
        let attempt = record.attemptCount == UInt16.max
            ? UInt16.max
            : record.attemptCount + 1
        let attemptAt = environment.now()
        var inFlight = record
        inFlight.state = .inFlight
        inFlight.attemptCount = attempt
        inFlight.lastAttemptAt = attemptAt
        inFlight.nextAttemptAt = attemptAt.addingTimeInterval(
            retryDelay(afterAttempt: attempt)
        )
        let inFlightRevision = try await persist(
            inFlight,
            expectedRevision: stored.revision
        )

        let delivery = ExistingUserMigrationDeliveryDTO(
            transactionID: record.receipt.transactionID,
            snapshot: snapshot
        )
        let client = try await dispatcher.progressionMigrationCommandClient()
        let result = try await client.send(
            delivery,
            to: RuntimeProgressionEndpointCatalog.applyExistingUserMigration,
            idempotencyKey: RuntimeIdempotencyKey(
                record.receipt.transactionID.rawValue.uuidString.lowercased()
            )
        )

        if result.isTerminalAcknowledgement {
            var terminal = inFlight
            terminal.snapshot = nil
            terminal.state = .terminal
            terminal.nextAttemptAt = nil
            terminal.terminalResult = result
            _ = try await persist(
                terminal,
                expectedRevision: inFlightRevision
            )
        } else {
            var retained = inFlight
            retained.state = .ready
            retained.terminalResult = nil
            _ = try await persist(
                retained,
                expectedRevision: inFlightRevision
            )
            scheduleRetry(at: retained.nextAttemptAt ?? environment.now())
        }
    }

    func replayPagedReady() async {
        guard runtimeIsActive, storageIsPrepared, !isReplayingPaged else { return }
        isReplayingPaged = true
        defer { isReplayingPaged = false }
        pagedRetryTask?.cancel()
        pagedRetryTask = nil
        scheduledPagedRetryAt = nil

        let stored: ModuleStateRecord
        let record: PagedRecord
        do {
            guard let candidate = try await state.runtimeFetch(
                namespace: Self.namespace,
                key: Self.pagedRecordKey
            ) else { return }
            stored = candidate
            record = try decodePaged(candidate.payload)
        } catch {
            schedulePagedRetry(at: environment.now().addingTimeInterval(1))
            return
        }

        guard record.state != .assembling, record.state != .terminal else { return }
        if let retryAt = record.nextAttemptAt, retryAt > environment.now() {
            schedulePagedRetry(at: retryAt)
            return
        }
        do {
            try await deliverPaged(record: record, stored: stored)
        } catch {
            schedulePagedRetry(
                at: environment.now().addingTimeInterval(
                    retryDelay(afterAttempt: record.attemptCount)
                )
            )
        }
    }

    private func deliverPaged(
        record: PagedRecord,
        stored: ModuleStateRecord
    ) async throws {
        guard record.nextPageIndex < record.receipt.pageCount,
              let storedPage = try await state.runtimeFetch(
                namespace: Self.namespace,
                key: Self.pageRecordKey(record.nextPageIndex)
              )
        else {
            throw RuntimeExistingUserMigrationHandoffError.corruptRecord
        }
        let snapshot = try decodeSnapshot(storedPage.payload)
        let page = try ExistingUserMigrationPageDTO(
            pageIndex: record.nextPageIndex,
            pageCount: record.receipt.pageCount,
            totalCipherCount: record.receipt.cipherCount,
            aggregateDigest: record.aggregateDigest,
            snapshot: snapshot
        )
        let attempt = record.attemptCount == UInt16.max
            ? UInt16.max
            : record.attemptCount + 1
        let attemptAt = environment.now()
        var inFlight = record
        inFlight.state = .inFlight
        inFlight.attemptCount = attempt
        inFlight.lastAttemptAt = attemptAt
        inFlight.nextAttemptAt = attemptAt.addingTimeInterval(
            retryDelay(afterAttempt: attempt)
        )
        let inFlightRevision = try await persistPaged(
            inFlight,
            expectedRevision: stored.revision
        )

        let delivery = ExistingUserMigrationPageDeliveryDTO(
            transactionID: record.receipt.transactionID,
            page: page
        )
        let client = try await dispatcher.progressionMigrationCommandClient()
        let result = try await client.send(
            delivery,
            to: RuntimeProgressionEndpointCatalog.applyExistingUserMigrationPage,
            idempotencyKey: RuntimeIdempotencyKey(
                "\(record.receipt.transactionID.rawValue.uuidString.lowercased())-page-\(record.nextPageIndex)"
            )
        )

        switch result {
        case let .accepted(pageIndex):
            guard pageIndex == record.nextPageIndex else {
                throw RuntimeExistingUserMigrationHandoffError.corruptRecord
            }
            var ready = inFlight
            ready.state = .ready
            ready.attemptCount = 0
            ready.lastAttemptAt = nil
            ready.nextAttemptAt = environment.now()
            ready.nextPageIndex = pageIndex + 1 < record.receipt.pageCount
                ? pageIndex + 1
                : 0
            _ = try await persistPaged(
                ready,
                expectedRevision: inFlightRevision
            )
            Task { await replayPagedReady() }
        case let .outcome(outcome) where outcome.isTerminalAcknowledgement:
            var terminal = inFlight
            terminal.state = .terminal
            terminal.nextAttemptAt = nil
            terminal.terminalResult = outcome
            _ = try await persistPaged(
                terminal,
                expectedRevision: inFlightRevision
            )
        case .outcome:
            var retained = inFlight
            retained.state = .ready
            retained.terminalResult = nil
            _ = try await persistPaged(
                retained,
                expectedRevision: inFlightRevision
            )
            schedulePagedRetry(at: retained.nextAttemptAt ?? environment.now())
        }
    }

    private func validateExisting(
        _ record: Record,
        snapshot: ExistingUserMigrationSnapshotDTO,
        snapshotDigest: Data
    ) throws {
        guard record.receipt.snapshotSchemaVersion == snapshot.schemaVersion,
              record.receipt.cipherCount == UInt32(snapshot.ciphers.count),
              record.snapshotDigest == snapshotDigest
        else {
            throw RuntimeExistingUserMigrationHandoffError.snapshotCollision
        }
        if let retained = record.snapshot, retained != snapshot {
            throw RuntimeExistingUserMigrationHandoffError.snapshotCollision
        }
        guard record.state == .terminal || record.snapshot != nil else {
            throw RuntimeExistingUserMigrationHandoffError.corruptRecord
        }
    }

    private func validateExistingPaged(
        _ record: PagedRecord,
        aggregateDigest: String,
        totalCipherCount: UInt32,
        pageCount: UInt32
    ) throws {
        guard record.aggregateDigest == aggregateDigest,
              record.receipt.handoffSchemaVersion ==
                ExistingUserMigrationPageDTO.currentHandoffSchemaVersion,
              record.receipt.snapshotSchemaVersion ==
                ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              record.receipt.cipherCount == totalCipherCount,
              record.receipt.pageCount == pageCount,
              record.nextPageIndex < pageCount,
              record.state != .terminal || record.terminalResult != nil,
              record.state == .terminal || record.terminalResult == nil
        else {
            throw RuntimeExistingUserMigrationHandoffError.snapshotCollision
        }
    }

    private func insertPagedManifest(
        _ record: PagedRecord
    ) async throws -> ModuleStateRecord {
        let payload = try encode(record)
        guard payload.count <= RuntimeModuleStateGateway.maximumPayloadBytes else {
            throw ModuleStateStoreError.payloadTooLarge(
                maximumBytes: RuntimeModuleStateGateway.maximumPayloadBytes
            )
        }
        let transaction = try ModuleStateTransaction(
            transactionID: record.receipt.transactionID.rawValue,
            mutations: [.upsert(ModuleStateUpsert(
                key: Self.pagedRecordKey,
                schemaVersion: Self.schemaVersion,
                payload: payload,
                expectedRevision: .absent
            ))]
        )
        do {
            _ = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
        } catch {
            let originalError = error
            guard let recovered = try? await state.runtimeFetch(
                namespace: Self.namespace,
                key: Self.pagedRecordKey
            ) else { throw originalError }
            let decoded = try decodePaged(recovered.payload)
            try validateExistingPaged(
                decoded,
                aggregateDigest: record.aggregateDigest,
                totalCipherCount: record.receipt.cipherCount,
                pageCount: record.receipt.pageCount
            )
            return recovered
        }
        guard let stored = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: Self.pagedRecordKey
        ) else {
            throw RuntimeExistingUserMigrationHandoffError.corruptRecord
        }
        return stored
    }

    private func persistPage(
        _ snapshot: ExistingUserMigrationSnapshotDTO,
        pageIndex: UInt32
    ) async throws {
        let key = Self.pageRecordKey(pageIndex)
        let payload = try encode(snapshot)
        guard payload.count <= RuntimeModuleStateGateway.maximumPayloadBytes else {
            throw ModuleStateStoreError.payloadTooLarge(
                maximumBytes: RuntimeModuleStateGateway.maximumPayloadBytes
            )
        }
        if let existing = try await state.runtimeFetch(
            namespace: Self.namespace,
            key: key
        ) {
            guard existing.payload == payload else {
                throw RuntimeExistingUserMigrationHandoffError.snapshotCollision
            }
            return
        }
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [.upsert(ModuleStateUpsert(
                key: key,
                schemaVersion: Self.schemaVersion,
                payload: payload,
                expectedRevision: .absent
            ))]
        )
        do {
            _ = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
        } catch {
            let originalError = error
            guard let recovered = try? await state.runtimeFetch(
                namespace: Self.namespace,
                key: key
            ), recovered.payload == payload else {
                throw originalError
            }
        }
    }

    private func pagedAggregateDigest(
        pages: [ExistingUserMigrationSnapshotDTO],
        totalCipherCount: UInt32
    ) throws -> String {
        var material = Data("existing-user-migration-paged-v2".utf8)
        append(totalCipherCount, to: &material)
        append(UInt32(pages.count), to: &material)
        for (index, page) in pages.enumerated() {
            append(UInt32(index), to: &material)
            material.append(RuntimeCryptographicDigest.sha256(try encode(page)))
        }
        return RuntimeIntegrityDigest.sha256Hex(material)
    }

    private func append(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private func prepareStorage() async throws {
        guard runtimeIsActive else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        if storageIsPrepared { return }
        let health = try await state.runtimePrepare(
            namespace: Self.namespace,
            schemaVersion: Self.schemaVersion
        )
        guard health.accessDisposition == .readWrite else {
            throw ModuleStateStoreError.quarantined
        }
        storageIsPrepared = true
    }

    private func persist(
        _ record: Record,
        expectedRevision: UInt64
    ) async throws -> UInt64 {
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: Self.recordKey,
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
            throw RuntimeExistingUserMigrationHandoffError.corruptRecord
        }
        return revision
    }

    private func persistPaged(
        _ record: PagedRecord,
        expectedRevision: UInt64
    ) async throws -> UInt64 {
        let payload = try encode(record)
        guard payload.count <= RuntimeModuleStateGateway.maximumPayloadBytes else {
            throw ModuleStateStoreError.payloadTooLarge(
                maximumBytes: RuntimeModuleStateGateway.maximumPayloadBytes
            )
        }
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [.upsert(ModuleStateUpsert(
                key: Self.pagedRecordKey,
                schemaVersion: Self.schemaVersion,
                payload: payload,
                expectedRevision: .exact(expectedRevision)
            ))]
        )
        let result = try await state.runtimeTransact(
            namespace: Self.namespace,
            transaction: transaction
        )
        guard let revision = result.mutations.first?.revision else {
            throw RuntimeExistingUserMigrationHandoffError.corruptRecord
        }
        return revision
    }

    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode(_ data: Data) throws -> Record {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(Record.self, from: data)
    }

    private func decodePaged(_ data: Data) throws -> PagedRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(PagedRecord.self, from: data)
    }

    private func decodeSnapshot(_ data: Data) throws -> ExistingUserMigrationSnapshotDTO {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(ExistingUserMigrationSnapshotDTO.self, from: data)
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

    private func schedulePagedRetry(at date: Date) {
        guard runtimeIsActive else { return }
        if let scheduledPagedRetryAt, scheduledPagedRetryAt <= date { return }
        pagedRetryTask?.cancel()
        scheduledPagedRetryAt = date
        let delay = max(0, date.timeIntervalSince(environment.now()))
        pagedRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await self?.replayPagedReady()
        }
    }

    private static var recordKey: ModuleStateRecordKey {
        ModuleStateRecordKey(collectionID: collectionID, recordID: recordID)
    }

    private static var pagedRecordKey: ModuleStateRecordKey {
        ModuleStateRecordKey(collectionID: collectionID, recordID: pagedRecordID)
    }

    private static func pageRecordKey(_ pageIndex: UInt32) -> ModuleStateRecordKey {
        let digits = String(pageIndex)
        let padded = String(repeating: "0", count: 10 - digits.count) + digits
        return ModuleStateRecordKey(
            collectionID: collectionID,
            recordID: ModuleStateRecordID(rawValue: "schema-v2-page-\(padded)")!
        )
    }
}
