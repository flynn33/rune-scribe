import Foundation
import RuneScribeContracts
import RuneScribeProgressionSyncDomain
import RuneScribeTestSupport
import Testing
@testable import RuneScribeProgressionModule
@testable import RuneScribeRuntimeCore

@Test
func externalMergeUsesLocalRulesToCompleteAndGrantDurably() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let initial = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    let achievementID = AchievementID(rawValue: "achievement.first-inscription")!
    let statisticID = StatisticID(rawValue: "stat.message.encoded.unique")!
    let completedAt = Date(timeIntervalSince1970: 2_000_000_050)
    let remote = projection(
        basedOn: initial.projection,
        counters: replacingCounter(
            statisticID,
            value: 1,
            in: initial.projection.counters
        ),
        distinctTokens: [try distinctToken(
            statisticID: statisticID,
            digestCharacter: "a",
            firstObservedAt: completedAt
        )],
        achievements: initial.projection.achievements.map { value in
            guard value.achievementID == achievementID else { return value }
            return RuntimeProgressionAchievementFact(
                achievementID: value.achievementID,
                current: 1,
                target: 1,
                completedAt: completedAt
            )
        },
        grants: [RuntimeProgressionGrantFact(
            grantID: GrantTransactionID(rawValue: "transaction.remote.first-inscription")!,
            contentID: "seal.norse.mjolnir",
            firstGrantedAt: completedAt,
            provenanceMaterial: "achievement.first-inscription"
        )],
        ownedContentIDs: initial.projection.ownedContentIDs + ["seal.norse.mjolnir"]
    )
    let delivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000001")!,
        sourceLocalRevision: initial.snapshot.revision,
        projection: remote,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-merge-first-inscription",
            timestamp: Date(timeIntervalSince1970: 2_000_000_100)
        )
    )

    let applied = try await service.applyExternalMerge(delivery)
    let achievement = try #require(applied.snapshot.achievements.first {
        $0.achievementID == achievementID
    })
    #expect(achievement.completedAt == completedAt)
    #expect(achievement.progress.isComplete)
    #expect(applied.snapshot.ownership.contains { value in
        value.reference == .artifact(ArtifactID(rawValue: "seal.norse.mjolnir")!)
            && value.state == .owned
    })

    let duplicate = try await service.applyExternalMerge(delivery)
    #expect(duplicate.snapshot.revision == applied.snapshot.revision)
    await service.shutdown()

    let relaunched = try await fixture.bootstrap()
    let persisted = try await fixture.snapshot(from: relaunched, suffix: "external-relaunch")
    #expect(persisted.achievements.first { $0.achievementID == achievementID }?.completedAt
        == completedAt)
    #expect(persisted.ownership.contains { value in
        value.reference == .artifact(ArtifactID(rawValue: "seal.norse.mjolnir")!)
            && value.state == .owned
    })
    await relaunched.shutdown()
}

@Test
func externalGrantClaimAloneCannotGrantOwnership() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let initial = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    let remote = projection(
        basedOn: initial.projection,
        grants: [RuntimeProgressionGrantFact(
            grantID: GrantTransactionID(rawValue: "transaction.remote.unvalidated")!,
            contentID: "seal.norse.mjolnir",
            firstGrantedAt: Date(timeIntervalSince1970: 2_000_000_050),
            provenanceMaterial: nil
        )],
        ownedContentIDs: initial.projection.ownedContentIDs + ["seal.norse.mjolnir"]
    )
    let delivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000002")!,
        sourceLocalRevision: initial.snapshot.revision,
        projection: remote,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-merge-unvalidated",
            timestamp: Date(timeIntervalSince1970: 2_000_000_100)
        )
    )

    let applied = try await service.applyExternalMerge(delivery)
    #expect(!applied.snapshot.ownership.contains { value in
        value.reference == .artifact(ArtifactID(rawValue: "seal.norse.mjolnir")!)
            && value.state == .owned
    })
    await service.shutdown()
}

@Test
func externalDistinctTokensMergeOverlapAndDisjointFactsIdempotently() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let initial = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    let statisticID = StatisticID(rawValue: "stat.message.encoded.unique")!
    let firstDate = Date(timeIntervalSince1970: 2_000_000_020)
    let secondDate = Date(timeIntervalSince1970: 2_000_000_030)
    let firstProjection = projection(
        basedOn: initial.projection,
        distinctTokens: [
            try distinctToken(
                statisticID: statisticID,
                digestCharacter: "a",
                firstObservedAt: firstDate
            ),
            try distinctToken(
                statisticID: statisticID,
                digestCharacter: "b",
                firstObservedAt: firstDate
            ),
        ]
    )
    let firstDelivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000003")!,
        sourceLocalRevision: initial.snapshot.revision,
        projection: firstProjection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-distinct-first",
            timestamp: Date(timeIntervalSince1970: 2_000_000_100)
        )
    )
    let firstApplied = try await service.applyExternalMerge(firstDelivery)
    #expect(firstApplied.projection.distinctTokens.count == 2)
    #expect(firstApplied.projection.counters.first {
        $0.statisticID == statisticID && $0.codexID == nil
    }?.value == 2)

    let secondProjection = projection(
        basedOn: firstApplied.projection,
        distinctTokens: [
            try distinctToken(
                statisticID: statisticID,
                digestCharacter: "b",
                firstObservedAt: firstDate
            ),
            try distinctToken(
                statisticID: statisticID,
                digestCharacter: "c",
                firstObservedAt: secondDate
            ),
        ]
    )
    let secondDelivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000004")!,
        sourceLocalRevision: firstApplied.snapshot.revision,
        projection: secondProjection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-distinct-second",
            timestamp: Date(timeIntervalSince1970: 2_000_000_200)
        )
    )
    let secondApplied = try await service.applyExternalMerge(secondDelivery)
    #expect(secondApplied.projection.distinctTokens.count == 3)
    #expect(secondApplied.projection.counters.first {
        $0.statisticID == statisticID && $0.codexID == nil
    }?.value == 3)
    let duplicate = try await service.applyExternalMerge(secondDelivery)
    #expect(duplicate.snapshot.revision == secondApplied.snapshot.revision)

    await service.shutdown()
    let relaunched = try await fixture.bootstrap()
    let persisted = try await relaunched.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_300)
    )
    #expect(persisted.projection.distinctTokens.count == 3)
    #expect(persisted.projection.counters.first {
        $0.statisticID == statisticID && $0.codexID == nil
    }?.value == 3)
    await relaunched.shutdown()
}

@Test
func externalMergeDeliveryRetriesAfterAcknowledgeFailsOnce() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let state = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    await service.shutdown()
    let delivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000005")!,
        sourceLocalRevision: state.snapshot.revision,
        projection: state.projection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-merge-retry",
            timestamp: Date(timeIntervalSince1970: 2_000_000_100)
        )
    )
    let probe = ExternalMergeRetryProbe(state: state)
    let delays = RetryDelayRecorder()
    let processor = ProgressionExternalMergeDeliveryProcessor { delay in
        await delays.record(delay)
    }

    await processor.process(
        delivery,
        apply: { delivery in try await probe.apply(delivery) },
        acknowledge: { deliveryID, state in
            try await probe.acknowledge(deliveryID: deliveryID, state: state)
        }
    )

    let counts = await probe.counts()
    let recordedDelays = await delays.values()
    #expect(counts.apply == 2)
    #expect(counts.acknowledge == 2)
    #expect(recordedDelays == [0.25])
}

@Test
func existingCompletionAndGrantDatesReconcileToRemoteEarliestDate() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let localDate = Date(timeIntervalSince1970: 2_000_000_200)
    let remoteDate = Date(timeIntervalSince1970: 2_000_000_100)
    guard case .applied = try await service.applyEvent(
        fixture.messageEncodedEvent(index: 44, occurredAt: localDate),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "external-earliest-local",
            timestamp: localDate
        )
    ) else {
        Issue.record("Expected the local completion event to apply.")
        return
    }
    let local = try await service.externalSyncState(
        capturedAt: localDate.addingTimeInterval(1)
    )
    let achievementID = AchievementID(rawValue: "achievement.first-inscription")!
    let remote = projection(
        basedOn: local.projection,
        achievements: local.projection.achievements.map { fact in
            guard fact.achievementID == achievementID else { return fact }
            return RuntimeProgressionAchievementFact(
                achievementID: fact.achievementID,
                current: fact.target,
                target: fact.target,
                completedAt: remoteDate
            )
        }
    )
    let delivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000006")!,
        sourceLocalRevision: local.snapshot.revision,
        projection: remote,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-earliest-remote",
            timestamp: localDate.addingTimeInterval(2)
        )
    )

    let applied = try await service.applyExternalMerge(delivery)
    #expect(applied.snapshot.achievements.first {
        $0.achievementID == achievementID
    }?.completedAt == remoteDate)
    let matchingGrantDates = applied.projection.grants.compactMap { grant -> Date? in
        guard grant.provenanceMaterial == "achievement.\(achievementID.rawValue)" else {
            return nil
        }
        return grant.firstGrantedAt
    }
    #expect(!matchingGrantDates.isEmpty)
    #expect(matchingGrantDates.allSatisfy { $0 == remoteDate })
    await service.shutdown()
}

@Test
func mergeProcessorStopsOnRevokedDeliveryAndAcceptsLaterDelivery() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let state = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    await service.shutdown()
    let firstID = UUID(uuidString: "91000000-0000-0000-0000-000000000007")!
    let secondID = UUID(uuidString: "91000000-0000-0000-0000-000000000008")!
    let first = RuntimeProgressionExternalMergeDelivery(
        deliveryID: firstID,
        sourceLocalRevision: state.snapshot.revision,
        projection: state.projection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-revoked-first"
        )
    )
    let second = RuntimeProgressionExternalMergeDelivery(
        deliveryID: secondID,
        sourceLocalRevision: state.snapshot.revision,
        projection: state.projection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-valid-second"
        )
    )
    let delays = RetryDelayRecorder()
    let processor = ProgressionExternalMergeDeliveryProcessor { delay in
        await delays.record(delay)
    }

    await processor.process(
        first,
        apply: { _ in state },
        acknowledge: { _, _ in throw ModuleStateStoreError.invalidRequest }
    )
    #expect(await processor.state() == .terminal(
        deliveryID: firstID,
        reason: .staleDelivery
    ))
    #expect(await delays.values().isEmpty)

    await processor.process(
        second,
        apply: { _ in state },
        acknowledge: { _, _ in }
    )
    #expect(await processor.state() == .idle)
}

@Test
func snapshotProcessorRetriesTransientFailureWithoutAnotherMutation() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let state = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    await service.shutdown()
    let probe = ExternalSnapshotSubmitProbe(
        state: state,
        errors: [.injectedFailure("submit-once")]
    )
    let delays = RetryDelayRecorder()
    let processor = ProgressionExternalSnapshotSubmitProcessor { delay in
        await delays.record(delay)
    }

    await processor.enqueue(
        state.snapshot,
        produce: { _ in state },
        submit: { value in try await probe.submit(value) },
        onDelivery: { _ in }
    )
    #expect(await waitForExternalSyncCondition {
        let state = await processor.state()
        let submitCount = await probe.submitCount()
        return state == .idle && submitCount == 2
    })
    #expect(await delays.values() == [0.25])
}

@Test
func snapshotProcessorStopsPermanentInvalidProjectionWithoutSpin() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let state = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    await service.shutdown()
    let probe = ExternalSnapshotSubmitProbe(
        state: state,
        errors: [.invalidRequest]
    )
    let delays = RetryDelayRecorder()
    let processor = ProgressionExternalSnapshotSubmitProcessor { delay in
        await delays.record(delay)
    }

    await processor.enqueue(
        state.snapshot,
        produce: { _ in state },
        submit: { value in try await probe.submit(value) },
        onDelivery: { _ in }
    )
    #expect(await waitForExternalSyncCondition {
        await processor.state() == .terminal(
            revision: state.snapshot.revision,
            reason: .invalidData
        )
    })
    #expect(await probe.submitCount() == 1)
    #expect(await delays.values().isEmpty)
}

@Test
func snapshotBuildFailureTerminatesExternalLifecycleWithTypedDiagnostic() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let lifecycle = RuneScribeProgressionModuleLifecycle()
    let client = RuntimeProgressionExternalSyncClient(
        submit: { _, _ in nil },
        deliveries: {
            AsyncStream { continuation in continuation.finish() }
        },
        acknowledge: { _, _, _ in }
    )
    let invalidTimestamp = Date(timeIntervalSinceReferenceDate: .infinity)

    await lifecycle.start(
        service,
        client: client,
        observationMetadata: try fixture.metadata(
            operation: "progression.external-sync.observe",
            suffix: "snapshot-build-failure",
            timestamp: invalidTimestamp
        )
    )

    let terminalReasonWasRecorded = await waitForExternalSyncCondition {
        await service.stateStreamTerminationReason() == .snapshotProjectionFailed
    }
    #expect(terminalReasonWasRecorded)
    let terminated = await waitForExternalSyncCondition {
        await lifecycle.externalSyncLifecycleState()
            == .terminal(.snapshotProjectionFailed)
    }
    let lifecycleState = await lifecycle.externalSyncLifecycleState()
    #expect(lifecycleState == .terminal(.snapshotProjectionFailed))
    #expect(terminated)
    for _ in 0 ..< 100 { await Task.yield() }
    #expect(
        await lifecycle.externalSyncLifecycleState()
            == .terminal(.snapshotProjectionFailed)
    )

    await lifecycle.stop()
}

@Test
func externalTitleSelectionAndExplicitClearApplyDurablyWithMutationTimestamp() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    _ = try await service.applyEvent(
        fixture.messageDecodedEvent(
            index: 176,
            occurredAt: Date(timeIntervalSince1970: 2_000_000_005)
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "external-title-source",
            timestamp: Date(timeIntervalSince1970: 2_000_000_006)
        )
    )
    let initial = try await service.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_000_010)
    )
    let titleID = try #require(initial.projection.titleIDs.first)
    let selectedAt = Date(timeIntervalSince1970: 2_000_000_100)
    let selectedProjection = projectionWithTitle(
        basedOn: initial.projection,
        titleID: titleID,
        updatedAt: selectedAt
    )
    let selectDelivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000009")!,
        sourceLocalRevision: initial.snapshot.revision,
        projection: selectedProjection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-title-select",
            timestamp: selectedAt.addingTimeInterval(1)
        )
    )
    let selected = try await service.applyExternalMerge(selectDelivery)
    #expect(selected.snapshot.selectedTitleID == titleID)
    #expect(selected.projection.selectedTitleUpdatedAt == selectedAt)

    let clearedAt = Date(timeIntervalSince1970: 2_000_000_200)
    let clearedProjection = projectionWithTitle(
        basedOn: selected.projection,
        titleID: nil,
        updatedAt: clearedAt
    )
    let clearDelivery = RuntimeProgressionExternalMergeDelivery(
        deliveryID: UUID(uuidString: "91000000-0000-0000-0000-000000000010")!,
        sourceLocalRevision: selected.snapshot.revision,
        projection: clearedProjection,
        operationMetadata: try fixture.metadata(
            operation: "progression.external-merge.apply",
            suffix: "external-title-clear",
            timestamp: clearedAt.addingTimeInterval(1)
        )
    )
    let cleared = try await service.applyExternalMerge(clearDelivery)
    #expect(cleared.snapshot.selectedTitleID == nil)
    #expect(cleared.projection.selectedTitleID == nil)
    #expect(cleared.projection.selectedTitleUpdatedAt == clearedAt)
    let duplicate = try await service.applyExternalMerge(clearDelivery)
    #expect(duplicate.snapshot.revision == cleared.snapshot.revision)

    await service.shutdown()
    let relaunched = try await fixture.bootstrap()
    let persisted = try await relaunched.externalSyncState(
        capturedAt: clearedAt.addingTimeInterval(10)
    )
    #expect(persisted.projection.selectedTitleID == nil)
    #expect(persisted.projection.selectedTitleUpdatedAt == clearedAt)
    await relaunched.shutdown()
}

@Test
func twoProgressionStoresConvergeThroughRuntimeApplyAcknowledgeAndResync() async throws {
    let cloud = SharedProgressionCloudTransport()
    let firstProgression = try ProgressionDurableFixture()
    let secondProgression = try ProgressionDurableFixture()
    let firstService = try await firstProgression.bootstrap()
    let secondService = try await secondProgression.bootstrap()
    let firstRuntime = try await ProgressionCloudRuntimeFixture(
        cloud: cloud,
        deviceByte: 0xa1
    )
    let secondRuntime = try await ProgressionCloudRuntimeFixture(
        cloud: cloud,
        deviceByte: 0xb1
    )

    let laterCompletion = Date(timeIntervalSince1970: 2_000_000_200)
    let earlierCompletion = Date(timeIntervalSince1970: 2_000_000_100)
    guard case .applied = try await firstService.applyEvent(
        firstProgression.messageEncodedEvent(index: 401, occurredAt: laterCompletion),
        metadata: firstProgression.metadata(
            operation: "progression.event.apply",
            suffix: "two-device-first"
        )
    ) else {
        Issue.record("The first device did not apply its local event.")
        return
    }
    guard case .applied = try await secondService.applyEvent(
        secondProgression.messageEncodedEvent(index: 402, occurredAt: earlierCompletion),
        metadata: secondProgression.metadata(
            operation: "progression.event.apply",
            suffix: "two-device-second"
        )
    ) else {
        Issue.record("The second device did not apply its local event.")
        return
    }

    var firstState = try await firstService.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_001_000)
    )
    var secondState = try await secondService.externalSyncState(
        capturedAt: Date(timeIntervalSince1970: 2_000_001_000)
    )
    _ = try await firstRuntime.coordinator.submitProgressionSnapshot(
        firstState.snapshot,
        projection: firstState.projection
    )
    await firstRuntime.coordinator.runPendingWork()

    _ = try await secondRuntime.coordinator.submitProgressionSnapshot(
        secondState.snapshot,
        projection: secondState.projection
    )
    await secondRuntime.coordinator.runPendingWork()
    let secondMergeStatus = try await secondRuntime.coordinator.statusSnapshot()
    #expect(secondMergeStatus.cloudSync.phase == .awaitingLocalApply)
    secondState = try await applyPendingProgressionMerge(
        coordinator: secondRuntime.coordinator,
        service: secondService,
        current: secondState
    )
    let secondUploadPayload = try #require(await cloud.payload())
    let secondUploadReplica = try CloudProgressionCodec.decode(secondUploadPayload)
    #expect(secondUploadReplica.achievementCompletions.first?.firstCompletedAt
        == earlierCompletion)

    await firstRuntime.coordinator.wake(.explicitRequest)
    await firstRuntime.coordinator.runPendingWork()
    let firstMergeStatus = try await firstRuntime.coordinator.statusSnapshot()
    #expect(firstMergeStatus.cloudSync.phase == .awaitingLocalApply)
    firstState = try await applyPendingProgressionMerge(
        coordinator: firstRuntime.coordinator,
        service: firstService,
        current: firstState
    )

    let saveCountBeforeStableResync = await cloud.saveCount()
    await secondRuntime.coordinator.wake(.explicitRequest)
    await secondRuntime.coordinator.runPendingWork()
    await firstRuntime.coordinator.wake(.explicitRequest)
    await firstRuntime.coordinator.runPendingWork()

    let achievementID = AchievementID(rawValue: "achievement.first-inscription")!
    #expect(firstState.snapshot.achievements.first {
        $0.achievementID == achievementID
    }?.completedAt == earlierCompletion)
    #expect(secondState.snapshot.achievements.first {
        $0.achievementID == achievementID
    }?.completedAt == earlierCompletion)
    #expect(firstState.snapshot.ownership.filter {
        $0.reference == .artifact(ArtifactID(rawValue: "seal.norse.mjolnir")!)
            && $0.state == .owned
    }.count == 1)
    #expect(secondState.snapshot.ownership.filter {
        $0.reference == .artifact(ArtifactID(rawValue: "seal.norse.mjolnir")!)
            && $0.state == .owned
    }.count == 1)
    #expect(await firstRuntime.coordinator.pendingCloudMergeDelivery() == nil)
    #expect(await secondRuntime.coordinator.pendingCloudMergeDelivery() == nil)
    #expect(await cloud.saveCount() == saveCountBeforeStableResync)

    let payload = try #require(await cloud.payload())
    let replica = try CloudProgressionCodec.decode(payload)
    #expect(replica.achievementCompletions == [try CloudAchievementCompletion(
        achievementID: achievementID,
        firstCompletedAt: earlierCompletion
    )])
    let achievementGrants = replica.grants.filter {
        $0.contentID.rawValue == "seal.norse.mjolnir"
    }
    #expect(achievementGrants.count == 2)
    #expect(Set(achievementGrants.map(\.firstGrantedAt)) == [earlierCompletion])
    #expect(replica.distinctStatisticTokens.count == 2)

    await firstService.shutdown()
    await secondService.shutdown()
    await firstRuntime.shutdown()
    await secondRuntime.shutdown()
}

private struct ProgressionCloudRuntimeFixture: Sendable {
    let stateGateway: RuntimeModuleStateGateway
    let platformGateway: RuntimeCloudGameCenterGateway
    let coordinator: RuntimeCloudGameCenterCoordinator

    init(
        cloud: SharedProgressionCloudTransport,
        deviceByte: UInt8
    ) async throws {
        let UUIDs = ProgressionCloudUUIDSequence(deviceByte: deviceByte)
        let environment = RuntimeEnvironment(
            now: { Date(timeIntervalSince1970: 2_000_001_000) },
            nextUUID: { UUIDs.next() }
        )
        let stateGateway = RuntimeModuleStateGateway(policy: .patternBFoundation)
        try await stateGateway.install(InMemoryModuleStateStore(now: environment.now))
        _ = await stateGateway.activateRuntime()
        let platformGateway = RuntimeCloudGameCenterGateway(environment: environment)
        try await platformGateway.install(cloud)
        await platformGateway.activateRuntime()
        let coordinator = RuntimeCloudGameCenterCoordinator(
            stateGateway: stateGateway,
            platformGateway: platformGateway,
            environment: environment,
            automaticScheduling: false
        )
        await coordinator.activateRuntime()
        self.stateGateway = stateGateway
        self.platformGateway = platformGateway
        self.coordinator = coordinator
    }

    func shutdown() async {
        await coordinator.deactivateRuntime()
        await platformGateway.deactivateRuntime()
        await stateGateway.deactivateRuntime()
    }
}

private actor SharedProgressionCloudTransport: CloudSyncTransport {
    private var storedPayload: Data?
    private var changeTag: String?
    private var saveSequence = 0

    func accountState() throws -> CloudAccountStateDTO {
        try CloudAccountStateDTO(
            state: .available,
            accountScopeDigest: CloudAccountScopeDigestDTO(
                rawValue: String(repeating: "a", count: 64)
            )!
        )
    }

    func fetchPrivateProgression() throws -> CloudSyncFetchResultDTO {
        try CloudSyncFetchResultDTO(payload: storedPayload, changeTag: changeTag)
    }

    func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO
    ) throws -> CloudSyncSaveResultDTO {
        guard request.expectedChangeTag == changeTag else {
            throw CloudSyncTransportError.conflict
        }
        saveSequence += 1
        storedPayload = request.payload
        changeTag = "change-\(saveSequence)"
        return try CloudSyncSaveResultDTO(changeTag: changeTag!)
    }

    func payload() -> Data? { storedPayload }
    func saveCount() -> Int { saveSequence }
}

private final class ProgressionCloudUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let deviceByte: UInt8
    private var sequence: UInt8 = 0

    init(deviceByte: UInt8) { self.deviceByte = deviceByte }

    func next() -> UUID {
        lock.withLock {
            sequence &+= 1
            return UUID(uuid: (
                deviceByte, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, sequence
            ))
        }
    }
}

private func applyPendingProgressionMerge(
    coordinator: RuntimeCloudGameCenterCoordinator,
    service: RuneScribeProgressionServiceActor,
    current: ProgressionExternalSyncState
) async throws -> ProgressionExternalSyncState {
    let delivery = try #require(await coordinator.submitProgressionSnapshot(
        current.snapshot,
        projection: current.projection
    ))
    let applied = try await service.applyExternalMerge(delivery)
    try await coordinator.acknowledgeProgressionMerge(
        deliveryID: delivery.deliveryID,
        snapshot: applied.snapshot,
        projection: applied.projection
    )
    await coordinator.runPendingWork()
    return applied
}

private actor ExternalMergeRetryProbe {
    private let state: ProgressionExternalSyncState
    private var applyCount = 0
    private var acknowledgeCount = 0

    init(state: ProgressionExternalSyncState) {
        self.state = state
    }

    func apply(
        _ delivery: RuntimeProgressionExternalMergeDelivery
    ) throws -> ProgressionExternalSyncState {
        _ = delivery
        applyCount += 1
        return state
    }

    func acknowledge(
        deliveryID: UUID,
        state: ProgressionExternalSyncState
    ) throws {
        _ = deliveryID
        _ = state
        acknowledgeCount += 1
        if acknowledgeCount == 1 {
            throw ModuleStateStoreError.injectedFailure("acknowledge-once")
        }
    }

    func counts() -> (apply: Int, acknowledge: Int) {
        (applyCount, acknowledgeCount)
    }
}

private actor RetryDelayRecorder {
    private var delays: [TimeInterval] = []

    func record(_ delay: TimeInterval) {
        delays.append(delay)
    }

    func values() -> [TimeInterval] { delays }
}

private actor ExternalSnapshotSubmitProbe {
    private let state: ProgressionExternalSyncState
    private var errors: [ModuleStateStoreError]
    private var count = 0

    init(state: ProgressionExternalSyncState, errors: [ModuleStateStoreError]) {
        self.state = state
        self.errors = errors
    }

    func submit(
        _ value: ProgressionExternalSyncState
    ) throws -> RuntimeProgressionExternalMergeDelivery? {
        #expect(value == state)
        count += 1
        if !errors.isEmpty { throw errors.removeFirst() }
        return nil
    }

    func submitCount() -> Int { count }
}

private func waitForExternalSyncCondition(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}

private func replacingCounter(
    _ statisticID: StatisticID,
    value: UInt64,
    in counters: [RuntimeProgressionCounterFact]
) -> [RuntimeProgressionCounterFact] {
    var values = counters.filter { $0.statisticID != statisticID || $0.codexID != nil }
    values.append(RuntimeProgressionCounterFact(
        statisticID: statisticID,
        codexID: nil,
        value: value
    ))
    return values
}

private func projection(
    basedOn value: RuntimeProgressionExternalProjection,
    counters: [RuntimeProgressionCounterFact]? = nil,
    distinctTokens: [RuntimeProgressionDistinctTokenFact]? = nil,
    achievements: [RuntimeProgressionAchievementFact]? = nil,
    grants: [RuntimeProgressionGrantFact]? = nil,
    ownedContentIDs: [String]? = nil
) -> RuntimeProgressionExternalProjection {
    RuntimeProgressionExternalProjection(
        catalogVersion: value.catalogVersion,
        localRevision: value.localRevision,
        initializedAt: value.initializedAt,
        counters: counters ?? value.counters,
        distinctTokens: distinctTokens ?? value.distinctTokens,
        achievements: achievements ?? value.achievements,
        milestones: value.milestones,
        grants: grants ?? value.grants,
        ownedContentIDs: ownedContentIDs ?? value.ownedContentIDs,
        unlockIDs: value.unlockIDs,
        titleIDs: value.titleIDs,
        encounters: value.encounters,
        selectedTitleID: value.selectedTitleID,
        selectedTitleUpdatedAt: value.selectedTitleUpdatedAt,
        knownStatisticIDs: value.knownStatisticIDs,
        knownAchievementIDs: value.knownAchievementIDs,
        knownMilestoneRuleIDs: value.knownMilestoneRuleIDs,
        knownContentIDs: value.knownContentIDs,
        knownArtifactIDs: value.knownArtifactIDs,
        knownUnlockIDs: value.knownUnlockIDs,
        knownTitleIDs: value.knownTitleIDs,
        statisticSchemas: value.statisticSchemas,
        knownCodexIDs: value.knownCodexIDs
    )
}

private func projectionWithTitle(
    basedOn value: RuntimeProgressionExternalProjection,
    titleID: TitleID?,
    updatedAt: Date
) -> RuntimeProgressionExternalProjection {
    RuntimeProgressionExternalProjection(
        catalogVersion: value.catalogVersion,
        localRevision: value.localRevision,
        initializedAt: value.initializedAt,
        counters: value.counters,
        distinctTokens: value.distinctTokens,
        achievements: value.achievements,
        milestones: value.milestones,
        grants: value.grants,
        ownedContentIDs: value.ownedContentIDs,
        unlockIDs: value.unlockIDs,
        titleIDs: value.titleIDs,
        encounters: value.encounters,
        selectedTitleID: titleID,
        selectedTitleUpdatedAt: updatedAt,
        knownStatisticIDs: value.knownStatisticIDs,
        knownAchievementIDs: value.knownAchievementIDs,
        knownMilestoneRuleIDs: value.knownMilestoneRuleIDs,
        knownContentIDs: value.knownContentIDs,
        knownArtifactIDs: value.knownArtifactIDs,
        knownUnlockIDs: value.knownUnlockIDs,
        knownTitleIDs: value.knownTitleIDs,
        statisticSchemas: value.statisticSchemas,
        knownCodexIDs: value.knownCodexIDs
    )
}

private func distinctToken(
    statisticID: StatisticID,
    digestCharacter: Character,
    firstObservedAt: Date
) throws -> RuntimeProgressionDistinctTokenFact {
    try RuntimeProgressionDistinctTokenFact(
        statisticID: statisticID,
        codexID: nil,
        opaqueTokenDigest: String(repeating: String(digestCharacter), count: 64),
        firstObservedAt: firstObservedAt
    )
}
