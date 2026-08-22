import Foundation

enum MessageError: Error, LocalizedError, Equatable, Sendable {
    case inputTooLarge
    case tooManyCandidateCiphers
    case decodeWorkLimitExceeded
    case noMatchingCipher

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            return "The pasted rune message is too large to decode."
        case .tooManyCandidateCiphers:
            return "Too many ciphers are available to decode this message."
        case .decodeWorkLimitExceeded:
            return "The message and cipher library require too much decode work."
        case .noMatchingCipher:
            return "No matching cipher. Import the sender's cipher, then try again."
        }
    }
}

/// Orchestrates compose (encrypt → frame → decorate) and read (try each cipher:
/// un-decorate → unframe → decrypt). Stateless; depends only on the leaf services.
struct MessageService: Sendable {
    /// Direct text decode intentionally permits messages much larger than the
    /// packaged UInt16 envelope while preventing an unbounded editor paste from
    /// being copied into the filtered rune string and per-cipher decode buffers.
    static let maximumPastedRuneUTF8ByteCount = 1_048_576

    /// Trying every stored key is part of the legacy identifier-free wire format.
    /// Keep that compatibility path finite even if durable library state grows.
    static let maximumCandidateCipherCount = CipherLibrary.maximumCipherCount

    /// Bounds the product of input bytes and candidate count. This preserves
    /// short-message compatibility for large existing libraries without letting
    /// a maximum-size input multiply into unbounded try-all work.
    static let maximumDecodeWorkByteCount = 128 * 1_024 * 1_024

    /// AEAD setup and authentication have a nonzero cost even for a short
    /// payload. Charging this floor bounds a minimum-size message to 65,568
    /// attempts while retaining the established 65,539-cipher sparse-library
    /// compatibility case.
    static let minimumDecodeWorkByteCountPerCandidate = 2_047

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
        guard runes.utf8.count <= Self.maximumPastedRuneUTF8ByteCount else {
            throw MessageError.inputTooLarge
        }
        try validateCandidateCount(ciphers)
        try validateDecodeWork(
            inputByteCount: runes.utf8.count,
            candidateCount: ciphers.count
        )

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
    /// Unwraps the framing once, then lets the AEAD tag pick the right key;
    /// a wrong key or any tampering throws rather than returning bogus plaintext.
    func read(envelope: Data, tryingCiphers ciphers: [Cipher]) throws -> (plaintext: String, cipher: Cipher) {
        try validateCandidateCount(ciphers)
        guard let sealed = try? MessageEnvelope.unwrap(envelope) else {
            throw MessageError.noMatchingCipher
        }
        guard sealed.count >= MessageCryptor.minimumCombinedByteCount else {
            throw MessageError.noMatchingCipher
        }
        try validateDecodeWork(
            inputByteCount: sealed.count,
            candidateCount: ciphers.count
        )
        for cipher in ciphers {
            guard let text = try? cryptor.open(sealed, with: cipher)
            else { continue }
            return (text, cipher)
        }
        throw MessageError.noMatchingCipher
    }

    private func validateCandidateCount(_ ciphers: [Cipher]) throws {
        guard ciphers.count <= Self.maximumCandidateCipherCount else {
            throw MessageError.tooManyCandidateCiphers
        }
    }

    private func validateDecodeWork(
        inputByteCount: Int,
        candidateCount: Int
    ) throws {
        let chargedByteCount = max(
            inputByteCount,
            Self.minimumDecodeWorkByteCountPerCandidate
        )
        guard candidateCount == 0
            || chargedByteCount <= Self.maximumDecodeWorkByteCount / candidateCount
        else {
            throw MessageError.decodeWorkLimitExceeded
        }
    }
}
