import Foundation
import RuneScribeContracts
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum ValidatedSafePreviewImageDecoder {
    static func image(from safePreviewData: Data) -> Image? {
        #if os(macOS)
        guard let image = NSImage(data: safePreviewData) else { return nil }
        return Image(nsImage: image)
        #elseif os(iOS)
        guard let image = UIImage(data: safePreviewData) else { return nil }
        return Image(uiImage: image)
        #endif
    }
}

struct ReceivedPresentationViewModel: Equatable, Sendable {
    let codexTitle: String
    let renderStatusTitle: String
    let renderStatusDetail: String
    let renderStatusSystemImage: String
    let safePreviewTitle: String
    let safePreviewDetail: String
    let safePreviewSystemImage: String
    let provenanceTitle: String
    let provenanceDetail: String
    let provenanceSystemImage: String
    let encounterDetail: String

    init(_ presentation: ReceivedSharePresentation) {
        codexTitle = presentation.requestedSelection.codexID.rawValue
        if presentation.renderMode == .requestedCodex {
            renderStatusTitle = "Sender Codex available"
            renderStatusDetail = "The inscription is using the sender's requested Codex."
            renderStatusSystemImage = "checkmark.shield.fill"
        } else {
            renderStatusTitle = "Reading with the Norse Codex"
            renderStatusDetail = Self.fallbackDetail(presentation.providerAvailability)
            renderStatusSystemImage = "arrow.trianglehead.branch"
        }
        (safePreviewTitle, safePreviewDetail, safePreviewSystemImage) = switch presentation
            .safePreviewStatus {
        case .valid:
            (
                "Sender preview verified",
                "The sender-rendered 4:3 preview passed its size, media, and hash checks.",
                "photo.badge.checkmark"
            )
        case .absent:
            (
                "No sender preview",
                "Interactive reading remains available without a static preview.",
                "photo.badge.plus"
            )
        case .invalid:
            (
                "Sender preview unavailable",
                "The static preview did not pass validation and was not displayed.",
                "photo.badge.exclamationmark"
            )
        }
        (provenanceTitle, provenanceDetail, provenanceSystemImage) = switch presentation
            .provenanceStatus {
        case .verified:
            (
                "Provenance verified",
                "The signed presentation record matches a trusted Rune Scribe signer.",
                "checkmark.seal.fill"
            )
        case .unverified:
            (
                "Provenance unverified",
                "A provenance reference is present, but it has not been verified.",
                "questionmark.diamond.fill"
            )
        case .unavailable:
            (
                "Provenance unavailable",
                "No trusted provenance result is available for this presentation.",
                "minus.circle.fill"
            )
        case .invalid:
            (
                "Provenance invalid",
                "The presentation remains readable, but its provenance did not validate.",
                "exclamationmark.shield.fill"
            )
        }
        encounterDetail = switch presentation.encounterRecordingStatus {
        case .recorded:
            "Encounter recorded for discovery. Encountering a Codex does not grant ownership."
        case .unavailable:
            "This encounter could not be recorded. The message remains readable and no ownership was granted."
        }
    }

    private static func fallbackDetail(_ availability: ShareProviderAvailability) -> String {
        switch availability {
        case .available:
            "The requested Codex is available."
        case .locked:
            "The sender's Codex is locked for creation, but the message remains readable."
        case .unknown:
            "This version does not recognize the sender's Codex."
        case .unavailable:
            "The sender's Codex is temporarily unavailable."
        case .incompatible:
            "The sender's presentation version is not compatible with this device."
        case .corrupt:
            "The sender's Codex resources did not pass validation."
        case .notInstalled:
            "The sender's Codex is not installed on this device."
        }
    }
}

struct ReceivedPresentationSummary: View {
    let model: ReceivedPresentationViewModel
    let safePreviewData: Data?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let preview = previewImage {
                preview
                    .resizable()
                    .scaledToFit()
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .accessibilityLabel(Text(model.safePreviewTitle))
                    .accessibilityIdentifier("received.safe-preview")
                    .runtimeViewportFrameProbe("received.safe-preview")
            }
            Text("Sender Codex: \(model.codexTitle)")
                .font(.caption)
            Label(model.renderStatusTitle, systemImage: model.renderStatusSystemImage)
                .font(.headline)
            Text(model.renderStatusDetail)
                .font(.subheadline)
            Label(model.safePreviewTitle, systemImage: model.safePreviewSystemImage)
                .font(.headline)
            Text(model.safePreviewDetail)
                .font(.subheadline)
            Label(model.provenanceTitle, systemImage: model.provenanceSystemImage)
                .font(.headline)
            Text(model.provenanceDetail)
                .font(.subheadline)
            Label(model.encounterDetail, systemImage: "sparkles.rectangle.stack")
                .font(.footnote)
        }
        .accessibilityElement(children: .contain)
    }

    private var previewImage: Image? {
        guard let safePreviewData else { return nil }
        return ValidatedSafePreviewImageDecoder.image(from: safePreviewData)
    }
}
