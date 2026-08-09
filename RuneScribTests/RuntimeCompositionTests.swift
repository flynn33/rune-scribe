import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeUIRuntime
import XCTest
@testable import RuneScrib

@MainActor
final class RuntimeCompositionTests: XCTestCase {
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

    func testInputRailPreservesMappingMetadataAndFIFOAcrossDetach() async {
        let fixture = makeFixture()
        let coldURL = URL(string: "runescribe://import?p=cold-url")!
        let coldFile = URL(fileURLWithPath: "/in-memory/cold.runescribe")

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
            equals: coldFile,
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

        let detachedFile = URL(fileURLWithPath: "/in-memory/detached.runescribe")
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
            equals: detachedFile,
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

    private func makeFixture(
        startGate: HostedActivationGate? = nil
    ) -> RuntimeCompositionFixture {
        let applicationService = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            shareArtifactStore: InMemoryShareArtifactStore(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
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
                injectedCoreFactory: coreFactory
            ),
            inboundInputService: inboundInputService
        )
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
        equals expectedURL: URL,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .file(let value) = input else {
            XCTFail("Expected file input, received \(input).", file: file, line: line)
            return
        }
        XCTAssertEqual(value.fileURL, expectedURL, file: file, line: line)
        XCTAssertTrue(value.requiresSecurityScopedAccess, file: file, line: line)
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
        try await context.publishService(
            applicationService as any RuneScribeApplicationService,
            for: RuneScribeServiceKeys.application
        )
        try await context.publishService(
            inboundInputService as any RuneScribeInboundInputService,
            for: RuneScribeServiceKeys.inboundInput
        )
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
