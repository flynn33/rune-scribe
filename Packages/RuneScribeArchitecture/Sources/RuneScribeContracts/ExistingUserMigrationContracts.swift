import Foundation

public enum ExistingUserMigrationContractError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case tooManyCiphers(maximum: Int)
    case duplicateCipherToken
    case invalidOrigin
    case invalidReceipt
    case invalidApplyResult
    case invalidPage
    case invalidAggregateDigest
    case tooManyAggregateCiphers(maximum: UInt32)
}

private func existingUserMigrationIsSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48 ... 57).contains($0) || (97 ... 102).contains($0)
    }
}

private struct ExistingUserMigrationAnyCodingKey: CodingKey {
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

private func existingUserMigrationRejectUnknownKeys<Key>(
    from decoder: Decoder,
    allowedBy _: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(
        keyedBy: ExistingUserMigrationAnyCodingKey.self
    )
    let allowed = Set(Key.allCases.map(\.stringValue))
    guard let unknown = container.allKeys.first(where: {
        !allowed.contains($0.stringValue)
    }) else { return }
    throw DecodingError.dataCorrupted(
        .init(
            codingPath: decoder.codingPath + [unknown],
            debugDescription: "Unknown existing-user migration field."
        )
    )
}

private func existingUserMigrationMilliseconds(_ date: Date) throws -> Int64 {
    let scaled = date.timeIntervalSince1970 * 1_000
    let rounded = scaled.rounded()
    guard rounded.isFinite,
          rounded >= Double(Int64.min),
          rounded < Double(Int64.max)
    else {
        throw ExistingUserMigrationContractError.invalidReceipt
    }
    return Int64(rounded)
}

private func existingUserMigrationDate(milliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
}

/// The only per-cipher information allowed across the existing-user migration
/// rail. Raw cipher identifiers, contacts, delivery state, and key material are
/// intentionally absent.
public struct ExistingUserMigrationCipherDTO: Codable, Equatable, Sendable {
    public let cipherToken: CipherToken
    public let origin: DomainEventOrigin

    public init(
        cipherToken: CipherToken,
        origin: DomainEventOrigin
    ) throws {
        guard origin == .generated || origin == .imported else {
            throw ExistingUserMigrationContractError.invalidOrigin
        }
        self.cipherToken = cipherToken
        self.origin = origin
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cipherToken: container.decode(CipherToken.self, forKey: .cipherToken),
            origin: container.decode(DomainEventOrigin.self, forKey: .origin)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case cipherToken
        case origin
    }
}

/// Versioned, bounded, canonical Core snapshot for first-store migration.
public struct ExistingUserMigrationSnapshotDTO: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maximumCipherCount = 4_096

    public let schemaVersion: UInt16
    public let ciphers: [ExistingUserMigrationCipherDTO]

    public init(ciphers: [ExistingUserMigrationCipherDTO]) throws {
        guard ciphers.count <= Self.maximumCipherCount else {
            throw ExistingUserMigrationContractError.tooManyCiphers(
                maximum: Self.maximumCipherCount
            )
        }
        let canonical = ciphers.sorted {
            if $0.cipherToken != $1.cipherToken {
                return $0.cipherToken < $1.cipherToken
            }
            return $0.origin.rawValue < $1.origin.rawValue
        }
        guard Set(canonical.map(\.cipherToken)).count == canonical.count else {
            throw ExistingUserMigrationContractError.duplicateCipherToken
        }
        schemaVersion = Self.currentSchemaVersion
        self.ciphers = canonical
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(UInt16.self, forKey: .schemaVersion)
            == Self.currentSchemaVersion
        else {
            throw ExistingUserMigrationContractError.unsupportedSchemaVersion
        }
        try self.init(
            ciphers: container.decode(
                [ExistingUserMigrationCipherDTO].self,
                forKey: .ciphers
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case ciphers
    }
}

public struct ExistingUserMigrationTransactionID: UUIDBackedIdentifier {
    public let rawValue: UUID

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Runtime-owned request delivered to Progression. Core cannot construct this
/// value through the public API and cannot select the transaction identity.
public struct ExistingUserMigrationDeliveryDTO: Codable, Equatable, Sendable {
    public let transactionID: ExistingUserMigrationTransactionID
    public let snapshot: ExistingUserMigrationSnapshotDTO

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(
        transactionID: ExistingUserMigrationTransactionID,
        snapshot: ExistingUserMigrationSnapshotDTO
    ) {
        self.transactionID = transactionID
        self.snapshot = snapshot
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transactionID: try container.decode(
                ExistingUserMigrationTransactionID.self,
                forKey: .transactionID
            ),
            snapshot: try container.decode(
                ExistingUserMigrationSnapshotDTO.self,
                forKey: .snapshot
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transactionID
        case snapshot
    }
}

/// One bounded page in the version-2 existing-user migration handoff. Runtime
/// constructs this value only after validating the complete, globally
/// canonical Core snapshot. Fixed page boundaries make the aggregate digest
/// reproducible without ever placing the complete snapshot in one endpoint
/// request or state-store record.
public struct ExistingUserMigrationPageDTO: Codable, Equatable, Sendable {
    public static let currentHandoffSchemaVersion: UInt16 = 2

    public let handoffSchemaVersion: UInt16
    public let pageIndex: UInt32
    public let pageCount: UInt32
    public let totalCipherCount: UInt32
    public let aggregateDigest: String
    public let snapshot: ExistingUserMigrationSnapshotDTO

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(
        pageIndex: UInt32,
        pageCount: UInt32,
        totalCipherCount: UInt32,
        aggregateDigest: String,
        snapshot: ExistingUserMigrationSnapshotDTO
    ) throws {
        let maximum = UInt64(ExistingUserMigrationSnapshotDTO.maximumCipherCount)
        let total = UInt64(totalCipherCount)
        let index = UInt64(pageIndex)
        let count = UInt64(pageCount)
        guard count >= 2, index < count, total > maximum else {
            throw ExistingUserMigrationContractError.invalidPage
        }
        let expectedPageCount = total == 0 ? 0 : ((total - 1) / maximum) + 1
        let expectedPageSize = index + 1 < count
            ? maximum
            : total - (maximum * (count - 1))
        guard count == expectedPageCount,
              snapshot.schemaVersion == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              UInt64(snapshot.ciphers.count) == expectedPageSize
        else {
            throw ExistingUserMigrationContractError.invalidPage
        }
        guard existingUserMigrationIsSHA256Hex(aggregateDigest) else {
            throw ExistingUserMigrationContractError.invalidAggregateDigest
        }
        handoffSchemaVersion = Self.currentHandoffSchemaVersion
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        self.totalCipherCount = totalCipherCount
        self.aggregateDigest = aggregateDigest
        self.snapshot = snapshot
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(UInt16.self, forKey: .handoffSchemaVersion)
            == Self.currentHandoffSchemaVersion
        else {
            throw ExistingUserMigrationContractError.unsupportedSchemaVersion
        }
        try self.init(
            pageIndex: container.decode(UInt32.self, forKey: .pageIndex),
            pageCount: container.decode(UInt32.self, forKey: .pageCount),
            totalCipherCount: container.decode(UInt32.self, forKey: .totalCipherCount),
            aggregateDigest: container.decode(String.self, forKey: .aggregateDigest),
            snapshot: container.decode(
                ExistingUserMigrationSnapshotDTO.self,
                forKey: .snapshot
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case handoffSchemaVersion
        case pageIndex
        case pageCount
        case totalCipherCount
        case aggregateDigest
        case snapshot
    }
}

/// Runtime-owned page delivery. Core cannot select the aggregate transaction
/// identity or construct a delivery through the public API.
public struct ExistingUserMigrationPageDeliveryDTO: Codable, Equatable, Sendable {
    public let transactionID: ExistingUserMigrationTransactionID
    public let page: ExistingUserMigrationPageDTO

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(
        transactionID: ExistingUserMigrationTransactionID,
        page: ExistingUserMigrationPageDTO
    ) {
        self.transactionID = transactionID
        self.page = page
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            transactionID: try container.decode(
                ExistingUserMigrationTransactionID.self,
                forKey: .transactionID
            ),
            page: try container.decode(
                ExistingUserMigrationPageDTO.self,
                forKey: .page
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transactionID
        case page
    }
}

public enum ExistingUserMigrationApplyResult: Codable, Equatable, Sendable {
    case applied(
        grantTransactionID: GrantTransactionID,
        revision: UInt64,
        delta: ProgressionStateDeltaSummary
    )
    case duplicate
    case rejectedPermanent(reason: ProgressionRejectionCode)
    case deferredUnsupportedSchema
    case deferredStoreUnavailable

    public var isTerminalAcknowledgement: Bool {
        switch self {
        case .applied, .duplicate, .rejectedPermanent:
            true
        case .deferredUnsupportedSchema, .deferredStoreUnavailable:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(Outcome.self, forKey: .outcome)
        let present = Set(container.allKeys)
        switch outcome {
        case .applied:
            guard present == Set([
                .outcome, .grantTransactionID, .revision, .delta,
            ]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            let revision = try container.decode(UInt64.self, forKey: .revision)
            guard revision > 0 else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .applied(
                grantTransactionID: try container.decode(
                    GrantTransactionID.self,
                    forKey: .grantTransactionID
                ),
                revision: revision,
                delta: try container.decode(
                    ProgressionStateDeltaSummary.self,
                    forKey: .delta
                )
            )
        case .duplicate:
            guard present == Set([.outcome]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .duplicate
        case .rejectedPermanent:
            guard present == Set([.outcome, .reason]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .rejectedPermanent(
                reason: try container.decode(
                    ProgressionRejectionCode.self,
                    forKey: .reason
                )
            )
        case .deferredUnsupportedSchema:
            guard present == Set([.outcome]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .deferredUnsupportedSchema
        case .deferredStoreUnavailable:
            guard present == Set([.outcome]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .deferredStoreUnavailable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .applied(grantTransactionID, revision, delta):
            guard revision > 0 else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            try container.encode(Outcome.applied, forKey: .outcome)
            try container.encode(
                grantTransactionID,
                forKey: .grantTransactionID
            )
            try container.encode(revision, forKey: .revision)
            try container.encode(delta, forKey: .delta)
        case .duplicate:
            try container.encode(Outcome.duplicate, forKey: .outcome)
        case let .rejectedPermanent(reason):
            try container.encode(Outcome.rejectedPermanent, forKey: .outcome)
            try container.encode(reason, forKey: .reason)
        case .deferredUnsupportedSchema:
            try container.encode(
                Outcome.deferredUnsupportedSchema,
                forKey: .outcome
            )
        case .deferredStoreUnavailable:
            try container.encode(
                Outcome.deferredStoreUnavailable,
                forKey: .outcome
            )
        }
    }

    private enum Outcome: String, Codable, Sendable {
        case applied
        case duplicate
        case rejectedPermanent = "rejected-permanent"
        case deferredUnsupportedSchema = "deferred-unsupported-schema"
        case deferredStoreUnavailable = "deferred-store-unavailable"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case outcome
        case grantTransactionID
        case revision
        case delta
        case reason
    }
}

/// Progression's acknowledgement for one version-2 page. `accepted` means the
/// page is durable but the aggregate has not yet been promoted. `outcome`
/// carries the same terminal/deferred semantics as the schema-v1 handoff.
public enum ExistingUserMigrationPageApplyResult: Codable, Equatable, Sendable {
    case accepted(pageIndex: UInt32)
    case outcome(ExistingUserMigrationApplyResult)

    public var isTerminalAcknowledgement: Bool {
        switch self {
        case .accepted:
            false
        case let .outcome(result):
            result.isTerminalAcknowledgement
        }
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(Outcome.self, forKey: .outcome)
        let present = Set(container.allKeys)
        switch outcome {
        case .accepted:
            guard present == Set([.outcome, .pageIndex]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .accepted(
                pageIndex: try container.decode(UInt32.self, forKey: .pageIndex)
            )
        case .result:
            guard present == Set([.outcome, .result]) else {
                throw ExistingUserMigrationContractError.invalidApplyResult
            }
            self = .outcome(
                try container.decode(
                    ExistingUserMigrationApplyResult.self,
                    forKey: .result
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .accepted(pageIndex):
            try container.encode(Outcome.accepted, forKey: .outcome)
            try container.encode(pageIndex, forKey: .pageIndex)
        case let .outcome(result):
            try container.encode(Outcome.result, forKey: .outcome)
            try container.encode(result, forKey: .result)
        }
    }

    private enum Outcome: String, Codable, Sendable {
        case accepted
        case result
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case outcome
        case pageIndex
        case result
    }
}

public struct ExistingUserMigrationHandoffReceipt: Codable, Equatable, Sendable {
    public let transactionID: ExistingUserMigrationTransactionID
    public let snapshotSchemaVersion: UInt16
    public let cipherCount: UInt32
    public let durableAt: Date

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(
        transactionID: ExistingUserMigrationTransactionID,
        snapshotSchemaVersion: UInt16,
        cipherCount: UInt32,
        durableAt: Date
    ) throws {
        guard snapshotSchemaVersion
            == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
            cipherCount <= ExistingUserMigrationSnapshotDTO.maximumCipherCount,
            durableAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ExistingUserMigrationContractError.invalidReceipt
        }
        self.transactionID = transactionID
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.cipherCount = cipherCount
        self.durableAt = existingUserMigrationDate(
            milliseconds: try existingUserMigrationMilliseconds(durableAt)
        )
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transactionID: container.decode(
                ExistingUserMigrationTransactionID.self,
                forKey: .transactionID
            ),
            snapshotSchemaVersion: container.decode(
                UInt16.self,
                forKey: .snapshotSchemaVersion
            ),
            cipherCount: container.decode(UInt32.self, forKey: .cipherCount),
            durableAt: existingUserMigrationDate(
                milliseconds: container.decode(Int64.self, forKey: .durableAt)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(snapshotSchemaVersion, forKey: .snapshotSchemaVersion)
        try container.encode(cipherCount, forKey: .cipherCount)
        try container.encode(
            existingUserMigrationMilliseconds(durableAt),
            forKey: .durableAt
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transactionID
        case snapshotSchemaVersion
        case cipherCount
        case durableAt
    }
}

/// Receipt returned by the full-snapshot convenience API. For schema-v1 the
/// page count is one; larger snapshots use the schema-v2 bounded page rail.
public struct ExistingUserMigrationPagedHandoffReceipt: Codable, Equatable, Sendable {
    public let transactionID: ExistingUserMigrationTransactionID
    public let handoffSchemaVersion: UInt16
    public let snapshotSchemaVersion: UInt16
    public let cipherCount: UInt32
    public let pageCount: UInt32
    public let durableAt: Date

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(
        transactionID: ExistingUserMigrationTransactionID,
        handoffSchemaVersion: UInt16,
        snapshotSchemaVersion: UInt16,
        cipherCount: UInt32,
        pageCount: UInt32,
        durableAt: Date
    ) throws {
        let maximum = UInt32(ExistingUserMigrationSnapshotDTO.maximumCipherCount)
        let expectedPageCount = cipherCount == 0
            ? 1
            : ((cipherCount - 1) / maximum) + 1
        guard snapshotSchemaVersion == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              (handoffSchemaVersion == 1 ||
                handoffSchemaVersion == ExistingUserMigrationPageDTO.currentHandoffSchemaVersion),
              pageCount == expectedPageCount,
              (handoffSchemaVersion == 1) == (pageCount == 1),
              durableAt.timeIntervalSinceReferenceDate.isFinite
        else {
            throw ExistingUserMigrationContractError.invalidReceipt
        }
        self.transactionID = transactionID
        self.handoffSchemaVersion = handoffSchemaVersion
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.cipherCount = cipherCount
        self.pageCount = pageCount
        self.durableAt = existingUserMigrationDate(
            milliseconds: try existingUserMigrationMilliseconds(durableAt)
        )
    }

    @_spi(RuntimeExistingUserMigrationAuthority)
    public init(schemaV1 receipt: ExistingUserMigrationHandoffReceipt) throws {
        try self.init(
            transactionID: receipt.transactionID,
            handoffSchemaVersion: 1,
            snapshotSchemaVersion: receipt.snapshotSchemaVersion,
            cipherCount: receipt.cipherCount,
            pageCount: 1,
            durableAt: receipt.durableAt
        )
    }

    public init(from decoder: Decoder) throws {
        try existingUserMigrationRejectUnknownKeys(
            from: decoder,
            allowedBy: CodingKeys.self
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transactionID: container.decode(
                ExistingUserMigrationTransactionID.self,
                forKey: .transactionID
            ),
            handoffSchemaVersion: container.decode(
                UInt16.self,
                forKey: .handoffSchemaVersion
            ),
            snapshotSchemaVersion: container.decode(
                UInt16.self,
                forKey: .snapshotSchemaVersion
            ),
            cipherCount: container.decode(UInt32.self, forKey: .cipherCount),
            pageCount: container.decode(UInt32.self, forKey: .pageCount),
            durableAt: existingUserMigrationDate(
                milliseconds: container.decode(Int64.self, forKey: .durableAt)
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transactionID, forKey: .transactionID)
        try container.encode(handoffSchemaVersion, forKey: .handoffSchemaVersion)
        try container.encode(snapshotSchemaVersion, forKey: .snapshotSchemaVersion)
        try container.encode(cipherCount, forKey: .cipherCount)
        try container.encode(pageCount, forKey: .pageCount)
        try container.encode(
            existingUserMigrationMilliseconds(durableAt),
            forKey: .durableAt
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case transactionID
        case handoffSchemaVersion
        case snapshotSchemaVersion
        case cipherCount
        case pageCount
        case durableAt
    }
}
