#if os(iOS)
import Foundation
import MessageUI
import RuneScribeContracts
import SwiftUI
import UIKit

public enum MessageComposeTerminalResult: Equatable, Sendable {
    case sent
    case cancelled
    case failed
}

public enum MessageComposeReportMapper {
    public static func report(
        for result: MessageComposeTerminalResult,
        requiredAttachmentWasPresent: Bool,
        requiredAttachmentAccepted: Bool
    ) -> SharePresentationReportDTO {
        let routeResult: ShareRouteResultDTO
        let accepted: Bool?
        switch result {
        case .sent:
            routeResult = .sentConfirmed
            accepted = requiredAttachmentWasPresent && requiredAttachmentAccepted
        case .cancelled:
            routeResult = .cancelled
            accepted = nil
        case .failed:
            routeResult = .failed
            accepted = nil
        }
        return try! SharePresentationReportDTO(
            routeClass: .messages,
            result: routeResult,
            requiredAttachmentAccepted: accepted
        )
    }
}

public enum MessageComposeAttachmentSetupDecision: Equatable, Sendable {
    case presentComposer(requiredAttachmentAccepted: Bool)
    case fail
}

public enum MessageComposeAttachmentSetupPolicy {
    public static func decide(
        requiredAttachmentWasPresent: Bool,
        requiredAttachmentAccepted: Bool
    ) -> MessageComposeAttachmentSetupDecision {
        guard requiredAttachmentWasPresent, requiredAttachmentAccepted else { return .fail }
        return .presentComposer(requiredAttachmentAccepted: true)
    }
}

public struct MessageComposeCompletionGate: Equatable, Sendable {
    public private(set) var hasCompleted = false

    public init() {}

    public mutating func accept(
        _ report: SharePresentationReportDTO
    ) -> SharePresentationReportDTO? {
        guard !hasCompleted else { return nil }
        hasCompleted = true
        return report
    }
}

/// Sends the rendered artwork and rune text through Apple's compose sheet.
/// The scoped Core transfer tracks completion; its package is not attached.
public struct MessageComposeView: UIViewControllerRepresentable {
    private let messageText: String
    private let recipients: [String]?
    private let attachment: OpaqueShareTransfer?
    private let previewImageData: Data?
    private let onFinish: ((SharePresentationCompletion) -> Void)?

    public init(
        messageText: String,
        recipients: [String]? = nil,
        attachment: OpaqueShareTransfer? = nil,
        previewImageData: Data? = nil,
        onFinish: ((SharePresentationCompletion) -> Void)? = nil
    ) {
        self.messageText = messageText
        self.recipients = recipients
        self.attachment = attachment
        self.previewImageData = previewImageData
        self.onFinish = onFinish
    }

    private var attachmentURL: URL? {
        attachment?.presentationURL
    }

    /// Whether this device can send text and the required PNG artwork.
    ///
    /// The `MFMessageComposeViewController` capability probes are main-actor-isolated, so
    /// this accessor is too; it is only read from the view body / a button action.
    @MainActor
    public static func canSend(requiredAttachment: Bool) -> Bool {
        guard MFMessageComposeViewController.canSendText() else { return false }
        guard requiredAttachment else { return true }
        return MFMessageComposeViewController.canSendAttachments()
            && MFMessageComposeViewController.isSupportedAttachmentUTI(
                "public.png"
            )
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onFinish: finish,
            requiredAttachmentWasPresent: previewImageData.flatMap {
                RuneScribeMessagePreviewAttachment.validatedPNG($0)
            } != nil
        )
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        composer.body = messageText
        if let recipients { composer.recipients = recipients }

        let validatedPreview = previewImageData.flatMap {
            RuneScribeMessagePreviewAttachment.validatedPNG($0)
        }
        let requiredAttachmentAccepted = validatedPreview.map {
            composer.addAttachmentData(
                $0,
                typeIdentifier: "public.png",
                filename: "Rune-Scribe.png"
            )
        } == true

        switch MessageComposeAttachmentSetupPolicy.decide(
            requiredAttachmentWasPresent: attachmentURL != nil && validatedPreview != nil,
            requiredAttachmentAccepted: requiredAttachmentAccepted
        ) {
        case .presentComposer(let accepted):
            context.coordinator.requiredAttachmentAccepted = accepted
            if let attachment {
                attachment.beginReportingPresented(on: .messages)
            }
            return composer
        case .fail:
            // Do not expose the configured composer (and its Send button). Its owner
            // dismisses the inert sheet after receiving this terminal failure.
            Task { @MainActor [coordinator = context.coordinator] in
                coordinator.finish(MessageComposeReportMapper.report(
                    for: .failed,
                    requiredAttachmentWasPresent: true,
                    requiredAttachmentAccepted: false
                ))
            }
            return UIViewController()
        }
    }

    public func updateUIViewController(_ vc: UIViewController, context: Context) {}

    private func finish(_ report: SharePresentationReportDTO) {
        guard let attachment else {
            onFinish?(.failure(OpaqueSharePresentationError.unavailable))
            return
        }
        Task { @MainActor in
            do {
                onFinish?(.success(try await attachment.finish(report)))
            } catch {
                onFinish?(.failure(error))
            }
        }
    }

    // MFMessageComposeViewControllerDelegate predates Swift concurrency and is not
    // annotated @MainActor in the SDK, yet UIKit always invokes it on the main thread.
    // Isolating the coordinator to @MainActor and marking the conformance @preconcurrency
    // lets a @MainActor method satisfy the nonisolated requirement — the compiler inserts
    // a runtime main-thread check at the call boundary — so we can touch the
    // @MainActor-isolated `dismiss` and the non-Sendable `onFinish` directly, with no
    // cross-actor send.
    @MainActor
    public final class Coordinator: NSObject,
        @preconcurrency MFMessageComposeViewControllerDelegate
    {
        let onFinish: ((SharePresentationReportDTO) -> Void)?
        /// Whether this send included the required PNG artwork.
        let requiredAttachmentWasPresent: Bool
        /// Whether the required attachment was actually accepted by the composer.
        var requiredAttachmentAccepted = false
        private var completionGate = MessageComposeCompletionGate()
        init(
            onFinish: ((SharePresentationReportDTO) -> Void)?,
            requiredAttachmentWasPresent: Bool
        ) {
            self.onFinish = onFinish
            self.requiredAttachmentWasPresent = requiredAttachmentWasPresent
        }

        public func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            defer { controller.dismiss(animated: true) }
            finish(MessageComposeReportMapper.report(
                for: Self.terminalResult(for: result),
                requiredAttachmentWasPresent: requiredAttachmentWasPresent,
                requiredAttachmentAccepted: requiredAttachmentAccepted
            ))
        }

        public func finish(_ proposedReport: SharePresentationReportDTO) {
            guard let report = completionGate.accept(proposedReport) else { return }
            onFinish?(report)
        }

        private static func terminalResult(
            for result: MessageComposeResult
        ) -> MessageComposeTerminalResult {
            switch result {
            case .sent:
                .sent
            case .cancelled:
                .cancelled
            case .failed:
                .failed
            @unknown default:
                .failed
            }
        }
    }
}

@_spi(RuntimeTesting)
public enum RuneScribeMessagePreviewAttachment {
    public static func validatedPNG(_ data: Data) -> Data? {
        guard data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              UIImage(data: data) != nil else { return nil }
        return data
    }
}
#endif
