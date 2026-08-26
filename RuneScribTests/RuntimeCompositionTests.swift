import Foundation
@_spi(ThemeFidelityQualification) import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeUIRuntime
import XCTest
@testable import RuneScrib

@MainActor
final class RuntimeCompositionTests: XCTestCase {
    func testQualificationLaunchParsingAndAdapterFactoriesFailClosed() async throws {
        let validEnvironment = [
            "RUNESCRIBE_QUALIFICATION": "theme-fidelity-v4.2",
            "RUNESCRIBE_QUALIFICATION_RESET_STATE": "1",
            "RUNESCRIBE_QUALIFICATION_THEME_ID": "theme.norse.base",
            "RUNESCRIBE_QUALIFICATION_CODEX_ID": "codex.norse",
            "RUNESCRIBE_QUALIFICATION_DEFAULT_RELIC_ID":
                "relic.norse.runestone-tablet",
            "RUNESCRIBE_QUALIFICATION_DEFAULT_SEAL_ID": "seal.norse.valknut",
            "RUNESCRIBE_QUALIFICATION_SURFACE": "compose-short",
            "RUNESCRIBE_QUALIFICATION_APPEARANCE": "standard",
            "RUNESCRIBE_QUALIFICATION_MESSAGE_PROFILE": "short-two-lines",
            "RUNESCRIBE_QUALIFICATION_DESTINATION": "macos-standard",
        ]
        let validated = ThemeFidelityQualificationLaunch.resolve(
            environment: validEnvironment,
            hostAuthorizationOverride: true
        )
        guard case .validated = validated else {
            return XCTFail("Expected the complete qualification tuple to validate")
        }
        XCTAssertEqual(
            ThemeFidelityQualificationLaunch.resolve(
                environment: validEnvironment,
                hostAuthorizationOverride: false
            ),
            .notRequested
        )

        var stateStoreFactoryWasCalled = false
        var inboundFactoryWasCalled = false
        func makeStateStore() -> any ModuleStateStore {
            stateStoreFactoryWasCalled = true
            return InMemoryModuleStateStore()
        }
        func makeInboundReader() -> any InboundFileReader {
            inboundFactoryWasCalled = true
            return InMemoryInboundFileReader()
        }

        let validatedComposition = RuneScribeRuntimeComposition(
            qualificationResolution: validated,
            moduleStateStore: makeStateStore(),
            inboundFiles: makeInboundReader()
        )
        XCTAssertFalse(stateStoreFactoryWasCalled)
        XCTAssertFalse(inboundFactoryWasCalled)

        await validatedComposition.start()
        let qualificationSnapshot = await validatedComposition.runtimeSnapshot
        XCTAssertFalse(validatedComposition.startupFailed)
        XCTAssertEqual(qualificationSnapshot.entitlementSnapshot.revision, 4_200)
        XCTAssertEqual(
            qualificationSnapshot.entitlementSnapshot.includedUnlockIDs,
            [RuneScribeUnlockIDs.norseCodex]
        )
        XCTAssertEqual(
            Set(qualificationSnapshot.entitlementSnapshot.earnedUnlockIDs.map(\.rawValue)),
            Set([
                "unlock.codex.moonleaf",
                "unlock.codex.sunspire",
                "unlock.codex.wildwood",
                "unlock.codex.gloamthorn",
            ])
        )
        await validatedComposition.stop()

        var invalidEnvironment = validEnvironment
        invalidEnvironment["RUNESCRIBE_QUALIFICATION_RESET_STATE"] = "0"
        let invalid = ThemeFidelityQualificationLaunch.resolve(
            environment: invalidEnvironment,
            hostAuthorizationOverride: true
        )
        XCTAssertEqual(invalid, .invalid)
        _ = RuneScribeRuntimeComposition(
            qualificationResolution: invalid,
            moduleStateStore: makeStateStore(),
            inboundFiles: makeInboundReader()
        )
        XCTAssertFalse(stateStoreFactoryWasCalled)
        XCTAssertFalse(inboundFactoryWasCalled)
    }

    func testMacAppDelegateForwardsLifecycleThroughInjectedRuntime() async {
        let fixture = makeFixture()
        let delegate = AppDelegate(runtime: fixture.composition)
        let notification = Notification(name: NSApplication.didBecomeActiveNotification)

        delegate.applicationDidBecomeActive(notification)
        delegate.applicationWillResignActive(notification)
        delegate.applicationDidResignActive(notification)

        await fixture.composition.start()
        var received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 3)
        guard received.count == 3 else {
            await fixture.composition.stop()
            return
        }
        assertLifecycle(received[0], equals: .didBecomeActive, isColdStart: true)
        assertLifecycle(received[1], equals: .willResignActive, isColdStart: true)
        assertLifecycle(received[2], equals: .didEnterBackground, isColdStart: true)

        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
        await fixture.composition.stop()

        received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 4)
        if received.count == 4 {
            assertLifecycle(received[3], equals: .willTerminate, isColdStart: false)
        }
        XCTAssertEqual(fixture.composition.rootPresentationStore.state, .booting)
    }

    func testCompositionPublishesRootAcrossStartStopAndRestart() async {
        let fixture = makeFixture()

        await fixture.composition.start()

        XCTAssertFalse(fixture.composition.startupFailed)
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )

        await fixture.composition.stop()

        XCTAssertEqual(fixture.composition.rootPresentationStore.state, .booting)

        await fixture.composition.start()

        XCTAssertFalse(fixture.composition.startupFailed)
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )

        await fixture.composition.stop()
        XCTAssertEqual(fixture.composition.rootPresentationStore.state, .booting)
    }

    func testCompositionInstallsModuleStateStoreBeforeRuntimeActivation() async {
        let store = InMemoryModuleStateStore()
        let startGate = HostedActivationGate()
        let fixture = makeFixture(startGate: startGate, moduleStateStore: store)
        let startTask = Task { await fixture.composition.start() }
        await startGate.waitUntilEntered()

        let registeredSnapshot = await fixture.composition.runtimeSnapshot
        XCTAssertEqual(
            registeredSnapshot.moduleStates[RuneScribeModuleIDs.progression],
            .eligible
        )
        await startGate.release()
        await startTask.value

        XCTAssertFalse(fixture.composition.startupFailed)
        let snapshot = await fixture.composition.runtimeSnapshot
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.core], .active)
        XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.progression], .active)
        XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.primaryUI], .active)
        if let progressionIndex = snapshot.activationOrder.firstIndex(
            of: RuneScribeModuleIDs.progression
        ), let uiIndex = snapshot.activationOrder.firstIndex(
            of: RuneScribeModuleIDs.primaryUI
        ) {
            XCTAssertLessThan(progressionIndex, uiIndex)
        } else {
            XCTFail("Expected Progression and UI in the runtime activation order.")
        }
        let settingsHealth = await store.health(
            namespace: ModuleStateNamespace(moduleID: "com.runescribe.runtime.settings")
        )
        let outboxHealth = await store.health(
            namespace: ModuleStateNamespace(
                moduleID: "com.runescribe.runtime.progression-outbox"
            )
        )
        let progressionHealth = await store.health(
            namespace: ModuleStateNamespace(moduleID: RuneScribeModuleIDs.progression)
        )
        XCTAssertEqual(settingsHealth.namespaceSchemaVersion, 1)
        XCTAssertEqual(outboxHealth.namespaceSchemaVersion, 1)
        XCTAssertEqual(progressionHealth.namespaceSchemaVersion, 1)
        XCTAssertGreaterThan(progressionHealth.recordCount, 0)
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )
        await fixture.composition.stop()
    }

    func testPhysicalModuleStateStoreConstructionFailureDegradesWithoutFallback() async {
        let fixture = makeFixture(moduleStateStore: nil)

        await fixture.composition.start()

        XCTAssertFalse(fixture.composition.startupFailed)
        let snapshot = await fixture.composition.runtimeSnapshot
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.core], .active)
        XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.progression], .failed)
        XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.primaryUI], .active)
        XCTAssertFalse(snapshot.activationOrder.contains(RuneScribeModuleIDs.progression))
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )
        XCTAssertEqual(
            fixture.composition.receive(lifecycle: .didBecomeActive),
            .accepted
        )
        let received = await waitForInputs(1, from: fixture.inboundInputService)
        XCTAssertEqual(received.count, 1)
        await fixture.composition.stop()
    }

    func testRuntimeInputRailPreservesMappingMetadataAndFIFOAcrossStopStart() async throws {
        let coldURL = URL(string: "runescribe://import?p=cold-url")!
        let coldFileData = Data("cold-runtime-composition-file".utf8)
        let detachedFileData = Data("detached-runtime-composition-file".utf8)
        let fixtureID = UUID().uuidString
        let coldFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuneScribeRuntimeCompositionTests-cold-\(fixtureID).runescribe"
            )
        let detachedFile = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuneScribeRuntimeCompositionTests-detached-\(fixtureID).runescribe"
            )
        let inboundFiles = InMemoryInboundFileReader(
            files: [
                coldFile: coldFileData,
                detachedFile: detachedFileData,
            ]
        )
        let fixture = makeFixture(inboundFiles: inboundFiles)

        XCTAssertEqual(
            fixture.composition.receive(
                urls: [coldURL, coldFile],
                source: .sceneOpen
            ),
            [.accepted, .accepted]
        )
        XCTAssertEqual(
            fixture.composition.receive(menu: .openSettings),
            .accepted
        )
        XCTAssertEqual(
            fixture.composition.receive(lifecycle: .didBecomeActive),
            .accepted
        )

        var received = await fixture.inboundInputService.snapshot()
        XCTAssertTrue(received.isEmpty)

        await fixture.composition.start()

        received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 4)
        guard received.count == 4 else {
            await fixture.composition.stop()
            return
        }
        assertURL(
            received[0],
            equals: coldURL,
            source: .sceneOpen,
            isColdStart: true
        )
        assertFile(
            received[1],
            equals: coldFileData,
            source: .sceneOpen,
            isColdStart: true
        )
        assertMenu(
            received[2],
            equals: .openSettings,
            isColdStart: true
        )
        assertLifecycle(
            received[3],
            equals: .didBecomeActive,
            isColdStart: true
        )

        let warmURL = URL(string: "https://ravenforgesoftware.com/rune-scribe/import?p=warm")!
        XCTAssertEqual(
            fixture.composition.receive(
                urls: [warmURL],
                source: .webBrowsingActivity
            ),
            [.accepted]
        )
        XCTAssertEqual(
            fixture.composition.receive(menu: .openCipherLibrary),
            .accepted
        )

        await fixture.composition.stop()

        received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 6)
        guard received.count == 6 else { return }
        assertURL(
            received[4],
            equals: warmURL,
            source: .webBrowsingActivity,
            isColdStart: false
        )
        assertMenu(
            received[5],
            equals: .openCipherLibrary,
            isColdStart: false
        )

        XCTAssertEqual(
            fixture.composition.receive(
                urls: [detachedFile],
                source: .fileImporter
            ),
            [.accepted]
        )
        XCTAssertEqual(
            fixture.composition.receive(lifecycle: .didEnterBackground),
            .accepted
        )

        for _ in 0..<20 { await Task.yield() }
        let whileDetached = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(whileDetached, received)

        await fixture.composition.start()

        received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 8)
        guard received.count == 8 else {
            await fixture.composition.stop()
            return
        }
        assertFile(
            received[6],
            equals: detachedFileData,
            source: .fileImporter,
            isColdStart: false
        )
        assertLifecycle(
            received[7],
            equals: .didEnterBackground,
            isColdStart: false
        )
        XCTAssertEqual(
            Set(received.map(\.metadata.id)).count,
            received.count,
            "Every host callback should receive distinct metadata."
        )

        await fixture.composition.stop()
    }

    func testConcurrentStopsJoinInterruptedStartAndCannotLeaveRuntimeActive() async {
        let startGate = HostedActivationGate()
        let fixture = makeFixture(startGate: startGate)
        let completions = HostedStopCompletions()
        let startTask = Task { await fixture.composition.start() }
        await startGate.waitUntilEntered()

        let firstStop = Task {
            await fixture.composition.stop()
            await completions.recordCompletion()
        }
        let secondStop = Task {
            await fixture.composition.stop()
            await completions.recordCompletion()
        }
        for _ in 0..<20 { await Task.yield() }
        let completionsBeforeRelease = await completions.count
        XCTAssertEqual(completionsBeforeRelease, 0)

        await startGate.release()
        await firstStop.value
        await secondStop.value
        await startTask.value

        let finalCompletionCount = await completions.count
        XCTAssertEqual(finalCompletionCount, 2)
        XCTAssertEqual(fixture.composition.rootPresentationStore.state, .booting)

        await fixture.composition.start()
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )
        await fixture.composition.stop()
    }

    func testIngressAdmissionFailurePresentsSanitizedRootNotice() async throws {
        let fixture = makeFixture()
        let sensitiveMarker = "private-input-must-not-be-presented"
        let oversized = try XCTUnwrap(
            URL(
                string: "runescribe://import?p="
                    + sensitiveMarker
                    + String(repeating: "x", count: 4_096)
            )
        )

        XCTAssertEqual(
            fixture.composition.receive(urls: [oversized], source: .sceneOpen),
            [.rejected]
        )
        var notice: RootPresentationNotice?
        for _ in 0..<1_000 {
            notice = fixture.composition.rootPresentationStore.notice
            if notice != nil { break }
            await Task.yield()
        }

        XCTAssertEqual(fixture.composition.lastInputFailure, .admissionRejected)
        XCTAssertEqual(notice, .inputRejected)
        let message = try XCTUnwrap(notice?.message)
        XCTAssertLessThanOrEqual(message.utf8.count, 96)
        XCTAssertFalse(message.contains(sensitiveMarker))
        XCTAssertEqual(message, "Rune Scribe could not accept that item.")
    }

    func testUnavailableDestinationFailurePresentsSanitizedRootNotice() throws {
        let fixture = makeFixture()
        let sensitiveMarker = "unroutable-private-input"

        fixture.composition.presentHostIngressFailure(.destinationUnavailable)

        let notice = try XCTUnwrap(
            fixture.composition.rootPresentationStore.notice
        )
        XCTAssertEqual(notice, .inputUnavailable)
        XCTAssertLessThanOrEqual(notice.message.utf8.count, 96)
        XCTAssertFalse(notice.message.contains(sensitiveMarker))
        XCTAssertEqual(
            notice.message,
            "Rune Scribe could not open that item right now."
        )
    }

    private func makeFixture(
        startGate: HostedActivationGate? = nil,
        moduleStateStore: (any ModuleStateStore)? = InMemoryModuleStateStore(),
        inboundFiles: any InboundFileReader = InMemoryInboundFileReader()
    ) -> RuntimeCompositionFixture {
        let secureValues = InMemorySecureValueStore()
        let protectedFiles = InMemoryProtectedFileStore()
        let shareArtifacts = InMemoryShareArtifactStore()
        let clock = SystemClock()
        let uuid = SystemUUIDProvider()
        let runtimeIO = RuntimeIOClient(
            secureValueData: {
                try await secureValues.data(service: $0, account: $1)
            },
            setSecureValue: {
                try await secureValues.set($0, service: $1, account: $2)
            },
            deleteSecureValue: {
                try await secureValues.delete(service: $0, account: $1)
            },
            readProtectedFile: {
                try await protectedFiles.read(
                    relativePath: $0,
                    maximumByteCount: $1
                )
            },
            writeProtectedFile: {
                try await protectedFiles.write($0, relativePath: $1)
            },
            removeProtectedFile: {
                try await protectedFiles.remove(relativePath: $0)
            },
            protectedFileExists: {
                try await protectedFiles.exists(relativePath: $0)
            },
            protectedFileContents: {
                try await protectedFiles.contents(of: $0, matchingExtension: $1)
            },
            now: { clock.now() },
            nextUUID: { uuid.nextUUID() },
            createShareArtifact: {
                try await shareArtifacts.create(
                    $0,
                    artifactID: $1,
                    filename: $2,
                    fileExtension: $3
                )
            },
            storeShareArtifactLink: {
                try await shareArtifacts.storeLink($0, artifactID: $1)
            },
            removeShareArtifactLink: {
                try await shareArtifacts.removeLink(artifactID: $0)
            },
            removeShareArtifact: { try await shareArtifacts.remove(artifactID: $0) },
            removeAllShareArtifacts: { try await shareArtifacts.removeAll() }
        )
        let applicationService = RuneScribeCoreApplicationService(runtimeIO: runtimeIO)
        let inboundInputService = RecordingInboundInputService()
        let coreFactory = AnyModuleFactory(
            descriptor: RuneScribeCoreModuleBootstrap.descriptor
        ) {
            HostedTestCoreModule(
                applicationService: applicationService,
                inboundInputService: inboundInputService,
                startGate: startGate
            )
        }
        return RuntimeCompositionFixture(
            composition: RuneScribeRuntimeComposition(
                bundle: .main,
                injectedCoreFactory: coreFactory,
                moduleStateStore: moduleStateStore,
                inboundFiles: inboundFiles,
                cloudSync: NoAccountCloudSyncTransport()
            ),
            inboundInputService: inboundInputService
        )
    }

    private func waitForInputs(
        _ minimumCount: Int,
        from service: RecordingInboundInputService
    ) async -> [RuneScribeInboundInput] {
        for _ in 0..<500 {
            let values = await service.snapshot()
            if values.count >= minimumCount { return values }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await service.snapshot()
    }

    private func assertURL(
        _ input: RuneScribeInboundInput,
        equals expectedURL: URL,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .url(let value) = input else {
            XCTFail("Expected URL input, received \(input).", file: file, line: line)
            return
        }
        XCTAssertEqual(value.url, expectedURL, file: file, line: line)
        assertMetadata(
            value.metadata,
            source: source,
            isColdStart: isColdStart,
            file: file,
            line: line
        )
    }

    private func assertFile(
        _ input: RuneScribeInboundInput,
        equals expectedData: Data,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .file(let value) = input else {
            XCTFail("Expected file input, received \(input).", file: file, line: line)
            return
        }
        XCTAssertEqual(value.data, expectedData, file: file, line: line)
        XCTAssertNil(value.declaredContentType, file: file, line: line)
        assertMetadata(
            value.metadata,
            source: source,
            isColdStart: isColdStart,
            file: file,
            line: line
        )
    }

    private func assertMenu(
        _ input: RuneScribeInboundInput,
        equals expectedCommand: ApplicationMenuCommandDTO,
        isColdStart: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .menu(let value) = input else {
            XCTFail("Expected menu input, received \(input).", file: file, line: line)
            return
        }
        XCTAssertEqual(value.command, expectedCommand, file: file, line: line)
        assertMetadata(
            value.metadata,
            source: .applicationOpen,
            isColdStart: isColdStart,
            file: file,
            line: line
        )
    }

    private func assertLifecycle(
        _ input: RuneScribeInboundInput,
        equals expectedEvent: ApplicationLifecycleInputDTO,
        isColdStart: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .lifecycle(let value) = input else {
            XCTFail("Expected lifecycle input, received \(input).", file: file, line: line)
            return
        }
        XCTAssertEqual(value.event, expectedEvent, file: file, line: line)
        assertMetadata(
            value.metadata,
            source: .applicationOpen,
            isColdStart: isColdStart,
            file: file,
            line: line
        )
    }

    private func assertMetadata(
        _ metadata: InboundInputMetadataDTO,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertEqual(metadata.source, source, file: file, line: line)
        XCTAssertEqual(metadata.isColdStart, isColdStart, file: file, line: line)
    }
}

private struct RuntimeCompositionFixture {
    let composition: RuneScribeRuntimeComposition
    let inboundInputService: RecordingInboundInputService
}

private struct HostedTestCoreModule: RuneScribeModule {
    let descriptor = RuneScribeCoreModuleBootstrap.descriptor
    let applicationService: RuneScribeCoreApplicationService
    let inboundInputService: RecordingInboundInputService
    let startGate: HostedActivationGate?

    func start(context: ModuleContext) async throws {
        if let startGate { await startGate.enterAndWait() }
        try await context.registerApplicationEndpoints(applicationService)
        try await context.registerInboundInputEndpoint(inboundInputService)
        await applicationService.startInboundProcessing()
    }

    func stop() async {
        await applicationService.stopInboundProcessing()
    }
}

private actor HostedActivationGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor HostedStopCompletions {
    private(set) var count = 0
    func recordCompletion() { count += 1 }
}

private actor RecordingInboundInputService: RuneScribeInboundInputService {
    private var inputs: [RuneScribeInboundInput] = []

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        inputs.append(input)
        return .accepted
    }

    func snapshot() -> [RuneScribeInboundInput] {
        inputs
    }
}
