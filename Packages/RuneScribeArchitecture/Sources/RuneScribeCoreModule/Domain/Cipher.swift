import CryptoKit
import Foundation

enum CipherValidationError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
    case invalidPublicIDLength
    case invalidKeyMaterialLength
    case invalidSymbolPermutation
    case invalidFontReference
    case invalidDeliveryState
}

enum KeyDeliveryState: String, Codable, Equatable, Sendable {
    case notLinked
    case pending
    case inProgress
    case completed
    case migratedUnverified

    var requiresDelivery: Bool {
        self == .pending
    }

    var preservesLegacyDeliveryContinuity: Bool {
        self == .completed || self == .migratedUnverified
    }
}

/// Compatibility data that remains Core-owned. A legacy/imported font is a validated
/// rendering resource, not a Theme Module and never a source of executable behavior.
struct CipherCompatibilityRecord: Codable, Equatable, Sendable {
    let originalRecordVersion: Int
    let legacyFontRef: FontRef?
}

/// A Rune Scribe cipher record. Cryptographic material and the 32-slot symbol
/// permutation are intentionally independent from the selected Codex/Script.
struct Cipher: Codable, Equatable, Identifiable, Sendable {

    enum Origin: String, Codable, Sendable { case generated, imported }

    /// v1 stored `decorativeMapping`, `fontRef`, and `delivered`. v2 stores the
    /// neutral symbol permutation, an explicit delivery state, and compatibility data.
    static let currentVersion = 2

    let id: UUID
    var label: String
    let origin: Origin
    let createdAt: Date
    let formatVersion: Int

    /// Non-secret 8-byte identity used for share-payload deduplication. It is never
    /// derived from the key and must not be used as a progression relationship token.
    let publicID: Data

    /// Secret AES-256 key material. It is serialized only in the encrypted library
    /// and explicit key-bearing share payloads and must never enter diagnostics.
    let keyMaterial: Data

    /// `symbolPermutation[value]` is the slot in a Script's ordered 32-symbol alphabet
    /// that represents that five-bit value. Changing a Script never changes this value.
    let symbolPermutation: [Int]

    /// Local organization metadata. It is not cryptographic material or share metadata.
    private(set) var contactID: UUID?

    /// Key-exchange continuity is explicit and independent from future progression proof.
    private(set) var keyDeliveryState: KeyDeliveryState

    let compatibility: CipherCompatibilityRecord

    /// Read-only compatibility projections. State changes use the explicit key-delivery
    /// transitions below; the legacy writable `delivered` rail is decode-only.
    var decorativeMapping: [Int] { symbolPermutation }
    var fontRef: FontRef { compatibility.legacyFontRef ?? .bundled }
    var hasCompletedKeyDelivery: Bool { keyDeliveryState.preservesLegacyDeliveryContinuity }

    var symmetricKey: SymmetricKey { SymmetricKey(data: keyMaterial) }

    var shortPublicID: String {
        publicID.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    init(
        id: UUID = UUID(),
        label: String,
        origin: Origin,
        createdAt: Date = Date(),
        formatVersion: Int = Cipher.currentVersion,
        publicID: Data,
        keyMaterial: Data,
        decorativeMapping: [Int],
        fontRef: FontRef = .bundled,
        contactID: UUID? = nil
    ) {
        self.id = id
        self.label = label
        self.origin = origin
        self.createdAt = createdAt
        self.formatVersion = formatVersion
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.symbolPermutation = decorativeMapping
        self.contactID = contactID
        self.keyDeliveryState = contactID == nil ? .notLinked : .pending
        self.compatibility = CipherCompatibilityRecord(
            originalRecordVersion: formatVersion,
            legacyFontRef: fontRef == .bundled ? nil : fontRef
        )
    }

    init(
        id: UUID = UUID(),
        label: String,
        origin: Origin,
        createdAt: Date = Date(),
        publicID: Data,
        keyMaterial: Data,
        symbolPermutation: [Int],
        contactID: UUID? = nil,
        keyDeliveryState: KeyDeliveryState? = nil,
        compatibility: CipherCompatibilityRecord? = nil
    ) {
        self.id = id
        self.label = label
        self.origin = origin
        self.createdAt = createdAt
        self.formatVersion = Self.currentVersion
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.symbolPermutation = symbolPermutation
        self.contactID = contactID
        self.keyDeliveryState = keyDeliveryState
            ?? (contactID == nil ? .notLinked : .pending)
        self.compatibility = compatibility ?? CipherCompatibilityRecord(
            originalRecordVersion: Self.currentVersion,
            legacyFontRef: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, origin, createdAt, formatVersion, publicID, keyMaterial
        case symbolPermutation, keyDeliveryState, compatibility
        case decorativeMapping, fontRef, contactID, delivered
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard storedVersion == 1 || storedVersion == Self.currentVersion else {
            throw CipherValidationError.unsupportedFormatVersion(storedVersion)
        }

        id = try container.decode(UUID.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        origin = try container.decode(Origin.self, forKey: .origin)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        formatVersion = Self.currentVersion
        publicID = try container.decode(Data.self, forKey: .publicID)
        keyMaterial = try container.decode(Data.self, forKey: .keyMaterial)
        contactID = try container.decodeIfPresent(UUID.self, forKey: .contactID)

        if storedVersion == 1 {
            symbolPermutation = try container.decode([Int].self, forKey: .decorativeMapping)
            let legacyFont = try container.decodeIfPresent(FontRef.self, forKey: .fontRef) ?? .bundled
            let wasDelivered = try container.decodeIfPresent(Bool.self, forKey: .delivered) ?? false
            if contactID == nil {
                // Legacy code deliberately preserved `delivered` while unlinking a
                // contact. With no current relationship there is no key-delivery
                // continuity to preserve and no progression fact to infer.
                keyDeliveryState = .notLinked
            } else {
                keyDeliveryState = wasDelivered ? .migratedUnverified : .pending
            }
            compatibility = CipherCompatibilityRecord(
                originalRecordVersion: storedVersion,
                legacyFontRef: legacyFont == .bundled ? nil : legacyFont
            )
        } else {
            symbolPermutation = try container.decode([Int].self, forKey: .symbolPermutation)
            let decodedDeliveryState = try container.decode(
                KeyDeliveryState.self,
                forKey: .keyDeliveryState
            )
            // An in-flight share lease is process-local. A relaunch cannot prove
            // completion, so persisted in-progress state recovers to pending.
            keyDeliveryState = decodedDeliveryState == .inProgress
                ? .pending
                : decodedDeliveryState
            compatibility = try container.decodeIfPresent(
                CipherCompatibilityRecord.self,
                forKey: .compatibility
            ) ?? CipherCompatibilityRecord(
                originalRecordVersion: Self.currentVersion,
                legacyFontRef: nil
            )
        }
        try validateStoredShape()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(origin, forKey: .origin)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(Self.currentVersion, forKey: .formatVersion)
        try container.encode(publicID, forKey: .publicID)
        try container.encode(keyMaterial, forKey: .keyMaterial)
        try container.encode(symbolPermutation, forKey: .symbolPermutation)
        try container.encodeIfPresent(contactID, forKey: .contactID)
        try container.encode(keyDeliveryState, forKey: .keyDeliveryState)
        try container.encode(compatibility, forKey: .compatibility)
    }

    mutating func setContactID(_ newContactID: UUID?) {
        guard newContactID != contactID else { return }
        contactID = newContactID
        keyDeliveryState = newContactID == nil ? .notLinked : .pending
    }

    mutating func beginKeyDelivery() {
        guard contactID != nil, keyDeliveryState.requiresDelivery else { return }
        keyDeliveryState = .inProgress
    }

    mutating func cancelKeyDelivery() {
        guard contactID != nil, keyDeliveryState == .inProgress else { return }
        keyDeliveryState = .pending
    }

    mutating func completeKeyDelivery() {
        guard contactID != nil else { return }
        keyDeliveryState = .completed
    }

    /// A brand-new locally generated cipher with random key material and permutation.
    static func generated(label: String) -> Cipher {
        var rng = SystemRandomNumberGenerator()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let publicID = Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
        return Cipher(
            label: label,
            origin: .generated,
            publicID: publicID,
            keyMaterial: key,
            symbolPermutation: Array(0..<32).shuffled(using: &rng)
        )
    }

    private func validateStoredShape() throws {
        guard formatVersion == Self.currentVersion else {
            throw CipherValidationError.unsupportedFormatVersion(formatVersion)
        }
        guard publicID.count == 8 else {
            throw CipherValidationError.invalidPublicIDLength
        }
        guard keyMaterial.count == 32 else {
            throw CipherValidationError.invalidKeyMaterialLength
        }
        guard symbolPermutation.count == 32,
              Set(symbolPermutation) == Set(0..<32)
        else {
            throw CipherValidationError.invalidSymbolPermutation
        }
        guard fontRef.hasValidWireShape else {
            throw CipherValidationError.invalidFontReference
        }
        guard (contactID == nil) == (keyDeliveryState == .notLinked) else {
            throw CipherValidationError.invalidDeliveryState
        }
    }
}
