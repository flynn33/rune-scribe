import Foundation

public enum ModuleStateStoreError: Error, Equatable, Sendable {
    case unavailable
    case invalidRequest
    case payloadTooLarge(maximumBytes: Int)
    case transactionTooLarge(maximumMutations: Int)
    case revisionConflict(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID,
        expected: UInt64?,
        actual: UInt64?
    )
    case quarantined
    case integrityMismatch
    case unreadable
    case corrupt
    case injectedFailure(String)
}

public struct ModuleStateNamespace: Codable, Equatable, Hashable, Sendable {
    public let moduleID: ModuleIdentifier

    public init(moduleID: ModuleIdentifier) {
        self.moduleID = moduleID
    }
}

public enum ModuleStateLoadState: String, Codable, CaseIterable, Sendable {
    case absent
    case loaded
    case migrated
    case quarantined
    case unreadable
    case corrupt
}

public enum ModuleStateAccessDisposition: String, Codable, CaseIterable, Sendable {
    case readWrite
    case blocked
}

public struct ModuleStateHealthSnapshot: Codable, Equatable, Sendable {
    public let namespace: ModuleStateNamespace
    public let loadState: ModuleStateLoadState
    public let storeRevision: UInt64
    public let namespaceSchemaVersion: UInt32?
    public let recordCount: UInt64
    public let quarantinedRecordCount: UInt64
    public let accessDisposition: ModuleStateAccessDisposition
    public let capturedAt: Date
    public let diagnosticCode: String?

    public init(
        namespace: ModuleStateNamespace,
        loadState: ModuleStateLoadState,
        storeRevision: UInt64,
        namespaceSchemaVersion: UInt32?,
        recordCount: UInt64,
        quarantinedRecordCount: UInt64 = 0,
        accessDisposition: ModuleStateAccessDisposition = .readWrite,
        capturedAt: Date,
        diagnosticCode: String? = nil
    ) {
        self.namespace = namespace
        self.loadState = loadState
        self.storeRevision = storeRevision
        self.namespaceSchemaVersion = namespaceSchemaVersion
        self.recordCount = recordCount
        self.quarantinedRecordCount = quarantinedRecordCount
        self.accessDisposition = accessDisposition
        self.capturedAt = capturedAt
        self.diagnosticCode = diagnosticCode
    }
}

public struct ModuleStateRecordKey: Codable, Equatable, Hashable, Sendable, Comparable {
    public let collectionID: ModuleStateCollectionID
    public let recordID: ModuleStateRecordID

    public init(collectionID: ModuleStateCollectionID, recordID: ModuleStateRecordID) {
        self.collectionID = collectionID
        self.recordID = recordID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.collectionID != rhs.collectionID {
            return lhs.collectionID < rhs.collectionID
        }
        return lhs.recordID < rhs.recordID
    }
}

public struct ModuleStateRecord: Codable, Equatable, Sendable {
    public let key: ModuleStateRecordKey
    public let schemaVersion: UInt32
    public let revision: UInt64
    public let payload: Data
    public let integrityDigest: Data
    public let updatedAt: Date

    public init(
        key: ModuleStateRecordKey,
        schemaVersion: UInt32,
        revision: UInt64,
        payload: Data,
        integrityDigest: Data,
        updatedAt: Date
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.payload = payload
        self.integrityDigest = integrityDigest
        self.updatedAt = updatedAt
    }
}

public struct ModuleStateScanCursor: Codable, Equatable, Hashable, Sendable {
    public let collectionID: ModuleStateCollectionID
    public let afterRecordID: ModuleStateRecordID
    public let observedStoreRevision: UInt64

    public init(
        collectionID: ModuleStateCollectionID,
        afterRecordID: ModuleStateRecordID,
        observedStoreRevision: UInt64
    ) {
        self.collectionID = collectionID
        self.afterRecordID = afterRecordID
        self.observedStoreRevision = observedStoreRevision
    }
}

public struct ModuleStateScanRequest: Codable, Equatable, Sendable {
    public static let maximumLimit = 200

    public let collectionID: ModuleStateCollectionID
    public let limit: Int
    public let cursor: ModuleStateScanCursor?

    public init(
        collectionID: ModuleStateCollectionID,
        limit: Int,
        cursor: ModuleStateScanCursor? = nil
    ) throws {
        guard (1 ... Self.maximumLimit).contains(limit),
              cursor == nil || cursor?.collectionID == collectionID
        else {
            throw ModuleStateStoreError.invalidRequest
        }
        self.collectionID = collectionID
        self.limit = limit
        self.cursor = cursor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            collectionID: container.decode(ModuleStateCollectionID.self, forKey: .collectionID),
            limit: container.decode(Int.self, forKey: .limit),
            cursor: container.decodeIfPresent(ModuleStateScanCursor.self, forKey: .cursor)
        )
    }
}

public struct ModuleStateScanPage: Codable, Equatable, Sendable {
    public let records: [ModuleStateRecord]
    public let nextCursor: ModuleStateScanCursor?

    public init(records: [ModuleStateRecord], nextCursor: ModuleStateScanCursor?) {
        self.records = records
        self.nextCursor = nextCursor
    }
}

public enum ModuleStateRevisionExpectation: Codable, Equatable, Sendable {
    case any
    case absent
    case exact(UInt64)
}

public struct ModuleStateUpsert: Codable, Equatable, Sendable {
    public let key: ModuleStateRecordKey
    public let schemaVersion: UInt32
    public let payload: Data
    public let expectedRevision: ModuleStateRevisionExpectation

    public init(
        key: ModuleStateRecordKey,
        schemaVersion: UInt32,
        payload: Data,
        expectedRevision: ModuleStateRevisionExpectation = .any
    ) {
        self.key = key
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.expectedRevision = expectedRevision
    }
}

public struct ModuleStateDelete: Codable, Equatable, Sendable {
    public let key: ModuleStateRecordKey
    public let expectedRevision: ModuleStateRevisionExpectation

    public init(
        key: ModuleStateRecordKey,
        expectedRevision: ModuleStateRevisionExpectation = .any
    ) {
        self.key = key
        self.expectedRevision = expectedRevision
    }
}

public enum ModuleStateMutation: Codable, Equatable, Sendable {
    case upsert(ModuleStateUpsert)
    case delete(ModuleStateDelete)

    public var key: ModuleStateRecordKey {
        switch self {
        case .upsert(let value): value.key
        case .delete(let value): value.key
        }
    }
}

public struct ModuleStateTransaction: Codable, Equatable, Sendable {
    public static let maximumMutations = 128

    public let transactionID: UUID
    public let mutations: [ModuleStateMutation]

    public init(transactionID: UUID, mutations: [ModuleStateMutation]) throws {
        guard !mutations.isEmpty, mutations.count <= Self.maximumMutations else {
            throw ModuleStateStoreError.transactionTooLarge(
                maximumMutations: Self.maximumMutations
            )
        }
        guard Set(mutations.map(\.key)).count == mutations.count else {
            throw ModuleStateStoreError.invalidRequest
        }
        self.transactionID = transactionID
        self.mutations = mutations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            transactionID: container.decode(UUID.self, forKey: .transactionID),
            mutations: container.decode([ModuleStateMutation].self, forKey: .mutations)
        )
    }
}

public struct ModuleStateMutationResult: Codable, Equatable, Sendable {
    public let key: ModuleStateRecordKey
    public let revision: UInt64?

    public init(key: ModuleStateRecordKey, revision: UInt64?) {
        self.key = key
        self.revision = revision
    }
}

public struct ModuleStateTransactionResult: Codable, Equatable, Sendable {
    public let transactionID: UUID
    public let storeRevision: UInt64
    public let mutations: [ModuleStateMutationResult]

    public init(
        transactionID: UUID,
        storeRevision: UInt64,
        mutations: [ModuleStateMutationResult]
    ) {
        self.transactionID = transactionID
        self.storeRevision = storeRevision
        self.mutations = mutations
    }
}

/// Host-owned physical storage seam. RuntimeCore scopes every call to the
/// requesting module before invoking this adapter. Module code receives only a
/// revocable RuntimeModuleStateClient and never sees this protocol instance.
public protocol ModuleStateStore: Sendable {
    func prepareNamespace(
        _ namespace: ModuleStateNamespace,
        schemaVersion: UInt32
    ) async throws -> ModuleStateHealthSnapshot

    func fetch(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey
    ) async throws -> ModuleStateRecord?

    func scan(
        namespace: ModuleStateNamespace,
        request: ModuleStateScanRequest
    ) async throws -> ModuleStateScanPage

    func transact(
        namespace: ModuleStateNamespace,
        transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult

    func quarantine(
        namespace: ModuleStateNamespace,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot

    func quarantineRecord(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot

    func health(
        namespace: ModuleStateNamespace
    ) async -> ModuleStateHealthSnapshot
}

public extension ModuleStateStore {
    func quarantineRecord(
        namespace _: ModuleStateNamespace,
        key _: ModuleStateRecordKey,
        expectedRevision _: UInt64,
        diagnosticCode _: String
    ) async throws -> ModuleStateHealthSnapshot {
        throw ModuleStateStoreError.unavailable
    }
}
