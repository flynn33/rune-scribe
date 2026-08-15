import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

private let outboxNamespace = ModuleStateNamespace(
    moduleID: "com.runescribe.runtime.progression-outbox"
)
private let outboxCollectionID = ModuleStateCollectionID(
    rawValue: "progression.outbox"
)!

@MainActor
final class RuntimeProgressionOutboxTests: XCTestCase {
    func testBatchSubmitIsExactlyIdempotentAndAcknowledgementBoundsReceipts() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_000) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_000),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(for: .coreReconciliation)
        XCTAssertEqual(context.authorityScope, .persistent)
        let batch = try factBatch(count: 3)

        let first = try await client.submitBatch(batch, context: context)
        let retry = try await client.submitBatch(batch, context: context)

        XCTAssertEqual(retry, first)
        XCTAssertTrue(first.matches(context: context))
        XCTAssertEqual(first.events.map(\.slot.rawValue), [0, 1, 2])
        await assertOutboxRecordCount(in: store, equals: 4)

        let conflicting = try factBatch(count: 3, tokenPrefix: "conflict")
        do {
            _ = try await client.submitBatch(conflicting, context: context)
            XCTFail("Expected a conflicting same-context batch to be rejected")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProgressionOutboxSubmissionError,
                .conflictingBatch
            )
        }
        await assertOutboxRecordCount(in: store, equals: 4)

        try await client.acknowledgeBatch(first, context: context)
        await assertOutboxRecordCount(in: store, equals: 3)
        try await client.acknowledgeBatch(first, context: context)
        await assertOutboxRecordCount(in: store, equals: 3)
        await runtime.stop()

        let replayProbe = OutboxProgressionProbe(
            store: store,
            results: [.duplicate, .duplicate, .duplicate]
        )
        let replay = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 9_010),
            progression: OutboxProgressionService(probe: replayProbe)
        )
        try await replay.start()
        try await waitUntil {
            let delivered = await replayProbe.envelopes().count
            let retained = await store.recordCount(namespace: outboxNamespace)
            return delivered == 3 && retained == 0
        }
        await replay.stop()
    }

    func testBatchUsesAll128PhysicalMutationsFor127RepeatedEventTypes() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_100) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_100),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(for: .coreReconciliation)
        let batch = try factBatch(count: ProgressionEventFactBatch.maximumFactsPerBatch)

        let receipt = try await client.submitBatch(batch, context: context)

        XCTAssertEqual(receipt.events.count, 127)
        XCTAssertEqual(Set(batch.facts.map(\.fact.eventType)).count, 1)
        await assertOutboxRecordCount(in: store, equals: 128)
        try await client.acknowledgeBatch(receipt, context: context)
        await assertOutboxRecordCount(in: store, equals: 127)
        await runtime.stop()
    }

    func testShareTerminalOperationStampsShareDeliveryAndBidirectionalFactsTogether() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_125) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_124.567_8),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(for: .coreReconciliation)
        let batch = try terminalShareBatch()

        let receipt = try await client.submitBatch(batch, context: context)

        let records = try await outboxRecords(in: store).sorted {
            ($0.factSlot?.rawValue ?? UInt32.max)
                < ($1.factSlot?.rawValue ?? UInt32.max)
        }
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.envelope.eventType.rawValue), [
            "runescribe.share.completed",
            "runescribe.cipher.first-delivery-completed",
            "runescribe.exchange.bidirectional-established",
        ])
        XCTAssertEqual(records.map(\.factSlot?.rawValue), [0, 1, 2])
        XCTAssertTrue(records.allSatisfy {
            $0.producerOperationID == context.runtimeOperationID
                && $0.envelope.correlationID == receipt.correlationID
                && $0.envelope.occurredAt == context.runtimeOccurredAtUTC
                && $0.envelope.sourceModuleID == RuneScribeModuleIDs.core
        })
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: records.compactMap { record in
                record.factSlot.map { ($0, record.envelope.eventID) }
            }),
            receipt.eventIDsBySlot
        )
        await assertOutboxRecordCount(in: store, equals: 4)
        await runtime.stop()
    }

    func testShareCompletionJournalSurvivesRelaunchBeforeCoreReceipt() async throws {
        let store = InMemoryModuleStateStore(
            now: { Date(timeIntervalSince1970: 9_140) }
        )
        let firstCapture = OutboxClientCapture()
        let firstRuntime = try await makeOutboxRuntime(
            store: store,
            capture: firstCapture,
            now: Date(timeIntervalSince1970: 9_140),
            progression: nil
        )
        try await firstRuntime.start()
        let capturedClient = await firstCapture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(
            for: .coreReconciliation
        )
        let artifactID = ShareArtifactID(
            rawValue: UUID(
                uuidString: "9A000000-0000-0000-0000-000000000140"
            )!
        )
        let report = try SharePresentationReportDTO(
            routeClass: .messages,
            result: .sentConfirmed,
            requiredAttachmentAccepted: true
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifactID,
            report: report,
            operationContext: context
        )

        try await client.journalShareCompletion(evidence)
        try await waitUntil {
            await store.recordCount(namespace: outboxNamespace) == 1
        }
        let outstandingBeforeRelaunch = try await client
            .outstandingShareCompletionArtifactIDs()
        XCTAssertEqual(outstandingBeforeRelaunch, Set([artifactID]))
        await firstRuntime.stop()

        let completionCapture = OutboxShareCompletionCapture()
        let replay = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 9_145),
            progression: nil,
            shareCompletionCapture: completionCapture
        )
        try await replay.start()
        try await waitUntil {
            let commands = await completionCapture.commands()
            let retained = await store.recordCount(namespace: outboxNamespace)
            return commands.count == 1 && retained == 0
        }
        let deliveredCommands = await completionCapture.commands()
        let delivered = try XCTUnwrap(deliveredCommands.first)
        XCTAssertEqual(delivered.evidence, evidence)
        await replay.stop()
    }

    func testShareCompletionReservationSurvivesBeforeAndAfterCommitFaults() async throws {
        for (offset, fault) in [
            (UInt64(0), InMemoryModuleStateFaultPoint.beforeTransactionCommit),
            (UInt64(1), InMemoryModuleStateFaultPoint.afterTransactionCommit),
        ] {
            let now = Date(timeIntervalSince1970: TimeInterval(9_160 + offset))
            let store = InMemoryModuleStateStore(now: { now })
            let capture = OutboxClientCapture()
            let runtime = try await makeOutboxRuntime(
                store: store,
                capture: capture,
                now: now,
                progression: nil
            )
            try await runtime.start()
            let capturedClient = await capture.client()
            let client = try XCTUnwrap(capturedClient)
            let context = try await client.issueBackgroundContext(
                for: .coreReconciliation
            )
            let artifactID = ShareArtifactID(
                rawValue: UUID(
                    uuidString: String(
                        format: "9a000000-0000-0000-0000-%012llx",
                        offset + 150
                    )
                )!
            )
            let evidence = try ShareArtifactCompletionEvidenceDTO(
                artifactID: artifactID,
                report: SharePresentationReportDTO(
                    routeClass: .messages,
                    result: .sentConfirmed,
                    requiredAttachmentAccepted: true
                ),
                operationContext: context
            )
            try await client.reserveShareCompletion(for: artifactID)
            await store.injectFault(at: fault)

            if fault == .beforeTransactionCommit {
                do {
                    try await client.journalShareCompletion(evidence)
                    XCTFail("Expected the pre-commit fault to retain the reservation")
                } catch ModuleStateStoreError.injectedFailure {}
                let retainedReservationCount = await store.recordCount(
                    namespace: outboxNamespace
                )
                XCTAssertEqual(retainedReservationCount, 1)
                try await client.journalShareCompletion(evidence)
            } else {
                try await client.journalShareCompletion(evidence)
            }
            let durableTerminalCount = await store.recordCount(
                namespace: outboxNamespace
            )
            XCTAssertEqual(durableTerminalCount, 1)
            await runtime.stop()

            let completionCapture = OutboxShareCompletionCapture()
            let replay = try await makeOutboxRuntime(
                store: store,
                capture: OutboxClientCapture(),
                now: now.addingTimeInterval(5),
                progression: nil,
                shareCompletionCapture: completionCapture
            )
            try await replay.start()
            try await waitUntil {
                let commands = await completionCapture.commands()
                let retained = await store.recordCount(namespace: outboxNamespace)
                return commands.count == 1 && retained == 0
            }
            let replayedCommands = await completionCapture.commands()
            XCTAssertEqual(
                replayedCommands.first?.evidence,
                evidence
            )
            await replay.stop()
        }
    }

    func testShareCompletionJournalRejectsChangedTerminalEvidence() async throws {
        let now = Date(timeIntervalSince1970: 9_170)
        let store = InMemoryModuleStateStore(now: { now })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: now,
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(
            for: .coreReconciliation
        )
        let artifactID = ShareArtifactID(
            rawValue: UUID(
                uuidString: "9A000000-0000-0000-0000-000000000170"
            )!
        )
        let original = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifactID,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: context
        )
        let changed = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifactID,
            report: SharePresentationReportDTO(
                routeClass: .airDrop,
                result: .completedBySystem
            ),
            operationContext: context
        )
        try await client.reserveShareCompletion(for: artifactID)
        try await client.journalShareCompletion(original)

        do {
            try await client.journalShareCompletion(changed)
            XCTFail("Expected exact terminal-evidence collision rejection")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProgressionOutboxSubmissionError,
                .conflictingShareCompletion
            )
        }
        let retainedCount = await store.recordCount(namespace: outboxNamespace)
        XCTAssertEqual(retainedCount, 1)
        await runtime.stop()
    }

    func testRelaunchReclaimsAnInterruptedShareReservation() async throws {
        let now = Date(timeIntervalSince1970: 9_180)
        let store = InMemoryModuleStateStore(now: { now })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: now,
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let artifactID = ShareArtifactID(
            rawValue: UUID(
                uuidString: "9A000000-0000-0000-0000-000000000180"
            )!
        )
        try await client.reserveShareCompletion(for: artifactID)
        let outstandingReservationIDs = try await client
            .outstandingShareCompletionArtifactIDs()
        XCTAssertTrue(outstandingReservationIDs.isEmpty)
        let retainedBeforeStop = await store.recordCount(
            namespace: outboxNamespace
        )
        XCTAssertEqual(retainedBeforeStop, 1)
        await runtime.stop()

        let replay = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: now.addingTimeInterval(5),
            progression: nil
        )
        try await replay.start()
        let retainedAfterRelaunch = await store.recordCount(
            namespace: outboxNamespace
        )
        XCTAssertEqual(retainedAfterRelaunch, 0)
        await replay.stop()
    }

    func testEarlyBatchAcknowledgementCannotStrandTheFinalBatch() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_150) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_150),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(for: .coreReconciliation)
        let batches = try factBatches(count: 128)
        XCTAssertEqual(batches.count, 2)

        do {
            _ = try await client.submitBatch(batches[1], context: context)
            XCTFail("Expected an out-of-order batch to be rejected")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProgressionOutboxSubmissionError,
                .missingPriorBatch
            )
        }

        let first = try await client.submitBatch(batches[0], context: context)
        try await client.acknowledgeBatch(first, context: context)
        await assertOutboxRecordCount(in: store, equals: 128)

        let final = try await client.submitBatch(batches[1], context: context)
        await assertOutboxRecordCount(in: store, equals: 130)
        try await client.acknowledgeBatch(final, context: context)
        await assertOutboxRecordCount(in: store, equals: 128)
        await runtime.stop()
    }

    func testBeforeCommitBatchFailureLeavesNoPartialEventsOrReceipt() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_175) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_175),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(for: .evidenceRecovery)
        let batch = try factBatch(count: 2)
        await store.injectFault(at: .beforeTransactionCommit)

        do {
            _ = try await client.submitBatch(batch, context: context)
            XCTFail("Expected a pre-commit interruption")
        } catch ModuleStateStoreError.injectedFailure {}
        await assertOutboxRecordCount(in: store, equals: 0)

        let receipt = try await client.submitBatch(batch, context: context)
        XCTAssertEqual(receipt.events.count, 2)
        await assertOutboxRecordCount(in: store, equals: 3)
        await runtime.stop()
    }

    func testAfterCommitBatchRetryReturnsTheOriginalAggregateReceipt() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_200) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_200),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let context = try await client.issueBackgroundContext(for: .evidenceRecovery)
        let batch = try factBatch(count: 2)
        await store.injectFault(at: .afterTransactionCommit)

        do {
            _ = try await client.submitBatch(batch, context: context)
            XCTFail("Expected an after-commit interruption")
        } catch ModuleStateStoreError.injectedFailure {}

        let recovered = try await client.submitBatch(batch, context: context)
        XCTAssertEqual(recovered.events.count, 2)
        await assertOutboxRecordCount(in: store, equals: 3)
        try await client.acknowledgeBatch(recovered, context: context)
        await assertOutboxRecordCount(in: store, equals: 2)
        await runtime.stop()
    }

    func testPubliclyDecodedContextWithFabricatedAuthorityTagIsRejected() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_300) })
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 9_300),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let valid = try await client.issueBackgroundContext(for: .evidenceRecovery)
        let encoded = try JSONEncoder().encode(valid)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["authorityTag"] = Data(repeating: 0, count: 32).base64EncodedString()
        let fabricatedData = try JSONSerialization.data(withJSONObject: object)
        let fabricated = try JSONDecoder().decode(
            RuntimePersistableOperationContext.self,
            from: fabricatedData
        )

        do {
            _ = try await client.submitBatch(
                factBatch(count: 1),
                context: fabricated
            )
            XCTFail("Expected runtime authority verification to fail")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProgressionOutboxSubmissionError,
                .invalidOperationContext
            )
        }
        await assertOutboxRecordCount(in: store, equals: 0)
        await runtime.stop()
    }

    func testPersistentContextSurvivesRelaunch() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 9_400) })
        let firstCapture = OutboxClientCapture()
        let firstRuntime = try await makeOutboxRuntime(
            store: store,
            capture: firstCapture,
            now: Date(timeIntervalSince1970: 9_400),
            progression: nil
        )
        try await firstRuntime.start()
        let firstCapturedClient = await firstCapture.client()
        let firstClient = try XCTUnwrap(firstCapturedClient)
        let retained = try await firstClient.issueBackgroundContext(for: .evidenceRecovery)
        XCTAssertEqual(retained.authorityScope, .persistent)
        await firstRuntime.stop()

        let secondCapture = OutboxClientCapture()
        let secondRuntime = try await makeOutboxRuntime(
            store: store,
            capture: secondCapture,
            now: Date(timeIntervalSince1970: 9_410),
            progression: nil
        )
        try await secondRuntime.start()
        let secondCapturedClient = await secondCapture.client()
        let secondClient = try XCTUnwrap(secondCapturedClient)
        let receipt = try await secondClient.submitBatch(
            factBatch(count: 1),
            context: retained
        )
        XCTAssertTrue(receipt.matches(context: retained))
        await secondRuntime.stop()
    }

    func testContextAndReceiptRoundTripInsideISO8601LedgerAndAckAfterRelaunch() async throws {
        struct LedgerContainer: Codable, Equatable {
            let context: RuntimePersistableOperationContext
            let receipt: ProgressionOutboxBatchReceipt
        }

        let fractional = Date(timeIntervalSince1970: 9_450.123_456)
        let store = InMemoryModuleStateStore(now: { fractional })
        let firstCapture = OutboxClientCapture()
        let firstRuntime = try await makeOutboxRuntime(
            store: store,
            capture: firstCapture,
            now: fractional,
            progression: nil
        )
        try await firstRuntime.start()
        let firstCapturedClient = await firstCapture.client()
        let firstClient = try XCTUnwrap(firstCapturedClient)
        let context = try await firstClient.issueBackgroundContext(for: .evidenceRecovery)
        let receipt = try await firstClient.submitBatch(
            factBatch(count: 1),
            context: context
        )
        let original = LedgerContainer(context: context, receipt: receipt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(LedgerContainer.self, from: encoded)
        XCTAssertEqual(restored, original)
        await firstRuntime.stop()

        let secondCapture = OutboxClientCapture()
        let secondRuntime = try await makeOutboxRuntime(
            store: store,
            capture: secondCapture,
            now: Date(timeIntervalSince1970: 9_460.987_654),
            progression: nil
        )
        try await secondRuntime.start()
        let secondCapturedClient = await secondCapture.client()
        let secondClient = try XCTUnwrap(secondCapturedClient)
        try await secondClient.acknowledgeBatch(
            restored.receipt,
            context: restored.context
        )
        await assertOutboxRecordCount(in: store, equals: 1)
        await secondRuntime.stop()
    }

    func testGenerationScopedContextDoesNotBlockUtilityAndRejectsAfterRelaunch() async throws {
        let absentStore = InMemoryModuleStateStore()
        let firstCapture = OutboxClientCapture()
        let firstRuntime = try await makeOutboxRuntime(
            store: absentStore,
            capture: firstCapture,
            now: Date(timeIntervalSince1970: 9_500),
            progression: nil,
            installStore: false
        )
        try await firstRuntime.start()
        let firstCapturedClient = await firstCapture.client()
        let firstClient = try XCTUnwrap(firstCapturedClient)
        let ephemeral = try await firstClient.issueBackgroundContext(for: .coreBootstrap)
        XCTAssertEqual(ephemeral.authorityScope, .runtimeGeneration)
        do {
            _ = try await firstClient.submitBatch(
                factBatch(count: 1),
                context: ephemeral
            )
            XCTFail("Expected durable submission to fail without ModuleStateStore")
        } catch {}
        await firstRuntime.stop()

        let persistentStore = InMemoryModuleStateStore()
        let secondCapture = OutboxClientCapture()
        let secondRuntime = try await makeOutboxRuntime(
            store: persistentStore,
            capture: secondCapture,
            now: Date(timeIntervalSince1970: 9_510),
            progression: nil
        )
        try await secondRuntime.start()
        let secondCapturedClient = await secondCapture.client()
        let secondClient = try XCTUnwrap(secondCapturedClient)
        do {
            _ = try await secondClient.submitBatch(
                factBatch(count: 1),
                context: ephemeral
            )
            XCTFail("Expected prior-generation authority to be rejected")
        } catch {
            XCTAssertEqual(
                error as? RuntimeProgressionOutboxSubmissionError,
                .invalidOperationContext
            )
        }
        let recovery = try await secondClient.issueBackgroundContext(for: .evidenceRecovery)
        XCTAssertEqual(recovery.authorityScope, .persistent)
        let receipt = try await secondClient.submitBatch(
            factBatch(count: 1),
            context: recovery
        )
        try await secondClient.acknowledgeBatch(receipt, context: recovery)
        await assertOutboxRecordCount(in: persistentStore, equals: 1)
        await secondRuntime.stop()
    }

    func testSubmitIsDurableWithoutProgressionAndReplaysInDeterministicOrderAfterRelaunch() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 10_000) })
        let firstCapture = OutboxClientCapture()
        let firstRuntime = try await makeOutboxRuntime(
            store: store,
            capture: firstCapture,
            now: Date(timeIntervalSince1970: 10_000),
            progression: nil
        )
        try await firstRuntime.start()
        let firstCapturedClient = await firstCapture.client()
        let client = try XCTUnwrap(firstCapturedClient)
        let firstReceipt = try await client.submit(
            try eventFact(type: "runescribe.exchange.bidirectional-established")
        )
        let secondReceipt = try await client.submit(
            try eventFact(type: "runescribe.exchange.bidirectional-established")
        )

        let namespace = ModuleStateNamespace(
            moduleID: "com.runescribe.runtime.progression-outbox"
        )
        try await waitUntil {
            await store.recordCount(namespace: namespace) == 2
        }
        let firstSnapshot = await firstRuntime.snapshot()
        XCTAssertEqual(firstSnapshot.status, .running)
        await firstRuntime.stop()

        let probe = OutboxProgressionProbe(
            store: store,
            results: [.duplicate, .duplicate]
        )
        let secondCapture = OutboxClientCapture()
        let secondRuntime = try await makeOutboxRuntime(
            store: store,
            capture: secondCapture,
            now: Date(timeIntervalSince1970: 10_010),
            progression: OutboxProgressionService(probe: probe)
        )
        try await secondRuntime.start()
        try await waitUntil {
            let receivedCount = await probe.envelopes().count
            let storedCount = await store.recordCount(namespace: namespace)
            return receivedCount == 2 && storedCount == 0
        }

        let envelopes = await probe.envelopes()
        let expectedIDs = [firstReceipt.eventID, secondReceipt.eventID].sorted()
        XCTAssertEqual(envelopes.map(\.eventID), expectedIDs)
        XCTAssertEqual(Set(envelopes.map(\.correlationID)), [
            firstReceipt.correlationID,
            secondReceipt.correlationID,
        ])
        let deliveriesWereDurable = await probe.allDeliveriesObservedDurableRecord()
        XCTAssertTrue(deliveriesWereDurable)
        XCTAssertTrue(envelopes.allSatisfy { $0.sourceModuleID == RuneScribeModuleIDs.core })
        XCTAssertTrue(envelopes.allSatisfy {
            $0.occurredAt == Date(timeIntervalSince1970: 10_000)
        })
        await secondRuntime.stop()
    }

    func testTerminalOutcomesCompactWhileDeferredOutcomesRemainRetryable() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 20_000) })
        let rejection = try XCTUnwrap(
            ProgressionRejectionCode(rawValue: "event.permanently-rejected")
        )
        let transactionID = try XCTUnwrap(
            GrantTransactionID(rawValue: "grant.transaction-1")
        )
        let probe = OutboxProgressionProbe(
            store: store,
            results: [
                .applied(
                    transactionID: transactionID,
                    revision: 1,
                    delta: ProgressionStateDeltaSummary(changedStatisticCount: 1)
                ),
                .duplicate,
                .ignoredIneligible,
                .rejectedPermanent(reason: rejection),
                .deferredUnsupportedSchema,
                .deferredStoreUnavailable,
            ]
        )
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 20_000),
            progression: OutboxProgressionService(probe: probe)
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        for index in 0 ..< 6 {
            _ = try await client.submit(
                try eventFact(type: "runescribe.exchange.bidirectional-established")
            )
            try await waitUntil { await probe.envelopes().count >= index + 1 }
        }

        let namespace = ModuleStateNamespace(
            moduleID: "com.runescribe.runtime.progression-outbox"
        )
        try await waitUntil {
            await store.recordCount(namespace: namespace) == 2
        }
        let retainedRecords = try await outboxRecords(in: store)
        XCTAssertEqual(retainedRecords.count, 2)
        XCTAssertTrue(retainedRecords.allSatisfy { $0.state == .ready })
        XCTAssertTrue(retainedRecords.allSatisfy { $0.attemptCount == 1 })
        XCTAssertTrue(retainedRecords.allSatisfy {
            $0.lastAttemptAt == Date(timeIntervalSince1970: 20_000)
                && $0.nextAttemptAt == Date(timeIntervalSince1970: 20_002)
        })
        let deliveriesWereDurable = await probe.allDeliveriesObservedDurableRecord()
        XCTAssertTrue(deliveriesWereDurable)
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        await runtime.stop()
    }

    func testAfterCommitInterruptionRetainsEvidenceForReplay() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 30_000) })
        let probe = OutboxProgressionProbe(store: store, results: [.duplicate])
        let capture = OutboxClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 30_000),
            progression: OutboxProgressionService(probe: probe)
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)

        // The outbox insert commits, but the adapter reports an interruption to
        // the caller. Relaunch can still recover the canonical stamped event.
        await store.injectFault(at: .afterTransactionCommit)
        do {
            _ = try await client.submit(
                try eventFact(type: "runescribe.exchange.bidirectional-established")
            )
            XCTFail("Expected simulated after-commit interruption")
        } catch ModuleStateStoreError.injectedFailure {}

        let namespace = ModuleStateNamespace(
            moduleID: "com.runescribe.runtime.progression-outbox"
        )
        let retainedCount = await store.recordCount(namespace: namespace)
        XCTAssertEqual(retainedCount, 1)
        await runtime.stop()

        let replayProbe = OutboxProgressionProbe(store: store, results: [.duplicate])
        let replayRuntime = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 30_010),
            progression: OutboxProgressionService(probe: replayProbe)
        )
        try await replayRuntime.start()
        try await waitUntil {
            let receivedCount = await replayProbe.envelopes().count
            let storedCount = await store.recordCount(namespace: namespace)
            return receivedCount == 1 && storedCount == 0
        }
        await replayRuntime.stop()
    }

    func testRetryBackoffCapsAtOneHour() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 40_000) })
        try await seedOutboxRecord(
            in: store,
            occurredAt: Date(timeIntervalSince1970: 39_000),
            attemptCount: 12,
            nextAttemptAt: Date(timeIntervalSince1970: 40_000)
        )
        let probe = OutboxProgressionProbe(
            store: store,
            results: [.deferredUnsupportedSchema]
        )
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 40_000),
            progression: OutboxProgressionService(probe: probe)
        )
        try await runtime.start()
        try await waitUntil {
            let records = try? await self.outboxRecords(in: store)
            return records?.first?.attemptCount == 13
                && records?.first?.state == .ready
        }
        let retainedRecords = try await outboxRecords(in: store)
        let retained = try XCTUnwrap(retainedRecords.first)
        XCTAssertEqual(retained.lastAttemptAt, Date(timeIntervalSince1970: 40_000))
        XCTAssertEqual(retained.nextAttemptAt, Date(timeIntervalSince1970: 43_600))
        await runtime.stop()
    }

    func testAfterCommitFaultsDuringDeliveryRemainReplaySafe() async throws {
        try await verifyInFlightAfterCommitRecovery()
        try await verifyTerminalAfterCommitRecovery()
        try await verifyCompactionAfterCommitRecovery()
    }

    func testRecoveryEndpointRemainsRegisteredButRejectsWhenGuardIsDisabled() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 80_000) })
        let recoveryCapture = OutboxRecoveryClientCapture()
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 80_000),
            progression: OutboxProgressionService(
                probe: OutboxProgressionProbe(store: store, results: [])
            ),
            permitsRecovery: false,
            recoveryCapture: recoveryCapture
        )
        try await runtime.start()
        let capturedClient = await recoveryCapture.client()
        let client = try XCTUnwrap(capturedClient)

        do {
            _ = try await client.send(
                ProgressionRecoveryRequest(confirmationToken: UUID()),
                to: RuntimeProgressionEndpointCatalog.rebuild
            )
            XCTFail("Expected the guarded recovery handler to reject the request")
        } catch {
            XCTAssertEqual(error as? RuntimeProgressionRecoveryError, .disabled)
        }
        await runtime.stop()
    }

    func testDiagnosticsAreEnrichedWithRuntimeOwnedPendingOutboxCount() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 90_000) })
        let outboxCapture = OutboxClientCapture()
        let diagnosticsCapture = OutboxDiagnosticsClientCapture()
        let probe = OutboxProgressionProbe(
            store: store,
            results: [.deferredUnsupportedSchema]
        )
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: outboxCapture,
            now: Date(timeIntervalSince1970: 90_000),
            progression: OutboxProgressionService(probe: probe),
            diagnosticsCapture: diagnosticsCapture
        )
        try await runtime.start()
        let capturedOutboxClient = await outboxCapture.client()
        let submittedClient = try XCTUnwrap(capturedOutboxClient)
        _ = try await submittedClient.submit(
            try eventFact(type: "runescribe.exchange.bidirectional-established")
        )
        try await waitUntil {
            let records = try? await self.outboxRecords(in: store)
            return records?.count == 1 && records?.first?.state == .ready
        }

        let capturedDiagnosticsClient = await diagnosticsCapture.client()
        let diagnosticsClient = try XCTUnwrap(capturedDiagnosticsClient)
        let summary = try await diagnosticsClient.diagnosticsSummary()
        XCTAssertEqual(summary.pendingOutboxCount, 1)
        await runtime.stop()
    }

    private func makeOutboxRuntime(
        store: InMemoryModuleStateStore,
        capture: OutboxClientCapture,
        now: Date,
        progression: OutboxProgressionService?,
        permitsRecovery: Bool = true,
        recoveryCapture: OutboxRecoveryClientCapture? = nil,
        diagnosticsCapture: OutboxDiagnosticsClientCapture? = nil,
        shareCompletionCapture: OutboxShareCompletionCapture? = nil,
        installStore: Bool = true
    ) async throws -> RuneScribeRuntime {
        let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
        let runtime = RuneScribeRuntime(
            runtimeVersion: version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { now },
                nextUUID: { UUID() },
                permitsProgressionRecovery: permitsRecovery
            )
        )
        let core = installStore
            ? outboxCoreDescriptor(
                version: version,
                publishesShareCompletion: shareCompletionCapture != nil
            )
            : outboxCoreDescriptorWithoutStateStore(version: version)
        let ui = outboxUIDescriptor(version: version)
        try await runtime.register(
            manifest: outboxManifest(for: core, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: core,
                make: {
                    OutboxTestModule(descriptor: core) { context in
                        await capture.setClient(
                            try await context.progressionOutboxClient()
                        )
                        if let shareCompletionCapture {
                            try await context.registerEndpoint(
                                RuntimeApplicationEndpointCatalog
                                    .completeShareArtifact
                            ) { _, command in
                                await shareCompletionCapture.complete(command)
                            }
                        }
                    }
                }
            )
        )
        if let progression {
            let descriptor = outboxProgressionDescriptor(version: version)
            try await runtime.register(
                manifest: outboxManifest(for: descriptor, runtimeVersion: version),
                factory: AnyModuleFactory(
                    descriptor: descriptor,
                    make: {
                        OutboxTestModule(descriptor: descriptor) { context in
                            try await context.registerProgressionEndpoints(progression)
                        }
                    }
                )
            )
        }
        if let recoveryCapture {
            let descriptor = outboxHostDescriptor(version: version)
            try await runtime.register(
                manifest: outboxManifest(for: descriptor, runtimeVersion: version),
                factory: AnyModuleFactory(
                    descriptor: descriptor,
                    make: {
                        OutboxTestModule(descriptor: descriptor) { context in
                            await recoveryCapture.setClient(
                                try await context.commandClient(
                                    to: .role(RuneScribeRoles.progression)
                                )
                            )
                        }
                    }
                )
            )
        }
        if let diagnosticsCapture {
            let descriptor = outboxDiagnosticsDescriptor(version: version)
            try await runtime.register(
                manifest: outboxManifest(for: descriptor, runtimeVersion: version),
                factory: AnyModuleFactory(
                    descriptor: descriptor,
                    make: {
                        OutboxTestModule(descriptor: descriptor) { context in
                            await diagnosticsCapture.setClient(
                                try await context.progressionClient()
                            )
                        }
                    }
                )
            )
        }
        try await runtime.register(
            manifest: outboxManifest(for: ui, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: ui,
                make: { OutboxTestModule(descriptor: ui) { _ in } }
            )
        )
        if installStore {
            try await runtime.installPlatformAdapter(
                store,
                for: RuneScribeServiceKeys.moduleStateStore
            )
        }
        return runtime
    }

    private func factBatch(
        count: Int,
        tokenPrefix: String = "relationship"
    ) throws -> ProgressionEventFactBatch {
        let facts = try (0 ..< count).map { index in
            let suffix = String(format: "%08x", index)
            let token = String(repeating: "r", count: 32) + tokenPrefix + suffix
            return try SlottedProgressionEventFact(
                slot: ProgressionFactSlot(rawValue: UInt32(index)),
                fact: ProgressionEventFact(
                    eventType: "runescribe.exchange.bidirectional-established",
                    eligibility: DomainEventEligibilityMetadata(
                        state: .eligible,
                        reason: try XCTUnwrap(
                            EligibilityReasonID(rawValue: "eligibility.test")
                        )
                    ),
                    payload: try DomainEventPayload(
                        relationshipToken: XCTUnwrap(
                            RelationshipToken(rawValue: token)
                        )
                    )
                )
            )
        }
        let total = UInt32(count)
        let batchCount = UInt32(
            (count + ProgressionEventFactBatch.maximumFactsPerBatch - 1)
                / ProgressionEventFactBatch.maximumFactsPerBatch
        )
        return try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: batchCount,
            totalFactCount: total,
            facts: facts
        )
    }

    private func factBatches(
        count: Int,
        tokenPrefix: String = "relationship"
    ) throws -> [ProgressionEventFactBatch] {
        let total = UInt32(count)
        let maximum = ProgressionEventFactBatch.maximumFactsPerBatch
        let batchCount = (count + maximum - 1) / maximum
        return try (0 ..< batchCount).map { batchIndex in
            let start = batchIndex * maximum
            let end = min(count, start + maximum)
            let facts = try (start ..< end).map { index in
                let suffix = String(format: "%08x", index)
                let token = String(repeating: "r", count: 32) + tokenPrefix + suffix
                return try SlottedProgressionEventFact(
                    slot: ProgressionFactSlot(rawValue: UInt32(index)),
                    fact: ProgressionEventFact(
                        eventType: "runescribe.exchange.bidirectional-established",
                        eligibility: DomainEventEligibilityMetadata(
                            state: .eligible,
                            reason: try XCTUnwrap(
                                EligibilityReasonID(rawValue: "eligibility.test")
                            )
                        ),
                        payload: try DomainEventPayload(
                            relationshipToken: XCTUnwrap(
                                RelationshipToken(rawValue: token)
                            )
                        )
                    )
                )
            }
            return try ProgressionEventFactBatch(
                batchIndex: UInt32(batchIndex),
                totalBatchCount: UInt32(batchCount),
                totalFactCount: total,
                facts: facts
            )
        }
    }

    private func terminalShareBatch() throws -> ProgressionEventFactBatch {
        let messageToken = try XCTUnwrap(
            MessageToken(rawValue: String(repeating: "m", count: 32))
        )
        let cipherToken = try XCTUnwrap(
            CipherToken(rawValue: String(repeating: "c", count: 32))
        )
        let relationshipToken = try XCTUnwrap(
            RelationshipToken(rawValue: String(repeating: "r", count: 32))
        )
        let codexID = try XCTUnwrap(CodexID(rawValue: "codex.norse"))
        let facts = [
            try ProgressionEventFact(
                eventType: "runescribe.share.completed",
                eligibility: DomainEventEligibilityMetadata(
                    state: .eligible,
                    reason: try XCTUnwrap(
                        EligibilityReasonID(
                            rawValue: "eligibility.eligible.message-sent-confirmed"
                        )
                    )
                ),
                payload: DomainEventPayload(
                    messageToken: messageToken,
                    relationshipToken: relationshipToken,
                    routeClass: .messages,
                    codexIDs: [codexID],
                    keyIncluded: true,
                    linkedRelationship: true
                )
            ),
            try ProgressionEventFact(
                eventType: "runescribe.cipher.first-delivery-completed",
                eligibility: DomainEventEligibilityMetadata(
                    state: .eligible,
                    reason: try XCTUnwrap(
                        EligibilityReasonID(
                            rawValue: "eligibility.eligible.domain-commit"
                        )
                    )
                ),
                payload: DomainEventPayload(
                    cipherToken: cipherToken,
                    relationshipToken: relationshipToken,
                    keyIncluded: true,
                    linkedRelationship: true
                )
            ),
            try ProgressionEventFact(
                eventType: "runescribe.exchange.bidirectional-established",
                eligibility: DomainEventEligibilityMetadata(
                    state: .eligible,
                    reason: try XCTUnwrap(
                        EligibilityReasonID(
                            rawValue: "eligibility.eligible.domain-commit"
                        )
                    )
                ),
                payload: DomainEventPayload(
                    relationshipToken: relationshipToken
                )
            ),
        ]
        return try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: 1,
            totalFactCount: 3,
            facts: try facts.enumerated().map { index, fact in
                try SlottedProgressionEventFact(
                    slot: ProgressionFactSlot(rawValue: UInt32(index)),
                    fact: fact
                )
            }
        )
    }

    private func eventFact(type: EventIdentifier) throws -> ProgressionEventFact {
        try ProgressionEventFact(
            eventType: type,
            eligibility: DomainEventEligibilityMetadata(
                state: .eligible,
                reason: try XCTUnwrap(EligibilityReasonID(rawValue: "eligibility.test"))
            ),
            payload: try DomainEventPayload(
                relationshipToken: XCTUnwrap(
                    RelationshipToken(rawValue: String(repeating: "r", count: 32))
                )
            )
        )
    }

    private func verifyInFlightAfterCommitRecovery() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 50_000) })
        let authorityBootstrap = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 49_999),
            progression: nil
        )
        try await authorityBootstrap.start()
        await authorityBootstrap.stop()
        try await seedOutboxRecord(
            in: store,
            occurredAt: Date(timeIntervalSince1970: 50_000),
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 50_000)
        )
        await store.injectFault(at: .afterTransactionCommit)
        let probe = OutboxProgressionProbe(store: store, results: [.duplicate])
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 50_000),
            progression: OutboxProgressionService(probe: probe)
        )
        try await runtime.start()
        try await waitUntil {
            let records = try? await self.outboxRecords(in: store)
            return records?.first?.state == .inFlight
        }
        let deliveriesBeforeRelaunch = await probe.envelopes().count
        XCTAssertEqual(deliveriesBeforeRelaunch, 0)
        await runtime.stop()

        let replayProbe = OutboxProgressionProbe(store: store, results: [.duplicate])
        let replay = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 50_003),
            progression: OutboxProgressionService(probe: replayProbe)
        )
        try await replay.start()
        try await waitUntil {
            let deliveryCount = await replayProbe.envelopes().count
            let storedCount = await store.recordCount(namespace: outboxNamespace)
            return deliveryCount == 1 && storedCount == 0
        }
        await replay.stop()
    }

    private func verifyTerminalAfterCommitRecovery() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 60_000) })
        try await seedOutboxRecord(
            in: store,
            occurredAt: Date(timeIntervalSince1970: 60_000),
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 60_000)
        )
        let probe = OutboxProgressionProbe(
            store: store,
            results: [.duplicate],
            faultAtApply: .init(afterSuccessfulCalls: 0)
        )
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 60_000),
            progression: OutboxProgressionService(probe: probe)
        )
        try await runtime.start()
        try await waitUntil {
            let records = try? await self.outboxRecords(in: store)
            return records?.first?.state == .acknowledged
        }
        await runtime.stop()

        let replayProbe = OutboxProgressionProbe(store: store, results: [.duplicate])
        let replay = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 60_010),
            progression: OutboxProgressionService(probe: replayProbe)
        )
        try await replay.start()
        try await waitUntil { await store.recordCount(namespace: outboxNamespace) == 0 }
        let redeliveries = await replayProbe.envelopes().count
        XCTAssertEqual(redeliveries, 0)
        await replay.stop()
    }

    private func verifyCompactionAfterCommitRecovery() async throws {
        let store = InMemoryModuleStateStore(now: { Date(timeIntervalSince1970: 70_000) })
        try await seedOutboxRecord(
            in: store,
            occurredAt: Date(timeIntervalSince1970: 70_000),
            attemptCount: 0,
            nextAttemptAt: Date(timeIntervalSince1970: 70_000)
        )
        let probe = OutboxProgressionProbe(
            store: store,
            results: [.duplicate],
            faultAtApply: .init(afterSuccessfulCalls: 1)
        )
        let runtime = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 70_000),
            progression: OutboxProgressionService(probe: probe)
        )
        try await runtime.start()
        try await waitUntil {
            let deliveryCount = await probe.envelopes().count
            let storedCount = await store.recordCount(namespace: outboxNamespace)
            return deliveryCount == 1 && storedCount == 0
        }
        await runtime.stop()

        let replayProbe = OutboxProgressionProbe(store: store, results: [.duplicate])
        let replay = try await makeOutboxRuntime(
            store: store,
            capture: OutboxClientCapture(),
            now: Date(timeIntervalSince1970: 70_010),
            progression: OutboxProgressionService(probe: replayProbe)
        )
        try await replay.start()
        let storedCount = await store.recordCount(namespace: outboxNamespace)
        let redeliveries = await replayProbe.envelopes().count
        XCTAssertEqual(storedCount, 0)
        XCTAssertEqual(redeliveries, 0)
        await replay.stop()
    }

    private func seedOutboxRecord(
        in store: InMemoryModuleStateStore,
        occurredAt: Date,
        attemptCount: UInt16,
        nextAttemptAt: Date
    ) async throws {
        _ = try await store.prepareNamespace(outboxNamespace, schemaVersion: 1)
        let eventUUID = UUID()
        let envelope = try DomainEventEnvelope(
            schemaVersion: 1,
            eventID: EventID(rawValue: eventUUID),
            correlationID: CorrelationID(rawValue: UUID()),
            eventType: try XCTUnwrap(EventIdentifier(rawValue: "test.seeded-event")),
            sourceModuleID: RuneScribeModuleIDs.core,
            occurredAt: occurredAt,
            eligibility: DomainEventEligibilityMetadata(
                state: .eligible,
                reason: try XCTUnwrap(EligibilityReasonID(rawValue: "eligibility.test"))
            ),
            payload: try DomainEventPayload()
        )
        let record = OutboxRecordMirror(
            envelope: envelope,
            producerOperationID: nil,
            factSlot: nil,
            state: .ready,
            attemptCount: attemptCount,
            lastAttemptAt: nil,
            nextAttemptAt: nextAttemptAt,
            diagnosticCode: nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let key = ModuleStateRecordKey(
            collectionID: outboxCollectionID,
            recordID: try XCTUnwrap(
                ModuleStateRecordID(rawValue: eventUUID.uuidString.lowercased())
            )
        )
        _ = try await store.transact(
            namespace: outboxNamespace,
            transaction: ModuleStateTransaction(
                transactionID: UUID(),
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: try encoder.encode(record),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
    }

    private func outboxRecords(
        in store: InMemoryModuleStateStore
    ) async throws -> [OutboxRecordMirror] {
        let request = try ModuleStateScanRequest(
            collectionID: outboxCollectionID,
            limit: ModuleStateScanRequest.maximumLimit
        )
        let page = try await store.scan(namespace: outboxNamespace, request: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try page.records.map { try decoder.decode(OutboxRecordMirror.self, from: $0.payload) }
    }

    private func waitUntil(
        _ predicate: () async -> Bool
    ) async throws {
        for _ in 0 ..< 200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for asynchronous runtime state")
    }

    private func assertOutboxRecordCount(
        in store: InMemoryModuleStateStore,
        equals expected: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let actual = await store.recordCount(namespace: outboxNamespace)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
}

private actor OutboxClientCapture {
    private var storedClient: RuntimeProgressionOutboxClient?

    func setClient(_ value: RuntimeProgressionOutboxClient) {
        storedClient = value
    }

    func client() -> RuntimeProgressionOutboxClient? { storedClient }
}

private actor OutboxShareCompletionCapture {
    private var received: [CompleteShareArtifactCommand] = []

    func complete(
        _ command: CompleteShareArtifactCommand
    ) -> ShareArtifactCompletionResultDTO {
        received.append(command)
        return .released
    }

    func commands() -> [CompleteShareArtifactCommand] { received }
}

private actor OutboxProgressionProbe {
    private let store: InMemoryModuleStateStore
    private var results: [ProgressionEventApplyResult]
    private var faultAtApply: OutboxFaultAtApply?
    private var received: [DomainEventEnvelope] = []
    private var durableAtDelivery = true

    init(
        store: InMemoryModuleStateStore,
        results: [ProgressionEventApplyResult],
        faultAtApply: OutboxFaultAtApply? = nil
    ) {
        self.store = store
        self.results = results
        self.faultAtApply = faultAtApply
    }

    func apply(_ envelope: DomainEventEnvelope) async -> ProgressionEventApplyResult {
        if await store.recordCount(namespace: outboxNamespace) == 0 {
            durableAtDelivery = false
        }
        received.append(envelope)
        if let faultAtApply {
            self.faultAtApply = nil
            await store.injectFault(
                at: .afterTransactionCommit,
                afterSuccessfulCalls: faultAtApply.afterSuccessfulCalls
            )
        }
        return results.isEmpty ? .duplicate : results.removeFirst()
    }

    func envelopes() -> [DomainEventEnvelope] { received }
    func allDeliveriesObservedDurableRecord() -> Bool { durableAtDelivery }
}

private struct OutboxFaultAtApply: Sendable {
    let afterSuccessfulCalls: Int
}

private struct OutboxRecordMirror: Codable, Sendable {
    let envelope: DomainEventEnvelope
    let producerOperationID: RuntimeOperationID?
    let factSlot: ProgressionFactSlot?
    let state: RuntimeProgressionOutboxRecordState
    let attemptCount: UInt16
    let lastAttemptAt: Date?
    let nextAttemptAt: Date?
    let diagnosticCode: ProgressionRejectionCode?
}

private struct OutboxProgressionService: RuneScribeProgressionService {
    let probe: OutboxProgressionProbe

    func applyEvent(
        _ envelope: DomainEventEnvelope,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionEventApplyResult {
        await probe.apply(envelope)
    }

    func stateStream(
        metadata _: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionSnapshotDTO> {
        AsyncStream { continuation in
            continuation.yield(
                try! ProgressionSnapshotDTO(
                    revision: 0,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    availability: .available,
                    storeHealth: .loaded,
                    catalogID: nil,
                    catalogVersion: nil
                )
            )
            continuation.finish()
        }
    }

    func entitlementStream(
        metadata _: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionEntitlementSnapshotDTO> {
        AsyncStream { continuation in
            continuation.yield(
                try! ProgressionEntitlementSnapshotDTO(
                    revision: 0,
                    capturedAt: Date(timeIntervalSince1970: 1),
                    includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                    earnedUnlockIDs: []
                )
            )
            continuation.finish()
        }
    }

    func acknowledgeReveal(
        _: AcknowledgeProgressionRevealCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {}
    func selectTitle(
        _: SelectProgressionTitleCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {}

    func diagnosticsSummary(
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionDiagnosticsSummaryDTO {
        try ProgressionDiagnosticsSummaryDTO(
            capturedAt: Date(timeIntervalSince1970: 1),
            availability: .available,
            storeHealth: .loaded,
            catalogID: nil,
            catalogVersion: nil,
            pendingOutboxCount: 0
        )
    }

    func rebuild(
        _: ProgressionRecoveryRequest,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionRecoveryResult {
        try ProgressionRecoveryResult(
            rebuiltAt: Date(timeIntervalSince1970: 1),
            revision: 1
        )
    }
}

private struct OutboxTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    init(
        descriptor: ModuleDescriptor,
        startAction: @escaping @Sendable (ModuleContext) async throws -> Void
    ) {
        self.descriptor = descriptor
        self.startAction = startAction
    }

    func start(context: ModuleContext) async throws { try await startAction(context) }
    func stop() async {}
}

private actor OutboxRecoveryClientCapture {
    private var storedClient: RuntimeCommandClient?

    func setClient(_ client: RuntimeCommandClient) {
        storedClient = client
    }

    func client() -> RuntimeCommandClient? { storedClient }
}

private actor OutboxDiagnosticsClientCapture {
    private var storedClient: RuntimeProgressionClient?

    func setClient(_ client: RuntimeProgressionClient) {
        storedClient = client
    }

    func client() -> RuntimeProgressionClient? { storedClient }
}

private func outboxCoreDescriptor(
    version: SemanticVersion,
    publishesShareCompletion: Bool = false
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.core,
        moduleVersion: version,
        kind: .service,
        criticality: .required,
        entryPoint: "OutboxCore",
        role: RuneScribeRoles.core,
        requestedCapabilities: [
            RuneScribeCapabilities.moduleStateAccess,
            RuneScribeCapabilities.progressionEventSubmit,
        ],
        requiredServices: [RuneScribeServiceIDs.moduleStateStore],
        publishedEndpoints: publishesShareCompletion
            ? [
                RuntimeApplicationEndpointCatalog.completeShareArtifact
                    .descriptor.endpointID,
            ]
            : []
    )
}

private func outboxCoreDescriptorWithoutStateStore(
    version: SemanticVersion
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.core,
        moduleVersion: version,
        kind: .service,
        criticality: .required,
        entryPoint: "OutboxCoreWithoutStateStore",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.progressionEventSubmit]
    )
}

private func outboxUIDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.primaryUI,
        moduleVersion: version,
        kind: .ui,
        criticality: .required,
        entryPoint: "OutboxUI",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [RuneScribeCapabilities.rootUI],
        requiredModuleRoles: [RuneScribeRoles.core]
    )
}

private func outboxProgressionDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.progression,
        moduleVersion: version,
        kind: .service,
        criticality: .optional,
        entryPoint: "OutboxProgression",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [],
        publishedEndpoints: RuntimeProgressionEndpointCatalog.publishedEndpointIDs
    )
}

private func outboxHostDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: "com.runescribe.application.host.progression-recovery-test",
        moduleVersion: version,
        kind: .service,
        criticality: .required,
        entryPoint: "OutboxHost",
        role: RuneScribeRoles.applicationHost,
        requestedCapabilities: [RuneScribeCapabilities.progressionRecovery],
        requiredModuleRoles: [RuneScribeRoles.progression],
        consumedEndpoints: [
            RuntimeProgressionEndpointCatalog.rebuild.descriptor.endpointID,
        ]
    )
}

private func outboxDiagnosticsDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: "com.runescribe.runtime.progression-diagnostics-test",
        moduleVersion: version,
        kind: .service,
        criticality: .required,
        entryPoint: "OutboxDiagnosticsConsumer",
        role: RuneScribeRoles.applicationHost,
        requestedCapabilities: [RuneScribeCapabilities.progressionStateRead],
        requiredModuleRoles: [RuneScribeRoles.progression],
        consumedEndpoints: [
            RuntimeProgressionEndpointCatalog.progressionState.endpointID,
            RuntimeProgressionEndpointCatalog.entitlements.endpointID,
            RuntimeProgressionEndpointCatalog.diagnosticsSummary.descriptor.endpointID,
        ]
    )
}

private func outboxManifest(
    for descriptor: ModuleDescriptor,
    runtimeVersion: SemanticVersion
) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: runtimeVersion,
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )
}
