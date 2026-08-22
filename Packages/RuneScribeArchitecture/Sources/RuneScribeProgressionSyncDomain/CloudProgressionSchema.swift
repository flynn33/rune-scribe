import Foundation
import RuneScribeContracts

public enum CloudProgressionSchemaError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(UInt16)
    case invalidCatalogVersion
    case invalidLogicalClock
    case resetIsNotSupported
    case invalidIdentifier(String)
    case invalidTimestamp
    case invalidDateRange
    case invalidProgress
    case invalidCounter
    case duplicateRecord(String)
    case collectionLimitExceeded(String)
    case invalidQuarantineDiagnostic
}

public struct CloudOpaqueIdentifier: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid opaque identifier.")
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "<redacted>" }
}

public struct CloudProgressionContentID: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty, bytes.count <= 96 else { return nil }
        var previousWasSeparator = false
        for (index, byte) in bytes.enumerated() {
            let isAlphanumeric = (48 ... 57).contains(byte) || (97 ... 122).contains(byte)
            let isSeparator = byte == 45 || byte == 46
            guard isAlphanumeric || isSeparator else { return nil }
            if isSeparator {
                guard index > 0, index < bytes.count - 1, !previousWasSeparator else {
                    return nil
                }
            }
            previousWasSeparator = isSeparator
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid content identifier.")
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { rawValue }
}

public struct CloudAchievementCompletion: Codable, Equatable, Hashable, Sendable {
    public let achievementID: AchievementID
    public let firstCompletedAt: Date

    public init(achievementID: AchievementID, firstCompletedAt: Date) throws {
        try cloudValidateFinite(firstCompletedAt)
        self.achievementID = achievementID
        self.firstCompletedAt = firstCompletedAt
    }
}

public struct CloudMilestoneCompletion: Codable, Equatable, Hashable, Sendable {
    public let ruleID: RuleID
    public let firstCompletedAt: Date

    public init(ruleID: RuleID, firstCompletedAt: Date) throws {
        try cloudValidateFinite(firstCompletedAt)
        self.ruleID = ruleID
        self.firstCompletedAt = firstCompletedAt
    }
}

public struct CloudGrant: Codable, Equatable, Hashable, Sendable {
    public let grantID: GrantTransactionID
    public let contentID: CloudProgressionContentID
    public let firstGrantedAt: Date
    public let provenanceReference: CloudOpaqueIdentifier?

    public init(
        grantID: GrantTransactionID,
        contentID: CloudProgressionContentID,
        firstGrantedAt: Date,
        provenanceReference: CloudOpaqueIdentifier? = nil
    ) throws {
        try cloudValidateFinite(firstGrantedAt)
        self.grantID = grantID
        self.contentID = contentID
        self.firstGrantedAt = firstGrantedAt
        self.provenanceReference = provenanceReference
    }
}

public struct CloudEncounter: Codable, Equatable, Hashable, Sendable {
    public let encounterID: CloudOpaqueIdentifier
    public let codexID: CodexID
    public let artifactIDs: [ArtifactID]
    public let firstEncounteredAt: Date
    public let lastEncounteredAt: Date
    public let encounterCount: UInt64
    public let provenanceReference: CloudOpaqueIdentifier?

    public init(
        encounterID: CloudOpaqueIdentifier,
        codexID: CodexID,
        artifactIDs: [ArtifactID] = [],
        firstEncounteredAt: Date,
        lastEncounteredAt: Date,
        encounterCount: UInt64,
        provenanceReference: CloudOpaqueIdentifier? = nil
    ) throws {
        try cloudValidateFinite(firstEncounteredAt)
        try cloudValidateFinite(lastEncounteredAt)
        guard firstEncounteredAt <= lastEncounteredAt else {
            throw CloudProgressionSchemaError.invalidDateRange
        }
        guard encounterCount > 0 else { throw CloudProgressionSchemaError.invalidCounter }
        guard artifactIDs.count <= CloudProgressionReplica.maximumRecordsPerCollection else {
            throw CloudProgressionSchemaError.collectionLimitExceeded("encounter-artifacts")
        }
        guard Set(artifactIDs).count == artifactIDs.count else {
            throw CloudProgressionSchemaError.duplicateRecord("encounter-artifact")
        }
        self.encounterID = encounterID
        self.codexID = codexID
        self.artifactIDs = artifactIDs.sorted()
        self.firstEncounteredAt = firstEncounteredAt
        self.lastEncounteredAt = lastEncounteredAt
        self.encounterCount = encounterCount
        self.provenanceReference = provenanceReference
    }
}

public struct CloudDeviceCounterShard: Codable, Equatable, Hashable, Sendable {
    public let statisticID: StatisticID
    public let codexID: CodexID?
    public let deviceID: CloudOpaqueIdentifier
    public let value: UInt64
    public let lastUpdatedAt: Date

    public init(
        statisticID: StatisticID,
        codexID: CodexID? = nil,
        deviceID: CloudOpaqueIdentifier,
        value: UInt64,
        lastUpdatedAt: Date
    ) throws {
        try cloudValidateFinite(lastUpdatedAt)
        self.statisticID = statisticID
        self.codexID = codexID
        self.deviceID = deviceID
        self.value = value
        self.lastUpdatedAt = lastUpdatedAt
    }

    public var mergeKey: String {
        "\(statisticID.rawValue)|\(codexID?.rawValue ?? "")|\(deviceID.rawValue)"
    }
}

public struct CloudDistinctStatisticToken: Codable, Equatable, Hashable, Sendable {
    public let statisticID: StatisticID
    public let codexID: CodexID?
    public let token: CloudOpaqueIdentifier
    public let firstObservedAt: Date

    public init(
        statisticID: StatisticID,
        codexID: CodexID? = nil,
        token: CloudOpaqueIdentifier,
        firstObservedAt: Date
    ) throws {
        try cloudValidateFinite(firstObservedAt)
        self.statisticID = statisticID
        self.codexID = codexID
        self.token = token
        self.firstObservedAt = firstObservedAt
    }

    public var mergeKey: String {
        "\(statisticID.rawValue)|\(codexID?.rawValue ?? "")|\(token.rawValue)"
    }
}

public struct CloudAchievementProgress: Codable, Equatable, Hashable, Sendable {
    public let achievementID: AchievementID
    public let current: UInt64
    public let target: UInt64
    public let lastUpdatedAt: Date

    public init(
        achievementID: AchievementID,
        current: UInt64,
        target: UInt64,
        lastUpdatedAt: Date
    ) throws {
        try cloudValidateFinite(lastUpdatedAt)
        guard target > 0, current <= target else {
            throw CloudProgressionSchemaError.invalidProgress
        }
        self.achievementID = achievementID
        self.current = current
        self.target = target
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public struct CloudCodexSelection: Codable, Equatable, Hashable, Sendable {
    public let codexID: CodexID
    public let logicalTimestamp: UInt64
    public let writerDeviceID: CloudOpaqueIdentifier
    public let updatedAt: Date

    public init(
        codexID: CodexID,
        logicalTimestamp: UInt64,
        writerDeviceID: CloudOpaqueIdentifier,
        updatedAt: Date
    ) throws {
        guard logicalTimestamp > 0, logicalTimestamp < UInt64.max else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        try cloudValidateFinite(updatedAt)
        self.codexID = codexID
        self.logicalTimestamp = logicalTimestamp
        self.writerDeviceID = writerDeviceID
        self.updatedAt = updatedAt
    }

    var deterministicOrder: (UInt64, String, String) {
        (logicalTimestamp, writerDeviceID.rawValue, codexID.rawValue)
    }
}

public struct CloudTitleSelection: Codable, Equatable, Hashable, Sendable {
    public let titleID: TitleID?
    public let logicalTimestamp: UInt64
    public let writerDeviceID: CloudOpaqueIdentifier
    public let updatedAt: Date

    public init(
        titleID: TitleID?,
        logicalTimestamp: UInt64,
        writerDeviceID: CloudOpaqueIdentifier,
        updatedAt: Date
    ) throws {
        guard logicalTimestamp > 0, logicalTimestamp < UInt64.max else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        try cloudValidateFinite(updatedAt)
        self.titleID = titleID
        self.logicalTimestamp = logicalTimestamp
        self.writerDeviceID = writerDeviceID
        self.updatedAt = updatedAt
    }

    var deterministicOrder: (UInt64, String, String) {
        (logicalTimestamp, writerDeviceID.rawValue, titleID?.rawValue ?? "")
    }
}

public struct CloudPendingGameCenterReport: Codable, Equatable, Hashable, Sendable {
    public let achievementID: AchievementID
    public let percentage: UInt8
    public let firstQueuedAt: Date
    public let lastUpdatedAt: Date

    public init(
        achievementID: AchievementID,
        percentage: UInt8,
        firstQueuedAt: Date,
        lastUpdatedAt: Date
    ) throws {
        guard percentage <= 100 else { throw CloudProgressionSchemaError.invalidProgress }
        try cloudValidateFinite(firstQueuedAt)
        try cloudValidateFinite(lastUpdatedAt)
        guard firstQueuedAt <= lastUpdatedAt else {
            throw CloudProgressionSchemaError.invalidDateRange
        }
        self.achievementID = achievementID
        self.percentage = percentage
        self.firstQueuedAt = firstQueuedAt
        self.lastUpdatedAt = lastUpdatedAt
    }
}

public enum CloudQuarantineCategory: String, Codable, CaseIterable, Sendable {
    case invalidRemoteSchema = "invalid-remote-schema"
    case invalidRemoteRecord = "invalid-remote-record"
    case prohibitedField = "prohibited-field"
    case accountScopeMismatch = "account-scope-mismatch"
}

public struct CloudQuarantineDiagnostic: Codable, Equatable, Hashable, Sendable {
    public let recordDigest: CloudOpaqueIdentifier
    public let category: CloudQuarantineCategory
    public let quarantinedAt: Date

    public init(
        recordDigest: CloudOpaqueIdentifier,
        category: CloudQuarantineCategory,
        quarantinedAt: Date
    ) throws {
        try cloudValidateFinite(quarantinedAt)
        self.recordDigest = recordDigest
        self.category = category
        self.quarantinedAt = quarantinedAt
    }
}

public struct CloudProgressionReplica: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maximumRecordsPerCollection = 512
    public static let maximumDistinctStatisticTokenRecords = 4_096
    public static let maximumTotalRecords = 8_192

    public let schemaVersion: UInt16
    public let catalogVersion: UInt64
    public let logicalClock: UInt64
    public let resetGeneration: UInt64
    public let achievementCompletions: [CloudAchievementCompletion]
    public let milestoneCompletions: [CloudMilestoneCompletion]
    public let grants: [CloudGrant]
    public let ownedContentIDs: [CloudProgressionContentID]
    public let unlockIDs: [UnlockID]
    public let titleIDs: [TitleID]
    public let encounters: [CloudEncounter]
    public let deviceCounterShards: [CloudDeviceCounterShard]
    public let distinctStatisticTokens: [CloudDistinctStatisticToken]
    public let achievementProgress: [CloudAchievementProgress]
    public let selectedCodex: CloudCodexSelection?
    public let selectedTitle: CloudTitleSelection?
    public let pendingGameCenterReports: [CloudPendingGameCenterReport]
    public let provenanceReferences: [CloudOpaqueIdentifier]
    public let quarantineDiagnostics: [CloudQuarantineDiagnostic]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        catalogVersion: UInt64,
        logicalClock: UInt64,
        resetGeneration: UInt64 = 0,
        achievementCompletions: [CloudAchievementCompletion] = [],
        milestoneCompletions: [CloudMilestoneCompletion] = [],
        grants: [CloudGrant] = [],
        ownedContentIDs: [CloudProgressionContentID] = [],
        unlockIDs: [UnlockID] = [],
        titleIDs: [TitleID] = [],
        encounters: [CloudEncounter] = [],
        deviceCounterShards: [CloudDeviceCounterShard] = [],
        distinctStatisticTokens: [CloudDistinctStatisticToken] = [],
        achievementProgress: [CloudAchievementProgress] = [],
        selectedCodex: CloudCodexSelection? = nil,
        selectedTitle: CloudTitleSelection? = nil,
        pendingGameCenterReports: [CloudPendingGameCenterReport] = [],
        provenanceReferences: [CloudOpaqueIdentifier] = [],
        quarantineDiagnostics: [CloudQuarantineDiagnostic] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.logicalClock = logicalClock
        self.resetGeneration = resetGeneration
        self.achievementCompletions = achievementCompletions.sorted {
            $0.achievementID < $1.achievementID
        }
        self.milestoneCompletions = milestoneCompletions.sorted { $0.ruleID < $1.ruleID }
        self.grants = grants.sorted {
            ($0.grantID.rawValue, $0.contentID.rawValue)
                < ($1.grantID.rawValue, $1.contentID.rawValue)
        }
        self.ownedContentIDs = ownedContentIDs.sorted()
        self.unlockIDs = unlockIDs.sorted()
        self.titleIDs = titleIDs.sorted()
        self.encounters = encounters.sorted { $0.encounterID < $1.encounterID }
        self.deviceCounterShards = deviceCounterShards.sorted { $0.mergeKey < $1.mergeKey }
        self.distinctStatisticTokens = distinctStatisticTokens.sorted {
            $0.mergeKey < $1.mergeKey
        }
        self.achievementProgress = achievementProgress.sorted {
            $0.achievementID < $1.achievementID
        }
        self.selectedCodex = selectedCodex
        self.selectedTitle = selectedTitle
        self.pendingGameCenterReports = pendingGameCenterReports.sorted {
            $0.achievementID < $1.achievementID
        }
        self.provenanceReferences = provenanceReferences.sorted()
        self.quarantineDiagnostics = quarantineDiagnostics.sorted {
            ($0.quarantinedAt, $0.recordDigest.rawValue)
                < ($1.quarantinedAt, $1.recordDigest.rawValue)
        }
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CloudProgressionSchemaError.unsupportedSchemaVersion(schemaVersion)
        }
        guard catalogVersion > 0 else {
            throw CloudProgressionSchemaError.invalidCatalogVersion
        }
        guard logicalClock > 0, logicalClock < UInt64.max else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        guard resetGeneration == 0 else {
            throw CloudProgressionSchemaError.resetIsNotSupported
        }

        let collections: [(String, Int)] = [
            ("achievement-completions", achievementCompletions.count),
            ("milestone-completions", milestoneCompletions.count),
            ("grants", grants.count),
            ("owned-content", ownedContentIDs.count),
            ("unlocks", unlockIDs.count),
            ("titles", titleIDs.count),
            ("encounters", encounters.count),
            ("device-counter-shards", deviceCounterShards.count),
            ("achievement-progress", achievementProgress.count),
            ("pending-game-center-reports", pendingGameCenterReports.count),
            ("provenance-references", provenanceReferences.count),
            ("quarantine-diagnostics", quarantineDiagnostics.count),
        ]
        for (name, count) in collections where count > Self.maximumRecordsPerCollection {
            throw CloudProgressionSchemaError.collectionLimitExceeded(name)
        }
        guard distinctStatisticTokens.count <= Self.maximumDistinctStatisticTokenRecords else {
            throw CloudProgressionSchemaError.collectionLimitExceeded(
                "distinct-statistic-tokens"
            )
        }
        let totalRecordCount = collections.reduce(0, { $0 + $1.1 })
            + distinctStatisticTokens.count
        guard totalRecordCount <= Self.maximumTotalRecords else {
            throw CloudProgressionSchemaError.collectionLimitExceeded("replica")
        }

        try cloudValidateUnique(achievementCompletions.map(\.achievementID), "achievement")
        try cloudValidateUnique(milestoneCompletions.map(\.ruleID), "milestone")
        try cloudValidateUnique(grants.map {
            CloudGrantIdentity(grantID: $0.grantID, contentID: $0.contentID)
        }, "grant")
        try cloudValidateUnique(ownedContentIDs, "owned-content")
        try cloudValidateUnique(unlockIDs, "unlock")
        try cloudValidateUnique(titleIDs, "title")
        try cloudValidateUnique(encounters.map(\.encounterID), "encounter")
        try cloudValidateUnique(deviceCounterShards.map(\.mergeKey), "device-counter-shard")
        try cloudValidateUnique(
            distinctStatisticTokens.map(\.mergeKey),
            "distinct-statistic-token"
        )
        try cloudValidateUnique(achievementProgress.map(\.achievementID), "achievement-progress")
        try cloudValidateUnique(
            pendingGameCenterReports.map(\.achievementID),
            "pending-game-center-report"
        )
        try cloudValidateUnique(provenanceReferences, "provenance-reference")
        try cloudValidateUnique(
            quarantineDiagnostics.map(\.recordDigest),
            "quarantine-diagnostic"
        )

        for completion in achievementCompletions { try cloudValidateFinite(completion.firstCompletedAt) }
        for completion in milestoneCompletions { try cloudValidateFinite(completion.firstCompletedAt) }
        for grant in grants { try cloudValidateFinite(grant.firstGrantedAt) }
        for encounter in encounters {
            try cloudValidateFinite(encounter.firstEncounteredAt)
            try cloudValidateFinite(encounter.lastEncounteredAt)
            guard encounter.artifactIDs.count <= Self.maximumRecordsPerCollection else {
                throw CloudProgressionSchemaError.collectionLimitExceeded(
                    "encounter-artifacts"
                )
            }
            guard encounter.firstEncounteredAt <= encounter.lastEncounteredAt,
                  encounter.encounterCount > 0,
                  Set(encounter.artifactIDs).count == encounter.artifactIDs.count
            else { throw CloudProgressionSchemaError.invalidDateRange }
        }
        for shard in deviceCounterShards { try cloudValidateFinite(shard.lastUpdatedAt) }
        var counterTotals: [String: UInt64] = [:]
        for shard in deviceCounterShards {
            let key = "\(shard.statisticID.rawValue)|\(shard.codexID?.rawValue ?? "")"
            let (total, overflow) = (counterTotals[key] ?? 0)
                .addingReportingOverflow(shard.value)
            guard !overflow else { throw CloudProgressionSchemaError.invalidCounter }
            counterTotals[key] = total
        }
        for token in distinctStatisticTokens { try cloudValidateFinite(token.firstObservedAt) }
        for progress in achievementProgress {
            try cloudValidateFinite(progress.lastUpdatedAt)
            guard progress.target > 0, progress.current <= progress.target else {
                throw CloudProgressionSchemaError.invalidProgress
            }
        }
        if let selectedCodex {
            try cloudValidateFinite(selectedCodex.updatedAt)
            guard selectedCodex.logicalTimestamp > 0,
                  selectedCodex.logicalTimestamp < UInt64.max
            else {
                throw CloudProgressionSchemaError.invalidLogicalClock
            }
        }
        if let selectedTitle {
            try cloudValidateFinite(selectedTitle.updatedAt)
            guard selectedTitle.logicalTimestamp > 0,
                  selectedTitle.logicalTimestamp < UInt64.max
            else {
                throw CloudProgressionSchemaError.invalidLogicalClock
            }
        }
        for report in pendingGameCenterReports {
            try cloudValidateFinite(report.firstQueuedAt)
            try cloudValidateFinite(report.lastUpdatedAt)
            guard report.percentage <= 100,
                  report.firstQueuedAt <= report.lastUpdatedAt
            else { throw CloudProgressionSchemaError.invalidProgress }
        }
        for diagnostic in quarantineDiagnostics {
            try cloudValidateFinite(diagnostic.quarantinedAt)
        }
    }
}

struct CloudGrantIdentity: Hashable {
    let grantID: GrantTransactionID
    let contentID: CloudProgressionContentID
}

func cloudValidateFinite(_ date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw CloudProgressionSchemaError.invalidTimestamp
    }
}

func cloudValidateUnique<Value: Hashable>(_ values: [Value], _ kind: String) throws {
    guard Set(values).count == values.count else {
        throw CloudProgressionSchemaError.duplicateRecord(kind)
    }
}
