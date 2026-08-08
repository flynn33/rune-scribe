import Foundation

/// Hosted-UI policy for deciding whether a prepared message requires the scoped
/// share artifact produced by Core. Payload construction and keys never enter UI.
enum MessageSend {

    /// Embed the key only when the cipher belongs to a known contact and we have
    /// not yet successfully handed it to them (first delivery bootstraps the key).
    static func shouldIncludeKey(_ cipher: CipherViewState) -> Bool {
        cipher.contactID != nil && !cipher.delivered
    }

    /// A neutral filename (no extension) for the outbound attachment — deliberately not
    /// derived from the message or sender, so the file itself leaks nothing.
    static func filename(senderName: String) -> String {
        "RuneScrib-Message"
    }
}

// MARK: - Outbound iMessage attachment policy

/// Whether the Messages composer may be presented for this send.
enum AttachmentRequirementDecision: Equatable {
    /// Fine to present.
    case allowed
    /// This send carries the one-time key file, but the device can't attach it.
    case blockedNeedsAttachment
    /// The device can't send texts at all (no iMessage / Simulator).
    case blockedCannotSendText
}

/// Pure decisions for the outbound iMessage path, kept free of MessageUI (and of any
/// `#if os(iOS)`) so they compile — and are unit-tested — on the macOS test host as
/// well as on device. `MessageComposeView` feeds these the live
/// `MFMessageComposeViewController` capabilities; the app never marks a cipher delivered
/// except through `shouldConsumeDelivery`.
enum MessageAttachmentPolicy {

    /// Decides whether presenting the composer is allowed given the device's Messages
    /// capabilities and whether *this* message must carry a `.runescribe` attachment (the
    /// first message to a contact, which bootstraps the cipher key). A message with no
    /// required attachment only needs text capability; a key-bearing message additionally
    /// needs attachment support *and* support for our UTI, so a key file can never be
    /// silently dropped.
    static func decide(canSendText: Bool,
                       canSendAttachments: Bool,
                       utiSupported: Bool,
                       requiredAttachment: Bool) -> AttachmentRequirementDecision {
        guard canSendText else { return .blockedCannotSendText }
        guard requiredAttachment else { return .allowed }
        guard canSendAttachments, utiSupported else { return .blockedNeedsAttachment }
        return .allowed
    }

    /// Whether a completed send should consume the one-time key delivery (mark the cipher
    /// delivered). Only a real send counts, and if this message was required to carry the
    /// key, that attachment must actually have been accepted — otherwise the recipient got
    /// a message with no key and the sender must NOT believe the key was handed over.
    static func shouldConsumeDelivery(sent: Bool,
                                      requiredAttachmentWasPresent: Bool,
                                      requiredAttachmentAccepted: Bool) -> Bool {
        guard sent else { return false }
        guard requiredAttachmentWasPresent else { return true }
        return requiredAttachmentAccepted
    }
}
