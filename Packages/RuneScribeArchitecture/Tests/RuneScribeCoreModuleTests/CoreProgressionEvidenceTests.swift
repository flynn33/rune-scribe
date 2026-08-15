import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@testable import RuneScribeCoreModule
import XCTest

final class CoreProgressionEvidenceTests: XCTestCase {
    func testLibraryV2RoundTripIsStrictAndPreservesFractionalContextIdentity() throws {
        let cipher = Self.cipher()
        let context = try Self.context(scope: .runtimeGeneration, byte: 1)
        let pending = try Self.pending(context: context, byte: 1)
        let ledger = try CoreProgressionLedger(
            cipherSeeds: [try .init(cipherID: cipher.id, seed: Self.seed(1))],
            pendingBatches: [pending]
        )
        let library = CipherLibrary(
            version: CipherLibrary.currentVersion,
            ciphers: [cipher],
            activeID: cipher.id,
            progressionLedger: ledger
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(library)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(CipherLibrary.self, from: data), library)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var encodedLedger = try XCTUnwrap(object["progressionLedger"] as? [String: Any])
        encodedLedger["unexpected"] = true
        object["progressionLedger"] = encodedLedger
        let invalid = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try decoder.decode(CipherLibrary.self, from: invalid)) {
            XCTAssertEqual($0 as? CoreProgressionEvidenceError, .unknownField)
        }
    }

    func testMigrationIsIdempotentAndDoesNotInventLegacyDeliveryEvidence() throws {
        let contactID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let cipher = Self.cipher(
            contactID: contactID,
            keyDeliveryState: .migratedUnverified
        )
        let legacy = CipherLibrary(ciphers: [cipher], activeID: cipher.id)
        let relationship = CoreProgressionRelationshipIdentity(
            cipherID: cipher.id,
            contactID: contactID
        )
        let seeds = CoreProgressionMigrationSeedSet(
            cipherSeeds: [cipher.id: Self.seed(2)],
            relationshipSeeds: [relationship: Self.seed(3)]
        )

        let migrated = try legacy.migratingProgressionEvidence(using: seeds)
        XCTAssertEqual(migrated.version, CipherLibrary.currentVersion)
        XCTAssertEqual(try migrated.migratingProgressionEvidence(using: seeds), migrated)
        let evidence = try XCTUnwrap(migrated.progressionLedger?.relationships.first)
        XCTAssertEqual(evidence.keyDeliveryState, .migratedUnverified)
        XCTAssertFalse(evidence.firstDeliveryEventCommitted)
        XCTAssertFalse(evidence.hasEligibleOutbound)
        XCTAssertFalse(evidence.hasAuthenticatedInbound)
        XCTAssertFalse(evidence.bidirectionalEventCommitted)
        XCTAssertTrue(try XCTUnwrap(migrated.progressionLedger).pendingBatches.isEmpty)
    }

    func testMigrationRequiresExactCurrentRelationshipSeedSet() throws {
        let contactID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let cipher = Self.cipher(contactID: contactID, keyDeliveryState: .pending)
        let legacy = CipherLibrary(ciphers: [cipher], activeID: cipher.id)
        XCTAssertThrowsError(try legacy.migratingProgressionEvidence(
            using: CoreProgressionMigrationSeedSet(
                cipherSeeds: [cipher.id: Self.seed(1)],
                relationshipSeeds: [:]
            )
        )) {
            XCTAssertEqual(
                $0 as? CipherLibraryValidationError,
                .progressionMigrationSeedMismatch
            )
        }
    }

    func testMigrationSnapshotIsCanonicalScalableAndContainsOnlyTokenAndOrigin() throws {
        let tokenA = Self.cipherToken(1)
        let tokenB = Self.cipherToken(2)
        let snapshot = try CoreProgressionMigrationSnapshot(ciphers: [
            .init(cipherToken: tokenB, origin: .imported),
            .init(cipherToken: tokenA, origin: .generated),
        ])
        XCTAssertEqual(snapshot.ciphers.map(\.cipherToken), [tokenA, tokenB])
        XCTAssertThrowsError(try CoreProgressionMigrationSnapshot(ciphers: [
            .init(cipherToken: tokenA, origin: .generated),
            .init(cipherToken: tokenA, origin: .imported),
        ])) {
            XCTAssertEqual(
                $0 as? CoreProgressionEvidenceError,
                .invalidMigrationSnapshot
            )
        }
        let scalable = (0 ..< 4_097).reversed().map {
            CoreProgressionMigrationCipher(
                cipherToken: Self.cipherToken($0 + 10),
                origin: .generated
            )
        }
        let scalableSnapshot = try CoreProgressionMigrationSnapshot(
            ciphers: scalable
        )
        XCTAssertEqual(scalableSnapshot.ciphers.count, 4_097)
        XCTAssertEqual(
            scalableSnapshot.ciphers,
            scalableSnapshot.ciphers.sorted {
                $0.cipherToken < $1.cipherToken
            }
        )

        let data = try JSONEncoder().encode(snapshot)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("cipherToken"))
        XCTAssertTrue(json.contains("origin"))
        for forbidden in [
            "contact", "delivery", "relationship", "seed", "publicID", "keyMaterial",
        ] {
            XCTAssertFalse(json.localizedCaseInsensitiveContains(forbidden))
        }
    }

    func testPendingReceiptLifecycleRetainsFactsUntilRuntimeAcknowledgement() throws {
        let context = try Self.context(scope: .persistent, byte: 3)
        let pending = try Self.pending(context: context, byte: 3)
        var ledger = try CoreProgressionLedger(cipherSeeds: [], pendingBatches: [pending])
        let receipt = try Self.receipt(context: context, batch: pending.batch, byte: 3)

        XCTAssertTrue(try ledger.acknowledge(context: context, receipt: receipt))
        XCTAssertTrue(ledger.pendingBatches.isEmpty)
        XCTAssertEqual(ledger.acknowledgedBatches.first?.batch, pending.batch)
        XCTAssertEqual(ledger.acknowledgedBatches.first?.receipt, receipt)
        XCTAssertFalse(try ledger.acknowledge(context: context, receipt: receipt))

        XCTAssertTrue(try ledger.clearAcknowledgement(context: context, receipt: receipt))
        XCTAssertTrue(ledger.acknowledgedBatches.isEmpty)
        XCTAssertFalse(try ledger.clearAcknowledgement(context: context, receipt: receipt))
    }

    func testMultiBatchReceiptsPersistInOrderBeforeAnyEvidenceIsCleared() throws {
        let context = try Self.context(scope: .persistent, byte: 7)
        let facts = try (0..<128).map { offset in
            try SlottedProgressionEventFact(
                slot: ProgressionFactSlot(rawValue: UInt32(offset)),
                fact: CoreProgressionFactFactory.cipherCreated(
                    cipherToken: Self.cipherToken(offset + 1_000)
                )
            )
        }
        let firstBatch = try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: 2,
            totalFactCount: 128,
            facts: Array(facts.prefix(127))
        )
        let secondBatch = try ProgressionEventFactBatch(
            batchIndex: 1,
            totalBatchCount: 2,
            totalFactCount: 128,
            facts: Array(facts.suffix(1))
        )
        let commandDigest = try CoreProgressionDigest.canonical("multi-batch")
        let first = try CorePendingProgressionBatch(
            context: context,
            commandDigest: commandDigest,
            batch: firstBatch
        )
        let second = try CorePendingProgressionBatch(
            context: context,
            commandDigest: commandDigest,
            batch: secondBatch
        )
        var ledger = try CoreProgressionLedger(
            cipherSeeds: [],
            pendingBatches: [second, first]
        )
        let firstReceipt = try Self.receipt(
            context: context,
            batch: firstBatch,
            byte: 7
        )
        let secondReceipt = try Self.receipt(
            context: context,
            batch: secondBatch,
            byte: 8
        )

        XCTAssertThrowsError(try ledger.acknowledge(
            context: context,
            receipt: secondReceipt
        ))
        XCTAssertTrue(try ledger.acknowledge(context: context, receipt: firstReceipt))
        XCTAssertThrowsError(try ledger.clearAcknowledgement(
            context: context,
            receipt: firstReceipt
        ))
        XCTAssertTrue(try ledger.acknowledge(context: context, receipt: secondReceipt))
        XCTAssertTrue(try ledger.clearAcknowledgement(
            context: context,
            receipt: firstReceipt
        ))
        XCTAssertTrue(try ledger.clearAcknowledgement(
            context: context,
            receipt: secondReceipt
        ))
    }

    func testGenerationContextCanBeReplacedWithoutChangingFacts() throws {
        let oldContext = try Self.context(scope: .runtimeGeneration, byte: 4)
        let replacement = try Self.context(scope: .persistent, byte: 5)
        let pending = try Self.pending(context: oldContext, byte: 4)
        var ledger = try CoreProgressionLedger(cipherSeeds: [], pendingBatches: [pending])

        XCTAssertEqual(try ledger.recontextualizePendingBatches(
            from: pending.identity.contextDigest,
            to: replacement
        ), 1)
        let rebound = try XCTUnwrap(ledger.pendingBatches.first)
        XCTAssertEqual(rebound.context, replacement)
        XCTAssertEqual(rebound.batch, pending.batch)
        XCTAssertEqual(rebound.commandDigest, pending.commandDigest)
        XCTAssertNotEqual(rebound.identity, pending.identity)
    }

    func testEvidenceIdentityCollisionsAreRejected() throws {
        let context = try Self.context(scope: .persistent, byte: 6)
        let first = try Self.pending(context: context, byte: 6)
        let conflicting = try CorePendingProgressionBatch(
            context: context,
            commandDigest: try CoreProgressionDigest.canonical("different-command"),
            batch: first.batch
        )
        var ledger = try CoreProgressionLedger(cipherSeeds: [], pendingBatches: [first])
        XCTAssertThrowsError(try ledger.appendPending([conflicting])) {
            XCTAssertEqual($0 as? CoreProgressionEvidenceError, .operationCollision)
        }
    }

    func testProgressionSeedsAndTokensNeverEnterCipherSharePayloadBytes() throws {
        let cipher = Self.cipher()
        let bytes = try CipherSharePayload(cipher: cipher).encoded()
        let progressionSeed = Self.seed(0xEE)
        let token = Self.cipherToken(0xAB).rawValue.data(using: .utf8)!

        XCTAssertNil(bytes.range(of: progressionSeed))
        XCTAssertNil(bytes.range(of: token))
        XCTAssertEqual(bytes.count, CipherSharePayload.byteCount)
    }

    private static func cipher(
        contactID: UUID? = nil,
        keyDeliveryState: KeyDeliveryState? = nil
    ) -> Cipher {
        Cipher(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            label: "Evidence",
            origin: .generated,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            publicID: Data(1...8),
            keyMaterial: Data(repeating: 2, count: 32),
            symbolPermutation: Array(0..<32),
            contactID: contactID,
            keyDeliveryState: keyDeliveryState
        )
    }

    private static func seed(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private static func cipherToken(_ value: Int) -> CipherToken {
        CipherToken(rawValue: String(format: "%064x", value))!
    }

    private static func context(
        scope: RuntimeOperationContextAuthorityScope,
        byte: UInt8
    ) throws -> RuntimePersistableOperationContext {
        try RuntimePersistableOperationContext(
            operationID: RuntimeOperationID(rawValue: "operation-\(byte)"),
            correlationID: RuntimeCorrelationID(
                rawValue: "30000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
            ),
            occurredAtUTC: Date(timeIntervalSince1970: 1_700_000_000.123_456),
            operationIdentifier: RuntimeOperationIdentifier(rawValue: "core.test"),
            runtimeGeneration: 1,
            authorityNonce: UUID(
                uuidString: "40000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
            )!,
            authorityTag: seed(byte),
            authorityScope: scope
        )
    }

    private static func pending(
        context: RuntimePersistableOperationContext,
        byte: UInt8
    ) throws -> CorePendingProgressionBatch {
        let fact = try CoreProgressionFactFactory.cipherCreated(
            cipherToken: cipherToken(Int(byte) + 10)
        )
        let batch = try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: 1,
            totalFactCount: 1,
            facts: [try SlottedProgressionEventFact(
                slot: ProgressionFactSlot(rawValue: 0),
                fact: fact
            )]
        )
        return try CorePendingProgressionBatch(
            context: context,
            commandDigest: CoreProgressionDigest.canonical("command-\(byte)"),
            batch: batch
        )
    }

    private static func receipt(
        context: RuntimePersistableOperationContext,
        batch: ProgressionEventFactBatch,
        byte: UInt8
    ) throws -> ProgressionOutboxBatchReceipt {
        try ProgressionOutboxBatchReceipt(
            contextID: context.runtimeOperationID,
            batchIndex: batch.batchIndex,
            eventIDsBySlot: Dictionary(uniqueKeysWithValues: batch.facts.map { fact in
                let suffix = String(
                    format: "%012llx",
                    UInt64(fact.slot.rawValue) + UInt64(byte) * 1_000
                )
                return (
                    fact.slot,
                    EventID(rawValue: UUID(
                        uuidString: "50000000-0000-0000-0000-\(suffix)"
                    )!)
                )
            }),
            correlationID: CorrelationID(rawValue: UUID(
                uuidString: context.runtimeCorrelationID.rawValue
            )!),
            durableAt: Date(timeIntervalSince1970: 1_700_000_001),
            outboxRevision: 1
        )
    }
}
