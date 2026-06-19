// RuneScrib/Models/CipherLibrary.swift

import Foundation

/// The persisted collection of the user's labelled ciphers, plus which one is
/// active. Stored AES-GCM-encrypted in the Keychain (account `cipherLibrary`).
/// Library order is the user's order — new ciphers are appended.
struct CipherLibrary: Codable, Equatable {

    /// Schema version, so the stored format can evolve safely.
    var version: Int = 1

    /// All ciphers the user has created or imported.
    var ciphers: [NamedCipher]

    /// The id of the active cipher (used for both encoding and decoding).
    var activeID: UUID?

    static let empty = CipherLibrary(ciphers: [], activeID: nil)

    /// The active cipher, falling back to the first entry when the stored
    /// `activeID` is missing or no longer present.
    var activeCipher: NamedCipher? {
        if let activeID, let match = ciphers.first(where: { $0.id == activeID }) {
            return match
        }
        return ciphers.first
    }

    private enum CodingKeys: String, CodingKey {
        case version, ciphers, activeID
    }
}

// MARK: - Pure Mutations
//
// These return a new library rather than mutating in place, and contain no
// Keychain or actor dependencies, so the invariants (always non-empty, active id
// always valid) are unit-testable. `KeyManager` delegates to them and persists.

extension CipherLibrary {

    /// Appends a cipher and makes it active.
    func adding(_ cipher: NamedCipher) -> CipherLibrary {
        var copy = self
        copy.ciphers.append(cipher)
        copy.activeID = cipher.id
        return copy
    }

    /// Removes the cipher with `id`. Never leaves the library empty: if the last
    /// cipher is removed, a fresh one is generated and made active.
    func removingCipher(id: UUID, regeneratedLabel: String = "My Cipher") -> CipherLibrary {
        var copy = self
        copy.ciphers.removeAll { $0.id == id }
        if copy.activeID == id { copy.activeID = copy.ciphers.first?.id }
        if copy.ciphers.isEmpty {
            let fresh = NamedCipher.generated(label: regeneratedLabel)
            copy.ciphers = [fresh]
            copy.activeID = fresh.id
        }
        return copy
    }

    /// Relabels the cipher with `id` (no-op if not found).
    func renamingCipher(id: UUID, to label: String) -> CipherLibrary {
        var copy = self
        if let index = copy.ciphers.firstIndex(where: { $0.id == id }) {
            copy.ciphers[index].label = label
        }
        return copy
    }

    /// Selects the active cipher (no-op if `id` isn't present).
    func settingActive(id: UUID) -> CipherLibrary {
        guard ciphers.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.activeID = id
        return copy
    }

    /// Builds the initial library from decrypted legacy data, preserving the
    /// imported decoder's original key id/date. Guarantees at least one cipher.
    static func fromLegacy(key: RuneKey?,
                           decoder: ImportedDecoder?,
                           defaultLabel: String = "My Cipher") -> CipherLibrary {
        var ciphers: [NamedCipher] = []
        if let key {
            ciphers.append(NamedCipher(label: "My Cipher", origin: .generated, key: key))
        }
        if let decoder {
            let decoderKey = RuneKey(keyId: decoder.keyId,
                                     createdAt: decoder.createdAt,
                                     mapping: decoder.mapping)
            ciphers.append(NamedCipher(label: "Imported Decoder", origin: .imported, key: decoderKey))
        }
        if ciphers.isEmpty {
            ciphers.append(NamedCipher.generated(label: defaultLabel))
        }
        return CipherLibrary(ciphers: ciphers, activeID: ciphers.first?.id)
    }
}
