import Foundation
import RuneScribeContracts

public enum GameCenterReportingError: Error, Equatable, Sendable {
    case unknownAchievement(AchievementID)
    case invalidProgress
    case invalidRevision
    case invalidTimestamp
    case invalidReport
}

public enum GameCenterAuthorityPolicy {
    public static let localProgressionIsAuthoritative = true
    public static let importsCanGrantOwnership = false
    public static let importsCanRevokeOwnership = false
    public static let reportsAreOneWay = true
}

public struct GameCenterLocalAchievementProgress: Codable, Equatable, Sendable {
    public let achievementID: AchievementID
    public let current: UInt64
    public let target: UInt64
    public let completedAt: Date?
    public let localRevision: UInt64

    public init(
        achievementID: AchievementID,
        current: UInt64,
        target: UInt64,
        completedAt: Date?,
        localRevision: UInt64
    ) throws {
        guard target > 0, current <= target else {
            throw GameCenterReportingError.invalidProgress
        }
        if let completedAt {
            guard completedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw GameCenterReportingError.invalidTimestamp
            }
        }
        guard (current == target) == (completedAt != nil) else {
            throw GameCenterReportingError.invalidProgress
        }
        self.achievementID = achievementID
        self.current = current
        self.target = target
        self.completedAt = completedAt
        self.localRevision = localRevision
    }

    public init(_ value: ProgressionAchievementDTO, localRevision: UInt64) throws {
        try self.init(
            achievementID: value.achievementID,
            current: value.progress.current,
            target: value.progress.target,
            completedAt: value.completedAt,
            localRevision: localRevision
        )
    }
}

public struct GameCenterReportCandidate: Codable, Equatable, Sendable {
    public let achievementID: AchievementID
    public let gameCenterIdentifier: String
    public let percentage: UInt8
    public let localRevision: UInt64
    public let locallyCompletedAt: Date?

    public init(
        achievementID: AchievementID,
        gameCenterIdentifier: String,
        percentage: UInt8,
        localRevision: UInt64,
        locallyCompletedAt: Date?
    ) throws {
        guard percentage <= 100,
              GameCenterAchievementDefinition.isValidGameCenterIdentifier(
                  gameCenterIdentifier
              ),
              gameCenterIdentifier == "com.runescribe.\(achievementID.rawValue)",
              (percentage == 100) == (locallyCompletedAt != nil)
        else { throw GameCenterReportingError.invalidReport }
        if let locallyCompletedAt,
           !locallyCompletedAt.timeIntervalSinceReferenceDate.isFinite
        {
            throw GameCenterReportingError.invalidTimestamp
        }
        self.achievementID = achievementID
        self.gameCenterIdentifier = gameCenterIdentifier
        self.percentage = percentage
        self.localRevision = localRevision
        self.locallyCompletedAt = locallyCompletedAt
    }
}

public enum GameCenterPercentagePolicy {
    /// Produces a deterministic whole-number floor without floating-point rounding
    /// or overflowing `current * 100` for large counters.
    public static func percentage(current: UInt64, target: UInt64) throws -> UInt8 {
        guard target > 0, current <= target else {
            throw GameCenterReportingError.invalidProgress
        }
        if current == target { return 100 }
        if current == 0 { return 0 }
        let product = current.multipliedFullWidth(by: 100)
        let quotient = target.dividingFullWidth(product).quotient
        guard quotient < 100 else { throw GameCenterReportingError.invalidProgress }
        return UInt8(quotient)
    }

    public static func monotonicMaximum(_ lhs: UInt8, _ rhs: UInt8) throws -> UInt8 {
        guard lhs <= 100, rhs <= 100 else { throw GameCenterReportingError.invalidProgress }
        return max(lhs, rhs)
    }
}

public enum GameCenterMappingPolicy {
    public static func candidate(
        for progress: GameCenterLocalAchievementProgress,
        catalog: GameCenterAchievementCatalog
    ) throws -> GameCenterReportCandidate {
        guard let definition = catalog.definition(for: progress.achievementID) else {
            throw GameCenterReportingError.unknownAchievement(progress.achievementID)
        }
        guard definition.progressTarget == progress.target else {
            throw GameCenterReportingError.invalidProgress
        }
        let percentage = try GameCenterPercentagePolicy.percentage(
            current: progress.current,
            target: progress.target
        )
        return try GameCenterReportCandidate(
            achievementID: progress.achievementID,
            gameCenterIdentifier: definition.gameCenterIdentifier,
            percentage: percentage,
            localRevision: progress.localRevision,
            locallyCompletedAt: progress.completedAt
        )
    }

    /// Reconciles every local Achievement after later opt-in. This is intentionally
    /// one-way and emits no ownership, unlock, or grant command.
    public static func priorCompletionCandidates(
        from snapshot: ProgressionSnapshotDTO,
        catalog: GameCenterAchievementCatalog
    ) throws -> [GameCenterReportCandidate] {
        try snapshot.achievements.map {
            try candidate(
                for: GameCenterLocalAchievementProgress($0, localRevision: snapshot.revision),
                catalog: catalog
            )
        }.sorted { $0.achievementID < $1.achievementID }
    }
}

public enum GameCenterConnectionState: String, Codable, CaseIterable, Sendable {
    case disabled
    case authenticationAvailable = "authentication-available"
    case authenticating
    case connected
    case declined
    case cancelled
    case restricted
    case offline
    case unavailable
}

public enum GameCenterReportStatus: String, Codable, CaseIterable, Sendable {
    case localOnly = "local-only"
    case pending
    case reporting
    case mirrored
    case deferred
}

public struct GameCenterStatusSnapshot: Codable, Equatable, Sendable {
    public let connection: GameCenterConnectionState
    public let reportStatus: GameCenterReportStatus
    public let pendingReportCount: UInt16
    public let localProgressionAvailable: Bool
    public let authenticationWasUserInitiated: Bool

    public init(
        connection: GameCenterConnectionState,
        reportStatus: GameCenterReportStatus,
        pendingReportCount: UInt16,
        localProgressionAvailable: Bool = true,
        authenticationWasUserInitiated: Bool
    ) throws {
        guard localProgressionAvailable else {
            throw GameCenterReportingError.invalidReport
        }
        guard connection != .authenticating || authenticationWasUserInitiated else {
            throw GameCenterReportingError.invalidReport
        }
        self.connection = connection
        self.reportStatus = reportStatus
        self.pendingReportCount = pendingReportCount
        self.localProgressionAvailable = localProgressionAvailable
        self.authenticationWasUserInitiated = authenticationWasUserInitiated
    }
}
