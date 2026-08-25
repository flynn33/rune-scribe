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
        XCTAssertEqual(defaults.selectedCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(
            defaults.artifactSelections(for: .relic)[RuneScribeCodexIDs.norse]?.rawValue,
            "relic.norse.runestone-tablet"
        )
        XCTAssertEqual(
            defaults.artifactSelections(for: .seal)[RuneScribeCodexIDs.norse]?.rawValue,
            "seal.norse.valknut"
        )
        XCTAssertEqual(
            defaults.artifactSelections(for: .frame).storedPreference(
                for: RuneScribeCodexIDs.norse
            ),
            RuntimeArtifactSelectionPreference.none
        )
        XCTAssertEqual(defaults.effectsPreference, .full)
        XCTAssertFalse(defaults.contactsImportPrompted)
        XCTAssertNil(defaults.splashLastShownAt)
        let stored = try await firstClient.set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
                value: .boolean(false),
                expectedRevision: 0
            )
        )
        XCTAssertGreaterThan(stored.revision, 0)
        let storedEffects = try await firstClient.set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.effectsPreference,
                value: RuntimeEffectsPreference.reduced.settingValue,
                expectedRevision: 0
            )
        )
        XCTAssertEqual(storedEffects.value, RuntimeEffectsPreference.reduced.settingValue)
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
        XCTAssertEqual(relaunched.effectsPreference, .reduced)
        await secondRuntime.stop()
    }

    func testAppearanceDefaultsCommitAtomicallyAndConflictPreservesPriorValues() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 2_250) })
        let capture = RuntimeRailClientCapture()
        let runtime = try await makeRuntime(store: store, capture: capture)
        try await runtime.start()
        defer { Task { await runtime.stop() } }

        let capturedClient = await capture.settingsClient()
        let client = try XCTUnwrap(capturedClient)
        let initial = try await client.snapshot()
        let settingIDs: [RuntimeSettingID] = [
            RuneScribeRuntimeSettings.selectedRelicByCodex,
            RuneScribeRuntimeSettings.selectedSealByCodex,
            RuneScribeRuntimeSettings.selectedFrameByCodex,
            RuneScribeRuntimeSettings.effectsPreference,
        ]
        func revisions(
            in snapshot: RuntimeSettingsSnapshotDTO
        ) -> [RuntimeSettingID: UInt64] {
            Dictionary(uniqueKeysWithValues: settingIDs.map { settingID in
                (
                    settingID,
                    snapshot.settings.first(where: { $0.settingID == settingID })?.revision ?? 0
                )
            })
        }

        let relics = try initial.artifactSelections(for: .relic).setting(
            XCTUnwrap(ArtifactID(rawValue: "relic.norse.dragonwood-plaque")),
            for: RuneScribeCodexIDs.norse
        )
        let seals = try initial.artifactSelections(for: .seal).setting(
            nil,
            for: RuneScribeCodexIDs.norse
        )
        let frames = try initial.artifactSelections(for: .frame).setting(
            XCTUnwrap(ArtifactID(rawValue: "frame.norse.carved-knotwork")),
            for: RuneScribeCodexIDs.norse
        )
        let committed = try await client.setAppearanceDefaults(
            relics: relics,
            seals: seals,
            frames: frames,
            effects: .reduced,
            expectedRevisions: revisions(in: initial)
        )
        XCTAssertEqual(committed.artifactSelections(for: .relic), relics)
        XCTAssertEqual(committed.artifactSelections(for: .seal), seals)
        XCTAssertEqual(committed.artifactSelections(for: .frame), frames)
        XCTAssertEqual(committed.effectsPreference, .reduced)
        XCTAssertEqual(
            committed.artifactSelections(for: .seal).storedPreference(
                for: RuneScribeCodexIDs.norse
            ),
            RuntimeArtifactSelectionPreference.none
        )

        let replacementRelics = try relics.setting(
            XCTUnwrap(ArtifactID(rawValue: "relic.norse.runestone-tablet")),
            for: RuneScribeCodexIDs.norse
        )
        let replacementSeals = try seals.setting(
            XCTUnwrap(ArtifactID(rawValue: "seal.norse.valknut")),
            for: RuneScribeCodexIDs.norse
        )
        let replacementFrames = try frames.setting(nil, for: RuneScribeCodexIDs.norse)
        var conflictingRevisions = revisions(in: committed)
        conflictingRevisions[RuneScribeRuntimeSettings.selectedSealByCodex] = 0
        do {
            _ = try await client.setAppearanceDefaults(
                relics: replacementRelics,
                seals: replacementSeals,
                frames: replacementFrames,
                effects: .off,
                expectedRevisions: conflictingRevisions
            )
            XCTFail("Expected one stale revision to reject the complete Appearance write")
        } catch let error as ModuleStateStoreError {
            guard case .revisionConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let afterConflict = try await client.snapshot()
        XCTAssertEqual(afterConflict.artifactSelections(for: .relic), relics)
        XCTAssertEqual(afterConflict.artifactSelections(for: .seal), seals)
        XCTAssertEqual(afterConflict.artifactSelections(for: .frame), frames)
        XCTAssertEqual(afterConflict.effectsPreference, .reduced)
        XCTAssertEqual(revisions(in: afterConflict), revisions(in: committed))
    }

    func testSettingsWriteScopeSeparatesPrimaryUIAndThemeCoordinator() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 2_500) })
        let capture = RuntimeRailClientCapture()
        let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
        let runtime = RuneScribeRuntime(runtimeVersion: version, platform: .macOS)
        let core = railCoreDescriptor(version: version)
        let ui = railUIDescriptor(version: version)
        let coordinator = themeCoordinatorSettingsDescriptor(version: version)

        try await runtime.register(
            manifest: railManifest(for: core, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: core,
                make: { RuntimeRailTestModule(descriptor: core) { _ in } }
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
        try await runtime.register(
            manifest: railManifest(for: coordinator, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: coordinator,
                make: {
                    RuntimeRailTestModule(descriptor: coordinator) { context in
                        await capture.setCoordinatorSettingsClient(
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
        try await runtime.start()

        let capturedPrimaryUIClient = await capture.settingsClient()
        let capturedCoordinatorClient = await capture.coordinatorSettingsClient()
        let primaryUIClient = try XCTUnwrap(capturedPrimaryUIClient)
        let coordinatorClient = try XCTUnwrap(capturedCoordinatorClient)
        let elven = try XCTUnwrap(CodexID(rawValue: "codex.elven"))
        let elvenText = try RuntimeSelectedCodexPreferenceCodec.encode(
            RuntimeSelectedCodexPreference(codexID: elven)
        )
        let command = SetRuntimeSettingCommand(
            settingID: RuneScribeRuntimeSettings.selectedCodex,
            value: .text(elvenText),
            expectedRevision: 0
        )

        do {
            _ = try await primaryUIClient.set(command)
            XCTFail("Expected selected Codex write to be denied for primary UI")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .settingWriteDenied(
                    moduleID: RuneScribeModuleIDs.primaryUI,
                    settingID: RuneScribeRuntimeSettings.selectedCodex
                )
            )
        }

        let stored = try await coordinatorClient.set(command)
        XCTAssertEqual(stored.settingID, RuneScribeRuntimeSettings.selectedCodex)
        XCTAssertEqual(stored.value, .text(elvenText))
        let visibleToPrimaryUI = try await primaryUIClient.snapshot()
        XCTAssertEqual(
            visibleToPrimaryUI.selectedCodexID,
            elven
        )
        do {
            _ = try await coordinatorClient.set(
                SetRuntimeSettingCommand(
                    settingID: RuneScribeRuntimeSettings.selectedCodex,
                    value: .text(RuntimeSettingText(rawValue: elven.rawValue)!)
                )
            )
            XCTFail("Legacy selected Codex writes must be rejected")
        } catch ModuleStateStoreError.invalidRequest {}

        let relicMap = try RuneScribeRuntimeSettings.defaultArtifactSelections(for: .relic)
            .setting(
                XCTUnwrap(ArtifactID(rawValue: "relic.norse.dragonwood-plaque")),
                for: RuneScribeCodexIDs.norse
            )
        let relicValue = try RuntimeArtifactSelectionCodec.encode(relicMap)
        let relicCommand = SetRuntimeSettingCommand(
            settingID: RuneScribeRuntimeSettings.selectedRelicByCodex,
            value: .text(relicValue),
            expectedRevision: 0
        )
        let storedRelic = try await primaryUIClient.set(relicCommand)
        XCTAssertEqual(storedRelic.value, .text(relicValue))
        do {
            _ = try await coordinatorClient.set(relicCommand)
            XCTFail("Theme coordinator must not own per-Codex artifact preferences")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .settingWriteDenied(
                    moduleID: RuneScribeModuleIDs.themeCoordinator,
                    settingID: RuneScribeRuntimeSettings.selectedRelicByCodex
                )
            )
        }

        let prompted = try await primaryUIClient.setContactsImportPrompted(
            true,
            expectedRevision: 0
        )
        XCTAssertEqual(prompted.value, .boolean(true))
        let shownAt = Date(timeIntervalSince1970: 2_500)
        let splash = try await primaryUIClient.setSplashLastShown(
            at: shownAt,
            expectedRevision: 0
        )
        XCTAssertEqual(
            splash.value,
            try RuntimePresentationSettingCodec.splashLastShownValue(at: shownAt)
        )
        do {
            _ = try await coordinatorClient.setContactsImportPrompted(true)
            XCTFail("Theme coordinator must not write UI presentation state")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .settingWriteDenied(
                    moduleID: RuneScribeModuleIDs.themeCoordinator,
                    settingID: RuneScribeRuntimeSettings.contactsImportPrompted
                )
            )
        }

        await runtime.stop()
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
        XCTAssertNil(RuntimeSettingText(
            rawValue: String(repeating: "x", count: RuntimeSettingText.maximumUTF8Count + 1)
        ))
        XCTAssertNil(RuntimeSettingText(rawValue: "contains\ncontrol"))
        XCTAssertNotNil(RuntimeSettingText(
            rawValue: String(repeating: "x", count: RuntimeSettingText.maximumUTF8Count)
        ))
    }

    func testSettingsCanonicalizeLegacyNorseSelectionsBeforeFirstSnapshotAndPersistLater()
        async throws
    {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 2_750) })
        let namespace = ModuleStateNamespace(moduleID: "com.runescribe.runtime.settings")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        let collection = try XCTUnwrap(ModuleStateCollectionID(rawValue: "settings.values"))
        func key(_ settingID: RuntimeSettingID) -> ModuleStateRecordKey {
            ModuleStateRecordKey(
                collectionID: collection,
                recordID: ModuleStateRecordID(rawValue: settingID.rawValue)!
            )
        }
        let legacyCodex = try XCTUnwrap(RuntimeSettingText(rawValue: "codex.moonleaf"))
        let legacyRelic = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=relic.norse.raven-medallion"
        ))
        let legacySeal = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=seal.norse.forge-flame"
        ))
        let legacyFrame = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=frame.norse.carved-knotwork"
        ))
        let unknownSeal = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"seal","schemaVersion":2,"selections":[{"artifactID":"seal.norse.future-seal","codexID":"codex.norse"}]}"#
        ))
        let futureSeal = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"seal","schemaVersion":3,"selections":[]}"#
        ))
        let legacyCodexPayload = try JSONEncoder().encode(
            RuntimeSettingValue.text(legacyCodex)
        )
        let legacyRelicPayload = try JSONEncoder().encode(
            RuntimeSettingValue.text(legacyRelic)
        )
        let legacySealPayload = try JSONEncoder().encode(
            RuntimeSettingValue.text(legacySeal)
        )
        let legacyFramePayload = try JSONEncoder().encode(
            RuntimeSettingValue.text(legacyFrame)
        )
        _ = try await store.transact(
            namespace: namespace,
            transaction: ModuleStateTransaction(
                transactionID: UUID(),
                mutations: [
                    .upsert(ModuleStateUpsert(
                        key: key(RuneScribeRuntimeSettings.selectedCodex),
                        schemaVersion: 1,
                        payload: legacyCodexPayload,
                        expectedRevision: .absent
                    )),
                    .upsert(ModuleStateUpsert(
                        key: key(RuneScribeRuntimeSettings.selectedRelicByCodex),
                        schemaVersion: 1,
                        payload: legacyRelicPayload,
                        expectedRevision: .absent
                    )),
                    .upsert(ModuleStateUpsert(
                        key: key(RuneScribeRuntimeSettings.selectedSealByCodex),
                        schemaVersion: 1,
                        payload: legacySealPayload,
                        expectedRevision: .absent
                    )),
                    .upsert(ModuleStateUpsert(
                        key: key(RuneScribeRuntimeSettings.selectedFrameByCodex),
                        schemaVersion: 1,
                        payload: legacyFramePayload,
                        expectedRevision: .absent
                    )),
                ]
            )
        )

        let capture = RuntimeRailClientCapture()
        let runtime = try await makeRuntime(store: store, capture: capture)
        try await runtime.start()
        let capturedClient = await capture.settingsClient()
        let client = try XCTUnwrap(capturedClient)
        let snapshot = try await client.snapshot()
        XCTAssertEqual(snapshot.selectedCodexID.rawValue, "codex.moonleaf")
        XCTAssertEqual(
            snapshot.artifactSelections(for: .relic)[RuneScribeCodexIDs.norse]?.rawValue,
            "relic.norse.dragonwood-plaque"
        )
        XCTAssertEqual(
            snapshot.artifactSelections(for: .seal)[RuneScribeCodexIDs.norse]?.rawValue,
            "seal.norse.ravenshield"
        )
        XCTAssertEqual(
            snapshot.artifactSelections(for: .frame)[RuneScribeCodexIDs.norse]?.rawValue,
            "frame.norse.carved-knotwork"
        )

        let readOnlyCodexRecord = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedCodex)
        )
        XCTAssertEqual(try XCTUnwrap(readOnlyCodexRecord).payload, legacyCodexPayload)
        let readOnlyRelicRecord = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedRelicByCodex)
        )
        XCTAssertEqual(try XCTUnwrap(readOnlyRelicRecord).payload, legacyRelicPayload)
        let readOnlySealRecord = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedSealByCodex)
        )
        XCTAssertEqual(try XCTUnwrap(readOnlySealRecord).payload, legacySealPayload)
        let readOnlyFrameRecord = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedFrameByCodex)
        )
        XCTAssertEqual(try XCTUnwrap(readOnlyFrameRecord).payload, legacyFramePayload)

        for command in [
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedRelicByCodex,
                value: .text(legacyRelic)
            ),
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedSealByCodex,
                value: .text(legacySeal)
            ),
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedFrameByCodex,
                value: .text(legacyFrame)
            ),
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedSealByCodex,
                value: .text(unknownSeal)
            ),
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedSealByCodex,
                value: .text(futureSeal)
            ),
        ] {
            do {
                _ = try await client.set(command)
                XCTFail("Expected non-current setting write rejection")
            } catch ModuleStateStoreError.invalidRequest {}
        }
        let codexAfterFailedMutation = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedCodex)
        )
        XCTAssertEqual(
            try XCTUnwrap(codexAfterFailedMutation).payload,
            legacyCodexPayload,
            "A failed mutation must not rewrite readable legacy bytes"
        )

        _ = try await client.setArtifactSelections(
            snapshot.artifactSelections(for: .relic)
        )
        let fetchedNormalizedCodexRecord = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedCodex)
        )
        let normalizedCodexRecord = try XCTUnwrap(fetchedNormalizedCodexRecord)
        let normalizedCodexValue = try JSONDecoder().decode(
            RuntimeSettingValue.self,
            from: normalizedCodexRecord.payload
        )
        XCTAssertNoThrow(try RuntimeSelectedCodexPreferenceCodec.decodeCurrentWrite(
            XCTUnwrap(normalizedCodexValue.textValue)
        ))
        let normalizedSelections: [
            (RuntimeSettingID, RuntimeArtifactSelectionKind, String)
        ] = [
            (
                RuneScribeRuntimeSettings.selectedRelicByCodex,
                .relic,
                "relic.norse.dragonwood-plaque"
            ),
            (
                RuneScribeRuntimeSettings.selectedSealByCodex,
                .seal,
                "seal.norse.ravenshield"
            ),
            (
                RuneScribeRuntimeSettings.selectedFrameByCodex,
                .frame,
                "frame.norse.carved-knotwork"
            ),
        ]
        for (settingID, kind, expectedArtifactID) in normalizedSelections {
            let fetchedRecord = try await store.fetch(
                namespace: namespace,
                key: key(settingID)
            )
            let record = try XCTUnwrap(fetchedRecord)
            let value = try JSONDecoder().decode(
                RuntimeSettingValue.self,
                from: record.payload
            )
            let decoded = try RuntimeArtifactSelectionCodec.decodeCurrentWrite(
                XCTUnwrap(value.textValue),
                expectedKind: kind
            )
            XCTAssertEqual(
                decoded[RuneScribeCodexIDs.norse]?.rawValue,
                expectedArtifactID
            )
        }

        await runtime.stop()
    }

    func testSettingsFailClosedForUnknownAndFutureStoredNorseSelections() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 2_800) })
        let namespace = ModuleStateNamespace(moduleID: "com.runescribe.runtime.settings")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        let collection = try XCTUnwrap(ModuleStateCollectionID(rawValue: "settings.values"))
        func key(_ settingID: RuntimeSettingID) -> ModuleStateRecordKey {
            ModuleStateRecordKey(
                collectionID: collection,
                recordID: ModuleStateRecordID(rawValue: settingID.rawValue)!
            )
        }
        let unknownRelic = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"relic","schemaVersion":2,"selections":[{"artifactID":"relic.norse.future-relic","codexID":"codex.norse"}]}"#
        ))
        let futureSeal = try XCTUnwrap(RuntimeSettingText(
            rawValue: #"{"kind":"seal","schemaVersion":3,"selections":[]}"#
        ))
        let unknownRelicPayload = try JSONEncoder().encode(
            RuntimeSettingValue.text(unknownRelic)
        )
        let futureSealPayload = try JSONEncoder().encode(
            RuntimeSettingValue.text(futureSeal)
        )
        _ = try await store.transact(
            namespace: namespace,
            transaction: ModuleStateTransaction(
                transactionID: UUID(),
                mutations: [
                    .upsert(ModuleStateUpsert(
                        key: key(RuneScribeRuntimeSettings.selectedRelicByCodex),
                        schemaVersion: 1,
                        payload: unknownRelicPayload,
                        expectedRevision: .absent
                    )),
                    .upsert(ModuleStateUpsert(
                        key: key(RuneScribeRuntimeSettings.selectedSealByCodex),
                        schemaVersion: 1,
                        payload: futureSealPayload,
                        expectedRevision: .absent
                    )),
                ]
            )
        )

        let capture = RuntimeRailClientCapture()
        let runtime = try await makeRuntime(store: store, capture: capture)
        try await runtime.start()
        let capturedClient = await capture.settingsClient()
        let client = try XCTUnwrap(capturedClient)
        let snapshot = try await client.snapshot()
        XCTAssertEqual(
            snapshot.artifactSelections(for: .relic),
            RuneScribeRuntimeSettings.defaultArtifactSelections(for: .relic)
        )
        XCTAssertEqual(
            snapshot.artifactSelections(for: .seal),
            RuneScribeRuntimeSettings.defaultArtifactSelections(for: .seal)
        )

        _ = try await client.set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
                value: .boolean(false),
                expectedRevision: 0
            )
        )
        let fetchedUnknown = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedRelicByCodex)
        )
        let retainedUnknown = try XCTUnwrap(fetchedUnknown)
        let fetchedFuture = try await store.fetch(
            namespace: namespace,
            key: key(RuneScribeRuntimeSettings.selectedSealByCodex)
        )
        let retainedFuture = try XCTUnwrap(fetchedFuture)
        XCTAssertEqual(retainedUnknown.payload, unknownRelicPayload)
        XCTAssertEqual(retainedFuture.payload, futureSealPayload)

        await runtime.stop()
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
    private var storedCoordinatorSettingsClient: RuntimeSettingsClient?
    private var storedOutboxClient: RuntimeProgressionOutboxClient?

    func setModuleStateClient(_ value: RuntimeModuleStateClient) {
        storedModuleStateClient = value
    }

    func setSettingsClient(_ value: RuntimeSettingsClient) {
        storedSettingsClient = value
    }

    func setCoordinatorSettingsClient(_ value: RuntimeSettingsClient) {
        storedCoordinatorSettingsClient = value
    }

    func setOutboxClient(_ value: RuntimeProgressionOutboxClient) {
        storedOutboxClient = value
    }

    func moduleStateClient() -> RuntimeModuleStateClient? { storedModuleStateClient }
    func settingsClient() -> RuntimeSettingsClient? { storedSettingsClient }
    func coordinatorSettingsClient() -> RuntimeSettingsClient? {
        storedCoordinatorSettingsClient
    }
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

private func themeCoordinatorSettingsDescriptor(
    version: SemanticVersion
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.themeCoordinator,
        moduleVersion: version,
        kind: .service,
        entryPoint: "RuntimeRailThemeCoordinator",
        role: RuneScribeRoles.themeCoordinator,
        policyClass: RuneScribePolicyClasses.themeCoordinator,
        requestedCapabilities: [
            RuneScribeCapabilities.runtimeSettingsRead,
            RuneScribeCapabilities.runtimeSettingsWrite,
        ],
        requiredModuleRoles: [RuneScribeRoles.core]
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
        policyClass: descriptor.policyClass,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )
}
