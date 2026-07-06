#if os(iOS)
import SwiftUI
import MessageUI

/// Thin SwiftUI bridge to the system Messages compose sheet. Presents a prefilled
/// draft (runes + import link); the user taps Send in Apple's own UI. When the message
/// must carry the cipher key (the first message to a contact), the key rides as a real
/// `.runescribe` attachment — and this bridge refuses to quietly mark the key delivered
/// unless that attachment was actually accepted and the user actually sent.
struct MessageComposeView: UIViewControllerRepresentable {
    var messageText: String
    var recipients: [String]?
    var attachmentData: Data?
    var onFinish: (() -> Void)?

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
        Coordinator(onFinish: onFinish, requiredAttachmentWasPresent: attachmentData != nil)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let vc = MFMessageComposeViewController()
        vc.messageComposeDelegate = context.coordinator
        vc.body = messageText
        if let recipients { vc.recipients = recipients }

        if let attachmentData {
            let filename = "message.\(RuneScribeShare.fileExtension)"
            var accepted = false
            // Prefer a real, correctly-typed temp file: Messages receives a concrete file
            // with extension and metadata, which is more reliable than a raw data blob.
            if let url = try? TemporaryRuneScribeFile.write(data: attachmentData) {
                context.coordinator.temporaryAttachmentURL = url
                accepted = vc.addAttachmentURL(url, withAlternateFilename: filename)
            }
            // Fallback to a data attachment — and, unlike before, its Bool result is
            // checked rather than discarded.
            if !accepted {
                accepted = vc.addAttachmentData(attachmentData,
                                                typeIdentifier: RuneScribeShare.uti,
                                                filename: filename)
            }
            context.coordinator.requiredAttachmentAccepted = accepted
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
        let onFinish: (() -> Void)?
        /// Whether this send was required to carry the key file (attachmentData != nil).
        let requiredAttachmentWasPresent: Bool
        /// Whether the required attachment was actually accepted by the composer.
        var requiredAttachmentAccepted = false
        /// The temp `.runescribe` file handed to Messages, removed when the composer finishes.
        var temporaryAttachmentURL: URL?

        init(onFinish: (() -> Void)?, requiredAttachmentWasPresent: Bool) {
            self.onFinish = onFinish
            self.requiredAttachmentWasPresent = requiredAttachmentWasPresent
        }

        func messageComposeViewController(_ controller: MFMessageComposeViewController,
                                          didFinishWith result: MessageComposeResult) {
            defer {
                cleanupTemporaryAttachment()
                controller.dismiss(animated: true)
            }
            // Consume the one-time key delivery only on a real send, and — when this
            // message had to carry the key — only if that attachment was actually
            // accepted. A key that never attached is never marked delivered, so the next
            // message re-attempts it instead of stranding the recipient without a key.
            if MessageAttachmentPolicy.shouldConsumeDelivery(
                sent: result == .sent,
                requiredAttachmentWasPresent: requiredAttachmentWasPresent,
                requiredAttachmentAccepted: requiredAttachmentAccepted) {
                onFinish?()
            }
        }

        /// Removes the unique per-attachment directory created for this send.
        private func cleanupTemporaryAttachment() {
            guard let url = temporaryAttachmentURL else { return }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            temporaryAttachmentURL = nil
        }
    }
}

/// Writes outbound attachment bytes to a real `.runescribe` file in a unique temp
/// subdirectory, so Messages receives a concrete, correctly-typed file rather than a
/// raw data blob. The composer's coordinator removes the enclosing directory when it
/// finishes, so these never accumulate.
enum TemporaryRuneScribeFile {
    static func write(data: Data, basename: String = "message") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeMessageAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(basename)
            .appendingPathExtension(RuneScribeShare.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
