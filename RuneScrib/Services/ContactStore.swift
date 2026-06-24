import Foundation
import CryptoKit

/// Persists the `ContactBook` AES-GCM-encrypted in a file in app-support, using the same
/// Keychain-held symmetric key as the cipher library. The key and directory are injectable so
/// the encrypted round-trip is unit-testable without touching the Keychain or app-support.
///
/// `@unchecked Sendable`: stored state is immutable (`let` key + `let` directory). In production
/// all I/O is driven by the `@MainActor` `ContactManager`, so `save()`/`load()` are serialized on
/// the main actor and never race.
final class ContactStore: @unchecked Sendable {
    static let shared = ContactStore()

    private let injectedKey: SymmetricKey?
    private let directory: URL?

    init(key: SymmetricKey? = nil, directory: URL? = nil) {
        self.injectedKey = key
        self.directory = directory
    }

    /// Decrypts the stored book, or `.empty` if the file is absent or unreadable (missing,
    /// wrong key, or corrupt).
    ///
    /// - Important: A returned `.empty` can mean either "no contacts yet" or "the existing file
    ///   could not be decrypted". Callers MUST NOT immediately `save()` over an `.empty` result
    ///   unless they know the file was genuinely absent, or they risk overwriting real (but
    ///   temporarily unreadable) contact data.
    func load() -> ContactBook {
        guard let data = try? Data(contentsOf: fileURL),
              let key = try? symmetricKey(),
              let book = try? decrypt(ContactBook.self, from: data, using: key)
        else { return .empty }
        return book
    }

    /// AES-GCM-encrypts and writes the book atomically.
    func save(_ book: ContactBook) throws {
        let url = fileURL
        let key = try symmetricKey()
        let data = try encrypt(book, using: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    // MARK: helpers

    private var fileURL: URL {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RuneScribContacts", isDirectory: true)
        return base.appendingPathComponent("contacts.enc")
    }

    private func symmetricKey() throws -> SymmetricKey {
        if let injectedKey { return injectedKey }
        if let data = try KeychainService.shared.retrieveSymmetricKeyData() { return SymmetricKey(data: data) }
        let key = SymmetricKey(size: .bits256)
        try KeychainService.shared.storeSymmetricKeyData(key.withUnsafeBytes { Data($0) })
        return key
    }

    private func encrypt<T: Encodable>(_ value: T, using key: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .deferredToDate
        let box = try AES.GCM.seal(try encoder.encode(value), using: key)
        guard let combined = box.combined else { throw KeyManagerError.encryptionFailed }
        return combined
    }

    private func decrypt<T: Decodable>(_ type: T.Type, from data: Data, using key: SymmetricKey) throws -> T {
        let box = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(box, using: key)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .deferredToDate
        return try decoder.decode(T.self, from: plaintext)
    }
}
