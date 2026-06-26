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

    /// The rune font this cipher uses for display. Defaults to the bundled font.
    let fontRef: FontRef

    /// The contact this cipher is organized under, if any. Purely organizational metadata —
    /// setting or clearing it never affects `keyMaterial`. Codable default nil so Phase-1/2
    /// ciphers (which predate this field) load unchanged.
    var contactID: UUID?

    /// Whether this cipher's key has been delivered to its linked contact at least once.
    /// Drives Phase-4 key auto-exchange: a key is embedded in an outgoing message only while
    /// this is false. Codable default false so pre-Phase-4 ciphers load unchanged.
    var delivered: Bool

    var symmetricKey: SymmetricKey { SymmetricKey(data: keyMaterial) }

    var shortPublicID: String { publicID.map { String(format: "%02x", $0) }.joined().prefix(8).description }

    init(id: UUID = UUID(), label: String, origin: Origin, createdAt: Date = Date(),
         formatVersion: Int = Cipher.currentVersion, publicID: Data, keyMaterial: Data,
         decorativeMapping: [Int], fontRef: FontRef = .bundled, contactID: UUID? = nil,
         delivered: Bool = false) {
        self.id = id
        self.label = label
        self.origin = origin
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.decorativeMapping = decorativeMapping
        self.fontRef = fontRef
        self.contactID = contactID
        self.delivered = delivered
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, origin, createdAt, formatVersion, publicID, keyMaterial, decorativeMapping, fontRef, contactID, delivered
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        origin = try c.decode(Origin.self, forKey: .origin)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        publicID = try c.decode(Data.self, forKey: .publicID)
        keyMaterial = try c.decode(Data.self, forKey: .keyMaterial)
        decorativeMapping = try c.decode([Int].self, forKey: .decorativeMapping)
        fontRef = try c.decodeIfPresent(FontRef.self, forKey: .fontRef) ?? .bundled
        contactID = try c.decodeIfPresent(UUID.self, forKey: .contactID)
        delivered = try c.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
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
