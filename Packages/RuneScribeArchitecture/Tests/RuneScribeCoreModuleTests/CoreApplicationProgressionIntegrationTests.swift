import CryptoKit
import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@testable import RuneScribeCoreModule
@testable import RuneScribeRuntimeCore
import XCTest

final class CoreApplicationProgressionIntegrationTests: XCTestCase {
    func testRuntimeAwareCompletionRejectsEvidenceFreeKeyDeliveryArtifact() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000201"
                )!)
            ),
            context: try Self.context(201)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "authority required", cipherID: cipherID),
            context: try Self.context(202)
        )
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: try XCTUnwrap(encoded.shareHandle)
            ),
            context: try Self.context(203)
        )
        XCTAssertTrue(artifact.requiresKeyDelivery)

        do {
            _ = try await service.completeShareArtifact(
                CompleteShareArtifactCommand(
                    artifactID: artifact.id,
                    outcome: .handedOff
                ),
                context: try Self.context(204)
            )
            XCTFail("Runtime-aware completion must require Runtime-minted evidence")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeProductError,
                .failure(RuneScribeFailureDTO(code: .invalidInput))
            )
        }

        let retainedArtifactCount = await harness.artifacts.count()
        XCTAssertEqual(retainedArtifactCount, 1)
        let library = try await CipherRepository(runtimeIO: harness.runtimeIO).snapshot()
        XCTAssertTrue(try XCTUnwrap(library.ciphers.first {
            $0.id == cipherID.rawValue
        }).keyDeliveryState.requiresDelivery)
    }

    func testFirstDeliveryAllowsOnlyOneLiveKeyBearingArtifactPerCipher() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000211"
                )!)
            ),
            context: try Self.context(211)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "one delivery", cipherID: cipherID),
            context: try Self.context(212)
        )
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Sender",
            cipherID: cipherID,
            shareHandle: try XCTUnwrap(encoded.shareHandle)
        )
        let first = try await service.prepareMessageShare(
            command,
            context: try Self.context(213)
        )
        XCTAssertTrue(first.requiresKeyDelivery)

        do {
            _ = try await service.prepareMessageShare(
                command,
                context: try Self.context(214)
            )
            XCTFail("A live first-delivery artifact must block a sibling")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeProductError,
                .failure(RuneScribeFailureDTO(code: .invalidInput))
            )
        }
        var activeArtifactCount = await harness.artifacts.count()
        XCTAssertEqual(activeArtifactCount, 1)

        await service.releaseShareArtifact(
            id: first.id,
            context: try Self.context(215)
        )
        let replacement = try await service.prepareMessageShare(
            command,
            context: try Self.context(216)
        )
        XCTAssertTrue(replacement.requiresKeyDelivery)
        XCTAssertNotEqual(replacement.id, first.id)
        activeArtifactCount = await harness.artifacts.count()
        XCTAssertEqual(activeArtifactCount, 1)
    }

    func testOperationAwareCreateAndEncodeCommitExactFactsAndDurableHandle() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()

        let created = try await service.createCipher(
            CreateCipherCommand(name: "Exact Facts"),
            context: try Self.context(1)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "raven", cipherID: created.id),
            context: try Self.context(2)
        )

        XCTAssertFalse(encoded.runes.isEmpty)
        XCTAssertNotNil(encoded.shareHandle)
        XCTAssertEqual(encoded.progressionInstrumentationStatus, .durable)
        let facts = await outbox.facts()
        XCTAssertEqual(facts.map(\.eventType.rawValue), [
            "runescribe.cipher.created",
            "runescribe.message.encoded",
        ])
        XCTAssertEqual(facts[0].payload.origin, .generated)
        XCTAssertEqual(facts[1].payload.origin, .generated)
        XCTAssertEqual(facts[0].payload.cipherToken, facts[1].payload.cipherToken)
        XCTAssertNotNil(facts[1].payload.messageToken)
        XCTAssertEqual(
            facts[1].payload.codexIDs,
            [CoreProgressionFactFactory.implicitNorseCodexID]
        )
        XCTAssertTrue(facts[1].payload.artifactIDs.isEmpty)
    }

    func testUnavailableOutboxRetainsEncodeEvidenceWithoutBlockingRunes() async throws {
        let harness = CoreProgressionHarness()
        let service = harness.service(outbox: nil)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)

        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "offline", cipherID: cipherID),
            context: try Self.context(3)
        )

        XCTAssertFalse(encoded.runes.isEmpty)
        XCTAssertNotNil(encoded.shareHandle)
        XCTAssertEqual(encoded.progressionInstrumentationStatus, .retainedForRetry)
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertEqual(ledger.encodedMessages.map(\.handle), [encoded.shareHandle!])
        XCTAssertEqual(
            ledger.pendingBatches.flatMap(\.batch.facts).map(\.fact.eventType.rawValue),
            ["runescribe.message.encoded"]
        )
    }

    func testEligibleTerminalsReuseMessageTokenWithoutRepeatingFirstDelivery() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let created = try await service.createCipher(
            CreateCipherCommand(name: "Linked"),
            context: try Self.context(4)
        )
        try await service.assignContact(
            AssignContactCommand(
                cipherID: created.id,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000001"
                )!)
            ),
            context: try Self.context(5)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "dispatch", cipherID: created.id),
            context: try Self.context(6)
        )
        let handle = try XCTUnwrap(encoded.shareHandle)

        let first = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: created.id,
                shareHandle: handle
            ),
            context: try Self.context(7)
        )
        let firstEvidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: first.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(8)
        )
        let firstCompletion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: firstEvidence),
            context: try Self.context(9)
        )
        XCTAssertEqual(firstCompletion, .deliveryRecorded)
        let duplicateCompletion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: firstEvidence),
            context: try Self.context(10)
        )
        XCTAssertEqual(duplicateCompletion, .deliveryRecorded)

        let second = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: created.id,
                shareHandle: handle
            ),
            context: try Self.context(11)
        )
        let secondEvidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: second.id,
            report: SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .completedBySystem
            ),
            operationContext: try Self.context(12)
        )
        _ = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: secondEvidence),
            context: try Self.context(13)
        )

        let disposable = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: created.id,
                shareHandle: handle
            ),
            context: try Self.context(14)
        )
        await service.releaseShareArtifact(id: disposable.id, context: try Self.context(15))
        _ = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: created.id,
                shareHandle: handle
            ),
            context: try Self.context(16)
        )

        let facts = await outbox.facts()
        let shares = facts.filter {
            $0.eventType.rawValue == "runescribe.share.completed"
        }
        XCTAssertEqual(shares.count, 2)
        XCTAssertEqual(Set(shares.compactMap(\.payload.messageToken)).count, 1)
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.cipher.first-delivery-completed"
        }.count, 1)
    }

    func testDeferredFirstDeliveryFactReconcilesAfterTokenRecovery() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let created = try await service.createCipher(
            CreateCipherCommand(name: "Deferred Delivery"),
            context: try Self.context(30)
        )
        try await service.assignContact(
            AssignContactCommand(
                cipherID: created.id,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000030"
                )!)
            ),
            context: try Self.context(31)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "defer event", cipherID: created.id),
            context: try Self.context(32)
        )
        let handle = try XCTUnwrap(encoded.shareHandle)
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: created.id,
                shareHandle: handle
            ),
            context: try Self.context(33)
        )
        await harness.tokens.setFailures([.relationshipToken])
        let completion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: try ShareArtifactCompletionEvidenceDTO(
                artifactID: artifact.id,
                report: SharePresentationReportDTO(
                    routeClass: .messages,
                    result: .sentConfirmed,
                    requiredAttachmentAccepted: true
                ),
                operationContext: try Self.context(34)
            )),
            context: try Self.context(35)
        )
        XCTAssertEqual(completion, .deliveryRecorded)
        let before = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        let relationshipBefore = try XCTUnwrap(before.relationships.first)
        XCTAssertEqual(relationshipBefore.keyDeliveryState, .completed)
        XCTAssertFalse(relationshipBefore.firstDeliveryEventCommitted)

        await harness.tokens.setFailures([])
        let relaunched = harness.service(outbox: outbox)
        await relaunched.startInboundProcessing()
        let after = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(try XCTUnwrap(after.relationships.first)
            .firstDeliveryEventCommitted)
        let facts = await outbox.facts()
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.cipher.first-delivery-completed"
        }.count, 1)
    }

    func testUnavailableOutboxRepeatedTerminalsKeepOnePhysicalArtifactBound() async throws {
        let harness = CoreProgressionHarness()
        let service = harness.service(outbox: nil)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000040"
                )!)
            ),
            context: try Self.context(39)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "bounded", cipherID: cipherID),
            context: try Self.context(40)
        )
        let handle = try XCTUnwrap(encoded.shareHandle)
        var artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: handle
            ),
            context: try Self.context(41)
        )
        var artifactCount = await harness.artifacts.count()
        XCTAssertEqual(artifactCount, 1)

        for offset in 0..<4 {
            let value = UInt64(42 + offset * 3)
            let completion = try await service.completeShareArtifact(
                CompleteShareArtifactCommand(evidence: try ShareArtifactCompletionEvidenceDTO(
                    artifactID: artifact.id,
                    report: SharePresentationReportDTO(
                        routeClass: .shareSheet,
                        result: .completedBySystem
                    ),
                    operationContext: try Self.context(value)
                )),
                context: try Self.context(value + 1)
            )
            XCTAssertEqual(completion, .retainedForRetry)
            artifactCount = await harness.artifacts.count()
            XCTAssertEqual(artifactCount, 0)
            artifact = try await service.prepareMessageShare(
                PrepareMessageShareCommand(
                    runes: encoded.runes,
                    senderName: "Sender",
                    cipherID: cipherID,
                    shareHandle: handle
                ),
                context: try Self.context(value + 2)
            )
            artifactCount = await harness.artifacts.count()
            XCTAssertLessThanOrEqual(artifactCount, 1)
        }
    }

    func testRetainedTerminalReleasesConsumedArtifactAndPreservesShareUtility() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsSubmissions: true)
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000050"
                )!)
            ),
            context: try Self.context(50)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "single lease", cipherID: cipherID),
            context: try Self.context(51)
        )
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Sender",
            cipherID: cipherID,
            shareHandle: try XCTUnwrap(encoded.shareHandle)
        )
        let artifact = try await service.prepareMessageShare(
            command,
            context: try Self.context(52)
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(53)
        )
        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 0)
        let retained = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(54)
        )
        XCTAssertEqual(retained, .retainedForRetry)
        var artifactCount = await harness.artifacts.count()
        XCTAssertEqual(artifactCount, 0)

        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 0)
        do {
            _ = try await service.prepareMessageShare(
                command,
                context: try Self.context(55)
            )
            XCTFail("A delivery-eligible retained terminal must block a sibling key artifact")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeProductError,
                .failure(RuneScribeFailureDTO(code: .invalidInput))
            )
        }
        artifactCount = await harness.artifacts.count()
        XCTAssertEqual(artifactCount, 0)

        let recovered = try await service.prepareMessageShare(
            command,
            context: try Self.context(57)
        )
        XCTAssertNotEqual(recovered.id, artifact.id)
        artifactCount = await harness.artifacts.count()
        XCTAssertLessThanOrEqual(artifactCount, 1)
        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let recoveredRecord = try await registry.durableRecord(
            artifactID: recovered.id
        )
        XCTAssertNotNil(recoveredRecord)
    }

    func testTerminalRetryFinishesLedgerCleanupAfterPhysicalRelease() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsSubmissions: true)
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "cleanup retry", cipherID: cipherID),
            context: try Self.context(60)
        )
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: try XCTUnwrap(encoded.shareHandle)
            ),
            context: try Self.context(61)
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .completedBySystem
            ),
            operationContext: try Self.context(62)
        )
        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 1)

        let first = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(63)
        )
        XCTAssertEqual(first, .retainedForRetry)
        let artifactCount = await harness.artifacts.count()
        XCTAssertEqual(artifactCount, 0)
        let retained = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(try XCTUnwrap(retained.shareTerminals.first).cleanupPending)

        let retry = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(64)
        )
        XCTAssertEqual(retry, .released)
        let completed = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertFalse(try XCTUnwrap(completed.shareTerminals.first).cleanupPending)
    }

    func testTerminalCannotCleanupOrTransitionBeforeDurableIntent() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000080"
                )!)
            ),
            context: try Self.context(80)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "durable first", cipherID: cipherID),
            context: try Self.context(81)
        )
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: try XCTUnwrap(encoded.shareHandle)
            ),
            context: try Self.context(82)
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(83)
        )
        await harness.protected.failWrite(afterSuccessfulWrites: 0)

        var didThrow = false
        do {
            _ = try await service.completeShareArtifact(
                CompleteShareArtifactCommand(evidence: evidence),
                context: try Self.context(84)
            )
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow)
        let physicalCount = await harness.artifacts.count()
        XCTAssertEqual(physicalCount, 1)
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(ledger.shareTerminals.isEmpty)
        let relationship = try XCTUnwrap(ledger.relationships.first)
        XCTAssertTrue(relationship.keyDeliveryState.requiresDelivery)
        XCTAssertFalse(relationship.firstDeliveryEventCommitted)
        let facts = await outbox.facts()
        XCTAssertTrue(facts.filter {
            $0.eventType.rawValue == "runescribe.share.completed"
                || $0.eventType.rawValue
                    == "runescribe.cipher.first-delivery-completed"
        }.isEmpty)
        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let loadedPrepared = try await registry.durableRecord(
            artifactID: artifact.id
        )
        let prepared = try XCTUnwrap(loadedPrepared)
        XCTAssertNil(prepared.terminalEvidence)
    }

    func testPendingTerminalCleanupFailureIsObservableAndRetried() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000085"
                )!)
            ),
            context: try Self.context(85)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "observable terminal retry",
                cipherID: cipherID
            ),
            context: try Self.context(86)
        )
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Sender",
            cipherID: cipherID,
            shareHandle: try XCTUnwrap(encoded.shareHandle)
        )
        let artifact = try await service.prepareMessageShare(
            command,
            context: try Self.context(87)
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(88)
        )

        // The terminal intent and planned disposition commit first. Core then
        // fails its transaction, and the best-effort physical-release journal
        // update fails once. The retained result must also publish typed state.
        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 0)
        await harness.protected.failWrite(afterSuccessfulWrites: 2)
        let retained = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(89)
        )
        XCTAssertEqual(retained, .retainedForRetry)
        var iterator = service.stateStream().makeAsyncIterator()
        let failedValue = await iterator.next()
        let failed = try XCTUnwrap(failedValue)
        XCTAssertEqual(failed.lastFailure?.code, .shareUnavailable)

        // A lifecycle retry that fails again must not discard its error or
        // clear the typed failure while the exact terminal remains pending.
        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 0)
        await service.stopInboundProcessing()
        var stoppedIterator = service.stateStream().makeAsyncIterator()
        let stoppedValue = await stoppedIterator.next()
        let stopped = try XCTUnwrap(stoppedValue)
        XCTAssertEqual(stopped.lastFailure?.code, .shareUnavailable)

        // The next activation retries the durable terminal before sharing is
        // enabled. The one-shot failures have cleared, so the original terminal
        // completes and only then may a replacement artifact be issued.
        await service.startInboundProcessing()
        let replacement = try await service.prepareMessageShare(
            command,
            context: try Self.context(90)
        )
        XCTAssertNotEqual(replacement.id, artifact.id)
        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let pendingIntents = try await registry.terminalIntents()
        XCTAssertTrue(pendingIntents.isEmpty)
        let facts = await outbox.facts()
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.share.completed"
        }.count, 1)
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.cipher.first-delivery-completed"
        }.count, 1)
    }

    func testRelaunchReplaysDurableTerminalAfterCoreCommitFailureExactlyOnce() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000090"
                )!)
            ),
            context: try Self.context(90)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "relaunch terminal", cipherID: cipherID),
            context: try Self.context(91)
        )
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: try XCTUnwrap(encoded.shareHandle)
            ),
            context: try Self.context(92)
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(93)
        )
        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 0)
        let retained = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(94)
        )
        XCTAssertEqual(retained, .retainedForRetry)
        let physicalAfterFailure = await harness.artifacts.count()
        XCTAssertEqual(physicalAfterFailure, 0)
        var ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        var relationship = try XCTUnwrap(ledger.relationships.first)
        XCTAssertTrue(relationship.keyDeliveryState.requiresDelivery)
        XCTAssertFalse(relationship.firstDeliveryEventCommitted)
        XCTAssertTrue(ledger.shareTerminals.isEmpty)

        let relaunched = harness.service(outbox: outbox)
        await relaunched.startInboundProcessing()
        ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        relationship = try XCTUnwrap(ledger.relationships.first)
        XCTAssertEqual(relationship.keyDeliveryState, .completed)
        XCTAssertTrue(relationship.firstDeliveryEventCommitted)
        XCTAssertEqual(ledger.shareTerminals.count, 1)
        XCTAssertFalse(try XCTUnwrap(ledger.shareTerminals.first).cleanupPending)

        let duplicate = try await relaunched.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(95)
        )
        XCTAssertEqual(duplicate, .deliveryRecorded)
        let facts = await outbox.facts()
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.share.completed"
        }.count, 1)
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.cipher.first-delivery-completed"
        }.count, 1)
    }

    func testPreparedLinkageAndHandleSurviveStartupUntilRuntimeRedelivery() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000100"
                )!)
            ),
            context: try Self.context(100)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "runtime redelivery", cipherID: cipherID),
            context: try Self.context(101)
        )
        let handle = try XCTUnwrap(encoded.shareHandle)
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: handle
            ),
            context: try Self.context(102)
        )
        let evidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(103)
        )

        // Runtime has durably journaled `evidence`, but Core has not received it.
        let relaunched = harness.service(outbox: outbox)
        await relaunched.startInboundProcessing()
        let physicalAfterStartup = await harness.artifacts.count()
        XCTAssertEqual(physicalAfterStartup, 0)
        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let retainedHandle = try await repository.encodedMessageProgressionEvidence(
            handle: handle
        )
        XCTAssertNotNil(retainedHandle)

        let result = try await relaunched.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: evidence),
            context: try Self.context(104)
        )
        XCTAssertEqual(result, .deliveryRecorded)
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertEqual(try XCTUnwrap(ledger.relationships.first).keyDeliveryState, .completed)
        let facts = await outbox.facts()
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.share.completed"
        }.count, 1)
    }

    func testRelaunchReplaysTerminalIntentsByOccurredAtBeforeArtifactID() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000110"
                )!)
            ),
            context: try Self.context(110)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "ordered replay", cipherID: cipherID),
            context: try Self.context(111)
        )
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Sender",
            cipherID: cipherID,
            shareHandle: try XCTUnwrap(encoded.shareHandle)
        )
        let lowerArtifactID = try await service.prepareMessageShare(
            command,
            context: try Self.context(112)
        )
        await service.releaseShareArtifact(
            id: lowerArtifactID.id,
            context: try Self.context(112_500)
        )
        let higherArtifactID = try await service.prepareMessageShare(
            command,
            context: try Self.context(113)
        )
        XCTAssertLessThan(
            lowerArtifactID.id.rawValue.uuidString,
            higherArtifactID.id.rawValue.uuidString
        )
        let later = try ShareArtifactCompletionEvidenceDTO(
            artifactID: lowerArtifactID.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(2_200)
        )
        let earlier = try ShareArtifactCompletionEvidenceDTO(
            artifactID: higherArtifactID.id,
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            operationContext: try Self.context(2_100)
        )
        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        _ = try await registry.journalTerminal(later)
        _ = try await registry.journalTerminal(earlier)

        let relaunched = harness.service(outbox: outbox)
        await relaunched.startInboundProcessing()
        let firstDeliveryContexts = await outbox.operationIDs(
            eventType: "runescribe.cipher.first-delivery-completed"
        )
        XCTAssertEqual(
            firstDeliveryContexts,
            [RuntimeOperationID(rawValue: "core-integration-2100")]
        )
        let durableRegistry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let earlierRecord = try await durableRegistry.durableRecord(
            artifactID: earlier.artifactID
        )
        let laterRecord = try await durableRegistry.durableRecord(
            artifactID: later.artifactID
        )
        XCTAssertEqual(earlierRecord?.completionDisposition, .deliveryRecorded)
        XCTAssertEqual(laterRecord?.completionDisposition, .released)
    }

    func testHandleRetryWindowPlusOneEvictsOldestUnreferencedHandleOnly() async throws {
        let harness = CoreProgressionHarness()
        let service = harness.service(outbox: nil)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        let first = try await service.encode(
            EncodeMessageCommand(plaintext: "active oldest", cipherID: cipherID),
            context: try Self.context(1_000)
        )
        let firstHandle = try XCTUnwrap(first.shareHandle)
        let active = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: first.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: firstHandle
            ),
            context: try Self.context(1_001)
        )
        var encoded = [first]
        for offset in 1...RuneScribeCoreApplicationService.encodedMessageRetryWindow {
            encoded.append(try await service.encode(
                EncodeMessageCommand(
                    plaintext: "message \(offset)",
                    cipherID: cipherID
                ),
                context: try Self.context(UInt64(1_001 + offset))
            ))
        }

        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let ledger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            ledger.encodedMessages.count,
            RuneScribeCoreApplicationService.encodedMessageRetryWindow
        )
        let retainedFirst = try await repository.encodedMessageProgressionEvidence(
            handle: firstHandle
        )
        XCTAssertNotNil(retainedFirst)
        let evicted = try XCTUnwrap(encoded[1].shareHandle)
        let retiredSecond = try await repository.encodedMessageProgressionEvidence(
            handle: evicted
        )
        XCTAssertNil(retiredSecond)
        let newest = try XCTUnwrap(encoded.last?.shareHandle)
        let retainedNewest = try await repository.encodedMessageProgressionEvidence(
            handle: newest
        )
        XCTAssertNotNil(retainedNewest)

        let staleUtility = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded[1].runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: evicted
            ),
            context: try Self.context(1_100)
        )
        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let loadedStaleRecord = try await registry.durableRecord(
            artifactID: staleUtility.id
        )
        let staleRecord = try XCTUnwrap(loadedStaleRecord)
        XCTAssertNil(staleRecord.encodedMessageHandle)
        await service.releaseShareArtifact(id: active.id)
        await service.releaseShareArtifact(id: staleUtility.id)
    }

    func testReleasedPreparedMetadataWindowPlusOneCompactsByPersistedChronology() async throws {
        let harness = CoreProgressionHarness()
        let service = harness.service(outbox: nil)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "prepared window", cipherID: cipherID),
            context: try Self.context(1_150)
        )
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Sender",
            cipherID: cipherID,
            shareHandle: try XCTUnwrap(encoded.shareHandle)
        )
        var artifactIDs: [ShareArtifactID] = []
        for offset in 0...ShareArtifactRegistry.releasedMetadataRetryWindow {
            let artifact = try await service.prepareMessageShare(
                command,
                context: try Self.context(UInt64(1_151 + offset))
            )
            artifactIDs.append(artifact.id)
            await service.releaseShareArtifact(id: artifact.id)
        }

        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let records = try await registry.durableRecords().filter {
            $0.terminalEvidence == nil && $0.physicalArtifactReleased
        }
        XCTAssertEqual(
            records.count,
            ShareArtifactRegistry.releasedMetadataRetryWindow
        )
        XCTAssertFalse(records.contains { $0.artifactID == artifactIDs[0] })
        XCTAssertEqual(records.last?.artifactID, artifactIDs.last)
        let physicalCount = await harness.artifacts.count()
        XCTAssertEqual(physicalCount, 0)

        let continued = try await service.prepareMessageShare(
            command,
            context: try Self.context(1_300)
        )
        let refreshedRegistry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let continuedRecord = try await refreshedRegistry.durableRecord(
            artifactID: continued.id
        )
        XCTAssertNotNil(continuedRecord)
        await service.releaseShareArtifact(id: continued.id)
    }

    func testOutstandingIDHandshakeRecoversPreparedJournalAtCapacityPlusOne() async throws {
        let harness = CoreProgressionHarness()
        let service = harness.service(outbox: nil)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service).rawValue
        let registry = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        var artifactIDs: [ShareArtifactID] = []
        for value in 1...256 {
            let artifactID = ShareArtifactID(rawValue: UUID(uuidString: String(
                format: "D1000000-0000-0000-0000-%012x",
                value
            ))!)
            artifactIDs.append(artifactID)
            _ = try await registry.createOpaqueMessage(
                id: artifactID,
                cipherID: cipherID
            )
        }
        let overflowID = ShareArtifactID(rawValue: UUID(uuidString:
            "D1000000-0000-0000-0000-000000000101"
        )!)
        var reachedCapacity = false
        do {
            _ = try await registry.createOpaqueMessage(
                id: overflowID,
                cipherID: cipherID
            )
        } catch ShareArtifactRegistryError.terminalJournalFull {
            reachedCapacity = true
        }
        XCTAssertTrue(reachedCapacity)

        // Runtime activation purged nil reservations and retained only the one
        // artifact that has durable terminal evidence awaiting Core delivery.
        let relaunched = ShareArtifactRegistry(runtimeIO: harness.runtimeIO)
        let outstanding = try XCTUnwrap(artifactIDs.last)
        let retired = try await relaunched.reconcilePreparedArtifacts(
            retaining: [outstanding]
        )
        XCTAssertEqual(retired.count, 255)
        let retained = try await relaunched.durableRecords()
        XCTAssertEqual(retained.map(\.artifactID), [outstanding])

        _ = try await relaunched.createOpaqueMessage(
            id: overflowID,
            cipherID: cipherID
        )
        let afterCapacityPlusOne = try await relaunched.durableRecords()
        XCTAssertEqual(
            afterCapacityPlusOne.map(\.artifactID),
            [outstanding, overflowID]
        )
    }

    func testTerminalRetryWindowPlusOneCompactsByChronologyAndKeepsDuplicateStable() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "terminal window", cipherID: cipherID),
            context: try Self.context(1_200)
        )
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Sender",
            cipherID: cipherID,
            shareHandle: try XCTUnwrap(encoded.shareHandle)
        )
        var evidence: [ShareArtifactCompletionEvidenceDTO] = []
        for offset in 0...ShareArtifactRegistry.completedTerminalRetryWindow {
            let artifact = try await service.prepareMessageShare(
                command,
                context: try Self.context(UInt64(1_201 + offset * 2))
            )
            let terminal = try ShareArtifactCompletionEvidenceDTO(
                artifactID: artifact.id,
                report: SharePresentationReportDTO(
                    routeClass: .shareSheet,
                    result: .completedBySystem
                ),
                operationContext: try Self.context(UInt64(1_202 + offset * 2))
            )
            evidence.append(terminal)
            let result = try await service.completeShareArtifact(
                CompleteShareArtifactCommand(evidence: terminal),
                context: try Self.context(UInt64(1_400 + offset))
            )
            XCTAssertEqual(result, .released)
        }

        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        var ledger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            ledger.shareTerminals.count,
            ShareArtifactRegistry.completedTerminalRetryWindow
        )
        XCTAssertFalse(ledger.shareTerminals.contains {
            $0.artifactID == evidence[0].artifactID
        })
        let last = try XCTUnwrap(evidence.last)
        XCTAssertTrue(ledger.shareTerminals.contains {
            $0.artifactID == last.artifactID
        })

        // Simulate a lost Core response: Runtime retries after relaunch.
        let relaunched = harness.service(outbox: outbox)
        await relaunched.startInboundProcessing()
        let duplicate = try await relaunched.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: last),
            context: try Self.context(1_500)
        )
        XCTAssertEqual(duplicate, .released)
        ledger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            ledger.shareTerminals.count,
            ShareArtifactRegistry.completedTerminalRetryWindow
        )
        let facts = await outbox.facts()
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.share.completed"
        }.count, ShareArtifactRegistry.completedTerminalRetryWindow + 1)
    }

    func testV2SeedAndTokenFailuresDegradeInstrumentationWithoutBlockingUtility() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let originalID = try await Self.firstCipherID(from: service)
        await harness.tokens.setFailures([.cipherSeed, .cipherToken])

        try await service.deleteCipher(id: originalID, context: try Self.context(70))
        let replacementID = try await Self.firstCipherID(from: service)
        let created = try await service.createCipher(
            CreateCipherCommand(name: "Fallback Seed"),
            context: try Self.context(71)
        )
        let importedPayload = CipherSharePayload(cipher: .generated(label: "Import"))
        let pending = try await service.importFile(
            Self.inboundFile(try importedPayload.encoded(), id: 72),
            context: try Self.context(72)
        )
        let importID = try XCTUnwrap(pending.pendingImport?.id)
        let imported = try await service.confirmImport(
            ConfirmImportCommand(importID: importID, name: "Imported Utility"),
            context: try Self.context(73)
        )
        await harness.tokens.setFailures([
            .cipherSeed, .cipherToken, .relationshipSeed,
        ])
        try await service.assignContact(
            AssignContactCommand(
                cipherID: created.id,
                contactID: ContactID(rawValue: UUID(
                    uuidString: "A0000000-0000-0000-0000-000000000070"
                )!)
            ),
            context: try Self.context(74)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "utility", cipherID: created.id),
            context: try Self.context(75)
        )

        XCTAssertNotEqual(replacementID, originalID)
        XCTAssertFalse(encoded.runes.isEmpty)
        XCTAssertNotNil(encoded.shareHandle)
        XCTAssertEqual(encoded.progressionInstrumentationStatus, .degraded)
        let library = try await CipherRepository(runtimeIO: harness.runtimeIO).snapshot()
        XCTAssertTrue(library.ciphers.contains { $0.id == created.id.rawValue })
        XCTAssertTrue(library.ciphers.contains { $0.id == imported.id.rawValue })
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertEqual(ledger.cipherSeeds.count, library.ciphers.count)
        XCTAssertEqual(ledger.relationships.count, 1)
    }

    func testRelaunchSweepRemovesHandlesButPreservesPendingFacts() async throws {
        let harness = CoreProgressionHarness()
        let first = harness.service(outbox: nil)
        await first.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: first)
        let encoded = try await first.encode(
            EncodeMessageCommand(plaintext: "pending", cipherID: cipherID),
            context: try Self.context(17)
        )
        XCTAssertNotNil(encoded.shareHandle)

        let before = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertEqual(before.encodedMessages.count, 1)
        XCTAssertEqual(before.pendingBatches.count, 1)

        let relaunched = harness.service(outbox: nil)
        await relaunched.startInboundProcessing()
        let after = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(after.encodedMessages.isEmpty)
        XCTAssertEqual(after.pendingBatches, before.pendingBatches)
    }

    func testMigrationDTOIsCanonicalAndContainsOnlyTokenAndOrigin() throws {
        let imported = CipherToken(rawValue: String(repeating: "b", count: 64))!
        let generated = CipherToken(rawValue: String(repeating: "a", count: 64))!
        let empty = try RuneScribeCoreApplicationService.existingUserMigrationDTO(
            from: CoreProgressionMigrationSnapshot(ciphers: [])
        )
        XCTAssertTrue(empty.ciphers.isEmpty)

        let mixed = try RuneScribeCoreApplicationService.existingUserMigrationDTO(
            from: CoreProgressionMigrationSnapshot(ciphers: [
                CoreProgressionMigrationCipher(
                    cipherToken: imported,
                    origin: .imported
                ),
                CoreProgressionMigrationCipher(
                    cipherToken: generated,
                    origin: .generated
                ),
            ])
        )
        XCTAssertEqual(mixed.ciphers.map(\.cipherToken), [generated, imported])
        XCTAssertEqual(mixed.ciphers.map(\.origin), [.generated, .imported])

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(mixed))
                as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "ciphers"])
        let rows = try XCTUnwrap(object["ciphers"] as? [[String: Any]])
        XCTAssertTrue(rows.allSatisfy { Set($0.keys) == ["cipherToken", "origin"] })
    }

    func testMigrationSubmissionFailureRetainsRederivableEvidenceAndUtility() async throws {
        let harness = CoreProgressionHarness()
        let unavailable = CoreIntegrationMigrationCapture(throwsOnSubmit: true)
        let first = harness.service(outbox: nil, migration: unavailable)
        await first.startInboundProcessing()
        _ = try await first.createCipher(CreateCipherCommand(name: "Still Useful"))
        let unavailableCount = await unavailable.submissionCount()
        XCTAssertEqual(unavailableCount, 1)

        let capture = CoreIntegrationMigrationCapture()
        let relaunched = harness.service(outbox: nil, migration: capture)
        await relaunched.startInboundProcessing()
        let capturedCiphers = await capture.lastCiphers()
        let ciphers = try XCTUnwrap(capturedCiphers)
        XCTAssertEqual(ciphers.count, 2)
        XCTAssertEqual(Set(ciphers.map(\.origin)), [.generated])
    }

    func testLegacyDeliveredMigrationSubmitsOnlyCipherOriginsWithoutEvents() async throws {
        let harness = CoreProgressionHarness()
        let contactID = UUID(
            uuidString: "A0000000-0000-0000-0000-000000000090"
        )!
        let records = [
            CoreIntegrationLegacyCipher(
                value: 1,
                label: "Delivered Legacy",
                origin: .generated,
                contactID: contactID,
                delivered: true
            ),
            CoreIntegrationLegacyCipher(
                value: 2,
                label: "Generated Legacy",
                origin: .generated
            ),
            CoreIntegrationLegacyCipher(
                value: 3,
                label: "Imported Legacy",
                origin: .imported
            ),
        ]
        let legacyLibrary = CoreIntegrationLegacyLibrary(
            ciphers: records,
            activeID: records[0].id
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(legacyLibrary)
        let keyData = Data(repeating: 0x5A, count: 32)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData)
        )
        let encrypted = try XCTUnwrap(sealed.combined)
        try await harness.secure.set(
            keyData,
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        try await harness.secure.set(
            encrypted,
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )

        let capture = CoreIntegrationMigrationCapture()
        let migrated = harness.service(outbox: nil, migration: capture)
        await migrated.startInboundProcessing()
        let capturedValue = await capture.lastCiphers()
        let captured = try XCTUnwrap(capturedValue)
        XCTAssertEqual(captured.count, 3)
        XCTAssertEqual(captured.filter { $0.origin == .generated }.count, 2)
        XCTAssertEqual(captured.filter { $0.origin == .imported }.count, 1)
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(ledger.pendingBatches.isEmpty)
        XCTAssertTrue(ledger.acknowledgedBatches.isEmpty)
        let relationship = try XCTUnwrap(ledger.relationships.first)
        XCTAssertEqual(relationship.keyDeliveryState, .migratedUnverified)
        XCTAssertFalse(relationship.firstDeliveryEventCommitted)
        XCTAssertFalse(relationship.bidirectionalEventCommitted)
    }

    func testMigrationSubmitsAllCiphersAcrossPagingBoundaryAndRelaunch() async throws {
        for cipherCount in [4_096, 4_097] {
            let harness = CoreProgressionHarness()
            let records = (1...cipherCount).map { value in
                CoreIntegrationLegacyCipher(
                    value: UInt64(value),
                    label: "Legacy \(value)",
                    origin: value.isMultiple(of: 3) ? .imported : .generated
                )
            }
            try await Self.installLegacyLibrary(records, in: harness)

            let capture = CoreIntegrationMigrationCapture()
            let first = harness.service(outbox: nil, migration: capture)
            await first.startInboundProcessing()
            let migratedLibrary = try await CipherRepository(
                runtimeIO: harness.runtimeIO
            ).snapshot()
            XCTAssertEqual(migratedLibrary.version, CipherLibrary.currentVersion)
            let snapshot = try await CoreProgressionCoordinator(
                repository: CipherRepository(runtimeIO: harness.runtimeIO),
                tokens: harness.tokens,
                outbox: nil
            ).existingUserMigrationSnapshot()
            XCTAssertEqual(snapshot.ciphers.count, cipherCount)
            let relaunched = harness.service(outbox: nil, migration: capture)
            await relaunched.startInboundProcessing()

            let submissions = await capture.allSubmissions()
            XCTAssertEqual(submissions.count, 2)
            let firstSubmission = try XCTUnwrap(submissions.first)
            let lastSubmission = try XCTUnwrap(submissions.last)
            XCTAssertEqual(firstSubmission.count, cipherCount)
            XCTAssertEqual(lastSubmission, firstSubmission)
            XCTAssertEqual(
                firstSubmission.filter { $0.origin == .imported }.count,
                cipherCount / 3
            )
            XCTAssertEqual(
                Set(firstSubmission.map(\.cipherToken)).count,
                cipherCount
            )

            let row = try XCTUnwrap(firstSubmission.first)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(row))
                    as? [String: Any]
            )
            XCTAssertEqual(Set(object.keys), ["cipherToken", "origin"])

            let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
                .progressionEvidenceSnapshot()
            XCTAssertEqual(ledger.cipherSeeds.count, cipherCount)
            XCTAssertTrue(ledger.pendingBatches.isEmpty)
            XCTAssertTrue(ledger.acknowledgedBatches.isEmpty)
            XCTAssertTrue(ledger.relationships.isEmpty)
            XCTAssertTrue(ledger.shareTerminals.isEmpty)
        }
    }

    func testCorruptAuthenticatedEnvelopeCommitsAdmissionOnly() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "Corrupt Sender")
        var envelope = MessageEnvelope.wrap(
            try MessageCryptor().seal("must authenticate", with: senderCipher)
        )
        envelope[envelope.index(before: envelope.endIndex)] ^= 0x01
        let data = try MessageSharePayload(
            senderName: "Corrupt Sender",
            envelope: envelope,
            embeddedCipher: CipherSharePayload(cipher: senderCipher)
        ).encodedFile(fontBytes: nil)

        do {
            _ = try await service.importFile(
                Self.inboundFile(data, id: 101),
                context: try Self.context(101)
            )
            XCTFail("Corrupt AEAD must not authenticate")
        } catch {}

        let library = try await CipherRepository(runtimeIO: harness.runtimeIO).snapshot()
        XCTAssertFalse(library.ciphers.contains { $0.publicID == senderCipher.publicID })
        let facts = await outbox.facts()
        XCTAssertEqual(
            facts.map(\.eventType.rawValue),
            ["runescribe.message.imported"]
        )
    }

    func testEmbeddedCipherRequiresConfirmationBeforeCanonicalImportFact() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "Authenticated Sender")
        let data = try Self.messageFile(
            plaintext: "authenticated",
            senderName: "Authenticated Sender",
            cipher: senderCipher,
            embedsCipher: true
        )

        let result = try await service.importFile(
            Self.inboundFile(data, id: 102),
            context: try Self.context(102)
        )

        XCTAssertEqual(result.disposition, .receivedMessage)
        let pending = try XCTUnwrap(result.pendingImport)
        let preconfirmation = try await CipherRepository(
            runtimeIO: harness.runtimeIO
        ).snapshot()
        XCTAssertFalse(
            preconfirmation.ciphers.contains { $0.publicID == senderCipher.publicID }
        )
        let initialFacts = await outbox.facts()
        XCTAssertEqual(initialFacts.map(\.eventType.rawValue), [
            "runescribe.message.imported",
            "runescribe.message.decoded",
            "runescribe.presentation.observed",
        ])

        _ = try await service.confirmImport(
            ConfirmImportCommand(
                importID: pending.id,
                name: "Reviewed Sender"
            ),
            context: try Self.context(102_100)
        )

        let library = try await CipherRepository(runtimeIO: harness.runtimeIO).snapshot()
        XCTAssertTrue(library.ciphers.contains { $0.publicID == senderCipher.publicID })
        let facts = await outbox.facts()
        XCTAssertEqual(facts.map(\.eventType.rawValue), [
            "runescribe.message.imported",
            "runescribe.message.decoded",
            "runescribe.presentation.observed",
            "runescribe.cipher.imported",
        ])
        XCTAssertEqual(Set(facts.compactMap(\.payload.packageToken)).count, 1)
        XCTAssertEqual(facts.last?.payload.origin, .imported)
        XCTAssertEqual(facts.last?.payload.routeClass, .file)
        XCTAssertEqual(
            facts[2].payload.codexIDs,
            [CoreProgressionFactFactory.implicitNorseCodexID]
        )
    }

    func testThemedInboundCommitsSelectedEncounterFactsToExistingOutbox() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "Themed Sender")
        let payload = MessageSharePayload(
            senderName: "Themed Sender",
            envelope: MessageEnvelope.wrap(
                try MessageCryptor().seal("themed authenticated", with: senderCipher)
            ),
            embeddedCipher: CipherSharePayload(cipher: senderCipher)
        )
        let selection = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.moonleaf")!,
            scriptID: ScriptID(rawValue: "script.moonleaf")!,
            relicID: ArtifactID(rawValue: "relic.moonleaf.tablet")!,
            sealID: ArtifactID(rawValue: "seal.moonleaf.firefly")!,
            frameID: ArtifactID(rawValue: "frame.moonleaf.silvervine")!
        )
        let metadata = try SharePresentationMetadata(
            selection: selection,
            compatibility: .norseInteractiveFallback
        )
        let package = try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: payload.encoded(),
            presentation: SharePresentationSectionBundle(
                metadata: metadata,
                safePreviewData: nil,
                signedProvenance: nil
            )
        ).encoded()

        let result = try await service.importFile(
            Self.inboundFile(package, id: 102_001),
            context: try Self.context(102_001)
        )

        XCTAssertEqual(result.disposition, .receivedMessage)
        let facts = await outbox.facts()
        let presentationFacts = facts.filter {
            [
                "runescribe.message.imported",
                "runescribe.message.decoded",
                "runescribe.presentation.observed",
            ].contains($0.eventType.rawValue)
        }
        XCTAssertEqual(presentationFacts.count, 3)
        for fact in presentationFacts {
            XCTAssertEqual(fact.payload.codexIDs, [selection.codexID])
            XCTAssertEqual(fact.payload.artifactIDs, selection.artifactIDs)
            XCTAssertEqual(fact.payload.provenanceStatus, .absent)
        }
        XCTAssertEqual(
            Set(presentationFacts.compactMap(\.payload.packageToken)).count,
            1
        )
        var stateIterator = service.stateStream().makeAsyncIterator()
        let nextState = await stateIterator.next()
        let state = try XCTUnwrap(nextState)
        XCTAssertEqual(
            state.messageState.pendingMessage?.presentation?.encounterRecordingStatus,
            .recorded
        )
    }

    func testThemedInboundKeepsPlaintextWhenEncounterRecordingIsUnavailable() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsBackgroundContexts: true)
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "Unavailable Encounter Sender")
        let payload = MessageSharePayload(
            senderName: "Unavailable Encounter Sender",
            envelope: MessageEnvelope.wrap(
                try MessageCryptor().seal("still readable", with: senderCipher)
            ),
            embeddedCipher: CipherSharePayload(cipher: senderCipher)
        )
        let selection = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.sunspire")!,
            scriptID: ScriptID(rawValue: "script.sunspire")!,
            relicID: ArtifactID(rawValue: "relic.sunspire.tablet")!,
            sealID: ArtifactID(rawValue: "seal.sunspire.flame")!
        )
        let metadata = try SharePresentationMetadata(
            selection: selection,
            compatibility: .norseInteractiveFallback
        )
        let package = try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: payload.encoded(),
            presentation: SharePresentationSectionBundle(
                metadata: metadata,
                safePreviewData: nil,
                signedProvenance: nil
            )
        ).encoded()

        let result = try await service.importFile(
            Self.inboundFile(package, id: 102_010),
            context: try Self.context(102_010)
        )

        XCTAssertEqual(result.disposition, .receivedMessage)
        var stateIterator = service.stateStream().makeAsyncIterator()
        let nextState = await stateIterator.next()
        let state = try XCTUnwrap(nextState)
        let message = try XCTUnwrap(state.messageState.pendingMessage)
        XCTAssertEqual(message.plaintext, "still readable")
        XCTAssertEqual(
            message.presentation?.encounterRecordingStatus,
            .unavailable
        )
        let facts = await outbox.facts()
        XCTAssertEqual(facts.map(\.eventType.rawValue), ["runescribe.message.imported"])
    }

    func testThemedShareTerminalUsesSelectionFrozenInDurableJournal() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(
            CreateCipherCommand(name: "Themed Outbound"),
            context: try Self.context(102_100)
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "frozen selection",
                cipherID: cipher.id
            ),
            context: try Self.context(102_101)
        )
        let selection = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.sunspire")!,
            scriptID: ScriptID(rawValue: "script.sunspire")!,
            relicID: ArtifactID(rawValue: "relic.sunspire.tablet")!,
            sealID: ArtifactID(rawValue: "seal.sunspire.flame")!
        )
        let metadata = try SharePresentationMetadata(
            selection: selection,
            compatibility: .norseInteractiveFallback
        )
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipher.id,
                shareHandle: try XCTUnwrap(encoded.shareHandle),
                presentation: OutboundSharePresentationDTO(metadata: metadata)
            ),
            context: try Self.context(102_102)
        )
        let completion = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifact.id,
            report: SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .completedBySystem
            ),
            operationContext: try Self.context(102_103)
        )

        _ = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: completion),
            context: try Self.context(102_104)
        )

        let outboxFacts = await outbox.facts()
        let share = try XCTUnwrap(outboxFacts.first {
            $0.eventType.rawValue == "runescribe.share.completed"
        })
        XCTAssertEqual(share.payload.codexIDs, [selection.codexID])
        XCTAssertEqual(share.payload.artifactIDs, selection.artifactIDs)
    }

    func testOptionalInboundTokenAndContextFailuresPreserveAuthenticatedUtility() async throws {
        let tokenHarness = CoreProgressionHarness()
        let tokenOutbox = CoreIntegrationOutbox()
        let tokenService = tokenHarness.service(outbox: tokenOutbox)
        await tokenService.startInboundProcessing()
        await tokenHarness.tokens.setFailures([.packageToken])
        let tokenCipher = Cipher.generated(label: "Token Unavailable")
        let tokenResult = try await tokenService.importFile(
            Self.inboundFile(try Self.messageFile(
                plaintext: "token fallback",
                senderName: "Token Unavailable",
                cipher: tokenCipher,
                embedsCipher: true
            ), id: 105),
            context: try Self.context(105)
        )
        XCTAssertEqual(tokenResult.disposition, .receivedMessage)
        XCTAssertNotNil(tokenResult.pendingImport)
        let tokenLibrary = try await CipherRepository(
            runtimeIO: tokenHarness.runtimeIO
        ).snapshot()
        XCTAssertFalse(tokenLibrary.ciphers.contains {
            $0.publicID == tokenCipher.publicID
        })
        let tokenFacts = await tokenOutbox.facts()
        XCTAssertTrue(tokenFacts.isEmpty)

        let contextHarness = CoreProgressionHarness()
        let contextOutbox = CoreIntegrationOutbox(failsBackgroundContexts: true)
        let contextService = contextHarness.service(outbox: contextOutbox)
        await contextService.startInboundProcessing()
        let contextCipher = Cipher.generated(label: "Context Unavailable")
        let contextResult = try await contextService.importFile(
            Self.inboundFile(try Self.messageFile(
                plaintext: "context fallback",
                senderName: "Context Unavailable",
                cipher: contextCipher,
                embedsCipher: true
            ), id: 106),
            context: try Self.context(106)
        )
        XCTAssertEqual(contextResult.disposition, .receivedMessage)
        XCTAssertNotNil(contextResult.pendingImport)
        let contextLibrary = try await CipherRepository(
            runtimeIO: contextHarness.runtimeIO
        ).snapshot()
        XCTAssertFalse(contextLibrary.ciphers.contains {
            $0.publicID == contextCipher.publicID
        })
        let contextFacts = await contextOutbox.facts()
        XCTAssertEqual(
            contextFacts.map(\.eventType.rawValue),
            ["runescribe.message.imported"]
        )
    }

    func testCipherSeedCapacityPlusOnePreservesDomainFactsAndMigrationPrivacy() async throws {
        let harness = CoreProgressionHarness()
        try await Self.installCurrentLibrary(
            try Self.cipherSeedCapacityLibrary(),
            in: harness
        )
        let unavailableOutbox = CoreIntegrationOutbox(failsSubmissions: true)
        let contactManager = ContactManager(
            repository: EncryptedContactRepository(runtimeIO: harness.runtimeIO),
            runtimeIO: harness.runtimeIO
        )
        let service = harness.service(
            outbox: unavailableOutbox,
            contactManager: contactManager
        )
        await service.startInboundProcessing()

        let created = try await service.createCipher(
            CreateCipherCommand(name: "Sparse Created"),
            context: try Self.context(50_000)
        )
        let importedPayload = CipherSharePayload(
            cipher: .generated(label: "Sparse Imported")
        )
        let pending = try await service.importFile(
            Self.inboundFile(try importedPayload.encoded(), id: 50_001),
            context: try Self.context(50_001)
        )
        let importID = try XCTUnwrap(pending.pendingImport?.id)
        let imported = try await service.confirmImport(
            ConfirmImportCommand(importID: importID, name: "Sparse Imported"),
            context: try Self.context(50_002)
        )
        let senderCipher = Cipher.generated(label: "Sparse Sender")
        let received = try await service.importFile(
            Self.inboundFile(try Self.messageFile(
                plaintext: "sparse authenticated",
                senderName: "Sparse Sender",
                cipher: senderCipher,
                embedsCipher: true
            ), id: 50_003),
            context: try Self.context(50_003)
        )
        XCTAssertEqual(received.disposition, .receivedMessage)
        let senderImportID = try XCTUnwrap(received.pendingImport?.id)
        _ = try await service.confirmImport(
            ConfirmImportCommand(
                importID: senderImportID,
                name: "Sparse Sender"
            ),
            context: try Self.context(50_003_001)
        )
        let importedContacts = try await service.importContacts(
            ImportContactsCommand(contacts: [SystemContactDTO(
                systemIdentifier: "seed-capacity-contact",
                displayName: "Sparse Reconciled Contact"
            )]),
            context: try Self.context(50_004)
        )
        XCTAssertEqual(importedContacts.count, 1)
        XCTAssertEqual(importedContacts.first?.linkedCipherCount, 1)
        let reconciledContactID = try XCTUnwrap(importedContacts.first?.id)

        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "sparse utility",
                cipherID: created.id
            ),
            context: try Self.context(50_005)
        )
        XCTAssertFalse(encoded.runes.isEmpty)
        XCTAssertNotNil(encoded.shareHandle)
        XCTAssertEqual(encoded.progressionInstrumentationStatus, .degraded)

        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let beforeLibrary = try await repository.snapshot()
        XCTAssertEqual(
            beforeLibrary.ciphers.count,
            CoreProgressionLedger.maximumCipherSeedCount + 4
        )
        let beforeLedger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            beforeLedger.cipherSeeds.count,
            CoreProgressionLedger.maximumCipherSeedCount
        )
        let seededIDs = Set(beforeLedger.cipherSeeds.map(\.cipherID))
        XCTAssertFalse(seededIDs.contains(created.id.rawValue))
        XCTAssertFalse(seededIDs.contains(imported.id.rawValue))
        let sender = try XCTUnwrap(beforeLibrary.ciphers.first {
            $0.publicID == senderCipher.publicID
        })
        XCTAssertFalse(seededIDs.contains(sender.id))
        let reconciled = try XCTUnwrap(beforeLibrary.ciphers.first {
            $0.contactID == reconciledContactID.rawValue
        })
        XCTAssertFalse(seededIDs.contains(reconciled.id))
        let retainedTypes = beforeLedger.pendingBatches.flatMap(\.batch.facts)
            .map(\.fact.eventType.rawValue)
        XCTAssertEqual(
            Dictionary(grouping: retainedTypes, by: { $0 }).mapValues(\.count),
            [
                "runescribe.cipher.created": 2,
                "runescribe.cipher.imported": 2,
                "runescribe.message.imported": 1,
                "runescribe.message.decoded": 1,
                "runescribe.presentation.observed": 1,
            ]
        )

        let capture = CoreIntegrationMigrationCapture()
        let recoveredOutbox = CoreIntegrationOutbox()
        let relaunched = harness.service(
            outbox: recoveredOutbox,
            migration: capture
        )
        await relaunched.startInboundProcessing()
        let capturedMigration = await capture.lastCiphers()
        let migrated = try XCTUnwrap(capturedMigration)
        XCTAssertEqual(
            migrated.count,
            CoreProgressionLedger.maximumCipherSeedCount
        )
        XCTAssertEqual(Set(migrated.map(\.cipherToken)).count, migrated.count)
        let delivered = await recoveredOutbox.facts()
        XCTAssertEqual(
            Dictionary(
                grouping: delivered.map(\.eventType.rawValue),
                by: { $0 }
            ).mapValues(\.count),
            [
                "runescribe.cipher.created": 2,
                "runescribe.cipher.imported": 2,
                "runescribe.message.imported": 1,
                "runescribe.message.decoded": 1,
                "runescribe.presentation.observed": 1,
            ]
        )
        let drained = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(drained.pendingBatches.isEmpty)
        XCTAssertTrue(drained.acknowledgedBatches.isEmpty)
    }

    func testRelationshipCapacityPlusOnePreservesBindingAndKeyDelivery() async throws {
        let harness = CoreProgressionHarness()
        try await Self.installCurrentLibrary(
            try Self.relationshipCapacityLibrary(),
            in: harness
        )
        let unavailableOutbox = CoreIntegrationOutbox(failsSubmissions: true)
        let service = harness.service(outbox: unavailableOutbox)
        await service.startInboundProcessing()
        let cipherID = try await Self.firstCipherID(from: service)
        let newContactID = ContactID(rawValue: Self.capacityUUID(
            prefix: "D3000000",
            value: UInt64(CoreProgressionLedger.maximumRelationshipCount + 1)
        ))
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipherID,
                contactID: newContactID
            ),
            context: try Self.context(60_000)
        )

        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "relationship capacity",
                cipherID: cipherID
            ),
            context: try Self.context(60_001)
        )
        let handle = try XCTUnwrap(encoded.shareHandle)
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipherID,
                shareHandle: handle
            ),
            context: try Self.context(60_002)
        )
        let completionEvidence = try ShareArtifactCompletionEvidenceDTO(
                artifactID: artifact.id,
                report: SharePresentationReportDTO(
                    routeClass: .messages,
                    result: .sentConfirmed,
                    requiredAttachmentAccepted: true
                ),
                operationContext: try Self.context(60_003)
            )
        let completion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: completionEvidence),
            context: try Self.context(60_004)
        )
        XCTAssertEqual(completion, .retainedForRetry)

        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let beforeLibrary = try await repository.snapshot()
        let bound = try XCTUnwrap(beforeLibrary.ciphers.first {
            $0.id == cipherID.rawValue
        })
        XCTAssertEqual(bound.contactID, newContactID.rawValue)
        XCTAssertEqual(bound.keyDeliveryState, .completed)
        let beforeLedger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            beforeLedger.relationships.count,
            CoreProgressionLedger.maximumRelationshipCount
        )
        let sparseRelationship = try await repository.relationshipProgressionEvidence(
            cipherID: cipherID.rawValue,
            contactID: newContactID.rawValue
        )
        XCTAssertNil(sparseRelationship)
        let existingRelationships = beforeLedger.relationships

        let capture = CoreIntegrationMigrationCapture()
        let recoveredOutbox = CoreIntegrationOutbox()
        let relaunched = harness.service(
            outbox: recoveredOutbox,
            migration: capture
        )
        await relaunched.startInboundProcessing()
        let redelivered = try await relaunched.completeShareArtifact(
            CompleteShareArtifactCommand(evidence: completionEvidence),
            context: try Self.context(60_005)
        )
        XCTAssertEqual(redelivered, .deliveryRecorded)
        let afterLedger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertEqual(afterLedger.relationships, existingRelationships)
        let capturedMigration = await capture.lastCiphers()
        let migrated = try XCTUnwrap(capturedMigration)
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated.first?.origin, .generated)
        let delivered = await recoveredOutbox.facts()
        XCTAssertEqual(
            Dictionary(
                grouping: delivered.map(\.eventType.rawValue),
                by: { $0 }
            ).mapValues(\.count),
            [
                "runescribe.message.encoded": 1,
                "runescribe.share.completed": 1,
            ]
        )
        XCTAssertNil(delivered.last?.payload.relationshipToken)
        XCTAssertFalse(delivered.contains {
            $0.eventType.rawValue
                == "runescribe.cipher.first-delivery-completed"
        })
    }

    func testPendingLedgerBeyondFormerLimitRetainsAndReplaysCipherFacts() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsSubmissions: true)
        let priming = harness.service(outbox: outbox)
        await priming.startInboundProcessing()
        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let retained = try await Self.fillPendingProgressionLedger(
            repository,
            count: 1_024,
            contextOffset: 20_000
        )

        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let originalID = try await Self.firstCipherID(from: service)
        let created = try await service.createCipher(
            CreateCipherCommand(name: "Capacity Create"),
            context: try Self.context(22_000)
        )

        let importPayload = CipherSharePayload(
            cipher: .generated(label: "Capacity Import")
        )
        let pending = try await service.importFile(
            Self.inboundFile(try importPayload.encoded(), id: 22_001),
            context: try Self.context(22_001)
        )
        let importID = try XCTUnwrap(pending.pendingImport?.id)
        let imported = try await service.confirmImport(
            ConfirmImportCommand(importID: importID, name: "Capacity Import"),
            context: try Self.context(22_002)
        )

        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "capacity utility",
                cipherID: created.id
            ),
            context: try Self.context(22_003)
        )
        XCTAssertFalse(encoded.runes.isEmpty)
        XCTAssertNotNil(encoded.shareHandle)
        XCTAssertEqual(
            encoded.progressionInstrumentationStatus,
            .retainedForRetry
        )

        var library = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .snapshot()
        XCTAssertTrue(library.ciphers.contains { $0.id == created.id.rawValue })
        XCTAssertTrue(library.ciphers.contains { $0.id == imported.id.rawValue })

        // Removing the two added ciphers leaves the original as the last
        // cipher. Deleting it exercises the replacement-cipher mutation beyond
        // the former lifetime limit as well.
        try await service.deleteCipher(
            id: created.id,
            context: try Self.context(22_004)
        )
        try await service.deleteCipher(
            id: imported.id,
            context: try Self.context(22_005)
        )
        try await service.deleteCipher(
            id: originalID,
            context: try Self.context(22_006)
        )

        library = try await CipherRepository(runtimeIO: harness.runtimeIO).snapshot()
        XCTAssertEqual(library.ciphers.count, 1)
        XCTAssertNotEqual(library.ciphers[0].id, originalID.rawValue)
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        let retainedIDs = Set(retained.map(\.identity))
        XCTAssertEqual(ledger.pendingBatches.count, 1_028)
        XCTAssertTrue(retainedIDs.isSubset(
            of: Set(ledger.pendingBatches.map(\.identity))
        ))
        let overflow = ledger.pendingBatches.filter {
            !retainedIDs.contains($0.identity)
        }
        let overflowEventTypes = overflow.flatMap(\.batch.facts)
            .map(\.fact.eventType.rawValue)
        XCTAssertEqual(
            Dictionary(grouping: overflowEventTypes, by: { $0 }).mapValues(\.count),
            [
                "runescribe.cipher.created": 2,
                "runescribe.cipher.imported": 1,
                "runescribe.message.encoded": 1,
            ]
        )
        XCTAssertEqual(ledger.cipherSeeds.count, 1)
        XCTAssertTrue(ledger.encodedMessages.isEmpty)

        // Model the older 1,024 operations having drained successfully, then
        // prove a relaunched healthy outbox receives the exact overflow facts.
        var replayLibrary = library
        var replayLedger = ledger
        replayLedger.pendingBatches = overflow
        let overflowDigests = Set(overflow.map { $0.identity.contextDigest })
        replayLedger.progressionOperationOrder.removeAll {
            !overflowDigests.contains($0)
        }
        replayLibrary.progressionLedger = replayLedger
        try await Self.installCurrentLibrary(replayLibrary, in: harness)
        let recoveredOutbox = CoreIntegrationOutbox()
        let relaunched = harness.service(outbox: recoveredOutbox)
        await relaunched.startInboundProcessing()
        let deliveredFacts = await recoveredOutbox.facts()
        let delivered = deliveredFacts.map(\.eventType.rawValue)
        XCTAssertEqual(
            Dictionary(grouping: delivered, by: { $0 }).mapValues(\.count),
            [
                "runescribe.cipher.created": 2,
                "runescribe.cipher.imported": 1,
                "runescribe.message.encoded": 1,
            ]
        )
        let drained = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(drained.pendingBatches.isEmpty)
        XCTAssertTrue(drained.acknowledgedBatches.isEmpty)
    }

    func testAuthenticatedImportBeyondFormerLimitReplaysCanonicalFacts() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsSubmissions: true)
        let priming = harness.service(outbox: outbox)
        await priming.startInboundProcessing()
        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let retained = try await Self.fillPendingProgressionLedger(
            repository,
            count: 1_024,
            contextOffset: 30_000
        )

        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "Capacity Sender")
        let data = try Self.messageFile(
            plaintext: "authenticated at capacity",
            senderName: "Capacity Sender",
            cipher: senderCipher,
            embedsCipher: true
        )
        let result = try await service.importFile(
            Self.inboundFile(data, id: 32_000),
            context: try Self.context(32_000)
        )

        XCTAssertEqual(result.disposition, .receivedMessage)
        let confirmation = try XCTUnwrap(result.pendingImport)
        _ = try await service.confirmImport(
            ConfirmImportCommand(
                importID: confirmation.id,
                name: "Confirmed Capacity Sender"
            ),
            context: try Self.context(32_001)
        )
        let library = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .snapshot()
        XCTAssertTrue(library.ciphers.contains {
            $0.publicID == senderCipher.publicID
        })
        let ledger = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertEqual(ledger.pendingBatches.count, 1_027)
        let retainedIDs = Set(retained.map(\.identity))
        XCTAssertTrue(retainedIDs.isSubset(
            of: Set(ledger.pendingBatches.map(\.identity))
        ))
        let overflow = ledger.pendingBatches
            .filter { !retainedIDs.contains($0.identity) }
        let newFacts = overflow
            .flatMap(\.batch.facts)
            .map(\.fact.eventType.rawValue)
        let expectedFacts = [
            "runescribe.message.imported",
            "runescribe.message.decoded",
            "runescribe.presentation.observed",
            "runescribe.cipher.imported",
        ]
        XCTAssertEqual(Set(newFacts), Set(expectedFacts))
        let submittedFacts = await outbox.facts()
        XCTAssertTrue(submittedFacts.isEmpty)

        var replayLibrary = library
        var replayLedger = ledger
        replayLedger.pendingBatches = overflow
        let overflowDigests = Set(overflow.map { $0.identity.contextDigest })
        replayLedger.progressionOperationOrder.removeAll {
            !overflowDigests.contains($0)
        }
        replayLibrary.progressionLedger = replayLedger
        try await Self.installCurrentLibrary(replayLibrary, in: harness)
        let recoveredOutbox = CoreIntegrationOutbox()
        let relaunched = harness.service(outbox: recoveredOutbox)
        await relaunched.startInboundProcessing()
        let delivered = await recoveredOutbox.facts()
        XCTAssertEqual(delivered.map(\.eventType.rawValue), expectedFacts)
        let drained = try await CipherRepository(runtimeIO: harness.runtimeIO)
            .progressionEvidenceSnapshot()
        XCTAssertTrue(drained.pendingBatches.isEmpty)
        XCTAssertTrue(drained.acknowledgedBatches.isEmpty)
    }

    func testConfirmedImportFailureRetainsDecodedMessageWithoutPersistingCipher() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsSubmissions: true)
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "Before Commit")
        let data = try Self.messageFile(
            plaintext: "before commit",
            senderName: "Before Commit",
            cipher: senderCipher,
            embedsCipher: true
        )
        let result = try await service.importFile(
            Self.inboundFile(data, id: 107),
            context: try Self.context(107)
        )
        let confirmation = try XCTUnwrap(result.pendingImport)
        await harness.secure.failCipherLibraryWrite(afterSuccessfulWrites: 0)
        do {
            _ = try await service.confirmImport(
                ConfirmImportCommand(
                    importID: confirmation.id,
                    name: "Before Confirm"
                ),
                context: try Self.context(107_001)
            )
            XCTFail("The failed confirmation write must report failure")
        } catch {}

        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let library = try await repository.snapshot()
        XCTAssertFalse(library.ciphers.contains { $0.publicID == senderCipher.publicID })
        let ledger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            ledger.pendingBatches.flatMap(\.batch.facts)
                .map(\.fact.eventType.rawValue),
            [
                "runescribe.message.imported",
                "runescribe.message.decoded",
                "runescribe.presentation.observed",
            ]
        )
    }

    func testConfirmedImportAfterWriteErrorUsesReadbackWithImportEvidence() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox(failsSubmissions: true)
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let senderCipher = Cipher.generated(label: "After Commit")
        let data = try Self.messageFile(
            plaintext: "after commit",
            senderName: "After Commit",
            cipher: senderCipher,
            embedsCipher: true
        )
        let result = try await service.importFile(
            Self.inboundFile(data, id: 108),
            context: try Self.context(108)
        )

        XCTAssertEqual(result.disposition, .receivedMessage)
        let confirmation = try XCTUnwrap(result.pendingImport)
        await harness.secure.failCipherLibraryWrite(
            afterSuccessfulWrites: 0,
            afterCommit: true
        )
        _ = try await service.confirmImport(
            ConfirmImportCommand(
                importID: confirmation.id,
                name: "After Confirm"
            ),
            context: try Self.context(108_001)
        )
        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let library = try await repository.snapshot()
        XCTAssertTrue(library.ciphers.contains { $0.publicID == senderCipher.publicID })
        let ledger = try await repository.progressionEvidenceSnapshot()
        XCTAssertEqual(
            Dictionary(
                grouping: ledger.pendingBatches.flatMap(\.batch.facts)
                    .map(\.fact.eventType.rawValue),
                by: { $0 }
            ).mapValues(\.count),
            [
                "runescribe.message.imported": 1,
                "runescribe.message.decoded": 1,
                "runescribe.presentation.observed": 1,
                "runescribe.cipher.imported": 1,
            ]
        )
    }

    func testUnconfirmedEmbeddedCipherCannotInvokeContactOrPersistRelationship() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let service = harness.service(outbox: outbox)
        await service.startInboundProcessing()
        let contact = CoreIntegrationContact(failsCommit: true, value: 1)
        let cipher = Cipher.generated(label: "Unverified Claim")

        let mutation = try await Self.directMessageImport(
            harness: harness,
            outbox: outbox,
            contact: contact,
            cipher: cipher
        )

        XCTAssertNotNil(mutation.pendingEmbeddedCipher)
        XCTAssertEqual(
            mutation.message.senderIdentityStatus,
            .awaitingCipherConfirmation
        )
        XCTAssertFalse(mutation.library.ciphers.contains {
            $0.publicID == cipher.publicID
        })
        let didCommit = await contact.didCommit()
        let didComplete = await contact.didComplete()
        XCTAssertFalse(didCommit)
        XCTAssertFalse(didComplete)
        let ledger = try await CipherRepository(
            runtimeIO: harness.runtimeIO
        ).progressionEvidenceSnapshot()
        XCTAssertTrue(ledger.relationships.isEmpty)
        let facts = await outbox.facts()
        XCTAssertEqual(facts.map(\.eventType.rawValue), [
            "runescribe.message.decoded",
            "runescribe.presentation.observed",
        ])
    }

    func testRelaunchedReadmissionKeepsSemanticTokensAndDoesNotReimportCipher() async throws {
        let harness = CoreProgressionHarness()
        let outbox = CoreIntegrationOutbox()
        let senderCipher = Cipher.generated(label: "Replay Sender")
        let data = try Self.messageFile(
            plaintext: "same package",
            senderName: "Replay Sender",
            cipher: senderCipher,
            embedsCipher: true
        )
        let first = harness.service(outbox: outbox)
        await first.startInboundProcessing()
        let firstResult = try await first.importFile(
            Self.inboundFile(data, id: 103),
            context: try Self.context(103)
        )
        let confirmation = try XCTUnwrap(firstResult.pendingImport)
        _ = try await first.confirmImport(
            ConfirmImportCommand(
                importID: confirmation.id,
                name: "Confirmed Replay Sender"
            ),
            context: try Self.context(103_001)
        )

        let relaunched = harness.service(outbox: outbox)
        await relaunched.startInboundProcessing()
        let replayResult = try await relaunched.importFile(
            Self.inboundFile(data, id: 104),
            context: try Self.context(104)
        )
        XCTAssertNil(replayResult.pendingImport)

        let facts = await outbox.facts()
        let imported = facts.filter {
            $0.eventType.rawValue == "runescribe.message.imported"
        }
        let decoded = facts.filter {
            $0.eventType.rawValue == "runescribe.message.decoded"
        }
        let presentations = facts.filter {
            $0.eventType.rawValue == "runescribe.presentation.observed"
        }
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(presentations.count, 2)
        XCTAssertEqual(Set(imported.compactMap(\.payload.packageToken)).count, 1)
        XCTAssertEqual(Set(decoded.compactMap(\.payload.packageToken)).count, 1)
        XCTAssertEqual(Set(presentations.compactMap(\.payload.packageToken)).count, 1)
        XCTAssertEqual(facts.filter {
            $0.eventType.rawValue == "runescribe.cipher.imported"
        }.count, 1)
        let library = try await CipherRepository(runtimeIO: harness.runtimeIO).snapshot()
        XCTAssertEqual(library.ciphers.filter {
            $0.publicID == senderCipher.publicID
        }.count, 1)
    }

    private static func firstCipherID(
        from service: RuneScribeCoreApplicationService
    ) async throws -> CipherID {
        var iterator = service.stateStream().makeAsyncIterator()
        let value = await iterator.next()
        let snapshot = try XCTUnwrap(value)
        return try XCTUnwrap(snapshot.cipherLibrary.ciphers.first?.id)
    }

    private static func installLegacyLibrary(
        _ records: [CoreIntegrationLegacyCipher],
        in harness: CoreProgressionHarness
    ) async throws {
        let activeID = try XCTUnwrap(records.first?.id)
        let library = CoreIntegrationLegacyLibrary(
            ciphers: records,
            activeID: activeID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(library)
        let keyData = Data(repeating: 0x6B, count: 32)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData)
        )
        try await harness.secure.set(
            keyData,
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        try await harness.secure.set(
            try XCTUnwrap(sealed.combined),
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
    }

    private static func installCurrentLibrary(
        _ library: CipherLibrary,
        in harness: CoreProgressionHarness
    ) async throws {
        let storedKeyData = await harness.secure.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        let keyData = storedKeyData ?? Data(repeating: 0x6C, count: 32)
        if storedKeyData == nil {
            try await harness.secure.set(
                keyData,
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.symmetricKeyAccount
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(library)
        let sealed = try AES.GCM.seal(
            plaintext,
            using: SymmetricKey(data: keyData)
        )
        try await harness.secure.set(
            try XCTUnwrap(sealed.combined),
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
    }

    private static func fillPendingProgressionLedger(
        _ repository: CipherRepository,
        count: Int,
        contextOffset: UInt64
    ) async throws -> [CorePendingProgressionBatch] {
        var batches: [CorePendingProgressionBatch] = []
        batches.reserveCapacity(count)
        for index in 0..<count {
            let value = contextOffset + UInt64(index)
            let token = try XCTUnwrap(CipherToken(
                rawValue: String(format: "%064llx", value)
            ))
            let fact = try CoreProgressionFactFactory.cipherCreated(
                cipherToken: token
            )
            batches.append(contentsOf: try CoreProgressionCoordinator.pendingBatches(
                context: try context(value),
                commandDigest: try CoreProgressionCoordinator.commandDigest(fact),
                facts: [fact]
            ))
        }
        _ = try await repository.appendPendingProgressionBatches(batches)
        return batches.sorted { $0.identity < $1.identity }
    }

    private static func cipherSeedCapacityLibrary() throws -> CipherLibrary {
        var ciphers: [Cipher] = []
        var seeds: [CoreCipherProgressionSeedRecord] = []
        ciphers.reserveCapacity(CoreProgressionLedger.maximumCipherSeedCount)
        seeds.reserveCapacity(CoreProgressionLedger.maximumCipherSeedCount)
        for index in 1...CoreProgressionLedger.maximumCipherSeedCount {
            let value = UInt64(index)
            let id = capacityUUID(prefix: "D1000000", value: value)
            ciphers.append(Cipher(
                id: id,
                label: "Capacity \(index)",
                origin: index.isMultiple(of: 2) ? .imported : .generated,
                createdAt: Date(timeIntervalSince1970: 1_600_000_000 + Double(index)),
                publicID: capacityBytes(value),
                keyMaterial: capacitySeed(domain: 0x91, value: value),
                symbolPermutation: Array(0..<32)
            ))
            seeds.append(try CoreCipherProgressionSeedRecord(
                cipherID: id,
                seed: capacitySeed(domain: 0xE1, value: value)
            ))
        }
        return CipherLibrary(
            version: CipherLibrary.currentVersion,
            ciphers: ciphers,
            activeID: ciphers.first?.id,
            progressionLedger: try CoreProgressionLedger(cipherSeeds: seeds)
        )
    }

    private static func relationshipCapacityLibrary() throws -> CipherLibrary {
        let cipherID = capacityUUID(prefix: "D2000000", value: 1)
        let firstContactID = capacityUUID(prefix: "D3000000", value: 1)
        let cipher = Cipher(
            id: cipherID,
            label: "Relationship Capacity",
            origin: .generated,
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            publicID: capacityBytes(1),
            keyMaterial: capacitySeed(domain: 0x92, value: 1),
            symbolPermutation: Array(0..<32),
            contactID: firstContactID,
            keyDeliveryState: .pending
        )
        var relationships: [CoreRelationshipProgressionRecord] = []
        relationships.reserveCapacity(CoreProgressionLedger.maximumRelationshipCount)
        for index in 1...CoreProgressionLedger.maximumRelationshipCount {
            let value = UInt64(index)
            relationships.append(try CoreRelationshipProgressionRecord(
                identity: CoreProgressionRelationshipIdentity(
                    cipherID: cipherID,
                    contactID: capacityUUID(prefix: "D3000000", value: value)
                ),
                seed: capacitySeed(domain: 0xE2, value: value),
                keyDeliveryState: .pending
            ))
        }
        return CipherLibrary(
            version: CipherLibrary.currentVersion,
            ciphers: [cipher],
            activeID: cipherID,
            progressionLedger: try CoreProgressionLedger(
                cipherSeeds: [try CoreCipherProgressionSeedRecord(
                    cipherID: cipherID,
                    seed: capacitySeed(domain: 0xE1, value: 1)
                )],
                relationships: relationships
            )
        )
    }

    private static func capacityUUID(prefix: String, value: UInt64) -> UUID {
        UUID(uuidString: String(
            format: "\(prefix)-0000-0000-0000-%012llx",
            value
        ))!
    }

    private static func capacityBytes(_ value: UInt64) -> Data {
        var encodedValue = value.bigEndian
        return withUnsafeBytes(of: &encodedValue) { Data($0) }
    }

    private static func capacitySeed(domain: UInt8, value: UInt64) -> Data {
        var encodedValue = value.bigEndian
        var data = Data(repeating: domain, count: 24)
        data.append(withUnsafeBytes(of: &encodedValue) { Data($0) })
        return data
    }

    private static func inboundFile(_ data: Data, id: UInt64) -> InboundFileDTO {
        let suffix = String(format: "%012llx", id)
        return InboundFileDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: UUID(
                    uuidString: "A2000000-0000-0000-0000-\(suffix)"
                )!),
                receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(id)),
                source: .fileImporter,
                isColdStart: false
            ),
            data: data,
            declaredContentType: RuneScribeWireFormat.contentType
        )
    }

    private static func messageFile(
        plaintext: String,
        senderName: String,
        cipher: Cipher,
        embedsCipher: Bool
    ) throws -> Data {
        let sealed = try MessageCryptor().seal(plaintext, with: cipher)
        return try MessageSharePayload(
            senderName: senderName,
            envelope: MessageEnvelope.wrap(sealed),
            embeddedCipher: embedsCipher ? CipherSharePayload(cipher: cipher) : nil
        ).encodedFile(fontBytes: nil)
    }

    private static func directMessageImport(
        harness: CoreProgressionHarness,
        outbox: CoreIntegrationOutbox,
        contact: CoreIntegrationContact,
        cipher: Cipher
    ) async throws -> MessageImportMutation {
        let data = try messageFile(
            plaintext: "direct atomic import",
            senderName: cipher.label,
            cipher: cipher,
            embedsCipher: true
        )
        let (payload, fontBytes) = try MessageSharePayload.decodeFile(data)
        let repository = CipherRepository(runtimeIO: harness.runtimeIO)
        let progression = CoreProgressionCoordinator(
            repository: repository,
            tokens: harness.tokens,
            outbox: outbox
        )
        return try await MessageImportUseCase.ingest(
            payload: payload,
            fontBytes: fontBytes,
            repository: repository,
            messageService: MessageService(),
            fontIntegration: nil,
            contactIntegration: contact,
            runtimeIO: harness.runtimeIO,
            progression: progression,
            usesProgressionEvidence: true,
            admittedPackageToken: try await harness.tokens.packageToken(for: data),
            progressionRoute: .file,
            embeddedCipherProgressionSeed: try await harness.tokens.makeCipherSeed(),
            relationshipProgressionSeed: try await harness.tokens
                .makeRelationshipSeed()
        )
    }

    private static func context(
        _ value: UInt64,
        scope: RuntimeOperationContextAuthorityScope = .persistent
    ) throws -> RuntimePersistableOperationContext {
        let suffix = String(format: "%012llx", value)
        return try RuntimePersistableOperationContext(
            operationID: RuntimeOperationID(rawValue: "core-integration-\(value)"),
            correlationID: RuntimeCorrelationID(
                rawValue: "B0000000-0000-0000-0000-\(suffix)"
            ),
            occurredAtUTC: Date(timeIntervalSince1970: 1_800_000_000 + Double(value)),
            operationIdentifier: RuntimeOperationIdentifier(
                rawValue: "core.integration.\(value)"
            ),
            runtimeGeneration: 1,
            authorityNonce: UUID(
                uuidString: "C0000000-0000-0000-0000-\(suffix)"
            )!,
            authorityTag: Data(repeating: UInt8(truncatingIfNeeded: value), count: 32),
            authorityScope: scope
        )
    }
}

private final class CoreProgressionHarness: @unchecked Sendable {
    let secure = CoreIntegrationSecureStore()
    let protected = CoreIntegrationProtectedStore()
    let artifacts = CoreIntegrationArtifactStore()
    let uuids = CoreIntegrationUUIDs()
    let tokens: CoreIntegrationTokens
    let runtimeIO: RuntimeIOClient

    init(tokens: CoreIntegrationTokens = CoreIntegrationTokens()) {
        self.tokens = tokens
        let secure = secure
        let protected = protected
        let artifacts = artifacts
        let uuids = uuids
        runtimeIO = RuntimeIOClient(
            secureValueData: { service, account in
                await secure.data(service: service, account: account)
            },
            setSecureValue: { data, service, account in
                try await secure.set(data, service: service, account: account)
            },
            deleteSecureValue: { service, account in
                await secure.delete(service: service, account: account)
            },
            readProtectedFile: { path, maximumByteCount in
                try await protected.read(
                    path,
                    maximumByteCount: maximumByteCount
                )
            },
            writeProtectedFile: { data, path in
                try await protected.write(data, path: path)
            },
            removeProtectedFile: { path in
                try await protected.remove(path)
            },
            protectedFileExists: { path in
                await protected.exists(path)
            },
            protectedFileContents: { root, fileExtension in
                await protected.contents(
                    root: root,
                    fileExtension: fileExtension
                )
            },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            nextUUID: { await uuids.next() },
            createShareArtifact: { data, id, _, _ in
                await artifacts.create(data, id: id)
            },
            storeShareArtifactLink: { url, id in
                await artifacts.store(url, id: id)
            },
            removeShareArtifactLink: { id in
                await artifacts.remove(id: id)
            },
            removeShareArtifact: { id in
                await artifacts.remove(id: id)
            },
            removeAllShareArtifacts: {
                await artifacts.removeAll()
            }
        )
    }

    func service(
        outbox: CoreIntegrationOutbox?,
        migration: CoreIntegrationMigrationCapture? = nil,
        contactManager: ContactManager? = nil
    ) -> RuneScribeCoreApplicationService {
        RuneScribeCoreApplicationService(
            runtimeIO: runtimeIO,
            fontCatalog: nil,
            contactManager: contactManager,
            progressionTransport: outbox,
            progressionTokens: tokens,
            existingUserMigration: migration
        )
    }
}

private actor CoreIntegrationProtectedStore {
    private var values: [ProtectedPath: Data] = [:]
    private var writesBeforeFailure: Int?
    private var failWriteAfterCommit = false

    func read(
        _ path: ProtectedPath,
        maximumByteCount: Int
    ) throws -> Data? {
        guard let data = values[path] else { return nil }
        guard data.count <= maximumByteCount else {
            throw ProtectedFileStoreReadError.contentTooLarge
        }
        return data
    }

    func write(_ data: Data, path: ProtectedPath) throws {
        if let remaining = writesBeforeFailure {
            if remaining == 0 {
                writesBeforeFailure = nil
                if failWriteAfterCommit { values[path] = data }
                failWriteAfterCommit = false
                throw CoreIntegrationFailure.injected
            }
            writesBeforeFailure = remaining - 1
        }
        values[path] = data
    }

    func remove(_ path: ProtectedPath) throws {
        values.removeValue(forKey: path)
    }

    func exists(_ path: ProtectedPath) -> Bool { values[path] != nil }

    func contents(
        root: ProtectedPath,
        fileExtension: String?
    ) -> [ProtectedPath] {
        values.keys.filter { path in
            path.rawValue.hasPrefix(root.rawValue)
                && fileExtension.map {
                    path.rawValue.hasSuffix(".\($0)")
                } ?? true
        }.sorted()
    }

    func failWrite(
        afterSuccessfulWrites successfulWrites: Int,
        afterCommit: Bool = false
    ) {
        writesBeforeFailure = successfulWrites
        failWriteAfterCommit = afterCommit
    }

    func count() -> Int { values.count }
}

private actor CoreIntegrationSecureStore {
    private struct Address: Hashable {
        let service: String
        let account: String
    }

    private var values: [Address: Data] = [:]
    private var cipherLibraryWritesBeforeFailure: Int?
    private var failCipherLibraryWriteAfterCommit = false

    func data(service: String, account: String) -> Data? {
        values[Address(service: service, account: account)]
    }

    func set(_ data: Data, service: String, account: String) throws {
        let address = Address(service: service, account: account)
        if account == RuneScribeKeychain.cipherLibraryAccount,
           let remaining = cipherLibraryWritesBeforeFailure {
            if remaining == 0 {
                cipherLibraryWritesBeforeFailure = nil
                if failCipherLibraryWriteAfterCommit {
                    values[address] = data
                }
                failCipherLibraryWriteAfterCommit = false
                throw CoreIntegrationFailure.injected
            }
            cipherLibraryWritesBeforeFailure = remaining - 1
        }
        values[address] = data
    }

    func delete(service: String, account: String) {
        values.removeValue(forKey: Address(service: service, account: account))
    }

    func failCipherLibraryWrite(
        afterSuccessfulWrites successfulWrites: Int,
        afterCommit: Bool = false
    ) {
        cipherLibraryWritesBeforeFailure = successfulWrites
        failCipherLibraryWriteAfterCommit = afterCommit
    }
}

private actor CoreIntegrationArtifactStore {
    private var dataByID: [ShareArtifactID: Data] = [:]
    private var linksByID: [ShareArtifactID: URL] = [:]

    func create(_ data: Data, id: ShareArtifactID) { dataByID[id] = data }
    func store(_ url: URL, id: ShareArtifactID) { linksByID[id] = url }
    func remove(id: ShareArtifactID) {
        dataByID.removeValue(forKey: id)
        linksByID.removeValue(forKey: id)
    }
    func removeAll() {
        dataByID.removeAll()
        linksByID.removeAll()
    }

    func count() -> Int {
        Set(dataByID.keys).union(linksByID.keys).count
    }
}

private actor CoreIntegrationUUIDs {
    private var value: UInt64 = 1

    func next() -> UUID {
        defer { value += 1 }
        return UUID(
            uuidString: "D0000000-0000-0000-0000-\(String(format: "%012llx", value))"
        )!
    }
}

private actor CoreIntegrationContact: CoreMessageContactAssociating {
    private let contact: Contact
    private let failsCommit: Bool
    private var committed = false
    private var completed = false

    init(failsCommit: Bool = false, value: UInt64) {
        let suffix = String(format: "%012llx", value)
        contact = Contact(
            id: UUID(uuidString: "A3000000-0000-0000-0000-\(suffix)")!,
            displayName: "Imported Contact \(value)",
            source: .imported,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        self.failsCommit = failsCommit
    }

    func prepareImportedContact(named _: String) -> PreparedMessageContact {
        PreparedMessageContact(contact: contact, requiresCommit: true)
    }

    func commitPreparedImportedContact(
        _ prepared: PreparedMessageContact
    ) throws -> ContactMutation<Contact> {
        if failsCommit { throw CoreIntegrationFailure.injected }
        committed = true
        return ContactMutation(
            value: prepared.contact,
            book: ContactBook(contacts: [prepared.contact])
        )
    }

    func stageMessageAssociation(
        _ prepared: PreparedMessageContact,
        cipherID: UUID,
        previousContactID: UUID?
    ) -> MessageContactAssociationIntent {
        MessageContactAssociationIntent(
            cipherID: cipherID,
            preparedContactID: prepared.contact.id,
            previousContactID: previousContactID,
            requiresContactCommit: prepared.requiresCommit
        )
    }

    func completeMessageAssociation(_: MessageContactAssociationIntent) {
        completed = true
    }

    func didCommit() -> Bool { committed }
    func didComplete() -> Bool { completed }
}

private struct CoreIntegrationLegacyLibrary: Encodable {
    let version = CipherLibrary.legacyVersion
    let ciphers: [CoreIntegrationLegacyCipher]
    let activeID: UUID
}

private struct CoreIntegrationLegacyCipher: Encodable {
    let id: UUID
    let label: String
    let origin: Cipher.Origin
    let createdAt: Date
    let formatVersion = 1
    let publicID: Data
    let keyMaterial: Data
    let decorativeMapping: [Int]
    let fontRef = FontRef.bundled
    let contactID: UUID?
    let delivered: Bool

    init(
        value: UInt64,
        label: String,
        origin: Cipher.Origin,
        contactID: UUID? = nil,
        delivered: Bool = false
    ) {
        id = UUID(uuidString: String(
            format: "A4000000-0000-0000-0000-%012x",
            value
        ))!
        self.label = label
        self.origin = origin
        createdAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(value))
        var encodedValue = value.bigEndian
        publicID = withUnsafeBytes(of: &encodedValue) { Data($0) }
        keyMaterial = Data(repeating: UInt8(truncatingIfNeeded: value), count: 32)
        decorativeMapping = Array(0..<32)
        self.contactID = contactID
        self.delivered = delivered
    }
}

private enum CoreIntegrationFailure: Error { case injected }

private enum CoreIntegrationTokenFailure: Hashable {
    case cipherSeed
    case cipherToken
    case messageToken
    case packageToken
    case relationshipSeed
    case relationshipToken
}

private actor CoreIntegrationTokens: CoreProgressionTokenDeriving {
    private var failures: Set<CoreIntegrationTokenFailure>
    private var cipherSeedValue: UInt64 = 1
    private var relationshipSeedValue: UInt64 = 1
    private var messageValue: UInt64 = 1

    init(failures: Set<CoreIntegrationTokenFailure> = []) {
        self.failures = failures
    }

    func setFailures(_ failures: Set<CoreIntegrationTokenFailure>) {
        self.failures = failures
    }

    func makeCipherSeed() throws -> Data {
        if failures.contains(.cipherSeed) { throw CoreIntegrationFailure.injected }
        defer { cipherSeedValue += 1 }
        return Self.seed(domain: 0xC1, value: cipherSeedValue)
    }

    func cipherToken(for seed: Data) throws -> CipherToken {
        if failures.contains(.cipherToken) { throw CoreIntegrationFailure.injected }
        return try Self.token(CipherToken.self, domain: "cipher", data: seed)
    }

    func makeMessageToken() throws -> MessageToken {
        if failures.contains(.messageToken) { throw CoreIntegrationFailure.injected }
        defer { messageValue += 1 }
        return MessageToken(rawValue: String(format: "%064llx", messageValue))!
    }

    func packageToken(for admittedPackageBytes: Data) throws -> PackageToken {
        if failures.contains(.packageToken) { throw CoreIntegrationFailure.injected }
        return try Self.token(
            PackageToken.self,
            domain: "package",
            data: admittedPackageBytes
        )
    }

    func makeRelationshipSeed() throws -> Data {
        if failures.contains(.relationshipSeed) {
            throw CoreIntegrationFailure.injected
        }
        defer { relationshipSeedValue += 1 }
        return Self.seed(domain: 0xD1, value: relationshipSeedValue)
    }

    func relationshipToken(for seed: Data) throws -> RelationshipToken {
        if failures.contains(.relationshipToken) {
            throw CoreIntegrationFailure.injected
        }
        return try Self.token(
            RelationshipToken.self,
            domain: "relationship",
            data: seed
        )
    }

    private static func token<Token: RawRepresentable>(
        _: Token.Type,
        domain: String,
        data: Data
    ) throws -> Token where Token.RawValue == String {
        let digest = SHA256.hash(data: Data(domain.utf8) + data)
        let raw = digest.map { String(format: "%02x", $0) }.joined()
        guard let token = Token(rawValue: raw) else {
            throw CoreIntegrationFailure.injected
        }
        return token
    }

    private static func seed(domain: UInt8, value: UInt64) -> Data {
        var encodedValue = value.bigEndian
        var data = Data(repeating: domain, count: 24)
        data.append(withUnsafeBytes(of: &encodedValue) { Data($0) })
        return data
    }
}

private actor CoreIntegrationOutbox: CoreProgressionOutboxTransport {
    private let failsBackgroundContexts: Bool
    private let failsSubmissions: Bool
    private var submitted: [ProgressionEventFact] = []
    private var submittedOperationIDs: [(String, RuntimeOperationID)] = []
    private var backgroundValue: UInt64 = 500
    private var revision: UInt64 = 0

    init(
        failsBackgroundContexts: Bool = false,
        failsSubmissions: Bool = false
    ) {
        self.failsBackgroundContexts = failsBackgroundContexts
        self.failsSubmissions = failsSubmissions
    }

    func submitBatch(
        _ batch: ProgressionEventFactBatch,
        context: RuntimePersistableOperationContext
    ) throws -> ProgressionOutboxBatchReceipt {
        if failsSubmissions { throw CoreIntegrationFailure.injected }
        submitted.append(contentsOf: batch.facts.map(\.fact))
        submittedOperationIDs.append(contentsOf: batch.facts.map {
            ($0.fact.eventType.rawValue, context.runtimeOperationID)
        })
        revision += 1
        let ids = Dictionary(uniqueKeysWithValues: batch.facts.map { item in
            let suffix = String(
                format: "%012llx",
                revision * 1_000 + UInt64(item.slot.rawValue)
            )
            let raw = UUID(
                uuidString: "E0000000-0000-0000-0000-\(suffix)"
            )!
            return (item.slot, EventID(rawValue: raw))
        })
        return try ProgressionOutboxBatchReceipt(
            contextID: context.runtimeOperationID,
            batchIndex: batch.batchIndex,
            eventIDsBySlot: ids,
            correlationID: CorrelationID(
                rawValue: UUID(uuidString: context.runtimeCorrelationID.rawValue)!
            ),
            durableAt: Date(timeIntervalSince1970: 1_800_000_100),
            outboxRevision: revision
        )
    }

    func issueBackgroundContext(
        for _: RuntimeBackgroundOperationPurpose
    ) throws -> RuntimePersistableOperationContext {
        if failsBackgroundContexts { throw CoreIntegrationFailure.injected }
        defer { backgroundValue += 1 }
        let suffix = String(format: "%012llx", backgroundValue)
        return try RuntimePersistableOperationContext(
            operationID: RuntimeOperationID(rawValue: "background-\(backgroundValue)"),
            correlationID: RuntimeCorrelationID(
                rawValue: "F0000000-0000-0000-0000-\(suffix)"
            ),
            occurredAtUTC: Date(timeIntervalSince1970: 1_800_000_000),
            operationIdentifier: RuntimeOperationIdentifier(rawValue: "core.background"),
            runtimeGeneration: 1,
            authorityNonce: UUID(
                uuidString: "A1000000-0000-0000-0000-\(suffix)"
            )!,
            authorityTag: Data(repeating: 9, count: 32),
            authorityScope: .persistent
        )
    }

    func acknowledgeBatch(
        _ receipt: ProgressionOutboxBatchReceipt,
        context: RuntimePersistableOperationContext
    ) throws {
        guard receipt.matches(context: context) else {
            throw CoreIntegrationFailure.injected
        }
    }

    func facts() -> [ProgressionEventFact] { submitted }

    func operationIDs(eventType: String) -> [RuntimeOperationID] {
        submittedOperationIDs.compactMap { type, operationID in
            type == eventType ? operationID : nil
        }
    }
}

private actor CoreIntegrationMigrationCapture: CoreExistingUserMigrationSubmitting {
    private let throwsOnSubmit: Bool
    private var submissions: [[ExistingUserMigrationCipherDTO]] = []

    init(throwsOnSubmit: Bool = false) {
        self.throwsOnSubmit = throwsOnSubmit
    }

    func submit(ciphers: [ExistingUserMigrationCipherDTO]) throws {
        submissions.append(ciphers)
        if throwsOnSubmit { throw CoreIntegrationFailure.injected }
    }

    func submissionCount() -> Int { submissions.count }
    func lastCiphers() -> [ExistingUserMigrationCipherDTO]? { submissions.last }
    func allSubmissions() -> [[ExistingUserMigrationCipherDTO]] { submissions }
}
