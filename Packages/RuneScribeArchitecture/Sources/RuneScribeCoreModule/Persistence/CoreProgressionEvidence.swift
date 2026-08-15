import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum CoreProgressionEvidenceError: Error, Equatable, Sendable {
    case unsupportedLedgerVersion(UInt16)
    case invalidSeed
    case invalidDigest
    case invalidCipherSeed
    case invalidRelationship
    case invalidPendingBatch
    case invalidAcknowledgement
    case invalidEncodedMessage
    case invalidShareTerminal
    case invalidMigrationSnapshot
    case unknownField
    case duplicateIdentity
    case nonCanonicalOrder
    case collectionLimitExceeded
    case payloadLimitExceeded
    case operationCollision
    case pendingBatchNotFound
    case receiptMismatch
}

/// A canonical SHA-256 digest used only for durable evidence identity. It never
/// contains source material and is safe to compare or persist inside the
/// encrypted Core library.
struct CoreProgressionDigest: RawRepresentable, Codable, Equatable, Hashable,
    Comparable, Sendable
{
    let rawValue: String

    init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else { return nil }
        self.rawValue = rawValue
    }

    init(validating rawValue: String) throws {
        guard let value = Self(rawValue: rawValue) else {
            throw CoreProgressionEvidenceError.invalidDigest
        }
        self = value
    }

    static func canonical<Value: Encodable>(_ value: Value) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        return try Self(validating: RuntimeIntegrityDigest.sha256Hex(data))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct CoreProgressionRelationshipIdentity: Codable, Equatable, Hashable,
    Comparable, Sendable
{
    let cipherID: UUID
    let contactID: UUID

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.cipherID.uuidString != rhs.cipherID.uuidString {
            return lhs.cipherID.uuidString < rhs.cipherID.uuidString
        }
        return lhs.contactID.uuidString < rhs.contactID.uuidString
    }

    init(cipherID: UUID, contactID: UUID) {
        self.cipherID = cipherID
        self.contactID = contactID
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cipherID: try container.decode(UUID.self, forKey: .cipherID),
            contactID: try container.decode(UUID.self, forKey: .contactID)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cipherID
        case contactID
    }
}

struct CoreCipherProgressionSeedRecord: Codable, Equatable, Sendable {
    static let seedByteCount = 32

    let cipherID: UUID
    let seed: Data

    init(cipherID: UUID, seed: Data) throws {
        guard seed.count == Self.seedByteCount else {
            throw CoreProgressionEvidenceError.invalidSeed
        }
        self.cipherID = cipherID
        self.seed = seed
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cipherID: container.decode(UUID.self, forKey: .cipherID),
            seed: container.decode(Data.self, forKey: .seed)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cipherID
        case seed
    }
}

struct CoreRelationshipProgressionRecord: Codable, Equatable, Sendable {
    static let seedByteCount = 32

    let identity: CoreProgressionRelationshipIdentity
    let seed: Data
    var keyDeliveryState: KeyDeliveryState
    var firstDeliveryEventCommitted: Bool
    var hasEligibleOutbound: Bool
    var hasAuthenticatedInbound: Bool
    var bidirectionalEventCommitted: Bool

    init(
        identity: CoreProgressionRelationshipIdentity,
        seed: Data,
        keyDeliveryState: KeyDeliveryState,
        firstDeliveryEventCommitted: Bool = false,
        hasEligibleOutbound: Bool = false,
        hasAuthenticatedInbound: Bool = false,
        bidirectionalEventCommitted: Bool = false
    ) throws {
        guard seed.count == Self.seedByteCount,
              keyDeliveryState != .notLinked,
              keyDeliveryState != .inProgress,
              !bidirectionalEventCommitted
                || (hasEligibleOutbound && hasAuthenticatedInbound)
        else {
            throw CoreProgressionEvidenceError.invalidRelationship
        }
        self.identity = identity
        self.seed = seed
        self.keyDeliveryState = keyDeliveryState
        self.firstDeliveryEventCommitted = firstDeliveryEventCommitted
        self.hasEligibleOutbound = hasEligibleOutbound
        self.hasAuthenticatedInbound = hasAuthenticatedInbound
        self.bidirectionalEventCommitted = bidirectionalEventCommitted
    }

    mutating func record(
        eligibleOutbound: Bool,
        authenticatedInbound: Bool,
        bidirectionalCommitted: Bool,
        firstDeliveryCommitted: Bool = false
    ) throws {
        hasEligibleOutbound = hasEligibleOutbound || eligibleOutbound
        hasAuthenticatedInbound = hasAuthenticatedInbound || authenticatedInbound
        firstDeliveryEventCommitted = firstDeliveryEventCommitted
            || firstDeliveryCommitted
        if bidirectionalCommitted {
            guard hasEligibleOutbound, hasAuthenticatedInbound else {
                throw CoreProgressionEvidenceError.invalidRelationship
            }
            bidirectionalEventCommitted = true
        }
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identity: container.decode(
                CoreProgressionRelationshipIdentity.self,
                forKey: .identity
            ),
            seed: container.decode(Data.self, forKey: .seed),
            keyDeliveryState: container.decode(
                KeyDeliveryState.self,
                forKey: .keyDeliveryState
            ),
            firstDeliveryEventCommitted: container.decode(
                Bool.self,
                forKey: .firstDeliveryEventCommitted
            ),
            hasEligibleOutbound: container.decode(
                Bool.self,
                forKey: .hasEligibleOutbound
            ),
            hasAuthenticatedInbound: container.decode(
                Bool.self,
                forKey: .hasAuthenticatedInbound
            ),
            bidirectionalEventCommitted: container.decode(
                Bool.self,
                forKey: .bidirectionalEventCommitted
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identity
        case seed
        case keyDeliveryState
        case firstDeliveryEventCommitted
        case hasEligibleOutbound
        case hasAuthenticatedInbound
        case bidirectionalEventCommitted
    }
}

struct CoreProgressionBatchIdentity: Codable, Equatable, Hashable, Comparable,
    Sendable
{
    let contextDigest: CoreProgressionDigest
    let batchIndex: UInt32

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.contextDigest != rhs.contextDigest {
            return lhs.contextDigest < rhs.contextDigest
        }
        return lhs.batchIndex < rhs.batchIndex
    }

    init(contextDigest: CoreProgressionDigest, batchIndex: UInt32) {
        self.contextDigest = contextDigest
        self.batchIndex = batchIndex
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            contextDigest: try container.decode(
                CoreProgressionDigest.self,
                forKey: .contextDigest
            ),
            batchIndex: try container.decode(UInt32.self, forKey: .batchIndex)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contextDigest
        case batchIndex
    }
}

struct CorePendingProgressionBatch: Codable, Equatable, Sendable {
    static let maximumEncodedByteCount = 8 * 1024 * 1024

    let identity: CoreProgressionBatchIdentity
    let context: RuntimePersistableOperationContext
    let commandDigest: CoreProgressionDigest
    let batchDigest: CoreProgressionDigest
    let batch: ProgressionEventFactBatch

    init(
        context: RuntimePersistableOperationContext,
        commandDigest: CoreProgressionDigest,
        batch: ProgressionEventFactBatch
    ) throws {
        let contextDigest = try CoreProgressionDigest.canonical(context)
        let batchDigest = try CoreProgressionDigest.canonical(batch)
        let encodedByteCount = try CoreProgressionCanonicalEncoding.data(batch).count
        guard encodedByteCount <= Self.maximumEncodedByteCount else {
            throw CoreProgressionEvidenceError.payloadLimitExceeded
        }
        identity = CoreProgressionBatchIdentity(
            contextDigest: contextDigest,
            batchIndex: batch.batchIndex
        )
        self.context = context
        self.commandDigest = commandDigest
        self.batchDigest = batchDigest
        self.batch = batch
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedContext = try container.decode(
            RuntimePersistableOperationContext.self,
            forKey: .context
        )
        let decodedCommandDigest = try container.decode(
            CoreProgressionDigest.self,
            forKey: .commandDigest
        )
        let decodedBatch = try container.decode(
            ProgressionEventFactBatch.self,
            forKey: .batch
        )
        try self.init(
            context: decodedContext,
            commandDigest: decodedCommandDigest,
            batch: decodedBatch
        )
        guard identity == (try container.decode(
            CoreProgressionBatchIdentity.self,
            forKey: .identity
        )), batchDigest == (try container.decode(
            CoreProgressionDigest.self,
            forKey: .batchDigest
        )) else {
            throw CoreProgressionEvidenceError.invalidPendingBatch
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identity
        case context
        case commandDigest
        case batchDigest
        case batch
    }
}

struct CoreAcknowledgedProgressionBatch: Codable, Equatable, Sendable {
    let identity: CoreProgressionBatchIdentity
    let context: RuntimePersistableOperationContext
    let commandDigest: CoreProgressionDigest
    let batchDigest: CoreProgressionDigest
    let batch: ProgressionEventFactBatch
    let receipt: ProgressionOutboxBatchReceipt

    init(
        pending: CorePendingProgressionBatch,
        receipt: ProgressionOutboxBatchReceipt
    ) throws {
        let expectedSlots = Set(pending.batch.facts.map(\.slot))
        guard receipt.matches(context: pending.context),
              receipt.batchIndex == pending.batch.batchIndex,
              Set(receipt.eventIDsBySlot.keys) == expectedSlots
        else {
            throw CoreProgressionEvidenceError.receiptMismatch
        }
        identity = pending.identity
        context = pending.context
        commandDigest = pending.commandDigest
        batchDigest = pending.batchDigest
        batch = pending.batch
        self.receipt = receipt
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identity = try container.decode(
            CoreProgressionBatchIdentity.self,
            forKey: .identity
        )
        context = try container.decode(
            RuntimePersistableOperationContext.self,
            forKey: .context
        )
        commandDigest = try container.decode(
            CoreProgressionDigest.self,
            forKey: .commandDigest
        )
        batchDigest = try container.decode(
            CoreProgressionDigest.self,
            forKey: .batchDigest
        )
        batch = try container.decode(
            ProgressionEventFactBatch.self,
            forKey: .batch
        )
        receipt = try container.decode(
            ProgressionOutboxBatchReceipt.self,
            forKey: .receipt
        )
        guard identity.contextDigest == (try CoreProgressionDigest.canonical(context)),
              batchDigest == (try CoreProgressionDigest.canonical(batch)),
              identity.batchIndex == batch.batchIndex,
              receipt.matches(context: context),
              identity.batchIndex == receipt.batchIndex,
              Set(batch.facts.map(\.slot)) == Set(receipt.eventIDsBySlot.keys)
        else {
            throw CoreProgressionEvidenceError.invalidAcknowledgement
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identity
        case context
        case commandDigest
        case batchDigest
        case batch
        case receipt
    }
}

struct CoreEncodedMessageProgressionRecord: Codable, Equatable, Sendable {
    static let maximumCodexCount = 8
    static let maximumArtifactCount = 16

    let handle: EncodedMessageHandle
    let cipherID: UUID
    let originatingContext: RuntimePersistableOperationContext
    let encodedMessageDigest: CoreProgressionDigest
    let messageToken: MessageToken
    let codexIDs: [CodexID]
    let artifactIDs: [ArtifactID]

    init(
        handle: EncodedMessageHandle,
        cipherID: UUID,
        originatingContext: RuntimePersistableOperationContext,
        encodedMessageDigest: CoreProgressionDigest,
        messageToken: MessageToken,
        codexIDs: [CodexID],
        artifactIDs: [ArtifactID]
    ) throws {
        guard !codexIDs.isEmpty,
              codexIDs.count <= Self.maximumCodexCount,
              artifactIDs.count <= Self.maximumArtifactCount,
              codexIDs == Array(Set(codexIDs)).sorted(),
              artifactIDs == Array(Set(artifactIDs)).sorted()
        else {
            throw CoreProgressionEvidenceError.invalidEncodedMessage
        }
        self.handle = handle
        self.cipherID = cipherID
        self.originatingContext = originatingContext
        self.encodedMessageDigest = encodedMessageDigest
        self.messageToken = messageToken
        self.codexIDs = codexIDs
        self.artifactIDs = artifactIDs
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            handle: container.decode(EncodedMessageHandle.self, forKey: .handle),
            cipherID: container.decode(UUID.self, forKey: .cipherID),
            originatingContext: container.decode(
                RuntimePersistableOperationContext.self,
                forKey: .originatingContext
            ),
            encodedMessageDigest: container.decode(
                CoreProgressionDigest.self,
                forKey: .encodedMessageDigest
            ),
            messageToken: container.decode(MessageToken.self, forKey: .messageToken),
            codexIDs: container.decode([CodexID].self, forKey: .codexIDs),
            artifactIDs: container.decode([ArtifactID].self, forKey: .artifactIDs)
        )
    }

    func replacingContext(
        _ context: RuntimePersistableOperationContext
    ) throws -> Self {
        try Self(
            handle: handle,
            cipherID: cipherID,
            originatingContext: context,
            encodedMessageDigest: encodedMessageDigest,
            messageToken: messageToken,
            codexIDs: codexIDs,
            artifactIDs: artifactIDs
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case handle
        case cipherID
        case originatingContext
        case encodedMessageDigest
        case messageToken
        case codexIDs
        case artifactIDs
    }
}

struct CoreShareTerminalProgressionRecord: Codable, Equatable, Sendable {
    let artifactID: ShareArtifactID
    let contextDigest: CoreProgressionDigest
    let commandDigest: CoreProgressionDigest
    let resultDigest: CoreProgressionDigest
    let encodedMessageHandle: EncodedMessageHandle?
    let progressionBatches: [CoreProgressionBatchIdentity]
    var cleanupPending: Bool

    init(
        artifactID: ShareArtifactID,
        context: RuntimePersistableOperationContext,
        commandDigest: CoreProgressionDigest,
        resultDigest: CoreProgressionDigest,
        encodedMessageHandle: EncodedMessageHandle? = nil,
        progressionBatches: [CoreProgressionBatchIdentity],
        cleanupPending: Bool = true
    ) throws {
        guard progressionBatches.count <= 8,
              progressionBatches == Array(Set(progressionBatches)).sorted()
        else {
            throw CoreProgressionEvidenceError.invalidShareTerminal
        }
        self.artifactID = artifactID
        contextDigest = try CoreProgressionDigest.canonical(context)
        self.commandDigest = commandDigest
        self.resultDigest = resultDigest
        self.encodedMessageHandle = encodedMessageHandle
        self.progressionBatches = progressionBatches
        self.cleanupPending = cleanupPending
    }

    func replacingBatches(
        _ progressionBatches: [CoreProgressionBatchIdentity],
        contextDigest: CoreProgressionDigest? = nil
    ) throws -> Self {
        guard progressionBatches.count <= 8,
              progressionBatches == Array(Set(progressionBatches)).sorted()
        else {
            throw CoreProgressionEvidenceError.invalidShareTerminal
        }
        return Self(
            artifactID: artifactID,
            contextDigest: contextDigest ?? self.contextDigest,
            commandDigest: commandDigest,
            resultDigest: resultDigest,
            encodedMessageHandle: encodedMessageHandle,
            progressionBatches: progressionBatches,
            cleanupPending: cleanupPending
        )
    }

    private init(
        artifactID: ShareArtifactID,
        contextDigest: CoreProgressionDigest,
        commandDigest: CoreProgressionDigest,
        resultDigest: CoreProgressionDigest,
        encodedMessageHandle: EncodedMessageHandle?,
        progressionBatches: [CoreProgressionBatchIdentity],
        cleanupPending: Bool
    ) {
        self.artifactID = artifactID
        self.contextDigest = contextDigest
        self.commandDigest = commandDigest
        self.resultDigest = resultDigest
        self.encodedMessageHandle = encodedMessageHandle
        self.progressionBatches = progressionBatches
        self.cleanupPending = cleanupPending
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let batches = try container.decode(
            [CoreProgressionBatchIdentity].self,
            forKey: .progressionBatches
        )
        guard batches.count <= 8,
              batches == Array(Set(batches)).sorted()
        else {
            throw CoreProgressionEvidenceError.invalidShareTerminal
        }
        self.init(
            artifactID: try container.decode(ShareArtifactID.self, forKey: .artifactID),
            contextDigest: try container.decode(
                CoreProgressionDigest.self,
                forKey: .contextDigest
            ),
            commandDigest: try container.decode(
                CoreProgressionDigest.self,
                forKey: .commandDigest
            ),
            resultDigest: try container.decode(
                CoreProgressionDigest.self,
                forKey: .resultDigest
            ),
            encodedMessageHandle: try container.decodeIfPresent(
                EncodedMessageHandle.self,
                forKey: .encodedMessageHandle
            ),
            progressionBatches: batches,
            cleanupPending: try container.decode(Bool.self, forKey: .cleanupPending)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case artifactID
        case contextDigest
        case commandDigest
        case resultDigest
        case encodedMessageHandle
        case progressionBatches
        case cleanupPending
    }
}

struct CoreProgressionMigrationSeedSet: Equatable, Sendable {
    let cipherSeeds: [UUID: Data]
    let relationshipSeeds: [CoreProgressionRelationshipIdentity: Data]

    init(
        cipherSeeds: [UUID: Data],
        relationshipSeeds: [CoreProgressionRelationshipIdentity: Data]
    ) {
        self.cipherSeeds = cipherSeeds
        self.relationshipSeeds = relationshipSeeds
    }
}

struct CoreProgressionMigrationCipher: Codable, Equatable, Sendable {
    let cipherToken: CipherToken
    let origin: Cipher.Origin

    init(cipherToken: CipherToken, origin: Cipher.Origin) {
        self.cipherToken = cipherToken
        self.origin = origin
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cipherToken: try container.decode(CipherToken.self, forKey: .cipherToken),
            origin: try container.decode(Cipher.Origin.self, forKey: .origin)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cipherToken
        case origin
    }
}

struct CoreProgressionMigrationSnapshot: Codable, Equatable, Sendable {
    let ciphers: [CoreProgressionMigrationCipher]

    init(ciphers: [CoreProgressionMigrationCipher]) throws {
        let sorted = ciphers.sorted {
            if $0.cipherToken != $1.cipherToken {
                return $0.cipherToken < $1.cipherToken
            }
            return $0.origin.rawValue < $1.origin.rawValue
        }
        guard Set(sorted.map(\.cipherToken)).count == sorted.count
        else {
            throw CoreProgressionEvidenceError.invalidMigrationSnapshot
        }
        self.ciphers = sorted
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            ciphers: container.decode(
                [CoreProgressionMigrationCipher].self,
                forKey: .ciphers
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case ciphers
    }
}

struct CoreGeneratedContactProgressionSeed: Equatable, Sendable {
    let contact: ImportedContactCipherSeed
    let cipherSeed: Data
    let relationshipSeed: Data
}

struct CoreProgressionRelationshipActivity: Equatable, Sendable {
    let eligibleOutbound: Bool
    let authenticatedInbound: Bool
    let bidirectionalCommitted: Bool

    init(
        eligibleOutbound: Bool = false,
        authenticatedInbound: Bool = false,
        bidirectionalCommitted: Bool = false
    ) {
        self.eligibleOutbound = eligibleOutbound
        self.authenticatedInbound = authenticatedInbound
        self.bidirectionalCommitted = bidirectionalCommitted
    }
}

struct CoreProgressionTerminalMutationResult: Equatable, Sendable {
    let inserted: Bool
    let keyDeliveryTransitioned: Bool
    let firstDeliveryTransitioned: Bool
    let bidirectionalTransitioned: Bool
}

struct CoreProgressionRelationshipMutationResult: Equatable, Sendable {
    let keyDeliveryTransitioned: Bool
    let firstDeliveryTransitioned: Bool
    let bidirectionalTransitioned: Bool
}

struct CoreProgressionContactReconciliationResult: Equatable, Sendable {
    let changes: Int
    let addedCiphers: [Cipher]
}

struct CoreProgressionLedger: Codable, Equatable, Sendable {
    static let currentVersion: UInt16 = 1
    static let maximumCipherSeedCount = 65_535
    static let maximumRelationshipCount = 65_535
    static let maximumAcknowledgedBatchCount = 4_096
    static let maximumEncodedMessageCount = 1_024
    static let maximumShareTerminalCount = 4_096

    let version: UInt16
    var cipherSeeds: [CoreCipherProgressionSeedRecord]
    var relationships: [CoreRelationshipProgressionRecord]
    var pendingBatches: [CorePendingProgressionBatch]
    var acknowledgedBatches: [CoreAcknowledgedProgressionBatch]
    var progressionOperationOrder: [CoreProgressionDigest]
    var encodedMessages: [CoreEncodedMessageProgressionRecord]
    var shareTerminals: [CoreShareTerminalProgressionRecord]

    init(
        cipherSeeds: [CoreCipherProgressionSeedRecord],
        relationships: [CoreRelationshipProgressionRecord] = [],
        pendingBatches: [CorePendingProgressionBatch] = [],
        acknowledgedBatches: [CoreAcknowledgedProgressionBatch] = [],
        encodedMessages: [CoreEncodedMessageProgressionRecord] = [],
        shareTerminals: [CoreShareTerminalProgressionRecord] = []
    ) throws {
        version = Self.currentVersion
        self.cipherSeeds = cipherSeeds.sorted {
            $0.cipherID.uuidString < $1.cipherID.uuidString
        }
        self.relationships = relationships.sorted { $0.identity < $1.identity }
        self.pendingBatches = pendingBatches.sorted { $0.identity < $1.identity }
        self.acknowledgedBatches = acknowledgedBatches.sorted {
            $0.identity < $1.identity
        }
        progressionOperationOrder = []
        let suppliedOrder = pendingBatches.map { $0.identity.contextDigest }
            + acknowledgedBatches.map { $0.identity.contextDigest }
        for digest in suppliedOrder where !progressionOperationOrder.contains(digest) {
            progressionOperationOrder.append(digest)
        }
        self.encodedMessages = encodedMessages.sorted {
            $0.handle.rawValue.uuidString < $1.handle.rawValue.uuidString
        }
        self.shareTerminals = shareTerminals.sorted {
            $0.artifactID.rawValue.uuidString < $1.artifactID.rawValue.uuidString
        }
        try validate()
    }

    init(from decoder: Decoder) throws {
        try coreRejectUnknownKeys(decoder, allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(UInt16.self, forKey: .version)
        guard decodedVersion == Self.currentVersion else {
            throw CoreProgressionEvidenceError.unsupportedLedgerVersion(decodedVersion)
        }
        version = decodedVersion
        cipherSeeds = try container.decode(
            [CoreCipherProgressionSeedRecord].self,
            forKey: .cipherSeeds
        )
        relationships = try container.decode(
            [CoreRelationshipProgressionRecord].self,
            forKey: .relationships
        )
        pendingBatches = try container.decode(
            [CorePendingProgressionBatch].self,
            forKey: .pendingBatches
        )
        acknowledgedBatches = try container.decode(
            [CoreAcknowledgedProgressionBatch].self,
            forKey: .acknowledgedBatches
        )
        progressionOperationOrder = try container.decode(
            [CoreProgressionDigest].self,
            forKey: .progressionOperationOrder
        )
        encodedMessages = try container.decode(
            [CoreEncodedMessageProgressionRecord].self,
            forKey: .encodedMessages
        )
        shareTerminals = try container.decode(
            [CoreShareTerminalProgressionRecord].self,
            forKey: .shareTerminals
        )
        try validate()
    }

    mutating func appendPending(
        _ additions: [CorePendingProgressionBatch]
    ) throws {
        let groupedAdditions = Dictionary(grouping: additions) {
            $0.identity.contextDigest
        }
        for group in groupedAdditions.values {
            guard let first = group.first,
                  group.count == Int(first.batch.totalBatchCount),
                  group.map({ $0.identity.batchIndex }).sorted()
                    == Array(0..<first.batch.totalBatchCount),
                  group.allSatisfy({
                      $0.context == first.context
                        && $0.commandDigest == first.commandDigest
                        && $0.batch.totalBatchCount == first.batch.totalBatchCount
                        && $0.batch.totalFactCount == first.batch.totalFactCount
                  })
            else {
                throw CoreProgressionEvidenceError.invalidPendingBatch
            }
        }
        for addition in additions where
            !progressionOperationOrder.contains(addition.identity.contextDigest)
        {
            progressionOperationOrder.append(addition.identity.contextDigest)
        }
        for addition in additions {
            if let existing = pendingBatches.first(where: {
                $0.identity == addition.identity
            }) {
                guard existing == addition else {
                    throw CoreProgressionEvidenceError.operationCollision
                }
                continue
            }
            if let acknowledged = acknowledgedBatches.first(where: {
                $0.identity == addition.identity
            }) {
                guard acknowledged.context == addition.context,
                      acknowledged.commandDigest == addition.commandDigest,
                      acknowledged.batchDigest == addition.batchDigest
                else {
                    throw CoreProgressionEvidenceError.operationCollision
                }
                continue
            }
            pendingBatches.append(addition)
        }
        pendingBatches.sort { $0.identity < $1.identity }
        try validate()
    }

    mutating func acknowledge(
        context: RuntimePersistableOperationContext,
        receipt: ProgressionOutboxBatchReceipt
    ) throws -> Bool {
        let identity = CoreProgressionBatchIdentity(
            contextDigest: try CoreProgressionDigest.canonical(context),
            batchIndex: receipt.batchIndex
        )
        if let acknowledged = acknowledgedBatches.first(where: {
            $0.identity == identity
        }) {
            guard acknowledged.context == context,
                  acknowledged.receipt == receipt
            else {
                throw CoreProgressionEvidenceError.receiptMismatch
            }
            return false
        }
        guard let index = pendingBatches.firstIndex(where: {
            $0.identity == identity && $0.context == context
        }) else {
            throw CoreProgressionEvidenceError.pendingBatchNotFound
        }
        let nextPendingIndex = pendingBatches
            .filter { $0.identity.contextDigest == identity.contextDigest }
            .map { $0.identity.batchIndex }
            .min()
        guard nextPendingIndex == receipt.batchIndex else {
            throw CoreProgressionEvidenceError.receiptMismatch
        }
        let pending = pendingBatches[index]
        let acknowledged = try CoreAcknowledgedProgressionBatch(
            pending: pending,
            receipt: receipt
        )
        pendingBatches.remove(at: index)
        acknowledgedBatches.append(acknowledged)
        acknowledgedBatches.sort { $0.identity < $1.identity }
        try validate()
        return true
    }

    mutating func clearAcknowledgement(
        context: RuntimePersistableOperationContext,
        receipt: ProgressionOutboxBatchReceipt
    ) throws -> Bool {
        let identity = CoreProgressionBatchIdentity(
            contextDigest: try CoreProgressionDigest.canonical(context),
            batchIndex: receipt.batchIndex
        )
        guard let index = acknowledgedBatches.firstIndex(where: {
            $0.identity == identity
        }) else {
            return false
        }
        guard !pendingBatches.contains(where: {
            $0.identity.contextDigest == identity.contextDigest
        }) else {
            throw CoreProgressionEvidenceError.receiptMismatch
        }
        let nextAcknowledgedIndex = acknowledgedBatches
            .filter { $0.identity.contextDigest == identity.contextDigest }
            .map { $0.identity.batchIndex }
            .min()
        guard nextAcknowledgedIndex == receipt.batchIndex else {
            throw CoreProgressionEvidenceError.receiptMismatch
        }
        guard acknowledgedBatches[index].context == context,
              acknowledgedBatches[index].receipt == receipt
        else {
            throw CoreProgressionEvidenceError.receiptMismatch
        }
        acknowledgedBatches.remove(at: index)
        if !pendingBatches.contains(where: {
            $0.identity.contextDigest == identity.contextDigest
        }), !acknowledgedBatches.contains(where: {
            $0.identity.contextDigest == identity.contextDigest
        }) {
            progressionOperationOrder.removeAll { $0 == identity.contextDigest }
        }
        try validate()
        return true
    }

    mutating func recontextualizePendingBatches(
        from sourceContextDigest: CoreProgressionDigest,
        to replacementContext: RuntimePersistableOperationContext
    ) throws -> Int {
        guard replacementContext.authorityScope == .persistent else {
            throw CoreProgressionEvidenceError.invalidPendingBatch
        }
        let targetContextDigest = try CoreProgressionDigest.canonical(replacementContext)
        let indices = pendingBatches.indices.filter {
            pendingBatches[$0].identity.contextDigest == sourceContextDigest
        }
        guard !indices.isEmpty else { return 0 }
        guard !progressionOperationOrder.contains(targetContextDigest) else {
            throw CoreProgressionEvidenceError.operationCollision
        }

        var replacements: [CoreProgressionBatchIdentity: CoreProgressionBatchIdentity] = [:]
        for index in indices {
            let old = pendingBatches[index]
            let replacement = try CorePendingProgressionBatch(
                context: replacementContext,
                commandDigest: old.commandDigest,
                batch: old.batch
            )
            guard !pendingBatches.contains(where: {
                $0.identity == replacement.identity && $0.identity != old.identity
            }), !acknowledgedBatches.contains(where: {
                $0.identity == replacement.identity
            }) else {
                throw CoreProgressionEvidenceError.operationCollision
            }
            replacements[old.identity] = replacement.identity
            pendingBatches[index] = replacement
        }
        for index in shareTerminals.indices {
            let rebased = shareTerminals[index].progressionBatches.map {
                replacements[$0] ?? $0
            }.sorted()
            let replacesContext = shareTerminals[index].contextDigest
                == sourceContextDigest
            if rebased != shareTerminals[index].progressionBatches || replacesContext {
                shareTerminals[index] = try shareTerminals[index].replacingBatches(
                    rebased,
                    contextDigest: replacesContext ? targetContextDigest : nil
                )
            }
        }
        for index in encodedMessages.indices where
            (try CoreProgressionDigest.canonical(
                encodedMessages[index].originatingContext
            )) == sourceContextDigest
        {
            encodedMessages[index] = try encodedMessages[index].replacingContext(
                replacementContext
            )
        }
        pendingBatches.sort { $0.identity < $1.identity }
        if let orderIndex = progressionOperationOrder.firstIndex(
            of: sourceContextDigest
        ) {
            progressionOperationOrder[orderIndex] = targetContextDigest
        }
        try validate()
        return indices.count
    }

    mutating func addCipherSeed(cipherID: UUID, seed: Data) throws {
        let candidate = try CoreCipherProgressionSeedRecord(
            cipherID: cipherID,
            seed: seed
        )
        if let existing = cipherSeeds.first(where: { $0.cipherID == cipherID }) {
            guard existing == candidate else {
                throw CoreProgressionEvidenceError.operationCollision
            }
            return
        }
        guard !cipherSeeds.contains(where: { $0.seed == seed }) else {
            throw CoreProgressionEvidenceError.invalidCipherSeed
        }
        cipherSeeds.append(candidate)
        cipherSeeds.sort { $0.cipherID.uuidString < $1.cipherID.uuidString }
        try validate()
    }

    mutating func upsertRelationship(
        _ record: CoreRelationshipProgressionRecord
    ) throws {
        if let index = relationships.firstIndex(where: {
            $0.identity == record.identity
        }) {
            guard relationships[index].seed == record.seed else {
                throw CoreProgressionEvidenceError.operationCollision
            }
            relationships[index] = record
        } else {
            guard !relationships.contains(where: { $0.seed == record.seed }) else {
                throw CoreProgressionEvidenceError.invalidRelationship
            }
            relationships.append(record)
        }
        relationships.sort { $0.identity < $1.identity }
        try validate()
    }

    mutating func addEncodedMessage(
        _ record: CoreEncodedMessageProgressionRecord
    ) throws {
        if let existing = encodedMessages.first(where: {
            $0.handle == record.handle
        }) {
            guard existing == record else {
                throw CoreProgressionEvidenceError.operationCollision
            }
            return
        }
        guard !encodedMessages.contains(where: {
            $0.messageToken == record.messageToken
        }) else {
            throw CoreProgressionEvidenceError.invalidEncodedMessage
        }
        encodedMessages.append(record)
        encodedMessages.sort { $0.handle.rawValue.uuidString < $1.handle.rawValue.uuidString }
        try validate()
    }

    mutating func removeEncodedMessage(handle: EncodedMessageHandle) -> Bool {
        guard let index = encodedMessages.firstIndex(where: { $0.handle == handle }) else {
            return false
        }
        encodedMessages.remove(at: index)
        return true
    }

    mutating func addShareTerminal(
        _ record: CoreShareTerminalProgressionRecord
    ) throws -> Bool {
        if let existing = shareTerminals.first(where: {
            $0.artifactID == record.artifactID
        }) {
            guard existing.contextDigest == record.contextDigest,
                  existing.commandDigest == record.commandDigest,
                  existing.resultDigest == record.resultDigest,
                  existing.encodedMessageHandle == record.encodedMessageHandle,
                  existing.progressionBatches == record.progressionBatches
            else {
                throw CoreProgressionEvidenceError.operationCollision
            }
            return false
        }
        shareTerminals.append(record)
        shareTerminals.sort {
            $0.artifactID.rawValue.uuidString < $1.artifactID.rawValue.uuidString
        }
        try validate()
        return true
    }

    mutating func markShareCleanupComplete(artifactID: ShareArtifactID) throws -> Bool {
        guard let index = shareTerminals.firstIndex(where: {
            $0.artifactID == artifactID
        }) else {
            throw CoreProgressionEvidenceError.invalidShareTerminal
        }
        guard shareTerminals[index].cleanupPending else { return false }
        shareTerminals[index].cleanupPending = false
        try validate()
        return true
    }

    mutating func retireShareTerminals(
        artifactIDs: Set<ShareArtifactID>
    ) throws -> Int {
        let before = shareTerminals.count
        shareTerminals.removeAll {
            artifactIDs.contains($0.artifactID) && !$0.cleanupPending
        }
        try validate()
        return before - shareTerminals.count
    }

    mutating func removeCipherEvidence(cipherID: UUID) throws {
        cipherSeeds.removeAll { $0.cipherID == cipherID }
        relationships.removeAll { $0.identity.cipherID == cipherID }
        encodedMessages.removeAll { $0.cipherID == cipherID }
        try validate()
    }

    func validate(for ciphers: [Cipher]) throws {
        try validate()
        let cipherIDs = Set(ciphers.map(\.id))
        guard Set(cipherSeeds.map(\.cipherID)).isSubset(of: cipherIDs) else {
            throw CoreProgressionEvidenceError.invalidCipherSeed
        }
        guard relationships.allSatisfy({ cipherIDs.contains($0.identity.cipherID) }) else {
            throw CoreProgressionEvidenceError.invalidRelationship
        }
        for cipher in ciphers {
            guard let contactID = cipher.contactID else { continue }
            let identity = CoreProgressionRelationshipIdentity(
                cipherID: cipher.id,
                contactID: contactID
            )
            guard let relationship = relationships.first(where: {
                $0.identity == identity
            }) else {
                // Progression evidence is optional and bounded. A valid domain
                // contact binding can therefore outlive capacity for a new
                // relationship row without weakening any retained row.
                continue
            }
            guard relationship.keyDeliveryState == cipher.keyDeliveryState else {
                throw CoreProgressionEvidenceError.invalidRelationship
            }
        }
        guard encodedMessages.allSatisfy({ cipherIDs.contains($0.cipherID) }) else {
            throw CoreProgressionEvidenceError.invalidEncodedMessage
        }
    }

    func validate() throws {
        guard version == Self.currentVersion else {
            throw CoreProgressionEvidenceError.unsupportedLedgerVersion(version)
        }
        guard cipherSeeds.count <= Self.maximumCipherSeedCount,
              relationships.count <= Self.maximumRelationshipCount,
              acknowledgedBatches.count <= Self.maximumAcknowledgedBatchCount,
              encodedMessages.count <= Self.maximumEncodedMessageCount,
              shareTerminals.count <= Self.maximumShareTerminalCount
        else {
            throw CoreProgressionEvidenceError.collectionLimitExceeded
        }
        guard isStrictlyIncreasing(cipherSeeds.map { $0.cipherID.uuidString }),
              isStrictlyIncreasing(relationships.map(\.identity)),
              isStrictlyIncreasing(pendingBatches.map(\.identity)),
              isStrictlyIncreasing(acknowledgedBatches.map(\.identity)),
              isStrictlyIncreasing(encodedMessages.map { $0.handle.rawValue.uuidString }),
              isStrictlyIncreasing(shareTerminals.map {
                  $0.artifactID.rawValue.uuidString
              })
        else {
            throw CoreProgressionEvidenceError.nonCanonicalOrder
        }
        guard Set(cipherSeeds.map(\.cipherID)).count == cipherSeeds.count,
              Set(relationships.map(\.identity)).count == relationships.count,
              Set(pendingBatches.map(\.identity)).count == pendingBatches.count,
              Set(acknowledgedBatches.map(\.identity)).count
                == acknowledgedBatches.count,
              Set(encodedMessages.map(\.handle)).count == encodedMessages.count,
              Set(encodedMessages.map(\.messageToken)).count == encodedMessages.count,
              Set(shareTerminals.map(\.artifactID)).count == shareTerminals.count,
              Set(pendingBatches.map(\.identity)).isDisjoint(
                  with: Set(acknowledgedBatches.map(\.identity))
              ), Set(progressionOperationOrder).count == progressionOperationOrder.count,
              Set(progressionOperationOrder) == Set(
                  pendingBatches.map { $0.identity.contextDigest }
                    + acknowledgedBatches.map { $0.identity.contextDigest }
              )
        else {
            throw CoreProgressionEvidenceError.duplicateIdentity
        }
        for seed in cipherSeeds {
            guard seed.seed.count == CoreCipherProgressionSeedRecord.seedByteCount else {
                throw CoreProgressionEvidenceError.invalidCipherSeed
            }
        }
        guard Set(cipherSeeds.map(\.seed)).count == cipherSeeds.count else {
            throw CoreProgressionEvidenceError.invalidCipherSeed
        }
        for relationship in relationships {
            guard relationship.seed.count
                    == CoreRelationshipProgressionRecord.seedByteCount,
                  relationship.keyDeliveryState != .notLinked,
                  relationship.keyDeliveryState != .inProgress,
                  !relationship.bidirectionalEventCommitted
                    || (relationship.hasEligibleOutbound
                        && relationship.hasAuthenticatedInbound)
            else {
                throw CoreProgressionEvidenceError.invalidRelationship
            }
        }
        guard Set(relationships.map(\.seed)).count == relationships.count else {
            throw CoreProgressionEvidenceError.invalidRelationship
        }
        let retainedBatches = pendingBatches.map {
            ($0.identity, $0.context, $0.commandDigest, $0.batchDigest, $0.batch)
        } + acknowledgedBatches.map {
            ($0.identity, $0.context, $0.commandDigest, $0.batchDigest, $0.batch)
        }
        for item in retainedBatches {
            guard item.0.contextDigest == (try CoreProgressionDigest.canonical(item.1)),
                  item.0.batchIndex == item.4.batchIndex,
                  item.3 == (try CoreProgressionDigest.canonical(item.4))
            else {
                throw CoreProgressionEvidenceError.invalidPendingBatch
            }
        }
        let groupedBatches = Dictionary(grouping: retainedBatches) { $0.0.contextDigest }
        for group in groupedBatches.values {
            guard let first = group.first,
                  group.allSatisfy({
                      $0.1 == first.1
                        && $0.2 == first.2
                        && $0.4.totalBatchCount == first.4.totalBatchCount
                        && $0.4.totalFactCount == first.4.totalFactCount
                  }), Set(group.map { $0.0.batchIndex }).count == group.count
            else {
                throw CoreProgressionEvidenceError.operationCollision
            }
        }
        for acknowledgement in acknowledgedBatches {
            guard acknowledgement.receipt.matches(context: acknowledgement.context),
                  acknowledgement.receipt.batchIndex
                    == acknowledgement.batch.batchIndex,
                  Set(acknowledgement.receipt.eventIDsBySlot.keys)
                    == Set(acknowledgement.batch.facts.map(\.slot))
            else {
                throw CoreProgressionEvidenceError.invalidAcknowledgement
            }
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case cipherSeeds
        case relationships
        case pendingBatches
        case acknowledgedBatches
        case progressionOperationOrder
        case encodedMessages
        case shareTerminals
    }
}

private enum CoreProgressionCanonicalEncoding {
    static func data<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }
}

private struct CoreProgressionDynamicCodingKey: CodingKey {
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

private func coreRejectUnknownKeys<Key: CodingKey & CaseIterable>(
    _ decoder: Decoder,
    allowed: Key.Type
) throws where Key.AllCases: Collection {
    let container = try decoder.container(keyedBy: CoreProgressionDynamicCodingKey.self)
    let allowedValues = Set(Key.allCases.map(\.stringValue))
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowedValues) else {
        throw CoreProgressionEvidenceError.unknownField
    }
}

private func isStrictlyIncreasing<Value: Comparable>(_ values: [Value]) -> Bool {
    zip(values, values.dropFirst()).allSatisfy(<)
}
