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
public final class RuneScribeSharePresentationHandle {
    private let closeAction: @MainActor () -> Void
    public private(set) var proposedServiceCount = 0

    init(close: @escaping @MainActor () -> Void) {
        closeAction = close
    }

    public func close() {
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
public struct RuneScribeFileShareLink: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let onShareTriggered: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationCompletion) -> Void
    private let onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void

    public init(
        transfer: OpaqueShareTransfer,
        onShareTriggered: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void = { _ in },
        onPresentation: @escaping @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in }
    ) {
        self.transfer = transfer
        self.onShareTriggered = onShareTriggered
        self.onFinish = onFinish
        self.onPresentation = onPresentation
    }

    public var body: some View {
        Group {
            if let presentationURL = transfer.presentationURL {
        #if os(macOS)
        Button { } label: {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .overlay {
            RuneScribeMacShareControl(
                payload: .file(presentationURL),
                accessibilityLabel: "Share",
                help: "Share via Messages, Mail…",
                onShareTriggered: onShareTriggered,
                onPresented: reportPresented,
                onFinish: finish,
                onPresentation: onPresentation
            )
        }
        #else
        RuneScribeIOSActivityButton(
            payload: .file(presentationURL),
            onShareTriggered: onShareTriggered,
            onPresented: reportPresented,
            onFinish: finish
        ) {
            Label("Share", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        #endif
            } else {
                Label("Share unavailable", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .disabled(true)
            }
        }
    }

    private func reportPresented(on routeClass: ShareRouteClassDTO) {
        transfer.beginReportingPresented(on: routeClass)
    }

    private func finish(_ report: SharePresentationReportDTO) {
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

/// Launches one freshly prepared file share without requiring a second tap.
/// The caller owns the preparation button and supplies a unique token only
/// after the runtime artifact and its presentation lease are ready.
public struct RuneScribePreparedFileShareLauncher: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let launchID: UUID
    private let onPresented: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationCompletion) -> Void

    public init(
        transfer: OpaqueShareTransfer,
        launchID: UUID,
        onPresented: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void
    ) {
        self.transfer = transfer
        self.launchID = launchID
        self.onPresented = onPresented
        self.onFinish = onFinish
    }

    public var body: some View {
        Group {
            if let presentationURL = transfer.presentationURL {
                #if os(iOS)
                RuneScribeIOSAutomaticActivityLauncher(
                    launchID: launchID,
                    payload: .file(presentationURL),
                    onPresented: reportPresented,
                    onFinish: finish
                )
                #elseif os(macOS)
                RuneScribeMacAutomaticShareControl(
                    launchID: launchID,
                    payload: .file(presentationURL),
                    onPresented: reportPresented,
                    onFinish: finish
                )
                #endif
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private func reportPresented(on routeClass: ShareRouteClassDTO) {
        transfer.beginReportingPresented(on: routeClass)
        onPresented()
    }

    private func finish(_ report: SharePresentationReportDTO) {
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

/// Launches one freshly prepared text share without requiring a second tap.
/// This remains a compatibility rail; canonical themed message operations use
/// the file launcher whenever Core supplies the typed package.
public struct RuneScribePreparedTextShareLauncher: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let launchID: UUID
    private let onPresented: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationCompletion) -> Void

    public init(
        transfer: OpaqueShareTransfer,
        launchID: UUID,
        onPresented: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void
    ) {
        self.transfer = transfer
        self.launchID = launchID
        self.onPresented = onPresented
        self.onFinish = onFinish
    }

    public var body: some View {
        Group {
            if let text = transfer.presentationText {
                #if os(iOS)
                RuneScribeIOSAutomaticActivityLauncher(
                    launchID: launchID,
                    payload: .text(text),
                    onPresented: reportPresented,
                    onFinish: finish
                )
                #elseif os(macOS)
                RuneScribeMacAutomaticShareControl(
                    launchID: launchID,
                    payload: .text(text),
                    onPresented: reportPresented,
                    onFinish: finish
                )
                #endif
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private func reportPresented(on routeClass: ShareRouteClassDTO) {
        transfer.beginReportingPresented(on: routeClass)
        onPresented()
    }

    private func finish(_ report: SharePresentationReportDTO) {
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

/// Launches a cipher invitation as a rendered image plus its HTTPS import link.
/// The Cipher Library primary action and its customized variant both use this
/// presentation; explicit file export remains available separately.
public struct RuneScribePreparedCipherLinkLauncher: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let cipherLabel: String
    private let previewImageData: Data?
    private let launchID: UUID
    private let onPresented: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationCompletion) -> Void

    public init(
        transfer: OpaqueShareTransfer,
        cipherLabel: String,
        previewImageData: Data? = nil,
        launchID: UUID,
        onPresented: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void
    ) {
        self.transfer = transfer
        self.cipherLabel = cipherLabel
        self.previewImageData = previewImageData
        self.launchID = launchID
        self.onPresented = onPresented
        self.onFinish = onFinish
    }

    public var body: some View {
        Group {
            if let presentationURL = transfer.presentationURL {
                #if os(iOS)
                RuneScribePreparedInteractiveMessageLauncher(
                    transfer: transfer,
                    cipherLabel: cipherLabel,
                    previewImageData: previewImageData,
                    launchID: launchID,
                    onPresented: {
                        reportPresented(on: .messages)
                    },
                    onFinish: finish
                )
                #elseif os(macOS)
                RuneScribeMacAutomaticShareControl(
                    launchID: launchID,
                    payload: .link(
                        presentationURL,
                        subject: "Rune Scribe cipher: \(cipherLabel)",
                        message: "Tap to open in Rune Scribe and import this cipher so you can decode my messages."
                    ),
                    onPresented: reportPresented,
                    onFinish: finish
                )
                #endif
            }
        }
        .frame(width: 1, height: 1)
        .opacity(0.001)
        .accessibilityHidden(true)
    }

    private func reportPresented(on routeClass: ShareRouteClassDTO) {
        transfer.beginReportingPresented(on: routeClass)
        onPresented()
    }

    private func finish(_ report: SharePresentationReportDTO) {
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

public struct RuneScribeTextShareLink: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let onShareTriggered: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationCompletion) -> Void
    private let onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void

    public init(
        transfer: OpaqueShareTransfer,
        onShareTriggered: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void = { _ in },
        onPresentation: @escaping @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in }
    ) {
        self.transfer = transfer
        self.onShareTriggered = onShareTriggered
        self.onFinish = onFinish
        self.onPresentation = onPresentation
    }

    public var body: some View {
        Group {
            if let text = transfer.presentationText {
                #if os(macOS)
                Button { } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .overlay {
                    RuneScribeMacShareControl(
                        payload: .text(text),
                        accessibilityLabel: "Share",
                        help: "Share via Messages, Mail…",
                        onShareTriggered: onShareTriggered,
                        onPresented: reportPresented,
                        onFinish: finish,
                        onPresentation: onPresentation
                    )
                }
                #else
                RuneScribeIOSActivityButton(
                    payload: .text(text),
                    onShareTriggered: onShareTriggered,
                    onPresented: reportPresented,
                    onFinish: finish
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                #endif
            } else {
                Label("Share unavailable", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .disabled(true)
            }
        }
    }

    private func reportPresented(on routeClass: ShareRouteClassDTO) {
        transfer.beginReportingPresented(on: routeClass)
    }

    private func finish(_ report: SharePresentationReportDTO) {
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

/// The production Cipher Library control for sharing an opaque, key-bearing
/// import link through the native system share surface.
public struct RuneScribeCipherLinkShareLink<Label: View>: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let cipherLabel: String
    private let previewImageData: Data
    private let onShareTriggered: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationCompletion) -> Void
    private let onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void
    private let label: () -> Label

    public init(
        transfer: OpaqueShareTransfer,
        cipherLabel: String,
        previewImageData: Data,
        onShareTriggered: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void = { _ in },
        onPresentation: @escaping @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in },
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.transfer = transfer
        self.cipherLabel = cipherLabel
        self.previewImageData = previewImageData
        self.onShareTriggered = onShareTriggered
        self.onFinish = onFinish
        self.onPresentation = onPresentation
        self.label = label
    }

    public var body: some View {
        Group {
            if let presentationURL = transfer.presentationURL {
        #if os(macOS)
        label()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                RuneScribeMacShareControl(
                    payload: .link(
                        presentationURL,
                        subject: "Rune Scribe cipher: \(cipherLabel)",
                        message: "Tap to open in Rune Scribe and import this cipher so you can decode my messages."
                    ),
                    accessibilityLabel: "Share \(cipherLabel)",
                    help: "Share via Messages, Mail…",
                    onShareTriggered: onShareTriggered,
                    onPresented: reportPresented,
                    onFinish: finish,
                    onPresentation: onPresentation
                )
            }
        #else
        RuneScribeInteractiveMessageButton(
            transfer: transfer,
            cipherLabel: cipherLabel,
            previewImageData: previewImageData,
            onShareTriggered: onShareTriggered,
            onPresented: {
                reportPresented(on: .messages)
            },
            onFinish: finish,
            label: label
        )
        .accessibilityLabel("Share \(cipherLabel)")
        .buttonStyle(.plain)
        .help("Share via Messages, Mail…")
        #endif
            } else {
                label().disabled(true)
            }
        }
    }

    private func reportPresented(on routeClass: ShareRouteClassDTO) {
        transfer.beginReportingPresented(on: routeClass)
    }

    private func finish(_ report: SharePresentationReportDTO) {
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

#if os(iOS)
public enum RuneScribeActivityReportMapper {
    public static func report(
        activityType: UIActivity.ActivityType?,
        completed: Bool,
        error: (any Error)?
    ) -> SharePresentationReportDTO {
        let routeClass: ShareRouteClassDTO = activityType == .airDrop
            ? .airDrop
            : .shareSheet
        let result: ShareRouteResultDTO
        if error != nil {
            result = .failed
        } else {
            result = completed ? .completedBySystem : .cancelled
        }
        return try! SharePresentationReportDTO(
            routeClass: routeClass,
            result: result
        )
    }
}

public struct RuneScribeActivityCompletionGate {
    public private(set) var hasCompleted = false

    public init() {}

    public mutating func accept(
        activityType: UIActivity.ActivityType?,
        completed: Bool,
        error: (any Error)?
    ) -> SharePresentationReportDTO? {
        guard !hasCompleted else { return nil }
        hasCompleted = true
        return RuneScribeActivityReportMapper.report(
            activityType: activityType,
            completed: completed,
            error: error
        )
    }
}

@MainActor
private struct RuneScribeIOSActivityButton<Label: View>: View {
    let payload: RuneScribeIOSActivityPayload
    let onShareTriggered: @MainActor () -> Void
    let onPresented: @MainActor (ShareRouteClassDTO) -> Void
    let onFinish: @MainActor (SharePresentationReportDTO) -> Void
    @ViewBuilder let label: () -> Label

    @State private var presentation: RuneScribeIOSActivityPresentation?

    var body: some View {
        Button {
            guard presentation == nil else { return }
            onShareTriggered()
            presentation = RuneScribeIOSActivityPresentation(
                payload: payload,
                onPresented: onPresented,
                onFinish: { report in
                    onFinish(report)
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

@MainActor
private struct RuneScribeIOSAutomaticActivityLauncher: View {
    let launchID: UUID
    let payload: RuneScribeIOSActivityPayload
    let onPresented: @MainActor (ShareRouteClassDTO) -> Void
    let onFinish: @MainActor (SharePresentationReportDTO) -> Void

    @State private var presentation: RuneScribeIOSActivityPresentation?

    var body: some View {
        RuneScribeIOSActivityPresenter(presentation: presentation)
            .task(id: launchID) {
                guard presentation == nil else { return }
                presentation = RuneScribeIOSActivityPresentation(
                    payload: payload,
                    onPresented: onPresented,
                    onFinish: { report in
                        onFinish(report)
                        presentation = nil
                    }
                )
            }
    }
}

private enum RuneScribeIOSActivityPayload {
    case file(URL)
    case text(String)
    case link(
        URL,
        previewTitle: String,
        previewSystemImage: String,
        previewImageData: Data?,
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
        case .text(let text):
            return [text as NSString]
        case let .link(
            url,
            previewTitle,
            previewSystemImage,
            previewImageData,
            subject,
            message
        ):
            return RuneScribeIOSLinkActivityItemFactory.makeItems(
                url: url,
                previewTitle: previewTitle,
                previewSystemImage: previewSystemImage,
                previewImageData: previewImageData,
                subject: subject,
                message: message
            )
        }
    }
}

/// Builds the concrete items handed to iOS share services for a cipher invitation.
/// The PNG is deliberately a first-class activity item instead of only link-preview
/// metadata, so the destination receives the rendered cipher, seal, and frame as a
/// proposed image attachment. The separate HTTPS item carries the opaque import payload.
/// Actual Messages transcript behavior remains a physical-device qualification boundary.
@_spi(RuntimeTesting)
@MainActor
public enum RuneScribeIOSLinkActivityItemFactory {
    public static func makeItems(
        url: URL,
        previewTitle: String,
        previewSystemImage: String,
        previewImageData: Data?,
        subject: String,
        message: String
    ) -> [Any] {
        var items: [Any] = []
        if let previewImageData,
           let previewImage = UIImage(data: previewImageData) {
            items.append(previewImage)
        }
        items.append(message as NSString)
        items.append(
            RuneScribeIOSActivityItemSource(
                url: url,
                previewTitle: previewTitle,
                previewSystemImage: previewSystemImage,
                previewImageData: previewImageData,
                subject: subject
            )
        )
        return items
    }
}

@MainActor
private final class RuneScribeIOSActivityPresentation: Identifiable {
    let id = UUID()
    let payload: RuneScribeIOSActivityPayload
    let activityItems: [Any]

    private var completionGate = RuneScribeActivityCompletionGate()
    private var hasReportedPresentation = false
    private let onPresented: @MainActor (ShareRouteClassDTO) -> Void
    private let onFinish: @MainActor (SharePresentationReportDTO) -> Void

    init(
        payload: RuneScribeIOSActivityPayload,
        onPresented: @escaping @MainActor (ShareRouteClassDTO) -> Void,
        onFinish: @escaping @MainActor (SharePresentationReportDTO) -> Void
    ) {
        self.payload = payload
        activityItems = payload.activityItems
        self.onPresented = onPresented
        self.onFinish = onFinish
    }

    func reportPresentedIfNeeded() {
        guard !hasReportedPresentation else { return }
        hasReportedPresentation = true
        onPresented(.shareSheet)
    }

    func complete(
        activityType: UIActivity.ActivityType? = nil,
        completed: Bool,
        error: (any Error)?
    ) {
        guard let report = completionGate.accept(
            activityType: activityType,
            completed: completed,
            error: error
        ) else { return }
        onFinish(report)
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
            [weak self, weak controller, presentation] activityType, completed, _, error in
            guard let controller else {
                presentation.complete(
                    activityType: activityType,
                    completed: completed,
                    error: error
                )
                return
            }
            self?.finishActivePresentation(
                presentation,
                controller: controller,
                activityType: activityType,
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
        presentation.reportPresentedIfNeeded()
        present(controller, animated: true)
        controller.presentationController?.delegate = self
    }

    private func finishActivePresentation(
        _ presentation: RuneScribeIOSActivityPresentation,
        controller: UIActivityViewController,
        activityType: UIActivity.ActivityType?,
        completed: Bool,
        error: (any Error)?
    ) {
        presentation.complete(
            activityType: activityType,
            completed: completed,
            error: error
        )
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

private final class RuneScribeIOSActivityItemSource: NSObject,
    UIActivityItemSource
{
    private let url: URL
    private let previewTitle: String
    private let previewSystemImage: String
    private let previewImageData: Data?
    private let subject: String?

    init(
        url: URL,
        previewTitle: String,
        previewSystemImage: String,
        previewImageData: Data? = nil,
        subject: String?
    ) {
        self.url = url
        self.previewTitle = previewTitle
        self.previewSystemImage = previewSystemImage
        self.previewImageData = previewImageData
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
        metadata.originalURL = url
        metadata.url = url
        if let previewImageData,
           let image = UIImage(data: previewImageData) {
            metadata.imageProvider = NSItemProvider(object: image)
        } else if let image = UIImage(systemName: previewSystemImage) {
            metadata.iconProvider = NSItemProvider(object: image)
        }
        return metadata
    }
}
#endif

#if os(macOS)
public enum RuneScribeMacSharingServiceReportMapper {
    public static func routeClass(
        for sharingService: NSSharingService?
    ) -> ShareRouteClassDTO {
        guard let sharingService,
              let airDrop = NSSharingService(named: .sendViaAirDrop),
              sharingService == airDrop
        else {
            return .shareSheet
        }
        return .airDrop
    }

    public static func report(
        for sharingService: NSSharingService?,
        result: ShareRouteResultDTO
    ) -> SharePresentationReportDTO {
        try! SharePresentationReportDTO(
            routeClass: routeClass(for: sharingService),
            result: result
        )
    }
}

private enum RuneScribeMacSharePayload {
    case file(URL)
    case text(String)
    case link(URL, subject: String, message: String)

    var items: [Any] {
        switch self {
        case .file(let url):
            [url as NSURL]
        case .text(let text):
            [text as NSString]
        case .link(let url, _, let message):
            [message as NSString, url as NSURL]
        }
    }

    var subject: String? {
        if case .link(_, let subject, _) = self { return subject }
        return nil
    }
}

private struct RuneScribeMacShareControl: NSViewRepresentable {
    let payload: RuneScribeMacSharePayload
    let accessibilityLabel: String
    let help: String
    let onShareTriggered: @MainActor () -> Void
    let onPresented: @MainActor (ShareRouteClassDTO) -> Void
    let onFinish: @MainActor (SharePresentationReportDTO) -> Void
    let onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void

    func makeNSView(context: Context) -> RuneScribeMacShareView {
        let view = RuneScribeMacShareView()
        view.configure(
            payload: payload,
            accessibilityLabel: accessibilityLabel,
            help: help,
            onShareTriggered: onShareTriggered,
            onPresented: onPresented,
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
            onPresented: onPresented,
            onFinish: onFinish,
            onPresentation: onPresentation
        )
    }

    static func dismantleNSView(_ view: RuneScribeMacShareView, coordinator: ()) {
        view.cancelPresentation()
    }
}

private struct RuneScribeMacAutomaticShareControl: NSViewRepresentable {
    let launchID: UUID
    let payload: RuneScribeMacSharePayload
    let onPresented: @MainActor (ShareRouteClassDTO) -> Void
    let onFinish: @MainActor (SharePresentationReportDTO) -> Void

    func makeNSView(context: Context) -> RuneScribeMacShareView {
        let view = RuneScribeMacShareView()
        configure(view)
        return view
    }

    func updateNSView(_ view: RuneScribeMacShareView, context: Context) {
        configure(view)
    }

    static func dismantleNSView(_ view: RuneScribeMacShareView, coordinator: ()) {
        view.cancelPresentation()
    }

    private func configure(_ view: RuneScribeMacShareView) {
        view.configure(
            payload: payload,
            accessibilityLabel: "Share",
            help: "Share via Messages, Mail…",
            onShareTriggered: {},
            onPresented: onPresented,
            onFinish: onFinish,
            onPresentation: { _ in }
        )
        view.presentAutomatically(launchID: launchID)
    }
}

@MainActor
private final class RuneScribeMacShareView: NSView,
    @preconcurrency NSSharingServicePickerDelegate,
    NSSharingServiceDelegate
{
    private var payload: RuneScribeMacSharePayload = .file(URL(fileURLWithPath: "/dev/null"))
    private var onShareTriggered: @MainActor () -> Void = {}
    private var onPresented: @MainActor (ShareRouteClassDTO) -> Void = { _ in }
    private var onFinish: @MainActor (SharePresentationReportDTO) -> Void = { _ in }
    private var onPresentation: @MainActor (RuneScribeSharePresentationHandle) -> Void = { _ in }
    private var picker: NSSharingServicePicker?
    private var chosenService: NSSharingService?
    private var presentationHandle: RuneScribeSharePresentationHandle?
    private var didFinish = false
    private var pendingAutomaticLaunchID: UUID?
    private var lastAutomaticLaunchID: UUID?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presentPendingAutomaticLaunchIfPossible()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(
            roundedRect: bounds,
            xRadius: 12,
            yRadius: 12
        ).fill()
    }

    func configure(
        payload: RuneScribeMacSharePayload,
        accessibilityLabel: String,
        help: String,
        onShareTriggered: @escaping @MainActor () -> Void,
        onPresented: @escaping @MainActor (ShareRouteClassDTO) -> Void,
        onFinish: @escaping @MainActor (SharePresentationReportDTO) -> Void,
        onPresentation: @escaping @MainActor (RuneScribeSharePresentationHandle) -> Void
    ) {
        self.payload = payload
        self.onShareTriggered = onShareTriggered
        self.onPresented = onPresented
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
        finish(result: .cancelled)
    }

    func presentAutomatically(launchID: UUID) {
        guard launchID != lastAutomaticLaunchID,
              launchID != pendingAutomaticLaunchID
        else { return }
        pendingAutomaticLaunchID = launchID
        presentPendingAutomaticLaunchIfPossible()
    }

    private func presentPendingAutomaticLaunchIfPossible() {
        guard window != nil,
              let launchID = pendingAutomaticLaunchID,
              picker == nil
        else { return }
        pendingAutomaticLaunchID = nil
        lastAutomaticLaunchID = launchID
        DispatchQueue.main.async { [weak self] in
            self?.presentPicker()
        }
    }

    fileprivate func presentPicker() {
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
        onPresented(.shareSheet)
        picker.show(relativeTo: bounds, of: self, preferredEdge: .minY)
    }

    private func finish(result: ShareRouteResultDTO) {
        guard !didFinish else { return }
        didFinish = true
        let report = RuneScribeMacSharingServiceReportMapper.report(
            for: chosenService,
            result: result
        )
        picker = nil
        chosenService = nil
        presentationHandle = nil
        onFinish(report)
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
            finish(result: .cancelled)
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
        chosenService = sharingService
        finish(result: .completedBySystem)
    }

    func sharingService(
        _ sharingService: NSSharingService,
        didFailToShareItems items: [Any],
        error: any Error
    ) {
        chosenService = sharingService
        finish(result: .failed)
    }
}
#endif
