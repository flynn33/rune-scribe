import Foundation
import RuneScribeContracts

public enum CloudServiceAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case offline
    case unavailable
    case disabled
}

public enum CloudStatisticMergeRepresentation: String, Codable, CaseIterable, Sendable {
    case deviceCounter = "device-counter"
    case distinctToken = "distinct-token"
    case derivedOmitted = "derived-omitted"
}

public struct CloudStatisticMergeSchema: Equatable, Sendable {
    public let representation: CloudStatisticMergeRepresentation
    public let requiresCodexBucket: Bool

    public init(
        representation: CloudStatisticMergeRepresentation,
        requiresCodexBucket: Bool
    ) {
        self.representation = representation
        self.requiresCodexBucket = requiresCodexBucket
    }
}

public struct CloudProgressionMergeContext: Equatable, Sendable {
    public let localAccountScope: CloudOpaqueIdentifier?
    public let remoteAccountScope: CloudOpaqueIdentifier?
    public let serviceAvailability: CloudServiceAvailability
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
    public let validatesCatalogMembership: Bool
    public let statisticSchemas: [StatisticID: CloudStatisticMergeSchema]
    public let knownCodexIDs: Set<CodexID>
    public let knownTitleIDs: Set<TitleID>
    public let now: Date

    public init(
        localAccountScope: CloudOpaqueIdentifier?,
        remoteAccountScope: CloudOpaqueIdentifier?,
        serviceAvailability: CloudServiceAvailability,
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
        validatesCatalogMembership: Bool = false,
        statisticSchemas: [StatisticID: CloudStatisticMergeSchema] = [:],
        knownCodexIDs: Set<CodexID> = [],
        knownTitleIDs: Set<TitleID> = [],
        now: Date
    ) throws {
        try cloudValidateFinite(now)
        self.localAccountScope = localAccountScope
        self.remoteAccountScope = remoteAccountScope
        self.serviceAvailability = serviceAvailability
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
        self.validatesCatalogMembership = validatesCatalogMembership
        self.statisticSchemas = statisticSchemas
        self.knownCodexIDs = knownCodexIDs
        self.knownTitleIDs = knownTitleIDs
        self.now = now
    }
}

public enum CloudProgressionMergeStatus: String, Codable, CaseIterable, Sendable {
    case merged
    case noRemoteReplica = "no-remote-replica"
    case offlineLocalOnly = "offline-local-only"
    case unavailableLocalOnly = "unavailable-local-only"
    case disabledLocalOnly = "disabled-local-only"
    case accountChangedLocalPreserved = "account-changed-local-preserved"
    case remoteQuarantinedLocalPreserved = "remote-quarantined-local-preserved"
}

public struct CloudProgressionMergeOutcome: Equatable, Sendable {
    public let replica: CloudProgressionReplica
    public let status: CloudProgressionMergeStatus
    public let effectiveCodexID: CodexID
    public let shouldUploadLocalReplica: Bool
    public let quarantinedRemoteDigest: CloudOpaqueIdentifier?

    public init(
        replica: CloudProgressionReplica,
        status: CloudProgressionMergeStatus,
        effectiveCodexID: CodexID,
        shouldUploadLocalReplica: Bool,
        quarantinedRemoteDigest: CloudOpaqueIdentifier? = nil
    ) {
        self.replica = replica
        self.status = status
        self.effectiveCodexID = effectiveCodexID
        self.shouldUploadLocalReplica = shouldUploadLocalReplica
        self.quarantinedRemoteDigest = quarantinedRemoteDigest
    }
}

public enum CloudProgressionMergeError: Error, Equatable, Sendable {
    case conflictingRecord(String)
}

public enum CloudProgressionMergeEngine {
    public static func merge(
        local: CloudProgressionReplica,
        remoteData: Data?,
        context: CloudProgressionMergeContext
    ) throws -> CloudProgressionMergeOutcome {
        try local.validate()
        switch context.serviceAvailability {
        case .disabled:
            return localOnly(local, status: .disabledLocalOnly, context: context)
        case .offline:
            return localOnly(local, status: .offlineLocalOnly, context: context)
        case .unavailable:
            return localOnly(local, status: .unavailableLocalOnly, context: context)
        case .available:
            break
        }

        guard context.localAccountScope == context.remoteAccountScope else {
            let digest = CloudProgressionCodec.digest(of: remoteData ?? Data())
            let replica = try appendingQuarantine(
                to: local,
                digest: digest,
                category: .accountScopeMismatch,
                at: context.now
            )
            return CloudProgressionMergeOutcome(
                replica: replica,
                status: .accountChangedLocalPreserved,
                effectiveCodexID: effectiveCodex(in: replica, context: context),
                shouldUploadLocalReplica: false,
                quarantinedRemoteDigest: digest
            )
        }

        guard let remoteData else {
            return CloudProgressionMergeOutcome(
                replica: local,
                status: .noRemoteReplica,
                effectiveCodexID: effectiveCodex(in: local, context: context),
                shouldUploadLocalReplica: true
            )
        }

        let remote: CloudProgressionReplica
        do {
            remote = try CloudProgressionCodec.decode(remoteData)
        } catch {
            return try quarantinedOutcome(
                local: local,
                remoteData: remoteData,
                category: quarantineCategory(for: error),
                context: context
            )
        }

        do {
            let merged = try mergeValidated(local: local, remote: remote, context: context)
            return CloudProgressionMergeOutcome(
                replica: merged,
                status: .merged,
                effectiveCodexID: effectiveCodex(in: merged, context: context),
                shouldUploadLocalReplica: merged != remote
            )
        } catch {
            return try quarantinedOutcome(
                local: local,
                remoteData: remoteData,
                category: .invalidRemoteRecord,
                context: context
            )
        }
    }

    public static func mergeValidated(
        local: CloudProgressionReplica,
        remote: CloudProgressionReplica,
        context: CloudProgressionMergeContext
    ) throws -> CloudProgressionReplica {
        try local.validate()
        try remote.validate()
        guard remote.catalogVersion == local.catalogVersion else {
            throw CloudProgressionSchemaError.invalidCatalogVersion
        }
        try validateRemoteLogicalClockHeadroom(remote, relativeTo: local)
        try validateRemoteTimestamps(remote, noLaterThan: context.now)
        try validateRemoteCatalogMembership(remote, context: context)

        let completions = try mergeByKey(
            local.achievementCompletions,
            remote.achievementCompletions,
            key: { $0.achievementID }
        ) { lhs, rhs in
            try CloudAchievementCompletion(
                achievementID: lhs.achievementID,
                firstCompletedAt: min(lhs.firstCompletedAt, rhs.firstCompletedAt)
            )
        }
        let milestones = try mergeByKey(
            local.milestoneCompletions,
            remote.milestoneCompletions,
            key: { $0.ruleID }
        ) { lhs, rhs in
            try CloudMilestoneCompletion(
                ruleID: lhs.ruleID,
                firstCompletedAt: min(lhs.firstCompletedAt, rhs.firstCompletedAt)
            )
        }
        let grants = try mergeByKey(
            local.grants,
            remote.grants,
            key: {
                CloudGrantIdentity(grantID: $0.grantID, contentID: $0.contentID)
            }
        ) { lhs, rhs in
            guard lhs.provenanceReference == rhs.provenanceReference
            else {
                throw CloudProgressionMergeError.conflictingRecord(
                    "grant.\(lhs.grantID.rawValue).\(lhs.contentID.rawValue)"
                )
            }
            return try CloudGrant(
                grantID: lhs.grantID,
                contentID: lhs.contentID,
                firstGrantedAt: min(lhs.firstGrantedAt, rhs.firstGrantedAt),
                provenanceReference: lhs.provenanceReference
            )
        }
        let encounters = try mergeByKey(
            local.encounters,
            remote.encounters,
            key: { $0.encounterID }
        ) { lhs, rhs in
            guard lhs.codexID == rhs.codexID,
                  lhs.provenanceReference == rhs.provenanceReference
            else {
                throw CloudProgressionMergeError.conflictingRecord(
                    "encounter.\(lhs.encounterID.rawValue)"
                )
            }
            return try CloudEncounter(
                encounterID: lhs.encounterID,
                codexID: lhs.codexID,
                artifactIDs: Array(Set(lhs.artifactIDs).union(rhs.artifactIDs)),
                firstEncounteredAt: min(lhs.firstEncounteredAt, rhs.firstEncounteredAt),
                lastEncounteredAt: max(lhs.lastEncounteredAt, rhs.lastEncounteredAt),
                encounterCount: max(lhs.encounterCount, rhs.encounterCount),
                provenanceReference: lhs.provenanceReference
            )
        }
        let shards = try mergeByKey(
            local.deviceCounterShards,
            remote.deviceCounterShards,
            key: { $0.mergeKey }
        ) { lhs, rhs in
            try CloudDeviceCounterShard(
                statisticID: lhs.statisticID,
                codexID: lhs.codexID,
                deviceID: lhs.deviceID,
                value: max(lhs.value, rhs.value),
                lastUpdatedAt: max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
            )
        }
        let tokens = try mergeByKey(
            local.distinctStatisticTokens,
            remote.distinctStatisticTokens,
            key: { $0.mergeKey }
        ) { lhs, rhs in
            try CloudDistinctStatisticToken(
                statisticID: lhs.statisticID,
                codexID: lhs.codexID,
                token: lhs.token,
                firstObservedAt: min(lhs.firstObservedAt, rhs.firstObservedAt)
            )
        }
        let progress = try mergeByKey(
            local.achievementProgress,
            remote.achievementProgress,
            key: { $0.achievementID }
        ) { lhs, rhs in
            let target = max(lhs.target, rhs.target)
            return try CloudAchievementProgress(
                achievementID: lhs.achievementID,
                current: min(max(lhs.current, rhs.current), target),
                target: target,
                lastUpdatedAt: max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
            )
        }
        let reports = try mergeByKey(
            local.pendingGameCenterReports,
            remote.pendingGameCenterReports,
            key: { $0.achievementID }
        ) { lhs, rhs in
            try CloudPendingGameCenterReport(
                achievementID: lhs.achievementID,
                percentage: max(lhs.percentage, rhs.percentage),
                firstQueuedAt: min(lhs.firstQueuedAt, rhs.firstQueuedAt),
                lastUpdatedAt: max(lhs.lastUpdatedAt, rhs.lastUpdatedAt)
            )
        }
        let quarantine = try mergeByKey(
            local.quarantineDiagnostics,
            remote.quarantineDiagnostics,
            key: { $0.recordDigest }
        ) { lhs, rhs in
            try CloudQuarantineDiagnostic(
                recordDigest: lhs.recordDigest,
                category: lhs.quarantinedAt <= rhs.quarantinedAt ? lhs.category : rhs.category,
                quarantinedAt: min(lhs.quarantinedAt, rhs.quarantinedAt)
            )
        }

        let mergedUnlockIDs = Array(Set(local.unlockIDs).union(remote.unlockIDs))
        let mergedTitleIDs = Array(Set(local.titleIDs).union(remote.titleIDs))
        return try CloudProgressionReplica(
            catalogVersion: local.catalogVersion,
            logicalClock: max(local.logicalClock, remote.logicalClock),
            achievementCompletions: completions,
            milestoneCompletions: milestones,
            grants: grants,
            ownedContentIDs: Array(Set(local.ownedContentIDs).union(remote.ownedContentIDs)),
            unlockIDs: mergedUnlockIDs,
            titleIDs: mergedTitleIDs,
            encounters: encounters,
            deviceCounterShards: shards,
            distinctStatisticTokens: tokens,
            achievementProgress: progress,
            selectedCodex: mergeCodexSelection(
                local.selectedCodex,
                remote.selectedCodex,
                availableCodexIDs: context.availableCodexIDs,
                mergedUnlockIDs: Set(mergedUnlockIDs)
            ),
            selectedTitle: mergeTitleSelection(
                local.selectedTitle,
                remote.selectedTitle,
                availableTitleIDs: context.availableTitleIDs,
                mergedTitleIDs: Set(mergedTitleIDs)
            ),
            pendingGameCenterReports: reports,
            provenanceReferences: Array(
                Set(local.provenanceReferences).union(remote.provenanceReferences)
            ),
            quarantineDiagnostics: quarantine
        )
    }

    private static func localOnly(
        _ local: CloudProgressionReplica,
        status: CloudProgressionMergeStatus,
        context: CloudProgressionMergeContext
    ) -> CloudProgressionMergeOutcome {
        CloudProgressionMergeOutcome(
            replica: local,
            status: status,
            effectiveCodexID: effectiveCodex(in: local, context: context),
            shouldUploadLocalReplica: false
        )
    }

    private static func quarantinedOutcome(
        local: CloudProgressionReplica,
        remoteData: Data,
        category: CloudQuarantineCategory,
        context: CloudProgressionMergeContext
    ) throws -> CloudProgressionMergeOutcome {
        let digest = CloudProgressionCodec.digest(of: remoteData)
        let replica = try appendingQuarantine(
            to: local,
            digest: digest,
            category: category,
            at: context.now
        )
        return CloudProgressionMergeOutcome(
            replica: replica,
            status: .remoteQuarantinedLocalPreserved,
            effectiveCodexID: effectiveCodex(in: replica, context: context),
            shouldUploadLocalReplica: true,
            quarantinedRemoteDigest: digest
        )
    }

    private static func appendingQuarantine(
        to replica: CloudProgressionReplica,
        digest: CloudOpaqueIdentifier,
        category: CloudQuarantineCategory,
        at date: Date
    ) throws -> CloudProgressionReplica {
        var diagnostics = replica.quarantineDiagnostics
        if !diagnostics.contains(where: { $0.recordDigest == digest }) {
            if diagnostics.count == CloudProgressionReplica.maximumRecordsPerCollection {
                diagnostics.removeFirst()
            }
            diagnostics.append(
                try CloudQuarantineDiagnostic(
                    recordDigest: digest,
                    category: category,
                    quarantinedAt: date
                )
            )
        }
        return try CloudProgressionReplica(
            catalogVersion: replica.catalogVersion,
            logicalClock: replica.logicalClock,
            achievementCompletions: replica.achievementCompletions,
            milestoneCompletions: replica.milestoneCompletions,
            grants: replica.grants,
            ownedContentIDs: replica.ownedContentIDs,
            unlockIDs: replica.unlockIDs,
            titleIDs: replica.titleIDs,
            encounters: replica.encounters,
            deviceCounterShards: replica.deviceCounterShards,
            distinctStatisticTokens: replica.distinctStatisticTokens,
            achievementProgress: replica.achievementProgress,
            selectedCodex: replica.selectedCodex,
            selectedTitle: replica.selectedTitle,
            pendingGameCenterReports: replica.pendingGameCenterReports,
            provenanceReferences: replica.provenanceReferences,
            quarantineDiagnostics: diagnostics
        )
    }

    private static func quarantineCategory(for error: Error) -> CloudQuarantineCategory {
        if case CloudProgressionCodecError.prohibitedField = error {
            return .prohibitedField
        }
        if case CloudProgressionSchemaError.unsupportedSchemaVersion = error {
            return .invalidRemoteSchema
        }
        return .invalidRemoteRecord
    }

    private static func validateRemoteTimestamps(
        _ replica: CloudProgressionReplica,
        noLaterThan now: Date
    ) throws {
        var values = replica.achievementCompletions.map(\.firstCompletedAt)
        values.append(contentsOf: replica.milestoneCompletions.map(\.firstCompletedAt))
        values.append(contentsOf: replica.grants.map(\.firstGrantedAt))
        for encounter in replica.encounters {
            values.append(encounter.firstEncounteredAt)
            values.append(encounter.lastEncounteredAt)
        }
        values.append(contentsOf: replica.deviceCounterShards.map(\.lastUpdatedAt))
        values.append(contentsOf: replica.distinctStatisticTokens.map(\.firstObservedAt))
        values.append(contentsOf: replica.achievementProgress.map(\.lastUpdatedAt))
        if let selectedCodex = replica.selectedCodex { values.append(selectedCodex.updatedAt) }
        if let selectedTitle = replica.selectedTitle { values.append(selectedTitle.updatedAt) }
        for report in replica.pendingGameCenterReports {
            values.append(report.firstQueuedAt)
            values.append(report.lastUpdatedAt)
        }
        values.append(contentsOf: replica.quarantineDiagnostics.map(\.quarantinedAt))
        guard values.allSatisfy({ $0 <= now }) else {
            throw CloudProgressionSchemaError.invalidTimestamp
        }
    }

    private static func validateRemoteLogicalClockHeadroom(
        _ remote: CloudProgressionReplica,
        relativeTo local: CloudProgressionReplica
    ) throws {
        let maximumAdvance = CloudProgressionReplica.maximumRemoteLogicalClockAdvance
        let absoluteCeiling = UInt64.max - maximumAdvance
        let localHighWatermark = max(
            local.logicalClock,
            max(
                local.selectedCodex?.logicalTimestamp ?? 0,
                local.selectedTitle?.logicalTimestamp ?? 0
            )
        )
        guard localHighWatermark <= absoluteCeiling else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
        let relativeCeiling = localHighWatermark + maximumAdvance
        let acceptedCeiling = min(relativeCeiling, absoluteCeiling)
        let remoteClocks = [
            remote.logicalClock,
            remote.selectedCodex?.logicalTimestamp,
            remote.selectedTitle?.logicalTimestamp,
        ].compactMap { $0 }
        guard remoteClocks.allSatisfy({ $0 <= acceptedCeiling }) else {
            throw CloudProgressionSchemaError.invalidLogicalClock
        }
    }

    private static func validateRemoteCatalogMembership(
        _ replica: CloudProgressionReplica,
        context: CloudProgressionMergeContext
    ) throws {
        func requireKnown<Value: Hashable>(
            _ values: [Value],
            in inventory: Set<Value>,
            label: String
        ) throws {
            guard !context.validatesCatalogMembership
                || values.allSatisfy(inventory.contains)
            else {
                throw CloudProgressionMergeError.conflictingRecord(label)
            }
        }

        try requireKnown(
            replica.deviceCounterShards.map(\.statisticID)
                + replica.distinctStatisticTokens.map(\.statisticID),
            in: context.knownStatisticIDs,
            label: "statistic"
        )
        if context.validatesCatalogMembership {
            for shard in replica.deviceCounterShards {
                guard let schema = context.statisticSchemas[shard.statisticID],
                      schema.representation == .deviceCounter,
                      schema.requiresCodexBucket == (shard.codexID != nil)
                else {
                    throw CloudProgressionMergeError.conflictingRecord(
                        "device-counter-schema"
                    )
                }
            }
            for token in replica.distinctStatisticTokens {
                guard let schema = context.statisticSchemas[token.statisticID],
                      schema.representation == .distinctToken,
                      schema.requiresCodexBucket == (token.codexID != nil)
                else {
                    throw CloudProgressionMergeError.conflictingRecord(
                        "distinct-token-schema"
                    )
                }
            }
        }
        let completionIDs = Set(replica.achievementCompletions.map(\.achievementID))
        let progressByID = Dictionary(
            uniqueKeysWithValues: replica.achievementProgress.map {
                ($0.achievementID, $0)
            }
        )
        for progress in replica.achievementProgress {
            if let target = context.achievementTargets[progress.achievementID],
               progress.target != target
            {
                throw CloudProgressionMergeError.conflictingRecord("achievement-target")
            }
        }
        for report in replica.pendingGameCenterReports {
            guard let progress = progressByID[report.achievementID] else {
                throw CloudProgressionMergeError.conflictingRecord("game-center-progress")
            }
            let percentage: UInt8
            if progress.current >= progress.target {
                percentage = 100
            } else {
                let product = progress.current.multipliedFullWidth(by: 100)
                let quotient = progress.target.dividingFullWidth(product).quotient
                guard quotient < 100 else {
                    throw CloudProgressionSchemaError.invalidProgress
                }
                percentage = UInt8(quotient)
            }
            guard report.percentage <= percentage,
                  report.percentage < 100 || completionIDs.contains(report.achievementID)
            else {
                throw CloudProgressionMergeError.conflictingRecord("game-center-report")
            }
        }
        try requireKnown(
            replica.achievementCompletions.map(\.achievementID)
                + replica.achievementProgress.map(\.achievementID)
                + replica.pendingGameCenterReports.map(\.achievementID),
            in: context.knownAchievementIDs,
            label: "achievement"
        )
        try requireKnown(
            replica.milestoneCompletions.map(\.ruleID),
            in: context.knownMilestoneRuleIDs,
            label: "milestone"
        )
        try requireKnown(
            replica.grants.map(\.contentID.rawValue)
                + replica.ownedContentIDs.map(\.rawValue),
            in: context.knownContentIDs,
            label: "content"
        )
        try requireKnown(
            replica.encounters.flatMap(\.artifactIDs),
            in: context.knownArtifactIDs,
            label: "artifact"
        )
        try requireKnown(
            replica.unlockIDs,
            in: context.knownUnlockIDs,
            label: "unlock"
        )
        try requireKnown(
            replica.titleIDs,
            in: context.knownTitleIDs,
            label: "title"
        )
        if let selectedTitle = replica.selectedTitle,
           let titleID = selectedTitle.titleID,
           context.validatesCatalogMembership,
           !context.knownTitleIDs.contains(titleID)
        {
            throw CloudProgressionMergeError.conflictingRecord("selected-title-catalog")
        }
        let codexIDs = replica.encounters.map(\.codexID)
            + replica.deviceCounterShards.compactMap(\.codexID)
            + replica.distinctStatisticTokens.compactMap(\.codexID)
        try requireKnown(
            codexIDs,
            in: context.knownCodexIDs,
            label: "codex"
        )
        if let selectedCodex = replica.selectedCodex,
           context.validatesCatalogMembership,
           !context.knownCodexIDs.contains(selectedCodex.codexID)
        {
            throw CloudProgressionMergeError.conflictingRecord("selected-codex-catalog")
        }
    }

    private static func mergeCodexSelection(
        _ lhs: CloudCodexSelection?,
        _ rhs: CloudCodexSelection?,
        availableCodexIDs: Set<CodexID>,
        mergedUnlockIDs: Set<UnlockID>
    ) -> CloudCodexSelection? {
        [lhs, rhs]
            .compactMap { $0 }
            .sorted { $0.deterministicOrder > $1.deterministicOrder }
            .first { selection in
                availableCodexIDs.contains(selection.codexID) ||
                    mergedUnlockIDs.contains(where: {
                        $0.rawValue == "unlock.\(selection.codexID.rawValue)"
                    })
            }
    }

    private static func mergeTitleSelection(
        _ lhs: CloudTitleSelection?,
        _ rhs: CloudTitleSelection?,
        availableTitleIDs: Set<TitleID>,
        mergedTitleIDs: Set<TitleID>
    ) -> CloudTitleSelection? {
        [lhs, rhs]
            .compactMap { $0 }
            .sorted { $0.deterministicOrder > $1.deterministicOrder }
            .first { selection in
                guard let titleID = selection.titleID else { return true }
                return availableTitleIDs.contains(titleID) ||
                    mergedTitleIDs.contains(titleID)
            }
    }

    private static func effectiveCodex(
        in replica: CloudProgressionReplica,
        context: CloudProgressionMergeContext
    ) -> CodexID {
        guard let selected = replica.selectedCodex,
              context.availableCodexIDs.contains(selected.codexID)
        else { return context.fallbackCodexID }
        return selected.codexID
    }
}

private func mergeByKey<Element, Key: Hashable>(
    _ lhs: [Element],
    _ rhs: [Element],
    key: (Element) -> Key,
    merge: (Element, Element) throws -> Element
) rethrows -> [Element] {
    var merged = Dictionary(uniqueKeysWithValues: lhs.map { (key($0), $0) })
    for element in rhs {
        let elementKey = key(element)
        if let current = merged[elementKey] {
            merged[elementKey] = try merge(current, element)
        } else {
            merged[elementKey] = element
        }
    }
    return Array(merged.values)
}
