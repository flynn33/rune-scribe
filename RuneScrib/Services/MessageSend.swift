import Foundation

/// Pure builder that turns a composed rune string + its cipher into a sendable
/// `MessageSharePayload`, deciding whether to ride along the cipher key.
enum MessageSend {

    /// Embed the key only when the cipher belongs to a known contact and we have
    /// not yet successfully handed it to them (first delivery bootstraps the key).
    static func shouldIncludeKey(_ cipher: Cipher) -> Bool {
        cipher.contactID != nil && !cipher.delivered
    }

    /// Re-derives the raw envelope from the decorated runes (round-trips the codec),
    /// then wraps it — with the cipher key when `includeKey` — into a share payload.
    static func payload(runes: String,
                        senderName: String,
                        cipher: Cipher,
                        includeKey: Bool) throws -> MessageSharePayload {
        let envelope = try RuneCodec().decode(runes, with: cipher)
        let embeddedCipher = includeKey ? CipherSharePayload(cipher: cipher) : nil
        return MessageSharePayload(senderName: senderName,
                                   envelope: envelope,
                                   embeddedCipher: embeddedCipher)
    }
}
