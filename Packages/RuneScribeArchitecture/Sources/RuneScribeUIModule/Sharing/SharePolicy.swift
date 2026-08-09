import RuneScribeContracts

enum RuneScribeShare {
    static let productLink = "https://ravenforgesoftware.com/rune-scribe/"
    static let uti = RuneScribeWireFormat.contentType
    static let fileExtension = RuneScribeWireFormat.fileExtension
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
        utiSupported: Bool,
        requiredAttachment: Bool
    ) -> AttachmentRequirementDecision {
        guard canSendText else { return .blockedCannotSendText }
        guard requiredAttachment else { return .allowed }
        guard canSendAttachments, utiSupported else { return .blockedNeedsAttachment }
        return .allowed
    }

    static func shouldConsumeDelivery(
        sent: Bool,
        requiredAttachmentWasPresent: Bool,
        requiredAttachmentAccepted: Bool
    ) -> Bool {
        guard sent else { return false }
        guard requiredAttachmentWasPresent else { return true }
        return requiredAttachmentAccepted
    }
}
