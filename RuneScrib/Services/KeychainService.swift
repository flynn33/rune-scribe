// RuneScrib/Services/KeychainService.swift

import Foundation
import Security

// MARK: - Error Type

enum KeychainError: Error, LocalizedError {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedDataFormat

    var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Keychain store failed (OSStatus \(status)): \(secErrorMessage(status))"
        case .retrieveFailed(let status):
            return "Keychain retrieve failed (OSStatus \(status)): \(secErrorMessage(status))"
        case .deleteFailed(let status):
            return "Keychain delete failed (OSStatus \(status)): \(secErrorMessage(status))"
        case .unexpectedDataFormat:
            return "Keychain returned data in an unexpected format."
        }
    }

    private func secErrorMessage(_ status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
    }
}

// MARK: - KeychainService

/// Low-level Keychain read/write service.
/// All data stored under service "com.runescribe.keystore".
/// Two accounts are used: "symmetricKey" and "cipherMapping".
///
/// `Sendable`: this type is `final` and holds only immutable `let` properties,
/// wrapping thread-safe Security-framework calls — so the shared singleton is
/// concurrency-safe under Swift 6 strict checking.
final class KeychainService: Sendable {

    // MARK: - Singleton

    static let shared = KeychainService()
    private init() {}

    // MARK: - Constants

    private let service = "com.runescribe.keystore"
    private let symmetricKeyAccount = "symmetricKey"
    private let cipherMappingAccount = "cipherMapping"
    private let importedDecoderAccount = "importedDecoder"

    // MARK: - Generic Store / Retrieve

    /// Stores arbitrary Data in the Keychain under the given account.
    /// If an item already exists, it is deleted and replaced.
    private func store(data: Data, account: String) throws {
        // Build base query
        let deleteQuery: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account
        ]
        // Delete any existing item (ignore errSecItemNotFound)
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw KeychainError.deleteFailed(deleteStatus)
        }

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String:           kSecClassGenericPassword,
            kSecAttrService as String:     service,
            kSecAttrAccount as String:     account,
            kSecValueData as String:       data,
            kSecAttrAccessible as String:  kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.storeFailed(addStatus)
        }
    }

    /// Deletes any item stored under the given account (no-op if absent).
    private func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Retrieves Data stored under the given account.
    /// Returns nil if the item does not exist.
    private func retrieve(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  kCFBooleanTrue!,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedDataFormat
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.retrieveFailed(status)
        }
    }

    // MARK: - Public API: Symmetric Key

    /// Stores the raw bytes of the AES-256 SymmetricKey in Keychain.
    func storeSymmetricKeyData(_ data: Data) throws {
        try store(data: data, account: symmetricKeyAccount)
    }

    /// Retrieves the raw bytes of the AES-256 SymmetricKey from Keychain.
    /// Returns nil if no key has been stored yet.
    func retrieveSymmetricKeyData() throws -> Data? {
        try retrieve(account: symmetricKeyAccount)
    }

    // MARK: - Public API: Cipher Mapping

    /// Stores the AES-GCM–encrypted cipher mapping (combined Data) in Keychain.
    func storeEncryptedMapping(_ data: Data) throws {
        try store(data: data, account: cipherMappingAccount)
    }

    /// Retrieves the AES-GCM–encrypted cipher mapping from Keychain.
    /// Returns nil if no mapping has been stored yet.
    func retrieveEncryptedMapping() throws -> Data? {
        try retrieve(account: cipherMappingAccount)
    }

    // MARK: - Public API: Imported Decoder

    /// Stores the AES-GCM–encrypted imported decoder (combined Data) in Keychain.
    func storeEncryptedDecoder(_ data: Data) throws {
        try store(data: data, account: importedDecoderAccount)
    }

    /// Retrieves the AES-GCM–encrypted imported decoder from Keychain.
    /// Returns nil if none has been imported.
    func retrieveEncryptedDecoder() throws -> Data? {
        try retrieve(account: importedDecoderAccount)
    }

    /// Removes the imported decoder from Keychain.
    func deleteImportedDecoder() throws {
        try delete(account: importedDecoderAccount)
    }
}
