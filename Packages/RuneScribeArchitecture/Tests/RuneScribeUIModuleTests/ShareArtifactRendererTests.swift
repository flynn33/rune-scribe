import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import RuneScribeContracts
import RuneScribeNorseThemeModule
@testable import RuneScribeUIRuntime
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

        let interactive = try ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: request.inscription,
            descriptor: descriptor,
            colorMode: request.colorMode,
            reduceMotion: request.reduceMotion,
            accessibilityLabel: request.accessibilityLabel,
            preferredSealAnchor: .lowerRight
        )
        XCTAssertEqual(first.composition, interactive)
        XCTAssertEqual(
            interactive.sealResourceID,
            includedSeal.monochromeFallbackResourceID
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
            (
                "maximum-paginated",
                pageCapacity * ShareArtifactRenderPolicy.maximumPageCount,
                ShareArtifactRenderPolicy.maximumPageCount
            ),
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

    func testRegisteredExternalFontOverrideIsSharedAndNotDeclaredAsThemeFontData() throws {
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
        let override = try XCTUnwrap(
            ThemeFontPostScriptName(rawValue: "ImportedRunic-Regular")
        )
        let request = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: "ABCD",
            operationID: RuntimeOperationID(rawValue: "operation.imported-font"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_103),
            accessibilityLabel: "An imported-font artifact preview.",
            fontPostScriptNameOverride: override
        )

        let staticPlan = try ShareArtifactRenderPolicy.plan(
            request: request,
            descriptor: descriptor
        )
        let interactivePlan = try ThemeArtifactCompositionPolicy.interactivePlan(
            selection: selection,
            inscription: request.inscription,
            descriptor: descriptor,
            colorMode: request.colorMode,
            reduceMotion: request.reduceMotion,
            accessibilityLabel: request.accessibilityLabel,
            fontPostScriptNameOverride: override
        )

        XCTAssertEqual(staticPlan.composition, interactivePlan)
        XCTAssertEqual(staticPlan.fontPostScriptName, override.rawValue)
        XCTAssertTrue(staticPlan.composition.usesExternalFontOverride)
        let themeFontID = try XCTUnwrap(descriptor.codex.scripts.first(where: {
            $0.id == selection.scriptID
        })?.fontResourceID)
        XCTAssertFalse(staticPlan.resourceMetadata.contains(where: {
            $0.resourceID == themeFontID
        }))
    }

    func testSharedPolicyUsesOptionalFrameCompatibilityReduceMotionAndMonochrome() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let frame = try XCTUnwrap(descriptor.codex.frames.first)
        let seal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let selection = try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: true,
            providerAvailable: true,
            ownedArtifactIDs: [frame.metadata.id],
            relicID: descriptor.codex.defaultRelicID,
            sealID: seal.metadata.id,
            frameID: frame.metadata.id
        )
        let reduceMotionRequest = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: "ABCD",
            operationID: RuntimeOperationID(rawValue: "operation.frame.reduce-motion"),
            capturedAt: Date(timeIntervalSince1970: 1_800_000_104),
            reduceMotion: true,
            accessibilityLabel: "An encoded artifact with an optional frame."
        )
        let reduceMotionPlan = try ShareArtifactRenderPolicy.plan(
            request: reduceMotionRequest,
            descriptor: descriptor
        )
        XCTAssertEqual(reduceMotionPlan.frameResourceID, frame.staticFallbackResourceID)
        XCTAssertEqual(
            reduceMotionPlan.backgroundResourceID,
            descriptor.codex.background.reduceMotionResourceID
        )

        let monochromeRequest = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: reduceMotionRequest.inscription,
            operationID: RuntimeOperationID(rawValue: "operation.frame.monochrome"),
            capturedAt: reduceMotionRequest.capturedAt,
            colorMode: .monochrome,
            accessibilityLabel: reduceMotionRequest.accessibilityLabel
        )
        let monochromePlan = try ShareArtifactRenderPolicy.plan(
            request: monochromeRequest,
            descriptor: descriptor
        )
        XCTAssertEqual(monochromePlan.sealResourceID, seal.monochromeFallbackResourceID)
        XCTAssertEqual(monochromePlan.frameResourceID, frame.staticFallbackResourceID)

        let incompatible = try descriptorByRestrictingFirstFrame(
            descriptor,
            to: descriptor.codex.relics[1].metadata.id
        )
        XCTAssertThrowsError(try ShareBuilderPolicy.selection(
            descriptor: incompatible,
            codexOwned: true,
            providerAvailable: true,
            ownedArtifactIDs: [frame.metadata.id],
            relicID: incompatible.codex.defaultRelicID,
            sealID: nil,
            frameID: frame.metadata.id
        )) { error in
            XCTAssertEqual(error as? ShareArtifactRenderError, .incompatibleFrame)
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

        let contentRevision: UInt64 = 1
        let imageReferences = try makeRuntimeImageReferences(
            plan: plan,
            resourceData: Dictionary(uniqueKeysWithValues: ids.map { ($0, data) }),
            contentRevision: contentRevision
        )
        let output = try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: [:],
            imageReferences: imageReferences,
            contentRevision: contentRevision
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

        if let qualificationPath = ProcessInfo.processInfo.environment[
            "RUNE_SCRIBE_PREVIEW_QUALIFICATION_OUTPUT"
        ] {
            let qualification: [String: Any] = [
                "schemaVersion": "1.0",
                "testIdentifier": "RuneScribeUIModuleTests.ShareArtifactRendererTests/"
                    + "testStaticRendererProducesBoundedFourByThreePreview",
                "previewBytes": output.pagePNGData[0].count,
                "previewWidthPixels": Int(output.safePreviewMetadata.pixelSize.width),
                "previewHeightPixels": Int(output.safePreviewMetadata.pixelSize.height),
            ]
            let encodedQualification = try JSONSerialization.data(
                withJSONObject: qualification,
                options: [.sortedKeys]
            )
            try encodedQualification.write(
                to: URL(fileURLWithPath: qualificationPath),
                options: .atomic
            )
        }

        let constrainedCache = RuntimeThemeDecodedResourceCache(
            maximumDecodedByteCount: 4 * 3 * 4
        )
        let constrainedPresentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: constrainedCache
        )
        let constrainedReferences = try makeRuntimeImageReferences(
            plan: plan,
            resourceData: Dictionary(uniqueKeysWithValues: ids.map { ($0, data) }),
            contentRevision: contentRevision,
            presentation: constrainedPresentation
        )
        let creationCountBeforeRender = constrainedCache.decodedImageCreationCount
        _ = try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: [:],
            imageReferences: constrainedReferences,
            contentRevision: contentRevision
        )
        XCTAssertLessThanOrEqual(
            constrainedCache.decodedImageCreationCount - creationCountBeforeRender,
            ids.count,
            "Static rendering must capture each runtime image once for the render scope."
        )

        XCTAssertThrowsError(try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: [:],
            imageReferences: [:],
            contentRevision: contentRevision
        )) { error in
            guard case .missingResource = error as? ShareArtifactRenderError else {
                return XCTFail("Expected missing image reference rejection, got \(error)")
            }
        }
        XCTAssertThrowsError(try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: [:],
            imageReferences: imageReferences,
            contentRevision: contentRevision + 1
        )) { error in
            guard case .unavailableSelection = error as? ShareArtifactRenderError else {
                return XCTFail("Expected stale image reference rejection, got \(error)")
            }
            XCTAssertEqual(
                RuneScribeUISession.outboundSharePresentationFallbackReason(for: error),
                .themeUnavailable
            )
        }

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
                resourceData: [:],
                imageReferences: imageReferences,
                contentRevision: contentRevision
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

    func testOutboundShareValidatesFontResolutionIdentityAndEncodedContent() throws {
        let codexID = CodexID(rawValue: "codex.test.share-font")!
        let resourceID = ThemeResourceID(rawValue: "resource.test.share-font")!
        let data = Data("validated-font-bytes".utf8)
        let digest = ThemeSHA256Digest(rawValue: SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined())!
        let metadata = try SharePresentationResourceMetadata(
            resourceID: resourceID,
            role: ThemeResourceRoles.scriptFont,
            mediaType: .ttf,
            byteLength: UInt64(data.count),
            pixelSize: nil,
            sha256: digest
        )
        let integrity = try ThemeResourceIntegrity(
            sha256: digest,
            byteLength: UInt64(data.count),
            pixelSize: nil
        )
        let resolved = try ResolvedThemeResourceDTO(
            codexID: codexID,
            resourceID: resourceID,
            role: metadata.role,
            mediaType: metadata.mediaType,
            integrity: integrity,
            verifiedSHA256: digest,
            data: data
        )

        XCTAssertNoThrow(try RuneScribeUISession.validateOutboundShareResolvedResource(
            resolved,
            expected: metadata,
            codexID: codexID
        ))

        let wrongRole = try ResolvedThemeResourceDTO(
            codexID: codexID,
            resourceID: resourceID,
            role: ThemeResourceRoles.relicThumbnail,
            mediaType: metadata.mediaType,
            integrity: integrity,
            verifiedSHA256: digest,
            data: data
        )
        XCTAssertThrowsError(try RuneScribeUISession.validateOutboundShareResolvedResource(
            wrongRole,
            expected: metadata,
            codexID: codexID
        )) {
            XCTAssertEqual($0 as? ShareArtifactRenderError, .invalidResource(resourceID))
        }

        var corruptedData = data
        corruptedData[corruptedData.startIndex] ^= 0xff
        let corrupt = try ResolvedThemeResourceDTO(
            codexID: codexID,
            resourceID: resourceID,
            role: metadata.role,
            mediaType: metadata.mediaType,
            integrity: integrity,
            verifiedSHA256: digest,
            data: corruptedData
        )
        XCTAssertThrowsError(try RuneScribeUISession.validateOutboundShareResolvedResource(
            corrupt,
            expected: metadata,
            codexID: codexID
        )) {
            XCTAssertEqual($0 as? ShareArtifactRenderError, .invalidResource(resourceID))
        }
    }

    func testOutboundShareMapsRuntimeReferenceFailuresPrecisely() {
        let resourceID = ThemeResourceID(rawValue: "resource.test.reference-failure")!
        let closed = RuneScribeUISession.outboundShareImageReferenceError(
            for: resourceID,
            underlying: RuntimeThemeImageReferenceError.presentationClosed
        )
        XCTAssertEqual(closed, .unavailableSelection)
        XCTAssertEqual(
            RuneScribeUISession.outboundSharePresentationFallbackReason(for: closed),
            .themeUnavailable
        )

        let capacity = RuneScribeUISession.outboundShareImageReferenceError(
            for: resourceID,
            underlying: RuntimeThemeImageReferenceError.cacheCapacityExceeded
        )
        XCTAssertEqual(capacity, .renderingFailed)
        XCTAssertEqual(
            RuneScribeUISession.outboundSharePresentationFallbackReason(for: capacity),
            .renderingUnavailable
        )

        for failure in [
            RuntimeThemeImageReferenceError.codexIdentityMismatch,
            .resourceIdentityMismatch,
            .roleMismatch,
            .mediaTypeMismatch,
            .integrityMismatch,
            .encodedContentMismatch,
            .pixelDimensionsMismatch,
            .unsupportedImage,
        ] {
            let normalized = RuneScribeUISession.outboundShareImageReferenceError(
                for: resourceID,
                underlying: failure
            )
            XCTAssertEqual(normalized, .invalidResource(resourceID), "\(failure)")
            XCTAssertEqual(
                RuneScribeUISession.outboundSharePresentationFallbackReason(for: normalized),
                .resourceUnavailable,
                "\(failure)"
            )
        }

        let unexpected = RuneScribeUISession.outboundShareImageReferenceError(
            for: resourceID,
            underlying: NSError(domain: "test.unexpected", code: 1)
        )
        XCTAssertEqual(unexpected, .renderingFailed)
        XCTAssertEqual(
            RuneScribeUISession.outboundSharePresentationFallbackReason(for: unexpected),
            .renderingUnavailable
        )
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

    private func makeRuntimeImageReferences(
        plan: ShareArtifactRenderPlan,
        resourceData: [ThemeResourceID: Data],
        contentRevision: UInt64,
        presentation: RuntimeApplicationResourcePresentation? = nil
    ) throws -> [ThemeResourceID: RuntimeThemeImageReference] {
        let presentation = presentation ?? RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        return try Dictionary(uniqueKeysWithValues: plan.resourceMetadata.compactMap {
            metadata in
            guard metadata.mediaType == .png
                    || metadata.mediaType == .heif
                    || metadata.mediaType == .pdf
            else { return nil }
            let data = try XCTUnwrap(resourceData[metadata.resourceID])
            let integrity = try ThemeResourceIntegrity(
                sha256: metadata.sha256,
                byteLength: metadata.byteLength,
                pixelSize: metadata.pixelSize
            )
            let resolved = try ResolvedThemeResourceDTO(
                codexID: plan.request.selection.codexID,
                resourceID: metadata.resourceID,
                role: metadata.role,
                mediaType: metadata.mediaType,
                integrity: integrity,
                verifiedSHA256: metadata.sha256,
                data: data
            )
            let reference = try presentation.makeThemeImageReference(
                resolvedResource: resolved,
                expectedInventory: SharePresentationProviderResourceInventory(
                    metadata: metadata
                ),
                expectedCodexID: plan.request.selection.codexID,
                contentRevision: contentRevision
            )
            return (metadata.resourceID, reference)
        })
    }

    private func descriptorByRestrictingFirstFrame(
        _ descriptor: ThemeDescriptor,
        to relicID: ArtifactID
    ) throws -> ThemeDescriptor {
        let encoded = try JSONEncoder().encode(descriptor)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var codex = try XCTUnwrap(root["codex"] as? [String: Any])
        var frames = try XCTUnwrap(codex["frames"] as? [[String: Any]])
        var frame = try XCTUnwrap(frames.first)
        frame["compatibleRelicIDs"] = [relicID.rawValue]
        frames[0] = frame
        codex["frames"] = frames
        root["codex"] = codex
        return try JSONDecoder().decode(
            ThemeDescriptor.self,
            from: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        )
    }

}
