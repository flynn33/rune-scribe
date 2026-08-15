import Foundation

enum StrictJSONStructure {
    static func parseObject(
        _ data: Data,
        resource: String,
        maximumBytes: Int
    ) throws -> [String: Any] {
        guard data.count <= maximumBytes else {
            throw ProgressionCatalogValidationError.inputTooLarge(
                resource: resource,
                maximumBytes: maximumBytes,
                actualBytes: data.count
            )
        }

        var scanner = JSONDuplicateKeyScanner(data: data)
        try scanner.validate()

        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ProgressionCatalogValidationError.invalidJSON(path: "$\(resource)")
        }
        guard let object = value as? [String: Any] else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: "$\(resource)",
                reason: "Expected an object root."
            )
        }
        return object
    }

    static func validateCatalog(_ root: [String: Any]) throws {
        try keys(
            root,
            required: [
                "schemaVersion", "catalogID", "catalogVersion", "packageVersion",
                "status", "effectiveDate", "governingObjective", "principles",
                "content", "statistics", "achievements", "milestones",
                "grantGroups", "journeyGraph", "revealPolicy", "gameCenterPolicy",
                "migration", "deferred",
            ],
            path: "$catalog"
        )

        for (index, value) in try array(root["content"], path: "$catalog.content").enumerated() {
            try keys(
                try object(value, path: "$catalog.content[\(index)]"),
                required: [
                    "contentID", "kind", "displayName", "countsAsArtifact",
                    "availability", "rarity",
                ],
                optional: ["codexID", "notes"],
                path: "$catalog.content[\(index)]"
            )
        }

        for (index, value) in try array(
            root["statistics"],
            path: "$catalog.statistics"
        ).enumerated() {
            try keys(
                try object(value, path: "$catalog.statistics[\(index)]"),
                required: [
                    "statisticID", "displayName", "storage", "dimension", "sourceEvents",
                ],
                optional: ["bucket", "filter"],
                path: "$catalog.statistics[\(index)]"
            )
        }

        for (index, value) in try array(
            root["achievements"],
            path: "$catalog.achievements"
        ).enumerated() {
            let path = "$catalog.achievements[\(index)]"
            let achievement = try object(value, path: path)
            try keys(
                achievement,
                required: [
                    "achievementID", "displayName", "description", "path", "evergreen",
                    "visibility", "localPointWeight", "gameCenter", "rule", "progress",
                    "rewardGrantGroupID", "fallbackSystemImage",
                ],
                path: path
            )
            try keys(
                try object(achievement["gameCenter"], path: "\(path).gameCenter"),
                required: ["eligible", "status", "permanentIdentifier", "points"],
                path: "\(path).gameCenter"
            )
            try validateRule(achievement["rule"], path: "\(path).rule")
            try keys(
                try object(achievement["progress"], path: "\(path).progress"),
                required: ["statisticID", "target"],
                optional: ["excludeAchievementIDs"],
                path: "\(path).progress"
            )
        }

        for (index, value) in try array(
            root["milestones"],
            path: "$catalog.milestones"
        ).enumerated() {
            let path = "$catalog.milestones[\(index)]"
            let milestone = try object(value, path: path)
            try keys(
                milestone,
                required: [
                    "ruleID", "displayName", "description", "visibility", "category",
                    "rule", "grantGroupID", "revealTier", "progressComponents",
                ],
                path: path
            )
            try validateRule(milestone["rule"], path: "\(path).rule")
            for (componentIndex, componentValue) in try array(
                milestone["progressComponents"],
                path: "\(path).progressComponents"
            ).enumerated() {
                try validateProgressComponent(
                    componentValue,
                    path: "\(path).progressComponents[\(componentIndex)]"
                )
            }
        }

        for (index, value) in try array(
            root["grantGroups"],
            path: "$catalog.grantGroups"
        ).enumerated() {
            let path = "$catalog.grantGroups[\(index)]"
            let group = try object(value, path: path)
            try keys(
                group,
                required: ["grantGroupID", "items", "revealTier", "primaryContentID"],
                optional: ["notes"],
                path: path
            )
            for (itemIndex, itemValue) in try array(
                group["items"],
                path: "\(path).items"
            ).enumerated() {
                try keys(
                    try object(itemValue, path: "\(path).items[\(itemIndex)]"),
                    required: ["contentID", "grantKind"],
                    path: "\(path).items[\(itemIndex)]"
                )
            }
        }

        let journey = try object(root["journeyGraph"], path: "$catalog.journeyGraph")
        try keys(journey, required: ["nodes", "edges"], path: "$catalog.journeyGraph")
        for (index, value) in try array(
            journey["nodes"],
            path: "$catalog.journeyGraph.nodes"
        ).enumerated() {
            try keys(
                try object(value, path: "$catalog.journeyGraph.nodes[\(index)]"),
                required: ["nodeID", "contentID", "state", "gateRuleID", "order"],
                path: "$catalog.journeyGraph.nodes[\(index)]"
            )
        }
        for (index, value) in try array(
            journey["edges"],
            path: "$catalog.journeyGraph.edges"
        ).enumerated() {
            try keys(
                try object(value, path: "$catalog.journeyGraph.edges[\(index)]"),
                required: ["from", "to"],
                path: "$catalog.journeyGraph.edges[\(index)]"
            )
        }

        try validateRevealPolicy(root["revealPolicy"])
        try keys(
            try object(root["gameCenterPolicy"], path: "$catalog.gameCenterPolicy"),
            required: [
                "implementationInScope", "localCatalogPointTotal", "achievementCount",
                "permanentIdentifiersFrozen", "direction",
            ],
            path: "$catalog.gameCenterPolicy"
        )
        try keys(
            try object(root["migration"], path: "$catalog.migration"),
            required: [
                "migrationVersion", "startingGrantGroupID",
                "seedSafelyDerivableCipherStatistics",
                "evaluateArchivistAchievementsAfterSafeSeed", "backfillPastShares",
                "backfillPastDecodes", "backfillDistinctRelationshipsFromDeliveredFlags",
                "includedGrantReveal", "derivedMigrationRewardsReveal",
            ],
            path: "$catalog.migration"
        )
    }

    static func validateEventCatalog(_ root: [String: Any]) throws {
        try keys(
            root,
            required: [
                "schemaVersion", "catalogID", "catalogVersion", "status", "effectiveDate",
                "eventEnvelope", "applyOutcomes", "acknowledgeOutboxOn", "retainOutboxOn",
                "events", "shareRoutePolicy", "forbiddenData", "eligibilityReasonIDs",
            ],
            path: "$events"
        )

        for (index, value) in try array(root["events"], path: "$events.events").enumerated() {
            let path = "$events.events[\(index)]"
            let event = try object(value, path: path)
            try keys(
                event,
                required: [
                    "eventType", "producer", "emissionPoint", "requiredPayload",
                    "semanticDedupe", "updates",
                ],
                optional: ["optionalPayload", "requiredValues", "notes"],
                path: path
            )
            if let requiredValues = event["requiredValues"] {
                let values = try object(requiredValues, path: "\(path).requiredValues")
                guard !values.isEmpty else {
                    throw ProgressionCatalogValidationError.invalidValue(
                        path: "\(path).requiredValues",
                        reason: "Required values cannot be empty."
                    )
                }
                try keys(
                    values,
                    required: [],
                    optional: ["origin", "keyIncluded", "linkedRelationship"],
                    path: "\(path).requiredValues"
                )
            }
        }

        for (index, value) in try array(
            root["shareRoutePolicy"],
            path: "$events.shareRoutePolicy"
        ).enumerated() {
            try keys(
                try object(value, path: "$events.shareRoutePolicy[\(index)]"),
                required: [
                    "routeClass", "terminalResult", "progressionEligible",
                    "firstDeliveryEligible",
                ],
                optional: ["requiresAttachmentAcceptedWhenKeyDelivery", "notes"],
                path: "$events.shareRoutePolicy[\(index)]"
            )
        }
    }

    static func validateFutureThemeBindings(_ root: [String: Any]) throws {
        try keys(
            root,
            required: [
                "schemaVersion", "contractID", "version", "status", "bindings", "rules",
                "supersessions",
            ],
            path: "$bindings"
        )
        for (index, value) in try array(
            root["bindings"],
            path: "$bindings.bindings"
        ).enumerated() {
            try keys(
                try object(value, path: "$bindings.bindings[\(index)]"),
                required: ["codexID", "moduleID", "entitlementID", "criticality"],
                optional: ["gate", "gateRuleID", "fallback", "fallbackCodexID"],
                path: "$bindings.bindings[\(index)]"
            )
        }
        for (index, value) in try array(
            root["supersessions"],
            path: "$bindings.supersessions"
        ).enumerated() {
            try keys(
                try object(value, path: "$bindings.supersessions[\(index)]"),
                required: ["source", "path", "old", "new"],
                path: "$bindings.supersessions[\(index)]"
            )
        }
    }

    private static func validateRule(_ value: Any?, path: String) throws {
        let rule = try object(value, path: path)
        guard let op = rule["op"] as? String else {
            throw ProgressionCatalogValidationError.missingField(path: path, field: "op")
        }
        switch op {
        case "distinctCountAtLeast":
            try keys(
                rule,
                required: ["op", "statisticID", "threshold"],
                optional: ["bucketID"],
                path: path
            )
        case "contentOwned":
            try keys(rule, required: ["op", "contentID"], path: path)
        case "achievementCompleted":
            try keys(rule, required: ["op", "achievementID"], path: path)
        case "completedAchievementCountAtLeast":
            try keys(
                rule,
                required: ["op", "threshold", "excludeAchievementIDs"],
                path: path
            )
        case "all", "any":
            try keys(rule, required: ["op", "conditions"], path: path)
            for (index, condition) in try array(
                rule["conditions"],
                path: "\(path).conditions"
            ).enumerated() {
                try validateRule(condition, path: "\(path).conditions[\(index)]")
            }
        case "bucketCountAtLeast":
            try keys(
                rule,
                required: [
                    "op", "statisticID", "minimumBuckets", "minimumValuePerBucket",
                ],
                path: path
            )
        case "allListedContentUsed":
            try keys(
                rule,
                required: ["op", "statisticID", "bucketID", "contentIDs"],
                path: path
            )
        default:
            throw ProgressionCatalogValidationError.invalidValue(
                path: "\(path).op",
                reason: "Unknown rule operator \(op)."
            )
        }
    }

    private static func validateProgressComponent(_ value: Any, path: String) throws {
        let component = try object(value, path: path)
        guard let type = component["type"] as? String else {
            throw ProgressionCatalogValidationError.missingField(path: path, field: "type")
        }
        switch type {
        case "achievement":
            try keys(component, required: ["type", "achievementID"], path: path)
        case "ownership":
            try keys(component, required: ["type", "contentID"], path: path)
        case "statistic":
            try keys(
                component,
                required: ["type", "statisticID", "target"],
                optional: ["bucketID"],
                path: path
            )
        case "all-content-used":
            try keys(
                component,
                required: ["type", "statisticID", "bucketID", "contentIDs"],
                path: path
            )
        case "bucket-threshold":
            try keys(
                component,
                required: [
                    "type", "statisticID", "minimumBuckets", "minimumValuePerBucket",
                ],
                path: path
            )
        default:
            throw ProgressionCatalogValidationError.invalidValue(
                path: "\(path).type",
                reason: "Unknown progress component type \(type)."
            )
        }
    }

    private static func validateRevealPolicy(_ value: Any?) throws {
        let path = "$catalog.revealPolicy"
        let policy = try object(value, path: path)
        try keys(
            policy,
            required: [
                "settings", "combineRule", "safePresentationConditions", "tiers",
                "accessibility",
            ],
            path: path
        )
        for (index, setting) in try array(
            policy["settings"],
            path: "\(path).settings"
        ).enumerated() {
            try keys(
                try object(setting, path: "\(path).settings[\(index)]"),
                required: ["settingID", "type", "default", "owner"],
                path: "\(path).settings[\(index)]"
            )
        }
        for (index, tier) in try array(policy["tiers"], path: "\(path).tiers").enumerated() {
            try keys(
                try object(tier, path: "\(path).tiers[\(index)]"),
                required: [
                    "tier", "durationSeconds", "visual", "soundSemanticID",
                    "genericFallbackResourceID", "haptic",
                ],
                path: "\(path).tiers[\(index)]"
            )
        }
        try keys(
            try object(policy["accessibility"], path: "\(path).accessibility"),
            required: ["reduceMotion", "voiceOver", "silentMode", "dismissal"],
            path: "\(path).accessibility"
        )
    }

    private static func keys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = [],
        path: String
    ) throws {
        let present = Set(object.keys)
        if let missing = required.subtracting(present).sorted().first {
            throw ProgressionCatalogValidationError.missingField(path: path, field: missing)
        }
        if let unknown = present.subtracting(required.union(optional)).sorted().first {
            throw ProgressionCatalogValidationError.unknownField(path: path, field: unknown)
        }
    }

    private static func object(_ value: Any?, path: String) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Expected an object."
            )
        }
        return object
    }

    private static func array(_ value: Any?, path: String) throws -> [Any] {
        guard let array = value as? [Any] else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Expected an array."
            )
        }
        return array
    }
}

private struct JSONDuplicateKeyScanner {
    private let bytes: [UInt8]
    private var index = 0
    private var path: [String] = ["$"]

    init(data: Data) {
        bytes = Array(data)
    }

    mutating func validate() throws {
        skipWhitespace()
        try scanValue()
        skipWhitespace()
        guard index == bytes.count else {
            throw ProgressionCatalogValidationError.invalidJSON(path: path.joined())
        }
    }

    private mutating func scanValue() throws {
        skipWhitespace()
        guard index < bytes.count else { return try invalidJSON() }
        switch bytes[index] {
        case 0x7B: try scanObject()
        case 0x5B: try scanArray()
        case 0x22: _ = try scanString()
        case 0x74: try scanLiteral("true")
        case 0x66: try scanLiteral("false")
        case 0x6E: try scanLiteral("null")
        case 0x2D, 0x30 ... 0x39: try scanNumber()
        default: return try invalidJSON()
        }
    }

    private mutating func scanObject() throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                return try invalidJSON()
            }
            let key = try scanString()
            guard keys.insert(key).inserted else {
                throw ProgressionCatalogValidationError.duplicateJSONKey(
                    path: path.joined(),
                    key: key
                )
            }
            skipWhitespace()
            guard consume(0x3A) else { return try invalidJSON() }
            path.append(".\(key)")
            try scanValue()
            path.removeLast()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { return try invalidJSON() }
            skipWhitespace()
        }
    }

    private mutating func scanArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        var element = 0
        while true {
            path.append("[\(element)]")
            try scanValue()
            path.removeLast()
            element += 1
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { return try invalidJSON() }
            skipWhitespace()
        }
    }

    private mutating func scanString() throws -> String {
        let start = index
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                let data = Data(bytes[start ..< index])
                do {
                    return try JSONDecoder().decode(String.self, from: data)
                } catch {
                    return try invalidJSON()
                }
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { return try invalidJSON() }
                if bytes[index] == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1) ... (index + 4)].allSatisfy(isHex)
                    else { return try invalidJSON() }
                    index += 5
                } else {
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74]
                        .contains(bytes[index])
                    else { return try invalidJSON() }
                    index += 1
                }
            } else {
                guard byte >= 0x20 else { return try invalidJSON() }
                index += 1
            }
        }
        return try invalidJSON()
    }

    private mutating func scanLiteral(_ literal: StaticString) throws {
        let literalBytes = Array(String(describing: literal).utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index ..< index + literalBytes.count]) == literalBytes
        else { return try invalidJSON() }
        index += literalBytes.count
    }

    private mutating func scanNumber() throws {
        let start = index
        if consume(0x2D), index == bytes.count { return try invalidJSON() }
        if consume(0x30) {
            if index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) {
                return try invalidJSON()
            }
        } else {
            guard index < bytes.count, (0x31 ... 0x39).contains(bytes[index]) else {
                return try invalidJSON()
            }
            while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) { index += 1 }
        }
        if consume(0x2E) {
            guard index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) else {
                return try invalidJSON()
            }
            while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) {
                index += 1
            }
            guard index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) else {
                return try invalidJSON()
            }
            while index < bytes.count, (0x30 ... 0x39).contains(bytes[index]) { index += 1 }
        }
        guard index > start else { return try invalidJSON() }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private func isHex(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x46).contains(byte)
            || (0x61 ... 0x66).contains(byte)
    }

    private func invalidJSON<T>() throws -> T {
        throw ProgressionCatalogValidationError.invalidJSON(path: path.joined())
    }
}
