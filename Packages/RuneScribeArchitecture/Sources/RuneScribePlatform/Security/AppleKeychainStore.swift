import Foundation
import RuneScribeContracts
import Security

public enum AppleKeychainStoreError: Error, Equatable, LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedDataFormat

    public var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            "Keychain store failed (OSStatus \(status)): \(Self.message(for: status))"
        case .retrieveFailed(let status):
            "Keychain retrieve failed (OSStatus \(status)): \(Self.message(for: status))"
        case .deleteFailed(let status):
            "Keychain delete failed (OSStatus \(status)): \(Self.message(for: status))"
        case .unexpectedDataFormat:
            "Keychain returned data in an unexpected format."
        }
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
    }
}

/// The concrete generic-password Keychain adapter used by the application hosts.
///
/// Writes intentionally retain the shipping delete-then-add behavior and the
/// `whenUnlockedThisDeviceOnly` accessibility class.
public struct AppleKeychainStore: SecureValueStore, Sendable {
    private let operations: any KeychainOperations

    public init() {
        operations = SecurityKeychainOperations()
    }

    init(operations: any KeychainOperations) {
        self.operations = operations
    }

    public func data(service: String, account: String) async throws -> Data? {
        let result = operations.read(service: service, account: account)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data else {
                throw AppleKeychainStoreError.unexpectedDataFormat
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw AppleKeychainStoreError.retrieveFailed(result.status)
        }
    }

    public func set(_ data: Data, service: String, account: String) async throws {
        let deleteStatus = operations.delete(service: service, account: account)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw AppleKeychainStoreError.deleteFailed(deleteStatus)
        }

        let addStatus = operations.add(
            data: data,
            service: service,
            account: account,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        guard addStatus == errSecSuccess else {
            throw AppleKeychainStoreError.storeFailed(addStatus)
        }
    }

    public func delete(service: String, account: String) async throws {
        let status = operations.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleKeychainStoreError.deleteFailed(status)
        }
    }
}

enum KeychainAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

protocol KeychainOperations: Sendable {
    func add(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus
    func read(service: String, account: String) -> (status: OSStatus, data: Data?)
    func delete(service: String, account: String) -> OSStatus
}

private struct SecurityKeychainOperations: KeychainOperations {
    func add(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus {
        let accessibleValue: CFString
        switch accessibility {
        case .whenUnlockedThisDeviceOnly:
            accessibleValue = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibleValue,
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
