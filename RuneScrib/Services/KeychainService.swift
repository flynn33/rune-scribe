import Foundation
import os
import RuneScribeContracts
import RuneScribePlatform

/// Transitional app-target facade for the legacy synchronous repositories.
/// Security framework access lives exclusively in `AppleKeychainStore`; this
/// facade is removed when the repositories move into the Core module.
final class KeychainService: Sendable {
    private final class MemoryStore: Sendable {
        private let values = OSAllocatedUnfairLock(initialState: [String: Data]())

        func set(_ data: Data, account: String) {
            values.withLock { $0[account] = data }
        }

        func data(account: String) -> Data? {
            values.withLock { $0[account] }
        }

        func remove(account: String) {
            _ = values.withLock { $0.removeValue(forKey: account) }
        }
    }

    static let shared = KeychainService()

    private let store = AppleKeychainStore()
    private let memoryStore: MemoryStore?

    private init() {
        memoryStore = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? nil
            : MemoryStore()
    }

    func storeSymmetricKeyData(_ data: Data) throws {
        try set(data, account: RuneScribeKeychain.symmetricKeyAccount)
    }

    func retrieveSymmetricKeyData() throws -> Data? {
        try value(account: RuneScribeKeychain.symmetricKeyAccount)
    }

    func storeEncryptedLibrary(_ data: Data) throws {
        try set(data, account: RuneScribeKeychain.cipherLibraryAccount)
    }

    func retrieveEncryptedLibrary() throws -> Data? {
        try value(account: RuneScribeKeychain.cipherLibraryAccount)
    }

    func storePINRecord(_ data: Data) throws {
        try set(data, account: RuneScribeKeychain.appPINAccount)
    }

    func retrievePINRecord() throws -> Data? {
        try value(account: RuneScribeKeychain.appPINAccount)
    }

    func deletePINRecord() throws {
        try remove(account: RuneScribeKeychain.appPINAccount)
    }

    func storePINThrottle(_ data: Data) throws {
        try set(data, account: RuneScribeKeychain.pinThrottleAccount)
    }

    func retrievePINThrottle() throws -> Data? {
        try value(account: RuneScribeKeychain.pinThrottleAccount)
    }

    func deletePINThrottle() throws {
        try remove(account: RuneScribeKeychain.pinThrottleAccount)
    }

    private func set(_ data: Data, account: String) throws {
        if let memoryStore {
            memoryStore.set(data, account: account)
        } else {
            try store.setSynchronously(
                data,
                service: RuneScribeKeychain.service,
                account: account
            )
        }
    }

    private func value(account: String) throws -> Data? {
        if let memoryStore {
            return memoryStore.data(account: account)
        }
        return try store.dataSynchronously(
            service: RuneScribeKeychain.service,
            account: account
        )
    }

    private func remove(account: String) throws {
        if let memoryStore {
            memoryStore.remove(account: account)
        } else {
            try store.deleteSynchronously(
                service: RuneScribeKeychain.service,
                account: account
            )
        }
    }
}
