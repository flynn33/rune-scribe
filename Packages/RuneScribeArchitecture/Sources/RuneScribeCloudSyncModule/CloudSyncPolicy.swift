import Foundation
import RuneScribeProgressionSyncDomain

public enum CloudAccountStatus: String, Codable, CaseIterable, Sendable {
    case unknown
    case available
    case noAccount = "no-account"
    case restricted
    case changed
}

public enum CloudSyncPhase: String, Codable, CaseIterable, Sendable {
    case disabled
    case localOnly = "local-only"
    case waitingForNetwork = "waiting-for-network"
    case queued
    case synchronizing
    case current
    case quarantinedRemote = "quarantined-remote"
    case accountChangeRequiresRebind = "account-change-requires-rebind"
}

public struct CloudSyncStatusSnapshot: Codable, Equatable, Sendable {
    public let phase: CloudSyncPhase
    public let accountStatus: CloudAccountStatus
    public let localRevision: UInt64
    public let pendingRevision: UInt64?
    public let lastSuccessfulSyncAt: Date?
    public let quarantineCount: UInt32
    public let localProgressionAvailable: Bool

    public init(
        phase: CloudSyncPhase,
        accountStatus: CloudAccountStatus,
        localRevision: UInt64,
        pendingRevision: UInt64? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        quarantineCount: UInt32 = 0,
        localProgressionAvailable: Bool = true
    ) throws {
        if let pendingRevision, pendingRevision < localRevision {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        if let lastSuccessfulSyncAt { try cloudPolicyValidateFinite(lastSuccessfulSyncAt) }
        guard localProgressionAvailable else {
            throw CloudProgressionSchemaError.invalidCounter
        }
        self.phase = phase
        self.accountStatus = accountStatus
        self.localRevision = localRevision
        self.pendingRevision = pendingRevision
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.quarantineCount = quarantineCount
        self.localProgressionAvailable = localProgressionAvailable
    }
}

public enum CloudAccountChangeDisposition: String, Codable, CaseIterable, Sendable {
    case unchanged
    case preserveLocalAndAwaitExplicitRebind = "preserve-local-and-await-explicit-rebind"
}

public enum CloudAccountChangePolicy {
    public static func disposition(
        previous: CloudOpaqueIdentifier?,
        current: CloudOpaqueIdentifier?
    ) -> CloudAccountChangeDisposition {
        previous == current ? .unchanged : .preserveLocalAndAwaitExplicitRebind
    }
}

public enum CloudResetPolicy: String, Codable, CaseIterable, Sendable {
    case omittedUntilSynchronizedTombstonesAreAccepted =
        "omitted-until-synchronized-tombstones-are-accepted"

    public static let current = Self.omittedUntilSynchronizedTombstonesAreAccepted
    public static let isResetSupported = false

    public static func validate(resetGeneration: UInt64) throws {
        guard resetGeneration == 0 else {
            throw CloudProgressionSchemaError.resetIsNotSupported
        }
    }
}

public enum CloudSyncFailureCategory: String, Codable, CaseIterable, Sendable {
    case offline
    case serviceUnavailable = "service-unavailable"
    case rateLimited = "rate-limited"
    case accountUnavailable = "account-unavailable"
    case accountChanged = "account-changed"
    case corruptRemote = "corrupt-remote"
    case permanentConfiguration = "permanent-configuration"
}

public enum CloudSyncRetryDisposition: Equatable, Sendable {
    case retry(at: Date)
    case waitForConnectivity
    case waitForAccount
    case quarantineAndContinueLocally
    case doNotRetry
}

public enum CloudSyncRetryPolicy {
    public static let maximumAttemptCount: UInt16 = 16
    public static let maximumDelay: TimeInterval = 6 * 60 * 60

    public static func disposition(
        for failure: CloudSyncFailureCategory,
        failedAttemptCount: UInt16,
        now: Date,
        serverRetryAfter: Date? = nil
    ) throws -> CloudSyncRetryDisposition {
        try cloudPolicyValidateFinite(now)
        if let serverRetryAfter { try cloudPolicyValidateFinite(serverRetryAfter) }
        switch failure {
        case .offline:
            return .waitForConnectivity
        case .accountUnavailable, .accountChanged:
            return .waitForAccount
        case .corruptRemote:
            return .quarantineAndContinueLocally
        case .permanentConfiguration:
            return .doNotRetry
        case .rateLimited:
            if let serverRetryAfter, serverRetryAfter > now {
                return .retry(at: serverRetryAfter)
            }
            fallthrough
        case .serviceUnavailable:
            guard failedAttemptCount < maximumAttemptCount else { return .doNotRetry }
            let exponent = min(Int(failedAttemptCount), 10)
            let delay = min(TimeInterval(1 << exponent) * 5, maximumDelay)
            return .retry(at: now.addingTimeInterval(delay))
        }
    }
}

public struct CloudSyncQueue: Codable, Equatable, Sendable {
    public let pendingRevision: UInt64?
    public let failedAttemptCount: UInt16
    public let nextEligibleAttemptAt: Date?

    public init(
        pendingRevision: UInt64? = nil,
        failedAttemptCount: UInt16 = 0,
        nextEligibleAttemptAt: Date? = nil
    ) throws {
        if let nextEligibleAttemptAt { try cloudPolicyValidateFinite(nextEligibleAttemptAt) }
        guard (pendingRevision.map { $0 > 0 } ?? true),
              pendingRevision != nil || (failedAttemptCount == 0 && nextEligibleAttemptAt == nil),
              failedAttemptCount <= CloudSyncRetryPolicy.maximumAttemptCount
        else { throw CloudProgressionSchemaError.invalidCounter }
        self.pendingRevision = pendingRevision
        self.failedAttemptCount = failedAttemptCount
        self.nextEligibleAttemptAt = nextEligibleAttemptAt
    }

    public func enqueue(localRevision: UInt64) throws -> Self {
        guard localRevision > 0 else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        return try Self(
            pendingRevision: max(pendingRevision ?? 0, localRevision),
            failedAttemptCount: failedAttemptCount,
            nextEligibleAttemptAt: nextEligibleAttemptAt
        )
    }

    public func acknowledge(uploadedRevision: UInt64) throws -> Self {
        guard uploadedRevision > 0 else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        guard let pendingRevision, uploadedRevision >= pendingRevision else { return self }
        return try Self()
    }

    public func recordFailure(
        _ category: CloudSyncFailureCategory,
        now: Date,
        serverRetryAfter: Date? = nil
    ) throws -> Self {
        guard pendingRevision != nil else { return self }
        let consumesRetryAttempt = category == .serviceUnavailable || category == .rateLimited
        let attempt = consumesRetryAttempt
            ? min(failedAttemptCount &+ 1, CloudSyncRetryPolicy.maximumAttemptCount)
            : failedAttemptCount
        let disposition = try CloudSyncRetryPolicy.disposition(
            for: category,
            failedAttemptCount: attempt,
            now: now,
            serverRetryAfter: serverRetryAfter
        )
        let nextAttempt: Date?
        if case let .retry(at) = disposition {
            nextAttempt = at
        } else {
            nextAttempt = nil
        }
        return try Self(
            pendingRevision: pendingRevision,
            failedAttemptCount: attempt,
            nextEligibleAttemptAt: nextAttempt
        )
    }
}

private func cloudPolicyValidateFinite(_ date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw CloudProgressionSchemaError.invalidTimestamp
    }
}
