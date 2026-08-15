import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum ProgressionContentIdentifierDomain: Sendable {}
public enum ProgressionJourneyNodeIdentifierDomain: Sendable {}

public typealias ProgressionContentID = RoadmapStringIdentifier<ProgressionContentIdentifierDomain>
public typealias ProgressionJourneyNodeID =
    RoadmapStringIdentifier<ProgressionJourneyNodeIdentifierDomain>

public enum ProgressionCatalogApprovalStatus: String, Decodable, Sendable {
    case approvedControllingImplementationInput =
        "approved-controlling-implementation-input"
}

public enum ProgressionCatalogContentKind: String, CaseIterable, Decodable, Sendable {
    case codex
    case crest
    case entitlement
    case frame
    case relic
    case script
    case seal
    case title
}

public enum ProgressionContentAvailability: String, CaseIterable, Decodable, Sendable {
    case earned
    case included
    case permanent
    case permanentMastery = "permanent-mastery"
    case seasonalDeferred = "seasonal-deferred"
}

public enum ProgressionContentRarity: String, CaseIterable, Decodable, Sendable {
    case forged = "Forged"
    case inscribed = "Inscribed"
    case mythic = "Mythic"
    case rare = "Rare"
}

public struct ProgressionContentDefinition: Decodable, Equatable, Sendable {
    public let contentID: ProgressionContentID
    public let kind: ProgressionCatalogContentKind
    public let displayName: String
    public let countsAsArtifact: Bool
    public let availability: ProgressionContentAvailability
    public let rarity: ProgressionContentRarity
    public let codexID: CodexID?
    public let notes: String?
}

public enum ProgressionStatisticStorage: String, CaseIterable, Decodable, Sendable {
    case distinctSet = "distinct-set"
    case bucketedDistinctSet = "bucketed-distinct-set"
    case derived
}

public enum ProgressionStatisticDimension: String, CaseIterable, Decodable, Sendable {
    case achievementID
    case artifactID
    case cipherToken
    case codexID
    case contentID
    case messageToken
    case packageToken
    case relationshipToken
}

public enum ProgressionStatisticBucket: String, CaseIterable, Decodable, Sendable {
    case codexID
}

public struct ProgressionStatisticDefinition: Decodable, Equatable, Sendable {
    public let statisticID: StatisticID
    public let displayName: String
    public let storage: ProgressionStatisticStorage
    public let bucket: ProgressionStatisticBucket?
    public let dimension: ProgressionStatisticDimension
    public let sourceEvents: [String]
    public let filter: String?
}

public enum ProgressionRuleOperator: String, CaseIterable, Decodable, Sendable {
    case distinctCountAtLeast
    case contentOwned
    case achievementCompleted
    case completedAchievementCountAtLeast
    case all
    case any
    case bucketCountAtLeast
    case allListedContentUsed
}

public indirect enum ProgressionRule: Decodable, Equatable, Sendable {
    case distinctCountAtLeast(
        statisticID: StatisticID,
        threshold: UInt32,
        bucketID: CodexID?
    )
    case contentOwned(ProgressionContentID)
    case achievementCompleted(AchievementID)
    case completedAchievementCountAtLeast(
        threshold: UInt32,
        excluding: [AchievementID]
    )
    case all([ProgressionRule])
    case any([ProgressionRule])
    case bucketCountAtLeast(
        statisticID: StatisticID,
        minimumBuckets: UInt16,
        minimumValuePerBucket: UInt32
    )
    case allListedContentUsed(
        statisticID: StatisticID,
        bucketID: CodexID,
        contentIDs: [ProgressionContentID]
    )

    public var `operator`: ProgressionRuleOperator {
        switch self {
        case .distinctCountAtLeast: .distinctCountAtLeast
        case .contentOwned: .contentOwned
        case .achievementCompleted: .achievementCompleted
        case .completedAchievementCountAtLeast: .completedAchievementCountAtLeast
        case .all: .all
        case .any: .any
        case .bucketCountAtLeast: .bucketCountAtLeast
        case .allListedContentUsed: .allListedContentUsed
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ProgressionRuleOperator.self, forKey: .op) {
        case .distinctCountAtLeast:
            self = try .distinctCountAtLeast(
                statisticID: container.decode(StatisticID.self, forKey: .statisticID),
                threshold: container.decode(UInt32.self, forKey: .threshold),
                bucketID: container.decodeIfPresent(CodexID.self, forKey: .bucketID)
            )
        case .contentOwned:
            self = try .contentOwned(
                container.decode(ProgressionContentID.self, forKey: .contentID)
            )
        case .achievementCompleted:
            self = try .achievementCompleted(
                container.decode(AchievementID.self, forKey: .achievementID)
            )
        case .completedAchievementCountAtLeast:
            self = try .completedAchievementCountAtLeast(
                threshold: container.decode(UInt32.self, forKey: .threshold),
                excluding: container.decode(
                    [AchievementID].self,
                    forKey: .excludeAchievementIDs
                )
            )
        case .all:
            self = try .all(container.decode([ProgressionRule].self, forKey: .conditions))
        case .any:
            self = try .any(container.decode([ProgressionRule].self, forKey: .conditions))
        case .bucketCountAtLeast:
            self = try .bucketCountAtLeast(
                statisticID: container.decode(StatisticID.self, forKey: .statisticID),
                minimumBuckets: container.decode(UInt16.self, forKey: .minimumBuckets),
                minimumValuePerBucket: container.decode(
                    UInt32.self,
                    forKey: .minimumValuePerBucket
                )
            )
        case .allListedContentUsed:
            self = try .allListedContentUsed(
                statisticID: container.decode(StatisticID.self, forKey: .statisticID),
                bucketID: container.decode(CodexID.self, forKey: .bucketID),
                contentIDs: container.decode(
                    [ProgressionContentID].self,
                    forKey: .contentIDs
                )
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case op
        case statisticID
        case threshold
        case bucketID
        case contentID
        case achievementID
        case excludeAchievementIDs
        case conditions
        case minimumBuckets
        case minimumValuePerBucket
        case contentIDs
    }
}

public enum ProgressionAchievementPath: String, CaseIterable, Decodable, Sendable {
    case archivist
    case courier
    case crossPath = "cross-path"
    case scribe
}

public enum ProgressionVisibility: String, CaseIterable, Decodable, Sendable {
    case hiddenUntilProgress = "hidden-until-progress"
    case visible
    case visibleProgressive = "visible-progressive"
}

public enum ProgressionGameCenterStatus: String, Decodable, Sendable {
    case deferredNotConfigured = "deferred-not-configured"
}

public struct ProgressionGameCenterAchievement: Decodable, Equatable, Sendable {
    public let eligible: Bool
    public let status: ProgressionGameCenterStatus
    public let permanentIdentifier: String?
    public let points: UInt16
}

public struct ProgressionAchievementProgressDescriptor: Decodable, Equatable, Sendable {
    public let statisticID: StatisticID
    public let target: UInt32
    public let excludeAchievementIDs: [AchievementID]?
}

public struct ProgressionAchievementDefinition: Decodable, Equatable, Sendable {
    public let achievementID: AchievementID
    public let displayName: String
    public let description: String
    public let path: ProgressionAchievementPath
    public let evergreen: Bool
    public let visibility: ProgressionVisibility
    public let localPointWeight: UInt16
    public let gameCenter: ProgressionGameCenterAchievement
    public let rule: ProgressionRule
    public let progress: ProgressionAchievementProgressDescriptor
    public let rewardGrantGroupID: GrantGroupID
    public let fallbackSystemImage: String
}

public enum ProgressionMilestoneCategory: String, CaseIterable, Decodable, Sendable {
    case artifactLadder = "artifact-ladder"
    case codexMastery = "codex-mastery"
    case codexUnlock = "codex-unlock"
}

public enum ProgressionProgressComponentType: String, CaseIterable, Decodable, Sendable {
    case achievement
    case allContentUsed = "all-content-used"
    case bucketThreshold = "bucket-threshold"
    case ownership
    case statistic
}

public struct ProgressionProgressComponent: Decodable, Equatable, Sendable {
    public let type: ProgressionProgressComponentType
    public let statisticID: StatisticID?
    public let target: UInt32?
    public let bucketID: CodexID?
    public let contentIDs: [ProgressionContentID]?
    public let minimumBuckets: UInt16?
    public let minimumValuePerBucket: UInt32?
    public let achievementID: AchievementID?
    public let contentID: ProgressionContentID?
}

public enum ProgressionCatalogRevealTier: String, CaseIterable, Decodable, Sendable {
    case none
    case micro
    case artifact
    case codex
    case mastery
}

public struct ProgressionMilestoneDefinition: Decodable, Equatable, Sendable {
    public let ruleID: RuleID
    public let displayName: String
    public let description: String
    public let visibility: ProgressionVisibility
    public let category: ProgressionMilestoneCategory
    public let rule: ProgressionRule
    public let grantGroupID: GrantGroupID
    public let revealTier: ProgressionCatalogRevealTier
    public let progressComponents: [ProgressionProgressComponent]
}

public enum ProgressionGrantKind: String, Decodable, Sendable {
    case permanent
}

public struct ProgressionGrantItem: Decodable, Equatable, Sendable {
    public let contentID: ProgressionContentID
    public let grantKind: ProgressionGrantKind
}

public struct ProgressionGrantGroup: Decodable, Equatable, Sendable {
    public let grantGroupID: GrantGroupID
    public let items: [ProgressionGrantItem]
    public let revealTier: ProgressionCatalogRevealTier
    public let primaryContentID: ProgressionContentID
    public let notes: String?
}

public enum ProgressionJourneyState: String, CaseIterable, Decodable, Sendable {
    case included
    case earned
}

public struct ProgressionJourneyNode: Decodable, Equatable, Sendable {
    public let nodeID: ProgressionJourneyNodeID
    public let contentID: ProgressionContentID
    public let state: ProgressionJourneyState
    public let gateRuleID: RuleID?
    public let order: UInt16
}

public struct ProgressionJourneyEdge: Decodable, Equatable, Sendable {
    public let from: ProgressionJourneyNodeID
    public let to: ProgressionJourneyNodeID
}

public struct ProgressionJourneyGraph: Decodable, Equatable, Sendable {
    public let nodes: [ProgressionJourneyNode]
    public let edges: [ProgressionJourneyEdge]
}

public enum ProgressionRevealSettingType: String, Decodable, Sendable {
    case bool
}

public enum ProgressionRevealSettingOwner: String, Decodable, Sendable {
    case forsettiRuntime = "forsetti-runtime"
}

public struct ProgressionRevealSetting: Decodable, Equatable, Sendable {
    public let settingID: RuntimeSettingID
    public let type: ProgressionRevealSettingType
    public let `default`: Bool
    public let owner: ProgressionRevealSettingOwner
}

public enum ProgressionRevealHaptic: String, CaseIterable, Decodable, Sendable {
    case lightSuccess = "light-success"
    case success
}

public struct ProgressionRevealTierDefinition: Decodable, Equatable, Sendable {
    public let tier: ProgressionCatalogRevealTier
    public let durationSeconds: [Double]
    public let visual: String
    public let soundSemanticID: EffectID
    public let genericFallbackResourceID: EffectID
    public let haptic: ProgressionRevealHaptic
}

public struct ProgressionRevealAccessibility: Decodable, Equatable, Sendable {
    public let reduceMotion: String
    public let voiceOver: String
    public let silentMode: String
    public let dismissal: String
}

public struct ProgressionRevealPolicy: Decodable, Equatable, Sendable {
    public let settings: [ProgressionRevealSetting]
    public let combineRule: String
    public let safePresentationConditions: [String]
    public let tiers: [ProgressionRevealTierDefinition]
    public let accessibility: ProgressionRevealAccessibility
}

public struct ProgressionGameCenterPolicy: Decodable, Equatable, Sendable {
    public let implementationInScope: Bool
    public let localCatalogPointTotal: UInt16
    public let achievementCount: UInt16
    public let permanentIdentifiersFrozen: Bool
    public let direction: String
}

public enum ProgressionMigrationReveal: String, Decodable, Sendable {
    case suppressed
    case oneCombinedReveal = "one-combined-reveal"
}

public struct ProgressionMigrationPolicy: Decodable, Equatable, Sendable {
    public let migrationVersion: UInt16
    public let startingGrantGroupID: GrantGroupID
    public let seedSafelyDerivableCipherStatistics: Bool
    public let evaluateArchivistAchievementsAfterSafeSeed: Bool
    public let backfillPastShares: Bool
    public let backfillPastDecodes: Bool
    public let backfillDistinctRelationshipsFromDeliveredFlags: Bool
    public let includedGrantReveal: ProgressionMigrationReveal
    public let derivedMigrationRewardsReveal: ProgressionMigrationReveal
}

public enum ProgressionPrinciple: String, CaseIterable, Decodable, Sendable {
    case directAccomplishmentsNotXP = "direct-accomplishments-not-xp"
    case noCurrency = "no-currency"
    case noStreakPressure = "no-streak-pressure"
    case noLootBoxes = "no-loot-boxes"
    case cosmeticAndExperientialRewardsOnly = "cosmetic-and-experiential-rewards-only"
    case readingAndDecodingNeverGated = "reading-and-decoding-never-gated"
    case automaticPermanentIrrevocableOrdinaryGrants =
        "automatic-permanent-irrevocable-ordinary-grants"
    case localFirst = "local-first"
    case distinctReachOverRawVolume = "distinct-reach-over-raw-volume"
    case reciprocityOverSpam = "reciprocity-over-spam"
}

public enum ProgressionDeferredFeature: String, CaseIterable, Decodable, Sendable {
    case privateICloudSync = "private-icloud-sync"
    case gameCenterRuntimeIntegration = "game-center-runtime-integration"
    case forgeLedger = "forge-ledger"
    case globalLimitedEditions = "global-limited-editions"
    case seasonalRules = "seasonal-rules"
    case productionThemeAssets = "production-theme-assets"
    case themeSpecificUnlockAudio = "theme-specific-unlock-audio"
}

public struct ProgressionCatalog: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    public let catalogID: ProgressionCatalogID
    public let catalogVersion: ProgressionCatalogVersion
    public let packageVersion: SemanticVersion
    public let status: ProgressionCatalogApprovalStatus
    public let effectiveDate: String
    public let governingObjective: String
    public let principles: [ProgressionPrinciple]
    public let content: [ProgressionContentDefinition]
    public let statistics: [ProgressionStatisticDefinition]
    public let achievements: [ProgressionAchievementDefinition]
    public let milestones: [ProgressionMilestoneDefinition]
    public let grantGroups: [ProgressionGrantGroup]
    public let journeyGraph: ProgressionJourneyGraph
    public let revealPolicy: ProgressionRevealPolicy
    public let gameCenterPolicy: ProgressionGameCenterPolicy
    public let migration: ProgressionMigrationPolicy
    public let deferred: [ProgressionDeferredFeature]
}

public enum ProgressionApplyOutcome: String, CaseIterable, Decodable, Sendable {
    case applied
    case duplicate
    case ignoredIneligible = "ignored-ineligible"
    case rejectedPermanent = "rejected-permanent"
    case deferredUnsupportedSchema = "deferred-unsupported-schema"
    case deferredStoreUnavailable = "deferred-store-unavailable"
}

public enum ProgressionEventPayloadField: String, CaseIterable, Decodable, Sendable {
    case artifactIDs
    case cipherToken
    case codexIDs
    case embeddedCipher
    case keyIncluded
    case linkedRelationship
    case messageToken
    case origin
    case packageToken
    case provenanceStatus
    case relationshipToken
    case routeClass
}

public enum ProgressionEventRequiredOrigin: String, Decodable, Sendable {
    case generated
    case imported
}

public struct ProgressionEventRequiredValues: Decodable, Equatable, Sendable {
    public let origin: ProgressionEventRequiredOrigin?
    public let keyIncluded: Bool?
    public let linkedRelationship: Bool?
}

public struct ProgressionEventDefinition: Decodable, Equatable, Sendable {
    public let eventType: EventIdentifier
    public let producer: String
    public let emissionPoint: String
    public let requiredPayload: [ProgressionEventPayloadField]
    public let optionalPayload: [ProgressionEventPayloadField]?
    public let requiredValues: ProgressionEventRequiredValues?
    public let semanticDedupe: [ProgressionEventPayloadField]
    public let updates: [StatisticID]
    public let notes: String?
}

public enum ProgressionShareRouteClass: String, CaseIterable, Decodable, Sendable {
    case messages
    case shareSheet = "share-sheet"
    case airDrop = "air-drop"
    case fileExport = "file-export"
    case clipboard
    case qrDisplay = "qr-display"
    case any
}

public enum ProgressionShareTerminalResult: String, CaseIterable, Decodable, Sendable {
    case sentConfirmed = "sent-confirmed"
    case completedBySystem = "completed-by-system"
    case completionUnavailable = "completion-unavailable"
    case presented
    case cancelled
    case failed
}

public struct ProgressionShareRoutePolicy: Decodable, Equatable, Sendable {
    public let routeClass: ProgressionShareRouteClass
    public let terminalResult: ProgressionShareTerminalResult
    public let requiresAttachmentAcceptedWhenKeyDelivery: Bool?
    public let progressionEligible: Bool
    public let firstDeliveryEligible: Bool
    public let notes: String?
}

public enum ProgressionForbiddenData: String, CaseIterable, Decodable, Sendable {
    case plaintext
    case encryptedPayloadBytes = "encrypted-payload-bytes"
    case cipherKeyMaterial = "cipher-key-material"
    case fullDecorativeMapping = "full-decorative-mapping"
    case phoneNumber = "phone-number"
    case emailAddress = "email-address"
    case contactName = "contact-name"
    case rawContactsIdentifier = "raw-contacts-identifier"
    case shareRecipientIdentity = "share-recipient-identity"
    case gameCenterPlayerID = "game-center-player-id"
    case clipboardContents = "clipboard-contents"
    case fileOrPackageBytes = "file-or-package-bytes"
}

public struct ProgressionEventCatalog: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    public let catalogID: ProgressionCatalogID
    public let catalogVersion: ProgressionCatalogVersion
    public let status: ProgressionCatalogApprovalStatus
    public let effectiveDate: String
    public let eventEnvelope: String
    public let applyOutcomes: [ProgressionApplyOutcome]
    public let acknowledgeOutboxOn: [ProgressionApplyOutcome]
    public let retainOutboxOn: [ProgressionApplyOutcome]
    public let events: [ProgressionEventDefinition]
    public let shareRoutePolicy: [ProgressionShareRoutePolicy]
    public let forbiddenData: [ProgressionForbiddenData]
    public let eligibilityReasonIDs: [EligibilityReasonID]
}

public enum ProgressionThemeBindingStatus: String, Decodable, Sendable {
    case approved
}

public enum ProgressionThemeBindingCriticality: String, CaseIterable, Decodable, Sendable {
    case requiredBase = "required-base"
    case optional
}

public enum ProgressionThemeBindingGate: String, Decodable, Sendable {
    case included
}

public struct ProgressionThemeBinding: Decodable, Equatable, Sendable {
    public let codexID: CodexID
    public let moduleID: ModuleIdentifier
    public let entitlementID: UnlockID
    public let gate: ProgressionThemeBindingGate?
    public let gateRuleID: RuleID?
    public let criticality: ProgressionThemeBindingCriticality
    public let fallback: Bool?
    public let fallbackCodexID: CodexID?
}

public struct ProgressionThemeSupersession: Decodable, Equatable, Sendable {
    public let source: String
    public let path: String
    public let old: String
    public let new: String
}

public struct ProgressionFutureThemeBindingContract: Decodable, Equatable, Sendable {
    public let schemaVersion: String
    public let contractID: ProgressionCatalogID
    public let version: ProgressionCatalogVersion
    public let status: ProgressionThemeBindingStatus
    public let bindings: [ProgressionThemeBinding]
    public let rules: [String]
    public let supersessions: [ProgressionThemeSupersession]
}

public struct ProgressionDependencyAnalysis: Equatable, Sendable {
    public let directEdges: [Edge]
    /// Informational monotonic reward-effect components. These are not direct
    /// rule-reference cycles and therefore are intentionally accepted. Catalog
    /// v1 contains the Collector/Master Scribe/Gloamthorn fixed-point component.
    public let rewardEffectStronglyConnectedComponents: [[String]]

    public struct Edge: Equatable, Hashable, Sendable {
        public let dependent: String
        public let prerequisite: String

        public init(dependent: String, prerequisite: String) {
            self.dependent = dependent
            self.prerequisite = prerequisite
        }
    }

    public init(
        directEdges: [Edge],
        rewardEffectStronglyConnectedComponents: [[String]]
    ) {
        self.directEdges = directEdges
        self.rewardEffectStronglyConnectedComponents =
            rewardEffectStronglyConnectedComponents
    }
}

public struct ValidatedProgressionCatalogBundle: Equatable, Sendable {
    public let catalog: ProgressionCatalog
    public let eventCatalog: ProgressionEventCatalog
    public let futureThemeBindings: ProgressionFutureThemeBindingContract
    public let dependencyAnalysis: ProgressionDependencyAnalysis
    public let integrityMetadata: ProgressionCatalogIntegrityMetadata

    public init(
        catalog: ProgressionCatalog,
        eventCatalog: ProgressionEventCatalog,
        futureThemeBindings: ProgressionFutureThemeBindingContract,
        dependencyAnalysis: ProgressionDependencyAnalysis,
        integrityMetadata: ProgressionCatalogIntegrityMetadata
    ) {
        self.catalog = catalog
        self.eventCatalog = eventCatalog
        self.futureThemeBindings = futureThemeBindings
        self.dependencyAnalysis = dependencyAnalysis
        self.integrityMetadata = integrityMetadata
    }
}

public struct ProgressionCatalogIntegrityMetadata: Equatable, Sendable {
    public let catalogSHA256: ProgressionSHA256Digest
    public let eventCatalogSHA256: ProgressionSHA256Digest

    public init(
        catalogSHA256: ProgressionSHA256Digest,
        eventCatalogSHA256: ProgressionSHA256Digest
    ) {
        self.catalogSHA256 = catalogSHA256
        self.eventCatalogSHA256 = eventCatalogSHA256
    }
}
