#if os(macOS)
import AppKit
#endif
import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import SwiftUI
import XCTest

@MainActor
final class RuneScribeUISessionTests: XCTestCase {
    func testRootImportFailureAlertDoesNotReplaceRetryableConfirmation() {
        XCTAssertFalse(
            RootImportFailurePresentation.shouldShowAlert(
                message: "The import failed.",
                hasPendingImport: true,
                isLocked: false,
                showSplash: false
            )
        )
        XCTAssertTrue(
            RootImportFailurePresentation.shouldShowAlert(
                message: "The import failed.",
                hasPendingImport: false,
                isLocked: false,
                showSplash: false
            )
        )
        XCTAssertFalse(
            RootImportFailurePresentation.shouldShowAlert(
                message: nil,
                hasPendingImport: false,
                isLocked: false,
                showSplash: false
            )
        )
    }

    func testImportConfirmationFailureRemainsPresentedAndCanRetry() async throws {
        enum FixtureError: Error {
            case rejected
        }

        var attemptedLabels: [String] = []
        let failed = await ImportConfirmationFlow.attempt(label: "Retry Name") { label in
            attemptedLabels.append(label)
            throw FixtureError.rejected
        }

        XCTAssertEqual(attemptedLabels, ["Retry Name"])
        XCTAssertFalse(failed.shouldDismiss)
        guard case let .failed(error) = failed else {
            return XCTFail("Expected the failed confirmation to remain presented")
        }
        XCTAssertTrue(error is FixtureError)

        let importedCipher = Self.fixtureCipherViewState(label: "Retry Name")
        let retried = await ImportConfirmationFlow.attempt(label: "Retry Name") { label in
            attemptedLabels.append(label)
            return Self.fixtureCipherViewState(label: label)
        }

        XCTAssertEqual(attemptedLabels, ["Retry Name", "Retry Name"])
        XCTAssertTrue(retried.shouldDismiss)
        guard case let .imported(cipher) = retried else {
            return XCTFail("Expected the successful retry to dismiss")
        }
        XCTAssertEqual(cipher, importedCipher)
    }

    func testContactImportFailureRemainsPresentedAndCanRetry() async {
        var attempts = 0
        let failed = await ContactImportCommitFlow.attempt {
            attempts += 1
            throw StubError.unexpectedCommand
        }

        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(failed.shouldDismiss)
        XCTAssertEqual(
            failed,
            .failed("Rune Scribe could not complete the operation.")
        )
        if case .failed(let message) = failed {
            XCTAssertFalse(message.contains(StubError.sensitiveFixtureDetail))
        }

        let retried = await ContactImportCommitFlow.attempt {
            attempts += 1
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(retried.shouldDismiss)
        XCTAssertEqual(retried, .imported)
    }

    func testRuntimeApplicationClientMediatesCommandQueryStateAndLedger() async throws {
        let snapshot = Self.fixtureSnapshot(
            revision: 6,
            plaintext: nil,
            includeFailures: false
        )
        let cipher = try XCTUnwrap(snapshot.cipherLibrary.ciphers.first)
        let contacts = [
            SystemContactDTO(systemIdentifier: "system-freya", displayName: "Freya Day"),
        ]
        let service = ControllableApplicationService(
            createdCipher: cipher,
            systemContacts: contacts
        )
        let harness = try await makeApplicationClientHarness(
            applicationService: service
        )
        let stateTask = Task {
            var iterator = harness.client.applicationStateEnvelopes.makeAsyncIterator()
            return await iterator.next()
        }

        service.yieldState(snapshot)
        let created = try await harness.client.createCipher(
            CreateCipherCommand(name: "Freya")
        )
        let queriedContacts = try await harness.client.requestSystemContacts()
        let receivedState = await stateTask.value
        let stateEnvelope = try XCTUnwrap(receivedState)

        XCTAssertEqual(created, cipher)
        XCTAssertEqual(queriedContacts, contacts)
        XCTAssertEqual(stateEnvelope.payload, snapshot)
        XCTAssertEqual(
            stateEnvelope.metadata.operationIdentifier.rawValue,
            RuntimeApplicationEndpointCatalog.applicationState.endpointID.rawValue
        )
        XCTAssertEqual(stateEnvelope.metadata.sourceModuleID, TestApplicationClientModule.moduleID)
        XCTAssertEqual(stateEnvelope.metadata.destinationModuleID, TestCoreModule.moduleID)

        let ledger = await harness.runtime.callLedgerSnapshot()
        let createRecord = try XCTUnwrap(
            ledger.last {
                $0.metadata.operationIdentifier.rawValue
                    == RuntimeApplicationEndpointCatalog.createCipher.descriptor.endpointID.rawValue
            }
        )
        let queryRecord = try XCTUnwrap(
            ledger.last {
                $0.metadata.operationIdentifier.rawValue
                    == RuntimeApplicationEndpointCatalog.requestSystemContacts
                        .descriptor.endpointID.rawValue
            }
        )
        let stateRecord = try XCTUnwrap(
            ledger.last {
                $0.metadata.operationIdentifier.rawValue
                    == RuntimeApplicationEndpointCatalog.applicationState.endpointID.rawValue
            }
        )
        XCTAssertEqual(createRecord.endpointKind, .command)
        XCTAssertEqual(createRecord.outcome, .succeeded)
        XCTAssertEqual(queryRecord.endpointKind, .query)
        XCTAssertEqual(queryRecord.outcome, .succeeded)
        XCTAssertEqual(stateRecord.endpointKind, .state)
        XCTAssertTrue(stateRecord.outcome == .inFlight || stateRecord.outcome == .succeeded)

        await harness.runtime.stop()
    }

    func testRuntimeApplicationClientPreservesBurstMenuCommandFIFO() async throws {
        let service = ControllableApplicationService()
        let harness = try await makeApplicationClientHarness(
            applicationService: service
        )
        let expected: [ApplicationMenuCommandDTO] = (0..<16).map {
            $0.isMultiple(of: 2) ? .openCipherLibrary : .openSettings
        }

        let consumer = Task { () -> [ApplicationMenuCommandDTO] in
            var received: [ApplicationMenuCommandDTO] = []
            for await envelope in harness.client.menuCommandEnvelopes {
                received.append(envelope.payload)
                if received.count == expected.count { break }
            }
            return received
        }
        let dispositions = harness.runtime.submit(
            contentsOf: expected.map(ExternalInputEnvelope.menu)
        )
        XCTAssertEqual(dispositions, Array(repeating: .accepted, count: expected.count))
        let received = await consumer.value

        XCTAssertEqual(received, expected)
        await harness.runtime.stop()
    }

    func testRuntimeMenuCommandRailRejectsCapacityPlusOneAndPreservesFIFO() async throws {
        let harness = try await makeApplicationClientHarness(
            applicationService: ControllableApplicationService()
        )
        let failureCapture = IngressFailureCapture()
        harness.runtime.observeHostIngressFailures { failure in
            Task { await failureCapture.record(failure) }
        }
        let expected: [ApplicationMenuCommandDTO] = (0..<16).map {
            $0.isMultiple(of: 2) ? .openSettings : .openCipherLibrary
        }
        let dispositions = harness.runtime.submit(
            contentsOf: (expected + [.openSettings]).map(ExternalInputEnvelope.menu)
        )

        XCTAssertEqual(
            Array(dispositions.prefix(16)),
            Array(repeating: .accepted, count: 16)
        )
        XCTAssertEqual(dispositions.last, .rejected)
        var observedFailure: RuntimeHostIngressFailure?
        for _ in 0..<1_000 {
            observedFailure = await failureCapture.last()
            if observedFailure != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(observedFailure, .admissionRejected)

        var iterator = harness.client.menuCommandEnvelopes.makeAsyncIterator()
        var received: [ApplicationMenuCommandDTO] = []
        for _ in expected.indices {
            let next = await iterator.next()
            received.append(try XCTUnwrap(next).payload)
        }
        XCTAssertEqual(received, expected)
        XCTAssertEqual(harness.runtime.hostIngressSnapshot.rejectedInputCount, 1)

        await harness.runtime.stop()
    }

    func testRuntimeMenuCommandRailInvalidatesStaleStreamAndReopensAfterRestart() async throws {
        let harness = try await makeApplicationClientHarness(
            applicationService: ControllableApplicationService()
        )
        var staleIterator = harness.client.menuCommandEnvelopes.makeAsyncIterator()

        await harness.runtime.stop()
        let staleNext = await staleIterator.next()
        XCTAssertNil(staleNext)

        try await harness.runtime.start()
        let replacementClient = try await harness.capture.requireClient()
        var replacementIterator = replacementClient.menuCommandEnvelopes.makeAsyncIterator()
        XCTAssertEqual(harness.runtime.submit(.menu(.openSettings)), .accepted)
        let replacementNext = await replacementIterator.next()
        let replacement = try XCTUnwrap(replacementNext)
        XCTAssertEqual(replacement.payload, .openSettings)

        await harness.runtime.stop()
    }

    func testRuntimeMenuCommandRailPurgesUnreadBufferedValueAfterStop() async throws {
        let harness = try await makeApplicationClientHarness(
            applicationService: ControllableApplicationService()
        )
        let staleStream = harness.client.menuCommandEnvelopes

        XCTAssertEqual(harness.runtime.submit(.menu(.openSettings)), .accepted)
        let deliveredToRuntimeBuffer = await eventually {
            harness.runtime.hostIngressSnapshot.queuedInputCount == 0
        }
        XCTAssertTrue(deliveredToRuntimeBuffer)
        XCTAssertEqual(harness.runtime.hostIngressSnapshot.failedDeliveryCount, 0)

        await harness.runtime.stop()
        var staleIterator = staleStream.makeAsyncIterator()
        let staleBufferedValue = await staleIterator.next()
        XCTAssertNil(staleBufferedValue)
    }

    func testCancelledMenuConsumerRejectsDeliveryAndPermitsFreshRuntimeClient() async throws {
        let harness = try await makeApplicationClientHarness(
            applicationService: ControllableApplicationService()
        )
        let failureCapture = IngressFailureCapture()
        harness.runtime.observeHostIngressFailures { failure in
            Task { await failureCapture.record(failure) }
        }
        let consumer = Task { () -> RuntimeStateEnvelope<ApplicationMenuCommandDTO>? in
            var iterator = harness.client.menuCommandEnvelopes.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()
        consumer.cancel()
        let cancelledValue = await consumer.value
        XCTAssertNil(cancelledValue)

        XCTAssertEqual(harness.runtime.submit(.menu(.openSettings)), .accepted)
        var observedFailure: RuntimeHostIngressFailure?
        for _ in 0..<1_000 {
            observedFailure = await failureCapture.last()
            if observedFailure != nil { break }
            await Task.yield()
        }
        XCTAssertEqual(observedFailure, .destinationRejected)

        let replacement = try await harness.capture.makeClient()
        var replacementIterator = replacement.menuCommandEnvelopes.makeAsyncIterator()
        XCTAssertEqual(harness.runtime.submit(.menu(.openCipherLibrary)), .accepted)
        let next = await replacementIterator.next()
        XCTAssertEqual(try XCTUnwrap(next).payload, .openCipherLibrary)

        await harness.runtime.stop()
    }

    func testCancelledMenuConsumerAllowsImmediateReplacementSubscription() async throws {
        let harness = try await makeApplicationClientHarness(
            applicationService: ControllableApplicationService()
        )
        let consumer = Task { () -> RuntimeStateEnvelope<ApplicationMenuCommandDTO>? in
            var iterator = harness.client.menuCommandEnvelopes.makeAsyncIterator()
            return await iterator.next()
        }
        await Task.yield()
        consumer.cancel()
        let cancelledValue = await consumer.value
        XCTAssertNil(cancelledValue)

        let replacement = try await harness.capture.makeClient()
        var replacementIterator = replacement.menuCommandEnvelopes.makeAsyncIterator()
        XCTAssertEqual(harness.runtime.submit(.menu(.openSettings)), .accepted)
        let next = await replacementIterator.next()
        XCTAssertEqual(try XCTUnwrap(next).payload, .openSettings)

        await harness.runtime.stop()
    }

    func testRuntimeStopDeniesNewClientCallsWhileAcceptedMenuDrainsToSubscriber() async throws {
        let inboundGate = InboundReceiveGate()
        let quiesceGate = RuntimeQuiesceGate()
        let cipher = try XCTUnwrap(
            Self.fixtureSnapshot(
                revision: 20,
                plaintext: nil,
                includeFailures: false
            ).cipherLibrary.ciphers.first
        )
        let service = ControllableApplicationService(
            createdCipher: cipher,
            inboundGate: inboundGate
        )
        let harness = try await makeApplicationClientHarness(
            applicationService: service,
            startCoordinator: quiesceGate
        )
        let session = RuneScribeUISession(
            applicationClient: harness.client,
            runtimeIO: RuntimeIOClient(setClipboardString: { _ in }),
            resourcePresentation: RuntimeApplicationResourcePresentation(
                splashVideo: nil,
                metalLibrary: nil
            ),
            productMetadata: .init(version: "1.0", buildNumber: "1")
        )
        try session.start()
        XCTAssertEqual(harness.runtime.submit(.menu(.openSettings)), .accepted)
        await inboundGate.waitUntilSuspended()

        let stopTask = Task { await harness.runtime.stop() }
        await quiesceGate.waitUntilSuspended()
        do {
            _ = try await harness.client.createCipher(
                CreateCipherCommand(name: "Denied during stop")
            )
            XCTFail("A new client call must not enter after stop quiesces the runtime")
        } catch let error as RuneScribeRuntimeError {
            guard case .runtimeNotRunning = error else {
                return XCTFail("Expected runtime-not-running, received \(error)")
            }
        }

        await inboundGate.release()
        let menuDelivered = await eventually {
            session.route?.route == .openSettings
        }
        XCTAssertTrue(menuDelivered)
        await quiesceGate.release()
        await stopTask.value
        let finalStatus = await harness.runtime.snapshot().status
        XCTAssertEqual(finalStatus, .stopped)
        await session.stop()
    }

    func testRuntimeApplicationClientFailsAfterCoreReplacementWithoutSessionCleanup() async throws {
        let snapshot = Self.fixtureSnapshot(
            revision: 6,
            plaintext: nil,
            includeFailures: false
        )
        let cipher = try XCTUnwrap(snapshot.cipherLibrary.ciphers.first)
        let service = ControllableApplicationService(createdCipher: cipher)
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()

        let created = try await session.addCipher(label: "Before replacement")
        XCTAssertEqual(created.id, cipher.id.rawValue)

        await runtime.stop()
        try await runtime.start()

        do {
            _ = try await session.addCipher(label: "Stale client")
            XCTFail("The retained UI client must fail after Core replacement")
        } catch let error as RuneScribeRuntimeError {
            guard case .staleClient = error else {
                return XCTFail("Expected stale-client rejection, received \(error)")
            }
        }
        XCTAssertEqual(session.lastError, "Rune Scribe could not complete the operation.")

        let ledger = await runtime.callLedgerSnapshot()
        XCTAssertTrue(
            ledger.contains {
                $0.metadata.operationIdentifier.rawValue
                    == RuntimeApplicationEndpointCatalog.createCipher.descriptor.endpointID.rawValue
                    && $0.outcome == .denied(.staleClient)
            }
        )

        await session.stop()
        await runtime.stop()
    }

    func testClipboardCopyUsesRuntimeIOClient() async throws {
        let capture = ClipboardWriteCapture()
        let runtimeIO = RuntimeIOClient(
            setClipboardString: { value in
                await capture.append(value)
            }
        )
        let (session, runtime) = try await makeSession(
            applicationService: ControllableApplicationService(),
            runtimeIO: runtimeIO
        )

        let copied = await session.copyToClipboard("ᚱᚢᚾᛖ")
        let copiedValues = await capture.values()

        XCTAssertTrue(copied)
        XCTAssertEqual(copiedValues, ["ᚱᚢᚾᛖ"])
        XCTAssertNil(session.lastError)
        await session.stop()
        await runtime.stop()
    }

    func testClipboardCopyFailureIsSanitizedAndNotConfirmed() async throws {
        let runtimeIO = RuntimeIOClient(
            setClipboardString: { _ in throw StubError.unexpectedCommand }
        )
        let (session, runtime) = try await makeSession(
            applicationService: ControllableApplicationService(),
            runtimeIO: runtimeIO
        )

        let copied = await session.copyToClipboard("secret")

        XCTAssertFalse(copied)
        XCTAssertEqual(
            session.lastError,
            "Rune Scribe could not complete the operation."
        )
        XCTAssertFalse(
            session.lastError?.contains(StubError.sensitiveFixtureDetail) ?? false
        )
        await session.stop()
        await runtime.stop()
    }

    func testSnapshotAndPendingMessageProjectWithoutOwningDomainState() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()

        service.yieldState(Self.fixtureSnapshot(revision: 7, plaintext: "Meet at the oak."))
        let projected = await eventually { session.snapshot?.revision == 7 }

        XCTAssertTrue(projected)
        XCTAssertEqual(session.ciphers.count, 1)
        XCTAssertEqual(session.activeCipher?.label, "Freya")
        XCTAssertEqual(session.activeCipher?.fontName, "Elder Runes")
        XCTAssertEqual(session.activeCipher?.shortPublicID, "ABCDEF12")
        XCTAssertEqual(session.contacts.map(\.displayName), ["Freya Day"])
        XCTAssertEqual(session.importedContactCount, 1)
        XCTAssertEqual(session.pendingMessage?.plaintext, "Meet at the oak.")
        XCTAssertEqual(session.pendingMessage?.senderName, "Freya")
        XCTAssertEqual(session.pendingMessage?.cipherName, "Freya")
        XCTAssertEqual(session.lastError, "A required app resource is unavailable.")
        XCTAssertEqual(session.importErrorMessage, "This isn't a valid Rune Scribe import.")
        XCTAssertEqual(
            session.messageErrorMessage,
            "This message couldn't be read with your ciphers."
        )

        await session.stop()
        await runtime.stop()
    }

    func testRepeatingSameMessageSnapshotKeepsOneIdenticalProjection() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()
        let state = Self.fixtureSnapshot(
            revision: 8,
            plaintext: "once only",
            includeFailures: false
        )

        service.yieldState(state)
        let firstProjectionArrived = await eventually {
            session.pendingMessage?.plaintext == "once only"
        }
        XCTAssertTrue(firstProjectionArrived)
        let firstProjection = try XCTUnwrap(session.pendingMessage)

        service.yieldState(state)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(session.pendingMessage, firstProjection)
        await session.stop()
        await runtime.stop()
    }

    func testSnapshotWithoutPendingMessageClearsPresentation() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()

        service.yieldState(
            Self.fixtureSnapshot(
                revision: 9,
                plaintext: "hello",
                includeFailures: false
            )
        )
        let pendingProjectionArrived = await eventually {
            session.pendingMessage != nil
        }
        XCTAssertTrue(pendingProjectionArrived)

        service.yieldState(
            Self.fixtureSnapshot(
                revision: 10,
                plaintext: nil,
                includeFailures: false
            )
        )
        let pendingProjectionCleared = await eventually {
            session.snapshot?.revision == 10 && session.pendingMessage == nil
        }
        XCTAssertTrue(pendingProjectionCleared)

        await session.stop()
        await runtime.stop()
    }

    func testMenuStreamAndReplyUseTypedConsumableRoutes() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()

        XCTAssertEqual(runtime.submit(.menu(.openSettings)), .accepted)
        let settingsProjected = await eventually {
            session.route?.route == .openSettings
        }
        let menuIngressSnapshot = runtime.hostIngressSnapshot
        let menuLedger = await runtime.callLedgerSnapshot().filter {
            $0.metadata.operationIdentifier.rawValue.contains("menu")
                || $0.metadata.operationIdentifier.rawValue.contains("ingress")
        }
        XCTAssertTrue(
            settingsProjected,
            "ingress=\(menuIngressSnapshot), menuLedger=\(menuLedger)"
        )
        let settingsRequest = try XCTUnwrap(session.route)

        session.consumeRoute(id: UUID())
        XCTAssertEqual(session.route, settingsRequest)
        session.consumeRoute(id: settingsRequest.id)
        XCTAssertNil(session.route)

        XCTAssertEqual(runtime.submit(.menu(.openCipherLibrary)), .accepted)
        let libraryProjected = await eventually {
            session.route?.route == .openCipherLibrary
        }
        XCTAssertTrue(libraryProjected)

        let cipherID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        session.requestRoute(.replyToMessage(cipherID: cipherID))
        XCTAssertEqual(session.route?.route, .replyToMessage(cipherID: cipherID))

        await session.stop()
        await runtime.stop()
    }

    func testStopClearsPresentationStateAndIgnoresLateStreamValues() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()

        service.yieldState(Self.fixtureSnapshot(revision: 1, plaintext: "Secret plaintext"))
        XCTAssertEqual(runtime.submit(.menu(.openSettings)), .accepted)
        let initialProjectionArrived = await eventually {
            session.snapshot?.revision == 1 && session.route?.route == .openSettings
        }
        XCTAssertTrue(initialProjectionArrived)

        session.requestRoute(
            .replyToMessage(
                cipherID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            )
        )
        await session.stop()

        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.pendingMessage)
        XCTAssertNil(session.route)
        XCTAssertNil(session.lastError)
        XCTAssertNil(session.importErrorMessage)
        XCTAssertNil(session.messageErrorMessage)

        service.yieldState(Self.fixtureSnapshot(revision: 2, plaintext: "Late plaintext"))
        XCTAssertEqual(runtime.submit(.menu(.openCipherLibrary)), .accepted)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.pendingMessage)
        XCTAssertNil(session.route)
        await session.stop()
        await runtime.stop()
    }

    func testAvailabilityProjectionAppliesRuntimeSnapshotsAndStopsObserving() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()

        let initialProjectionArrived = await eventually {
            session.availabilitySnapshot != nil
        }
        XCTAssertTrue(initialProjectionArrived)
        XCTAssertEqual(
            session.availabilitySnapshot?.entitlementSnapshot.includedUnlockIDs,
            [RuneScribeUnlockIDs.norseCodex]
        )
        XCTAssertEqual(
            session.availabilitySnapshot?.entitlementSnapshot.earnedUnlockIDs,
            []
        )

        let earnedUnlockID = UnlockID(rawValue: "unlock.codex.synthetic")!
        let updatedEntitlements = try ProgressionEntitlementSnapshotDTO(
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 1_000),
            includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
            earnedUnlockIDs: [earnedUnlockID]
        )
        try await runtime.reconcileEntitlements(updatedEntitlements)

        let updatedProjectionArrived = await eventually {
            session.availabilitySnapshot?.entitlementSnapshot.revision == 1
                && session.availabilitySnapshot?.entitlementSnapshot.earnedUnlockIDs
                    == [earnedUnlockID]
        }
        XCTAssertTrue(updatedProjectionArrived)

        await session.stop()
        XCTAssertNil(session.availabilitySnapshot)

        try await runtime.reconcileEntitlements(
            ProgressionEntitlementSnapshotDTO(
                revision: 2,
                capturedAt: Date(timeIntervalSince1970: 2_000),
                includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                earnedUnlockIDs: [
                    earnedUnlockID,
                    UnlockID(rawValue: "unlock.codex.late")!,
                ]
            )
        )
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(session.availabilitySnapshot)
        await runtime.stop()
    }

    func testStopReleasesClientWithoutTakingOwnershipFromRuntimeShareProvider() async throws {
        var service: ControllableApplicationService? = ControllableApplicationService()
        var shareOwner: LifetimeProbe? = LifetimeProbe()
        let weakService = WeakReference(service)
        let weakShareOwner = WeakReference(shareOwner)
        var shareProvider: SharePresentationProbe? = SharePresentationProbe(
            owner: try XCTUnwrap(shareOwner)
        )
        var session: RuneScribeUISession?
        var runtime: RuneScribeRuntime?

        do {
            let fixture = try await makeSession(
                applicationService: try XCTUnwrap(service),
                sharePresentation: try XCTUnwrap(shareProvider)
            )
            session = fixture.session
            runtime = fixture.runtime
        }
        try XCTUnwrap(session).start()

        service = nil
        shareOwner = nil
        shareProvider = nil
        XCTAssertNotNil(weakService.value)
        XCTAssertNotNil(weakShareOwner.value)

        await session?.stop()
        XCTAssertNotNil(
            weakShareOwner.value,
            "The runtime, rather than the stopped UI session, must own the provider"
        )
        XCTAssertNotNil(weakService.value)
        await runtime?.stop()
        session = nil
        runtime = nil
        let runtimeOwnersReleased = await eventually { weakShareOwner.value == nil }
        XCTAssertTrue(runtimeOwnersReleased)
    }

    func testModuleActivationToleratesMissingOptionalResourcesAndProgressionRails() async throws {
        let rootStore = RootViewPresentationStore()
        let applicationService = ControllableApplicationService()
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )

        try await runtime.register(
            manifest: TestCoreModule.manifest,
            factory: TestCoreModule.factory(applicationService: applicationService)
        )
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory()
        )
        try await runtime.installStandardPort(
            rootStore.runtimeHostAdapter(productMetadata: .unavailable),
            for: .standard
        )
        try await runtime.installPlatformAdapter(
            MissingApplicationResources(),
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            LifetimeClipboard(),
            for: RuneScribeServiceKeys.clipboardWrite
        )
        try await runtime.installPlatformAdapter(
            UnavailableInboundFileReader(),
            for: RuneScribeServiceKeys.inboundFileReader
        )
        try await runtime.installPlatformAdapter(
            SharePresentationProbe(),
            for: RuneScribeServiceKeys.sharePresentation
        )

        try await runtime.start()
        XCTAssertEqual(
            rootStore.state,
            .ready(moduleID: RuneScribeUIModuleBootstrap.moduleID)
        )
        let runningSnapshot = await runtime.snapshot()
        XCTAssertEqual(
            runningSnapshot.moduleStates[RuneScribeUIModuleBootstrap.moduleID],
            .active
        )
        XCTAssertNil(runningSnapshot.moduleStates[RuneScribeModuleIDs.progression])

        let (nilResourceSession, nilResourceRuntime) = try await makeSession(
            applicationService: ControllableApplicationService(),
            productMetadata: .unavailable
        )
        XCTAssertFalse(nilResourceSession.resourcePresentation.hasSplashVideo)
        await nilResourceSession.stop()
        await nilResourceRuntime.stop()

        await runtime.stop()
        XCTAssertEqual(rootStore.state, .booting)
    }

    func testUserTriggeredMutationFailuresRemainVisibleAndSanitized() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        let cipherID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let contactID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        )
        let contact = ContactViewState(
            id: contactID,
            displayName: "Failure Fixture",
            source: .manual
        )

        func assertSanitizedFailure(
            _ operation: () async throws -> Void,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                try await operation()
                XCTFail("Expected the mutation to fail", file: file, line: line)
            } catch {
                XCTAssertEqual(
                    session.lastError,
                    "Rune Scribe could not complete the operation.",
                    file: file,
                    line: line
                )
                XCTAssertFalse(
                    session.lastError?.contains(StubError.sensitiveFixtureDetail) ?? false,
                    file: file,
                    line: line
                )
            }
        }

        await assertSanitizedFailure {
            _ = try await session.renameCipher(id: cipherID, to: "Renamed")
        }
        await assertSanitizedFailure {
            try await session.deleteCipher(id: cipherID)
        }
        await assertSanitizedFailure {
            try await session.setActive(id: cipherID)
        }
        await assertSanitizedFailure {
            try await session.setContact(cipherID: cipherID, contactID: contactID)
        }
        await assertSanitizedFailure {
            _ = try await session.createContact(contact)
        }
        await assertSanitizedFailure {
            _ = try await session.updateContact(contact)
        }
        await assertSanitizedFailure {
            try await session.deleteContact(id: contactID)
        }
        await assertSanitizedFailure {
            try await session.deleteContacts(ids: [contactID])
        }
        await assertSanitizedFailure {
            try await session.deleteAllImportedContacts()
        }
        await assertSanitizedFailure {
            _ = try await session.importContacts([contact])
        }
        let completionContext = try RuntimePersistableOperationContext(
            operationID: "ui-session-share-completion",
            correlationID: "85500000-0000-0000-0000-000000000001",
            occurredAtUTC: Date(timeIntervalSince1970: 1_700_000_000),
            operationIdentifier: "io.share.presentation.complete",
            runtimeGeneration: 1,
            authorityNonce: UUID(
                uuidString: "85500000-0000-0000-0000-000000000002"
            )!,
            authorityTag: Data(repeating: 0x85, count: 32),
            authorityScope: .persistent
        )
        let completionEvidence = try ShareArtifactCompletionEvidenceDTO(
            artifactID: artifactID,
            report: SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .completedBySystem
            ),
            operationContext: completionContext
        )
        await assertSanitizedFailure {
            _ = try await session.completeShareArtifact(evidence: completionEvidence)
        }
        await session.stop()
        await runtime.stop()
    }

    func testMutationViewsDoNotDiscardThrowingSessionResults() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsDirectory = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
            .appendingPathComponent("Views", isDirectory: true)

        for filename in [
            "CipherLibraryView.swift",
            "ContactImportPicker.swift",
            "ContactsView.swift",
            "ContentView.swift",
        ] {
            let source = try String(
                contentsOf: viewsDirectory.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("try? await session."),
                "\(filename) must surface failures from throwing session operations"
            )
        }

        for filename in [
            "CipherLibraryView.swift",
            "ContactImportPicker.swift",
            "ContactsView.swift",
            "RootView.swift",
        ] {
            let source = try String(
                contentsOf: viewsDirectory.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertFalse(
                source.contains("error.localizedDescription"),
                "\(filename) must project unknown errors through RuneScribeUISession.message(for:)"
            )
        }
    }

    func testCipherCardActionsAdaptBeforeTheActivationLabelCompresses() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
                .appendingPathComponent("Views", isDirectory: true)
                .appendingPathComponent("CipherLibraryView.swift"),
            encoding: .utf8
        )

        let adaptiveLayout = try sourceSection(
            source,
            from: "    private func cipherCardActions(",
            to: "    private func cipherActivationButton("
        )
        XCTAssertTrue(adaptiveLayout.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(adaptiveLayout.contains("VStack(alignment: .leading"))
        XCTAssertTrue(adaptiveLayout.contains("cipherUtilityActions(cipher, spacing: 4)"))

        let activationButton = try sourceSection(
            source,
            from: "    private func cipherActivationButton(",
            to: "    private func cipherUtilityActions("
        )
        XCTAssertTrue(activationButton.contains(".lineLimit(1)"))
        XCTAssertTrue(
            activationButton.contains(".fixedSize(horizontal: true, vertical: false)")
        )
        XCTAssertTrue(
            activationButton.contains(".frame(minWidth: 44, minHeight: 44")
        )
    }

    func testCompactActionRowsAndPINFlowsRetainAdaptiveLayoutGuards() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsDirectory = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
            .appendingPathComponent("Views", isDirectory: true)

        func viewSource(_ filename: String) throws -> String {
            try String(
                contentsOf: viewsDirectory.appendingPathComponent(filename),
                encoding: .utf8
            )
        }

        let contentSource = try viewSource("ContentView.swift")
        let resultActions = try sourceSection(
            contentSource,
            from: "    private var resultEditCopyActions:",
            to: "    // MARK: - Active Cipher Bar"
        )
        XCTAssertGreaterThanOrEqual(
            resultActions.components(separatedBy: "ViewThatFits(in: .horizontal)").count - 1,
            2
        )
        XCTAssertTrue(resultActions.contains("resultEditButton(resistsCompression: true)"))
        XCTAssertTrue(resultActions.contains("resultEditButton(resistsCompression: false)"))
        XCTAssertTrue(resultActions.contains("resultShareButton(resistsCompression: true)"))
        XCTAssertTrue(resultActions.contains("resultShareButton(resistsCompression: false)"))
        XCTAssertGreaterThanOrEqual(
            resultActions.components(separatedBy: ".lineLimit(1)").count - 1,
            4
        )

        let activeCipherBar = try sourceSection(
            contentSource,
            from: "    private var activeCipherBar:",
            to: "    // MARK: - Compose Recipient"
        )
        XCTAssertTrue(activeCipherBar.contains(".truncationMode(.tail)"))
        XCTAssertTrue(
            activeCipherBar.contains(".frame(maxWidth: .infinity, minHeight: 44")
        )
        XCTAssertTrue(
            activeCipherBar.contains(".fixedSize(horizontal: true, vertical: false)")
        )
        XCTAssertFalse(
            activeCipherBar.contains(".contentShape(Rectangle())\n            .fixedSize()")
        )

        let cipherSource = try viewSource("CipherLibraryView.swift")
        let creationActions = try sourceSection(
            cipherSource,
            from: "    private var creationActions:",
            to: "    // MARK: - Cipher Card"
        )
        XCTAssertTrue(creationActions.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(creationActions.contains("newCipherButton(resistsCompression: true)"))
        XCTAssertTrue(creationActions.contains("newCipherButton(resistsCompression: false)"))
        XCTAssertTrue(creationActions.contains("importCipherButton(resistsCompression: true)"))
        XCTAssertTrue(creationActions.contains("importCipherButton(resistsCompression: false)"))

        let contactsSource = try viewSource("ContactsView.swift")
        let contactActions = try sourceSection(
            contactsSource,
            from: "    private var actionsBar:",
            to: "    private var emptyState:"
        )
        XCTAssertEqual(
            contactActions.components(separatedBy: "ViewThatFits(in: .horizontal)").count - 1,
            3
        )
        XCTAssertTrue(contactActions.contains("VStack(spacing: 8)"))
        XCTAssertTrue(contactActions.contains("removeSelectedButton(resistsCompression: true)"))
        XCTAssertTrue(contactActions.contains("removeSelectedButton(resistsCompression: false)"))
        XCTAssertGreaterThanOrEqual(
            contactActions.components(separatedBy: ".lineLimit(1)").count - 1,
            8
        )

        for filename in ["PINFlowView.swift", "LockView.swift"] {
            let source = try viewSource(filename)
            XCTAssertTrue(source.contains("GeometryReader { proxy in"), filename)
            XCTAssertTrue(source.contains("ScrollView {"), filename)
            XCTAssertTrue(
                source.contains(".frame(minHeight: proxy.size.height, alignment: .center)"),
                filename
            )
            XCTAssertTrue(source.contains(".scrollBounceBehavior(.basedOnSize)"), filename)
        }

        let buttonStyles = try viewSource("RuneScribButtonStyle.swift")
        XCTAssertGreaterThanOrEqual(
            buttonStyles.components(separatedBy: ".frame(minHeight: 46)").count - 1,
            2,
            "Both compact-row button styles must preserve at least 44-point targets"
        )
    }

    func testMessageArtifactCompletionGateAdmitsOneCompletionUntilFinished() {
        let first = ShareArtifactID(
            rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let second = ShareArtifactID(
            rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        var gate = MessageArtifactCompletionGate()

        XCTAssertTrue(gate.begin(for: first))
        XCTAssertTrue(gate.isCompleting(first))
        XCTAssertFalse(gate.begin(for: first), "A later delegate must not duplicate completion")
        XCTAssertFalse(gate.begin(for: second), "Only one artifact completion may be in flight")

        gate.finish(for: second)
        XCTAssertTrue(gate.isCompleting(first), "A mismatched callback must not release the gate")

        gate.finish(for: first)
        XCTAssertNil(gate.inFlightArtifactID)
        XCTAssertTrue(gate.begin(for: second), "A terminal completion must permit the next artifact")
    }

    func testSharePresentationForwardsRuntimeEvidenceAndPresentedIsNonterminal() async throws {
        let service = ControllableApplicationService(
            shareCompletionResult: .released
        )
        let fixture = try await makeSession(applicationService: service)
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "86000000-0000-0000-0000-000000000001")!
        )
        let transfer = try await fixture.session.shareTransfer(for: artifactID)

        try await transfer.reportPresented(on: .shareSheet)

        XCTAssertTrue(transfer.isAvailable)
        XCTAssertNil(transfer.completionEvidence)
        let commandsAfterPresentation = await service.recordedShareCompletionCommands()
        XCTAssertTrue(commandsAfterPresentation.isEmpty)
        let presentationObserved = await eventually {
            transfer.presentationReport?.result == .presented
        }
        XCTAssertTrue(presentationObserved)

        let report = try SharePresentationReportDTO(
            routeClass: .shareSheet,
            result: .completedBySystem
        )
        let evidence = try await transfer.finish(report)
        let completionResult = try await fixture.session.completeShareArtifact(
            evidence: evidence
        )

        XCTAssertEqual(completionResult, .released)
        XCTAssertFalse(transfer.isAvailable)
        XCTAssertEqual(transfer.completionEvidence, evidence)
        XCTAssertEqual(evidence.artifactID, artifactID)
        let commands = await service.recordedShareCompletionCommands()
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(commands.allSatisfy { $0.evidence == evidence })
        do {
            _ = try await transfer.finish(report)
            XCTFail("A completed transfer must reject a duplicate terminal callback")
        } catch {
            XCTAssertEqual(error as? OpaqueSharePresentationError, .revoked)
        }
        var commandsAfterDuplicate = await service.recordedShareCompletionCommands()
        for _ in 0 ..< 500 where commandsAfterDuplicate.count < 2 {
            try? await Task.sleep(for: .milliseconds(2))
            commandsAfterDuplicate = await service.recordedShareCompletionCommands()
        }
        XCTAssertEqual(
            commandsAfterDuplicate.count,
            2,
            "Immediate UI forwarding and durable Runtime replay must both arrive"
        )
        XCTAssertTrue(commandsAfterDuplicate.allSatisfy { $0.evidence == evidence })
        XCTAssertEqual(commandsAfterDuplicate.compactMap { $0.evidence?.operationContext }, [
            evidence.operationContext,
            evidence.operationContext,
        ])
        let logicalEffects = await service.recordedLogicalShareCompletionEffectCount()
        XCTAssertEqual(
            logicalEffects,
            1,
            "Identical transport replays must retain one logical terminal effect"
        )

        await fixture.session.stop()
        await fixture.runtime.stop()
    }

    func testPrepareMessageShareForwardsPerEncodeHandle() async throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "86100000-0000-0000-0000-000000000001")!
        )
        let artifact = ShareArtifactDTO(
            id: artifactID,
            reference: .opaque(artifactID),
            displayName: "Rune Scribe Message",
            contentType: "text/plain",
            fileExtension: nil,
            lifetime: .singleUse,
            requiresKeyDelivery: false
        )
        let service = ControllableApplicationService(
            preparedMessageArtifact: artifact
        )
        let fixture = try await makeSession(applicationService: service)
        let cipherID = UUID(uuidString: "86100000-0000-0000-0000-000000000002")!
        let handle = EncodedMessageHandle(
            rawValue: UUID(uuidString: "86100000-0000-0000-0000-000000000003")!
        )

        let prepared = try await fixture.session.prepareMessageShare(
            runes: "ᚱᚢᚾᛖ",
            senderName: "Freya",
            cipherID: cipherID,
            shareHandle: handle
        )

        XCTAssertEqual(prepared, artifact)
        let commands = await service.recordedPrepareMessageShareCommands()
        let command = try XCTUnwrap(commands.first)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(command.runes, "ᚱᚢᚾᛖ")
        XCTAssertEqual(command.senderName, "Freya")
        XCTAssertEqual(command.cipherID, CipherID(rawValue: cipherID))
        XCTAssertEqual(command.shareHandle, handle)

        await fixture.session.stop()
        await fixture.runtime.stop()
    }

    func testContentViewLockCleanupClearsSensitiveStateAndReleasesArtifactOnce() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
                .appendingPathComponent("Views", isDirectory: true)
                .appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )

        let lockCleanup = try sourceSection(
            source,
            from: "    private func dismissPresentedContentForLock() {",
            to: "    /// The Share button."
        )
        for requiredStatement in [
            "settleTask?.cancel()",
            "settleTask = nil",
            "inputText = \"\"",
            "sourceSnapshot = \"\"",
            "targetSnapshot = \"\"",
            "decodeError = nil",
            "copyConfirmed = false",
            "boxPhase = .editing",
            "showLibrary = false",
            "showSettings = false",
            "showMessageCompose = false",
            "showNewContact = false",
            "resetNewContact()",
            "releaseMessageArtifact()",
        ] {
            XCTAssertTrue(
                lockCleanup.contains(requiredStatement),
                "Lock cleanup must contain: \(requiredStatement)"
            )
        }
        XCTAssertFalse(lockCleanup.contains("beginMessageArtifactCompletion"))
        XCTAssertFalse(lockCleanup.contains("pendingMessageArtifact = nil"))

        let action = try sourceSection(
            source,
            from: "    private func performAction(generation: UInt64) async {",
            to: "    private func returnToEditing() {"
        )
        let finalCoreAwait = try XCTUnwrap(
            action.range(of: "session.prepareMessageShare", options: .backwards)
        )
        let postAwaitLockGuard = try XCTUnwrap(
            action.range(of: "guard !session.isLocked else")
        )
        let snapshotCommit = try XCTUnwrap(
            action.range(of: "sourceSnapshot = source")
        )
        XCTAssertLessThan(
            action.distance(from: action.startIndex, to: finalCoreAwait.lowerBound),
            action.distance(from: action.startIndex, to: postAwaitLockGuard.lowerBound),
            "The lock guard must run after the final suspended Core operation"
        )
        XCTAssertLessThan(
            action.distance(from: action.startIndex, to: postAwaitLockGuard.lowerBound),
            action.distance(from: action.startIndex, to: snapshotCommit.lowerBound),
            "A resumed action must not repopulate plaintext after lock cleanup"
        )
        XCTAssertTrue(action.contains("dismissPresentedContentForLock()"))
        XCTAssertTrue(action.contains("actionGeneration == generation"))
        XCTAssertTrue(action.contains("!Task.isCancelled"))
        XCTAssertTrue(action.contains("await session.releaseShareArtifact(id: preparedArtifact.id)"))
        XCTAssertLessThan(
            action.distance(
                from: action.startIndex,
                to: try XCTUnwrap(action.range(of: "var preparedArtifact")).lowerBound
            ),
            action.distance(
                from: action.startIndex,
                to: try XCTUnwrap(action.range(of: "pendingMessageArtifact = preparedArtifact")).lowerBound
            ),
            "A prepared artifact must remain local until the action generation commits"
        )

        let beginAction = try sourceSection(
            source,
            from: "    private func beginAction() {",
            to: "    private func performAction(generation: UInt64) async {"
        )
        XCTAssertTrue(beginAction.contains("guard actionTask == nil else"))
        XCTAssertTrue(beginAction.contains("let generation = actionGeneration"))

        XCTAssertTrue(lockCleanup.contains("actionGeneration &+= 1"))
        XCTAssertTrue(lockCleanup.contains("actionTask?.cancel()"))

        let beginCompletion = try sourceSection(
            source,
            from: "    private func beginMessageArtifactCompletion(",
            to: "    private func completePreparedArtifact("
        )
        XCTAssertTrue(beginCompletion.contains("pendingMessageArtifact"))
        XCTAssertTrue(
            beginCompletion.contains(
                "messageArtifactCompletionGate.begin(for: evidence.artifactID)"
            )
        )
        XCTAssertTrue(
            beginCompletion.contains(
                "completePreparedArtifact(artifact: artifact, evidence: evidence)"
            )
        )

        let completion = try sourceSection(
            source,
            from: "    private func completePreparedArtifact(",
            to: "    private func selectActiveCipher("
        )
        let coreCompletion = try XCTUnwrap(
            completion.range(of: "try await session.completeShareArtifact")
        )
        let referenceClear = try XCTUnwrap(
            completion.range(of: "pendingMessageArtifact = nil")
        )
        XCTAssertLessThan(
            completion.distance(from: completion.startIndex, to: coreCompletion.lowerBound),
            completion.distance(from: completion.startIndex, to: referenceClear.lowerBound),
            "The UI must retain the artifact reference until Core cancellation completes"
        )

        let messageFinished = try sourceSection(
            source,
            from: "    private func handleMessageFinished(",
            to: "    #endif"
        )
        let hidesComposer = try XCTUnwrap(
            messageFinished.range(of: "showMessageCompose = false")
        )
        let beginsCompletion = try XCTUnwrap(
            messageFinished.range(of: "handleShareCompletion(completion)")
        )
        XCTAssertLessThan(
            messageFinished.distance(from: messageFinished.startIndex, to: hidesComposer.lowerBound),
            messageFinished.distance(from: messageFinished.startIndex, to: beginsCompletion.lowerBound)
        )

        let normalRelease = String(
            source[try XCTUnwrap(
                source.range(of: "    private func releaseMessageArtifact() {")
            ).lowerBound...]
        )
        XCTAssertTrue(
            normalRelease.contains("messageArtifactCompletionGate.isCompleting(artifact.id)")
        )

        let returnToEditing = try sourceSection(
            source,
            from: "    private func returnToEditing() {",
            to: "    /// Wipes the composer back to a pristine"
        )
        for preservedStatement in [
            "settleTask?.cancel()",
            "releaseMessageArtifact()",
            "copyConfirmed = false",
            "boxPhase = .editing",
        ] {
            XCTAssertTrue(
                returnToEditing.contains(preservedStatement),
                "Edit behavior must retain: \(preservedStatement)"
            )
        }

        let reset = try sourceSection(
            source,
            from: "    private func reset() {",
            to: "    private var copyButtonTitle: String {"
        )
        for preservedStatement in [
            "settleTask?.cancel()",
            "inputText = \"\"",
            "sourceSnapshot = \"\"",
            "targetSnapshot = \"\"",
            "releaseMessageArtifact()",
            "copyConfirmed = false",
            "decodeError = nil",
            "boxPhase = .editing",
        ] {
            XCTAssertTrue(
                reset.contains(preservedStatement),
                "Reset behavior must retain: \(preservedStatement)"
            )
        }
    }

    func testContentViewRepreparesWithSameHandleAfterEveryTerminalLease() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
                .appendingPathComponent("Views", isDirectory: true)
                .appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )

        let action = try sourceSection(
            source,
            from: "    private func performAction(generation: UInt64) async {",
            to: "    private func returnToEditing() {"
        )
        XCTAssertTrue(action.contains("guard let shareHandle = result.shareHandle"))
        XCTAssertTrue(action.contains("shareHandle: share.shareHandle"))
        XCTAssertTrue(action.contains("messageSharePreparation = preparedShare"))

        let terminalFailure = try sourceSection(
            source,
            from: "    private func recoverMessageArtifactAfterTerminalFailure(",
            to: "    private func beginMessageArtifactCompletion("
        )
        XCTAssertTrue(terminalFailure.contains("session.releaseShareArtifact(id: artifact.id)"))
        XCTAssertTrue(
            terminalFailure.contains("prepareReplacementMessageArtifact(using: preparation)")
        )

        let completion = try sourceSection(
            source,
            from: "    private func completePreparedArtifact(",
            to: "    private func prepareReplacementMessageArtifact("
        )
        XCTAssertTrue(completion.contains("session.completeShareArtifact(evidence: evidence)"))
        XCTAssertTrue(completion.contains("pendingMessageArtifact = nil"))
        XCTAssertTrue(completion.contains("prepareReplacementMessageArtifact(using: preparation)"))
        XCTAssertFalse(completion.contains("retainedForRetry"))

        let replacement = try sourceSection(
            source,
            from: "    private func prepareReplacementMessageArtifact(",
            to: "    private func selectActiveCipher("
        )
        XCTAssertTrue(replacement.contains("shareHandle: preparation.shareHandle"))
        XCTAssertTrue(replacement.contains("session.shareTransfer(for: preparedArtifact.id)"))
        XCTAssertTrue(replacement.contains("artifactID: preparedArtifact.id"))
        XCTAssertTrue(replacement.contains("pendingMessageArtifact = artifact"))
        XCTAssertTrue(replacement.contains("pendingMessageTransfer = transfer"))
    }

    #if os(macOS)
    func testRepresentativeUserFacingViewsRenderForParityInspection() async throws {
        let service = ControllableApplicationService()
        let (session, runtime) = try await makeSession(applicationService: service)
        try session.start()
        service.yieldState(
            Self.fixtureSnapshot(
                revision: 40,
                plaintext: "Synthetic parity message",
                includeFailures: false
            )
        )
        let snapshotArrived = await eventually { session.snapshot?.revision == 40 }
        XCTAssertTrue(snapshotArrived)

        let pendingImportID = try XCTUnwrap(
            UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")
        )
        let pendingImport = PendingImportSummary(
            id: ImportID(rawValue: pendingImportID),
            suggestedName: "Shared Cipher",
            source: .link,
            includesFont: true
        )
        let pendingMessage = try XCTUnwrap(session.pendingMessage)
        let qrArtifactID = try XCTUnwrap(
            UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")
        )
        let qrTransfer = try await session.shareTransfer(
            for: ShareArtifactID(rawValue: qrArtifactID)
        )
        let views: [(String, AnyView, CGSize)] = [
            (
                "workspace",
                AnyView(
                    ContentView()
                        .environmentObject(session)
                        .environment(\.runtimeApplicationResourcePresentation, nil)
                ),
                CGSize(width: 600, height: 720)
            ),
            (
                "lock",
                AnyView(LockView().environmentObject(session)),
                CGSize(width: 600, height: 720)
            ),
            (
                "cipher-library",
                AnyView(CipherLibraryView().environmentObject(session)),
                CGSize(width: 600, height: 720)
            ),
            (
                "contacts",
                AnyView(ContactsView().environmentObject(session)),
                CGSize(width: 600, height: 720)
            ),
            (
                "settings",
                AnyView(SettingsView().environmentObject(session)),
                CGSize(width: 600, height: 720)
            ),
            (
                "pin-flow",
                AnyView(PINFlowView(mode: .change).environmentObject(session)),
                CGSize(width: 600, height: 720)
            ),
            (
                "import-confirmation",
                AnyView(
                    ImportConfirmView(
                        pending: pendingImport,
                        confirmImport: { _ in throw StubError.unexpectedCommand }
                    )
                ),
                CGSize(width: 600, height: 720)
            ),
            (
                "received-message",
                AnyView(ReceivedMessageView(pending: pendingMessage)),
                CGSize(width: 600, height: 720)
            ),
            (
                "qr-share",
                AnyView(QRDisplaySheet(transfer: qrTransfer, label: "Freya")),
                CGSize(width: 600, height: 720)
            ),
            (
                "license",
                AnyView(LicenseView()),
                CGSize(width: 600, height: 720)
            ),
        ]

        for (name, view, size) in views {
            let pngData = try renderPNG(view, size: size)
            XCTAssertGreaterThan(pngData.count, 10_000, "\(name) did not render meaningful output")
            try writeParityArtifactIfRequested(pngData, name: name)
        }

        await session.stop()
        await runtime.stop()
    }
    #endif

    private func makeSession(
        applicationService: ControllableApplicationService,
        runtimeIO: RuntimeIOClient? = nil,
        sharePresentation: any SharePresentationProviding = SharePresentationProbe(),
        resourcePresentation: RuntimeApplicationResourcePresentation? = nil,
        productMetadata: RuneScribeUIProductMetadata = .init(
            version: "1.0",
            buildNumber: "1"
        )
    ) async throws -> (session: RuneScribeUISession, runtime: RuneScribeRuntime) {
        let harness = try await makeApplicationClientHarness(
            applicationService: applicationService,
            sharePresentation: sharePresentation
        )
        let session = RuneScribeUISession(
            applicationClient: harness.client,
            runtimeIO: runtimeIO ?? harness.runtimeIO,
            availabilityClient: harness.availabilityClient,
            resourcePresentation: resourcePresentation
                ?? RuntimeApplicationResourcePresentation(
                    splashVideo: nil,
                    metalLibrary: nil
                ),
            productMetadata: productMetadata
        )
        return (session, harness.runtime)
    }

    private func makeApplicationClientHarness(
        applicationService: ControllableApplicationService,
        startCoordinator: (any RuntimeStartCoordinating)? = nil,
        sharePresentation: any SharePresentationProviding = SharePresentationProbe()
    ) async throws -> (
        client: RuntimeApplicationClient,
        runtimeIO: RuntimeIOClient,
        availabilityClient: RuntimeAvailabilityClient,
        runtime: RuneScribeRuntime,
        capture: ApplicationClientCapture
    ) {
        let capture = ApplicationClientCapture()
        let runtime: RuneScribeRuntime
        if let startCoordinator {
            runtime = RuneScribeRuntime(
                runtimeVersion: TestCoreModule.moduleVersion,
                platform: .macOS,
                startCoordinator: startCoordinator
            )
        } else {
            runtime = RuneScribeRuntime(
                runtimeVersion: TestCoreModule.moduleVersion,
                platform: .macOS
            )
        }
        try await runtime.installPlatformAdapter(
            sharePresentation,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.installPlatformAdapter(
            InMemoryModuleStateStore(),
            for: RuneScribeServiceKeys.moduleStateStore
        )
        try await runtime.register(
            manifest: TestCoreModule.manifest,
            factory: TestCoreModule.factory(applicationService: applicationService)
        )
        try await runtime.register(
            manifest: TestApplicationClientModule.manifest,
            factory: TestApplicationClientModule.factory(capture: capture)
        )
        try await runtime.start()
        return (
            try await capture.requireClient(),
            try await capture.requireRuntimeIOClient(),
            try await capture.requireAvailabilityClient(),
            runtime,
            capture
        )
    }

    private func sourceSection(
        _ source: String,
        from startMarker: String,
        to endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker))
        let end = try XCTUnwrap(
            source.range(of: endMarker, range: start.upperBound..<source.endIndex)
        )
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<500 {
            if predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return predicate()
    }

    #if os(macOS)
    private func renderPNG(_ view: AnyView, size: CGSize) throws -> Data {
        let hostingView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    #endif

    private func writeParityArtifactIfRequested(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["RUNESCRIBE_PARITY_ARTIFACT_DIR"] else {
            return
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try data.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }

    private static func fixtureSnapshot(
        revision: UInt64,
        plaintext: String?,
        includeFailures: Bool = true
    ) -> RuneScribeApplicationSnapshot {
        let cipherID = CipherID(
            rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let contactID = ContactID(
            rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let fontID = FontID(rawValue: "elder-runes")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cipher = CipherSummary(
            id: cipherID,
            name: "Freya",
            origin: .generated,
            createdAt: createdAt,
            isActive: true,
            assignedContactID: contactID,
            hasBeenDelivered: true,
            publicIdentifier: "ABCDEF1234567890",
            fontID: fontID
        )
        let contact = ContactSummary(
            id: contactID,
            displayName: "Freya Day",
            phoneNumbers: ["+15550001"],
            emailAddresses: ["freya@example.com"],
            source: .imported,
            createdAt: createdAt,
            linkedCipherCount: 1
        )
        let message = plaintext.map {
            ReceivedMessageDTO(
                id: MessageID(
                    rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
                ),
                plaintext: $0,
                senderName: "Freya",
                cipherID: cipherID,
                cipherName: "Freya"
            )
        }
        return RuneScribeApplicationSnapshot(
            revision: revision,
            capturedAt: createdAt,
            cipherLibrary: CipherLibraryStateDTO(
                ciphers: [cipher],
                activeCipherID: cipherID
            ),
            contactLibrary: ContactLibraryStateDTO(
                contacts: [contact],
                importedCount: 1,
                authorization: .authorized
            ),
            fonts: [
                FontSummary(
                    id: fontID,
                    displayName: "Elder Runes",
                    version: 1,
                    contentHash: "fixture-hash",
                    source: .bundled,
                    isRegistered: true
                ),
            ],
            importState: ImportStateDTO(
                phase: includeFailures ? .failed : .idle,
                lastFailure: includeFailures
                    ? RuneScribeFailureDTO(code: .invalidInput)
                    : nil
            ),
            messageState: MessageStateDTO(
                phase: message == nil ? .idle : (includeFailures ? .failed : .received),
                pendingMessage: message,
                lastFailure: includeFailures
                    ? RuneScribeFailureDTO(code: .noMatchingCipher)
                    : nil
            ),
            lockState: ApplicationLockStateDTO(isPINSet: true, isLocked: false),
            lastFailure: includeFailures
                ? RuneScribeFailureDTO(code: .resourceUnavailable)
                : nil
        )
    }

    private static func fixtureCipherViewState(label: String) -> CipherViewState {
        CipherViewState(
            id: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            label: label,
            origin: .imported,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            isActive: true,
            contactID: nil,
            delivered: false,
            publicIdentifier: "1234567890ABCDEF",
            fontName: "Elder Runes"
        )
    }
}

private enum StubError: LocalizedError {
    case unexpectedCommand

    static let sensitiveFixtureDetail = "sensitive-fixture-detail-must-not-be-presented"

    var errorDescription: String? {
        Self.sensitiveFixtureDetail
    }
}

private actor LifetimeProbe {}

private actor SharePresentationProbe: SharePresentationProviding {
    private let owner: LifetimeProbe?
    private let url: URL
    private var requestedArtifactIDs: [ShareArtifactID] = []

    init(
        owner: LifetimeProbe? = nil,
        url: URL = URL(fileURLWithPath: "/fixture/share.runescribe")
    ) {
        self.owner = owner
        self.url = url
    }

    func presentationURL(for artifactID: ShareArtifactID) async throws -> URL {
        _ = owner
        requestedArtifactIDs.append(artifactID)
        return url
    }

    func requests() -> [ShareArtifactID] {
        requestedArtifactIDs
    }
}

private actor ClipboardWriteCapture {
    private var recordedValues: [String] = []

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func values() -> [String] {
        recordedValues
    }
}

private actor InboundReceiveGate {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendIfNeeded() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RuntimeQuiesceGate: RuntimeStartCoordinating {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func beforeInfrastructureActivation() async {}

    func afterClientQuiesceBeforeIngressDrain() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor IngressFailureCapture {
    private var failures: [RuntimeHostIngressFailure] = []

    func record(_ failure: RuntimeHostIngressFailure) {
        failures.append(failure)
    }

    func last() -> RuntimeHostIngressFailure? {
        failures.last
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private actor LifetimeClipboard: ClipboardWriting {
    func setString(_ value: String) async throws {}
}

private actor ControllableApplicationService:
    RuneScribeApplicationService,
    RuneScribeInboundInputService
{
    private let createdCipher: CipherSummary?
    private let systemContacts: [SystemContactDTO]?
    private let inboundGate: InboundReceiveGate?
    private let shareCompletionResult: ShareArtifactCompletionResultDTO?
    private let preparedMessageArtifact: ShareArtifactDTO?
    private var shareCompletionCommands: [CompleteShareArtifactCommand] = []
    private var logicalShareCompletionEvidence: [
        ShareArtifactID: ShareArtifactCompletionEvidenceDTO
    ] = [:]
    private var prepareMessageShareCommands: [PrepareMessageShareCommand] = []
    nonisolated let states: AsyncStream<RuneScribeApplicationSnapshot>
    nonisolated let stateContinuation: AsyncStream<RuneScribeApplicationSnapshot>.Continuation

    init(
        createdCipher: CipherSummary? = nil,
        systemContacts: [SystemContactDTO]? = nil,
        inboundGate: InboundReceiveGate? = nil,
        shareCompletionResult: ShareArtifactCompletionResultDTO? = nil,
        preparedMessageArtifact: ShareArtifactDTO? = nil
    ) {
        self.createdCipher = createdCipher
        self.systemContacts = systemContacts
        self.inboundGate = inboundGate
        self.shareCompletionResult = shareCompletionResult
        self.preparedMessageArtifact = preparedMessageArtifact
        let stateChannel = AsyncStream.makeStream(
            of: RuneScribeApplicationSnapshot.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        states = stateChannel.stream
        stateContinuation = stateChannel.continuation
    }

    nonisolated func yieldState(_ snapshot: RuneScribeApplicationSnapshot) {
        stateContinuation.yield(snapshot)
    }

    nonisolated func stateStream() -> AsyncStream<RuneScribeApplicationSnapshot> {
        states
    }

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        switch input {
        case .menu:
            await inboundGate?.suspendIfNeeded()
            return .accepted
        case .file, .url, .lifecycle:
            return .rejected
        }
    }

    func encode(_ command: EncodeMessageCommand) async throws -> EncodedMessageResult {
        throw StubError.unexpectedCommand
    }

    func decode(_ command: DecodeMessageCommand) async throws -> DecodedMessageResult {
        throw StubError.unexpectedCommand
    }

    func createCipher(_ command: CreateCipherCommand) async throws -> CipherSummary {
        if let createdCipher { return createdCipher }
        throw StubError.unexpectedCommand
    }

    func renameCipher(_ command: RenameCipherCommand) async throws -> CipherSummary {
        throw StubError.unexpectedCommand
    }

    func deleteCipher(id: CipherID) async throws {
        throw StubError.unexpectedCommand
    }

    func setActiveCipher(_ command: SetActiveCipherCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func assignContact(_ command: AssignContactCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func createContact(_ command: CreateContactCommand) async throws -> ContactSummary {
        throw StubError.unexpectedCommand
    }

    func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary {
        throw StubError.unexpectedCommand
    }

    func deleteContacts(ids: Set<ContactID>) async throws {
        throw StubError.unexpectedCommand
    }

    func deleteAllImportedContacts() async throws {
        throw StubError.unexpectedCommand
    }

    func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary] {
        throw StubError.unexpectedCommand
    }

    func requestSystemContacts() async throws -> [SystemContactDTO] {
        if let systemContacts { return systemContacts }
        throw StubError.unexpectedCommand
    }

    func prepareCipherShare(
        _ command: PrepareCipherShareCommand
    ) async throws -> ShareArtifactDTO {
        throw StubError.unexpectedCommand
    }

    func prepareMessageShare(
        _ command: PrepareMessageShareCommand
    ) async throws -> ShareArtifactDTO {
        prepareMessageShareCommands.append(command)
        if let preparedMessageArtifact { return preparedMessageArtifact }
        throw StubError.unexpectedCommand
    }

    func recordedPrepareMessageShareCommands() -> [PrepareMessageShareCommand] {
        prepareMessageShareCommands
    }

    func completeShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        shareCompletionCommands.append(command)
        guard let evidence = command.evidence else { throw StubError.unexpectedCommand }
        if let existing = logicalShareCompletionEvidence[evidence.artifactID] {
            guard existing == evidence else { throw StubError.unexpectedCommand }
        } else {
            logicalShareCompletionEvidence[evidence.artifactID] = evidence
        }
        if let shareCompletionResult { return shareCompletionResult }
        throw StubError.unexpectedCommand
    }

    func recordedShareCompletionCommands() -> [CompleteShareArtifactCommand] {
        shareCompletionCommands
    }

    func recordedLogicalShareCompletionEffectCount() -> Int {
        logicalShareCompletionEvidence.count
    }

    func releaseShareArtifact(id: ShareArtifactID) async {}

    func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO {
        throw StubError.unexpectedCommand
    }

    func importURL(_ input: InboundURLDTO) async throws -> ImportResultDTO {
        throw StubError.unexpectedCommand
    }

    func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary {
        throw StubError.unexpectedCommand
    }

    func cancelImport(id: ImportID) async {}

    func dismissReceivedMessage(id: MessageID) async {}

    func lock() async {}

    func verifyPIN(_ input: PINInput) async throws -> Bool {
        throw StubError.unexpectedCommand
    }

    func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO {
        throw StubError.unexpectedCommand
    }

    func setPIN(_ command: SetPINCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func changePIN(_ command: ChangePINCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func disablePIN(_ command: DisablePINCommand) async throws {
        throw StubError.unexpectedCommand
    }
}

private enum MissingResourceError: Error {
    case unavailable
}

private struct UnavailableInboundFileReader: InboundFileReader {
    func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        throw InboundFileReaderError.unavailable
    }
}

private struct MissingApplicationResources: ApplicationResourceLocator {
    func data(for resource: ApplicationResource) async throws -> Data {
        throw MissingResourceError.unavailable
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        throw MissingResourceError.unavailable
    }
}

private enum TestCoreModule {
    static let moduleID: ModuleIdentifier = "com.runescribe.test.core"
    static let moduleVersion = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: moduleVersion,
        kind: .service,
        entryPoint: "RuneScribeTestCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.inboundInput],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
            RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
    )
    static let manifest = ModuleManifest(
        runtimeVersion: moduleVersion,
        moduleID: moduleID,
        displayName: "Rune Scribe Test Core",
        moduleVersion: moduleVersion,
        moduleType: .service,
        criticality: descriptor.criticality,
        supportedPlatforms: [.iOS, .macOS],
        capabilitiesRequested: [RuneScribeCapabilities.inboundInput],
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(),
        defaultRole: RuneScribeRoles.core,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )

    static func factory(
        applicationService: ControllableApplicationService
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            ApplicationPublishingModule(applicationService: applicationService)
        }
    }
}

private struct ApplicationPublishingModule: RuneScribeModule {
    let descriptor = TestCoreModule.descriptor
    let applicationService: ControllableApplicationService

    func start(context: ModuleContext) async throws {
        try await context.registerApplicationEndpoints(applicationService)
        try await context.registerInboundInputEndpoint(applicationService)
    }

    func stop() async {}
}

private enum TestApplicationClientModule {
    static let moduleID: ModuleIdentifier = "com.runescribe.test.ui-client"
    static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: TestCoreModule.moduleVersion,
        kind: .ui,
        entryPoint: "RuneScribeTestApplicationClientModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
            RuneScribeCapabilities.runtimeAvailabilityRead,
        ],
        requiredServices: [RuneScribeServiceIDs.sharePresentation],
        requiredModuleRoles: [RuneScribeRoles.core],
        consumedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs
    )
    static let manifest = ModuleManifest(
        runtimeVersion: TestCoreModule.moduleVersion,
        moduleID: moduleID,
        displayName: "Rune Scribe Test Application Client",
        moduleVersion: TestCoreModule.moduleVersion,
        moduleType: .ui,
        criticality: descriptor.criticality,
        supportedPlatforms: [.iOS, .macOS],
        capabilitiesRequested: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
            RuneScribeCapabilities.runtimeAvailabilityRead,
        ],
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: [RuneScribeServiceIDs.sharePresentation],
            requiredModuleRoles: [RuneScribeRoles.core]
        ),
        defaultRole: RuneScribeRoles.primaryUI,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )

    static func factory(capture: ApplicationClientCapture) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            ApplicationClientModule(capture: capture)
        }
    }
}

private actor ApplicationClientCapture {
    typealias ClientFactory = @Sendable () async throws -> RuntimeApplicationClient

    private var client: RuntimeApplicationClient?
    private var runtimeIOClient: RuntimeIOClient?
    private var availabilityClient: RuntimeAvailabilityClient?
    private var clientFactory: ClientFactory?

    func store(
        _ client: RuntimeApplicationClient,
        runtimeIOClient: RuntimeIOClient,
        availabilityClient: RuntimeAvailabilityClient,
        clientFactory: @escaping ClientFactory
    ) {
        self.client = client
        self.runtimeIOClient = runtimeIOClient
        self.availabilityClient = availabilityClient
        self.clientFactory = clientFactory
    }

    func requireClient() throws -> RuntimeApplicationClient {
        guard let client else { throw StubError.unexpectedCommand }
        return client
    }

    func requireRuntimeIOClient() throws -> RuntimeIOClient {
        guard let runtimeIOClient else { throw StubError.unexpectedCommand }
        return runtimeIOClient
    }

    func requireAvailabilityClient() throws -> RuntimeAvailabilityClient {
        guard let availabilityClient else { throw StubError.unexpectedCommand }
        return availabilityClient
    }

    func makeClient() async throws -> RuntimeApplicationClient {
        guard let clientFactory else { throw StubError.unexpectedCommand }
        return try await clientFactory()
    }
}

private struct ApplicationClientModule: RuneScribeModule {
    let descriptor = TestApplicationClientModule.descriptor
    let capture: ApplicationClientCapture

    func start(context: ModuleContext) async throws {
        let client = try await context.applicationClient()
        let runtimeIOClient = try await context.runtimeIOClient()
        let availabilityClient = try await context.runtimeAvailabilityClient()
        await capture.store(
            client,
            runtimeIOClient: runtimeIOClient,
            availabilityClient: availabilityClient,
            clientFactory: { try await context.applicationClient() }
        )
    }

    func stop() async {}
}
