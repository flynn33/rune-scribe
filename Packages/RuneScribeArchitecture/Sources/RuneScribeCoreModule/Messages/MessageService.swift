import Foundation

enum MessageError: Error, LocalizedError, Equatable, Sendable {
    case noMatchingCipher
    var errorDescription: String? {
        switch self {
        case .noMatchingCipher:
            return "No matching cipher. Import the sender's cipher, then try again."
        }
    }
}

/// Orchestrates compose (encrypt → frame → decorate) and read (try each cipher:
/// un-decorate → unframe → decrypt). Stateless; depends only on the leaf services.
struct MessageService: Sendable {
    private let cryptor = MessageCryptor()
    private let codec = RuneCodec()

    /// Plaintext + cipher → decorative rune string.
    func compose(_ plaintext: String, with cipher: Cipher) throws -> String {
        let sealed = try cryptor.seal(plaintext, with: cipher)
        let envelope = MessageEnvelope.wrap(sealed)
        return codec.encode(envelope, with: cipher)
    }

    /// Rune string → (plaintext, cipher) by trying each candidate. Exactly one cipher's
    /// key authenticates the message; everything else fails to open.
    func read(_ runes: String, tryingCiphers ciphers: [Cipher]) throws -> (plaintext: String, cipher: Cipher) {
        // Tolerate whitespace, newlines, or surrounding text around a pasted rune
        // message (e.g. copied from Messages/Mail) by keeping only the decorative runes.
        let alphabet = Set(RuneCharacterSet.decorativeAlphabet)
        let cleaned = String(runes.filter(alphabet.contains))
        for cipher in ciphers {
            guard let bytes = try? codec.decode(cleaned, with: cipher),
                  let sealed = try? MessageEnvelope.unwrap(bytes),
                  let text = try? cryptor.open(sealed, with: cipher)
            else { continue }
            return (text, cipher)
        }
        throw MessageError.noMatchingCipher
    }

    /// Raw `MessageEnvelope` bytes → (plaintext, cipher) by trying each candidate.
    /// Used by message intake, which already holds a decoded envelope (no rune layer).
    /// Unwraps the framing once per cipher and lets the AEAD tag pick the right key;
    /// a wrong key or any tampering throws rather than returning bogus plaintext.
    func read(envelope: Data, tryingCiphers ciphers: [Cipher]) throws -> (plaintext: String, cipher: Cipher) {
        for cipher in ciphers {
            guard let sealed = try? MessageEnvelope.unwrap(envelope),
                  let text = try? cryptor.open(sealed, with: cipher)
            else { continue }
            return (text, cipher)
        }
        throw MessageError.noMatchingCipher
    }
}
