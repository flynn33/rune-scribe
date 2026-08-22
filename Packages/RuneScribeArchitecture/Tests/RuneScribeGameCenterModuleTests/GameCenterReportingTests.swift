import Foundation
import RuneScribeContracts
import Testing
@testable import RuneScribeGameCenterModule

@Test
func percentageMappingIsWholeNumberMonotonicAndOverflowSafe() throws {
    #expect(try GameCenterPercentagePolicy.percentage(current: 0, target: 3) == 0)
    #expect(try GameCenterPercentagePolicy.percentage(current: 1, target: 3) == 33)
    #expect(try GameCenterPercentagePolicy.percentage(current: 2, target: 3) == 66)
    #expect(try GameCenterPercentagePolicy.percentage(current: 3, target: 3) == 100)
    #expect(
        try GameCenterPercentagePolicy.percentage(
            current: UInt64.max - 1,
            target: UInt64.max
        ) == 99
    )
    #expect(throws: GameCenterReportingError.invalidProgress) {
        _ = try GameCenterPercentagePolicy.percentage(current: 4, target: 3)
    }
}

@Test
func mappingUsesOnlyLocalProgressionAndLaterOptInIncludesPriorCompletion() throws {
    let catalog = try bundledCatalog()
    let completed = try achievementDTO(
        id: "achievement.first-inscription",
        current: 1,
        target: 1,
        completedAt: date(100)
    )
    let partial = try achievementDTO(
        id: "achievement.courier-1",
        current: 2,
        target: 5,
        completedAt: nil
    )
    let snapshot = try ProgressionSnapshotDTO(
        revision: 8,
        capturedAt: date(200),
        availability: .available,
        storeHealth: .loaded,
        catalogID: nil,
        catalogVersion: nil,
        achievements: [partial, completed]
    )

    let reports = try GameCenterMappingPolicy.priorCompletionCandidates(
        from: snapshot,
        catalog: catalog
    )
    #expect(reports.map(\.achievementID.rawValue) == [
        "achievement.courier-1", "achievement.first-inscription",
    ])
    #expect(reports.map(\.percentage) == [40, 100])
    #expect(reports.last?.locallyCompletedAt == date(100))
    #expect(GameCenterAuthorityPolicy.localProgressionIsAuthoritative)
    #expect(!GameCenterAuthorityPolicy.importsCanGrantOwnership)
    #expect(!GameCenterAuthorityPolicy.importsCanRevokeOwnership)
    #expect(GameCenterAuthorityPolicy.reportsAreOneWay)
}

@Test
func initialRevisionCanBeMirroredWithoutInventingLocalAuthority() throws {
    let catalog = try bundledCatalog()
    let initial = try achievementDTO(
        id: "achievement.first-inscription",
        current: 0,
        target: 1,
        completedAt: nil
    )
    let snapshot = try ProgressionSnapshotDTO(
        revision: 0,
        capturedAt: date(1),
        availability: .available,
        storeHealth: .loaded,
        catalogID: nil,
        catalogVersion: nil,
        achievements: [initial]
    )

    let candidates = try GameCenterMappingPolicy.priorCompletionCandidates(
        from: snapshot,
        catalog: catalog
    )
    #expect(candidates.single?.percentage == 0)
    #expect(candidates.single?.localRevision == 0)
    #expect(try GameCenterReportOutbox().enqueue(candidates).pendingEntries.isEmpty)
}

@Test
func outboxCoalescesMonotonicallyAndHandlesRetryDenialAndDuplicateCallbacks() throws {
    let id = achievement("achievement.courier-1")
    let candidate20 = try report(id: id, percentage: 20, revision: 2)
    let candidate60 = try report(id: id, percentage: 60, revision: 4)
    let candidate40 = try report(id: id, percentage: 40, revision: 5)

    let queued = try GameCenterReportOutbox()
        .enqueue(candidate20)
        .enqueue(candidate60)
        .enqueue(candidate40)
    #expect(queued.pendingEntries.single?.candidate.percentage == 60)
    #expect(try queued.nextBatch(connection: .declined, now: date(100)).isEmpty)
    #expect(try queued.nextBatch(connection: .offline, now: date(100)).isEmpty)
    #expect(try queued.nextBatch(connection: .connected, now: date(100)) == [candidate60])

    let inFlight = try queued.markInFlight([id])
    let denied = try inFlight.recordFailure(
        achievementID: id,
        category: .denied,
        now: date(100)
    )
    #expect(denied.pendingEntries.single?.state == .deferred)
    #expect(denied.pendingEntries.single?.deferralReason == .explicitOptInRequired)
    #expect(denied.pendingEntries.single?.nextEligibleAttemptAt == nil)
    #expect(try denied.nextBatch(connection: .connected, now: date(100)).isEmpty)
    let optedBackIn = try denied.resumeDeferred(after: .explicitOptIn)
    #expect(try optedBackIn.nextBatch(connection: .connected, now: date(100)) == [candidate60])

    let retry = try inFlight.recordFailure(
        achievementID: id,
        category: .serviceUnavailable,
        now: date(100)
    )
    #expect(retry.pendingEntries.single?.nextEligibleAttemptAt == date(110))
    #expect(try retry.nextBatch(connection: .connected, now: date(109)).isEmpty)
    #expect(try retry.nextBatch(connection: .connected, now: date(110)) == [candidate60])

    let unknown = try retry.recordSuccess(
        achievementID: achievement("achievement.first-dispatch"),
        reportedPercentage: 100
    )
    #expect(unknown == retry)
    let retryInFlight = try retry.markInFlight([id])
    let success = try retryInFlight.recordSuccess(achievementID: id, reportedPercentage: 60)
    #expect(success.pendingEntries.isEmpty)
    #expect(success.acknowledgements.single?.percentage == 60)
    #expect(try success.recordSuccess(achievementID: id, reportedPercentage: 60) == success)
    #expect(try success.enqueue(candidate40) == success)

    let partialInFlight = try queued.markInFlight([id])
    let partial = try partialInFlight.recordSuccess(
        achievementID: id,
        reportedPercentage: 40
    )
    #expect(partial.acknowledgements.single?.percentage == 40)
    #expect(partial.pendingEntries.single?.candidate.percentage == 60)
    #expect(partial.pendingEntries.single?.state == .pending)

    let offline = try inFlight.recordFailure(
        achievementID: id,
        category: .offline,
        now: date(100)
    )
    #expect(offline.pendingEntries.single?.deferralReason == .connectivityRequired)
    #expect(try offline.nextBatch(connection: .connected, now: date(1_000)).isEmpty)
    let reconnected = try offline.resumeDeferred(after: .connectivityRestored)
    #expect(try reconnected.nextBatch(connection: .connected, now: date(1_000)) == [candidate60])
}

@Test
func accountChangeDropsOnlyRemoteAcknowledgementsAndRequeuesLocalTruth() throws {
    let id = achievement("achievement.first-inscription")
    let completed = try report(id: id, percentage: 100, revision: 9, completedAt: date(50))
    let queued = try GameCenterReportOutbox().enqueue(completed)
    let acknowledged = try queued
        .markInFlight([id])
        .recordSuccess(achievementID: id, reportedPercentage: 100)
    #expect(acknowledged.pendingEntries.isEmpty)
    #expect(acknowledged.acknowledgements.single?.percentage == 100)

    let rebound = try acknowledged.rebindForAccountChange(localCandidates: [completed])
    #expect(rebound.acknowledgements.isEmpty)
    #expect(rebound.pendingEntries.single?.candidate == completed)
}

private func achievementDTO(
    id: String,
    current: UInt64,
    target: UInt64,
    completedAt: Date?
) throws -> ProgressionAchievementDTO {
    try ProgressionAchievementDTO(
        achievementID: achievement(id),
        presentation: ProgressionPresentationDTO(
            displayName: id,
            summary: completedAt == nil ? "Progress" : "Complete",
            fallbackSystemImageName: "star"
        ),
        completedRuleCount: completedAt == nil ? 0 : 1,
        requiredRuleCount: 1,
        progress: ProgressionNumericProgressDTO(current: current, target: target),
        completedAt: completedAt,
        isHidden: false,
        localPointWeight: 5,
        rewards: ProgressionRewardSummaryDTO()
    )
}

private func report(
    id: AchievementID,
    percentage: UInt8,
    revision: UInt64,
    completedAt: Date? = nil
) throws -> GameCenterReportCandidate {
    try GameCenterReportCandidate(
        achievementID: id,
        gameCenterIdentifier: "com.runescribe.\(id.rawValue)",
        percentage: percentage,
        localRevision: revision,
        locallyCompletedAt: completedAt
    )
}

private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
