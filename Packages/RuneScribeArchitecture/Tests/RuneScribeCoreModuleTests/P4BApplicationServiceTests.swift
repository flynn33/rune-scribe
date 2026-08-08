import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import XCTest

final class P4BApplicationServiceTests: XCTestCase {
    func testMessageShareCoreOwnsFirstDeliveryAndArtifactCleanup() async throws {
        let secure = P4BSecureStore()
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: secure,
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Sender"))
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipher.id,
                contactID: ContactID(rawValue: UUID())
            )
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "rendezvous", cipherID: cipher.id)
        )

        let cancelled = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Untrusted Caller Name",
                cipherID: cipher.id
            )
        )
        guard case .file = cancelled.reference else {
            return XCTFail("First delivery must be a scoped file")
        }
        XCTAssertTrue(cancelled.requiresKeyDelivery)
        let firstData = await artifacts.createdData(id: cancelled.id)
        let firstBytes = try XCTUnwrap(firstData)
        let decodedFile = try MessageSharePayload.decodeFile(firstBytes)
        let decodedFirst = decodedFile.0
        XCTAssertNil(decodedFile.fontBytes)
        XCTAssertEqual(decodedFirst.senderName, "Untrusted Caller Name")
        let embedded = try XCTUnwrap(decodedFirst.embeddedCipher)
        let dtoBytes = try JSONEncoder().encode(cancelled)
        XCTAssertFalse(dtoBytes.contains(embedded.keyMaterial))
        XCTAssertFalse(
            String(decoding: dtoBytes, as: UTF8.self)
                .contains(embedded.keyMaterial.base64EncodedString())
        )

        let cancelledCompletion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(
                artifactID: cancelled.id,
                outcome: .cancelled
            )
        )
        XCTAssertEqual(cancelledCompletion, .released)
        let cancelledRemoved = await artifacts.wasRemoved(id: cancelled.id)
        XCTAssertTrue(cancelledRemoved)
        let afterCancellation = try await summary(id: cipher.id, from: service)
        XCTAssertFalse(afterCancellation.hasBeenDelivered)

        let delivered = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Ignored",
                cipherID: cipher.id
            )
        )
        let deliveredCompletion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(
                artifactID: delivered.id,
                outcome: .handedOff
            )
        )
        XCTAssertEqual(deliveredCompletion, .deliveryRecorded)
        let afterDelivery = try await summary(id: cipher.id, from: service)
        XCTAssertTrue(afterDelivery.hasBeenDelivered)

        let followup = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Ignored",
                cipherID: cipher.id
            )
        )
        XCTAssertEqual(followup.reference, .opaque(followup.id))
        XCTAssertFalse(followup.requiresKeyDelivery)
        let followupCompletion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(
                artifactID: followup.id,
                outcome: .messageSent(requiredAttachmentAccepted: false)
            )
        )
        XCTAssertEqual(followupCompletion, .released)
    }

    func testUnlinkedMessageNeverRequiresKeyDeliveryOrRecordsDelivery() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Unlinked"))
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "no bootstrap target", cipherID: cipher.id)
        )

        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Unlinked",
                cipherID: cipher.id
            )
        )

        XCTAssertEqual(artifact.reference, .opaque(artifact.id))
        XCTAssertFalse(artifact.requiresKeyDelivery)
        let storedBytes = await artifacts.createdData(id: artifact.id)
        XCTAssertNil(storedBytes)
        let completion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(
                artifactID: artifact.id,
                outcome: .handedOff
            )
        )
        XCTAssertEqual(completion, .released)
        let afterShare = try await summary(id: cipher.id, from: service)
        XCTAssertFalse(afterShare.hasBeenDelivered)
    }

    func testCustomFontBytesAppearOnlyInRequiredFirstDeliveryFile() async throws {
        let artifacts = P4BShareStore()
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore(),
            artifacts: artifacts,
            registrar: P4BSuccessfulFontRegistrar()
        )
        await service.startInboundProcessing()

        let fontBytes = Data("outbound-custom-font".utf8)
        let generated = Cipher.generated(label: "Custom Font Sender")
        let custom = Cipher(
            id: generated.id,
            label: generated.label,
            origin: generated.origin,
            createdAt: generated.createdAt,
            formatVersion: generated.formatVersion,
            publicID: generated.publicID,
            keyMaterial: generated.keyMaterial,
            decorativeMapping: generated.decorativeMapping,
            fontRef: FontRef(
                id: "outbound-font",
                version: 1,
                sha256: Data(SHA256.hash(data: fontBytes))
            )
        )
        let fileURL = try temporaryFile(
            containing: try CipherSharePayload(cipher: custom)
                .encodedFile(fontBytes: fontBytes)
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let imported = try await service.importFile(inboundFile(fileURL))
        let pending = try XCTUnwrap(imported.pendingImport)
        let cipher = try await service.confirmImport(
            ConfirmImportCommand(importID: pending.id, name: "Custom Font Sender")
        )
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipher.id,
                contactID: ContactID(rawValue: UUID())
            )
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "font bootstrap", cipherID: cipher.id)
        )

        let first = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Custom Font Sender",
                cipherID: cipher.id
            )
        )
        XCTAssertTrue(first.requiresKeyDelivery)
        let storedFirst = await artifacts.createdData(id: first.id)
        let firstBytes = try XCTUnwrap(storedFirst)
        let decodedFirst = try MessageSharePayload.decodeFile(firstBytes)
        XCTAssertEqual(decodedFirst.fontBytes, fontBytes)
        _ = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(artifactID: first.id, outcome: .handedOff)
        )

        let followup = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Custom Font Sender",
                cipherID: cipher.id
            )
        )
        XCTAssertEqual(followup.reference, .opaque(followup.id))
        XCTAssertFalse(followup.requiresKeyDelivery)
        let storedFollowup = await artifacts.createdData(id: followup.id)
        XCTAssertNil(storedFollowup)
    }

    func testRejectedRequiredAttachmentNeverRecordsDelivery() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Sender"))
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipher.id,
                contactID: ContactID(rawValue: UUID())
            )
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "message", cipherID: cipher.id)
        )
        let artifact = try await service.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Sender",
                cipherID: cipher.id
            )
        )

        let completion = try await service.completeShareArtifact(
            CompleteShareArtifactCommand(
                artifactID: artifact.id,
                outcome: .messageSent(requiredAttachmentAccepted: false)
            )
        )
        XCTAssertEqual(completion, .released)
        let summary = try await summary(id: cipher.id, from: service)
        XCTAssertFalse(summary.hasBeenDelivered)
        let removed = await artifacts.wasRemoved(id: artifact.id)
        XCTAssertTrue(removed)
    }

    func testCipherLinkAndQRRemainWireCompatibleAndEphemeral() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Link Fixture"))

        for representation in [ShareRepresentationDTO.link, .qrCode] {
            let artifact = try await service.prepareCipherShare(
                PrepareCipherShareCommand(
                    cipherID: cipher.id,
                    displayName: "Recipient Name",
                    representation: representation
                )
            )
            XCTAssertEqual(artifact.reference, .opaque(artifact.id))
            let storedURL = await artifacts.storedLink(id: artifact.id)
            let url = try XCTUnwrap(storedURL)
            let payload = try CipherSharePayload(url: url)
            XCTAssertEqual(payload.parsedName, "Recipient Name")
            XCTAssertEqual(try payload.encoded().count, CipherSharePayload.byteCount)
            let completion = try await service.completeShareArtifact(
                CompleteShareArtifactCommand(
                    artifactID: artifact.id,
                    outcome: .handedOff
                )
            )
            XCTAssertEqual(completion, .released)
        }
    }

    func testSharePreparationRequiresSuccessfulInboundStart() async throws {
        let secure = P4BSecureStore()
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: secure,
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Not Started"))
        do {
            _ = try await service.prepareCipherShare(
                PrepareCipherShareCommand(cipherID: cipher.id, representation: .file)
            )
            XCTFail("Pre-start sharing must be disabled")
        } catch {}
        let prestartCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(prestartCount, 0)

        await service.startInboundProcessing()
        let started = try await service.prepareCipherShare(
            PrepareCipherShareCommand(cipherID: cipher.id, representation: .file)
        )
        guard case .file = started.reference else {
            return XCTFail("A successful start must enable scoped sharing")
        }

        let failingSecure = P4BSecureStore()
        await failingSecure.failReads()
        let failedArtifacts = P4BShareStore()
        let failedService = RuneScribeCoreApplicationService(
            secureValueStore: failingSecure,
            shareArtifactStore: failedArtifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await failedService.startInboundProcessing()
        do {
            _ = try await failedService.prepareCipherShare(
                PrepareCipherShareCommand(
                    cipherID: CipherID(rawValue: UUID()),
                    representation: .file
                )
            )
            XCTFail("Failed activation must not enable sharing")
        } catch {}
        let failedCount = await failedArtifacts.activeArtifactCount()
        XCTAssertEqual(failedCount, 0)
    }

    func testFailedStopCleanupRetainsLeasesAndStartRetriesBeforeSharing() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Cleanup"))
        let artifact = try await service.prepareCipherShare(
            PrepareCipherShareCommand(cipherID: cipher.id, representation: .file)
        )
        let createdCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(createdCount, 1)

        await artifacts.failNextRemoveAll()
        await service.stopInboundProcessing()
        let retainedCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(retainedCount, 1)
        let failedStop = try await currentSnapshot(from: service)
        XCTAssertEqual(failedStop.lastFailure?.code, .shareUnavailable)

        await service.startInboundProcessing()
        let cleanedCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(cleanedCount, 0)
        let recovered = try await currentSnapshot(from: service)
        XCTAssertNil(recovered.lastFailure)
        let next = try await service.prepareCipherShare(
            PrepareCipherShareCommand(cipherID: cipher.id, representation: .file)
        )
        XCTAssertNotEqual(next.id, artifact.id)
    }

    func testLockRevokesShareCreatedAcrossSuspension() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        try await service.setPIN(SetPINCommand(input: PINInput("1234")))
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Lock Race"))
        try await service.assignContact(
            AssignContactCommand(
                cipherID: cipher.id,
                contactID: ContactID(rawValue: UUID())
            )
        )
        let encoded = try await service.encode(
            EncodeMessageCommand(plaintext: "lock race", cipherID: cipher.id)
        )
        await artifacts.pauseNextCreate()
        let command = PrepareMessageShareCommand(
            runes: encoded.runes,
            senderName: "Lock Race",
            cipherID: cipher.id
        )
        let preparation = Task { try await service.prepareMessageShare(command) }
        await artifacts.waitUntilCreatePaused()

        await service.lock()
        await artifacts.resumeCreate()
        do {
            _ = try await preparation.value
            XCTFail("A request crossing the lock boundary must be revoked")
        } catch {}
        let activeCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(activeCount, 0)
        let snapshot = try await currentSnapshot(from: service)
        XCTAssertTrue(snapshot.lockState.isLocked)
    }

    func testFailedRevocationIsObservableAndRetriedByLifecycleCleanup() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        try await service.setPIN(SetPINCommand(input: PINInput("1234")))
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Revoke Failure"))
        await artifacts.pauseNextCreate()
        await artifacts.failNextRemove()
        let command = PrepareCipherShareCommand(
            cipherID: cipher.id,
            representation: .file
        )
        let preparation = Task { try await service.prepareCipherShare(command) }
        await artifacts.waitUntilCreatePaused()
        await service.lock()
        await artifacts.resumeCreate()
        do {
            _ = try await preparation.value
            XCTFail("Authorization and cleanup failure must not return an artifact")
        } catch {}

        let retainedCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(retainedCount, 1)
        let failed = try await currentSnapshot(from: service)
        XCTAssertEqual(failed.lastFailure?.code, .shareUnavailable)

        await service.stopInboundProcessing()
        let cleanedCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(cleanedCount, 0)
        let cleaned = try await currentSnapshot(from: service)
        XCTAssertNil(cleaned.lastFailure)
    }

    func testStopSerializesWithSuspendedShareAndLeavesNoLease() async throws {
        let artifacts = P4BShareStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            shareArtifactStore: artifacts,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let cipher = try await service.createCipher(CreateCipherCommand(name: "Stop Race"))
        await artifacts.pauseNextCreate()
        let command = PrepareCipherShareCommand(
            cipherID: cipher.id,
            representation: .file
        )
        let preparation = Task { try await service.prepareCipherShare(command) }
        await artifacts.waitUntilCreatePaused()
        let stopping = Task { await service.stopInboundProcessing() }
        for _ in 0..<10 { await Task.yield() }
        await artifacts.resumeCreate()

        do {
            _ = try await preparation.value
            XCTFail("A late creation must not escape a concurrent stop")
        } catch {}
        await stopping.value
        let activeCount = await artifacts.activeArtifactCount()
        XCTAssertEqual(activeCount, 0)
        do {
            _ = try await service.prepareCipherShare(command)
            XCTFail("Stopped service must reject new share preparation")
        } catch {}
    }

    func testPrestartQueueDrainsInOrderAndDeduplicatesSameContent() async throws {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        let first = try CipherSharePayload(cipher: .generated(label: "First"))
            .url(name: "First")
        let second = try CipherSharePayload(cipher: .generated(label: "Second"))
            .url(name: "Second")

        let firstDisposition = try await service.receive(
            .url(inboundURL(first, id: UUID(), cold: true))
        )
        XCTAssertEqual(firstDisposition, .accepted)
        let secondDisposition = try await service.receive(
            .url(inboundURL(second, id: UUID(), cold: true))
        )
        XCTAssertEqual(secondDisposition, .accepted)
        await service.startInboundProcessing()

        let firstSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(firstSnapshot.importState.pending?.suggestedName, "First")
        let firstPending = try XCTUnwrap(firstSnapshot.importState.pending)
        await service.cancelImport(id: firstPending.id)

        let secondSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(secondSnapshot.importState.pending?.suggestedName, "Second")
        let duplicate = try await service.receive(
            .url(inboundURL(second, id: UUID(), cold: false))
        )
        XCTAssertEqual(duplicate, .duplicate)
    }

    func testURLDedupeLivesOnlyForPendingPresentation() async throws {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        let url = try CipherSharePayload(cipher: .generated(label: "Repeatable"))
            .url(name: "Repeatable")

        let first = try await service.importURL(inboundURL(url, id: UUID(), cold: false))
        XCTAssertEqual(first.disposition, .awaitingConfirmation)
        let firstPending = try XCTUnwrap(first.pendingImport)
        let whilePending = try await service.importURL(
            inboundURL(url, id: UUID(), cold: false)
        )
        XCTAssertEqual(whilePending.disposition, .duplicate)

        await service.cancelImport(id: firstPending.id)
        let afterCancel = try await service.importURL(
            inboundURL(url, id: UUID(), cold: false)
        )
        XCTAssertEqual(afterCancel.disposition, .awaitingConfirmation)
        let secondPending = try XCTUnwrap(afterCancel.pendingImport)
        _ = try await service.confirmImport(
            ConfirmImportCommand(importID: secondPending.id, name: "Imported")
        )

        let afterConfirmation = try await service.importURL(
            inboundURL(url, id: UUID(), cold: false)
        )
        XCTAssertEqual(afterConfirmation.disposition, .awaitingConfirmation)
    }

    func testQueuedFileSourceDedupeDoesNotReappearAfterCancel() async throws {
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore()
        )
        await service.startInboundProcessing()
        let fileURL = try temporaryFile(
            containing: CipherSharePayload(cipher: .generated(label: "File Dedupe"))
                .encoded()
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let first = try await service.receive(.file(inboundFile(fileURL)))
        XCTAssertEqual(first, .accepted)
        let pending = try await currentSnapshot(from: service)
        let pendingImport = try XCTUnwrap(pending.importState.pending)

        let duplicate = try await service.receive(.file(inboundFile(fileURL)))
        XCTAssertEqual(duplicate, .duplicate)
        await service.cancelImport(id: pendingImport.id)
        let cancelled = try await currentSnapshot(from: service)
        XCTAssertNil(cancelled.importState.pending)

        let afterCancel = try await service.receive(.file(inboundFile(fileURL)))
        XCTAssertEqual(afterCancel, .accepted)
        let represented = try await currentSnapshot(from: service)
        XCTAssertEqual(represented.importState.pending?.suggestedName, "Imported Cipher")
    }

    func testIdenticalBytesAtDifferentPathsDoNotHideInPausedQueue() async throws {
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore()
        )
        await service.startInboundProcessing()
        let bytes = try CipherSharePayload(cipher: .generated(label: "Content Dedupe"))
            .encoded()
        let firstURL = try temporaryFile(containing: bytes)
        let secondURL = try temporaryFile(containing: bytes)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }

        _ = try await service.receive(.file(inboundFile(firstURL)))
        let firstSnapshot = try await currentSnapshot(from: service)
        let pending = try XCTUnwrap(firstSnapshot.importState.pending)
        let secondSubmission = try await service.receive(.file(inboundFile(secondURL)))
        XCTAssertEqual(secondSubmission, .accepted)

        await service.cancelImport(id: pending.id)
        let afterCancel = try await currentSnapshot(from: service)
        XCTAssertNil(afterCancel.importState.pending)

        let explicitRetry = try await service.receive(.file(inboundFile(secondURL)))
        XCTAssertEqual(explicitRetry, .accepted)
        let retried = try await currentSnapshot(from: service)
        XCTAssertNotNil(retried.importState.pending)
    }

    func testCancelSuspendedConfirmationPreventsCipherCommitAndPreservesFIFO() async throws {
        let registrar = P4BGatedFontRegistrar()
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore(),
            registrar: registrar
        )
        await service.startInboundProcessing()
        let initial = try await currentSnapshot(from: service)
        let initialCipherCount = initial.cipherLibrary.ciphers.count

        let fontBytes = Data("custom-font-fixture".utf8)
        let base = Cipher.generated(label: "Cancelled Import")
        let custom = Cipher(
            id: base.id,
            label: base.label,
            origin: base.origin,
            createdAt: base.createdAt,
            formatVersion: base.formatVersion,
            publicID: base.publicID,
            keyMaterial: base.keyMaterial,
            decorativeMapping: base.decorativeMapping,
            fontRef: FontRef(
                id: "cancel-font",
                version: 1,
                sha256: Data(SHA256.hash(data: fontBytes))
            )
        )
        let fileURL = try temporaryFile(
            containing: CipherSharePayload(cipher: custom)
                .encodedFile(fontBytes: fontBytes)
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let imported = try await service.importFile(inboundFile(fileURL))
        let pending = try XCTUnwrap(imported.pendingImport)

        let nextURL = try CipherSharePayload(cipher: .generated(label: "Next FIFO"))
            .url(name: "Next FIFO")
        let queued = try await service.receive(
            .url(inboundURL(nextURL, id: UUID(), cold: false))
        )
        XCTAssertEqual(queued, .accepted)

        let command = ConfirmImportCommand(importID: pending.id, name: "Must Not Persist")
        let confirmation = Task { try await service.confirmImport(command) }
        await registrar.waitUntilPaused()
        await service.cancelImport(id: pending.id)
        await registrar.resume()
        do {
            _ = try await confirmation.value
            XCTFail("Cancellation before the commit point must win")
        } catch {}

        let snapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(snapshot.cipherLibrary.ciphers.count, initialCipherCount)
        XCTAssertFalse(snapshot.cipherLibrary.ciphers.contains { $0.name == "Must Not Persist" })
        XCTAssertEqual(snapshot.importState.pending?.suggestedName, "Next FIFO")
    }

    func testWarmArrivalDuringColdInitializationStaysBehindColdInput() async throws {
        let secure = P4BGatedSecureStore()
        let service = RuneScribeCoreApplicationService(
            secureValueStore: secure,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        let cold = try CipherSharePayload(cipher: .generated(label: "Cold"))
            .url(name: "Cold")
        let warm = try CipherSharePayload(cipher: .generated(label: "Warm"))
            .url(name: "Warm")
        _ = try await service.receive(.url(inboundURL(cold, id: UUID(), cold: true)))

        let start = Task { await service.startInboundProcessing() }
        await secure.waitUntilPaused()
        let warmDisposition = try await service.receive(
            .url(inboundURL(warm, id: UUID(), cold: false))
        )
        XCTAssertEqual(warmDisposition, .accepted)
        await secure.resume()
        await start.value

        let coldSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(coldSnapshot.importState.pending?.suggestedName, "Cold")
        let coldPending = try XCTUnwrap(coldSnapshot.importState.pending)
        await service.cancelImport(id: coldPending.id)
        let warmSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(warmSnapshot.importState.pending?.suggestedName, "Warm")
    }

    func testMalformedColdInputDoesNotBlockLaterValidInput() async throws {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        let malformed = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=bad"))
        let valid = try CipherSharePayload(cipher: .generated(label: "Valid"))
            .url(name: "Valid")
        _ = try await service.receive(.url(inboundURL(malformed, id: UUID(), cold: true)))
        _ = try await service.receive(.url(inboundURL(valid, id: UUID(), cold: true)))

        await service.startInboundProcessing()

        let snapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(snapshot.importState.pending?.suggestedName, "Valid")
        XCTAssertNil(snapshot.importState.lastFailure)
    }

    func testLockedInboundQueuesUntilSuccessfulUnlock() async throws {
        let secure = P4BSecureStore()
        await secure.seed(
            Data(#"{"version":1,"iterations":120000,"salt":"AAECAwQFBgcICQoLDA0ODw==","hash":"UHAyHKNNva/pslNx0cD4O8r+Bz+64fInTwCm1saOmJk="}"#.utf8),
            account: RuneScribeKeychain.appPINAccount
        )
        let service = RuneScribeCoreApplicationService(
            secureValueStore: secure,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await service.startInboundProcessing()
        let lockedSnapshot = try await currentSnapshot(from: service)
        XCTAssertTrue(lockedSnapshot.lockState.isLocked)

        let url = try CipherSharePayload(cipher: .generated(label: "Queued"))
            .url(name: "Queued")
        let queued = try await service.receive(.url(inboundURL(url, id: UUID(), cold: false)))
        XCTAssertEqual(queued, .accepted)
        let whileLocked = try await currentSnapshot(from: service)
        XCTAssertNil(whileLocked.importState.pending)

        let unlock = try await service.unlock(UnlockCommand(input: PINInput("1234")))
        XCTAssertEqual(unlock, .unlocked)
        let unlocked = try await currentSnapshot(from: service)
        XCTAssertFalse(unlocked.lockState.isLocked)
        XCTAssertEqual(unlocked.importState.pending?.suggestedName, "Queued")
    }

    func testWillResignDoesNotLockButBackgroundLocksPastPendingData() async throws {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        try await service.setPIN(SetPINCommand(input: PINInput("1234")))
        _ = try await currentSnapshot(from: service)
        await service.startInboundProcessing()

        let resign = try await service.receive(
            .lifecycle(inboundLifecycle(.willResignActive))
        )
        XCTAssertEqual(resign, .accepted)
        let afterResign = try await currentSnapshot(from: service)
        XCTAssertFalse(afterResign.lockState.isLocked)

        let url = try CipherSharePayload(cipher: .generated(label: "Pending"))
            .url(name: "Pending")
        _ = try await service.receive(.url(inboundURL(url, id: UUID(), cold: false)))
        let pendingSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(pendingSnapshot.importState.pending?.suggestedName, "Pending")

        let background = try await service.receive(
            .lifecycle(inboundLifecycle(.didEnterBackground))
        )
        XCTAssertEqual(background, .accepted)
        let afterBackground = try await currentSnapshot(from: service)
        XCTAssertTrue(afterBackground.lockState.isLocked)
        XCTAssertEqual(afterBackground.importState.pending?.suggestedName, "Pending")
    }

    func testPINMutationDeleteFailuresPublishAndReconstructLockedState() async throws {
        let setStore = P4BSecureStore()
        let setService = RuneScribeCoreApplicationService(
            secureValueStore: setStore,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        _ = try await currentSnapshot(from: setService)
        await setStore.failNextDeletes(account: RuneScribeKeychain.pinThrottleAccount)
        do {
            try await setService.setPIN(SetPINCommand(input: PINInput("1234")))
            XCTFail("A failed throttle delete must fail PIN setup")
        } catch {}
        let failedSet = try await currentSnapshot(from: setService)
        XCTAssertTrue(failedSet.lockState.isPINSet)
        XCTAssertTrue(failedSet.lockState.isLocked)
        XCTAssertEqual(failedSet.lastFailure?.code, .secureStorageUnavailable)
        let reconstructedSet = RuneScribeCoreApplicationService(
            secureValueStore: setStore,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await reconstructedSet.startInboundProcessing()
        let reconstructedSetState = try await currentSnapshot(from: reconstructedSet)
        XCTAssertTrue(reconstructedSetState.lockState.isPINSet)
        XCTAssertTrue(reconstructedSetState.lockState.isLocked)

        let changeStore = P4BSecureStore()
        let changeService = RuneScribeCoreApplicationService(
            secureValueStore: changeStore,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        _ = try await currentSnapshot(from: changeService)
        try await changeService.setPIN(SetPINCommand(input: PINInput("1234")))
        await changeStore.failNextDeletes(account: RuneScribeKeychain.pinThrottleAccount)
        do {
            try await changeService.changePIN(
                ChangePINCommand(
                    current: PINInput("1234"),
                    replacement: PINInput("5678")
                )
            )
            XCTFail("A failed throttle delete must fail PIN change")
        } catch {}
        let failedChange = try await currentSnapshot(from: changeService)
        XCTAssertTrue(failedChange.lockState.isPINSet)
        XCTAssertTrue(failedChange.lockState.isLocked)
        XCTAssertEqual(failedChange.lastFailure?.code, .secureStorageUnavailable)
        let reconstructedChange = RuneScribeCoreApplicationService(
            secureValueStore: changeStore,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await reconstructedChange.startInboundProcessing()
        let reconstructedChangeState = try await currentSnapshot(from: reconstructedChange)
        XCTAssertTrue(reconstructedChangeState.lockState.isPINSet)
        XCTAssertTrue(reconstructedChangeState.lockState.isLocked)

        let disableStore = P4BSecureStore()
        let disableService = RuneScribeCoreApplicationService(
            secureValueStore: disableStore,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        _ = try await currentSnapshot(from: disableService)
        try await disableService.setPIN(SetPINCommand(input: PINInput("1234")))
        await disableStore.failNextDeletes(account: RuneScribeKeychain.pinThrottleAccount)
        do {
            try await disableService.disablePIN(
                DisablePINCommand(current: PINInput("1234"))
            )
            XCTFail("A failed throttle delete must fail PIN disable")
        } catch {}
        let failedDisable = try await currentSnapshot(from: disableService)
        XCTAssertTrue(failedDisable.lockState.isPINSet)
        XCTAssertTrue(failedDisable.lockState.isLocked)
        XCTAssertEqual(failedDisable.lastFailure?.code, .secureStorageUnavailable)
        let reconstructedDisable = RuneScribeCoreApplicationService(
            secureValueStore: disableStore,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        await reconstructedDisable.startInboundProcessing()
        let reconstructedDisableState = try await currentSnapshot(from: reconstructedDisable)
        XCTAssertTrue(reconstructedDisableState.lockState.isPINSet)
        XCTAssertTrue(reconstructedDisableState.lockState.isLocked)
    }

    func testContactCipherPartialCommitRepairsBeforeFailureReturns() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let service = fullService(secure: secure, protected: protected)
        await service.startInboundProcessing()
        await secure.failNextCipherLibraryWrites(1)

        do {
            _ = try await service.importContacts(
                ImportContactsCommand(
                    contacts: [
                        SystemContactDTO(
                            systemIdentifier: "system-repair-once",
                            displayName: "Repair Once"
                        )
                    ]
                )
            )
            XCTFail("The original second-store failure must still be surfaced")
        } catch {}

        // The contact file committed first. A fresh, cancellation-independent
        // repair retries the cipher commit before the failed command returns.
        let repaired = try await currentSnapshot(from: service)
        let contact = try XCTUnwrap(
            repaired.contactLibrary.contacts.first { $0.displayName == "Repair Once" }
        )
        XCTAssertEqual(contact.linkedCipherCount, 1)

        let reconstructed = fullService(secure: secure, protected: protected)
        await reconstructed.startInboundProcessing()
        let reloaded = try await currentSnapshot(from: reconstructed)
        let reloadedContact = try XCTUnwrap(
            reloaded.contactLibrary.contacts.first { $0.displayName == "Repair Once" }
        )
        XCTAssertEqual(reloadedContact.linkedCipherCount, 1)
    }

    func testSystemContactRequestUsesApplicationFacadeAndPublishesAuthorization() async throws {
        let expected = [
            SystemContactDTO(
                systemIdentifier: "system-facade-contact",
                displayName: "Facade Contact"
            )
        ]
        let authorized = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore(),
            contactAccess: P4BContactAccess(
                status: .authorized,
                requestResult: true,
                contacts: expected
            )
        )
        await authorized.startInboundProcessing()

        let contacts = try await authorized.requestSystemContacts()

        XCTAssertEqual(contacts, expected)
        let authorizedSnapshot = try await currentSnapshot(from: authorized)
        XCTAssertEqual(authorizedSnapshot.contactLibrary.authorization, .authorized)

        let denied = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore(),
            contactAccess: P4BContactAccess(
                status: .denied,
                requestResult: false
            )
        )
        await denied.startInboundProcessing()

        do {
            _ = try await denied.requestSystemContacts()
            XCTFail("Denied contact access must surface a typed product error")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeProductError,
                .failure(RuneScribeFailureDTO(code: .authorizationDenied))
            )
        }
        let deniedSnapshot = try await currentSnapshot(from: denied)
        XCTAssertEqual(deniedSnapshot.contactLibrary.authorization, .denied)
    }

    func testColdQueuedMenuCommandsReachFirstUISubscriberInOrder() async throws {
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore()
        )
        let commands: [ApplicationMenuCommandDTO] = [
            .openSettings,
            .openCipherLibrary,
        ]
        for (offset, command) in commands.enumerated() {
            let input = RuneScribeInboundInput.menu(
                InboundMenuCommandDTO(
                    metadata: InboundInputMetadataDTO(
                        id: InboundInputID(
                            rawValue: UUID(
                                uuidString: String(
                                    format: "00000000-0000-0000-0000-%012d",
                                    offset + 1
                                )
                            )!
                        ),
                        receivedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(offset)),
                        source: .applicationOpen,
                        isColdStart: true
                    ),
                    command: command
                )
            )
            let disposition = try await service.receive(input)
            XCTAssertEqual(disposition, .accepted)
        }

        await service.startInboundProcessing()
        var iterator = service.menuCommandStream().makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()

        XCTAssertEqual(first, .openSettings)
        XCTAssertEqual(second, .openCipherLibrary)
    }

    func testImportedContactLinksAreIdempotentPreserveActiveAndUnlinkOnDelete() async throws {
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore()
        )
        await service.startInboundProcessing()
        let before = try await currentSnapshot(from: service)
        let priorActiveID = try XCTUnwrap(before.cipherLibrary.activeCipherID)

        let command = ImportContactsCommand(
            contacts: [
                SystemContactDTO(
                    systemIdentifier: "system-one",
                    displayName: "Contact One"
                ),
                SystemContactDTO(
                    systemIdentifier: "system-two",
                    displayName: "Contact Two"
                ),
            ]
        )
        _ = try await service.importContacts(command)
        _ = try await service.importContacts(command)
        let imported = try await currentSnapshot(from: service)
        XCTAssertEqual(imported.cipherLibrary.activeCipherID, priorActiveID)
        let contacts = imported.contactLibrary.contacts.filter {
            $0.displayName == "Contact One" || $0.displayName == "Contact Two"
        }
        XCTAssertEqual(contacts.count, 2)
        XCTAssertTrue(contacts.allSatisfy { $0.linkedCipherCount == 1 })
        let linkedIDs = Set(contacts.map(\.id))
        XCTAssertEqual(
            imported.cipherLibrary.ciphers.filter {
                $0.assignedContactID.map(linkedIDs.contains) == true
            }.count,
            2
        )
        let cipherCount = imported.cipherLibrary.ciphers.count

        try await service.deleteContacts(ids: linkedIDs)
        let deleted = try await currentSnapshot(from: service)
        XCTAssertTrue(deleted.contactLibrary.contacts.allSatisfy {
            !linkedIDs.contains($0.id)
        })
        XCTAssertEqual(deleted.cipherLibrary.ciphers.count, cipherCount)
        XCTAssertTrue(deleted.cipherLibrary.ciphers.allSatisfy {
            $0.assignedContactID.map(linkedIDs.contains) != true
        })
        XCTAssertEqual(deleted.cipherLibrary.activeCipherID, priorActiveID)
    }

    func testStartupReconcilesPartialCommitWithoutCommandRetry() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let firstService = fullService(secure: secure, protected: protected)
        await firstService.startInboundProcessing()
        // The command's cipher write and its immediate repair both fail. The
        // persisted contact remains the durable source for startup repair.
        await secure.failNextCipherLibraryWrites(2)

        do {
            _ = try await firstService.importContacts(
                ImportContactsCommand(
                    contacts: [
                        SystemContactDTO(
                            systemIdentifier: "system-startup-repair",
                            displayName: "Startup Repair"
                        )
                    ]
                )
            )
            XCTFail("The injected partial commit must fail")
        } catch {}

        let reconstructed = fullService(secure: secure, protected: protected)
        await reconstructed.startInboundProcessing()
        let snapshot = try await currentSnapshot(from: reconstructed)
        XCTAssertFalse(snapshot.cipherLibrary.isLoading)
        let contact = try XCTUnwrap(
            snapshot.contactLibrary.contacts.first { $0.displayName == "Startup Repair" }
        )
        XCTAssertEqual(contact.linkedCipherCount, 1)
        XCTAssertEqual(
            snapshot.cipherLibrary.ciphers.filter { $0.assignedContactID == contact.id }.count,
            1
        )
    }

    func testCancellationBetweenContactAndCipherCommitsStillRepairs() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let service = fullService(secure: secure, protected: protected)
        await service.startInboundProcessing()
        await secure.pauseNextCipherLibraryWrite()

        let operation = Task {
            try await service.importContacts(
                ImportContactsCommand(
                    contacts: [
                        SystemContactDTO(
                            systemIdentifier: "system-cancelled",
                            displayName: "Cancelled Commit"
                        )
                    ]
                )
            )
        }
        await secure.waitUntilCipherLibraryWritePaused()
        operation.cancel()
        await secure.resumeCipherLibraryWrite()

        do {
            _ = try await operation.value
            XCTFail("The cancelled cipher commit must not report success")
        } catch {}

        let snapshot = try await currentSnapshot(from: service)
        let contact = try XCTUnwrap(
            snapshot.contactLibrary.contacts.first { $0.displayName == "Cancelled Commit" }
        )
        XCTAssertEqual(contact.linkedCipherCount, 1)
        XCTAssertEqual(
            snapshot.cipherLibrary.ciphers.filter { $0.assignedContactID == contact.id }.count,
            1
        )
    }

    func testInboundMessageEmbeddedAndStoredCipherPathsPreserveAssociationAndDedupe() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let service = fullService(secure: secure, protected: protected)
        await service.startInboundProcessing()
        let initial = try await currentSnapshot(from: service)
        let initialActiveID = try XCTUnwrap(initial.cipherLibrary.activeCipherID)

        let senderCipher = Cipher.generated(label: "Sender Cipher")
        let embeddedBytes = try messageFileData(
            plaintext: "embedded hello",
            senderName: "Sender Person",
            cipher: senderCipher,
            embedsCipher: true
        )
        let embeddedURL = try temporaryFile(containing: embeddedBytes)
        defer { try? FileManager.default.removeItem(at: embeddedURL) }

        let embeddedResult = try await service.importFile(inboundFile(embeddedURL))
        XCTAssertEqual(embeddedResult.disposition, .receivedMessage)
        let duplicate = try await service.importFile(inboundFile(embeddedURL))
        XCTAssertEqual(duplicate.disposition, .duplicate)

        let embeddedSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(
            embeddedSnapshot.messageState.pendingMessage?.plaintext,
            "embedded hello"
        )
        let senderContact = try XCTUnwrap(
            embeddedSnapshot.contactLibrary.contacts.first {
                $0.displayName == "Sender Person"
            }
        )
        XCTAssertEqual(senderContact.linkedCipherCount, 1)
        let importedCipher = try XCTUnwrap(
            embeddedSnapshot.cipherLibrary.ciphers.first {
                $0.assignedContactID == senderContact.id
            }
        )
        XCTAssertEqual(embeddedSnapshot.cipherLibrary.activeCipherID, initialActiveID)
        XCTAssertNotEqual(importedCipher.id, initialActiveID)
        let cipherCount = embeddedSnapshot.cipherLibrary.ciphers.count
        let firstMessageID = try XCTUnwrap(embeddedSnapshot.messageState.pendingMessage?.id)
        await service.dismissReceivedMessage(id: firstMessageID)

        let storedBytes = try messageFileData(
            plaintext: "stored hello",
            senderName: "Sender Person",
            cipher: senderCipher,
            embedsCipher: false
        )
        let storedURL = try temporaryFile(containing: storedBytes)
        defer { try? FileManager.default.removeItem(at: storedURL) }
        let storedResult = try await service.importFile(inboundFile(storedURL))
        XCTAssertEqual(storedResult.disposition, .receivedMessage)
        let storedSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(storedSnapshot.messageState.pendingMessage?.plaintext, "stored hello")
        XCTAssertEqual(storedSnapshot.contactLibrary.contacts.count, 1)
        XCTAssertEqual(storedSnapshot.cipherLibrary.ciphers.count, cipherCount)
        XCTAssertEqual(storedSnapshot.cipherLibrary.activeCipherID, initialActiveID)
        let storedMessageID = try XCTUnwrap(storedSnapshot.messageState.pendingMessage?.id)
        await service.dismissReceivedMessage(id: storedMessageID)

        // Dismissal forgets pending-only content dedupe, while embedded public-ID
        // ingestion still reuses the persisted cipher and exact-name contact.
        let resent = try await service.importFile(inboundFile(embeddedURL))
        XCTAssertEqual(resent.disposition, .receivedMessage)
        let resentSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(resentSnapshot.cipherLibrary.ciphers.count, cipherCount)
        XCTAssertEqual(resentSnapshot.contactLibrary.contacts.count, 1)
        XCTAssertEqual(resentSnapshot.cipherLibrary.activeCipherID, initialActiveID)
    }

    func testInboundMessageFailuresAreSafeAndDoNotBlockRetry() async throws {
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore()
        )
        await service.startInboundProcessing()

        let malformedURL = try temporaryFile(containing: Data([1, 0, 0]))
        defer { try? FileManager.default.removeItem(at: malformedURL) }
        do {
            _ = try await service.importFile(inboundFile(malformedURL))
            XCTFail("Malformed message file must fail")
        } catch {}

        let unknownCipher = Cipher.generated(label: "Unknown")
        let unknownBytes = try messageFileData(
            plaintext: "cannot decrypt",
            senderName: "Unknown Sender",
            cipher: unknownCipher,
            embedsCipher: false
        )
        let unknownURL = try temporaryFile(containing: unknownBytes)
        defer { try? FileManager.default.removeItem(at: unknownURL) }
        do {
            _ = try await service.importFile(inboundFile(unknownURL))
            XCTFail("A message without a matching stored cipher must fail")
        } catch {}
        let failed = try await currentSnapshot(from: service)
        XCTAssertEqual(failed.messageState.phase, .failed)
        XCTAssertNil(failed.messageState.pendingMessage)
        XCTAssertNotNil(failed.messageState.lastFailure)

        let validCipher = Cipher.generated(label: "Retry Sender")
        let validBytes = try messageFileData(
            plaintext: "retry succeeds",
            senderName: "Retry Sender",
            cipher: validCipher,
            embedsCipher: true
        )
        let validURL = try temporaryFile(containing: validBytes)
        defer { try? FileManager.default.removeItem(at: validURL) }
        let validResult = try await service.importFile(inboundFile(validURL))
        XCTAssertEqual(validResult.disposition, .receivedMessage)
        let recovered = try await currentSnapshot(from: service)
        XCTAssertEqual(recovered.messageState.pendingMessage?.plaintext, "retry succeeds")
    }

    func testUnreadableAndUnknownFilesPublishSafeFailureAndDoNotBlockValidRetry() async throws {
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore()
        )
        await service.startInboundProcessing()

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(RuneScribeWireFormat.fileExtension)
        do {
            _ = try await service.importFile(inboundFile(missingURL))
            XCTFail("An unreadable file must fail")
        } catch {}
        let unreadable = try await currentSnapshot(from: service)
        XCTAssertEqual(unreadable.importState.phase, .failed)
        XCTAssertEqual(
            unreadable.importState.lastFailure?.code,
            .protectedFileUnavailable
        )

        let unknownURL = try temporaryFile(containing: Data([0x7f, 0x01, 0x02]))
        defer { try? FileManager.default.removeItem(at: unknownURL) }
        do {
            _ = try await service.importFile(inboundFile(unknownURL))
            XCTFail("An unknown wire version must fail")
        } catch {}
        let unknown = try await currentSnapshot(from: service)
        XCTAssertEqual(unknown.importState.phase, .failed)
        XCTAssertEqual(unknown.importState.lastFailure?.code, .unsupportedFormat)

        let validURL = try temporaryFile(
            containing: try CipherSharePayload(cipher: .generated(label: "Valid Retry"))
                .encoded()
        )
        defer { try? FileManager.default.removeItem(at: validURL) }
        let valid = try await service.importFile(inboundFile(validURL))
        XCTAssertEqual(valid.disposition, .awaitingConfirmation)
        let recovered = try await currentSnapshot(from: service)
        XCTAssertEqual(recovered.importState.phase, .awaitingConfirmation)
        XCTAssertEqual(recovered.importState.pending?.suggestedName, "Imported Cipher")
        XCTAssertNil(recovered.importState.lastFailure)
    }

    func testMessageContactCommitFailureRepairsBeforeRetry() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let service = fullService(secure: secure, protected: protected)
        await service.startInboundProcessing()
        let cipher = Cipher.generated(label: "Contact Failure")
        let contactAID = try await establishMessageAssociation(
            service: service,
            cipher: cipher,
            contactName: "Contact A"
        )
        let bytes = try messageFileData(
            plaintext: "repair then retry",
            senderName: "Contact B",
            cipher: cipher,
            embedsCipher: false
        )
        let url = try temporaryFile(containing: bytes)
        defer { try? FileManager.default.removeItem(at: url) }
        await protected.failNextContactWrites()

        do {
            _ = try await service.importFile(inboundFile(url))
            XCTFail("A failed durable contact association must fail intake")
        } catch {}
        let failed = try await currentSnapshot(from: service)
        XCTAssertEqual(failed.messageState.phase, .failed)
        XCTAssertNil(failed.messageState.pendingMessage)
        XCTAssertNil(failed.contactLibrary.contacts.first { $0.displayName == "Contact B" })
        XCTAssertEqual(
            failed.contactLibrary.contacts.first { $0.id == contactAID }?.linkedCipherCount,
            1
        )
        XCTAssertEqual(
            failed.cipherLibrary.ciphers.first { $0.assignedContactID == contactAID }?
                .assignedContactID,
            contactAID
        )

        let retried = try await service.importFile(inboundFile(url))
        XCTAssertEqual(retried.disposition, .receivedMessage)
        let recovered = try await currentSnapshot(from: service)
        let contact = try XCTUnwrap(
            recovered.contactLibrary.contacts.first { $0.displayName == "Contact B" }
        )
        XCTAssertEqual(contact.linkedCipherCount, 1)
    }

    func testCancelledMessageContactCommitRepairsWithoutCreatingContact() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let service = fullService(secure: secure, protected: protected)
        await service.startInboundProcessing()
        let cipher = Cipher.generated(label: "Cancelled Contact")
        let contactAID = try await establishMessageAssociation(
            service: service,
            cipher: cipher,
            contactName: "Cancellation A"
        )
        let url = try temporaryFile(
            containing: messageFileData(
                plaintext: "cancel association",
                senderName: "Cancellation B",
                cipher: cipher,
                embedsCipher: false
            )
        )
        defer { try? FileManager.default.removeItem(at: url) }
        await protected.pauseNextContactWrite()

        let input = inboundFile(url)
        let operation = Task { try await service.importFile(input) }
        await protected.waitUntilContactWritePaused()
        operation.cancel()
        await protected.resumeContactWrite()
        do {
            _ = try await operation.value
            XCTFail("Cancellation before the contact commit must fail intake")
        } catch {}

        let snapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(snapshot.messageState.phase, .failed)
        XCTAssertNil(
            snapshot.contactLibrary.contacts.first { $0.displayName == "Cancellation B" }
        )
        XCTAssertEqual(
            snapshot.contactLibrary.contacts.first { $0.id == contactAID }?.linkedCipherCount,
            1
        )
    }

    func testMessageAssociationRepairsOnReconstructionWithoutRetryingImport() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let firstService = fullService(secure: secure, protected: protected)
        await firstService.startInboundProcessing()
        let cipher = Cipher.generated(label: "Reconstruct Contact")
        let contactAID = try await establishMessageAssociation(
            service: firstService,
            cipher: cipher,
            contactName: "Reconstruction A"
        )
        let url = try temporaryFile(
            containing: messageFileData(
                plaintext: "reconstruct",
                senderName: "Reconstruction B",
                cipher: cipher,
                embedsCipher: false
            )
        )
        defer { try? FileManager.default.removeItem(at: url) }
        await protected.failNextContactWrites {
            await secure.failNextCipherLibraryWrites(1)
        }

        do {
            _ = try await firstService.importFile(inboundFile(url))
            XCTFail("Both the association commit and immediate repair are injected failures")
        } catch {}

        let reconstructed = fullService(secure: secure, protected: protected)
        await reconstructed.startInboundProcessing()
        let snapshot = try await currentSnapshot(from: reconstructed)
        XCTAssertFalse(snapshot.cipherLibrary.isLoading)
        XCTAssertNil(
            snapshot.contactLibrary.contacts.first { $0.displayName == "Reconstruction B" }
        )
        XCTAssertEqual(
            snapshot.contactLibrary.contacts.first { $0.id == contactAID }?.linkedCipherCount,
            1
        )
        XCTAssertEqual(
            snapshot.cipherLibrary.ciphers.first { $0.assignedContactID == contactAID }?
                .assignedContactID,
            contactAID
        )
        XCTAssertNil(snapshot.messageState.pendingMessage)
    }

    func testTransientMessageCipherDecryptsWithoutCreatingContact() async throws {
        let secure = P4BSecureStore()
        let protected = P4BProtectedStore()
        let service = fullService(secure: secure, protected: protected)
        await service.startInboundProcessing()
        await secure.failNextCipherLibraryWrites(1)
        let cipher = Cipher.generated(label: "Transient Sender")
        let url = try temporaryFile(
            containing: messageFileData(
                plaintext: "transient decrypt",
                senderName: "Transient Sender",
                cipher: cipher,
                embedsCipher: true
            )
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await service.importFile(inboundFile(url))
        XCTAssertEqual(result.disposition, .receivedMessage)
        let snapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(snapshot.messageState.pendingMessage?.plaintext, "transient decrypt")
        XCTAssertTrue(snapshot.contactLibrary.contacts.isEmpty)
        XCTAssertTrue(snapshot.cipherLibrary.ciphers.allSatisfy { $0.name != "Transient Sender" })
    }

    func testPendingMessageDoesNotConsumeClipboardChangeBeforeDismissal() async throws {
        let clipboard = P4BClipboard()
        let service = fullService(
            secure: P4BSecureStore(),
            protected: P4BProtectedStore(),
            clipboard: clipboard
        )
        await service.startInboundProcessing()

        let messageCipher = Cipher.generated(label: "Clipboard Gate")
        let messageURL = try temporaryFile(
            containing: messageFileData(
                plaintext: "pending",
                senderName: "Clipboard Gate",
                cipher: messageCipher,
                embedsCipher: true
            )
        )
        defer { try? FileManager.default.removeItem(at: messageURL) }
        _ = try await service.importFile(inboundFile(messageURL))
        let pendingMessageSnapshot = try await currentSnapshot(from: service)
        let messageID = try XCTUnwrap(
            pendingMessageSnapshot.messageState.pendingMessage?.id
        )

        let clipboardURL = try CipherSharePayload(cipher: .generated(label: "Clipboard"))
            .url(name: "Clipboard")
        await clipboard.set(changeCount: 1, string: clipboardURL.absoluteString)
        _ = try await service.receive(.lifecycle(inboundLifecycle(.didBecomeActive)))
        let stillMessage = try await currentSnapshot(from: service)
        XCTAssertNotNil(stillMessage.messageState.pendingMessage)
        XCTAssertNil(stillMessage.importState.pending)

        await service.dismissReceivedMessage(id: messageID)
        _ = try await service.receive(.lifecycle(inboundLifecycle(.didBecomeActive)))
        let importedClipboard = try await currentSnapshot(from: service)
        XCTAssertEqual(importedClipboard.importState.pending?.suggestedName, "Clipboard")
        XCTAssertEqual(importedClipboard.importState.pending?.source, .clipboard)
    }

    func testInboundQueueBoundsDataAndReservesSecurityControlLane() async throws {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        try await service.setPIN(SetPINCommand(input: PINInput("1234")))
        let first = try CipherSharePayload(cipher: .generated(label: "First FIFO"))
            .url(name: "First FIFO")
        let second = try CipherSharePayload(cipher: .generated(label: "Second FIFO"))
            .url(name: "Second FIFO")
        let firstDisposition = try await service.receive(
            .url(inboundURL(first, id: UUID(), cold: true))
        )
        XCTAssertEqual(firstDisposition, .accepted)
        let secondDisposition = try await service.receive(
            .url(inboundURL(second, id: UUID(), cold: true))
        )
        XCTAssertEqual(secondDisposition, .accepted)
        for index in 2..<496 {
            let malformed = try XCTUnwrap(
                URL(string: "runescribe://import?v=3&p=queued-\(index)")
            )
            let disposition = try await service.receive(
                .url(inboundURL(malformed, id: UUID(), cold: true))
            )
            XCTAssertEqual(disposition, .accepted)
        }
        let overflowData = try XCTUnwrap(
            URL(string: "runescribe://import?v=3&p=data-overflow")
        )
        let dataRejection = try await service.receive(
            .url(inboundURL(overflowData, id: UUID(), cold: true))
        )
        XCTAssertEqual(dataRejection, .rejected)

        let backgroundDisposition = try await service.receive(
            .lifecycle(inboundLifecycle(.didEnterBackground))
        )
        XCTAssertEqual(backgroundDisposition, .accepted)
        for _ in 1..<16 {
            let disposition = try await service.receive(
                .lifecycle(inboundLifecycle(.willResignActive))
            )
            XCTAssertEqual(disposition, .accepted)
        }
        let controlRejection = try await service.receive(
            .lifecycle(inboundLifecycle(.willEnterForeground))
        )
        XCTAssertEqual(controlRejection, .rejected)
        let rejectedSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(rejectedSnapshot.lastFailure?.code, .temporarilyUnavailable)

        await service.startInboundProcessing()
        let firstSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(firstSnapshot.importState.pending?.suggestedName, "First FIFO")
        XCTAssertTrue(firstSnapshot.lockState.isLocked)

        let firstPending = try XCTUnwrap(firstSnapshot.importState.pending)
        await service.cancelImport(id: firstPending.id)
        _ = try await service.unlock(UnlockCommand(input: PINInput("1234")))
        let secondSnapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(secondSnapshot.importState.pending?.suggestedName, "Second FIFO")
    }

    func testInboundMetadataRejectionPublishesSafeInvalidInput() async throws {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: P4BSecureStore(),
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
        _ = try await currentSnapshot(from: service)
        let file = InboundFileDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: UUID()),
                receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
                source: .fileImporter,
                isColdStart: false
            ),
            fileURL: URL(fileURLWithPath: "/tmp/inbound.runescribe"),
            declaredContentType: String(repeating: "x", count: 257),
            requiresSecurityScopedAccess: false
        )
        let disposition = try await service.receive(.file(file))
        XCTAssertEqual(disposition, .rejected)
        let snapshot = try await currentSnapshot(from: service)
        XCTAssertEqual(snapshot.lastFailure?.code, .invalidInput)
    }

    private func summary(
        id: CipherID,
        from service: RuneScribeCoreApplicationService
    ) async throws -> CipherSummary {
        let snapshot = try await currentSnapshot(from: service)
        return try XCTUnwrap(snapshot.cipherLibrary.ciphers.first { $0.id == id })
    }

    private func currentSnapshot(
        from service: RuneScribeCoreApplicationService
    ) async throws -> RuneScribeApplicationSnapshot {
        var iterator = service.stateStream().makeAsyncIterator()
        let value = await iterator.next()
        return try XCTUnwrap(value)
    }

    private func fullService(
        secure: P4BSecureStore,
        protected: P4BProtectedStore,
        clipboard: P4BClipboard = P4BClipboard(),
        artifacts: P4BShareStore = P4BShareStore(),
        registrar: any SystemFontRegistrar = P4BUnavailableFontRegistrar(),
        contactAccess: any ContactAccessService = P4BContactAccess()
    ) -> RuneScribeCoreApplicationService {
        RuneScribeCoreApplicationService(
            secureValueStore: secure,
            protectedFileStore: protected,
            inboundFileReader: P4BInboundFileReader(),
            shareArtifactStore: artifacts,
            applicationResourceLocator: P4BUnavailableResources(),
            systemFontRegistrar: registrar,
            contactAccess: contactAccess,
            clipboardReading: clipboard,
            clock: P4BClock(),
            uuid: P4BUUIDs()
        )
    }

    private func inboundFile(_ url: URL) -> InboundFileDTO {
        InboundFileDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: UUID()),
                receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
                source: .fileImporter,
                isColdStart: false
            ),
            fileURL: url,
            requiresSecurityScopedAccess: false
        )
    }

    private func messageFileData(
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

    private func establishMessageAssociation(
        service: RuneScribeCoreApplicationService,
        cipher: Cipher,
        contactName: String
    ) async throws -> ContactID {
        let url = try temporaryFile(
            containing: messageFileData(
                plaintext: "establish association",
                senderName: contactName,
                cipher: cipher,
                embedsCipher: true
            )
        )
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await service.importFile(inboundFile(url))
        let snapshot = try await currentSnapshot(from: service)
        let contact = try XCTUnwrap(
            snapshot.contactLibrary.contacts.first { $0.displayName == contactName }
        )
        let messageID = try XCTUnwrap(snapshot.messageState.pendingMessage?.id)
        await service.dismissReceivedMessage(id: messageID)
        return contact.id
    }

    private func temporaryFile(containing data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(RuneScribeWireFormat.fileExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func inboundURL(_ url: URL, id: UUID, cold: Bool) -> InboundURLDTO {
        InboundURLDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: id),
                receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
                source: .applicationOpen,
                isColdStart: cold
            ),
            url: url
        )
    }

    private func inboundLifecycle(
        _ event: ApplicationLifecycleInputDTO
    ) -> InboundLifecycleDTO {
        InboundLifecycleDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: UUID()),
                receivedAt: Date(timeIntervalSince1970: 1_750_000_000),
                source: .sceneOpen,
                isColdStart: false
            ),
            event: event
        )
    }
}

private struct P4BClock: ClockProviding {
    func now() -> Date { Date(timeIntervalSince1970: 1_750_000_000) }
}

private struct P4BUUIDs: UUIDProviding {
    func nextUUID() -> UUID { UUID() }
}

private actor P4BSecureStore: SecureValueStore {
    private var values: [String: Data] = [:]
    private var dataReadsFail = false
    private var cipherLibraryFailuresRemaining = 0
    private var deleteFailures: [String: Int] = [:]
    private var pauseNextCipherLibrarySet = false
    private var cipherLibrarySetIsPaused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func seed(_ data: Data, account: String) {
        values[account] = data
    }

    func failReads() {
        dataReadsFail = true
    }

    func failNextCipherLibraryWrites(_ count: Int) {
        cipherLibraryFailuresRemaining = count
    }

    func failNextDeletes(account: String, count: Int = 1) {
        deleteFailures[account] = count
    }

    func pauseNextCipherLibraryWrite() {
        pauseNextCipherLibrarySet = true
        cipherLibrarySetIsPaused = false
    }

    func waitUntilCipherLibraryWritePaused() async {
        if cipherLibrarySetIsPaused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resumeCipherLibraryWrite() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func data(service: String, account: String) async throws -> Data? {
        if dataReadsFail { throw P4BInjectedFailure() }
        return values[account]
    }

    func set(_ data: Data, service: String, account: String) async throws {
        if account == RuneScribeKeychain.cipherLibraryAccount {
            if pauseNextCipherLibrarySet {
                pauseNextCipherLibrarySet = false
                cipherLibrarySetIsPaused = true
                let waiters = pauseWaiters
                pauseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                await withCheckedContinuation { resumeContinuation = $0 }
                try Task.checkCancellation()
            }
            if cipherLibraryFailuresRemaining > 0 {
                cipherLibraryFailuresRemaining -= 1
                throw P4BInjectedFailure()
            }
        }
        values[account] = data
    }

    func delete(service: String, account: String) async throws {
        if let failures = deleteFailures[account], failures > 0 {
            deleteFailures[account] = failures - 1
            throw P4BInjectedFailure()
        }
        values.removeValue(forKey: account)
    }
}

private struct P4BInjectedFailure: Error, Sendable {}

private actor P4BProtectedStore: ProtectedFileStore {
    private var values: [ProtectedPath: Data] = [:]
    private var contactWriteFailuresRemaining = 0
    private var contactFailureAction: (@Sendable () async -> Void)?
    private var pauseNextContactSet = false
    private var contactSetIsPaused = false
    private var contactPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var contactResumeContinuation: CheckedContinuation<Void, Never>?

    func failNextContactWrites(
        _ count: Int = 1,
        then action: (@Sendable () async -> Void)? = nil
    ) {
        contactWriteFailuresRemaining = count
        contactFailureAction = action
    }

    func pauseNextContactWrite() {
        pauseNextContactSet = true
        contactSetIsPaused = false
    }

    func waitUntilContactWritePaused() async {
        if contactSetIsPaused { return }
        await withCheckedContinuation { contactPauseWaiters.append($0) }
    }

    func resumeContactWrite() {
        contactResumeContinuation?.resume()
        contactResumeContinuation = nil
    }

    func read(relativePath: ProtectedPath) async throws -> Data? {
        values[relativePath]
    }

    func write(_ data: Data, relativePath: ProtectedPath) async throws {
        if relativePath == .contacts {
            if pauseNextContactSet {
                pauseNextContactSet = false
                contactSetIsPaused = true
                let waiters = contactPauseWaiters
                contactPauseWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
                await withCheckedContinuation { contactResumeContinuation = $0 }
                try Task.checkCancellation()
            }
            if contactWriteFailuresRemaining > 0 {
                contactWriteFailuresRemaining -= 1
                let action = contactFailureAction
                contactFailureAction = nil
                await action?()
                throw P4BInjectedFailure()
            }
        }
        values[relativePath] = data
    }

    func remove(relativePath: ProtectedPath) async throws {
        values.removeValue(forKey: relativePath)
    }

    func exists(relativePath: ProtectedPath) async throws -> Bool {
        values[relativePath] != nil
    }

    func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        let prefix = directory.rawValue + "/"
        return values.keys.filter { path in
            guard path.rawValue.hasPrefix(prefix) else { return false }
            guard let fileExtension else { return true }
            return path.rawValue.hasSuffix("." + fileExtension)
        }.sorted()
    }
}

private struct P4BUnavailableResources: ApplicationResourceLocator {
    func data(for resource: ApplicationResource) async throws -> Data {
        throw P4BInjectedFailure()
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        throw P4BInjectedFailure()
    }
}

private struct P4BInboundFileReader: InboundFileReader {
    func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        guard fileURL.isFileURL else { throw InboundFileReaderError.notFileURL }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw InboundFileReaderError.unavailable
        }
        guard data.count <= maximumByteCount else {
            throw InboundFileReaderError.contentTooLarge
        }
        return data
    }
}

private struct P4BUnavailableFontRegistrar: SystemFontRegistrar {
    func postScriptName(forFontData data: Data) async throws -> String {
        throw P4BInjectedFailure()
    }

    func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        throw P4BInjectedFailure()
    }
}

private struct P4BSuccessfulFontRegistrar: SystemFontRegistrar {
    func postScriptName(forFontData data: Data) async throws -> String {
        "TestCustomFont"
    }

    func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        RegisteredFontDTO(postScriptName: "TestCustomFont")
    }
}

private actor P4BGatedFontRegistrar: SystemFontRegistrar {
    private var paused = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func postScriptName(forFontData data: Data) async throws -> String {
        if !paused {
            paused = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        return "TestFont"
    }

    func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        RegisteredFontDTO(postScriptName: "TestFont")
    }
}

private struct P4BContactAccess: ContactAccessService {
    let status: ContactAuthorizationDTO
    let requestResult: Bool
    let contacts: [SystemContactDTO]

    init(
        status: ContactAuthorizationDTO = .authorized,
        requestResult: Bool = true,
        contacts: [SystemContactDTO] = []
    ) {
        self.status = status
        self.requestResult = requestResult
        self.contacts = contacts
    }

    func authorizationStatus() async -> ContactAuthorizationDTO { status }
    func requestAccess() async throws -> Bool { requestResult }
    func fetchContacts() async throws -> [SystemContactDTO] { contacts }
}

private actor P4BClipboard: ClipboardReading {
    private var currentChangeCount = 0
    private var currentString: String?

    func set(changeCount: Int, string: String?) {
        currentChangeCount = changeCount
        currentString = string
    }

    func changeCount() async -> Int { currentChangeCount }
    func string() async -> String? { currentString }
}

private actor P4BGatedSecureStore: SecureValueStore {
    private var values: [String: Data] = [:]
    private var didPause = false
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func waitUntilPaused() async {
        if didPause { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }

    func data(service: String, account: String) async throws -> Data? {
        if !didPause {
            didPause = true
            let waiters = pauseWaiters
            pauseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        return values[account]
    }

    func set(_ data: Data, service: String, account: String) async throws {
        values[account] = data
    }

    func delete(service: String, account: String) async throws {
        values.removeValue(forKey: account)
    }
}

private actor P4BShareStore: ShareArtifactStore {
    private var dataByID: [ShareArtifactID: Data] = [:]
    private var linksByID: [ShareArtifactID: URL] = [:]
    private var removed: Set<ShareArtifactID> = []
    private var removeAllFailuresRemaining = 0
    private var removeFailuresRemaining = 0
    private var pauseNextCreation = false
    private var creationIsPaused = false
    private var creationPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var creationResumeContinuation: CheckedContinuation<Void, Never>?

    func failNextRemoveAll(_ count: Int = 1) {
        removeAllFailuresRemaining = count
    }

    func failNextRemove(_ count: Int = 1) {
        removeFailuresRemaining = count
    }

    func pauseNextCreate() {
        pauseNextCreation = true
        creationIsPaused = false
    }

    func waitUntilCreatePaused() async {
        if creationIsPaused { return }
        await withCheckedContinuation { creationPauseWaiters.append($0) }
    }

    func resumeCreate() {
        creationResumeContinuation?.resume()
        creationResumeContinuation = nil
    }

    func create(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws -> ScopedShareFile {
        if pauseNextCreation {
            pauseNextCreation = false
            creationIsPaused = true
            let waiters = creationPauseWaiters
            creationPauseWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { creationResumeContinuation = $0 }
        }
        dataByID[artifactID] = data
        return ScopedShareFile(
            artifactID: artifactID,
            fileURL: URL(fileURLWithPath: "/scoped/\(artifactID.rawValue.uuidString)/\(filename).\(fileExtension)")
        )
    }

    func remove(_ file: ScopedShareFile) async throws {
        if removeFailuresRemaining > 0 {
            removeFailuresRemaining -= 1
            throw P4BInjectedFailure()
        }
        dataByID.removeValue(forKey: file.artifactID)
        removed.insert(file.artifactID)
    }

    func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws {
        linksByID[artifactID] = url
    }

    func removeLink(artifactID: ShareArtifactID) async throws {
        linksByID.removeValue(forKey: artifactID)
        removed.insert(artifactID)
    }

    func removeAll() async throws {
        if removeAllFailuresRemaining > 0 {
            removeAllFailuresRemaining -= 1
            throw P4BInjectedFailure()
        }
        removed.formUnion(dataByID.keys)
        removed.formUnion(linksByID.keys)
        dataByID.removeAll()
        linksByID.removeAll()
    }

    func createdData(id: ShareArtifactID) -> Data? {
        dataByID[id]
    }

    func wasRemoved(id: ShareArtifactID) -> Bool {
        removed.contains(id)
    }

    func storedLink(id: ShareArtifactID) -> URL? {
        linksByID[id]
    }

    func activeArtifactCount() -> Int {
        dataByID.count + linksByID.count
    }
}
