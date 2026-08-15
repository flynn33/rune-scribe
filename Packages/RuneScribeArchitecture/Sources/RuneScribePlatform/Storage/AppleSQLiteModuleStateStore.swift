@preconcurrency import CoreData
import CryptoKit
import Foundation
import RuneScribeContracts

private func protectSQLiteStoreFiles(at storeURL: URL) throws {
    let filenames = [
        storeURL.path,
        storeURL.path + "-wal",
        storeURL.path + "-shm",
    ]
    for filename in filenames where FileManager.default.fileExists(atPath: filename) {
        #if os(iOS)
        try FileManager.default.setAttributes(
            [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                .posixPermissions: 0o600,
            ],
            ofItemAtPath: filename
        )
        #else
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: filename
        )
        #endif
    }
}

/// Core Data/SQLite implementation of the runtime-owned module state rail.
///
/// The store is deliberately generic. It persists only namespaced, versioned
/// bytes and never exposes Core Data objects, contexts, coordinators, or URLs
/// through the module-state contract.
public final class AppleSQLiteModuleStateStore: ModuleStateStore, @unchecked Sendable {
    public static let maximumPayloadByteCount = 1_048_576
    public static let maximumTransactionPayloadByteCount = 8_388_608

    private static let ownedDirectoryName = "RuneScribe/RuntimeModuleState"
    private static let storeFilename = "module-state.sqlite"

    private let stack: CoreDataStack

    /// Creates the production store below the app's Application Support
    /// directory. The owned directory is never accepted through a symbolic
    /// link, and the SQLite store is configured for platform file protection.
    public init(applicationSupportDirectory: URL? = nil) throws {
        let baseDirectory = (
            applicationSupportDirectory
                ?? FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0]
        ).resolvingSymlinksInPath().standardizedFileURL
        let ownedDirectory = baseDirectory
            .appendingPathComponent(Self.ownedDirectoryName, isDirectory: true)
            .standardizedFileURL

        try Self.prepareOwnedDirectory(ownedDirectory, below: baseDirectory)
        let storeURL = ownedDirectory
            .appendingPathComponent(Self.storeFilename, isDirectory: false)
            .standardizedFileURL
        stack = try CoreDataStack(storeURL: storeURL)
        try protectSQLiteStoreFiles(at: storeURL)
    }

    /// Exact file injection is internal so tests can close and reopen one
    /// physical SQLite store without making its location part of the public
    /// runtime API.
    init(storeURL: URL) throws {
        let standardizedURL = storeURL.standardizedFileURL
        let directory = standardizedURL.deletingLastPathComponent()
        try Self.prepareOwnedDirectory(
            directory,
            below: directory.deletingLastPathComponent()
        )
        guard !Self.isSymbolicLink(at: standardizedURL) else {
            throw ModuleStateStoreError.unavailable
        }
        stack = try CoreDataStack(storeURL: standardizedURL)
        try protectSQLiteStoreFiles(at: standardizedURL)
    }

    public func prepareNamespace(
        _ namespace: ModuleStateNamespace,
        schemaVersion: UInt32
    ) async throws -> ModuleStateHealthSnapshot {
        guard Self.isValid(namespace: namespace), schemaVersion > 0 else {
            throw ModuleStateStoreError.invalidRequest
        }

        return try await stack.perform { context in
            do {
                if let metadata = try Self.fetchNamespace(namespace, context: context) {
                    try Self.validateNamespaceIntegrity(metadata)
                    let storedSchemaVersion = try Self.namespaceSchemaVersion(metadata)
                    let currentState = try Self.loadState(metadata)
                    let blocksAccess = try Self.bool(metadata, key: Schema.blocksAccess)

                    if currentState == .quarantined || currentState == .corrupt {
                        return try Self.snapshot(
                            namespace: namespace,
                            metadata: metadata,
                            context: context
                        )
                    }

                    if storedSchemaVersion < schemaVersion {
                        try Self.setUInt32(
                            schemaVersion,
                            on: metadata,
                            key: Schema.namespaceSchemaVersion
                        )
                        try Self.incrementStoreRevision(metadata)
                        metadata.setValue(
                            ModuleStateLoadState.migrated.rawValue,
                            forKey: Schema.loadState
                        )
                        metadata.setValue(false, forKey: Schema.blocksAccess)
                        metadata.setValue(nil, forKey: Schema.diagnosticCode)
                        metadata.setValue(Date(), forKey: Schema.updatedAt)
                        try Self.updateNamespaceIntegrity(metadata)
                        try context.save()
                    } else if storedSchemaVersion > schemaVersion {
                        if currentState != .unreadable || !blocksAccess {
                            try Self.incrementStoreRevision(metadata)
                            metadata.setValue(
                                ModuleStateLoadState.unreadable.rawValue,
                                forKey: Schema.loadState
                            )
                            metadata.setValue(true, forKey: Schema.blocksAccess)
                            metadata.setValue(
                                Diagnostic.schemaVersionNewer,
                                forKey: Schema.diagnosticCode
                            )
                            metadata.setValue(Date(), forKey: Schema.updatedAt)
                            try Self.updateNamespaceIntegrity(metadata)
                            try context.save()
                        }
                    } else if currentState == .unreadable && blocksAccess {
                        // A newer binary can recover a namespace that an older
                        // binary correctly refused to interpret.
                        metadata.setValue(
                            ModuleStateLoadState.loaded.rawValue,
                            forKey: Schema.loadState
                        )
                        metadata.setValue(false, forKey: Schema.blocksAccess)
                        metadata.setValue(nil, forKey: Schema.diagnosticCode)
                        metadata.setValue(Date(), forKey: Schema.updatedAt)
                        try Self.updateNamespaceIntegrity(metadata)
                        try context.save()
                    }

                    return try Self.snapshot(
                        namespace: namespace,
                        metadata: metadata,
                        context: context
                    )
                }

                let metadata = NSEntityDescription.insertNewObject(
                    forEntityName: Schema.namespaceEntity,
                    into: context
                )
                metadata.setValue(namespace.moduleID.rawValue, forKey: Schema.moduleID)
                try Self.setUInt32(
                    schemaVersion,
                    on: metadata,
                    key: Schema.namespaceSchemaVersion
                )
                try Self.setUInt64(0, on: metadata, key: Schema.storeRevision)
                metadata.setValue(
                    ModuleStateLoadState.absent.rawValue,
                    forKey: Schema.loadState
                )
                metadata.setValue(false, forKey: Schema.blocksAccess)
                metadata.setValue(nil, forKey: Schema.diagnosticCode)
                metadata.setValue(Date(), forKey: Schema.updatedAt)
                try Self.updateNamespaceIntegrity(metadata)
                try context.save()
                return try Self.snapshot(
                    namespace: namespace,
                    metadata: metadata,
                    context: context
                )
            } catch {
                context.rollback()
                throw Self.storeError(error)
            }
        }
    }

    public func fetch(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey
    ) async throws -> ModuleStateRecord? {
        guard Self.isValid(namespace: namespace) else {
            throw ModuleStateStoreError.invalidRequest
        }

        return try await stack.perform { context in
            do {
                guard let metadata = try Self.fetchNamespace(namespace, context: context) else {
                    return nil
                }
                try Self.requireAccessible(metadata)
                guard let object = try Self.fetchRecord(
                    namespace: namespace,
                    key: key,
                    context: context
                ) else {
                    return nil
                }
                guard !(try Self.bool(object, key: Schema.isQuarantined)) else {
                    throw ModuleStateStoreError.quarantined
                }

                do {
                    return try Self.record(
                        from: object,
                        namespace: namespace
                    )
                } catch let error as ModuleStateStoreError
                    where error == .integrityMismatch || error == .corrupt
                {
                    let diagnosticCode = error == .integrityMismatch
                        ? Diagnostic.integrityMismatch
                        : Diagnostic.invalidRecord
                    try Self.quarantineRecord(
                        object,
                        namespaceMetadata: metadata,
                        diagnosticCode: diagnosticCode,
                        context: context
                    )
                    throw error
                }
            } catch {
                context.rollback()
                throw Self.storeError(error)
            }
        }
    }

    public func scan(
        namespace: ModuleStateNamespace,
        request: ModuleStateScanRequest
    ) async throws -> ModuleStateScanPage {
        guard Self.isValid(namespace: namespace),
              request.cursor == nil || request.cursor?.collectionID == request.collectionID
        else {
            throw ModuleStateStoreError.invalidRequest
        }

        return try await stack.perform { context in
            do {
                guard let metadata = try Self.fetchNamespace(namespace, context: context) else {
                    return ModuleStateScanPage(records: [], nextCursor: nil)
                }
                try Self.requireAccessible(metadata)
                let initialStoreRevision = try Self.uint64(
                    metadata,
                    key: Schema.storeRevision
                )
                if let cursor = request.cursor,
                   cursor.observedStoreRevision != initialStoreRevision {
                    throw ModuleStateStoreError.invalidRequest
                }

                var records: [ModuleStateRecord] = []
                var afterRecordID = request.cursor?.afterRecordID.rawValue
                var quarantineDiagnosticCode: String?

                while records.count <= request.limit {
                    let batch = try Self.fetchRecordBatch(
                        namespace: namespace,
                        collectionID: request.collectionID,
                        afterRecordID: afterRecordID,
                        limit: min(ModuleStateScanRequest.maximumLimit + 1, request.limit + 1),
                        context: context
                    )
                    guard !batch.isEmpty else { break }

                    for object in batch {
                        let recordID = try Self.string(object, key: Schema.recordID)
                        afterRecordID = recordID
                        do {
                            records.append(
                                try Self.record(from: object, namespace: namespace)
                            )
                        } catch let error as ModuleStateStoreError
                            where error == .integrityMismatch || error == .corrupt
                        {
                            try Self.markRecordQuarantined(
                                object,
                                namespaceMetadata: metadata,
                                diagnosticCode: error == .integrityMismatch
                                    ? Diagnostic.integrityMismatch
                                    : Diagnostic.invalidRecord
                            )
                            quarantineDiagnosticCode = error == .integrityMismatch
                                ? Diagnostic.integrityMismatch
                                : Diagnostic.invalidRecord
                        }
                        if records.count > request.limit { break }
                    }

                    if records.count > request.limit || batch.count < request.limit + 1 {
                        break
                    }
                }

                if let quarantineDiagnosticCode {
                    try Self.incrementStoreRevision(metadata)
                    metadata.setValue(
                        ModuleStateLoadState.quarantined.rawValue,
                        forKey: Schema.loadState
                    )
                    metadata.setValue(
                        quarantineDiagnosticCode,
                        forKey: Schema.diagnosticCode
                    )
                    metadata.setValue(Date(), forKey: Schema.updatedAt)
                    try Self.updateNamespaceIntegrity(metadata)
                    try context.save()
                }

                let observedStoreRevision = try Self.uint64(
                    metadata,
                    key: Schema.storeRevision
                )
                let hasMore = records.count > request.limit
                let pageRecords = Array(records.prefix(request.limit))
                let nextCursor: ModuleStateScanCursor?
                if hasMore, let finalRecord = pageRecords.last {
                    nextCursor = ModuleStateScanCursor(
                        collectionID: request.collectionID,
                        afterRecordID: finalRecord.key.recordID,
                        observedStoreRevision: observedStoreRevision
                    )
                } else {
                    nextCursor = nil
                }
                return ModuleStateScanPage(records: pageRecords, nextCursor: nextCursor)
            } catch {
                context.rollback()
                throw Self.storeError(error)
            }
        }
    }

    public func transact(
        namespace: ModuleStateNamespace,
        transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        guard Self.isValid(namespace: namespace) else {
            throw ModuleStateStoreError.invalidRequest
        }
        var transactionPayloadByteCount = 0
        for mutation in transaction.mutations {
            if case .upsert(let upsert) = mutation, upsert.schemaVersion == 0 {
                throw ModuleStateStoreError.invalidRequest
            }
            if case .upsert(let upsert) = mutation,
               upsert.payload.count > Self.maximumPayloadByteCount {
                throw ModuleStateStoreError.payloadTooLarge(
                    maximumBytes: Self.maximumPayloadByteCount
                )
            }
            if case .upsert(let upsert) = mutation {
                let (total, overflowed) = transactionPayloadByteCount
                    .addingReportingOverflow(upsert.payload.count)
                guard !overflowed, total <= Self.maximumTransactionPayloadByteCount else {
                    throw ModuleStateStoreError.payloadTooLarge(
                        maximumBytes: Self.maximumTransactionPayloadByteCount
                    )
                }
                transactionPayloadByteCount = total
            }
        }
        let transactionDigest = try Self.transactionDigest(transaction)

        return try await stack.perform { context in
            do {
                guard let metadata = try Self.fetchNamespace(namespace, context: context) else {
                    throw ModuleStateStoreError.unavailable
                }
                try Self.requireAccessible(metadata)

                if let receipt = try Self.fetchReceipt(
                    namespace: namespace,
                    transactionID: transaction.transactionID,
                    context: context
                ) {
                    do {
                        return try Self.replayedResult(
                            receipt,
                            transactionDigest: transactionDigest
                        )
                    } catch let error as ModuleStateStoreError
                        where error == .integrityMismatch || error == .corrupt
                    {
                        try Self.incrementStoreRevision(metadata)
                        metadata.setValue(
                            ModuleStateLoadState.corrupt.rawValue,
                            forKey: Schema.loadState
                        )
                        metadata.setValue(true, forKey: Schema.blocksAccess)
                        metadata.setValue(
                            Diagnostic.receiptIntegrityMismatch,
                            forKey: Schema.diagnosticCode
                        )
                        metadata.setValue(Date(), forKey: Schema.updatedAt)
                        try Self.updateNamespaceIntegrity(metadata)
                        try context.save()
                        throw error
                    }
                }

                var existingRecords: [ModuleStateRecordKey: NSManagedObject] = [:]
                var existingRevisions: [ModuleStateRecordKey: UInt64?] = [:]
                for mutation in transaction.mutations {
                    let object = try Self.fetchRecord(
                        namespace: namespace,
                        key: mutation.key,
                        context: context
                    )
                    if let object {
                        guard !(try Self.bool(object, key: Schema.isQuarantined)) else {
                            throw ModuleStateStoreError.quarantined
                        }
                        do {
                            _ = try Self.record(from: object, namespace: namespace)
                        } catch let error as ModuleStateStoreError
                            where error == .integrityMismatch || error == .corrupt
                        {
                            let diagnosticCode = error == .integrityMismatch
                                ? Diagnostic.integrityMismatch
                                : Diagnostic.invalidRecord
                            try Self.quarantineRecord(
                                object,
                                namespaceMetadata: metadata,
                                diagnosticCode: diagnosticCode,
                                context: context
                            )
                            throw error
                        }
                        existingRecords[mutation.key] = object
                        existingRevisions[mutation.key] = try Self.uint64(
                            object,
                            key: Schema.recordRevision
                        )
                    } else {
                        existingRevisions[mutation.key] = .some(nil)
                    }

                    try Self.validate(
                        expectation: Self.expectation(for: mutation),
                        actual: existingRevisions[mutation.key] ?? nil,
                        key: mutation.key
                    )
                }

                let nextStoreRevision = try Self.incremented(
                    try Self.uint64(metadata, key: Schema.storeRevision)
                )
                var mutationResults: [ModuleStateMutationResult] = []
                let now = Date()

                for mutation in transaction.mutations {
                    switch mutation {
                    case .upsert(let upsert):
                        let previousRevision = existingRevisions[upsert.key] ?? nil
                        let revision = try Self.incremented(previousRevision ?? 0)
                        let object = existingRecords[upsert.key]
                            ?? NSEntityDescription.insertNewObject(
                                forEntityName: Schema.recordEntity,
                                into: context
                            )
                        object.setValue(namespace.moduleID.rawValue, forKey: Schema.moduleID)
                        object.setValue(
                            upsert.key.collectionID.rawValue,
                            forKey: Schema.collectionID
                        )
                        object.setValue(upsert.key.recordID.rawValue, forKey: Schema.recordID)
                        try Self.setUInt32(
                            upsert.schemaVersion,
                            on: object,
                            key: Schema.recordSchemaVersion
                        )
                        try Self.setUInt64(revision, on: object, key: Schema.recordRevision)
                        object.setValue(upsert.payload, forKey: Schema.payload)
                        object.setValue(
                            Self.integrityDigest(
                                namespace: namespace,
                                key: upsert.key,
                                schemaVersion: upsert.schemaVersion,
                                revision: revision,
                                payload: upsert.payload
                            ),
                            forKey: Schema.integrityDigest
                        )
                        object.setValue(now, forKey: Schema.updatedAt)
                        object.setValue(false, forKey: Schema.isQuarantined)
                        object.setValue(nil, forKey: Schema.recordDiagnosticCode)
                        mutationResults.append(
                            ModuleStateMutationResult(key: upsert.key, revision: revision)
                        )

                    case .delete(let deletion):
                        if let object = existingRecords[deletion.key] {
                            context.delete(object)
                        }
                        mutationResults.append(
                            ModuleStateMutationResult(key: deletion.key, revision: nil)
                        )
                    }
                }

                try Self.setUInt64(
                    nextStoreRevision,
                    on: metadata,
                    key: Schema.storeRevision
                )
                let currentState = try Self.loadState(metadata)
                if currentState == .absent || currentState == .migrated {
                    metadata.setValue(
                        ModuleStateLoadState.loaded.rawValue,
                        forKey: Schema.loadState
                    )
                }
                metadata.setValue(now, forKey: Schema.updatedAt)
                try Self.updateNamespaceIntegrity(metadata)

                let result = ModuleStateTransactionResult(
                    transactionID: transaction.transactionID,
                    storeRevision: nextStoreRevision,
                    mutations: mutationResults
                )
                try Self.insertReceipt(
                    namespace: namespace,
                    transactionDigest: transactionDigest,
                    result: result,
                    createdAt: now,
                    context: context
                )
                try context.save()
                return result
            } catch {
                context.rollback()
                throw Self.storeError(error)
            }
        }
    }

    public func quarantine(
        namespace: ModuleStateNamespace,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        guard Self.isValid(namespace: namespace),
              Self.isValid(diagnosticCode: diagnosticCode)
        else {
            throw ModuleStateStoreError.invalidRequest
        }

        return try await stack.perform { context in
            do {
                guard let metadata = try Self.fetchNamespace(namespace, context: context) else {
                    throw ModuleStateStoreError.unavailable
                }
                try Self.validateNamespaceIntegrity(metadata)
                if !(try Self.bool(metadata, key: Schema.blocksAccess)) {
                    try Self.incrementStoreRevision(metadata)
                }
                metadata.setValue(
                    ModuleStateLoadState.quarantined.rawValue,
                    forKey: Schema.loadState
                )
                metadata.setValue(true, forKey: Schema.blocksAccess)
                metadata.setValue(diagnosticCode, forKey: Schema.diagnosticCode)
                metadata.setValue(Date(), forKey: Schema.updatedAt)
                try Self.updateNamespaceIntegrity(metadata)
                try context.save()
                return try Self.snapshot(
                    namespace: namespace,
                    metadata: metadata,
                    context: context
                )
            } catch {
                context.rollback()
                throw Self.storeError(error)
            }
        }
    }

    public func quarantineRecord(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        guard Self.isValid(namespace: namespace),
              expectedRevision > 0,
              Self.isValid(diagnosticCode: diagnosticCode)
        else {
            throw ModuleStateStoreError.invalidRequest
        }

        return try await stack.perform { context in
            do {
                guard let metadata = try Self.fetchNamespace(namespace, context: context) else {
                    throw ModuleStateStoreError.unavailable
                }
                try Self.requireAccessible(metadata)
                let object = try Self.fetchRecord(
                    namespace: namespace,
                    key: key,
                    context: context
                )
                let actualRevision = try object.map {
                    try Self.uint64($0, key: Schema.recordRevision)
                }
                try Self.validate(
                    expectation: .exact(expectedRevision),
                    actual: actualRevision,
                    key: key
                )
                guard let object else {
                    throw ModuleStateStoreError.unavailable
                }
                if try Self.bool(object, key: Schema.isQuarantined) {
                    return try Self.snapshot(
                        namespace: namespace,
                        metadata: metadata,
                        context: context
                    )
                }

                try Self.quarantineRecord(
                    object,
                    namespaceMetadata: metadata,
                    diagnosticCode: diagnosticCode,
                    context: context
                )
                return try Self.snapshot(
                    namespace: namespace,
                    metadata: metadata,
                    context: context
                )
            } catch {
                context.rollback()
                throw Self.storeError(error)
            }
        }
    }

    public func health(
        namespace: ModuleStateNamespace
    ) async -> ModuleStateHealthSnapshot {
        guard Self.isValid(namespace: namespace) else {
            return Self.fallbackHealth(
                namespace: namespace,
                state: .unreadable,
                diagnosticCode: Diagnostic.invalidNamespace
            )
        }

        do {
            return try await stack.perform { context in
                guard let metadata = try Self.fetchNamespace(namespace, context: context) else {
                    return Self.fallbackHealth(namespace: namespace, state: .absent)
                }
                return try Self.snapshot(
                    namespace: namespace,
                    metadata: metadata,
                    context: context
                )
            }
        } catch let error as ModuleStateStoreError
            where error == .integrityMismatch || error == .corrupt
        {
            return Self.fallbackHealth(
                namespace: namespace,
                state: .corrupt,
                diagnosticCode: Diagnostic.integrityMismatch
            )
        } catch {
            return Self.fallbackHealth(
                namespace: namespace,
                state: .unreadable,
                diagnosticCode: Diagnostic.storeUnavailable
            )
        }
    }
}

private extension AppleSQLiteModuleStateStore {
    enum Schema {
        static let namespaceEntity = "ModuleStateNamespaceMetadata"
        static let recordEntity = "ModuleStateRecord"
        static let receiptEntity = "ModuleStateTransactionReceipt"

        static let moduleID = "moduleID"
        static let namespaceSchemaVersion = "namespaceSchemaVersion"
        static let storeRevision = "storeRevision"
        static let loadState = "loadState"
        static let blocksAccess = "blocksAccess"
        static let diagnosticCode = "diagnosticCode"
        static let namespaceIntegrityDigest = "namespaceIntegrityDigest"
        static let updatedAt = "updatedAt"

        static let collectionID = "collectionID"
        static let recordID = "recordID"
        static let recordSchemaVersion = "recordSchemaVersion"
        static let recordRevision = "recordRevision"
        static let payload = "payload"
        static let integrityDigest = "integrityDigest"
        static let isQuarantined = "isQuarantined"
        static let recordDiagnosticCode = "recordDiagnosticCode"

        static let transactionID = "transactionID"
        static let transactionDigest = "transactionDigest"
        static let resultData = "resultData"
        static let resultDigest = "resultDigest"
        static let createdAt = "createdAt"
    }

    enum Diagnostic {
        static let integrityMismatch = "module-state-integrity-mismatch"
        static let invalidRecord = "module-state-record-invalid"
        static let invalidNamespace = "module-state-invalid-namespace"
        static let receiptIntegrityMismatch = "module-state-receipt-integrity-mismatch"
        static let schemaVersionNewer = "module-state-schema-newer-than-runtime"
        static let storeUnavailable = "module-state-store-unavailable"
    }

    static func prepareOwnedDirectory(_ directory: URL, below base: URL) throws {
        let standardizedBase = base.standardizedFileURL
        let standardizedDirectory = directory.standardizedFileURL
        let prefix = standardizedBase.path.hasSuffix("/")
            ? standardizedBase.path
            : standardizedBase.path + "/"
        guard standardizedDirectory == standardizedBase
                || standardizedDirectory.path.hasPrefix(prefix),
              !isSymbolicLink(at: standardizedBase)
        else {
            throw ModuleStateStoreError.unavailable
        }

        if standardizedDirectory != standardizedBase {
            let relativePath = String(standardizedDirectory.path.dropFirst(prefix.count))
            var candidate = standardizedBase
            for component in relativePath.split(separator: "/") {
                candidate.appendPathComponent(String(component), isDirectory: true)
                guard !isSymbolicLink(at: candidate) else {
                    throw ModuleStateStoreError.unavailable
                }
            }
        }

        try FileManager.default.createDirectory(
            at: standardizedDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let resolvedDirectory = standardizedDirectory.resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedDirectory == standardizedDirectory else {
            throw ModuleStateStoreError.unavailable
        }

        #if os(iOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: standardizedDirectory.path
        )
        #endif
    }

    static func isSymbolicLink(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    static func isValid(namespace: ModuleStateNamespace) -> Bool {
        let bytes = namespace.moduleID.rawValue.utf8
        return !bytes.isEmpty
            && bytes.count <= 128
            && !namespace.moduleID.rawValue.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    static func isValid(diagnosticCode: String) -> Bool {
        let bytes = Array(diagnosticCode.utf8)
        guard !bytes.isEmpty, bytes.count <= 96 else { return false }
        var previousWasSeparator = false
        for (index, byte) in bytes.enumerated() {
            let isLetterOrNumber = (0x61 ... 0x7A).contains(byte)
                || (0x30 ... 0x39).contains(byte)
            if isLetterOrNumber {
                previousWasSeparator = false
                continue
            }
            let isSeparator = byte == 0x2D || byte == 0x2E
            guard isSeparator,
                  index > 0,
                  index < bytes.count - 1,
                  !previousWasSeparator
            else {
                return false
            }
            previousWasSeparator = true
        }
        return true
    }

    static func fetchNamespace(
        _ namespace: ModuleStateNamespace,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Schema.namespaceEntity)
        request.predicate = NSPredicate(format: "%K == %@", Schema.moduleID, namespace.moduleID.rawValue)
        request.fetchLimit = 2
        let results = try context.fetch(request)
        guard results.count <= 1 else { throw ModuleStateStoreError.corrupt }
        return results.first
    }

    static func fetchRecord(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Schema.recordEntity)
        request.predicate = NSPredicate(
            format: "%K == %@ AND %K == %@ AND %K == %@",
            Schema.moduleID,
            namespace.moduleID.rawValue,
            Schema.collectionID,
            key.collectionID.rawValue,
            Schema.recordID,
            key.recordID.rawValue
        )
        request.fetchLimit = 2
        let results = try context.fetch(request)
        guard results.count <= 1 else { throw ModuleStateStoreError.corrupt }
        return results.first
    }

    static func fetchRecordBatch(
        namespace: ModuleStateNamespace,
        collectionID: ModuleStateCollectionID,
        afterRecordID: String?,
        limit: Int,
        context: NSManagedObjectContext
    ) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: Schema.recordEntity)
        if let afterRecordID {
            request.predicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K == NO AND %K > %@",
                Schema.moduleID,
                namespace.moduleID.rawValue,
                Schema.collectionID,
                collectionID.rawValue,
                Schema.isQuarantined,
                Schema.recordID,
                afterRecordID
            )
        } else {
            request.predicate = NSPredicate(
                format: "%K == %@ AND %K == %@ AND %K == NO",
                Schema.moduleID,
                namespace.moduleID.rawValue,
                Schema.collectionID,
                collectionID.rawValue,
                Schema.isQuarantined
            )
        }
        request.sortDescriptors = [
            NSSortDescriptor(key: Schema.recordID, ascending: true, selector: #selector(NSString.compare(_:))),
        ]
        request.fetchLimit = limit
        return try context.fetch(request)
    }

    static func fetchReceipt(
        namespace: ModuleStateNamespace,
        transactionID: UUID,
        context: NSManagedObjectContext
    ) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: Schema.receiptEntity)
        request.predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            Schema.moduleID,
            namespace.moduleID.rawValue,
            Schema.transactionID,
            transactionID.uuidString.lowercased()
        )
        request.fetchLimit = 2
        let results = try context.fetch(request)
        guard results.count <= 1 else { throw ModuleStateStoreError.corrupt }
        return results.first
    }

    static func record(
        from object: NSManagedObject,
        namespace: ModuleStateNamespace
    ) throws -> ModuleStateRecord {
        guard let collectionID = ModuleStateCollectionID(
            rawValue: try string(object, key: Schema.collectionID)
        ), let recordID = ModuleStateRecordID(
            rawValue: try string(object, key: Schema.recordID)
        ) else {
            throw ModuleStateStoreError.corrupt
        }
        let key = ModuleStateRecordKey(collectionID: collectionID, recordID: recordID)
        let schemaVersion = try uint32(object, key: Schema.recordSchemaVersion)
        let revision = try uint64(object, key: Schema.recordRevision)
        let payload = try data(object, key: Schema.payload)
        guard payload.count <= maximumPayloadByteCount else {
            throw ModuleStateStoreError.corrupt
        }
        let storedDigest = try data(object, key: Schema.integrityDigest)
        let expectedDigest = integrityDigest(
            namespace: namespace,
            key: key,
            schemaVersion: schemaVersion,
            revision: revision,
            payload: payload
        )
        guard storedDigest.count == SHA256.Digest.byteCount,
              storedDigest == expectedDigest
        else {
            throw ModuleStateStoreError.integrityMismatch
        }
        guard let updatedAt = object.value(forKey: Schema.updatedAt) as? Date else {
            throw ModuleStateStoreError.corrupt
        }
        return ModuleStateRecord(
            key: key,
            schemaVersion: schemaVersion,
            revision: revision,
            payload: payload,
            integrityDigest: storedDigest,
            updatedAt: updatedAt
        )
    }

    static func snapshot(
        namespace: ModuleStateNamespace,
        metadata: NSManagedObject,
        context: NSManagedObjectContext
    ) throws -> ModuleStateHealthSnapshot {
        try validateNamespaceIntegrity(metadata)
        let activeCountRequest = NSFetchRequest<NSFetchRequestResult>(
            entityName: Schema.recordEntity
        )
        activeCountRequest.predicate = NSPredicate(
            format: "%K == %@ AND %K == NO",
            Schema.moduleID,
            namespace.moduleID.rawValue,
            Schema.isQuarantined
        )
        let quarantinedCountRequest = NSFetchRequest<NSFetchRequestResult>(
            entityName: Schema.recordEntity
        )
        quarantinedCountRequest.predicate = NSPredicate(
            format: "%K == %@ AND %K == YES",
            Schema.moduleID,
            namespace.moduleID.rawValue,
            Schema.isQuarantined
        )
        let activeCount = try context.count(for: activeCountRequest)
        let quarantinedCount = try context.count(for: quarantinedCountRequest)
        guard activeCount >= 0, quarantinedCount >= 0 else {
            throw ModuleStateStoreError.unavailable
        }
        return ModuleStateHealthSnapshot(
            namespace: namespace,
            loadState: try loadState(metadata),
            storeRevision: try uint64(metadata, key: Schema.storeRevision),
            namespaceSchemaVersion: try namespaceSchemaVersion(metadata),
            recordCount: UInt64(activeCount),
            quarantinedRecordCount: UInt64(quarantinedCount),
            accessDisposition: try bool(metadata, key: Schema.blocksAccess)
                ? .blocked
                : .readWrite,
            capturedAt: Date(),
            diagnosticCode: metadata.value(forKey: Schema.diagnosticCode) as? String
        )
    }

    static func fallbackHealth(
        namespace: ModuleStateNamespace,
        state: ModuleStateLoadState,
        diagnosticCode: String? = nil
    ) -> ModuleStateHealthSnapshot {
        ModuleStateHealthSnapshot(
            namespace: namespace,
            loadState: state,
            storeRevision: 0,
            namespaceSchemaVersion: nil,
            recordCount: 0,
            quarantinedRecordCount: 0,
            accessDisposition: state == .absent ? .readWrite : .blocked,
            capturedAt: Date(),
            diagnosticCode: diagnosticCode
        )
    }

    static func requireAccessible(_ metadata: NSManagedObject) throws {
        try validateNamespaceIntegrity(metadata)
        let state = try loadState(metadata)
        if try bool(metadata, key: Schema.blocksAccess) {
            switch state {
            case .quarantined: throw ModuleStateStoreError.quarantined
            case .unreadable: throw ModuleStateStoreError.unreadable
            case .corrupt: throw ModuleStateStoreError.corrupt
            default: throw ModuleStateStoreError.unavailable
            }
        }
        if state == .corrupt { throw ModuleStateStoreError.corrupt }
        if state == .unreadable { throw ModuleStateStoreError.unreadable }
    }

    static func quarantineRecord(
        _ record: NSManagedObject,
        namespaceMetadata: NSManagedObject,
        diagnosticCode: String,
        context: NSManagedObjectContext
    ) throws {
        try markRecordQuarantined(
            record,
            namespaceMetadata: namespaceMetadata,
            diagnosticCode: diagnosticCode
        )
        try incrementStoreRevision(namespaceMetadata)
        namespaceMetadata.setValue(
            ModuleStateLoadState.quarantined.rawValue,
            forKey: Schema.loadState
        )
        namespaceMetadata.setValue(diagnosticCode, forKey: Schema.diagnosticCode)
        namespaceMetadata.setValue(Date(), forKey: Schema.updatedAt)
        try updateNamespaceIntegrity(namespaceMetadata)
        try context.save()
    }

    static func markRecordQuarantined(
        _ record: NSManagedObject,
        namespaceMetadata: NSManagedObject,
        diagnosticCode: String
    ) throws {
        record.setValue(true, forKey: Schema.isQuarantined)
        record.setValue(diagnosticCode, forKey: Schema.recordDiagnosticCode)
        record.setValue(Date(), forKey: Schema.updatedAt)
        namespaceMetadata.setValue(false, forKey: Schema.blocksAccess)
    }

    static func validate(
        expectation: ModuleStateRevisionExpectation,
        actual: UInt64?,
        key: ModuleStateRecordKey
    ) throws {
        switch expectation {
        case .any:
            return
        case .absent where actual == nil:
            return
        case .exact(let expected) where actual == expected:
            return
        case .absent:
            throw ModuleStateStoreError.revisionConflict(
                collectionID: key.collectionID,
                recordID: key.recordID,
                expected: nil,
                actual: actual
            )
        case .exact(let expected):
            throw ModuleStateStoreError.revisionConflict(
                collectionID: key.collectionID,
                recordID: key.recordID,
                expected: expected,
                actual: actual
            )
        }
    }

    static func expectation(
        for mutation: ModuleStateMutation
    ) -> ModuleStateRevisionExpectation {
        switch mutation {
        case .upsert(let value): value.expectedRevision
        case .delete(let value): value.expectedRevision
        }
    }

    static func transactionDigest(_ transaction: ModuleStateTransaction) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return Data(SHA256.hash(data: try encoder.encode(transaction)))
    }

    static func integrityDigest(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey,
        schemaVersion: UInt32,
        revision: UInt64,
        payload: Data
    ) -> Data {
        var input = Data("RuneScribe.ModuleState.Record.v1".utf8)
        appendLengthPrefixed(Data(namespace.moduleID.rawValue.utf8), to: &input)
        appendLengthPrefixed(Data(key.collectionID.rawValue.utf8), to: &input)
        appendLengthPrefixed(Data(key.recordID.rawValue.utf8), to: &input)
        appendInteger(schemaVersion, to: &input)
        appendInteger(revision, to: &input)
        appendLengthPrefixed(payload, to: &input)
        return Data(SHA256.hash(data: input))
    }

    static func validateNamespaceIntegrity(_ metadata: NSManagedObject) throws {
        let storedDigest = try data(metadata, key: Schema.namespaceIntegrityDigest)
        guard storedDigest.count == SHA256.Digest.byteCount,
              storedDigest == (try namespaceIntegrityDigest(metadata))
        else {
            throw ModuleStateStoreError.integrityMismatch
        }
    }

    static func updateNamespaceIntegrity(_ metadata: NSManagedObject) throws {
        metadata.setValue(
            try namespaceIntegrityDigest(metadata),
            forKey: Schema.namespaceIntegrityDigest
        )
    }

    static func namespaceIntegrityDigest(_ metadata: NSManagedObject) throws -> Data {
        var input = Data("RuneScribe.ModuleState.Namespace.v1".utf8)
        appendLengthPrefixed(
            Data(try string(metadata, key: Schema.moduleID).utf8),
            to: &input
        )
        appendInteger(
            try uint32(metadata, key: Schema.namespaceSchemaVersion),
            to: &input
        )
        appendInteger(try uint64(metadata, key: Schema.storeRevision), to: &input)
        appendLengthPrefixed(
            Data(try string(metadata, key: Schema.loadState).utf8),
            to: &input
        )
        input.append(try bool(metadata, key: Schema.blocksAccess) ? 1 : 0)
        if let diagnosticCode = metadata.value(forKey: Schema.diagnosticCode) {
            guard let diagnosticCode = diagnosticCode as? String else {
                throw ModuleStateStoreError.corrupt
            }
            input.append(1)
            appendLengthPrefixed(Data(diagnosticCode.utf8), to: &input)
        } else {
            input.append(0)
        }
        return Data(SHA256.hash(data: input))
    }

    static func appendLengthPrefixed(_ data: Data, to output: inout Data) {
        appendInteger(UInt64(data.count), to: &output)
        output.append(data)
    }

    static func appendInteger<T: FixedWidthInteger>(_ value: T, to output: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { output.append(contentsOf: $0) }
    }

    static func insertReceipt(
        namespace: ModuleStateNamespace,
        transactionDigest: Data,
        result: ModuleStateTransactionResult,
        createdAt: Date,
        context: NSManagedObjectContext
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let resultData = try encoder.encode(result)
        let object = NSEntityDescription.insertNewObject(
            forEntityName: Schema.receiptEntity,
            into: context
        )
        object.setValue(namespace.moduleID.rawValue, forKey: Schema.moduleID)
        object.setValue(
            result.transactionID.uuidString.lowercased(),
            forKey: Schema.transactionID
        )
        object.setValue(transactionDigest, forKey: Schema.transactionDigest)
        object.setValue(resultData, forKey: Schema.resultData)
        object.setValue(Data(SHA256.hash(data: resultData)), forKey: Schema.resultDigest)
        object.setValue(createdAt, forKey: Schema.createdAt)
    }

    static func replayedResult(
        _ receipt: NSManagedObject,
        transactionDigest: Data
    ) throws -> ModuleStateTransactionResult {
        guard try data(receipt, key: Schema.transactionDigest) == transactionDigest else {
            throw ModuleStateStoreError.invalidRequest
        }
        let resultData = try data(receipt, key: Schema.resultData)
        let resultDigest = try data(receipt, key: Schema.resultDigest)
        guard resultDigest.count == SHA256.Digest.byteCount,
              resultDigest == Data(SHA256.hash(data: resultData))
        else {
            throw ModuleStateStoreError.integrityMismatch
        }
        do {
            return try JSONDecoder().decode(ModuleStateTransactionResult.self, from: resultData)
        } catch {
            throw ModuleStateStoreError.corrupt
        }
    }

    static func incrementStoreRevision(_ metadata: NSManagedObject) throws {
        try setUInt64(
            incremented(try uint64(metadata, key: Schema.storeRevision)),
            on: metadata,
            key: Schema.storeRevision
        )
    }

    static func incremented(_ value: UInt64) throws -> UInt64 {
        guard value < UInt64(Int64.max) else { throw ModuleStateStoreError.corrupt }
        return value + 1
    }

    static func namespaceSchemaVersion(_ object: NSManagedObject) throws -> UInt32 {
        try uint32(object, key: Schema.namespaceSchemaVersion)
    }

    static func loadState(_ object: NSManagedObject) throws -> ModuleStateLoadState {
        guard let value = ModuleStateLoadState(
            rawValue: try string(object, key: Schema.loadState)
        ) else {
            throw ModuleStateStoreError.corrupt
        }
        return value
    }

    static func string(_ object: NSManagedObject, key: String) throws -> String {
        guard let value = object.value(forKey: key) as? String else {
            throw ModuleStateStoreError.corrupt
        }
        return value
    }

    static func data(_ object: NSManagedObject, key: String) throws -> Data {
        guard let value = object.value(forKey: key) as? Data else {
            throw ModuleStateStoreError.corrupt
        }
        return value
    }

    static func bool(_ object: NSManagedObject, key: String) throws -> Bool {
        guard let value = object.value(forKey: key) as? NSNumber else {
            throw ModuleStateStoreError.corrupt
        }
        return value.boolValue
    }

    static func uint32(_ object: NSManagedObject, key: String) throws -> UInt32 {
        let value = try int64(object, key: key)
        guard value >= 0, value <= Int64(UInt32.max) else {
            throw ModuleStateStoreError.corrupt
        }
        return UInt32(value)
    }

    static func uint64(_ object: NSManagedObject, key: String) throws -> UInt64 {
        let value = try int64(object, key: key)
        guard value >= 0 else { throw ModuleStateStoreError.corrupt }
        return UInt64(value)
    }

    static func int64(_ object: NSManagedObject, key: String) throws -> Int64 {
        guard let value = object.value(forKey: key) as? NSNumber else {
            throw ModuleStateStoreError.corrupt
        }
        return value.int64Value
    }

    static func setUInt32(_ value: UInt32, on object: NSManagedObject, key: String) throws {
        object.setValue(NSNumber(value: value), forKey: key)
    }

    static func setUInt64(_ value: UInt64, on object: NSManagedObject, key: String) throws {
        guard value <= UInt64(Int64.max) else { throw ModuleStateStoreError.corrupt }
        object.setValue(NSNumber(value: value), forKey: key)
    }

    static func storeError(_ error: Error) -> Error {
        if let error = error as? ModuleStateStoreError { return error }
        if error is DecodingError || error is EncodingError {
            return ModuleStateStoreError.corrupt
        }
        return ModuleStateStoreError.unavailable
    }
}

private final class CoreDataStack: @unchecked Sendable {
    private let context: NSManagedObjectContext
    private let storeURL: URL

    init(storeURL: URL) throws {
        let model = Self.makeModel()
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        var options: [AnyHashable: Any] = [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true,
            NSSQLitePragmasOption: [
                "journal_mode": "WAL",
                "secure_delete": "1",
            ],
        ]
        #if os(iOS)
        options[NSPersistentStoreFileProtectionKey] =
            FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        do {
            try coordinator.addPersistentStore(
                ofType: NSSQLiteStoreType,
                configurationName: nil,
                at: storeURL,
                options: options
            )
        } catch {
            throw ModuleStateStoreError.unavailable
        }

        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        self.context = context
        self.storeURL = storeURL
    }

    func perform<T: Sendable>(
        _ operation: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            context.perform { [context, storeURL] in
                do {
                    let result = try operation(context)
                    try protectSQLiteStoreFiles(at: storeURL)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func makeModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        let namespace = NSEntityDescription()
        namespace.name = AppleSQLiteModuleStateStore.Schema.namespaceEntity
        namespace.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        namespace.properties = [
            attribute(AppleSQLiteModuleStateStore.Schema.moduleID, .stringAttributeType),
            attribute(
                AppleSQLiteModuleStateStore.Schema.namespaceSchemaVersion,
                .integer64AttributeType
            ),
            attribute(AppleSQLiteModuleStateStore.Schema.storeRevision, .integer64AttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.loadState, .stringAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.blocksAccess, .booleanAttributeType),
            attribute(
                AppleSQLiteModuleStateStore.Schema.diagnosticCode,
                .stringAttributeType,
                optional: true
            ),
            attribute(
                AppleSQLiteModuleStateStore.Schema.namespaceIntegrityDigest,
                .binaryDataAttributeType
            ),
            attribute(AppleSQLiteModuleStateStore.Schema.updatedAt, .dateAttributeType),
        ]
        namespace.uniquenessConstraints = [[AppleSQLiteModuleStateStore.Schema.moduleID]]

        let record = NSEntityDescription()
        record.name = AppleSQLiteModuleStateStore.Schema.recordEntity
        record.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        record.properties = [
            attribute(AppleSQLiteModuleStateStore.Schema.moduleID, .stringAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.collectionID, .stringAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.recordID, .stringAttributeType),
            attribute(
                AppleSQLiteModuleStateStore.Schema.recordSchemaVersion,
                .integer64AttributeType
            ),
            attribute(AppleSQLiteModuleStateStore.Schema.recordRevision, .integer64AttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.payload, .binaryDataAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.integrityDigest, .binaryDataAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.updatedAt, .dateAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.isQuarantined, .booleanAttributeType),
            attribute(
                AppleSQLiteModuleStateStore.Schema.recordDiagnosticCode,
                .stringAttributeType,
                optional: true
            ),
        ]
        record.uniquenessConstraints = [[
            AppleSQLiteModuleStateStore.Schema.moduleID,
            AppleSQLiteModuleStateStore.Schema.collectionID,
            AppleSQLiteModuleStateStore.Schema.recordID,
        ]]

        let receipt = NSEntityDescription()
        receipt.name = AppleSQLiteModuleStateStore.Schema.receiptEntity
        receipt.managedObjectClassName = NSStringFromClass(NSManagedObject.self)
        receipt.properties = [
            attribute(AppleSQLiteModuleStateStore.Schema.moduleID, .stringAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.transactionID, .stringAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.transactionDigest, .binaryDataAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.resultData, .binaryDataAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.resultDigest, .binaryDataAttributeType),
            attribute(AppleSQLiteModuleStateStore.Schema.createdAt, .dateAttributeType),
        ]
        receipt.uniquenessConstraints = [[
            AppleSQLiteModuleStateStore.Schema.moduleID,
            AppleSQLiteModuleStateStore.Schema.transactionID,
        ]]

        model.entities = [namespace, record, receipt]
        return model
    }

    private static func attribute(
        _ name: String,
        _ type: NSAttributeType,
        optional: Bool = false
    ) -> NSAttributeDescription {
        let attribute = NSAttributeDescription()
        attribute.name = name
        attribute.attributeType = type
        attribute.isOptional = optional
        return attribute
    }
}
