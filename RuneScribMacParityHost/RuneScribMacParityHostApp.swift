import AppKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeUIModule
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
/// files and same-process AppKit events, then exits without touching user data.
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
        let report: NativeShareSelfTestReport
        do {
            let fileResult = try runFileShare()
            let linkResult = try runCipherLinkShare()
            report = NativeShareSelfTestReport(
                version: 1,
                file: fileResult,
                link: linkResult,
                passed: fileResult.passed && linkResult.passed
            )
        } catch let failure as NativeShareSelfTestFailure {
            report = NativeShareSelfTestReport(
                version: 1,
                file: .notRun,
                link: .notRun,
                passed: false,
                failureCode: failure.rawValue
            )
        } catch {
            report = NativeShareSelfTestReport(
                version: 1,
                file: .notRun,
                link: .notRun,
                passed: false,
                failureCode: NativeShareSelfTestFailure.unexpected.rawValue
            )
        }

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

    private func runFileShare() throws -> NativeShareStepReport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuneScribeMacParityHost-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let fileURL = directory.appendingPathComponent("synthetic.runescribe")
        try Data([0x03, 0x52, 0x53]).write(to: fileURL, options: .atomic)
        var triggerCount = 0
        var finishOutcome: ShareArtifactOutcomeDTO?
        var presentation: RuneScribeSharePresentationHandle?
        let view = AnyView(
            RuneScribeFileShareLink(
                fileURL: fileURL,
                onShareTriggered: { triggerCount += 1 },
                onFinish: { finishOutcome = $0 },
                onPresentation: { presentation = $0 }
            )
            .frame(width: 260, height: 100)
        )
        return try presentAndDismiss(
            view: view,
            triggerCount: { triggerCount },
            finishOutcome: { finishOutcome },
            presentationReady: { (presentation?.proposedServiceCount ?? 0) > 0 }
        )
    }

    private func runCipherLinkShare() throws -> NativeShareStepReport {
        guard let url = URL(string: "runescribe://import?v=3&p=synthetic") else {
            throw NativeShareSelfTestFailure.invalidFixture
        }
        let transfer = OpaqueShareTransfer(
            artifactID: ShareArtifactID(rawValue: UUID()),
            url: url
        )
        var triggerCount = 0
        var finishOutcome: ShareArtifactOutcomeDTO?
        var presentation: RuneScribeSharePresentationHandle?
        let view = AnyView(
            RuneScribeCipherLinkShareLink(
                transfer: transfer,
                cipherLabel: "Synthetic Cipher",
                onShareTriggered: { triggerCount += 1 },
                onFinish: { finishOutcome = $0 },
                onPresentation: { presentation = $0 }
            ) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 260, height: 100)
        )
        return try presentAndDismiss(
            view: view,
            triggerCount: { triggerCount },
            finishOutcome: { finishOutcome },
            presentationReady: { (presentation?.proposedServiceCount ?? 0) > 0 }
        )
    }

    private func presentAndDismiss(
        view: AnyView,
        triggerCount: () -> Int,
        finishOutcome: () -> ShareArtifactOutcomeDTO?,
        presentationReady: () -> Bool
    ) throws -> NativeShareStepReport {
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
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        guard waitUntil(timeout: 2, predicate: { window.isVisible }) else {
            throw NativeShareSelfTestFailure.hostNotActive
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

        guard waitUntil(timeout: 2, predicate: { triggerCount() == 1 }) else {
            throw NativeShareSelfTestFailure.triggerCountMismatch
        }
        guard waitUntil(timeout: 5, predicate: presentationReady) else {
            throw NativeShareSelfTestFailure.pickerDidNotPresent
        }

        let escapeWindowNumber = NSApp.keyWindow?.windowNumber ?? window.windowNumber
        let escapeDown = try keyEvent(type: .keyDown, windowNumber: escapeWindowNumber)
        let escapeUp = try keyEvent(type: .keyUp, windowNumber: escapeWindowNumber)
        NSApp.sendEvent(escapeDown)
        NSApp.sendEvent(escapeUp)

        guard waitUntil(timeout: 5, predicate: {
            finishOutcome() == .cancelled
        }) else {
            throw NativeShareSelfTestFailure.pickerDidNotDismiss
        }
        return NativeShareStepReport(
            triggerCount: 1,
            nativePickerPresented: true,
            dismissedByLocalEscape: true
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

    private func keyEvent(
        type: NSEvent.EventType,
        windowNumber: Int
    ) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        ) else {
            throw NativeShareSelfTestFailure.eventCreationFailed
        }
        return event
    }

    private func waitUntil(
        timeout: TimeInterval,
        predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return true }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        } while Date() < deadline
        return predicate()
    }
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
    let dismissedByLocalEscape: Bool

    var passed: Bool {
        triggerCount == 1
            && nativePickerPresented
            && dismissedByLocalEscape
    }

    static let notRun = NativeShareStepReport(
        triggerCount: 0,
        nativePickerPresented: false,
        dismissedByLocalEscape: false
    )
}

private enum NativeShareSelfTestFailure: String, Error {
    case invalidFixture
    case noScreen
    case hostNotActive
    case controlNotHittable
    case eventCreationFailed
    case pickerDidNotPresent
    case triggerCountMismatch
    case pickerDidNotDismiss
    case unexpected
}
