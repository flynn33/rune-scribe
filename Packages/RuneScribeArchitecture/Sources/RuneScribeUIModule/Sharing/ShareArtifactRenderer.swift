import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

#if os(macOS)
import AppKit
private typealias ShareArtifactPlatformFont = NSFont
#elseif os(iOS)
import UIKit
private typealias ShareArtifactPlatformFont = UIFont
#endif

enum ShareArtifactRenderError: Error, Equatable, Sendable {
    case invalidRequest
    case unknownSelection
    case lockedSelection(ArtifactID)
    case unavailableSelection
    case incompatibleFrame
    case unavailableSealAnchor
    case inscriptionTooLong
    case missingResource(ThemeResourceID)
    case invalidResource(ThemeResourceID)
    case renderingFailed
    case outputTooLarge
}

enum ShareBuilderItemAccess: String, Equatable, Sendable {
    case owned
    case locked
    case unavailable
}

struct ShareBuilderItem: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let displayName: String
    let access: ShareBuilderItemAccess
}

enum ShareBuilderPolicy {
    static func relics(
        in descriptor: ThemeDescriptor,
        ownedArtifactIDs: Set<ArtifactID>,
        providerAvailable: Bool
    ) -> [ShareBuilderItem] {
        descriptor.codex.relics.compactMap { relic in
            guard relic.metadata.availability != .reservedInactive else { return nil }
            return item(
                relic.metadata,
                ownedArtifactIDs: ownedArtifactIDs,
                providerAvailable: providerAvailable
            )
        }
    }

    static func seals(
        in descriptor: ThemeDescriptor,
        ownedArtifactIDs: Set<ArtifactID>,
        providerAvailable: Bool
    ) -> [ShareBuilderItem] {
        descriptor.codex.seals.compactMap { seal in
            guard seal.metadata.availability != .reservedInactive else { return nil }
            return item(
                seal.metadata,
                ownedArtifactIDs: ownedArtifactIDs,
                providerAvailable: providerAvailable
            )
        }
    }

    static func frames(
        in descriptor: ThemeDescriptor,
        ownedArtifactIDs: Set<ArtifactID>,
        providerAvailable: Bool
    ) -> [ShareBuilderItem] {
        descriptor.codex.frames.compactMap { frame in
            guard frame.metadata.availability != .reservedInactive else { return nil }
            return item(
                frame.metadata,
                ownedArtifactIDs: ownedArtifactIDs,
                providerAvailable: providerAvailable
            )
        }
    }

    static func selection(
        descriptor: ThemeDescriptor,
        codexOwned: Bool,
        providerAvailable: Bool,
        ownedArtifactIDs: Set<ArtifactID>,
        relicID: ArtifactID?,
        sealID: ArtifactID?,
        frameID: ArtifactID?
    ) throws -> SharePresentationSelection {
        guard codexOwned || descriptor.criticality == .requiredBase,
              providerAvailable
        else { throw ShareArtifactRenderError.unavailableSelection }

        let effectiveRelicID = relicID ?? descriptor.codex.defaultRelicID
        guard let relic = descriptor.codex.relics.first(where: {
            $0.metadata.id == effectiveRelicID
        }) else { throw ShareArtifactRenderError.unknownSelection }
        try requireOwned(relic.metadata, ownedArtifactIDs: ownedArtifactIDs)

        if let sealID {
            guard let seal = descriptor.codex.seals.first(where: {
                $0.metadata.id == sealID
            }) else { throw ShareArtifactRenderError.unknownSelection }
            try requireOwned(seal.metadata, ownedArtifactIDs: ownedArtifactIDs)
        }
        if let frameID {
            guard let frame = descriptor.codex.frames.first(where: {
                $0.metadata.id == frameID
            }) else { throw ShareArtifactRenderError.unknownSelection }
            try requireOwned(frame.metadata, ownedArtifactIDs: ownedArtifactIDs)
            guard frame.compatibleRelicIDs.contains(effectiveRelicID),
                  frame.allowsStaticShare
            else { throw ShareArtifactRenderError.incompatibleFrame }
        }
        return try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: effectiveRelicID,
            sealID: sealID,
            frameID: frameID,
            presentationVersion: SharePresentationSelection.supportedPresentationVersion
        )
    }

    private static func item(
        _ metadata: ThemeArtifactMetadata,
        ownedArtifactIDs: Set<ArtifactID>,
        providerAvailable: Bool
    ) -> ShareBuilderItem {
        let access: ShareBuilderItemAccess
        if !providerAvailable {
            access = .unavailable
        } else if metadata.availability == .included
                    || ownedArtifactIDs.contains(metadata.id) {
            access = .owned
        } else {
            access = .locked
        }
        return ShareBuilderItem(
            id: metadata.id,
            displayName: metadata.displayName.fallbackValue,
            access: access
        )
    }

    private static func requireOwned(
        _ metadata: ThemeArtifactMetadata,
        ownedArtifactIDs: Set<ArtifactID>
    ) throws {
        guard metadata.availability == .included || ownedArtifactIDs.contains(metadata.id)
        else { throw ShareArtifactRenderError.lockedSelection(metadata.id) }
    }
}

enum ShareArtifactColorMode: String, Equatable, Sendable {
    case standard
    case highContrast = "high-contrast"
    case monochrome
}

struct ShareArtifactRenderRequest: Equatable, Sendable {
    static let maximumInscriptionCharacters = 4_096
    static let maximumAccessibilityUTF8Count = 1_024

    let selection: SharePresentationSelection
    let inscription: String
    let operationID: RuntimeOperationID
    let capturedAt: Date
    let localeIdentifier: String
    let scale: Double
    let colorMode: ShareArtifactColorMode
    let reduceMotion: Bool
    let accessibilityLabel: String
    let provenanceLabel: String?
    let fontPostScriptNameOverride: ThemeFontPostScriptName?

    init(
        selection: SharePresentationSelection,
        inscription: String,
        operationID: RuntimeOperationID,
        capturedAt: Date,
        localeIdentifier: String = "en-US",
        scale: Double = 1,
        colorMode: ShareArtifactColorMode = .standard,
        reduceMotion: Bool = false,
        accessibilityLabel: String,
        provenanceLabel: String? = nil,
        fontPostScriptNameOverride: ThemeFontPostScriptName? = nil
    ) throws {
        guard !inscription.isEmpty,
              inscription.count <= Self.maximumInscriptionCharacters,
              !operationID.rawValue.isEmpty,
              capturedAt.timeIntervalSinceReferenceDate.isFinite,
              !localeIdentifier.isEmpty,
              localeIdentifier.utf8.count <= 64,
              scale.isFinite,
              (1...3).contains(scale),
              !accessibilityLabel.isEmpty,
              accessibilityLabel.utf8.count <= Self.maximumAccessibilityUTF8Count,
              (provenanceLabel?.utf8.count ?? 0) <= Self.maximumAccessibilityUTF8Count
        else { throw ShareArtifactRenderError.invalidRequest }
        self.selection = selection
        self.inscription = inscription
        self.operationID = operationID
        self.capturedAt = capturedAt
        self.localeIdentifier = localeIdentifier
        self.scale = scale
        self.colorMode = colorMode
        self.reduceMotion = reduceMotion
        self.accessibilityLabel = accessibilityLabel
        self.provenanceLabel = provenanceLabel
        self.fontPostScriptNameOverride = fontPostScriptNameOverride
    }
}

struct ShareArtifactRenderPage: Equatable, Hashable, Sendable {
    let index: Int
    let count: Int
    let inscription: String
}

/// Provider-neutral composition shared by the interactive workspace preview
/// and deterministic static sharing. It is deliberately pure: image bytes and
/// platform image objects remain in their respective runtime/rendering rails.
struct ThemeArtifactGlyphStyle: Equatable, Sendable {
    let pointSize: Double
    let color: ThemeSemanticColor
}

struct ThemeArtifactCompositionPlan: Equatable, Sendable {
    let selection: SharePresentationSelection
    let inscription: String
    let palette: ThemeSemanticPalette
    let layout: ThemeShareLayoutPreset
    let pages: [ShareArtifactRenderPage]
    let relicResourceID: ThemeResourceID
    let sealResourceID: ThemeResourceID?
    let frameResourceID: ThemeResourceID?
    let backgroundResourceID: ThemeResourceID
    let sealAnchor: ThemeNormalizedPoint?
    let sealScale: Double
    let fontPostScriptName: String
    let fontResourceID: ThemeResourceID?
    let glyphStyle: ThemeArtifactGlyphStyle
    let usesExternalFontOverride: Bool
    let colorMode: ShareArtifactColorMode
    let accessibilityLabel: String
    let provenanceLabel: String?
}

struct ShareArtifactRenderPlan: Equatable, Sendable {
    static let outputWidth = 1_200
    static let outputHeight = 900

    let request: ShareArtifactRenderRequest
    let palette: ThemeSemanticPalette
    let layout: ThemeShareLayoutPreset
    let pages: [ShareArtifactRenderPage]
    let relicResourceID: ThemeResourceID
    let sealResourceID: ThemeResourceID?
    let frameResourceID: ThemeResourceID?
    let backgroundResourceID: ThemeResourceID
    let sealAnchor: ThemeNormalizedPoint?
    let sealScale: Double
    let fontPostScriptName: String
    let fontResourceID: ThemeResourceID?
    let glyphStyle: ThemeArtifactGlyphStyle
    let resourceMetadata: [SharePresentationResourceMetadata]

    var composition: ThemeArtifactCompositionPlan {
        ThemeArtifactCompositionPlan(
            selection: request.selection,
            inscription: request.inscription,
            palette: palette,
            layout: layout,
            pages: pages,
            relicResourceID: relicResourceID,
            sealResourceID: sealResourceID,
            frameResourceID: frameResourceID,
            backgroundResourceID: backgroundResourceID,
            sealAnchor: sealAnchor,
            sealScale: sealScale,
            fontPostScriptName: fontPostScriptName,
            fontResourceID: fontResourceID,
            glyphStyle: glyphStyle,
            usesExternalFontOverride: request.fontPostScriptNameOverride != nil,
            colorMode: request.colorMode,
            accessibilityLabel: request.accessibilityLabel,
            provenanceLabel: request.provenanceLabel
        )
    }
}

enum ThemeArtifactCompositionPolicy {
    static let maximumPageCount = 16

    static func plan(
        request: ShareArtifactRenderRequest,
        descriptor: ThemeDescriptor,
        preferredSealAnchor: ThemeSealAnchorCategory? = .lowerRight
    ) throws -> ThemeArtifactCompositionPlan {
        try compose(
            selection: request.selection,
            inscription: request.inscription,
            descriptor: descriptor,
            colorMode: request.colorMode,
            reduceMotion: request.reduceMotion,
            accessibilityLabel: request.accessibilityLabel,
            provenanceLabel: request.provenanceLabel,
            fontPostScriptNameOverride: request.fontPostScriptNameOverride,
            preferredSealAnchor: preferredSealAnchor
        )
    }

    static func interactivePlan(
        selection: SharePresentationSelection,
        inscription: String,
        descriptor: ThemeDescriptor,
        colorMode: ShareArtifactColorMode,
        reduceMotion: Bool,
        accessibilityLabel: String,
        provenanceLabel: String? = nil,
        fontPostScriptNameOverride: ThemeFontPostScriptName? = nil,
        preferredSealAnchor: ThemeSealAnchorCategory? = .lowerRight
    ) throws -> ThemeArtifactCompositionPlan {
        guard !inscription.isEmpty,
              inscription.count <= ShareArtifactRenderRequest.maximumInscriptionCharacters,
              !accessibilityLabel.isEmpty,
              accessibilityLabel.utf8.count
                <= ShareArtifactRenderRequest.maximumAccessibilityUTF8Count,
              (provenanceLabel?.utf8.count ?? 0)
                <= ShareArtifactRenderRequest.maximumAccessibilityUTF8Count
        else { throw ShareArtifactRenderError.invalidRequest }
        return try compose(
            selection: selection,
            inscription: inscription,
            descriptor: descriptor,
            colorMode: colorMode,
            reduceMotion: reduceMotion,
            accessibilityLabel: accessibilityLabel,
            provenanceLabel: provenanceLabel,
            fontPostScriptNameOverride: fontPostScriptNameOverride,
            preferredSealAnchor: preferredSealAnchor
        )
    }

    private static func compose(
        selection: SharePresentationSelection,
        inscription: String,
        descriptor: ThemeDescriptor,
        colorMode: ShareArtifactColorMode,
        reduceMotion: Bool,
        accessibilityLabel: String,
        provenanceLabel: String?,
        fontPostScriptNameOverride: ThemeFontPostScriptName?,
        preferredSealAnchor: ThemeSealAnchorCategory?
    ) throws -> ThemeArtifactCompositionPlan {
        guard descriptor.codex.id == selection.codexID,
              let script = descriptor.codex.scripts.first(where: {
                  $0.id == selection.scriptID
              }),
              let relic = descriptor.codex.relics.first(where: {
                  $0.metadata.id == selection.relicID
              }),
              let layout = relic.layouts.first(where: {
                  $0.id == relic.defaultLayoutID
              })
        else { throw ShareArtifactRenderError.unknownSelection }

        let seal = selection.sealID.flatMap { id in
            descriptor.codex.seals.first(where: { $0.metadata.id == id })
        }
        if selection.sealID != nil, seal == nil {
            throw ShareArtifactRenderError.unknownSelection
        }
        let frame = selection.frameID.flatMap { id in
            descriptor.codex.frames.first(where: { $0.metadata.id == id })
        }
        if selection.frameID != nil, frame == nil {
            throw ShareArtifactRenderError.unknownSelection
        }
        if let frame,
           (!frame.compatibleRelicIDs.contains(relic.metadata.id)
            || !frame.allowsStaticShare) {
            throw ShareArtifactRenderError.incompatibleFrame
        }

        let selectedAnchor: ThemeSealAnchor?
        if let seal {
            let candidates = layout.sealAnchors.filter {
                seal.allowedAnchors.contains($0.category)
            }
            guard !candidates.isEmpty else {
                throw ShareArtifactRenderError.unavailableSealAnchor
            }
            if let preferredSealAnchor {
                selectedAnchor = candidates.first(where: {
                    $0.category == preferredSealAnchor
                }) ?? candidates[0]
            } else {
                selectedAnchor = candidates[0]
            }
        } else {
            selectedAnchor = nil
        }

        let fontName = fontPostScriptNameOverride?.rawValue
            ?? script.fontPostScriptName?.rawValue
            ?? "NotoSansRunic-Regular"
        let pages = try paginate(
            inscription,
            layout: layout,
            fontName: fontName,
            pointSize: script.recommendedPointSizes.maximum
        )
        let relicResourceID: ThemeResourceID = switch colorMode {
        case .highContrast: relic.highContrastResourceID
        case .standard, .monochrome: relic.staticFallbackResourceID
        }
        let sealResourceID: ThemeResourceID? = seal.map {
            switch colorMode {
            case .standard, .highContrast:
                $0.standardResourceID
            case .monochrome:
                $0.monochromeFallbackResourceID
            }
        }
        let frameResourceID = frame?.staticFallbackResourceID
        let backgroundResourceID: ThemeResourceID = if colorMode == .highContrast {
            descriptor.codex.background.highContrastResourceID
        } else if reduceMotion {
            descriptor.codex.background.reduceMotionResourceID
        } else {
            descriptor.codex.background.staticBaseResourceID
        }
        return ThemeArtifactCompositionPlan(
            selection: selection,
            inscription: inscription,
            palette: descriptor.codex.palette,
            layout: layout,
            pages: pages,
            relicResourceID: relicResourceID,
            sealResourceID: sealResourceID,
            frameResourceID: frameResourceID,
            backgroundResourceID: backgroundResourceID,
            sealAnchor: selectedAnchor?.point,
            sealScale: seal.map {
                min($0.allowedScale.maximum, max($0.allowedScale.minimum, 0.18))
            } ?? 0,
            fontPostScriptName: fontName,
            fontResourceID: fontPostScriptNameOverride == nil
                ? script.fontResourceID : nil,
            glyphStyle: ThemeArtifactGlyphStyle(
                pointSize: script.recommendedPointSizes.maximum,
                color: descriptor.codex.palette.textInverse
            ),
            usesExternalFontOverride: fontPostScriptNameOverride != nil,
            colorMode: colorMode,
            accessibilityLabel: accessibilityLabel,
            provenanceLabel: provenanceLabel
        )
    }

    private static func paginate(
        _ inscription: String,
        layout: ThemeShareLayoutPreset,
        fontName: String,
        pointSize: Double
    ) throws -> [ShareArtifactRenderPage] {
        let font: ShareArtifactPlatformFont
        #if os(macOS)
        font = NSFont(name: fontName, size: pointSize)
            ?? NSFont.systemFont(ofSize: pointSize)
        let lineHeight = font.ascender - font.descender + font.leading
        #else
        font = UIFont(name: fontName, size: pointSize)
            ?? UIFont.systemFont(ofSize: pointSize)
        let lineHeight = font.lineHeight
        #endif
        let maximumWidth = Double(ShareArtifactRenderPlan.outputWidth)
            * layout.glyphSafeRegion.width * 0.9
        let maximumHeight = Double(ShareArtifactRenderPlan.outputHeight)
            * layout.glyphSafeRegion.height * 0.9
        let maximumLines = min(
            Int(layout.maximumGlyphLines),
            Int(maximumHeight / lineHeight)
        )
        guard maximumLines > 0 else { throw ShareArtifactRenderError.invalidRequest }

        func fits(_ text: String) -> Bool {
            (text as NSString).size(withAttributes: [.font: font]).width
                <= maximumWidth
        }

        let hardLines = inscription.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        var renderedLines: [String] = []
        renderedLines.reserveCapacity(hardLines.count)
        for hardLine in hardLines {
            let characters = Array(hardLine)
            if characters.isEmpty {
                renderedLines.append("")
                continue
            }
            var line = ""
            for character in characters {
                let candidate = line + String(character)
                if !line.isEmpty && !fits(candidate) {
                    renderedLines.append(line)
                    line = String(character)
                } else {
                    line = candidate
                }
                guard fits(line) else {
                    throw ShareArtifactRenderError.inscriptionTooLong
                }
            }
            renderedLines.append(line)
        }

        let pageCount = max(
            1,
            Int(ceil(Double(renderedLines.count) / Double(maximumLines)))
        )
        guard pageCount <= maximumPageCount else {
            throw ShareArtifactRenderError.inscriptionTooLong
        }
        return (0..<pageCount).map { pageIndex in
            let pageStart = pageIndex * maximumLines
            let pageEnd = min(renderedLines.count, pageStart + maximumLines)
            return ShareArtifactRenderPage(
                index: pageIndex,
                count: pageCount,
                inscription: renderedLines[pageStart..<pageEnd].joined(separator: "\n")
            )
        }
    }
}

enum ShareArtifactRenderPolicy {
    static let maximumPageCount = ThemeArtifactCompositionPolicy.maximumPageCount

    static func plan(
        request: ShareArtifactRenderRequest,
        descriptor: ThemeDescriptor,
        preferredSealAnchor: ThemeSealAnchorCategory? = nil
    ) throws -> ShareArtifactRenderPlan {
        let composition = try ThemeArtifactCompositionPolicy.plan(
            request: request,
            descriptor: descriptor,
            preferredSealAnchor: preferredSealAnchor
        )
        var seenResourceIDs = Set<ThemeResourceID>()
        let resourceIDs = [
            composition.relicResourceID,
            composition.sealResourceID,
            composition.frameResourceID,
            composition.backgroundResourceID,
            composition.fontResourceID,
        ].compactMap { $0 }.filter { seenResourceIDs.insert($0).inserted }
        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map {
            ($0.id, $0)
        })
        let metadata = try resourceIDs.map { resourceID -> SharePresentationResourceMetadata in
            guard let reference = references[resourceID] else {
                throw ShareArtifactRenderError.missingResource(resourceID)
            }
            let sharePixelSize: ThemePixelSize? = switch reference.mediaType {
            case .png, .heif:
                reference.integrity.pixelSize
            case .pdf, .ttf, .otf, .json, .mp4, .quickTime, .m4a, .caf, .wav:
                nil
            }
            return try SharePresentationResourceMetadata(
                resourceID: reference.id,
                role: reference.role,
                mediaType: reference.mediaType,
                byteLength: reference.integrity.byteLength,
                pixelSize: sharePixelSize,
                sha256: reference.integrity.sha256
            )
        }
        return ShareArtifactRenderPlan(
            request: request,
            palette: composition.palette,
            layout: composition.layout,
            pages: composition.pages,
            relicResourceID: composition.relicResourceID,
            sealResourceID: composition.sealResourceID,
            frameResourceID: composition.frameResourceID,
            backgroundResourceID: composition.backgroundResourceID,
            sealAnchor: composition.sealAnchor,
            sealScale: composition.sealScale,
            fontPostScriptName: composition.fontPostScriptName,
            fontResourceID: composition.fontResourceID,
            glyphStyle: composition.glyphStyle,
            resourceMetadata: metadata
        )
    }
}

struct ShareArtifactStaticOutput: Equatable, Sendable {
    let pagePNGData: [Data]
    let safePreviewMetadata: ShareSafePreviewMetadata
    let rendererOutputID: String

    func presentationMetadata(
        for plan: ShareArtifactRenderPlan,
        provenance: ShareProvenanceReference? = nil
    ) throws -> SharePresentationMetadata {
        var compatibility = SharePresentationCompatibilityFlags.safePreviewPresent
            .union(.norseInteractiveFallback)
        if plan.request.colorMode == .highContrast {
            compatibility = compatibility.union(.highContrastPreviewAvailable)
        }
        if plan.request.colorMode == .monochrome {
            compatibility = compatibility.union(.monochromePreviewAvailable)
        }
        return try SharePresentationMetadata(
            selection: plan.request.selection,
            safePreview: safePreviewMetadata,
            resources: plan.resourceMetadata,
            provenance: provenance,
            compatibility: compatibility
        )
    }
}

@MainActor
enum ShareArtifactStaticRenderer {
    private struct ValidatedThemeImage {
        let reference: RuntimeThemeImageReference
        let image: Image
    }

    static func render(
        plan: ShareArtifactRenderPlan,
        resourceData: [ThemeResourceID: Data],
        imageReferences: [ThemeResourceID: RuntimeThemeImageReference],
        contentRevision: UInt64
    ) throws -> ShareArtifactStaticOutput {
        let renderedImages = try validateResources(
            plan: plan,
            resourceData: resourceData,
            imageReferences: imageReferences,
            contentRevision: contentRevision
        )
        var pageData: [Data] = []
        pageData.reserveCapacity(plan.pages.count)
        for page in plan.pages {
            let content = ThemeArtifactCanvas(
                plan: plan.composition,
                page: page,
                context: .staticShare,
                image: { resourceID in
                    renderedImages[resourceID]?.image ?? Image(systemName: "photo")
                }
            )
            .environment(\.locale, Locale(identifier: plan.request.localeIdentifier))
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(
                width: CGFloat(ShareArtifactRenderPlan.outputWidth),
                height: CGFloat(ShareArtifactRenderPlan.outputHeight)
            )
            renderer.scale = CGFloat(plan.request.scale)
            renderer.isOpaque = true
            #if os(macOS)
            guard let cgImage = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(
                    using: .png,
                    properties: [:]
                  )
            else { throw ShareArtifactRenderError.renderingFailed }
            #elseif os(iOS)
            guard let png = renderer.uiImage?.pngData() else {
                throw ShareArtifactRenderError.renderingFailed
            }
            #endif
            guard png.count <= Int(ShareSafePreviewMetadata.maximumByteLength) else {
                throw ShareArtifactRenderError.outputTooLarge
            }
            pageData.append(png)
        }
        guard let safePreview = pageData.first else {
            throw ShareArtifactRenderError.renderingFailed
        }
        let digest = SHA256.hash(data: safePreview).map {
            String(format: "%02x", $0)
        }.joined()
        let metadata = try ShareSafePreviewMetadata(
            mediaType: .png,
            byteLength: UInt32(safePreview.count),
            pixelSize: ThemePixelSize(
                width: UInt32(
                    (Double(ShareArtifactRenderPlan.outputWidth) * plan.request.scale).rounded()
                ),
                height: UInt32(
                    (Double(ShareArtifactRenderPlan.outputHeight) * plan.request.scale).rounded()
                )
            ),
            sha256: ThemeSHA256Digest(rawValue: digest)!
        )
        return ShareArtifactStaticOutput(
            pagePNGData: pageData,
            safePreviewMetadata: metadata,
            rendererOutputID: ThemeCaptureIdentifier.staticShareRendererOutput(
                codexID: plan.request.selection.codexID,
                relicID: plan.request.selection.relicID,
                sealID: plan.request.selection.sealID,
                colorMode: plan.request.colorMode
            )
        )
    }

    private static func validateResources(
        plan: ShareArtifactRenderPlan,
        resourceData: [ThemeResourceID: Data],
        imageReferences: [ThemeResourceID: RuntimeThemeImageReference],
        contentRevision: UInt64
    ) throws -> [ThemeResourceID: ValidatedThemeImage] {
        let expected = Dictionary(uniqueKeysWithValues: plan.resourceMetadata.map {
            ($0.resourceID, $0)
        })
        let renderedResourceIDs = [
            plan.relicResourceID,
            plan.sealResourceID,
            plan.frameResourceID,
            plan.backgroundResourceID,
        ].compactMap { $0 }
        guard renderedResourceIDs.allSatisfy({ expected[$0] != nil }) else {
            throw ShareArtifactRenderError.renderingFailed
        }
        let renderedResourceIDSet = Set(renderedResourceIDs)
        var renderedImages: [ThemeResourceID: ValidatedThemeImage] = [:]
        for (resourceID, metadata) in expected {
            switch metadata.mediaType {
            case .png, .heif, .pdf:
                guard let image = imageReferences[resourceID] else {
                    throw ShareArtifactRenderError.missingResource(resourceID)
                }
                let pixelSizeMatches = metadata.mediaType == .pdf
                    ? metadata.pixelSize == nil
                    : image.integrity.pixelSize == metadata.pixelSize
                guard image.codexID == plan.request.selection.codexID,
                      image.resourceID == metadata.resourceID,
                      image.role == metadata.role,
                      image.mediaType == metadata.mediaType,
                      image.integrity.byteLength == metadata.byteLength,
                      pixelSizeMatches,
                      image.integrity.sha256 == metadata.sha256
                else {
                    throw ShareArtifactRenderError.invalidResource(resourceID)
                }
                guard image.contentRevision == contentRevision else {
                    throw ShareArtifactRenderError.unavailableSelection
                }
                guard let renderedImage = image.image else {
                    throw ShareArtifactRenderError.renderingFailed
                }
                if renderedResourceIDSet.contains(resourceID) {
                    renderedImages[resourceID] = ValidatedThemeImage(
                        reference: image,
                        image: renderedImage
                    )
                }
            case .ttf, .otf:
                guard let data = resourceData[resourceID] else {
                    throw ShareArtifactRenderError.missingResource(resourceID)
                }
                let digest = SHA256.hash(data: data).map {
                    String(format: "%02x", $0)
                }.joined()
                guard !data.isEmpty,
                      UInt64(data.count) == metadata.byteLength,
                      digest == metadata.sha256.rawValue
                else {
                    throw ShareArtifactRenderError.invalidResource(resourceID)
                }
            case .json, .mp4, .quickTime, .m4a, .caf, .wav:
                throw ShareArtifactRenderError.invalidResource(resourceID)
            }
        }
        guard renderedImages.count == renderedResourceIDSet.count else {
            throw ShareArtifactRenderError.renderingFailed
        }
        return renderedImages
    }
}

enum ThemeArtifactCanvasContext: Equatable, Sendable {
    case interactivePreview
    case receivedPreview
    case staticShare

    var showsSeal: Bool {
        switch self {
        case .interactivePreview, .receivedPreview, .staticShare:
            true
        }
    }

    var showsAttribution: Bool {
        self == .staticShare
    }

    func glyphRegion(
        for layout: ThemeShareLayoutPreset
    ) -> ThemeArtifactGlyphRegion {
        switch self {
        case .interactivePreview, .staticShare:
            return ThemeArtifactGlyphRegion(layout.glyphSafeRegion)
        case .receivedPreview:
            let content = layout.contentSafeRegion
            return ThemeArtifactGlyphRegion(
                x: content.x,
                y: content.y + content.height * 0.68,
                width: content.width,
                height: content.height * 0.22
            )
        }
    }
}

struct ThemeArtifactGlyphRegion: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ region: ThemeNormalizedRegion) {
        self.init(
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height
        )
    }

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// One composition implementation for both interactive and static output.
/// The caller supplies only already-admitted images; all geometry, layering,
/// page text, frame placement, and seal anchoring live here.
@MainActor
struct ThemeArtifactCanvas: View {
    let plan: ThemeArtifactCompositionPlan
    let page: ShareArtifactRenderPage
    let context: ThemeArtifactCanvasContext
    let maximumWidth: CGFloat?
    let sealResourceIDOverride: ThemeResourceID?
    let sealAnchorOverride: ThemeNormalizedPoint?
    let sealScaleOverride: Double?
    let image: (ThemeResourceID) -> Image

    init(
        plan: ThemeArtifactCompositionPlan,
        page: ShareArtifactRenderPage,
        context: ThemeArtifactCanvasContext,
        maximumWidth: CGFloat? = nil,
        sealResourceIDOverride: ThemeResourceID? = nil,
        sealAnchorOverride: ThemeNormalizedPoint? = nil,
        sealScaleOverride: Double? = nil,
        image: @escaping (ThemeResourceID) -> Image
    ) {
        self.plan = plan
        self.page = page
        self.context = context
        self.maximumWidth = maximumWidth
        self.sealResourceIDOverride = sealResourceIDOverride
        self.sealAnchorOverride = sealAnchorOverride
        self.sealScaleOverride = sealScaleOverride
        self.image = image
    }

    var presentedSealResourceID: ThemeResourceID? {
        sealResourceIDOverride ?? plan.sealResourceID
    }

    var presentedSealAnchor: ThemeNormalizedPoint? {
        sealAnchorOverride ?? plan.sealAnchor
    }

    var presentedSealScale: Double {
        sealScaleOverride ?? plan.sealScale
    }

    var body: some View {
        GeometryReader { geometry in
            let glyphRegion = context.glyphRegion(for: plan.layout)
            ZStack {
                color(plan.palette.backgroundPrimary)
                image(plan.backgroundResourceID)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                regionImage(
                    plan.relicResourceID,
                    region: plan.layout.relicBounds,
                    in: geometry.size
                )
                if let frameResourceID = plan.frameResourceID {
                    regionImage(
                        frameResourceID,
                        region: plan.layout.relicBounds,
                        in: geometry.size
                    )
                }

                Text(page.inscription)
                    .font(
                        .custom(
                            plan.fontPostScriptName,
                            size: CGFloat(plan.glyphStyle.pointSize)
                                * typographyScale(in: geometry.size)
                        )
                    )
                    .minimumScaleFactor(CGFloat(plan.layout.minimumGlyphScale))
                    .lineLimit(Int(plan.layout.maximumGlyphLines))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(color(plan.glyphStyle.color))
                    .frame(
                        width: geometry.size.width * CGFloat(glyphRegion.width),
                        height: geometry.size.height * CGFloat(glyphRegion.height)
                    )
                    .clipped()
                    .position(point(for: glyphRegion, in: geometry.size))
                    .accessibilityHidden(true)
                    .onAppear {
                        reportGlyphTextResourceUse()
                    }

                if context.showsSeal,
                   let sealResourceID = presentedSealResourceID,
                   let anchor = presentedSealAnchor {
                    image(sealResourceID)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: geometry.size.width * CGFloat(presentedSealScale),
                            height: geometry.size.height * CGFloat(presentedSealScale)
                        )
                        .position(
                            x: geometry.size.width * CGFloat(anchor.x),
                            y: geometry.size.height * CGFloat(anchor.y)
                        )
                }

                if context.showsAttribution {
                    Text(page.count == 1 ? "Rune Scribe" : "Rune Scribe · \(page.index + 1)/\(page.count)")
                        .font(
                            .system(
                                size: 18 * typographyScale(in: geometry.size),
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .foregroundStyle(color(plan.palette.textSecondary))
                        .frame(
                            width: geometry.size.width
                                * CGFloat(plan.layout.attributionRegion.width),
                            height: geometry.size.height
                                * CGFloat(plan.layout.attributionRegion.height)
                        )
                        .position(point(for: plan.layout.attributionRegion, in: geometry.size))
                        .accessibilityHidden(true)

                    if let provenanceLabel = plan.provenanceLabel,
                       let region = plan.layout.provenanceRegion {
                        Text(provenanceLabel)
                            .font(
                                .system(
                                    size: 13 * typographyScale(in: geometry.size),
                                    weight: .medium,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(color(plan.palette.textSecondary))
                            .lineLimit(1)
                            .frame(
                                width: geometry.size.width * CGFloat(region.width),
                                height: geometry.size.height * CGFloat(region.height)
                            )
                            .position(point(for: region, in: geometry.size))
                            .accessibilityHidden(true)
                    }
                }
            }
            // The canvas is a deterministic visual artifact, not flowing UI text.
            // Its accessible label/value below remain available at every user size.
            .dynamicTypeSize(.medium)
            .grayscale(plan.colorMode == .monochrome ? 1 : 0)
        }
        .modifier(ThemeArtifactCanvasSizing(context: context))
        .modifier(ThemeArtifactCanvasMaximumWidth(maximumWidth: maximumWidth))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(plan.accessibilityLabel))
        .accessibilityValue(Text(page.inscription))
        .accessibilityHint(Text("The sender-rendered inscription remains available when its Codex is not."))
    }

    @discardableResult
    func reportGlyphTextResourceUse() -> Bool {
        guard let fontResourceID = plan.fontResourceID else { return false }
        return RuntimeThemeSemanticResourceUseObservation.report(fontResourceID)
    }

    private func regionImage(
        _ resourceID: ThemeResourceID,
        region: ThemeNormalizedRegion,
        in size: CGSize
    ) -> some View {
        image(resourceID)
            .resizable()
            .scaledToFit()
            .frame(
                width: size.width * CGFloat(region.width),
                height: size.height * CGFloat(region.height)
            )
            .position(point(for: region, in: size))
    }

    private func point(for region: ThemeNormalizedRegion, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * CGFloat(region.x + region.width / 2),
            y: size.height * CGFloat(region.y + region.height / 2)
        )
    }

    private func point(for region: ThemeArtifactGlyphRegion, in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width * CGFloat(region.x + region.width / 2),
            y: size.height * CGFloat(region.y + region.height / 2)
        )
    }

    private func typographyScale(in size: CGSize) -> CGFloat {
        min(
            size.width / CGFloat(ShareArtifactRenderPlan.outputWidth),
            size.height / CGFloat(ShareArtifactRenderPlan.outputHeight)
        )
    }

    private func color(_ semantic: ThemeSemanticColor) -> Color {
        let digits = String(semantic.rawValue.dropFirst())
        let value = UInt64(digits, radix: 16)!
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        if digits.count == 8 {
            red = (value >> 24) & 0xff
            green = (value >> 16) & 0xff
            blue = (value >> 8) & 0xff
            alpha = value & 0xff
        } else {
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
            alpha = 0xff
        }
        return Color(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

private struct ThemeArtifactCanvasSizing: ViewModifier {
    let context: ThemeArtifactCanvasContext

    @ViewBuilder
    func body(content: Content) -> some View {
        switch context {
        case .interactivePreview, .receivedPreview:
            content.aspectRatio(
                CGFloat(ShareArtifactRenderPlan.outputWidth)
                    / CGFloat(ShareArtifactRenderPlan.outputHeight),
                contentMode: .fit
            )
        case .staticShare:
            content.frame(
                width: CGFloat(ShareArtifactRenderPlan.outputWidth),
                height: CGFloat(ShareArtifactRenderPlan.outputHeight)
            )
        }
    }
}

private struct ThemeArtifactCanvasMaximumWidth: ViewModifier {
    let maximumWidth: CGFloat?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let maximumWidth {
            content.frame(
                width: maximumWidth,
                height: maximumWidth
                    * CGFloat(ShareArtifactRenderPlan.outputHeight)
                    / CGFloat(ShareArtifactRenderPlan.outputWidth)
            )
        } else {
            content
        }
    }
}
