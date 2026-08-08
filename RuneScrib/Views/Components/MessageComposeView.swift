#if os(iOS)
import MessageUI
import RuneScribeContracts
import SwiftUI

/// Thin SwiftUI bridge to the system Messages compose sheet. Presents a prefilled
/// draft (runes + import link); the user taps Send in Apple's own UI. When the message
/// must carry the cipher key (the first message to a contact), the key rides as a real
/// `.runescribe` attachment — and this bridge refuses to quietly mark the key delivered
/// unless that attachment was actually accepted and the user actually sent.
struct MessageComposeView: UIViewControllerRepresentable {
    var messageText: String
    var recipients: [String]?
    var attachmentURL: URL?
    var onFinish: ((ShareArtifactOutcomeDTO) -> Void)?

    /// Whether this device can send this message at all. Pass `requiredAttachment: true`
    /// when the message must carry the key file: the device must then also support
    /// attachments and our UTI, so the key can't be silently dropped. Callers must
    /// preflight this before presenting the composer.
    ///
    /// The `MFMessageComposeViewController` capability probes are main-actor-isolated, so
    /// this accessor is too; it is only read from the view body / a button action.
    @MainActor
    static func canSend(requiredAttachment: Bool) -> Bool {
        MessageAttachmentPolicy.decide(
            canSendText: MFMessageComposeViewController.canSendText(),
            canSendAttachments: MFMessageComposeViewController.canSendAttachments(),
            utiSupported: MFMessageComposeViewController.isSupportedAttachmentUTI(RuneScribeShare.uti),
            requiredAttachment: requiredAttachment) == .allowed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, requiredAttachmentWasPresent: attachmentURL != nil)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.body = messageText
        if let recipients { vc.recipients = recipients }

        if let attachmentURL {
            let filename = "message.\(RuneScribeShare.fileExtension)"
            context.coordinator.requiredAttachmentAccepted = vc.addAttachmentURL(
                attachmentURL,
                withAlternateFilename: filename
            )
        }
        return vc
    }

    func updateUIViewController(_ vc: MFMessageComposeViewController, context: Context) {}

    // MFMessageComposeViewControllerDelegate predates Swift concurrency and is not
    // annotated @MainActor in the SDK, yet UIKit always invokes it on the main thread.
    // Isolating the coordinator to @MainActor and marking the conformance @preconcurrency
    // lets a @MainActor method satisfy the nonisolated requirement — the compiler inserts
    // a runtime main-thread check at the call boundary — so we can touch the
    // @MainActor-isolated `dismiss` and the non-Sendable `onFinish` directly, with no
    // cross-actor send.
    @MainActor
    final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
        let onFinish: ((ShareArtifactOutcomeDTO) -> Void)?
        /// Whether this send was required to carry the scoped Core artifact.
        let requiredAttachmentWasPresent: Bool
        /// Whether the required attachment was actually accepted by the composer.
        var requiredAttachmentAccepted = false
        init(
            onFinish: ((ShareArtifactOutcomeDTO) -> Void)?,
            requiredAttachmentWasPresent: Bool
        ) {
            self.onFinish = onFinish
            self.requiredAttachmentWasPresent = requiredAttachmentWasPresent
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            defer { controller.dismiss(animated: true) }
            switch result {
            case .sent:
                onFinish?(.messageSent(
                    requiredAttachmentAccepted: requiredAttachmentWasPresent
                        && requiredAttachmentAccepted
                ))
            case .cancelled:
                onFinish?(.cancelled)
            case .failed:
                onFinish?(.failed)
            @unknown default:
                onFinish?(.failed)
            }
        }
    }
}
#endif
