import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum ProgressionEventValidationResult: Sendable {
    case accepted(ProgressionValidatedEvent)
    case ignored
    case rejected(ProgressionRejectionCode)
    case unsupportedSchema
}

struct ProgressionValidatedEvent: Sendable {
    let envelope: DomainEventEnvelope
    let definition: ProgressionEventDefinition
    let semanticMaterial: String
    let semanticDigest: String
    let envelopeDigest: String
}

enum ProgressionLegacyArtifactAliasValidationPolicy: Equatable {
    case incomingOnly
    case allEvents
}

enum ProgressionEventValidator {
    static let unknownEvent = rejection("progression.event-unknown")
    static let invalidSource = rejection("progression.event-source")
    static let invalidPayload = rejection("progression.event-payload")
    static let invalidEligibility = rejection("progression.event-eligibility")
    static let eventIDCollision = rejection("progression.event-id-collision")
    static let semanticCollision = rejection("progression.semantic-collision")

    static func validate(
        _ envelope: DomainEventEnvelope,
        bundle: ValidatedProgressionCatalogBundle,
        legacyArtifactAliasPolicy: ProgressionLegacyArtifactAliasValidationPolicy =
            .incomingOnly
    ) -> ProgressionEventValidationResult {
        guard envelope.schemaVersion == 1 else { return .unsupportedSchema }
        guard envelope.sourceModuleID == RuneScribeModuleIDs.core else {
            return .rejected(invalidSource)
        }
        guard let definition = bundle.eventCatalog.event(envelope.eventType) else {
            return .rejected(unknownEvent)
        }
        guard bundle.eventCatalog.eligibilityReasonIDs.contains(envelope.eligibility.reason) else {
            return .rejected(invalidEligibility)
        }
        do {
            _ = try ProgressionEventFact(
                eventType: envelope.eventType,
                eligibility: envelope.eligibility,
                payload: envelope.payload
            )
            try validatePayload(envelope.payload, definition: definition)
            try validateEligibility(envelope, bundle: bundle)
            try validateCatalogIdentifiers(
                envelope,
                catalog: bundle.catalog,
                legacyArtifactAliasPolicy: legacyArtifactAliasPolicy
            )
            let semanticMaterial = try semanticMaterial(
                eventType: envelope.eventType,
                definition: definition,
                payload: envelope.payload
            )
            let envelopeDigest = try ProgressionDeterminism.encodedDigest(envelope)
            guard envelope.eligibility.state == .eligible else { return .ignored }
            return .accepted(ProgressionValidatedEvent(
                envelope: envelope,
                definition: definition,
                semanticMaterial: semanticMaterial,
                semanticDigest: ProgressionDeterminism.digest128(semanticMaterial),
                envelopeDigest: envelopeDigest
            ))
        } catch {
            return .rejected(invalidPayload)
        }
    }

    private static func validateEligibility(
        _ envelope: DomainEventEnvelope,
        bundle: ValidatedProgressionCatalogBundle
    ) throws {
        let reason = envelope.eligibility.reason.rawValue
        let expectedPrefix: String = switch envelope.eligibility.state {
        case .eligible: "eligibility.eligible."
        case .ineligible: "eligibility.ineligible."
        case .informational: "eligibility.informational."
        }
        guard reason.hasPrefix(expectedPrefix) else {
            throw ProgressionDomainError.invalidRecord("event-eligibility-reason")
        }

        if envelope.eventType.rawValue == "runescribe.share.completed" {
            guard let route = shareRoute(envelope.payload.routeClass),
                  envelope.payload.relationshipToken == nil ||
                    envelope.payload.linkedRelationship == true
            else { throw ProgressionDomainError.invalidRecord("share-payload-consistency") }

            if reason == "eligibility.ineligible.required-attachment-not-accepted" {
                guard route == .messages, envelope.payload.keyIncluded == true else {
                    throw ProgressionDomainError.invalidRecord("share-route-policy")
                }
                return
            }
            guard let terminal = terminalResult(for: reason) else {
                throw ProgressionDomainError.invalidRecord("share-terminal-result")
            }
            let policy = bundle.eventCatalog.shareRoutePolicy.first { candidate in
                (candidate.routeClass == route || candidate.routeClass == .any) &&
                    candidate.terminalResult == terminal
            }
            guard let policy,
                  policy.progressionEligible == (envelope.eligibility.state == .eligible)
            else { throw ProgressionDomainError.invalidRecord("share-route-policy") }
        } else {
            guard envelope.eligibility.state == .eligible,
                  reason == "eligibility.eligible.domain-commit"
            else { throw ProgressionDomainError.invalidRecord("event-eligibility-definition") }
        }
    }

    static func canonicalizingLegacyArtifactAliases(
        in event: ProgressionValidatedEvent,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ProgressionValidatedEvent {
        let containsLegacyArtifact = event.envelope.payload.artifactIDs.contains {
            guard let contentID = ProgressionContentID(rawValue: $0.rawValue) else {
                return true
            }
            return bundle.catalog.content(id: contentID)?.countsAsArtifact != true
        }
        guard containsLegacyArtifact else { return event }
        let canonicalArtifactIDs = try ProgressionNorseV2Migration.canonicalArtifactIDs(
            event.envelope.payload.artifactIDs,
            catalog: bundle.catalog
        )
        let original = event.envelope
        let envelope = try original.replacingArtifactIDs(canonicalArtifactIDs)
        let semanticMaterial = try semanticMaterial(
            eventType: envelope.eventType,
            definition: event.definition,
            payload: envelope.payload
        )
        return ProgressionValidatedEvent(
            envelope: envelope,
            definition: event.definition,
            semanticMaterial: semanticMaterial,
            semanticDigest: ProgressionDeterminism.digest128(semanticMaterial),
            envelopeDigest: try ProgressionDeterminism.encodedDigest(envelope)
        )
    }

    private static func validateCatalogIdentifiers(
        _ envelope: DomainEventEnvelope,
        catalog: ProgressionCatalog,
        legacyArtifactAliasPolicy: ProgressionLegacyArtifactAliasValidationPolicy
    ) throws {
        for codexID in envelope.payload.codexIDs {
            guard let contentID = ProgressionContentID(rawValue: codexID.rawValue),
                  catalog.content(id: contentID)?.kind == .codex
            else { throw ProgressionDomainError.unknownContent(codexID.rawValue) }
        }

        let permitsLegacyAliases = legacyArtifactAliasPolicy == .allEvents || [
            "runescribe.message.imported",
            "runescribe.message.decoded",
            "runescribe.presentation.observed",
        ].contains(envelope.eventType.rawValue)
        for artifactID in envelope.payload.artifactIDs {
            if let contentID = ProgressionContentID(rawValue: artifactID.rawValue),
               catalog.content(id: contentID)?.countsAsArtifact == true
            {
                continue
            }
            guard permitsLegacyAliases,
                  ProgressionNorseV2Migration.canonicalArtifactID(
                artifactID,
                catalog: catalog
                  ) != nil
            else { throw ProgressionDomainError.unknownContent(artifactID.rawValue) }
        }
    }

    private static func shareRoute(
        _ route: DomainEventRouteClass?
    ) -> ProgressionShareRouteClass? {
        switch route {
        case .messages: .messages
        case .shareSheet: .shareSheet
        case .airDrop: .airDrop
        case .fileExport: .fileExport
        case .clipboard: .clipboard
        case .qrDisplay: .qrDisplay
        case .any: .any
        default: nil
        }
    }

    private static func terminalResult(
        for reason: String
    ) -> ProgressionShareTerminalResult? {
        switch reason {
        case "eligibility.eligible.message-sent-confirmed": .sentConfirmed
        case "eligibility.eligible.share-completed-by-system": .completedBySystem
        case "eligibility.ineligible.completion-unavailable": .completionUnavailable
        case "eligibility.informational.presented-only": .presented
        case "eligibility.ineligible.cancelled": .cancelled
        case "eligibility.ineligible.failed": .failed
        default: nil
        }
    }

    private static func validatePayload(
        _ payload: DomainEventPayload,
        definition: ProgressionEventDefinition
    ) throws {
        let present = Set(ProgressionEventPayloadField.allCases.filter {
            isPresent($0, in: payload)
        })
        let required = Set(definition.requiredPayload)
        let optional = Set(definition.optionalPayload ?? [])
        guard required.isSubset(of: present), present.isSubset(of: required.union(optional)) else {
            throw ProgressionDomainError.invalidRecord("event-payload-shape")
        }
        if let values = definition.requiredValues {
            if let origin = values.origin {
                let expected: DomainEventOrigin = origin == .generated ? .generated : .imported
                guard payload.origin == expected else {
                    throw ProgressionDomainError.invalidRecord("event-origin")
                }
            }
            if let keyIncluded = values.keyIncluded {
                guard payload.keyIncluded == keyIncluded else {
                    throw ProgressionDomainError.invalidRecord("event-key-included")
                }
            }
            if let linked = values.linkedRelationship {
                guard payload.linkedRelationship == linked else {
                    throw ProgressionDomainError.invalidRecord("event-linked-relationship")
                }
            }
        }
    }

    private static func semanticMaterial(
        eventType: EventIdentifier,
        definition: ProgressionEventDefinition,
        payload: DomainEventPayload
    ) throws -> String {
        var components = [eventType.rawValue]
        let optional = Set(definition.optionalPayload ?? [])
        for field in definition.semanticDedupe.sorted(by: { $0.rawValue < $1.rawValue }) {
            let values = values(field, in: payload)
            if values.isEmpty, optional.contains(field) {
                components.append("\(field.rawValue)=<absent>")
                continue
            }
            guard !values.isEmpty else {
                throw ProgressionDomainError.invalidRecord("semantic-field")
            }
            components.append("\(field.rawValue)=\(values.sorted().joined(separator: ","))")
        }
        let material = components.joined(separator: "|")
        guard material.utf8.count <= ProgressionRecordConstants.maximumCanonicalMaterialBytes else {
            throw ProgressionDomainError.invalidRecord("semantic-material")
        }
        return material
    }

    static func values(
        _ field: ProgressionEventPayloadField,
        in payload: DomainEventPayload
    ) -> [String] {
        switch field {
        case .artifactIDs: payload.artifactIDs.map(\.rawValue)
        case .cipherToken: payload.cipherToken.map { [$0.rawValue] } ?? []
        case .codexIDs: payload.codexIDs.map(\.rawValue)
        case .embeddedCipher: payload.embeddedCipher.map { [$0 ? "true" : "false"] } ?? []
        case .keyIncluded: payload.keyIncluded.map { [$0 ? "true" : "false"] } ?? []
        case .linkedRelationship:
            payload.linkedRelationship.map { [$0 ? "true" : "false"] } ?? []
        case .messageToken: payload.messageToken.map { [$0.rawValue] } ?? []
        case .origin: payload.origin.map { [$0.rawValue] } ?? []
        case .packageToken: payload.packageToken.map { [$0.rawValue] } ?? []
        case .provenanceStatus: payload.provenanceStatus.map { [$0.rawValue] } ?? []
        case .relationshipToken: payload.relationshipToken.map { [$0.rawValue] } ?? []
        case .routeClass: payload.routeClass.map { [$0.rawValue] } ?? []
        }
    }

    private static func isPresent(
        _ field: ProgressionEventPayloadField,
        in payload: DomainEventPayload
    ) -> Bool {
        !values(field, in: payload).isEmpty
    }

    private static func rejection(_ value: String) -> ProgressionRejectionCode {
        ProgressionRejectionCode(rawValue: value)!
    }
}

struct ProgressionReductionOutput: Sendable {
    let projection: ProgressionProjection
    let newDistinctTokens: [DistinctTokenRecord]
    let queuedRevealUpserts: [PendingRevealRecord]
    let newPendingReveal: PendingRevealRecord?
    let delta: ProgressionStateDeltaSummary
}

private struct ProgressionGrantAccumulator {
    struct Candidate {
        let contentID: ProgressionContentID
        let groupID: GrantGroupID
        let tier: ProgressionDurableRevealTier
        let isPrimary: Bool
        var sources: Set<ProgressionGrantSource>
    }

    var candidates: [ProgressionContentID: Candidate] = [:]
    var sourceAchievementIDs = Set<AchievementID>()
    var sourceRuleIDs = Set<RuleID>()
    var newlyOwnedCount = 0
    var newlyEntitledCount = 0
}

struct ProgressionRevealExclusions: Sendable {
    let contentIDs: Set<ProgressionContentID>
    let replacementRevealID: RevealID
}

private struct ProgressionMutableReductionState {
    var projection: ProgressionProjection
    var lifetimeTokens: [String: DistinctTokenRecord]
    var newLifetimeTokenIDs = Set<String>()
    var revealQueueUpserts: [RevealID: PendingRevealRecord] = [:]
    var queueTail: PendingRevealRecord?
    var changedStatisticKeys = Set<String>()

    init(
        projection: ProgressionProjection,
        lifetimeTokens: [DistinctTokenRecord],
        queueTail: PendingRevealRecord?
    ) throws {
        self.projection = projection
        self.lifetimeTokens = [:]
        self.queueTail = queueTail
        for token in lifetimeTokens {
            try token.validate()
            guard token.generation == projection.metadata.activeGeneration else {
                throw ProgressionDomainError.invalidRecord("lifetime-token-generation")
            }
            let identity = lifetimeTokenIdentity(token)
            if let prior = self.lifetimeTokens[identity], prior != token {
                throw ProgressionDomainError.recordIdentityCollision(identity)
            }
            self.lifetimeTokens[identity] = token
        }
    }

    mutating func addLifetimeDistinct(
        statisticID: StatisticID,
        bucketID: CodexID?,
        canonicalToken: String,
        firstObservedAt: Date
    ) throws -> Bool {
        let nextRevision = projection.metadata.revision.addingReportingOverflow(1)
        guard !nextRevision.overflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        let token = DistinctTokenRecord(
            generation: projection.metadata.activeGeneration,
            statisticID: statisticID,
            bucketID: bucketID,
            canonicalToken: canonicalToken,
            firstObservedAt: firstObservedAt,
            firstAppliedRevision: nextRevision.partialValue
        )
        try token.validate()
        let identity = lifetimeTokenIdentity(token)
        if let existing = lifetimeTokens[identity] {
            guard sameLifetimeToken(existing, token) else {
                throw ProgressionDomainError.recordIdentityCollision(identity)
            }
            return false
        }
        lifetimeTokens[identity] = token
        newLifetimeTokenIDs.insert(identity)
        try incrementCounter(statisticID: statisticID, bucketID: bucketID)
        return true
    }

    mutating func addExternalLifetimeDistinct(
        statisticID: StatisticID,
        bucketID: CodexID?,
        opaqueTokenDigest: String,
        firstObservedAt: Date,
        transactionID: UUID,
        firstAppliedRevision: UInt64
    ) throws -> Bool {
        let opaqueIdentity =
            "\(statisticID.rawValue)|\(bucketID?.rawValue ?? "")|\(opaqueTokenDigest)"
        if let existing = lifetimeTokens.values.first(where: {
            "\($0.statisticID.rawValue)|\($0.bucketID?.rawValue ?? "")|\($0.cloudOpaqueTokenDigest)"
                == opaqueIdentity
        }) {
            guard existing.statisticID == statisticID, existing.bucketID == bucketID else {
                throw ProgressionDomainError.recordIdentityCollision(opaqueIdentity)
            }
            return false
        }
        let token = DistinctTokenRecord(
            generation: projection.metadata.activeGeneration,
            statisticID: statisticID,
            bucketID: bucketID,
            externalOpaqueTokenDigest: opaqueTokenDigest,
            firstObservedAt: firstObservedAt,
            sourceExternalMergeTransactionID: transactionID,
            firstAppliedRevision: firstAppliedRevision
        )
        try token.validate()
        let identity = lifetimeTokenIdentity(token)
        guard lifetimeTokens[identity] == nil else {
            throw ProgressionDomainError.recordIdentityCollision(identity)
        }
        lifetimeTokens[identity] = token
        newLifetimeTokenIDs.insert(identity)
        try incrementCounter(statisticID: statisticID, bucketID: bucketID)
        return true
    }

    mutating func addCatalogContent(
        statisticID: StatisticID,
        bucketID: CodexID?,
        contentID: ProgressionContentID
    ) throws -> Bool {
        let identity = contentUseIdentity(statisticID, bucketID)
        var values: [ProgressionContentID]
        if case let .statisticContentUse(existing)? = projection.records[identity] {
            values = existing.contentIDs
        } else {
            values = []
        }
        guard !values.contains(contentID) else { return false }
        values.append(contentID)
        let record = StatisticContentUseRecord(
            generation: projection.metadata.activeGeneration,
            statisticID: statisticID,
            bucketID: bucketID,
            contentIDs: values
        )
        try record.validate()
        try projection.upsert(.statisticContentUse(record))
        try setCounter(
            statisticID: statisticID,
            bucketID: bucketID,
            value: UInt64(record.contentIDs.count)
        )
        return true
    }

    mutating func enqueue(_ reveal: PendingRevealRecord) throws {
        guard case let .revealQueueState(current)? = projection.records[
            "reveal-queue-state"
        ] else { throw ProgressionDomainError.invalidRecord("reveal-queue-state-missing") }
        let (count, overflow) = current.pendingCount.addingReportingOverflow(1)
        guard !overflow else {
            throw ProgressionDomainError.invalidRecord("reveal-queue-overflow")
        }
        if current.pendingCount == 0 {
            guard queueTail == nil else {
                throw ProgressionDomainError.invalidRecord("reveal-queue-tail-unexpected")
            }
            try projection.upsert(.revealQueueState(ProgressionRevealQueueStateRecord(
                generation: projection.metadata.activeGeneration,
                pendingCount: count,
                headRevealID: reveal.revealID,
                tailRevealID: reveal.revealID
            )))
        } else {
            guard var tail = queueTail,
                  tail.state != .acknowledged,
                  tail.generation == projection.metadata.activeGeneration,
                  tail.revealID == current.tailRevealID,
                  tail.nextRevealID == nil
            else { throw ProgressionDomainError.invalidRecord("reveal-queue-tail-missing") }
            tail.nextRevealID = reveal.revealID
            try tail.validate()
            revealQueueUpserts[tail.revealID] = tail
            try projection.upsert(.revealQueueState(ProgressionRevealQueueStateRecord(
                generation: projection.metadata.activeGeneration,
                pendingCount: count,
                headRevealID: current.headRevealID,
                tailRevealID: reveal.revealID
            )))
        }
        revealQueueUpserts[reveal.revealID] = reveal
        queueTail = reveal
    }

    mutating func incrementCounter(
        statisticID: StatisticID,
        bucketID: CodexID?
    ) throws {
        let identity = counterIdentity(statisticID, bucketID)
        let prior: UInt64
        if case let .statisticCounter(value)? = projection.records[identity] {
            prior = value.value
        } else {
            prior = 0
        }
        let (value, overflow) = prior.addingReportingOverflow(1)
        guard !overflow else { throw ProgressionDomainError.invalidRecord("counter-overflow") }
        try setCounter(statisticID: statisticID, bucketID: bucketID, value: value)
    }

    mutating func setCounter(
        statisticID: StatisticID,
        bucketID: CodexID?,
        value: UInt64
    ) throws {
        try projection.upsert(.statisticCounter(StatisticCounterRecord(
            generation: projection.metadata.activeGeneration,
            statisticID: statisticID,
            bucketID: bucketID,
            value: value
        )))
        changedStatisticKeys.insert(counterIdentity(statisticID, bucketID))
    }

    func newDistinctTokens() -> [DistinctTokenRecord] {
        newLifetimeTokenIDs.sorted().compactMap { lifetimeTokens[$0] }
    }

    func queuedRevealRecords() -> [PendingRevealRecord] {
        revealQueueUpserts.values.sorted { $0.revealID < $1.revealID }
    }
}

enum ProgressionReducer {
    static func lifetimeDistinctCandidates(
        for event: ProgressionValidatedEvent,
        projection: ProgressionProjection,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> [DistinctTokenRecord] {
        let nextRevision = projection.metadata.revision.addingReportingOverflow(1)
        guard !nextRevision.overflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        var candidates: [String: DistinctTokenRecord] = [:]
        for statisticID in event.definition.updates.sorted() {
            guard let statistic = bundle.catalog.statistic(id: statisticID) else {
                throw ProgressionDomainError.invalidRecord("event-statistic-reference")
            }
            guard isLifetimeDimension(statistic.dimension), statistic.storage != .derived else {
                continue
            }
            let values = dimensionValues(statistic.dimension, payload: event.envelope.payload)
                .filter {
                    accepts(
                        value: $0,
                        statistic: statistic,
                        payload: event.envelope.payload,
                        projection: projection,
                        catalog: bundle.catalog
                    )
                }
                .sorted()
            let bucketIDs: [CodexID?]
            switch statistic.storage {
            case .distinctSet:
                bucketIDs = [nil]
            case .bucketedDistinctSet:
                guard statistic.bucket == .codexID else {
                    throw ProgressionDomainError.invalidRecord("statistic-bucket")
                }
                bucketIDs = try eligibleBucketIDs(
                    event: event,
                    projection: projection,
                    catalog: bundle.catalog
                ).map(Optional.some)
            case .derived:
                bucketIDs = []
            }
            for bucketID in bucketIDs {
                for value in values {
                    let candidate = DistinctTokenRecord(
                        generation: projection.metadata.activeGeneration,
                        statisticID: statisticID,
                        bucketID: bucketID,
                        canonicalToken: value,
                        firstObservedAt: event.envelope.occurredAt,
                        firstAppliedRevision: nextRevision.partialValue
                    )
                    try candidate.validate()
                    let identity = lifetimeTokenIdentity(candidate)
                    if let prior = candidates[identity], prior != candidate {
                        throw ProgressionDomainError.recordIdentityCollision(identity)
                    }
                    candidates[identity] = candidate
                }
            }
        }
        return candidates.values.sorted { lifetimeTokenIdentity($0) < lifetimeTokenIdentity($1) }
    }

    static func initialProjection(
        bundle: ValidatedProgressionCatalogBundle,
        generation: String? = nil
    ) throws -> ProgressionProjection {
        let catalog = bundle.catalog
        let resolvedGeneration = generation ?? ProgressionDeterminism.digest128(
            "initial-generation|\(catalog.catalogID.rawValue)|\(catalog.catalogVersion.rawValue)"
        )
        let metadata = ProgressionMetadataRecord(
            catalogID: catalog.catalogID,
            catalogVersion: catalog.catalogVersion,
            activeGeneration: resolvedGeneration
        )
        var records: [ProgressionLogicalRecord] = []

        let codexIDs = catalog.content.compactMap { definition -> CodexID? in
            guard definition.kind == .codex else { return nil }
            return CodexID(rawValue: definition.contentID.rawValue)
        }.sorted()
        for statistic in catalog.statistics.sorted(by: { $0.statisticID < $1.statisticID }) {
            switch statistic.storage {
            case .bucketedDistinctSet:
                for codexID in codexIDs {
                    records.append(.statisticCounter(StatisticCounterRecord(
                        generation: resolvedGeneration,
                        statisticID: statistic.statisticID,
                        bucketID: codexID,
                        value: 0
                    )))
                }
            case .distinctSet, .derived:
                records.append(.statisticCounter(StatisticCounterRecord(
                    generation: resolvedGeneration,
                    statisticID: statistic.statisticID,
                    bucketID: nil,
                    value: 0
                )))
            }
        }
        for achievement in catalog.achievements.sorted(by: {
            $0.achievementID < $1.achievementID
        }) {
            records.append(.achievementProgress(AchievementProgressRecord(
                generation: resolvedGeneration,
                achievementID: achievement.achievementID,
                current: 0,
                target: UInt64(achievement.progress.target)
            )))
        }
        records.append(.titleSelection(TitleSelectionRecord(
            generation: resolvedGeneration,
            selectedTitleID: nil,
            selectedAt: nil
        )))
        records.append(.revealQueueState(ProgressionRevealQueueStateRecord(
            generation: resolvedGeneration,
            pendingCount: 0,
            headRevealID: nil,
            tailRevealID: nil
        )))

        let bootstrapTransactionID = ProgressionDeterminism.transactionUUID(
            "progression-bootstrap|\(catalog.catalogID.rawValue)|\(catalog.catalogVersion.rawValue)|\(catalog.migration.migrationVersion)"
        )
        records.append(.catalogMigration(CatalogMigrationRecord(
            generation: resolvedGeneration,
            migrationVersion: catalog.migration.migrationVersion,
            catalogVersion: catalog.catalogVersion,
            transactionID: bootstrapTransactionID,
            completedAt: nil,
            compatibilityFingerprints: try ProgressionCatalogCompatibility.fingerprints(
                for: bundle
            )
        )))

        var projection = try ProgressionProjection(metadata: metadata, records: records)
        var accumulator = ProgressionGrantAccumulator()
        try applyGrantGroup(
            catalog.migration.startingGrantGroupID,
            source: .migration(catalog.migration.migrationVersion),
            transactionID: grantTransactionID("bootstrap.\(bootstrapTransactionID.uuidString.lowercased())"),
            grantedAt: nil,
            revealEligible: false,
            bundle: bundle,
            projection: &projection,
            accumulator: &accumulator
        )
        try recomputeDerivedStatistics(bundle: bundle, projection: &projection)
        var initialState = try ProgressionMutableReductionState(
            projection: projection,
            lifetimeTokens: [],
            queueTail: nil
        )
        try updateAchievementProgress(state: &initialState, bundle: bundle)
        projection = initialState.projection
        return projection
    }

    static func apply(
        _ event: ProgressionValidatedEvent,
        to repositoryState: ProgressionRepositoryState,
        existingLifetimeTokens: [DistinctTokenRecord],
        queueTail: PendingRevealRecord?,
        suppressReveal: Bool = false,
        revealExclusions: ProgressionRevealExclusions? = nil,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ProgressionReductionOutput {
        var state = try ProgressionMutableReductionState(
            projection: repositoryState.projection,
            lifetimeTokens: existingLifetimeTokens,
            queueTail: queueTail
        )
        return try apply(
            event,
            state: &state,
            suppressReveal: suppressReveal,
            revealExclusions: revealExclusions,
            bundle: bundle
        )
    }

    static func replay(
        appliedEvents: [ProgressionValidatedEvent],
        bundle: ValidatedProgressionCatalogBundle,
        generation: String,
        acknowledgedRevealIDs: Set<RevealID> = []
    ) throws -> ProgressionReductionOutput {
        let initial = try initialProjection(bundle: bundle, generation: generation)
        var state = try ProgressionMutableReductionState(
            projection: initial,
            lifetimeTokens: [],
            queueTail: nil
        )
        var latest: ProgressionReductionOutput?
        for event in appliedEvents {
            let candidateRevealID = revealID(for: event.envelope.eventID)
            latest = try apply(
                event,
                state: &state,
                suppressReveal: acknowledgedRevealIDs.contains(candidateRevealID),
                revealExclusions: nil,
                bundle: bundle
            )
        }
        if let latest { return latest }
        return ProgressionReductionOutput(
            projection: state.projection,
            newDistinctTokens: state.newDistinctTokens(),
            queuedRevealUpserts: state.queuedRevealRecords(),
            newPendingReveal: nil,
            delta: ProgressionStateDeltaSummary()
        )
    }

    /// Imports monotonic facts, then evaluates the local source-controlled
    /// catalog to decide completions and grants. Remote grant/ownership arrays
    /// are corroborating output only and never create a local grant directly.
    static func applyExternalMerge(
        _ external: RuntimeProgressionExternalProjection,
        to source: ProgressionProjection,
        transactionID: UUID,
        appliedAt: Date,
        existingDistinctTokens: [DistinctTokenRecord],
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> (
        projection: ProgressionProjection,
        newDistinctTokens: [DistinctTokenRecord]
    ) {
        guard external.catalogVersion == bundle.catalog.catalogVersion.rawValue else {
            throw ProgressionDomainError.invalidRecord("external-merge-catalog-version")
        }
        let (firstAppliedRevision, revisionOverflow) = source.metadata.revision
            .addingReportingOverflow(1)
        guard !revisionOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        var tokenState = try ProgressionMutableReductionState(
            projection: source,
            lifetimeTokens: existingDistinctTokens,
            queueTail: nil
        )
        for fact in external.distinctTokens.sorted(by: {
            ($0.statisticID.rawValue, $0.codexID?.rawValue ?? "", $0.opaqueTokenDigest)
                < ($1.statisticID.rawValue, $1.codexID?.rawValue ?? "", $1.opaqueTokenDigest)
        }) {
            guard let definition = bundle.catalog.statistic(id: fact.statisticID),
                  definition.storage != .derived,
                  isLifetimeDimension(definition.dimension),
                  (definition.bucket == nil) == (fact.codexID == nil),
                  fact.firstObservedAt <= appliedAt
            else { continue }
            _ = try tokenState.addExternalLifetimeDistinct(
                statisticID: fact.statisticID,
                bucketID: fact.codexID,
                opaqueTokenDigest: fact.opaqueTokenDigest,
                firstObservedAt: fact.firstObservedAt,
                transactionID: transactionID,
                firstAppliedRevision: firstAppliedRevision
            )
        }
        let newDistinctTokens = tokenState.newDistinctTokens()
        var projection = tokenState.projection
        let generation = projection.metadata.activeGeneration

        for fact in external.counters {
            guard let definition = bundle.catalog.statistic(id: fact.statisticID),
                  definition.storage != .derived,
                  !isLifetimeDimension(definition.dimension),
                  (definition.bucket == nil) == (fact.codexID == nil)
            else { continue }
            let identity = counterIdentity(fact.statisticID, fact.codexID)
            let localValue: UInt64
            if case let .statisticCounter(record)? = projection.records[identity] {
                localValue = record.value
            } else {
                localValue = 0
            }
            guard fact.value > localValue else { continue }
            try projection.upsert(.statisticCounter(StatisticCounterRecord(
                generation: generation,
                statisticID: fact.statisticID,
                bucketID: fact.codexID,
                value: fact.value
            )))
        }

        for fact in external.encounters {
            let artifactIDs = try ProgressionNorseV2Migration.canonicalArtifactIDs(
                fact.artifactIDs,
                catalog: bundle.catalog
            )
            guard let codexContentID = ProgressionContentID(rawValue: fact.codexID.rawValue),
                  bundle.catalog.content(id: codexContentID)?.kind == .codex,
                  fact.encounterCount > 0,
                  fact.firstEncounteredAt <= fact.lastEncounteredAt
            else { continue }
            let identity = "encounter|\(fact.codexID.rawValue)"
            if case let .encounter(existing)? = projection.records[identity] {
                var observations = Dictionary(
                    uniqueKeysWithValues: existing.artifactObservations.map {
                        ($0.artifactID, $0)
                    }
                )
                for artifactID in artifactIDs where observations[artifactID] == nil {
                    observations[artifactID] = EncounterRecord.ArtifactObservation(
                        artifactID: artifactID,
                        firstEncounteredAt: fact.firstEncounteredAt,
                        lastEncounteredAt: fact.lastEncounteredAt,
                        encounterCount: 1,
                        provenanceStatus: .unverified
                    )
                }
                try projection.upsert(.encounter(EncounterRecord(
                    generation: generation,
                    codexID: fact.codexID,
                    artifactObservations: Array(observations.values),
                    firstEncounteredAt: min(
                        existing.firstEncounteredAt,
                        fact.firstEncounteredAt
                    ),
                    lastEncounteredAt: max(
                        existing.lastEncounteredAt,
                        fact.lastEncounteredAt
                    ),
                    encounterCount: max(existing.encounterCount, fact.encounterCount),
                    provenanceStatus: mergeProvenance(
                        existing.provenanceStatus,
                        .unverified
                    )
                )))
            } else {
                try projection.upsert(.encounter(EncounterRecord(
                    generation: generation,
                    codexID: fact.codexID,
                    artifactIDs: artifactIDs,
                    firstEncounteredAt: fact.firstEncounteredAt,
                    lastEncounteredAt: fact.lastEncounteredAt,
                    encounterCount: fact.encounterCount,
                    provenanceStatus: .unverified
                )))
            }
        }

        let remoteCompletions: [(AchievementID, Date)] = external.achievements
            .compactMap { fact in
                guard let completedAt = fact.completedAt,
                      let definition = bundle.catalog.achievement(id: fact.achievementID),
                      fact.target == UInt64(definition.progress.target),
                      fact.current == fact.target,
                      completedAt <= appliedAt
                else { return nil }
                return (fact.achievementID, completedAt)
            }
        let remoteCompletionByID = Dictionary(
            uniqueKeysWithValues: remoteCompletions
        )
        let remoteMilestones: [(RuleID, Date)] = external.milestones.compactMap { fact in
                guard fact.completedAt <= appliedAt else { return nil }
                return bundle.catalog.milestone(id: fact.ruleID).map { _ in
                    (fact.ruleID, fact.completedAt)
                }
            }
        let remoteMilestoneByID = Dictionary(
            uniqueKeysWithValues: remoteMilestones
        )
        try reconcileExistingCompletionDates(
            achievementDates: remoteCompletionByID,
            milestoneDates: remoteMilestoneByID,
            transactionID: transactionID,
            projection: &projection
        )
        var grants = ProgressionGrantAccumulator()
        let grantTransactionID = externalMergeGrantTransactionID(transactionID)
        let maximumPasses = bundle.catalog.achievements.count
            + bundle.catalog.milestones.count + 1
        for _ in 0 ..< maximumPasses {
            try recomputeDerivedStatistics(bundle: bundle, projection: &projection)
            let facts = ProgressionRuleFacts(projection: projection)
            var changed = false
            for achievement in bundle.catalog.achievements.sorted(by: {
                $0.achievementID < $1.achievementID
            }) where !completedAchievements(in: projection).contains(
                achievement.achievementID
            ) {
                guard ProgressionRuleEvaluator.evaluate(
                    achievement.rule,
                    facts: facts
                ).isSatisfied else { continue }
                let completedAt = remoteCompletionByID[achievement.achievementID] ?? appliedAt
                try projection.upsert(.achievementCompletion(
                    AchievementCompletionRecord(
                        generation: generation,
                        achievementID: achievement.achievementID,
                        completedAt: min(completedAt, appliedAt),
                        sourceExternalMergeTransactionID: transactionID
                    )
                ))
                try applyGrantGroup(
                    achievement.rewardGrantGroupID,
                    source: .achievement(achievement.achievementID),
                    transactionID: grantTransactionID,
                    grantedAt: min(completedAt, appliedAt),
                    revealEligible: false,
                    bundle: bundle,
                    projection: &projection,
                    accumulator: &grants
                )
                changed = true
            }

            try recomputeDerivedStatistics(bundle: bundle, projection: &projection)
            let milestoneFacts = ProgressionRuleFacts(projection: projection)
            for milestone in bundle.catalog.milestones.sorted(by: {
                $0.ruleID < $1.ruleID
            }) where !completedMilestones(in: projection).contains(milestone.ruleID) {
                guard ProgressionRuleEvaluator.evaluate(
                    milestone.rule,
                    facts: milestoneFacts
                ).isSatisfied else { continue }
                let completedAt = remoteMilestoneByID[milestone.ruleID] ?? appliedAt
                try projection.upsert(.milestoneCompletion(MilestoneCompletionRecord(
                    generation: generation,
                    ruleID: milestone.ruleID,
                    completedAt: min(completedAt, appliedAt),
                    sourceExternalMergeTransactionID: transactionID
                )))
                try applyGrantGroup(
                    milestone.grantGroupID,
                    source: .milestone(milestone.ruleID),
                    transactionID: grantTransactionID,
                    grantedAt: min(completedAt, appliedAt),
                    revealEligible: false,
                    bundle: bundle,
                    projection: &projection,
                    accumulator: &grants
                )
                changed = true
            }
            if !changed { break }
        }

        var mutable = try ProgressionMutableReductionState(
            projection: projection,
            lifetimeTokens: existingDistinctTokens + newDistinctTokens,
            queueTail: nil
        )
        try updateAchievementProgress(state: &mutable, bundle: bundle)
        projection = mutable.projection

        if let selectedTitleUpdatedAt = external.selectedTitleUpdatedAt {
            if let selectedTitleID = external.selectedTitleID {
                guard external.titleIDs.contains(selectedTitleID),
                      let contentID = ProgressionContentID(
                          rawValue: selectedTitleID.rawValue
                      ),
                      bundle.catalog.content(id: contentID)?.kind == .title,
                      projection.records["ownership|\(contentID.rawValue)"] != nil
                else { return (projection, newDistinctTokens) }
            }
            try projection.upsert(.titleSelection(TitleSelectionRecord(
                generation: generation,
                selectedTitleID: external.selectedTitleID,
                selectedAt: selectedTitleUpdatedAt
            )))
        }
        return (projection, newDistinctTokens)
    }

    private static func reconcileExistingCompletionDates(
        achievementDates: [AchievementID: Date],
        milestoneDates: [RuleID: Date],
        transactionID: UUID,
        projection: inout ProgressionProjection
    ) throws {
        let generation = projection.metadata.activeGeneration
        for (achievementID, remoteDate) in achievementDates {
            let identity = "achievement-completion|\(achievementID.rawValue)"
            guard case let .achievementCompletion(existing)? = projection.records[identity],
                  remoteDate < existing.completedAt
            else { continue }
            try projection.upsert(.achievementCompletion(AchievementCompletionRecord(
                generation: generation,
                preservingProvenance: existing,
                completedAt: remoteDate,
                sourceExternalMergeTransactionID: transactionID
            )))
            try reconcileGrantDates(
                source: .achievement(achievementID),
                grantedAt: remoteDate,
                transactionID: transactionID,
                replaceGrantProvenance: existing.sourceEventID == nil &&
                    existing.sourceExistingUserMigrationTransactionID == nil,
                projection: &projection
            )
        }
        for (ruleID, remoteDate) in milestoneDates {
            let identity = "milestone-completion|\(ruleID.rawValue)"
            guard case let .milestoneCompletion(existing)? = projection.records[identity],
                  remoteDate < existing.completedAt
            else { continue }
            try projection.upsert(.milestoneCompletion(MilestoneCompletionRecord(
                generation: generation,
                preservingProvenance: existing,
                completedAt: remoteDate,
                sourceExternalMergeTransactionID: transactionID
            )))
            try reconcileGrantDates(
                source: .milestone(ruleID),
                grantedAt: remoteDate,
                transactionID: transactionID,
                replaceGrantProvenance: existing.sourceEventID == nil,
                projection: &projection
            )
        }
    }

    private static func reconcileGrantDates(
        source: ProgressionGrantSource,
        grantedAt: Date,
        transactionID: UUID,
        replaceGrantProvenance: Bool,
        projection: inout ProgressionProjection
    ) throws {
        let generation = projection.metadata.activeGeneration
        var affectedContentIDs: Set<ProgressionContentID> = []
        for logical in projection.logicalRecords() {
            guard case let .grant(existing) = logical,
                  existing.source == source,
                  existing.grantedAt.map({ grantedAt < $0 }) ?? true
            else { continue }
            if replaceGrantProvenance {
                try projection.upsert(.grant(GrantRecord(
                    generation: generation,
                    grantGroupID: existing.grantGroupID,
                    contentID: existing.contentID,
                    source: existing.source,
                    transactionID: externalMergeGrantTransactionID(transactionID),
                    grantedAt: grantedAt
                )))
            }
            affectedContentIDs.insert(existing.contentID)
        }
        for contentID in affectedContentIDs {
            let ownershipID = "ownership|\(contentID.rawValue)"
            if case let .ownership(existing)? = projection.records[ownershipID],
               existing.grantedAt.map({ grantedAt < $0 }) ?? true
            {
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: generation,
                    copying: existing,
                    grantedAt: grantedAt
                )))
            }
            if let unlockID = UnlockID(rawValue: contentID.rawValue),
               case let .entitlement(existing)? = projection.records[
                   "entitlement|\(unlockID.rawValue)"
               ], existing.grantedAt.map({ grantedAt < $0 }) ?? true
            {
                try projection.upsert(.entitlement(ProgressionEntitlementRecord(
                    generation: generation,
                    copying: existing,
                    grantedAt: grantedAt
                )))
            }
        }
    }

    private static func apply(
        _ event: ProgressionValidatedEvent,
        state: inout ProgressionMutableReductionState,
        suppressReveal: Bool,
        revealExclusions: ProgressionRevealExclusions?,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> ProgressionReductionOutput {
        let priorAchievementCount = completedAchievements(in: state.projection).count
        let priorMilestoneCount = completedMilestones(in: state.projection).count
        let priorOwnedCount = ownershipRecords(in: state.projection).count
        let priorEntitlementCount = entitlementRecords(in: state.projection).count

        try applyStatisticUpdates(event, state: &state, bundle: bundle)
        try applyEncounter(event, state: &state, bundle: bundle)

        var grants = ProgressionGrantAccumulator()
        try evaluateToFixpoint(
            event: event,
            state: &state,
            bundle: bundle,
            grants: &grants
        )
        try updateAchievementProgress(state: &state, bundle: bundle)

        let (revision, overflow) = state.projection.metadata.revision.addingReportingOverflow(1)
        guard !overflow else { throw ProgressionDomainError.invalidRecord("revision-overflow") }
        let (appliedEventCount, countOverflow) = state.projection.metadata.appliedEventCount
            .addingReportingOverflow(1)
        guard !countOverflow else {
            throw ProgressionDomainError.invalidRecord("applied-event-count-overflow")
        }
        let (processedEventCount, processedOverflow) = state.projection.metadata
            .processedEventCount.addingReportingOverflow(1)
        let (distinctTokenCount, distinctOverflow) = state.projection.metadata
            .distinctTokenCount.addingReportingOverflow(
                UInt64(state.newDistinctTokens().count)
            )
        guard !processedOverflow, !distinctOverflow else {
            throw ProgressionDomainError.invalidRecord("diagnostic-count-overflow")
        }
        let envelopeDigest = try ProgressionDeterminism.encodedDigest(event.envelope)
        let appliedEventDigest = ProgressionDeterminism.digest128(
            "\(state.projection.metadata.appliedEventDigest ?? "genesis")|\(revision)|\(event.envelope.eventID.rawValue.uuidString.lowercased())|\(envelopeDigest)"
        )
        state.projection.metadata.revision = revision
        state.projection.metadata.lastMutationAt = event.envelope.occurredAt
        state.projection.metadata.appliedEventCount = appliedEventCount
        state.projection.metadata.lastAppliedRevision = revision
        state.projection.metadata.appliedEventDigest = appliedEventDigest
        state.projection.metadata.processedEventCount = processedEventCount
        state.projection.metadata.distinctTokenCount = distinctTokenCount

        let reveal = try makeReveal(
            event: event,
            grants: grants,
            generation: state.projection.metadata.activeGeneration,
            createdRevision: revision,
            exclusions: revealExclusions
        )
        let queuedReveal = suppressReveal ? nil : reveal
        if let queuedReveal {
            try state.enqueue(queuedReveal)
        }

        let completedAchievementCount = completedAchievements(in: state.projection).count
        let completedMilestoneCount = completedMilestones(in: state.projection).count
        let ownedCount = ownershipRecords(in: state.projection).count
        let entitlementCount = entitlementRecords(in: state.projection).count
        let delta = ProgressionStateDeltaSummary(
            changedStatisticCount: boundedUInt16(state.changedStatisticKeys.count),
            completedAchievementCount: boundedUInt16(
                completedAchievementCount - priorAchievementCount
            ),
            completedMilestoneCount: boundedUInt16(completedMilestoneCount - priorMilestoneCount),
            grantedContentCount: boundedUInt16(ownedCount - priorOwnedCount),
            grantedEntitlementCount: boundedUInt16(entitlementCount - priorEntitlementCount),
            queuedRevealCount: queuedReveal == nil ? 0 : 1
        )
        return ProgressionReductionOutput(
            projection: state.projection,
            newDistinctTokens: state.newDistinctTokens(),
            queuedRevealUpserts: state.queuedRevealRecords(),
            newPendingReveal: queuedReveal,
            delta: delta
        )
    }

    private static func applyStatisticUpdates(
        _ event: ProgressionValidatedEvent,
        state: inout ProgressionMutableReductionState,
        bundle: ValidatedProgressionCatalogBundle
    ) throws {
        for statisticID in event.definition.updates.sorted() {
            guard let statistic = bundle.catalog.statistic(id: statisticID) else {
                throw ProgressionDomainError.invalidRecord("event-statistic-reference")
            }
            guard statistic.sourceEvents.contains(event.envelope.eventType.rawValue) else {
                throw ProgressionDomainError.invalidRecord("event-statistic-source")
            }
            guard statistic.storage != .derived else { continue }
            let values = dimensionValues(statistic.dimension, payload: event.envelope.payload)
                .filter {
                    accepts(
                        value: $0,
                        statistic: statistic,
                        payload: event.envelope.payload,
                        projection: state.projection,
                        catalog: bundle.catalog
                    )
                }
            switch statistic.storage {
            case .distinctSet:
                for value in values.sorted() {
                    if isLifetimeDimension(statistic.dimension) {
                        _ = try state.addLifetimeDistinct(
                            statisticID: statisticID,
                            bucketID: nil,
                            canonicalToken: value,
                            firstObservedAt: event.envelope.occurredAt
                        )
                    } else {
                        guard let rawContentID = ProgressionContentID(rawValue: value),
                              let contentID = ProgressionNorseV2Migration.canonicalContentID(
                                rawContentID,
                                catalog: bundle.catalog
                              )
                        else { throw ProgressionDomainError.unknownContent(value) }
                        _ = try state.addCatalogContent(
                            statisticID: statisticID,
                            bucketID: nil,
                            contentID: contentID
                        )
                    }
                }
            case .bucketedDistinctSet:
                guard statistic.bucket == .codexID else {
                    throw ProgressionDomainError.invalidRecord("statistic-bucket")
                }
                let bucketIDs = try eligibleBucketIDs(
                    event: event,
                    projection: state.projection,
                    catalog: bundle.catalog
                )
                for bucketID in bucketIDs {
                    for value in values.sorted() {
                        if isLifetimeDimension(statistic.dimension) {
                            _ = try state.addLifetimeDistinct(
                                statisticID: statisticID,
                                bucketID: bucketID,
                                canonicalToken: value,
                                firstObservedAt: event.envelope.occurredAt
                            )
                        } else {
                            guard let rawContentID = ProgressionContentID(rawValue: value),
                                  let contentID = ProgressionNorseV2Migration.canonicalContentID(
                                    rawContentID,
                                    catalog: bundle.catalog
                                  )
                            else { throw ProgressionDomainError.unknownContent(value) }
                            _ = try state.addCatalogContent(
                                statisticID: statisticID,
                                bucketID: bucketID,
                                contentID: contentID
                            )
                        }
                    }
                }
            case .derived:
                break
            }
        }
    }

    private static func applyEncounter(
        _ event: ProgressionValidatedEvent,
        state: inout ProgressionMutableReductionState,
        bundle: ValidatedProgressionCatalogBundle
    ) throws {
        guard event.envelope.eventType.rawValue == "runescribe.presentation.observed" else {
            return
        }
        let generation = state.projection.metadata.activeGeneration
        let artifactIDs = try ProgressionNorseV2Migration.canonicalArtifactIDs(
            event.envelope.payload.artifactIDs,
            catalog: bundle.catalog
        )
        for codexID in event.envelope.payload.codexIDs.sorted() {
            guard let contentID = ProgressionContentID(rawValue: codexID.rawValue),
                  let content = bundle.catalog.content(id: contentID),
                  content.kind == .codex
            else { throw ProgressionDomainError.unknownContent(codexID.rawValue) }
            let identity = "encounter|\(codexID.rawValue)"
            if case let .encounter(existing)? = state.projection.records[identity] {
                var observations = Dictionary(uniqueKeysWithValues:
                    existing.artifactObservations.map { ($0.artifactID, $0) }
                )
                let eventProvenance = event.envelope.payload.provenanceStatus ?? .absent
                for artifactID in artifactIDs {
                    if var observation = observations[artifactID] {
                        let (artifactCount, artifactOverflow) = observation.encounterCount
                            .addingReportingOverflow(1)
                        guard !artifactOverflow else {
                            throw ProgressionDomainError.invalidRecord(
                                "artifact-encounter-overflow"
                            )
                        }
                        observation.encounterCount = artifactCount
                        observation.firstEncounteredAt = min(
                            observation.firstEncounteredAt,
                            event.envelope.occurredAt
                        )
                        observation.lastEncounteredAt = max(
                            observation.lastEncounteredAt,
                            event.envelope.occurredAt
                        )
                        observation.provenanceStatus = mergeProvenance(
                            observation.provenanceStatus,
                            eventProvenance
                        )
                        observations[artifactID] = observation
                    } else {
                        observations[artifactID] = EncounterRecord.ArtifactObservation(
                            artifactID: artifactID,
                            firstEncounteredAt: event.envelope.occurredAt,
                            lastEncounteredAt: event.envelope.occurredAt,
                            encounterCount: 1,
                            provenanceStatus: eventProvenance
                        )
                    }
                }
                let (count, overflow) = existing.encounterCount.addingReportingOverflow(1)
                guard !overflow else {
                    throw ProgressionDomainError.invalidRecord("encounter-overflow")
                }
                try state.projection.upsert(.encounter(EncounterRecord(
                    generation: generation,
                    codexID: codexID,
                    artifactObservations: Array(observations.values),
                    firstEncounteredAt: min(existing.firstEncounteredAt, event.envelope.occurredAt),
                    lastEncounteredAt: max(existing.lastEncounteredAt, event.envelope.occurredAt),
                    encounterCount: count,
                    provenanceStatus: mergeProvenance(
                        existing.provenanceStatus,
                        eventProvenance
                    )
                )))
            } else {
                try state.projection.upsert(.encounter(EncounterRecord(
                    generation: generation,
                    codexID: codexID,
                    artifactIDs: artifactIDs,
                    firstEncounteredAt: event.envelope.occurredAt,
                    lastEncounteredAt: event.envelope.occurredAt,
                    encounterCount: 1,
                    provenanceStatus: event.envelope.payload.provenanceStatus ?? .absent
                )))
            }
        }
    }

    private static func evaluateToFixpoint(
        event: ProgressionValidatedEvent,
        state: inout ProgressionMutableReductionState,
        bundle: ValidatedProgressionCatalogBundle,
        grants: inout ProgressionGrantAccumulator
    ) throws {
        let maximumPasses = bundle.catalog.achievements.count + bundle.catalog.milestones.count + 1
        for _ in 0 ..< maximumPasses {
            try recomputeDerivedStatistics(bundle: bundle, projection: &state.projection)
            let facts = ProgressionRuleFacts(projection: state.projection)
            var changed = false
            for achievement in bundle.catalog.achievements.sorted(by: {
                $0.achievementID < $1.achievementID
            }) where !completedAchievements(in: state.projection).contains(achievement.achievementID) {
                guard ProgressionRuleEvaluator.evaluate(
                    achievement.rule,
                    facts: facts
                ).isSatisfied else { continue }
                try state.projection.upsert(.achievementCompletion(
                    AchievementCompletionRecord(
                        generation: state.projection.metadata.activeGeneration,
                        achievementID: achievement.achievementID,
                        completedAt: event.envelope.occurredAt,
                        sourceEventID: event.envelope.eventID
                    )
                ))
                grants.sourceAchievementIDs.insert(achievement.achievementID)
                try applyGrantGroup(
                    achievement.rewardGrantGroupID,
                    source: .achievement(achievement.achievementID),
                    transactionID: eventTransactionID(event.envelope.eventID),
                    grantedAt: event.envelope.occurredAt,
                    revealEligible: true,
                    bundle: bundle,
                    projection: &state.projection,
                    accumulator: &grants
                )
                changed = true
            }

            try recomputeDerivedStatistics(bundle: bundle, projection: &state.projection)
            let milestoneFacts = ProgressionRuleFacts(projection: state.projection)
            for milestone in bundle.catalog.milestones.sorted(by: { $0.ruleID < $1.ruleID })
                where !completedMilestones(in: state.projection).contains(milestone.ruleID)
            {
                guard ProgressionRuleEvaluator.evaluate(
                    milestone.rule,
                    facts: milestoneFacts
                ).isSatisfied else { continue }
                try state.projection.upsert(.milestoneCompletion(MilestoneCompletionRecord(
                    generation: state.projection.metadata.activeGeneration,
                    ruleID: milestone.ruleID,
                    completedAt: event.envelope.occurredAt,
                    sourceEventID: event.envelope.eventID
                )))
                grants.sourceRuleIDs.insert(milestone.ruleID)
                try applyGrantGroup(
                    milestone.grantGroupID,
                    source: .milestone(milestone.ruleID),
                    transactionID: eventTransactionID(event.envelope.eventID),
                    grantedAt: event.envelope.occurredAt,
                    revealEligible: true,
                    bundle: bundle,
                    projection: &state.projection,
                    accumulator: &grants
                )
                changed = true
            }
            if !changed {
                try recomputeDerivedStatistics(bundle: bundle, projection: &state.projection)
                return
            }
        }
        throw ProgressionDomainError.invalidRecord("fixpoint-bound")
    }

    private static func updateAchievementProgress(
        state: inout ProgressionMutableReductionState,
        bundle: ValidatedProgressionCatalogBundle
    ) throws {
        let completed = completedAchievements(in: state.projection)
        for achievement in bundle.catalog.achievements {
            let target = UInt64(achievement.progress.target)
            let current: UInt64
            if completed.contains(achievement.achievementID) {
                current = target
            } else if achievement.progress.statisticID.rawValue
                == "stat.achievement.completed-count"
            {
                let excluded = Set(achievement.progress.excludeAchievementIDs ?? [])
                current = min(UInt64(completed.subtracting(excluded).count), target)
            } else {
                current = min(counterValue(
                    achievement.progress.statisticID,
                    bucketID: nil,
                    projection: state.projection
                ), target)
            }
            try state.projection.upsert(.achievementProgress(AchievementProgressRecord(
                generation: state.projection.metadata.activeGeneration,
                achievementID: achievement.achievementID,
                current: current,
                target: target
            )))
        }
    }

    private static func recomputeDerivedStatistics(
        bundle: ValidatedProgressionCatalogBundle,
        projection: inout ProgressionProjection
    ) throws {
        let owned = ownershipRecords(in: projection)
        let completed = completedAchievements(in: projection)
        for statistic in bundle.catalog.statistics where statistic.storage == .derived {
            let value: UInt64
            switch statistic.dimension {
            case .contentID:
                value = UInt64(owned.values.filter { record in
                    bundle.catalog.content(id: record.contentID)?.countsAsArtifact == true
                }.count)
            case .achievementID:
                value = UInt64(completed.count)
            default:
                value = 0
            }
            try projection.upsert(.statisticCounter(StatisticCounterRecord(
                generation: projection.metadata.activeGeneration,
                statisticID: statistic.statisticID,
                bucketID: nil,
                value: value
            )))
        }
    }

    private static func applyGrantGroup(
        _ grantGroupID: GrantGroupID,
        source: ProgressionGrantSource,
        transactionID: GrantTransactionID,
        grantedAt: Date?,
        revealEligible: Bool,
        bundle: ValidatedProgressionCatalogBundle,
        projection: inout ProgressionProjection,
        accumulator: inout ProgressionGrantAccumulator
    ) throws {
        guard let group = bundle.catalog.grantGroup(id: grantGroupID) else {
            throw ProgressionDomainError.invalidRecord("grant-group-reference")
        }
        let generation = projection.metadata.activeGeneration
        for item in group.items.sorted(by: { $0.contentID.rawValue < $1.contentID.rawValue }) {
            guard let content = bundle.catalog.content(id: item.contentID) else {
                throw ProgressionDomainError.unknownContent(item.contentID.rawValue)
            }
            let grant = GrantRecord(
                generation: generation,
                grantGroupID: grantGroupID,
                contentID: item.contentID,
                source: source,
                transactionID: transactionID,
                grantedAt: grantedAt
            )
            let logical = ProgressionLogicalRecord.grant(grant)
            if projection.records[logical.identity] != nil { continue }
            try projection.upsert(logical)

            let ownershipIdentity = "ownership|\(item.contentID.rawValue)"
            let wasOwned = projection.records[ownershipIdentity] != nil
            if case let .ownership(existing)? = projection.records[ownershipIdentity] {
                var keys = Set(existing.sourceGrantKeys)
                keys.insert(logical.identity)
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: generation,
                    contentID: item.contentID,
                    sourceGrantKeys: Array(keys),
                    grantedAt: existing.grantedAt
                )))
            } else {
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: generation,
                    contentID: item.contentID,
                    sourceGrantKeys: [logical.identity],
                    grantedAt: grantedAt
                )))
                accumulator.newlyOwnedCount += 1
            }

            if content.kind == .entitlement,
               let unlockID = UnlockID(rawValue: item.contentID.rawValue)
            {
                let entitlementIdentity = "entitlement|\(unlockID.rawValue)"
                if projection.records[entitlementIdentity] == nil {
                    let entitlementSource: ProgressionEntitlementSource =
                        content.availability == .included ? .included : .earned
                    try projection.upsert(.entitlement(ProgressionEntitlementRecord(
                        generation: generation,
                        entitlementID: unlockID,
                        contentID: item.contentID,
                        source: entitlementSource,
                        grantedAt: grantedAt
                    )))
                    accumulator.newlyEntitledCount += 1
                }
            }

            let durableTier = durableRevealTier(group.revealTier)
            if revealEligible, content.availability != .included,
               durableTier != .none
            {
                let incoming = ProgressionGrantAccumulator.Candidate(
                    contentID: item.contentID,
                    groupID: group.grantGroupID,
                    tier: durableTier,
                    isPrimary: item.contentID == group.primaryContentID,
                    sources: [source]
                )
                if var candidate = accumulator.candidates[item.contentID] {
                    candidate.sources.insert(source)
                    if grantCandidateSortsBefore(incoming, candidate) {
                        accumulator.candidates[item.contentID] = .init(
                            contentID: incoming.contentID,
                            groupID: incoming.groupID,
                            tier: incoming.tier,
                            isPrimary: incoming.isPrimary,
                            sources: candidate.sources
                        )
                    } else {
                        accumulator.candidates[item.contentID] = candidate
                    }
                } else if !wasOwned {
                    accumulator.candidates[item.contentID] = incoming
                }
            }
        }
    }

    private static func makeReveal(
        event: ProgressionValidatedEvent,
        grants: ProgressionGrantAccumulator,
        generation: String,
        createdRevision: UInt64,
        exclusions: ProgressionRevealExclusions?
    ) throws -> PendingRevealRecord? {
        let candidates = grants.candidates.values.filter { candidate in
            !(exclusions?.contentIDs.contains(candidate.contentID) ?? false)
        }
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted {
            let lhs = (tierRank($0.tier), $0.isPrimary ? 1 : 0, $0.groupID.rawValue,
                       $0.contentID.rawValue)
            let rhs = (tierRank($1.tier), $1.isPrimary ? 1 : 0, $1.groupID.rawValue,
                       $1.contentID.rawValue)
            return lhs > rhs
        }
        guard let primary = sorted.first else { return nil }
        let secondary = sorted.dropFirst().map(\.contentID)
        let candidateSources = sorted.reduce(into: Set<ProgressionGrantSource>()) {
            $0.formUnion($1.sources)
        }
        let sourceAchievementIDs = candidateSources.compactMap { source -> AchievementID? in
            guard case let .achievement(value) = source else { return nil }
            return value
        }
        let sourceRuleIDs = candidateSources.compactMap { source -> RuleID? in
            guard case let .milestone(value) = source else { return nil }
            return value
        }
        let reveal = PendingRevealRecord(
            generation: generation,
            revealID: exclusions?.replacementRevealID ?? RevealID(
                rawValue: "reveal.\(event.envelope.eventID.rawValue.uuidString.lowercased())"
            )!,
            transactionID: eventTransactionID(event.envelope.eventID),
            createdRevision: createdRevision,
            createdAt: event.envelope.occurredAt,
            state: .queued,
            acknowledgedAt: nil,
            tier: primary.tier,
            primaryContentID: primary.contentID,
            secondaryContentIDs: secondary,
            sourceAchievementIDs: sourceAchievementIDs,
            sourceRuleIDs: sourceRuleIDs
        )
        try reveal.validate()
        return reveal
    }

    private static func grantCandidateSortsBefore(
        _ lhs: ProgressionGrantAccumulator.Candidate,
        _ rhs: ProgressionGrantAccumulator.Candidate
    ) -> Bool {
        let left = (
            tierRank(lhs.tier),
            lhs.isPrimary ? 1 : 0,
            lhs.groupID.rawValue,
            lhs.contentID.rawValue
        )
        let right = (
            tierRank(rhs.tier),
            rhs.isPrimary ? 1 : 0,
            rhs.groupID.rawValue,
            rhs.contentID.rawValue
        )
        return left > right
    }

    private static func dimensionValues(
        _ dimension: ProgressionStatisticDimension,
        payload: DomainEventPayload
    ) -> [String] {
        switch dimension {
        case .artifactID: payload.artifactIDs.map(\.rawValue)
        case .cipherToken: payload.cipherToken.map { [$0.rawValue] } ?? []
        case .codexID: payload.codexIDs.map(\.rawValue)
        case .messageToken: payload.messageToken.map { [$0.rawValue] } ?? []
        case .packageToken: payload.packageToken.map { [$0.rawValue] } ?? []
        case .relationshipToken: payload.relationshipToken.map { [$0.rawValue] } ?? []
        case .achievementID, .contentID: []
        }
    }

    private static func isLifetimeDimension(
        _ dimension: ProgressionStatisticDimension
    ) -> Bool {
        switch dimension {
        case .cipherToken, .messageToken, .packageToken, .relationshipToken:
            true
        case .achievementID, .artifactID, .codexID, .contentID:
            false
        }
    }

    private static func eligibleBucketIDs(
        event: ProgressionValidatedEvent,
        projection: ProgressionProjection,
        catalog: ProgressionCatalog
    ) throws -> [CodexID] {
        try event.envelope.payload.codexIDs.sorted().filter { codexID in
            guard let contentID = ProgressionContentID(rawValue: codexID.rawValue),
                  catalog.content(id: contentID)?.kind == .codex
            else { throw ProgressionDomainError.unknownContent(codexID.rawValue) }
            if event.envelope.eventType.rawValue == "runescribe.share.completed" {
                return projection.records["ownership|\(contentID.rawValue)"] != nil
            }
            return true
        }
    }

    private static func accepts(
        value: String,
        statistic: ProgressionStatisticDefinition,
        payload: DomainEventPayload,
        projection: ProgressionProjection,
        catalog: ProgressionCatalog
    ) -> Bool {
        guard let filter = statistic.filter else { return true }
        let contentID = ProgressionContentID(rawValue: value).flatMap {
            ProgressionNorseV2Migration.canonicalContentID($0, catalog: catalog)
        }
        switch filter {
        case "owned relic IDs only":
            return contentID.map {
                isUsableArtifact(
                    $0,
                    expectedKind: .relic,
                    projection: projection,
                    catalog: catalog
                )
            } == true
        case "owned seal IDs only":
            return contentID.map {
                isUsableArtifact(
                    $0,
                    expectedKind: .seal,
                    projection: projection,
                    catalog: catalog
                )
            } == true
        case "owned Codex IDs only":
            return contentID.flatMap(catalog.content(id:))?.kind == .codex &&
                contentID.map { projection.records["ownership|\($0.rawValue)"] != nil } == true
        case "Codex unowned at first observation":
            return contentID.flatMap(catalog.content(id:))?.kind == .codex &&
                contentID.map { projection.records["ownership|\($0.rawValue)"] == nil } == true
        case "relationshipToken present and share eligible":
            return payload.relationshipToken != nil
        default:
            return false
        }
    }

    private static func isUsableArtifact(
        _ contentID: ProgressionContentID,
        expectedKind: ProgressionCatalogContentKind,
        projection: ProgressionProjection,
        catalog: ProgressionCatalog
    ) -> Bool {
        guard let definition = catalog.content(id: contentID),
              definition.kind == expectedKind,
              projection.records["ownership|\(contentID.rawValue)"] != nil
        else { return false }
        guard let parentCodexID = definition.codexID,
              let parentContentID = ProgressionContentID(rawValue: parentCodexID.rawValue)
        else { return true }
        return projection.records["ownership|\(parentContentID.rawValue)"] != nil
    }

    private static func counterValue(
        _ statisticID: StatisticID,
        bucketID: CodexID?,
        projection: ProgressionProjection
    ) -> UInt64 {
        if case let .statisticCounter(record)? = projection.records[
            counterIdentity(statisticID, bucketID)
        ] {
            return record.value
        }
        return 0
    }

    private static func completedAchievements(
        in projection: ProgressionProjection
    ) -> Set<AchievementID> {
        Set(projection.records(matching: {
            if case let .achievementCompletion(value) = $0 { return value.achievementID }
            return nil
        }))
    }

    private static func completedMilestones(
        in projection: ProgressionProjection
    ) -> Set<RuleID> {
        Set(projection.records(matching: {
            if case let .milestoneCompletion(value) = $0 { return value.ruleID }
            return nil
        }))
    }

    private static func ownershipRecords(
        in projection: ProgressionProjection
    ) -> [ProgressionContentID: OwnershipRecord] {
        Dictionary(uniqueKeysWithValues: projection.records(matching: {
            if case let .ownership(value) = $0 { return (value.contentID, value) }
            return nil
        }))
    }

    private static func entitlementRecords(
        in projection: ProgressionProjection
    ) -> [UnlockID: ProgressionEntitlementRecord] {
        Dictionary(uniqueKeysWithValues: projection.records(matching: {
            if case let .entitlement(value) = $0 { return (value.entitlementID, value) }
            return nil
        }))
    }

    private static func durableRevealTier(
        _ tier: ProgressionCatalogRevealTier
    ) -> ProgressionDurableRevealTier {
        switch tier {
        case .none: .none
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        }
    }

    private static func tierRank(_ tier: ProgressionDurableRevealTier) -> Int {
        switch tier {
        case .none: 0
        case .micro: 1
        case .artifact: 2
        case .codex: 3
        case .mastery: 4
        }
    }

    private static func mergeProvenance(
        _ lhs: DomainEventProvenanceStatus,
        _ rhs: DomainEventProvenanceStatus
    ) -> DomainEventProvenanceStatus {
        provenanceRank(lhs) >= provenanceRank(rhs) ? lhs : rhs
    }

    private static func provenanceRank(_ value: DomainEventProvenanceStatus) -> Int {
        switch value {
        case .absent: 0
        case .verified: 1
        case .unverified: 2
        case .unsupported: 3
        case .invalid: 4
        }
    }

    private static func eventTransactionID(_ eventID: EventID) -> GrantTransactionID {
        grantTransactionID(eventID.rawValue.uuidString.lowercased())
    }

    private static func grantTransactionID(_ suffix: String) -> GrantTransactionID {
        GrantTransactionID(rawValue: "transaction.\(suffix)")!
    }

    private static func boundedUInt16(_ value: Int) -> UInt16 {
        UInt16(min(value, Int(UInt16.max)))
    }
}

private func sameLifetimeToken(_ lhs: DistinctTokenRecord, _ rhs: DistinctTokenRecord) -> Bool {
    lhs.generation == rhs.generation &&
        lhs.statisticID == rhs.statisticID &&
        lhs.bucketID == rhs.bucketID &&
        lhs.tokenDigest == rhs.tokenDigest &&
        lhs.canonicalToken == rhs.canonicalToken &&
        lhs.externalOpaqueTokenDigest == rhs.externalOpaqueTokenDigest
}

private func counterIdentity(_ statisticID: StatisticID, _ bucketID: CodexID?) -> String {
    "counter|\(statisticID.rawValue)|\(bucketID?.rawValue ?? "-")"
}

private func contentUseIdentity(_ statisticID: StatisticID, _ bucketID: CodexID?) -> String {
    "content-use|\(statisticID.rawValue)|\(bucketID?.rawValue ?? "-")"
}

private func lifetimeTokenIdentity(_ record: DistinctTokenRecord) -> String {
    "\(record.generation)|\(record.statisticID.rawValue)|\(record.bucketID?.rawValue ?? "-")|\(record.tokenDigest)"
}

private func revealID(for eventID: EventID) -> RevealID {
    RevealID(rawValue: "reveal.\(eventID.rawValue.uuidString.lowercased())")!
}
