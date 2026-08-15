import CryptoKit
import Foundation
import RuneScribeContracts

public enum InMemoryModuleStateFaultPoint: String, Codable, Hashable, Sendable {
    case prepare
    case fetch
    case scan
    case beforeTransactionCommit
    case afterTransactionCommit
    case quarantine
    case quarantineRecord
    case afterQuarantineRecord
}

public actor InMemoryModuleStateStore: ModuleStateStore {
    private struct FaultPlan: Sendable {
        var successfulCallsBeforeFault: Int
        var remainingFaultCount: Int
    }

    private struct NamespaceState: Sendable {
        struct CompletedTransaction: Sendable {
            let request: ModuleStateTransaction
            let result: ModuleStateTransactionResult
        }

        var loadState: ModuleStateLoadState
        var schemaVersion: UInt32?
        var storeRevision: UInt64
        var records: [ModuleStateRecordKey: ModuleStateRecord]
        var quarantinedRecordKeys: Set<ModuleStateRecordKey>
        var completedTransactions: [UUID: CompletedTransaction]
        var diagnosticCode: String?
        var blocksAccess: Bool

        static let absent = NamespaceState(
            loadState: .absent,
            schemaVersion: nil,
            storeRevision: 0,
            records: [:],
            quarantinedRecordKeys: [],
            completedTransactions: [:],
            diagnosticCode: nil,
            blocksAccess: false
        )
    }

    private let now: @Sendable () -> Date
    private var namespaces: [ModuleStateNamespace: NamespaceState] = [:]
    private var faultPlans: [InMemoryModuleStateFaultPoint: [FaultPlan]] = [:]

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func injectFault(
        at point: InMemoryModuleStateFaultPoint,
        afterSuccessfulCalls: Int = 0,
        count: Int = 1
    ) {
        guard count > 0 else { return }
        faultPlans[point, default: []].append(
            FaultPlan(
                successfulCallsBeforeFault: max(0, afterSuccessfulCalls),
                remainingFaultCount: count
            )
        )
    }

    public func corruptIntegrityDigest(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey
    ) {
        guard var state = namespaces[namespace],
              let record = state.records[key]
        else { return }
        state.records[key] = ModuleStateRecord(
            key: record.key,
            schemaVersion: record.schemaVersion,
            revision: record.revision,
            payload: record.payload,
            integrityDigest: Data(repeating: 0, count: 32),
            updatedAt: record.updatedAt
        )
        namespaces[namespace] = state
    }

    public func prepareNamespace(
        _ namespace: ModuleStateNamespace,
        schemaVersion: UInt32
    ) async throws -> ModuleStateHealthSnapshot {
        try consumeFault(.prepare)
        guard schemaVersion > 0 else { throw ModuleStateStoreError.invalidRequest }
        var state = namespaces[namespace] ?? .absent
        if state.schemaVersion == nil {
            state.schemaVersion = schemaVersion
            state.loadState = .absent
            state.diagnosticCode = nil
            state.blocksAccess = false
        } else if state.loadState == .quarantined || state.loadState == .corrupt {
            return snapshot(namespace: namespace, state: state)
        } else if let currentSchemaVersion = state.schemaVersion,
                  currentSchemaVersion < schemaVersion {
            state.schemaVersion = schemaVersion
            state.storeRevision = try incrementing(state.storeRevision)
            state.loadState = .migrated
            state.diagnosticCode = nil
            state.blocksAccess = false
        } else if let currentSchemaVersion = state.schemaVersion,
                  currentSchemaVersion > schemaVersion {
            if state.loadState != .unreadable {
                state.storeRevision = try incrementing(state.storeRevision)
                state.loadState = .unreadable
                state.diagnosticCode = "module-state-schema-newer-than-runtime"
                state.blocksAccess = true
            }
        } else if state.loadState == .unreadable {
            state.loadState = .loaded
            state.diagnosticCode = nil
            state.blocksAccess = false
        }
        namespaces[namespace] = state
        return snapshot(namespace: namespace, state: state)
    }

    public func fetch(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey
    ) async throws -> ModuleStateRecord? {
        try consumeFault(.fetch)
        guard var state = namespaces[namespace] else { return nil }
        try requireUsable(state)
        guard let record = state.records[key] else { return nil }
        guard !state.quarantinedRecordKeys.contains(key) else {
            throw ModuleStateStoreError.quarantined
        }
        guard verify(record: record, namespace: namespace) else {
            state.storeRevision = try incrementing(state.storeRevision)
            state.quarantinedRecordKeys.insert(key)
            state.loadState = .quarantined
            state.diagnosticCode = "integrity-mismatch"
            state.blocksAccess = false
            namespaces[namespace] = state
            throw ModuleStateStoreError.integrityMismatch
        }
        return record
    }

    public func scan(
        namespace: ModuleStateNamespace,
        request: ModuleStateScanRequest
    ) async throws -> ModuleStateScanPage {
        try consumeFault(.scan)
        guard var state = namespaces[namespace] else {
            return ModuleStateScanPage(records: [], nextCursor: nil)
        }
        try requireUsable(state)
        if let cursor = request.cursor,
           cursor.observedStoreRevision != state.storeRevision
        {
            throw ModuleStateStoreError.invalidRequest
        }

        let ordered = state.records.values
            .filter { record in
                guard record.key.collectionID == request.collectionID else { return false }
                guard !state.quarantinedRecordKeys.contains(record.key) else { return false }
                guard let cursor = request.cursor else { return true }
                return record.key.recordID > cursor.afterRecordID
            }
            .sorted { $0.key.recordID < $1.key.recordID }

        var validRecords: [ModuleStateRecord] = []
        var quarantinedInvalidRecord = false
        for record in ordered {
            if verify(record: record, namespace: namespace) {
                validRecords.append(record)
                if validRecords.count > request.limit { break }
            } else {
                state.quarantinedRecordKeys.insert(record.key)
                quarantinedInvalidRecord = true
            }
        }
        if quarantinedInvalidRecord {
            state.storeRevision = try incrementing(state.storeRevision)
            state.loadState = .quarantined
            state.diagnosticCode = "integrity-mismatch"
            state.blocksAccess = false
            namespaces[namespace] = state
        }
        let records = Array(validRecords.prefix(request.limit))
        let nextCursor: ModuleStateScanCursor?
        if validRecords.count > records.count, let last = records.last {
            nextCursor = ModuleStateScanCursor(
                collectionID: request.collectionID,
                afterRecordID: last.key.recordID,
                observedStoreRevision: state.storeRevision
            )
        } else {
            nextCursor = nil
        }
        return ModuleStateScanPage(records: records, nextCursor: nextCursor)
    }

    public func transact(
        namespace: ModuleStateNamespace,
        transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        var state = namespaces[namespace] ?? .absent
        try requireUsable(state)
        if let existing = state.completedTransactions[transaction.transactionID] {
            guard existing.request == transaction else {
                throw ModuleStateStoreError.invalidRequest
            }
            return existing.result
        }
        guard state.schemaVersion != nil else { throw ModuleStateStoreError.unavailable }

        var transactionPayloadBytes = 0
        for mutation in transaction.mutations {
            guard case .upsert(let value) = mutation else { continue }
            guard value.schemaVersion > 0 else {
                throw ModuleStateStoreError.invalidRequest
            }
            guard value.payload.count <= 1_048_576 else {
                throw ModuleStateStoreError.payloadTooLarge(maximumBytes: 1_048_576)
            }
            transactionPayloadBytes += value.payload.count
        }
        guard transactionPayloadBytes <= 8_388_608 else {
            throw ModuleStateStoreError.payloadTooLarge(maximumBytes: 8_388_608)
        }

        for mutation in transaction.mutations {
            let current = state.records[mutation.key]
            guard !state.quarantinedRecordKeys.contains(mutation.key) else {
                throw ModuleStateStoreError.quarantined
            }
            let expectation: ModuleStateRevisionExpectation
            switch mutation {
            case .upsert(let value): expectation = value.expectedRevision
            case .delete(let value): expectation = value.expectedRevision
            }
            try validate(
                expectation,
                current: current,
                key: mutation.key
            )
            if case .upsert = mutation, current?.revision == UInt64.max {
                throw ModuleStateStoreError.corrupt
            }
        }

        try consumeFault(.beforeTransactionCommit)
        let committedAt = now()
        let nextStoreRevision = try incrementing(state.storeRevision)
        var results: [ModuleStateMutationResult] = []
        for mutation in transaction.mutations {
            switch mutation {
            case .upsert(let value):
                let recordRevision = (state.records[value.key]?.revision ?? 0) + 1
                let record = makeRecord(
                    namespace: namespace,
                    value: value,
                    revision: recordRevision,
                    updatedAt: committedAt
                )
                state.records[value.key] = record
                results.append(
                    ModuleStateMutationResult(key: value.key, revision: recordRevision)
                )
            case .delete(let value):
                state.records.removeValue(forKey: value.key)
                results.append(ModuleStateMutationResult(key: value.key, revision: nil))
            }
        }
        state.storeRevision = nextStoreRevision
        if state.loadState == .absent || state.loadState == .migrated {
            state.loadState = .loaded
        }
        let result = ModuleStateTransactionResult(
            transactionID: transaction.transactionID,
            storeRevision: nextStoreRevision,
            mutations: results
        )
        state.completedTransactions[transaction.transactionID] = .init(
            request: transaction,
            result: result
        )
        namespaces[namespace] = state
        try consumeFault(.afterTransactionCommit)
        return result
    }

    public func quarantine(
        namespace: ModuleStateNamespace,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try consumeFault(.quarantine)
        guard isValidDiagnosticCode(diagnosticCode) else {
            throw ModuleStateStoreError.invalidRequest
        }
        guard var state = namespaces[namespace] else {
            throw ModuleStateStoreError.unavailable
        }
        if !state.blocksAccess {
            state.storeRevision = try incrementing(state.storeRevision)
        }
        state.loadState = .quarantined
        state.diagnosticCode = diagnosticCode
        state.blocksAccess = true
        namespaces[namespace] = state
        return snapshot(namespace: namespace, state: state)
    }

    public func quarantineRecord(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try consumeFault(.quarantineRecord)
        guard expectedRevision > 0,
              isValidDiagnosticCode(diagnosticCode)
        else {
            throw ModuleStateStoreError.invalidRequest
        }
        guard var state = namespaces[namespace] else {
            throw ModuleStateStoreError.unavailable
        }
        try requireUsable(state)
        guard let record = state.records[key] else {
            throw conflict(key: key, expected: expectedRevision, actual: nil)
        }
        guard record.revision == expectedRevision else {
            throw conflict(
                key: key,
                expected: expectedRevision,
                actual: record.revision
            )
        }
        if state.quarantinedRecordKeys.contains(key) {
            return snapshot(namespace: namespace, state: state)
        }
        state.storeRevision = try incrementing(state.storeRevision)
        state.quarantinedRecordKeys.insert(key)
        state.loadState = .quarantined
        state.diagnosticCode = diagnosticCode
        state.blocksAccess = false
        namespaces[namespace] = state
        try consumeFault(.afterQuarantineRecord)
        return snapshot(namespace: namespace, state: state)
    }

    public func health(
        namespace: ModuleStateNamespace
    ) async -> ModuleStateHealthSnapshot {
        snapshot(namespace: namespace, state: namespaces[namespace] ?? .absent)
    }

    public func recordCount(namespace: ModuleStateNamespace) -> Int {
        guard let state = namespaces[namespace] else { return 0 }
        return state.records.count - state.quarantinedRecordKeys.count
    }

    private func consumeFault(_ point: InMemoryModuleStateFaultPoint) throws {
        guard var plans = faultPlans[point], !plans.isEmpty else { return }
        if plans[0].successfulCallsBeforeFault > 0 {
            plans[0].successfulCallsBeforeFault -= 1
            faultPlans[point] = plans
            return
        }
        plans[0].remainingFaultCount -= 1
        if plans[0].remainingFaultCount == 0 {
            plans.removeFirst()
        }
        if plans.isEmpty {
            faultPlans.removeValue(forKey: point)
        } else {
            faultPlans[point] = plans
        }
        throw ModuleStateStoreError.injectedFailure(point.rawValue)
    }

    private func incrementing(_ revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else { throw ModuleStateStoreError.corrupt }
        return revision + 1
    }

    private func isValidDiagnosticCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 96 else { return false }
        var previousWasSeparator = false
        for (index, byte) in bytes.enumerated() {
            let isAlphaNumeric = (0x61 ... 0x7A).contains(byte)
                || (0x30 ... 0x39).contains(byte)
            if isAlphaNumeric {
                previousWasSeparator = false
                continue
            }
            let isSeparator = byte == 0x2D || byte == 0x2E
            guard isSeparator,
                  index > 0,
                  index < bytes.count - 1,
                  !previousWasSeparator
            else { return false }
            previousWasSeparator = true
        }
        return true
    }

    private func requireUsable(_ state: NamespaceState) throws {
        if state.blocksAccess {
            switch state.loadState {
            case .quarantined: throw ModuleStateStoreError.quarantined
            case .unreadable: throw ModuleStateStoreError.unreadable
            case .corrupt: throw ModuleStateStoreError.corrupt
            case .absent, .loaded, .migrated:
                throw ModuleStateStoreError.unavailable
            }
        }
        switch state.loadState {
        case .corrupt: throw ModuleStateStoreError.corrupt
        case .unreadable: throw ModuleStateStoreError.unreadable
        case .absent, .loaded, .migrated, .quarantined: return
        }
    }

    private func validate(
        _ expectation: ModuleStateRevisionExpectation,
        current: ModuleStateRecord?,
        key: ModuleStateRecordKey
    ) throws {
        switch expectation {
        case .any:
            return
        case .absent:
            guard current == nil else {
                throw conflict(key: key, expected: nil, actual: current?.revision)
            }
        case .exact(let revision):
            guard current?.revision == revision else {
                throw conflict(key: key, expected: revision, actual: current?.revision)
            }
        }
    }

    private func conflict(
        key: ModuleStateRecordKey,
        expected: UInt64?,
        actual: UInt64?
    ) -> ModuleStateStoreError {
        .revisionConflict(
            collectionID: key.collectionID,
            recordID: key.recordID,
            expected: expected,
            actual: actual
        )
    }

    private func makeRecord(
        namespace: ModuleStateNamespace,
        value: ModuleStateUpsert,
        revision: UInt64,
        updatedAt: Date
    ) -> ModuleStateRecord {
        let digest = integrityDigest(
            namespace: namespace,
            key: value.key,
            schemaVersion: value.schemaVersion,
            revision: revision,
            payload: value.payload
        )
        return ModuleStateRecord(
            key: value.key,
            schemaVersion: value.schemaVersion,
            revision: revision,
            payload: value.payload,
            integrityDigest: digest,
            updatedAt: updatedAt
        )
    }

    private func verify(
        record: ModuleStateRecord,
        namespace: ModuleStateNamespace
    ) -> Bool {
        record.integrityDigest == integrityDigest(
            namespace: namespace,
            key: record.key,
            schemaVersion: record.schemaVersion,
            revision: record.revision,
            payload: record.payload
        )
    }

    private func integrityDigest(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey,
        schemaVersion: UInt32,
        revision: UInt64,
        payload: Data
    ) -> Data {
        var material = Data()
        material.append(Data(namespace.moduleID.rawValue.utf8))
        material.append(0)
        material.append(Data(key.collectionID.rawValue.utf8))
        material.append(0)
        material.append(Data(key.recordID.rawValue.utf8))
        material.append(0)
        material.append(Data(String(schemaVersion).utf8))
        material.append(0)
        material.append(Data(String(revision).utf8))
        material.append(0)
        material.append(payload)
        return Data(SHA256.hash(data: material))
    }

    private func snapshot(
        namespace: ModuleStateNamespace,
        state: NamespaceState
    ) -> ModuleStateHealthSnapshot {
        ModuleStateHealthSnapshot(
            namespace: namespace,
            loadState: state.loadState,
            storeRevision: state.storeRevision,
            namespaceSchemaVersion: state.schemaVersion,
            recordCount: UInt64(
                state.records.count - state.quarantinedRecordKeys.count
            ),
            quarantinedRecordCount: UInt64(state.quarantinedRecordKeys.count),
            accessDisposition: state.blocksAccess ? .blocked : .readWrite,
            capturedAt: now(),
            diagnosticCode: state.diagnosticCode
        )
    }
}
