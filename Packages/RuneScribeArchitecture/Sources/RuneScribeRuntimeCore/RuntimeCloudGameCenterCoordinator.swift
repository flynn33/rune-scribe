import Foundation
import RuneScribeCloudSyncModule
import RuneScribeContracts
import RuneScribeGameCenterModule
import RuneScribeProgressionSyncDomain

public struct RuntimeCloudProgressionProjection: Equatable, Sendable {
    public let replica: CloudProgressionReplica
    public let localRevision: UInt64
    public let availableCodexIDs: Set<CodexID>
    public let fallbackCodexID: CodexID
    public let availableTitleIDs: Set<TitleID>
    public let knownStatisticIDs: Set<StatisticID>
    public let knownAchievementIDs: Set<AchievementID>
    public let knownMilestoneRuleIDs: Set<RuleID>
    public let knownContentIDs: Set<String>
    public let knownArtifactIDs: Set<ArtifactID>
    public let knownUnlockIDs: Set<UnlockID>
    public let achievementTargets: [AchievementID: UInt64]
    public let knownCodexIDs: Set<CodexID>
    public let knownTitleIDs: Set<TitleID>
    public let statisticSchemas: [StatisticID: CloudStatisticMergeSchema]

    public init(
        replica: CloudProgressionReplica,
        localRevision: UInt64,
        availableCodexIDs: Set<CodexID>,
        fallbackCodexID: CodexID,
        availableTitleIDs: Set<TitleID> = [],
        knownStatisticIDs: Set<StatisticID> = [],
        knownAchievementIDs: Set<AchievementID> = [],
        knownMilestoneRuleIDs: Set<RuleID> = [],
        knownContentIDs: Set<String> = [],
        knownArtifactIDs: Set<ArtifactID> = [],
        knownUnlockIDs: Set<UnlockID> = [],
        achievementTargets: [AchievementID: UInt64] = [:],
        knownCodexIDs: Set<CodexID> = [],
        knownTitleIDs: Set<TitleID> = [],
        statisticSchemas: [StatisticID: CloudStatisticMergeSchema] = [:]
    ) throws {
        try replica.validate()
        guard localRevision > 0 else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        guard availableCodexIDs.contains(fallbackCodexID) else {
            throw CloudProgressionSchemaError.invalidIdentifier(fallbackCodexID.rawValue)
        }
        self.replica = replica
        self.localRevision = localRevision
        self.availableCodexIDs = availableCodexIDs
        self.fallbackCodexID = fallbackCodexID
        self.availableTitleIDs = availableTitleIDs
        self.knownStatisticIDs = knownStatisticIDs
        self.knownAchievementIDs = knownAchievementIDs
        self.knownMilestoneRuleIDs = knownMilestoneRuleIDs
        self.knownContentIDs = knownContentIDs
        self.knownArtifactIDs = knownArtifactIDs
        self.knownUnlockIDs = knownUnlockIDs
        self.achievementTargets = achievementTargets
        self.knownCodexIDs = knownCodexIDs
        self.knownTitleIDs = knownTitleIDs
        self.statisticSchemas = statisticSchemas
    }
}

public struct RuntimeCloudProgressionMergeDelivery: Equatable, Sendable {
    public let deliveryID: UUID
    public let sourceLocalRevision: UInt64
    public let replica: CloudProgressionReplica
    let accountOperationEpoch: UInt64

    init(
        deliveryID: UUID,
        sourceLocalRevision: UInt64,
        replica: CloudProgressionReplica,
        accountOperationEpoch: UInt64 = 0
    ) {
        self.deliveryID = deliveryID
        self.sourceLocalRevision = sourceLocalRevision
        self.replica = replica
        self.accountOperationEpoch = accountOperationEpoch
    }
}

public enum RuntimeExternalServiceWakeReason: String, Codable, CaseIterable, Sendable {
    case runtimeStarted = "runtime-started"
    case localProgressChanged = "local-progress-changed"
    case applicationBecameActive = "application-became-active"
    case connectivityMayHaveChanged = "connectivity-may-have-changed"
    case retryDeadlineReached = "retry-deadline-reached"
    case explicitRequest = "explicit-request"
}

public struct RuntimeCloudGameCenterStatusClient: Sendable {
    private let coordinator: RuntimeCloudGameCenterCoordinator
    private let lease: ModuleContextLease
    private let canManageGameCenterParticipation: Bool
    private let canRebindCloudAccount: Bool

    init(
        coordinator: RuntimeCloudGameCenterCoordinator,
        lease: ModuleContextLease,
        canManageGameCenterParticipation: Bool,
        canRebindCloudAccount: Bool
    ) {
        self.coordinator = coordinator
        self.lease = lease
        self.canManageGameCenterParticipation = canManageGameCenterParticipation
        self.canRebindCloudAccount = canRebindCloudAccount
    }

    public func snapshot() async throws -> RuntimeCloudGameCenterStatusSnapshotDTO {
        try await lease.requireActive()
        let result = try await coordinator.statusSnapshot()
        try await lease.requireActive()
        return result
    }

    public func snapshots() async throws
        -> AsyncStream<RuntimeCloudGameCenterStatusSnapshotDTO>
    {
        try await lease.requireActive()
        let source = try await coordinator.statusSnapshots()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await value in source {
                    do {
                        try await lease.requireActive()
                        continuation.yield(value)
                    } catch {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func submit(
        _ intent: RuntimeGameCenterParticipationIntentDTO
    ) async throws {
        try await lease.requireActive()
        guard canManageGameCenterParticipation else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: lease.moduleID,
                capability: RuneScribeCapabilities.gameCenterOptIn
            )
        }
        try await coordinator.submit(intent)
        try await lease.requireActive()
    }

    public func rebindCloudAccount() async throws {
        try await lease.requireActive()
        guard canRebindCloudAccount else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: lease.moduleID,
                capability: RuneScribeCapabilities.cloudAccountRebind
            )
        }
        try await coordinator.rebindCloudAccount()
        try await lease.requireActive()
    }
}

actor RuntimeCloudGameCenterCoordinator {
    enum SelectedCodexCloudSubmissionState: Equatable, Sendable {
        case stopped
        case idle
        case pending(settingRevision: UInt64)
        case retrying(settingRevision: UInt64, failedAttemptCount: UInt16)
        case terminal(
            settingRevision: UInt64,
            reason: SelectedCodexCloudSubmissionTerminalReason
        )
    }

    enum SelectedCodexCloudSubmissionTerminalReason: Equatable, Sendable {
        case invalidProjection
    }

    private enum DurableLoadState: Equatable, Sendable {
        case notAttempted
        case confirmedAbsent
        case loaded
        case unavailable
        case quarantined
    }

    private struct ProgressionCounterTracker: Codable, Equatable, Sendable {
        let statisticID: StatisticID
        let codexID: CodexID?
        var deviceContribution: UInt64
        var lastAuthoritativeTotal: UInt64
        var pendingImportedTotal: UInt64?

        var key: String {
            "\(statisticID.rawValue)|\(codexID?.rawValue ?? "")"
        }

        func validated() throws -> Self {
            guard deviceContribution <= lastAuthoritativeTotal,
                  pendingImportedTotal.map({ $0 >= lastAuthoritativeTotal }) ?? true
            else {
                throw ModuleStateStoreError.corrupt
            }
            return self
        }
    }

    private struct ProgressionCodexSelectionTracker: Codable, Equatable, Sendable {
        let codexID: CodexID
        let logicalTimestamp: UInt64
        let writerDeviceID: CloudOpaqueIdentifier
        let updatedAt: Date

        func validated() throws -> Self {
            guard logicalTimestamp > 0,
                  logicalTimestamp < UInt64.max,
                  updatedAt.timeIntervalSinceReferenceDate.isFinite
            else { throw ModuleStateStoreError.corrupt }
            return self
        }
    }

    private struct ProgressionTitleSelectionTracker: Codable, Equatable, Sendable {
        let titleID: TitleID?
        let logicalTimestamp: UInt64
        let writerDeviceID: CloudOpaqueIdentifier
        let updatedAt: Date

        func validated() throws -> Self {
            guard logicalTimestamp > 0,
                  logicalTimestamp < UInt64.max,
                  updatedAt.timeIntervalSinceReferenceDate.isFinite
            else { throw ModuleStateStoreError.corrupt }
            return self
        }
    }

    private struct CloudInboundPollState: Codable, Equatable, Sendable {
        var failedAttemptCount: UInt16
        var nextEligibleAttemptAt: Date?

        static let idle = Self(failedAttemptCount: 0, nextEligibleAttemptAt: nil)

        func validated() throws -> Self {
            guard failedAttemptCount <= CloudSyncRetryPolicy.maximumAttemptCount,
                  nextEligibleAttemptAt?.timeIntervalSinceReferenceDate.isFinite ?? true
            else { throw ModuleStateStoreError.corrupt }
            return self
        }

        func recordingFailure(
            _ category: CloudSyncFailureCategory,
            now: Date,
            serverRetryAfter: Date?
        ) throws -> Self {
            let consumesAttempt = category == .serviceUnavailable || category == .rateLimited
            let attempt = consumesAttempt
                ? min(failedAttemptCount &+ 1, CloudSyncRetryPolicy.maximumAttemptCount)
                : failedAttemptCount
            let disposition = try CloudSyncRetryPolicy.disposition(
                for: category,
                failedAttemptCount: attempt,
                now: now,
                serverRetryAfter: serverRetryAfter
            )
            let next: Date?
            if case let .retry(at) = disposition {
                next = at
            } else {
                next = nil
            }
            return Self(failedAttemptCount: attempt, nextEligibleAttemptAt: next)
        }
    }

    private struct DurableState: Codable, Equatable, Sendable {
        static let currentSchemaVersion: UInt16 = 1

        var schemaVersion: UInt16
        var cloudQueue: CloudSyncQueue
        var lastKnownCloudRevision: UInt64
        var boundCloudAccountScope: CloudAccountScopeDigestDTO?
        var lastSuccessfulCloudSyncAt: Date?
        var cloudQuarantineCount: UInt32
        var gameCenterOutbox: GameCenterReportOutbox
        var gameCenterOptedIn: Bool
        var boundGameCenterAccountScope: GameCenterAccountScopeDigestDTO?
        var lastLocalGameCenterCandidates: [GameCenterReportCandidate]?
        var progressionDeviceID: CloudOpaqueIdentifier?
        var progressionCounterTrackers: [ProgressionCounterTracker]?
        var progressionCodexSelection: ProgressionCodexSelectionTracker?
        var progressionTitleSelection: ProgressionTitleSelectionTracker?
        var cloudInboundPollState: CloudInboundPollState?
        var gameCenterCloudReportMetadata: [CloudPendingGameCenterReport]?

        static func empty() -> Self {
            Self(
                schemaVersion: currentSchemaVersion,
                cloudQueue: try! CloudSyncQueue(),
                lastKnownCloudRevision: 0,
                boundCloudAccountScope: nil,
                lastSuccessfulCloudSyncAt: nil,
                cloudQuarantineCount: 0,
                gameCenterOutbox: try! GameCenterReportOutbox(),
                gameCenterOptedIn: false,
                boundGameCenterAccountScope: nil,
                lastLocalGameCenterCandidates: nil,
                progressionDeviceID: nil,
                progressionCounterTrackers: nil,
                progressionCodexSelection: nil,
                progressionTitleSelection: nil,
                cloudInboundPollState: nil,
                gameCenterCloudReportMetadata: nil
            )
        }

        func validated() throws -> Self {
            guard schemaVersion == Self.currentSchemaVersion,
                  lastSuccessfulCloudSyncAt?.timeIntervalSinceReferenceDate.isFinite ?? true
            else { throw ModuleStateStoreError.corrupt }
            let trackers = try progressionCounterTrackers?.map { try $0.validated() }
            guard trackers.map({ Set($0.map(\.key)).count == $0.count }) ?? true else {
                throw ModuleStateStoreError.corrupt
            }
            let localCandidates = try Self.validateCandidates(
                lastLocalGameCenterCandidates ?? []
            )
            let reportMetadata = try Self.validateReportMetadata(
                gameCenterCloudReportMetadata ?? []
            )
            return Self(
                schemaVersion: schemaVersion,
                cloudQueue: try CloudSyncQueue(
                    pendingRevision: cloudQueue.pendingRevision,
                    failedAttemptCount: cloudQueue.failedAttemptCount,
                    nextEligibleAttemptAt: cloudQueue.nextEligibleAttemptAt
                ),
                lastKnownCloudRevision: lastKnownCloudRevision,
                boundCloudAccountScope: boundCloudAccountScope,
                lastSuccessfulCloudSyncAt: lastSuccessfulCloudSyncAt,
                cloudQuarantineCount: cloudQuarantineCount,
                gameCenterOutbox: try Self.validate(gameCenterOutbox),
                gameCenterOptedIn: gameCenterOptedIn,
                boundGameCenterAccountScope: boundGameCenterAccountScope,
                lastLocalGameCenterCandidates: localCandidates.isEmpty ? nil : localCandidates,
                progressionDeviceID: progressionDeviceID,
                progressionCounterTrackers: trackers?.sorted { $0.key < $1.key },
                progressionCodexSelection: try progressionCodexSelection?.validated(),
                progressionTitleSelection: try progressionTitleSelection?.validated(),
                cloudInboundPollState: try cloudInboundPollState?.validated(),
                gameCenterCloudReportMetadata: reportMetadata.isEmpty
                    ? nil
                    : reportMetadata
            )
        }

        private static func validateReportMetadata(
            _ values: [CloudPendingGameCenterReport]
        ) throws -> [CloudPendingGameCenterReport] {
            guard values.count <= GameCenterReportOutbox.maximumEntryCount,
                  Set(values.map(\.achievementID)).count == values.count
            else { throw ModuleStateStoreError.corrupt }
            return try values.map { value in
                try CloudPendingGameCenterReport(
                    achievementID: value.achievementID,
                    percentage: value.percentage,
                    firstQueuedAt: value.firstQueuedAt,
                    lastUpdatedAt: value.lastUpdatedAt
                )
            }.sorted { $0.achievementID < $1.achievementID }
        }

        private static func validate(
            _ outbox: GameCenterReportOutbox
        ) throws -> GameCenterReportOutbox {
            let acknowledgements = try outbox.acknowledgements.map {
                try GameCenterAcknowledgement(
                    achievementID: $0.achievementID,
                    percentage: $0.percentage
                )
            }
            let entries = try outbox.pendingEntries.map { entry in
                let candidate = try GameCenterReportCandidate(
                    achievementID: entry.candidate.achievementID,
                    gameCenterIdentifier: entry.candidate.gameCenterIdentifier,
                    percentage: entry.candidate.percentage,
                    localRevision: entry.candidate.localRevision,
                    locallyCompletedAt: entry.candidate.locallyCompletedAt
                )
                return try GameCenterOutboxEntry(
                    candidate: candidate,
                    state: entry.state,
                    failedAttemptCount: entry.failedAttemptCount,
                    deferralReason: entry.deferralReason,
                    nextEligibleAttemptAt: entry.nextEligibleAttemptAt
                )
            }
            return try GameCenterReportOutbox(
                acknowledgements: acknowledgements,
                pendingEntries: entries
            )
        }

        private static func validateCandidates(
            _ candidates: [GameCenterReportCandidate]
        ) throws -> [GameCenterReportCandidate] {
            let outbox = try GameCenterReportOutbox().enqueue(candidates)
            return outbox.pendingEntries.map(\.candidate)
        }
    }

    private static let namespace = ModuleStateNamespace(
        moduleID: "com.runescribe.runtime.cloud-game-center"
    )
    private static let collectionID = ModuleStateCollectionID(
        rawValue: "external-services.state"
    )!
    private static let recordID = ModuleStateRecordID(rawValue: "orchestration")!
    private static let schemaVersion: UInt32 = 1

    private let stateGateway: RuntimeModuleStateGateway
    private let platformGateway: RuntimeCloudGameCenterGateway
    private let environment: RuntimeEnvironment
    private let settingsGateway: RuntimeSettingsGateway?
    private let automaticScheduling: Bool
    private let sleep: @Sendable (TimeInterval) async -> Void

    private var durable = DurableState.empty()
    private var durableRecordID: ModuleStateRecordID
    private var durableLoadState: DurableLoadState = .notAttempted
    private var pendingGameCenterOptInPreference: Bool?
    private var persistenceIsDurable = false
    private var runtimeIsActive = false
    private var runtimeGeneration: UInt64 = 0
    private var cloudProjection: RuntimeCloudProgressionProjection?
    private var pendingCloudMerge: RuntimeCloudProgressionMergeDelivery?
    private var scheduledTask: Task<Void, Never>?
    private var settingsObservationTask: Task<Void, Never>?
    private var selectedCodexRetryTask: Task<Void, Never>?
    private var cloudAccountOperationEpoch: UInt64 = 0
    private var cloudPollWasRequested = false
    private var workIsInFlight = false
    private var workWasRequested = false
    private var gameCenterAuthenticationIsInFlight = false
    private var gameCenterAuthenticationWasAttemptedThisActivation = false
    private var gameCenterAuthenticationRetryOnNextApplicationActivation = false
    private var gameCenterAuthenticationPresentationRetryWasConsumed = false
    private var gameCenterOperationEpoch: UInt64 = 0
    private var lastObservedProgressionRevision: UInt64?
    private var lastProgressionSnapshot: ProgressionSnapshotDTO?
    private var lastProgressionProjection: RuntimeProgressionExternalProjection?
    private var mergeContinuationSequence: UInt64 = 0
    private var mergeContinuations: [
        UInt64: AsyncStream<RuntimeProgressionExternalMergeDelivery>.Continuation
    ] = [:]
    private var gameCenterCatalog: GameCenterAchievementCatalog?
    private var lastObservedSelectedCodexSettingRevision: UInt64?
    private var suppressSelectedCodexObservation = false
    private var selectedCodexSubmissionState: SelectedCodexCloudSubmissionState = .stopped
    private var cloudAvailabilityProbeAt: Date?
    private var gameCenterAvailabilityProbeAt: Date?
    private var gameCenterProbeWasRequested = false
    private var persistenceAvailabilityProbeAt: Date?

    private static let serviceAvailabilityProbeInterval: TimeInterval = 60

    private enum ProgressionCounterObservation {
        case localSnapshot
        case acknowledgedExternalMerge
    }

    private var cloudPhase: RuntimeCloudSyncPhaseDTO = .localOnly
    private var cloudAccountStatus: RuntimeCloudAccountStatusDTO = .unknown
    private var gameCenterConnection: RuntimeGameCenterConnectionDTO = .disabled
    private var gameCenterReportStatus: RuntimeGameCenterReportStatusDTO = .localOnly
    private var gameCenterAuthenticationWasUserInitiated = false
    private var statusRevision: UInt64 = 0
    private var latestStatus: RuntimeCloudGameCenterStatusSnapshotDTO
    private var continuations: [
        UUID: AsyncStream<RuntimeCloudGameCenterStatusSnapshotDTO>.Continuation
    ] = [:]

    init(
        stateGateway: RuntimeModuleStateGateway,
        platformGateway: RuntimeCloudGameCenterGateway,
        environment: RuntimeEnvironment,
        settingsGateway: RuntimeSettingsGateway? = nil,
        automaticScheduling: Bool = true,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            guard delay > 0 else { return }
            let nanoseconds = UInt64(min(delay, 86_400) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.stateGateway = stateGateway
        self.platformGateway = platformGateway
        self.environment = environment
        self.settingsGateway = settingsGateway
        self.automaticScheduling = automaticScheduling
        self.sleep = sleep
        durableRecordID = Self.recordID
        latestStatus = Self.makeStatus(
            revision: 0,
            capturedAt: environment.now(),
            durable: durable,
            persistenceIsDurable: false,
            cloudPhase: .localOnly,
            cloudAccountStatus: .unknown,
            gameCenterConnection: .disabled,
            gameCenterReportStatus: .localOnly,
            authenticationWasUserInitiated: false
        )
    }

    func activateRuntime() async {
        runtimeGeneration &+= 1
        cloudAccountOperationEpoch &+= 1
        gameCenterOperationEpoch &+= 1
        runtimeIsActive = true
        durable = .empty()
        durableRecordID = Self.recordID
        durableLoadState = .notAttempted
        pendingGameCenterOptInPreference = nil
        cloudProjection = nil
        pendingCloudMerge = nil
        workIsInFlight = false
        workWasRequested = false
        gameCenterAuthenticationIsInFlight = false
        gameCenterAuthenticationWasAttemptedThisActivation = false
        gameCenterAuthenticationRetryOnNextApplicationActivation = false
        gameCenterAuthenticationPresentationRetryWasConsumed = false
        lastObservedProgressionRevision = nil
        lastProgressionSnapshot = nil
        lastProgressionProjection = nil
        lastObservedSelectedCodexSettingRevision = nil
        selectedCodexRetryTask?.cancel()
        selectedCodexRetryTask = nil
        selectedCodexSubmissionState = .idle
        cloudAvailabilityProbeAt = nil
        gameCenterAvailabilityProbeAt = nil
        gameCenterProbeWasRequested = false
        persistenceAvailabilityProbeAt = nil
        await loadDurableStateIfAvailable()
        cloudPollWasRequested = durable.cloudInboundPollState != nil
        cloudPhase = durableCloudPhaseWithoutActiveOperation()
        cloudAccountStatus = .unknown
        gameCenterConnection = durable.gameCenterOptedIn
            ? .authenticationAvailable
            : .disabled
        gameCenterReportStatus = initialGameCenterReportStatus()
        gameCenterAuthenticationWasUserInitiated = false
        publishStatus(force: true)
        startSettingsObservation()
        if durable.cloudQueue.pendingRevision != nil
            || durable.gameCenterOptedIn
            || !durable.gameCenterOutbox.pendingEntries.isEmpty
        {
            scheduleImmediateWork(reason: .runtimeStarted)
        }
    }

    func deactivateRuntime() {
        runtimeIsActive = false
        cloudAccountOperationEpoch &+= 1
        gameCenterOperationEpoch &+= 1
        do {
            durable.gameCenterOutbox = try durable.gameCenterOutbox
                .recoverInterruptedReports()
        } catch {
            persistenceIsDurable = false
        }
        scheduledTask?.cancel()
        scheduledTask = nil
        settingsObservationTask?.cancel()
        settingsObservationTask = nil
        selectedCodexRetryTask?.cancel()
        selectedCodexRetryTask = nil
        cloudProjection = nil
        pendingCloudMerge = nil
        workIsInFlight = false
        workWasRequested = false
        gameCenterAuthenticationIsInFlight = false
        gameCenterAuthenticationWasAttemptedThisActivation = false
        gameCenterAuthenticationRetryOnNextApplicationActivation = false
        gameCenterAuthenticationPresentationRetryWasConsumed = false
        lastObservedProgressionRevision = nil
        lastProgressionSnapshot = nil
        lastProgressionProjection = nil
        lastObservedSelectedCodexSettingRevision = nil
        suppressSelectedCodexObservation = false
        selectedCodexSubmissionState = .stopped
        cloudAvailabilityProbeAt = nil
        gameCenterAvailabilityProbeAt = nil
        gameCenterProbeWasRequested = false
        persistenceAvailabilityProbeAt = nil
        cloudPollWasRequested = false
        cloudPhase = .localOnly
        cloudAccountStatus = .unknown
        gameCenterConnection = .disabled
        gameCenterReportStatus = .localOnly
        gameCenterAuthenticationWasUserInitiated = false
        publishStatus(force: true)
        let active = continuations.values
        continuations.removeAll()
        for continuation in active { continuation.finish() }
        let mergeActive = mergeContinuations.values
        mergeContinuations.removeAll()
        for continuation in mergeActive { continuation.finish() }
    }

    func statusSnapshot() throws -> RuntimeCloudGameCenterStatusSnapshotDTO {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return latestStatus
    }

    func statusSnapshotIncludingInactive() -> RuntimeCloudGameCenterStatusSnapshotDTO {
        latestStatus
    }

    func selectedCodexCloudSubmissionState() -> SelectedCodexCloudSubmissionState {
        selectedCodexSubmissionState
    }

    func statusSnapshots() throws
        -> AsyncStream<RuntimeCloudGameCenterStatusSnapshotDTO>
    {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        let id = environment.nextUUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(latestStatus)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    func submit(_ intent: RuntimeGameCenterParticipationIntentDTO) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        switch intent {
        case .optIn:
            guard !gameCenterAuthenticationIsInFlight else { return }
            gameCenterAuthenticationRetryOnNextApplicationActivation = false
            gameCenterAuthenticationPresentationRetryWasConsumed = true
            gameCenterOperationEpoch &+= 1
            let operationEpoch = gameCenterOperationEpoch
            durable.gameCenterOptedIn = true
            pendingGameCenterOptInPreference = true
            durable.gameCenterOutbox = try durable.gameCenterOutbox.resumeDeferred(
                after: .explicitOptIn
            )
            gameCenterConnection = .authenticating
            gameCenterAuthenticationWasUserInitiated = true
            gameCenterAuthenticationIsInFlight = true
            guard await persistDurableStateIfPossible() else {
                gameCenterAuthenticationIsInFlight = false
                gameCenterConnection = .authenticationAvailable
                gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
                    ? .localOnly
                    : .deferred
                cloudPhase = .persistenceDegraded
                publishStatus()
                scheduleImmediateWork(reason: .explicitRequest)
                return
            }
            publishStatus()
            gameCenterAuthenticationWasAttemptedThisActivation = true
            do {
                let client = try await platformGateway.gameCenterClient()
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
                let session = try await client.issueSession(for: .requestAuthentication)
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
                let state = try await client.requestAuthentication(session: session)
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
                adoptAuthenticationState(state)
            } catch {
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
                adoptGameCenterFailure(error)
            }
            gameCenterAuthenticationIsInFlight = false
            publishStatus()
            if gameCenterConnection == .connected {
                scheduleImmediateWork(reason: .explicitRequest)
            }
        case .optOut:
            gameCenterOperationEpoch &+= 1
            durable.gameCenterOptedIn = false
            pendingGameCenterOptInPreference = false
            gameCenterAuthenticationIsInFlight = false
            gameCenterAuthenticationWasUserInitiated = false
            gameCenterAuthenticationRetryOnNextApplicationActivation = false
            gameCenterAuthenticationPresentationRetryWasConsumed = false
            try deferGameCenterInFlightForOptOut()
            gameCenterConnection = .disabled
            gameCenterReportStatus = .localOnly
            gameCenterAvailabilityProbeAt = nil
            gameCenterProbeWasRequested = false
            await persistDurableStateIfPossible()
            publishStatus()
        }
    }

    func submitCloudProjection(
        _ projection: RuntimeCloudProgressionProjection
    ) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        cloudProjection = projection
        durable.lastKnownCloudRevision = max(
            durable.lastKnownCloudRevision,
            projection.localRevision
        )
        durable.cloudQueue = try durable.cloudQueue.enqueue(
            localRevision: projection.localRevision
        )
        cloudPhase = durableCloudPhaseWithoutActiveOperation()
        if !(await persistDurableStateIfPossible()) {
            cloudPhase = .persistenceDegraded
        }
        publishStatus()
        scheduleImmediateWork(reason: .localProgressChanged)
    }

    func submitGameCenterCandidates(
        _ candidates: [GameCenterReportCandidate]
    ) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        durable.gameCenterOutbox = try durable.gameCenterOutbox.enqueue(candidates)
        durable.lastLocalGameCenterCandidates = try GameCenterReportOutbox()
            .enqueue((durable.lastLocalGameCenterCandidates ?? []) + candidates)
            .pendingEntries
            .map(\.candidate)
        gameCenterReportStatus = durable.gameCenterOptedIn ? .pending : .localOnly
        if !(await persistDurableStateIfPossible()), durable.gameCenterOptedIn {
            gameCenterReportStatus = .deferred
        }
        publishStatus()
        if durable.gameCenterOptedIn {
            scheduleImmediateWork(reason: .localProgressChanged)
        }
    }

    func submitProgressionSnapshot(
        _ snapshot: ProgressionSnapshotDTO,
        projection authoritative: RuntimeProgressionExternalProjection
    ) async throws -> RuntimeProgressionExternalMergeDelivery? {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        guard snapshot.revision == authoritative.localRevision else {
            throw ModuleStateStoreError.invalidRequest
        }
        lastProgressionSnapshot = snapshot
        lastProgressionProjection = authoritative

        let catalog = try loadGameCenterCatalog()
        let candidates = try GameCenterMappingPolicy.priorCompletionCandidates(
            from: snapshot,
            catalog: catalog
        )
        try await submitGameCenterCandidates(candidates)

        if lastObservedProgressionRevision != authoritative.localRevision
            || cloudProjection == nil
        {
            let deviceID = ensureProgressionDeviceID()
            let selectedCodex = try await selectedCodexProjection(
                snapshot: snapshot,
                deviceID: deviceID
            )
            let selectedTitle = try selectedTitleProjection(
                authoritative,
                deviceID: deviceID
            )
            let counterState = try counterAdjustedProjection(
                authoritative,
                observation: .localSnapshot
            )
            let projected = try RuntimeProgressionExternalProjectionMapper.projection(
                from: snapshot,
                authoritative: counterState.projection,
                deviceID: persistenceIsDurable ? deviceID : nil,
                baseReplica: pendingCloudMerge?.replica ?? cloudProjection?.replica,
                pendingGameCenterReports: try cloudPendingGameCenterReports(),
                selectedCodex: selectedCodex,
                selectedTitle: selectedTitle
            )
            durable.progressionCounterTrackers = counterState.trackers
            lastObservedProgressionRevision = authoritative.localRevision
            try await submitCloudProjection(projected)
        }
        return try currentProgressionMergeDelivery()
    }

    func progressionMergeDeliveries() throws
        -> AsyncStream<RuntimeProgressionExternalMergeDelivery>
    {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        let initialDelivery = try currentProgressionMergeDelivery()
        mergeContinuationSequence &+= 1
        let key = mergeContinuationSequence
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            mergeContinuations[key] = continuation
            if let delivery = initialDelivery {
                continuation.yield(delivery)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeMergeContinuation(key) }
            }
        }
    }

    func acknowledgeProgressionMerge(
        deliveryID: UUID,
        snapshot: ProgressionSnapshotDTO,
        projection authoritative: RuntimeProgressionExternalProjection
    ) async throws {
        guard let pendingCloudMerge,
              pendingCloudMerge.deliveryID == deliveryID,
              snapshot.revision == authoritative.localRevision
        else { throw ModuleStateStoreError.invalidRequest }
        lastProgressionSnapshot = snapshot
        lastProgressionProjection = authoritative
        lastObservedProgressionRevision = authoritative.localRevision
        let deviceID = ensureProgressionDeviceID()
        try await adoptSelectedCodexAfterProgressionApply(
            pendingCloudMerge.replica,
            snapshot: snapshot,
            fallbackCodexID: cloudProjection?.fallbackCodexID
                ?? CodexID(rawValue: "codex.norse")!
        )
        try adoptSelectedTitleAfterProgressionApply(
            pendingCloudMerge.replica,
            authoritative: authoritative,
            deviceID: deviceID
        )
        let selectedCodex = try await selectedCodexProjection(
            snapshot: snapshot,
            deviceID: deviceID
        )
        let selectedTitle = try selectedTitleProjection(
            authoritative,
            deviceID: deviceID
        )
        let gameCenterCandidates = try GameCenterMappingPolicy.priorCompletionCandidates(
            from: snapshot,
            catalog: loadGameCenterCatalog()
        )
        try await submitGameCenterCandidates(gameCenterCandidates)
        try adoptCorroboratedCloudGameCenterReportMetadata(
            pendingCloudMerge.replica.pendingGameCenterReports,
            candidates: gameCenterCandidates
        )
        let counterState = try counterAdjustedProjection(
            authoritative,
            observation: .acknowledgedExternalMerge
        )
        let updated = try RuntimeProgressionExternalProjectionMapper.projection(
            from: snapshot,
            authoritative: counterState.projection,
            deviceID: persistenceIsDurable ? deviceID : nil,
            baseReplica: try RuntimeProgressionExternalProjectionMapper.sanitizedBaseReplica(
                pendingCloudMerge.replica,
                authoritative: authoritative
            ),
            pendingGameCenterReports: try cloudPendingGameCenterReports(),
            selectedCodex: selectedCodex,
            selectedTitle: selectedTitle
        )
        durable.progressionCounterTrackers = counterState.trackers
        try await acknowledgeCloudMerge(
            deliveryID: deliveryID,
            updatedProjection: updated
        )
    }

    func pendingCloudMergeDelivery() -> RuntimeCloudProgressionMergeDelivery? {
        pendingCloudMerge
    }

    func acknowledgeCloudMerge(
        deliveryID: UUID,
        updatedProjection: RuntimeCloudProgressionProjection
    ) async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        guard let pendingCloudMerge,
              pendingCloudMerge.deliveryID == deliveryID
        else {
            throw ModuleStateStoreError.invalidRequest
        }
        guard pendingCloudMerge.accountOperationEpoch == cloudAccountOperationEpoch else {
            throw ModuleStateStoreError.invalidRequest
        }
        try await validateAccountBeforeAcknowledgingMerge(
            pendingCloudMerge,
            updatedProjection: updatedProjection
        )
        guard self.pendingCloudMerge?.deliveryID == deliveryID,
              pendingCloudMerge.accountOperationEpoch == cloudAccountOperationEpoch
        else { throw ModuleStateStoreError.invalidRequest }
        self.pendingCloudMerge = nil
        try await submitCloudProjection(updatedProjection)
    }

    private func validateAccountBeforeAcknowledgingMerge(
        _ delivery: RuntimeCloudProgressionMergeDelivery,
        updatedProjection: RuntimeCloudProgressionProjection
    ) async throws {
        guard let expectedScope = durable.boundCloudAccountScope else {
            throw ModuleStateStoreError.invalidRequest
        }
        do {
            let client = try await platformGateway.cloudClient()
            guard cloudOperationIsCurrent(delivery.accountOperationEpoch) else {
                throw ModuleStateStoreError.invalidRequest
            }
            let session = try await client.issueSession(for: .accountState)
            guard cloudOperationIsCurrent(delivery.accountOperationEpoch) else {
                throw ModuleStateStoreError.invalidRequest
            }
            let account = try await client.accountState(session: session)
            guard cloudOperationIsCurrent(delivery.accountOperationEpoch) else {
                throw ModuleStateStoreError.invalidRequest
            }
            guard account.state == .available,
                  let currentScope = account.accountScopeDigest
            else {
                adoptCloudAccountState(account.state)
                armCloudAvailabilityProbe()
                publishStatus()
                throw ModuleStateStoreError.unavailable
            }
            guard currentScope == expectedScope else {
                try await revokePendingMergeForAccountChange(
                    updatedProjection: updatedProjection
                )
                throw ModuleStateStoreError.invalidRequest
            }
        } catch let error as ModuleStateStoreError {
            throw error
        } catch {
            armCloudAvailabilityProbe()
            publishStatus()
            throw ModuleStateStoreError.unavailable
        }
    }

    private func revokePendingMergeForAccountChange(
        updatedProjection: RuntimeCloudProgressionProjection
    ) async throws {
        cloudAccountOperationEpoch &+= 1
        pendingCloudMerge = nil
        clearPendingImportedCounterTotals()
        cloudProjection = updatedProjection
        durable.lastKnownCloudRevision = max(
            durable.lastKnownCloudRevision,
            updatedProjection.localRevision
        )
        durable.cloudQueue = try durable.cloudQueue.enqueue(
            localRevision: updatedProjection.localRevision
        )
        cloudAccountStatus = .changed
        cloudPhase = .accountChangeRequiresRebind
        cloudPollWasRequested = false
        try recordCloudFailure(.accountChanged)
        guard await persistDurableStateIfPossible() else {
            cloudPhase = .persistenceDegraded
            publishStatus()
            throw ModuleStateStoreError.unavailable
        }
        publishStatus()
    }

    func rebindCloudAccount() async throws {
        guard runtimeIsActive else { throw RuneScribeRuntimeError.runtimeNotRunning }
        guard cloudPhase == .accountChangeRequiresRebind else {
            throw ModuleStateStoreError.invalidRequest
        }
        cloudAccountOperationEpoch &+= 1
        pendingCloudMerge = nil
        clearPendingImportedCounterTotals()
        durable.boundCloudAccountScope = nil
        durable.cloudInboundPollState = .idle
        cloudPollWasRequested = true
        cloudAccountStatus = .unknown
        cloudPhase = durable.cloudQueue.pendingRevision == nil ? .localOnly : .queued
        guard await persistDurableStateIfPossible() else {
            cloudPhase = .persistenceDegraded
            publishStatus()
            scheduleNextRetryIfNeeded()
            throw ModuleStateStoreError.unavailable
        }
        publishStatus()
        scheduleImmediateWork(reason: .explicitRequest)
    }

    func wake(_ reason: RuntimeExternalServiceWakeReason) {
        guard runtimeIsActive else { return }
        switch reason {
        case .applicationBecameActive:
            if gameCenterAuthenticationRetryOnNextApplicationActivation {
                gameCenterAuthenticationRetryOnNextApplicationActivation = false
                gameCenterAuthenticationPresentationRetryWasConsumed = true
                gameCenterAuthenticationWasAttemptedThisActivation = false
            }
            cloudPollWasRequested = true
            if durable.cloudInboundPollState == nil {
                durable.cloudInboundPollState = .idle
            }
        case .runtimeStarted, .connectivityMayHaveChanged, .retryDeadlineReached,
             .explicitRequest:
            cloudPollWasRequested = true
            if durable.cloudInboundPollState == nil {
                durable.cloudInboundPollState = .idle
            }
        case .localProgressChanged:
            break
        }
        scheduleImmediateWork(reason: reason)
    }

    func runPendingWork() async {
        guard runtimeIsActive else { return }
        guard !workIsInFlight else {
            workWasRequested = true
            return
        }
        let workGeneration = runtimeGeneration
        workIsInFlight = true
        scheduledTask = nil
        await processCloudIfPossible()
        guard runtimeIsActive, runtimeGeneration == workGeneration else { return }
        await processGameCenterIfPossible()
        guard runtimeIsActive, runtimeGeneration == workGeneration else { return }
        let persisted = await persistDurableStateIfPossible()
        guard runtimeIsActive, runtimeGeneration == workGeneration else { return }
        if !persisted {
            cloudPhase = .persistenceDegraded
            if durable.gameCenterOptedIn,
               !durable.gameCenterOutbox.pendingEntries.isEmpty
            {
                gameCenterReportStatus = .deferred
            }
        }
        publishStatus()
        workIsInFlight = false
        if workWasRequested {
            workWasRequested = false
            scheduleImmediateWork(reason: .explicitRequest)
        } else {
            scheduleNextRetryIfNeeded()
        }
    }

    private func processCloudIfPossible() async {
        guard await ensureDurableStateForExternalIO() else {
            cloudPhase = .persistenceDegraded
            return
        }
        guard pendingCloudMerge == nil else {
            cloudPhase = .awaitingLocalApply
            return
        }
        guard let projection = cloudProjection else {
            cloudPhase = durableCloudPhaseWithoutActiveOperation()
            return
        }
        let hasOutboundWork = durable.cloudQueue.pendingRevision != nil
        let hasInboundWork = cloudPollWasRequested || durable.cloudInboundPollState != nil
        guard hasOutboundWork || hasInboundWork else {
            cloudPhase = durable.lastSuccessfulCloudSyncAt == nil ? .localOnly : .current
            return
        }
        let nextEligibleAttemptAt = [
            durable.cloudQueue.nextEligibleAttemptAt,
            durable.cloudInboundPollState?.nextEligibleAttemptAt,
        ].compactMap { $0 }.max()
        if let next = nextEligibleAttemptAt,
           next > environment.now()
        {
            cloudPhase = .queued
            return
        }

        let operationEpoch = cloudAccountOperationEpoch
        cloudPhase = .synchronizing
        publishStatus()
        do {
            let client = try await platformGateway.cloudClient()
            guard cloudOperationIsCurrent(operationEpoch) else { return }
            let accountSession = try await client.issueSession(for: .accountState)
            guard cloudOperationIsCurrent(operationEpoch) else { return }
            let account = try await client.accountState(session: accountSession)
            guard cloudOperationIsCurrent(operationEpoch) else { return }
            guard account.state == .available, let accountScope = account.accountScopeDigest else {
                adoptCloudAccountState(account.state)
                try recordCloudFailure(.accountUnavailable)
                armCloudAvailabilityProbe()
                return
            }
            cloudAvailabilityProbeAt = nil
            cloudAccountStatus = .available
            if let bound = durable.boundCloudAccountScope, bound != accountScope {
                cloudAccountOperationEpoch &+= 1
                cloudAccountStatus = .changed
                cloudPhase = .accountChangeRequiresRebind
                try recordCloudFailure(.accountChanged)
                cloudPollWasRequested = false
                return
            }
            if durable.boundCloudAccountScope == nil {
                durable.boundCloudAccountScope = accountScope
                guard await persistDurableStateIfPossible() else {
                    cloudPhase = .persistenceDegraded
                    return
                }
                guard cloudOperationIsCurrent(operationEpoch) else { return }
            }

            let fetchSession = try await client.issueSession(for: .fetchPrivateProgression)
            guard cloudOperationIsCurrent(operationEpoch) else { return }
            let fetched = try await client.fetchPrivateProgression(session: fetchSession)
            guard cloudOperationIsCurrent(operationEpoch) else { return }
            guard try await cloudAccountStillMatches(
                accountScope,
                client: client,
                operationEpoch: operationEpoch
            ) else { return }
            let scope = CloudOpaqueIdentifier(rawValue: accountScope.rawValue)!
            let context = try CloudProgressionMergeContext(
                localAccountScope: scope,
                remoteAccountScope: scope,
                serviceAvailability: .available,
                availableCodexIDs: projection.availableCodexIDs,
                fallbackCodexID: projection.fallbackCodexID,
                availableTitleIDs: projection.availableTitleIDs,
                knownStatisticIDs: projection.knownStatisticIDs,
                knownAchievementIDs: projection.knownAchievementIDs,
                knownMilestoneRuleIDs: projection.knownMilestoneRuleIDs,
                knownContentIDs: projection.knownContentIDs,
                knownArtifactIDs: projection.knownArtifactIDs,
                knownUnlockIDs: projection.knownUnlockIDs,
                achievementTargets: projection.achievementTargets,
                validatesCatalogMembership: true,
                statisticSchemas: projection.statisticSchemas,
                knownCodexIDs: projection.knownCodexIDs,
                knownTitleIDs: projection.knownTitleIDs,
                now: environment.now()
            )
            let outcome = try CloudProgressionMergeEngine.merge(
                local: projection.replica,
                remoteData: fetched.payload,
                context: context
            )
            durable.cloudQuarantineCount = UInt32(
                min(outcome.replica.quarantineDiagnostics.count, Int(UInt32.max))
            )

            if outcome.status == .merged, outcome.replica != projection.replica {
                try stagePendingImportedCounterTotals(outcome.replica)
                guard await persistDurableStateIfPossible() else {
                    cloudPhase = .persistenceDegraded
                    return
                }
                guard cloudOperationIsCurrent(operationEpoch) else { return }
                pendingCloudMerge = RuntimeCloudProgressionMergeDelivery(
                    deliveryID: environment.nextUUID(),
                    sourceLocalRevision: projection.localRevision,
                    replica: outcome.replica,
                    accountOperationEpoch: operationEpoch
                )
                cloudPhase = .awaitingLocalApply
                try yieldProgressionMergeDelivery()
                return
            }

            if outcome.shouldUploadLocalReplica {
                let data = try CloudProgressionCodec.encode(outcome.replica)
                let saveSession = try await client.issueSession(for: .savePrivateProgression)
                guard cloudOperationIsCurrent(operationEpoch) else { return }
                _ = try await client.savePrivateProgression(
                    CloudSyncSaveRequestDTO(
                        payload: data,
                        expectedChangeTag: fetched.changeTag
                    ),
                    session: saveSession
                )
                guard cloudOperationIsCurrent(operationEpoch) else { return }
                guard try await cloudAccountStillMatches(
                    accountScope,
                    client: client,
                    operationEpoch: operationEpoch
                ) else { return }
            }
            durable.cloudQueue = try durable.cloudQueue.acknowledge(
                uploadedRevision: projection.localRevision
            )
            durable.lastSuccessfulCloudSyncAt = environment.now()
            durable.cloudInboundPollState = nil
            cloudPollWasRequested = false
            cloudProjection = try RuntimeCloudProgressionProjection(
                replica: outcome.replica,
                localRevision: projection.localRevision,
                availableCodexIDs: projection.availableCodexIDs,
                fallbackCodexID: projection.fallbackCodexID,
                availableTitleIDs: projection.availableTitleIDs,
                knownStatisticIDs: projection.knownStatisticIDs,
                knownAchievementIDs: projection.knownAchievementIDs,
                knownMilestoneRuleIDs: projection.knownMilestoneRuleIDs,
                knownContentIDs: projection.knownContentIDs,
                knownArtifactIDs: projection.knownArtifactIDs,
                knownUnlockIDs: projection.knownUnlockIDs,
                achievementTargets: projection.achievementTargets,
                knownCodexIDs: projection.knownCodexIDs,
                knownTitleIDs: projection.knownTitleIDs,
                statisticSchemas: projection.statisticSchemas
            )
            cloudPhase = outcome.status == .remoteQuarantinedLocalPreserved
                ? .quarantinedRemote
                : .current
            armCloudAvailabilityProbe()
        } catch {
            guard cloudOperationIsCurrent(operationEpoch) else { return }
            adoptCloudFailure(error)
        }
    }

    private func cloudOperationIsCurrent(_ epoch: UInt64) -> Bool {
        runtimeIsActive && cloudAccountOperationEpoch == epoch
    }

    private func cloudAccountStillMatches(
        _ expectedScope: CloudAccountScopeDigestDTO,
        client: RuntimeCloudSyncClient,
        operationEpoch: UInt64
    ) async throws -> Bool {
        let session = try await client.issueSession(for: .accountState)
        guard cloudOperationIsCurrent(operationEpoch) else { return false }
        let account = try await client.accountState(session: session)
        guard cloudOperationIsCurrent(operationEpoch) else { return false }
        guard account.state == .available,
              let currentScope = account.accountScopeDigest
        else {
            adoptCloudAccountState(account.state)
            try recordCloudFailure(.accountUnavailable)
            armCloudAvailabilityProbe()
            return false
        }
        guard currentScope == expectedScope,
              durable.boundCloudAccountScope == expectedScope
        else {
            cloudAccountOperationEpoch &+= 1
            pendingCloudMerge = nil
            clearPendingImportedCounterTotals()
            cloudAccountStatus = .changed
            cloudPhase = .accountChangeRequiresRebind
            cloudPollWasRequested = false
            try recordCloudFailure(.accountChanged)
            return false
        }
        return true
    }

    private func recordCloudFailure(
        _ category: CloudSyncFailureCategory,
        serverRetryAfter: Date? = nil
    ) throws {
        let now = environment.now()
        durable.cloudQueue = try durable.cloudQueue.recordFailure(
            category,
            now: now,
            serverRetryAfter: serverRetryAfter
        )
        if cloudPollWasRequested || durable.cloudInboundPollState != nil {
            durable.cloudInboundPollState = try (
                durable.cloudInboundPollState ?? .idle
            ).recordingFailure(
                category,
                now: now,
                serverRetryAfter: serverRetryAfter
            )
        }
    }

    private func processGameCenterIfPossible() async {
        guard durable.gameCenterOptedIn else {
            gameCenterConnection = .disabled
            gameCenterReportStatus = .localOnly
            return
        }
        guard !gameCenterAuthenticationIsInFlight else { return }
        guard await ensureDurableStateForExternalIO() else {
            gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
                ? .localOnly
                : .deferred
            return
        }
        let operationEpoch = gameCenterOperationEpoch
        var attemptedRestoredAuthentication = false
        do {
            let client = try await platformGateway.gameCenterClient()
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            let stateSession = try await client.issueSession(for: .authenticationState)
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            var authentication = try await client.authenticationState(session: stateSession)
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            adoptAuthenticationState(authentication)
            if authentication == .notAuthenticated,
               !gameCenterAuthenticationWasAttemptedThisActivation
            {
                gameCenterAuthenticationWasAttemptedThisActivation = true
                gameCenterAuthenticationIsInFlight = true
                attemptedRestoredAuthentication = true
                gameCenterConnection = .authenticating
                gameCenterAuthenticationWasUserInitiated = true
                publishStatus()
                let authenticationSession = try await client.issueSession(
                    for: .requestAuthentication
                )
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
                authentication = try await client.requestAuthentication(
                    session: authenticationSession
                )
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
                gameCenterAuthenticationIsInFlight = false
                adoptAuthenticationState(authentication)
                publishStatus()
            }
            guard authentication == .authenticated else {
                if !durable.gameCenterOutbox.pendingEntries.isEmpty {
                    armGameCenterAvailabilityProbe()
                }
                return
            }
            gameCenterAvailabilityProbeAt = nil
            let scopeSession = try await client.issueSession(for: .accountScope)
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            let accountScope = try await client.accountScopeDigest(session: scopeSession)
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            if let accountScope,
               let bound = durable.boundGameCenterAccountScope,
               bound != accountScope
            {
                durable.gameCenterOutbox = try durable.gameCenterOutbox
                    .rebindForAccountChange(localCandidates: gameCenterCandidatesForRebind())
                durable.boundGameCenterAccountScope = accountScope
                gameCenterOperationEpoch &+= 1
                gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
                    ? .mirrored
                    : .pending
                if !(await persistDurableStateIfPossible()) {
                    gameCenterReportStatus = .deferred
                }
                publishStatus()
                scheduleImmediateWork(reason: .explicitRequest)
                return
            }
            if durable.boundGameCenterAccountScope == nil {
                durable.boundGameCenterAccountScope = accountScope
                guard await persistDurableStateIfPossible() else {
                    gameCenterReportStatus = .deferred
                    return
                }
                guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            }
            durable.gameCenterOutbox = try durable.gameCenterOutbox
                .resumeDeferred(after: .authenticated)
                .resumeDeferred(after: .connectivityRestored)
            if gameCenterProbeWasRequested {
                durable.gameCenterOutbox = try durable.gameCenterOutbox
                    .resumeDeferred(after: .retryProbe)
                gameCenterProbeWasRequested = false
            }

            let candidates = try durable.gameCenterOutbox.nextBatch(
                connection: .connected,
                now: environment.now()
            )
            guard !candidates.isEmpty else {
                gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
                    ? .mirrored
                    : .deferred
                armGameCenterAvailabilityProbe()
                return
            }
            let ids = Set(candidates.map(\.achievementID))
            durable.gameCenterOutbox = try durable.gameCenterOutbox.markInFlight(ids)
            gameCenterReportStatus = .reporting
            guard await persistDurableStateIfPossible() else {
                try recordGameCenterFailures(ids, category: .serviceUnavailable)
                gameCenterReportStatus = .deferred
                return
            }
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            publishStatus()

            let reports = try candidates.map {
                try GameCenterAchievementReportDTO(
                    identifier: $0.gameCenterIdentifier,
                    percentage: $0.percentage
                )
            }
            let reportSession = try await client.issueSession(for: .reportAchievements)
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            try await client.report(reports, session: reportSession)
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            for candidate in candidates {
                durable.gameCenterOutbox = try durable.gameCenterOutbox.recordSuccess(
                    achievementID: candidate.achievementID,
                    reportedPercentage: candidate.percentage
                )
            }
            gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
                ? .mirrored
                : .pending
            armGameCenterAvailabilityProbe()
        } catch {
            guard gameCenterOperationIsCurrent(operationEpoch) else { return }
            gameCenterAuthenticationIsInFlight = false
            if attemptedRestoredAuthentication,
               error as? GameCenterReportingTransportError
                   == .authenticationPresentationUnavailable,
               !gameCenterAuthenticationPresentationRetryWasConsumed
            {
                gameCenterAuthenticationRetryOnNextApplicationActivation = true
            } else if attemptedRestoredAuthentication {
                gameCenterAuthenticationRetryOnNextApplicationActivation = false
            }
            let category = gameCenterFailureCategory(for: error)
            let inFlightIDs = durable.gameCenterOutbox.pendingEntries
                .filter { $0.state == .inFlight }
                .map(\.candidate.achievementID)
            do {
                try recordGameCenterFailures(
                    inFlightIDs,
                    category: category,
                    serverRetryAfter: gameCenterRetryAfter(for: error)
                )
            } catch {
                persistenceIsDurable = false
                cloudPhase = .persistenceDegraded
            }
            adoptGameCenterFailure(error)
            if category == .offline || category == .notAuthenticated ||
                durable.gameCenterOutbox.pendingEntries.contains(where: {
                    $0.deferralReason == .retryExhausted
                })
            {
                armGameCenterAvailabilityProbe()
            }
            if durable.gameCenterOutbox.pendingEntries.contains(where: {
                $0.deferralReason == .retryExhausted
            }) {
                gameCenterReportStatus = .retryExhausted
            } else {
                gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
                    ? .localOnly
                    : .deferred
            }
        }
    }

    private func gameCenterOperationIsCurrent(_ epoch: UInt64) -> Bool {
        runtimeIsActive && durable.gameCenterOptedIn && gameCenterOperationEpoch == epoch
    }

    private func recordGameCenterFailures<S: Sequence>(
        _ achievementIDs: S,
        category: GameCenterFailureCategory,
        serverRetryAfter: Date? = nil
    ) throws where S.Element == AchievementID {
        for id in achievementIDs {
            durable.gameCenterOutbox = try durable.gameCenterOutbox.recordFailure(
                achievementID: id,
                category: category,
                now: environment.now(),
                serverRetryAfter: serverRetryAfter
            )
        }
    }

    private func gameCenterCandidatesForRebind() throws -> [GameCenterReportCandidate] {
        guard let lastProgressionSnapshot else {
            return durable.lastLocalGameCenterCandidates
                ?? durable.gameCenterOutbox.pendingEntries.map(\.candidate)
        }
        return try GameCenterMappingPolicy.priorCompletionCandidates(
            from: lastProgressionSnapshot,
            catalog: loadGameCenterCatalog()
        )
    }

    private func deferGameCenterInFlightForOptOut() throws {
        let inFlightIDs = durable.gameCenterOutbox.pendingEntries
            .filter { $0.state == .inFlight }
            .map(\.candidate.achievementID)
        try recordGameCenterFailures(inFlightIDs, category: .notAuthenticated)
    }

    private func currentProgressionMergeDelivery() throws
        -> RuntimeProgressionExternalMergeDelivery?
    {
        guard let pendingCloudMerge,
              let local = lastProgressionProjection
        else { return nil }
        let uuid = pendingCloudMerge.deliveryID.uuidString.lowercased()
        let metadata = RuntimeOperationMetadata(
            schemaVersion: RuntimeSchemaVersions.v1,
            operationID: RuntimeOperationID("operation.external-merge.\(uuid)"),
            correlationID: RuntimeCorrelationID("correlation.external-merge.\(uuid)"),
            sourceModuleID: "com.runescribe.runtime.cloud-game-center",
            destinationModuleID: RuneScribeModuleIDs.progression,
            runtimeGeneration: runtimeGeneration,
            timestampUTC: environment.now(),
            operationIdentifier: "progression.external-merge.apply",
            privacyClass: .internalData,
            idempotencyKey: RuntimeIdempotencyKey("external-merge.\(uuid)")
        )
        return RuntimeProgressionExternalMergeDelivery(
            deliveryID: pendingCloudMerge.deliveryID,
            sourceLocalRevision: pendingCloudMerge.sourceLocalRevision,
            projection: try RuntimeProgressionExternalProjectionMapper.externalProjection(
                from: pendingCloudMerge.replica,
                localRevision: local.localRevision,
                initializedAt: local.initializedAt
            ),
            operationMetadata: metadata
        )
    }

    private func yieldProgressionMergeDelivery() throws {
        guard let delivery = try currentProgressionMergeDelivery() else { return }
        for continuation in mergeContinuations.values { continuation.yield(delivery) }
    }

    private func removeMergeContinuation(_ key: UInt64) {
        mergeContinuations.removeValue(forKey: key)
    }

    private func ensureProgressionDeviceID() -> CloudOpaqueIdentifier {
        if let value = durable.progressionDeviceID { return value }
        let value = RuntimeProgressionExternalProjectionMapper.opaqueIdentifier(
            "progression-device|\(environment.nextUUID().uuidString.lowercased())"
        )
        durable.progressionDeviceID = value
        return value
    }

    private func counterAdjustedProjection(
        _ authoritative: RuntimeProgressionExternalProjection,
        observation: ProgressionCounterObservation
    ) throws -> (
        projection: RuntimeProgressionExternalProjection,
        trackers: [ProgressionCounterTracker]
    ) {
        let existing = Dictionary(
            uniqueKeysWithValues: (durable.progressionCounterTrackers ?? []).map {
                ($0.key, $0)
            }
        )
        var next: [ProgressionCounterTracker] = []
        var deviceCounters: [RuntimeProgressionCounterFact] = []
        next.reserveCapacity(authoritative.counters.count)
        deviceCounters.reserveCapacity(authoritative.counters.count)

        let schemaByID = Dictionary(
            uniqueKeysWithValues: authoritative.statisticSchemas.map {
                ($0.statisticID, $0)
            }
        )
        let counterFacts = authoritative.counters.filter { fact in
            schemaByID.isEmpty || schemaByID[fact.statisticID]?.transport == .deviceCounter
        }
        for fact in counterFacts {
            let key = "\(fact.statisticID.rawValue)|\(fact.codexID?.rawValue ?? "")"
            let tracker: ProgressionCounterTracker
            if var prior = existing[key] {
                if observation == .localSnapshot {
                    let delta: UInt64
                    if let pendingImportedTotal = prior.pendingImportedTotal,
                       fact.value >= pendingImportedTotal
                    {
                        delta = fact.value - pendingImportedTotal
                    } else {
                        guard fact.value >= prior.lastAuthoritativeTotal else {
                            throw ModuleStateStoreError.invalidRequest
                        }
                        delta = fact.value - prior.lastAuthoritativeTotal
                    }
                    let (value, overflow) = prior.deviceContribution
                        .addingReportingOverflow(delta)
                    guard !overflow else {
                        throw CloudProgressionSchemaError.invalidCounter
                    }
                    prior.deviceContribution = value
                }
                prior.lastAuthoritativeTotal = fact.value
                prior.pendingImportedTotal = nil
                tracker = prior
            } else {
                tracker = ProgressionCounterTracker(
                    statisticID: fact.statisticID,
                    codexID: fact.codexID,
                    deviceContribution: observation == .localSnapshot ? fact.value : 0,
                    lastAuthoritativeTotal: fact.value,
                    pendingImportedTotal: nil
                )
            }
            next.append(tracker)
            deviceCounters.append(RuntimeProgressionCounterFact(
                statisticID: tracker.statisticID,
                codexID: tracker.codexID,
                value: tracker.deviceContribution
            ))
        }

        next.sort { $0.key < $1.key }
        deviceCounters.sort {
            ($0.statisticID.rawValue, $0.codexID?.rawValue ?? "")
                < ($1.statisticID.rawValue, $1.codexID?.rawValue ?? "")
        }
        return (
            RuntimeProgressionExternalProjection(
                catalogVersion: authoritative.catalogVersion,
                localRevision: authoritative.localRevision,
                initializedAt: authoritative.initializedAt,
                counters: deviceCounters,
                distinctTokens: authoritative.distinctTokens,
                achievements: authoritative.achievements,
                milestones: authoritative.milestones,
                grants: authoritative.grants,
                ownedContentIDs: authoritative.ownedContentIDs,
                unlockIDs: authoritative.unlockIDs,
                titleIDs: authoritative.titleIDs,
                encounters: authoritative.encounters,
                selectedTitleID: authoritative.selectedTitleID,
                selectedTitleUpdatedAt: authoritative.selectedTitleUpdatedAt,
                knownStatisticIDs: authoritative.knownStatisticIDs,
                knownAchievementIDs: authoritative.knownAchievementIDs,
                knownMilestoneRuleIDs: authoritative.knownMilestoneRuleIDs,
                knownContentIDs: authoritative.knownContentIDs,
                knownArtifactIDs: authoritative.knownArtifactIDs,
                knownUnlockIDs: authoritative.knownUnlockIDs,
                knownTitleIDs: authoritative.knownTitleIDs,
                statisticSchemas: authoritative.statisticSchemas,
                knownCodexIDs: authoritative.knownCodexIDs
            ),
            next
        )
    }

    private func stagePendingImportedCounterTotals(
        _ replica: CloudProgressionReplica
    ) throws {
        var totals: [String: UInt64] = [:]
        var identities: [String: (StatisticID, CodexID?)] = [:]
        for shard in replica.deviceCounterShards {
            let key = "\(shard.statisticID.rawValue)|\(shard.codexID?.rawValue ?? "")"
            let (total, overflow) = (totals[key] ?? 0).addingReportingOverflow(shard.value)
            guard !overflow else { throw CloudProgressionSchemaError.invalidCounter }
            totals[key] = total
            identities[key] = (shard.statisticID, shard.codexID)
        }
        var trackers = Dictionary(
            uniqueKeysWithValues: (durable.progressionCounterTrackers ?? []).map {
                ($0.key, $0)
            }
        )
        for (key, total) in totals {
            if var tracker = trackers[key] {
                guard total >= tracker.lastAuthoritativeTotal else {
                    throw CloudProgressionSchemaError.invalidCounter
                }
                tracker.pendingImportedTotal = total
                trackers[key] = tracker
            } else if let identity = identities[key] {
                trackers[key] = ProgressionCounterTracker(
                    statisticID: identity.0,
                    codexID: identity.1,
                    deviceContribution: 0,
                    lastAuthoritativeTotal: 0,
                    pendingImportedTotal: total
                )
            }
        }
        durable.progressionCounterTrackers = trackers.values.sorted { $0.key < $1.key }
    }

    private func clearPendingImportedCounterTotals() {
        durable.progressionCounterTrackers = durable.progressionCounterTrackers?.map {
            var tracker = $0
            tracker.pendingImportedTotal = nil
            return tracker
        }
    }

    private func cloudPendingGameCenterReports() throws
        -> [CloudPendingGameCenterReport]
    {
        let metadataByID = Dictionary(
            uniqueKeysWithValues: (durable.gameCenterCloudReportMetadata ?? []).map {
                ($0.achievementID, $0)
            }
        )
        let reports = try durable.gameCenterOutbox.pendingEntries.map { entry in
            let stableDate = entry.candidate.locallyCompletedAt
                ?? Date(timeIntervalSinceReferenceDate: TimeInterval(
                    min(entry.candidate.localRevision, UInt64(Int.max))
                ))
            let metadata = metadataByID[entry.candidate.achievementID]
            return try CloudPendingGameCenterReport(
                achievementID: entry.candidate.achievementID,
                percentage: entry.candidate.percentage,
                firstQueuedAt: min(metadata?.firstQueuedAt ?? stableDate, stableDate),
                lastUpdatedAt: max(metadata?.lastUpdatedAt ?? stableDate, stableDate)
            )
        }
        durable.gameCenterCloudReportMetadata = reports.isEmpty ? nil : reports
        return reports
    }

    private func adoptCorroboratedCloudGameCenterReportMetadata(
        _ remote: [CloudPendingGameCenterReport],
        candidates: [GameCenterReportCandidate]
    ) throws {
        let candidateByID = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.achievementID, $0) }
        )
        var metadataByID = Dictionary(
            uniqueKeysWithValues: (durable.gameCenterCloudReportMetadata ?? []).map {
                ($0.achievementID, $0)
            }
        )
        for report in remote {
            guard let candidate = candidateByID[report.achievementID],
                  report.percentage <= candidate.percentage,
                  report.percentage < 100 || candidate.locallyCompletedAt != nil
            else { continue }
            if let existing = metadataByID[report.achievementID] {
                metadataByID[report.achievementID] = try CloudPendingGameCenterReport(
                    achievementID: report.achievementID,
                    percentage: max(existing.percentage, report.percentage),
                    firstQueuedAt: min(existing.firstQueuedAt, report.firstQueuedAt),
                    lastUpdatedAt: max(existing.lastUpdatedAt, report.lastUpdatedAt)
                )
            } else {
                metadataByID[report.achievementID] = report
            }
        }
        durable.gameCenterCloudReportMetadata = metadataByID.values.sorted {
            $0.achievementID < $1.achievementID
        }
    }

    private func selectedCodexProjection(
        snapshot: ProgressionSnapshotDTO,
        deviceID: CloudOpaqueIdentifier
    ) async throws -> CloudCodexSelection? {
        guard let settingsGateway else { return nil }
        let settings = try await settingsGateway.snapshot()
        guard let setting = settings.settings.first(where: {
            $0.settingID == RuneScribeRuntimeSettings.selectedCodex
        }) else { return nil }
        let codexID = settings.selectedCodexID
        guard
           snapshot.codexGates.contains(where: {
               $0.codexID == codexID && $0.unlockedAt != nil
           })
        else { return nil }
        if let tracked = durable.progressionCodexSelection,
           tracked.codexID == codexID
        {
            return try CloudCodexSelection(
                codexID: tracked.codexID,
                logicalTimestamp: tracked.logicalTimestamp,
                writerDeviceID: tracked.writerDeviceID,
                updatedAt: tracked.updatedAt
            )
        }
        let priorClock = max(
            durable.progressionCodexSelection?.logicalTimestamp ?? 0,
            cloudProjection?.replica.selectedCodex?.logicalTimestamp ?? 0
        )
        let (nextClock, overflow) = priorClock.addingReportingOverflow(1)
        guard !overflow else { throw CloudProgressionSchemaError.invalidLogicalClock }
        let tracked = ProgressionCodexSelectionTracker(
            codexID: codexID,
            logicalTimestamp: max(nextClock, max(1, setting.revision)),
            writerDeviceID: deviceID,
            updatedAt: setting.updatedAt ?? snapshot.capturedAt
        )
        durable.progressionCodexSelection = tracked
        return try CloudCodexSelection(
            codexID: tracked.codexID,
            logicalTimestamp: tracked.logicalTimestamp,
            writerDeviceID: tracked.writerDeviceID,
            updatedAt: tracked.updatedAt
        )
    }

    private func selectedTitleProjection(
        _ authoritative: RuntimeProgressionExternalProjection,
        deviceID: CloudOpaqueIdentifier
    ) throws -> CloudTitleSelection? {
        guard let updatedAt = authoritative.selectedTitleUpdatedAt else { return nil }
        if let tracked = durable.progressionTitleSelection,
           tracked.titleID == authoritative.selectedTitleID,
           tracked.updatedAt == updatedAt
        {
            return try CloudTitleSelection(
                titleID: tracked.titleID,
                logicalTimestamp: tracked.logicalTimestamp,
                writerDeviceID: tracked.writerDeviceID,
                updatedAt: tracked.updatedAt
            )
        }
        let priorClock = max(
            durable.progressionTitleSelection?.logicalTimestamp ?? 0,
            cloudProjection?.replica.selectedTitle?.logicalTimestamp ?? 0
        )
        let (logicalTimestamp, overflow) = priorClock.addingReportingOverflow(1)
        guard !overflow, logicalTimestamp < UInt64.max else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        let tracker = ProgressionTitleSelectionTracker(
            titleID: authoritative.selectedTitleID,
            logicalTimestamp: logicalTimestamp,
            writerDeviceID: deviceID,
            updatedAt: updatedAt
        )
        durable.progressionTitleSelection = tracker
        return try CloudTitleSelection(
            titleID: tracker.titleID,
            logicalTimestamp: tracker.logicalTimestamp,
            writerDeviceID: tracker.writerDeviceID,
            updatedAt: tracker.updatedAt
        )
    }

    private func adoptSelectedTitleAfterProgressionApply(
        _ replica: CloudProgressionReplica,
        authoritative: RuntimeProgressionExternalProjection,
        deviceID: CloudOpaqueIdentifier
    ) throws {
        guard let remote = replica.selectedTitle else { return }
        if authoritative.selectedTitleID == remote.titleID,
           authoritative.selectedTitleUpdatedAt == remote.updatedAt
        {
            durable.progressionTitleSelection = ProgressionTitleSelectionTracker(
                titleID: remote.titleID,
                logicalTimestamp: remote.logicalTimestamp,
                writerDeviceID: remote.writerDeviceID,
                updatedAt: remote.updatedAt
            )
            return
        }
        let (logicalTimestamp, overflow) = remote.logicalTimestamp
            .addingReportingOverflow(1)
        guard !overflow, logicalTimestamp < UInt64.max else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        durable.progressionTitleSelection = ProgressionTitleSelectionTracker(
            titleID: authoritative.selectedTitleID,
            logicalTimestamp: logicalTimestamp,
            writerDeviceID: deviceID,
            updatedAt: authoritative.selectedTitleUpdatedAt ?? environment.now()
        )
    }

    private func adoptSelectedCodexAfterProgressionApply(
        _ replica: CloudProgressionReplica,
        snapshot: ProgressionSnapshotDTO,
        fallbackCodexID: CodexID
    ) async throws {
        guard let settingsGateway, let remoteSelection = replica.selectedCodex else {
            return
        }
        let unlockedCodexIDs = Set(snapshot.codexGates.compactMap { gate in
            gate.unlockedAt == nil ? nil : gate.codexID
        })
        let selection: ProgressionCodexSelectionTracker
        if unlockedCodexIDs.contains(remoteSelection.codexID) {
            selection = ProgressionCodexSelectionTracker(
                codexID: remoteSelection.codexID,
                logicalTimestamp: remoteSelection.logicalTimestamp,
                writerDeviceID: remoteSelection.writerDeviceID,
                updatedAt: remoteSelection.updatedAt
            )
        } else {
            guard unlockedCodexIDs.contains(fallbackCodexID) else {
                throw ModuleStateStoreError.invalidRequest
            }
            let (logicalTimestamp, overflow) = remoteSelection.logicalTimestamp
                .addingReportingOverflow(1)
            guard !overflow, logicalTimestamp < UInt64.max else {
                throw CloudProgressionSchemaError.invalidLogicalClock
            }
            selection = ProgressionCodexSelectionTracker(
                codexID: fallbackCodexID,
                logicalTimestamp: logicalTimestamp,
                writerDeviceID: ensureProgressionDeviceID(),
                updatedAt: environment.now()
            )
        }
        durable.progressionCodexSelection = selection
        let settings = try await settingsGateway.snapshot()
        guard settings.selectedCodexID != selection.codexID else { return }
        suppressSelectedCodexObservation = true
        defer { suppressSelectedCodexObservation = false }
        let preference = try RuntimeSelectedCodexPreference(codexID: selection.codexID)
        let updated = try await settingsGateway.set(
            SetRuntimeSettingCommand(
                settingID: RuneScribeRuntimeSettings.selectedCodex,
                value: .text(try RuntimeSelectedCodexPreferenceCodec.encode(preference))
            )
        )
        lastObservedSelectedCodexSettingRevision = updated.revision
    }

    private func startSettingsObservation() {
        guard let settingsGateway else { return }
        settingsObservationTask?.cancel()
        let generation = runtimeGeneration
        settingsObservationTask = Task { [weak self] in
            let stream = await settingsGateway.stream()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await self?.selectedCodexSettingDidChange(
                    snapshot,
                    generation: generation
                )
            }
        }
    }

    private func selectedCodexSettingDidChange(
        _ settings: RuntimeSettingsSnapshotDTO,
        generation: UInt64
    ) async {
        guard runtimeIsActive, runtimeGeneration == generation,
              let setting = settings.settings.first(where: {
                  $0.settingID == RuneScribeRuntimeSettings.selectedCodex
              })
        else { return }
        if lastObservedSelectedCodexSettingRevision == setting.revision { return }
        lastObservedSelectedCodexSettingRevision = setting.revision
        guard !suppressSelectedCodexObservation,
              lastProgressionSnapshot != nil,
              lastProgressionProjection != nil
        else { return }
        selectedCodexRetryTask?.cancel()
        selectedCodexRetryTask = nil
        selectedCodexSubmissionState = .pending(settingRevision: setting.revision)
        await submitSelectedCodexSettingProjection(
            settingRevision: setting.revision,
            failedAttemptCount: 0,
            generation: generation
        )
    }

    private func submitSelectedCodexSettingProjection(
        settingRevision: UInt64,
        failedAttemptCount: UInt16,
        generation: UInt64
    ) async {
        guard runtimeIsActive,
              runtimeGeneration == generation,
              lastObservedSelectedCodexSettingRevision == settingRevision,
              let snapshot = lastProgressionSnapshot,
              let projection = lastProgressionProjection
        else { return }
        do {
            lastObservedProgressionRevision = nil
            _ = try await submitProgressionSnapshot(snapshot, projection: projection)
            selectedCodexSubmissionState = .idle
            selectedCodexRetryTask = nil
        } catch {
            guard selectedCodexSubmissionErrorIsTransient(error) else {
                selectedCodexSubmissionState = .terminal(
                    settingRevision: settingRevision,
                    reason: .invalidProjection
                )
                selectedCodexRetryTask = nil
                cloudPhase = persistenceIsDurable ? .queued : .persistenceDegraded
                publishStatus()
                return
            }
            let nextAttempt = min(failedAttemptCount &+ 1, 10)
            selectedCodexSubmissionState = .retrying(
                settingRevision: settingRevision,
                failedAttemptCount: nextAttempt
            )
            cloudPhase = persistenceIsDurable ? .queued : .persistenceDegraded
            publishStatus()
            let delay = min(TimeInterval(1 << nextAttempt) * 0.125, 4)
            selectedCodexRetryTask = Task { [weak self, sleep] in
                await sleep(delay)
                guard !Task.isCancelled else { return }
                await self?.submitSelectedCodexSettingProjection(
                    settingRevision: settingRevision,
                    failedAttemptCount: nextAttempt,
                    generation: generation
                )
            }
        }
    }

    private func selectedCodexSubmissionErrorIsTransient(_ error: Error) -> Bool {
        if let stateError = error as? ModuleStateStoreError {
            switch stateError {
            case .unavailable, .revisionConflict, .injectedFailure:
                return true
            case .invalidRequest, .payloadTooLarge, .transactionTooLarge,
                 .quarantined, .integrityMismatch, .unreadable, .corrupt:
                return false
            }
        }
        if let runtimeError = error as? RuneScribeRuntimeError {
            switch runtimeError {
            case .runtimeBusy, .serviceUnavailable, .endpointUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func loadGameCenterCatalog() throws -> GameCenterAchievementCatalog {
        if let gameCenterCatalog { return gameCenterCatalog }
        let resource = GameCenterCatalogResourceCatalog.catalog
        guard let bundle = GameCenterCatalogResourceCatalog.ownerScopedResourceBundles[
            GameCenterCatalogResourceCatalog.ownerModuleID
        ], let url = bundle.url(
            forResource: resource.name,
            withExtension: resource.fileExtension,
            subdirectory: resource.subdirectory
        ) else { throw GameCenterCatalogError.invalidInventory }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let catalog = try GameCenterCatalogResourceCatalog.decodeAndValidate(data)
        gameCenterCatalog = catalog
        return catalog
    }

    @discardableResult
    private func loadDurableStateIfAvailable() async -> Bool {
        let overlay = durable
        let record: ModuleStateRecord?
        do {
            _ = try await stateGateway.runtimePrepare(
                namespace: Self.namespace,
                schemaVersion: Self.schemaVersion
            )
            let page = try await stateGateway.runtimeScan(
                namespace: Self.namespace,
                request: ModuleStateScanRequest(
                    collectionID: Self.collectionID,
                    limit: 2
                )
            )
            guard page.nextCursor == nil, page.records.count <= 1 else {
                throw ModuleStateStoreError.corrupt
            }
            record = page.records.first
            if let record {
                durableRecordID = record.key.recordID
            } else {
                let health = try await stateGateway.runtimeHealth(
                    namespace: Self.namespace
                )
                durableRecordID = health.quarantinedRecordCount == 0
                    ? Self.recordID
                    : nextRecoveryRecordID()
            }
        } catch {
            persistenceIsDurable = false
            durableLoadState = .unavailable
            armPersistenceAvailabilityProbe()
            return false
        }

        guard let record else {
            durable = overlay
            durableLoadState = .confirmedAbsent
            persistenceIsDurable = true
            persistenceAvailabilityProbeAt = nil
            return true
        }

        do {
            guard record.schemaVersion == Self.schemaVersion else {
                throw ModuleStateStoreError.corrupt
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let persisted = try decoder.decode(DurableState.self, from: record.payload)
                .validated()
            let recoveredInterruptedReports = persisted.gameCenterOutbox.pendingEntries
                .contains { $0.state == .inFlight }
            durable = try mergeRecoveredDurableState(persisted, overlay: overlay)
            durableLoadState = .loaded
            persistenceIsDurable = true
            persistenceAvailabilityProbeAt = nil
            pendingGameCenterOptInPreference = nil
            lastObservedProgressionRevision = nil
            if recoveredInterruptedReports {
                return await persistDurableStateIfPossible()
            }
            return true
        } catch {
            do {
                _ = try await stateGateway.runtimeQuarantineRecord(
                    namespace: Self.namespace,
                    key: record.key,
                    expectedRevision: record.revision,
                    diagnosticCode: "cloud-game-center-state-invalid"
                )
                durableRecordID = nextRecoveryRecordID()
                durable = try overlay.validated()
                if durable.cloudQuarantineCount < UInt32.max {
                    durable.cloudQuarantineCount += 1
                }
                durableLoadState = .confirmedAbsent
                persistenceIsDurable = true
                persistenceAvailabilityProbeAt = nil
                return await persistDurableStateIfPossible()
            } catch {
                durableLoadState = .unavailable
                armPersistenceAvailabilityProbe()
            }
            persistenceIsDurable = false
            return false
        }
    }

    private func mergeRecoveredDurableState(
        _ persisted: DurableState,
        overlay: DurableState
    ) throws -> DurableState {
        var result = persisted
        if let pendingRevision = overlay.cloudQueue.pendingRevision {
            result.cloudQueue = try result.cloudQueue.enqueue(
                localRevision: pendingRevision
            )
        }
        result.lastKnownCloudRevision = max(
            result.lastKnownCloudRevision,
            overlay.lastKnownCloudRevision
        )
        result.gameCenterOutbox = try result.gameCenterOutbox.enqueue(
            overlay.gameCenterOutbox.pendingEntries.map(\.candidate)
        )
        result.gameCenterOptedIn = pendingGameCenterOptInPreference
            ?? result.gameCenterOptedIn
        let combinedCandidates = (result.lastLocalGameCenterCandidates ?? [])
            + (overlay.lastLocalGameCenterCandidates ?? [])
        result.lastLocalGameCenterCandidates = try GameCenterReportOutbox()
            .enqueue(combinedCandidates)
            .pendingEntries
            .map(\.candidate)
        result.progressionDeviceID = result.progressionDeviceID
            ?? overlay.progressionDeviceID
        result.progressionCounterTrackers = result.progressionCounterTrackers
            ?? overlay.progressionCounterTrackers
        if let overlaySelection = overlay.progressionCodexSelection,
           result.progressionCodexSelection.map({
               $0.logicalTimestamp < overlaySelection.logicalTimestamp
           }) ?? true
        {
            result.progressionCodexSelection = overlaySelection
        }
        if let overlaySelection = overlay.progressionTitleSelection,
           result.progressionTitleSelection.map({
               $0.logicalTimestamp < overlaySelection.logicalTimestamp
           }) ?? true
        {
            result.progressionTitleSelection = overlaySelection
        }
        result.cloudInboundPollState = result.cloudInboundPollState
            ?? overlay.cloudInboundPollState
        result.gameCenterCloudReportMetadata = try mergeCloudReportMetadata(
            result.gameCenterCloudReportMetadata ?? [],
            overlay.gameCenterCloudReportMetadata ?? []
        )
        result.gameCenterOutbox = try result.gameCenterOutbox.recoverInterruptedReports()
        return try result.validated()
    }

    private func mergeCloudReportMetadata(
        _ first: [CloudPendingGameCenterReport],
        _ second: [CloudPendingGameCenterReport]
    ) throws -> [CloudPendingGameCenterReport]? {
        var byID: [AchievementID: CloudPendingGameCenterReport] = [:]
        for value in first + second {
            if let existing = byID[value.achievementID] {
                byID[value.achievementID] = try CloudPendingGameCenterReport(
                    achievementID: value.achievementID,
                    percentage: max(existing.percentage, value.percentage),
                    firstQueuedAt: min(existing.firstQueuedAt, value.firstQueuedAt),
                    lastUpdatedAt: max(existing.lastUpdatedAt, value.lastUpdatedAt)
                )
            } else {
                byID[value.achievementID] = value
            }
        }
        let values = byID.values.sorted { $0.achievementID < $1.achievementID }
        return values.isEmpty ? nil : values
    }

    @discardableResult
    private func persistDurableStateIfPossible() async -> Bool {
        guard runtimeIsActive,
              durableLoadState == .loaded || durableLoadState == .confirmedAbsent
        else {
            persistenceIsDurable = false
            return false
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let payload = try encoder.encode(durable.validated())
            let transaction = try ModuleStateTransaction(
                transactionID: environment.nextUUID(),
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: ModuleStateRecordKey(
                                collectionID: Self.collectionID,
                                recordID: durableRecordID
                            ),
                            schemaVersion: Self.schemaVersion,
                            payload: payload,
                            expectedRevision: .any
                        )
                    ),
                ]
            )
            _ = try await stateGateway.runtimeTransact(
                namespace: Self.namespace,
                transaction: transaction
            )
            persistenceIsDurable = true
            persistenceAvailabilityProbeAt = nil
            return true
        } catch {
            persistenceIsDurable = false
            armPersistenceAvailabilityProbe()
            return false
        }
    }

    private func ensureDurableStateForExternalIO() async -> Bool {
        if persistenceIsDurable { return true }
        if durableLoadState == .unavailable || durableLoadState == .notAttempted {
            guard await loadDurableStateIfAvailable() else { return false }
            if let snapshot = lastProgressionSnapshot,
               let projection = lastProgressionProjection
            {
                cloudProjection = nil
                lastObservedProgressionRevision = nil
                do {
                    _ = try await submitProgressionSnapshot(
                        snapshot,
                        projection: projection
                    )
                } catch {
                    cloudPhase = .persistenceDegraded
                    return false
                }
                scheduleImmediateWork(reason: .explicitRequest)
                return false
            }
        }
        return await persistDurableStateIfPossible()
    }

    private func nextRecoveryRecordID() -> ModuleStateRecordID {
        let token = environment.nextUUID().uuidString
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
        return ModuleStateRecordID(
            rawValue: "orchestration.recovery.\(token)"
        )!
    }

    private func scheduleImmediateWork(reason _: RuntimeExternalServiceWakeReason) {
        guard automaticScheduling, runtimeIsActive else { return }
        scheduledTask?.cancel()
        let generation = runtimeGeneration
        scheduledTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            await self?.scheduledWake(generation: generation)
        }
    }

    private func scheduleNextRetryIfNeeded() {
        guard automaticScheduling, runtimeIsActive else { return }
        var dates: [Date] = []
        let cloudDates = [
            durable.cloudQueue.nextEligibleAttemptAt,
            durable.cloudInboundPollState?.nextEligibleAttemptAt,
        ].compactMap { $0 }
        if let cloudDate = cloudDates.max() {
            dates.append(cloudDate)
        }
        dates.append(contentsOf: durable.gameCenterOutbox.pendingEntries.compactMap {
            $0.deferralReason == .scheduledRetry ? $0.nextEligibleAttemptAt : nil
        })
        if let cloudAvailabilityProbeAt { dates.append(cloudAvailabilityProbeAt) }
        if let gameCenterAvailabilityProbeAt { dates.append(gameCenterAvailabilityProbeAt) }
        if let persistenceAvailabilityProbeAt {
            dates.append(persistenceAvailabilityProbeAt)
        }
        guard let next = dates.min() else { return }
        scheduledTask?.cancel()
        let generation = runtimeGeneration
        let delay = max(0, next.timeIntervalSince(environment.now()))
        scheduledTask = Task { [weak self, sleep] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.scheduledWake(generation: generation, scheduledAt: next)
        }
    }

    private func scheduledWake(
        generation: UInt64,
        scheduledAt: Date? = nil
    ) async {
        guard runtimeIsActive, runtimeGeneration == generation else { return }
        scheduledTask = nil
        if let scheduledAt {
            if let probe = cloudAvailabilityProbeAt, probe <= scheduledAt {
                cloudAvailabilityProbeAt = nil
                cloudPollWasRequested = true
                if durable.cloudInboundPollState == nil {
                    durable.cloudInboundPollState = .idle
                }
            }
            if let probe = gameCenterAvailabilityProbeAt, probe <= scheduledAt {
                gameCenterAvailabilityProbeAt = nil
                gameCenterProbeWasRequested = true
            }
            if let probe = persistenceAvailabilityProbeAt, probe <= scheduledAt {
                persistenceAvailabilityProbeAt = nil
            }
        }
        await runPendingWork()
    }

    private func armCloudAvailabilityProbe() {
        let proposed = environment.now().addingTimeInterval(
            Self.serviceAvailabilityProbeInterval
        )
        cloudAvailabilityProbeAt = min(cloudAvailabilityProbeAt ?? proposed, proposed)
    }

    private func armGameCenterAvailabilityProbe() {
        let proposed = environment.now().addingTimeInterval(
            Self.serviceAvailabilityProbeInterval
        )
        gameCenterAvailabilityProbeAt = min(
            gameCenterAvailabilityProbeAt ?? proposed,
            proposed
        )
    }

    private func armPersistenceAvailabilityProbe() {
        let proposed = environment.now().addingTimeInterval(
            Self.serviceAvailabilityProbeInterval
        )
        persistenceAvailabilityProbeAt = min(
            persistenceAvailabilityProbeAt ?? proposed,
            proposed
        )
    }

    private func adoptCloudAccountState(_ state: CloudAccountStateValueDTO) {
        switch state {
        case .available:
            cloudAccountStatus = .available
            cloudPhase = .queued
        case .noAccount:
            cloudAccountStatus = .noAccount
            cloudPhase = .waitingForAccount
        case .restricted:
            cloudAccountStatus = .restricted
            cloudPhase = .waitingForAccount
        case .temporarilyUnavailable, .couldNotDetermine:
            cloudAccountStatus = .temporarilyUnavailable
            cloudPhase = .waitingForAccount
        }
    }

    private func adoptCloudFailure(_ error: Error) {
        let category = cloudFailureCategory(for: error)
        do {
            try recordCloudFailure(
                category,
                serverRetryAfter: cloudRetryAfter(for: error)
            )
        } catch {
            persistenceIsDurable = false
            cloudPhase = .persistenceDegraded
            return
        }
        if category == .accountChanged {
            cloudAccountOperationEpoch &+= 1
            cloudPollWasRequested = false
        }
        switch category {
        case .offline:
            cloudPhase = .waitingForNetwork
            armCloudAvailabilityProbe()
        case .accountUnavailable:
            cloudPhase = .waitingForAccount
            armCloudAvailabilityProbe()
        case .accountChanged:
            cloudAccountStatus = .changed
            cloudPhase = .accountChangeRequiresRebind
        case .corruptRemote:
            cloudPhase = .quarantinedRemote
        case .permanentConfiguration:
            cloudPhase = .disabled
        case .rateLimited, .serviceUnavailable:
            if cloudRetryIsExhausted {
                cloudPhase = .retryExhausted
                armCloudAvailabilityProbe()
            } else {
                cloudPhase = .queued
            }
        }
    }

    private var cloudRetryIsExhausted: Bool {
        let outboundExhausted = durable.cloudQueue.pendingRevision != nil &&
            durable.cloudQueue.failedAttemptCount ==
                CloudSyncRetryPolicy.maximumAttemptCount &&
            durable.cloudQueue.nextEligibleAttemptAt == nil
        let inboundExhausted = durable.cloudInboundPollState.map {
            $0.failedAttemptCount == CloudSyncRetryPolicy.maximumAttemptCount &&
                $0.nextEligibleAttemptAt == nil
        } ?? false
        return outboundExhausted || inboundExhausted
    }

    private func durableCloudPhaseWithoutActiveOperation() -> RuntimeCloudSyncPhaseDTO {
        if cloudRetryIsExhausted { return .retryExhausted }
        return durable.cloudQueue.pendingRevision == nil ? .localOnly : .queued
    }

    private func adoptAuthenticationState(_ state: GameCenterAuthenticationStateDTO) {
        switch state {
        case .authenticated:
            gameCenterConnection = .connected
        case .notAuthenticated:
            gameCenterConnection = .authenticationAvailable
        case .restricted:
            gameCenterConnection = .restricted
        case .unavailable:
            gameCenterConnection = .unavailable
        }
        gameCenterReportStatus = durable.gameCenterOutbox.pendingEntries.isEmpty
            ? (state == .authenticated ? .mirrored : .localOnly)
            : (state == .authenticated ? .pending : .deferred)
    }

    private func adoptGameCenterFailure(_ error: Error) {
        guard let transport = error as? GameCenterReportingTransportError else {
            gameCenterConnection = .unavailable
            return
        }
        switch transport {
        case .notAuthenticated, .authenticationPresentationUnavailable:
            gameCenterConnection = .authenticationAvailable
        case .denied:
            gameCenterConnection = .declined
        case .restricted:
            gameCenterConnection = .restricted
        case .cancelled:
            gameCenterConnection = .cancelled
        case .offline:
            gameCenterConnection = .offline
        case .invalidReport, .rateLimited, .serviceUnavailable,
             .configurationUnavailable:
            gameCenterConnection = .unavailable
        }
    }

    private func initialGameCenterReportStatus() -> RuntimeGameCenterReportStatusDTO {
        guard !durable.gameCenterOutbox.pendingEntries.isEmpty else {
            return durable.gameCenterOptedIn ? .mirrored : .localOnly
        }
        return durable.gameCenterOptedIn ? .pending : .localOnly
    }

    private func publishStatus(force: Bool = false) {
        let candidate = Self.makeStatus(
            revision: statusRevision,
            capturedAt: environment.now(),
            durable: durable,
            persistenceIsDurable: persistenceIsDurable,
            cloudPhase: cloudPhase,
            cloudAccountStatus: cloudAccountStatus,
            gameCenterConnection: gameCenterConnection,
            gameCenterReportStatus: gameCenterReportStatus,
            authenticationWasUserInitiated: gameCenterAuthenticationWasUserInitiated
        )
        let changed = candidate.cloudSync != latestStatus.cloudSync
            || candidate.gameCenter != latestStatus.gameCenter
        guard force || changed else { return }
        if statusRevision < UInt64.max { statusRevision += 1 }
        latestStatus = Self.makeStatus(
            revision: statusRevision,
            capturedAt: environment.now(),
            durable: durable,
            persistenceIsDurable: persistenceIsDurable,
            cloudPhase: cloudPhase,
            cloudAccountStatus: cloudAccountStatus,
            gameCenterConnection: gameCenterConnection,
            gameCenterReportStatus: gameCenterReportStatus,
            authenticationWasUserInitiated: gameCenterAuthenticationWasUserInitiated
        )
        for continuation in continuations.values { continuation.yield(latestStatus) }
    }

    private static func makeStatus(
        revision: UInt64,
        capturedAt: Date,
        durable: DurableState,
        persistenceIsDurable: Bool,
        cloudPhase: RuntimeCloudSyncPhaseDTO,
        cloudAccountStatus: RuntimeCloudAccountStatusDTO,
        gameCenterConnection: RuntimeGameCenterConnectionDTO,
        gameCenterReportStatus: RuntimeGameCenterReportStatusDTO,
        authenticationWasUserInitiated: Bool
    ) -> RuntimeCloudGameCenterStatusSnapshotDTO {
        let cloud = try! RuntimeCloudSyncStatusDTO(
            phase: cloudPhase,
            accountStatus: cloudAccountStatus,
            localRevision: durable.lastKnownCloudRevision,
            pendingRevision: durable.cloudQueue.pendingRevision,
            lastSuccessfulSyncAt: durable.lastSuccessfulCloudSyncAt,
            quarantineCount: durable.cloudQuarantineCount,
            localProgressionAvailable: true,
            persistenceIsDurable: persistenceIsDurable
        )
        let gameCenter = try! RuntimeGameCenterStatusDTO(
            connection: gameCenterConnection,
            reportStatus: gameCenterReportStatus,
            pendingReportCount: UInt16(durable.gameCenterOutbox.pendingEntries.count),
            localProgressionAvailable: true,
            isOptedIn: durable.gameCenterOptedIn,
            authenticationWasUserInitiated: authenticationWasUserInitiated,
            persistenceIsDurable: persistenceIsDurable
        )
        return try! RuntimeCloudGameCenterStatusSnapshotDTO(
            revision: revision,
            capturedAt: capturedAt,
            cloudSync: cloud,
            gameCenter: gameCenter
        )
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

private func cloudFailureCategory(for error: Error) -> CloudSyncFailureCategory {
    guard let transport = error as? CloudSyncTransportError else {
        return .serviceUnavailable
    }
    switch transport {
    case .offline:
        return .offline
    case .accountUnavailable:
        return .accountUnavailable
    case .accountChanged:
        return .accountChanged
    case .corruptRemote:
        return .corruptRemote
    case .configurationUnavailable, .payloadTooLarge, .invalidChangeTag:
        return .permanentConfiguration
    case .rateLimited:
        return .rateLimited
    case .serviceUnavailable, .conflict:
        return .serviceUnavailable
    }
}

private func cloudRetryAfter(for error: Error) -> Date? {
    guard case let CloudSyncTransportError.rateLimited(retryAfter) = error else {
        return nil
    }
    return retryAfter
}

private func gameCenterFailureCategory(for error: Error) -> GameCenterFailureCategory {
    guard let transport = error as? GameCenterReportingTransportError else {
        return .serviceUnavailable
    }
    switch transport {
    case .offline:
        return .offline
    case .notAuthenticated, .authenticationPresentationUnavailable:
        return .notAuthenticated
    case .denied:
        return .denied
    case .restricted:
        return .restricted
    case .cancelled:
        return .cancelled
    case .rateLimited:
        return .rateLimited
    case .configurationUnavailable, .invalidReport:
        return .permanentConfiguration
    case .serviceUnavailable:
        return .serviceUnavailable
    }
}

private func gameCenterRetryAfter(for error: Error) -> Date? {
    guard case let GameCenterReportingTransportError.rateLimited(retryAfter) = error else {
        return nil
    }
    return retryAfter
}
