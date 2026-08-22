// RuneScrib/Models/CipherLibrary.swift

import Foundation

enum CipherLibraryValidationError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidVersionShape
    case tooManyCiphers
    case duplicateCipher
    case invalidActiveCipher
    case progressionEvidenceRequired
    case progressionMigrationSeedMismatch
}

/// The persisted collection of the user's labelled ciphers, plus which one is
/// active. Stored AES-GCM-encrypted in the Keychain (account `cipherLibrary`).
/// Library order is the user's order — new ciphers are appended.
struct CipherLibrary: Codable, Equatable, Sendable {

    /// Schema version, so the stored format can evolve safely.
    static let legacyVersion = 1
    static let currentVersion = 2
    /// The identifier-free legacy message format requires a bounded try-all
    /// decode. Keep storage and both decode paths on the same finite contract.
    /// This includes the established 65,539-cipher sparse-progression case plus
    /// bounded headroom without admitting a library that no message can decode.
    static let maximumCipherCount = 65_568

    var version: Int

    /// All ciphers the user has created or imported.
    var ciphers: [Cipher]

    /// The id of the active cipher (the default used when composing a message).
    var activeID: UUID?

    /// PRG-3 evidence remains separate from `Cipher`, preserving the frozen v2
    /// cipher wire representation and all explicit cipher-share payloads.
    var progressionLedger: CoreProgressionLedger?

    static let empty = CipherLibrary(ciphers: [], activeID: nil)

    init(
        version: Int = Self.legacyVersion,
        ciphers: [Cipher],
        activeID: UUID?,
        progressionLedger: CoreProgressionLedger? = nil
    ) {
        self.version = version
        self.ciphers = ciphers
        self.activeID = activeID
        self.progressionLedger = progressionLedger
    }

    /// The active cipher, falling back to the first entry when the stored
    /// `activeID` is missing or no longer present.
    var activeCipher: Cipher? {
        if let activeID, let match = ciphers.first(where: { $0.id == activeID }) {
            return match
        }
        return ciphers.first
    }

    private enum CodingKeys: String, CodingKey {
        case version, ciphers, activeID, progressionLedger
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: CipherLibraryDynamicCodingKey.self)
        let rawKeys = Set(dynamic.allKeys.map(\.stringValue))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        let allowedKeys: Set<String>
        switch decodedVersion {
        case Self.legacyVersion:
            allowedKeys = ["version", "ciphers", "activeID"]
        case Self.currentVersion:
            allowedKeys = ["version", "ciphers", "activeID", "progressionLedger"]
        default:
            throw CipherLibraryValidationError.unsupportedVersion(decodedVersion)
        }
        let requiredKeys: Set<String> = decodedVersion == Self.currentVersion
            ? ["version", "ciphers", "progressionLedger"]
            : ["version", "ciphers"]
        guard requiredKeys.isSubset(of: rawKeys), rawKeys.isSubset(of: allowedKeys) else {
            throw CipherLibraryValidationError.invalidVersionShape
        }
        version = decodedVersion
        var encodedCiphers = try container.nestedUnkeyedContainer(forKey: .ciphers)
        if let count = encodedCiphers.count, count > Self.maximumCipherCount {
            throw CipherLibraryValidationError.tooManyCiphers
        }
        var decodedCiphers: [Cipher] = []
        decodedCiphers.reserveCapacity(
            min(encodedCiphers.count ?? 0, Self.maximumCipherCount)
        )
        while !encodedCiphers.isAtEnd {
            guard decodedCiphers.count < Self.maximumCipherCount else {
                throw CipherLibraryValidationError.tooManyCiphers
            }
            decodedCiphers.append(try encodedCiphers.decode(Cipher.self))
        }
        ciphers = decodedCiphers
        activeID = try container.decodeIfPresent(UUID.self, forKey: .activeID)
        progressionLedger = try container.decodeIfPresent(
            CoreProgressionLedger.self,
            forKey: .progressionLedger
        )
        try validateStoredShape()
    }

    func encode(to encoder: Encoder) throws {
        try validateStoredShape()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(ciphers, forKey: .ciphers)
        try container.encodeIfPresent(activeID, forKey: .activeID)
        if version == Self.currentVersion {
            try container.encode(progressionLedger, forKey: .progressionLedger)
        }
    }

    func migratingProgressionEvidence(
        using seeds: CoreProgressionMigrationSeedSet
    ) throws -> CipherLibrary {
        if version == Self.currentVersion {
            try validateStoredShape()
            return self
        }
        guard version == Self.legacyVersion else {
            throw CipherLibraryValidationError.unsupportedVersion(version)
        }

        let cipherIDs = Set(ciphers.map(\.id))
        guard Set(seeds.cipherSeeds.keys) == cipherIDs else {
            throw CipherLibraryValidationError.progressionMigrationSeedMismatch
        }
        let currentRelationships = Set(ciphers.compactMap { cipher in
            cipher.contactID.map {
                CoreProgressionRelationshipIdentity(
                    cipherID: cipher.id,
                    contactID: $0
                )
            }
        })
        guard Set(seeds.relationshipSeeds.keys) == currentRelationships else {
            throw CipherLibraryValidationError.progressionMigrationSeedMismatch
        }

        let cipherSeedRecords = try ciphers.map { cipher in
            try CoreCipherProgressionSeedRecord(
                cipherID: cipher.id,
                seed: seeds.cipherSeeds[cipher.id]!
            )
        }
        let relationshipRecords: [CoreRelationshipProgressionRecord] = try ciphers.compactMap {
            cipher -> CoreRelationshipProgressionRecord? in
            guard let contactID = cipher.contactID else { return nil }
            let identity = CoreProgressionRelationshipIdentity(
                cipherID: cipher.id,
                contactID: contactID
            )
            return try CoreRelationshipProgressionRecord(
                identity: identity,
                seed: seeds.relationshipSeeds[identity]!,
                keyDeliveryState: cipher.keyDeliveryState
            )
        }
        let ledger = try CoreProgressionLedger(
            cipherSeeds: cipherSeedRecords,
            relationships: relationshipRecords
        )
        let candidate = CipherLibrary(
            version: Self.currentVersion,
            ciphers: ciphers,
            activeID: activeID,
            progressionLedger: ledger
        )
        try candidate.validateStoredShape()
        return candidate
    }

    func validatedProgressionLedger() throws -> CoreProgressionLedger {
        guard version == Self.currentVersion, let progressionLedger else {
            throw CipherLibraryValidationError.progressionEvidenceRequired
        }
        try progressionLedger.validate(for: ciphers)
        return progressionLedger
    }

    func validateStoredShape() throws {
        guard ciphers.count <= Self.maximumCipherCount else {
            throw CipherLibraryValidationError.tooManyCiphers
        }
        guard Set(ciphers.map(\.id)).count == ciphers.count else {
            throw CipherLibraryValidationError.duplicateCipher
        }
        if let activeID, !ciphers.contains(where: { $0.id == activeID }) {
            throw CipherLibraryValidationError.invalidActiveCipher
        }
        switch version {
        case Self.legacyVersion:
            guard progressionLedger == nil else {
                throw CipherLibraryValidationError.invalidVersionShape
            }
        case Self.currentVersion:
            guard let progressionLedger else {
                throw CipherLibraryValidationError.progressionEvidenceRequired
            }
            try progressionLedger.validate(for: ciphers)
        default:
            throw CipherLibraryValidationError.unsupportedVersion(version)
        }
    }
}

private struct CipherLibraryDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Pure Mutations
//
// These return a new library rather than mutating in place, and contain no
// Keychain or actor dependencies, so the invariants (always non-empty, active id
// always valid) are unit-testable. The cipher repository applies and persists them.

extension CipherLibrary {

    /// Appends a cipher and makes it active.
    func adding(_ cipher: Cipher) -> CipherLibrary {
        var copy = self
        copy.ciphers.append(cipher)
        copy.activeID = cipher.id
        return copy
    }

    /// Removes the cipher with `id`. Never leaves the library empty: if the last
    /// cipher is removed, a fresh one is generated and made active.
    func removingCipher(id: UUID, regeneratedLabel: String = "My Cipher") -> CipherLibrary {
        var copy = self
        copy.ciphers.removeAll { $0.id == id }
        if copy.activeID == id { copy.activeID = copy.ciphers.first?.id }
        if copy.ciphers.isEmpty {
            let fresh = Cipher.generated(label: regeneratedLabel)
            copy.ciphers = [fresh]
            copy.activeID = fresh.id
        }
        return copy
    }

    /// Relabels the cipher with `id` (no-op if not found).
    func renamingCipher(id: UUID, to label: String) -> CipherLibrary {
        var copy = self
        if let index = copy.ciphers.firstIndex(where: { $0.id == id }) {
            copy.ciphers[index].label = label
        }
        return copy
    }

    /// Selects the active cipher (no-op if `id` isn't present).
    func settingActive(id: UUID) -> CipherLibrary {
        guard ciphers.contains(where: { $0.id == id }) else { return self }
        var copy = self
        copy.activeID = id
        return copy
    }

    /// Sets (or clears, with nil) a cipher's contact link. Never touches key material.
    func settingContact(cipherID: UUID, contactID: UUID?) -> CipherLibrary {
        var copy = self
        if let i = copy.ciphers.firstIndex(where: { $0.id == cipherID }) {
            copy.ciphers[i].setContactID(contactID)
        }
        return copy
    }

    /// Clears the link on every cipher pointing at `contactID` (used when a contact is deleted).
    /// Never removes a cipher.
    func unlinkingContact(contactID: UUID) -> CipherLibrary {
        var copy = self
        for i in copy.ciphers.indices where copy.ciphers[i].contactID == contactID {
            copy.ciphers[i].setContactID(nil)
        }
        return copy
    }

    /// Completes key delivery for `cipherID` (no-op if not found). Touches nothing else.
    func completingKeyDelivery(cipherID: UUID) -> CipherLibrary {
        var copy = self
        if let i = copy.ciphers.firstIndex(where: { $0.id == cipherID }) {
            copy.ciphers[i].completeKeyDelivery()
        }
        return copy
    }

    /// Appends a cipher without changing the active selection. If the library had no active
    /// cipher (empty library), the new one becomes active so the invariant holds.
    func addingWithoutActivating(_ cipher: Cipher) -> CipherLibrary {
        var copy = self
        copy.ciphers.append(cipher)
        if copy.activeID == nil { copy.activeID = cipher.id }
        return copy
    }
}
