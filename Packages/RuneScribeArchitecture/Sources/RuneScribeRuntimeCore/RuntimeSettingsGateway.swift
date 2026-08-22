import Foundation
import RuneScribeContracts

public struct RuntimeSettingsClient: Sendable {
    private let gateway: RuntimeSettingsGateway
    private let lease: ModuleContextLease
    private let writableSettingIDs: Set<RuntimeSettingID>

    init(
        gateway: RuntimeSettingsGateway,
        lease: ModuleContextLease,
        writableSettingIDs: Set<RuntimeSettingID>
    ) {
        self.gateway = gateway
        self.lease = lease
        self.writableSettingIDs = writableSettingIDs
    }

    public func snapshot() async throws -> RuntimeSettingsSnapshotDTO {
        try await lease.requireActive()
        let result = try await gateway.snapshot()
        try await lease.requireActive()
        return result
    }

    public func set(
        _ command: SetRuntimeSettingCommand
    ) async throws -> RuntimeSettingDTO {
        try await lease.requireActive()
        guard writableSettingIDs.contains(command.settingID) else {
            throw RuneScribeRuntimeError.settingWriteDenied(
                moduleID: lease.moduleID,
                settingID: command.settingID
            )
        }
        let result = try await gateway.set(command)
        try await lease.requireActive()
        return result
    }

    public func snapshots() async throws -> AsyncStream<RuntimeSettingsSnapshotDTO> {
        try await lease.requireActive()
        let source = await gateway.stream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await value in source {
                    do {
                        try await lease.requireActive()
                        continuation.yield(value)
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

    public func artifactSelections(
        for kind: RuntimeArtifactSelectionKind
    ) async throws -> RuntimeCodexArtifactSelectionMap {
        try await snapshot().artifactSelections(for: kind)
    }

    @discardableResult
    public func setArtifactSelections(
        _ selections: RuntimeCodexArtifactSelectionMap,
        expectedRevision: UInt64? = nil
    ) async throws -> RuntimeSettingDTO {
        let text = try RuntimeArtifactSelectionCodec.encode(selections)
        return try await set(
            SetRuntimeSettingCommand(
                settingID: selections.kind.settingID,
                value: .text(text),
                expectedRevision: expectedRevision
            )
        )
    }

    @discardableResult
    public func setSelectedCodex(
        _ codexID: CodexID,
        expectedRevision: UInt64? = nil
    ) async throws -> RuntimeSettingDTO {
        let preference = try RuntimeSelectedCodexPreference(codexID: codexID)
        return try await set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedCodex,
                value: .text(try RuntimeSelectedCodexPreferenceCodec.encode(preference)),
                expectedRevision: expectedRevision
            )
        )
    }

    @discardableResult
    public func setContactsImportPrompted(
        _ prompted: Bool,
        expectedRevision: UInt64? = nil
    ) async throws -> RuntimeSettingDTO {
        try await set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.contactsImportPrompted,
                value: .boolean(prompted),
                expectedRevision: expectedRevision
            )
        )
    }

    @discardableResult
    public func setSplashLastShown(
        at date: Date,
        expectedRevision: UInt64? = nil
    ) async throws -> RuntimeSettingDTO {
        try await set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.splashLastShownEpochMilliseconds,
                value: try RuntimePresentationSettingCodec.splashLastShownValue(at: date),
                expectedRevision: expectedRevision
            )
        )
    }
}

actor RuntimeSettingsGateway {
    private static let namespace = ModuleStateNamespace(
        moduleID: "com.runescribe.runtime.settings"
    )
    private static let collectionID = ModuleStateCollectionID(
        rawValue: "settings.values"
    )!
    private static let schemaVersion: UInt32 = 1

    private let state: RuntimeModuleStateGateway
    private let environment: RuntimeEnvironment
    private let descriptors: [RuntimeSettingID: RuntimeSettingDescriptor]
    private var values: [RuntimeSettingID: RuntimeSettingDTO] = [:]
    private var revision: UInt64 = 0
    private var loaded = false
    private var continuationSequence: UInt64 = 0
    private var continuations: [UInt64: AsyncStream<RuntimeSettingsSnapshotDTO>.Continuation] = [:]

    init(
        state: RuntimeModuleStateGateway,
        environment: RuntimeEnvironment,
        descriptors: [RuntimeSettingDescriptor] = RuneScribeRuntimeSettings.descriptors
    ) {
        self.state = state
        self.environment = environment
        self.descriptors = Dictionary(
            uniqueKeysWithValues: descriptors.map { ($0.settingID, $0) }
        )
    }

    func activateRuntime() async {
        loaded = false
        values.removeAll(keepingCapacity: true)
        revision = 0
        try? await loadIfNeeded()
    }

    func deactivateRuntime() {
        loaded = false
        values.removeAll(keepingCapacity: true)
        revision = 0
        let active = continuations.values
        continuations.removeAll()
        for continuation in active { continuation.finish() }
    }

    func snapshot() async throws -> RuntimeSettingsSnapshotDTO {
        try await loadIfNeeded()
        return currentSnapshot()
    }

    func set(_ command: SetRuntimeSettingCommand) async throws -> RuntimeSettingDTO {
        try await loadIfNeeded()
        guard let descriptor = descriptors[command.settingID],
              sameValueKind(command.value, descriptor.defaultValue)
        else {
            throw ModuleStateStoreError.invalidRequest
        }
        let validatedValue = try validatedWriteValue(
            command.value,
            settingID: command.settingID
        )

        let key = recordKey(for: command.settingID)
        let existing = try await state.runtimeFetch(namespace: Self.namespace, key: key)
        let expectation: ModuleStateRevisionExpectation
        if let expected = command.expectedRevision {
            expectation = expected == 0 ? .absent : .exact(expected)
        } else {
            expectation = .any
        }
        let transaction = try ModuleStateTransaction(
            transactionID: environment.nextUUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: Self.schemaVersion,
                        payload: try JSONEncoder().encode(validatedValue),
                        expectedRevision: expectation
                    )
                ),
            ]
        )
        do {
            let result = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
            guard let storedRevision = result.mutations.first?.revision else {
                throw ModuleStateStoreError.corrupt
            }
            let dto = RuntimeSettingDTO(
                settingID: command.settingID,
                value: validatedValue,
                revision: storedRevision,
                updatedAt: environment.now()
            )
            values[command.settingID] = dto
            revision = result.storeRevision
            yieldSnapshot()
            return dto
        } catch {
            if existing != nil {
                loaded = false
                try? await loadIfNeeded()
            }
            throw error
        }
    }

    func stream() async -> AsyncStream<RuntimeSettingsSnapshotDTO> {
        continuationSequence &+= 1
        let id = continuationSequence
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            if loaded { continuation.yield(currentSnapshot()) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func loadIfNeeded() async throws {
        guard !loaded else { return }
        let health = try await state.runtimePrepare(
            namespace: Self.namespace,
            schemaVersion: Self.schemaVersion
        )
        let request = try ModuleStateScanRequest(
            collectionID: Self.collectionID,
            limit: max(1, descriptors.count)
        )
        let page = try await state.runtimeScan(namespace: Self.namespace, request: request)
        var loadedValues: [RuntimeSettingID: RuntimeSettingDTO] = [:]
        var normalizationMutations: [ModuleStateMutation] = []
        for record in page.records {
            guard let settingID = RuntimeSettingID(rawValue: record.key.recordID.rawValue),
                  let descriptor = descriptors[settingID]
            else { continue }
            let storedValue = try JSONDecoder().decode(
                RuntimeSettingValue.self,
                from: record.payload
            )
            let normalization = normalizedStoredValue(
                storedValue,
                settingID: settingID,
                fallback: descriptor.defaultValue
            )
            let value = normalization.value
            guard sameValueKind(value, descriptor.defaultValue) else {
                throw ModuleStateStoreError.corrupt
            }
            loadedValues[settingID] = RuntimeSettingDTO(
                settingID: settingID,
                value: value,
                revision: record.revision,
                updatedAt: record.updatedAt
            )
            if normalization.shouldPersist {
                normalizationMutations.append(
                    .upsert(
                        ModuleStateUpsert(
                            key: record.key,
                            schemaVersion: Self.schemaVersion,
                            payload: try JSONEncoder().encode(value),
                            expectedRevision: .exact(record.revision)
                        )
                    )
                )
            }
        }
        if !normalizationMutations.isEmpty {
            let transaction = try ModuleStateTransaction(
                transactionID: environment.nextUUID(),
                mutations: normalizationMutations
            )
            let result = try await state.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
            for mutation in result.mutations {
                guard let settingID = RuntimeSettingID(
                    rawValue: mutation.key.recordID.rawValue
                ),
                    let storedRevision = mutation.revision,
                    let existing = loadedValues[settingID]
                else { continue }
                loadedValues[settingID] = RuntimeSettingDTO(
                    settingID: settingID,
                    value: existing.value,
                    revision: storedRevision,
                    updatedAt: environment.now()
                )
            }
            revision = result.storeRevision
        } else {
            revision = health.storeRevision
        }
        values = loadedValues
        loaded = true
        yieldSnapshot()
    }

    private func currentSnapshot() -> RuntimeSettingsSnapshotDTO {
        let settings = descriptors.values.map { descriptor in
            values[descriptor.settingID] ?? RuntimeSettingDTO(
                settingID: descriptor.settingID,
                value: descriptor.defaultValue,
                revision: 0,
                updatedAt: nil
            )
        }
        return try! RuntimeSettingsSnapshotDTO(
            revision: revision,
            capturedAt: environment.now(),
            settings: settings
        )
    }

    private func recordKey(for settingID: RuntimeSettingID) -> ModuleStateRecordKey {
        ModuleStateRecordKey(
            collectionID: Self.collectionID,
            recordID: ModuleStateRecordID(rawValue: settingID.rawValue)!
        )
    }

    private func sameValueKind(
        _ lhs: RuntimeSettingValue,
        _ rhs: RuntimeSettingValue
    ) -> Bool {
        switch (lhs, rhs) {
        case (.boolean, .boolean), (.integer, .integer), (.text, .text): true
        default: false
        }
    }

    private func artifactKind(
        for settingID: RuntimeSettingID
    ) -> RuntimeArtifactSelectionKind? {
        RuntimeArtifactSelectionKind.allCases.first { $0.settingID == settingID }
    }

    private func validatedWriteValue(
        _ value: RuntimeSettingValue,
        settingID: RuntimeSettingID
    ) throws -> RuntimeSettingValue {
        if let kind = artifactKind(for: settingID) {
            guard let text = value.textValue else {
                throw ModuleStateStoreError.invalidRequest
            }
            do {
                _ = try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
                    text,
                    expectedKind: kind
                )
            } catch {
                throw ModuleStateStoreError.invalidRequest
            }
        }
        if settingID == RuneScribeRuntimeSettings.selectedCodex {
            guard let text = value.textValue else {
                throw ModuleStateStoreError.invalidRequest
            }
            do {
                _ = try RuntimeSelectedCodexPreferenceCodec.decodeCurrentWrite(text)
            } catch {
                throw ModuleStateStoreError.invalidRequest
            }
        }
        if settingID == RuneScribeRuntimeSettings.splashLastShownEpochMilliseconds {
            guard let milliseconds = value.integerValue, milliseconds >= 0 else {
                throw ModuleStateStoreError.invalidRequest
            }
        }
        return value
    }

    private func normalizedStoredValue(
        _ value: RuntimeSettingValue,
        settingID: RuntimeSettingID,
        fallback: RuntimeSettingValue
    ) -> (value: RuntimeSettingValue, shouldPersist: Bool) {
        if settingID == RuneScribeRuntimeSettings.selectedCodex {
            guard let text = value.textValue,
                  let decoded = try? RuntimeSelectedCodexPreferenceCodec.decodeForRead(text),
                  let canonical = try? RuntimeSelectedCodexPreferenceCodec.encode(decoded.value)
            else {
                return (fallback, false)
            }
            return (.text(canonical), canonical != text)
        }
        guard let kind = artifactKind(for: settingID) else {
            if settingID == RuneScribeRuntimeSettings.splashLastShownEpochMilliseconds,
               (value.integerValue ?? -1) < 0 {
                return (fallback, false)
            }
            return (value, false)
        }
        guard let text = value.textValue,
              let decoded = try? RuntimeArtifactSelectionCodec.decodeForRead(
                  text,
                  expectedKind: kind
              ),
              let canonical = try? RuntimeArtifactSelectionCodec.encode(decoded.value)
        else {
            return (fallback, false)
        }
        return (.text(canonical), canonical != text)
    }

    private func yieldSnapshot() {
        let snapshot = currentSnapshot()
        for continuation in continuations.values { continuation.yield(snapshot) }
    }

    private func removeContinuation(_ id: UInt64) {
        continuations.removeValue(forKey: id)
    }
}
