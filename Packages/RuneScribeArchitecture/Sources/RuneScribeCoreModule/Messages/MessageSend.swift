import Foundation
import RuneScribeContracts

enum MessageSend {
    /// The neutral filename deliberately contains neither message nor sender data.
    static let filename = "RuneScrib-Message"

    static func payload(
        runes: String,
        senderName: String,
        cipher: Cipher
    ) throws -> MessageSharePayload {
        let envelope = try RuneCodec().decode(runes, with: cipher)
        return MessageSharePayload(
            senderName: senderName,
            envelope: envelope,
            embeddedCipher: nil
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
