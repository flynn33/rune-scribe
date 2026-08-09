import Foundation
import RuneScribeContracts
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import LinkPresentation
import UIKit
#endif

@MainActor
final class RuneScribeSharePresentationHandle {
    private let closeAction: @MainActor () -> Void
    private(set) var proposedServiceCount = 0

    init(close: @escaping @MainActor () -> Void) {
        closeAction = close
    }

    func close() {
        closeAction()
    }

    fileprivate func recordProposedServices(_ count: Int) {
        proposedServiceCount = count
    }
}

/// The production file-sharing control used for first-delivery Rune Scribe
/// messages. macOS owns its native picker so presentation and completion have
/// a public lifecycle; iOS uses the system activity controller's public
/// completion callback.
struct RuneScribeFileShareLink: View {
    let fileURL: URL
    var onShareTriggered: @MainActor () -> Void = {}
    var onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void = { _ in }
    var onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in }

    var body: some View {
        #if os(macOS)
        Button { } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .overlay {
            RuneScribeMacShareControl(
                payload: .file(fileURL),
                accessibilityLabel: "Share",
                help: "Share via Messages, Mail…",
                onShareTriggered: onShareTriggered,
                onFinish: onFinish,
                onPresentation: onPresentation
            )
        }
        #else
        RuneScribeIOSActivityButton(
            payload: .file(fileURL),
            onShareTriggered: onShareTriggered,
            onFinish: onFinish
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
        #endif
    }
}

/// The production Cipher Library control for sharing an opaque, key-bearing
/// import link through the native system share surface.
struct RuneScribeCipherLinkShareLink<Label: View>: View {
    let transfer: OpaqueShareTransfer
    let cipherLabel: String
    var onShareTriggered: @MainActor () -> Void = {}
    var onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void = { _ in }
    var onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in }
    @ViewBuilder let label: () -> Label

    var body: some View {
        #if os(macOS)
        label()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                RuneScribeMacShareControl(
                    payload: .link(
                        transfer.macOSSharingURL,
                        subject: "Rune Scribe cipher: \(cipherLabel)",
                        message: "Tap to open in Rune Scribe and import this cipher so you can decode my messages."
                    ),
                    accessibilityLabel: "Share \(cipherLabel)",
                    help: "Share via Messages, Mail…",
                    onShareTriggered: onShareTriggered,
                    onFinish: onFinish,
                    onPresentation: onPresentation
                )
            }
        #else
        RuneScribeIOSActivityButton(
            payload: .link(
                transfer,
                previewTitle: "Rune Scribe cipher: \(cipherLabel)",
                previewSystemImage: "link",
                subject: "Rune Scribe cipher: \(cipherLabel)",
                message: "Tap to open in Rune Scribe and import this cipher so you "
                    + "can decode my messages."
            ),
            onShareTriggered: onShareTriggered,
            onFinish: onFinish,
            label: label
        )
        .accessibilityLabel("Share \(cipherLabel)")
        .buttonStyle(.plain)
        .help("Share via Messages, Mail…")
        #endif
    }
}

#if os(iOS)
enum RuneScribeActivityOutcomeMapper {
    static func outcome(
        completed: Bool,
        error: (any Error)?
    ) -> ShareArtifactOutcomeDTO {
        if error != nil { return .failed }
        return completed ? .handedOff : .cancelled
    }
}

struct RuneScribeActivityCompletionGate {
    private(set) var hasCompleted = false

    mutating func accept(
        completed: Bool,
        error: (any Error)?
    ) -> ShareArtifactOutcomeDTO? {
        guard !hasCompleted else { return nil }
        hasCompleted = true
        return RuneScribeActivityOutcomeMapper.outcome(
            completed: completed,
            error: error
        )
    }
}

@MainActor
private struct RuneScribeIOSActivityButton<Label: View>: View {
    let payload: RuneScribeIOSActivityPayload
    let onShareTriggered: @MainActor () -> Void
    let onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void
    @ViewBuilder let label: () -> Label

    @State private var presentation: RuneScribeIOSActivityPresentation?

    var body: some View {
        Button {
            guard presentation == nil else { return }
            onShareTriggered()
            presentation = RuneScribeIOSActivityPresentation(
                payload: payload,
                onFinish: { outcome in
                    onFinish(outcome)
                    presentation = nil
                }
            )
        } label: {
            label()
        }
        .background {
            RuneScribeIOSActivityPresenter(presentation: presentation)
                .allowsHitTesting(false)
        }
    }
}

private enum RuneScribeIOSActivityPayload {
    case file(URL)
    case link(
        OpaqueShareTransfer,
        previewTitle: String,
        previewSystemImage: String,
        subject: String,
        message: String
    )

    @MainActor
    var activityItems: [Any] {
        switch self {
        case .file(let url):
            return [
                RuneScribeIOSActivityItemSource(
                    url: url,
                    previewTitle: "Rune Scribe message",
                    previewSystemImage: "doc.fill",
                    subject: nil
                ),
            ]
        case let .link(
            transfer,
            previewTitle,
            previewSystemImage,
            subject,
            message
        ):
            return [
                message as NSString,
                RuneScribeIOSActivityItemSource(
                    url: transfer.iOSSharingURL,
                    previewTitle: previewTitle,
                    previewSystemImage: previewSystemImage,
                    subject: subject
                ),
            ]
        }
    }
}

@MainActor
private final class RuneScribeIOSActivityPresentation: Identifiable {
    let id = UUID()
    let payload: RuneScribeIOSActivityPayload
    let activityItems: [Any]

    private var completionGate = RuneScribeActivityCompletionGate()
    private let onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void

    init(
        payload: RuneScribeIOSActivityPayload,
        onFinish: @escaping @MainActor (ShareArtifactOutcomeDTO) -> Void
    ) {
        self.payload = payload
        activityItems = payload.activityItems
        self.onFinish = onFinish
    }

    func complete(completed: Bool, error: (any Error)?) {
        guard let outcome = completionGate.accept(
            completed: completed,
            error: error
        ) else { return }
        onFinish(outcome)
    }

    func cancelIfNeeded() {
        complete(completed: false, error: nil)
    }
}

@MainActor
private struct RuneScribeIOSActivityPresenter: UIViewControllerRepresentable {
    let presentation: RuneScribeIOSActivityPresentation?

    func makeUIViewController(context: Context) -> RuneScribeIOSActivityPresenterController {
        RuneScribeIOSActivityPresenterController()
    }

    func updateUIViewController(
        _ controller: RuneScribeIOSActivityPresenterController,
        context: Context
    ) {
        controller.update(presentation: presentation)
    }

    static func dismantleUIViewController(
        _ controller: RuneScribeIOSActivityPresenterController,
        coordinator: ()
    ) {
        controller.cancelActivePresentation(animated: false)
    }
}

@MainActor
private final class RuneScribeIOSActivityPresenterController: UIViewController,
    UIAdaptivePresentationControllerDelegate
{
    private var pendingPresentation: RuneScribeIOSActivityPresentation?
    private var activePresentation: RuneScribeIOSActivityPresentation?
    private var activityController: UIActivityViewController?
    private var hasAppeared = false
    private var isDismissing = false

    override func loadView() {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
        presentIfPossible()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        hasAppeared = false
    }

    func update(presentation: RuneScribeIOSActivityPresentation?) {
        guard let presentation else {
            pendingPresentation = nil
            cancelActivePresentation(animated: true)
            return
        }

        guard activePresentation?.id != presentation.id,
              pendingPresentation?.id != presentation.id else { return }
        pendingPresentation = presentation
        presentIfPossible()
    }

    func cancelActivePresentation(animated: Bool) {
        pendingPresentation?.cancelIfNeeded()
        pendingPresentation = nil

        guard let controller = activityController,
              let presentation = activePresentation else {
            activityController = nil
            activePresentation = nil
            isDismissing = false
            return
        }

        presentation.cancelIfNeeded()
        dismissTrackedController(
            controller,
            presentation: presentation,
            animated: animated
        )
    }

    private func presentIfPossible() {
        guard hasAppeared,
              viewIfLoaded?.window != nil,
              presentedViewController == nil,
              !isDismissing,
              activityController == nil,
              activePresentation == nil,
              let presentation = pendingPresentation else { return }

        pendingPresentation = nil

        let controller = UIActivityViewController(
            activityItems: presentation.activityItems,
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = {
            [weak self, weak controller, presentation] _, completed, _, error in
            guard let controller else {
                presentation.complete(completed: completed, error: error)
                return
            }
            self?.finishActivePresentation(
                presentation,
                controller: controller,
                completed: completed,
                error: error
            )
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = view.bounds.isEmpty
                ? CGRect(x: 0, y: 0, width: 1, height: 1)
                : view.bounds
        }
        activityController = controller
        activePresentation = presentation
        present(controller, animated: true)
        controller.presentationController?.delegate = self
    }

    private func finishActivePresentation(
        _ presentation: RuneScribeIOSActivityPresentation,
        controller: UIActivityViewController,
        completed: Bool,
        error: (any Error)?
    ) {
        presentation.complete(completed: completed, error: error)
        guard activityController === controller,
              activePresentation?.id == presentation.id else { return }
        dismissTrackedController(
            controller,
            presentation: presentation,
            animated: true
        )
    }

    private func dismissTrackedController(
        _ controller: UIActivityViewController,
        presentation: RuneScribeIOSActivityPresentation,
        animated: Bool
    ) {
        guard activityController === controller,
              activePresentation?.id == presentation.id,
              !isDismissing else { return }
        isDismissing = true

        let cleanup = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.completeDismissal(
                controller,
                presentation: presentation
            )
        }
        if controller.presentingViewController != nil
            || presentedViewController === controller
        {
            controller.dismiss(animated: animated, completion: cleanup)
        } else {
            cleanup()
        }
    }

    private func completeDismissal(
        _ controller: UIActivityViewController,
        presentation: RuneScribeIOSActivityPresentation
    ) {
        guard activityController === controller,
              activePresentation?.id == presentation.id else { return }
        activityController = nil
        activePresentation = nil
        isDismissing = false
        presentIfPossible()
    }

    func presentationControllerDidDismiss(
        _ presentationController: UIPresentationController
    ) {
        guard let controller = activityController,
              presentationController.presentedViewController === controller,
              let presentation = activePresentation else { return }
        presentation.cancelIfNeeded()
        completeDismissal(controller, presentation: presentation)
    }
}

@MainActor
private final class RuneScribeIOSActivityItemSource: NSObject,
    @preconcurrency UIActivityItemSource
{
    private let url: URL
    private let previewTitle: String
    private let previewSystemImage: String
    private let subject: String?

    init(
        url: URL,
        previewTitle: String,
        previewSystemImage: String,
        subject: String?
    ) {
        self.url = url
        self.previewTitle = previewTitle
        self.previewSystemImage = previewSystemImage
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        subject ?? previewTitle
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = previewTitle
        if let image = UIImage(systemName: previewSystemImage) {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}
#endif

#if os(macOS)
private enum RuneScribeMacSharePayload {
    case file(URL)
    case link(URL, subject: String, message: String)

    var items: [Any] {
        switch self {
        case .file(let url):
            [url as NSURL]
        case .link(let url, _, let message):
            [message as NSString, url as NSURL]
        }
    }

    var subject: String? {
        guard case .link(_, let subject, _) = self else { return nil }
        return subject
    }
}

private struct RuneScribeMacShareControl: NSViewRepresentable {
    let payload: RuneScribeMacSharePayload
    let accessibilityLabel: String
    let help: String
    let onShareTriggered: @MainActor () -> Void
    let onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void
    let onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void

    func makeNSView(context: Context) -> RuneScribeMacShareView {
        let view = RuneScribeMacShareView()
        view.configure(
            payload: payload,
            accessibilityLabel: accessibilityLabel,
            help: help,
            onShareTriggered: onShareTriggered,
            onFinish: onFinish,
            onPresentation: onPresentation
        )
        return view
    }

    func updateNSView(_ view: RuneScribeMacShareView, context: Context) {
        view.configure(
            payload: payload,
            accessibilityLabel: accessibilityLabel,
            help: help,
            onShareTriggered: onShareTriggered,
            onFinish: onFinish,
            onPresentation: onPresentation
        )
    }

    static func dismantleNSView(_ view: RuneScribeMacShareView, coordinator: ()) {
        view.cancelPresentation()
    }
}

@MainActor
private final class RuneScribeMacShareView: NSView,
    @preconcurrency NSSharingServicePickerDelegate,
    NSSharingServiceDelegate
{
    private var payload: RuneScribeMacSharePayload = .file(URL(fileURLWithPath: "/dev/null"))
    private var onShareTriggered: @MainActor () -> Void = {}
    private var onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void = { _ in }
    private var onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in }
    private var picker: NSSharingServicePicker?
    private var chosenService: NSSharingService?
    private var presentationHandle: RuneScribeSharePresentationHandle?
    private var didFinish = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: RuneMetrics.corner,
            yRadius: RuneMetrics.corner
        ).fill()
    }

    func configure(
        payload: RuneScribeMacSharePayload,
        accessibilityLabel: String,
        help: String,
        onShareTriggered: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor (ShareArtifactOutcomeDTO) -> Void,
        onPresentation: @escaping @MainActor (RuneScribeSharePresentationHandle) -> Void
    ) {
        self.payload = payload
        self.onShareTriggered = onShareTriggered
        self.onFinish = onFinish
        self.onPresentation = onPresentation
        toolTip = help
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityHelp(help)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        presentPicker()
    }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 36 || event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        presentPicker()
    }

    override func accessibilityPerformPress() -> Bool {
        presentPicker()
        return true
    }

    override func cancelOperation(_ sender: Any?) {
        cancelPresentation()
    }

    func cancelPresentation() {
        guard let picker else { return }
        picker.close()
        finish(.cancelled)
    }

    private func presentPicker() {
        guard picker == nil else { return }
        didFinish = false
        onShareTriggered()
        let picker = NSSharingServicePicker(items: payload.items)
        picker.delegate = self
        self.picker = picker
        let handle = RuneScribeSharePresentationHandle { [weak self] in
            self?.cancelPresentation()
        }
        presentationHandle = handle
        onPresentation(handle)
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    private func finish(_ outcome: ShareArtifactOutcomeDTO) {
        guard !didFinish else { return }
        didFinish = true
        picker = nil
        chosenService = nil
        presentationHandle = nil
        onFinish(outcome)
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices: [NSSharingService]
    ) -> [NSSharingService] {
        presentationHandle?.recordProposedServices(proposedSharingServices.count)
        return proposedSharingServices
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        guard let service else {
            finish(.cancelled)
            return
        }
        chosenService = service
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        chosenService = sharingService
        return self
    }

    func sharingService(
        _ sharingService: NSSharingService,
        subjectForItems items: [Any]
    ) -> String? {
        payload.subject
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finish(.handedOff)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        finish(.failed)
    }
}
#endif
