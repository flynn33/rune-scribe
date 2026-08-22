import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ShareArtifactRegistryError: Error, Equatable, Sendable {
    case artifactNotFound
    case terminalEvidenceCollision
    case terminalJournalFull
    case storageUnavailable
}

struct CoreShareArtifact: Sendable {
    let dto: ShareArtifactDTO
    let hasStoredFile: Bool
    let hasStoredLink: Bool
    let messageCipherID: UUID?
    let encodedMessageHandle: EncodedMessageHandle?
    let presentationSelection: SharePresentationSelection?
    let persistsMetadata: Bool
}

struct CoreDurableShareArtifactRecord: Codable, Equatable, Sendable {
    let sequence: UInt64
    let artifactID: ShareArtifactID
    let hasStoredFile: Bool
    let hasStoredLink: Bool
    let requiresKeyDelivery: Bool
    let messageCipherID: UUID?
    let encodedMessageHandle: EncodedMessageHandle?
    let presentationSelection: SharePresentationSelection?
    var terminalEvidence: ShareArtifactCompletionEvidenceDTO?
    var plannedDisposition: ShareArtifactCompletionResultDTO?
    var completionDisposition: ShareArtifactCompletionResultDTO?
    var physicalArtifactReleased: Bool
    var preservesRelaunchRedelivery: Bool

    init(
        sequence: UInt64,
        artifact: CoreShareArtifact
    ) throws {
        guard !(artifact.hasStoredFile && artifact.hasStoredLink)
        else {
            throw ShareArtifactRegistryError.terminalEvidenceCollision
        }
        self.sequence = sequence
        artifactID = artifact.dto.id
        hasStoredFile = artifact.hasStoredFile
        hasStoredLink = artifact.hasStoredLink
        requiresKeyDelivery = artifact.dto.requiresKeyDelivery
        messageCipherID = artifact.messageCipherID
        encodedMessageHandle = artifact.encodedMessageHandle
        presentationSelection = artifact.presentationSelection
        terminalEvidence = nil
        plannedDisposition = nil
        completionDisposition = nil
        physicalArtifactReleased = false
        preservesRelaunchRedelivery = false
    }

    mutating func recordTerminal(
        _ evidence: ShareArtifactCompletionEvidenceDTO
    ) throws {
        guard evidence.artifactID == artifactID else {
            throw ShareArtifactRegistryError.terminalEvidenceCollision
        }
        if let terminalEvidence {
            guard terminalEvidence == evidence else {
                throw ShareArtifactRegistryError.terminalEvidenceCollision
            }
            return
        }
        terminalEvidence = evidence
    }

    mutating func planTerminalDisposition(
        _ disposition: ShareArtifactCompletionResultDTO
    ) throws {
        guard terminalEvidence != nil,
              disposition != .retainedForRetry
        else {
            throw ShareArtifactRegistryError.terminalEvidenceCollision
        }
        if let plannedDisposition {
            guard completionDisposition == nil else {
                throw ShareArtifactRegistryError.terminalEvidenceCollision
            }
            if plannedDisposition == disposition { return }
        }
        plannedDisposition = disposition
    }

    mutating func completeTerminal(
        _ disposition: ShareArtifactCompletionResultDTO
    ) throws {
        try planTerminalDisposition(disposition)
        if let completionDisposition {
            guard completionDisposition == disposition else {
                throw ShareArtifactRegistryError.terminalEvidenceCollision
            }
            return
        }
        guard physicalArtifactReleased else {
            throw ShareArtifactRegistryError.terminalEvidenceCollision
        }
        completionDisposition = disposition
    }
}

private struct CoreShareArtifactJournal: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumRecordCount = 256
    static let releasedMetadataRetryWindow = 64
    static let completedTerminalRetryWindow = 64

    let version: Int
    var nextSequence: UInt64
    var records: [CoreDurableShareArtifactRecord]
    var encodedHandleOrder: [EncodedMessageHandle]

    init(
        nextSequence: UInt64 = 0,
        records: [CoreDurableShareArtifactRecord] = [],
        encodedHandleOrder: [EncodedMessageHandle] = []
    ) throws {
        version = Self.currentVersion
        self.nextSequence = nextSequence
        self.records = records.sorted { $0.sequence < $1.sequence }
        self.encodedHandleOrder = encodedHandleOrder
        try validate()
    }

    mutating func addEncodedHandle(_ handle: EncodedMessageHandle) throws {
        guard !encodedHandleOrder.contains(handle) else { return }
        guard encodedHandleOrder.count < CoreProgressionLedger
            .maximumEncodedMessageCount
        else {
            throw ShareArtifactRegistryError.terminalJournalFull
        }
        encodedHandleOrder.append(handle)
        try validate()
    }

    mutating func removeEncodedHandle(_ handle: EncodedMessageHandle) throws {
        encodedHandleOrder.removeAll { $0 == handle }
        try validate()
    }

    mutating func addPrepared(_ artifact: CoreShareArtifact) throws {
        if let existing = records.first(where: {
            $0.artifactID == artifact.dto.id
        }) {
            let expected = try CoreDurableShareArtifactRecord(
                sequence: existing.sequence,
                artifact: artifact
            )
            guard existing.artifactID == expected.artifactID,
                  existing.hasStoredFile == expected.hasStoredFile,
                  existing.hasStoredLink == expected.hasStoredLink,
                  existing.requiresKeyDelivery == expected.requiresKeyDelivery,
                  existing.messageCipherID == expected.messageCipherID,
                  existing.encodedMessageHandle == expected.encodedMessageHandle,
                  existing.presentationSelection == expected.presentationSelection
            else {
                throw ShareArtifactRegistryError.terminalEvidenceCollision
            }
            return
        }
        compactReleasedMetadata()
        guard records.count < Self.maximumRecordCount,
              nextSequence < UInt64.max
        else {
            throw ShareArtifactRegistryError.terminalJournalFull
        }
        records.append(try CoreDurableShareArtifactRecord(
            sequence: nextSequence,
            artifact: artifact
        ))
        nextSequence += 1
        try validate()
    }

    mutating func recordTerminal(
        _ evidence: ShareArtifactCompletionEvidenceDTO
    ) throws -> CoreDurableShareArtifactRecord {
        guard let index = records.firstIndex(where: {
            $0.artifactID == evidence.artifactID
        }) else {
            throw ShareArtifactRegistryError.artifactNotFound
        }
        try records[index].recordTerminal(evidence)
        try validate()
        return records[index]
    }

    mutating func planTerminalDisposition(
        artifactID: ShareArtifactID,
        disposition: ShareArtifactCompletionResultDTO
    ) throws -> CoreDurableShareArtifactRecord {
        guard let index = records.firstIndex(where: {
            $0.artifactID == artifactID
        }) else {
            throw ShareArtifactRegistryError.artifactNotFound
        }
        try records[index].planTerminalDisposition(disposition)
        try validate()
        return records[index]
    }

    mutating func completeTerminal(
        artifactID: ShareArtifactID,
        disposition: ShareArtifactCompletionResultDTO
    ) throws -> Set<ShareArtifactID> {
        guard let index = records.firstIndex(where: {
            $0.artifactID == artifactID
        }) else {
            throw ShareArtifactRegistryError.artifactNotFound
        }
        try records[index].completeTerminal(disposition)
        let before = Set(records.map(\.artifactID))
        compactRetryMetadata()
        try validate()
        return before.subtracting(Set(records.map(\.artifactID)))
    }

    mutating func markPhysicalArtifactReleased(
        artifactID: ShareArtifactID
    ) throws {
        guard let index = records.firstIndex(where: {
            $0.artifactID == artifactID
        }) else { return }
        records[index].physicalArtifactReleased = true
        compactReleasedMetadata()
        try validate()
    }

    mutating func markAllPhysicalArtifactsReleased() throws {
        for index in records.indices {
            records[index].physicalArtifactReleased = true
            if records[index].completionDisposition == nil {
                records[index].preservesRelaunchRedelivery = true
            }
        }
        try validate()
    }

    mutating func remove(artifactID: ShareArtifactID) throws -> Bool {
        let before = records.count
        records.removeAll { $0.artifactID == artifactID }
        try validate()
        return before != records.count
    }

    mutating func reconcilePreparedArtifacts(
        retaining outstandingArtifactIDs: Set<ShareArtifactID>
    ) throws -> Set<ShareArtifactID> {
        let knownArtifactIDs = Set(records.map(\.artifactID))
        guard outstandingArtifactIDs.isSubset(of: knownArtifactIDs) else {
            throw ShareArtifactRegistryError.storageUnavailable
        }
        let retired = Set(records.compactMap { record -> ShareArtifactID? in
            guard record.terminalEvidence == nil,
                  !outstandingArtifactIDs.contains(record.artifactID)
            else { return nil }
            return record.artifactID
        })
        records.removeAll { retired.contains($0.artifactID) }
        for index in records.indices where
            outstandingArtifactIDs.contains(records[index].artifactID) {
            records[index].preservesRelaunchRedelivery = true
        }
        try validate()
        return retired
    }

    private mutating func compactReleasedMetadata() {
        let candidates = records.filter {
            $0.physicalArtifactReleased
                && $0.terminalEvidence == nil
                && !$0.preservesRelaunchRedelivery
        }
        let excess = candidates.count - Self.releasedMetadataRetryWindow
        guard excess > 0 else { return }
        let retired = Set(candidates.prefix(excess).map(\.artifactID))
        records.removeAll { retired.contains($0.artifactID) }
    }

    private mutating func compactCompletedTerminals() {
        let candidates = records.filter { $0.completionDisposition != nil }
        let excess = candidates.count - Self.completedTerminalRetryWindow
        guard excess > 0 else { return }
        let retired = Set(candidates.prefix(excess).map(\.artifactID))
        records.removeAll { retired.contains($0.artifactID) }
    }

    private mutating func compactRetryMetadata() {
        compactReleasedMetadata()
        compactCompletedTerminals()
    }

    func validate() throws {
        guard version == Self.currentVersion,
              records.count <= Self.maximumRecordCount,
              Set(records.map(\.artifactID)).count == records.count,
              Set(records.map(\.sequence)).count == records.count,
              encodedHandleOrder.count <= CoreProgressionLedger
                .maximumEncodedMessageCount,
              Set(encodedHandleOrder).count == encodedHandleOrder.count,
              records == records.sorted(by: { $0.sequence < $1.sequence }),
              records.allSatisfy({ record in
                  !record.hasStoredFile || !record.hasStoredLink
              }), records.allSatisfy({ record in
                  record.terminalEvidence?.artifactID == record.artifactID
                    || record.terminalEvidence == nil
              }), records.allSatisfy({ record in
                  record.plannedDisposition == nil
                    || (record.terminalEvidence != nil
                        && record.plannedDisposition != .retainedForRetry)
              }), records.allSatisfy({ record in
                  record.completionDisposition == nil
                    || (record.completionDisposition == record.plannedDisposition
                        && record.physicalArtifactReleased)
              }), records.last.map({ $0.sequence < nextSequence }) ?? true,
              records.filter({
                  $0.completionDisposition != nil
              }).count <= Self.completedTerminalRetryWindow
        else {
            throw ShareArtifactRegistryError.storageUnavailable
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        nextSequence = try container.decode(UInt64.self, forKey: .nextSequence)
        records = try container.decode(
            [CoreDurableShareArtifactRecord].self,
            forKey: .records
        )
        encodedHandleOrder = try container.decode(
            [EncodedMessageHandle].self,
            forKey: .encodedHandleOrder
        )
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case nextSequence
        case records
        case encodedHandleOrder
    }
}

/// Owns the lifetime of every outbound share lease. Key-bearing data is passed
/// directly to the scoped Platform store and is never cached by this registry.
actor ShareArtifactRegistry {
    static let completedTerminalRetryWindow = CoreShareArtifactJournal
        .completedTerminalRetryWindow
    static let releasedMetadataRetryWindow = CoreShareArtifactJournal
        .releasedMetadataRetryWindow

    private static let terminalJournalPath = ProtectedPath(
        rawValue: "RuneScribCore/share-terminal-intents.enc"
    )!
    private static let maximumTerminalJournalByteCount = 512 * 1_024

    private let runtimeIO: RuntimeIOClient
    private var artifacts: [ShareArtifactID: CoreShareArtifact] = [:]
    private var terminalJournal: CoreShareArtifactJournal?
    private var terminalJournalKey: SymmetricKey?

    init(runtimeIO: RuntimeIOClient) {
        self.runtimeIO = runtimeIO
    }

    func createFile(
        data: Data,
        id: ShareArtifactID,
        filename: String,
        displayName: String,
        contentType: String,
        fileExtension: String,
        requiresKeyDelivery: Bool,
        messageCipherID: UUID?,
        encodedMessageHandle: EncodedMessageHandle? = nil,
        presentationSelection: SharePresentationSelection? = nil,
        persistsMetadata: Bool = true
    ) async throws -> ShareArtifactDTO {
        do {
            try await runtimeIO.createShareArtifact(
                data,
                artifactID: id,
                filename: filename,
                fileExtension: fileExtension
            )
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }

        let dto = ShareArtifactDTO(
            id: id,
            reference: .file(id),
            displayName: displayName,
            contentType: contentType,
            fileExtension: fileExtension,
            lifetime: .singleUse,
            requiresKeyDelivery: requiresKeyDelivery
        )
        let artifact = CoreShareArtifact(
            dto: dto,
            hasStoredFile: true,
            hasStoredLink: false,
            messageCipherID: messageCipherID,
            encodedMessageHandle: encodedMessageHandle,
            presentationSelection: presentationSelection,
            persistsMetadata: persistsMetadata
        )
        artifacts[id] = artifact
        if persistsMetadata {
            do {
                try await persistPreparedArtifact(artifact)
            } catch {
                try? await runtimeIO.removeShareArtifact(artifactID: id)
                artifacts.removeValue(forKey: id)
                throw error
            }
        }
        return dto
    }

    func createLink(
        url: URL,
        id: ShareArtifactID,
        displayName: String,
        presentationSelection: SharePresentationSelection? = nil,
        persistsMetadata: Bool = true
    ) async throws -> ShareArtifactDTO {
        do {
            try await runtimeIO.storeShareArtifactLink(url, artifactID: id)
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }
        let dto = ShareArtifactDTO(
            id: id,
            reference: .opaque(id),
            displayName: displayName,
            contentType: "text/uri-list",
            fileExtension: nil,
            lifetime: .singleUse,
            requiresKeyDelivery: true
        )
        let artifact = CoreShareArtifact(
            dto: dto,
            hasStoredFile: false,
            hasStoredLink: true,
            messageCipherID: nil,
            encodedMessageHandle: nil,
            presentationSelection: presentationSelection,
            persistsMetadata: persistsMetadata
        )
        artifacts[id] = artifact
        if persistsMetadata {
            do {
                try await persistPreparedArtifact(artifact)
            } catch {
                try? await runtimeIO.removeShareArtifactLink(artifactID: id)
                artifacts.removeValue(forKey: id)
                throw error
            }
        }
        return dto
    }

    func createOpaqueMessage(
        id: ShareArtifactID,
        cipherID: UUID,
        encodedMessageHandle: EncodedMessageHandle? = nil,
        presentationSelection: SharePresentationSelection? = nil,
        persistsMetadata: Bool = true
    ) async throws -> ShareArtifactDTO {
        let dto = ShareArtifactDTO(
            id: id,
            reference: .opaque(id),
            displayName: "Rune Scribe Message",
            contentType: "text/plain",
            fileExtension: nil,
            lifetime: .singleUse,
            requiresKeyDelivery: false
        )
        let artifact = CoreShareArtifact(
            dto: dto,
            hasStoredFile: false,
            hasStoredLink: false,
            messageCipherID: cipherID,
            encodedMessageHandle: encodedMessageHandle,
            presentationSelection: presentationSelection,
            persistsMetadata: persistsMetadata
        )
        if persistsMetadata {
            try await persistPreparedArtifact(artifact)
        }
        artifacts[id] = artifact
        return dto
    }

    private func persistPreparedArtifact(
        _ artifact: CoreShareArtifact
    ) async throws {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        try candidate.addPrepared(artifact)
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
    }

    func artifact(id: ShareArtifactID) throws -> CoreShareArtifact {
        guard let artifact = artifacts[id] else {
            throw ShareArtifactRegistryError.artifactNotFound
        }
        return artifact
    }

    func hasArtifact(encodedMessageHandle: EncodedMessageHandle) -> Bool {
        artifacts.values.contains {
            $0.encodedMessageHandle == encodedMessageHandle
        }
    }

    func hasRetainedArtifact(
        encodedMessageHandle: EncodedMessageHandle
    ) async throws -> Bool {
        try await loadTerminalJournal().records.contains {
            $0.encodedMessageHandle == encodedMessageHandle
                && $0.completionDisposition == nil
        }
    }

    /// Prevents two addressable copies of the same first-delivery key material.
    /// A physically released cancellation may be replaced, while a delivery-
    /// eligible terminal or a Runtime-retained terminal remains authoritative.
    func hasOutstandingKeyDeliveryArtifact(
        cipherID: UUID,
        runtimeOutstandingArtifactIDs: Set<ShareArtifactID>? = nil,
        inspectsDurableJournal: Bool = true
    ) async throws -> Bool {
        if artifacts.values.contains(where: { artifact in
            artifact.dto.requiresKeyDelivery
                && artifact.messageCipherID == cipherID
        }) {
            return true
        }
        guard inspectsDurableJournal else { return false }

        return try await loadTerminalJournal().records.contains { record in
            guard record.requiresKeyDelivery,
                  record.messageCipherID == cipherID,
                  record.completionDisposition == nil
            else { return false }
            if !record.physicalArtifactReleased { return true }
            if runtimeOutstandingArtifactIDs?.contains(record.artifactID) == true {
                return true
            }
            return record.terminalEvidence?.report.isEligibleTerminal(
                requiresKeyDelivery: true
            ) == true
        }
    }

    func retainEncodedMessageHandle(
        _ handle: EncodedMessageHandle
    ) async throws {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        try candidate.addEncodedHandle(handle)
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
    }

    func releaseEncodedMessageHandle(
        _ handle: EncodedMessageHandle
    ) async throws {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        try candidate.removeEncodedHandle(handle)
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
    }

    func encodedMessageHandleChronology() async throws
        -> [EncodedMessageHandle]
    {
        try await loadTerminalJournal().encodedHandleOrder
    }

    func durableRecord(
        artifactID: ShareArtifactID
    ) async throws -> CoreDurableShareArtifactRecord? {
        try await loadTerminalJournal().records.first {
            $0.artifactID == artifactID
        }
    }

    func durableRecords() async throws -> [CoreDurableShareArtifactRecord] {
        try await loadTerminalJournal().records
    }

    /// Persists the exact Runtime-minted terminal result before Core mutates
    /// key-delivery state or releases the single-use artifact.
    func journalTerminal(
        _ evidence: ShareArtifactCompletionEvidenceDTO
    ) async throws -> CoreDurableShareArtifactRecord {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        let record = try candidate.recordTerminal(evidence)
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
        return record
    }

    func terminalIntent(
        artifactID: ShareArtifactID
    ) async throws -> CoreDurableShareArtifactRecord? {
        try await loadTerminalJournal().records.first {
            $0.artifactID == artifactID && $0.terminalEvidence != nil
        }
    }

    func terminalIntents() async throws -> [CoreDurableShareArtifactRecord] {
        try await loadTerminalJournal().records.filter {
            $0.terminalEvidence != nil && $0.completionDisposition == nil
        }
    }

    func hasTerminalIntent(
        encodedMessageHandle: EncodedMessageHandle
    ) async throws -> Bool {
        try await loadTerminalJournal().records.contains {
            $0.encodedMessageHandle == encodedMessageHandle
                && $0.terminalEvidence != nil
                && $0.completionDisposition == nil
        }
    }

    func planTerminalDisposition(
        artifactID: ShareArtifactID,
        disposition: ShareArtifactCompletionResultDTO
    ) async throws -> CoreDurableShareArtifactRecord {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        let record = try candidate.planTerminalDisposition(
            artifactID: artifactID,
            disposition: disposition
        )
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
        return record
    }

    func completeTerminal(
        artifactID: ShareArtifactID,
        disposition: ShareArtifactCompletionResultDTO
    ) async throws -> Set<ShareArtifactID> {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        let retired = try candidate.completeTerminal(
            artifactID: artifactID,
            disposition: disposition
        )
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
        return retired
    }

    func retainedCompletedTerminalIDs() async throws -> Set<ShareArtifactID> {
        Set(try await loadTerminalJournal().records.compactMap { record in
            record.completionDisposition == nil ? nil : record.artifactID
        })
    }

    @discardableResult
    func reconcilePreparedArtifacts(
        retaining outstandingArtifactIDs: Set<ShareArtifactID>
    ) async throws -> Set<ShareArtifactID> {
        var candidate = try await loadTerminalJournal()
        let before = candidate
        let retired = try candidate.reconcilePreparedArtifacts(
            retaining: outstandingArtifactIDs
        )
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
        return retired
    }

    func removeTerminalIntent(artifactID: ShareArtifactID) async throws {
        var candidate = try await loadTerminalJournal()
        guard try candidate.remove(artifactID: artifactID) else { return }
        try await persistTerminalJournal(candidate)
    }

    /// A reconstructed registry has no in-memory lease table. Durable metadata
    /// is sufficient to idempotently remove the exact physical artifact before
    /// the encrypted terminal tombstone is marked cleanup-complete.
    func releaseTerminalArtifact(
        _ intent: CoreDurableShareArtifactRecord
    ) async throws {
        do {
            if intent.hasStoredFile {
                try await runtimeIO.removeShareArtifact(
                    artifactID: intent.artifactID
                )
            } else if intent.hasStoredLink {
                try await runtimeIO.removeShareArtifactLink(
                    artifactID: intent.artifactID
                )
            }
            artifacts.removeValue(forKey: intent.artifactID)
            var candidate = try await loadTerminalJournal()
            let before = candidate
            try candidate.markPhysicalArtifactReleased(
                artifactID: intent.artifactID
            )
            if candidate != before {
                try await persistTerminalJournal(candidate)
            }
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }
    }

    func release(id: ShareArtifactID) async throws {
        let artifact = artifacts[id]
        if let artifact, !artifact.persistsMetadata {
            do {
                if artifact.hasStoredFile {
                    try await runtimeIO.removeShareArtifact(artifactID: id)
                } else if artifact.hasStoredLink {
                    try await runtimeIO.removeShareArtifactLink(artifactID: id)
                }
                artifacts.removeValue(forKey: id)
                return
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        }
        let record = try await loadTerminalJournal().records.first {
            $0.artifactID == id
        }
        guard artifact != nil || record != nil else { return }
        let hasStoredFile = artifact?.hasStoredFile
            ?? record?.hasStoredFile
            ?? false
        let hasStoredLink = artifact?.hasStoredLink
            ?? record?.hasStoredLink
            ?? false
        if hasStoredFile {
            do {
                try await runtimeIO.removeShareArtifact(artifactID: id)
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        } else if hasStoredLink {
            do {
                try await runtimeIO.removeShareArtifactLink(artifactID: id)
            } catch {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        }
        artifacts.removeValue(forKey: id)
        var candidate = try await loadTerminalJournal()
        let before = candidate
        try candidate.markPhysicalArtifactReleased(artifactID: id)
        if candidate != before {
            try await persistTerminalJournal(candidate)
        }
    }

    func releaseAll(updatingDurableJournal: Bool = true) async throws {
        do {
            try await runtimeIO.removeAllShareArtifacts()
            artifacts.removeAll()
            guard updatingDurableJournal else { return }
            var candidate = try await loadTerminalJournal()
            let before = candidate
            try candidate.markAllPhysicalArtifactsReleased()
            if candidate != before {
                try await persistTerminalJournal(candidate)
            }
        } catch {
            // Keep leases addressable so callers can retry explicit cleanup.
            throw ShareArtifactRegistryError.storageUnavailable
        }
    }

    private func loadTerminalJournal() async throws
        -> CoreShareArtifactJournal
    {
        if let terminalJournal { return terminalJournal }
        let key = try await loadTerminalJournalKey()
        let loaded: CoreShareArtifactJournal
        do {
            guard let encrypted = try await runtimeIO.readProtectedFile(
                Self.terminalJournalPath,
                maximumByteCount: Self.maximumTerminalJournalByteCount
            ) else {
                loaded = try CoreShareArtifactJournal()
                terminalJournal = loaded
                return loaded
            }
            guard encrypted.count <= Self.maximumTerminalJournalByteCount else {
                throw ShareArtifactRegistryError.storageUnavailable
            }
            loaded = try Self.decryptTerminalJournal(encrypted, using: key)
        } catch let error as ShareArtifactRegistryError {
            throw error
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }
        terminalJournal = loaded
        return loaded
    }

    private func loadTerminalJournalKey() async throws -> SymmetricKey {
        if let terminalJournalKey { return terminalJournalKey }
        do {
            guard let keyData = try await runtimeIO.secureValueData(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.symmetricKeyAccount
            ), keyData.count == 32 else {
                throw ShareArtifactRegistryError.storageUnavailable
            }
            let key = SymmetricKey(data: keyData)
            terminalJournalKey = key
            return key
        } catch let error as ShareArtifactRegistryError {
            throw error
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }
    }

    private func persistTerminalJournal(
        _ journal: CoreShareArtifactJournal
    ) async throws {
        try journal.validate()
        let key = try await loadTerminalJournalKey()
        if journal.records.isEmpty {
            do {
                try await runtimeIO.removeProtectedFile(Self.terminalJournalPath)
            } catch {
                if (try? await runtimeIO.readProtectedFile(
                    Self.terminalJournalPath,
                    maximumByteCount: Self.maximumTerminalJournalByteCount
                )) != nil {
                    throw ShareArtifactRegistryError.storageUnavailable
                }
            }
            terminalJournal = journal
            return
        }

        let encrypted: Data
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let plaintext = try encoder.encode(journal)
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined,
                  combined.count <= Self.maximumTerminalJournalByteCount
            else {
                throw ShareArtifactRegistryError.storageUnavailable
            }
            encrypted = combined
        } catch let error as ShareArtifactRegistryError {
            throw error
        } catch {
            throw ShareArtifactRegistryError.storageUnavailable
        }

        do {
            try await runtimeIO.writeProtectedFile(
                encrypted,
                path: Self.terminalJournalPath
            )
        } catch {
            guard let stored = try? await runtimeIO.readProtectedFile(
                Self.terminalJournalPath,
                maximumByteCount: Self.maximumTerminalJournalByteCount
            ), let decoded = try? Self.decryptTerminalJournal(
                      stored,
                      using: key
                  ), decoded == journal
            else {
                throw ShareArtifactRegistryError.storageUnavailable
            }
        }
        terminalJournal = journal
    }

    private static func decryptTerminalJournal(
        _ encrypted: Data,
        using key: SymmetricKey
    ) throws -> CoreShareArtifactJournal {
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let plaintext = try AES.GCM.open(box, using: key)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            CoreShareArtifactJournal.self,
            from: plaintext
        )
    }
}
