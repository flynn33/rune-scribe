import Foundation
import RuneScribeContracts

public enum GameCenterOutboxEntryState: String, Codable, CaseIterable, Sendable {
    case pending
    case inFlight = "in-flight"
    case deferred
}

public enum GameCenterOutboxDeferralReason: String, Codable, CaseIterable, Sendable {
    case scheduledRetry = "scheduled-retry"
    case connectivityRequired = "connectivity-required"
    case authenticationRequired = "authentication-required"
    case explicitOptInRequired = "explicit-opt-in-required"
    case accountRebindRequired = "account-rebind-required"
    case permanentConfiguration = "permanent-configuration"
    case retryExhausted = "retry-exhausted"
}

public enum GameCenterOutboxResumeTrigger: String, Codable, CaseIterable, Sendable {
    case connectivityRestored = "connectivity-restored"
    case authenticated
    case explicitOptIn = "explicit-opt-in"
    case accountRebound = "account-rebound"
    case configurationChanged = "configuration-changed"
    case retryProbe = "retry-probe"
}

public struct GameCenterAcknowledgement: Codable, Equatable, Sendable {
    public let achievementID: AchievementID
    public let percentage: UInt8

    public init(achievementID: AchievementID, percentage: UInt8) throws {
        guard percentage <= 100 else { throw GameCenterReportingError.invalidProgress }
        self.achievementID = achievementID
        self.percentage = percentage
    }
}

public struct GameCenterOutboxEntry: Codable, Equatable, Sendable {
    public let candidate: GameCenterReportCandidate
    public let state: GameCenterOutboxEntryState
    public let failedAttemptCount: UInt16
    public let deferralReason: GameCenterOutboxDeferralReason?
    public let nextEligibleAttemptAt: Date?

    public init(
        candidate: GameCenterReportCandidate,
        state: GameCenterOutboxEntryState = .pending,
        failedAttemptCount: UInt16 = 0,
        deferralReason: GameCenterOutboxDeferralReason? = nil,
        nextEligibleAttemptAt: Date? = nil
    ) throws {
        guard candidate.percentage > 0,
              failedAttemptCount <= GameCenterRetryPolicy.maximumAttemptCount
        else { throw GameCenterReportingError.invalidReport }
        if let nextEligibleAttemptAt,
           !nextEligibleAttemptAt.timeIntervalSinceReferenceDate.isFinite
        {
            throw GameCenterReportingError.invalidTimestamp
        }
        switch state {
        case .pending, .inFlight:
            guard deferralReason == nil, nextEligibleAttemptAt == nil else {
                throw GameCenterReportingError.invalidReport
            }
        case .deferred:
            guard let deferralReason else {
                throw GameCenterReportingError.invalidReport
            }
            if deferralReason == .scheduledRetry {
                guard nextEligibleAttemptAt != nil else {
                    throw GameCenterReportingError.invalidReport
                }
            } else {
                guard nextEligibleAttemptAt == nil else {
                    throw GameCenterReportingError.invalidReport
                }
            }
        }
        self.candidate = candidate
        self.state = state
        self.failedAttemptCount = failedAttemptCount
        self.deferralReason = deferralReason
        self.nextEligibleAttemptAt = nextEligibleAttemptAt
    }
}

public enum GameCenterFailureCategory: String, Codable, CaseIterable, Sendable {
    case offline
    case serviceUnavailable = "service-unavailable"
    case rateLimited = "rate-limited"
    case notAuthenticated = "not-authenticated"
    case denied
    case restricted
    case cancelled
    case accountChanged = "account-changed"
    case permanentConfiguration = "permanent-configuration"
}

public enum GameCenterRetryDisposition: Equatable, Sendable {
    case retry(at: Date)
    case waitForConnectivity
    case waitForAuthentication
    case preserveUntilExplicitOptIn
    case rebindAccount
    case doNotRetry
    case retryExhausted
}

public enum GameCenterRetryPolicy {
    public static let maximumAttemptCount: UInt16 = 16
    public static let maximumDelay: TimeInterval = 6 * 60 * 60

    public static func disposition(
        for failure: GameCenterFailureCategory,
        failedAttemptCount: UInt16,
        now: Date,
        serverRetryAfter: Date? = nil
    ) throws -> GameCenterRetryDisposition {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              serverRetryAfter?.timeIntervalSinceReferenceDate.isFinite ?? true
        else { throw GameCenterReportingError.invalidTimestamp }
        switch failure {
        case .offline:
            return .waitForConnectivity
        case .notAuthenticated:
            return .waitForAuthentication
        case .denied, .restricted, .cancelled:
            return .preserveUntilExplicitOptIn
        case .accountChanged:
            return .rebindAccount
        case .permanentConfiguration:
            return .doNotRetry
        case .rateLimited:
            if let serverRetryAfter, serverRetryAfter > now {
                return .retry(at: serverRetryAfter)
            }
            fallthrough
        case .serviceUnavailable:
            guard failedAttemptCount < maximumAttemptCount else {
                return .retryExhausted
            }
            let exponent = min(Int(failedAttemptCount), 10)
            let delay = min(TimeInterval(1 << exponent) * 5, maximumDelay)
            return .retry(at: now.addingTimeInterval(delay))
        }
    }
}

public struct GameCenterReportOutbox: Codable, Equatable, Sendable {
    public static let maximumEntryCount = 100

    public let acknowledgements: [GameCenterAcknowledgement]
    public let pendingEntries: [GameCenterOutboxEntry]

    public init(
        acknowledgements: [GameCenterAcknowledgement] = [],
        pendingEntries: [GameCenterOutboxEntry] = []
    ) throws {
        guard acknowledgements.count <= Self.maximumEntryCount,
              pendingEntries.count <= Self.maximumEntryCount,
              Set(acknowledgements.map(\.achievementID)).count == acknowledgements.count,
              Set(pendingEntries.map(\.candidate.achievementID)).count == pendingEntries.count
        else { throw GameCenterReportingError.invalidReport }
        let acknowledgementByID = Dictionary(
            uniqueKeysWithValues: acknowledgements.map { ($0.achievementID, $0.percentage) }
        )
        guard pendingEntries.allSatisfy({ entry in
            entry.candidate.percentage > (acknowledgementByID[entry.candidate.achievementID] ?? 0)
        }) else { throw GameCenterReportingError.invalidReport }
        self.acknowledgements = acknowledgements.sorted { $0.achievementID < $1.achievementID }
        self.pendingEntries = pendingEntries.sorted {
            $0.candidate.achievementID < $1.candidate.achievementID
        }
    }

    public func enqueue(_ candidate: GameCenterReportCandidate) throws -> Self {
        guard candidate.percentage > 0 else { return self }
        let acknowledged = acknowledgements.first {
            $0.achievementID == candidate.achievementID
        }?.percentage ?? 0
        guard candidate.percentage > acknowledged else { return self }

        var entries = pendingEntries
        if let index = entries.firstIndex(where: {
            $0.candidate.achievementID == candidate.achievementID
        }) {
            let existing = entries[index]
            guard candidate.percentage > existing.candidate.percentage
                || (candidate.percentage == existing.candidate.percentage
                    && candidate.localRevision > existing.candidate.localRevision)
            else { return self }
            entries[index] = try GameCenterOutboxEntry(
                candidate: candidate,
                state: existing.state,
                failedAttemptCount: existing.failedAttemptCount,
                deferralReason: existing.deferralReason,
                nextEligibleAttemptAt: existing.nextEligibleAttemptAt
            )
        } else {
            entries.append(try GameCenterOutboxEntry(candidate: candidate))
        }
        return try Self(acknowledgements: acknowledgements, pendingEntries: entries)
    }

    public func enqueue(_ candidates: [GameCenterReportCandidate]) throws -> Self {
        try candidates.reduce(self) { try $0.enqueue($1) }
    }

    public func nextBatch(
        connection: GameCenterConnectionState,
        now: Date,
        maximumCount: Int = 15
    ) throws -> [GameCenterReportCandidate] {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              maximumCount > 0,
              maximumCount <= Self.maximumEntryCount,
              connection == .connected
        else { return [] }
        return pendingEntries
            .filter { entry in
                entry.state == .pending
                    || (entry.deferralReason == .scheduledRetry
                        && entry.nextEligibleAttemptAt.map { $0 <= now } == true)
            }
            .prefix(maximumCount)
            .map(\.candidate)
    }

    /// Restores reports whose process-local callback owner was lost. Recovery does
    /// not consume another attempt because no report failure was observed.
    public func recoverInterruptedReports() throws -> Self {
        let entries = try pendingEntries.map { entry in
            guard entry.state == .inFlight else { return entry }
            return try GameCenterOutboxEntry(
                candidate: entry.candidate,
                failedAttemptCount: entry.failedAttemptCount
            )
        }
        return try Self(acknowledgements: acknowledgements, pendingEntries: entries)
    }

    public func markInFlight(_ achievementIDs: Set<AchievementID>) throws -> Self {
        let entries = try pendingEntries.map { entry in
            guard achievementIDs.contains(entry.candidate.achievementID) else { return entry }
            guard entry.state == .pending || entry.deferralReason == .scheduledRetry else {
                return entry
            }
            return try GameCenterOutboxEntry(
                candidate: entry.candidate,
                state: .inFlight,
                failedAttemptCount: entry.failedAttemptCount
            )
        }
        return try Self(acknowledgements: acknowledgements, pendingEntries: entries)
    }

    /// Accepts callbacks only for a report currently in this outbox. Unknown callbacks
    /// are ignored so Game Center state can never become an ownership or completion input.
    public func recordSuccess(
        achievementID: AchievementID,
        reportedPercentage: UInt8
    ) throws -> Self {
        guard reportedPercentage <= 100 else {
            throw GameCenterReportingError.invalidProgress
        }
        guard let pending = pendingEntries.first(where: {
            $0.candidate.achievementID == achievementID
                && $0.state == .inFlight
        }), reportedPercentage <= pending.candidate.percentage
        else { return self }

        var acknowledgedByID = Dictionary(
            uniqueKeysWithValues: acknowledgements.map { ($0.achievementID, $0.percentage) }
        )
        if reportedPercentage > 0 {
            acknowledgedByID[achievementID] = max(
                acknowledgedByID[achievementID] ?? 0,
                reportedPercentage
            )
        }
        var retainedEntries = pendingEntries.filter {
            $0.candidate.achievementID != achievementID
        }
        if pending.candidate.percentage > reportedPercentage {
            retainedEntries.append(
                try GameCenterOutboxEntry(candidate: pending.candidate)
            )
        }
        let acknowledgements = try acknowledgedByID.map {
            try GameCenterAcknowledgement(achievementID: $0.key, percentage: $0.value)
        }
        return try Self(
            acknowledgements: acknowledgements,
            pendingEntries: retainedEntries
        )
    }

    public func recordFailure(
        achievementID: AchievementID,
        category: GameCenterFailureCategory,
        now: Date,
        serverRetryAfter: Date? = nil
    ) throws -> Self {
        guard let index = pendingEntries.firstIndex(where: {
            $0.candidate.achievementID == achievementID
        }) else { return self }
        var entries = pendingEntries
        let current = entries[index]
        guard current.state == .inFlight else { return self }
        let attempts = min(
            current.failedAttemptCount &+ 1,
            GameCenterRetryPolicy.maximumAttemptCount
        )
        let disposition = try GameCenterRetryPolicy.disposition(
            for: category,
            failedAttemptCount: attempts,
            now: now,
            serverRetryAfter: serverRetryAfter
        )
        switch disposition {
        case let .retry(at):
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .scheduledRetry,
                nextEligibleAttemptAt: at
            )
        case .waitForConnectivity:
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .connectivityRequired
            )
        case .waitForAuthentication:
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .authenticationRequired
            )
        case .preserveUntilExplicitOptIn:
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .explicitOptInRequired
            )
        case .rebindAccount:
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .accountRebindRequired
            )
        case .doNotRetry:
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .permanentConfiguration
            )
        case .retryExhausted:
            entries[index] = try GameCenterOutboxEntry(
                candidate: current.candidate,
                state: .deferred,
                failedAttemptCount: attempts,
                deferralReason: .retryExhausted
            )
        }
        return try Self(acknowledgements: acknowledgements, pendingEntries: entries)
    }

    public func resumeDeferred(after trigger: GameCenterOutboxResumeTrigger) throws -> Self {
        let resumableReason: GameCenterOutboxDeferralReason
        switch trigger {
        case .connectivityRestored:
            resumableReason = .connectivityRequired
        case .authenticated:
            resumableReason = .authenticationRequired
        case .explicitOptIn:
            resumableReason = .explicitOptInRequired
        case .accountRebound:
            resumableReason = .accountRebindRequired
        case .configurationChanged:
            resumableReason = .permanentConfiguration
        case .retryProbe:
            resumableReason = .retryExhausted
        }
        let entries = try pendingEntries.map { entry in
            guard entry.deferralReason == resumableReason else { return entry }
            return try GameCenterOutboxEntry(
                candidate: entry.candidate,
                failedAttemptCount: entry.failedAttemptCount
            )
        }
        return try Self(acknowledgements: acknowledgements, pendingEntries: entries)
    }

    /// A new Game Center account has no trusted acknowledgement history. Local
    /// candidates are re-enqueued, while local Progression remains untouched.
    public func rebindForAccountChange(
        localCandidates: [GameCenterReportCandidate]
    ) throws -> Self {
        try Self().enqueue(localCandidates)
    }
}
