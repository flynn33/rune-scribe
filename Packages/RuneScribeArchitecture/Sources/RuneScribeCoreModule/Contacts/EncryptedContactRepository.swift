import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ContactRepositoryError: Error, Equatable, Sendable {
    case secureStorageUnavailable
    case protectedStorageUnavailable
    case missingSymmetricKey
    case invalidSymmetricKey
    case corruptedStore
    case unsupportedStoreVersion(Int)
    case encryptionFailed
}

/// Owns the shipping AES-GCM `contacts.enc` representation. The repository
/// deliberately never creates the shared symmetric key: cipher initialization
/// is the single authority that creates and persists that key.
actor EncryptedContactRepository {
    static let maximumContactBookPlaintextByteCount = 4 * 1_024 * 1_024
    static let maximumContactBookEncryptedByteCount =
        maximumContactBookPlaintextByteCount + 28
    static let maximumAssociationIntentPlaintextByteCount = 4 * 1_024
    static let maximumAssociationIntentEncryptedByteCount =
        maximumAssociationIntentPlaintextByteCount + 28

    private struct LoadedState: Sendable {
        let book: ContactBook
        let keyData: Data?
    }

    private struct Initialization {
        let id: UInt64
        let task: Task<LoadedState, Error>
    }

    private let runtimeIO: RuntimeIOClient

    private var cachedBook: ContactBook?
    private var symmetricKey: SymmetricKey?
    private var initialization: Initialization?
    private var nextInitializationID: UInt64 = 0

    // A complete read-validate-encrypt-write cycle must remain serialized even
    // though the injected stores suspend at actor boundaries.
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(runtimeIO: RuntimeIOClient) {
        self.runtimeIO = runtimeIO
    }

    func snapshot() async throws -> ContactBook {
        if let cachedBook {
            return cachedBook
        }
        if let initialization {
            return try await finishLoading(initialization)
        }

        let runtimeIO = runtimeIO
        let task = Task<LoadedState, Error> {
            try await Self.loadState(runtimeIO: runtimeIO)
        }
        let initialization = Initialization(id: nextInitializationID, task: task)
        nextInitializationID &+= 1
        self.initialization = initialization
        return try await finishLoading(initialization)
    }

    func messageAssociationIntent() async throws -> MessageContactAssociationIntent? {
        let path = try Self.messageAssociationIntentPath()
        let encrypted: Data?
        do {
            encrypted = try await runtimeIO.readProtectedFile(
                path,
                maximumByteCount: Self.maximumAssociationIntentEncryptedByteCount
            )
        } catch ProtectedFileStoreReadError.contentTooLarge {
            throw ContactRepositoryError.corruptedStore
        } catch {
            throw ContactRepositoryError.protectedStorageUnavailable
        }
        guard let encrypted else { return nil }

        let key = try await loadSymmetricKeyIfNeeded()
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: key)
            guard plaintext.count <= Self.maximumAssociationIntentPlaintextByteCount else {
                throw ContactRepositoryError.corruptedStore
            }
            let intent = try JSONDecoder().decode(
                MessageContactAssociationIntent.self,
                from: plaintext
            )
            guard intent.version == MessageContactAssociationIntent.currentVersion else {
                throw ContactRepositoryError.unsupportedStoreVersion(intent.version)
            }
            return intent
        } catch let error as ContactRepositoryError {
            throw error
        } catch {
            throw ContactRepositoryError.corruptedStore
        }
    }

    func storeMessageAssociationIntent(
        _ intent: MessageContactAssociationIntent
    ) async throws {
        guard intent.version == MessageContactAssociationIntent.currentVersion else {
            throw ContactRepositoryError.unsupportedStoreVersion(intent.version)
        }
        let key = try await loadSymmetricKeyIfNeeded()
        let encrypted: Data
        do {
            let plaintext = try JSONEncoder().encode(intent)
            guard plaintext.count <= Self.maximumAssociationIntentPlaintextByteCount else {
                throw ContactRepositoryError.encryptionFailed
            }
            let box = try AES.GCM.seal(plaintext, using: key)
            guard let combined = box.combined else {
                throw ContactRepositoryError.encryptionFailed
            }
            guard combined.count <= Self.maximumAssociationIntentEncryptedByteCount else {
                throw ContactRepositoryError.encryptionFailed
            }
            encrypted = combined
        } catch let error as ContactRepositoryError {
            throw error
        } catch {
            throw ContactRepositoryError.encryptionFailed
        }

        do {
            try await runtimeIO.writeProtectedFile(
                encrypted,
                path: try Self.messageAssociationIntentPath()
            )
        } catch {
            // Atomic replacement may have reached disk before the adapter
            // surfaced an error. An authenticated re-read resolves ambiguity.
            if (try? await messageAssociationIntent()) == intent {
                return
            }
            if let error = error as? ContactRepositoryError {
                throw error
            }
            throw ContactRepositoryError.protectedStorageUnavailable
        }
        guard try await messageAssociationIntent() == intent else {
            throw ContactRepositoryError.corruptedStore
        }
    }

    func removeMessageAssociationIntent() async throws {
        do {
            try await runtimeIO.removeProtectedFile(
                try Self.messageAssociationIntentPath()
            )
        } catch {
            do {
                if try await messageAssociationIntent() == nil {
                    return
                }
            } catch let verificationError as ContactRepositoryError {
                throw verificationError
            } catch {
                throw ContactRepositoryError.protectedStorageUnavailable
            }
            if let error = error as? ContactRepositoryError {
                throw error
            }
            throw ContactRepositoryError.protectedStorageUnavailable
        }
    }

    /// Persists a complete schema-v1 book. Loading first prevents an unreadable
    /// existing store from being silently overwritten by a new empty snapshot.
    @discardableResult
    func replace(_ book: ContactBook) async throws -> ContactBook {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        guard book.version == ContactBook.currentVersion else {
            throw ContactRepositoryError.unsupportedStoreVersion(book.version)
        }
        _ = try await snapshot()
        let key = try await loadSymmetricKeyIfNeeded()
        let encrypted = try Self.encrypt(book, using: key)

        do {
            try await runtimeIO.writeProtectedFile(encrypted, path: .contacts)
        } catch {
            // A storage implementation may report failure after an atomic
            // replacement reached disk. Discard the cached pre-write snapshot
            // so reconciliation observes whichever version is authoritative.
            cachedBook = nil
            throw ContactRepositoryError.protectedStorageUnavailable
        }

        cachedBook = book
        return book
    }

    private func finishLoading(_ initialization: Initialization) async throws -> ContactBook {
        do {
            let state = try await initialization.task.value
            if self.initialization?.id == initialization.id {
                cachedBook = state.book
                symmetricKey = state.keyData.map(SymmetricKey.init(data:))
                self.initialization = nil
            }
            return state.book
        } catch {
            if self.initialization?.id == initialization.id {
                self.initialization = nil
            }
            throw error
        }
    }

    private static func loadState(runtimeIO: RuntimeIOClient) async throws -> LoadedState {
        let encrypted: Data?
        do {
            encrypted = try await runtimeIO.readProtectedFile(
                .contacts,
                maximumByteCount: Self.maximumContactBookEncryptedByteCount
            )
        } catch ProtectedFileStoreReadError.contentTooLarge {
            throw ContactRepositoryError.corruptedStore
        } catch {
            throw ContactRepositoryError.protectedStorageUnavailable
        }

        guard let encrypted else {
            return LoadedState(book: .empty, keyData: nil)
        }

        let keyData = try await readSymmetricKey(from: runtimeIO)
        let book = try decrypt(encrypted, using: SymmetricKey(data: keyData))
        return LoadedState(book: book, keyData: keyData)
    }

    private func loadSymmetricKeyIfNeeded() async throws -> SymmetricKey {
        if let symmetricKey {
            return symmetricKey
        }
        let keyData = try await Self.readSymmetricKey(from: runtimeIO)
        let key = SymmetricKey(data: keyData)
        symmetricKey = key
        return key
    }

    private static func readSymmetricKey(from runtimeIO: RuntimeIOClient) async throws -> Data {
        let stored: Data?
        do {
            stored = try await runtimeIO.secureValueData(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.symmetricKeyAccount
            )
        } catch {
            throw ContactRepositoryError.secureStorageUnavailable
        }
        guard let stored else {
            throw ContactRepositoryError.missingSymmetricKey
        }
        guard stored.count == 32 else {
            throw ContactRepositoryError.invalidSymmetricKey
        }
        return stored
    }

    private static func encrypt(_ book: ContactBook, using key: SymmetricKey) throws -> Data {
        do {
            try book.validatePersistenceBounds()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .deferredToDate
            let plaintext = try encoder.encode(book)
            guard plaintext.count <= Self.maximumContactBookPlaintextByteCount else {
                throw ContactRepositoryError.encryptionFailed
            }
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else {
                throw ContactRepositoryError.encryptionFailed
            }
            guard combined.count <= Self.maximumContactBookEncryptedByteCount else {
                throw ContactRepositoryError.encryptionFailed
            }
            return combined
        } catch let error as ContactRepositoryError {
            throw error
        } catch {
            throw ContactRepositoryError.encryptionFailed
        }
    }

    private static func decrypt(_ encrypted: Data, using key: SymmetricKey) throws -> ContactBook {
        do {
            guard encrypted.count <= Self.maximumContactBookEncryptedByteCount else {
                throw ContactRepositoryError.corruptedStore
            }
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard plaintext.count <= Self.maximumContactBookPlaintextByteCount else {
                throw ContactRepositoryError.corruptedStore
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .deferredToDate
            return try decoder.decode(ContactBook.self, from: plaintext)
        } catch let error as ContactBookValidationError {
            switch error {
            case .unsupportedVersion(let version):
                throw ContactRepositoryError.unsupportedStoreVersion(version)
            case .tooManyContacts,
                 .tooManyPhoneNumbers,
                 .tooManyEmailAddresses,
                 .displayNameTooLong,
                 .phoneNumberTooLong,
                 .emailAddressTooLong,
                 .appleContactIDTooLong:
                throw ContactRepositoryError.corruptedStore
            }
        } catch {
            throw ContactRepositoryError.corruptedStore
        }
    }

    private static func messageAssociationIntentPath() throws -> ProtectedPath {
        do {
            return try ProtectedPath(
                validating: "RuneScribContacts/message-contact-association.enc"
            )
        } catch {
            throw ContactRepositoryError.protectedStorageUnavailable
        }
    }

    private func acquireMutationPermit() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationPermit() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}
