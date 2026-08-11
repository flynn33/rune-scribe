import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum CipherRepositoryError: Error, Equatable, Sendable {
    case secureStorageUnavailable
    case invalidSymmetricKey
    case corruptedLibrary
    case unsupportedLibraryVersion(Int)
    case encryptionFailed
}

struct CipherRepositoryMutation<Value: Sendable>: Sendable {
    let value: Value
    let library: CipherLibrary
}

enum MessageCipherIngestionResult: Equatable, Sendable {
    case existing(cipher: Cipher, library: CipherLibrary)
    case persisted(cipher: Cipher, library: CipherLibrary)
    case transient(cipher: Cipher, failure: CipherRepositoryError)
}

struct ImportedContactCipherSeed: Equatable, Sendable {
    let contactID: UUID
    let displayName: String
}

/// Owns the encrypted cipher library and serializes every read-modify-write cycle.
/// Key-bearing values never leave the Core target.
actor CipherRepository {
    private struct LoadedState: Sendable {
        let keyData: Data
        let library: CipherLibrary
    }

    private struct Initialization {
        let id: UInt64
        let task: Task<LoadedState, Error>
    }

    private let runtimeIO: RuntimeIOClient

    private var library: CipherLibrary?
    private var symmetricKey: SymmetricKey?
    private var initialization: Initialization?
    private var nextInitializationID: UInt64 = 0

    // Actors are reentrant at suspension points. This permit keeps a complete
    // read-modify-write cycle linear even while the secure store is awaited.
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(runtimeIO: RuntimeIOClient) {
        self.runtimeIO = runtimeIO
    }

    /// Loads the shipping Keychain representation, creating and persisting one
    /// generated cipher only when the stored library is absent or empty.
    func snapshot() async throws -> CipherLibrary {
        if let library {
            return library
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

    func createCipher(label: String) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let cipher = try await Self.generatedCipher(
            label: Self.cleanLabel(label, fallback: "New Cipher"),
            runtimeIO: runtimeIO
        )
        let candidate = current.adding(cipher)
        // The secure write is the commit point. Never publish or cache an
        // unsaved candidate as application state when persistence fails.
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: cipher, library: candidate)
    }

    func renameCipher(
        id: UUID,
        label: String
    ) async throws -> CipherRepositoryMutation<Cipher?> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard let existing = current.ciphers.first(where: { $0.id == id }) else {
            return CipherRepositoryMutation(value: nil, library: current)
        }

        let candidate = current.renamingCipher(
            id: id,
            to: Self.cleanLabel(label, fallback: existing.label)
        )
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(
            value: candidate.ciphers.first(where: { $0.id == id }),
            library: candidate
        )
    }

    /// Deletion is idempotent, matching the legacy repository. Deleting the last
    /// cipher generates and activates a fresh `My Cipher` through injected seams.
    func deleteCipher(id: UUID) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let existed = current.ciphers.contains(where: { $0.id == id })
        var candidate = current
        candidate.ciphers.removeAll { $0.id == id }
        if candidate.activeID == id {
            candidate.activeID = candidate.ciphers.first?.id
        }
        if candidate.ciphers.isEmpty {
            let replacement = try await Self.generatedCipher(
                label: "My Cipher",
                runtimeIO: runtimeIO
            )
            candidate = CipherLibrary(ciphers: [replacement], activeID: replacement.id)
        }

        // The legacy path persisted even when the id was already absent.
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: existed, library: candidate)
    }

    func setActiveCipher(id: UUID) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let existed = current.ciphers.contains(where: { $0.id == id })
        let candidate = current.settingActive(id: id)
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: existed, library: candidate)
    }

    func assignContact(
        cipherID: UUID,
        contactID: UUID?
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let existed = current.ciphers.contains(where: { $0.id == cipherID })
        let candidate = current.settingContact(cipherID: cipherID, contactID: contactID)
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: existed, library: candidate)
    }

    /// Idempotently records successful first-delivery handoff without changing
    /// the key, contact association, active selection, or any other cipher.
    func markDelivered(cipherID: UUID) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard let cipher = current.ciphers.first(where: { $0.id == cipherID }) else {
            return CipherRepositoryMutation(value: false, library: current)
        }
        guard !cipher.delivered else {
            return CipherRepositoryMutation(value: true, library: current)
        }
        let candidate = current.markingDelivered(cipherID: cipherID)
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: true, library: candidate)
    }

    /// Ensures every newly imported contact has a linked cipher. All additions are
    /// committed in one encrypted-library write and never change the active cipher.
    func ensureLinkedCiphers(
        for contacts: [ImportedContactCipherSeed]
    ) async throws -> CipherRepositoryMutation<[Cipher]> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        var added: [Cipher] = []
        for contact in contacts where !candidate.ciphers.contains(where: {
            $0.contactID == contact.contactID
        }) {
            var cipher = try await Self.generatedCipher(
                label: Self.cleanLabel(contact.displayName, fallback: "Imported Cipher"),
                runtimeIO: runtimeIO
            )
            cipher.setContactID(contact.contactID)
            candidate = candidate.addingWithoutActivating(cipher)
            added.append(cipher)
        }
        guard !added.isEmpty else {
            return CipherRepositoryMutation(value: [], library: current)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: added, library: candidate)
    }

    /// Clears every association in one encrypted-library write. Delivery state is
    /// intentionally preserved so unlinking or reassignment never resets history.
    func unlinkContacts(
        _ contactIDs: Set<UUID>
    ) async throws -> CipherRepositoryMutation<Int> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard !contactIDs.isEmpty else {
            return CipherRepositoryMutation(value: 0, library: current)
        }
        let linkedCount = current.ciphers.filter { cipher in
            cipher.contactID.map(contactIDs.contains) ?? false
        }.count
        guard linkedCount > 0 else {
            return CipherRepositoryMutation(value: 0, library: current)
        }
        let candidate = contactIDs.reduce(current) { library, contactID in
            library.unlinkingContact(contactID: contactID)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: linkedCount, library: candidate)
    }

    /// Repairs cross-store contact/cipher invariants from one library snapshot and
    /// one encrypted commit. Active selection, keys, and delivery history survive.
    func reconcileContactAssociations(
        systemImportedSeeds: [ImportedContactCipherSeed],
        validContactIDs: Set<UUID>
    ) async throws -> CipherRepositoryMutation<Int> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        var changes = 0

        for index in candidate.ciphers.indices {
            if let contactID = candidate.ciphers[index].contactID,
               !validContactIDs.contains(contactID) {
                candidate.ciphers[index].setContactID(nil)
                changes += 1
            }
        }

        var processed = Set<UUID>()
        for seed in systemImportedSeeds where processed.insert(seed.contactID).inserted {
            let linked = candidate.ciphers.indices.filter {
                candidate.ciphers[$0].contactID == seed.contactID
            }
            if linked.isEmpty {
                var cipher = try await Self.generatedCipher(
                    label: Self.cleanLabel(seed.displayName, fallback: "Imported Cipher"),
                    runtimeIO: runtimeIO
                )
                cipher.setContactID(seed.contactID)
                candidate = candidate.addingWithoutActivating(cipher)
                changes += 1
            } else if linked.count > 1 {
                for index in linked.dropFirst() {
                    candidate.ciphers[index].setContactID(nil)
                    changes += 1
                }
            }
        }

        guard candidate != current else {
            return CipherRepositoryMutation(value: 0, library: current)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: changes, library: candidate)
    }

    /// Deliberate imports append and activate, exactly like the legacy share flow.
    func importCipher(
        _ payload: CipherSharePayload,
        label: String?
    ) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let cipher = try await Self.importedCipher(
            payload,
            label: Self.cleanLabel(label ?? "", fallback: "Imported Cipher"),
            runtimeIO: runtimeIO
        )
        let candidate = current.adding(cipher)
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: cipher, library: candidate)
    }

    /// Embedded-message imports deduplicate by public id and never steal the
    /// active selection. A transient result explicitly preserves the legacy
    /// best-effort decrypt path when secure persistence is unavailable.
    func ingestMessageCipher(
        _ payload: CipherSharePayload,
        label: String
    ) async throws -> MessageCipherIngestionResult {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let cleanedLabel = Self.cleanLabel(label, fallback: "Imported Cipher")
        do {
            let current = try await snapshot()
            if let existing = current.ciphers.first(where: { $0.publicID == payload.publicID }) {
                return .existing(cipher: existing, library: current)
            }

            let cipher = try await Self.importedCipher(
                payload,
                label: cleanedLabel,
                runtimeIO: runtimeIO
            )
            let candidate = current.addingWithoutActivating(cipher)
            do {
                try await persist(candidate)
                library = candidate
                return .persisted(cipher: cipher, library: candidate)
            } catch let error as CipherRepositoryError {
                return .transient(cipher: cipher, failure: error)
            } catch {
                return .transient(cipher: cipher, failure: .secureStorageUnavailable)
            }
        } catch let error as CipherRepositoryError {
            let cipher = try await Self.importedCipher(
                payload,
                label: cleanedLabel,
                runtimeIO: runtimeIO
            )
            return .transient(cipher: cipher, failure: error)
        } catch {
            let cipher = try await Self.importedCipher(
                payload,
                label: cleanedLabel,
                runtimeIO: runtimeIO
            )
            return .transient(cipher: cipher, failure: .secureStorageUnavailable)
        }
    }

    // MARK: - Loading and persistence

    private func finishLoading(_ initialization: Initialization) async throws -> CipherLibrary {
        do {
            let state = try await initialization.task.value
            if self.initialization?.id == initialization.id {
                symmetricKey = SymmetricKey(data: state.keyData)
                library = state.library
                self.initialization = nil
            }
            return state.library
        } catch {
            if self.initialization?.id == initialization.id {
                self.initialization = nil
            }
            throw error
        }
    }

    private static func loadState(
        runtimeIO: RuntimeIOClient
    ) async throws -> LoadedState {
        let keyData: Data
        if let storedKey = try await secureData(
            runtimeIO,
            account: RuneScribeKeychain.symmetricKeyAccount
        ) {
            guard storedKey.count == 32 else {
                throw CipherRepositoryError.invalidSymmetricKey
            }
            keyData = storedKey
        } else {
            keyData = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            try await setSecureData(
                keyData,
                runtimeIO: runtimeIO,
                account: RuneScribeKeychain.symmetricKeyAccount
            )
        }

        let key = SymmetricKey(data: keyData)
        var loadedLibrary: CipherLibrary = .empty
        if let encrypted = try await secureData(
            runtimeIO,
            account: RuneScribeKeychain.cipherLibraryAccount
        ) {
            loadedLibrary = try decryptLibrary(encrypted, using: key)
        }

        guard loadedLibrary.version == 1 else {
            throw CipherRepositoryError.unsupportedLibraryVersion(loadedLibrary.version)
        }

        if loadedLibrary.ciphers.isEmpty {
            let first = try await generatedCipher(
                label: "My Cipher",
                runtimeIO: runtimeIO
            )
            loadedLibrary = CipherLibrary(ciphers: [first], activeID: first.id)
            try await writeLibrary(
                loadedLibrary,
                using: key,
                runtimeIO: runtimeIO
            )
        }

        return LoadedState(keyData: keyData, library: loadedLibrary)
    }

    private func persist(_ library: CipherLibrary) async throws {
        guard let symmetricKey else {
            throw CipherRepositoryError.invalidSymmetricKey
        }
        try await Self.writeLibrary(
            library,
            using: symmetricKey,
            runtimeIO: runtimeIO
        )
    }

    private static func writeLibrary(
        _ library: CipherLibrary,
        using key: SymmetricKey,
        runtimeIO: RuntimeIOClient
    ) async throws {
        let encoded: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoded = try encoder.encode(library)
        } catch {
            throw CipherRepositoryError.encryptionFailed
        }

        let encrypted: Data
        do {
            let box = try AES.GCM.seal(encoded, using: key)
            guard let combined = box.combined else {
                throw CipherRepositoryError.encryptionFailed
            }
            encrypted = combined
        } catch let error as CipherRepositoryError {
            throw error
        } catch {
            throw CipherRepositoryError.encryptionFailed
        }

        try await setSecureData(
            encrypted,
            runtimeIO: runtimeIO,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
    }

    private static func decryptLibrary(
        _ encrypted: Data,
        using key: SymmetricKey
    ) throws -> CipherLibrary {
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: key)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CipherLibrary.self, from: plaintext)
        } catch {
            throw CipherRepositoryError.corruptedLibrary
        }
    }

    private static func secureData(
        _ runtimeIO: RuntimeIOClient,
        account: String
    ) async throws -> Data? {
        do {
            return try await runtimeIO.secureValueData(
                service: RuneScribeKeychain.service,
                account: account
            )
        } catch {
            throw CipherRepositoryError.secureStorageUnavailable
        }
    }

    private static func setSecureData(
        _ data: Data,
        runtimeIO: RuntimeIOClient,
        account: String
    ) async throws {
        do {
            try await runtimeIO.setSecureValue(
                data,
                service: RuneScribeKeychain.service,
                account: account
            )
        } catch {
            throw CipherRepositoryError.secureStorageUnavailable
        }
    }

    // MARK: - Mutation serialization

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

    // MARK: - Cipher construction

    private static func generatedCipher(
        label: String,
        runtimeIO: RuntimeIOClient
    ) async throws -> Cipher {
        var random = SystemRandomNumberGenerator()
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let publicID = Data((0..<8).map { _ in
            UInt8.random(in: .min ... .max, using: &random)
        })
        let mapping = Array(0..<32).shuffled(using: &random)
        return Cipher(
            id: try await runtimeIO.nextUUID(),
            label: label,
            origin: .generated,
            createdAt: try await runtimeIO.now(),
            publicID: publicID,
            keyMaterial: key,
            decorativeMapping: mapping
        )
    }

    private static func importedCipher(
        _ payload: CipherSharePayload,
        label: String,
        runtimeIO: RuntimeIOClient
    ) async throws -> Cipher {
        Cipher(
            id: try await runtimeIO.nextUUID(),
            label: label,
            origin: .imported,
            createdAt: try await runtimeIO.now(),
            publicID: payload.publicID,
            keyMaterial: payload.keyMaterial,
            decorativeMapping: payload.decorativeMapping,
            fontRef: payload.fontRef
        )
    }

    private static func cleanLabel(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback : trimmed
        return String(value.prefix(40))
    }
}
