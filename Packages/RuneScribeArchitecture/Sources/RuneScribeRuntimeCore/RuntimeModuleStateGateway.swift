import Foundation
import RuneScribeContracts

struct RuntimeModuleStateLease: Sendable {
    let moduleID: ModuleIdentifier
    let moduleGeneration: UInt64
    let runtimeGeneration: UInt64
}

public struct RuntimeModuleStateClient: Sendable {
    private let gateway: RuntimeModuleStateGateway
    private let lease: RuntimeModuleStateLease

    fileprivate init(
        gateway: RuntimeModuleStateGateway,
        lease: RuntimeModuleStateLease
    ) {
        self.gateway = gateway
        self.lease = lease
    }

    public func prepare(schemaVersion: UInt32) async throws -> ModuleStateHealthSnapshot {
        try await gateway.prepare(lease: lease, schemaVersion: schemaVersion)
    }

    public func fetch(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID
    ) async throws -> ModuleStateRecord? {
        try await gateway.fetch(
            lease: lease,
            key: ModuleStateRecordKey(collectionID: collectionID, recordID: recordID)
        )
    }

    public func scan(_ request: ModuleStateScanRequest) async throws -> ModuleStateScanPage {
        try await gateway.scan(lease: lease, request: request)
    }

    public func transact(
        _ transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        try await gateway.transact(lease: lease, transaction: transaction)
    }

    public func quarantine(
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try await gateway.quarantine(lease: lease, diagnosticCode: diagnosticCode)
    }

    public func quarantineRecord(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try await gateway.quarantineRecord(
            lease: lease,
            key: ModuleStateRecordKey(
                collectionID: collectionID,
                recordID: recordID
            ),
            expectedRevision: expectedRevision,
            diagnosticCode: diagnosticCode
        )
    }

    public func health() async throws -> ModuleStateHealthSnapshot {
        try await gateway.health(lease: lease)
    }
}

actor RuntimeModuleStateGateway {
    static let maximumPayloadBytes = 1_048_576
    static let maximumTransactionPayloadBytes = 8_388_608

    private let policy: RuntimePolicy
    private var store: (any ModuleStateStore)?
    private var runtimeGeneration: UInt64 = 0
    private var runtimeIsActive = false
    private var activeModuleGenerations: [ModuleIdentifier: UInt64] = [:]

    init(policy: RuntimePolicy) {
        self.policy = policy
    }

    func install(_ store: any ModuleStateStore) throws {
        guard self.store == nil else {
            throw RuneScribeRuntimeError.duplicateService(
                RuneScribeServiceIDs.moduleStateStore
            )
        }
        self.store = store
    }

    func containsStore() -> Bool {
        store != nil
    }

    func activateRuntime() -> UInt64 {
        runtimeGeneration &+= 1
        runtimeIsActive = true
        activeModuleGenerations.removeAll(keepingCapacity: true)
        return runtimeGeneration
    }

    func deactivateRuntime() {
        runtimeIsActive = false
        activeModuleGenerations.removeAll(keepingCapacity: true)
    }

    func activateModule(descriptor: ModuleDescriptor, generation: UInt64) throws {
        if descriptor.requestedCapabilities.contains(RuneScribeCapabilities.moduleStateAccess) {
            guard policy.capabilities.allows(
                RuneScribeCapabilities.moduleStateAccess,
                for: descriptor.policyClass
            ) else {
                throw RuneScribeRuntimeError.capabilityDenied(
                    moduleID: descriptor.moduleID,
                    capability: RuneScribeCapabilities.moduleStateAccess
                )
            }
        }
        activeModuleGenerations[descriptor.moduleID] = generation
    }

    func invalidateModule(_ moduleID: ModuleIdentifier, generation: UInt64) {
        guard activeModuleGenerations[moduleID] == generation else { return }
        activeModuleGenerations.removeValue(forKey: moduleID)
    }

    func makeClient(
        descriptor: ModuleDescriptor,
        moduleGeneration: UInt64,
        runtimeGeneration expectedRuntimeGeneration: UInt64
    ) throws -> RuntimeModuleStateClient {
        guard descriptor.requestedCapabilities.contains(
            RuneScribeCapabilities.moduleStateAccess
        ),
        policy.capabilities.allows(
            RuneScribeCapabilities.moduleStateAccess,
            for: descriptor.policyClass
        ) else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: descriptor.moduleID,
                capability: RuneScribeCapabilities.moduleStateAccess
            )
        }
        let lease = RuntimeModuleStateLease(
            moduleID: descriptor.moduleID,
            moduleGeneration: moduleGeneration,
            runtimeGeneration: expectedRuntimeGeneration
        )
        try validate(lease)
        return RuntimeModuleStateClient(gateway: self, lease: lease)
    }

    func currentGeneration() -> UInt64 {
        runtimeGeneration
    }

    func prepare(
        lease: RuntimeModuleStateLease,
        schemaVersion: UInt32
    ) async throws -> ModuleStateHealthSnapshot {
        guard schemaVersion > 0 else { throw ModuleStateStoreError.invalidRequest }
        let store = try validatedStore(lease)
        let result = try await store.prepareNamespace(
            namespace(for: lease.moduleID),
            schemaVersion: schemaVersion
        )
        try validate(lease)
        return result
    }

    func fetch(
        lease: RuntimeModuleStateLease,
        key: ModuleStateRecordKey
    ) async throws -> ModuleStateRecord? {
        let store = try validatedStore(lease)
        let result = try await store.fetch(namespace: namespace(for: lease.moduleID), key: key)
        try validate(lease)
        try validateRecord(result)
        return result
    }

    func scan(
        lease: RuntimeModuleStateLease,
        request: ModuleStateScanRequest
    ) async throws -> ModuleStateScanPage {
        let store = try validatedStore(lease)
        let result = try await store.scan(
            namespace: namespace(for: lease.moduleID),
            request: request
        )
        try validate(lease)
        guard result.records.count <= request.limit,
              result.records.allSatisfy({ $0.key.collectionID == request.collectionID })
        else {
            throw ModuleStateStoreError.corrupt
        }
        for record in result.records {
            try validateRecord(record)
        }
        return result
    }

    func transact(
        lease: RuntimeModuleStateLease,
        transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        try validateTransaction(transaction)
        let store = try validatedStore(lease)
        let result = try await store.transact(
            namespace: namespace(for: lease.moduleID),
            transaction: transaction
        )
        try validate(lease)
        guard result.transactionID == transaction.transactionID,
              result.mutations.map(\.key) == transaction.mutations.map(\.key)
        else {
            throw ModuleStateStoreError.corrupt
        }
        return result
    }

    func quarantine(
        lease: RuntimeModuleStateLease,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        guard isBoundedDiagnosticCode(diagnosticCode) else {
            throw ModuleStateStoreError.invalidRequest
        }
        let store = try validatedStore(lease)
        let result = try await store.quarantine(
            namespace: namespace(for: lease.moduleID),
            diagnosticCode: diagnosticCode
        )
        try validate(lease)
        return result
    }

    func quarantineRecord(
        lease: RuntimeModuleStateLease,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        guard expectedRevision > 0,
              isBoundedDiagnosticCode(diagnosticCode)
        else {
            throw ModuleStateStoreError.invalidRequest
        }
        let store = try validatedStore(lease)
        let result = try await store.quarantineRecord(
            namespace: namespace(for: lease.moduleID),
            key: key,
            expectedRevision: expectedRevision,
            diagnosticCode: diagnosticCode
        )
        try validate(lease)
        return result
    }

    func health(lease: RuntimeModuleStateLease) async throws -> ModuleStateHealthSnapshot {
        let store = try validatedStore(lease)
        let result = await store.health(namespace: namespace(for: lease.moduleID))
        try validate(lease)
        return result
    }

    // Runtime-owned clients use these methods for Settings and the outbox. The
    // namespace is fixed by RuntimeCore and never caller-selectable.
    func runtimePrepare(
        namespace: ModuleStateNamespace,
        schemaVersion: UInt32
    ) async throws -> ModuleStateHealthSnapshot {
        let store = try validatedRuntimeStore()
        return try await store.prepareNamespace(namespace, schemaVersion: schemaVersion)
    }

    func runtimeFetch(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey
    ) async throws -> ModuleStateRecord? {
        let store = try validatedRuntimeStore()
        let result = try await store.fetch(namespace: namespace, key: key)
        try validateRecord(result)
        return result
    }

    func runtimeScan(
        namespace: ModuleStateNamespace,
        request: ModuleStateScanRequest
    ) async throws -> ModuleStateScanPage {
        let store = try validatedRuntimeStore()
        let result = try await store.scan(namespace: namespace, request: request)
        guard result.records.count <= request.limit else {
            throw ModuleStateStoreError.corrupt
        }
        for record in result.records { try validateRecord(record) }
        return result
    }

    func runtimeTransact(
        namespace: ModuleStateNamespace,
        transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        try validateTransaction(transaction)
        let store = try validatedRuntimeStore()
        return try await store.transact(namespace: namespace, transaction: transaction)
    }

    func runtimeHealth(
        namespace: ModuleStateNamespace
    ) async throws -> ModuleStateHealthSnapshot {
        let store = try validatedRuntimeStore()
        return await store.health(namespace: namespace)
    }

    func runtimeQuarantine(
        namespace: ModuleStateNamespace,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        guard isBoundedDiagnosticCode(diagnosticCode) else {
            throw ModuleStateStoreError.invalidRequest
        }
        let store = try validatedRuntimeStore()
        return try await store.quarantine(
            namespace: namespace,
            diagnosticCode: diagnosticCode
        )
    }

    private func validatedRuntimeStore() throws -> any ModuleStateStore {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        guard let store else { throw ModuleStateStoreError.unavailable }
        return store
    }

    private func validatedStore(
        _ lease: RuntimeModuleStateLease
    ) throws -> any ModuleStateStore {
        try validate(lease)
        guard let store else { throw ModuleStateStoreError.unavailable }
        return store
    }

    private func validate(_ lease: RuntimeModuleStateLease) throws {
        guard runtimeIsActive,
              runtimeGeneration == lease.runtimeGeneration,
              activeModuleGenerations[lease.moduleID] == lease.moduleGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.moduleID)
        }
    }

    private func validateTransaction(_ transaction: ModuleStateTransaction) throws {
        var totalBytes = 0
        for mutation in transaction.mutations {
            guard case .upsert(let upsert) = mutation else { continue }
            guard upsert.schemaVersion > 0 else { throw ModuleStateStoreError.invalidRequest }
            guard upsert.payload.count <= Self.maximumPayloadBytes else {
                throw ModuleStateStoreError.payloadTooLarge(
                    maximumBytes: Self.maximumPayloadBytes
                )
            }
            totalBytes += upsert.payload.count
        }
        guard totalBytes <= Self.maximumTransactionPayloadBytes else {
            throw ModuleStateStoreError.payloadTooLarge(
                maximumBytes: Self.maximumTransactionPayloadBytes
            )
        }
    }

    private func validateRecord(_ record: ModuleStateRecord?) throws {
        guard let record else { return }
        guard record.schemaVersion > 0,
              record.payload.count <= Self.maximumPayloadBytes,
              record.integrityDigest.count == 32
        else {
            throw ModuleStateStoreError.corrupt
        }
    }

    private func namespace(for moduleID: ModuleIdentifier) -> ModuleStateNamespace {
        ModuleStateNamespace(moduleID: moduleID)
    }

    private func isBoundedDiagnosticCode(_ value: String) -> Bool {
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
}
