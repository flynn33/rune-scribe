import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeUIRuntime
import UIKit
import XCTest
@testable import RuneScrib

@MainActor
final class AppHostRoutingTests: XCTestCase {
    func testAppDelegateIgnoresUnsupportedAndBrowsingActivitiesWithoutURLs() async {
        let fixture = makeFixture()
        let delegate = AppDelegate(runtime: fixture.composition)
        let unsupported = NSUserActivity(activityType: "com.runescribe.unsupported")
        unsupported.webpageURL = URL(
            string: "https://ravenforgesoftware.com/rune-scribe/import?p=ignored"
        )
        let missingURL = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)

        XCTAssertEqual(delegate.receive(userActivity: unsupported), [])
        XCTAssertEqual(delegate.receive(userActivity: missingURL), [])

        await fixture.composition.start()
        let received = await fixture.inboundInputService.snapshot()
        XCTAssertTrue(received.isEmpty)
        await fixture.composition.stop()
    }

    func testAppDelegateRoutesURLsFilesActivitiesAndLifecycleWithColdWarmMetadata() async {
        let fixture = makeFixture()
        let delegate = AppDelegate(runtime: fixture.composition)
        let application = UIApplication.shared
        let coldURL = URL(string: "runescribe://import?p=cold")!
        let coldFile = URL(fileURLWithPath: "/in-memory/cold.runescribe")
        let coldWebURL = URL(string: "https://ravenforgesoftware.com/rune-scribe/import?p=cold-web")!
        let coldActivity = browsingActivity(url: coldWebURL)

        XCTAssertTrue(delegate.application(application, open: coldURL))
        XCTAssertTrue(delegate.application(application, open: coldFile))
        XCTAssertEqual(delegate.receive(userActivity: coldActivity), [.accepted])
        delegate.applicationDidBecomeActive(application)
        delegate.applicationWillResignActive(application)
        delegate.applicationDidEnterBackground(application)
        delegate.applicationWillEnterForeground(application)
        XCTAssertEqual(delegate.receive(lifecycle: .willTerminate), .accepted)

        await fixture.composition.start()

        var received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 8)
        guard received.count == 8 else {
            await fixture.composition.stop()
            return
        }
        assertURL(received[0], equals: coldURL, source: .applicationOpen, isColdStart: true)
        assertFile(received[1], equals: coldFile, source: .applicationOpen, isColdStart: true)
        assertURL(received[2], equals: coldWebURL, source: .webBrowsingActivity, isColdStart: true)
        assertLifecycle(received[3], equals: .didBecomeActive, isColdStart: true)
        assertLifecycle(received[4], equals: .willResignActive, isColdStart: true)
        assertLifecycle(received[5], equals: .didEnterBackground, isColdStart: true)
        assertLifecycle(received[6], equals: .willEnterForeground, isColdStart: true)
        assertLifecycle(received[7], equals: .willTerminate, isColdStart: true)

        let warmURL = URL(string: "runescribe://import?p=warm")!
        let warmWebURL = URL(string: "https://ravenforgesoftware.com/rune-scribe/import?p=warm-web")!
        XCTAssertTrue(delegate.application(application, open: warmURL))
        XCTAssertEqual(delegate.receive(userActivity: browsingActivity(url: warmWebURL)), [.accepted])
        delegate.applicationDidBecomeActive(application)

        await fixture.composition.stop()

        received = await fixture.inboundInputService.snapshot()
        XCTAssertEqual(received.count, 11)
        guard received.count == 11 else { return }
        assertURL(received[8], equals: warmURL, source: .applicationOpen, isColdStart: false)
        assertURL(received[9], equals: warmWebURL, source: .webBrowsingActivity, isColdStart: false)
        assertLifecycle(received[10], equals: .didBecomeActive, isColdStart: false)
        XCTAssertEqual(Set(received.map(\.metadata.id)).count, received.count)
    }

    func testSwiftUIScenePhaseMappingForwardsOrderedLifecycleInputs() {
        XCTAssertEqual(RuneScribApp.lifecycleInputs(from: .inactive, to: .active), [.didBecomeActive])
        XCTAssertEqual(RuneScribApp.lifecycleInputs(from: .active, to: .inactive), [.willResignActive])
        XCTAssertEqual(RuneScribApp.lifecycleInputs(from: .inactive, to: .background), [.didEnterBackground])
        XCTAssertEqual(RuneScribApp.lifecycleInputs(from: .background, to: .inactive), [.willEnterForeground])
        XCTAssertEqual(
            RuneScribApp.lifecycleInputs(from: .background, to: .active),
            [.willEnterForeground, .didBecomeActive]
        )
        XCTAssertEqual(RuneScribApp.lifecycleInputs(from: .inactive, to: .inactive), [])
    }

    func testCompositionRecoversFromFirstStartupFailureAndRetries() async {
        let startAttempt = HostedStartAttempt()
        let fixture = makeFixture(startAttempt: startAttempt)

        await fixture.composition.start()

        XCTAssertTrue(fixture.composition.startupFailed)
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .recovery(message: "Please quit and reopen Rune Scribe.")
        )
        let failedAttemptCount = await startAttempt.count
        XCTAssertEqual(failedAttemptCount, 1)

        await fixture.composition.start()

        XCTAssertFalse(fixture.composition.startupFailed)
        XCTAssertEqual(
            fixture.composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )
        let recoveredAttemptCount = await startAttempt.count
        XCTAssertEqual(recoveredAttemptCount, 2)

        await fixture.composition.stop()
        XCTAssertEqual(fixture.composition.rootPresentationStore.state, .booting)
    }

    func testSystemClipboardAdapterRoundTripsWithinHostedApplicationWithoutPastePrompt() async throws {
        let clipboard = SystemClipboardService()
        let originalChangeCount = await clipboard.changeCount()
        defer {
            UIPasteboard.general.items = []
        }
        try await clipboard.setString(Self.clipboardCipherURL.absoluteString)
        let string = await clipboard.string()
        let updatedChangeCount = await clipboard.changeCount()
        XCTAssertEqual(string, Self.clipboardCipherURL.absoluteString)
        XCTAssertGreaterThan(updatedChangeCount, originalChangeCount)
    }

    private func makeFixture(startAttempt: HostedStartAttempt? = nil) -> AppHostFixture {
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
            HostedCoreModule(
                applicationService: applicationService,
                inboundInputService: inboundInputService,
                startAttempt: startAttempt
            )
        }
        return AppHostFixture(
            composition: RuneScribeRuntimeComposition(
                bundle: .main,
                injectedCoreFactory: coreFactory
            ),
            inboundInputService: inboundInputService
        )
    }

    private func browsingActivity(url: URL) -> NSUserActivity {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        return activity
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
        assertMetadata(value.metadata, source: source, isColdStart: isColdStart, file: file, line: line)
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
        assertMetadata(value.metadata, source: source, isColdStart: isColdStart, file: file, line: line)
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
        assertMetadata(value.metadata, source: .applicationOpen, isColdStart: isColdStart, file: file, line: line)
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

    private static let clipboardCipherURL = URL(
        string: "runescribe://import?v=3&p="
            + "AwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8f"
            + "Hh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1y"
            + "dW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhN"
            + "&n=Clipboard%20Cipher"
    )!
}

private struct AppHostFixture {
    let composition: RuneScribeRuntimeComposition
    let inboundInputService: RecordingInboundInputService
}

private struct HostedCoreModule: RuneScribeModule {
    let descriptor = RuneScribeCoreModuleBootstrap.descriptor
    let applicationService: RuneScribeCoreApplicationService
    let inboundInputService: RecordingInboundInputService
    let startAttempt: HostedStartAttempt?

    func start(context: ModuleContext) async throws {
        if let startAttempt, await startAttempt.shouldFail() {
            throw HostedStartFailure.requested
        }
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

private enum HostedStartFailure: Error {
    case requested
}

private actor HostedStartAttempt {
    private var attempts = 0

    func shouldFail() -> Bool {
        attempts += 1
        return attempts == 1
    }

    var count: Int { attempts }
}

private actor RecordingInboundInputService: RuneScribeInboundInputService {
    private var inputs: [RuneScribeInboundInput] = []

    func receive(_ input: RuneScribeInboundInput) async throws -> InboundInputDispositionDTO {
        inputs.append(input)
        return .accepted
    }

    func snapshot() -> [RuneScribeInboundInput] {
        inputs
    }
}
