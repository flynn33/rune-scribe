import Foundation
import RuneScribeContracts

public enum ProgressionCatalogDecoder {
    public static func decodeCatalog(_ data: Data) throws -> ProgressionCatalog {
        let root = try StrictJSONStructure.parseObject(
            data,
            resource: "catalog",
            maximumBytes: ProgressionCatalogResourceCatalog.catalogDescriptor.maximumByteCount
        )
        try StrictJSONStructure.validateCatalog(root)
        let catalog: ProgressionCatalog = try decode(data, path: "$catalog")
        try ProgressionCatalogSemanticValidator.validate(catalog)
        return catalog
    }

    public static func decodeEventCatalog(_ data: Data) throws -> ProgressionEventCatalog {
        let root = try StrictJSONStructure.parseObject(
            data,
            resource: "event-catalog",
            maximumBytes: ProgressionCatalogResourceCatalog.eventCatalogDescriptor.maximumByteCount
        )
        try StrictJSONStructure.validateEventCatalog(root)
        let catalog: ProgressionEventCatalog = try decode(data, path: "$events")
        try ProgressionEventCatalogSemanticValidator.validate(catalog)
        return catalog
    }

    public static func decodeFutureThemeBindings(
        _ data: Data
    ) throws -> ProgressionFutureThemeBindingContract {
        let root = try StrictJSONStructure.parseObject(
            data,
            resource: "future-theme-bindings",
            maximumBytes: ProgressionCatalogResourceCatalog
                .futureThemeBindingsDescriptor.maximumByteCount
        )
        try StrictJSONStructure.validateFutureThemeBindings(root)
        let bindings: ProgressionFutureThemeBindingContract = try decode(
            data,
            path: "$bindings"
        )
        try ProgressionThemeBindingSemanticValidator.validate(bindings)
        return bindings
    }

    public static func decodeAndValidateBundle(
        catalogData: Data,
        eventCatalogData: Data,
        futureThemeBindingData: Data,
        integrityMetadata: ProgressionCatalogIntegrityMetadata
    ) throws -> ValidatedProgressionCatalogBundle {
        let catalog = try decodeCatalog(catalogData)
        let eventCatalog = try decodeEventCatalog(eventCatalogData)
        let bindings = try decodeFutureThemeBindings(futureThemeBindingData)
        return try ProgressionCatalogBundleSemanticValidator.validate(
            catalog: catalog,
            eventCatalog: eventCatalog,
            bindings: bindings,
            integrityMetadata: integrityMetadata
        )
    }

    private static func decode<Value: Decodable>(_ data: Data, path: String) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch let error as ProgressionCatalogValidationError {
            throw error
        } catch let error as DecodingError {
            throw ProgressionCatalogValidationError.invalidValue(
                path: decodingPath(error, fallback: path),
                reason: "Typed decoding failed."
            )
        } catch {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Typed decoding failed."
            )
        }
    }

    private static func decodingPath(_ error: DecodingError, fallback: String) -> String {
        let codingPath: [CodingKey]
        switch error {
        case let .dataCorrupted(context), let .keyNotFound(_, context),
             let .typeMismatch(_, context), let .valueNotFound(_, context):
            codingPath = context.codingPath
        @unknown default:
            return fallback
        }
        guard !codingPath.isEmpty else { return fallback }
        return codingPath.reduce("$") { path, key in
            if let index = key.intValue { return "\(path)[\(index)]" }
            return "\(path).\(key.stringValue)"
        }
    }
}

public extension ProgressionCatalog {
    func content(id: ProgressionContentID) -> ProgressionContentDefinition? {
        content.first { $0.contentID == id }
    }

    func statistic(id: StatisticID) -> ProgressionStatisticDefinition? {
        statistics.first { $0.statisticID == id }
    }

    func achievement(id: AchievementID) -> ProgressionAchievementDefinition? {
        achievements.first { $0.achievementID == id }
    }

    func milestone(id: RuleID) -> ProgressionMilestoneDefinition? {
        milestones.first { $0.ruleID == id }
    }

    func grantGroup(id: GrantGroupID) -> ProgressionGrantGroup? {
        grantGroups.first { $0.grantGroupID == id }
    }

    var orderedJourneyNodes: [ProgressionJourneyNode] {
        journeyGraph.nodes.sorted { $0.order < $1.order }
    }

    func revealTier(
        _ tier: ProgressionCatalogRevealTier
    ) -> ProgressionRevealTierDefinition? {
        revealPolicy.tiers.first { $0.tier == tier }
    }
}

public extension ProgressionEventCatalog {
    func event(_ eventType: EventIdentifier) -> ProgressionEventDefinition? {
        events.first { $0.eventType == eventType }
    }
}

enum ProgressionCatalogValidationSupport {
    static let maximumShortTextBytes = 256
    static let maximumLongTextBytes = 2_048
    static let maximumThreshold: UInt32 = 1_000_000

    static func requireCount<T>(
        _ values: [T],
        _ expected: Int,
        name: String
    ) throws {
        guard values.count == expected else {
            throw ProgressionCatalogValidationError.inventoryMismatch(
                name: name,
                expected: expected,
                actual: values.count
            )
        }
    }

    static func requireUnique<T: Hashable>(
        _ values: [T],
        kind: String,
        describe: (T) -> String
    ) throws {
        var seen = Set<T>()
        for value in values where !seen.insert(value).inserted {
            throw ProgressionCatalogValidationError.duplicateIdentifier(
                kind: kind,
                identifier: describe(value)
            )
        }
    }

    static func requireText(
        _ value: String,
        path: String,
        maximumBytes: Int = maximumLongTextBytes
    ) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Text must be nonempty and at most \(maximumBytes) UTF-8 bytes."
            )
        }
    }

    static func requireDate(_ value: String, path: String) throws {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (0x30 ... 0x39).contains(byte)
              })
        else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Expected a YYYY-MM-DD date."
            )
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let year = Int(value.prefix(4)),
              let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)),
              let date = calendar.date(
                  from: DateComponents(year: year, month: month, day: day)
              )
        else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Invalid calendar date."
            )
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year,
              components.month == month,
              components.day == day
        else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Invalid calendar date."
            )
        }
    }

    static func requireIdentifier(_ value: String, path: String) throws {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= 96 else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Identifier length is invalid."
            )
        }
        var previousSeparator = false
        for (index, byte) in bytes.enumerated() {
            let alphanumeric = (0x61 ... 0x7A).contains(byte) || (0x30 ... 0x39).contains(byte)
            if alphanumeric {
                previousSeparator = false
                continue
            }
            let separator = byte == 0x2D || byte == 0x2E
            guard separator, index > 0, index < bytes.count - 1, !previousSeparator else {
                throw ProgressionCatalogValidationError.invalidValue(
                    path: path,
                    reason: "Identifier syntax is invalid."
                )
            }
            previousSeparator = true
        }
    }

    static func requireThreshold(_ value: UInt32, path: String) throws {
        guard value > 0, value <= maximumThreshold else {
            throw ProgressionCatalogValidationError.invalidValue(
                path: path,
                reason: "Threshold must be between 1 and \(maximumThreshold)."
            )
        }
    }

    static func requireReference<T: Hashable>(
        _ value: T,
        in known: Set<T>,
        path: String,
        describe: (T) -> String
    ) throws {
        guard known.contains(value) else {
            throw ProgressionCatalogValidationError.unknownReference(
                path: path,
                identifier: describe(value)
            )
        }
    }
}
