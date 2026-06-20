// RuneScrib/Services/KeyManager.swift

import Foundation
import CryptoKit

// MARK: - KeyManager Errors

enum KeyManagerError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case noKeyAvailable

    var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Failed to encrypt the cipher library."
        case .decryptionFailed: return "Failed to decrypt the cipher library."
        case .noKeyAvailable:   return "No cipher is currently available."
        }
    }
}

// MARK: - KeyManager

/// Owns the user's cipher library: a list of labelled `NamedCipher` pairs plus the
/// active selection. The whole library is persisted AES-GCM-encrypted in the
/// Keychain. One symmetric AES key (also in the Keychain) protects it.
///
/// Published as a singleton and injected as an `@EnvironmentObject`. All published
/// state mutates on the main actor.
@MainActor
final class KeyManager: ObservableObject {

    // MARK: - Singleton

    static let shared = KeyManager()

    // MARK: - Published State

    @Published private(set) var library: CipherLibrary = .empty
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Derived

    /// All ciphers in library order.
    var ciphers: [NamedCipher] { library.ciphers }

    /// The active cipher, used for both encoding and decoding.
    var activeCipher: NamedCipher? { library.activeCipher }

    // MARK: - Private Dependencies

    private let keychain = KeychainService.shared

    // MARK: - Init

    private init() {
        Task { await load() }
    }

    // MARK: - Load / Migrate

    /// Loads the cipher library from the Keychain. On first launch under the
    /// library model, migrates any legacy single key / imported decoder, and
    /// guarantees at least one cipher exists.
    func load() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let aesKey = try loadOrCreateSymmetricKey()

            if let data = try keychain.retrieveEncryptedLibrary() {
                library = try decrypt(CipherLibrary.self, from: data, using: aesKey)
            } else {
                library = migrateLegacy(using: aesKey)
                try persist(using: aesKey)
                // Migration succeeded and is now the source of truth — remove the
                // legacy entries so this path doesn't run again.
                try? keychain.deleteEncryptedMapping()
                try? keychain.deleteImportedDecoder()
            }

            if library.ciphers.isEmpty {
                let first = NamedCipher.generated(label: "My Cipher")
                library = CipherLibrary(ciphers: [first], activeID: first.id)
                try persist(using: aesKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Builds the initial library from any pre-library Keychain data so existing
    /// users keep their cipher and any imported decoder across the upgrade. If the
    /// legacy blobs are absent or unreadable, a fresh cipher is seeded (the old
    /// data, if present-but-undecryptable, is unrecoverable regardless).
    private func migrateLegacy(using aesKey: SymmetricKey) -> CipherLibrary {
        let legacyKey: RuneKey? = (try? keychain.retrieveEncryptedMapping())
            .flatMap { $0 }
            .flatMap { try? decrypt(RuneKey.self, from: $0, using: aesKey) }

        let legacyDecoder: ImportedDecoder? = (try? keychain.retrieveEncryptedDecoder())
            .flatMap { $0 }
            .flatMap { try? decrypt(ImportedDecoder.self, from: $0, using: aesKey) }

        return CipherLibrary.fromLegacy(key: legacyKey, decoder: legacyDecoder)
    }

    // MARK: - Mutations

    /// Creates a new random cipher, appends it, and makes it active.
    @discardableResult
    func addCipher(label: String) -> NamedCipher? {
        let cipher = NamedCipher.generated(label: cleanLabel(label, fallback: "New Cipher"))
        library = library.adding(cipher)
        persist()
        return lastError == nil ? cipher : nil
    }

    /// Imports a decoder file as a new cipher, appends it, and makes it active.
    @discardableResult
    func importCipher(data: Data, label: String?) throws -> NamedCipher {
        let decoder = try ImportedDecoder.parse(data)
        let key = RuneKey(keyId: decoder.keyId, createdAt: decoder.createdAt, mapping: decoder.mapping)
        let name = cleanLabel(label ?? "", fallback: "Imported \(decoder.keyId.prefix(6))")
        let cipher = NamedCipher(label: name, origin: .imported, key: key)

        let aesKey = try loadOrCreateSymmetricKey()
        library = library.adding(cipher)
        try persist(using: aesKey)
        lastError = nil
        return cipher
    }

    /// Renames the cipher with the given id.
    func renameCipher(id: UUID, to newLabel: String) {
        guard let existing = library.ciphers.first(where: { $0.id == id }) else { return }
        library = library.renamingCipher(id: id, to: cleanLabel(newLabel, fallback: existing.label))
        persist()
    }

    /// Deletes the cipher with the given id. Never leaves the library empty: if the
    /// last cipher is removed, a fresh one is generated.
    func deleteCipher(id: UUID) {
        library = library.removingCipher(id: id)
        persist()
    }

    /// Selects the active cipher used for encoding and decoding.
    func setActive(id: UUID) {
        library = library.settingActive(id: id)
        persist()
    }

    // MARK: - Export

    /// Builds the single decoder/decrypter JSON file for the given cipher.
    func exportData(for id: UUID) throws -> Data {
        guard let cipher = library.ciphers.first(where: { $0.id == id }) else {
            throw KeyManagerError.noKeyAvailable
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(RuneKeyExport.from(cipher.key))
    }

    /// Suggested filename (without extension) for the given cipher's decoder file.
    func exportFilename(for id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let cipher = library.ciphers.first(where: { $0.id == id })
        let base = cipher.map { sanitizeForFilename($0.label) } ?? "decoder"
        let stamp = cipher.map { formatter.string(from: $0.createdAt) } ?? "key"
        return "RuneScrib-\(base)-\(stamp)"
    }

    // MARK: - Persistence Helpers

    private func persist() {
        do {
            let aesKey = try loadOrCreateSymmetricKey()
            try persist(using: aesKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persist(using aesKey: SymmetricKey) throws {
        let data = try encrypt(library, using: aesKey)
        try keychain.storeEncryptedLibrary(data)
    }

    /// Loads the AES symmetric key from Keychain, creating and storing one if absent.
    private func loadOrCreateSymmetricKey() throws -> SymmetricKey {
        if let data = try keychain.retrieveSymmetricKeyData() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try keychain.storeSymmetricKeyData(key.withUnsafeBytes { Data($0) })
        return key
    }

    /// AES-GCM-encrypts any Codable value to combined Data.
    private func encrypt<T: Encodable>(_ value: T, using aesKey: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let sealedBox = try AES.GCM.seal(try encoder.encode(value), using: aesKey)
        guard let combined = sealedBox.combined else { throw KeyManagerError.encryptionFailed }
        return combined
    }

    /// AES-GCM-decrypts combined Data back into a Codable value.
    private func decrypt<T: Decodable>(_ type: T.Type, from data: Data, using aesKey: SymmetricKey) throws -> T {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(sealedBox, using: aesKey)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: plaintext)
    }

    // MARK: - Label Helpers

    /// Trims a user label and caps its length; falls back when empty.
    private func cleanLabel(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback : trimmed
        return String(value.prefix(40))
    }

    /// Reduces a label to a filename-safe slug.
    private func sanitizeForFilename(_ label: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = String(label.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        let collapsed = slug.split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "decoder" : String(collapsed.prefix(32))
    }
}
