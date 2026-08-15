import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@testable import RuneScribeCoreModule
@testable import RuneScribeRuntimeCore
import XCTest

final class CoreProgressionCoordinatorTests: XCTestCase {
    func testBatchBuilderUsesGlobalContiguousSlotsAndRejectsDuplicates() throws {
        let context = try Self.context(byte: 1, scope: .persistent)
        let facts = try (0 ..< 128).map { value in
            try CoreProgressionFactFactory.cipherCreated(
                cipherToken: Self.cipherToken(value + 1)
            )
        }
        let digest = try CoreProgressionCoordinator.commandDigest("batch-command")
        let batches = try CoreProgressionCoordinator.pendingBatches(
            context: context,
            commandDigest: digest,
            facts: facts
        )

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches.map(\.batch.batchIndex), [0, 1])
        XCTAssertEqual(batches.map(\.batch.totalBatchCount), [2, 2])
        XCTAssertEqual(batches.map(\.batch.facts.count), [127, 1])
        XCTAssertEqual(
            batches.flatMap(\.batch.facts).map(\.slot.rawValue),
            Array(0 ..< 128).map(UInt32.init)
        )
        XCTAssertEqual(Set(batches.map(\.commandDigest)), [digest])

        XCTAssertThrowsError(try CoreProgressionCoordinator.pendingBatches(
            context: context,
            commandDigest: digest,
            facts: [facts[0], facts[0]]
        )) { error in
            XCTAssertEqual(error as? CoreProgressionCoordinatorError, .duplicateFact)
        }
    }

    func testMigrationPersistsRandomizedSeedsWithoutInventingHistory() async throws {
        let store = CoordinatorSecureStore()
        let repository = Self.repository(store: store)
        let legacy = try await repository.snapshot()
        let cipher = try XCTUnwrap(legacy.ciphers.first)
        let contactID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        _ = try await repository.assignContact(
            cipherID: cipher.id,
            contactID: contactID
        )
        let tokens = CoordinatorTokens()
        let coordinator = CoreProgressionCoordinator(
            repository: repository,
            tokens: tokens,
            outbox: nil
        )

        let migrated = try await coordinator.migrateEvidenceIfNeeded()
        let ledger = try migrated.validatedProgressionLedger()

        XCTAssertEqual(migrated.version, CipherLibrary.currentVersion)
        XCTAssertEqual(ledger.cipherSeeds.count, 1)
        XCTAssertEqual(ledger.relationships.count, 1)
        XCTAssertEqual(ledger.relationships[0].identity.contactID, contactID)
        XCTAssertTrue(ledger.pendingBatches.isEmpty)
        XCTAssertTrue(ledger.acknowledgedBatches.isEmpty)
        XCTAssertTrue(ledger.encodedMessages.isEmpty)
        XCTAssertTrue(ledger.shareTerminals.isEmpty)

        let snapshot = try await coordinator.existingUserMigrationSnapshot()
        XCTAssertEqual(snapshot.ciphers.count, 1)
        XCTAssertEqual(snapshot.ciphers[0].origin, .generated)
        let seedCounts = await tokens.seedCounts()
        XCTAssertEqual(seedCounts, [1, 1])
    }

    func testDrainRetainsAmbiguousMultiBatchEvidenceThenResumesInOrder() async throws {
        let store = CoordinatorSecureStore()
        let repository = Self.repository(store: store)
        let tokens = CoordinatorTokens()
        let outbox = CoordinatorOutbox(
            recoveryContext: try Self.context(byte: 9, scope: .persistent),
            failSubmitBatchOnce: 1
        )
        let coordinator = CoreProgressionCoordinator(
            repository: repository,
            tokens: tokens,
            outbox: outbox
        )
        _ = try await coordinator.migrateEvidenceIfNeeded()

        let context = try Self.context(byte: 2, scope: .persistent)
        let facts = try (0 ..< 128).map { value in
            try CoreProgressionFactFactory.cipherCreated(
                cipherToken: Self.cipherToken(value + 200)
            )
        }
        let pending = try CoreProgressionCoordinator.pendingBatches(
            context: context,
            commandDigest: CoreProgressionCoordinator.commandDigest("two-batches"),
            facts: facts
        )
        _ = try await repository.appendPendingProgressionBatches(pending)

        let firstDrain = await coordinator.drain()
        let firstSubmissions = await outbox.submittedBatchIndices()
        let firstAcknowledgements = await outbox.acknowledgedBatchIndices()
        let retainedPending = try await repository.pendingProgressionBatches()
        let retainedAcknowledged = try await repository
            .acknowledgedProgressionBatches()
        XCTAssertEqual(firstDrain, .retainedForRetry)
        XCTAssertEqual(firstSubmissions, [0, 1])
        XCTAssertEqual(firstAcknowledgements, [])
        XCTAssertEqual(retainedPending.map(\.batch.batchIndex), [1])
        XCTAssertEqual(retainedAcknowledged.map(\.batch.batchIndex), [0])

        let secondDrain = await coordinator.drain()
        let finalSubmissions = await outbox.submittedBatchIndices()
        let finalAcknowledgements = await outbox.acknowledgedBatchIndices()
        let finalPending = try await repository.pendingProgressionBatches()
        let finalAcknowledged = try await repository.acknowledgedProgressionBatches()
        XCTAssertEqual(secondDrain, .durable)
        XCTAssertEqual(finalSubmissions, [0, 1, 1])
        XCTAssertEqual(finalAcknowledgements, [0, 1])
        XCTAssertTrue(finalPending.isEmpty)
        XCTAssertTrue(finalAcknowledged.isEmpty)
    }

    func testDrainRecontextualizesGenerationOnlyEvidenceBeforeSubmission() async throws {
        let store = CoordinatorSecureStore()
        let repository = Self.repository(store: store)
        let tokens = CoordinatorTokens()
        let replacement = try Self.context(byte: 8, scope: .persistent)
        let outbox = CoordinatorOutbox(recoveryContext: replacement)
        let coordinator = CoreProgressionCoordinator(
            repository: repository,
            tokens: tokens,
            outbox: outbox
        )
        _ = try await coordinator.migrateEvidenceIfNeeded()

        let ephemeral = try Self.context(byte: 3, scope: .runtimeGeneration)
        let fact = try CoreProgressionFactFactory.cipherCreated(
            cipherToken: Self.cipherToken(900)
        )
        let pending = try CoreProgressionCoordinator.pendingBatches(
            context: ephemeral,
            commandDigest: CoreProgressionCoordinator.commandDigest("ephemeral"),
            facts: [fact]
        )
        _ = try await repository.appendPendingProgressionBatches(pending)

        let drain = await coordinator.drain()
        let purposes = await outbox.issuedPurposes()
        let contexts = await outbox.submittedContexts()
        let remainingPending = try await repository.pendingProgressionBatches()
        let remainingAcknowledged = try await repository
            .acknowledgedProgressionBatches()
        XCTAssertEqual(drain, .durable)
        XCTAssertEqual(purposes, [.evidenceRecovery])
        XCTAssertEqual(contexts, [replacement])
        XCTAssertTrue(remainingPending.isEmpty)
        XCTAssertTrue(remainingAcknowledged.isEmpty)
    }

    func testUnavailableOutboxNeverDiscardsCommittedEvidence() async throws {
        let store = CoordinatorSecureStore()
        let repository = Self.repository(store: store)
        let coordinator = CoreProgressionCoordinator(
            repository: repository,
            tokens: CoordinatorTokens(),
            outbox: nil
        )
        _ = try await coordinator.migrateEvidenceIfNeeded()
        let context = try Self.context(byte: 4, scope: .runtimeGeneration)
        let pending = try CoreProgressionCoordinator.pendingBatches(
            context: context,
            commandDigest: CoreProgressionCoordinator.commandDigest("unavailable"),
            facts: [try CoreProgressionFactFactory.cipherCreated(
                cipherToken: Self.cipherToken(901)
            )]
        )
        _ = try await repository.appendPendingProgressionBatches(pending)

        let drain = await coordinator.drain()
        let retained = try await repository.pendingProgressionBatches()
        XCTAssertEqual(drain, .unavailable)
        XCTAssertEqual(retained, pending)
    }

    private static func repository(store: CoordinatorSecureStore) -> CipherRepository {
        CipherRepository(runtimeIO: RuntimeIOClient(
            secureValueData: { service, account in
                await store.data(service: service, account: account)
            },
            setSecureValue: { data, service, account in
                await store.set(data, service: service, account: account)
            },
            deleteSecureValue: { service, account in
                await store.delete(service: service, account: account)
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            nextUUID: {
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            }
        ))
    }

    private static func context(
        byte: UInt8,
        scope: RuntimeOperationContextAuthorityScope
    ) throws -> RuntimePersistableOperationContext {
        try RuntimePersistableOperationContext(
            operationID: RuntimeOperationID(rawValue: "coordinator-\(byte)"),
            correlationID: RuntimeCorrelationID(
                rawValue: "30000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
            ),
            occurredAtUTC: Date(timeIntervalSince1970: 1_700_000_000.123),
            operationIdentifier: RuntimeOperationIdentifier(rawValue: "core.coordinator"),
            runtimeGeneration: 1,
            authorityNonce: UUID(
                uuidString: "40000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
            )!,
            authorityTag: Data(repeating: byte, count: 32),
            authorityScope: scope
        )
    }

    private static func cipherToken(_ value: Int) -> CipherToken {
        CipherToken(rawValue: String(format: "%064x", value))!
    }
}

private actor CoordinatorSecureStore {
    private struct Address: Hashable {
        let service: String
        let account: String
    }

    private var values: [Address: Data] = [:]

    func data(service: String, account: String) -> Data? {
        values[Address(service: service, account: account)]
    }

    func set(_ data: Data, service: String, account: String) {
        values[Address(service: service, account: account)] = data
    }

    func delete(service: String, account: String) {
        values.removeValue(forKey: Address(service: service, account: account))
    }
}

private actor CoordinatorTokens: CoreProgressionTokenDeriving {
    private var cipherSeedCount = 0
    private var relationshipSeedCount = 0
    private var messageCount = 0

    func makeCipherSeed() -> Data {
        cipherSeedCount += 1
        return Data(repeating: UInt8(cipherSeedCount), count: 32)
    }

    func cipherToken(for seed: Data) throws -> CipherToken {
        guard seed.count == 32 else { throw CoreProgressionCoordinatorError.evidenceMigrationFailed }
        return CipherToken(rawValue: String(format: "%064x", Int(seed[0])))!
    }

    func makeMessageToken() -> MessageToken {
        messageCount += 1
        return MessageToken(rawValue: String(format: "%064x", 1_000 + messageCount))!
    }

    func packageToken(for admittedPackageBytes: Data) -> PackageToken {
        PackageToken(
            rawValue: String(format: "%064x", admittedPackageBytes.count + 2_000)
        )!
    }

    func makeRelationshipSeed() -> Data {
        relationshipSeedCount += 1
        return Data(repeating: UInt8(100 + relationshipSeedCount), count: 32)
    }

    func relationshipToken(for seed: Data) throws -> RelationshipToken {
        guard seed.count == 32 else { throw CoreProgressionCoordinatorError.evidenceMigrationFailed }
        return RelationshipToken(rawValue: String(format: "%064x", Int(seed[0]) + 3_000))!
    }

    func seedCounts() -> [Int] {
        [cipherSeedCount, relationshipSeedCount]
    }
}

private enum CoordinatorOutboxError: Error {
    case injected
}

private actor CoordinatorOutbox: CoreProgressionOutboxTransport {
    private let recoveryContext: RuntimePersistableOperationContext
    private var failingSubmitIndices: Set<UInt32>
    private var submissions: [UInt32] = []
    private var acknowledgements: [UInt32] = []
    private var purposes: [RuntimeBackgroundOperationPurpose] = []
    private var contexts: [RuntimePersistableOperationContext] = []

    init(
        recoveryContext: RuntimePersistableOperationContext,
        failSubmitBatchOnce: UInt32? = nil
    ) {
        self.recoveryContext = recoveryContext
        failingSubmitIndices = failSubmitBatchOnce.map { [$0] } ?? []
    }

    func submitBatch(
        _ batch: ProgressionEventFactBatch,
        context: RuntimePersistableOperationContext
    ) throws -> ProgressionOutboxBatchReceipt {
        submissions.append(batch.batchIndex)
        contexts.append(context)
        if failingSubmitIndices.remove(batch.batchIndex) != nil {
            throw CoordinatorOutboxError.injected
        }
        let eventIDs = Dictionary(uniqueKeysWithValues: batch.facts.map { item in
            let suffix = String(
                format: "%012llx",
                UInt64(item.slot.rawValue) + 1
            )
            return (
                item.slot,
                EventID(rawValue: UUID(
                    uuidString: "50000000-0000-0000-0000-\(suffix)"
                )!)
            )
        })
        return try ProgressionOutboxBatchReceipt(
            contextID: context.runtimeOperationID,
            batchIndex: batch.batchIndex,
            eventIDsBySlot: eventIDs,
            correlationID: CorrelationID(rawValue: UUID(
                uuidString: context.runtimeCorrelationID.rawValue
            )!),
            durableAt: Date(timeIntervalSince1970: 1_700_000_001),
            outboxRevision: UInt64(batch.batchIndex) + 1
        )
    }

    func issueBackgroundContext(
        for purpose: RuntimeBackgroundOperationPurpose
    ) -> RuntimePersistableOperationContext {
        purposes.append(purpose)
        return recoveryContext
    }

    func acknowledgeBatch(
        _ receipt: ProgressionOutboxBatchReceipt,
        context: RuntimePersistableOperationContext
    ) throws {
        guard receipt.matches(context: context) else {
            throw CoordinatorOutboxError.injected
        }
        acknowledgements.append(receipt.batchIndex)
    }

    func submittedBatchIndices() -> [UInt32] { submissions }
    func acknowledgedBatchIndices() -> [UInt32] { acknowledgements }
    func issuedPurposes() -> [RuntimeBackgroundOperationPurpose] { purposes }
    func submittedContexts() -> [RuntimePersistableOperationContext] { contexts }
}
