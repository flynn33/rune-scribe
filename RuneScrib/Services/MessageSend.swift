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

    /// The self-contained file-form bytes for the `.runescribe` attachment. When the key
    /// rides along (`includeKey`) and the cipher uses a non-bundled font, the font bytes
    /// are appended so the recipient can render it; the bundled font is never re-sent
    /// (every install already has it).
    static func fileData(runes: String,
                         senderName: String,
                         cipher: Cipher,
                         includeKey: Bool) throws -> Data {
        let payload = try payload(runes: runes, senderName: senderName,
                                  cipher: cipher, includeKey: includeKey)
        let fontBytes = (includeKey && cipher.fontRef != .bundled)
            ? FontStore.shared.fontData(for: cipher.fontRef) : nil
        return payload.encodedFile(fontBytes: fontBytes)
    }

    /// A neutral filename (no extension) for the outbound attachment — deliberately not
    /// derived from the message or sender, so the file itself leaks nothing.
    static func filename(senderName: String) -> String {
        "RuneScrib-Message"
    }
}
