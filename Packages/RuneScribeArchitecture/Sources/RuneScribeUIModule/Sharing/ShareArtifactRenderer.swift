import CryptoKit
import Foundation
import ImageIO
import RuneScribeContracts
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
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
        guard codexOwned || descriptor.codex.id == RuneScribeCodexIDs.norse,
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
        provenanceLabel: String? = nil
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
    }
}

struct ShareArtifactRenderPage: Equatable, Hashable, Sendable {
    let index: Int
    let count: Int
    let inscription: String
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
    let resourceMetadata: [SharePresentationResourceMetadata]
}

enum ShareArtifactRenderPolicy {
    static let maximumPageCount = 16
    private static let glyphsPerLine = 24

    static func plan(
        request: ShareArtifactRenderRequest,
        descriptor: ThemeDescriptor,
        preferredSealAnchor: ThemeSealAnchorCategory? = nil
    ) throws -> ShareArtifactRenderPlan {
        guard descriptor.codex.id == request.selection.codexID,
              let script = descriptor.codex.scripts.first(where: {
                  $0.id == request.selection.scriptID
              }),
              let relic = descriptor.codex.relics.first(where: {
                  $0.metadata.id == request.selection.relicID
              }),
              let layout = relic.layouts.first(where: {
                  $0.id == relic.defaultLayoutID
              })
        else { throw ShareArtifactRenderError.unknownSelection }

        let seal = request.selection.sealID.flatMap { id in
            descriptor.codex.seals.first(where: { $0.metadata.id == id })
        }
        if request.selection.sealID != nil, seal == nil {
            throw ShareArtifactRenderError.unknownSelection
        }
        let frame = request.selection.frameID.flatMap { id in
            descriptor.codex.frames.first(where: { $0.metadata.id == id })
        }
        if request.selection.frameID != nil, frame == nil {
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

        let pages = try paginate(
            request.inscription,
            maximumLines: Int(layout.maximumGlyphLines)
        )
        let relicResourceID: ThemeResourceID = switch request.colorMode {
        case .highContrast: relic.highContrastResourceID
        case .standard, .monochrome: relic.staticFallbackResourceID
        }
        let sealResourceID: ThemeResourceID? = seal.map {
            request.colorMode == .standard
                ? $0.vectorResourceID
                : $0.monochromeFallbackResourceID
        }
        let frameResourceID = frame?.staticFallbackResourceID
        let backgroundResourceID: ThemeResourceID = if request.colorMode == .highContrast {
            descriptor.codex.background.highContrastResourceID
        } else if request.reduceMotion {
            descriptor.codex.background.reduceMotionResourceID
        } else {
            descriptor.codex.background.staticBaseResourceID
        }
        var seenResourceIDs = Set<ThemeResourceID>()
        let resourceIDs = [
            relicResourceID,
            sealResourceID,
            frameResourceID,
            backgroundResourceID,
            script.fontResourceID,
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
            fontPostScriptName: script.fontPostScriptName?.rawValue
                ?? "NotoSansRunic-Regular",
            resourceMetadata: metadata
        )
    }

    private static func paginate(
        _ inscription: String,
        maximumLines: Int
    ) throws -> [ShareArtifactRenderPage] {
        let characters = Array(inscription)
        let pageCapacity = maximumLines * glyphsPerLine
        guard pageCapacity > 0 else { throw ShareArtifactRenderError.invalidRequest }
        let pageCount = max(1, Int(ceil(Double(characters.count) / Double(pageCapacity))))
        guard pageCount <= maximumPageCount else {
            throw ShareArtifactRenderError.inscriptionTooLong
        }
        return (0..<pageCount).map { pageIndex in
            let pageStart = pageIndex * pageCapacity
            let pageEnd = min(characters.count, pageStart + pageCapacity)
            let pageCharacters = Array(characters[pageStart..<pageEnd])
            let lines = stride(from: 0, to: pageCharacters.count, by: glyphsPerLine).map {
                String(pageCharacters[$0..<min(pageCharacters.count, $0 + glyphsPerLine)])
            }
            return ShareArtifactRenderPage(
                index: pageIndex,
                count: pageCount,
                inscription: lines.joined(separator: "\n")
            )
        }
    }
}

struct ShareArtifactStaticOutput: Equatable, Sendable {
    let pagePNGData: [Data]
    let safePreviewMetadata: ShareSafePreviewMetadata

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
    static func render(
        plan: ShareArtifactRenderPlan,
        resourceData: [ThemeResourceID: Data]
    ) throws -> ShareArtifactStaticOutput {
        try validateResources(plan: plan, resourceData: resourceData)
        var pageData: [Data] = []
        pageData.reserveCapacity(plan.pages.count)
        for page in plan.pages {
            let content = ShareArtifactCanvas(
                plan: plan,
                page: page,
                resourceData: resourceData
            )
            .environment(\.locale, Locale(identifier: plan.request.localeIdentifier))
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(
                width: CGFloat(ShareArtifactRenderPlan.outputWidth),
                height: CGFloat(ShareArtifactRenderPlan.outputHeight)
            )
            renderer.scale = CGFloat(plan.request.scale)
            renderer.isOpaque = true
            guard let cgImage = renderer.cgImage,
                  let png = pngData(from: cgImage)
            else { throw ShareArtifactRenderError.renderingFailed }
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
            safePreviewMetadata: metadata
        )
    }

    private static func validateResources(
        plan: ShareArtifactRenderPlan,
        resourceData: [ThemeResourceID: Data]
    ) throws {
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
        for (resourceID, metadata) in expected {
            guard let data = resourceData[resourceID] else {
                throw ShareArtifactRenderError.missingResource(resourceID)
            }
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            guard UInt64(data.count) == metadata.byteLength,
                  digest == metadata.sha256.rawValue,
                  validateResource(data, metadata: metadata)
            else { throw ShareArtifactRenderError.invalidResource(resourceID) }
        }
    }

    private static func validateResource(
        _ data: Data,
        metadata: SharePresentationResourceMetadata
    ) -> Bool {
        switch metadata.mediaType {
        case .png, .heif:
            guard let pixelSize = metadata.pixelSize,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width == Int(pixelSize.width),
                  height == Int(pixelSize.height)
            else { return false }
            #if os(macOS)
            return NSImage(data: data) != nil
            #elseif os(iOS)
            return UIImage(data: data) != nil
            #endif
        case .pdf:
            #if os(macOS)
            return NSImage(data: data) != nil
            #elseif os(iOS)
            return UIImage(data: data) != nil
            #endif
        case .ttf, .otf:
            // Theme activation owns font parsing and registration. The renderer
            // binds the already-admitted bytes to their declared length/hash.
            return !data.isEmpty
        case .json, .mp4, .quickTime, .m4a, .caf, .wav:
            return false
        }
    }

    private static func pngData(from image: CGImage) -> Data? {
        #if os(macOS)
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        #elseif os(iOS)
        UIImage(cgImage: image).pngData()
        #endif
    }
}

@MainActor
private struct ShareArtifactCanvas: View {
    let plan: ShareArtifactRenderPlan
    let page: ShareArtifactRenderPage
    let resourceData: [ThemeResourceID: Data]

    var body: some View {
        GeometryReader { geometry in
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
                    .font(.custom(plan.fontPostScriptName, size: 54))
                    .minimumScaleFactor(CGFloat(plan.layout.minimumGlyphScale))
                    .lineLimit(Int(plan.layout.maximumGlyphLines))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(color(plan.palette.textPrimary))
                    .frame(
                        width: geometry.size.width * CGFloat(plan.layout.glyphSafeRegion.width),
                        height: geometry.size.height * CGFloat(plan.layout.glyphSafeRegion.height)
                    )
                    .position(point(for: plan.layout.glyphSafeRegion, in: geometry.size))

                if let sealResourceID = plan.sealResourceID,
                   let anchor = plan.sealAnchor {
                    image(sealResourceID)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: geometry.size.width * CGFloat(plan.sealScale),
                            height: geometry.size.height * CGFloat(plan.sealScale)
                        )
                        .position(
                            x: geometry.size.width * CGFloat(anchor.x),
                            y: geometry.size.height * CGFloat(anchor.y)
                        )
                }

                Text(page.count == 1 ? "Rune Scribe" : "Rune Scribe · \(page.index + 1)/\(page.count)")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(color(plan.palette.textSecondary))
                    .frame(
                        width: geometry.size.width
                            * CGFloat(plan.layout.attributionRegion.width),
                        height: geometry.size.height
                            * CGFloat(plan.layout.attributionRegion.height)
                    )
                    .position(point(for: plan.layout.attributionRegion, in: geometry.size))

                if let provenanceLabel = plan.request.provenanceLabel,
                   let region = plan.layout.provenanceRegion {
                    Text(provenanceLabel)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(color(plan.palette.textSecondary))
                        .lineLimit(1)
                        .frame(
                            width: geometry.size.width * CGFloat(region.width),
                            height: geometry.size.height * CGFloat(region.height)
                        )
                        .position(point(for: region, in: geometry.size))
                }
            }
            .grayscale(plan.request.colorMode == .monochrome ? 1 : 0)
        }
        .frame(
            width: CGFloat(ShareArtifactRenderPlan.outputWidth),
            height: CGFloat(ShareArtifactRenderPlan.outputHeight)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(plan.request.accessibilityLabel))
        .accessibilityHint(Text("The sender-rendered inscription remains available when its Codex is not."))
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

    private func image(_ resourceID: ThemeResourceID) -> Image {
        let data = resourceData[resourceID]!
        #if os(macOS)
        return Image(nsImage: NSImage(data: data)!)
        #elseif os(iOS)
        return Image(uiImage: UIImage(data: data)!)
        #endif
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
