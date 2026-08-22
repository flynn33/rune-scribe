import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import RuneScribeContracts
import RuneScribeNorseThemeModule
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class ShareArtifactRendererTests: XCTestCase {
    func testBuilderShowsLockedContentButCannotSelectIt() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let items = ShareBuilderPolicy.seals(
            in: descriptor,
            ownedArtifactIDs: [],
            providerAvailable: true
        )
        let locked = try XCTUnwrap(items.first(where: { $0.access == .locked }))
        XCTAssertTrue(items.contains(where: { $0.access == .owned }))

        XCTAssertThrowsError(try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: true,
            providerAvailable: true,
            ownedArtifactIDs: [],
            relicID: nil,
            sealID: locked.id,
            frameID: nil
        )) { error in
            XCTAssertEqual(
                error as? ShareArtifactRenderError,
                .lockedSelection(locked.id)
            )
        }
    }

    func testRenderPlanIsDeterministicPaginatedAndUsesApprovedAnchor() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let includedSeal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let selection = try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: true,
            providerAvailable: true,
            ownedArtifactIDs: [],
            relicID: nil,
            sealID: includedSeal.metadata.id,
            frameID: nil
        )
        let request = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: String(repeating: "A", count: 300),
            operationID: RuntimeOperationID(rawValue: "operation.static-preview.1"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            colorMode: .highContrast,
            reduceMotion: true,
            accessibilityLabel: "A Norse artifact containing an encoded inscription."
        )

        let first = try ShareArtifactRenderPolicy.plan(
            request: request,
            descriptor: descriptor,
            preferredSealAnchor: .lowerRight
        )
        let second = try ShareArtifactRenderPolicy.plan(
            request: request,
            descriptor: descriptor,
            preferredSealAnchor: .lowerRight
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.pages.count, 2)
        XCTAssertEqual(first.relicResourceID, descriptor.codex.relics.first {
            $0.metadata.id == selection.relicID
        }?.highContrastResourceID)
        XCTAssertEqual(
            first.backgroundResourceID,
            descriptor.codex.background.highContrastResourceID
        )
        XCTAssertNotNil(first.sealAnchor)
        XCTAssertEqual(
            first.pages.map(\.inscription).joined().replacingOccurrences(of: "\n", with: ""),
            request.inscription
        )
    }

    func testRenderPlanCoversShortMediumLongPaginatedAndOverflowInscriptions() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let selection = try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: true,
            providerAvailable: true,
            ownedArtifactIDs: [],
            relicID: nil,
            sealID: nil,
            frameID: nil
        )
        let relic = try XCTUnwrap(descriptor.codex.relics.first(where: {
            $0.metadata.id == selection.relicID
        }))
        let layout = try XCTUnwrap(relic.layouts.first(where: {
            $0.id == relic.defaultLayoutID
        }))
        let pageCapacity = Int(layout.maximumGlyphLines) * 24
        XCTAssertGreaterThan(pageCapacity, 1)

        let cases = [
            ("short", 1, 1),
            ("medium", max(2, pageCapacity / 2), 1),
            ("long", pageCapacity, 1),
            ("paginated", pageCapacity + 1, 2),
        ]
        for (label, characterCount, expectedPageCount) in cases {
            let inscription = String(repeating: "ᚠ", count: characterCount)
            let request = try ShareArtifactRenderRequest(
                selection: selection,
                inscription: inscription,
                operationID: RuntimeOperationID(rawValue: "operation.inscription.\(label)"),
                capturedAt: Date(timeIntervalSince1970: 1_800_000_100),
                reduceMotion: true,
                accessibilityLabel: "A \(label) encoded inscription."
            )
            let plan = try ShareArtifactRenderPolicy.plan(
                request: request,
                descriptor: descriptor
            )

            XCTAssertEqual(plan.pages.count, expectedPageCount, label)
            XCTAssertEqual(
                plan.pages.map(\.inscription).joined().replacingOccurrences(of: "\n", with: ""),
                inscription,
                label
            )
            XCTAssertTrue(plan.pages.allSatisfy { page in
                page.inscription.split(separator: "\n").allSatisfy { $0.count <= 24 }
            }, label)
            XCTAssertTrue(plan.pages.allSatisfy { $0.count == plan.pages.count }, label)
        }

        let overflowCount = pageCapacity * ShareArtifactRenderPolicy.maximumPageCount + 1
        XCTAssertLessThanOrEqual(
            overflowCount,
            ShareArtifactRenderRequest.maximumInscriptionCharacters
        )
        let overflow = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: String(repeating: "ᚠ", count: overflowCount),
            operationID: RuntimeOperationID(rawValue: "operation.inscription.overflow"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_101),
            accessibilityLabel: "An overflowing encoded inscription."
        )
        XCTAssertThrowsError(try ShareArtifactRenderPolicy.plan(
            request: overflow,
            descriptor: descriptor
        )) { error in
            XCTAssertEqual(error as? ShareArtifactRenderError, .inscriptionTooLong)
        }

        XCTAssertThrowsError(try ShareArtifactRenderRequest(
            selection: selection,
            inscription: String(
                repeating: "ᚠ",
                count: ShareArtifactRenderRequest.maximumInscriptionCharacters + 1
            ),
            operationID: RuntimeOperationID(rawValue: "operation.inscription.hard-limit"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_102),
            accessibilityLabel: "An invalid encoded inscription."
        )) { error in
            XCTAssertEqual(error as? ShareArtifactRenderError, .invalidRequest)
        }
    }

    func testStaticRendererProducesBoundedFourByThreePreview() throws {
        let data = try makePNG(width: 4, height: 3)
        let ids = [
            ThemeResourceID(rawValue: "resource.test.background")!,
            ThemeResourceID(rawValue: "resource.test.relic")!,
            ThemeResourceID(rawValue: "resource.test.seal")!,
        ]
        let digest = ThemeSHA256Digest(rawValue: SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined())!
        let metadata = try ids.enumerated().map { index, id in
            try SharePresentationResourceMetadata(
                resourceID: id,
                role: ThemeResourceRoleID(rawValue: "test.image.\(index)")!,
                mediaType: .png,
                byteLength: UInt64(data.count),
                pixelSize: ThemePixelSize(width: 4, height: 3),
                sha256: digest
            )
        }
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let relic = try XCTUnwrap(descriptor.codex.relics.first)
        let layout = try XCTUnwrap(relic.layouts.first)
        let request = try ShareArtifactRenderRequest(
            selection: SharePresentationSelection(
                codexID: descriptor.codex.id,
                scriptID: descriptor.codex.primaryScriptID,
                relicID: relic.metadata.id,
                sealID: descriptor.codex.seals.first?.metadata.id
            ),
            inscription: "ABCD",
            operationID: RuntimeOperationID(rawValue: "operation.static-preview.2"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_001),
            colorMode: .monochrome,
            reduceMotion: true,
            accessibilityLabel: "A deterministic artifact preview."
        )
        let plan = ShareArtifactRenderPlan(
            request: request,
            palette: descriptor.codex.palette,
            layout: layout,
            pages: [ShareArtifactRenderPage(index: 0, count: 1, inscription: "ABCD")],
            relicResourceID: ids[1],
            sealResourceID: ids[2],
            frameResourceID: nil,
            backgroundResourceID: ids[0],
            sealAnchor: layout.sealAnchors.first?.point,
            sealScale: 0.18,
            fontPostScriptName: "Helvetica",
            resourceMetadata: metadata
        )

        let output = try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: Dictionary(uniqueKeysWithValues: ids.map { ($0, data) })
        )

        XCTAssertEqual(output.pagePNGData.count, 1)
        XCTAssertLessThanOrEqual(
            output.pagePNGData[0].count,
            Int(ShareSafePreviewMetadata.maximumByteLength)
        )
        XCTAssertEqual(output.safePreviewMetadata.mediaType, .png)
        XCTAssertEqual(
            Double(output.safePreviewMetadata.pixelSize.width)
                / Double(output.safePreviewMetadata.pixelSize.height),
            4.0 / 3.0,
            accuracy: 0.000_001
        )
        let presentation = try output.presentationMetadata(for: plan)
        XCTAssertEqual(presentation.selection, request.selection)
        XCTAssertEqual(presentation.resources, metadata)
        XCTAssertTrue(presentation.compatibility.contains(.safePreviewPresent))
        XCTAssertTrue(presentation.compatibility.contains(.monochromePreviewAvailable))

        let variants: [(Double, ShareArtifactColorMode)] = [
            (1, .standard),
            (2, .highContrast),
            (3, .monochrome),
        ]
        for (scale, colorMode) in variants {
            let variantRequest = try ShareArtifactRenderRequest(
                selection: request.selection,
                inscription: request.inscription,
                operationID: RuntimeOperationID(
                    rawValue: "operation.static-preview.scale-\(Int(scale))"
                ),
                capturedAt: request.capturedAt,
                scale: scale,
                colorMode: colorMode,
                reduceMotion: true,
                accessibilityLabel: request.accessibilityLabel
            )
            let variantPlan = ShareArtifactRenderPlan(
                request: variantRequest,
                palette: plan.palette,
                layout: plan.layout,
                pages: plan.pages,
                relicResourceID: plan.relicResourceID,
                sealResourceID: plan.sealResourceID,
                frameResourceID: plan.frameResourceID,
                backgroundResourceID: plan.backgroundResourceID,
                sealAnchor: plan.sealAnchor,
                sealScale: plan.sealScale,
                fontPostScriptName: plan.fontPostScriptName,
                resourceMetadata: plan.resourceMetadata
            )
            let variant = try ShareArtifactStaticRenderer.render(
                plan: variantPlan,
                resourceData: Dictionary(uniqueKeysWithValues: ids.map { ($0, data) })
            )
            XCTAssertEqual(
                variant.safePreviewMetadata.pixelSize.width,
                UInt32(Double(ShareArtifactRenderPlan.outputWidth) * scale)
            )
            XCTAssertEqual(
                variant.safePreviewMetadata.pixelSize.height,
                UInt32(Double(ShareArtifactRenderPlan.outputHeight) * scale)
            )
            let variantDigest = SHA256.hash(data: variant.pagePNGData[0]).map {
                String(format: "%02x", $0)
            }.joined()
            XCTAssertEqual(variant.safePreviewMetadata.sha256.rawValue, variantDigest)
            let variantPresentation = try variant.presentationMetadata(for: variantPlan)
            XCTAssertEqual(
                variantPresentation.compatibility.contains(.highContrastPreviewAvailable),
                colorMode == .highContrast
            )
            XCTAssertEqual(
                variantPresentation.compatibility.contains(.monochromePreviewAvailable),
                colorMode == .monochrome
            )
        }
    }

    func testReceivedSummaryExplainsFallbackProvenanceAndEncounter() throws {
        let selection = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.gloamthorn")!,
            scriptID: ScriptID(rawValue: "script.gloamthorn")!,
            relicID: ArtifactID(rawValue: "relic.gloamthorn.nightthorn-tablet")!
        )
        let presentation = try ReceivedSharePresentation(
            requestedSelection: selection,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: .corrupt,
            renderMode: .norseInteractiveFallback,
            safePreviewStatus: .valid,
            provenanceStatus: .invalid,
            encounterRecordingStatus: .recorded
        )

        let model = ReceivedPresentationViewModel(presentation)

        XCTAssertTrue(model.renderStatusTitle.contains("Norse"))
        XCTAssertTrue(model.renderStatusDetail.contains("did not pass validation"))
        XCTAssertTrue(model.provenanceTitle.contains("invalid"))
        XCTAssertTrue(model.provenanceDetail.contains("remains readable"))
        XCTAssertTrue(model.safePreviewDetail.contains("size, media, and hash"))
        XCTAssertTrue(model.encounterDetail.contains("does not grant ownership"))

        let preview = Data([0x01, 0x02, 0x03])
        let received = try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            plaintext: "Still readable",
            senderName: "Sender",
            cipherID: CipherID(rawValue: UUID()),
            cipherName: "Cipher",
            presentation: presentation,
            safePreviewData: preview
        )
        let pending = PendingMessageViewState(received)
        XCTAssertEqual(pending.presentation, presentation)
        XCTAssertEqual(pending.safePreviewData, preview)
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

}
