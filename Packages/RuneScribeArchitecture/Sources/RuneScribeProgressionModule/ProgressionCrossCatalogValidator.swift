import Foundation
import RuneScribeContracts

enum ProgressionEventCatalogSemanticValidator {
    private typealias Support = ProgressionCatalogValidationSupport

    private struct ExpectedEvent {
        let producer: String
        let required: Set<ProgressionEventPayloadField>
        let optional: Set<ProgressionEventPayloadField>?
        let semanticDedupe: Set<ProgressionEventPayloadField>
        let updates: Set<String>
        let requiredOrigin: ProgressionEventRequiredOrigin?
        let keyIncluded: Bool?
        let linkedRelationship: Bool?
    }

    static func validate(_ catalog: ProgressionEventCatalog) throws {
        guard catalog.schemaVersion == "1.0",
              catalog.catalogID.rawValue == "runescribe.progression.event-catalog",
              catalog.catalogVersion.rawValue == 2
        else { return try invalid("$events", "Unexpected event catalog identity.") }
        try Support.requireDate(catalog.effectiveDate, path: "$events.effectiveDate")
        try Support.requireText(catalog.eventEnvelope, path: "$events.eventEnvelope")
        guard catalog.applyOutcomes == ProgressionApplyOutcome.allCases,
              catalog.acknowledgeOutboxOn == [
                  .applied, .duplicate, .ignoredIneligible, .rejectedPermanent,
              ],
              catalog.retainOutboxOn == [
                  .deferredUnsupportedSchema, .deferredStoreUnavailable,
              ]
        else { return try invalid("$events.applyOutcomes", "Apply outcome policy is invalid.") }

        let expected = expectedEvents
        try Support.requireCount(catalog.events, 9, name: "event definitions")
        try Support.requireUnique(
            catalog.events.map { $0.eventType.rawValue },
            kind: "eventType",
            describe: { $0 }
        )
        guard Set(catalog.events.map { $0.eventType.rawValue }) == Set(expected.keys) else {
            return try invalid("$events.events", "Event type inventory does not match v2.")
        }
        for (index, event) in catalog.events.enumerated() {
            let path = "$events.events[\(index)]"
            try Support.requireIdentifier(event.eventType.rawValue, path: "\(path).eventType")
            try Support.requireText(event.producer, path: "\(path).producer", maximumBytes: 128)
            try Support.requireText(event.emissionPoint, path: "\(path).emissionPoint")
            if let notes = event.notes { try Support.requireText(notes, path: "\(path).notes") }
            try Support.requireUnique(event.requiredPayload, kind: "required payload field", describe: \.rawValue)
            if let optional = event.optionalPayload {
                guard !optional.isEmpty else {
                    return try invalid("\(path).optionalPayload", "Optional payload cannot be empty.")
                }
                try Support.requireUnique(optional, kind: "optional payload field", describe: \.rawValue)
            }
            try Support.requireUnique(event.semanticDedupe, kind: "semantic dedupe field", describe: \.rawValue)
            try Support.requireUnique(event.updates, kind: "updated statisticID", describe: \.rawValue)
            guard let shape = expected[event.eventType.rawValue],
                  event.producer == shape.producer,
                  Set(event.requiredPayload) == shape.required,
                  event.optionalPayload.map(Set.init) == shape.optional,
                  Set(event.semanticDedupe) == shape.semanticDedupe,
                  Set(event.updates.map(\.rawValue)) == shape.updates,
                  event.requiredValues?.origin == shape.requiredOrigin,
                  event.requiredValues?.keyIncluded == shape.keyIncluded,
                  event.requiredValues?.linkedRelationship == shape.linkedRelationship,
                  (event.requiredValues != nil) == (
                      shape.requiredOrigin != nil
                          || shape.keyIncluded != nil
                          || shape.linkedRelationship != nil
                  )
            else { return try invalid(path, "Event payload or update shape does not match v2.") }
            let available = Set(event.requiredPayload).union(event.optionalPayload ?? [])
            guard Set(event.semanticDedupe).isSubset(of: available) else {
                return try invalid("\(path).semanticDedupe", "Dedupe fields must be payload fields.")
            }
        }

        try validateRoutes(catalog.shareRoutePolicy)
        guard catalog.forbiddenData == ProgressionForbiddenData.allCases else {
            return try invalid("$events.forbiddenData", "Forbidden-data inventory is incomplete.")
        }
        let expectedReasons = [
            "eligibility.eligible.domain-commit",
            "eligibility.eligible.share-completed-by-system",
            "eligibility.eligible.message-sent-confirmed",
            "eligibility.ineligible.cancelled",
            "eligibility.ineligible.failed",
            "eligibility.ineligible.completion-unavailable",
            "eligibility.ineligible.required-attachment-not-accepted",
            "eligibility.informational.presented-only",
        ]
        guard catalog.eligibilityReasonIDs.map(\.rawValue) == expectedReasons else {
            return try invalid("$events.eligibilityReasonIDs", "Eligibility reason inventory mismatch.")
        }
    }

    private static func validateRoutes(_ routes: [ProgressionShareRoutePolicy]) throws {
        try Support.requireCount(routes, 9, name: "share route policies")
        let keys = routes.map { "\($0.routeClass.rawValue)|\($0.terminalResult.rawValue)" }
        try Support.requireUnique(keys, kind: "share route policy", describe: { $0 })
        let expected: [String: (Bool?, Bool, Bool)] = [
            "messages|sent-confirmed": (true, true, true),
            "share-sheet|completed-by-system": (false, true, true),
            "air-drop|completed-by-system": (false, true, true),
            "file-export|completion-unavailable": (nil, false, false),
            "clipboard|completion-unavailable": (nil, false, false),
            "qr-display|completion-unavailable": (nil, false, false),
            "any|presented": (nil, false, false),
            "any|cancelled": (nil, false, false),
            "any|failed": (nil, false, false),
        ]
        guard Set(keys) == Set(expected.keys) else {
            return try invalid("$events.shareRoutePolicy", "Share route matrix is incomplete.")
        }
        for (index, route) in routes.enumerated() {
            let key = keys[index]
            guard let expectedValues = expected[key],
                  route.requiresAttachmentAcceptedWhenKeyDelivery == expectedValues.0,
                  route.progressionEligible == expectedValues.1,
                  route.firstDeliveryEligible == expectedValues.2
            else {
                return try invalid(
                    "$events.shareRoutePolicy[\(index)]",
                    "Share route eligibility does not match v2."
                )
            }
            if let notes = route.notes {
                try Support.requireText(notes, path: "$events.shareRoutePolicy[\(index)].notes")
            }
        }
    }

    private static let expectedEvents: [String: ExpectedEvent] = [
        "runescribe.cipher.created": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.cipherToken, .origin], optional: nil,
            semanticDedupe: [.cipherToken],
            updates: ["stat.cipher.created-or-imported.unique"],
            requiredOrigin: .generated, keyIncluded: nil, linkedRelationship: nil
        ),
        "runescribe.cipher.imported": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.cipherToken, .origin, .routeClass], optional: nil,
            semanticDedupe: [.cipherToken],
            updates: ["stat.cipher.created-or-imported.unique"],
            requiredOrigin: .imported, keyIncluded: nil, linkedRelationship: nil
        ),
        "runescribe.message.encoded": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.messageToken, .cipherToken, .origin, .codexIDs], optional: nil,
            semanticDedupe: [.messageToken], updates: ["stat.message.encoded.unique"],
            requiredOrigin: .generated, keyIncluded: nil, linkedRelationship: nil
        ),
        "runescribe.share.completed": ExpectedEvent(
            producer: "RuneScribeCoreModule through Forsetti terminal-share normalization",
            required: [.messageToken, .routeClass, .codexIDs, .keyIncluded, .linkedRelationship],
            optional: [.relationshipToken, .artifactIDs],
            semanticDedupe: [.messageToken, .codexIDs],
            updates: [
                "stat.share.eligible-message.unique", "stat.share.relic-used.unique",
                "stat.share.seal-used.unique", "stat.share.codex-used.unique",
                "stat.codex.share.unique-message",
                "stat.codex.relationship-presented.unique",
                "stat.codex.relic-used.unique", "stat.codex.seal-used.unique",
            ],
            requiredOrigin: nil, keyIncluded: nil, linkedRelationship: nil
        ),
        "runescribe.cipher.first-delivery-completed": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.cipherToken, .relationshipToken, .keyIncluded, .linkedRelationship],
            optional: nil, semanticDedupe: [.relationshipToken],
            updates: ["stat.relationship.first-delivery.unique"],
            requiredOrigin: nil, keyIncluded: true, linkedRelationship: true
        ),
        "runescribe.message.imported": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.packageToken, .origin, .routeClass, .codexIDs, .embeddedCipher],
            optional: [.artifactIDs, .provenanceStatus], semanticDedupe: [.packageToken],
            updates: [], requiredOrigin: .imported, keyIncluded: nil,
            linkedRelationship: nil
        ),
        "runescribe.message.decoded": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.packageToken, .origin, .codexIDs],
            optional: [.relationshipToken, .artifactIDs, .provenanceStatus],
            semanticDedupe: [.packageToken],
            updates: [
                "stat.message.incoming-decoded.unique",
                "stat.codex.incoming-decode.unique-package",
            ],
            requiredOrigin: .imported, keyIncluded: nil, linkedRelationship: nil
        ),
        "runescribe.exchange.bidirectional-established": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.relationshipToken], optional: nil,
            semanticDedupe: [.relationshipToken],
            updates: ["stat.relationship.bidirectional.unique"],
            requiredOrigin: nil, keyIncluded: nil, linkedRelationship: nil
        ),
        "runescribe.presentation.observed": ExpectedEvent(
            producer: "RuneScribeCoreModule",
            required: [.packageToken, .codexIDs],
            optional: [.artifactIDs, .provenanceStatus],
            semanticDedupe: [.packageToken, .codexIDs, .artifactIDs],
            updates: ["stat.encounter.codex.unique", "stat.codex.observed.unique-package"],
            requiredOrigin: nil, keyIncluded: nil, linkedRelationship: nil
        ),
    ]

    private static func invalid<T>(_ path: String, _ reason: String) throws -> T {
        throw ProgressionCatalogValidationError.invalidValue(path: path, reason: reason)
    }
}

enum ProgressionThemeBindingSemanticValidator {
    private typealias Support = ProgressionCatalogValidationSupport

    static func validate(_ contract: ProgressionFutureThemeBindingContract) throws {
        guard contract.schemaVersion == "1.0",
              contract.contractID.rawValue == "runescribe.progression.future-theme-binding",
              contract.version.rawValue == 2,
              contract.status == .approved
        else { return try invalid("$bindings", "Unexpected theme-binding identity.") }
        try Support.requireCount(contract.bindings, 5, name: "theme bindings")
        try Support.requireCount(contract.rules, 5, name: "theme binding rules")
        try Support.requireCount(contract.supersessions, 2, name: "theme supersessions")
        try Support.requireUnique(contract.bindings.map(\.codexID), kind: "binding codexID", describe: \.rawValue)
        try Support.requireUnique(contract.bindings.map(\.moduleID), kind: "binding moduleID", describe: \.rawValue)
        try Support.requireUnique(contract.bindings.map(\.entitlementID), kind: "binding entitlementID", describe: \.rawValue)
        try Support.requireUnique(contract.rules, kind: "binding rule prose", describe: { $0 })
        for (index, rule) in contract.rules.enumerated() {
            try Support.requireText(rule, path: "$bindings.rules[\(index)]")
        }
        for (index, binding) in contract.bindings.enumerated() {
            let path = "$bindings.bindings[\(index)]"
            try Support.requireIdentifier(binding.moduleID.rawValue, path: "\(path).moduleID")
            switch binding.criticality {
            case .requiredBase:
                guard binding.codexID.rawValue == "codex.norse",
                      binding.gate == .included,
                      binding.gateRuleID == nil,
                      binding.fallback == true,
                      binding.fallbackCodexID == nil
                else { return try invalid(path, "Required-base binding shape is invalid.") }
            case .optional:
                guard binding.codexID.rawValue != "codex.norse",
                      binding.gate == nil,
                      binding.gateRuleID != nil,
                      binding.fallback == nil,
                      binding.fallbackCodexID?.rawValue == "codex.norse"
                else { return try invalid(path, "Optional binding shape is invalid.") }
            }
        }
        for (index, supersession) in contract.supersessions.enumerated() {
            let path = "$bindings.supersessions[\(index)]"
            try Support.requireText(supersession.source, path: "\(path).source", maximumBytes: 256)
            try Support.requireText(supersession.path, path: "\(path).path", maximumBytes: 256)
            try Support.requireText(supersession.old, path: "\(path).old")
            try Support.requireText(supersession.new, path: "\(path).new")
        }
    }

    private static func invalid<T>(_ path: String, _ reason: String) throws -> T {
        throw ProgressionCatalogValidationError.invalidValue(path: path, reason: reason)
    }
}

enum ProgressionCatalogBundleSemanticValidator {
    private typealias Support = ProgressionCatalogValidationSupport

    static func validate(
        catalog: ProgressionCatalog,
        eventCatalog: ProgressionEventCatalog,
        bindings: ProgressionFutureThemeBindingContract,
        integrityMetadata: ProgressionCatalogIntegrityMetadata
    ) throws -> ValidatedProgressionCatalogBundle {
        guard catalog.effectiveDate == eventCatalog.effectiveDate else {
            return try invalid("$bundle.effectiveDate", "Catalog dates must match.")
        }
        let statistics = Set(catalog.statistics.map(\.statisticID))
        let eventTypes = Set(eventCatalog.events.map { $0.eventType.rawValue })
        let internalSources = Set(["grant-transaction", "achievement-completion"])
        for statistic in catalog.statistics {
            for source in statistic.sourceEvents where internalSources.contains(source) {
                let isCompatible =
                    statistic.storage == .derived
                    && ((source == "grant-transaction" && statistic.dimension == .contentID)
                    || (source == "achievement-completion" &&
                        statistic.dimension == .achievementID))
                guard isCompatible else {
                    return try invalid(
                        "$bundle.statistics.dimension",
                        "Internal statistic source does not provide its configured dimension."
                    )
                }
            }
            for source in statistic.sourceEvents where !internalSources.contains(source) {
                guard statistic.storage != .derived else {
                    return try invalid(
                        "$bundle.statistics.storage",
                        "Event-updated statistics cannot use derived storage."
                    )
                }
                guard eventTypes.contains(source) else {
                    throw ProgressionCatalogValidationError.unknownReference(
                        path: "$bundle.statistics.sourceEvents",
                        identifier: source
                    )
                }
                guard eventCatalog.event(EventIdentifier(rawValue: source))?.updates
                    .contains(statistic.statisticID) == true
                else {
                    return try invalid(
                        "$bundle.statistics.sourceEvents",
                        "Event/statistic update references are not bidirectional."
                    )
                }
                guard let payloadField = payloadField(for: statistic.dimension),
                      let event = eventCatalog.event(EventIdentifier(rawValue: source)),
                      event.requiredPayload.contains(payloadField)
                        || (event.optionalPayload?.contains(payloadField) == true)
                else {
                    return try invalid(
                        "$bundle.statistics.dimension",
                        "Statistic source event does not provide its configured dimension."
                    )
                }
            }
        }
        for event in eventCatalog.events {
            for statisticID in event.updates {
                try Support.requireReference(
                    statisticID,
                    in: statistics,
                    path: "$bundle.events.updates",
                    describe: \.rawValue
                )
                guard catalog.statistic(id: statisticID)?.sourceEvents
                    .contains(event.eventType.rawValue) == true
                else {
                    return try invalid(
                        "$bundle.events.updates",
                        "Event/statistic update references are not bidirectional."
                    )
                }
            }
        }
        try validateBindings(bindings, catalog: catalog)
        let analysis = try ProgressionCatalogDependencyAnalyzer.analyze(catalog)
        return ValidatedProgressionCatalogBundle(
            catalog: catalog,
            eventCatalog: eventCatalog,
            futureThemeBindings: bindings,
            dependencyAnalysis: analysis,
            integrityMetadata: integrityMetadata
        )
    }

    private static func payloadField(
        for dimension: ProgressionStatisticDimension
    ) -> ProgressionEventPayloadField? {
        switch dimension {
        case .artifactID: .artifactIDs
        case .cipherToken: .cipherToken
        case .codexID: .codexIDs
        case .messageToken: .messageToken
        case .packageToken: .packageToken
        case .relationshipToken: .relationshipToken
        case .achievementID, .contentID: nil
        }
    }

    private static func validateBindings(
        _ bindings: ProgressionFutureThemeBindingContract,
        catalog: ProgressionCatalog
    ) throws {
        let content = Dictionary(uniqueKeysWithValues: catalog.content.map { ($0.contentID.rawValue, $0) })
        let rules = Set(catalog.milestones.map(\.ruleID))
        let codices = Set(catalog.content.filter { $0.kind == .codex }.map { $0.contentID.rawValue })
        guard Set(bindings.bindings.map { $0.codexID.rawValue }) == codices else {
            return try invalid("$bindings.bindings", "Every Codex requires exactly one binding.")
        }
        for (index, binding) in bindings.bindings.enumerated() {
            let path = "$bindings.bindings[\(index)]"
            guard content[binding.codexID.rawValue]?.kind == .codex else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "\(path).codexID",
                    identifier: binding.codexID.rawValue
                )
            }
            guard let entitlement = content[binding.entitlementID.rawValue],
                  entitlement.kind == .entitlement,
                  entitlement.codexID == binding.codexID
            else {
                throw ProgressionCatalogValidationError.unknownReference(
                    path: "\(path).entitlementID",
                    identifier: binding.entitlementID.rawValue
                )
            }
            if let gate = binding.gateRuleID {
                try Support.requireReference(
                    gate,
                    in: rules,
                    path: "\(path).gateRuleID",
                    describe: \.rawValue
                )
                guard catalog.journeyGraph.nodes.contains(where: {
                    $0.contentID.rawValue == binding.codexID.rawValue && $0.gateRuleID == gate
                }) else {
                    return try invalid(path, "Binding gate must match the Journey gate.")
                }
            }
        }
    }

    private static func invalid<T>(_ path: String, _ reason: String) throws -> T {
        throw ProgressionCatalogValidationError.invalidValue(path: path, reason: reason)
    }
}

enum ProgressionCatalogDependencyAnalyzer {
    static func rejectDirectCycles(in catalog: ProgressionCatalog) throws {
        _ = try directGraph(catalog)
        if let cycle = firstCycle(requiredRewardGraph(catalog)) {
            throw ProgressionCatalogValidationError.dependencyCycle(cycle)
        }
    }

    static func analyze(_ catalog: ProgressionCatalog) throws -> ProgressionDependencyAnalysis {
        let direct = try directGraph(catalog)
        let rewardGraph = rewardEffectGraph(catalog)
        if let cycle = firstCycle(requiredRewardGraph(catalog)) {
            throw ProgressionCatalogValidationError.dependencyCycle(cycle)
        }
        let components = stronglyConnectedComponents(rewardGraph)
            .filter { component in
                component.count > 1
                    || component.first.map { rewardGraph[$0]?.contains($0) == true } == true
            }
            .map { $0.sorted() }
            .sorted { $0.joined(separator: "|") < $1.joined(separator: "|") }
        return ProgressionDependencyAnalysis(
            directEdges: direct.edges.sorted {
                ($0.dependent, $0.prerequisite) < ($1.dependent, $1.prerequisite)
            },
            rewardEffectStronglyConnectedComponents: components
        )
    }

    private static func directGraph(
        _ catalog: ProgressionCatalog
    ) throws -> (edges: [ProgressionDependencyAnalysis.Edge], adjacency: [String: Set<String>]) {
        var adjacency: [String: Set<String>] = [:]
        var edges = [ProgressionDependencyAnalysis.Edge]()
        let completionRules: [(String, ProgressionRule)] =
            catalog.achievements.map { ($0.achievementID.rawValue, $0.rule) }
                + catalog.milestones.map { ($0.ruleID.rawValue, $0.rule) }
        for (id, rule) in completionRules {
            if adjacency[id] == nil { adjacency[id] = [] }
            for prerequisite in explicitAchievementDependencies(rule) {
                adjacency[id, default: []].insert(prerequisite)
                edges.append(.init(dependent: id, prerequisite: prerequisite))
            }
        }
        if let cycle = firstCycle(adjacency) {
            throw ProgressionCatalogValidationError.dependencyCycle(cycle)
        }
        return (edges, adjacency)
    }

    private static func rewardEffectGraph(
        _ catalog: ProgressionCatalog
    ) -> [String: Set<String>] {
        let completionRules: [(String, GrantGroupID, ProgressionRule)] =
            catalog.achievements.map {
                ($0.achievementID.rawValue, $0.rewardGrantGroupID, $0.rule)
            } + catalog.milestones.map { ($0.ruleID.rawValue, $0.grantGroupID, $0.rule) }
        let sourcesByGroup = Dictionary(grouping: completionRules, by: { $0.1 })
        var sourcesByContent: [ProgressionContentID: Set<String>] = [:]
        let artifacts = Set(catalog.content.filter(\.countsAsArtifact).map(\.contentID))
        for group in catalog.grantGroups {
            let sources = Set((sourcesByGroup[group.grantGroupID] ?? []).map { $0.0 })
            for item in group.items {
                sourcesByContent[item.contentID, default: []].formUnion(sources)
            }
        }
        let artifactSources = Set(
            artifacts.flatMap { Array(sourcesByContent[$0, default: []]) }
        )
        let achievementIDs = Set(catalog.achievements.map { $0.achievementID.rawValue })
        var graph: [String: Set<String>] = [:]
        for (id, _, rule) in completionRules {
            if graph[id] == nil { graph[id] = [] }
            collectRewardDependencies(
                rule,
                contentSources: sourcesByContent,
                artifactSources: artifactSources,
                achievementIDs: achievementIDs,
                into: &graph[id, default: []]
            )
        }
        return graph
    }

    private static func requiredRewardGraph(
        _ catalog: ProgressionCatalog
    ) -> [String: Set<String>] {
        let completionRules: [(String, GrantGroupID, ProgressionRule)] =
            catalog.achievements.map {
                ($0.achievementID.rawValue, $0.rewardGrantGroupID, $0.rule)
            } + catalog.milestones.map { ($0.ruleID.rawValue, $0.grantGroupID, $0.rule) }
        let sourcesByGroup = Dictionary(grouping: completionRules, by: { $0.1 })
        var sourcesByContent: [ProgressionContentID: Set<String>] = [:]
        for group in catalog.grantGroups {
            let sources = Set((sourcesByGroup[group.grantGroupID] ?? []).map { $0.0 })
            for item in group.items {
                sourcesByContent[item.contentID, default: []].formUnion(sources)
            }
        }
        let initiallyOwned = Set(
            catalog.grantGroup(id: catalog.migration.startingGrantGroupID)?.items
                .map(\.contentID) ?? []
        )
        var graph: [String: Set<String>] = [:]
        for (identifier, _, rule) in completionRules {
            graph[identifier] = requiredRewardDependencies(
                rule,
                contentSources: sourcesByContent,
                initiallyOwned: initiallyOwned
            )
        }
        return graph
    }

    private static func requiredRewardDependencies(
        _ rule: ProgressionRule,
        contentSources: [ProgressionContentID: Set<String>],
        initiallyOwned: Set<ProgressionContentID>
    ) -> Set<String> {
        switch rule {
        case let .contentOwned(contentID):
            guard !initiallyOwned.contains(contentID) else { return [] }
            let sources = contentSources[contentID, default: []]
            return sources.count == 1 ? sources : []
        case let .achievementCompleted(achievementID):
            return [achievementID.rawValue]
        case let .all(conditions):
            return conditions.reduce(into: Set<String>()) { result, condition in
                result.formUnion(requiredRewardDependencies(
                    condition,
                    contentSources: contentSources,
                    initiallyOwned: initiallyOwned
                ))
            }
        case let .any(conditions):
            guard let first = conditions.first else { return [] }
            return conditions.dropFirst().reduce(
                requiredRewardDependencies(
                    first,
                    contentSources: contentSources,
                    initiallyOwned: initiallyOwned
                )
            ) { result, condition in
                result.intersection(requiredRewardDependencies(
                    condition,
                    contentSources: contentSources,
                    initiallyOwned: initiallyOwned
                ))
            }
        default:
            return []
        }
    }

    private static func collectRewardDependencies(
        _ rule: ProgressionRule,
        contentSources: [ProgressionContentID: Set<String>],
        artifactSources: Set<String>,
        achievementIDs: Set<String>,
        into result: inout Set<String>
    ) {
        switch rule {
        case let .contentOwned(contentID):
            result.formUnion(contentSources[contentID, default: []])
        case let .achievementCompleted(achievementID):
            result.insert(achievementID.rawValue)
        case let .completedAchievementCountAtLeast(_, excluding):
            result.formUnion(achievementIDs.subtracting(excluding.map(\.rawValue)))
        case let .distinctCountAtLeast(statisticID, _, _)
            where statisticID.rawValue == "stat.ownership.artifact-count":
            result.formUnion(artifactSources)
        case let .all(conditions), let .any(conditions):
            for condition in conditions {
                collectRewardDependencies(
                    condition,
                    contentSources: contentSources,
                    artifactSources: artifactSources,
                    achievementIDs: achievementIDs,
                    into: &result
                )
            }
        default:
            break
        }
    }

    private static func explicitAchievementDependencies(_ rule: ProgressionRule) -> Set<String> {
        switch rule {
        case let .achievementCompleted(achievementID):
            [achievementID.rawValue]
        case let .all(conditions), let .any(conditions):
            conditions.reduce(into: Set<String>()) {
                $0.formUnion(explicitAchievementDependencies($1))
            }
        default:
            []
        }
    }

    private static func firstCycle(_ graph: [String: Set<String>]) -> [String]? {
        enum Mark { case visiting, visited }
        var marks: [String: Mark] = [:]
        var stack = [String]()

        func visit(_ node: String) -> [String]? {
            if marks[node] == .visiting {
                if let index = stack.firstIndex(of: node) {
                    return Array(stack[index...]) + [node]
                }
                return [node, node]
            }
            if marks[node] == .visited { return nil }
            marks[node] = .visiting
            stack.append(node)
            for dependency in graph[node, default: []].sorted() {
                if let cycle = visit(dependency) { return cycle }
            }
            _ = stack.popLast()
            marks[node] = .visited
            return nil
        }

        for node in graph.keys.sorted() {
            if let cycle = visit(node) { return cycle }
        }
        return nil
    }

    private static func stronglyConnectedComponents(
        _ graph: [String: Set<String>]
    ) -> [[String]] {
        var nextIndex = 0
        var indices: [String: Int] = [:]
        var lowLinks: [String: Int] = [:]
        var stack = [String]()
        var onStack = Set<String>()
        var result = [[String]]()
        let nodes = Set(graph.keys).union(graph.values.flatMap { $0 })

        func connect(_ node: String) {
            indices[node] = nextIndex
            lowLinks[node] = nextIndex
            nextIndex += 1
            stack.append(node)
            onStack.insert(node)

            for dependency in graph[node, default: []].sorted() {
                if indices[dependency] == nil {
                    connect(dependency)
                    lowLinks[node] = min(lowLinks[node]!, lowLinks[dependency]!)
                } else if onStack.contains(dependency) {
                    lowLinks[node] = min(lowLinks[node]!, indices[dependency]!)
                }
            }
            if lowLinks[node] == indices[node] {
                var component = [String]()
                while let member = stack.popLast() {
                    onStack.remove(member)
                    component.append(member)
                    if member == node { break }
                }
                result.append(component)
            }
        }

        for node in nodes.sorted() where indices[node] == nil { connect(node) }
        return result
    }
}
