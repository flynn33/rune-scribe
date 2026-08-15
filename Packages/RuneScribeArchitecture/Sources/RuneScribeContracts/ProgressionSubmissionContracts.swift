import Foundation

private func progressionSubmissionMilliseconds(_ date: Date) throws -> Int64 {
    let scaled = date.timeIntervalSince1970 * 1_000
    let rounded = scaled.rounded()
    guard rounded.isFinite,
          rounded >= Double(Int64.min),
          rounded < Double(Int64.max)
    else {
        throw RuntimeOperationContextError.invalidContext
    }
    return Int64(rounded)
}

private func progressionSubmissionDate(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
}

/// Runtime-issued metadata that a domain module may persist and return to the
/// progression outbox. Its authoritative fields are intentionally unavailable
/// outside the runtime authority SPI.
public struct RuntimePersistableOperationContext: Codable, Hashable, Sendable {
    private let schemaVersion: UInt16
    private let operationID: RuntimeOperationID
    private let correlationID: RuntimeCorrelationID
    private let occurredAtUTC: Date
    private let operationIdentifier: RuntimeOperationIdentifier
    private let runtimeGeneration: UInt64
    private let authorityNonce: UUID
    private let authorityTag: Data
    public let authorityScope: RuntimeOperationContextAuthorityScope

    @_spi(RuntimeOperationAuthority)
    public init(
        operationID: RuntimeOperationID,
        correlationID: RuntimeCorrelationID,
        occurredAtUTC: Date,
        operationIdentifier: RuntimeOperationIdentifier,
        runtimeGeneration: UInt64,
        authorityNonce: UUID,
        authorityTag: Data,
        authorityScope: RuntimeOperationContextAuthorityScope
    ) throws {
        guard !operationID.rawValue.isEmpty,
              UUID(uuidString: correlationID.rawValue) != nil,
              occurredAtUTC.timeIntervalSinceReferenceDate.isFinite,
              !operationIdentifier.rawValue.isEmpty,
              runtimeGeneration > 0,
              authorityTag.count == 32
        else {
            throw RuntimeOperationContextError.invalidContext
        }
        schemaVersion = 1
        self.operationID = operationID
        self.correlationID = correlationID
        self.occurredAtUTC = progressionSubmissionDate(
            milliseconds: try progressionSubmissionMilliseconds(occurredAtUTC)
        )
        self.operationIdentifier = operationIdentifier
        self.runtimeGeneration = runtimeGeneration
        self.authorityNonce = authorityNonce
        self.authorityTag = authorityTag
        self.authorityScope = authorityScope
    }

    @_spi(RuntimeOperationAuthority)
    public init(
        metadata: RuntimeOperationMetadata,
        authorityNonce: UUID,
        authorityTag: Data,
        authorityScope: RuntimeOperationContextAuthorityScope
    ) throws {
        try self.init(
            operationID: metadata.operationID,
            correlationID: metadata.correlationID,
            occurredAtUTC: metadata.timestampUTC,
            operationIdentifier: metadata.operationIdentifier,
            runtimeGeneration: metadata.runtimeGeneration,
            authorityNonce: authorityNonce,
            authorityTag: authorityTag,
            authorityScope: authorityScope
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == CodingKeys.allCases.count else {
            throw RuntimeOperationContextError.invalidContext
        }
        let decodedSchemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == 1 else {
            throw RuntimeOperationContextError.unsupportedSchema
        }
        try self.init(
            operationID: container.decode(RuntimeOperationID.self, forKey: .operationID),
            correlationID: container.decode(
                RuntimeCorrelationID.self,
                forKey: .correlationID
            ),
            occurredAtUTC: progressionSubmissionDate(
                milliseconds: container.decode(Int64.self, forKey: .occurredAtUTC)
            ),
            operationIdentifier: container.decode(
                RuntimeOperationIdentifier.self,
                forKey: .operationIdentifier
            ),
            runtimeGeneration: container.decode(UInt64.self, forKey: .runtimeGeneration),
            authorityNonce: container.decode(UUID.self, forKey: .authorityNonce),
            authorityTag: container.decode(Data.self, forKey: .authorityTag),
            authorityScope: container.decode(
                RuntimeOperationContextAuthorityScope.self,
                forKey: .authorityScope
            )
        )
    }

    @_spi(RuntimeOperationAuthority)
    public var runtimeOperationID: RuntimeOperationID { operationID }

    @_spi(RuntimeOperationAuthority)
    public var runtimeCorrelationID: RuntimeCorrelationID { correlationID }

    @_spi(RuntimeOperationAuthority)
    public var runtimeOccurredAtUTC: Date { occurredAtUTC }

    @_spi(RuntimeOperationAuthority)
    public var runtimeOperationIdentifier: RuntimeOperationIdentifier {
        operationIdentifier
    }

    @_spi(RuntimeOperationAuthority)
    public var issuingRuntimeGeneration: UInt64 { runtimeGeneration }

    @_spi(RuntimeOperationAuthority)
    public var runtimeAuthorityNonce: UUID { authorityNonce }

    @_spi(RuntimeOperationAuthority)
    public var runtimeAuthorityTag: Data { authorityTag }

    @_spi(RuntimeOperationAuthority)
    public static func normalizedOccurredAtUTC(_ date: Date) throws -> Date {
        progressionSubmissionDate(
            milliseconds: try progressionSubmissionMilliseconds(date)
        )
    }

    fileprivate func matches(operationID candidate: RuntimeOperationID) -> Bool {
        operationID == candidate
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(operationID, forKey: .operationID)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(
            progressionSubmissionMilliseconds(occurredAtUTC),
            forKey: .occurredAtUTC
        )
        try container.encode(operationIdentifier, forKey: .operationIdentifier)
        try container.encode(runtimeGeneration, forKey: .runtimeGeneration)
        try container.encode(authorityNonce, forKey: .authorityNonce)
        try container.encode(authorityTag, forKey: .authorityTag)
        try container.encode(authorityScope, forKey: .authorityScope)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case operationID
        case correlationID
        case occurredAtUTC
        case operationIdentifier
        case runtimeGeneration
        case authorityNonce
        case authorityTag
        case authorityScope
    }
}

public enum RuntimeOperationContextError: Error, Equatable, Sendable {
    case invalidContext
    case unsupportedSchema
}

public enum RuntimeOperationContextAuthorityScope: String, Codable, Sendable {
    /// The authority key is runtime-private and durable across launches.
    case persistent
    /// The authority is valid only for the current runtime generation. Core
    /// retains evidence and requests a recovery context on a later launch.
    case runtimeGeneration
}

public enum RuntimeBackgroundOperationPurpose: String, Codable, CaseIterable, Sendable {
    case coreBootstrap = "core-bootstrap"
    case coreReconciliation = "core-reconciliation"
    case evidenceRecovery = "evidence-recovery"
    case persistenceMigration = "persistence-migration"
}

public enum ProgressionSubmissionContractError: Error, Equatable, Sendable {
    case emptyBatch
    case invalidBatchIndex
    case invalidBatchCount
    case invalidFactCount
    case invalidFactSlot
    case duplicateFact
    case invalidReceipt
}

public struct ProgressionFactSlot: RawRepresentable, Codable, Hashable, Sendable,
    Comparable
{
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct SlottedProgressionEventFact: Codable, Equatable, Sendable {
    public let slot: ProgressionFactSlot
    public let fact: ProgressionEventFact

    public init(slot: ProgressionFactSlot, fact: ProgressionEventFact) throws {
        self.slot = slot
        self.fact = fact
    }
}

/// One deterministic physical outbox transaction. Larger logical operations
/// retain their full evidence in Core and submit consecutive batches.
public struct ProgressionEventFactBatch: Codable, Equatable, Sendable {
    public static let maximumFactsPerBatch = ModuleStateTransaction.maximumMutations - 1
    public static let maximumBatchesPerOperation =
        ModuleStateTransaction.maximumMutations - 1
    public static let maximumFactsPerOperation =
        maximumFactsPerBatch * maximumBatchesPerOperation

    public let batchIndex: UInt32
    public let totalBatchCount: UInt32
    public let totalFactCount: UInt32
    public let facts: [SlottedProgressionEventFact]

    public init(
        batchIndex: UInt32,
        totalBatchCount: UInt32,
        totalFactCount: UInt32,
        facts: [SlottedProgressionEventFact]
    ) throws {
        guard !facts.isEmpty else {
            throw ProgressionSubmissionContractError.emptyBatch
        }
        guard facts.count <= Self.maximumFactsPerBatch else {
            throw ProgressionSubmissionContractError.invalidFactCount
        }
        guard totalFactCount > 0,
              totalFactCount <= UInt32(Self.maximumFactsPerOperation)
        else {
            throw ProgressionSubmissionContractError.invalidFactCount
        }
        let maximum = UInt64(Self.maximumFactsPerBatch)
        let expectedBatchCount = UInt32(
            (UInt64(totalFactCount) + maximum - 1) / maximum
        )
        guard totalBatchCount == expectedBatchCount,
              totalBatchCount > 0,
              totalBatchCount <= UInt32(Self.maximumBatchesPerOperation)
        else {
            throw ProgressionSubmissionContractError.invalidBatchCount
        }
        guard batchIndex < totalBatchCount else {
            throw ProgressionSubmissionContractError.invalidBatchIndex
        }
        let expectedStart = UInt64(batchIndex) * maximum
        let remaining = UInt64(totalFactCount) - expectedStart
        let expectedFactCount = Int(min(maximum, remaining))
        guard facts.count == expectedFactCount else {
            throw ProgressionSubmissionContractError.invalidFactCount
        }
        for (offset, slotted) in facts.enumerated() {
            guard UInt64(slotted.slot.rawValue) == expectedStart + UInt64(offset) else {
                throw ProgressionSubmissionContractError.invalidFactSlot
            }
            guard !facts[..<offset].contains(where: { $0.fact == slotted.fact }) else {
                throw ProgressionSubmissionContractError.duplicateFact
            }
        }
        self.batchIndex = batchIndex
        self.totalBatchCount = totalBatchCount
        self.totalFactCount = totalFactCount
        self.facts = facts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            batchIndex: container.decode(UInt32.self, forKey: .batchIndex),
            totalBatchCount: container.decode(UInt32.self, forKey: .totalBatchCount),
            totalFactCount: container.decode(UInt32.self, forKey: .totalFactCount),
            facts: container.decode([SlottedProgressionEventFact].self, forKey: .facts)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case batchIndex
        case totalBatchCount
        case totalFactCount
        case facts
    }
}

public struct ProgressionOutboxEventReceipt: Codable, Equatable, Sendable {
    public let slot: ProgressionFactSlot
    public let eventID: EventID

    public init(slot: ProgressionFactSlot, eventID: EventID) {
        self.slot = slot
        self.eventID = eventID
    }
}

public struct ProgressionOutboxBatchReceipt: Codable, Equatable, Sendable {
    public let contextID: RuntimeOperationID
    public let batchIndex: UInt32
    public let events: [ProgressionOutboxEventReceipt]
    public let correlationID: CorrelationID
    public let durableAt: Date
    public let outboxRevision: UInt64

    public var eventIDsBySlot: [ProgressionFactSlot: EventID] {
        Dictionary(uniqueKeysWithValues: events.map { ($0.slot, $0.eventID) })
    }

    /// Verifies receipt ownership without exposing the context's runtime IDs.
    public func matches(context: RuntimePersistableOperationContext) -> Bool {
        context.matches(operationID: contextID)
    }

    public init(
        contextID: RuntimeOperationID,
        batchIndex: UInt32,
        eventIDsBySlot: [ProgressionFactSlot: EventID],
        correlationID: CorrelationID,
        durableAt: Date,
        outboxRevision: UInt64
    ) throws {
        guard !contextID.rawValue.isEmpty,
              !eventIDsBySlot.isEmpty,
              eventIDsBySlot.count <= ProgressionEventFactBatch.maximumFactsPerBatch,
              durableAt.timeIntervalSinceReferenceDate.isFinite,
              outboxRevision > 0
        else {
            throw ProgressionSubmissionContractError.invalidReceipt
        }
        self.contextID = contextID
        self.batchIndex = batchIndex
        events = eventIDsBySlot
            .map { ProgressionOutboxEventReceipt(slot: $0.key, eventID: $0.value) }
            .sorted { $0.slot < $1.slot }
        self.correlationID = correlationID
        self.durableAt = progressionSubmissionDate(
            milliseconds: try progressionSubmissionMilliseconds(durableAt)
        )
        self.outboxRevision = outboxRevision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedEvents = try container.decode(
            [ProgressionOutboxEventReceipt].self,
            forKey: .events
        )
        guard Set(decodedEvents.map(\.slot)).count == decodedEvents.count else {
            throw ProgressionSubmissionContractError.invalidReceipt
        }
        try self.init(
            contextID: container.decode(RuntimeOperationID.self, forKey: .contextID),
            batchIndex: container.decode(UInt32.self, forKey: .batchIndex),
            eventIDsBySlot: Dictionary(
                uniqueKeysWithValues: decodedEvents.map { ($0.slot, $0.eventID) }
            ),
            correlationID: container.decode(CorrelationID.self, forKey: .correlationID),
            durableAt: progressionSubmissionDate(
                milliseconds: container.decode(Int64.self, forKey: .durableAt)
            ),
            outboxRevision: container.decode(UInt64.self, forKey: .outboxRevision)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contextID, forKey: .contextID)
        try container.encode(batchIndex, forKey: .batchIndex)
        try container.encode(events, forKey: .events)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(
            progressionSubmissionMilliseconds(durableAt),
            forKey: .durableAt
        )
        try container.encode(outboxRevision, forKey: .outboxRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case contextID
        case batchIndex
        case events
        case correlationID
        case durableAt
        case outboxRevision
    }
}
