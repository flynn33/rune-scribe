import Foundation
import CryptoKit

/// A Rune Scribe cipher: real symmetric encryption key material plus the
/// decorative rune presentation. Replaces the old permutation-based `RuneKey`/`NamedCipher`.
struct Cipher: Codable, Equatable, Identifiable {

    enum Origin: String, Codable { case generated, imported }

    /// Current on-disk schema version for a cipher.
    static let currentVersion = 1

    let id: UUID
    var label: String
    let origin: Origin
    let createdAt: Date
    let formatVersion: Int

    /// Non-secret 8-byte identity, used only in the share payload (dedup / updated-cipher
    /// recognition). Never placed in messages. Never derived from the key.
    let publicID: Data

    /// The secret AES-256 key (32 bytes). Only ever serialized into the Keychain-encrypted
    /// library and a user-initiated share payload. Never logged.
    let keyMaterial: Data

    /// Permutation of 0..<32: `decorativeMapping[value]` is the index into
    /// `RuneCharacterSet.decorativeAlphabet` that represents that 5-bit value.
    let decorativeMapping: [Int]

    var symmetricKey: SymmetricKey { SymmetricKey(data: keyMaterial) }

    var shortPublicID: String { publicID.map { String(format: "%02x", $0) }.joined().prefix(8).description }

    init(id: UUID = UUID(), label: String, origin: Origin, createdAt: Date = Date(),
         formatVersion: Int = Cipher.currentVersion, publicID: Data, keyMaterial: Data,
         decorativeMapping: [Int]) {
        self.id = id
        self.label = label
        self.origin = origin
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.decorativeMapping = decorativeMapping
    }

    /// A brand-new locally-generated cipher with a random key, id, and decorative mapping.
    static func generated(label: String) -> Cipher {
        var rng = SystemRandomNumberGenerator()   // CSPRNG on Apple platforms
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let publicID = Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        let mapping = Array(0..<32).shuffled(using: &rng)
        return Cipher(label: label, origin: .generated, publicID: publicID,
                      keyMaterial: key, decorativeMapping: mapping)
    }
}
