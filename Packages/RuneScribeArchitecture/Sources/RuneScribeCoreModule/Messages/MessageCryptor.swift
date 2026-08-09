import Foundation
import CryptoKit

enum MessageCryptorError: Error, LocalizedError, Equatable, Sendable {
    case sealFailed
    case notUTF8
    var errorDescription: String? {
        switch self {
        case .sealFailed: return "Couldn't encrypt the message."
        case .notUTF8:    return "The decrypted message wasn't valid text."
        }
    }
}

/// Stateless authenticated encryption over a `Cipher`'s symmetric key (AES-GCM).
/// A wrong key or any tampering makes `open` throw — it never returns bogus plaintext.
struct MessageCryptor: Sendable {
    /// Returns `AES.GCM.SealedBox.combined` (12-byte nonce ‖ ciphertext ‖ 16-byte tag).
    func seal(_ plaintext: String, with cipher: Cipher) throws -> Data {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: cipher.symmetricKey)
        guard let combined = box.combined else { throw MessageCryptorError.sealFailed }
        return combined
    }

    func open(_ sealed: Data, with cipher: Cipher) throws -> String {
        let box = try AES.GCM.SealedBox(combined: sealed)
        let plaintext = try AES.GCM.open(box, using: cipher.symmetricKey)
        guard let text = String(data: plaintext, encoding: .utf8) else { throw MessageCryptorError.notUTF8 }
        return text
    }
}
