import Foundation

public enum RuntimeExternalServiceContractError: Error, Equatable, Sendable {
    case invalidRevision
    case invalidTimestamp
    case invalidPendingCount
    case invalidAuthenticationState
}

public enum RuntimeCloudSyncPhaseDTO: String, Codable, CaseIterable, Sendable {
    case disabled
    case localOnly = "local-only"
    case waitingForNetwork = "waiting-for-network"
    case waitingForAccount = "waiting-for-account"
    case queued
    case synchronizing
    case awaitingLocalApply = "awaiting-local-apply"
    case current
    case quarantinedRemote = "quarantined-remote"
    case accountChangeRequiresRebind = "account-change-requires-rebind"
    case persistenceDegraded = "persistence-degraded"
    case retryExhausted = "retry-exhausted"
}

public enum RuntimeCloudAccountStatusDTO: String, Codable, CaseIterable, Sendable {
    case unknown
    case available
    case noAccount = "no-account"
    case restricted
    case temporarilyUnavailable = "temporarily-unavailable"
    case changed
}

public struct RuntimeCloudSyncStatusDTO: Codable, Equatable, Sendable {
    public let phase: RuntimeCloudSyncPhaseDTO
    public let accountStatus: RuntimeCloudAccountStatusDTO
    public let localRevision: UInt64
    public let pendingRevision: UInt64?
    public let lastSuccessfulSyncAt: Date?
    public let quarantineCount: UInt32
    public let localProgressionAvailable: Bool
    public let persistenceIsDurable: Bool

    public init(
        phase: RuntimeCloudSyncPhaseDTO,
        accountStatus: RuntimeCloudAccountStatusDTO,
        localRevision: UInt64,
        pendingRevision: UInt64? = nil,
        lastSuccessfulSyncAt: Date? = nil,
        quarantineCount: UInt32 = 0,
        localProgressionAvailable: Bool = true,
        persistenceIsDurable: Bool
    ) throws {
        guard pendingRevision.map({ $0 > 0 }) ?? true else {
            throw RuntimeExternalServiceContractError.invalidRevision
        }
        guard lastSuccessfulSyncAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw RuntimeExternalServiceContractError.invalidTimestamp
        }
        self.phase = phase
        self.accountStatus = accountStatus
        self.localRevision = localRevision
        self.pendingRevision = pendingRevision
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.quarantineCount = quarantineCount
        self.localProgressionAvailable = localProgressionAvailable
        self.persistenceIsDurable = persistenceIsDurable
    }
}

public enum RuntimeGameCenterConnectionDTO: String, Codable, CaseIterable, Sendable {
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

public enum RuntimeGameCenterReportStatusDTO: String, Codable, CaseIterable, Sendable {
    case localOnly = "local-only"
    case pending
    case reporting
    case mirrored
    case deferred
    case retryExhausted = "retry-exhausted"
}

public struct RuntimeGameCenterStatusDTO: Codable, Equatable, Sendable {
    public let connection: RuntimeGameCenterConnectionDTO
    public let reportStatus: RuntimeGameCenterReportStatusDTO
    public let pendingReportCount: UInt16
    public let localProgressionAvailable: Bool
    public let isOptedIn: Bool
    public let authenticationWasUserInitiated: Bool
    public let persistenceIsDurable: Bool

    public init(
        connection: RuntimeGameCenterConnectionDTO,
        reportStatus: RuntimeGameCenterReportStatusDTO,
        pendingReportCount: UInt16,
        localProgressionAvailable: Bool = true,
        isOptedIn: Bool,
        authenticationWasUserInitiated: Bool,
        persistenceIsDurable: Bool
    ) throws {
        guard Int(pendingReportCount) <= 100 else {
            throw RuntimeExternalServiceContractError.invalidPendingCount
        }
        guard connection != .authenticating || authenticationWasUserInitiated else {
            throw RuntimeExternalServiceContractError.invalidAuthenticationState
        }
        self.connection = connection
        self.reportStatus = reportStatus
        self.pendingReportCount = pendingReportCount
        self.localProgressionAvailable = localProgressionAvailable
        self.isOptedIn = isOptedIn
        self.authenticationWasUserInitiated = authenticationWasUserInitiated
        self.persistenceIsDurable = persistenceIsDurable
    }
}

public struct RuntimeCloudGameCenterStatusSnapshotDTO: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let capturedAt: Date
    public let cloudSync: RuntimeCloudSyncStatusDTO
    public let gameCenter: RuntimeGameCenterStatusDTO

    public init(
        revision: UInt64,
        capturedAt: Date,
        cloudSync: RuntimeCloudSyncStatusDTO,
        gameCenter: RuntimeGameCenterStatusDTO
    ) throws {
        guard capturedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RuntimeExternalServiceContractError.invalidTimestamp
        }
        self.revision = revision
        self.capturedAt = capturedAt
        self.cloudSync = cloudSync
        self.gameCenter = gameCenter
    }
}

public enum RuntimeGameCenterParticipationIntentDTO: String, Codable, CaseIterable,
    Sendable
{
    /// Grants continuing consent for Runtime to authenticate now and once after a
    /// later activation. A presentation-unavailable attempt may be retried once
    /// after the application becomes active.
    case optIn = "opt-in"
    /// Stops Rune Scribe mirroring without signing out of the Apple account or
    /// deleting local Progression or queued reports.
    case optOut = "opt-out"
}
