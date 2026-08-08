import Foundation
import RuneScribeContracts

enum MessageSend {
    /// Core is authoritative for first-delivery key inclusion.
    static func shouldIncludeKey(_ cipher: Cipher) -> Bool {
        cipher.contactID != nil && !cipher.delivered
    }

    /// The neutral filename deliberately contains neither message nor sender data.
    static let filename = "RuneScrib-Message"

    static func payload(
        runes: String,
        senderName: String,
        cipher: Cipher,
        includeKey: Bool
    ) throws -> MessageSharePayload {
        let envelope = try RuneCodec().decode(runes, with: cipher)
        return MessageSharePayload(
            senderName: senderName,
            envelope: envelope,
            embeddedCipher: includeKey ? CipherSharePayload(cipher: cipher) : nil
        )
    }

    static func shouldRecordDelivery(
        outcome: ShareArtifactOutcomeDTO,
        requiresKeyDelivery: Bool
    ) -> Bool {
        guard requiresKeyDelivery else { return false }
        switch outcome {
        case .handedOff:
            return true
        case .messageSent(let requiredAttachmentAccepted):
            return requiredAttachmentAccepted
        case .cancelled, .failed:
            return false
        }
    }
}

enum AttachmentRequirementDecision: Equatable, Sendable {
    case allowed
    case blockedNeedsAttachment
    case blockedCannotSendText
}

enum MessageAttachmentPolicy {
    static func decide(
        canSendText: Bool,
        canSendAttachments: Bool,
        utiSupported: Bool,
        requiredAttachment: Bool
    ) -> AttachmentRequirementDecision {
        guard canSendText else { return .blockedCannotSendText }
        guard requiredAttachment else { return .allowed }
        guard canSendAttachments, utiSupported else { return .blockedNeedsAttachment }
        return .allowed
    }

    static func shouldConsumeDelivery(
        sent: Bool,
        requiredAttachmentWasPresent: Bool,
        requiredAttachmentAccepted: Bool
    ) -> Bool {
        guard sent else { return false }
        guard requiredAttachmentWasPresent else { return true }
        return requiredAttachmentAccepted
    }
}
