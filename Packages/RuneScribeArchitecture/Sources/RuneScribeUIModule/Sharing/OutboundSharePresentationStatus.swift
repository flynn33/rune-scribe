import Foundation
import RuneScribeContracts

enum OutboundSharePresentationFallbackReason: String, Equatable, Sendable {
    case themeUnavailable = "theme-unavailable"
    case selectionUnavailable = "selection-unavailable"
    case resourceUnavailable = "resource-unavailable"
    case renderingUnavailable = "rendering-unavailable"
    case invalidPresentation = "invalid-presentation"
}

enum OutboundSharePresentationStatus: Equatable, Sendable {
    case idle
    case themed
    case legacyFallback(OutboundSharePresentationFallbackReason)

    var diagnosticCode: String? {
        switch self {
        case .idle:
            nil
        case .themed:
            "share.presentation.themed"
        case .legacyFallback(let reason):
            "share.presentation.legacy-fallback.\(reason.rawValue)"
        }
    }

    var userVisibleMessage: String? {
        guard case .legacyFallback = self else { return nil }
        return "The themed appearance was unavailable, so Rune Scribe prepared the compatible standard share instead."
    }
}

struct OutboundSharePresentationPreparation: Sendable {
    let presentation: OutboundSharePresentationDTO?
    let status: OutboundSharePresentationStatus
    let rendererOutputID: String?

    init(
        presentation: OutboundSharePresentationDTO?,
        status: OutboundSharePresentationStatus,
        rendererOutputID: String? = nil
    ) {
        self.presentation = presentation
        self.status = status
        self.rendererOutputID = rendererOutputID
    }
}
