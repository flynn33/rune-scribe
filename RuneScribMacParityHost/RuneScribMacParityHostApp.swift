import AppKit
import Foundation
import RuneScribeContracts
import RuneScribePlatform
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import RuneScribeUIRuntime
import SwiftUI

@MainActor
private final class RuneScribMacParityHostDelegate: NSObject,
    NSApplicationDelegate
{
    private var selfTest: NativeShareSelfTest?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let reportURL = Self.selfTestReportURL() else { return }
        NSApp.activate()
        let selfTest = NativeShareSelfTest(reportURL: reportURL)
        self.selfTest = selfTest
        Task { @MainActor in
            await selfTest.run()
            NSApp.terminate(nil)
        }
    }

    private static func selfTestReportURL() -> URL? {
        let arguments = CommandLine.arguments
        guard let marker = arguments.firstIndex(of: "--native-share-self-test"),
              arguments.indices.contains(marker + 1)
        else { return nil }
        return URL(fileURLWithPath: arguments[marker + 1])
    }
}

/// Isolated verification host. Product state and adapters are created only by
/// the hosted unit tests. The optional native-share self-test uses synthetic
/// files, a same-process AppKit trigger, and public presentation-handle
/// dismissal, then exits without touching user data.
@main
struct RuneScribMacParityHostApp: App {
    @NSApplicationDelegateAdaptor(RuneScribMacParityHostDelegate.self)
    private var applicationDelegate

    var body: some Scene {
        WindowGroup {
            EmptyView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1, height: 1)
    }
}

@MainActor
private final class NativeShareSelfTest {
    private let reportURL: URL

    init(reportURL: URL) {
        self.reportURL = reportURL
    }

    func run() async {
        var fixture: NativeShareRuntimeFixture?
        let report: NativeShareSelfTestReport
        do {
            let activeFixture = try await NativeShareRuntimeFixture.start()
            fixture = activeFixture
            let fileResult = try await runFileShare(using: activeFixture)
            let linkResult = try await runCipherLinkShare(using: activeFixture)
            report = NativeShareSelfTestReport(
                version: 2,
                file: fileResult,
                link: linkResult,
                passed: fileResult.passed && linkResult.passed
            )
        } catch let failure as NativeShareSelfTestFailure {
            report = NativeShareSelfTestReport(
                version: 2,
                file: .notRun,
                link: .notRun,
                passed: false,
                failureCode: failure.rawValue
            )
        } catch {
            report = NativeShareSelfTestReport(
                version: 2,
                file: .notRun,
                link: .notRun,
                passed: false,
                failureCode: NativeShareSelfTestFailure.unexpected.rawValue
            )
        }
        await fixture?.stop()

        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let bytes = try JSONEncoder().encode(report)
            try bytes.write(to: reportURL, options: .atomic)
        } catch {
            // The shell gate also has a bounded timeout, so a report-write
            // failure terminates safely and is observed as a failed check.
        }
    }

    private func runFileShare(
        using fixture: NativeShareRuntimeFixture
    ) async throws -> NativeShareStepReport {
        let transfer = try await fixture.makeFileTransfer()
        var triggerCount = 0
        var finishCompletion: SharePresentationCompletion?
        var presentation: RuneScribeSharePresentationHandle?
        let view = AnyView(
            RuneScribeFileShareLink(
                transfer: transfer,
                onShareTriggered: { triggerCount += 1 },
                onFinish: { finishCompletion = $0 },
                onPresentation: { presentation = $0 }
            )
            .frame(width: 260, height: 100)
        )
        do {
            let report = try await presentAndDismiss(
                view: view,
                triggerCount: { triggerCount },
                finishCompletion: { finishCompletion },
                presentation: { presentation }
            )
            await transfer.close()
            return report
        } catch {
            await transfer.close()
            throw error
        }
    }

    private func runCipherLinkShare(
        using fixture: NativeShareRuntimeFixture
    ) async throws -> NativeShareStepReport {
        let transfer = try await fixture.makeLinkTransfer()
        var triggerCount = 0
        var finishCompletion: SharePresentationCompletion?
        var presentation: RuneScribeSharePresentationHandle?
        let view = AnyView(
            RuneScribeCipherLinkShareLink(
                transfer: transfer,
                cipherLabel: "Synthetic Cipher",
                onShareTriggered: { triggerCount += 1 },
                onFinish: { finishCompletion = $0 },
                onPresentation: { presentation = $0 }
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 260, height: 100)
        )
        do {
            let report = try await presentAndDismiss(
                view: view,
                triggerCount: { triggerCount },
                finishCompletion: { finishCompletion },
                presentation: { presentation }
            )
            await transfer.close()
            return report
        } catch {
            await transfer.close()
            throw error
        }
    }

    private func presentAndDismiss(
        view: AnyView,
        triggerCount: () -> Int,
        finishCompletion: () -> SharePresentationCompletion?,
        presentation: () -> RuneScribeSharePresentationHandle?
    ) async throws -> NativeShareStepReport {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            throw NativeShareSelfTestFailure.noScreen
        }
        let size = CGSize(width: 260, height: 100)
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(
                x: screen.visibleFrame.minX + 24,
                y: screen.visibleFrame.minY + 24,
                width: size.width,
                height: size.height
            ),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.hasShadow = false
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        guard await waitUntil(timeout: 2, predicate: { window.isVisible }) else {
            throw NativeShareSelfTestFailure.hostWindowNotVisible
        }

        let clickPoint = NSPoint(x: size.width / 2, y: size.height / 2)
        guard let hitView = hostingView.hitTest(clickPoint) else {
            throw NativeShareSelfTestFailure.controlNotHittable
        }
        let mouseDown = try mouseEvent(
            type: .leftMouseDown,
            location: clickPoint,
            window: window,
            eventNumber: 1,
            pressure: 1
        )
        let mouseUp = try mouseEvent(
            type: .leftMouseUp,
            location: clickPoint,
            window: window,
            eventNumber: 2,
            pressure: 0
        )
        hitView.mouseDown(with: mouseDown)
        hitView.mouseUp(with: mouseUp)

        guard await waitUntil(timeout: 2, predicate: { triggerCount() == 1 }) else {
            throw NativeShareSelfTestFailure.triggerCountMismatch
        }
        guard await waitUntil(timeout: 5, predicate: {
            (presentation()?.proposedServiceCount ?? 0) > 0
        }) else {
            throw NativeShareSelfTestFailure.pickerDidNotPresent
        }
        guard let presentationHandle = presentation() else {
            throw NativeShareSelfTestFailure.pickerDidNotPresent
        }
        presentationHandle.close()

        guard await waitUntil(timeout: 5, predicate: {
            guard case .success(let evidence)? = finishCompletion() else {
                return false
            }
            return evidence.report.routeClass == .shareSheet
                && evidence.report.result == .cancelled
        }) else {
            throw NativeShareSelfTestFailure.presentationHandleDidNotDismiss
        }
        return NativeShareStepReport(
            triggerCount: 1,
            nativePickerPresented: true,
            dismissedByHandleClose: true
        )
    }

    private func mouseEvent(
        type: NSEvent.EventType,
        location: NSPoint,
        window: NSWindow,
        eventNumber: Int,
        pressure: Float
    ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: pressure
        ) else {
            throw NativeShareSelfTestFailure.eventCreationFailed
        }
        return event
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            try? await Task<Never, Never>.sleep(for: .milliseconds(20))
        } while Date() < deadline
        return predicate()
    }
}

@MainActor
private final class NativeShareRuntimeFixture {
    private let runtime: RuneScribeRuntime
    private let runtimeIO: RuntimeIOClient
    private let shareArtifacts: AppleShareArtifactStore
    private let temporaryRoot: URL
    private var isStopped = false

    private init(
        runtime: RuneScribeRuntime,
        runtimeIO: RuntimeIOClient,
        shareArtifacts: AppleShareArtifactStore,
        temporaryRoot: URL
    ) {
        self.runtime = runtime
        self.runtimeIO = runtimeIO
        self.shareArtifacts = shareArtifacts
        self.temporaryRoot = temporaryRoot
    }

    static func start() async throws -> NativeShareRuntimeFixture {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuneScribeMacParityHostRuntime-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )

        let shareArtifacts = AppleShareArtifactStore(
            temporaryDirectory: temporaryRoot
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: NativeShareRuntimeModule.version,
            platform: .macOS
        )
        let clientCapture = NativeShareRuntimeClientCapture()

        do {
            let moduleStateStore = try AppleSQLiteModuleStateStore(
                applicationSupportDirectory: temporaryRoot
            )
            try await runtime.register(
                manifest: NativeShareRuntimeModule.manifest,
                factory: AnyModuleFactory(
                    descriptor: NativeShareRuntimeModule.descriptor
                ) {
                    NativeShareRuntimeClientModule(capture: clientCapture)
                }
            )
            try await runtime.installPlatformAdapter(
                shareArtifacts,
                for: RuneScribeServiceKeys.sharePresentation
            )
            try await runtime.installPlatformAdapter(
                moduleStateStore,
                for: RuneScribeServiceKeys.moduleStateStore
            )
            try await runtime.start()
            return NativeShareRuntimeFixture(
                runtime: runtime,
                runtimeIO: try await clientCapture.requireRuntimeIO(),
                shareArtifacts: shareArtifacts,
                temporaryRoot: temporaryRoot
            )
        } catch {
            await runtime.stop()
            try? await shareArtifacts.removeAll()
            try? FileManager.default.removeItem(at: temporaryRoot)
            throw error
        }
    }

    func makeFileTransfer() async throws -> OpaqueShareTransfer {
        let artifactID = ShareArtifactID(rawValue: UUID())
        try await shareArtifacts.create(
            Data([0x03, 0x52, 0x53]),
            artifactID: artifactID,
            filename: "synthetic",
            fileExtension: "runescribe"
        )
        return try await openTransfer(artifactID: artifactID)
    }

    func makeLinkTransfer() async throws -> OpaqueShareTransfer {
        guard let url = URL(string: "runescribe://import?v=3&p=synthetic") else {
            throw NativeShareSelfTestFailure.invalidFixture
        }
        let artifactID = ShareArtifactID(rawValue: UUID())
        try await shareArtifacts.storeLink(url, artifactID: artifactID)
        return try await openTransfer(artifactID: artifactID)
    }

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        await runtime.stop()
        try? await shareArtifacts.removeAll()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func openTransfer(
        artifactID: ShareArtifactID
    ) async throws -> OpaqueShareTransfer {
        let session = try await runtimeIO.sharePresentationSession(
            artifactID: artifactID
        )
        return try await OpaqueShareTransfer.open(
            artifactID: artifactID,
            session: session
        )
    }
}

private enum NativeShareRuntimeModule {
    static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    static let moduleID: ModuleIdentifier =
        "com.runescribe.parity.native-share-ui"
    static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: version,
        kind: .ui,
        entryPoint: "RuneScribeNativeShareRuntimeClientModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        requiredServices: [RuneScribeServiceIDs.sharePresentation]
    )
    static let manifest = ModuleManifest(
        runtimeVersion: version,
        moduleID: moduleID,
        displayName: "Rune Scribe Native Share Runtime Client",
        moduleVersion: version,
        moduleType: .ui,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: [RuneScribeServiceIDs.sharePresentation]
        ),
        defaultRole: RuneScribeRoles.primaryUI
    )
}

private actor NativeShareRuntimeClientCapture {
    private var runtimeIO: RuntimeIOClient?

    func store(_ runtimeIO: RuntimeIOClient) {
        self.runtimeIO = runtimeIO
    }

    func requireRuntimeIO() throws -> RuntimeIOClient {
        guard let runtimeIO else {
            throw NativeShareSelfTestFailure.runtimeClientUnavailable
        }
        return runtimeIO
    }
}

private struct NativeShareRuntimeClientModule: RuneScribeModule {
    let descriptor = NativeShareRuntimeModule.descriptor
    let capture: NativeShareRuntimeClientCapture

    func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        await capture.store(runtimeIO)
    }

    func stop() async {}
}

private struct NativeShareSelfTestReport: Codable {
    let version: Int
    let file: NativeShareStepReport
    let link: NativeShareStepReport
    let passed: Bool
    var failureCode: String?

    init(
        version: Int,
        file: NativeShareStepReport,
        link: NativeShareStepReport,
        passed: Bool,
        failureCode: String? = nil
    ) {
        self.version = version
        self.file = file
        self.link = link
        self.passed = passed
        self.failureCode = failureCode
    }
}

private struct NativeShareStepReport: Codable {
    let triggerCount: Int
    let nativePickerPresented: Bool
    let dismissedByHandleClose: Bool

    var passed: Bool {
        triggerCount == 1
            && nativePickerPresented
            && dismissedByHandleClose
    }

    static let notRun = NativeShareStepReport(
        triggerCount: 0,
        nativePickerPresented: false,
        dismissedByHandleClose: false
    )
}

private enum NativeShareSelfTestFailure: String, Error {
    case invalidFixture
    case runtimeClientUnavailable
    case noScreen
    case hostWindowNotVisible
    case controlNotHittable
    case eventCreationFailed
    case pickerDidNotPresent
    case triggerCountMismatch
    case presentationHandleDidNotDismiss
    case unexpected
}
