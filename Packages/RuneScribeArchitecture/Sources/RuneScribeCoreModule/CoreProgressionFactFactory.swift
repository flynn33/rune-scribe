import Foundation
import RuneScribeContracts

enum CoreProgressionFactError: Error, Equatable, Sendable {
    case invalidRelationshipEvidence
}

enum CoreProgressionFactFactory {
    static let implicitNorseCodexID = CodexID(rawValue: "codex.norse")!

    static func cipherCreated(
        cipherToken: CipherToken
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.cipher.created",
            payload: DomainEventPayload(
                cipherToken: cipherToken,
                origin: .generated
            )
        )
    }

    static func cipherImported(
        cipherToken: CipherToken,
        routeClass: DomainEventRouteClass
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.cipher.imported",
            payload: DomainEventPayload(
                cipherToken: cipherToken,
                origin: .imported,
                routeClass: routeClass
            )
        )
    }

    static func messageEncoded(
        messageToken: MessageToken,
        cipherToken: CipherToken,
        codexIDs: [CodexID] = [implicitNorseCodexID]
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.message.encoded",
            payload: DomainEventPayload(
                cipherToken: cipherToken,
                messageToken: messageToken,
                origin: .generated,
                codexIDs: codexIDs
            )
        )
    }

    static func shareCompleted(
        report: SharePresentationReportDTO,
        messageToken: MessageToken,
        codexIDs: [CodexID] = [implicitNorseCodexID],
        artifactIDs: [ArtifactID] = [],
        keyIncluded: Bool,
        relationshipToken: RelationshipToken?,
        linkedRelationship: Bool
    ) throws -> ProgressionEventFact? {
        guard report.isEligibleTerminal(requiresKeyDelivery: keyIncluded) else {
            return nil
        }
        guard relationshipToken == nil || linkedRelationship else {
            throw CoreProgressionFactError.invalidRelationshipEvidence
        }

        let reason: EligibilityReasonID
        switch report.result {
        case .sentConfirmed:
            reason = identifier("eligibility.eligible.message-sent-confirmed")
        case .completedBySystem:
            reason = identifier("eligibility.eligible.share-completed-by-system")
        case .presented, .cancelled, .failed, .completionUnavailable:
            return nil
        }

        return try ProgressionEventFact(
            eventType: eventIdentifier("runescribe.share.completed"),
            eligibility: DomainEventEligibilityMetadata(
                state: .eligible,
                reason: reason
            ),
            payload: DomainEventPayload(
                messageToken: messageToken,
                relationshipToken: relationshipToken,
                routeClass: domainRoute(for: report.routeClass),
                codexIDs: codexIDs,
                artifactIDs: artifactIDs,
                keyIncluded: keyIncluded,
                linkedRelationship: linkedRelationship
            )
        )
    }

    static func firstDeliveryCompleted(
        cipherToken: CipherToken,
        relationshipToken: RelationshipToken
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.cipher.first-delivery-completed",
            payload: DomainEventPayload(
                cipherToken: cipherToken,
                relationshipToken: relationshipToken,
                keyIncluded: true,
                linkedRelationship: true
            )
        )
    }

    static func messageImported(
        packageToken: PackageToken,
        routeClass: DomainEventRouteClass,
        embeddedCipher: Bool,
        codexIDs: [CodexID] = [implicitNorseCodexID],
        artifactIDs: [ArtifactID] = [],
        provenanceStatus: DomainEventProvenanceStatus? = nil
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.message.imported",
            payload: DomainEventPayload(
                packageToken: packageToken,
                origin: .imported,
                routeClass: routeClass,
                codexIDs: codexIDs,
                artifactIDs: artifactIDs,
                embeddedCipher: embeddedCipher,
                provenanceStatus: provenanceStatus
            )
        )
    }

    static func messageDecoded(
        packageToken: PackageToken,
        relationshipToken: RelationshipToken?,
        codexIDs: [CodexID] = [implicitNorseCodexID],
        artifactIDs: [ArtifactID] = [],
        provenanceStatus: DomainEventProvenanceStatus? = nil
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.message.decoded",
            payload: DomainEventPayload(
                packageToken: packageToken,
                relationshipToken: relationshipToken,
                origin: .imported,
                codexIDs: codexIDs,
                artifactIDs: artifactIDs,
                provenanceStatus: provenanceStatus
            )
        )
    }

    static func bidirectionalEstablished(
        relationshipToken: RelationshipToken
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.exchange.bidirectional-established",
            payload: DomainEventPayload(relationshipToken: relationshipToken)
        )
    }

    static func presentationObserved(
        packageToken: PackageToken,
        codexIDs: [CodexID],
        artifactIDs: [ArtifactID] = [],
        provenanceStatus: DomainEventProvenanceStatus? = nil
    ) throws -> ProgressionEventFact {
        try domainFact(
            type: "runescribe.presentation.observed",
            payload: DomainEventPayload(
                packageToken: packageToken,
                codexIDs: codexIDs,
                artifactIDs: artifactIDs,
                provenanceStatus: provenanceStatus
            )
        )
    }

    private static func domainFact(
        type: String,
        payload: DomainEventPayload
    ) throws -> ProgressionEventFact {
        try ProgressionEventFact(
            eventType: eventIdentifier(type),
            eligibility: DomainEventEligibilityMetadata(
                state: .eligible,
                reason: identifier("eligibility.eligible.domain-commit")
            ),
            payload: payload
        )
    }

    private static func domainRoute(
        for routeClass: ShareRouteClassDTO
    ) -> DomainEventRouteClass {
        switch routeClass {
        case .messages: .messages
        case .shareSheet: .shareSheet
        case .airDrop: .airDrop
        case .fileExport: .fileExport
        case .clipboard: .clipboard
        case .qrDisplay: .qrDisplay
        }
    }

    private static func eventIdentifier(_ rawValue: String) -> EventIdentifier {
        EventIdentifier(rawValue: rawValue)
    }

    private static func identifier(_ rawValue: String) -> EligibilityReasonID {
        EligibilityReasonID(rawValue: rawValue)!
    }
}
