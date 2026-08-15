import Foundation

public enum ProgressionContractError: Error, Equatable, Sendable {
    case invalidRevision
    case invalidTimestamp
    case invalidProgress
    case invalidCompletionState
    case invalidEventPayload
    case invalidPresentation
    case invalidOwnershipState
    case invalidSelection
    case invalidReveal
    case invalidDiagnostics
    case duplicateIdentifier
    case tooManyItems(maximum: Int)
    case invalidApplyResult
}

private struct ProgressionAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func progressionRejectUnknownKeys<Key>(
    from decoder: Decoder,
    allowedBy _: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: ProgressionAnyCodingKey.self)
    let allowed = Set(Key.allCases.map(\.stringValue))
    guard let unknown = container.allKeys.first(where: { !allowed.contains($0.stringValue) })
    else { return }
    throw DecodingError.dataCorrupted(
        .init(
            codingPath: decoder.codingPath + [unknown],
            debugDescription: "Unknown progression contract field."
        )
    )
}

private func progressionValidateFinite(_ date: Date?) throws {
    guard let date else { return }
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw ProgressionContractError.invalidTimestamp
    }
}

private func progressionValidateUnique<ID: Hashable>(_ values: [ID]) throws {
    guard Set(values).count == values.count else {
        throw ProgressionContractError.duplicateIdentifier
    }
}

private enum ProgressionPayloadField: Hashable {
    case cipherToken
    case messageToken
    case packageToken
    case relationshipToken
    case origin
    case routeClass
    case codexIDs
    case artifactIDs
    case keyIncluded
    case linkedRelationship
    case embeddedCipher
    case provenanceStatus
}

/// Validates the nine cataloged event payload shapes before the runtime stamps
/// a schema-v1 envelope. New event types require an explicit contract update.
public enum ProgressionEventPayloadContract {
    public static func validate(
        eventType: EventIdentifier,
        payload: DomainEventPayload
    ) throws {
        var present = Set<ProgressionPayloadField>()
        if payload.cipherToken != nil { present.insert(.cipherToken) }
        if payload.messageToken != nil { present.insert(.messageToken) }
        if payload.packageToken != nil { present.insert(.packageToken) }
        if payload.relationshipToken != nil { present.insert(.relationshipToken) }
        if payload.origin != nil { present.insert(.origin) }
        if payload.routeClass != nil { present.insert(.routeClass) }
        if !payload.codexIDs.isEmpty { present.insert(.codexIDs) }
        if !payload.artifactIDs.isEmpty { present.insert(.artifactIDs) }
        if payload.keyIncluded != nil { present.insert(.keyIncluded) }
        if payload.linkedRelationship != nil { present.insert(.linkedRelationship) }
        if payload.embeddedCipher != nil { present.insert(.embeddedCipher) }
        if payload.provenanceStatus != nil { present.insert(.provenanceStatus) }

        let required: Set<ProgressionPayloadField>
        let allowed: Set<ProgressionPayloadField>
        let requiredOrigin: DomainEventOrigin?

        switch eventType.rawValue {
        case "runescribe.cipher.created":
            required = [.cipherToken, .origin]
            allowed = required
            requiredOrigin = .generated
        case "runescribe.cipher.imported":
            required = [.cipherToken, .origin, .routeClass]
            allowed = required
            requiredOrigin = .imported
        case "runescribe.message.encoded":
            required = [.messageToken, .cipherToken, .origin, .codexIDs]
            allowed = required
            requiredOrigin = .generated
        case "runescribe.share.completed":
            required = [
                .messageToken, .routeClass, .codexIDs, .keyIncluded,
                .linkedRelationship,
            ]
            allowed = required.union([.relationshipToken, .artifactIDs])
            requiredOrigin = nil
        case "runescribe.cipher.first-delivery-completed":
            required = [
                .cipherToken, .relationshipToken, .keyIncluded,
                .linkedRelationship,
            ]
            allowed = required
            requiredOrigin = nil
        case "runescribe.message.imported":
            required = [
                .packageToken, .origin, .routeClass, .codexIDs, .embeddedCipher,
            ]
            allowed = required.union([.artifactIDs, .provenanceStatus])
            requiredOrigin = .imported
        case "runescribe.message.decoded":
            required = [.packageToken, .origin, .codexIDs]
            allowed = required.union([
                .relationshipToken, .artifactIDs, .provenanceStatus,
            ])
            requiredOrigin = .imported
        case "runescribe.exchange.bidirectional-established":
            required = [.relationshipToken]
            allowed = required
            requiredOrigin = nil
        case "runescribe.presentation.observed":
            required = [.packageToken, .codexIDs]
            allowed = required.union([.artifactIDs, .provenanceStatus])
            requiredOrigin = nil
        default:
            throw ProgressionContractError.invalidEventPayload
        }

        guard required.isSubset(of: present), present.isSubset(of: allowed) else {
            throw ProgressionContractError.invalidEventPayload
        }
        if let requiredOrigin, payload.origin != requiredOrigin {
            throw ProgressionContractError.invalidEventPayload
        }
        if eventType.rawValue == "runescribe.cipher.first-delivery-completed",
           payload.keyIncluded != true || payload.linkedRelationship != true
        {
            throw ProgressionContractError.invalidEventPayload
        }
    }
}

/// A privacy-safe domain fact submitted to the runtime. Canonical event
/// identity, correlation, source, schema, and time are runtime-owned stamps.
public struct ProgressionEventFact: Codable, Equatable, Sendable {
    public let eventType: EventIdentifier
    public let eligibility: DomainEventEligibilityMetadata
    public let payload: DomainEventPayload

    public init(
        eventType: EventIdentifier,
        eligibility: DomainEventEligibilityMetadata,
        payload: DomainEventPayload
    ) throws {
        guard RoadmapIdentifierSyntax.isValidIdentifier(eventType.rawValue) else {
            throw ProgressionContractError.invalidEventPayload
        }
        try ProgressionEventPayloadContract.validate(eventType: eventType, payload: payload)
        self.eventType = eventType
        self.eligibility = eligibility
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventType: container.decode(EventIdentifier.self, forKey: .eventType),
            eligibility: container.decode(
                DomainEventEligibilityMetadata.self,
                forKey: .eligibility
            ),
            payload: container.decode(DomainEventPayload.self, forKey: .payload)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eventType
        case eligibility
        case payload
    }
}

public struct ProgressionStateDeltaSummary: Codable, Equatable, Sendable {
    public let changedStatisticCount: UInt16
    public let completedAchievementCount: UInt16
    public let completedMilestoneCount: UInt16
    public let grantedContentCount: UInt16
    public let grantedEntitlementCount: UInt16
    public let queuedRevealCount: UInt16

    public init(
        changedStatisticCount: UInt16 = 0,
        completedAchievementCount: UInt16 = 0,
        completedMilestoneCount: UInt16 = 0,
        grantedContentCount: UInt16 = 0,
        grantedEntitlementCount: UInt16 = 0,
        queuedRevealCount: UInt16 = 0
    ) {
        self.changedStatisticCount = changedStatisticCount
        self.completedAchievementCount = completedAchievementCount
        self.completedMilestoneCount = completedMilestoneCount
        self.grantedContentCount = grantedContentCount
        self.grantedEntitlementCount = grantedEntitlementCount
        self.queuedRevealCount = queuedRevealCount
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            changedStatisticCount: try container.decode(
                UInt16.self,
                forKey: .changedStatisticCount
            ),
            completedAchievementCount: try container.decode(
                UInt16.self,
                forKey: .completedAchievementCount
            ),
            completedMilestoneCount: try container.decode(
                UInt16.self,
                forKey: .completedMilestoneCount
            ),
            grantedContentCount: try container.decode(
                UInt16.self,
                forKey: .grantedContentCount
            ),
            grantedEntitlementCount: try container.decode(
                UInt16.self,
                forKey: .grantedEntitlementCount
            ),
            queuedRevealCount: try container.decode(UInt16.self, forKey: .queuedRevealCount)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case changedStatisticCount
        case completedAchievementCount
        case completedMilestoneCount
        case grantedContentCount
        case grantedEntitlementCount
        case queuedRevealCount
    }
}

public enum ProgressionEventApplyResult: Codable, Equatable, Sendable {
    case applied(
        transactionID: GrantTransactionID,
        revision: UInt64,
        delta: ProgressionStateDeltaSummary
    )
    case duplicate
    case ignoredIneligible
    case rejectedPermanent(reason: ProgressionRejectionCode)
    case deferredUnsupportedSchema
    case deferredStoreUnavailable

    public var isTerminalAcknowledgement: Bool {
        switch self {
        case .applied, .duplicate, .ignoredIneligible, .rejectedPermanent:
            true
        case .deferredUnsupportedSchema, .deferredStoreUnavailable:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let outcome = try container.decode(Outcome.self, forKey: .outcome)
        let present = Set(container.allKeys)

        switch outcome {
        case .applied:
            guard present == Set([.outcome, .transactionID, .revision, .delta]) else {
                throw ProgressionContractError.invalidApplyResult
            }
            let revision = try container.decode(UInt64.self, forKey: .revision)
            guard revision > 0 else { throw ProgressionContractError.invalidRevision }
            self = .applied(
                transactionID: try container.decode(
                    GrantTransactionID.self,
                    forKey: .transactionID
                ),
                revision: revision,
                delta: try container.decode(ProgressionStateDeltaSummary.self, forKey: .delta)
            )
        case .duplicate:
            guard present == Set([.outcome]) else {
                throw ProgressionContractError.invalidApplyResult
            }
            self = .duplicate
        case .ignoredIneligible:
            guard present == Set([.outcome]) else {
                throw ProgressionContractError.invalidApplyResult
            }
            self = .ignoredIneligible
        case .rejectedPermanent:
            guard present == Set([.outcome, .reason]) else {
                throw ProgressionContractError.invalidApplyResult
            }
            self = .rejectedPermanent(
                reason: try container.decode(ProgressionRejectionCode.self, forKey: .reason)
            )
        case .deferredUnsupportedSchema:
            guard present == Set([.outcome]) else {
                throw ProgressionContractError.invalidApplyResult
            }
            self = .deferredUnsupportedSchema
        case .deferredStoreUnavailable:
            guard present == Set([.outcome]) else {
                throw ProgressionContractError.invalidApplyResult
            }
            self = .deferredStoreUnavailable
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .applied(transactionID, revision, delta):
            guard revision > 0 else { throw ProgressionContractError.invalidRevision }
            try container.encode(Outcome.applied, forKey: .outcome)
            try container.encode(transactionID, forKey: .transactionID)
            try container.encode(revision, forKey: .revision)
            try container.encode(delta, forKey: .delta)
        case .duplicate:
            try container.encode(Outcome.duplicate, forKey: .outcome)
        case .ignoredIneligible:
            try container.encode(Outcome.ignoredIneligible, forKey: .outcome)
        case let .rejectedPermanent(reason):
            try container.encode(Outcome.rejectedPermanent, forKey: .outcome)
            try container.encode(reason, forKey: .reason)
        case .deferredUnsupportedSchema:
            try container.encode(Outcome.deferredUnsupportedSchema, forKey: .outcome)
        case .deferredStoreUnavailable:
            try container.encode(Outcome.deferredStoreUnavailable, forKey: .outcome)
        }
    }

    private enum Outcome: String, Codable, Sendable {
        case applied
        case duplicate
        case ignoredIneligible = "ignored-ineligible"
        case rejectedPermanent = "rejected-permanent"
        case deferredUnsupportedSchema = "deferred-unsupported-schema"
        case deferredStoreUnavailable = "deferred-store-unavailable"
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case outcome
        case transactionID
        case revision
        case delta
        case reason
    }
}

public struct ProgressionOutboxReceipt: Codable, Equatable, Sendable {
    public let eventID: EventID
    public let correlationID: CorrelationID
    public let durableAt: Date
    public let outboxRevision: UInt64

    public init(
        eventID: EventID,
        correlationID: CorrelationID,
        durableAt: Date,
        outboxRevision: UInt64
    ) throws {
        try progressionValidateFinite(durableAt)
        guard outboxRevision > 0 else { throw ProgressionContractError.invalidRevision }
        self.eventID = eventID
        self.correlationID = correlationID
        self.durableAt = durableAt
        self.outboxRevision = outboxRevision
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventID: container.decode(EventID.self, forKey: .eventID),
            correlationID: container.decode(CorrelationID.self, forKey: .correlationID),
            durableAt: container.decode(Date.self, forKey: .durableAt),
            outboxRevision: container.decode(UInt64.self, forKey: .outboxRevision)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case eventID
        case correlationID
        case durableAt
        case outboxRevision
    }
}

public enum ProgressionModuleAvailability: String, Codable, CaseIterable, Sendable {
    case unavailable
    case available
    case degraded
}

public struct ProgressionPresentationDTO: Codable, Equatable, Sendable {
    public static let maximumDisplayNameUTF8Count = 120
    public static let maximumSummaryUTF8Count = 512
    public static let maximumSystemImageNameUTF8Count = 80

    public let displayName: String
    public let summary: String?
    public let fallbackSystemImageName: String

    public init(
        displayName: String,
        summary: String?,
        fallbackSystemImageName: String
    ) throws {
        guard Self.isBoundedDisplayText(
            displayName,
            maximum: Self.maximumDisplayNameUTF8Count
        ),
        summary.map({
            Self.isBoundedDisplayText($0, maximum: Self.maximumSummaryUTF8Count)
        }) ?? true,
        !fallbackSystemImageName.isEmpty,
        fallbackSystemImageName.utf8.count <= Self.maximumSystemImageNameUTF8Count,
        fallbackSystemImageName.utf8.allSatisfy({
            (97 ... 122).contains($0) || (48 ... 57).contains($0) || $0 == 45 || $0 == 46
        })
        else {
            throw ProgressionContractError.invalidPresentation
        }
        self.displayName = displayName
        self.summary = summary
        self.fallbackSystemImageName = fallbackSystemImageName
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            displayName: container.decode(String.self, forKey: .displayName),
            summary: container.decodeIfPresent(String.self, forKey: .summary),
            fallbackSystemImageName: container.decode(
                String.self,
                forKey: .fallbackSystemImageName
            )
        )
    }

    private static func isBoundedDisplayText(_ value: String, maximum: Int) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximum,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        })
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case displayName
        case summary
        case fallbackSystemImageName
    }
}

public struct ProgressionNumericProgressDTO: Codable, Equatable, Sendable {
    public let current: UInt64
    public let target: UInt64

    public init(current: UInt64, target: UInt64) throws {
        guard target > 0, current <= target else {
            throw ProgressionContractError.invalidProgress
        }
        self.current = current
        self.target = target
    }

    public var isComplete: Bool { current == target }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            current: container.decode(UInt64.self, forKey: .current),
            target: container.decode(UInt64.self, forKey: .target)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case current
        case target
    }
}

public struct ProgressionGateComponentDTO: Codable, Equatable, Sendable {
    public static let maximumComponentIDUTF8Count = 160
    public static let maximumLabelUTF8Count = 160

    public let componentID: String
    public let label: String
    public let current: UInt64
    public let target: UInt64
    public let isComplete: Bool

    public init(
        componentID: String,
        label: String,
        current: UInt64,
        target: UInt64,
        isComplete: Bool
    ) throws {
        guard RoadmapIdentifierSyntax.isValidIdentifier(componentID),
              componentID.utf8.count <= Self.maximumComponentIDUTF8Count,
              !label.isEmpty,
              label.utf8.count <= Self.maximumLabelUTF8Count,
              label == label.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              target > 0,
              current <= target
        else {
            throw ProgressionContractError.invalidProgress
        }
        guard isComplete == (current == target) else {
            throw ProgressionContractError.invalidCompletionState
        }
        self.componentID = componentID
        self.label = label
        self.current = current
        self.target = target
        self.isComplete = isComplete
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            componentID: container.decode(String.self, forKey: .componentID),
            label: container.decode(String.self, forKey: .label),
            current: container.decode(UInt64.self, forKey: .current),
            target: container.decode(UInt64.self, forKey: .target),
            isComplete: container.decode(Bool.self, forKey: .isComplete)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case componentID
        case label
        case current
        case target
        case isComplete
    }
}

public struct ProgressionCodexGateDTO: Codable, Equatable, Sendable {
    public static let maximumComponentCount = 8

    public let codexID: CodexID
    public let presentation: ProgressionPresentationDTO
    public let journeyOrder: UInt16
    public let completedRuleCount: UInt16
    public let requiredRuleCount: UInt16
    public let progress: ProgressionNumericProgressDTO
    public let components: [ProgressionGateComponentDTO]
    public let unlockedAt: Date?

    public init(
        codexID: CodexID,
        presentation: ProgressionPresentationDTO,
        journeyOrder: UInt16,
        completedRuleCount: UInt16,
        requiredRuleCount: UInt16,
        progress: ProgressionNumericProgressDTO,
        components: [ProgressionGateComponentDTO],
        unlockedAt: Date?
    ) throws {
        guard completedRuleCount <= requiredRuleCount,
              components.count <= Self.maximumComponentCount
        else {
            throw ProgressionContractError.invalidProgress
        }
        try progressionValidateUnique(components.map(\.componentID))
        let componentCompletedCount = UInt16(
            clamping: components.lazy.filter(\.isComplete).count
        )
        guard componentCompletedCount == completedRuleCount,
              UInt16(clamping: components.count) == requiredRuleCount
        else {
            throw ProgressionContractError.invalidCompletionState
        }
        guard (completedRuleCount == requiredRuleCount) == progress.isComplete,
              progress.isComplete == (unlockedAt != nil)
        else {
            throw ProgressionContractError.invalidCompletionState
        }
        try progressionValidateFinite(unlockedAt)
        self.codexID = codexID
        self.presentation = presentation
        self.journeyOrder = journeyOrder
        self.completedRuleCount = completedRuleCount
        self.requiredRuleCount = requiredRuleCount
        self.progress = progress
        self.components = components
        self.unlockedAt = unlockedAt
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codexID: container.decode(CodexID.self, forKey: .codexID),
            presentation: container.decode(
                ProgressionPresentationDTO.self,
                forKey: .presentation
            ),
            journeyOrder: container.decode(UInt16.self, forKey: .journeyOrder),
            completedRuleCount: container.decode(UInt16.self, forKey: .completedRuleCount),
            requiredRuleCount: container.decode(UInt16.self, forKey: .requiredRuleCount),
            progress: container.decode(ProgressionNumericProgressDTO.self, forKey: .progress),
            components: container.decode(
                [ProgressionGateComponentDTO].self,
                forKey: .components
            ),
            unlockedAt: container.decodeIfPresent(Date.self, forKey: .unlockedAt)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codexID
        case presentation
        case journeyOrder
        case completedRuleCount
        case requiredRuleCount
        case progress
        case components
        case unlockedAt
    }
}

public struct ProgressionRewardSummaryDTO: Codable, Equatable, Sendable {
    public static let maximumRewardCount = 64

    public let codexIDs: [CodexID]
    public let contentIDs: [ArtifactID]
    public let entitlementIDs: [UnlockID]
    public let titleIDs: [TitleID]
    public let crestIDs: [CrestID]

    public init(
        codexIDs: [CodexID] = [],
        contentIDs: [ArtifactID] = [],
        entitlementIDs: [UnlockID] = [],
        titleIDs: [TitleID] = [],
        crestIDs: [CrestID] = []
    ) throws {
        let counts = [
            codexIDs.count, contentIDs.count, entitlementIDs.count, titleIDs.count,
            crestIDs.count,
        ]
        guard counts.allSatisfy({ $0 <= Self.maximumRewardCount }) else {
            throw ProgressionContractError.tooManyItems(maximum: Self.maximumRewardCount)
        }
        try progressionValidateUnique(codexIDs)
        try progressionValidateUnique(contentIDs)
        try progressionValidateUnique(entitlementIDs)
        try progressionValidateUnique(titleIDs)
        try progressionValidateUnique(crestIDs)
        self.codexIDs = codexIDs.sorted()
        self.contentIDs = contentIDs.sorted()
        self.entitlementIDs = entitlementIDs.sorted()
        self.titleIDs = titleIDs.sorted()
        self.crestIDs = crestIDs.sorted()
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codexIDs: container.decode([CodexID].self, forKey: .codexIDs),
            contentIDs: container.decode([ArtifactID].self, forKey: .contentIDs),
            entitlementIDs: container.decode([UnlockID].self, forKey: .entitlementIDs),
            titleIDs: container.decode([TitleID].self, forKey: .titleIDs),
            crestIDs: container.decode([CrestID].self, forKey: .crestIDs)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codexIDs
        case contentIDs
        case entitlementIDs
        case titleIDs
        case crestIDs
    }
}

public struct ProgressionAchievementDTO: Codable, Equatable, Sendable {
    public let achievementID: AchievementID
    public let presentation: ProgressionPresentationDTO
    public let completedRuleCount: UInt16
    public let requiredRuleCount: UInt16
    public let progress: ProgressionNumericProgressDTO
    public let completedAt: Date?
    public let isHidden: Bool
    public let localPointWeight: UInt16
    public let rewards: ProgressionRewardSummaryDTO

    public init(
        achievementID: AchievementID,
        presentation: ProgressionPresentationDTO,
        completedRuleCount: UInt16,
        requiredRuleCount: UInt16,
        progress: ProgressionNumericProgressDTO,
        completedAt: Date?,
        isHidden: Bool,
        localPointWeight: UInt16,
        rewards: ProgressionRewardSummaryDTO
    ) throws {
        guard requiredRuleCount > 0, completedRuleCount <= requiredRuleCount else {
            throw ProgressionContractError.invalidProgress
        }
        guard (completedRuleCount == requiredRuleCount) == progress.isComplete,
              progress.isComplete == (completedAt != nil),
              localPointWeight <= 100,
              !isHidden || completedAt != nil || presentation.summary == nil
        else {
            throw ProgressionContractError.invalidCompletionState
        }
        try progressionValidateFinite(completedAt)
        self.achievementID = achievementID
        self.presentation = presentation
        self.completedRuleCount = completedRuleCount
        self.requiredRuleCount = requiredRuleCount
        self.progress = progress
        self.completedAt = completedAt
        self.isHidden = isHidden
        self.localPointWeight = localPointWeight
        self.rewards = rewards
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            achievementID: container.decode(AchievementID.self, forKey: .achievementID),
            presentation: container.decode(
                ProgressionPresentationDTO.self,
                forKey: .presentation
            ),
            completedRuleCount: container.decode(UInt16.self, forKey: .completedRuleCount),
            requiredRuleCount: container.decode(UInt16.self, forKey: .requiredRuleCount),
            progress: container.decode(ProgressionNumericProgressDTO.self, forKey: .progress),
            completedAt: container.decodeIfPresent(Date.self, forKey: .completedAt),
            isHidden: container.decode(Bool.self, forKey: .isHidden),
            localPointWeight: container.decode(UInt16.self, forKey: .localPointWeight),
            rewards: container.decode(ProgressionRewardSummaryDTO.self, forKey: .rewards)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case achievementID
        case presentation
        case completedRuleCount
        case requiredRuleCount
        case progress
        case completedAt
        case isHidden
        case localPointWeight
        case rewards
    }
}

public struct ProgressionStatisticDTO: Codable, Equatable, Sendable {
    public let statisticID: StatisticID
    public let presentation: ProgressionPresentationDTO
    public let codexID: CodexID?
    public let value: UInt64

    public init(
        statisticID: StatisticID,
        presentation: ProgressionPresentationDTO,
        codexID: CodexID? = nil,
        value: UInt64
    ) {
        self.statisticID = statisticID
        self.presentation = presentation
        self.codexID = codexID
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            statisticID: try container.decode(StatisticID.self, forKey: .statisticID),
            presentation: try container.decode(
                ProgressionPresentationDTO.self,
                forKey: .presentation
            ),
            codexID: try container.decodeIfPresent(CodexID.self, forKey: .codexID),
            value: try container.decode(UInt64.self, forKey: .value)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case statisticID
        case presentation
        case codexID
        case value
    }
}

public enum ProgressionContentKind: String, Codable, CaseIterable, Sendable {
    case codex
    case crest
    case entitlement
    case frame
    case relic
    case script
    case seal
    case title
    case unknown
}

public enum ProgressionContentReference: Codable, Equatable, Hashable, Sendable {
    case codex(CodexID)
    case artifact(ArtifactID)
    case title(TitleID)
    case entitlement(UnlockID)
    case crest(CrestID)
    case unknown

    fileprivate var sortKey: String {
        switch self {
        case let .codex(id): "codex:\(id.rawValue)"
        case let .artifact(id): "artifact:\(id.rawValue)"
        case let .title(id): "title:\(id.rawValue)"
        case let .entitlement(id): "entitlement:\(id.rawValue)"
        case let .crest(id): "crest:\(id.rawValue)"
        case .unknown: "unknown"
        }
    }

    fileprivate func isCompatible(with kind: ProgressionContentKind) -> Bool {
        switch (self, kind) {
        case (.codex, .codex), (.title, .title), (.entitlement, .entitlement),
             (.crest, .crest), (.artifact, .frame), (.artifact, .relic),
             (.artifact, .script), (.artifact, .seal), (.unknown, .unknown):
            true
        default:
            false
        }
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let referenceType = try container.decode(ReferenceType.self, forKey: .referenceType)
        let present = Set(container.allKeys)
        switch referenceType {
        case .codex:
            guard present == Set([.referenceType, .codexID]) else {
                throw ProgressionContractError.invalidOwnershipState
            }
            self = .codex(try container.decode(CodexID.self, forKey: .codexID))
        case .artifact:
            guard present == Set([.referenceType, .artifactID]) else {
                throw ProgressionContractError.invalidOwnershipState
            }
            self = .artifact(try container.decode(ArtifactID.self, forKey: .artifactID))
        case .title:
            guard present == Set([.referenceType, .titleID]) else {
                throw ProgressionContractError.invalidOwnershipState
            }
            self = .title(try container.decode(TitleID.self, forKey: .titleID))
        case .entitlement:
            guard present == Set([.referenceType, .entitlementID]) else {
                throw ProgressionContractError.invalidOwnershipState
            }
            self = .entitlement(
                try container.decode(UnlockID.self, forKey: .entitlementID)
            )
        case .crest:
            guard present == Set([.referenceType, .crestID]) else {
                throw ProgressionContractError.invalidOwnershipState
            }
            self = .crest(try container.decode(CrestID.self, forKey: .crestID))
        case .unknown:
            guard present == Set([.referenceType]) else {
                throw ProgressionContractError.invalidOwnershipState
            }
            self = .unknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .codex(id):
            try container.encode(ReferenceType.codex, forKey: .referenceType)
            try container.encode(id, forKey: .codexID)
        case let .artifact(id):
            try container.encode(ReferenceType.artifact, forKey: .referenceType)
            try container.encode(id, forKey: .artifactID)
        case let .title(id):
            try container.encode(ReferenceType.title, forKey: .referenceType)
            try container.encode(id, forKey: .titleID)
        case let .entitlement(id):
            try container.encode(ReferenceType.entitlement, forKey: .referenceType)
            try container.encode(id, forKey: .entitlementID)
        case let .crest(id):
            try container.encode(ReferenceType.crest, forKey: .referenceType)
            try container.encode(id, forKey: .crestID)
        case .unknown:
            try container.encode(ReferenceType.unknown, forKey: .referenceType)
        }
    }

    private enum ReferenceType: String, Codable, Sendable {
        case codex
        case artifact
        case title
        case entitlement
        case crest
        case unknown
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case referenceType
        case codexID
        case artifactID
        case titleID
        case entitlementID
        case crestID
    }
}

public enum ProgressionContentOwnershipState: String, Codable, CaseIterable, Sendable {
    case locked
    case encountered
    case owned
}

public enum ProgressionProviderAvailability: String, Codable, CaseIterable, Sendable {
    case unavailable
    case eligible
    case active
    case failed
}

public enum ProgressionContentRenderState: String, Codable, CaseIterable, Sendable {
    case locked
    case genericFallback
    case providerAvailable
    case providerFailed
}

public struct ProgressionOwnershipDTO: Codable, Equatable, Sendable {
    public static let maximumSourceRuleCount = 16

    public let kind: ProgressionContentKind
    public let reference: ProgressionContentReference
    public let presentation: ProgressionPresentationDTO
    public let state: ProgressionContentOwnershipState
    public let firstEncounteredAt: Date?
    public let grantedAt: Date?
    public let sourceRuleIDs: [RuleID]
    public let providerAvailability: ProgressionProviderAvailability
    public let renderState: ProgressionContentRenderState

    public init(
        kind: ProgressionContentKind,
        reference: ProgressionContentReference,
        presentation: ProgressionPresentationDTO,
        state: ProgressionContentOwnershipState,
        firstEncounteredAt: Date? = nil,
        grantedAt: Date? = nil,
        sourceRuleIDs: [RuleID] = [],
        providerAvailability: ProgressionProviderAvailability = .unavailable,
        renderState: ProgressionContentRenderState
    ) throws {
        guard reference.isCompatible(with: kind) else {
            throw ProgressionContractError.invalidOwnershipState
        }
        guard sourceRuleIDs.count <= Self.maximumSourceRuleCount else {
            throw ProgressionContractError.tooManyItems(maximum: Self.maximumSourceRuleCount)
        }
        try progressionValidateUnique(sourceRuleIDs)
        try progressionValidateFinite(firstEncounteredAt)
        try progressionValidateFinite(grantedAt)
        if let firstEncounteredAt, let grantedAt, grantedAt < firstEncounteredAt {
            throw ProgressionContractError.invalidTimestamp
        }

        switch state {
        case .locked:
            guard firstEncounteredAt == nil, grantedAt == nil, sourceRuleIDs.isEmpty,
                  providerAvailability == .unavailable, renderState == .locked
            else { throw ProgressionContractError.invalidOwnershipState }
        case .encountered:
            guard firstEncounteredAt != nil, grantedAt == nil, sourceRuleIDs.isEmpty,
                  providerAvailability == .unavailable, renderState == .genericFallback
            else { throw ProgressionContractError.invalidOwnershipState }
        case .owned:
            guard grantedAt != nil else {
                throw ProgressionContractError.invalidOwnershipState
            }
            let expectedRenderState: ProgressionContentRenderState
            switch providerAvailability {
            case .unavailable, .eligible: expectedRenderState = .genericFallback
            case .active: expectedRenderState = .providerAvailable
            case .failed: expectedRenderState = .providerFailed
            }
            guard renderState == expectedRenderState else {
                throw ProgressionContractError.invalidOwnershipState
            }
        }

        self.kind = kind
        self.reference = reference
        self.presentation = presentation
        self.state = state
        self.firstEncounteredAt = firstEncounteredAt
        self.grantedAt = grantedAt
        self.sourceRuleIDs = sourceRuleIDs.sorted()
        self.providerAvailability = providerAvailability
        self.renderState = renderState
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ProgressionContentKind.self, forKey: .kind),
            reference: container.decode(ProgressionContentReference.self, forKey: .reference),
            presentation: container.decode(
                ProgressionPresentationDTO.self,
                forKey: .presentation
            ),
            state: container.decode(ProgressionContentOwnershipState.self, forKey: .state),
            firstEncounteredAt: container.decodeIfPresent(Date.self, forKey: .firstEncounteredAt),
            grantedAt: container.decodeIfPresent(Date.self, forKey: .grantedAt),
            sourceRuleIDs: container.decode([RuleID].self, forKey: .sourceRuleIDs),
            providerAvailability: container.decode(
                ProgressionProviderAvailability.self,
                forKey: .providerAvailability
            ),
            renderState: container.decode(ProgressionContentRenderState.self, forKey: .renderState)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case reference
        case presentation
        case state
        case firstEncounteredAt
        case grantedAt
        case sourceRuleIDs
        case providerAvailability
        case renderState
    }
}

public struct ProgressionEncounterDTO: Codable, Equatable, Sendable {
    public let codexID: CodexID
    public let firstEncounteredAt: Date
    public let lastEncounteredAt: Date
    public let encounterCount: UInt64
    public let provenanceStatus: DomainEventProvenanceStatus

    public init(
        codexID: CodexID,
        firstEncounteredAt: Date,
        lastEncounteredAt: Date,
        encounterCount: UInt64,
        provenanceStatus: DomainEventProvenanceStatus
    ) throws {
        try progressionValidateFinite(firstEncounteredAt)
        try progressionValidateFinite(lastEncounteredAt)
        guard encounterCount > 0, firstEncounteredAt <= lastEncounteredAt else {
            throw ProgressionContractError.invalidProgress
        }
        self.codexID = codexID
        self.firstEncounteredAt = firstEncounteredAt
        self.lastEncounteredAt = lastEncounteredAt
        self.encounterCount = encounterCount
        self.provenanceStatus = provenanceStatus
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codexID: container.decode(CodexID.self, forKey: .codexID),
            firstEncounteredAt: container.decode(Date.self, forKey: .firstEncounteredAt),
            lastEncounteredAt: container.decode(Date.self, forKey: .lastEncounteredAt),
            encounterCount: container.decode(UInt64.self, forKey: .encounterCount),
            provenanceStatus: container.decode(
                DomainEventProvenanceStatus.self,
                forKey: .provenanceStatus
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codexID
        case firstEncounteredAt
        case lastEncounteredAt
        case encounterCount
        case provenanceStatus
    }
}

public enum ProgressionArchiveSupportState: String, Codable, CaseIterable, Sendable {
    case known
    case unsupported
    case unknown
}

public struct ProgressionArchiveEntryDTO: Codable, Equatable, Sendable {
    public let kind: ProgressionContentKind
    public let reference: ProgressionContentReference
    public let presentation: ProgressionPresentationDTO
    public let supportState: ProgressionArchiveSupportState
    public let ownershipState: ProgressionContentOwnershipState
    public let renderState: ProgressionContentRenderState
    public let firstEncounteredAt: Date
    public let lastEncounteredAt: Date
    public let encounterCount: UInt64
    public let provenanceStatus: DomainEventProvenanceStatus

    public init(
        kind: ProgressionContentKind,
        reference: ProgressionContentReference,
        presentation: ProgressionPresentationDTO,
        supportState: ProgressionArchiveSupportState,
        ownershipState: ProgressionContentOwnershipState,
        renderState: ProgressionContentRenderState,
        firstEncounteredAt: Date,
        lastEncounteredAt: Date,
        encounterCount: UInt64,
        provenanceStatus: DomainEventProvenanceStatus
    ) throws {
        guard reference.isCompatible(with: kind) else {
            throw ProgressionContractError.invalidOwnershipState
        }
        switch supportState {
        case .known, .unsupported:
            guard reference != .unknown else {
                throw ProgressionContractError.invalidOwnershipState
            }
        case .unknown:
            guard reference == .unknown, kind == .unknown else {
                throw ProgressionContractError.invalidOwnershipState
            }
        }
        guard ownershipState != .locked else {
            throw ProgressionContractError.invalidOwnershipState
        }
        if ownershipState == .encountered {
            guard renderState == .genericFallback else {
                throw ProgressionContractError.invalidOwnershipState
            }
        }
        try progressionValidateFinite(firstEncounteredAt)
        try progressionValidateFinite(lastEncounteredAt)
        guard encounterCount > 0, firstEncounteredAt <= lastEncounteredAt else {
            throw ProgressionContractError.invalidProgress
        }
        self.kind = kind
        self.reference = reference
        self.presentation = presentation
        self.supportState = supportState
        self.ownershipState = ownershipState
        self.renderState = renderState
        self.firstEncounteredAt = firstEncounteredAt
        self.lastEncounteredAt = lastEncounteredAt
        self.encounterCount = encounterCount
        self.provenanceStatus = provenanceStatus
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(ProgressionContentKind.self, forKey: .kind),
            reference: container.decode(ProgressionContentReference.self, forKey: .reference),
            presentation: container.decode(
                ProgressionPresentationDTO.self,
                forKey: .presentation
            ),
            supportState: container.decode(ProgressionArchiveSupportState.self, forKey: .supportState),
            ownershipState: container.decode(
                ProgressionContentOwnershipState.self,
                forKey: .ownershipState
            ),
            renderState: container.decode(ProgressionContentRenderState.self, forKey: .renderState),
            firstEncounteredAt: container.decode(Date.self, forKey: .firstEncounteredAt),
            lastEncounteredAt: container.decode(Date.self, forKey: .lastEncounteredAt),
            encounterCount: container.decode(UInt64.self, forKey: .encounterCount),
            provenanceStatus: container.decode(
                DomainEventProvenanceStatus.self,
                forKey: .provenanceStatus
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case reference
        case presentation
        case supportState
        case ownershipState
        case renderState
        case firstEncounteredAt
        case lastEncounteredAt
        case encounterCount
        case provenanceStatus
    }
}

public struct ProgressionTitleDTO: Codable, Equatable, Sendable {
    public let titleID: TitleID
    public let presentation: ProgressionPresentationDTO
    public let isOwned: Bool
    public let isSelected: Bool

    public init(
        titleID: TitleID,
        presentation: ProgressionPresentationDTO,
        isOwned: Bool,
        isSelected: Bool
    ) throws {
        guard !isSelected || isOwned else {
            throw ProgressionContractError.invalidSelection
        }
        self.titleID = titleID
        self.presentation = presentation
        self.isOwned = isOwned
        self.isSelected = isSelected
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            titleID: container.decode(TitleID.self, forKey: .titleID),
            presentation: container.decode(
                ProgressionPresentationDTO.self,
                forKey: .presentation
            ),
            isOwned: container.decode(Bool.self, forKey: .isOwned),
            isSelected: container.decode(Bool.self, forKey: .isSelected)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case titleID
        case presentation
        case isOwned
        case isSelected
    }
}

public enum ProgressionRevealTier: String, Codable, CaseIterable, Sendable {
    case micro
    case artifact
    case codex
    case mastery
}

public enum ProgressionRewardRarity: String, Codable, CaseIterable, Sendable {
    case forged = "Forged"
    case inscribed = "Inscribed"
    case rare = "Rare"
    case mythic = "Mythic"
}

public enum ProgressionRevealState: String, Codable, CaseIterable, Sendable {
    case pending
    case presented
    case acknowledged
}

public struct ProgressionRevealSummaryDTO: Codable, Equatable, Sendable {
    public static let maximumSecondaryRewardCount = 64
    public static let maximumSourceCount = 64

    public let revealID: RevealID
    public let transactionID: GrantTransactionID
    public let createdAt: Date
    public let state: ProgressionRevealState
    public let tier: ProgressionRevealTier
    public let rarity: ProgressionRewardRarity
    public let primaryRewardID: ProgressionContentReference
    public let primaryRewardPresentation: ProgressionPresentationDTO
    public let secondaryRewardIDs: [ProgressionContentReference]
    public let sourceAchievementIDs: [AchievementID]
    public let sourceRuleIDs: [RuleID]

    public init(
        revealID: RevealID,
        transactionID: GrantTransactionID,
        createdAt: Date,
        state: ProgressionRevealState,
        tier: ProgressionRevealTier,
        rarity: ProgressionRewardRarity,
        primaryRewardID: ProgressionContentReference,
        primaryRewardPresentation: ProgressionPresentationDTO,
        secondaryRewardIDs: [ProgressionContentReference] = [],
        sourceAchievementIDs: [AchievementID] = [],
        sourceRuleIDs: [RuleID] = []
    ) throws {
        guard secondaryRewardIDs.count <= Self.maximumSecondaryRewardCount,
              sourceAchievementIDs.count <= Self.maximumSourceCount,
              sourceRuleIDs.count <= Self.maximumSourceCount
        else {
            throw ProgressionContractError.tooManyItems(
                maximum: max(Self.maximumSecondaryRewardCount, Self.maximumSourceCount)
            )
        }
        try progressionValidateUnique(secondaryRewardIDs)
        try progressionValidateUnique(sourceAchievementIDs)
        try progressionValidateUnique(sourceRuleIDs)
        guard !secondaryRewardIDs.contains(primaryRewardID),
              !sourceAchievementIDs.isEmpty || !sourceRuleIDs.isEmpty
        else { throw ProgressionContractError.invalidReveal }
        try progressionValidateFinite(createdAt)
        self.revealID = revealID
        self.transactionID = transactionID
        self.createdAt = createdAt
        self.state = state
        self.tier = tier
        self.rarity = rarity
        self.primaryRewardID = primaryRewardID
        self.primaryRewardPresentation = primaryRewardPresentation
        self.secondaryRewardIDs = secondaryRewardIDs.sorted { $0.sortKey < $1.sortKey }
        self.sourceAchievementIDs = sourceAchievementIDs.sorted()
        self.sourceRuleIDs = sourceRuleIDs.sorted()
    }

    public var contentGrantCount: UInt16 {
        UInt16(1 + secondaryRewardIDs.count)
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revealID: container.decode(RevealID.self, forKey: .revealID),
            transactionID: container.decode(GrantTransactionID.self, forKey: .transactionID),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            state: container.decode(ProgressionRevealState.self, forKey: .state),
            tier: container.decode(ProgressionRevealTier.self, forKey: .tier),
            rarity: container.decode(ProgressionRewardRarity.self, forKey: .rarity),
            primaryRewardID: container.decode(
                ProgressionContentReference.self,
                forKey: .primaryRewardID
            ),
            primaryRewardPresentation: container.decode(
                ProgressionPresentationDTO.self,
                forKey: .primaryRewardPresentation
            ),
            secondaryRewardIDs: container.decode(
                [ProgressionContentReference].self,
                forKey: .secondaryRewardIDs
            ),
            sourceAchievementIDs: container.decode(
                [AchievementID].self,
                forKey: .sourceAchievementIDs
            ),
            sourceRuleIDs: container.decode([RuleID].self, forKey: .sourceRuleIDs)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revealID
        case transactionID
        case createdAt
        case state
        case tier
        case rarity
        case primaryRewardID
        case primaryRewardPresentation
        case secondaryRewardIDs
        case sourceAchievementIDs
        case sourceRuleIDs
    }
}

public enum ProgressionGameCenterMirrorStatus: String, Codable, CaseIterable, Sendable {
    case notConfigured
}

public struct ProgressionSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumItemsPerCollection = 256
    public static let maximumCodexGateCount = 16
    public static let maximumAchievementCount = 64
    public static let maximumStatisticCount = 256
    public static let maximumOwnershipCount = 256
    public static let maximumEncounterCount = 256
    public static let maximumArchiveCount = 256
    public static let maximumTitleCount = 64
    public static let maximumEntitlementCount = 256

    public let revision: UInt64
    public let capturedAt: Date
    public let availability: ProgressionModuleAvailability
    public let storeHealth: ModuleStateLoadState
    public let catalogID: ProgressionCatalogID?
    public let catalogVersion: ProgressionCatalogVersion?
    public let codexGates: [ProgressionCodexGateDTO]
    public let achievements: [ProgressionAchievementDTO]
    public let statistics: [ProgressionStatisticDTO]
    public let ownership: [ProgressionOwnershipDTO]
    public let encounters: [ProgressionEncounterDTO]
    public let archive: [ProgressionArchiveEntryDTO]
    public let titles: [ProgressionTitleDTO]
    public let selectedTitleID: TitleID?
    public let pendingRevealCount: UInt16
    public let nextReveal: ProgressionRevealSummaryDTO?
    public let entitlementIDs: [UnlockID]
    public let gameCenterMirrorStatus: ProgressionGameCenterMirrorStatus

    public init(
        revision: UInt64,
        capturedAt: Date,
        availability: ProgressionModuleAvailability,
        storeHealth: ModuleStateLoadState,
        catalogID: ProgressionCatalogID?,
        catalogVersion: ProgressionCatalogVersion?,
        codexGates: [ProgressionCodexGateDTO] = [],
        achievements: [ProgressionAchievementDTO] = [],
        statistics: [ProgressionStatisticDTO] = [],
        ownership: [ProgressionOwnershipDTO] = [],
        encounters: [ProgressionEncounterDTO] = [],
        archive: [ProgressionArchiveEntryDTO] = [],
        titles: [ProgressionTitleDTO] = [],
        selectedTitleID: TitleID? = nil,
        pendingRevealCount: UInt16 = 0,
        nextReveal: ProgressionRevealSummaryDTO? = nil,
        entitlementIDs: [UnlockID] = [],
        gameCenterMirrorStatus: ProgressionGameCenterMirrorStatus = .notConfigured
    ) throws {
        guard codexGates.count <= Self.maximumCodexGateCount,
              achievements.count <= Self.maximumAchievementCount,
              statistics.count <= Self.maximumStatisticCount,
              ownership.count <= Self.maximumOwnershipCount,
              encounters.count <= Self.maximumEncounterCount,
              archive.count <= Self.maximumArchiveCount,
              titles.count <= Self.maximumTitleCount,
              entitlementIDs.count <= Self.maximumEntitlementCount
        else {
            throw ProgressionContractError.tooManyItems(
                maximum: Self.maximumItemsPerCollection
            )
        }
        try progressionValidateFinite(capturedAt)
        guard (catalogID == nil) == (catalogVersion == nil) else {
            throw ProgressionContractError.invalidDiagnostics
        }

        try progressionValidateUnique(codexGates.map(\.codexID))
        try progressionValidateUnique(codexGates.map(\.journeyOrder))
        try progressionValidateUnique(achievements.map(\.achievementID))
        try progressionValidateUnique(
            statistics.map { "\($0.statisticID.rawValue)|\($0.codexID?.rawValue ?? "")" }
        )
        try progressionValidateUnique(ownership.map(\.reference))
        try progressionValidateUnique(encounters.map(\.codexID))
        try progressionValidateUnique(archive.map(\.reference))
        try progressionValidateUnique(titles.map(\.titleID))
        try progressionValidateUnique(entitlementIDs)

        let selectedTitles = titles.filter(\.isSelected)
        guard selectedTitles.count <= 1,
              selectedTitles.first?.titleID == selectedTitleID,
              selectedTitleID == nil || titles.contains(where: {
                  $0.titleID == selectedTitleID && $0.isOwned && $0.isSelected
              })
        else {
            throw ProgressionContractError.invalidSelection
        }

        if pendingRevealCount == 0 {
            guard nextReveal == nil else { throw ProgressionContractError.invalidReveal }
        } else {
            guard let nextReveal, nextReveal.state != .acknowledged else {
                throw ProgressionContractError.invalidReveal
            }
        }

        self.revision = revision
        self.capturedAt = capturedAt
        self.availability = availability
        self.storeHealth = storeHealth
        self.catalogID = catalogID
        self.catalogVersion = catalogVersion
        self.codexGates = codexGates.sorted {
            ($0.journeyOrder, $0.codexID.rawValue) < ($1.journeyOrder, $1.codexID.rawValue)
        }
        self.achievements = achievements.sorted { $0.achievementID < $1.achievementID }
        self.statistics = statistics.sorted {
            ($0.statisticID.rawValue, $0.codexID?.rawValue ?? "")
                < ($1.statisticID.rawValue, $1.codexID?.rawValue ?? "")
        }
        self.ownership = ownership.sorted { $0.reference.sortKey < $1.reference.sortKey }
        self.encounters = encounters.sorted { $0.codexID < $1.codexID }
        self.archive = archive.sorted { $0.reference.sortKey < $1.reference.sortKey }
        self.titles = titles.sorted { $0.titleID < $1.titleID }
        self.selectedTitleID = selectedTitleID
        self.pendingRevealCount = pendingRevealCount
        self.nextReveal = nextReveal
        self.entitlementIDs = entitlementIDs.sorted()
        self.gameCenterMirrorStatus = gameCenterMirrorStatus
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(UInt64.self, forKey: .revision),
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            availability: container.decode(
                ProgressionModuleAvailability.self,
                forKey: .availability
            ),
            storeHealth: container.decode(ModuleStateLoadState.self, forKey: .storeHealth),
            catalogID: container.decodeIfPresent(ProgressionCatalogID.self, forKey: .catalogID),
            catalogVersion: container.decodeIfPresent(
                ProgressionCatalogVersion.self,
                forKey: .catalogVersion
            ),
            codexGates: container.decode([ProgressionCodexGateDTO].self, forKey: .codexGates),
            achievements: container.decode(
                [ProgressionAchievementDTO].self,
                forKey: .achievements
            ),
            statistics: container.decode([ProgressionStatisticDTO].self, forKey: .statistics),
            ownership: container.decode([ProgressionOwnershipDTO].self, forKey: .ownership),
            encounters: container.decode([ProgressionEncounterDTO].self, forKey: .encounters),
            archive: container.decode([ProgressionArchiveEntryDTO].self, forKey: .archive),
            titles: container.decode([ProgressionTitleDTO].self, forKey: .titles),
            selectedTitleID: container.decodeIfPresent(TitleID.self, forKey: .selectedTitleID),
            pendingRevealCount: container.decode(UInt16.self, forKey: .pendingRevealCount),
            nextReveal: container.decodeIfPresent(
                ProgressionRevealSummaryDTO.self,
                forKey: .nextReveal
            ),
            entitlementIDs: container.decode([UnlockID].self, forKey: .entitlementIDs),
            gameCenterMirrorStatus: container.decode(
                ProgressionGameCenterMirrorStatus.self,
                forKey: .gameCenterMirrorStatus
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revision
        case capturedAt
        case availability
        case storeHealth
        case catalogID
        case catalogVersion
        case codexGates
        case achievements
        case statistics
        case ownership
        case encounters
        case archive
        case titles
        case selectedTitleID
        case pendingRevealCount
        case nextReveal
        case entitlementIDs
        case gameCenterMirrorStatus
    }
}

public struct ProgressionEntitlementSnapshotDTO: Codable, Equatable, Sendable {
    public static let maximumUnlockCount = 512

    public let revision: UInt64
    public let capturedAt: Date
    public let includedUnlockIDs: [UnlockID]
    public let earnedUnlockIDs: [UnlockID]

    public init(
        revision: UInt64,
        capturedAt: Date,
        includedUnlockIDs: [UnlockID],
        earnedUnlockIDs: [UnlockID]
    ) throws {
        guard includedUnlockIDs.count <= Self.maximumUnlockCount,
              earnedUnlockIDs.count <= Self.maximumUnlockCount
        else {
            throw ProgressionContractError.tooManyItems(maximum: Self.maximumUnlockCount)
        }
        try progressionValidateFinite(capturedAt)
        try progressionValidateUnique(includedUnlockIDs)
        try progressionValidateUnique(earnedUnlockIDs)
        guard Set(includedUnlockIDs).isDisjoint(with: earnedUnlockIDs) else {
            throw ProgressionContractError.duplicateIdentifier
        }
        self.revision = revision
        self.capturedAt = capturedAt
        self.includedUnlockIDs = includedUnlockIDs.sorted()
        self.earnedUnlockIDs = earnedUnlockIDs.sorted()
    }

    public var allUnlockIDs: Set<UnlockID> {
        Set(includedUnlockIDs).union(earnedUnlockIDs)
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            revision: container.decode(UInt64.self, forKey: .revision),
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            includedUnlockIDs: container.decode([UnlockID].self, forKey: .includedUnlockIDs),
            earnedUnlockIDs: container.decode([UnlockID].self, forKey: .earnedUnlockIDs)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revision
        case capturedAt
        case includedUnlockIDs
        case earnedUnlockIDs
    }
}

public struct AcknowledgeProgressionRevealCommand: Codable, Equatable, Sendable {
    public let revealID: RevealID

    public init(revealID: RevealID) {
        self.revealID = revealID
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(revealID: try container.decode(RevealID.self, forKey: .revealID))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revealID
    }
}

public struct MarkProgressionRevealPresentedCommand: Codable, Equatable, Sendable {
    public let revealID: RevealID

    public init(revealID: RevealID) {
        self.revealID = revealID
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(revealID: try container.decode(RevealID.self, forKey: .revealID))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case revealID
    }
}

public struct SelectProgressionTitleCommand: Codable, Equatable, Sendable {
    public let titleID: TitleID?

    public init(titleID: TitleID?) {
        self.titleID = titleID
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(titleID: try container.decodeIfPresent(TitleID.self, forKey: .titleID))
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case titleID
    }
}

public struct ProgressionSHA256Digest: RawRepresentable, Codable, Equatable, Hashable,
    Sendable, Comparable
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
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let digest = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid SHA-256 digest."
                )
            )
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ProgressionDiagnosticRecordCategory: String, Codable, CaseIterable, Sendable {
    case metadata
    case processedEvent = "processed-event"
    case statisticCounter = "statistic-counter"
    case distinctToken = "distinct-token"
    case achievementProgress = "achievement-progress"
    case achievementCompletion = "achievement-completion"
    case milestoneCompletion = "milestone-completion"
    case grant
    case ownership
    case entitlement
    case encounter
    case titleSelection = "title-selection"
    case pendingReveal = "pending-reveal"
    case catalogMigration = "catalog-migration"
    case quarantine
}

public enum ProgressionDiagnosticHashKind: String, Codable, CaseIterable, Sendable {
    case catalog
    case eventCatalog = "event-catalog"
    case activeProjection = "active-projection"
    case processedEventLog = "processed-event-log"
}

public enum ProgressionDiagnosticErrorCategory: String, Codable, CaseIterable, Sendable {
    case catalog
    case recordDecode = "record-decode"
    case recordReference = "record-reference"
    case integrity
    case migration
    case eventValidation = "event-validation"
    case transaction
    case rebuild
    case provider
}

public struct ProgressionDiagnosticRecordCountDTO: Codable, Equatable, Sendable {
    public static let maximumRecordCount: UInt64 = 1_000_000_000

    public let category: ProgressionDiagnosticRecordCategory
    public let count: UInt64

    public init(category: ProgressionDiagnosticRecordCategory, count: UInt64) throws {
        guard count <= Self.maximumRecordCount else {
            throw ProgressionContractError.invalidDiagnostics
        }
        self.category = category
        self.count = count
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            category: container.decode(
                ProgressionDiagnosticRecordCategory.self,
                forKey: .category
            ),
            count: container.decode(UInt64.self, forKey: .count)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case category
        case count
    }
}

public struct ProgressionDiagnosticHashDTO: Codable, Equatable, Sendable {
    public let kind: ProgressionDiagnosticHashKind
    public let digest: ProgressionSHA256Digest

    public init(kind: ProgressionDiagnosticHashKind, digest: ProgressionSHA256Digest) {
        self.kind = kind
        self.digest = digest
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(ProgressionDiagnosticHashKind.self, forKey: .kind),
            digest: try container.decode(ProgressionSHA256Digest.self, forKey: .digest)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case kind
        case digest
    }
}

public struct ProgressionDiagnosticErrorDTO: Codable, Equatable, Sendable {
    public static let maximumErrorCount: UInt64 = 1_000_000_000

    public let category: ProgressionDiagnosticErrorCategory
    public let count: UInt64
    public let mostRecentCode: ProgressionRejectionCode?

    public init(
        category: ProgressionDiagnosticErrorCategory,
        count: UInt64,
        mostRecentCode: ProgressionRejectionCode?
    ) throws {
        guard count > 0, count <= Self.maximumErrorCount else {
            throw ProgressionContractError.invalidDiagnostics
        }
        self.category = category
        self.count = count
        self.mostRecentCode = mostRecentCode
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            category: container.decode(
                ProgressionDiagnosticErrorCategory.self,
                forKey: .category
            ),
            count: container.decode(UInt64.self, forKey: .count),
            mostRecentCode: container.decodeIfPresent(
                ProgressionRejectionCode.self,
                forKey: .mostRecentCode
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case category
        case count
        case mostRecentCode
    }
}

public struct ProgressionDiagnosticsSummaryDTO: Codable, Equatable, Sendable {
    public static let maximumRecordCategories = 32
    public static let maximumHashes = 16
    public static let maximumErrorCategories = 32

    public let capturedAt: Date
    public let availability: ProgressionModuleAvailability
    public let storeHealth: ModuleStateLoadState
    public let catalogID: ProgressionCatalogID?
    public let catalogVersion: ProgressionCatalogVersion?
    public let stateNamespaceSchemaVersion: UInt32?
    public let logicalRecordSchemaVersion: UInt16?
    public let pendingOutboxCount: UInt64
    public let recordCounts: [ProgressionDiagnosticRecordCountDTO]
    public let hashes: [ProgressionDiagnosticHashDTO]
    public let errors: [ProgressionDiagnosticErrorDTO]

    public init(
        capturedAt: Date,
        availability: ProgressionModuleAvailability,
        storeHealth: ModuleStateLoadState,
        catalogID: ProgressionCatalogID?,
        catalogVersion: ProgressionCatalogVersion?,
        stateNamespaceSchemaVersion: UInt32? = nil,
        logicalRecordSchemaVersion: UInt16? = nil,
        pendingOutboxCount: UInt64,
        recordCounts: [ProgressionDiagnosticRecordCountDTO] = [],
        hashes: [ProgressionDiagnosticHashDTO] = [],
        errors: [ProgressionDiagnosticErrorDTO] = []
    ) throws {
        guard recordCounts.count <= Self.maximumRecordCategories,
              hashes.count <= Self.maximumHashes,
              errors.count <= Self.maximumErrorCategories,
              pendingOutboxCount <= ProgressionDiagnosticRecordCountDTO.maximumRecordCount
        else {
            throw ProgressionContractError.invalidDiagnostics
        }
        try progressionValidateFinite(capturedAt)
        let hasCatalog = catalogID != nil
        let hasStateSchema = stateNamespaceSchemaVersion != nil
        let hasLogicalSchema = logicalRecordSchemaVersion != nil
        guard hasCatalog == (catalogVersion != nil),
              hasStateSchema == hasLogicalSchema,
              !hasCatalog || hasStateSchema,
              stateNamespaceSchemaVersion.map({ $0 > 0 }) ?? true,
              logicalRecordSchemaVersion.map({ $0 > 0 }) ?? true
        else {
            throw ProgressionContractError.invalidDiagnostics
        }
        try progressionValidateUnique(recordCounts.map(\.category))
        try progressionValidateUnique(hashes.map(\.kind))
        try progressionValidateUnique(errors.map(\.category))
        self.capturedAt = capturedAt
        self.availability = availability
        self.storeHealth = storeHealth
        self.catalogID = catalogID
        self.catalogVersion = catalogVersion
        self.stateNamespaceSchemaVersion = stateNamespaceSchemaVersion
        self.logicalRecordSchemaVersion = logicalRecordSchemaVersion
        self.pendingOutboxCount = pendingOutboxCount
        self.recordCounts = recordCounts.sorted { $0.category.rawValue < $1.category.rawValue }
        self.hashes = hashes.sorted { $0.kind.rawValue < $1.kind.rawValue }
        self.errors = errors.sorted { $0.category.rawValue < $1.category.rawValue }
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            availability: container.decode(
                ProgressionModuleAvailability.self,
                forKey: .availability
            ),
            storeHealth: container.decode(ModuleStateLoadState.self, forKey: .storeHealth),
            catalogID: container.decodeIfPresent(ProgressionCatalogID.self, forKey: .catalogID),
            catalogVersion: container.decodeIfPresent(
                ProgressionCatalogVersion.self,
                forKey: .catalogVersion
            ),
            stateNamespaceSchemaVersion: container.decodeIfPresent(
                UInt32.self,
                forKey: .stateNamespaceSchemaVersion
            ),
            logicalRecordSchemaVersion: container.decodeIfPresent(
                UInt16.self,
                forKey: .logicalRecordSchemaVersion
            ),
            pendingOutboxCount: container.decode(UInt64.self, forKey: .pendingOutboxCount),
            recordCounts: container.decode(
                [ProgressionDiagnosticRecordCountDTO].self,
                forKey: .recordCounts
            ),
            hashes: container.decode([ProgressionDiagnosticHashDTO].self, forKey: .hashes),
            errors: container.decode([ProgressionDiagnosticErrorDTO].self, forKey: .errors)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case capturedAt
        case availability
        case storeHealth
        case catalogID
        case catalogVersion
        case stateNamespaceSchemaVersion
        case logicalRecordSchemaVersion
        case pendingOutboxCount
        case recordCounts
        case hashes
        case errors
    }
}

public struct ProgressionRecoveryRequest: Codable, Equatable, Sendable {
    public let confirmationToken: UUID

    public init(confirmationToken: UUID) {
        self.confirmationToken = confirmationToken
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            confirmationToken: try container.decode(UUID.self, forKey: .confirmationToken)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case confirmationToken
    }
}

public struct ProgressionRecoveryResult: Codable, Equatable, Sendable {
    public let rebuiltAt: Date
    public let revision: UInt64

    public init(rebuiltAt: Date, revision: UInt64) throws {
        try progressionValidateFinite(rebuiltAt)
        guard revision > 0 else { throw ProgressionContractError.invalidRevision }
        self.rebuiltAt = rebuiltAt
        self.revision = revision
    }

    public init(from decoder: Decoder) throws {
        try progressionRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            rebuiltAt: container.decode(Date.self, forKey: .rebuiltAt),
            revision: container.decode(UInt64.self, forKey: .revision)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case rebuiltAt
        case revision
    }
}
