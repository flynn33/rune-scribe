import Foundation
import RuneScribeContracts

enum ProgressionCatalogSemanticValidator {
    private typealias Support = ProgressionCatalogValidationSupport

    static func validate(_ catalog: ProgressionCatalog) throws {
        guard catalog.schemaVersion == "1.0" else {
            return try invalid("$catalog.schemaVersion", "Only schema 1.0 is supported.")
        }
        guard catalog.catalogID.rawValue == "runescribe.progression.catalog" else {
            return try invalid("$catalog.catalogID", "Unexpected catalog identifier.")
        }
        guard catalog.catalogVersion.rawValue == 3 else {
            return try invalid("$catalog.catalogVersion", "Unexpected catalog version.")
        }
        guard catalog.packageVersion.description == "1.0.0" else {
            return try invalid("$catalog.packageVersion", "Unexpected package version.")
        }
        try Support.requireDate(catalog.effectiveDate, path: "$catalog.effectiveDate")
        try Support.requireText(catalog.governingObjective, path: "$catalog.governingObjective")
        try exactUniqueSet(
            catalog.principles,
            expected: Set(ProgressionPrinciple.allCases),
            path: "$catalog.principles"
        )
        try exactUniqueSet(
            catalog.deferred,
            expected: Set(ProgressionDeferredFeature.allCases),
            path: "$catalog.deferred"
        )
        try ProgressionCatalogDependencyAnalyzer.rejectDirectCycles(in: catalog)

        try validateContent(catalog)
        try validateStatistics(catalog)
        try validateAchievementsAndMilestones(catalog)
        try validateGrantGroups(catalog)
        try validateJourney(catalog)
        try validateRevealPolicy(catalog)
        try validatePolicies(catalog)
    }

    private static func validateContent(_ catalog: ProgressionCatalog) throws {
        try Support.requireCount(catalog.content, 84, name: "content")
        try Support.requireUnique(
            catalog.content.map(\.contentID),
            kind: "contentID",
            describe: \.rawValue
        )

        let expectedKinds: [ProgressionCatalogContentKind: Int] = [
            .codex: 5, .crest: 5, .entitlement: 5, .frame: 7,
            .relic: 16, .script: 5, .seal: 32, .title: 9,
        ]
        let actualKinds = Dictionary(grouping: catalog.content, by: \.kind).mapValues(\.count)
        guard actualKinds == expectedKinds else {
            return try invalid("$catalog.content", "Content kind inventory does not match v3.")
        }
        let expectedAvailability: [ProgressionContentAvailability: Int] = [
            .earned: 12, .included: 6, .permanent: 52,
            .permanentMastery: 14,
        ]
        let actualAvailability = Dictionary(
            grouping: catalog.content,
            by: \.availability
        ).mapValues(\.count)
        guard actualAvailability == expectedAvailability else {
            return try invalid("$catalog.content", "Availability inventory does not match v3.")
        }

        let codexContent = Set(
            catalog.content.filter { $0.kind == .codex }.map { $0.contentID.rawValue }
        )
        let expectedCodexCounts = [
            "<none>": 9,
            "codex.norse": 15,
            "codex.moonleaf": 15,
            "codex.sunspire": 15,
            "codex.wildwood": 15,
            "codex.gloamthorn": 15,
        ]
        let codexCounts = Dictionary(
            grouping: catalog.content,
            by: { $0.codexID?.rawValue ?? "<none>" }
        ).mapValues(\.count)
        guard codexCounts == expectedCodexCounts else {
            return try invalid("$catalog.content", "Codex ownership inventory mismatch.")
        }
        for (index, item) in catalog.content.enumerated() {
            let path = "$catalog.content[\(index)]"
            try Support.requireText(
                item.displayName,
                path: "\(path).displayName",
                maximumBytes: Support.maximumShortTextBytes
            )
            if let notes = item.notes {
                try Support.requireText(notes, path: "\(path).notes")
            }
            let expectedPrefix = switch item.kind {
            case .entitlement: "unlock."
            default: "\(item.kind.rawValue)."
            }
            guard item.contentID.rawValue.hasPrefix(expectedPrefix) else {
                return try invalid("\(path).contentID", "Content kind prefix mismatch.")
            }
            let expectedArtifact = [
                ProgressionCatalogContentKind.crest, .frame, .relic, .seal,
            ].contains(item.kind)
            guard item.countsAsArtifact == expectedArtifact else {
                return try invalid(
                    "\(path).countsAsArtifact",
                    "Only Crests, Frames, Relics, and Seals count as Artifacts."
                )
            }
            if let codexID = item.codexID {
                guard codexContent.contains(codexID.rawValue) else {
                    throw ProgressionCatalogValidationError.unknownReference(
                        path: "\(path).codexID",
                        identifier: codexID.rawValue
                    )
                }
                if item.kind == .codex, item.contentID.rawValue != codexID.rawValue {
                    return try invalid("\(path).codexID", "Codex content must reference itself.")
                }
            }
        }

        guard catalog.content.allSatisfy({ $0.availability != .seasonalDeferred }) else {
            return try invalid("$catalog.content", "Catalog v3 has no seasonal content item.")
        }
        try validateNorseV2Content(catalog)
        try validateElvenMasteryTitles(catalog)
    }

    private static func validateElvenMasteryTitles(_ catalog: ProgressionCatalog) throws {
        struct Expected {
            let displayName: String
            let codexID: String
        }
        let expected: [String: Expected] = [
            "title.gloamthorn.mastery": .init(
                displayName: "Sovereign of the Gloam", codexID: "codex.gloamthorn"
            ),
            "title.moonleaf.mastery": .init(
                displayName: "Moonleaf Master", codexID: "codex.moonleaf"
            ),
            "title.sunspire.mastery": .init(
                displayName: "Bearer of First Light", codexID: "codex.sunspire"
            ),
            "title.wildwood.mastery": .init(
                displayName: "Keeper of the Heartwood", codexID: "codex.wildwood"
            ),
        ]
        for (contentID, value) in expected {
            guard let id = ProgressionContentID(rawValue: contentID),
                  let item = catalog.content(id: id),
                  item.kind == .title,
                  item.displayName == value.displayName,
                  item.countsAsArtifact == false,
                  item.availability == .permanentMastery,
                  item.rarity == .mythic,
                  item.codexID?.rawValue == value.codexID
            else {
                return try invalid(
                    "$catalog.content.\(contentID)",
                    "Elven mastery title metadata is invalid."
                )
            }
        }
    }

    private static func validateNorseV2Content(_ catalog: ProgressionCatalog) throws {
        struct Expected {
            let kind: ProgressionCatalogContentKind
            let displayName: String
            let availability: ProgressionContentAvailability
            let rarity: String
        }
        let expected: [String: Expected] = [
            "codex.norse": .init(
                kind: .codex, displayName: "Norse Codex",
                availability: .included, rarity: "Forged"
            ),
            "crest.norse.raven-mastery": .init(
                kind: .crest, displayName: "Raven Mastery Crest",
                availability: .permanentMastery, rarity: "Mythic"
            ),
            "frame.norse.carved-knotwork": .init(
                kind: .frame, displayName: "Norse Mastery Frame",
                availability: .permanent, rarity: "Inscribed"
            ),
            "relic.norse.dragonwood-plaque": .init(
                kind: .relic, displayName: "Dragonwood Plaque",
                availability: .permanent, rarity: "Inscribed"
            ),
            "relic.norse.runestone-tablet": .init(
                kind: .relic, displayName: "Runestone Tablet",
                availability: .included, rarity: "Forged"
            ),
            "relic.norse.stormforged-stele": .init(
                kind: .relic, displayName: "Stormforged Stele",
                availability: .permanent, rarity: "Rare"
            ),
            "script.base-runes": .init(
                kind: .script, displayName: "Base Rune Script",
                availability: .included, rarity: "Forged"
            ),
            "seal.norse.berserk": .init(
                kind: .seal, displayName: "Berserk Seal",
                availability: .permanent, rarity: "Inscribed"
            ),
            "seal.norse.mjolnir": .init(
                kind: .seal, displayName: "Mjolnir Seal",
                availability: .permanent, rarity: "Inscribed"
            ),
            "seal.norse.ravenshield": .init(
                kind: .seal, displayName: "Ravenshield Seal",
                availability: .included, rarity: "Forged"
            ),
            "seal.norse.valknut": .init(
                kind: .seal, displayName: "Valknut Seal",
                availability: .included, rarity: "Forged"
            ),
            "seal.norse.wolkin": .init(
                kind: .seal, displayName: "Wolkin Seal",
                availability: .permanent, rarity: "Inscribed"
            ),
            "seal.norse.yggdrasil": .init(
                kind: .seal, displayName: "Yggdrasil Seal",
                availability: .permanent, rarity: "Inscribed"
            ),
            "title.norse.master-of-runes": .init(
                kind: .title, displayName: "Master of Runes",
                availability: .permanentMastery, rarity: "Mythic"
            ),
            "unlock.codex.norse": .init(
                kind: .entitlement,
                displayName: "Norse Codex Create and Select Right",
                availability: .included, rarity: "Forged"
            ),
        ]
        let actual = catalog.content.filter { $0.codexID?.rawValue == "codex.norse" }
        guard Set(actual.map { $0.contentID.rawValue }) == Set(expected.keys) else {
            return try invalid("$catalog.content", "Norse v2 content identifiers are invalid.")
        }
        for item in actual {
            guard let value = expected[item.contentID.rawValue],
                  item.kind == value.kind,
                  item.displayName == value.displayName,
                  item.availability == value.availability,
                  item.rarity.rawValue == value.rarity
            else {
                return try invalid(
                    "$catalog.content.\(item.contentID.rawValue)",
                    "Norse v2 content metadata is invalid."
                )
            }
        }
    }

    private static func validateStatistics(_ catalog: ProgressionCatalog) throws {
        let expectedFilters: [String: String] = [
            "stat.share.relic-used.unique": "owned relic IDs only",
            "stat.share.seal-used.unique": "owned seal IDs only",
            "stat.share.codex-used.unique": "owned Codex IDs only",
            "stat.encounter.codex.unique": "Codex unowned at first observation",
            "stat.ownership.artifact-count": "countsAsArtifact=true",
            "stat.achievement.completed-count":
                "evergreen=true and excludes achievement.master-scribe when evaluating itself",
            "stat.codex.relationship-presented.unique":
                "relationshipToken present and share eligible",
            "stat.codex.relic-used.unique": "owned relic IDs only",
            "stat.codex.seal-used.unique": "owned seal IDs only",
        ]
        try Support.requireCount(catalog.statistics, 18, name: "statistics")
        try Support.requireUnique(
            catalog.statistics.map(\.statisticID),
            kind: "statisticID",
            describe: \.rawValue
        )
        let expectedStorage: [ProgressionStatisticStorage: Int] = [
            .distinctSet: 10, .bucketedDistinctSet: 6, .derived: 2,
        ]
        let actualStorage = Dictionary(
            grouping: catalog.statistics,
            by: \.storage
        ).mapValues(\.count)
        guard actualStorage == expectedStorage else {
            return try invalid("$catalog.statistics", "Statistic storage inventory mismatch.")
        }

        for (index, statistic) in catalog.statistics.enumerated() {
            let path = "$catalog.statistics[\(index)]"
            try Support.requireText(
                statistic.displayName,
                path: "\(path).displayName",
                maximumBytes: Support.maximumShortTextBytes
            )
            guard !statistic.sourceEvents.isEmpty, statistic.sourceEvents.count <= 4 else {
                return try invalid("\(path).sourceEvents", "Source events must contain 1...4 values.")
            }
            try Support.requireUnique(
                statistic.sourceEvents,
                kind: "statistic source event",
                describe: { $0 }
            )
            for source in statistic.sourceEvents {
                try Support.requireIdentifier(source, path: "\(path).sourceEvents")
            }
            if let filter = statistic.filter {
                try Support.requireText(filter, path: "\(path).filter")
            }
            guard statistic.filter == expectedFilters[statistic.statisticID.rawValue] else {
                return try invalid(
                    "\(path).filter",
                    "Statistic filter does not match the supported definition."
                )
            }
            let filterDimensionIsCompatible: Bool
            switch statistic.filter {
            case "owned relic IDs only", "owned seal IDs only":
                filterDimensionIsCompatible = statistic.dimension == .artifactID
            case "owned Codex IDs only", "Codex unowned at first observation":
                filterDimensionIsCompatible = statistic.dimension == .codexID
            case "relationshipToken present and share eligible":
                filterDimensionIsCompatible = statistic.dimension == .relationshipToken
            case "countsAsArtifact=true":
                filterDimensionIsCompatible = statistic.dimension == .contentID
            case "evergreen=true and excludes achievement.master-scribe when evaluating itself":
                filterDimensionIsCompatible = statistic.dimension == .achievementID
            case nil:
                filterDimensionIsCompatible = true
            default:
                filterDimensionIsCompatible = false
            }
            guard filterDimensionIsCompatible else {
                return try invalid(
                    "\(path).dimension",
                    "Statistic filter is incompatible with its dimension."
                )
            }
            switch statistic.storage {
            case .bucketedDistinctSet:
                guard statistic.bucket == .codexID else {
                    return try invalid("\(path).bucket", "Bucketed statistics require codexID.")
                }
            case .derived, .distinctSet:
                guard statistic.bucket == nil else {
                    return try invalid("\(path).bucket", "Only bucketed statistics have a bucket.")
                }
            }
        }
    }

    private static func validateAchievementsAndMilestones(
        _ catalog: ProgressionCatalog
    ) throws {
        try Support.requireCount(catalog.achievements, 15, name: "achievements")
        try Support.requireCount(catalog.milestones, 30, name: "milestones")
        try Support.requireUnique(
            catalog.achievements.map(\.achievementID),
            kind: "achievementID",
            describe: \.rawValue
        )
        try Support.requireUnique(
            catalog.milestones.map(\.ruleID),
            kind: "ruleID",
            describe: \.rawValue
        )
        let statisticByID = Dictionary(
            uniqueKeysWithValues: catalog.statistics.map { ($0.statisticID, $0) }
        )
        let contentByID = Dictionary(
            uniqueKeysWithValues: catalog.content.map { ($0.contentID, $0) }
        )
        let grantableContent = Set(
            catalog.grantGroups.flatMap(\.items).map(\.contentID)
        )
        let achievementIDs = Set(catalog.achievements.map(\.achievementID))
        let completionSourceCounts = Dictionary(
            grouping: catalog.achievements.map(\.rewardGrantGroupID)
                + catalog.milestones.map(\.grantGroupID),
            by: { $0 }
        ).mapValues(\.count)

        var operatorCounts: [ProgressionRuleOperator: Int] = [:]
        for (index, achievement) in catalog.achievements.enumerated() {
            let path = "$catalog.achievements[\(index)]"
            try validateCompletionText(
                name: achievement.displayName,
                description: achievement.description,
                path: path
            )
            guard achievement.evergreen,
                  achievement.localPointWeight <= 100,
                  achievement.gameCenter.eligible,
                  achievement.gameCenter.status == .deferredNotConfigured,
                  achievement.gameCenter.permanentIdentifier == nil,
                  achievement.gameCenter.points == achievement.localPointWeight
            else {
                return try invalid(path, "Achievement or Game Center metadata is invalid.")
            }
            try Support.requireText(
                achievement.fallbackSystemImage,
                path: "\(path).fallbackSystemImage",
                maximumBytes: 96
            )
            try validateRule(
                achievement.rule,
                path: "\(path).rule",
                statistics: statisticByID,
                content: contentByID,
                grantableContent: grantableContent,
                achievements: achievementIDs,
                depth: 0,
                operatorCounts: &operatorCounts
            )
            try validateBucketReachability(
                achievement.rule,
                grantGroupID: achievement.rewardGrantGroupID,
                sourceCounts: completionSourceCounts,
                catalog: catalog,
                path: "\(path).rule"
            )
            try validateAchievementProgress(
                achievement,
                path: path,
                statistics: statisticByID,
                achievements: achievementIDs
            )
        }
        guard catalog.achievements.reduce(0, { $0 + Int($1.localPointWeight) }) == 220 else {
            return try invalid("$catalog.achievements", "Local point total must be 220.")
        }

        let expectedCategories: [ProgressionMilestoneCategory: Int] = [
            .artifactLadder: 21, .codexMastery: 5, .codexUnlock: 4,
        ]
        let actualCategories = Dictionary(
            grouping: catalog.milestones,
            by: \.category
        ).mapValues(\.count)
        guard actualCategories == expectedCategories else {
            return try invalid("$catalog.milestones", "Milestone category inventory mismatch.")
        }
        for (index, milestone) in catalog.milestones.enumerated() {
            let path = "$catalog.milestones[\(index)]"
            try validateCompletionText(
                name: milestone.displayName,
                description: milestone.description,
                path: path
            )
            guard milestone.revealTier != .none else {
                return try invalid("\(path).revealTier", "Milestones cannot use the none tier.")
            }
            try validateRule(
                milestone.rule,
                path: "\(path).rule",
                statistics: statisticByID,
                content: contentByID,
                grantableContent: grantableContent,
                achievements: achievementIDs,
                depth: 0,
                operatorCounts: &operatorCounts
            )
            try validateBucketReachability(
                milestone.rule,
                grantGroupID: milestone.grantGroupID,
                sourceCounts: completionSourceCounts,
                catalog: catalog,
                path: "\(path).rule"
            )
            guard !milestone.progressComponents.isEmpty,
                  milestone.progressComponents.count <= 8
            else {
                return try invalid(
                    "\(path).progressComponents",
                    "Progress components must contain 1...8 entries."
                )
            }
            for (componentIndex, component) in milestone.progressComponents.enumerated() {
                try validateProgressComponent(
                    component,
                    path: "\(path).progressComponents[\(componentIndex)]",
                    statistics: statisticByID,
                    content: contentByID,
                    grantableContent: grantableContent,
                    achievements: achievementIDs
                )
            }
            try validateAllContentProgressMirrorsRule(milestone, path: path)
        }

        let expectedOperators: [ProgressionRuleOperator: Int] = [
            .achievementCompleted: 2,
            .all: 24,
            .allListedContentUsed: 5,
            .bucketCountAtLeast: 1,
            .completedAchievementCountAtLeast: 1,
            .contentOwned: 24,
            .distinctCountAtLeast: 62,
        ]
        guard operatorCounts == expectedOperators else {
            return try invalid("$catalog", "Rule operator inventory does not match catalog v2.")
        }
        try validateNorseV2Mastery(catalog)
    }

    private static func validateNorseV2Mastery(_ catalog: ProgressionCatalog) throws {
        let codex = CodexID(rawValue: "codex.norse")!
        let relics = [
            ProgressionContentID(rawValue: "relic.norse.runestone-tablet")!,
            ProgressionContentID(rawValue: "relic.norse.dragonwood-plaque")!,
            ProgressionContentID(rawValue: "relic.norse.stormforged-stele")!,
        ]
        let expectedRule = ProgressionRule.all([
            .contentOwned(ProgressionContentID(rawValue: "codex.norse")!),
            .distinctCountAtLeast(
                statisticID: StatisticID(rawValue: "stat.codex.share.unique-message")!,
                threshold: 15,
                bucketID: codex
            ),
            .distinctCountAtLeast(
                statisticID: StatisticID(
                    rawValue: "stat.codex.relationship-presented.unique"
                )!,
                threshold: 5,
                bucketID: codex
            ),
            .allListedContentUsed(
                statisticID: StatisticID(rawValue: "stat.codex.relic-used.unique")!,
                bucketID: codex,
                contentIDs: relics
            ),
            .distinctCountAtLeast(
                statisticID: StatisticID(rawValue: "stat.codex.seal-used.unique")!,
                threshold: 4,
                bucketID: codex
            ),
            .distinctCountAtLeast(
                statisticID: StatisticID(
                    rawValue: "stat.codex.incoming-decode.unique-package"
                )!,
                threshold: 5,
                bucketID: codex
            ),
        ])
        let expectedProgress = [
            ProgressionProgressComponent(
                type: .statistic,
                statisticID: StatisticID(rawValue: "stat.codex.share.unique-message")!,
                target: 15,
                bucketID: codex,
                contentIDs: nil,
                minimumBuckets: nil,
                minimumValuePerBucket: nil,
                achievementID: nil,
                contentID: nil
            ),
            ProgressionProgressComponent(
                type: .statistic,
                statisticID: StatisticID(
                    rawValue: "stat.codex.relationship-presented.unique"
                )!,
                target: 5,
                bucketID: codex,
                contentIDs: nil,
                minimumBuckets: nil,
                minimumValuePerBucket: nil,
                achievementID: nil,
                contentID: nil
            ),
            ProgressionProgressComponent(
                type: .allContentUsed,
                statisticID: StatisticID(rawValue: "stat.codex.relic-used.unique")!,
                target: nil,
                bucketID: codex,
                contentIDs: relics,
                minimumBuckets: nil,
                minimumValuePerBucket: nil,
                achievementID: nil,
                contentID: nil
            ),
            ProgressionProgressComponent(
                type: .statistic,
                statisticID: StatisticID(rawValue: "stat.codex.seal-used.unique")!,
                target: 4,
                bucketID: codex,
                contentIDs: nil,
                minimumBuckets: nil,
                minimumValuePerBucket: nil,
                achievementID: nil,
                contentID: nil
            ),
            ProgressionProgressComponent(
                type: .statistic,
                statisticID: StatisticID(
                    rawValue: "stat.codex.incoming-decode.unique-package"
                )!,
                target: 5,
                bucketID: codex,
                contentIDs: nil,
                minimumBuckets: nil,
                minimumValuePerBucket: nil,
                achievementID: nil,
                contentID: nil
            ),
        ]
        guard let mastery = catalog.milestone(id: RuleID(
            rawValue: "rule.codex.norse.mastery"
        )!),
        mastery.rule == expectedRule,
        mastery.progressComponents == expectedProgress,
        mastery.grantGroupID.rawValue == "grant-group.codex.norse.mastery",
        mastery.revealTier == .mastery
        else {
            return try invalid(
                "$catalog.milestones.rule.codex.norse.mastery",
                "Norse mastery must require all three current Relics."
            )
        }
    }

    private static func validateAchievementProgress(
        _ achievement: ProgressionAchievementDefinition,
        path: String,
        statistics: [StatisticID: ProgressionStatisticDefinition],
        achievements: Set<AchievementID>
    ) throws {
        guard statistics[achievement.progress.statisticID] != nil else {
            throw ProgressionCatalogValidationError.unknownReference(
                path: "\(path).progress.statisticID",
                identifier: achievement.progress.statisticID.rawValue
            )
        }
        try Support.requireThreshold(achievement.progress.target, path: "\(path).progress.target")
        switch achievement.rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            guard bucketID == nil,
                  statisticID == achievement.progress.statisticID,
                  threshold == achievement.progress.target,
                  achievement.progress.excludeAchievementIDs == nil
            else {
                return try invalid("\(path).progress", "Achievement progress must mirror its rule.")
            }
        case let .completedAchievementCountAtLeast(threshold, excluding):
            guard achievement.progress.statisticID.rawValue ==
                    "stat.achievement.completed-count",
                  threshold == achievement.progress.target,
                  achievement.progress.excludeAchievementIDs == excluding
            else {
                return try invalid("\(path).progress", "Master progress must mirror its rule.")
            }
            try Support.requireUnique(
                excluding,
                kind: "excluded achievementID",
                describe: \.rawValue
            )
            for excluded in excluding {
                try Support.requireReference(
                    excluded,
                    in: achievements,
                    path: "\(path).progress.excludeAchievementIDs",
                    describe: \.rawValue
                )
            }
        default:
            return try invalid("\(path).rule", "Unexpected v2 Achievement rule shape.")
        }
    }

    private static func validateRule(
        _ rule: ProgressionRule,
        path: String,
        statistics: [StatisticID: ProgressionStatisticDefinition],
        content: [ProgressionContentID: ProgressionContentDefinition],
        grantableContent: Set<ProgressionContentID>,
        achievements: Set<AchievementID>,
        depth: Int,
        operatorCounts: inout [ProgressionRuleOperator: Int]
    ) throws {
        guard depth <= 8 else { return try invalid(path, "Rule nesting exceeds 8 levels.") }
        operatorCounts[rule.operator, default: 0] += 1
        switch rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            guard let statistic = statistics[statisticID] else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "\(path).statisticID",
                    identifier: statisticID.rawValue
                )
            }
            try Support.requireThreshold(threshold, path: "\(path).threshold")
            if let maximum = maximumCardinality(
                for: statistic,
                content: content,
                grantableContent: grantableContent,
                achievements: achievements
            ), threshold > maximum {
                return try invalid(
                    "\(path).threshold",
                    "Threshold exceeds the statistic's finite domain."
                )
            }
            if statistic.storage == .bucketedDistinctSet {
                guard let bucketID,
                      let bucketContentID = ProgressionContentID(rawValue: bucketID.rawValue),
                      content[bucketContentID]?.kind == .codex
                else {
                    throw ProgressionCatalogValidationError.unknownReference(
                        path: "\(path).bucketID",
                        identifier: bucketID?.rawValue ?? "<missing>"
                    )
                }
            } else if bucketID != nil {
                return try invalid("\(path).bucketID", "Non-bucketed statistic forbids a bucket.")
            }
        case let .contentOwned(contentID):
            guard content[contentID] != nil, grantableContent.contains(contentID) else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "\(path).contentID",
                    identifier: contentID.rawValue
                )
            }
        case let .achievementCompleted(achievementID):
            try Support.requireReference(
                achievementID,
                in: achievements,
                path: "\(path).achievementID",
                describe: \.rawValue
            )
        case let .completedAchievementCountAtLeast(threshold, excluding):
            try Support.requireThreshold(threshold, path: "\(path).threshold")
            guard !excluding.isEmpty, excluding.count <= 15 else {
                return try invalid("\(path).excludeAchievementIDs", "Invalid exclusion count.")
            }
            try Support.requireUnique(
                excluding,
                kind: "excluded achievementID",
                describe: \.rawValue
            )
            for achievementID in excluding {
                try Support.requireReference(
                    achievementID,
                    in: achievements,
                    path: "\(path).excludeAchievementIDs",
                    describe: \.rawValue
                )
            }
            guard threshold <= UInt32(clamping: achievements.count - excluding.count) else {
                return try invalid(
                    "\(path).threshold",
                    "Achievement threshold exceeds the non-excluded domain."
                )
            }
        case let .all(conditions), let .any(conditions):
            guard !conditions.isEmpty, conditions.count <= 8 else {
                return try invalid("\(path).conditions", "Condition count must be 1...8.")
            }
            for (index, condition) in conditions.enumerated() {
                try validateRule(
                    condition,
                    path: "\(path).conditions[\(index)]",
                    statistics: statistics,
                    content: content,
                    grantableContent: grantableContent,
                    achievements: achievements,
                    depth: depth + 1,
                    operatorCounts: &operatorCounts
                )
            }
        case let .bucketCountAtLeast(statisticID, minimumBuckets, minimumValuePerBucket):
            guard let statistic = statistics[statisticID],
                  statistic.storage == .bucketedDistinctSet
            else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "\(path).statisticID",
                    identifier: statisticID.rawValue
                )
            }
            let codexCount = UInt16(clamping: content.values.filter { $0.kind == .codex }.count)
            guard minimumBuckets > 0, minimumBuckets <= codexCount else {
                return try invalid(
                    "\(path).minimumBuckets",
                    "Bucket count exceeds the catalog Codex universe."
                )
            }
            try Support.requireThreshold(
                minimumValuePerBucket,
                path: "\(path).minimumValuePerBucket"
            )
        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            guard let statistic = statistics[statisticID],
                  statistic.storage == .bucketedDistinctSet,
                  statistic.dimension == .artifactID,
                  let bucketContentID = ProgressionContentID(rawValue: bucketID.rawValue),
                  content[bucketContentID]?.kind == .codex
            else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "\(path).bucketID",
                    identifier: bucketID.rawValue
                )
            }
            guard !contentIDs.isEmpty, contentIDs.count <= 16 else {
                return try invalid("\(path).contentIDs", "Content count must be 1...16.")
            }
            try Support.requireUnique(contentIDs, kind: "listed contentID", describe: \.rawValue)
            for contentID in contentIDs {
                guard let item = content[contentID],
                      item.kind == .relic,
                      item.codexID == bucketID,
                      grantableContent.contains(contentID)
                else {
                    throw ProgressionCatalogValidationError.unknownReference(
                        path: "\(path).contentIDs",
                        identifier: contentID.rawValue
                    )
                }
            }
        }
    }

    private static func validateBucketReachability(
        _ rule: ProgressionRule,
        grantGroupID: GrantGroupID,
        sourceCounts: [GrantGroupID: Int],
        catalog: ProgressionCatalog,
        path: String
    ) throws {
        let codexCount = catalog.content.filter { $0.kind == .codex }.count
        let selfGatedCodexCount: Int
        if sourceCounts[grantGroupID] == 1,
           let group = catalog.grantGroup(id: grantGroupID)
        {
            selfGatedCodexCount = group.items.filter { item in
                catalog.content(id: item.contentID)?.kind == .codex
            }.count
        } else {
            selfGatedCodexCount = 0
        }
        let maximumAvailableBuckets = UInt16(
            clamping: max(0, codexCount - selfGatedCodexCount)
        )

        func unreachableBucketPath(
            _ value: ProgressionRule,
            nestedPath: String
        ) -> String? {
            switch value {
            case let .bucketCountAtLeast(_, minimumBuckets, _):
                return minimumBuckets > maximumAvailableBuckets
                    ? "\(nestedPath).minimumBuckets" : nil
            case let .all(conditions):
                for (index, condition) in conditions.enumerated() {
                    if let path = unreachableBucketPath(
                        condition,
                        nestedPath: "\(nestedPath).conditions[\(index)]"
                    ) {
                        return path
                    }
                }
                return nil
            case let .any(conditions):
                let paths = conditions.enumerated().map { index, condition in
                    unreachableBucketPath(
                        condition,
                        nestedPath: "\(nestedPath).conditions[\(index)]"
                    )
                }
                return paths.allSatisfy { $0 != nil } ? paths.compactMap { $0 }.first : nil
            default:
                return nil
            }
        }
        if let unreachablePath = unreachableBucketPath(rule, nestedPath: path) {
            return try invalid(
                unreachablePath,
                "Bucket threshold depends on a Codex granted by its own completion."
            )
        }
    }

    private static func validateProgressComponent(
        _ component: ProgressionProgressComponent,
        path: String,
        statistics: [StatisticID: ProgressionStatisticDefinition],
        content: [ProgressionContentID: ProgressionContentDefinition],
        grantableContent: Set<ProgressionContentID>,
        achievements: Set<AchievementID>
    ) throws {
        switch component.type {
        case .achievement:
            guard let achievementID = component.achievementID,
                  achievements.contains(achievementID),
                  component.statisticID == nil, component.target == nil,
                  component.bucketID == nil, component.contentIDs == nil,
                  component.minimumBuckets == nil, component.minimumValuePerBucket == nil,
                  component.contentID == nil
            else { return try invalid(path, "Invalid achievement component shape.") }
        case .ownership:
            guard let contentID = component.contentID,
                  content[contentID] != nil,
                  grantableContent.contains(contentID),
                  component.statisticID == nil, component.target == nil,
                  component.bucketID == nil, component.contentIDs == nil,
                  component.minimumBuckets == nil, component.minimumValuePerBucket == nil,
                  component.achievementID == nil
            else { return try invalid(path, "Invalid ownership component shape.") }
        case .statistic:
            guard let statisticID = component.statisticID,
                  let statistic = statistics[statisticID],
                  let target = component.target,
                  component.contentIDs == nil, component.minimumBuckets == nil,
                  component.minimumValuePerBucket == nil, component.achievementID == nil,
                  component.contentID == nil
            else { return try invalid(path, "Invalid statistic component shape.") }
            try Support.requireThreshold(target, path: "\(path).target")
            if let maximum = maximumCardinality(
                for: statistic,
                content: content,
                grantableContent: grantableContent,
                achievements: achievements
            ), target > maximum {
                return try invalid(path, "Statistic target exceeds its finite domain.")
            }
            guard (statistic.storage == .bucketedDistinctSet) == (component.bucketID != nil) else {
                return try invalid(path, "Statistic component bucket mismatch.")
            }
        case .allContentUsed:
            guard let statisticID = component.statisticID,
                  statistics[statisticID]?.storage == .bucketedDistinctSet,
                  let bucketID = component.bucketID,
                  let bucketContentID = ProgressionContentID(rawValue: bucketID.rawValue),
                  content[bucketContentID]?.kind == .codex,
                  let contentIDs = component.contentIDs,
                  !contentIDs.isEmpty, contentIDs.count <= 16,
                  component.target == nil, component.minimumBuckets == nil,
                  component.minimumValuePerBucket == nil, component.achievementID == nil,
                  component.contentID == nil
            else { return try invalid(path, "Invalid all-content-used component shape.") }
            try Support.requireUnique(contentIDs, kind: "component contentID", describe: \.rawValue)
            for contentID in contentIDs {
                guard let item = content[contentID],
                      item.kind == .relic,
                      item.codexID == bucketID,
                      grantableContent.contains(contentID)
                else {
                    throw ProgressionCatalogValidationError.unknownReference(
                        path: "\(path).contentIDs",
                        identifier: contentID.rawValue
                    )
                }
            }
        case .bucketThreshold:
            guard let statisticID = component.statisticID,
                  statistics[statisticID]?.storage == .bucketedDistinctSet,
                  let minimumBuckets = component.minimumBuckets,
                  let minimumValue = component.minimumValuePerBucket,
                  minimumBuckets > 0,
                  minimumBuckets <= UInt16(
                      clamping: content.values.filter { $0.kind == .codex }.count
                  ),
                  component.target == nil, component.bucketID == nil,
                  component.contentIDs == nil, component.achievementID == nil,
                  component.contentID == nil
            else { return try invalid(path, "Invalid bucket-threshold component shape.") }
            try Support.requireThreshold(minimumValue, path: "\(path).minimumValuePerBucket")
            if let statistic = statistics[statisticID],
               let maximum = maximumCardinality(
                   for: statistic,
                   content: content,
                   grantableContent: grantableContent,
                   achievements: achievements
               ), minimumValue > maximum {
                return try invalid(path, "Bucket target exceeds its finite domain.")
            }
        }
    }

    private static func maximumCardinality(
        for statistic: ProgressionStatisticDefinition,
        content: [ProgressionContentID: ProgressionContentDefinition],
        grantableContent: Set<ProgressionContentID>,
        achievements: Set<AchievementID>
    ) -> UInt32? {
        let count: Int
        switch statistic.dimension {
        case .achievementID:
            count = achievements.count
        case .artifactID:
            switch statistic.filter {
            case "owned relic IDs only":
                count = content.filter {
                    $0.value.kind == .relic && grantableContent.contains($0.key)
                }.count
            case "owned seal IDs only":
                count = content.filter {
                    $0.value.kind == .seal && grantableContent.contains($0.key)
                }.count
            default:
                count = content.values.filter(\.countsAsArtifact).count
            }
        case .codexID:
            if statistic.filter == "Codex unowned at first observation" {
                count = content.values.filter {
                    $0.kind == .codex && $0.availability != .included
                }.count
            } else {
                count = content.filter {
                    $0.value.kind == .codex && grantableContent.contains($0.key)
                }.count
            }
        case .contentID:
            count = statistic.filter == "countsAsArtifact=true"
                ? content.filter {
                    $0.value.countsAsArtifact && grantableContent.contains($0.key)
                }.count
                : content.count
        case .cipherToken, .messageToken, .packageToken, .relationshipToken:
            return nil
        }
        return UInt32(clamping: count)
    }

    private static func validateAllContentProgressMirrorsRule(
        _ milestone: ProgressionMilestoneDefinition,
        path: String
    ) throws {
        var ruleSignatures = [String]()
        collectAllContentRuleSignatures(milestone.rule, into: &ruleSignatures)
        let componentSignatures: [String] = milestone.progressComponents.compactMap {
            component -> String? in
            guard component.type == .allContentUsed,
                  let statisticID = component.statisticID,
                  let bucketID = component.bucketID,
                  let contentIDs = component.contentIDs
            else { return nil }
            return allContentSignature(
                statisticID: statisticID,
                bucketID: bucketID,
                contentIDs: contentIDs
            )
        }
        guard ruleSignatures.sorted() == componentSignatures.sorted() else {
            return try invalid(
                "\(path).progressComponents",
                "All-content-used progress must mirror the evaluated rule."
            )
        }
    }

    private static func collectAllContentRuleSignatures(
        _ rule: ProgressionRule,
        into signatures: inout [String]
    ) {
        switch rule {
        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            signatures.append(allContentSignature(
                statisticID: statisticID,
                bucketID: bucketID,
                contentIDs: contentIDs
            ))
        case let .all(conditions), let .any(conditions):
            for condition in conditions {
                collectAllContentRuleSignatures(condition, into: &signatures)
            }
        default:
            break
        }
    }

    private static func allContentSignature(
        statisticID: StatisticID,
        bucketID: CodexID,
        contentIDs: [ProgressionContentID]
    ) -> String {
        "\(statisticID.rawValue)|\(bucketID.rawValue)|"
            + contentIDs.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func validateGrantGroups(_ catalog: ProgressionCatalog) throws {
        try Support.requireCount(catalog.grantGroups, 45, name: "grant groups")
        try Support.requireUnique(
            catalog.grantGroups.map(\.grantGroupID),
            kind: "grantGroupID",
            describe: \.rawValue
        )
        let contentIDs = Set(catalog.content.map(\.contentID))
        var granted = [ProgressionContentID]()
        for (index, group) in catalog.grantGroups.enumerated() {
            let path = "$catalog.grantGroups[\(index)]"
            guard !group.items.isEmpty, group.items.count <= 8 else {
                return try invalid("\(path).items", "Grant groups contain 1...8 items.")
            }
            try Support.requireUnique(
                group.items.map(\.contentID),
                kind: "grant item contentID",
                describe: \.rawValue
            )
            let itemIDs = Set(group.items.map(\.contentID))
            guard itemIDs.contains(group.primaryContentID) else {
                return try invalid("\(path).primaryContentID", "Primary content must be granted.")
            }
            for item in group.items {
                try Support.requireReference(
                    item.contentID,
                    in: contentIDs,
                    path: "\(path).items",
                    describe: \.rawValue
                )
                granted.append(item.contentID)
            }
            if let notes = group.notes { try Support.requireText(notes, path: "\(path).notes") }
        }
        try Support.requireCount(granted, 85, name: "grant items")
        guard Set(granted) == contentIDs else {
            return try invalid("$catalog.grantGroups", "Every v3 content item must be granted.")
        }
        let duplicates = Dictionary(grouping: granted, by: { $0 }).filter { $0.value.count > 1 }
        let yggdrasil = ProgressionContentID(rawValue: "seal.norse.yggdrasil")!
        guard duplicates.count == 1, duplicates[yggdrasil]?.count == 2 else {
            return try invalid(
                "$catalog.grantGroups",
                "Yggdrasil must be the sole duplicated grant item and have exactly two routes."
            )
        }

        let expectedTiers: [ProgressionCatalogRevealTier: Int] = [
            .none: 1, .micro: 20, .artifact: 15, .codex: 4, .mastery: 5,
        ]
        let tiers = Dictionary(grouping: catalog.grantGroups, by: \.revealTier).mapValues(\.count)
        guard tiers == expectedTiers else {
            return try invalid("$catalog.grantGroups", "Grant reveal tier inventory mismatch.")
        }
        guard let base = catalog.grantGroups.first(where: {
            $0.grantGroupID.rawValue == "grant-group.base.norse.included"
        }), base.revealTier == .none, base.items.count == 6
        else {
            return try invalid("$catalog.grantGroups", "Base Norse grant is invalid.")
        }
        try validateNorseV2GrantGroups(catalog)
        try validateElvenMasteryGrantGroups(catalog)
        let includedContent = Set(
            catalog.content.filter { $0.availability == .included }.map(\.contentID)
        )
        guard includedContent.isSubset(of: Set(base.items.map(\.contentID))) else {
            return try invalid(
                "$catalog.content.availability",
                "Included content must be present in the starting grant group."
            )
        }

        let knownGroups = Set(catalog.grantGroups.map(\.grantGroupID))
        var referenceCounts: [GrantGroupID: Int] = [:]
        for achievement in catalog.achievements {
            try Support.requireReference(
                achievement.rewardGrantGroupID,
                in: knownGroups,
                path: "$catalog.achievements.rewardGrantGroupID",
                describe: \.rawValue
            )
            referenceCounts[achievement.rewardGrantGroupID, default: 0] += 1
        }
        for milestone in catalog.milestones {
            try Support.requireReference(
                milestone.grantGroupID,
                in: knownGroups,
                path: "$catalog.milestones.grantGroupID",
                describe: \.rawValue
            )
            guard catalog.grantGroup(id: milestone.grantGroupID)?.revealTier ==
                    milestone.revealTier
            else {
                return try invalid(
                    "$catalog.milestones.revealTier",
                    "Milestone and grant-group reveal tiers must match."
                )
            }
            referenceCounts[milestone.grantGroupID, default: 0] += 1
        }
        for group in catalog.grantGroups {
            let expected = if group.grantGroupID.rawValue == "grant-group.base.norse.included" {
                0
            } else if group.grantGroupID.rawValue == "grant-group.codex.moonleaf.unlock" {
                2
            } else {
                1
            }
            guard referenceCounts[group.grantGroupID, default: 0] == expected else {
                return try invalid(
                    "$catalog.grantGroups",
                    "Grant completion-source cardinality is invalid."
                )
            }
        }
    }

    private static func validateElvenMasteryGrantGroups(
        _ catalog: ProgressionCatalog
    ) throws {
        let expected: [String: [String]] = [
            "grant-group.codex.gloamthorn.mastery": [
                "frame.gloamthorn.briar-court",
                "crest.gloamthorn.gloam-sovereign",
                "title.gloamthorn.mastery",
            ],
            "grant-group.codex.moonleaf.mastery": [
                "frame.moonleaf.silvervine",
                "crest.moonleaf.moonbloom",
                "title.moonleaf.mastery",
            ],
            "grant-group.codex.sunspire.mastery": [
                "frame.sunspire.laurel-of-dawn",
                "crest.sunspire.first-light",
                "title.sunspire.mastery",
            ],
            "grant-group.codex.wildwood.mastery": [
                "frame.wildwood.living-root",
                "crest.wildwood.heartwood-crown",
                "title.wildwood.mastery",
            ],
        ]
        for (grantGroupID, items) in expected {
            guard let id = GrantGroupID(rawValue: grantGroupID),
                  let group = catalog.grantGroup(id: id),
                  group.items.map({ $0.contentID.rawValue }) == items,
                  group.items.allSatisfy({ $0.grantKind == .permanent }),
                  group.revealTier == .mastery,
                  group.primaryContentID.rawValue == items[1]
            else {
                return try invalid(
                    "$catalog.grantGroups.\(grantGroupID)",
                    "Elven mastery reward route is invalid."
                )
            }
        }
    }

    private static func validateNorseV2GrantGroups(_ catalog: ProgressionCatalog) throws {
        struct Expected {
            let items: [String]
            let primary: String
            let tier: ProgressionCatalogRevealTier
        }
        let expected: [String: Expected] = [
            "grant-group.base.norse.included": .init(
                items: [
                    "unlock.codex.norse", "codex.norse", "script.base-runes",
                    "relic.norse.runestone-tablet", "seal.norse.valknut",
                    "seal.norse.ravenshield",
                ],
                primary: "codex.norse", tier: .none
            ),
            "grant-group.first-inscription": .init(
                items: ["seal.norse.mjolnir"],
                primary: "seal.norse.mjolnir", tier: .micro
            ),
            "grant-group.first-dispatch": .init(
                items: ["relic.norse.dragonwood-plaque"],
                primary: "relic.norse.dragonwood-plaque", tier: .artifact
            ),
            "grant-group.correspondent": .init(
                items: ["seal.norse.wolkin"],
                primary: "seal.norse.wolkin", tier: .micro
            ),
            "grant-group.courier-1": .init(
                items: ["seal.norse.yggdrasil"],
                primary: "seal.norse.yggdrasil", tier: .micro
            ),
            "grant-group.courier-2": .init(
                items: ["relic.norse.stormforged-stele"],
                primary: "relic.norse.stormforged-stele", tier: .artifact
            ),
            "grant-group.archivist-1": .init(
                items: ["frame.norse.carved-knotwork"],
                primary: "frame.norse.carved-knotwork", tier: .artifact
            ),
            "grant-group.archivist-2": .init(
                items: ["title.archivist", "seal.norse.berserk"],
                primary: "title.archivist", tier: .artifact
            ),
            "grant-group.codex.norse.echo-five": .init(
                items: ["seal.norse.yggdrasil"],
                primary: "seal.norse.yggdrasil", tier: .micro
            ),
            "grant-group.codex.norse.mastery": .init(
                items: ["crest.norse.raven-mastery", "title.norse.master-of-runes"],
                primary: "crest.norse.raven-mastery", tier: .mastery
            ),
        ]
        for (groupID, value) in expected {
            guard let id = GrantGroupID(rawValue: groupID),
                  let group = catalog.grantGroup(id: id),
                  group.items.map({ $0.contentID.rawValue }) == value.items,
                  group.items.allSatisfy({ $0.grantKind == .permanent }),
                  group.primaryContentID.rawValue == value.primary,
                  group.revealTier == value.tier
            else {
                return try invalid(
                    "$catalog.grantGroups.\(groupID)",
                    "Norse v2 reward route is invalid."
                )
            }
        }
        guard catalog.grantGroup(id: GrantGroupID(
            rawValue: "grant-group.codex.norse.echo-five"
        )!)?.notes?.contains("Idempotent second route to Yggdrasil Seal") == true else {
            return try invalid(
                "$catalog.grantGroups.grant-group.codex.norse.echo-five.notes",
                "The idempotent Echo route must be documented."
            )
        }
    }

    private static func validateJourney(_ catalog: ProgressionCatalog) throws {
        let graph = catalog.journeyGraph
        try Support.requireCount(graph.nodes, 5, name: "journey nodes")
        try Support.requireCount(graph.edges, 4, name: "journey edges")
        try Support.requireUnique(graph.nodes.map(\.nodeID), kind: "journey nodeID", describe: \.rawValue)
        try Support.requireUnique(
            graph.nodes.map(\.contentID),
            kind: "journey contentID",
            describe: \.rawValue
        )
        try Support.requireUnique(graph.nodes.map(\.order), kind: "journey order", describe: String.init)
        guard Set(graph.nodes.map(\.order)) == Set(UInt16(0) ... UInt16(4)) else {
            return try invalid("$catalog.journeyGraph.nodes", "Journey order must be 0...4.")
        }
        let nodeIDs = Set(graph.nodes.map(\.nodeID))
        let ruleIDs = Set(catalog.milestones.map(\.ruleID))
        let content = Dictionary(uniqueKeysWithValues: catalog.content.map { ($0.contentID, $0) })
        for node in graph.nodes {
            guard content[node.contentID]?.kind == .codex else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "$catalog.journeyGraph.nodes.contentID",
                    identifier: node.contentID.rawValue
                )
            }
            switch node.state {
            case .included:
                guard node.order == 0, node.gateRuleID == nil else {
                    return try invalid("$catalog.journeyGraph.nodes", "Included node shape is invalid.")
                }
            case .earned:
                guard let gate = node.gateRuleID, ruleIDs.contains(gate) else {
                    return try invalid("$catalog.journeyGraph.nodes", "Earned node requires a gate.")
                }
            }
        }
        try Support.requireUnique(
            graph.edges.map { "\($0.from.rawValue)->\($0.to.rawValue)" },
            kind: "journey edge",
            describe: { $0 }
        )
        for edge in graph.edges {
            try Support.requireReference(edge.from, in: nodeIDs, path: "$catalog.journeyGraph.edges.from", describe: \.rawValue)
            try Support.requireReference(edge.to, in: nodeIDs, path: "$catalog.journeyGraph.edges.to", describe: \.rawValue)
            guard edge.from != edge.to else {
                throw ProgressionCatalogValidationError.dependencyCycle([edge.from.rawValue])
            }
        }
        let ordered = catalog.orderedJourneyNodes
        let expectedEdges = Set(zip(ordered, ordered.dropFirst()).map {
            "\($0.0.nodeID.rawValue)->\($0.1.nodeID.rawValue)"
        })
        let actualEdges = Set(graph.edges.map { "\($0.from.rawValue)->\($0.to.rawValue)" })
        guard expectedEdges == actualEdges else {
            return try invalid("$catalog.journeyGraph.edges", "Journey must be one ordered chain.")
        }
    }

    private static func validateRevealPolicy(_ catalog: ProgressionCatalog) throws {
        let policy = catalog.revealPolicy
        try Support.requireCount(policy.settings, 3, name: "reveal settings")
        try Support.requireCount(policy.tiers, 4, name: "reveal tiers")
        try Support.requireUnique(policy.settings.map(\.settingID), kind: "reveal settingID", describe: \.rawValue)
        try Support.requireUnique(policy.tiers.map(\.tier), kind: "reveal tier", describe: \.rawValue)
        let expectedSettings = Set([
            "setting.unlock-feedback.sound-enabled",
            "setting.unlock-feedback.haptics-enabled",
            "setting.unlock-feedback.animation-enabled",
        ])
        guard Set(policy.settings.map { $0.settingID.rawValue }) == expectedSettings,
              policy.settings.allSatisfy({ $0.type == .bool && $0.default && $0.owner == .forsettiRuntime })
        else {
            return try invalid("$catalog.revealPolicy.settings", "Reveal settings are invalid.")
        }
        let expectedTiers: Set<ProgressionCatalogRevealTier> = [.micro, .artifact, .codex, .mastery]
        guard Set(policy.tiers.map(\.tier)) == expectedTiers else {
            return try invalid("$catalog.revealPolicy.tiers", "Reveal tier vocabulary is invalid.")
        }
        for (index, tier) in policy.tiers.enumerated() {
            guard tier.durationSeconds.count == 2,
                  tier.durationSeconds.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 10 }),
                  tier.durationSeconds[0] <= tier.durationSeconds[1]
            else {
                return try invalid(
                    "$catalog.revealPolicy.tiers[\(index)].durationSeconds",
                    "Duration must be a finite ascending two-value range."
                )
            }
            try Support.requireText(tier.visual, path: "$catalog.revealPolicy.tiers[\(index)].visual")
        }
        try Support.requireText(policy.combineRule, path: "$catalog.revealPolicy.combineRule")
        let expectedConditions = Set([
            "application-unlocked", "root-ui-active", "no-system-share-sheet",
            "no-message-composer", "no-file-importer", "no-qr-camera",
            "no-import-confirmation", "no-received-message-decode",
            "no-security-warning-or-pin-flow",
        ])
        try Support.requireUnique(
            policy.safePresentationConditions,
            kind: "safe presentation condition",
            describe: { $0 }
        )
        guard Set(policy.safePresentationConditions) == expectedConditions else {
            return try invalid(
                "$catalog.revealPolicy.safePresentationConditions",
                "Safe presentation conditions are incomplete."
            )
        }
        try Support.requireText(policy.accessibility.reduceMotion, path: "$catalog.revealPolicy.accessibility.reduceMotion")
        try Support.requireText(policy.accessibility.voiceOver, path: "$catalog.revealPolicy.accessibility.voiceOver")
        try Support.requireText(policy.accessibility.silentMode, path: "$catalog.revealPolicy.accessibility.silentMode")
        try Support.requireText(policy.accessibility.dismissal, path: "$catalog.revealPolicy.accessibility.dismissal")
    }

    private static func validatePolicies(_ catalog: ProgressionCatalog) throws {
        let gameCenter = catalog.gameCenterPolicy
        guard !gameCenter.implementationInScope,
              gameCenter.localCatalogPointTotal == 220,
              gameCenter.achievementCount == 15,
              !gameCenter.permanentIdentifiersFrozen
        else { return try invalid("$catalog.gameCenterPolicy", "Game Center policy is invalid.") }
        try Support.requireText(gameCenter.direction, path: "$catalog.gameCenterPolicy.direction")

        let migration = catalog.migration
        guard migration.migrationVersion == 1,
              migration.startingGrantGroupID.rawValue == "grant-group.base.norse.included",
              migration.seedSafelyDerivableCipherStatistics,
              migration.evaluateArchivistAchievementsAfterSafeSeed,
              !migration.backfillPastShares,
              !migration.backfillPastDecodes,
              !migration.backfillDistinctRelationshipsFromDeliveredFlags,
              migration.includedGrantReveal == .suppressed,
              migration.derivedMigrationRewardsReveal == .oneCombinedReveal
        else { return try invalid("$catalog.migration", "Migration policy is invalid.") }
    }

    private static func validateCompletionText(
        name: String,
        description: String,
        path: String
    ) throws {
        try Support.requireText(name, path: "\(path).displayName", maximumBytes: 256)
        try Support.requireText(description, path: "\(path).description")
    }

    private static func exactUniqueSet<T: Hashable>(
        _ actual: [T],
        expected: Set<T>,
        path: String
    ) throws {
        guard actual.count == expected.count, Set(actual) == expected else {
            return try invalid(path, "Vocabulary inventory mismatch.")
        }
    }

    private static func invalid<T>(_ path: String, _ reason: String) throws -> T {
        throw ProgressionCatalogValidationError.invalidValue(path: path, reason: reason)
    }
}
