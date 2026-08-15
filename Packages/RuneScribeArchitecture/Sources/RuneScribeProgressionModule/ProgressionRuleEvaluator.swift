import Foundation
import RuneScribeContracts

struct ProgressionRuleFacts: Sendable {
    let counters: [String: UInt64]
    let distinctValues: [String: Set<String>]
    let ownedContentIDs: Set<ProgressionContentID>
    let completedAchievementIDs: Set<AchievementID>

    init(
        counters: [String: UInt64],
        distinctValues: [String: Set<String>],
        ownedContentIDs: Set<ProgressionContentID>,
        completedAchievementIDs: Set<AchievementID>
    ) {
        self.counters = counters
        self.distinctValues = distinctValues
        self.ownedContentIDs = ownedContentIDs
        self.completedAchievementIDs = completedAchievementIDs
    }

    init(projection: ProgressionProjection) {
        var counters: [String: UInt64] = [:]
        var distinctValues: [String: Set<String>] = [:]
        var ownedContentIDs = Set<ProgressionContentID>()
        var completedAchievementIDs = Set<AchievementID>()
        for record in projection.logicalRecords() {
            switch record {
            case let .statisticCounter(value):
                counters[Self.counterKey(value.statisticID, value.bucketID)] = value.value
            case let .statisticContentUse(value):
                distinctValues[
                    Self.counterKey(value.statisticID, value.bucketID),
                    default: []
                ].formUnion(value.contentIDs.map(\.rawValue))
            case let .ownership(value):
                ownedContentIDs.insert(value.contentID)
            case let .achievementCompletion(value):
                completedAchievementIDs.insert(value.achievementID)
            default:
                break
            }
        }

        self.counters = counters
        self.distinctValues = distinctValues
        self.ownedContentIDs = ownedContentIDs
        self.completedAchievementIDs = completedAchievementIDs
    }

    static func counterKey(_ statisticID: StatisticID, _ bucketID: CodexID?) -> String {
        "\(statisticID.rawValue)|\(bucketID?.rawValue ?? "-")"
    }
}

struct ProgressionRuleEvaluation: Equatable, Sendable {
    let isSatisfied: Bool
    let current: UInt64
    let target: UInt64
    let completedComponentCount: UInt16
    let requiredComponentCount: UInt16
}

enum ProgressionRuleEvaluator {
    static func evaluate(
        _ rule: ProgressionRule,
        facts: ProgressionRuleFacts
    ) -> ProgressionRuleEvaluation {
        switch rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            let target = UInt64(threshold)
            let value = facts.counters[
                ProgressionRuleFacts.counterKey(statisticID, bucketID),
                default: 0
            ]
            return leaf(current: min(value, target), target: target)

        case let .contentOwned(contentID):
            return booleanLeaf(facts.ownedContentIDs.contains(contentID))

        case let .achievementCompleted(achievementID):
            return booleanLeaf(facts.completedAchievementIDs.contains(achievementID))

        case let .completedAchievementCountAtLeast(threshold, excluding):
            let excluded = Set(excluding)
            let count = facts.completedAchievementIDs.subtracting(excluded).count
            return leaf(
                current: min(UInt64(count), UInt64(threshold)),
                target: UInt64(threshold)
            )

        case let .all(conditions):
            let evaluations = conditions.map { evaluate($0, facts: facts) }
            let current = evaluations.reduce(UInt64(0)) {
                saturatedAdd($0, $1.current)
            }
            let target = evaluations.reduce(UInt64(0)) {
                saturatedAdd($0, $1.target)
            }
            let completed = evaluations.reduce(UInt32(0)) {
                min(UInt32(UInt16.max), $0 + UInt32($1.completedComponentCount))
            }
            let required = evaluations.reduce(UInt32(0)) {
                min(UInt32(UInt16.max), $0 + UInt32($1.requiredComponentCount))
            }
            return ProgressionRuleEvaluation(
                isSatisfied: !evaluations.isEmpty && evaluations.allSatisfy(\.isSatisfied),
                current: min(current, max(target, 1)),
                target: max(target, 1),
                completedComponentCount: UInt16(completed),
                requiredComponentCount: max(UInt16(required), 1)
            )

        case let .any(conditions):
            let evaluations = conditions.map { evaluate($0, facts: facts) }
            let satisfied = evaluations.contains(where: \.isSatisfied)
            return ProgressionRuleEvaluation(
                isSatisfied: satisfied,
                current: satisfied ? 1 : 0,
                target: 1,
                completedComponentCount: satisfied ? 1 : 0,
                requiredComponentCount: 1
            )

        case let .bucketCountAtLeast(statisticID, minimumBuckets, minimumValuePerBucket):
            let prefix = "\(statisticID.rawValue)|"
            let bucketCount = facts.counters.reduce(into: 0) { count, item in
                if item.key.hasPrefix(prefix),
                   !item.key.hasSuffix("|-"),
                   item.value >= UInt64(minimumValuePerBucket)
                {
                    count += 1
                }
            }
            return leaf(
                current: min(UInt64(bucketCount), UInt64(minimumBuckets)),
                target: UInt64(minimumBuckets)
            )

        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            let values = facts.distinctValues[
                ProgressionRuleFacts.counterKey(statisticID, bucketID),
                default: []
            ]
            let completed = contentIDs.reduce(into: 0) { count, contentID in
                if values.contains(contentID.rawValue) { count += 1 }
            }
            return leaf(
                current: UInt64(completed),
                target: UInt64(contentIDs.count)
            )
        }
    }

    private static func booleanLeaf(_ value: Bool) -> ProgressionRuleEvaluation {
        leaf(current: value ? 1 : 0, target: 1)
    }

    private static func leaf(current: UInt64, target: UInt64) -> ProgressionRuleEvaluation {
        let validTarget = max(target, 1)
        let boundedCurrent = min(current, validTarget)
        return ProgressionRuleEvaluation(
            isSatisfied: boundedCurrent == validTarget,
            current: boundedCurrent,
            target: validTarget,
            completedComponentCount: boundedCurrent == validTarget ? 1 : 0,
            requiredComponentCount: 1
        )
    }

    private static func saturatedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }
}
