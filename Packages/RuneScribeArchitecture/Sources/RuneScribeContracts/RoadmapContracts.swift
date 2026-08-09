import Foundation

public enum RoadmapContractValidationError: Error, Equatable, Sendable {
    case invalidSchemaVersion
    case invalidEventType
    case invalidSourceModuleID
    case invalidOccurredAt
    case tooManyPayloadIdentifiers(maximum: Int)
    case duplicatePayloadIdentifier
    case missingEntitlementSourceReference(EntitlementSourceKind)
    case unexpectedEntitlementSourceReference
    case invalidEntitlementSourceCount(maximum: Int)
    case duplicateEntitlementSource
}

public struct PackageTypeDescriptor: Codable, Equatable, Hashable, Sendable {
    public let kind: PackageKindID
    public let version: PackageVersionID

    public init(kind: PackageKindID, version: PackageVersionID) {
        self.kind = kind
        self.version = version
    }
}

public enum DomainEventEligibilityState: String, Codable, CaseIterable, Sendable {
    case eligible
    case ineligible
    case informational
}

public struct DomainEventEligibilityMetadata: Codable, Equatable, Hashable, Sendable {
    public let state: DomainEventEligibilityState
    public let reason: EligibilityReasonID

    public init(state: DomainEventEligibilityState, reason: EligibilityReasonID) {
        self.state = state
        self.reason = reason
    }
}

public enum EntitlementSourceKind: String, Codable, CaseIterable, Sendable {
    case included
    case earned
    case debug
    case futurePurchase
}

public struct EntitlementSourceDescriptor: Codable, Equatable, Hashable, Sendable {
    public let kind: EntitlementSourceKind
    public let referenceID: EntitlementSourceReferenceID?

    public init(
        kind: EntitlementSourceKind,
        referenceID: EntitlementSourceReferenceID? = nil
    ) throws {
        switch kind {
        case .included:
            guard referenceID == nil else {
                throw RoadmapContractValidationError.unexpectedEntitlementSourceReference
            }
        case .earned, .debug, .futurePurchase:
            guard referenceID != nil else {
                throw RoadmapContractValidationError.missingEntitlementSourceReference(kind)
            }
        }

        self.kind = kind
        self.referenceID = referenceID
    }

    public static let included = EntitlementSourceDescriptor(
        validatedKind: .included,
        referenceID: nil
    )

    public static func earned(_ referenceID: EntitlementSourceReferenceID) -> Self {
        Self(validatedKind: .earned, referenceID: referenceID)
    }

    public static func debug(_ referenceID: EntitlementSourceReferenceID) -> Self {
        Self(validatedKind: .debug, referenceID: referenceID)
    }

    public static func futurePurchase(_ referenceID: EntitlementSourceReferenceID) -> Self {
        Self(validatedKind: .futurePurchase, referenceID: referenceID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            kind: container.decode(EntitlementSourceKind.self, forKey: .kind),
            referenceID: container.decodeIfPresent(
                EntitlementSourceReferenceID.self,
                forKey: .referenceID
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(referenceID, forKey: .referenceID)
    }

    private init(
        validatedKind kind: EntitlementSourceKind,
        referenceID: EntitlementSourceReferenceID?
    ) {
        self.kind = kind
        self.referenceID = referenceID
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case referenceID
    }
}

public enum EntitlementRequirementMatch: String, Codable, CaseIterable, Sendable {
    case any
    case all
}

public struct EntitlementRequirementDescriptor: Codable, Equatable, Hashable, Sendable {
    public static let maximumSourceCount = 8

    public let requirementID: UnlockID
    public let match: EntitlementRequirementMatch
    public let sources: [EntitlementSourceDescriptor]

    public init(
        requirementID: UnlockID,
        match: EntitlementRequirementMatch = .any,
        sources: [EntitlementSourceDescriptor]
    ) throws {
        guard !sources.isEmpty, sources.count <= Self.maximumSourceCount else {
            throw RoadmapContractValidationError.invalidEntitlementSourceCount(
                maximum: Self.maximumSourceCount
            )
        }
        guard Set(sources).count == sources.count else {
            throw RoadmapContractValidationError.duplicateEntitlementSource
        }

        self.requirementID = requirementID
        self.match = match
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requirementID: container.decode(UnlockID.self, forKey: .requirementID),
            match: container.decode(EntitlementRequirementMatch.self, forKey: .match),
            sources: container.decode([EntitlementSourceDescriptor].self, forKey: .sources)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requirementID, forKey: .requirementID)
        try container.encode(match, forKey: .match)
        try container.encode(sources, forKey: .sources)
    }

    private enum CodingKeys: String, CodingKey {
        case requirementID
        case match
        case sources
    }
}

public enum DomainEventOrigin: String, Codable, CaseIterable, Sendable {
    case generated
    case imported
}

public enum DomainEventRouteClass: String, Codable, CaseIterable, Sendable {
    case file
    case customURL
    case qrCode
    case clipboard
    case shareSheet
    case messages
    case airDrop
    case other
}

public enum DomainEventProvenanceStatus: String, Codable, CaseIterable, Sendable {
    case absent
    case unverified
    case verified
    case invalid
    case unsupported
}

/// Typed, bounded event facts. The contract intentionally has no free-form
/// string field, so names, addresses, plaintext, keys, and package bytes cannot
/// be smuggled through a permissive dictionary key.
public struct DomainEventPayload: Codable, Equatable, Sendable {
    public static let maximumCodexIDs = 8
    public static let maximumArtifactIDs = 16

    public let cipherToken: CipherToken?
    public let messageToken: MessageToken?
    public let packageToken: PackageToken?
    public let relationshipToken: RelationshipToken?
    public let origin: DomainEventOrigin?
    public let routeClass: DomainEventRouteClass?
    public let codexIDs: [CodexID]
    public let artifactIDs: [ArtifactID]
    public let keyIncluded: Bool?
    public let linkedRelationship: Bool?
    public let embeddedCipher: Bool?
    public let provenanceStatus: DomainEventProvenanceStatus?

    public init(
        cipherToken: CipherToken? = nil,
        messageToken: MessageToken? = nil,
        packageToken: PackageToken? = nil,
        relationshipToken: RelationshipToken? = nil,
        origin: DomainEventOrigin? = nil,
        routeClass: DomainEventRouteClass? = nil,
        codexIDs: [CodexID] = [],
        artifactIDs: [ArtifactID] = [],
        keyIncluded: Bool? = nil,
        linkedRelationship: Bool? = nil,
        embeddedCipher: Bool? = nil,
        provenanceStatus: DomainEventProvenanceStatus? = nil
    ) throws {
        guard codexIDs.count <= Self.maximumCodexIDs else {
            throw RoadmapContractValidationError.tooManyPayloadIdentifiers(
                maximum: Self.maximumCodexIDs
            )
        }
        guard artifactIDs.count <= Self.maximumArtifactIDs else {
            throw RoadmapContractValidationError.tooManyPayloadIdentifiers(
                maximum: Self.maximumArtifactIDs
            )
        }
        guard Set(codexIDs).count == codexIDs.count,
              Set(artifactIDs).count == artifactIDs.count
        else {
            throw RoadmapContractValidationError.duplicatePayloadIdentifier
        }

        self.cipherToken = cipherToken
        self.messageToken = messageToken
        self.packageToken = packageToken
        self.relationshipToken = relationshipToken
        self.origin = origin
        self.routeClass = routeClass
        self.codexIDs = codexIDs
        self.artifactIDs = artifactIDs
        self.keyIncluded = keyIncluded
        self.linkedRelationship = linkedRelationship
        self.embeddedCipher = embeddedCipher
        self.provenanceStatus = provenanceStatus
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            cipherToken: container.decodeIfPresent(CipherToken.self, forKey: .cipherToken),
            messageToken: container.decodeIfPresent(MessageToken.self, forKey: .messageToken),
            packageToken: container.decodeIfPresent(PackageToken.self, forKey: .packageToken),
            relationshipToken: container.decodeIfPresent(
                RelationshipToken.self,
                forKey: .relationshipToken
            ),
            origin: container.decodeIfPresent(DomainEventOrigin.self, forKey: .origin),
            routeClass: container.decodeIfPresent(DomainEventRouteClass.self, forKey: .routeClass),
            codexIDs: container.decodeIfPresent([CodexID].self, forKey: .codexIDs) ?? [],
            artifactIDs: container.decodeIfPresent([ArtifactID].self, forKey: .artifactIDs) ?? [],
            keyIncluded: container.decodeIfPresent(Bool.self, forKey: .keyIncluded),
            linkedRelationship: container.decodeIfPresent(
                Bool.self,
                forKey: .linkedRelationship
            ),
            embeddedCipher: container.decodeIfPresent(Bool.self, forKey: .embeddedCipher),
            provenanceStatus: container.decodeIfPresent(
                DomainEventProvenanceStatus.self,
                forKey: .provenanceStatus
            )
        )
    }
}

/// A versioned, privacy-safe fact emitted after a domain operation has been
/// validated. Payload values are deliberately limited to bounded wire scalars;
/// plaintext, keys, contact identity, envelopes, and raw packages are not
/// valid event fields.
public struct DomainEventEnvelope: Codable, Equatable, Sendable {
    public let schemaVersion: UInt16
    public let eventID: EventID
    public let correlationID: CorrelationID
    public let eventType: EventIdentifier
    public let sourceModuleID: ModuleIdentifier
    public let occurredAt: Date
    public let eligibility: DomainEventEligibilityMetadata
    public let payload: DomainEventPayload

    public init(
        schemaVersion: UInt16,
        eventID: EventID,
        correlationID: CorrelationID,
        eventType: EventIdentifier,
        sourceModuleID: ModuleIdentifier,
        occurredAt: Date,
        eligibility: DomainEventEligibilityMetadata,
        payload: DomainEventPayload
    ) throws {
        guard schemaVersion > 0 else {
            throw RoadmapContractValidationError.invalidSchemaVersion
        }
        guard RoadmapIdentifierSyntax.isValidIdentifier(eventType.rawValue) else {
            throw RoadmapContractValidationError.invalidEventType
        }
        guard RoadmapIdentifierSyntax.isValidIdentifier(sourceModuleID.rawValue) else {
            throw RoadmapContractValidationError.invalidSourceModuleID
        }
        guard occurredAt.timeIntervalSinceReferenceDate.isFinite else {
            throw RoadmapContractValidationError.invalidOccurredAt
        }

        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.correlationID = correlationID
        self.eventType = eventType
        self.sourceModuleID = sourceModuleID
        self.occurredAt = occurredAt
        self.eligibility = eligibility
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            eventID: container.decode(EventID.self, forKey: .eventID),
            correlationID: container.decode(CorrelationID.self, forKey: .correlationID),
            eventType: container.decode(EventIdentifier.self, forKey: .eventType),
            sourceModuleID: container.decode(ModuleIdentifier.self, forKey: .sourceModuleID),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            eligibility: container.decode(
                DomainEventEligibilityMetadata.self,
                forKey: .eligibility
            ),
            payload: container.decode(DomainEventPayload.self, forKey: .payload)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(correlationID, forKey: .correlationID)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(sourceModuleID, forKey: .sourceModuleID)
        try container.encode(occurredAt, forKey: .occurredAt)
        try container.encode(eligibility, forKey: .eligibility)
        try container.encode(payload, forKey: .payload)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case eventID
        case correlationID
        case eventType
        case sourceModuleID
        case occurredAt
        case eligibility
        case payload
    }
}
