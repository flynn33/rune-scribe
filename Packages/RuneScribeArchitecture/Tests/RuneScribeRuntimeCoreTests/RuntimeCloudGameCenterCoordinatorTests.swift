import Foundation
import RuneScribeCloudSyncModule
import RuneScribeContracts
import RuneScribeGameCenterModule
import RuneScribeProgressionSyncDomain
@testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

final class RuntimeCloudGameCenterCoordinatorTests: XCTestCase {
    func testRuntimeSnapshotAlwaysProjectsLocalExternalServiceStatus() async throws {
        let runtime = RuneScribeRuntime(
            runtimeVersion: try SemanticVersion(major: 1, minor: 0, patch: 0),
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { testDate },
                nextUUID: { UUID(uuid: (0xa0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)) }
            )
        )

        let snapshot = await runtime.snapshot()

        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertTrue(snapshot.cloudGameCenterStatus.cloudSync.localProgressionAvailable)
        XCTAssertTrue(snapshot.cloudGameCenterStatus.gameCenter.localProgressionAvailable)
        XCTAssertEqual(snapshot.cloudGameCenterStatus.gameCenter.connection, .disabled)
    }

    func testMissingServicesAndStorePreserveLocalFirstStatusAndQueuedTruth() async throws {
        let fixture = try await CoordinatorFixture(includeStore: false)
        let projection = try makeProjection(localRevision: 3)
        let candidate = try makeCandidate(percentage: 50, revision: 3)

        try await fixture.coordinator.submitCloudProjection(projection)
        try await fixture.coordinator.submitGameCenterCandidates([candidate])
        await fixture.coordinator.runPendingWork()

        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertTrue(status.cloudSync.localProgressionAvailable)
        XCTAssertEqual(status.cloudSync.pendingRevision, 3)
        XCTAssertEqual(status.cloudSync.phase, .persistenceDegraded)
        XCTAssertFalse(status.cloudSync.persistenceIsDurable)
        XCTAssertEqual(status.gameCenter.connection, .disabled)
        XCTAssertEqual(status.gameCenter.reportStatus, .localOnly)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)
        XCTAssertTrue(status.gameCenter.localProgressionAvailable)
        XCTAssertFalse(status.gameCenter.persistenceIsDurable)
    }

    func testGameCenterNeverAuthenticatesBeforeOptInAndPersistsAcknowledgement() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let gameCenter = GameCenterCoordinatorProbe()
        let fixture = try await CoordinatorFixture(
            store: store,
            gameCenter: gameCenter
        )
        let candidate = try makeCandidate(percentage: 100, revision: 8)

        try await fixture.coordinator.submitGameCenterCandidates([candidate])
        await fixture.coordinator.runPendingWork()
        var authenticationRequestCount = await gameCenter.authenticationRequestCount()
        var reportedBatches = await gameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 0)
        XCTAssertEqual(reportedBatches, [])

        try await fixture.coordinator.submit(.optIn)
        authenticationRequestCount = await gameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)
        await fixture.coordinator.runPendingWork()

        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.connection, .connected)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertTrue(status.gameCenter.authenticationWasUserInitiated)
        reportedBatches = await gameCenter.reportedBatches()
        XCTAssertEqual(reportedBatches.count, 1)

        await fixture.coordinator.deactivateRuntime()
        await fixture.platformGateway.deactivateRuntime()
        await fixture.stateGateway.deactivateRuntime()
        _ = await fixture.stateGateway.activateRuntime()
        await fixture.platformGateway.activateRuntime()

        let relaunched = RuntimeCloudGameCenterCoordinator(
            stateGateway: fixture.stateGateway,
            platformGateway: fixture.platformGateway,
            environment: fixture.environment,
            automaticScheduling: false
        )
        await relaunched.activateRuntime()
        status = try await relaunched.statusSnapshot()
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
        authenticationRequestCount = await gameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)

        await relaunched.runPendingWork()
        authenticationRequestCount = await gameCenter.authenticationRequestCount()
        reportedBatches = await gameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reportedBatches.count, 1)
    }

    func testPersistedGameCenterOptInAuthenticatesFreshAdapterOnceAndDrainsOutbox() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let uuidSequence = TestUUIDSequence()
        let initialGameCenter = GameCenterCoordinatorProbe()
        let first = try await CoordinatorFixture(
            store: store,
            gameCenter: initialGameCenter,
            uuidSequence: uuidSequence
        )
        try await first.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 9),
        ])
        try await first.coordinator.submit(.optIn)
        var status = try await first.coordinator.statusSnapshot()
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        let freshGameCenter = GameCenterCoordinatorProbe()
        let relaunched = try await CoordinatorFixture(
            store: store,
            gameCenter: freshGameCenter,
            uuidSequence: uuidSequence
        )
        status = try await relaunched.coordinator.statusSnapshot()
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.connection, .authenticationAvailable)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)
        XCTAssertFalse(status.gameCenter.authenticationWasUserInitiated)
        var authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 0)

        await relaunched.coordinator.runPendingWork()
        status = try await relaunched.coordinator.statusSnapshot()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        var reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reportedBatches.count, 1)
        XCTAssertEqual(status.gameCenter.connection, .connected)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
        XCTAssertTrue(status.gameCenter.authenticationWasUserInitiated)

        await relaunched.coordinator.wake(.applicationBecameActive)
        await relaunched.coordinator.runPendingWork()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reportedBatches.count, 1)
    }

    func testInterruptedGameCenterReportRecoversNewestCandidateAfterRelaunch() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let uuidSequence = TestUUIDSequence()
        let interruptedGameCenter = GameCenterCoordinatorProbe()
        await interruptedGameCenter.suspendReport()
        let first = try await CoordinatorFixture(
            store: store,
            gameCenter: interruptedGameCenter,
            uuidSequence: uuidSequence
        )
        let candidate60 = try makeCandidate(percentage: 60, revision: 13)
        let candidate80 = try makeCandidate(percentage: 80, revision: 14)
        try await first.coordinator.submitGameCenterCandidates([candidate60])
        try await first.coordinator.submit(.optIn)

        let pendingWork = Task {
            await first.coordinator.runPendingWork()
        }
        let reportStarted = await waitForCoordinatorCondition {
            await interruptedGameCenter.reportAttemptCount() == 1
        }
        XCTAssertTrue(reportStarted)

        try await first.coordinator.submitGameCenterCandidates([candidate80])
        var status = try await first.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)

        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()
        await interruptedGameCenter.resumeReport()
        await pendingWork.value

        let freshGameCenter = GameCenterCoordinatorProbe()
        let relaunched = try await CoordinatorFixture(
            store: store,
            gameCenter: freshGameCenter,
            uuidSequence: uuidSequence
        )
        status = try await relaunched.coordinator.statusSnapshot()
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.reportStatus, .pending)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)

        await relaunched.coordinator.runPendingWork()
        status = try await relaunched.coordinator.statusSnapshot()
        var reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(reportedBatches.count, 1)
        XCTAssertEqual(reportedBatches.single?.single?.percentage, 80)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)

        try await relaunched.coordinator.submitGameCenterCandidates([candidate60])
        await relaunched.coordinator.runPendingWork()
        reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(reportedBatches.count, 1)
    }

    func testInterruptedGameCenterReportRecoversAcrossSameCoordinatorReactivation() async throws {
        let gameCenter = GameCenterCoordinatorProbe()
        await gameCenter.suspendReport()
        let fixture = try await CoordinatorFixture(gameCenter: gameCenter)
        let candidate60 = try makeCandidate(percentage: 60, revision: 15)
        let candidate80 = try makeCandidate(percentage: 80, revision: 16)
        try await fixture.coordinator.submitGameCenterCandidates([candidate60])
        try await fixture.coordinator.submit(.optIn)

        let interruptedWork = Task {
            await fixture.coordinator.runPendingWork()
        }
        let reportStarted = await waitForCoordinatorCondition {
            await gameCenter.reportAttemptCount() == 1
        }
        XCTAssertTrue(reportStarted)
        try await fixture.coordinator.submitGameCenterCandidates([candidate80])

        await fixture.coordinator.deactivateRuntime()
        await fixture.coordinator.activateRuntime()
        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.reportStatus, .pending)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)

        await gameCenter.resumeReport()
        await interruptedWork.value
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.reportStatus, .pending)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)

        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        var reportedBatches = await gameCenter.reportedBatches()
        XCTAssertEqual(reportedBatches.map { $0.single?.percentage }, [60, 80])
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)

        try await fixture.coordinator.submitGameCenterCandidates([candidate60])
        await fixture.coordinator.runPendingWork()
        reportedBatches = await gameCenter.reportedBatches()
        XCTAssertEqual(reportedBatches.count, 2)
    }

    func testFailedRestoredGameCenterAuthenticationDoesNotPromptAgainOnWake() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let uuidSequence = TestUUIDSequence()
        let first = try await CoordinatorFixture(
            store: store,
            gameCenter: GameCenterCoordinatorProbe(),
            uuidSequence: uuidSequence
        )
        try await first.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 10),
        ])
        try await first.coordinator.submit(.optIn)
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        let freshGameCenter = GameCenterCoordinatorProbe()
        await freshGameCenter.setAuthenticationErrors([.cancelled])
        let relaunched = try await CoordinatorFixture(
            store: store,
            gameCenter: freshGameCenter,
            uuidSequence: uuidSequence
        )

        await relaunched.coordinator.runPendingWork()
        var status = try await relaunched.coordinator.statusSnapshot()
        var authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        var reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reportedBatches, [])
        XCTAssertEqual(status.gameCenter.connection, .cancelled)
        XCTAssertEqual(status.gameCenter.reportStatus, .deferred)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)

        await relaunched.coordinator.wake(.applicationBecameActive)
        await relaunched.coordinator.wake(.connectivityMayHaveChanged)
        await relaunched.coordinator.runPendingWork()
        status = try await relaunched.coordinator.statusSnapshot()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reportedBatches, [])
        XCTAssertEqual(status.gameCenter.connection, .authenticationAvailable)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)
    }

    func testRestoredAuthenticationRetriesPresentationUnavailableOnceWhenApplicationBecomesActive() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let uuidSequence = TestUUIDSequence()
        let first = try await CoordinatorFixture(
            store: store,
            gameCenter: GameCenterCoordinatorProbe(),
            uuidSequence: uuidSequence
        )
        try await first.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 11),
        ])
        try await first.coordinator.submit(.optIn)
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        let freshGameCenter = GameCenterCoordinatorProbe()
        await freshGameCenter.setAuthenticationErrors([
            .authenticationPresentationUnavailable,
        ])
        let relaunched = try await CoordinatorFixture(
            store: store,
            gameCenter: freshGameCenter,
            uuidSequence: uuidSequence
        )

        await relaunched.coordinator.runPendingWork()
        var authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)

        await relaunched.coordinator.wake(.connectivityMayHaveChanged)
        await relaunched.coordinator.runPendingWork()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)

        await relaunched.coordinator.wake(.applicationBecameActive)
        await relaunched.coordinator.runPendingWork()
        var status = try await relaunched.coordinator.statusSnapshot()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        var reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 2)
        XCTAssertEqual(reportedBatches.count, 1)
        XCTAssertEqual(status.gameCenter.connection, .connected)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)

        await relaunched.coordinator.wake(.applicationBecameActive)
        await relaunched.coordinator.runPendingWork()
        status = try await relaunched.coordinator.statusSnapshot()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 2)
        XCTAssertEqual(reportedBatches.count, 1)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
    }

    func testExplicitOptInDoesNotRaceRestoredAuthenticationAlreadyInFlight() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let uuidSequence = TestUUIDSequence()
        let first = try await CoordinatorFixture(
            store: store,
            gameCenter: GameCenterCoordinatorProbe(),
            uuidSequence: uuidSequence
        )
        try await first.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 12),
        ])
        try await first.coordinator.submit(.optIn)
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        let freshGameCenter = GameCenterCoordinatorProbe()
        await freshGameCenter.suspendAuthenticationRequest()
        let relaunched = try await CoordinatorFixture(
            store: store,
            gameCenter: freshGameCenter,
            uuidSequence: uuidSequence
        )
        let pendingWork = Task {
            await relaunched.coordinator.runPendingWork()
        }
        let authenticationStarted = await waitForCoordinatorCondition {
            await freshGameCenter.authenticationRequestCount() == 1
        }
        XCTAssertTrue(authenticationStarted)

        try await relaunched.coordinator.submit(.optIn)
        var authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)

        await freshGameCenter.resumeAuthenticationRequest()
        await pendingWork.value
        let status = try await relaunched.coordinator.statusSnapshot()
        authenticationRequestCount = await freshGameCenter.authenticationRequestCount()
        let reportedBatches = await freshGameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reportedBatches.count, 1)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
    }

    func testCloudRemoteFactsWaitForExplicitLocalApplyBeforeAnyUpload() async throws {
        let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
        let remote = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 2,
            unlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!]
        )
        let cloud = try CloudCoordinatorProbe(
            remotePayload: CloudProgressionCodec.encode(remote)
        )
        let fixture = try await CoordinatorFixture(cloud: cloud)
        let projection = try RuntimeCloudProgressionProjection(
            replica: local,
            localRevision: 4,
            availableCodexIDs: [CodexID(rawValue: "codex.norse")!, CodexID(rawValue: "codex.moonleaf")!],
            fallbackCodexID: CodexID(rawValue: "codex.norse")!,
            knownUnlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!],
            knownCodexIDs: [
                CodexID(rawValue: "codex.norse")!,
                CodexID(rawValue: "codex.moonleaf")!,
            ]
        )

        try await fixture.coordinator.submitCloudProjection(projection)
        await fixture.coordinator.runPendingWork()

        let delivery = await fixture.coordinator.pendingCloudMergeDelivery()
        XCTAssertEqual(delivery?.sourceLocalRevision, 4)
        XCTAssertEqual(delivery?.replica.unlockIDs, remote.unlockIDs)
        let savedPayloads = await cloud.savedPayloads()
        XCTAssertEqual(savedPayloads, [])
        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .awaitingLocalApply)
        XCTAssertEqual(status.cloudSync.pendingRevision, 4)
        XCTAssertTrue(status.cloudSync.localProgressionAvailable)
    }

    func testOfflineCloudFailureRemainsDurablyQueuedForRetry() async throws {
        let cloud = try CloudCoordinatorProbe(remotePayload: nil, fetchError: .offline)
        let fixture = try await CoordinatorFixture(cloud: cloud)

        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 9)
        )
        await fixture.coordinator.runPendingWork()

        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .waitingForNetwork)
        XCTAssertEqual(status.cloudSync.pendingRevision, 9)
        XCTAssertTrue(status.cloudSync.persistenceIsDurable)
        let fetchCount = await cloud.fetchCount()
        let savedPayloads = await cloud.savedPayloads()
        XCTAssertEqual(fetchCount, 1)
        XCTAssertEqual(savedPayloads, [])
    }

    func testAccountScopeRecheckDiscardsBlockedOldAccountFetchBeforeRebind() async throws {
        let remote = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 2,
            unlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!]
        )
        let cloud = BlockingCloudCoordinatorProbe()
        let fixture = try await CoordinatorFixture(cloudTransport: cloud)
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 4)
        )

        let work = Task { await fixture.coordinator.runPendingWork() }
        await cloud.waitUntilFetchStarted()
        await cloud.setAccountScope(character: "b")
        try await cloud.resumeFetch(payload: CloudProgressionCodec.encode(remote))
        await work.value

        let pending = await fixture.coordinator.pendingCloudMergeDelivery()
        let saves = await cloud.savedPayloads()
        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertNil(pending)
        XCTAssertEqual(saves, [])
        XCTAssertEqual(status.cloudSync.pendingRevision, 4)
        XCTAssertEqual(status.cloudSync.phase, .accountChangeRequiresRebind)
        try await fixture.coordinator.rebindCloudAccount()
    }

    func testRebindIsAtomicallyRejectedWhileMergeAwaitsLocalApply() async throws {
        let remote = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 2,
            unlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!]
        )
        let cloud = try CloudCoordinatorProbe(
            remotePayload: CloudProgressionCodec.encode(remote)
        )
        let fixture = try await CoordinatorFixture(cloud: cloud)
        let projection = try RuntimeCloudProgressionProjection(
            replica: CloudProgressionReplica(catalogVersion: 1, logicalClock: 4),
            localRevision: 4,
            availableCodexIDs: [
                CodexID(rawValue: "codex.norse")!,
                CodexID(rawValue: "codex.moonleaf")!,
            ],
            fallbackCodexID: CodexID(rawValue: "codex.norse")!,
            knownUnlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!],
            knownCodexIDs: [
                CodexID(rawValue: "codex.norse")!,
                CodexID(rawValue: "codex.moonleaf")!,
            ]
        )
        try await fixture.coordinator.submitCloudProjection(projection)
        await fixture.coordinator.runPendingWork()
        let pendingBeforeRebind = await fixture.coordinator.pendingCloudMergeDelivery()
        let delivery = try XCTUnwrap(pendingBeforeRebind)

        await XCTAssertThrowsErrorAsync {
            try await fixture.coordinator.rebindCloudAccount()
        }
        let pendingAfterRebind = await fixture.coordinator.pendingCloudMergeDelivery()
        XCTAssertEqual(pendingAfterRebind?.deliveryID, delivery.deliveryID)
    }

    func testIdleAccountChangeRequiresExplicitRebindAndPreservesLocalProjection() async throws {
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let fixture = try await CoordinatorFixture(cloud: cloud)
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 12)
        )
        await fixture.coordinator.runPendingWork()
        await cloud.setAccountScope(character: "b")

        await fixture.coordinator.wake(.applicationBecameActive)
        await fixture.coordinator.runPendingWork()
        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .accountChangeRequiresRebind)
        XCTAssertEqual(status.cloudSync.localRevision, 12)

        try await fixture.coordinator.rebindCloudAccount()
        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .current)
        XCTAssertEqual(status.cloudSync.localRevision, 12)
        let fetchCount = await cloud.fetchCount()
        XCTAssertEqual(fetchCount, 2)
    }

    func testAutomaticCloudProbeRecoversOfflineWorkWithoutAnotherLifecycleEvent() async throws {
        let clock = CoordinatorTestClock()
        let sleeper = CoordinatorTestSleeper(clock: clock)
        let cloud = try CloudCoordinatorProbe(remotePayload: nil, fetchError: .offline)
        let fixture = try await CoordinatorFixture(
            cloud: cloud,
            automaticScheduling: true,
            clock: clock,
            sleeper: sleeper
        )
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 20)
        )

        let reachedOffline = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let pendingSleeps = await sleeper.pendingCount()
            return status?.cloudSync.phase == .waitingForNetwork
                && pendingSleeps > 0
        }
        XCTAssertTrue(reachedOffline)
        await cloud.setFetchError(nil)
        await sleeper.resumeNext()

        let recovered = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let savedCount = await cloud.savedPayloads().count
            return status?.cloudSync.phase == .current
                && status?.cloudSync.pendingRevision == nil
                && savedCount == 1
        }
        XCTAssertTrue(recovered)
        await fixture.coordinator.deactivateRuntime()
        await sleeper.resumeAll()
    }

    func testAutomaticCloudProbeRecoversWhenAccountBecomesAvailable() async throws {
        let clock = CoordinatorTestClock()
        let sleeper = CoordinatorTestSleeper(clock: clock)
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        await cloud.setAccountState(.noAccount)
        let fixture = try await CoordinatorFixture(
            cloud: cloud,
            automaticScheduling: true,
            clock: clock,
            sleeper: sleeper
        )
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 21)
        )

        let reachedWaitingForAccount = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let pendingSleeps = await sleeper.pendingCount()
            return status?.cloudSync.phase == .waitingForAccount
                && pendingSleeps > 0
        }
        XCTAssertTrue(reachedWaitingForAccount)
        await cloud.setAccountState(.available)
        await sleeper.resumeNext()

        let accountRecovered = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let savedCount = await cloud.savedPayloads().count
            return status?.cloudSync.phase == .current
                && savedCount == 1
        }
        XCTAssertTrue(accountRecovered)
        await fixture.coordinator.deactivateRuntime()
        await sleeper.resumeAll()
    }

    func testPeriodicInboundPollDeliversRemoteOnlyProgressToPassiveDevice() async throws {
        let clock = CoordinatorTestClock()
        let sleeper = CoordinatorTestSleeper(clock: clock)
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let fixture = try await CoordinatorFixture(
            cloud: cloud,
            automaticScheduling: true,
            clock: clock,
            sleeper: sleeper
        )
        let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
        let projection = try projectionAllowingMoonleaf(localRevision: 22, replica: local)
        try await fixture.coordinator.submitCloudProjection(projection)

        let initialSyncCompleted = await waitForCoordinatorCondition {
            let savedCount = await cloud.savedPayloads().count
            let pendingSleeps = await sleeper.pendingCount()
            return savedCount == 1 && pendingSleeps > 0
        }
        XCTAssertTrue(initialSyncCompleted)
        let remote = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 2,
            unlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!]
        )
        await cloud.setRemotePayload(try CloudProgressionCodec.encode(remote))
        await sleeper.resumeNext()

        let remoteWasDelivered = await waitForCoordinatorCondition {
            let pending = await fixture.coordinator.pendingCloudMergeDelivery()
            let status = try? await fixture.coordinator.statusSnapshot()
            return pending?.replica.unlockIDs == remote.unlockIDs
                && status?.cloudSync.phase == .awaitingLocalApply
        }
        XCTAssertTrue(remoteWasDelivered)
        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .awaitingLocalApply)
        await fixture.coordinator.deactivateRuntime()
        await sleeper.resumeAll()
    }

    func testSaveConflictRefetchesAndRetriesWithoutDroppingQueuedRevision() async throws {
        let clock = CoordinatorTestClock()
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        await cloud.setSaveErrors([.conflict])
        let fixture = try await CoordinatorFixture(cloud: cloud, clock: clock)
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 23)
        )
        await fixture.coordinator.runPendingWork()

        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .queued)
        XCTAssertEqual(status.cloudSync.pendingRevision, 23)
        let firstSaveAttemptCount = await cloud.saveAttempts()
        XCTAssertEqual(firstSaveAttemptCount, 1)

        clock.advance(by: 10)
        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .current)
        XCTAssertNil(status.cloudSync.pendingRevision)
        let fetchCount = await cloud.fetchCount()
        let saveAttemptCount = await cloud.saveAttempts()
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(saveAttemptCount, 2)
    }

    func testRetryExhaustionSurvivesRelaunchAndProbePreservesPendingRevision() async throws {
        let clock = CoordinatorTestClock()
        let store = InMemoryModuleStateStore(now: { clock.now() })
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let uuidSequence = TestUUIDSequence()
        let maximumAttemptCount = Int(CloudSyncRetryPolicy.maximumAttemptCount)
        await cloud.setSaveErrors(
            Array(repeating: .serviceUnavailable, count: maximumAttemptCount)
        )
        let projection = try makeProjection(localRevision: 27)
        let first = try await CoordinatorFixture(
            store: store,
            cloud: cloud,
            clock: clock,
            uuidSequence: uuidSequence
        )
        try await first.coordinator.submitCloudProjection(projection)

        for attempt in 1 ... maximumAttemptCount {
            await first.coordinator.runPendingWork()
            let status = try await first.coordinator.statusSnapshot()
            let saveAttemptCount = await cloud.saveAttempts()
            XCTAssertEqual(status.cloudSync.pendingRevision, 27)
            XCTAssertEqual(saveAttemptCount, attempt)
            if attempt < maximumAttemptCount {
                XCTAssertEqual(status.cloudSync.phase, .queued)
                clock.advance(by: CloudSyncRetryPolicy.maximumDelay)
            } else {
                XCTAssertEqual(status.cloudSync.phase, .retryExhausted)
            }
        }

        var status = try await first.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .retryExhausted)
        XCTAssertEqual(status.cloudSync.pendingRevision, 27)
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        let relaunched = try await CoordinatorFixture(
            store: store,
            cloud: cloud,
            clock: clock,
            uuidSequence: uuidSequence
        )
        status = try await relaunched.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .retryExhausted)
        XCTAssertEqual(status.cloudSync.pendingRevision, 27)

        try await relaunched.coordinator.submitCloudProjection(projection)
        status = try await relaunched.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .retryExhausted)
        XCTAssertEqual(status.cloudSync.pendingRevision, 27)

        await relaunched.coordinator.wake(.retryDeadlineReached)
        await relaunched.coordinator.runPendingWork()
        status = try await relaunched.coordinator.statusSnapshot()
        let recoveredSaveAttemptCount = await cloud.saveAttempts()
        let savedPayloadCount = await cloud.savedPayloads().count
        XCTAssertEqual(status.cloudSync.phase, .current)
        XCTAssertNil(status.cloudSync.pendingRevision)
        XCTAssertEqual(recoveredSaveAttemptCount, maximumAttemptCount + 1)
        XCTAssertEqual(savedPayloadCount, 1)
    }

    func testCorruptRemoteIsQuarantinedAndReplacedWithValidatedLocalReplica() async throws {
        let cloud = try CloudCoordinatorProbe(remotePayload: Data("not-json".utf8))
        let fixture = try await CoordinatorFixture(cloud: cloud)
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 24)
        )
        await fixture.coordinator.runPendingWork()

        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .quarantinedRemote)
        XCTAssertEqual(status.cloudSync.quarantineCount, 1)
        let savedPayload = await cloud.savedPayloads().last
        let saved = try XCTUnwrap(savedPayload)
        let replacement = try CloudProgressionCodec.decode(saved)
        XCTAssertEqual(replacement.catalogVersion, 1)
        XCTAssertEqual(replacement.quarantineDiagnostics.count, 1)
    }

    func testNearMaximumRemoteSelectionClockIsQuarantinedBeforeRuntimeAdoption() async throws {
        let localCodex = CodexID(rawValue: "codex.norse")!
        let remoteCodex = CodexID(rawValue: "codex.moonleaf")!
        let local = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 24,
            selectedCodex: CloudCodexSelection(
                codexID: localCodex,
                logicalTimestamp: 24,
                writerDeviceID: CloudOpaqueIdentifier(
                    rawValue: String(repeating: "a", count: 64)
                )!,
                updatedAt: testDate.addingTimeInterval(-2)
            )
        )
        let remote = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: UInt64.max - 2,
            selectedCodex: CloudCodexSelection(
                codexID: remoteCodex,
                logicalTimestamp: UInt64.max - 2,
                writerDeviceID: CloudOpaqueIdentifier(
                    rawValue: String(repeating: "b", count: 64)
                )!,
                updatedAt: testDate.addingTimeInterval(-1)
            )
        )
        let cloud = try CloudCoordinatorProbe(
            remotePayload: CloudProgressionCodec.encode(remote)
        )
        let fixture = try await CoordinatorFixture(cloud: cloud)
        try await fixture.coordinator.submitCloudProjection(
            projectionAllowingMoonleaf(localRevision: 24, replica: local)
        )
        await fixture.coordinator.runPendingWork()

        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .quarantinedRemote)
        XCTAssertEqual(status.cloudSync.quarantineCount, 1)
        let pendingDelivery = await fixture.coordinator.pendingCloudMergeDelivery()
        XCTAssertNil(pendingDelivery)
        let savedPayload = await cloud.savedPayloads().last
        let saved = try XCTUnwrap(savedPayload)
        let replacement = try CloudProgressionCodec.decode(saved)
        XCTAssertEqual(replacement.selectedCodex?.codexID, localCodex)
        XCTAssertEqual(replacement.selectedCodex?.logicalTimestamp, 24)
        XCTAssertEqual(replacement.quarantineDiagnostics.count, 1)
    }

    func testAlreadyYieldedMergeIsRevokedWhenAccountChangesBeforeAcknowledge() async throws {
        let remote = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 2,
            unlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!]
        )
        let cloud = try CloudCoordinatorProbe(
            remotePayload: CloudProgressionCodec.encode(remote)
        )
        let fixture = try await CoordinatorFixture(cloud: cloud)
        try await fixture.coordinator.submitCloudProjection(
            projectionAllowingMoonleaf(
                localRevision: 25,
                replica: try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
            )
        )
        await fixture.coordinator.runPendingWork()
        let pendingDelivery = await fixture.coordinator.pendingCloudMergeDelivery()
        let delivery = try XCTUnwrap(pendingDelivery)
        await cloud.setAccountScope(character: "b")

        await XCTAssertThrowsErrorAsync {
            try await fixture.coordinator.acknowledgeCloudMerge(
                deliveryID: delivery.deliveryID,
                updatedProjection: try projectionAllowingMoonleaf(
                    localRevision: 26,
                    replica: remote
                )
            )
        }
        let pendingAfterRevocation = await fixture.coordinator.pendingCloudMergeDelivery()
        XCTAssertNil(pendingAfterRevocation)
        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .accountChangeRequiresRebind)
        XCTAssertEqual(status.cloudSync.pendingRevision, 26)
        let savesBeforeRebind = await cloud.savedPayloads()
        XCTAssertEqual(savesBeforeRebind, [])

        try await fixture.coordinator.rebindCloudAccount()
        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .current)
        XCTAssertNil(status.cloudSync.pendingRevision)
    }

    func testPriorCompletionReportsOnceAndDuplicateSnapshotCallbackIsIdempotent() async throws {
        let gameCenter = GameCenterCoordinatorProbe()
        let fixture = try await CoordinatorFixture(gameCenter: gameCenter)
        let state = try makeCompletedProgressionState(revision: 30)
        _ = try await fixture.coordinator.submitProgressionSnapshot(
            state.snapshot,
            projection: state.projection
        )
        try await fixture.coordinator.submit(.optIn)
        await fixture.coordinator.runPendingWork()

        _ = try await fixture.coordinator.submitProgressionSnapshot(
            state.snapshot,
            projection: state.projection
        )
        await fixture.coordinator.runPendingWork()
        let batches = await gameCenter.reportedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.single?.single?.percentage, 100)
        let reportAttemptCount = await gameCenter.reportAttemptCount()
        XCTAssertEqual(reportAttemptCount, 1)
    }

    func testGameCenterDenialPreservesQueueAndLaterExplicitOptInReplays() async throws {
        let gameCenter = GameCenterCoordinatorProbe()
        await gameCenter.setAuthenticationErrors([.denied])
        let fixture = try await CoordinatorFixture(gameCenter: gameCenter)
        try await fixture.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 31),
        ])

        try await fixture.coordinator.submit(.optIn)
        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.connection, .declined)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)
        var reportAttemptCount = await gameCenter.reportAttemptCount()
        XCTAssertEqual(reportAttemptCount, 0)

        try await fixture.coordinator.submit(.optIn)
        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
        reportAttemptCount = await gameCenter.reportAttemptCount()
        XCTAssertEqual(reportAttemptCount, 1)
    }

    func testGameCenterOptOutPreservesQueueAndReOptInReplays() async throws {
        let gameCenter = GameCenterCoordinatorProbe()
        let fixture = try await CoordinatorFixture(gameCenter: gameCenter)
        try await fixture.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 32),
        ])
        try await fixture.coordinator.submit(.optIn)
        try await fixture.coordinator.submit(.optOut)
        await fixture.coordinator.runPendingWork()

        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.connection, .disabled)
        XCTAssertFalse(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 1)
        var reportAttemptCount = await gameCenter.reportAttemptCount()
        XCTAssertEqual(reportAttemptCount, 0)

        try await fixture.coordinator.submit(.optIn)
        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        reportAttemptCount = await gameCenter.reportAttemptCount()
        XCTAssertEqual(reportAttemptCount, 1)
    }

    func testAutomaticGameCenterProbeRecoversOfflineReportWithoutNewInput() async throws {
        let clock = CoordinatorTestClock()
        let sleeper = CoordinatorTestSleeper(clock: clock)
        let gameCenter = GameCenterCoordinatorProbe()
        await gameCenter.setReportErrors([.offline])
        let fixture = try await CoordinatorFixture(
            gameCenter: gameCenter,
            automaticScheduling: true,
            clock: clock,
            sleeper: sleeper
        )
        try await fixture.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 33),
        ])
        try await fixture.coordinator.submit(.optIn)

        let offlineWasObserved = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let pendingSleeps = await sleeper.pendingCount()
            return status?.gameCenter.connection == .offline
                && status?.gameCenter.pendingReportCount == 1
                && pendingSleeps > 0
        }
        XCTAssertTrue(offlineWasObserved)
        await sleeper.resumeNext()
        let reportingRecovered = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let attempts = await gameCenter.reportAttemptCount()
            return status?.gameCenter.reportStatus == .mirrored
                && attempts == 2
        }
        XCTAssertTrue(reportingRecovered)
        await fixture.coordinator.deactivateRuntime()
        await sleeper.resumeAll()
    }

    func testGameCenterAccountChangeRequeuesPriorLocalCompletionForNewScope() async throws {
        let clock = CoordinatorTestClock()
        let sleeper = CoordinatorTestSleeper(clock: clock)
        let gameCenter = GameCenterCoordinatorProbe()
        let fixture = try await CoordinatorFixture(
            gameCenter: gameCenter,
            automaticScheduling: true,
            clock: clock,
            sleeper: sleeper
        )
        try await fixture.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 34),
        ])
        try await fixture.coordinator.submit(.optIn)
        let firstScopeWasReported = await waitForCoordinatorCondition {
            let batches = await gameCenter.reportedBatches().count
            let pendingSleeps = await sleeper.pendingCount()
            return batches == 1 && pendingSleeps > 0
        }
        XCTAssertTrue(firstScopeWasReported)

        await gameCenter.setAccountScope(character: "b")
        await sleeper.resumeNext()
        let secondScopeWasReported = await waitForCoordinatorCondition {
            let batches = await gameCenter.reportedBatches().count
            let status = try? await fixture.coordinator.statusSnapshot()
            return batches == 2
                && status?.gameCenter.reportStatus == .mirrored
                && status?.gameCenter.pendingReportCount == 0
        }
        XCTAssertTrue(secondScopeWasReported)
        let status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
        await fixture.coordinator.deactivateRuntime()
        await sleeper.resumeAll()
    }

    func testUnavailableInitialLoadRecoversExistingDurableOutboxWithoutOverwrite() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let first = try await CoordinatorFixture(store: store)
        try await first.coordinator.submitGameCenterCandidates([
            makeCandidate(percentage: 100, revision: 40),
        ])
        try await first.coordinator.submit(.optIn)
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        await store.injectFault(at: .scan)
        let gameCenter = GameCenterCoordinatorProbe()
        let recovered = try await CoordinatorFixture(
            store: store,
            gameCenter: gameCenter
        )
        var status = try await recovered.coordinator.statusSnapshot()
        XCTAssertFalse(status.cloudSync.persistenceIsDurable)

        await recovered.coordinator.runPendingWork()
        status = try await recovered.coordinator.statusSnapshot()
        XCTAssertTrue(status.cloudSync.persistenceIsDurable)
        XCTAssertTrue(status.gameCenter.isOptedIn)
        XCTAssertEqual(status.gameCenter.connection, .connected)
        XCTAssertEqual(status.gameCenter.reportStatus, .mirrored)
        XCTAssertEqual(status.gameCenter.pendingReportCount, 0)
        var authenticationRequestCount = await gameCenter.authenticationRequestCount()
        XCTAssertEqual(authenticationRequestCount, 1)
        var reported = await gameCenter.reportedBatches()
        XCTAssertEqual(reported.count, 1)
        XCTAssertEqual(reported.single?.single?.percentage, 100)

        await recovered.coordinator.wake(.applicationBecameActive)
        await recovered.coordinator.runPendingWork()
        authenticationRequestCount = await gameCenter.authenticationRequestCount()
        reported = await gameCenter.reportedBatches()
        XCTAssertEqual(authenticationRequestCount, 1)
        XCTAssertEqual(reported.count, 1)
    }

    func testPersistenceProbeFailsClosedThenRecoversQueuedCloudWorkAutomatically() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        await store.injectFault(at: .beforeTransactionCommit, count: 3)
        let clock = CoordinatorTestClock()
        let sleeper = CoordinatorTestSleeper(clock: clock)
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let fixture = try await CoordinatorFixture(
            store: store,
            cloud: cloud,
            automaticScheduling: true,
            clock: clock,
            sleeper: sleeper
        )
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 41)
        )

        let persistenceFailureWasProjected = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let pendingSleeps = await sleeper.pendingCount()
            let fetchCount = await cloud.fetchCount()
            return status?.cloudSync.phase == .persistenceDegraded
                && status?.cloudSync.pendingRevision == 41
                && pendingSleeps > 0
                && fetchCount == 0
        }
        XCTAssertTrue(persistenceFailureWasProjected)

        await sleeper.resumeNext()
        let persistenceRecovered = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            let savedCount = await cloud.savedPayloads().count
            return status?.cloudSync.persistenceIsDurable == true
                && status?.cloudSync.phase == .current
                && status?.cloudSync.pendingRevision == nil
                && savedCount == 1
        }
        XCTAssertTrue(persistenceRecovered)
        await fixture.coordinator.deactivateRuntime()
        await sleeper.resumeAll()
    }

    func testInvalidCoordinatorRecordIsPhysicallyQuarantinedAndRebuiltWithoutRelaunch() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let namespace = ModuleStateNamespace(
            moduleID: "com.runescribe.runtime.cloud-game-center"
        )
        let collectionID = ModuleStateCollectionID(
            rawValue: "external-services.state"
        )!
        let key = ModuleStateRecordKey(
            collectionID: collectionID,
            recordID: ModuleStateRecordID(rawValue: "orchestration")!
        )
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        _ = try await store.transact(
            namespace: namespace,
            transaction: ModuleStateTransaction(
                transactionID: UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!,
                mutations: [.upsert(ModuleStateUpsert(
                    key: key,
                    schemaVersion: 1,
                    payload: Data("invalid-coordinator-state".utf8),
                    expectedRevision: .absent
                ))]
            )
        )
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let fixture = try await CoordinatorFixture(store: store, cloud: cloud)

        var status = try await fixture.coordinator.statusSnapshot()
        XCTAssertTrue(status.cloudSync.persistenceIsDurable)
        XCTAssertEqual(status.cloudSync.quarantineCount, 1)
        try await fixture.coordinator.submitCloudProjection(
            makeProjection(localRevision: 42)
        )
        await fixture.coordinator.runPendingWork()
        status = try await fixture.coordinator.statusSnapshot()
        XCTAssertEqual(status.cloudSync.phase, .current)
        XCTAssertTrue(status.cloudSync.persistenceIsDurable)
        let health = await store.health(namespace: namespace)
        XCTAssertEqual(health.quarantinedRecordCount, 1)
        XCTAssertEqual(health.recordCount, 1)
    }

    func testSelectedCodexSettingOnlyChangeEnqueuesAndUploadsNewProjection() async throws {
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let store = InMemoryModuleStateStore(now: { testDate })
        let settingsNamespace = ModuleStateNamespace(
            moduleID: "com.runescribe.runtime.settings"
        )
        _ = try await store.prepareNamespace(settingsNamespace, schemaVersion: 1)
        let selectedCodexKey = ModuleStateRecordKey(
            collectionID: ModuleStateCollectionID(rawValue: "settings.values")!,
            recordID: ModuleStateRecordID(
                rawValue: RuneScribeRuntimeSettings.selectedCodex.rawValue
            )!
        )
        _ = try await store.transact(
            namespace: settingsNamespace,
            transaction: ModuleStateTransaction(
                transactionID: UUID(),
                mutations: [
                    .upsert(ModuleStateUpsert(
                        key: selectedCodexKey,
                        schemaVersion: 1,
                        payload: try JSONEncoder().encode(
                            RuntimeSettingValue.text(
                                RuntimeSettingText(rawValue: "codex.norse")!
                            )
                        ),
                        expectedRevision: .absent
                    )),
                ]
            )
        )
        let fixture = try await CoordinatorFixture(
            store: store,
            cloud: cloud,
            includeSettings: true
        )
        let settingsGateway = try XCTUnwrap(fixture.settingsGateway)
        let migratedSettings = try await settingsGateway.snapshot()
        let migratedText = try XCTUnwrap(
            migratedSettings[RuneScribeRuntimeSettings.selectedCodex]?.textValue
        )
        XCTAssertNoThrow(
            try RuntimeSelectedCodexPreferenceCodec.decodeCurrentWrite(migratedText)
        )
        let state = try makeCompletedProgressionState(
            revision: 50,
            includeMoonleaf: true
        )
        _ = try await fixture.coordinator.submitProgressionSnapshot(
            state.snapshot,
            projection: state.projection
        )
        await fixture.coordinator.runPendingWork()
        var saves = await cloud.savedPayloads()
        XCTAssertEqual(saves.count, 1)
        XCTAssertEqual(
            try CloudProgressionCodec.decode(saves[0]).selectedCodex?.codexID,
            CodexID(rawValue: "codex.norse")!
        )

        let moonleaf = try XCTUnwrap(CodexID(rawValue: "codex.moonleaf"))
        _ = try await settingsGateway.set(SetRuntimeSettingCommand(
            settingID: RuneScribeRuntimeSettings.selectedCodex,
            value: .text(try RuntimeSelectedCodexPreferenceCodec.encode(
                RuntimeSelectedCodexPreference(codexID: moonleaf)
            ))
        ))
        let settingChangeWasQueued = await waitForCoordinatorCondition {
            let status = try? await fixture.coordinator.statusSnapshot()
            return status?.cloudSync.pendingRevision != nil
        }
        XCTAssertTrue(settingChangeWasQueued)
        await fixture.coordinator.runPendingWork()

        saves = await cloud.savedPayloads()
        XCTAssertEqual(saves.count, 2)
        let updated = try CloudProgressionCodec.decode(saves[1])
        XCTAssertEqual(
            updated.selectedCodex?.codexID,
            CodexID(rawValue: "codex.moonleaf")!
        )
        let submissionState = await fixture.coordinator.selectedCodexCloudSubmissionState()
        XCTAssertEqual(submissionState, .idle)
    }

    func testCounterImportCrashWindowDoesNotAmplifyDeviceShardsAfterRelaunch() async throws {
        let store = InMemoryModuleStateStore(now: { testDate })
        let cloud = try CloudCoordinatorProbe(remotePayload: nil)
        let first = try await CoordinatorFixture(store: store, cloud: cloud)
        let localFive = try makeCounterProgressionState(revision: 60, total: 5)
        _ = try await first.coordinator.submitProgressionSnapshot(
            localFive.snapshot,
            projection: localFive.projection
        )
        await first.coordinator.runPendingWork()
        let initialRemotePayload = await cloud.currentRemotePayload()
        let firstPayload = try XCTUnwrap(initialRemotePayload)
        let firstReplica = try CloudProgressionCodec.decode(firstPayload)
        XCTAssertEqual(firstReplica.deviceCounterShards.map(\.value), [5])

        let statisticID = StatisticID(rawValue: "stat.synthetic.device-counter")!
        let divergent = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: firstReplica.logicalClock + 1,
            deviceCounterShards: firstReplica.deviceCounterShards + [
                CloudDeviceCounterShard(
                    statisticID: statisticID,
                    deviceID: CloudOpaqueIdentifier(
                        rawValue: String(repeating: "b", count: 64)
                    )!,
                    value: 7,
                    lastUpdatedAt: testDate
                ),
            ]
        )
        await cloud.setRemotePayload(try CloudProgressionCodec.encode(divergent))
        await first.coordinator.wake(.explicitRequest)
        await first.coordinator.runPendingWork()
        let pendingBeforeCrash = await first.coordinator.pendingCloudMergeDelivery()
        XCTAssertNotNil(pendingBeforeCrash)

        // Progression commits the imported total, then the process terminates
        // before Runtime can acknowledge the delivery.
        await first.coordinator.deactivateRuntime()
        await first.platformGateway.deactivateRuntime()
        await first.stateGateway.deactivateRuntime()

        let relaunched = try await CoordinatorFixture(store: store, cloud: cloud)
        let authoritativeTwelve = try makeCounterProgressionState(
            revision: 61,
            total: 12
        )
        _ = try await relaunched.coordinator.submitProgressionSnapshot(
            authoritativeTwelve.snapshot,
            projection: authoritativeTwelve.projection
        )
        await relaunched.coordinator.runPendingWork()
        let pendingAfterRelaunch = await relaunched.coordinator
            .pendingCloudMergeDelivery()
        let replayedDelivery = try XCTUnwrap(pendingAfterRelaunch)
        try await relaunched.coordinator.acknowledgeProgressionMerge(
            deliveryID: replayedDelivery.deliveryID,
            snapshot: authoritativeTwelve.snapshot,
            projection: authoritativeTwelve.projection
        )
        await relaunched.coordinator.runPendingWork()

        let remoteAfterAcknowledge = await cloud.currentRemotePayload()
        let convergedPayload = try XCTUnwrap(remoteAfterAcknowledge)
        let converged = try CloudProgressionCodec.decode(convergedPayload)
        XCTAssertEqual(converged.deviceCounterShards.map(\.value).sorted(), [5, 7])
        XCTAssertEqual(
            converged.deviceCounterShards.reduce(UInt64(0)) { $0 + $1.value },
            12
        )

        await relaunched.coordinator.wake(.explicitRequest)
        await relaunched.coordinator.runPendingWork()
        let pendingAfterRepeat = await relaunched.coordinator.pendingCloudMergeDelivery()
        XCTAssertNil(pendingAfterRepeat)
        let remoteAfterRepeat = await cloud.currentRemotePayload()
        let repeatedPayload = try XCTUnwrap(remoteAfterRepeat)
        let repeated = try CloudProgressionCodec.decode(repeatedPayload)
        XCTAssertEqual(
            repeated.deviceCounterShards.reduce(UInt64(0)) { $0 + $1.value },
            12
        )
    }
}

private struct CoordinatorFixture {
    let stateGateway: RuntimeModuleStateGateway
    let platformGateway: RuntimeCloudGameCenterGateway
    let coordinator: RuntimeCloudGameCenterCoordinator
    let environment: RuntimeEnvironment
    let settingsGateway: RuntimeSettingsGateway?

    init(
        includeStore: Bool = true,
        store: InMemoryModuleStateStore? = nil,
        cloud: CloudCoordinatorProbe? = nil,
        gameCenter: GameCenterCoordinatorProbe? = nil,
        cloudTransport: (any CloudSyncTransport)? = nil,
        automaticScheduling: Bool = false,
        clock: CoordinatorTestClock? = nil,
        sleeper: CoordinatorTestSleeper? = nil,
        includeSettings: Bool = false,
        uuidSequence: TestUUIDSequence? = nil
    ) async throws {
        let UUIDs = uuidSequence ?? TestUUIDSequence()
        let environment = RuntimeEnvironment(
            now: { clock?.now() ?? testDate },
            nextUUID: { UUIDs.next() }
        )
        let stateGateway = RuntimeModuleStateGateway(policy: .patternBFoundation)
        if includeStore {
            try await stateGateway.install(store ?? InMemoryModuleStateStore(now: { testDate }))
        }
        _ = await stateGateway.activateRuntime()

        let platformGateway = RuntimeCloudGameCenterGateway(environment: environment)
        if let cloudTransport {
            try await platformGateway.install(cloudTransport)
        } else if let cloud {
            try await platformGateway.install(cloud)
        }
        if let gameCenter { try await platformGateway.install(gameCenter) }
        await platformGateway.activateRuntime()

        let settingsGateway: RuntimeSettingsGateway?
        if includeSettings {
            let gateway = RuntimeSettingsGateway(
                state: stateGateway,
                environment: environment
            )
            await gateway.activateRuntime()
            settingsGateway = gateway
        } else {
            settingsGateway = nil
        }

        let sleep: @Sendable (TimeInterval) async -> Void
        if let sleeper {
            sleep = { delay in await sleeper.sleep(delay) }
        } else {
            sleep = { _ in }
        }

        self.stateGateway = stateGateway
        self.platformGateway = platformGateway
        self.environment = environment
        self.settingsGateway = settingsGateway
        coordinator = RuntimeCloudGameCenterCoordinator(
            stateGateway: stateGateway,
            platformGateway: platformGateway,
            environment: environment,
            settingsGateway: settingsGateway,
            automaticScheduling: automaticScheduling,
            sleep: sleep
        )
        await coordinator.activateRuntime()
    }
}

private actor BlockingCloudCoordinatorProbe: CloudSyncTransport {
    private var fetchStarted = false
    private var fetchStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var fetchContinuation: CheckedContinuation<CloudSyncFetchResultDTO, any Error>?
    private var saves: [Data] = []
    private var accountScopeCharacter: Character = "a"

    func accountState() async throws -> CloudAccountStateDTO {
        try CloudAccountStateDTO(
            state: .available,
            accountScopeDigest: CloudAccountScopeDigestDTO(
                rawValue: String(repeating: accountScopeCharacter, count: 64)
            )!
        )
    }

    func fetchPrivateProgression() async throws -> CloudSyncFetchResultDTO {
        fetchStarted = true
        let waiters = fetchStartWaiters
        fetchStartWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        return try await withCheckedThrowingContinuation { continuation in
            fetchContinuation = continuation
        }
    }

    func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO
    ) async throws -> CloudSyncSaveResultDTO {
        saves.append(request.payload)
        return try CloudSyncSaveResultDTO(changeTag: "change-2")
    }

    func waitUntilFetchStarted() async {
        if fetchStarted { return }
        await withCheckedContinuation { continuation in
            fetchStartWaiters.append(continuation)
        }
    }

    func resumeFetch(payload: Data?) throws {
        let continuation = fetchContinuation
        fetchContinuation = nil
        continuation?.resume(
            returning: try CloudSyncFetchResultDTO(
                payload: payload,
                changeTag: payload == nil ? nil : "change-1"
            )
        )
    }

    func savedPayloads() -> [Data] { saves }
    func setAccountScope(character: Character) { accountScopeCharacter = character }
}

private actor CloudCoordinatorProbe: CloudSyncTransport {
    private var remotePayload: Data?
    private var remoteChangeTag: String?
    private var fetchError: CloudSyncTransportError?
    private var saveErrors: [CloudSyncTransportError] = []
    private var accountStateValue: CloudAccountStateValueDTO = .available
    private var fetches = 0
    private var saves: [Data] = []
    private var saveAttemptCount = 0
    private var accountScopeCharacter: Character = "a"

    init(remotePayload: Data?, fetchError: CloudSyncTransportError? = nil) throws {
        self.remotePayload = remotePayload
        remoteChangeTag = remotePayload == nil ? nil : "change-1"
        self.fetchError = fetchError
    }

    func accountState() async throws -> CloudAccountStateDTO {
        try CloudAccountStateDTO(
                state: accountStateValue,
                accountScopeDigest: accountStateValue == .available
                    ? CloudAccountScopeDigestDTO(
                rawValue: String(repeating: accountScopeCharacter, count: 64)
                    )!
                    : nil
        )
    }

    func fetchPrivateProgression() async throws -> CloudSyncFetchResultDTO {
        fetches += 1
        if let fetchError { throw fetchError }
        return try CloudSyncFetchResultDTO(
            payload: remotePayload,
            changeTag: remoteChangeTag
        )
    }

    func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO
    ) async throws -> CloudSyncSaveResultDTO {
        saveAttemptCount += 1
        if !saveErrors.isEmpty { throw saveErrors.removeFirst() }
        saves.append(request.payload)
        remotePayload = request.payload
        remoteChangeTag = "change-\(saveAttemptCount + 1)"
        return try CloudSyncSaveResultDTO(changeTag: remoteChangeTag!)
    }

    func fetchCount() -> Int { fetches }
    func savedPayloads() -> [Data] { saves }
    func saveAttempts() -> Int { saveAttemptCount }
    func setAccountScope(character: Character) { accountScopeCharacter = character }
    func setAccountState(_ state: CloudAccountStateValueDTO) { accountStateValue = state }
    func setFetchError(_ error: CloudSyncTransportError?) { fetchError = error }
    func setSaveErrors(_ errors: [CloudSyncTransportError]) { saveErrors = errors }
    func setRemotePayload(_ payload: Data?) {
        remotePayload = payload
        remoteChangeTag = payload == nil ? nil : "change-remote"
    }
    func currentRemotePayload() -> Data? { remotePayload }
}

private actor GameCenterCoordinatorProbe: GameCenterReporting {
    private var authenticationRequests = 0
    private var reports: [[GameCenterAchievementReportDTO]] = []
    private var reportAttempts = 0
    private var authentication = GameCenterAuthenticationStateDTO.notAuthenticated
    private var authenticationErrors: [GameCenterReportingTransportError] = []
    private var reportErrors: [GameCenterReportingTransportError] = []
    private var accountScopeCharacter: Character = "a"
    private var authenticationRequestShouldWait = false
    private var authenticationRequestContinuation: CheckedContinuation<Void, Never>?
    private var reportShouldWait = false
    private var reportContinuation: CheckedContinuation<Void, Never>?

    func authenticationState() async -> GameCenterAuthenticationStateDTO {
        authentication
    }

    func accountScopeDigest() async -> GameCenterAccountScopeDigestDTO? {
        guard authentication == .authenticated else { return nil }
        return GameCenterAccountScopeDigestDTO(
            rawValue: String(repeating: accountScopeCharacter, count: 64)
        )!
    }

    func requestAuthentication() async throws -> GameCenterAuthenticationStateDTO {
        authenticationRequests += 1
        if authenticationRequestShouldWait {
            await withCheckedContinuation { continuation in
                authenticationRequestContinuation = continuation
            }
        }
        if !authenticationErrors.isEmpty { throw authenticationErrors.removeFirst() }
        authentication = .authenticated
        return authentication
    }

    func report(_ achievements: [GameCenterAchievementReportDTO]) async throws {
        reportAttempts += 1
        if reportShouldWait {
            await withCheckedContinuation { continuation in
                reportContinuation = continuation
            }
        }
        if !reportErrors.isEmpty { throw reportErrors.removeFirst() }
        reports.append(achievements)
    }

    func authenticationRequestCount() -> Int { authenticationRequests }
    func reportedBatches() -> [[GameCenterAchievementReportDTO]] { reports }
    func reportAttemptCount() -> Int { reportAttempts }
    func setAuthentication(_ value: GameCenterAuthenticationStateDTO) {
        authentication = value
    }
    func setAuthenticationErrors(_ errors: [GameCenterReportingTransportError]) {
        authenticationErrors = errors
    }
    func suspendAuthenticationRequest() {
        authenticationRequestShouldWait = true
    }
    func resumeAuthenticationRequest() {
        authenticationRequestShouldWait = false
        let continuation = authenticationRequestContinuation
        authenticationRequestContinuation = nil
        continuation?.resume()
    }
    func setReportErrors(_ errors: [GameCenterReportingTransportError]) {
        reportErrors = errors
    }
    func suspendReport() {
        reportShouldWait = true
    }
    func resumeReport() {
        reportShouldWait = false
        let continuation = reportContinuation
        reportContinuation = nil
        continuation?.resume()
    }
    func setAccountScope(character: Character) { accountScopeCharacter = character }
}

private final class CoordinatorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = testDate) { self.value = value }

    func now() -> Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private actor CoordinatorTestSleeper {
    private struct Request {
        let delay: TimeInterval
        let continuation: CheckedContinuation<Void, Never>
    }

    private let clock: CoordinatorTestClock
    private var requests: [Request] = []

    init(clock: CoordinatorTestClock) { self.clock = clock }

    func sleep(_ delay: TimeInterval) async {
        await withCheckedContinuation { continuation in
            requests.append(Request(delay: delay, continuation: continuation))
        }
    }

    func pendingCount() -> Int { requests.count }

    func resumeNext() {
        guard !requests.isEmpty else { return }
        let request = requests.removeFirst()
        clock.advance(by: request.delay)
        request.continuation.resume()
    }

    func resumeAll() {
        let pending = requests
        requests.removeAll()
        for request in pending { request.continuation.resume() }
    }
}

private final class TestUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt8 = 0

    func next() -> UUID {
        lock.withLock {
            counter &+= 1
            return UUID(uuid: (
                0xa0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, counter
            ))
        }
    }
}

private let testDate = Date(timeIntervalSince1970: 50_000)

private func makeProjection(localRevision: UInt64) throws
    -> RuntimeCloudProgressionProjection
{
    try RuntimeCloudProgressionProjection(
        replica: CloudProgressionReplica(catalogVersion: 1, logicalClock: localRevision),
        localRevision: localRevision,
        availableCodexIDs: [CodexID(rawValue: "codex.norse")!],
        fallbackCodexID: CodexID(rawValue: "codex.norse")!
    )
}

private func projectionAllowingMoonleaf(
    localRevision: UInt64,
    replica: CloudProgressionReplica
) throws -> RuntimeCloudProgressionProjection {
    try RuntimeCloudProgressionProjection(
        replica: replica,
        localRevision: localRevision,
        availableCodexIDs: [
            CodexID(rawValue: "codex.norse")!,
            CodexID(rawValue: "codex.moonleaf")!,
        ],
        fallbackCodexID: CodexID(rawValue: "codex.norse")!,
        knownUnlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!],
        knownCodexIDs: [
            CodexID(rawValue: "codex.norse")!,
            CodexID(rawValue: "codex.moonleaf")!,
        ]
    )
}

private func makeCompletedProgressionState(
    revision: UInt64,
    includeMoonleaf: Bool = false
) throws -> (
    snapshot: ProgressionSnapshotDTO,
    projection: RuntimeProgressionExternalProjection
) {
    let achievementID = AchievementID(rawValue: "achievement.first-inscription")!
    let norse = CodexID(rawValue: "codex.norse")!
    let completedAt = testDate.addingTimeInterval(-10)
    let presentation = try ProgressionPresentationDTO(
        displayName: "First Inscription",
        summary: "Complete",
        fallbackSystemImageName: "star"
    )
    let component = try ProgressionGateComponentDTO(
        componentID: "gate.norse.included",
        label: "Included",
        current: 1,
        target: 1,
        isComplete: true
    )
    let gate = try unlockedCodexGate(
        codexID: norse,
        displayName: "Norse",
        journeyOrder: 0,
        component: component
    )
    let moonleaf = CodexID(rawValue: "codex.moonleaf")!
    let moonleafGate = try unlockedCodexGate(
        codexID: moonleaf,
        displayName: "Moonleaf",
        journeyOrder: 1,
        component: ProgressionGateComponentDTO(
            componentID: "gate.moonleaf.earned",
            label: "Earned",
            current: 1,
            target: 1,
            isComplete: true
        )
    )
    let achievement = try ProgressionAchievementDTO(
        achievementID: achievementID,
        presentation: presentation,
        completedRuleCount: 1,
        requiredRuleCount: 1,
        progress: ProgressionNumericProgressDTO(current: 1, target: 1),
        completedAt: completedAt,
        isHidden: false,
        localPointWeight: 5,
        rewards: ProgressionRewardSummaryDTO()
    )
    let snapshot = try ProgressionSnapshotDTO(
        revision: revision,
        capturedAt: testDate,
        availability: .available,
        storeHealth: .loaded,
        catalogID: ProgressionCatalogID(rawValue: "catalog.progression")!,
        catalogVersion: ProgressionCatalogVersion(rawValue: 1)!,
        codexGates: includeMoonleaf ? [gate, moonleafGate] : [gate],
        achievements: [achievement]
    )
    let projection = RuntimeProgressionExternalProjection(
        catalogVersion: 1,
        localRevision: revision,
        initializedAt: testDate.addingTimeInterval(-1_000),
        counters: [],
        achievements: [RuntimeProgressionAchievementFact(
            achievementID: achievementID,
            current: 1,
            target: 1,
            completedAt: completedAt
        )],
        milestones: [],
        grants: [],
        ownedContentIDs: [],
        unlockIDs: includeMoonleaf
            ? [UnlockID(rawValue: "unlock.codex.moonleaf")!]
            : [],
        titleIDs: [],
        encounters: [],
        selectedTitleID: nil,
        knownAchievementIDs: [achievementID],
        knownUnlockIDs: [UnlockID(rawValue: "unlock.codex.moonleaf")!],
        knownCodexIDs: [norse, moonleaf]
    )
    return (snapshot, projection)
}

private func makeCounterProgressionState(
    revision: UInt64,
    total: UInt64
) throws -> (
    snapshot: ProgressionSnapshotDTO,
    projection: RuntimeProgressionExternalProjection
) {
    let norse = CodexID(rawValue: "codex.norse")!
    let component = try ProgressionGateComponentDTO(
        componentID: "gate.norse.included",
        label: "Included",
        current: 1,
        target: 1,
        isComplete: true
    )
    let snapshot = try ProgressionSnapshotDTO(
        revision: revision,
        capturedAt: testDate,
        availability: .available,
        storeHealth: .loaded,
        catalogID: ProgressionCatalogID(rawValue: "catalog.progression")!,
        catalogVersion: ProgressionCatalogVersion(rawValue: 1)!,
        codexGates: [try unlockedCodexGate(
            codexID: norse,
            displayName: "Norse",
            journeyOrder: 0,
            component: component
        )]
    )
    let statisticID = StatisticID(rawValue: "stat.synthetic.device-counter")!
    return (
        snapshot,
        RuntimeProgressionExternalProjection(
            catalogVersion: 1,
            localRevision: revision,
            initializedAt: testDate.addingTimeInterval(-1_000),
            counters: [RuntimeProgressionCounterFact(
                statisticID: statisticID,
                codexID: nil,
                value: total
            )],
            achievements: [],
            milestones: [],
            grants: [],
            ownedContentIDs: [],
            unlockIDs: [],
            titleIDs: [],
            encounters: [],
            selectedTitleID: nil,
            knownStatisticIDs: [statisticID],
            statisticSchemas: [RuntimeProgressionStatisticSchema(
                statisticID: statisticID,
                transport: .deviceCounter,
                requiresCodexBucket: false
            )],
            knownCodexIDs: [norse]
        )
    )
}

private func unlockedCodexGate(
    codexID: CodexID,
    displayName: String,
    journeyOrder: UInt16,
    component: ProgressionGateComponentDTO
) throws -> ProgressionCodexGateDTO {
    try ProgressionCodexGateDTO(
        codexID: codexID,
        presentation: ProgressionPresentationDTO(
            displayName: displayName,
            summary: "Available",
            fallbackSystemImageName: "book"
        ),
        journeyOrder: journeyOrder,
        completedRuleCount: 1,
        requiredRuleCount: 1,
        progress: ProgressionNumericProgressDTO(current: 1, target: 1),
        components: [component],
        unlockedAt: testDate.addingTimeInterval(-100)
    )
}

private func makeCandidate(percentage: UInt8, revision: UInt64) throws
    -> GameCenterReportCandidate
{
    try GameCenterReportCandidate(
        achievementID: AchievementID(rawValue: "achievement.first-inscription")!,
        gameCenterIdentifier: "com.runescribe.achievement.first-inscription",
        percentage: percentage,
        localRevision: revision,
        locallyCompletedAt: percentage == 100 ? testDate : nil
    )
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {}
}

private func waitForCoordinatorCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 10_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
