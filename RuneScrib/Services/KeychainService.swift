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
    private let cipherLibraryAccount = "cipherLibrary"
    private let pinAccount = "appPin"
    private let pinThrottleAccount = "pinThrottle"

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

    // MARK: - Public API: Cipher Library

    /// Stores the AES-GCM–encrypted cipher library (all labelled ciphers + active id).
    func storeEncryptedLibrary(_ data: Data) throws {
        try store(data: data, account: cipherLibraryAccount)
    }

    /// Retrieves the AES-GCM–encrypted cipher library, or nil if none stored yet.
    func retrieveEncryptedLibrary() throws -> Data? {
        try retrieve(account: cipherLibraryAccount)
    }

    // MARK: - Public API: App-Lock PIN

    /// Stores the salted-hash PIN record (already non-reversible; Keychain adds
    /// at-rest protection). Replaces any existing record.
    func storePINRecord(_ data: Data) throws {
        try store(data: data, account: pinAccount)
    }

    /// Retrieves the salted-hash PIN record, or nil if no PIN is set.
    func retrievePINRecord() throws -> Data? {
        try retrieve(account: pinAccount)
    }

    /// Removes the PIN record (disables the app lock).
    func deletePINRecord() throws {
        try delete(account: pinAccount)
    }

    // MARK: - Public API: PIN Throttle State

    /// Stores the failed-attempt throttle record so the lockout survives relaunch.
    func storePINThrottle(_ data: Data) throws {
        try store(data: data, account: pinThrottleAccount)
    }

    /// Retrieves the throttle record, or nil if there have been no failures.
    func retrievePINThrottle() throws -> Data? {
        try retrieve(account: pinThrottleAccount)
    }

    /// Clears the throttle record (on successful unlock or PIN disable).
    func deletePINThrottle() throws {
        try delete(account: pinThrottleAccount)
    }
}
