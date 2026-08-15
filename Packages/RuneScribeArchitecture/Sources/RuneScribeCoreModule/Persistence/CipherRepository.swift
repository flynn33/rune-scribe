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

struct PreparedMessageCipher: Equatable, Sendable {
    let cipher: Cipher
    let library: CipherLibrary
    let requiresPersistence: Bool
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

    /// Explicit, retryable v1 -> v2 migration. A failed seed derivation or
    /// secure write leaves the cached utility library untouched and readable.
    func migrateProgressionEvidence(
        using seeds: CoreProgressionMigrationSeedSet
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let candidate: CipherLibrary
        do {
            candidate = try current.migratingProgressionEvidence(using: seeds)
        } catch {
            throw Self.mapProgressionError(error)
        }
        guard candidate != current else {
            return CipherRepositoryMutation(value: false, library: current)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: true, library: candidate)
    }

    /// Returns only the typed token and unambiguous stored origin needed by
    /// the existing-user migration rail. Cipher IDs and seed bytes never leave
    /// this Core repository boundary.
    func progressionMigrationSnapshot(
        cipherTokensByID: [UUID: CipherToken]
    ) async throws -> CoreProgressionMigrationSnapshot {
        let current = try await snapshot()
        let ledger = try Self.progressionLedger(in: current)
        let cipherIDs = Set(current.ciphers.map(\.id))
        let seededCipherIDs = Set(ledger.cipherSeeds.map(\.cipherID))
        guard seededCipherIDs.isSubset(of: cipherIDs),
              Set(cipherTokensByID.keys) == seededCipherIDs
        else {
            throw CoreProgressionEvidenceError.operationCollision
        }
        do {
            return try CoreProgressionMigrationSnapshot(
                ciphers: current.ciphers.compactMap { cipher in
                    guard let cipherToken = cipherTokensByID[cipher.id] else {
                        return nil
                    }
                    return CoreProgressionMigrationCipher(
                        cipherToken: cipherToken,
                        origin: cipher.origin
                    )
                }
            )
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    func progressionEvidenceSnapshot() async throws -> CoreProgressionLedger {
        try Self.progressionLedger(in: try await snapshot())
    }

    func cipherProgressionSeed(cipherID: UUID) async throws -> Data? {
        try Self.progressionLedger(in: try await snapshot()).cipherSeeds.first {
            $0.cipherID == cipherID
        }?.seed
    }

    func relationshipProgressionEvidence(
        cipherID: UUID,
        contactID: UUID
    ) async throws -> CoreRelationshipProgressionRecord? {
        let identity = CoreProgressionRelationshipIdentity(
            cipherID: cipherID,
            contactID: contactID
        )
        return try Self.progressionLedger(in: try await snapshot()).relationships.first {
            $0.identity == identity
        }
    }

    func pendingProgressionBatches() async throws -> [CorePendingProgressionBatch] {
        let ledger = try Self.progressionLedger(in: try await snapshot())
        return ledger.progressionOperationOrder.flatMap { contextDigest in
            ledger.pendingBatches.filter {
                $0.identity.contextDigest == contextDigest
            }.sorted { $0.identity.batchIndex < $1.identity.batchIndex }
        }
    }

    func acknowledgedProgressionBatches() async throws
        -> [CoreAcknowledgedProgressionBatch]
    {
        let ledger = try Self.progressionLedger(in: try await snapshot())
        return ledger.progressionOperationOrder.flatMap { contextDigest in
            ledger.acknowledgedBatches.filter {
                $0.identity.contextDigest == contextDigest
            }.sorted { $0.identity.batchIndex < $1.identity.batchIndex }
        }
    }

    func encodedMessageProgressionEvidence(
        handle: EncodedMessageHandle
    ) async throws -> CoreEncodedMessageProgressionRecord? {
        try Self.progressionLedger(in: try await snapshot()).encodedMessages.first {
            $0.handle == handle
        }
    }

    func shareTerminalProgressionEvidence(
        artifactID: ShareArtifactID
    ) async throws -> CoreShareTerminalProgressionRecord? {
        try Self.progressionLedger(in: try await snapshot()).shareTerminals.first {
            $0.artifactID == artifactID
        }
    }

    func createCipher(label: String) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.legacyVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
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

    func createCipher(
        label: String,
        progressionSeed: Data,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let cipher = try await Self.generatedCipher(
            label: Self.cleanLabel(label, fallback: "New Cipher"),
            runtimeIO: runtimeIO
        )
        var candidate = current.adding(cipher)
        do {
            var ledger = try Self.progressionLedger(in: current)
            try ledger.addCipherSeed(cipherID: cipher.id, seed: progressionSeed)
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
        } catch {
            throw Self.mapProgressionError(error)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: cipher, library: candidate)
    }

    /// Capacity fallback for optional progression evidence. The domain cipher
    /// and its exact fact batches still commit atomically; only the new seed
    /// row is omitted while every previously retained row remains unchanged.
    func createCipherWithoutProgressionEvidence(
        label: String,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.currentVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
        let cipher = try await Self.generatedCipher(
            label: Self.cleanLabel(label, fallback: "New Cipher"),
            runtimeIO: runtimeIO
        )
        var candidate = current.adding(cipher)
        do {
            var ledger = try Self.progressionLedger(in: current)
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
        } catch {
            throw Self.mapProgressionError(error)
        }
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
        guard current.version == CipherLibrary.legacyVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
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

    func deleteCipher(
        id: UUID,
        replacementProgressionSeed: Data?,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let existed = current.ciphers.contains(where: { $0.id == id })
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            if existed {
                candidate.ciphers.removeAll { $0.id == id }
                if candidate.activeID == id {
                    candidate.activeID = candidate.ciphers.first?.id
                }
                try ledger.removeCipherEvidence(cipherID: id)
                if candidate.ciphers.isEmpty {
                    guard let replacementProgressionSeed else {
                        throw CoreProgressionEvidenceError.invalidSeed
                    }
                    let replacement = try await Self.generatedCipher(
                        label: "My Cipher",
                        runtimeIO: runtimeIO
                    )
                    candidate.ciphers = [replacement]
                    candidate.activeID = replacement.id
                    try ledger.addCipherSeed(
                        cipherID: replacement.id,
                        seed: replacementProgressionSeed
                    )
                }
            }
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            guard candidate != current else {
                return CipherRepositoryMutation(value: existed, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: existed, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
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
        guard current.version == CipherLibrary.legacyVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
        let existed = current.ciphers.contains(where: { $0.id == cipherID })
        let candidate = current.settingContact(cipherID: cipherID, contactID: contactID)
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: existed, library: candidate)
    }

    func assignContact(
        cipherID: UUID,
        contactID: UUID?,
        relationshipSeed: Data?,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard let cipherIndex = current.ciphers.firstIndex(where: {
            $0.id == cipherID
        }) else {
            return CipherRepositoryMutation(value: false, library: current)
        }
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            if let contactID {
                let identity = CoreProgressionRelationshipIdentity(
                    cipherID: cipherID,
                    contactID: contactID
                )
                if let relationshipIndex = ledger.relationships.firstIndex(where: {
                    $0.identity == identity
                }) {
                    let existing = ledger.relationships[relationshipIndex]
                    if let relationshipSeed, relationshipSeed != existing.seed {
                        throw CoreProgressionEvidenceError.operationCollision
                    }
                    if candidate.ciphers[cipherIndex].contactID != contactID {
                        candidate.ciphers[cipherIndex].setContactID(contactID)
                    }
                    ledger.relationships[relationshipIndex].keyDeliveryState =
                        candidate.ciphers[cipherIndex].keyDeliveryState
                } else {
                    guard let relationshipSeed else {
                        throw CoreProgressionEvidenceError.invalidSeed
                    }
                    candidate.ciphers[cipherIndex].setContactID(contactID)
                    try ledger.upsertRelationship(
                        CoreRelationshipProgressionRecord(
                            identity: identity,
                            seed: relationshipSeed,
                            keyDeliveryState: candidate.ciphers[cipherIndex].keyDeliveryState
                        )
                    )
                }
            } else {
                candidate.ciphers[cipherIndex].setContactID(nil)
            }
            try ledger.appendPending(pendingBatches)
            guard candidate != current || candidate.progressionLedger != ledger else {
                return CipherRepositoryMutation(value: true, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: true, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Binds the domain cipher when the bounded relationship collection cannot
    /// accept a new optional row. Existing relationship evidence is preserved;
    /// exact batches supplied by the caller remain durable.
    func assignContactWithoutProgressionEvidence(
        cipherID: UUID,
        contactID: UUID?,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.currentVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
        guard let cipherIndex = current.ciphers.firstIndex(where: {
            $0.id == cipherID
        }) else {
            return CipherRepositoryMutation(value: false, library: current)
        }
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            if candidate.ciphers[cipherIndex].contactID != contactID {
                candidate.ciphers[cipherIndex].setContactID(contactID)
            }
            if let contactID,
               let relationshipIndex = ledger.relationships.firstIndex(where: {
                   $0.identity == CoreProgressionRelationshipIdentity(
                       cipherID: cipherID,
                       contactID: contactID
                   )
               }) {
                ledger.relationships[relationshipIndex].keyDeliveryState =
                    candidate.ciphers[cipherIndex].keyDeliveryState
            }
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            guard candidate != current else {
                return CipherRepositoryMutation(value: true, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: true, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
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
        var candidate = current.markingDelivered(cipherID: cipherID)
        if current.version == CipherLibrary.currentVersion,
           let contactID = cipher.contactID {
            var ledger = try Self.progressionLedger(in: current)
            let identity = CoreProgressionRelationshipIdentity(
                cipherID: cipherID,
                contactID: contactID
            )
            if let relationshipIndex = ledger.relationships.firstIndex(where: {
                $0.identity == identity
            }) {
                ledger.relationships[relationshipIndex].keyDeliveryState = .completed
                candidate.progressionLedger = ledger
            }
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: true, library: candidate)
    }

    func recordRelationshipProgressionActivity(
        cipherID: UUID,
        contactID: UUID,
        completesKeyDelivery: Bool,
        commitsFirstDeliveryEvent: Bool,
        activity: CoreProgressionRelationshipActivity,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<CoreProgressionRelationshipMutationResult> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard let cipherIndex = current.ciphers.firstIndex(where: {
            $0.id == cipherID && $0.contactID == contactID
        }) else {
            throw CoreProgressionEvidenceError.operationCollision
        }
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let identity = CoreProgressionRelationshipIdentity(
                cipherID: cipherID,
                contactID: contactID
            )
            guard let relationshipIndex = ledger.relationships.firstIndex(where: {
                $0.identity == identity
            }) else {
                throw CoreProgressionEvidenceError.invalidRelationship
            }
            let wasFirstDeliveryCommitted = ledger.relationships[relationshipIndex]
                .firstDeliveryEventCommitted
            let wasBidirectional = ledger.relationships[relationshipIndex]
                .bidirectionalEventCommitted
            let firstDeliveryFactCount = pendingBatches.reduce(0) { count, pending in
                count + pending.batch.facts.filter {
                    $0.fact.eventType.rawValue
                        == "runescribe.cipher.first-delivery-completed"
                }.count
            }
            guard firstDeliveryFactCount == (commitsFirstDeliveryEvent ? 1 : 0) else {
                throw CoreProgressionEvidenceError.invalidPendingBatch
            }
            let initialKeyDeliveryState = candidate.ciphers[cipherIndex]
                .keyDeliveryState
            let keyDeliveryCanComplete = initialKeyDeliveryState.requiresDelivery
                || initialKeyDeliveryState == .migratedUnverified
            if completesKeyDelivery {
                guard keyDeliveryCanComplete else {
                    throw CoreProgressionEvidenceError.invalidRelationship
                }
                candidate.ciphers[cipherIndex].completeKeyDelivery()
                ledger.relationships[relationshipIndex].keyDeliveryState =
                    candidate.ciphers[cipherIndex].keyDeliveryState
            }
            if commitsFirstDeliveryEvent {
                guard !wasFirstDeliveryCommitted,
                      candidate.ciphers[cipherIndex].keyDeliveryState == .completed
                else {
                    throw CoreProgressionEvidenceError.invalidRelationship
                }
            }
            try ledger.relationships[relationshipIndex].record(
                eligibleOutbound: activity.eligibleOutbound,
                authenticatedInbound: activity.authenticatedInbound,
                bidirectionalCommitted: activity.bidirectionalCommitted,
                firstDeliveryCommitted: commitsFirstDeliveryEvent
            )
            if commitsFirstDeliveryEvent,
               !ledger.relationships[relationshipIndex].hasEligibleOutbound {
                throw CoreProgressionEvidenceError.invalidRelationship
            }
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            let result = CoreProgressionRelationshipMutationResult(
                keyDeliveryTransitioned: initialKeyDeliveryState != .completed
                    && candidate.ciphers[cipherIndex].keyDeliveryState == .completed,
                firstDeliveryTransitioned: !wasFirstDeliveryCommitted
                    && ledger.relationships[relationshipIndex]
                        .firstDeliveryEventCommitted,
                bidirectionalTransitioned: !wasBidirectional
                    && ledger.relationships[relationshipIndex]
                        .bidirectionalEventCommitted
            )
            guard candidate != current else {
                return CipherRepositoryMutation(value: result, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: result, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Ensures every newly imported contact has a linked cipher. All additions are
    /// committed in one encrypted-library write and never change the active cipher.
    func ensureLinkedCiphers(
        for contacts: [ImportedContactCipherSeed]
    ) async throws -> CipherRepositoryMutation<[Cipher]> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.legacyVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
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

    func ensureLinkedCiphers(
        for seeds: [CoreGeneratedContactProgressionSeed],
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<[Cipher]> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard Set(seeds.map { $0.contact.contactID }).count == seeds.count else {
            throw CoreProgressionEvidenceError.operationCollision
        }
        var candidate = current
        var added: [Cipher] = []
        do {
            var ledger = try Self.progressionLedger(in: current)
            for seed in seeds where !candidate.ciphers.contains(where: {
                $0.contactID == seed.contact.contactID
            }) {
                var cipher = try await Self.generatedCipher(
                    label: Self.cleanLabel(
                        seed.contact.displayName,
                        fallback: "Imported Cipher"
                    ),
                    runtimeIO: runtimeIO
                )
                cipher.setContactID(seed.contact.contactID)
                candidate = candidate.addingWithoutActivating(cipher)
                try ledger.addCipherSeed(cipherID: cipher.id, seed: seed.cipherSeed)
                try ledger.upsertRelationship(
                    CoreRelationshipProgressionRecord(
                        identity: CoreProgressionRelationshipIdentity(
                            cipherID: cipher.id,
                            contactID: seed.contact.contactID
                        ),
                        seed: seed.relationshipSeed,
                        keyDeliveryState: cipher.keyDeliveryState
                    )
                )
                added.append(cipher)
            }
            try ledger.appendPending(pendingBatches)
            guard !added.isEmpty || candidate.progressionLedger != ledger else {
                return CipherRepositoryMutation(value: [], library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: added, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
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
        guard current.version == CipherLibrary.legacyVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
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

    func reconcileContactAssociations(
        generatedSeeds: [CoreGeneratedContactProgressionSeed],
        validContactIDs: Set<UUID>,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<CoreProgressionContactReconciliationResult> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard Set(generatedSeeds.map { $0.contact.contactID }).count
                == generatedSeeds.count,
              generatedSeeds.allSatisfy({
                  validContactIDs.contains($0.contact.contactID)
              })
        else {
            throw CoreProgressionEvidenceError.operationCollision
        }
        var candidate = current
        var changes = 0
        var added: [Cipher] = []
        do {
            var ledger = try Self.progressionLedger(in: current)

            for index in candidate.ciphers.indices {
                if let contactID = candidate.ciphers[index].contactID,
                   !validContactIDs.contains(contactID) {
                    candidate.ciphers[index].setContactID(nil)
                    changes += 1
                }
            }

            var retainedContactIDs = Set<UUID>()
            for index in candidate.ciphers.indices {
                guard let contactID = candidate.ciphers[index].contactID else {
                    continue
                }
                if !retainedContactIDs.insert(contactID).inserted {
                    candidate.ciphers[index].setContactID(nil)
                    changes += 1
                }
            }

            for seed in generatedSeeds where !candidate.ciphers.contains(where: {
                $0.contactID == seed.contact.contactID
            }) {
                var cipher = try await Self.generatedCipher(
                    label: Self.cleanLabel(
                        seed.contact.displayName,
                        fallback: "Imported Cipher"
                    ),
                    runtimeIO: runtimeIO
                )
                cipher.setContactID(seed.contact.contactID)
                candidate = candidate.addingWithoutActivating(cipher)
                try ledger.addCipherSeed(cipherID: cipher.id, seed: seed.cipherSeed)
                try ledger.upsertRelationship(
                    CoreRelationshipProgressionRecord(
                        identity: CoreProgressionRelationshipIdentity(
                            cipherID: cipher.id,
                            contactID: seed.contact.contactID
                        ),
                        seed: seed.relationshipSeed,
                        keyDeliveryState: cipher.keyDeliveryState
                    )
                )
                changes += 1
                added.append(cipher)
            }
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            let result = CoreProgressionContactReconciliationResult(
                changes: changes,
                addedCiphers: added
            )
            guard candidate != current else {
                return CipherRepositoryMutation(value: result, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: result, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Reconciles required contact/cipher domain state after either optional
    /// seed collection reaches capacity. Existing evidence is never removed,
    /// and the caller's exact facts remain in the atomic encrypted commit.
    func reconcileContactAssociationsWithoutProgressionEvidence(
        generatedSeeds: [CoreGeneratedContactProgressionSeed],
        validContactIDs: Set<UUID>,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<CoreProgressionContactReconciliationResult> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.currentVersion,
              Set(generatedSeeds.map { $0.contact.contactID }).count
                == generatedSeeds.count,
              generatedSeeds.allSatisfy({
                  validContactIDs.contains($0.contact.contactID)
              })
        else {
            throw CoreProgressionEvidenceError.operationCollision
        }
        var candidate = current
        var changes = 0
        var added: [Cipher] = []
        do {
            var ledger = try Self.progressionLedger(in: current)
            for index in candidate.ciphers.indices {
                if let contactID = candidate.ciphers[index].contactID,
                   !validContactIDs.contains(contactID) {
                    candidate.ciphers[index].setContactID(nil)
                    changes += 1
                }
            }
            var retainedContactIDs = Set<UUID>()
            for index in candidate.ciphers.indices {
                guard let contactID = candidate.ciphers[index].contactID else {
                    continue
                }
                if !retainedContactIDs.insert(contactID).inserted {
                    candidate.ciphers[index].setContactID(nil)
                    changes += 1
                }
            }
            for seed in generatedSeeds where !candidate.ciphers.contains(where: {
                $0.contactID == seed.contact.contactID
            }) {
                var cipher = try await Self.generatedCipher(
                    label: Self.cleanLabel(
                        seed.contact.displayName,
                        fallback: "Imported Cipher"
                    ),
                    runtimeIO: runtimeIO
                )
                cipher.setContactID(seed.contact.contactID)
                candidate = candidate.addingWithoutActivating(cipher)
                changes += 1
                added.append(cipher)
            }
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            let result = CoreProgressionContactReconciliationResult(
                changes: changes,
                addedCiphers: added
            )
            guard candidate != current else {
                return CipherRepositoryMutation(value: result, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: result, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Deliberate imports append and activate, exactly like the legacy share flow.
    func importCipher(
        _ payload: CipherSharePayload,
        label: String?
    ) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.legacyVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
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

    func importCipher(
        _ payload: CipherSharePayload,
        label: String?,
        progressionSeed: Data,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        let cipher = try await Self.importedCipher(
            payload,
            label: Self.cleanLabel(label ?? "", fallback: "Imported Cipher"),
            runtimeIO: runtimeIO
        )
        var candidate = current.adding(cipher)
        do {
            var ledger = try Self.progressionLedger(in: current)
            try ledger.addCipherSeed(cipherID: cipher.id, seed: progressionSeed)
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
        } catch {
            throw Self.mapProgressionError(error)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: cipher, library: candidate)
    }

    /// Capacity fallback matching `createCipherWithoutProgressionEvidence` for
    /// deliberate imports. The imported cipher and exact event batches commit
    /// together while the full seed collection remains untouched.
    func importCipherWithoutProgressionEvidence(
        _ payload: CipherSharePayload,
        label: String?,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Cipher> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        guard current.version == CipherLibrary.currentVersion else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
        let cipher = try await Self.importedCipher(
            payload,
            label: Self.cleanLabel(label ?? "", fallback: "Imported Cipher"),
            runtimeIO: runtimeIO
        )
        var candidate = current.adding(cipher)
        do {
            var ledger = try Self.progressionLedger(in: current)
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
        } catch {
            throw Self.mapProgressionError(error)
        }
        try await persist(candidate)
        library = candidate
        return CipherRepositoryMutation(value: cipher, library: candidate)
    }

    /// Embedded-message imports deduplicate by public id and never steal the
    /// active selection. A transient result explicitly preserves the legacy
    /// best-effort decrypt path when secure persistence is unavailable.
    func prepareMessageCipher(
        _ payload: CipherSharePayload,
        label: String
    ) async throws -> PreparedMessageCipher {
        let cleanedLabel = Self.cleanLabel(label, fallback: "Imported Cipher")
        let current: CipherLibrary
        do {
            current = try await snapshot()
        } catch {
            // Preserve the established transient-decrypt behavior when the
            // encrypted library cannot be read. No mutation occurs here.
            return PreparedMessageCipher(
                cipher: try await Self.importedCipher(
                    payload,
                    label: cleanedLabel,
                    runtimeIO: runtimeIO
                ),
                library: .empty,
                requiresPersistence: true
            )
        }
        if let existing = current.ciphers.first(where: {
            $0.publicID == payload.publicID
        }) {
            return PreparedMessageCipher(
                cipher: existing,
                library: current,
                requiresPersistence: false
            )
        }
        return PreparedMessageCipher(
            cipher: try await Self.importedCipher(
                payload,
                label: cleanedLabel,
                runtimeIO: runtimeIO
            ),
            library: current,
            requiresPersistence: true
        )
    }

    /// Commits every durable consequence of an authenticated incoming message
    /// in one encrypted-library write: an optional embedded cipher, its final
    /// contact binding, relationship aggregate state, and the complete decoded
    /// event batch. A failed secure write leaves the candidate transient so
    /// authenticated plaintext remains usable without claiming a durable fact.
    func commitAuthenticatedMessageImport(
        candidate preparedCipher: Cipher,
        persistCandidate: Bool,
        contactID: UUID?,
        cipherProgressionSeed: Data?,
        relationshipProgressionSeed: Data?,
        activity: CoreProgressionRelationshipActivity,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> MessageCipherIngestionResult {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        return try await commitAuthenticatedMessageImportWithPermit(
            candidate: preparedCipher,
            persistCandidate: persistCandidate,
            contactID: contactID,
            cipherProgressionSeed: cipherProgressionSeed,
            relationshipProgressionSeed: relationshipProgressionSeed,
            activity: activity,
            pendingBatches: pendingBatches,
            retainsNewProgressionEvidence: true
        )
    }

    /// Capacity fallback for an authenticated domain import. Existing seed and
    /// relationship rows can still receive compatible activity, but no new row
    /// is added; the complete authenticated fact group remains atomic.
    func commitAuthenticatedMessageImportWithoutProgressionEvidence(
        candidate preparedCipher: Cipher,
        persistCandidate: Bool,
        contactID: UUID?,
        activity: CoreProgressionRelationshipActivity,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> MessageCipherIngestionResult {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        return try await commitAuthenticatedMessageImportWithPermit(
            candidate: preparedCipher,
            persistCandidate: persistCandidate,
            contactID: contactID,
            cipherProgressionSeed: nil,
            relationshipProgressionSeed: nil,
            activity: activity,
            pendingBatches: pendingBatches,
            retainsNewProgressionEvidence: false
        )
    }

    private func commitAuthenticatedMessageImportWithPermit(
        candidate preparedCipher: Cipher,
        persistCandidate: Bool,
        contactID: UUID?,
        cipherProgressionSeed: Data?,
        relationshipProgressionSeed: Data?,
        activity: CoreProgressionRelationshipActivity,
        pendingBatches: [CorePendingProgressionBatch],
        retainsNewProgressionEvidence: Bool
    ) async throws -> MessageCipherIngestionResult {
        do {
            let current = try await snapshot()
            var candidate = current
            var ledger = try Self.progressionLedger(in: current)
            let cipherIndex: Int
            let persistedNewCipher: Bool

            if let existingIndex = current.ciphers.firstIndex(where: {
                $0.publicID == preparedCipher.publicID
            }) {
                cipherIndex = existingIndex
                persistedNewCipher = false
            } else {
                guard persistCandidate else {
                    throw CoreProgressionEvidenceError.invalidCipherSeed
                }
                candidate = current.addingWithoutActivating(preparedCipher)
                guard let addedIndex = candidate.ciphers.firstIndex(where: {
                    $0.id == preparedCipher.id
                }) else {
                    throw CoreProgressionEvidenceError.operationCollision
                }
                cipherIndex = addedIndex
                persistedNewCipher = true
                if retainsNewProgressionEvidence {
                    guard let cipherProgressionSeed else {
                        throw CoreProgressionEvidenceError.invalidCipherSeed
                    }
                    try ledger.addCipherSeed(
                        cipherID: preparedCipher.id,
                        seed: cipherProgressionSeed
                    )
                }
            }

            let committedCipherID = candidate.ciphers[cipherIndex].id
            if let contactID {
                let identity = CoreProgressionRelationshipIdentity(
                    cipherID: committedCipherID,
                    contactID: contactID
                )
                if candidate.ciphers[cipherIndex].contactID != contactID {
                    candidate.ciphers[cipherIndex].setContactID(contactID)
                }
                let relationshipIndex: Int?
                if let existingIndex = ledger.relationships.firstIndex(where: {
                    $0.identity == identity
                }) {
                    if let relationshipProgressionSeed,
                       relationshipProgressionSeed
                        != ledger.relationships[existingIndex].seed {
                        throw CoreProgressionEvidenceError.operationCollision
                    }
                    relationshipIndex = existingIndex
                    ledger.relationships[existingIndex].keyDeliveryState =
                        candidate.ciphers[cipherIndex].keyDeliveryState
                } else if retainsNewProgressionEvidence {
                    guard let relationshipProgressionSeed else {
                        throw CoreProgressionEvidenceError.invalidSeed
                    }
                    try ledger.upsertRelationship(
                        CoreRelationshipProgressionRecord(
                            identity: identity,
                            seed: relationshipProgressionSeed,
                            keyDeliveryState: candidate.ciphers[cipherIndex]
                                .keyDeliveryState
                        )
                    )
                    guard let insertedIndex = ledger.relationships.firstIndex(where: {
                        $0.identity == identity
                    }) else {
                        throw CoreProgressionEvidenceError.invalidRelationship
                    }
                    relationshipIndex = insertedIndex
                } else {
                    relationshipIndex = nil
                }
                if let relationshipIndex {
                    try ledger.relationships[relationshipIndex].record(
                        eligibleOutbound: activity.eligibleOutbound,
                        authenticatedInbound: activity.authenticatedInbound,
                        bidirectionalCommitted: activity.bidirectionalCommitted
                    )
                }
            } else if activity.eligibleOutbound || activity.bidirectionalCommitted {
                throw CoreProgressionEvidenceError.invalidRelationship
            }

            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            if candidate != current {
                do {
                    try await persist(candidate)
                    library = candidate
                } catch let error as CipherRepositoryError {
                    return .transient(cipher: preparedCipher, failure: error)
                }
            }
            let committedCipher = candidate.ciphers[cipherIndex]
            return persistedNewCipher
                ? .persisted(cipher: committedCipher, library: candidate)
                : .existing(cipher: committedCipher, library: candidate)
        } catch let error as CipherRepositoryError {
            return .transient(cipher: preparedCipher, failure: error)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

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

    func ingestMessageCipher(
        _ payload: CipherSharePayload,
        label: String,
        progressionSeed: Data?,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> MessageCipherIngestionResult {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let cleanedLabel = Self.cleanLabel(label, fallback: "Imported Cipher")
        do {
            let current = try await snapshot()
            var ledger = try Self.progressionLedger(in: current)
            if let existing = current.ciphers.first(where: {
                $0.publicID == payload.publicID
            }) {
                var candidate = current
                try ledger.appendPending(pendingBatches)
                guard ledger != current.progressionLedger else {
                    return .existing(cipher: existing, library: current)
                }
                candidate.progressionLedger = ledger
                try candidate.validateStoredShape()
                do {
                    try await persist(candidate)
                    library = candidate
                    return .existing(cipher: existing, library: candidate)
                } catch let error as CipherRepositoryError {
                    return .transient(cipher: existing, failure: error)
                }
            }

            guard let progressionSeed else {
                throw CoreProgressionEvidenceError.invalidSeed
            }
            let cipher = try await Self.importedCipher(
                payload,
                label: cleanedLabel,
                runtimeIO: runtimeIO
            )
            var candidate = current.addingWithoutActivating(cipher)
            try ledger.addCipherSeed(cipherID: cipher.id, seed: progressionSeed)
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            do {
                try await persist(candidate)
                library = candidate
                return .persisted(cipher: cipher, library: candidate)
            } catch let error as CipherRepositoryError {
                return .transient(cipher: cipher, failure: error)
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
            return .transient(cipher: cipher, failure: .corruptedLibrary)
        }
    }

    /// Commits ephemeral encode evidence and its event batches before a
    /// successful encoded result is reported. The encrypted message itself is
    /// not retained here; only a digest, opaque handle, token, and presentation
    /// identifiers are stored.
    func commitEncodedMessageProgressionEvidence(
        _ record: CoreEncodedMessageProgressionRecord,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let contextDigest = try CoreProgressionDigest.canonical(
                record.originatingContext
            )
            guard pendingBatches.allSatisfy({
                $0.identity.contextDigest == contextDigest
            }) else {
                throw CoreProgressionEvidenceError.invalidEncodedMessage
            }
            let existed = ledger.encodedMessages.contains { $0.handle == record.handle }
            try ledger.addEncodedMessage(record)
            try ledger.appendPending(pendingBatches)
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            guard candidate != current else {
                return CipherRepositoryMutation(value: false, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: !existed, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    func appendPendingProgressionBatches(
        _ pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<Int> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let before = ledger.pendingBatches.count + ledger.acknowledgedBatches.count
            try ledger.appendPending(pendingBatches)
            let after = ledger.pendingBatches.count + ledger.acknowledgedBatches.count
            guard ledger != current.progressionLedger else {
                return CipherRepositoryMutation(value: 0, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: after - before, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    func abandonEncodedMessageProgressionEvidence(
        handle: EncodedMessageHandle
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let removed = ledger.removeEncodedMessage(handle: handle)
            guard removed else {
                return CipherRepositoryMutation(value: false, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: true, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Persists the runtime receipt but deliberately retains the exact facts.
    /// The caller must acknowledge the receipt back to Runtime before invoking
    /// `clearAcknowledgedProgressionBatch`.
    func recordProgressionBatchReceipt(
        context: RuntimePersistableOperationContext,
        receipt: ProgressionOutboxBatchReceipt
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let changed = try ledger.acknowledge(context: context, receipt: receipt)
            guard changed else {
                return CipherRepositoryMutation(value: false, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: true, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    func clearAcknowledgedProgressionBatch(
        context: RuntimePersistableOperationContext,
        receipt: ProgressionOutboxBatchReceipt
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let changed = try ledger.clearAcknowledgement(
                context: context,
                receipt: receipt
            )
            guard changed else {
                return CipherRepositoryMutation(value: false, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: true, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    func recontextualizePendingProgressionBatches(
        from sourceContextDigest: CoreProgressionDigest,
        to replacementContext: RuntimePersistableOperationContext
    ) async throws -> CipherRepositoryMutation<Int> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let count = try ledger.recontextualizePendingBatches(
                from: sourceContextDigest,
                to: replacementContext
            )
            guard count > 0 else {
                return CipherRepositoryMutation(value: 0, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: count, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Atomically journals a terminal share result, relationship transitions,
    /// exact progression batches, and encoded-handle retirement. Artifact
    /// cleanup is a later idempotent step gated by `cleanupPending`.
    func commitShareTerminalProgression(
        artifactID: ShareArtifactID,
        context: RuntimePersistableOperationContext,
        commandDigest: CoreProgressionDigest,
        resultDigest: CoreProgressionDigest,
        encodedMessageHandle: EncodedMessageHandle?,
        cipherID: UUID?,
        contactID: UUID?,
        completesKeyDelivery: Bool,
        commitsFirstDeliveryEvent: Bool,
        activity: CoreProgressionRelationshipActivity,
        pendingBatches: [CorePendingProgressionBatch]
    ) async throws -> CipherRepositoryMutation<CoreProgressionTerminalMutationResult> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            var keyDeliveryTransitioned = false
            var firstDeliveryTransitioned = false
            var bidirectionalTransitioned = false
            let terminalContextDigest = try CoreProgressionDigest.canonical(context)
            guard pendingBatches.allSatisfy({
                $0.identity.contextDigest == terminalContextDigest
            }) else {
                throw CoreProgressionEvidenceError.invalidShareTerminal
            }
            let firstDeliveryFactCount = pendingBatches.reduce(0) { count, pending in
                count + pending.batch.facts.filter {
                    $0.fact.eventType.rawValue
                        == "runescribe.cipher.first-delivery-completed"
                }.count
            }
            guard firstDeliveryFactCount == (commitsFirstDeliveryEvent ? 1 : 0) else {
                throw CoreProgressionEvidenceError.invalidShareTerminal
            }

            switch (cipherID, contactID) {
            case (.some(let cipherID), .some(let contactID)):
                guard let cipherIndex = candidate.ciphers.firstIndex(where: {
                    $0.id == cipherID && $0.contactID == contactID
                }) else {
                    throw CoreProgressionEvidenceError.invalidRelationship
                }
                let identity = CoreProgressionRelationshipIdentity(
                    cipherID: cipherID,
                    contactID: contactID
                )
                let relationshipIndex = ledger.relationships.firstIndex(where: {
                    $0.identity == identity
                })
                let initialKeyDeliveryState = candidate.ciphers[cipherIndex]
                    .keyDeliveryState
                let keyDeliveryCanComplete = initialKeyDeliveryState.requiresDelivery
                    || initialKeyDeliveryState == .migratedUnverified
                if completesKeyDelivery {
                    guard keyDeliveryCanComplete else {
                        throw CoreProgressionEvidenceError.invalidRelationship
                    }
                    candidate.ciphers[cipherIndex].completeKeyDelivery()
                    if let relationshipIndex {
                        ledger.relationships[relationshipIndex].keyDeliveryState =
                            candidate.ciphers[cipherIndex].keyDeliveryState
                    }
                    keyDeliveryTransitioned = true
                }
                if let relationshipIndex {
                    let wasFirstDeliveryCommitted = ledger.relationships[
                        relationshipIndex
                    ].firstDeliveryEventCommitted
                    let wasBidirectional = ledger.relationships[relationshipIndex]
                        .bidirectionalEventCommitted
                    if commitsFirstDeliveryEvent {
                        guard !wasFirstDeliveryCommitted,
                              candidate.ciphers[cipherIndex].keyDeliveryState
                                == .completed
                        else {
                            throw CoreProgressionEvidenceError.invalidRelationship
                        }
                    }
                    try ledger.relationships[relationshipIndex].record(
                        eligibleOutbound: activity.eligibleOutbound,
                        authenticatedInbound: activity.authenticatedInbound,
                        bidirectionalCommitted: activity.bidirectionalCommitted,
                        firstDeliveryCommitted: commitsFirstDeliveryEvent
                    )
                    if commitsFirstDeliveryEvent,
                       !ledger.relationships[relationshipIndex].hasEligibleOutbound {
                        throw CoreProgressionEvidenceError.invalidRelationship
                    }
                    firstDeliveryTransitioned = !wasFirstDeliveryCommitted
                        && ledger.relationships[relationshipIndex]
                            .firstDeliveryEventCommitted
                    bidirectionalTransitioned = !wasBidirectional
                        && ledger.relationships[relationshipIndex]
                            .bidirectionalEventCommitted
                } else {
                    guard !commitsFirstDeliveryEvent,
                          !activity.eligibleOutbound,
                          !activity.authenticatedInbound,
                          !activity.bidirectionalCommitted
                    else {
                        throw CoreProgressionEvidenceError.invalidRelationship
                    }
                }
            case (.none, .none):
                guard !completesKeyDelivery,
                      !commitsFirstDeliveryEvent,
                      !activity.eligibleOutbound,
                      !activity.authenticatedInbound,
                      !activity.bidirectionalCommitted
                else {
                    throw CoreProgressionEvidenceError.invalidRelationship
                }
            default:
                throw CoreProgressionEvidenceError.invalidRelationship
            }

            if let encodedMessageHandle,
               !ledger.encodedMessages.contains(where: {
                   $0.handle == encodedMessageHandle
               }), !ledger.shareTerminals.contains(where: {
                   $0.artifactID == artifactID
                    && $0.encodedMessageHandle == encodedMessageHandle
               }) {
                throw CoreProgressionEvidenceError.invalidEncodedMessage
            }
            try ledger.appendPending(pendingBatches)
            let terminal = try CoreShareTerminalProgressionRecord(
                artifactID: artifactID,
                context: context,
                commandDigest: commandDigest,
                resultDigest: resultDigest,
                encodedMessageHandle: encodedMessageHandle,
                progressionBatches: pendingBatches.map(\.identity).sorted()
            )
            let inserted = try ledger.addShareTerminal(terminal)
            if inserted, let encodedMessageHandle {
                guard ledger.removeEncodedMessage(handle: encodedMessageHandle) else {
                    throw CoreProgressionEvidenceError.invalidEncodedMessage
                }
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            let result = CoreProgressionTerminalMutationResult(
                inserted: inserted,
                keyDeliveryTransitioned: keyDeliveryTransitioned,
                firstDeliveryTransitioned: firstDeliveryTransitioned,
                bidirectionalTransitioned: bidirectionalTransitioned
            )
            guard candidate != current else {
                return CipherRepositoryMutation(value: result, library: current)
            }
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: result, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    func markShareTerminalCleanupComplete(
        artifactID: ShareArtifactID
    ) async throws -> CipherRepositoryMutation<Bool> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let changed = try ledger.markShareCleanupComplete(artifactID: artifactID)
            guard changed else {
                return CipherRepositoryMutation(value: false, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: true, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    /// Retention is explicit: only terminal tombstones already marked cleanup-
    /// complete and named by the owning coordinator may be removed.
    func retireShareTerminalEvidence(
        artifactIDs: Set<ShareArtifactID>
    ) async throws -> CipherRepositoryMutation<Int> {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let current = try await snapshot()
        var candidate = current
        do {
            var ledger = try Self.progressionLedger(in: current)
            let removed = try ledger.retireShareTerminals(artifactIDs: artifactIDs)
            guard removed > 0 else {
                return CipherRepositoryMutation(value: 0, library: current)
            }
            candidate.progressionLedger = ledger
            try candidate.validateStoredShape()
            try await persist(candidate)
            library = candidate
            return CipherRepositoryMutation(value: removed, library: candidate)
        } catch {
            throw Self.mapProgressionError(error)
        }
    }

    // MARK: - Loading and persistence

    private static func progressionLedger(
        in library: CipherLibrary
    ) throws -> CoreProgressionLedger {
        do {
            return try library.validatedProgressionLedger()
        } catch {
            throw mapProgressionError(error)
        }
    }

    private static func mapProgressionError(_ error: Error) -> Error {
        error
    }

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

        guard loadedLibrary.version == CipherLibrary.legacyVersion
                || loadedLibrary.version == CipherLibrary.currentVersion
        else {
            throw CipherRepositoryError.unsupportedLibraryVersion(loadedLibrary.version)
        }
        do {
            try loadedLibrary.validateStoredShape()
        } catch let error as CipherLibraryValidationError {
            if case .unsupportedVersion(let version) = error {
                throw CipherRepositoryError.unsupportedLibraryVersion(version)
            }
            throw CipherRepositoryError.corruptedLibrary
        } catch {
            throw CipherRepositoryError.corruptedLibrary
        }

        if loadedLibrary.ciphers.isEmpty {
            guard loadedLibrary.version == CipherLibrary.legacyVersion else {
                throw CipherRepositoryError.corruptedLibrary
            }
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
        do {
            try library.validateStoredShape()
        } catch {
            throw CipherRepositoryError.encryptionFailed
        }
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

        do {
            try await setSecureData(
                encrypted,
                runtimeIO: runtimeIO,
                account: RuneScribeKeychain.cipherLibraryAccount
            )
        } catch {
            // A secure-store error may be reported after the value became durable.
            // Authenticate and decode the physical value before deciding whether
            // the atomic candidate committed; never trust ciphertext equality.
            if let stored = try? await secureData(
                runtimeIO,
                account: RuneScribeKeychain.cipherLibraryAccount
            ), let decoded = try? decryptLibrary(stored, using: key),
               decoded == library {
                return
            }
            throw CipherRepositoryError.secureStorageUnavailable
        }
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
