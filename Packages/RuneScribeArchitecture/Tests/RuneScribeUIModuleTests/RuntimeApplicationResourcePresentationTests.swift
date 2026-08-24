import CoreGraphics
import Foundation
import PDFKit
import RuneScribeContracts
@_spi(RuntimeResourceHost) @testable import RuneScribeRuntimeCore
@testable import RuneScribeUIRuntime
import XCTest

@MainActor
final class RuntimeApplicationResourcePresentationTests: XCTestCase {
    func testThemeBackgroundParametersDecodeEveryBoundedRendererField() throws {
        let parameters = try RuntimeThemeBackgroundParameters.decode(
            from: validThemeBackgroundParameters
        )

        XCTAssertEqual(parameters.rendererID, "fragment-rune-background")
        XCTAssertEqual(parameters.baseGradient.map(\.rawValue), ["#080A1E", "#14082E"])
        XCTAssertEqual(parameters.bandFrequency, 18)
        XCTAssertEqual(parameters.bandThreshold, [0.85, 1])
        XCTAssertEqual(parameters.bandColor.rawValue, "#0F1438")
        XCTAssertEqual(parameters.columnColor.rawValue, "#1A4D99")
        XCTAssertEqual(parameters.highlightColor.rawValue, "#D19914")
        XCTAssertEqual(parameters.shimmerStrength, 0.012)
    }

    func testThemeBackgroundParametersRejectNoncanonicalAndUnsafeValues() throws {
        var lowercase = try themeBackgroundParameterObject()
        var lowercaseParameters = try XCTUnwrap(
            lowercase["rendererParameters"] as? [String: Any]
        )
        lowercaseParameters["bandColor"] = "#0f1438"
        lowercase["rendererParameters"] = lowercaseParameters
        XCTAssertThrowsError(
            try RuntimeThemeBackgroundParameters.decode(
                from: try JSONSerialization.data(withJSONObject: lowercase)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeBackgroundParameterError,
                .invalidField("color")
            )
        }

        var unsafe = try themeBackgroundParameterObject()
        var unsafeParameters = try XCTUnwrap(
            unsafe["rendererParameters"] as? [String: Any]
        )
        unsafeParameters["shimmerStrength"] = 0.75
        unsafe["rendererParameters"] = unsafeParameters
        XCTAssertThrowsError(
            try RuntimeThemeBackgroundParameters.decode(
                from: try JSONSerialization.data(withJSONObject: unsafe)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeBackgroundParameterError,
                .invalidField("shimmerStrength")
            )
        }

        var unexpected = try themeBackgroundParameterObject()
        var unexpectedParameters = try XCTUnwrap(
            unexpected["rendererParameters"] as? [String: Any]
        )
        unexpectedParameters["unapprovedField"] = 1
        unexpected["rendererParameters"] = unexpectedParameters
        XCTAssertThrowsError(
            try RuntimeThemeBackgroundParameters.decode(
                from: try JSONSerialization.data(withJSONObject: unexpected)
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeBackgroundParameterError,
                .malformedDocument
            )
        }
    }

    func testThemeBackgroundInstallFallsBackToStaticWhenParametersFail() throws {
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )

        try presentation.installThemeBackground(
            staticBaseData: validThemeBackgroundImage,
            reduceMotionData: validThemeBackgroundImage,
            highContrastData: validThemeBackgroundImage,
            rendererParametersData: Data("not-json".utf8)
        )

        XCTAssertNotNil(presentation.staticThemeBackgroundImage)
        XCTAssertNotNil(presentation.reduceMotionThemeBackgroundImage)
        XCTAssertNotNil(presentation.highContrastThemeBackgroundImage)
        XCTAssertNil(presentation.themeBackgroundParameters)
        XCTAssertEqual(presentation.themeBackgroundRevision, 1)
    }

    func testFailedRequiredBackgroundReplacementRetainsPreviousConfiguration() throws {
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        try presentation.installThemeBackground(
            staticBaseData: validThemeBackgroundImage,
            reduceMotionData: validThemeBackgroundImage,
            highContrastData: validThemeBackgroundImage,
            rendererParametersData: validThemeBackgroundParameters
        )

        XCTAssertThrowsError(
            try presentation.installThemeBackground(
                staticBaseData: metadataOnlyThemeBackgroundImage,
                reduceMotionData: validThemeBackgroundImage,
                highContrastData: validThemeBackgroundImage,
                rendererParametersData: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeBackgroundInstallationError,
                .invalidStaticBaseData
            )
        }

        XCTAssertEqual(presentation.themeBackgroundRevision, 1)
        XCTAssertEqual(
            presentation.themeBackgroundParameters?.rendererID,
            "fragment-rune-background"
        )
        XCTAssertNotNil(presentation.staticThemeBackgroundImage)
        XCTAssertNotNil(presentation.reduceMotionThemeBackgroundImage)
        XCTAssertNotNil(presentation.highContrastThemeBackgroundImage)
    }

    func testPreparedBackgroundDoesNotPublishUntilCommitted() throws {
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        let prepared = try presentation.prepareThemeBackground(
            staticBaseData: validThemeBackgroundImage,
            reduceMotionData: validThemeBackgroundImage,
            highContrastData: validThemeBackgroundImage,
            rendererParametersData: validThemeBackgroundParameters
        )

        XCTAssertEqual(presentation.themeBackgroundRevision, 0)
        XCTAssertNil(presentation.staticThemeBackgroundImage)
        XCTAssertTrue(prepared.usesRendererParameters)

        try presentation.commitThemeBackground(prepared)
        XCTAssertEqual(presentation.themeBackgroundRevision, 1)
        XCTAssertNotNil(presentation.staticThemeBackgroundImage)
        XCTAssertThrowsError(try presentation.commitThemeBackground(prepared)) {
            XCTAssertEqual(
                $0 as? RuntimeThemeBackgroundInstallationError,
                .preparedBackgroundAlreadyCommitted
            )
        }
    }

    func testThemeBackgroundInstallAndClearReplaceTheWholeConfiguration() throws {
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        try presentation.installThemeBackground(
            staticBaseData: validThemeBackgroundImage,
            reduceMotionData: validThemeBackgroundImage,
            highContrastData: validThemeBackgroundImage,
            rendererParametersData: validThemeBackgroundParameters
        )
        XCTAssertEqual(
            presentation.themeBackgroundParameters?.rendererID,
            "fragment-rune-background"
        )

        presentation.clearThemeBackground()

        XCTAssertNil(presentation.staticThemeBackgroundImage)
        XCTAssertNil(presentation.reduceMotionThemeBackgroundImage)
        XCTAssertNil(presentation.highContrastThemeBackgroundImage)
        XCTAssertNil(presentation.themeBackgroundParameters)
        XCTAssertEqual(presentation.themeBackgroundRevision, 2)
    }

    func testThemeBackgroundInstallRejectsMetadataOnlyRaster() {
        let cache = RuntimeThemeDecodedResourceCache()
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: cache
        )

        XCTAssertThrowsError(
            try presentation.installThemeBackground(
                staticBaseData: metadataOnlyThemeBackgroundImage,
                reduceMotionData: validThemeBackgroundImage,
                highContrastData: validThemeBackgroundImage,
                rendererParametersData: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeBackgroundInstallationError,
                .invalidStaticBaseData
            )
        }
        XCTAssertNil(presentation.staticThemeBackgroundImage)
        XCTAssertEqual(cache.decodedImageValidationCount, 0)
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testThemeBackgroundRendererUniformLayoutMatchesMetalABI() {
        XCTAssertEqual(
            RuntimeThemeBackgroundRendererABI.actualFragmentUniformByteCount,
            RuntimeThemeBackgroundRendererABI.expectedFragmentUniformByteCount
        )
        XCTAssertEqual(
            RuntimeThemeBackgroundRendererABI.expectedFragmentUniformByteCount,
            160
        )
        XCTAssertTrue(RuntimeThemeBackgroundRendererABI.isValid)
    }

    func testDecodedThemeResourcePreflightEnforcesADRLimits() throws {
        XCTAssertEqual(
            RuntimeThemeDecodedResourceCache.maximumEncodedImageByteCount,
            8 * 1_024 * 1_024
        )
        XCTAssertEqual(
            RuntimeThemeDecodedResourceCache.maximumTotalEncodedImageByteCount,
            64 * 1_024 * 1_024
        )
        XCTAssertEqual(
            RuntimeThemeDecodedResourceCache.maximumPixelDimension,
            4_096
        )
        XCTAssertEqual(
            RuntimeThemeDecodedResourceCache.maximumDecodedByteCount,
            64 * 1_024 * 1_024
        )
        XCTAssertEqual(
            try RuntimeThemeDecodedResourceCache.validatedDecodedByteCount(
                width: 4_096,
                height: 4_096
            ),
            64 * 1_024 * 1_024
        )
        XCTAssertThrowsError(
            try RuntimeThemeDecodedResourceCache.validatedDecodedByteCount(
                width: 4_097,
                height: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeDecodedResourceError,
                .invalidPixelDimensions
            )
        }

        let cache = RuntimeThemeDecodedResourceCache()
        let handle = try cache.prepareImage(data: validThemeBackgroundImage)
        XCTAssertEqual(handle.encodedByteCount, validThemeBackgroundImage.count)
        XCTAssertEqual(handle.pixelWidth, 1)
        XCTAssertEqual(handle.pixelHeight, 1)
        XCTAssertEqual(handle.decodedByteCount, 4)
        XCTAssertEqual(cache.encodedEntryCount, 1)
        XCTAssertEqual(cache.totalEncodedByteCount, validThemeBackgroundImage.count)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.totalDecodedByteCount, 0)
    }

    func testDecodedThemeResourceCacheDeduplicatesEvictsAndReleases() throws {
        let cache = RuntimeThemeDecodedResourceCache(
            maximumDecodedByteCount: 4,
            maximumEntryCount: 2
        )
        let first = try cache.prepareImage(data: validThemeBackgroundImage)
        let second = try cache.prepareImage(
            data: validThemeBackgroundImage + Data([0])
        )
        cache.retain([first, second])

        XCTAssertNotNil(cache.image(for: first))
        XCTAssertNotNil(cache.image(for: first))
        XCTAssertEqual(cache.decodedImageCreationCount, 1)
        XCTAssertEqual(cache.decodedImageCount, 1)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.totalDecodedByteCount, 4)

        XCTAssertNotNil(cache.image(for: second))
        XCTAssertEqual(cache.decodedImageCreationCount, 2)
        XCTAssertEqual(cache.decodedImageCount, 1)
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertEqual(cache.totalDecodedByteCount, 4)

        cache.release([first, second])
        XCTAssertEqual(cache.decodedImageCount, 0)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.encodedEntryCount, 0)
        XCTAssertEqual(cache.totalEncodedByteCount, 0)
        XCTAssertEqual(cache.totalDecodedByteCount, 0)

        XCTAssertNil(cache.image(for: first))
        cache.purge()
        XCTAssertEqual(cache.decodedImageCount, 0)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.totalDecodedByteCount, 0)
    }

    func testDecodedThemeResourceReleaseWaitsForLastOwner() throws {
        let cache = RuntimeThemeDecodedResourceCache()
        let handle = try cache.prepareImage(data: validThemeBackgroundImage)
        cache.retain([handle])
        cache.retain([handle])

        XCTAssertNotNil(cache.image(for: handle))
        XCTAssertEqual(cache.decodedImageCreationCount, 1)
        cache.release([handle])
        XCTAssertEqual(cache.entryCount, 1)
        XCTAssertNotNil(cache.image(for: handle))
        XCTAssertEqual(cache.decodedImageCreationCount, 1)

        cache.release([handle])
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.encodedEntryCount, 0)
        XCTAssertEqual(cache.totalDecodedByteCount, 0)
    }

    func testEncodedBudgetHonorsLeasesAndMemoryPressureRehydrates() throws {
        let secondData = validThemeBackgroundImage + Data([0])
        let cache = RuntimeThemeDecodedResourceCache(
            maximumTotalEncodedImageByteCount: secondData.count,
            maximumDecodedByteCount: 4,
            maximumEntryCount: 2
        )
        let first = try cache.prepareImage(data: validThemeBackgroundImage)
        cache.retain([first])
        XCTAssertNotNil(cache.image(for: first))
        XCTAssertEqual(cache.retainedEntryCount, 1)

        XCTAssertThrowsError(try cache.prepareImage(data: secondData)) {
            XCTAssertEqual(
                $0 as? RuntimeThemeDecodedResourceError,
                .encodedCacheCapacityExceeded
            )
        }

        cache.purge()
        XCTAssertEqual(cache.encodedEntryCount, 1)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertNotNil(cache.image(for: first))
        XCTAssertEqual(cache.decodedImageCreationCount, 2)

        cache.release([first])
        XCTAssertEqual(cache.totalEncodedByteCount, 0)
        XCTAssertNoThrow(try cache.prepareImage(data: secondData))
    }

    func testEncodedEntryLimitEvictsLeastRecentlyUsedUnleasedResource() throws {
        let cache = RuntimeThemeDecodedResourceCache(maximumEntryCount: 2)
        let first = try cache.prepareImage(data: validThemeBackgroundImage)
        let second = try cache.prepareImage(
            data: validThemeBackgroundImage + Data([0])
        )
        XCTAssertNotNil(cache.image(for: first))
        let third = try cache.prepareImage(
            data: validThemeBackgroundImage + Data([1])
        )

        XCTAssertEqual(cache.encodedEntryCount, 2)
        XCTAssertNotNil(cache.image(for: first))
        XCTAssertNil(cache.image(for: second))
        XCTAssertNotNil(cache.image(for: third))
    }

    func testDecodedVectorResourceIsRasterizedOnceAndReused() throws {
        let cache = RuntimeThemeDecodedResourceCache()
        let data = try makeThemeVectorPDF(
            width: 2,
            height: 3,
            rotationAngle: 90
        )
        let handle = try cache.prepareImage(data: data)

        XCTAssertEqual(handle.pixelWidth, 3)
        XCTAssertEqual(handle.pixelHeight, 2)
        XCTAssertEqual(handle.decodedByteCount, 24)
        XCTAssertNotNil(cache.image(for: data))
        XCTAssertNotNil(cache.image(for: handle))
        XCTAssertEqual(cache.decodedImageCreationCount, 1)
        XCTAssertEqual(cache.decodedImageCount, 1)
        XCTAssertEqual(cache.totalDecodedByteCount, 24)
    }

    func testThemeImageReferenceSupportsPDFShareInventory() throws {
        let data = try makeThemeVectorPDF(width: 2, height: 3)
        let fixture = try makeThemeImageContractFixture(
            role: ThemeResourceRoles.sealVectorMaster,
            mediaType: .pdf,
            pixelSize: nil,
            data: data
        )
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        let reference = try presentation.makeThemeImageReference(
            resolvedResource: fixture.resolved,
            expectedInventory: SharePresentationProviderResourceInventory(
                reference: fixture.reference
            ),
            expectedCodexID: fixture.codexID,
            contentRevision: 17
        )

        XCTAssertEqual(reference.resourceID, fixture.reference.id)
        XCTAssertEqual(reference.mediaType, .pdf)
        XCTAssertEqual(reference.kind, .vectorPDF)
        XCTAssertEqual(reference.pixelWidth, 2)
        XCTAssertEqual(reference.pixelHeight, 3)
        XCTAssertEqual(reference.contentRevision, 17)
        XCTAssertNotNil(reference.image)
    }

    func testThemeImageReferenceValidatesIdentityAndSupportsInventory() throws {
        let fixture = try makeThemeImageContractFixture()
        let cache = RuntimeThemeDecodedResourceCache()
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: cache
        )
        let active = try presentation.makeThemeImageReference(
            resolvedResource: fixture.resolved,
            expectedReference: fixture.reference,
            expectedCodexID: fixture.codexID,
            contentRevision: 11
        )

        XCTAssertEqual(active.codexID, fixture.codexID)
        XCTAssertEqual(active.resourceID, fixture.reference.id)
        XCTAssertEqual(active.role, ThemeResourceRoles.relicThumbnail)
        XCTAssertEqual(active.mediaType, .png)
        XCTAssertEqual(active.contentRevision, 11)
        XCTAssertEqual(active.pixelWidth, 1)
        XCTAssertEqual(active.pixelHeight, 1)
        XCTAssertEqual(active.kind, .raster)
        XCTAssertEqual(active.pixelSize, fixture.reference.integrity.pixelSize)
        XCTAssertNotNil(active.image)

        let catalog = try presentation.makeThemeImageReference(
            resolvedResource: fixture.resolved,
            expectedInventory: SharePresentationProviderResourceInventory(
                reference: fixture.reference
            ),
            expectedCodexID: fixture.codexID,
            contentRevision: 12
        )
        XCTAssertNotNil(catalog.image)
        XCTAssertEqual(cache.encodedEntryCount, 2)
        XCTAssertEqual(cache.retainedEntryCount, 2)
    }

    func testThemeImageReferenceRejectsForgedContentMediaAndDimensions() throws {
        let fixture = try makeThemeImageContractFixture()
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        let wrongRole = try ResolvedThemeResourceDTO(
            codexID: fixture.codexID,
            resourceID: fixture.reference.id,
            role: ThemeResourceRoles.sealThumbnail,
            mediaType: fixture.reference.mediaType,
            integrity: fixture.reference.integrity,
            verifiedSHA256: fixture.reference.integrity.sha256,
            data: fixture.resolved.data
        )
        XCTAssertThrowsError(
            try presentation.makeThemeImageReference(
                resolvedResource: wrongRole,
                expectedReference: fixture.reference,
                expectedCodexID: fixture.codexID,
                contentRevision: 1
            )
        ) {
            XCTAssertEqual($0 as? RuntimeThemeImageReferenceError, .roleMismatch)
        }

        XCTAssertThrowsError(
            try presentation.makeThemeImageReference(
                resolvedResource: fixture.resolved,
                expectedReference: fixture.reference,
                expectedCodexID: CodexID(rawValue: "codex.runtime-test-other")!,
                contentRevision: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeThemeImageReferenceError,
                .codexIdentityMismatch
            )
        }

        var corruptedData = fixture.resolved.data
        corruptedData[corruptedData.startIndex] ^= 0xff
        let corrupted = try ResolvedThemeResourceDTO(
            codexID: fixture.codexID,
            resourceID: fixture.reference.id,
            role: fixture.reference.role,
            mediaType: fixture.reference.mediaType,
            integrity: fixture.reference.integrity,
            verifiedSHA256: fixture.reference.integrity.sha256,
            data: corruptedData
        )
        XCTAssertThrowsError(
            try presentation.makeThemeImageReference(
                resolvedResource: corrupted,
                expectedReference: fixture.reference,
                expectedCodexID: fixture.codexID,
                contentRevision: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeThemeImageReferenceError,
                .encodedContentMismatch
            )
        }

        let wrongMedia = try makeThemeImageContractFixture(mediaType: .heif)
        XCTAssertThrowsError(
            try presentation.makeThemeImageReference(
                resolvedResource: wrongMedia.resolved,
                expectedReference: wrongMedia.reference,
                expectedCodexID: wrongMedia.codexID,
                contentRevision: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeThemeImageReferenceError,
                .unsupportedImage
            )
        }

        let wrongDimensions = try makeThemeImageContractFixture(
            pixelSize: ThemePixelSize(width: 2, height: 1)
        )
        XCTAssertThrowsError(
            try presentation.makeThemeImageReference(
                resolvedResource: wrongDimensions.resolved,
                expectedReference: wrongDimensions.reference,
                expectedCodexID: wrongDimensions.codexID,
                contentRevision: 1
            )
        ) {
            XCTAssertEqual(
                $0 as? RuntimeThemeImageReferenceError,
                .pixelDimensionsMismatch
            )
        }
    }

    func testThemeImageReferenceLeaseSurvivesPurgeAndReleasesOnDeinit() async throws {
        let fixture = try makeThemeImageContractFixture()
        let cache = RuntimeThemeDecodedResourceCache()
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: cache
        )
        var reference: RuntimeThemeImageReference? = try presentation
            .makeThemeImageReference(
                resolvedResource: fixture.resolved,
                expectedReference: fixture.reference,
                expectedCodexID: fixture.codexID,
                contentRevision: 21
            )
        XCTAssertNotNil(reference?.image)
        XCTAssertEqual(cache.encodedEntryCount, 1)
        XCTAssertEqual(cache.retainedEntryCount, 1)

        cache.purge()
        XCTAssertEqual(cache.encodedEntryCount, 1)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertNotNil(reference?.image)
        XCTAssertEqual(cache.decodedImageCreationCount, 2)

        reference = nil
        for _ in 0 ..< 100 where cache.retainedEntryCount != 0 {
            await Task.yield()
        }
        XCTAssertEqual(cache.retainedEntryCount, 0)
        XCTAssertEqual(cache.encodedEntryCount, 0)
        XCTAssertEqual(cache.totalEncodedByteCount, 0)
    }

    func testBackgroundCanStageFromValidatedReferencesWithoutDuplicateEntries() throws {
        let cache = RuntimeThemeDecodedResourceCache()
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: cache
        )
        let references = try [
            ThemeResourceRoles.backgroundStaticBase,
            ThemeResourceRoles.backgroundHighContrast,
        ].map { role in
            let fixture = try makeThemeImageContractFixture(role: role)
            return try presentation.makeThemeImageReference(
                resolvedResource: fixture.resolved,
                expectedReference: fixture.reference,
                expectedCodexID: fixture.codexID,
                contentRevision: 31
            )
        }
        let prepared = try presentation.prepareThemeBackground(
            staticBase: references[0],
            reduceMotion: references[0],
            highContrast: references[1],
            rendererParametersData: validThemeBackgroundParameters
        )
        XCTAssertEqual(cache.encodedEntryCount, 2)

        try presentation.commitThemeBackground(prepared)
        XCTAssertEqual(cache.encodedEntryCount, 2)
        XCTAssertEqual(presentation.themeBackgroundRevision, 1)
    }

    func testThemeBackgroundSelectionUsesOneBoundedAccessibilityVariant() throws {
        let cache = RuntimeThemeDecodedResourceCache(
            maximumDecodedByteCount: 4,
            maximumEntryCount: 3
        )
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: cache
        )
        try presentation.installThemeBackground(
            staticBaseData: validThemeBackgroundImage,
            reduceMotionData: validThemeBackgroundImage + Data([0]),
            highContrastData: validThemeBackgroundImage + Data([1]),
            rendererParametersData: validThemeBackgroundParameters
        )

        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.totalDecodedByteCount, 0)
        XCTAssertEqual(cache.decodedImageValidationCount, 3)
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: false,
                increasedContrast: false
            ),
            .staticBase
        )
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: true,
                increasedContrast: false
            ),
            .reduceMotion
        )
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: false,
                increasedContrast: true
            ),
            .highContrast
        )
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: true,
                increasedContrast: true
            ),
            .highContrast
        )

        presentation.setThemeEffectsPreference(.reduced)
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: false,
                increasedContrast: false
            ),
            .reduceMotion
        )
        presentation.setThemeEffectsPreference(.off)
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: false,
                increasedContrast: false
            ),
            .staticBase
        )
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: false,
                increasedContrast: true
            ),
            .highContrast
        )
        presentation.setThemeEffectsPreference(.full)

        XCTAssertNotNil(presentation.staticThemeBackgroundImage)
        XCTAssertEqual(cache.decodedImageCount, 1)
        XCTAssertEqual(cache.totalDecodedByteCount, 4)
        XCTAssertNotNil(presentation.reduceMotionThemeBackgroundImage)
        XCTAssertEqual(cache.decodedImageCount, 1)
        XCTAssertEqual(cache.totalDecodedByteCount, 4)
        XCTAssertNotNil(presentation.highContrastThemeBackgroundImage)
        XCTAssertEqual(cache.decodedImageCount, 1)
        XCTAssertEqual(cache.totalDecodedByteCount, 4)
        XCTAssertEqual(cache.decodedImageCreationCount, 3)

        presentation.clearThemeBackground()
        XCTAssertEqual(cache.decodedImageCount, 0)
        XCTAssertEqual(cache.entryCount, 0)
        XCTAssertEqual(cache.totalDecodedByteCount, 0)
        XCTAssertEqual(
            presentation.themeBackgroundPresentationVariant(
                reduceMotion: false,
                increasedContrast: false
            ),
            .semanticFallback
        )
    }

    func testSplashPresentationAcquiresLazilyAndFinishesExactlyOnce() async throws {
        let fixture = try await makeFixture(resource: .splashVideo)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: fixture.session,
            metalLibrary: nil
        )
        var finishCount = 0

        var state = await fixture.provider.state()
        XCTAssertTrue(state.urlRequests.isEmpty)
        let initialBindingCount = await fixture.gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(initialBindingCount, 0)

        await presentation.startSplash {
            finishCount += 1
        }

        XCTAssertTrue(presentation.splashIsActive)
        XCTAssertNotNil(presentation.splashPlayer)
        state = await fixture.provider.state()
        XCTAssertEqual(state.urlRequests, [.splashVideo])
        let acquiredBindingCount = await fixture.gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(acquiredBindingCount, 1)

        presentation.finishSplash()
        presentation.finishSplash()

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(presentation.splashIsActive)
        XCTAssertNil(presentation.splashPlayer)
        let bindingClosed = await bindingCountEventuallyEquals(
            0,
            on: fixture.gateway
        )
        XCTAssertTrue(bindingClosed)
    }

    func testSourceRevocationStopsSplashAndNotifiesOnce() async throws {
        let fixture = try await makeFixture(resource: .splashVideo)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: fixture.session,
            metalLibrary: nil
        )
        var finishCount = 0
        await presentation.startSplash {
            finishCount += 1
        }

        await fixture.gateway.invalidateModule(
            fixture.descriptor.moduleID,
            generation: fixture.moduleGeneration
        )

        let presentationRevoked = await conditionEventually {
            finishCount == 1 && presentation.splashPlayer == nil
        }
        XCTAssertTrue(presentationRevoked)
        XCTAssertEqual(finishCount, 1)
        let bindingCount = await fixture.gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testCloseReleasesSplashLeaseWithoutReportingCompletion() async throws {
        let fixture = try await makeFixture(resource: .splashVideo)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: fixture.session,
            metalLibrary: nil
        )
        var finishCount = 0
        await presentation.startSplash {
            finishCount += 1
        }

        await presentation.close()

        XCTAssertEqual(finishCount, 0)
        XCTAssertFalse(presentation.hasSplashVideo)
        XCTAssertNil(presentation.splashPlayer)
        let bindingCount = await fixture.gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testMissingSplashSessionFinishesWithoutCreatingNativeState() async {
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        var finishCount = 0

        await presentation.startSplash {
            finishCount += 1
        }

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(presentation.hasSplashVideo)
        XCTAssertNil(presentation.splashPlayer)
        XCTAssertNil(presentation.metalResource)
    }

    func testInvalidMetalLibraryClosesLeaseAndDegradesToStaticState() async throws {
        let fixture = try await makeFixture(resource: .defaultMetalLibrary)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: fixture.session
        )

        await presentation.startMetal()

        XCTAssertNil(presentation.metalResource)
        let bindingClosed = await bindingCountEventuallyEquals(
            0,
            on: fixture.gateway
        )
        XCTAssertTrue(bindingClosed)
        let state = await fixture.provider.state()
        XCTAssertEqual(state.urlRequests, [.defaultMetalLibrary])
    }

    func testMetalCancellationClosesLeaseAcquiredBeforeCancellation() async throws {
        let fixture = try await makeFixture(resource: .defaultMetalLibrary)
        let acquiredLease = try await fixture.session.acquire()
        let acquiredBindingCount = await fixture.gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(acquiredBindingCount, 1)

        let gate = ResourceLeaseGate()
        let suspendedSession = RuntimeApplicationResourceSession {
            await gate.wait()
            return acquiredLease
        }
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: suspendedSession
        )
        let task = Task { @MainActor in
            await presentation.startMetal()
        }
        let acquisitionIsSuspended = await conditionEventually {
            await gate.isWaiting
        }
        XCTAssertTrue(acquisitionIsSuspended)

        task.cancel()
        await gate.resume()
        await task.value

        XCTAssertNil(presentation.metalResource)
        let bindingClosed = await bindingCountEventuallyEquals(
            0,
            on: fixture.gateway
        )
        XCTAssertTrue(bindingClosed)
    }
}

private struct ThemeImageContractFixture {
    let codexID: CodexID
    let reference: ThemeResourceReference
    let resolved: ResolvedThemeResourceDTO
}

private func makeThemeImageContractFixture(
    role: ThemeResourceRoleID = ThemeResourceRoles.relicThumbnail,
    mediaType: ThemeResourceMediaType = .png,
    pixelSize: ThemePixelSize? = try? ThemePixelSize(width: 1, height: 1),
    data: Data = validThemeBackgroundImage
) throws -> ThemeImageContractFixture {
    let codexID = RuneScribeCodexIDs.norse
    let resourceSlug = role.rawValue.replacingOccurrences(of: ".", with: "-")
    let resourceID = ThemeResourceID(
        rawValue: "resource.norse.runtime-test-\(resourceSlug)"
    )!
    let sha256 = ThemeSHA256Digest(
        rawValue: RuntimeIntegrityDigest.sha256Hex(data)
    )!
    let integrity = try ThemeResourceIntegrity(
        sha256: sha256,
        byteLength: UInt64(data.count),
        pixelSize: pixelSize
    )
    let reference = try ThemeResourceReference(
        id: resourceID,
        role: role,
        mediaType: mediaType,
        requirement: .required,
        integrity: integrity,
        rightsID: ThemeProvenanceID(
            rawValue: "rights.norse.runtime-test-image"
        )!
    )
    return try ThemeImageContractFixture(
        codexID: codexID,
        reference: reference,
        resolved: ResolvedThemeResourceDTO(
            codexID: codexID,
            resourceID: resourceID,
            role: role,
            mediaType: mediaType,
            integrity: integrity,
            verifiedSHA256: sha256,
            data: data
        )
    )
}

private let validThemeBackgroundImage = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!

private let metadataOnlyThemeBackgroundImage = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVRub3QtemxpYi1kYXRhFEFebgAAAABJRU5ErkJggg=="
)!

private let validThemeBackgroundParameters = Data(
    #"""
    {
      "schemaVersion": "1.0",
      "rendererParameters": {
        "rendererID": "fragment-rune-background",
        "baseGradient": ["#080A1E", "#14082E"],
        "bandFrequency": 18.0,
        "bandTimeScale": 0.25,
        "bandThreshold": [0.85, 1.0],
        "bandColor": "#0F1438",
        "bandStrength": 0.4,
        "columnFrequency": 9.0,
        "columnTimeScale": 0.15,
        "columnExponent": 6.0,
        "columnColor": "#1A4D99",
        "columnStrength": 0.12,
        "highlightColor": "#D19914",
        "highlightExponent": 7.0,
        "highlightStrength": 0.9,
        "vignetteStrength": 1.8,
        "shimmerTimeScale": 2.1,
        "shimmerFrequency": 40.0,
        "shimmerStrength": 0.012
      }
    }
    """#.utf8
)

private func themeBackgroundParameterObject() throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(with: validThemeBackgroundParameters)
            as? [String: Any]
    )
}

private func makeThemeVectorPDF(
    width: CGFloat,
    height: CGFloat,
    rotationAngle: Int = 0
) throws -> Data {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
        throw RuntimeThemeDecodedResourceError.unsupportedImage
    }
    var mediaBox = CGRect(x: 0, y: 0, width: width, height: height)
    guard let context = CGContext(
        consumer: consumer,
        mediaBox: &mediaBox,
        nil
    ) else {
        throw RuntimeThemeDecodedResourceError.unsupportedImage
    }
    context.beginPDFPage(nil)
    context.setFillColor(gray: 1, alpha: 1)
    context.fill(mediaBox)
    context.endPDFPage()
    context.closePDF()
    let pdfData = data as Data
    guard rotationAngle != 0 else { return pdfData }
    guard let document = PDFDocument(data: pdfData),
          let page = document.page(at: 0)
    else {
        throw RuntimeThemeDecodedResourceError.unsupportedImage
    }
    page.rotation = rotationAngle
    guard let rotatedData = document.dataRepresentation() else {
        throw RuntimeThemeDecodedResourceError.unsupportedImage
    }
    return rotatedData
}

private actor ResourceLeaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
        isWaiting = false
    }
}

private struct ResourcePresentationFixture {
    let gateway: RuntimeIOGateway
    let provider: ResourcePresentationProbe
    let descriptor: ModuleDescriptor
    let moduleGeneration: UInt64
    let session: RuntimeApplicationResourceSession
}

private struct ResourcePresentationProbeState: Equatable, Sendable {
    let urlRequests: [ApplicationResource]
}

private actor ResourcePresentationProbe: ApplicationResourceLocator {
    private let url: URL
    private var urlRequests: [ApplicationResource] = []

    init(url: URL) {
        self.url = url
    }

    func data(for resource: ApplicationResource) async throws -> Data {
        Data()
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        urlRequests.append(resource)
        return url
    }

    func state() -> ResourcePresentationProbeState {
        ResourcePresentationProbeState(urlRequests: urlRequests)
    }
}

private func makeFixture(
    resource: ApplicationResource
) async throws -> ResourcePresentationFixture {
    let provider = ResourcePresentationProbe(
        url: URL(fileURLWithPath: "/tmp/runescribe-runtime-resource-fixture")
    )
    let gateway = RuntimeIOGateway(policy: .patternBFoundation)
    await gateway.install(provider)
    let runtimeGeneration = await gateway.activateRuntime()
    let descriptor = ModuleDescriptor(
        moduleID: "com.runescribe.test.ui-runtime-resource-presentation",
        moduleVersion: SemanticVersion(
            major: UInt(1),
            minor: UInt(0),
            patch: UInt(34)
        ),
        kind: .ui,
        entryPoint: "RuntimeApplicationResourcePresentationTestModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [RuneScribeCapabilities.resourceRead],
        requiredServices: [RuneScribeServiceIDs.applicationResourceLocator],
        requiredResources: [resource],
        publishedServices: [],
        requiredModuleRoles: [],
        consumedEndpoints: [],
        publishedEndpoints: []
    )
    let moduleGeneration = UInt64(1)
    try await gateway.activateModule(
        descriptor: descriptor,
        generation: moduleGeneration
    )
    let client = try await gateway.makeClient(
        sourceModuleID: descriptor.moduleID,
        sourceModuleGeneration: moduleGeneration,
        runtimeGeneration: runtimeGeneration
    )
    let session = try await client.applicationResourceSession(resource)
    return ResourcePresentationFixture(
        gateway: gateway,
        provider: provider,
        descriptor: descriptor,
        moduleGeneration: moduleGeneration,
        session: session
    )
}

@MainActor
private func conditionEventually(
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if predicate() {
            return true
        }
        await Task.yield()
    }
    return false
}

private func conditionEventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if await predicate() {
            return true
        }
        await Task.yield()
    }
    return false
}

private func bindingCountEventuallyEquals(
    _ expectedCount: Int,
    on gateway: RuntimeIOGateway
) async -> Bool {
    for _ in 0..<1_000 {
        if await gateway.activeApplicationResourceBindingCount() == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}
