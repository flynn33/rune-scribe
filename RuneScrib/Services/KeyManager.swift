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

/// Owns the user's cipher library: a list of labelled `Cipher`s plus the active
/// selection. The whole library is persisted AES-GCM-encrypted in the Keychain.
/// One symmetric AES key (also in the Keychain) protects it.
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
    var ciphers: [Cipher] { library.ciphers }

    /// The active cipher, used as the default when composing a message.
    var activeCipher: Cipher? { library.activeCipher }

    // MARK: - Private Dependencies

    private let keychain = KeychainService.shared

    // MARK: - Init

    private init() {
        Task { await load() }
    }

    // MARK: - Load

    /// Loads the cipher library from the Keychain, guaranteeing at least one cipher
    /// exists on first launch.
    func load() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            let aesKey = try loadOrCreateSymmetricKey()

            if let data = try keychain.retrieveEncryptedLibrary() {
                library = try decrypt(CipherLibrary.self, from: data, using: aesKey)
            }

            if library.ciphers.isEmpty {
                let first = Cipher.generated(label: "My Cipher")
                library = CipherLibrary(ciphers: [first], activeID: first.id)
                try persist(using: aesKey)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Mutations

    /// Creates a new random cipher, appends it, and makes it active.
    @discardableResult
    func addCipher(label: String) -> Cipher? {
        let cipher = Cipher.generated(label: cleanLabel(label, fallback: "New Cipher"))
        library = library.adding(cipher)
        persist()
        return lastError == nil ? cipher : nil
    }

    /// Imports a shared cipher (from a deep link, QR code, file, or clipboard) as a
    /// new cipher, appends it, and makes it active.
    @discardableResult
    func importCipher(_ payload: CipherSharePayload, label: String?) throws -> Cipher {
        let cipher = payload.cipher(label: cleanLabel(label ?? "", fallback: "Imported Cipher"))
        let aesKey = try loadOrCreateSymmetricKey()
        library = library.adding(cipher)
        try persist(using: aesKey)
        lastError = nil
        return cipher
    }

    /// Imports a cipher from a file-form package (compact payload + optional font bytes).
    /// Validates and stores the font; requires the font to be present (supplied in the file, or
    /// already local) before the cipher is added.
    @discardableResult
    func importCipher(fileData data: Data, label: String?) throws -> Cipher {
        let (payload, fontBytes) = try CipherSharePayload.decodeFile(data)
        if let fontBytes {
            try FontStore.shared.importFont(fontBytes, expecting: payload.fontRef)
        } else if FontStore.shared.resolve(payload.fontRef) == nil {
            throw FontStoreError.unreadableFont
        }
        return try importCipher(payload, label: label)
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

    /// Selects the active cipher used as the default when composing.
    func setActive(id: UUID) {
        library = library.settingActive(id: id)
        persist()
    }

    /// Links (or clears, with nil) a cipher's contact. Never changes key material.
    func setContact(cipherID: UUID, contactID: UUID?) {
        library = library.settingContact(cipherID: cipherID, contactID: contactID)
        persist()
    }

    /// Clears the link on every cipher of a contact (used when the contact is deleted). Keeps ciphers.
    func unlinkContact(_ contactID: UUID) {
        library = library.unlinkingContact(contactID: contactID)
        persist()
    }

    /// Marks the cipher with `cipherID` as having had its key delivered, then persists.
    /// Idempotent and never touches key material. Called by the send flow after a message
    /// that embedded this cipher's key has been handed off to Messages.
    func markDelivered(cipherID: UUID) {
        library = library.markingDelivered(cipherID: cipherID)
        persist()
    }

    /// The ciphers currently linked to `contactID`.
    func ciphers(forContact contactID: UUID) -> [Cipher] { library.ciphers.filter { $0.contactID == contactID } }

    /// Ensures an imported contact has at least one linked cipher, generating and linking one
    /// (without changing the active selection) when it has none. Returns the new cipher, or
    /// `nil` when the contact already has a linked cipher. Import-only by design.
    @discardableResult
    func ensureLinkedCipher(forImportedContact contact: Contact) -> Cipher? {
        guard ciphers(forContact: contact.id).isEmpty else { return nil }
        var cipher = Cipher.generated(label: cleanLabel(contact.displayName, fallback: "Imported Cipher"))
        cipher.contactID = contact.id
        library = library.addingWithoutActivating(cipher)
        persist()
        return cipher
    }

    // MARK: - Export / Share

    /// The self-contained file-form package for the given cipher: the compact payload plus the
    /// cipher's font bytes, so a recipient who lacks the font still receives it.
    func exportData(for id: UUID) throws -> Data {
        guard let cipher = library.ciphers.first(where: { $0.id == id }) else {
            throw KeyManagerError.noKeyAvailable
        }
        let fontBytes = FontStore.shared.fontData(for: cipher.fontRef) ?? Data()
        return CipherSharePayload(cipher: cipher).encodedFile(fontBytes: fontBytes)
    }

    /// The `runescribe://import` share URL for the given cipher (QR / deep-link form).
    func shareURL(for id: UUID, name: String?) throws -> URL {
        guard let cipher = library.ciphers.first(where: { $0.id == id }) else {
            throw KeyManagerError.noKeyAvailable
        }
        return try CipherSharePayload(cipher: cipher).url(name: name)
    }

    /// Suggested filename (without extension) for the given cipher's share file.
    func exportFilename(for id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let cipher = library.ciphers.first(where: { $0.id == id })
        let base = cipher.map { sanitizeForFilename($0.label) } ?? "cipher"
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
        return collapsed.isEmpty ? "cipher" : String(collapsed.prefix(32))
    }
}
