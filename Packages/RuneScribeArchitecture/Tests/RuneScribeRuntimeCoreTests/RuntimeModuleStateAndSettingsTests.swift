import Foundation
import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

@MainActor
final class RuntimeModuleStateAndSettingsTests: XCTestCase {
    func testInMemoryAdapterMatchesSchemaReplayAndDiagnosticSemantics() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 500) })
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let absent = try await store.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(absent.loadState, .absent)
        XCTAssertEqual(absent.storeRevision, 0)
        let repeated = try await store.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(repeated.loadState, .absent)
        XCTAssertEqual(repeated.storeRevision, 0)

        let migrated = try await store.prepareNamespace(namespace, schemaVersion: 2)
        XCTAssertEqual(migrated.loadState, .migrated)
        XCTAssertEqual(migrated.storeRevision, 1)
        let key = ModuleStateRecordKey(
            collectionID: ModuleStateCollectionID(rawValue: "migration.records")!,
            recordID: ModuleStateRecordID(rawValue: "version-2")!
        )
        let transactionID = UUID()
        let transaction = try ModuleStateTransaction(
            transactionID: transactionID,
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: 2,
                        payload: Data("complete".utf8),
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        let committed = try await store.transact(
            namespace: namespace,
            transaction: transaction
        )
        XCTAssertEqual(committed.storeRevision, 2)
        XCTAssertEqual(committed.mutations.first?.revision, 1)
        let committedHealth = await store.health(namespace: namespace)
        XCTAssertEqual(committedHealth.loadState, .loaded)
        let replayed = try await store.transact(
            namespace: namespace,
            transaction: transaction
        )
        XCTAssertEqual(replayed, committed)

        let changedReplay = try ModuleStateTransaction(
            transactionID: transactionID,
            mutations: [.delete(ModuleStateDelete(key: key))]
        )
        do {
            _ = try await store.transact(
                namespace: namespace,
                transaction: changedReplay
            )
            XCTFail("Expected changed transaction replay to fail")
        } catch ModuleStateStoreError.invalidRequest {}

        let downgrade = try await store.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(downgrade.loadState, .unreadable)
        XCTAssertEqual(downgrade.storeRevision, 3)
        XCTAssertEqual(
            downgrade.diagnosticCode,
            "module-state-schema-newer-than-runtime"
        )
        let repeatedDowngrade = try await store.prepareNamespace(
            namespace,
            schemaVersion: 1
        )
        XCTAssertEqual(repeatedDowngrade.storeRevision, 3)
        do {
            _ = try await store.fetch(namespace: namespace, key: key)
            XCTFail("Expected unreadable namespace")
        } catch ModuleStateStoreError.unreadable {}
        let recovered = try await store.prepareNamespace(namespace, schemaVersion: 2)
        XCTAssertEqual(recovered.loadState, .loaded)

        for invalidCode in ["Uppercase", "double--separator", ".leading"] {
            do {
                _ = try await store.quarantine(
                    namespace: namespace,
                    diagnosticCode: invalidCode
                )
                XCTFail("Expected invalid diagnostic code")
            } catch ModuleStateStoreError.invalidRequest {}
        }
        let quarantined = try await store.quarantine(
            namespace: namespace,
            diagnosticCode: "record.validation-failed"
        )
        XCTAssertEqual(quarantined.loadState, .quarantined)
        XCTAssertEqual(quarantined.storeRevision, 4)
    }

    func testModuleStateClientScopesAtomicRevisionedRecordsAndRevokesOnStop() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 1_000) })
        let capture = RuntimeRailClientCapture()
        let runtime = try await makeRuntime(store: store, capture: capture)
        try await runtime.start()

        let capturedStateClient = await capture.moduleStateClient()
        let client = try XCTUnwrap(capturedStateClient)
        let health = try await client.prepare(schemaVersion: 1)
        XCTAssertEqual(health.loadState, .absent)

        let collection = try XCTUnwrap(ModuleStateCollectionID(rawValue: "test.records"))
        let firstID = try XCTUnwrap(ModuleStateRecordID(rawValue: "record.a"))
        let secondID = try XCTUnwrap(ModuleStateRecordID(rawValue: "record.b"))
        let thirdID = try XCTUnwrap(ModuleStateRecordID(rawValue: "record.c"))
        let transaction = try ModuleStateTransaction(
            transactionID: UUID(),
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: .init(collectionID: collection, recordID: secondID),
                        schemaVersion: 1,
                        payload: Data("second".utf8),
                        expectedRevision: .absent
                    )
                ),
                .upsert(
                    ModuleStateUpsert(
                        key: .init(collectionID: collection, recordID: firstID),
                        schemaVersion: 1,
                        payload: Data("first".utf8),
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        let committed = try await client.transact(transaction)
        XCTAssertEqual(Set(committed.mutations.compactMap(\.revision)), [1])

        let firstPage = try await client.scan(
            ModuleStateScanRequest(collectionID: collection, limit: 1)
        )
        XCTAssertEqual(firstPage.records.map(\.key.recordID), [firstID])
        let secondPage = try await client.scan(
            ModuleStateScanRequest(
                collectionID: collection,
                limit: 1,
                cursor: try XCTUnwrap(firstPage.nextCursor)
            )
        )
        XCTAssertEqual(secondPage.records.map(\.key.recordID), [secondID])
        XCTAssertNil(secondPage.nextCursor)

        let conflicting = try ModuleStateTransaction(
            transactionID: UUID(),
            mutations: [
                .delete(
                    ModuleStateDelete(
                        key: .init(collectionID: collection, recordID: firstID),
                        expectedRevision: .exact(99)
                    )
                ),
                .upsert(
                    ModuleStateUpsert(
                        key: .init(collectionID: collection, recordID: thirdID),
                        schemaVersion: 1,
                        payload: Data("must-not-commit".utf8),
                        expectedRevision: .absent
                    )
                ),
            ]
        )
        do {
            _ = try await client.transact(conflicting)
            XCTFail("Expected revision conflict")
        } catch let error as ModuleStateStoreError {
            guard case .revisionConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let thirdAfterConflict = try await client.fetch(
            collectionID: collection,
            recordID: thirdID
        )
        XCTAssertNil(thirdAfterConflict)

        await store.injectFault(at: .beforeTransactionCommit)
        do {
            _ = try await client.transact(
                ModuleStateTransaction(
                    transactionID: UUID(),
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: .init(collectionID: collection, recordID: thirdID),
                                schemaVersion: 1,
                                payload: Data("interrupted".utf8),
                                expectedRevision: .absent
                            )
                        ),
                    ]
                )
            )
            XCTFail("Expected injected interruption")
        } catch {}
        let thirdAfterInterruption = try await client.fetch(
            collectionID: collection,
            recordID: thirdID
        )
        XCTAssertNil(thirdAfterInterruption)

        let namespace = ModuleStateNamespace(moduleID: RuneScribeModuleIDs.core)
        await store.corruptIntegrityDigest(
            namespace: namespace,
            key: .init(collectionID: collection, recordID: firstID)
        )
        do {
            _ = try await client.fetch(collectionID: collection, recordID: firstID)
            XCTFail("Expected integrity failure")
        } catch ModuleStateStoreError.integrityMismatch {}
        let corruptHealth = try await client.health()
        XCTAssertEqual(corruptHealth.loadState, .quarantined)
        XCTAssertEqual(corruptHealth.accessDisposition, .readWrite)
        XCTAssertEqual(corruptHealth.recordCount, 1)
        XCTAssertEqual(corruptHealth.quarantinedRecordCount, 1)
        let quarantined = try await client.quarantine(
            diagnosticCode: "state-integrity-failed"
        )
        XCTAssertEqual(quarantined.loadState, .quarantined)
        XCTAssertEqual(quarantined.accessDisposition, .blocked)

        await runtime.stop()
        do {
            _ = try await client.health()
            XCTFail("Expected revoked state client")
        } catch RuneScribeRuntimeError.contextInactive {
        } catch RuneScribeRuntimeError.staleClient {}
    }

    func testSyntheticProgressionUsesScopedInMemoryStateClientAndRevokes() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 1_500) })
        let capture = ProgressionStateClientCapture()
        let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
        let runtime = RuneScribeRuntime(runtimeVersion: version, platform: .macOS)
        let core = railCoreDescriptor(version: version)
        let progression = progressionRailDescriptor(version: version)
        let ui = railUIDescriptor(version: version)

        try await runtime.register(
            manifest: railManifest(for: core, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: core,
                make: { RuntimeRailTestModule(descriptor: core) { _ in } }
            )
        )
        try await runtime.register(
            manifest: railManifest(for: progression, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: progression,
                make: {
                    RuntimeRailTestModule(descriptor: progression) { context in
                        await capture.set(try await context.moduleStateClient())
                    }
                }
            )
        )
        try await runtime.register(
            manifest: railManifest(for: ui, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: ui,
                make: { RuntimeRailTestModule(descriptor: ui) { _ in } }
            )
        )
        try await runtime.installPlatformAdapter(
            store,
            for: RuneScribeServiceKeys.moduleStateStore
        )
        try await runtime.start()

        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        _ = try await client.prepare(schemaVersion: 1)
        let collection = try XCTUnwrap(
            ModuleStateCollectionID(rawValue: "progression.synthetic")
        )
        let firstID = try XCTUnwrap(ModuleStateRecordID(rawValue: "state-1"))
        let secondID = try XCTUnwrap(ModuleStateRecordID(rawValue: "state-2"))
        let thirdID = try XCTUnwrap(ModuleStateRecordID(rawValue: "state-3"))
        let firstKey = ModuleStateRecordKey(collectionID: collection, recordID: firstID)
        let secondKey = ModuleStateRecordKey(collectionID: collection, recordID: secondID)
        _ = try await client.transact(
            ModuleStateTransaction(
                transactionID: UUID(),
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: firstKey,
                            schemaVersion: 1,
                            payload: Data("invalid-logical-state".utf8),
                            expectedRevision: .absent
                        )
                    ),
                    .upsert(
                        ModuleStateUpsert(
                            key: secondKey,
                            schemaVersion: 1,
                            payload: Data("valid-event".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        let progressionNamespace = ModuleStateNamespace(
            moduleID: RuneScribeModuleIDs.progression
        )
        let stored = try await store.fetch(namespace: progressionNamespace, key: firstKey)
        XCTAssertEqual(stored?.payload, Data("invalid-logical-state".utf8))
        let coreNamespaceRecord = try await store.fetch(
            namespace: ModuleStateNamespace(moduleID: RuneScribeModuleIDs.core),
            key: firstKey
        )
        XCTAssertNil(coreNamespaceRecord)

        let recordQuarantine = try await client.quarantineRecord(
            collectionID: collection,
            recordID: firstID,
            expectedRevision: try XCTUnwrap(stored?.revision),
            diagnosticCode: "progression-record-invalid"
        )
        XCTAssertEqual(recordQuarantine.loadState, .quarantined)
        XCTAssertEqual(recordQuarantine.accessDisposition, .readWrite)
        XCTAssertEqual(recordQuarantine.recordCount, 1)
        XCTAssertEqual(recordQuarantine.quarantinedRecordCount, 1)
        do {
            _ = try await client.fetch(collectionID: collection, recordID: firstID)
            XCTFail("Expected quarantined record to remain inaccessible")
        } catch ModuleStateStoreError.quarantined {}

        let validPage = try await client.scan(
            ModuleStateScanRequest(collectionID: collection, limit: 10)
        )
        XCTAssertEqual(validPage.records.map(\.key.recordID), [secondID])
        _ = try await client.transact(
            ModuleStateTransaction(
                transactionID: UUID(),
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: ModuleStateRecordKey(
                                collectionID: collection,
                                recordID: thirdID
                            ),
                            schemaVersion: 1,
                            payload: Data("rebuilt-state".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        let postRebuildHealth = try await client.health()
        XCTAssertEqual(postRebuildHealth.accessDisposition, .readWrite)
        XCTAssertEqual(postRebuildHealth.recordCount, 2)
        XCTAssertEqual(postRebuildHealth.quarantinedRecordCount, 1)

        await runtime.stop()
        do {
            _ = try await client.quarantineRecord(
                collectionID: collection,
                recordID: secondID,
                expectedRevision: 1,
                diagnosticCode: "late-record-quarantine"
            )
            XCTFail("Expected Progression state client revocation")
        } catch RuneScribeRuntimeError.contextInactive {
        } catch RuneScribeRuntimeError.staleClient {}
    }

    func testSettingsUseDefaultsPersistAndRevokeThroughRuntimeRail() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 2_000) })
        let firstCapture = RuntimeRailClientCapture()
        let firstRuntime = try await makeRuntime(store: store, capture: firstCapture)
        try await firstRuntime.start()

        let firstCapturedSettingsClient = await firstCapture.settingsClient()
        let firstClient = try XCTUnwrap(firstCapturedSettingsClient)
        let defaults = try await firstClient.snapshot()
        XCTAssertEqual(
            defaults[RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled],
            .boolean(true)
        )
        let stored = try await firstClient.set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
                value: .boolean(false),
                expectedRevision: 0
            )
        )
        XCTAssertGreaterThan(stored.revision, 0)
        await firstRuntime.stop()

        do {
            _ = try await firstClient.snapshot()
            XCTFail("Expected revoked settings client")
        } catch RuneScribeRuntimeError.contextInactive {}

        let secondCapture = RuntimeRailClientCapture()
        let secondRuntime = try await makeRuntime(store: store, capture: secondCapture)
        try await secondRuntime.start()
        let secondCapturedSettingsClient = await secondCapture.settingsClient()
        let secondClient = try XCTUnwrap(secondCapturedSettingsClient)
        let relaunched = try await secondClient.snapshot()
        XCTAssertEqual(
            relaunched[RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled],
            .boolean(false)
        )
        await secondRuntime.stop()
    }

    func testSettingsSnapshotAndTextRejectUnboundedOrAmbiguousValues() throws {
        let setting = RuntimeSettingDTO(
            settingID: RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
            value: .boolean(true),
            revision: 1,
            updatedAt: nil
        )
        XCTAssertThrowsError(
            try RuntimeSettingsSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                settings: [setting, setting]
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeSettingsContractError, .duplicateSettingID)
        }

        let tooMany = try (0 ... RuntimeSettingsSnapshotDTO.maximumSettingCount).map {
            index -> RuntimeSettingDTO in
            let settingID = try XCTUnwrap(
                RuntimeSettingID(rawValue: "setting.test-\(index)")
            )
            return RuntimeSettingDTO(
                settingID: settingID,
                value: .boolean(true),
                revision: 0,
                updatedAt: nil
            )
        }
        XCTAssertThrowsError(
            try RuntimeSettingsSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                settings: tooMany
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeSettingsContractError,
                .tooManySettings(maximum: RuntimeSettingsSnapshotDTO.maximumSettingCount)
            )
        }

        let duplicatePayload = UncheckedSettingsSnapshot(
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 1),
            settings: [setting, setting]
        )
        let encoded = try JSONEncoder().encode(duplicatePayload)
        XCTAssertThrowsError(try JSONDecoder().decode(
            RuntimeSettingsSnapshotDTO.self,
            from: encoded
        ))
        XCTAssertNil(RuntimeSettingText(rawValue: ""))
        XCTAssertNil(RuntimeSettingText(rawValue: String(repeating: "x", count: 257)))
        XCTAssertNil(RuntimeSettingText(rawValue: "contains\ncontrol"))
        XCTAssertNotNil(RuntimeSettingText(rawValue: String(repeating: "x", count: 256)))
    }

    private func makeRuntime(
        store: InMemoryModuleStateStore,
        capture: RuntimeRailClientCapture
    ) async throws -> RuneScribeRuntime {
        let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
        let runtime = RuneScribeRuntime(
            runtimeVersion: version,
            platform: .macOS
        )
        let core = railCoreDescriptor(version: version)
        let ui = railUIDescriptor(version: version)
        try await runtime.register(
            manifest: railManifest(for: core, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: core,
                make: {
                    RuntimeRailTestModule(descriptor: core) { context in
                        await capture.setModuleStateClient(
                            try await context.moduleStateClient()
                        )
                        await capture.setOutboxClient(
                            try await context.progressionOutboxClient()
                        )
                    }
                }
            )
        )
        try await runtime.register(
            manifest: railManifest(for: ui, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: ui,
                make: {
                    RuntimeRailTestModule(descriptor: ui) { context in
                        await capture.setSettingsClient(
                            try await context.runtimeSettingsClient()
                        )
                    }
                }
            )
        )
        try await runtime.installPlatformAdapter(
            store,
            for: RuneScribeServiceKeys.moduleStateStore
        )
        return runtime
    }
}

private struct UncheckedSettingsSnapshot: Encodable {
    let revision: UInt64
    let capturedAt: Date
    let settings: [RuntimeSettingDTO]
}

private actor RuntimeRailClientCapture {
    private var storedModuleStateClient: RuntimeModuleStateClient?
    private var storedSettingsClient: RuntimeSettingsClient?
    private var storedOutboxClient: RuntimeProgressionOutboxClient?

    func setModuleStateClient(_ value: RuntimeModuleStateClient) {
        storedModuleStateClient = value
    }

    func setSettingsClient(_ value: RuntimeSettingsClient) {
        storedSettingsClient = value
    }

    func setOutboxClient(_ value: RuntimeProgressionOutboxClient) {
        storedOutboxClient = value
    }

    func moduleStateClient() -> RuntimeModuleStateClient? { storedModuleStateClient }
    func settingsClient() -> RuntimeSettingsClient? { storedSettingsClient }
    func outboxClient() -> RuntimeProgressionOutboxClient? { storedOutboxClient }
}

private actor ProgressionStateClientCapture {
    private var stored: RuntimeModuleStateClient?

    func set(_ client: RuntimeModuleStateClient) { stored = client }
    func client() -> RuntimeModuleStateClient? { stored }
}

private struct RuntimeRailTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    init(
        descriptor: ModuleDescriptor,
        startAction: @escaping @Sendable (ModuleContext) async throws -> Void
    ) {
        self.descriptor = descriptor
        self.startAction = startAction
    }

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private func railCoreDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.core,
        moduleVersion: version,
        kind: .service,
        criticality: .required,
        entryPoint: "RuntimeRailCore",
        role: RuneScribeRoles.core,
        requestedCapabilities: [
            RuneScribeCapabilities.moduleStateAccess,
            RuneScribeCapabilities.progressionEventSubmit,
        ],
        requiredServices: [RuneScribeServiceIDs.moduleStateStore]
    )
}

private func railUIDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.primaryUI,
        moduleVersion: version,
        kind: .ui,
        criticality: .required,
        entryPoint: "RuntimeRailUI",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.runtimeSettingsRead,
            RuneScribeCapabilities.runtimeSettingsWrite,
        ],
        requiredModuleRoles: [RuneScribeRoles.core]
    )
}

private func progressionRailDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.progression,
        moduleVersion: version,
        kind: .service,
        criticality: .optional,
        entryPoint: "SyntheticProgressionStateModule",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [RuneScribeCapabilities.moduleStateAccess],
        requiredServices: [RuneScribeServiceIDs.moduleStateStore]
    )
}

private func railManifest(
    for descriptor: ModuleDescriptor,
    runtimeVersion: SemanticVersion
) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: runtimeVersion,
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )
}
