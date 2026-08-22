import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ProgressionDomainError: Error, Equatable, Sendable {
    case invalidRecord(String)
    case recordIdentityCollision(String)
    case unsupportedRecordSchema(UInt16)
    case missingMetadata
    case catalogMismatch
    case unsafeNonemptyInitialization
    case transactionIdentityCollision
    case commandAlreadyCompleted(UInt64)
    case unknownContent(String)
    case unknownTitle(TitleID)
    case unownedTitle(TitleID)
    case unknownReveal(RevealID)
    case rebuildConfirmationMismatch
}

enum ProgressionRecordConstants {
    static let schemaVersion: UInt16 = 1
    static let maximumCanonicalMaterialBytes = 4_096
    static let maximumSourceCount = 64
    static let maximumGrantKeys = 64
}

struct ProgressionMetadataRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let catalogID: ProgressionCatalogID
    let catalogVersion: ProgressionCatalogVersion
    let activeGeneration: String
    var revision: UInt64
    var lastMutationAt: Date?
    var initializedAt: Date?
    var appliedEventCount: UInt64
    var lastAppliedRevision: UInt64?
    var appliedEventDigest: String?
    var processedEventCount: UInt64
    var terminalProcessedEventDigest: String?
    var distinctTokenCount: UInt64
    var acknowledgedRevealCount: UInt64
    var acknowledgedRevealDigest: String?
    var commandReceiptCount: UInt64
    var commandReceiptDigest: String?
    var knownInactiveQuarantineCount: UInt64

    init(
        catalogID: ProgressionCatalogID,
        catalogVersion: ProgressionCatalogVersion,
        activeGeneration: String,
        revision: UInt64 = 0,
        lastMutationAt: Date? = nil,
        initializedAt: Date? = nil,
        appliedEventCount: UInt64 = 0,
        lastAppliedRevision: UInt64? = nil,
        appliedEventDigest: String? = nil,
        processedEventCount: UInt64 = 0,
        terminalProcessedEventDigest: String? = nil,
        distinctTokenCount: UInt64 = 0,
        acknowledgedRevealCount: UInt64 = 0,
        acknowledgedRevealDigest: String? = nil,
        commandReceiptCount: UInt64 = 0,
        commandReceiptDigest: String? = nil,
        knownInactiveQuarantineCount: UInt64 = 0
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.catalogID = catalogID
        self.catalogVersion = catalogVersion
        self.activeGeneration = activeGeneration
        self.revision = revision
        self.lastMutationAt = lastMutationAt
        self.initializedAt = initializedAt
        self.appliedEventCount = appliedEventCount
        self.lastAppliedRevision = lastAppliedRevision
        self.appliedEventDigest = appliedEventDigest
        self.processedEventCount = processedEventCount
        self.terminalProcessedEventDigest = terminalProcessedEventDigest
        self.distinctTokenCount = distinctTokenCount
        self.acknowledgedRevealCount = acknowledgedRevealCount
        self.acknowledgedRevealDigest = acknowledgedRevealDigest
        self.commandReceiptCount = commandReceiptCount
        self.commandReceiptDigest = commandReceiptDigest
        self.knownInactiveQuarantineCount = knownInactiveQuarantineCount
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard ProgressionDeterminism.isDigest(activeGeneration),
              isFinite(lastMutationAt),
              isFinite(initializedAt),
              (revision == 0) == (lastMutationAt == nil),
              (appliedEventCount == 0) ==
                (lastAppliedRevision == nil && appliedEventDigest == nil),
              appliedEventCount == 0 ||
                (lastAppliedRevision.map({ $0 > 0 && $0 <= revision }) == true &&
                    appliedEventDigest.map(ProgressionDeterminism.isDigest) == true),
              processedEventCount >= appliedEventCount,
              ((processedEventCount - appliedEventCount) == 0) ==
                (terminalProcessedEventDigest == nil),
              terminalProcessedEventDigest.map(ProgressionDeterminism.isIntegrityDigest) ?? true,
              (acknowledgedRevealCount == 0) == (acknowledgedRevealDigest == nil),
              acknowledgedRevealDigest.map(ProgressionDeterminism.isIntegrityDigest) ?? true,
              (commandReceiptCount == 0) == (commandReceiptDigest == nil),
              commandReceiptDigest.map(ProgressionDeterminism.isIntegrityDigest) ?? true,
              commandReceiptCount >= acknowledgedRevealCount
        else { throw ProgressionDomainError.invalidRecord("metadata") }
    }
}

enum ProgressionProcessedEventOutcome: String, Codable, Sendable {
    case applied
    case duplicate
    case ignoredIneligible = "ignored-ineligible"
    case rejectedPermanent = "rejected-permanent"
}

struct ProcessedEventRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let eventID: EventID
    let envelopeDigest: String
    let semanticDigest: String?
    let envelope: DomainEventEnvelope
    let outcome: ProgressionProcessedEventOutcome
    let rejectionCode: ProgressionRejectionCode?
    let transactionID: GrantTransactionID?
    let appliedRevision: UInt64?

    init(
        envelope: DomainEventEnvelope,
        envelopeDigest: String,
        semanticDigest: String?,
        outcome: ProgressionProcessedEventOutcome,
        rejectionCode: ProgressionRejectionCode? = nil,
        transactionID: GrantTransactionID? = nil,
        appliedRevision: UInt64? = nil
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        eventID = envelope.eventID
        self.envelopeDigest = envelopeDigest
        self.semanticDigest = semanticDigest
        self.envelope = envelope
        self.outcome = outcome
        self.rejectionCode = rejectionCode
        self.transactionID = transactionID
        self.appliedRevision = appliedRevision
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard eventID == envelope.eventID,
              ProgressionDeterminism.isDigest(envelopeDigest),
              semanticDigest.map(ProgressionDeterminism.isDigest) ?? true,
              envelopeDigest == (try ProgressionDeterminism.encodedDigest(envelope))
        else { throw ProgressionDomainError.invalidRecord("processed-event") }

        switch outcome {
        case .applied:
            guard rejectionCode == nil, transactionID != nil,
                  appliedRevision.map({ $0 > 0 }) == true,
                  transactionID == GrantTransactionID(
                    rawValue: "transaction.\(eventID.rawValue.uuidString.lowercased())"
                  )
            else { throw ProgressionDomainError.invalidRecord("processed-event-outcome") }
        case .duplicate, .ignoredIneligible:
            guard rejectionCode == nil, transactionID == nil, appliedRevision == nil else {
                throw ProgressionDomainError.invalidRecord("processed-event-outcome")
            }
        case .rejectedPermanent:
            guard rejectionCode != nil, transactionID == nil, appliedRevision == nil else {
                throw ProgressionDomainError.invalidRecord("processed-event-outcome")
            }
        }
    }
}

struct ProgressionAppliedEventOrderRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let appliedRevision: UInt64
    let eventID: EventID
    let envelope: DomainEventEnvelope
    let envelopeDigest: String
    let cumulativeDigest: String

    init(
        appliedRevision: UInt64,
        envelope: DomainEventEnvelope,
        cumulativeDigest: String
    ) throws {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.appliedRevision = appliedRevision
        eventID = envelope.eventID
        self.envelope = envelope
        envelopeDigest = try ProgressionDeterminism.encodedDigest(envelope)
        self.cumulativeDigest = cumulativeDigest
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard appliedRevision > 0,
              eventID == envelope.eventID,
              envelopeDigest == (try ProgressionDeterminism.encodedDigest(envelope)),
              ProgressionDeterminism.isDigest(cumulativeDigest)
        else {
            throw ProgressionDomainError.invalidRecord("applied-event-order")
        }
    }
}

struct ProgressionRecoveryEventCandidateRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let appliedRevision: UInt64
    let eventID: EventID
    let envelope: DomainEventEnvelope
    let envelopeDigest: String
    let sourceCumulativeDigest: String?
    let hasProcessedSource: Bool
    let conflictingProcessedEnvelope: DomainEventEnvelope?

    init(
        generation: String,
        appliedRevision: UInt64,
        envelope: DomainEventEnvelope,
        sourceCumulativeDigest: String?,
        hasProcessedSource: Bool,
        conflictingProcessedEnvelope: DomainEventEnvelope? = nil
    ) throws {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.appliedRevision = appliedRevision
        eventID = envelope.eventID
        self.envelope = envelope
        envelopeDigest = try ProgressionDeterminism.encodedDigest(envelope)
        self.sourceCumulativeDigest = sourceCumulativeDigest
        self.hasProcessedSource = hasProcessedSource
        self.conflictingProcessedEnvelope = conflictingProcessedEnvelope
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard appliedRevision > 0,
              eventID == envelope.eventID,
              envelopeDigest == (try ProgressionDeterminism.encodedDigest(envelope)),
              sourceCumulativeDigest.map(ProgressionDeterminism.isDigest) ?? true,
              sourceCumulativeDigest != nil || hasProcessedSource,
              conflictingProcessedEnvelope == nil ||
                (sourceCumulativeDigest != nil &&
                    hasProcessedSource &&
                    conflictingProcessedEnvelope != envelope)
        else { throw ProgressionDomainError.invalidRecord("recovery-event-candidate") }
        if let conflictingProcessedEnvelope {
            _ = try ProgressionDeterminism.encodedDigest(conflictingProcessedEnvelope)
        }
    }
}

struct ProgressionSemanticDedupeRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let digest: String
    let canonicalMaterial: String
    let firstEventID: EventID

    init(canonicalMaterial: String, firstEventID: EventID) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        digest = ProgressionDeterminism.digest128(canonicalMaterial)
        self.canonicalMaterial = canonicalMaterial
        self.firstEventID = firstEventID
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard !canonicalMaterial.isEmpty,
              canonicalMaterial.utf8.count <= ProgressionRecordConstants.maximumCanonicalMaterialBytes,
              digest == ProgressionDeterminism.digest128(canonicalMaterial)
        else { throw ProgressionDomainError.invalidRecord("semantic-dedupe") }
    }
}

struct StatisticCounterRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let statisticID: StatisticID
    let bucketID: CodexID?
    var value: UInt64

    init(generation: String, statisticID: StatisticID, bucketID: CodexID?, value: UInt64) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.statisticID = statisticID
        self.bucketID = bucketID
        self.value = value
    }

    func validate() throws { try validateGeneration(schemaVersion, generation) }
}

struct DistinctTokenRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let statisticID: StatisticID
    let bucketID: CodexID?
    let tokenDigest: String
    let canonicalToken: String?
    let externalOpaqueTokenDigest: String?
    let firstObservedAt: Date?
    let sourceExternalMergeTransactionID: UUID?
    let firstAppliedRevision: UInt64

    init(
        generation: String,
        statisticID: StatisticID,
        bucketID: CodexID?,
        canonicalToken: String,
        firstObservedAt: Date? = nil,
        firstAppliedRevision: UInt64
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.statisticID = statisticID
        self.bucketID = bucketID
        tokenDigest = ProgressionDeterminism.digest128(canonicalToken)
        self.canonicalToken = canonicalToken
        externalOpaqueTokenDigest = nil
        self.firstObservedAt = firstObservedAt
        sourceExternalMergeTransactionID = nil
        self.firstAppliedRevision = firstAppliedRevision
    }

    init(
        generation: String,
        statisticID: StatisticID,
        bucketID: CodexID?,
        externalOpaqueTokenDigest: String,
        firstObservedAt: Date,
        sourceExternalMergeTransactionID: UUID,
        firstAppliedRevision: UInt64
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.statisticID = statisticID
        self.bucketID = bucketID
        tokenDigest = externalOpaqueTokenDigest
        canonicalToken = nil
        self.externalOpaqueTokenDigest = externalOpaqueTokenDigest
        self.firstObservedAt = firstObservedAt
        self.sourceExternalMergeTransactionID = sourceExternalMergeTransactionID
        self.firstAppliedRevision = firstAppliedRevision
    }

    init(generation: String, copying record: DistinctTokenRecord) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        statisticID = record.statisticID
        bucketID = record.bucketID
        tokenDigest = record.tokenDigest
        canonicalToken = record.canonicalToken
        externalOpaqueTokenDigest = record.externalOpaqueTokenDigest
        firstObservedAt = record.firstObservedAt
        sourceExternalMergeTransactionID = record.sourceExternalMergeTransactionID
        firstAppliedRevision = record.firstAppliedRevision
    }

    var cloudOpaqueTokenDigest: String {
        externalOpaqueTokenDigest ?? RuntimeIntegrityDigest.sha256Hex(
            Data("progression-distinct|\(tokenDigest)".utf8)
        )
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        let isLocal: Bool
        if let canonicalToken {
            isLocal = !canonicalToken.isEmpty &&
                canonicalToken.utf8.count <= 256 &&
                tokenDigest == ProgressionDeterminism.digest128(canonicalToken) &&
                externalOpaqueTokenDigest == nil &&
                sourceExternalMergeTransactionID == nil
        } else {
            isLocal = false
        }
        let isExternal = canonicalToken == nil &&
            externalOpaqueTokenDigest == tokenDigest &&
            sourceExternalMergeTransactionID != nil &&
            tokenDigest.utf8.count == 64 &&
            tokenDigest.utf8.allSatisfy({ byte in
                (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
            })
        guard (isLocal || isExternal),
              firstObservedAt.map(isFinite) ?? true,
              firstAppliedRevision > 0
        else { throw ProgressionDomainError.invalidRecord("distinct-token") }
    }
}

struct StatisticContentUseRecord: Codable, Equatable, Sendable {
    static let maximumContentCount = 82

    let schemaVersion: UInt16
    let generation: String
    let statisticID: StatisticID
    let bucketID: CodexID?
    var contentIDs: [ProgressionContentID]

    init(
        generation: String,
        statisticID: StatisticID,
        bucketID: CodexID?,
        contentIDs: [ProgressionContentID]
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.statisticID = statisticID
        self.bucketID = bucketID
        self.contentIDs = contentIDs.sorted { $0.rawValue < $1.rawValue }
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard contentIDs.count <= Self.maximumContentCount,
              Set(contentIDs).count == contentIDs.count,
              contentIDs == contentIDs.sorted(by: { $0.rawValue < $1.rawValue })
        else { throw ProgressionDomainError.invalidRecord("statistic-content-use") }
    }
}

struct AchievementProgressRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let achievementID: AchievementID
    var current: UInt64
    let target: UInt64

    init(generation: String, achievementID: AchievementID, current: UInt64, target: UInt64) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.achievementID = achievementID
        self.current = current
        self.target = target
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard target > 0, current <= target else {
            throw ProgressionDomainError.invalidRecord("achievement-progress")
        }
    }
}

struct AchievementCompletionRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let achievementID: AchievementID
    let completedAt: Date
    let sourceEventID: EventID?
    let sourceExistingUserMigrationTransactionID: UUID?
    let sourceExternalMergeTransactionID: UUID?

    init(
        generation: String,
        achievementID: AchievementID,
        completedAt: Date,
        sourceEventID: EventID
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.achievementID = achievementID
        self.completedAt = completedAt
        self.sourceEventID = sourceEventID
        sourceExistingUserMigrationTransactionID = nil
        sourceExternalMergeTransactionID = nil
    }

    init(
        generation: String,
        achievementID: AchievementID,
        completedAt: Date,
        sourceExistingUserMigrationTransactionID: UUID
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.achievementID = achievementID
        self.completedAt = completedAt
        sourceEventID = nil
        self.sourceExistingUserMigrationTransactionID =
            sourceExistingUserMigrationTransactionID
        sourceExternalMergeTransactionID = nil
    }

    init(
        generation: String,
        achievementID: AchievementID,
        completedAt: Date,
        sourceExternalMergeTransactionID: UUID
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.achievementID = achievementID
        self.completedAt = completedAt
        sourceEventID = nil
        sourceExistingUserMigrationTransactionID = nil
        self.sourceExternalMergeTransactionID = sourceExternalMergeTransactionID
    }

    init(
        generation: String,
        preservingProvenance record: AchievementCompletionRecord,
        completedAt: Date,
        sourceExternalMergeTransactionID: UUID
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        achievementID = record.achievementID
        self.completedAt = completedAt
        sourceEventID = record.sourceEventID
        sourceExistingUserMigrationTransactionID =
            record.sourceExistingUserMigrationTransactionID
        self.sourceExternalMergeTransactionID = sourceExternalMergeTransactionID
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        let authoritativeOriginCount = [
            sourceEventID != nil,
            sourceExistingUserMigrationTransactionID != nil,
        ].filter { $0 }.count
        guard isFinite(completedAt),
              authoritativeOriginCount == 1 || (
                authoritativeOriginCount == 0 &&
                    sourceExternalMergeTransactionID != nil
              )
        else {
            throw ProgressionDomainError.invalidRecord("achievement-completion")
        }
    }
}

struct MilestoneCompletionRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let ruleID: RuleID
    let completedAt: Date
    let sourceEventID: EventID?
    let sourceExternalMergeTransactionID: UUID?

    init(generation: String, ruleID: RuleID, completedAt: Date, sourceEventID: EventID) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.ruleID = ruleID
        self.completedAt = completedAt
        self.sourceEventID = sourceEventID
        sourceExternalMergeTransactionID = nil
    }

    init(
        generation: String,
        ruleID: RuleID,
        completedAt: Date,
        sourceExternalMergeTransactionID: UUID
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.ruleID = ruleID
        self.completedAt = completedAt
        sourceEventID = nil
        self.sourceExternalMergeTransactionID = sourceExternalMergeTransactionID
    }

    init(
        generation: String,
        preservingProvenance record: MilestoneCompletionRecord,
        completedAt: Date,
        sourceExternalMergeTransactionID: UUID
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        ruleID = record.ruleID
        self.completedAt = completedAt
        sourceEventID = record.sourceEventID
        self.sourceExternalMergeTransactionID = sourceExternalMergeTransactionID
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard isFinite(completedAt),
              sourceEventID != nil || sourceExternalMergeTransactionID != nil
        else {
            throw ProgressionDomainError.invalidRecord("milestone-completion")
        }
    }
}

enum ProgressionGrantSource: Codable, Equatable, Hashable, Sendable {
    case migration(UInt16)
    case achievement(AchievementID)
    case milestone(RuleID)

    var key: String {
        switch self {
        case let .migration(version): "migration.\(version)"
        case let .achievement(id): "achievement.\(id.rawValue)"
        case let .milestone(id): "milestone.\(id.rawValue)"
        }
    }
}

struct GrantRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let grantGroupID: GrantGroupID
    let contentID: ProgressionContentID
    let source: ProgressionGrantSource
    let transactionID: GrantTransactionID
    let grantedAt: Date?

    init(
        generation: String,
        grantGroupID: GrantGroupID,
        contentID: ProgressionContentID,
        source: ProgressionGrantSource,
        transactionID: GrantTransactionID,
        grantedAt: Date?
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.grantGroupID = grantGroupID
        self.contentID = contentID
        self.source = source
        self.transactionID = transactionID
        self.grantedAt = grantedAt
    }

    init(generation: String, copying record: GrantRecord, grantedAt: Date?) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        grantGroupID = record.grantGroupID
        contentID = record.contentID
        source = record.source
        transactionID = record.transactionID
        self.grantedAt = grantedAt
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        let permitsRuntimeOwnedBootstrapTime: Bool
        if case .migration = source {
            permitsRuntimeOwnedBootstrapTime = true
        } else {
            permitsRuntimeOwnedBootstrapTime = false
        }
        guard isFinite(grantedAt), grantedAt != nil || permitsRuntimeOwnedBootstrapTime else {
            throw ProgressionDomainError.invalidRecord("grant")
        }
    }
}

struct OwnershipRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let contentID: ProgressionContentID
    var sourceGrantKeys: [String]
    var grantedAt: Date?

    init(
        generation: String,
        contentID: ProgressionContentID,
        sourceGrantKeys: [String],
        grantedAt: Date?
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.contentID = contentID
        self.sourceGrantKeys = sourceGrantKeys.sorted()
        self.grantedAt = grantedAt
    }

    init(generation: String, copying record: OwnershipRecord, grantedAt: Date?) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        contentID = record.contentID
        sourceGrantKeys = record.sourceGrantKeys
        self.grantedAt = grantedAt
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard !sourceGrantKeys.isEmpty,
              sourceGrantKeys.count <= ProgressionRecordConstants.maximumGrantKeys,
              Set(sourceGrantKeys).count == sourceGrantKeys.count,
              sourceGrantKeys == sourceGrantKeys.sorted(),
              sourceGrantKeys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              isFinite(grantedAt),
              grantedAt != nil || sourceGrantKeys.allSatisfy({
                  $0.hasPrefix("grant|") && $0.contains("|migration.")
              })
        else { throw ProgressionDomainError.invalidRecord("ownership") }
    }
}

enum ProgressionEntitlementSource: String, Codable, Sendable {
    case included
    case earned
}

struct ProgressionEntitlementRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let entitlementID: UnlockID
    let contentID: ProgressionContentID
    let source: ProgressionEntitlementSource
    let grantedAt: Date?

    init(
        generation: String,
        entitlementID: UnlockID,
        contentID: ProgressionContentID,
        source: ProgressionEntitlementSource,
        grantedAt: Date?
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.entitlementID = entitlementID
        self.contentID = contentID
        self.source = source
        self.grantedAt = grantedAt
    }

    init(
        generation: String,
        copying record: ProgressionEntitlementRecord,
        grantedAt: Date?
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        entitlementID = record.entitlementID
        contentID = record.contentID
        source = record.source
        self.grantedAt = grantedAt
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard isFinite(grantedAt), grantedAt != nil || source == .included else {
            throw ProgressionDomainError.invalidRecord("entitlement")
        }
    }
}

struct EncounterRecord: Codable, Equatable, Sendable {
    struct ArtifactObservation: Codable, Equatable, Sendable {
        let artifactID: ArtifactID
        var firstEncounteredAt: Date
        var lastEncounteredAt: Date
        var encounterCount: UInt64
        var provenanceStatus: DomainEventProvenanceStatus

        func validate() throws {
            guard isFinite(firstEncounteredAt), isFinite(lastEncounteredAt),
                  firstEncounteredAt <= lastEncounteredAt,
                  encounterCount > 0
            else { throw ProgressionDomainError.invalidRecord("artifact-observation") }
        }
    }

    let schemaVersion: UInt16
    let generation: String
    let codexID: CodexID
    var artifactObservations: [ArtifactObservation]
    let firstEncounteredAt: Date
    var lastEncounteredAt: Date
    var encounterCount: UInt64
    var provenanceStatus: DomainEventProvenanceStatus

    init(
        generation: String,
        codexID: CodexID,
        artifactIDs: [ArtifactID],
        firstEncounteredAt: Date,
        lastEncounteredAt: Date,
        encounterCount: UInt64,
        provenanceStatus: DomainEventProvenanceStatus
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.codexID = codexID
        self.artifactObservations = artifactIDs.sorted().map {
            ArtifactObservation(
                artifactID: $0,
                firstEncounteredAt: firstEncounteredAt,
                lastEncounteredAt: lastEncounteredAt,
                encounterCount: 1,
                provenanceStatus: provenanceStatus
            )
        }
        self.firstEncounteredAt = firstEncounteredAt
        self.lastEncounteredAt = lastEncounteredAt
        self.encounterCount = encounterCount
        self.provenanceStatus = provenanceStatus
    }

    init(
        generation: String,
        codexID: CodexID,
        artifactObservations: [ArtifactObservation],
        firstEncounteredAt: Date,
        lastEncounteredAt: Date,
        encounterCount: UInt64,
        provenanceStatus: DomainEventProvenanceStatus
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.codexID = codexID
        self.artifactObservations = artifactObservations.sorted {
            $0.artifactID < $1.artifactID
        }
        self.firstEncounteredAt = firstEncounteredAt
        self.lastEncounteredAt = lastEncounteredAt
        self.encounterCount = encounterCount
        self.provenanceStatus = provenanceStatus
    }

    var artifactIDs: [ArtifactID] { artifactObservations.map(\.artifactID) }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard artifactObservations.count <= StatisticContentUseRecord.maximumContentCount,
              Set(artifactObservations.map(\.artifactID)).count == artifactObservations.count,
              artifactObservations.map(\.artifactID) ==
                artifactObservations.map(\.artifactID).sorted(),
              isFinite(firstEncounteredAt), isFinite(lastEncounteredAt),
              firstEncounteredAt <= lastEncounteredAt,
              encounterCount > 0
        else { throw ProgressionDomainError.invalidRecord("encounter") }
        for observation in artifactObservations {
            try observation.validate()
            guard firstEncounteredAt <= observation.firstEncounteredAt,
                  observation.lastEncounteredAt <= lastEncounteredAt,
                  observation.encounterCount <= encounterCount
            else { throw ProgressionDomainError.invalidRecord("artifact-observation-range") }
        }
    }
}

struct TitleSelectionRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    var selectedTitleID: TitleID?
    var selectedAt: Date?

    init(generation: String, selectedTitleID: TitleID?, selectedAt: Date?) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.selectedTitleID = selectedTitleID
        self.selectedAt = selectedAt
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard selectedTitleID == nil || selectedAt != nil,
              isFinite(selectedAt)
        else {
            throw ProgressionDomainError.invalidRecord("title-selection")
        }
    }
}

enum ProgressionPendingRevealState: String, Codable, Sendable {
    case queued
    case presented
    case acknowledged
}

enum ProgressionDurableRevealTier: String, Codable, CaseIterable, Sendable {
    case none
    case micro
    case artifact
    case codex
    case mastery
}

struct PendingRevealRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let revealID: RevealID
    let transactionID: GrantTransactionID
    let createdRevision: UInt64
    let createdAt: Date
    var state: ProgressionPendingRevealState
    var presentedAt: Date?
    var acknowledgedAt: Date?
    let tier: ProgressionDurableRevealTier
    let primaryContentID: ProgressionContentID
    let secondaryContentIDs: [ProgressionContentID]
    let sourceAchievementIDs: [AchievementID]
    let sourceRuleIDs: [RuleID]
    var nextRevealID: RevealID?

    init(
        generation: String,
        revealID: RevealID,
        transactionID: GrantTransactionID,
        createdRevision: UInt64,
        createdAt: Date,
        state: ProgressionPendingRevealState,
        presentedAt: Date? = nil,
        acknowledgedAt: Date?,
        tier: ProgressionDurableRevealTier,
        primaryContentID: ProgressionContentID,
        secondaryContentIDs: [ProgressionContentID],
        sourceAchievementIDs: [AchievementID],
        sourceRuleIDs: [RuleID],
        nextRevealID: RevealID? = nil
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.revealID = revealID
        self.transactionID = transactionID
        self.createdRevision = createdRevision
        self.createdAt = createdAt
        self.state = state
        self.presentedAt = presentedAt
        self.acknowledgedAt = acknowledgedAt
        self.tier = tier
        self.primaryContentID = primaryContentID
        self.secondaryContentIDs = secondaryContentIDs.sorted { $0.rawValue < $1.rawValue }
        self.sourceAchievementIDs = sourceAchievementIDs.sorted()
        self.sourceRuleIDs = sourceRuleIDs.sorted()
        self.nextRevealID = nextRevealID
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard createdRevision > 0, isFinite(createdAt), isFinite(presentedAt),
              isFinite(acknowledgedAt),
              tier != .none,
              secondaryContentIDs.count <= ProgressionRecordConstants.maximumSourceCount,
              sourceAchievementIDs.count <= ProgressionRecordConstants.maximumSourceCount,
              sourceRuleIDs.count <= ProgressionRecordConstants.maximumSourceCount,
              Set(secondaryContentIDs).count == secondaryContentIDs.count,
              Set(sourceAchievementIDs).count == sourceAchievementIDs.count,
              Set(sourceRuleIDs).count == sourceRuleIDs.count,
              !secondaryContentIDs.contains(primaryContentID),
              !sourceAchievementIDs.isEmpty || !sourceRuleIDs.isEmpty
        else { throw ProgressionDomainError.invalidRecord("pending-reveal") }
        switch state {
        case .queued:
            guard presentedAt == nil, acknowledgedAt == nil else {
                throw ProgressionDomainError.invalidRecord("pending-reveal-state")
            }
        case .presented:
            guard let presentedAt, presentedAt >= createdAt, acknowledgedAt == nil else {
                throw ProgressionDomainError.invalidRecord("pending-reveal-state")
            }
        case .acknowledged:
            guard let presentedAt, presentedAt >= createdAt,
                  let acknowledgedAt, acknowledgedAt >= presentedAt
            else {
                throw ProgressionDomainError.invalidRecord("pending-reveal-state")
            }
        }
    }
}

struct ProgressionRevealQueueStateRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    var pendingCount: UInt16
    var headRevealID: RevealID?
    var tailRevealID: RevealID?

    init(
        generation: String,
        pendingCount: UInt16,
        headRevealID: RevealID?,
        tailRevealID: RevealID?
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.pendingCount = pendingCount
        self.headRevealID = headRevealID
        self.tailRevealID = tailRevealID
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard (pendingCount == 0) == (headRevealID == nil && tailRevealID == nil),
              pendingCount != 1 || headRevealID == tailRevealID,
              pendingCount <= 1 || headRevealID != tailRevealID,
              pendingCount == 0 || (headRevealID != nil && tailRevealID != nil)
        else { throw ProgressionDomainError.invalidRecord("reveal-queue-state") }
    }
}

struct CatalogMigrationRecord: Codable, Equatable, Sendable {
    struct CompatibilityFingerprint: Codable, Equatable, Sendable {
        let stableKey: String
        let semanticMaterial: String
        let semanticDigest: String

        func validate() throws {
            guard !stableKey.isEmpty,
                  stableKey.utf8.count <= 512,
                  !semanticMaterial.isEmpty,
                  semanticMaterial.utf8.count <= 16_384,
                  ProgressionDeterminism.isDigest(semanticDigest),
                  semanticDigest == ProgressionDeterminism.digest128(semanticMaterial)
            else { throw ProgressionDomainError.invalidRecord("catalog-fingerprint") }
        }
    }

    static let maximumCompatibilityFingerprints = 4_096

    struct UpgradeRevealBundle: Codable, Equatable, Sendable {
        let tier: ProgressionDurableRevealTier
        let primaryContentID: ProgressionContentID
        let secondaryContentIDs: [ProgressionContentID]
        let sourceAchievementIDs: [AchievementID]
        let sourceRuleIDs: [RuleID]

        init(
            tier: ProgressionDurableRevealTier,
            primaryContentID: ProgressionContentID,
            secondaryContentIDs: [ProgressionContentID],
            sourceAchievementIDs: [AchievementID],
            sourceRuleIDs: [RuleID]
        ) {
            self.tier = tier
            self.primaryContentID = primaryContentID
            self.secondaryContentIDs = secondaryContentIDs.sorted {
                $0.rawValue < $1.rawValue
            }
            self.sourceAchievementIDs = sourceAchievementIDs.sorted()
            self.sourceRuleIDs = sourceRuleIDs.sorted()
        }

        init(reveal: PendingRevealRecord) {
            self.init(
                tier: reveal.tier,
                primaryContentID: reveal.primaryContentID,
                secondaryContentIDs: reveal.secondaryContentIDs,
                sourceAchievementIDs: reveal.sourceAchievementIDs,
                sourceRuleIDs: reveal.sourceRuleIDs
            )
        }

        func validate() throws {
            guard tier != .none,
                  secondaryContentIDs.count <=
                    ProgressionRecordConstants.maximumSourceCount,
                  sourceAchievementIDs.count <=
                    ProgressionRecordConstants.maximumSourceCount,
                  sourceRuleIDs.count <= ProgressionRecordConstants.maximumSourceCount,
                  Set(secondaryContentIDs).count == secondaryContentIDs.count,
                  Set(sourceAchievementIDs).count == sourceAchievementIDs.count,
                  Set(sourceRuleIDs).count == sourceRuleIDs.count,
                  secondaryContentIDs == secondaryContentIDs.sorted(by: {
                      $0.rawValue < $1.rawValue
                  }),
                  sourceAchievementIDs == sourceAchievementIDs.sorted(),
                  sourceRuleIDs == sourceRuleIDs.sorted(),
                  !secondaryContentIDs.contains(primaryContentID),
                  !sourceAchievementIDs.isEmpty || !sourceRuleIDs.isEmpty
            else {
                throw ProgressionDomainError.invalidRecord(
                    "catalog-migration-reveal"
                )
            }
        }
    }

    let schemaVersion: UInt16
    let generation: String
    let migrationVersion: UInt16
    let catalogVersion: ProgressionCatalogVersion
    let transactionID: UUID
    let completedAt: Date?
    let compatibilityFingerprints: [CompatibilityFingerprint]
    let upgradeRevealBundle: UpgradeRevealBundle?
    let priorCatalogVersion: ProgressionCatalogVersion?
    let priorGeneration: String?
    let cleanupCompletedAt: Date?

    init(
        generation: String,
        migrationVersion: UInt16,
        catalogVersion: ProgressionCatalogVersion,
        transactionID: UUID,
        completedAt: Date?,
        compatibilityFingerprints: [CompatibilityFingerprint],
        upgradeRevealBundle: UpgradeRevealBundle? = nil,
        priorCatalogVersion: ProgressionCatalogVersion? = nil,
        priorGeneration: String? = nil,
        cleanupCompletedAt: Date? = nil
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.migrationVersion = migrationVersion
        self.catalogVersion = catalogVersion
        self.transactionID = transactionID
        self.completedAt = completedAt
        self.compatibilityFingerprints = compatibilityFingerprints.sorted {
            $0.stableKey < $1.stableKey
        }
        self.upgradeRevealBundle = upgradeRevealBundle
        self.priorCatalogVersion = priorCatalogVersion
        self.priorGeneration = priorGeneration
        self.cleanupCompletedAt = cleanupCompletedAt
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard migrationVersion > 0,
              isFinite(completedAt),
              !compatibilityFingerprints.isEmpty,
              compatibilityFingerprints.count <= Self.maximumCompatibilityFingerprints,
              Set(compatibilityFingerprints.map(\.stableKey)).count ==
                compatibilityFingerprints.count,
              compatibilityFingerprints.map(\.stableKey) ==
                compatibilityFingerprints.map(\.stableKey).sorted(),
              (priorCatalogVersion == nil) == (priorGeneration == nil),
              priorCatalogVersion.map({ $0 < catalogVersion }) ?? true,
              upgradeRevealBundle == nil || priorCatalogVersion != nil,
              priorGeneration.map(ProgressionDeterminism.isDigest) ?? true,
              priorGeneration != generation,
              isFinite(cleanupCompletedAt),
              cleanupCompletedAt == nil || priorGeneration != nil,
              cleanupCompletedAt.map({ cleanup in
                  completedAt.map { cleanup >= $0 } ?? false
              }) ?? true
        else {
            throw ProgressionDomainError.invalidRecord("catalog-migration")
        }
        for fingerprint in compatibilityFingerprints { try fingerprint.validate() }
        try upgradeRevealBundle?.validate()
    }
}

struct ExistingUserMigrationRecord: Codable, Equatable, Sendable {
    static let migrationVersion: UInt16 = 1

    let schemaVersion: UInt16
    let generation: String
    let version: UInt16
    let snapshotSchemaVersion: UInt16
    let transactionID: UUID
    let snapshotDigest: String
    let cipherCount: UInt32
    let handoffSchemaVersion: UInt16?
    let pageCount: UInt32?
    let completedAt: Date
    let grantTransactionID: GrantTransactionID
    let revealBundle: CatalogMigrationRecord.UpgradeRevealBundle?

    init(
        generation: String,
        snapshotSchemaVersion: UInt16,
        transactionID: UUID,
        snapshotDigest: String,
        cipherCount: UInt32,
        handoffSchemaVersion: UInt16? = nil,
        pageCount: UInt32? = nil,
        completedAt: Date,
        grantTransactionID: GrantTransactionID,
        revealBundle: CatalogMigrationRecord.UpgradeRevealBundle?
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        version = Self.migrationVersion
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.transactionID = transactionID
        self.snapshotDigest = snapshotDigest
        self.cipherCount = cipherCount
        self.handoffSchemaVersion = handoffSchemaVersion
        self.pageCount = pageCount
        self.completedAt = completedAt
        self.grantTransactionID = grantTransactionID
        self.revealBundle = revealBundle
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        let maximum = UInt32(ExistingUserMigrationSnapshotDTO.maximumCipherCount)
        let expectedPageCount = cipherCount == 0
            ? 1
            : ((cipherCount - 1) / maximum) + 1
        let validHandoff = if let handoffSchemaVersion {
            handoffSchemaVersion == ExistingUserMigrationPageDTO
                .currentHandoffSchemaVersion &&
                pageCount == expectedPageCount &&
                expectedPageCount >= 2 &&
                cipherCount > maximum
        } else {
            pageCount == nil && cipherCount <= maximum
        }
        guard version == Self.migrationVersion,
              snapshotSchemaVersion == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              ProgressionDeterminism.isIntegrityDigest(snapshotDigest),
              validHandoff,
              isFinite(completedAt),
              grantTransactionID == existingUserMigrationGrantTransactionID(transactionID),
              (cipherCount < 5) == (revealBundle == nil)
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration")
        }
        try revealBundle?.validate()
    }
}

struct ExistingUserMigrationSeedRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let generation: String
    let migrationVersion: UInt16
    let cipherToken: CipherToken
    let origin: DomainEventOrigin
    let sourcePageIndex: UInt32?

    init(
        generation: String,
        cipherToken: CipherToken,
        origin: DomainEventOrigin,
        sourcePageIndex: UInt32? = nil
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        migrationVersion = ExistingUserMigrationRecord.migrationVersion
        self.cipherToken = cipherToken
        self.origin = origin
        self.sourcePageIndex = sourcePageIndex
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard migrationVersion == ExistingUserMigrationRecord.migrationVersion,
              origin == .generated || origin == .imported
        else { throw ProgressionDomainError.invalidRecord("existing-user-migration-seed") }
    }
}

struct ExistingUserMigrationStageMarkerRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let sourceGeneration: String
    let sourceRevision: UInt64
    let destinationGeneration: String
    let migrationVersion: UInt16
    let snapshotSchemaVersion: UInt16
    let transactionID: UUID
    let snapshotDigest: String
    let cipherCount: UInt32
    let handoffSchemaVersion: UInt16?
    let pageCount: UInt32?
    let operationID: String
    let correlationID: String
    let operationIdentifier: String
    let operationTimestamp: Date

    init(
        sourceGeneration: String,
        sourceRevision: UInt64,
        destinationGeneration: String,
        snapshotSchemaVersion: UInt16,
        transactionID: UUID,
        snapshotDigest: String,
        cipherCount: UInt32,
        handoffSchemaVersion: UInt16? = nil,
        pageCount: UInt32? = nil,
        operationID: String,
        correlationID: String,
        operationIdentifier: String,
        operationTimestamp: Date
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.sourceGeneration = sourceGeneration
        self.sourceRevision = sourceRevision
        self.destinationGeneration = destinationGeneration
        migrationVersion = ExistingUserMigrationRecord.migrationVersion
        self.snapshotSchemaVersion = snapshotSchemaVersion
        self.transactionID = transactionID
        self.snapshotDigest = snapshotDigest
        self.cipherCount = cipherCount
        self.handoffSchemaVersion = handoffSchemaVersion
        self.pageCount = pageCount
        self.operationID = operationID
        self.correlationID = correlationID
        self.operationIdentifier = operationIdentifier
        self.operationTimestamp = operationTimestamp
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        let maximum = UInt32(ExistingUserMigrationSnapshotDTO.maximumCipherCount)
        let expectedPageCount = cipherCount == 0
            ? 1
            : ((cipherCount - 1) / maximum) + 1
        let validHandoff = if let handoffSchemaVersion {
            handoffSchemaVersion == ExistingUserMigrationPageDTO
                .currentHandoffSchemaVersion &&
                pageCount == expectedPageCount &&
                expectedPageCount >= 2 &&
                cipherCount > maximum &&
                operationIdentifier ==
                    "progression.migration.existing-user.page.apply"
        } else {
            pageCount == nil &&
                cipherCount <= maximum &&
                operationIdentifier == "progression.migration.existing-user.apply"
        }
        guard ProgressionDeterminism.isDigest(sourceGeneration),
              ProgressionDeterminism.isDigest(destinationGeneration),
              sourceGeneration != destinationGeneration,
              migrationVersion == ExistingUserMigrationRecord.migrationVersion,
              snapshotSchemaVersion == ExistingUserMigrationSnapshotDTO.currentSchemaVersion,
              ProgressionDeterminism.isIntegrityDigest(snapshotDigest),
              validHandoff,
              ProgressionDeterminism.isBoundedRuntimeIdentifier(operationID),
              ProgressionDeterminism.isBoundedRuntimeIdentifier(correlationID),
              isFinite(operationTimestamp)
        else {
            throw ProgressionDomainError.invalidRecord("existing-user-migration-stage")
        }
    }
}

struct QuarantineRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let category: ProgressionDiagnosticRecordCategory
    let sourceCollectionID: ModuleStateCollectionID
    let sourceRecordDigest: String
    let sourceRevision: UInt64
    let diagnosticCode: ProgressionRejectionCode
    let detectedAt: Date

    init(
        category: ProgressionDiagnosticRecordCategory,
        sourceCollectionID: ModuleStateCollectionID,
        sourceRecordDigest: String,
        sourceRevision: UInt64,
        diagnosticCode: ProgressionRejectionCode,
        detectedAt: Date
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.category = category
        self.sourceCollectionID = sourceCollectionID
        self.sourceRecordDigest = sourceRecordDigest
        self.sourceRevision = sourceRevision
        self.diagnosticCode = diagnosticCode
        self.detectedAt = detectedAt
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard ProgressionDeterminism.isDigest(sourceRecordDigest),
              sourceRevision > 0,
              isFinite(detectedAt)
        else {
            throw ProgressionDomainError.invalidRecord("quarantine")
        }
    }
}

struct ProgressionCommandReceiptRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let operationID: String
    let correlationID: String
    let operationIdentifier: String
    let commandDigest: String
    let completedAt: Date
    let resultRevision: UInt64
    let cleanupGeneration: String?

    init(
        operationID: String,
        correlationID: String,
        operationIdentifier: String,
        commandDigest: String,
        completedAt: Date,
        resultRevision: UInt64,
        cleanupGeneration: String? = nil
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.operationID = operationID
        self.correlationID = correlationID
        self.operationIdentifier = operationIdentifier
        self.commandDigest = commandDigest
        self.completedAt = completedAt
        self.resultRevision = resultRevision
        self.cleanupGeneration = cleanupGeneration
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard ProgressionDeterminism.isBoundedRuntimeIdentifier(operationID),
              ProgressionDeterminism.isBoundedRuntimeIdentifier(correlationID),
              ProgressionDeterminism.isBoundedRuntimeIdentifier(operationIdentifier),
              ProgressionDeterminism.isDigest(commandDigest),
              cleanupGeneration.map(ProgressionDeterminism.isDigest) ?? true,
              isFinite(completedAt), resultRevision > 0
        else { throw ProgressionDomainError.invalidRecord("command-receipt") }
    }
}

struct ProgressionRebuildStageMarkerRecord: Codable, Equatable, Sendable {
    let schemaVersion: UInt16
    let sourceGeneration: String
    let sourceRevision: UInt64
    let destinationGeneration: String
    let operationID: String
    let correlationID: String
    let operationIdentifier: String
    let operationTimestamp: Date

    init(
        sourceGeneration: String,
        sourceRevision: UInt64,
        destinationGeneration: String,
        operationID: String,
        correlationID: String,
        operationIdentifier: String,
        operationTimestamp: Date
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.sourceGeneration = sourceGeneration
        self.sourceRevision = sourceRevision
        self.destinationGeneration = destinationGeneration
        self.operationID = operationID
        self.correlationID = correlationID
        self.operationIdentifier = operationIdentifier
        self.operationTimestamp = operationTimestamp
    }

    func validate() throws {
        try validateSchema(schemaVersion)
        guard ProgressionDeterminism.isDigest(sourceGeneration),
              ProgressionDeterminism.isDigest(destinationGeneration),
              sourceGeneration != destinationGeneration,
              !operationID.isEmpty, operationID.utf8.count <= 256,
              !correlationID.isEmpty, correlationID.utf8.count <= 256,
              operationIdentifier == "progression.recovery.rebuild",
              isFinite(operationTimestamp)
        else { throw ProgressionDomainError.invalidRecord("rebuild-stage-marker") }
    }
}

enum ProgressionLogicalRecord: Codable, Equatable, Sendable {
    case statisticCounter(StatisticCounterRecord)
    case statisticContentUse(StatisticContentUseRecord)
    case achievementProgress(AchievementProgressRecord)
    case achievementCompletion(AchievementCompletionRecord)
    case milestoneCompletion(MilestoneCompletionRecord)
    case grant(GrantRecord)
    case ownership(OwnershipRecord)
    case entitlement(ProgressionEntitlementRecord)
    case encounter(EncounterRecord)
    case titleSelection(TitleSelectionRecord)
    case revealQueueState(ProgressionRevealQueueStateRecord)
    case catalogMigration(CatalogMigrationRecord)
    case existingUserMigration(ExistingUserMigrationRecord)

    var generation: String {
        switch self {
        case let .statisticCounter(value): value.generation
        case let .statisticContentUse(value): value.generation
        case let .achievementProgress(value): value.generation
        case let .achievementCompletion(value): value.generation
        case let .milestoneCompletion(value): value.generation
        case let .grant(value): value.generation
        case let .ownership(value): value.generation
        case let .entitlement(value): value.generation
        case let .encounter(value): value.generation
        case let .titleSelection(value): value.generation
        case let .revealQueueState(value): value.generation
        case let .catalogMigration(value): value.generation
        case let .existingUserMigration(value): value.generation
        }
    }

    var category: ProgressionDiagnosticRecordCategory {
        switch self {
        case .statisticCounter: .statisticCounter
        case .statisticContentUse: .statisticCounter
        case .achievementProgress: .achievementProgress
        case .achievementCompletion: .achievementCompletion
        case .milestoneCompletion: .milestoneCompletion
        case .grant: .grant
        case .ownership: .ownership
        case .entitlement: .entitlement
        case .encounter: .encounter
        case .titleSelection: .titleSelection
        case .revealQueueState: .pendingReveal
        case .catalogMigration: .catalogMigration
        case .existingUserMigration: .catalogMigration
        }
    }

    var identity: String {
        switch self {
        case let .statisticCounter(value):
            "counter|\(value.statisticID.rawValue)|\(value.bucketID?.rawValue ?? "-")"
        case let .statisticContentUse(value):
            "content-use|\(value.statisticID.rawValue)|\(value.bucketID?.rawValue ?? "-")"
        case let .achievementProgress(value):
            "achievement-progress|\(value.achievementID.rawValue)"
        case let .achievementCompletion(value):
            "achievement-completion|\(value.achievementID.rawValue)"
        case let .milestoneCompletion(value):
            "milestone-completion|\(value.ruleID.rawValue)"
        case let .grant(value):
            "grant|\(value.grantGroupID.rawValue)|\(value.contentID.rawValue)|\(value.source.key)"
        case let .ownership(value):
            "ownership|\(value.contentID.rawValue)"
        case let .entitlement(value):
            "entitlement|\(value.entitlementID.rawValue)"
        case let .encounter(value):
            "encounter|\(value.codexID.rawValue)"
        case .titleSelection:
            "title-selection"
        case .revealQueueState:
            "reveal-queue-state"
        case let .catalogMigration(value):
            "catalog-migration|\(value.migrationVersion)"
        case let .existingUserMigration(value):
            "existing-user-migration|\(value.version)"
        }
    }

    func validate() throws {
        switch self {
        case let .statisticCounter(value): try value.validate()
        case let .statisticContentUse(value): try value.validate()
        case let .achievementProgress(value): try value.validate()
        case let .achievementCompletion(value): try value.validate()
        case let .milestoneCompletion(value): try value.validate()
        case let .grant(value): try value.validate()
        case let .ownership(value): try value.validate()
        case let .entitlement(value): try value.validate()
        case let .encounter(value): try value.validate()
        case let .titleSelection(value): try value.validate()
        case let .revealQueueState(value): try value.validate()
        case let .catalogMigration(value): try value.validate()
        case let .existingUserMigration(value): try value.validate()
        }
    }
}

struct ProgressionProjectionShard: Codable, Equatable, Sendable {
    static let maximumRecordCount = 2_048

    let schemaVersion: UInt16
    let generation: String
    let category: ProgressionDiagnosticRecordCategory
    let shardIndex: UInt16
    let records: [ProgressionLogicalRecord]

    init(
        generation: String,
        category: ProgressionDiagnosticRecordCategory,
        shardIndex: UInt16,
        records: [ProgressionLogicalRecord]
    ) {
        schemaVersion = ProgressionRecordConstants.schemaVersion
        self.generation = generation
        self.category = category
        self.shardIndex = shardIndex
        self.records = records.sorted { $0.identity < $1.identity }
    }

    func validate() throws {
        try validateGeneration(schemaVersion, generation)
        guard records.count <= Self.maximumRecordCount,
              records.allSatisfy({ $0.generation == generation && $0.category == category }),
              Set(records.map(\.identity)).count == records.count,
              records.map(\.identity) == records.map(\.identity).sorted(),
              shardIndex < ProgressionProjectionLayout.shardCount(for: category),
              records.allSatisfy({
                  ProgressionProjectionLayout.shardIndex(for: $0) == shardIndex
              })
        else { throw ProgressionDomainError.invalidRecord("projection-shard") }
        for record in records {
            try record.validate()
        }
    }
}

enum ProgressionProjectionLayout {
    static let projectedCategories: [ProgressionDiagnosticRecordCategory] = [
        .statisticCounter,
        .achievementProgress,
        .achievementCompletion,
        .milestoneCompletion,
        .grant,
        .ownership,
        .entitlement,
        .encounter,
        .titleSelection,
        .pendingReveal,
        .catalogMigration,
    ]

    static func shardCount(for category: ProgressionDiagnosticRecordCategory) -> UInt16 {
        1
    }

    static func shardIndex(for record: ProgressionLogicalRecord) -> UInt16 {
        let prefix = ProgressionDeterminism.digest128(record.identity).prefix(4)
        let value = UInt16(prefix, radix: 16)!
        return value % shardCount(for: record.category)
    }

    static func shardIdentity(
        generation: String,
        category: ProgressionDiagnosticRecordCategory,
        shardIndex: UInt16
    ) -> String {
        "\(generation)|\(category.rawValue)|\(shardIndex)"
    }
}

private func validateSchema(_ schemaVersion: UInt16) throws {
    guard schemaVersion == ProgressionRecordConstants.schemaVersion else {
        throw ProgressionDomainError.unsupportedRecordSchema(schemaVersion)
    }
}

private func validateGeneration(_ schemaVersion: UInt16, _ generation: String) throws {
    try validateSchema(schemaVersion)
    guard ProgressionDeterminism.isDigest(generation) else {
        throw ProgressionDomainError.invalidRecord("generation")
    }
}

private func isFinite(_ date: Date?) -> Bool {
    date?.timeIntervalSinceReferenceDate.isFinite ?? true
}

func existingUserMigrationGrantTransactionID(_ transactionID: UUID) -> GrantTransactionID {
    GrantTransactionID(
        rawValue: "transaction.existing-user-migration.\(transactionID.uuidString.lowercased())"
    )!
}

func externalMergeGrantTransactionID(_ transactionID: UUID) -> GrantTransactionID {
    GrantTransactionID(
        rawValue: "transaction.external-merge.\(transactionID.uuidString.lowercased())"
    )!
}

private func isFinite(_ date: Date) -> Bool {
    date.timeIntervalSinceReferenceDate.isFinite
}
