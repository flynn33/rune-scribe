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
        case .encryptionFailed: return "Failed to encrypt the cipher mapping."
        case .decryptionFailed: return "Failed to decrypt the cipher mapping."
        case .noKeyAvailable:   return "No cipher key is currently loaded."
        }
    }
}

// MARK: - KeyManager

/// Manages the full lifecycle of the cipher key: load from Keychain, generate on
/// first launch, rotate, export (as a single decoder file), and import a decoder
/// used to decode incoming rune messages.
///
/// Published as a singleton and injected as an @EnvironmentObject. All published
/// property mutations occur on the main actor.
@MainActor
final class KeyManager: ObservableObject {

    // MARK: - Singleton

    static let shared = KeyManager()

    // MARK: - Published State

    /// The device's own key, used to encode plain text into runes.
    @Published private(set) var currentKey: RuneKey?
    /// A decoder imported from a file, used to decode pasted rune messages.
    @Published private(set) var importedDecoder: ImportedDecoder?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Private Dependencies

    private let keychain = KeychainService.shared

    // MARK: - Init

    private init() {
        Task { await loadOrCreateKey() }
    }

    // MARK: - Load or Create

    /// Loads the existing cipher key (and any imported decoder) from Keychain.
    /// On first launch, generates a new random key and stores it.
    func loadOrCreateKey() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let aesKey = try loadOrCreateSymmetricKey()

            if let encryptedMapping = try keychain.retrieveEncryptedMapping() {
                currentKey = try decrypt(RuneKey.self, from: encryptedMapping, using: aesKey)
            } else {
                try generateAndStoreNewKey(using: aesKey)
            }

            if let encryptedDecoder = try keychain.retrieveEncryptedDecoder() {
                importedDecoder = try? decrypt(ImportedDecoder.self, from: encryptedDecoder, using: aesKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Rotate Key

    /// Generates a new random cipher mapping and stores it, overwriting the
    /// previous one. The AES key is preserved.
    ///
    /// ⚠️ After rotation, any previously encoded messages are permanently undecodable.
    func rotateKey() async throws {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        let aesKey = try loadOrCreateSymmetricKey()
        try generateAndStoreNewKey(using: aesKey)
    }

    // MARK: - Export (single decoder file)

    /// Builds the single decoder/decrypter file (JSON) for the current key. This
    /// one file contains the full mapping + reverse mapping and is what the app
    /// imports and what AI models read to decode.
    func decoderExportData() throws -> Data {
        guard let key = currentKey else { throw KeyManagerError.noKeyAvailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(RuneKeyExport.from(key))
    }

    /// Suggested filename (without extension) for the exported decoder file.
    var decoderExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stamp = currentKey.map { formatter.string(from: $0.createdAt) } ?? "key"
        return "RuneScrib-Decoder-\(stamp)"
    }

    // MARK: - Import decoder

    /// Imports a decoder file and makes it the active decoder for decoding pasted
    /// rune messages. Validated on parse and persisted (encrypted) in Keychain so
    /// it survives relaunch.
    @discardableResult
    func importDecoder(data: Data) throws -> ImportedDecoder {
        let decoder = try ImportedDecoder.parse(data)
        importedDecoder = decoder

        // Best-effort persistence — the import still works in-memory if this fails.
        if let aesData = try? keychain.retrieveSymmetricKeyData() {
            let aesKey = SymmetricKey(data: aesData)
            if let encrypted = try? encrypt(decoder, using: aesKey) {
                try? keychain.storeEncryptedDecoder(encrypted)
            }
        }
        return decoder
    }

    /// Removes the active imported decoder.
    func clearImportedDecoder() {
        importedDecoder = nil
        try? keychain.deleteImportedDecoder()
    }

    // MARK: - Private Helpers

    /// Loads the AES symmetric key from Keychain, creating and storing one if absent.
    private func loadOrCreateSymmetricKey() throws -> SymmetricKey {
        if let data = try keychain.retrieveSymmetricKeyData() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try keychain.storeSymmetricKeyData(key.withUnsafeBytes { Data($0) })
        return key
    }

    /// Generates a new random RuneKey, encrypts it, persists it, and publishes it.
    private func generateAndStoreNewKey(using aesKey: SymmetricKey) throws {
        let newKey = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let encrypted = try encrypt(newKey, using: aesKey)
        try keychain.storeEncryptedMapping(encrypted)
        currentKey = newKey
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
}
