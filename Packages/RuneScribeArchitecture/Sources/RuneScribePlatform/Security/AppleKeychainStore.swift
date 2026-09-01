import Foundation
import RuneScribeContracts
import Security

public enum AppleKeychainStoreError: Error, Equatable, LocalizedError, Sendable {
    case storeFailed(OSStatus)
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedDataFormat
    case migrationVerificationFailed

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
        case .migrationVerificationFailed:
            "Keychain migration verification failed."
        }
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Unknown error"
    }
}

/// The concrete generic-password Keychain adapter used by the application hosts.
///
/// Writes update existing items in place so a failed replacement cannot destroy
/// the prior value. New items use the `whenUnlockedThisDeviceOnly` accessibility
/// class, and updates reassert that same protection.
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
            let data = try verifiedDataProtectionValue(result)
#if os(macOS)
            try deleteLegacyValueIfPresent(service: service, account: account)
#endif
            return data
        case errSecItemNotFound:
#if os(macOS)
            return try migrateLegacyValueIfNeeded(service: service, account: account)
#else
            return nil
#endif
        default:
            throw AppleKeychainStoreError.retrieveFailed(result.status)
        }
    }

    public func set(_ data: Data, service: String, account: String) async throws {
        let accessibility = KeychainAccessibility.whenUnlockedThisDeviceOnly
        let updateStatus = operations.update(
            data: data,
            service: service,
            account: account,
            accessibility: accessibility
        )
        switch updateStatus {
        case errSecSuccess:
#if os(macOS)
            try deleteLegacyValueIfPresent(service: service, account: account)
#endif
            return
        case errSecItemNotFound:
            break
        default:
            throw AppleKeychainStoreError.storeFailed(updateStatus)
        }

#if os(macOS)
        if try migrateLegacyValueIfNeeded(service: service, account: account) != nil {
            let migratedUpdateStatus = operations.update(
                data: data,
                service: service,
                account: account,
                accessibility: accessibility
            )
            guard migratedUpdateStatus == errSecSuccess else {
                throw AppleKeychainStoreError.storeFailed(migratedUpdateStatus)
            }
            return
        }
#endif

        let addStatus = operations.add(
            data: data,
            service: service,
            account: account,
            accessibility: accessibility
        )
        guard addStatus == errSecSuccess else {
            throw AppleKeychainStoreError.storeFailed(addStatus)
        }
    }

    public func delete(service: String, account: String) async throws {
#if os(macOS)
        try deleteLegacyValueIfPresent(service: service, account: account)
#endif
        let status = operations.delete(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleKeychainStoreError.deleteFailed(status)
        }
    }

    private func verifiedDataProtectionValue(_ result: KeychainReadResult) throws -> Data {
        guard let data = result.data else {
            throw AppleKeychainStoreError.unexpectedDataFormat
        }
        guard result.accessibility == .whenUnlockedThisDeviceOnly else {
            throw AppleKeychainStoreError.migrationVerificationFailed
        }
        return data
    }

#if os(macOS)
    private func deleteLegacyValueIfPresent(
        service: String,
        account: String
    ) throws {
        let status = operations.deleteLegacy(service: service, account: account)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppleKeychainStoreError.deleteFailed(status)
        }
    }

    private func migrateLegacyValueIfNeeded(
        service: String,
        account: String
    ) throws -> Data? {
        let legacyResult = operations.readLegacy(service: service, account: account)
        switch legacyResult.status {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            break
        default:
            throw AppleKeychainStoreError.retrieveFailed(legacyResult.status)
        }
        guard let legacyData = legacyResult.data else {
            throw AppleKeychainStoreError.unexpectedDataFormat
        }

        let addStatus = operations.add(
            data: legacyData,
            service: service,
            account: account,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw AppleKeychainStoreError.storeFailed(addStatus)
        }

        let verification = operations.read(service: service, account: account)
        guard verification.status == errSecSuccess,
              verification.data == legacyData,
              verification.accessibility == .whenUnlockedThisDeviceOnly
        else {
            throw AppleKeychainStoreError.migrationVerificationFailed
        }

        let deleteStatus = operations.deleteLegacy(service: service, account: account)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw AppleKeychainStoreError.deleteFailed(deleteStatus)
        }
        return legacyData
    }
#endif
}

enum KeychainAccessibility: Equatable, Sendable {
    case whenUnlockedThisDeviceOnly
}

protocol KeychainOperations: Sendable {
    func update(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus
    func add(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus
    func read(service: String, account: String) -> KeychainReadResult
    func delete(service: String, account: String) -> OSStatus
    func readLegacy(service: String, account: String) -> KeychainReadResult
    func deleteLegacy(service: String, account: String) -> OSStatus
}

struct KeychainReadResult: Equatable, Sendable {
    let status: OSStatus
    let data: Data?
    let accessibility: KeychainAccessibility?
}

enum AppleKeychainQueryBuilder {
    static func dataProtectionItem(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
#if os(macOS)
        // macOS applies kSecAttrAccessible only to Data Protection Keychain items.
        query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
#endif
        return query
    }

    static func legacyItem(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private struct SecurityKeychainOperations: KeychainOperations {
    func update(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus {
        let query = AppleKeychainQueryBuilder.dataProtectionItem(
            service: service,
            account: account
        )
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: securityValue(for: accessibility),
        ]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func add(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus {
        var query = AppleKeychainQueryBuilder.dataProtectionItem(
            service: service,
            account: account
        )
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = securityValue(for: accessibility)
        return SecItemAdd(query as CFDictionary, nil)
    }

    func read(service: String, account: String) -> KeychainReadResult {
        read(
            query: AppleKeychainQueryBuilder.dataProtectionItem(
                service: service,
                account: account
            )
        )
    }

    func readLegacy(service: String, account: String) -> KeychainReadResult {
#if os(macOS)
        read(query: AppleKeychainQueryBuilder.legacyItem(service: service, account: account))
#else
        KeychainReadResult(status: errSecItemNotFound, data: nil, accessibility: nil)
#endif
    }

    private func read(query baseQuery: [String: Any]) -> KeychainReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecReturnAttributes as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let values = result as? [String: Any]
        else {
            return KeychainReadResult(status: status, data: nil, accessibility: nil)
        }
        let accessibility: KeychainAccessibility? = if
            values[kSecAttrAccessible as String] as? String
                == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        {
            .whenUnlockedThisDeviceOnly
        } else {
            nil
        }
        return KeychainReadResult(
            status: status,
            data: values[kSecValueData as String] as? Data,
            accessibility: accessibility
        )
    }

    func delete(service: String, account: String) -> OSStatus {
        let query = AppleKeychainQueryBuilder.dataProtectionItem(
            service: service,
            account: account
        )
        return SecItemDelete(query as CFDictionary)
    }

    func deleteLegacy(service: String, account: String) -> OSStatus {
#if os(macOS)
        let query = AppleKeychainQueryBuilder.legacyItem(service: service, account: account)
        return SecItemDelete(query as CFDictionary)
#else
        errSecItemNotFound
#endif
    }

    private func securityValue(for accessibility: KeychainAccessibility) -> CFString {
        switch accessibility {
        case .whenUnlockedThisDeviceOnly:
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }
    }
}
