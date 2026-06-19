// RuneScrib/Models/RuneKey.swift

import Foundation

/// The in-memory representation of the active cipher mapping.
/// Both `mapping` and `reverseMapping` are derived from the same
/// random permutation — they are always consistent with each other.
struct RuneKey: Codable, Equatable {

    // MARK: - Properties

    /// Schema version. Increment if the RuneKey format changes.
    let version: Int

    /// Unique identifier for this key instance. Used in exports.
    let keyId: String

    /// UTC timestamp of key creation or last rotation.
    let createdAt: Date

    /// Forward map: single input character string → single rune character string.
    /// Example: ["A": "ᚷ", "B": "ᛒ", " ": "ᚨ", ...]
    let mapping: [String: String]

    /// Reverse map: single rune character string → single input character string.
    /// Derived from `mapping`. Used for decoding.
    let reverseMapping: [String: String]

    // MARK: - Initialiser

    /// Creates a RuneKey from a forward mapping dictionary.
    /// The reverse mapping is automatically derived.
    /// - Parameter mapping: A bijection from 89 input chars to 89 rune chars.
    init(mapping: [String: String]) {
        precondition(mapping.count == 89,
                     "RuneKey requires exactly 89 mapping entries, got \(mapping.count)")

        self.init(keyId: UUID().uuidString, createdAt: Date(), mapping: mapping)
    }

    /// Reconstructs a RuneKey while preserving an existing identity and creation
    /// date (used when importing a decoder file so the original key id/date are
    /// retained). The reverse mapping is always re-derived from `mapping`.
    init(keyId: String, createdAt: Date, mapping: [String: String]) {
        precondition(mapping.count == 89,
                     "RuneKey requires exactly 89 mapping entries, got \(mapping.count)")

        self.version = 1
        self.keyId = keyId
        self.createdAt = createdAt
        self.mapping = mapping
        self.reverseMapping = Dictionary(
            uniqueKeysWithValues: mapping.map { inputChar, runeChar in
                (runeChar, inputChar)
            }
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case version, keyId, createdAt, mapping, reverseMapping
    }
}
