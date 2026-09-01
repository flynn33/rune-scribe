import Foundation
import RuneScribeContracts

enum RuneScribeShare {
    static let productLink = "https://ravenforgesoftware.com/rune-scribe/"
    static let uti = RuneScribeWireFormat.contentType
    static let fileExtension = RuneScribeWireFormat.fileExtension
}

enum CanonicalMessageArtifactPolicy {
    static func accepts(_ artifact: ShareArtifactDTO) -> Bool {
        guard case .file(let referenceID) = artifact.reference else { return false }
        return referenceID == artifact.id
            && artifact.contentType == RuneScribeWireFormat.contentType
            && artifact.fileExtension == RuneScribeWireFormat.fileExtension
    }
}

enum MessageResultActionPolicy {
    static func allowsPlainCopy(
        artifactPreparationInFlight: Bool,
        hasPendingArtifact: Bool
    ) -> Bool {
        !artifactPreparationInFlight && !hasPendingArtifact
    }
}

enum MessageKeyDeliveryDisclosurePolicy {
    static func requiresKeyDelivery(
        cipherID: UUID,
        ciphers: [CipherViewState],
        encodeTimeFallback: Bool
    ) -> Bool {
        guard let cipher = ciphers.first(where: { $0.id == cipherID }) else {
            return encodeTimeFallback
        }
        return cipher.contactID != nil && !cipher.delivered
    }
}

enum ShareBuilderTerminalDisposition: Equatable, Sendable {
    case completed
    case cancelled
    case failed

    init(routeResult: ShareRouteResultDTO) {
        self = switch routeResult {
        case .completedBySystem, .sentConfirmed:
            .completed
        case .cancelled:
            .cancelled
        case .presented, .failed, .completionUnavailable:
            .failed
        }
    }
}

enum AttachmentRequirementDecision: Equatable, Sendable {
    case allowed
    case blockedNeedsAttachment
    case blockedCannotSendText
}

enum MessageAttachmentPolicy {
    static func decide(
        canSendText: Bool,
        canSendAttachments: Bool,
        utiSupported: Bool
    ) -> AttachmentRequirementDecision {
        guard canSendText else { return .blockedCannotSendText }
        guard canSendAttachments, utiSupported else { return .blockedNeedsAttachment }
        return .allowed
    }

    static func shouldConsumeDelivery(
        sent: Bool,
        requiredAttachmentWasPresent: Bool,
        requiredAttachmentAccepted: Bool
    ) -> Bool {
        sent && requiredAttachmentWasPresent && requiredAttachmentAccepted
    }
}
