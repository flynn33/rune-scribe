// RuneScrib/Models/NamedCipher.swift

import Foundation

/// A labelled cipher in the user's library. Each entry wraps a full `RuneKey` —
/// a matched cipher/decipher pair — so a single entry can both encode plain text
/// into runes and decode runes back to text. Entries are either generated on this
/// device or imported from a decoder file shared by a correspondent.
struct NamedCipher: Codable, Equatable, Identifiable {

    /// Where the cipher came from, surfaced as a small badge in the library.
    enum Origin: String, Codable {
        case generated   // created on this device
        case imported    // imported from a decoder file
    }

    /// Stable library-entry identifier (independent of the key id, so the same
    /// decoder file may be imported more than once under different labels).
    let id: UUID

    /// User-supplied label shown throughout the UI.
    var label: String

    /// Whether this pair was generated locally or imported.
    let origin: Origin

    /// The underlying cipher/decipher pair.
    let key: RuneKey

    /// Creation timestamp of the underlying key (mirrored for display/sorting).
    var createdAt: Date { key.createdAt }

    /// Short, display-friendly form of the underlying key id.
    var shortKeyId: String { String(key.keyId.prefix(8)) }

    init(id: UUID = UUID(), label: String, origin: Origin, key: RuneKey) {
        self.id = id
        self.label = label
        self.origin = origin
        self.key = key
    }

    /// Creates a brand-new locally-generated cipher with a random mapping.
    static func generated(label: String) -> NamedCipher {
        NamedCipher(label: label,
                    origin: .generated,
                    key: RuneKey(mapping: RuneCharacterSet.generateRandomMapping()))
    }
}
