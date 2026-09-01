import Foundation
import RuneScribeContracts
@_spi(RuntimeResourceHost) @testable import RuneScribeRuntimeCore
@testable import RuneScribeUIRuntime
import XCTest

@MainActor
final class RuntimeThemeResourceGenerationTests: XCTestCase {
    func testNorseToEveryOptionalProviderPromotesWithSettingsPreviewsRetained()
        throws
    {
        let optionalCodexIDs = try [
            "codex.moonleaf",
            "codex.sunspire",
            "codex.wildwood",
            "codex.gloamthorn",
        ].map { try XCTUnwrap(CodexID(rawValue: $0)) }

        for codexID in optionalCodexIDs {
            try assertAtomicTransitionWithRetainedSettingsPreviews(
                to: codexID
            )
        }
    }

    func testMismatchedGenerationCannotPartiallyReplaceActiveBackground()
        throws
    {
        let priorCache = RuntimeThemeDecodedResourceCache(
            maximumTotalEncodedImageByteCount: generationTestPNG.count * 4,
            maximumDecodedByteCount: 4,
            maximumEntryCount: 4
        )
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: priorCache
        )
        try presentation.installThemeBackground(
            staticBaseData: generationTestPNG,
            reduceMotionData: generationTestPNG,
            highContrastData: generationTestPNG,
            rendererParametersData: nil
        )
        let nextCodexID = try XCTUnwrap(CodexID(rawValue: "codex.moonleaf"))
        let nextData = generationTestPNG + Data([99])
        let staticFixture = try makeGenerationFixture(
            codexID: nextCodexID,
            resourceID: "resource.moonleaf.generation-next-static",
            role: ThemeResourceRoles.backgroundStaticBase,
            data: nextData
        )
        let highContrastFixture = try makeGenerationFixture(
            codexID: nextCodexID,
            resourceID: "resource.moonleaf.generation-next-high-contrast",
            role: ThemeResourceRoles.backgroundHighContrast,
            data: nextData
        )
        let preparedGeneration = try presentation.beginThemeResourceGeneration()
        let unrelatedGeneration = try presentation.beginThemeResourceGeneration()
        let staticReference = try presentation.makeThemeImageReference(
            resolvedResource: staticFixture.resolved,
            expectedReference: staticFixture.reference,
            expectedCodexID: nextCodexID,
            contentRevision: 2,
            generation: preparedGeneration
        )
        let highContrastReference = try presentation.makeThemeImageReference(
            resolvedResource: highContrastFixture.resolved,
            expectedReference: highContrastFixture.reference,
            expectedCodexID: nextCodexID,
            contentRevision: 2,
            generation: preparedGeneration
        )
        let preparedBackground = try presentation.prepareThemeBackground(
            staticBase: staticReference,
            reduceMotion: staticReference,
            highContrast: highContrastReference,
            rendererParametersData: nil,
            generation: preparedGeneration
        )

        XCTAssertThrowsError(
            try presentation.commitThemeResourceGeneration(
                unrelatedGeneration,
                background: preparedBackground
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeResourceGenerationError,
                .invalidGeneration
            )
        }
        XCTAssertTrue(presentation.themeDecodedResourceCache === priorCache)
        XCTAssertEqual(presentation.themeBackgroundRevision, 1)
        XCTAssertNotNil(presentation.staticThemeBackgroundImage)

        try presentation.commitThemeResourceGeneration(
            preparedGeneration,
            background: preparedBackground
        )
        XCTAssertFalse(presentation.themeDecodedResourceCache === priorCache)
        XCTAssertEqual(presentation.themeBackgroundRevision, 2)
        XCTAssertNotNil(presentation.staticThemeBackgroundImage)
    }

    private func assertAtomicTransitionWithRetainedSettingsPreviews(
        to nextCodexID: CodexID
    ) throws {
        let priorData = (0 ..< 7).map {
            generationTestPNG + Data([UInt8($0)])
        }
        let nextData = generationTestPNG + Data([100])
        let priorCache = RuntimeThemeDecodedResourceCache(
            maximumTotalEncodedImageByteCount: priorData.reduce(0) {
                $0 + $1.count
            },
            maximumDecodedByteCount: 4,
            maximumEntryCount: 8
        )
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil,
            decodedResourceCache: priorCache
        )

        let priorStaticFixture = try makeGenerationFixture(
            codexID: RuneScribeCodexIDs.norse,
            resourceID: "resource.norse.generation-prior-static",
            role: ThemeResourceRoles.backgroundStaticBase,
            data: priorData[0]
        )
        let priorHighContrastFixture = try makeGenerationFixture(
            codexID: RuneScribeCodexIDs.norse,
            resourceID: "resource.norse.generation-prior-high-contrast",
            role: ThemeResourceRoles.backgroundHighContrast,
            data: priorData[1]
        )
        let priorStatic = try presentation.makeThemeImageReference(
            resolvedResource: priorStaticFixture.resolved,
            expectedReference: priorStaticFixture.reference,
            expectedCodexID: priorStaticFixture.codexID,
            contentRevision: 1
        )
        let priorHighContrast = try presentation.makeThemeImageReference(
            resolvedResource: priorHighContrastFixture.resolved,
            expectedReference: priorHighContrastFixture.reference,
            expectedCodexID: priorHighContrastFixture.codexID,
            contentRevision: 1
        )
        let priorBackground = try presentation.prepareThemeBackground(
            staticBase: priorStatic,
            reduceMotion: priorStatic,
            highContrast: priorHighContrast,
            rendererParametersData: nil
        )
        try presentation.commitThemeBackground(priorBackground)

        var retainedSettingsPreviews = [priorStatic, priorHighContrast]
        let previewCodexIDs = try [
            "codex.norse",
            "codex.moonleaf",
            "codex.sunspire",
            "codex.wildwood",
            "codex.gloamthorn",
        ].map { try XCTUnwrap(CodexID(rawValue: $0)) }
        for (offset, codexID) in previewCodexIDs.enumerated() {
            let codexName = codexID.rawValue.replacingOccurrences(
                of: "codex.",
                with: ""
            )
            let fixture = try makeGenerationFixture(
                codexID: codexID,
                resourceID: "resource.\(codexName).generation-settings-preview",
                role: ThemeResourceRoles.vaultSelected,
                data: priorData[offset + 2]
            )
            retainedSettingsPreviews.append(
                try presentation.makeThemeImageReference(
                    resolvedResource: fixture.resolved,
                    expectedReference: fixture.reference,
                    expectedCodexID: codexID,
                    contentRevision: 1
                )
            )
        }
        XCTAssertEqual(priorCache.retainedEntryCount, priorData.count)
        XCTAssertEqual(
            priorCache.totalEncodedByteCount,
            priorData.reduce(0) { $0 + $1.count }
        )

        let nextCodexName = nextCodexID.rawValue.replacingOccurrences(
            of: "codex.",
            with: ""
        )
        let nextStaticFixture = try makeGenerationFixture(
            codexID: nextCodexID,
            resourceID: "resource.\(nextCodexName).generation-next-static",
            role: ThemeResourceRoles.backgroundStaticBase,
            data: nextData
        )
        let nextHighContrastFixture = try makeGenerationFixture(
            codexID: nextCodexID,
            resourceID:
                "resource.\(nextCodexName).generation-next-high-contrast",
            role: ThemeResourceRoles.backgroundHighContrast,
            data: nextData
        )

        XCTAssertThrowsError(
            try presentation.makeThemeImageReference(
                resolvedResource: nextStaticFixture.resolved,
                expectedReference: nextStaticFixture.reference,
                expectedCodexID: nextCodexID,
                contentRevision: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? RuntimeThemeImageReferenceError,
                .cacheCapacityExceeded
            )
        }

        var renderedResourceIDs: [ThemeResourceID] = []
        presentation.beginRenderedResourceObservation {
            renderedResourceIDs.append($0.resourceID)
        }
        let generation = try presentation.beginThemeResourceGeneration()
        let nextStatic = try presentation.makeThemeImageReference(
            resolvedResource: nextStaticFixture.resolved,
            expectedReference: nextStaticFixture.reference,
            expectedCodexID: nextCodexID,
            contentRevision: 2,
            generation: generation
        )
        let nextHighContrast = try presentation.makeThemeImageReference(
            resolvedResource: nextHighContrastFixture.resolved,
            expectedReference: nextHighContrastFixture.reference,
            expectedCodexID: nextCodexID,
            contentRevision: 2,
            generation: generation
        )
        let nextBackground = try presentation.prepareThemeBackground(
            staticBase: nextStatic,
            reduceMotion: nextStatic,
            highContrast: nextHighContrast,
            rendererParametersData: nil,
            generation: generation
        )

        XCTAssertTrue(presentation.themeDecodedResourceCache === priorCache)
        XCTAssertEqual(priorCache.retainedEntryCount, priorData.count)
        XCTAssertTrue(renderedResourceIDs.isEmpty)

        try presentation.commitThemeResourceGeneration(
            generation,
            background: nextBackground
        )

        let promotedCache = presentation.themeDecodedResourceCache
        XCTAssertFalse(promotedCache === priorCache)
        XCTAssertEqual(
            promotedCache.configuredEncodedByteLimit,
            priorCache.configuredEncodedByteLimit
        )
        XCTAssertEqual(
            promotedCache.configuredDecodedByteLimit,
            priorCache.configuredDecodedByteLimit
        )
        XCTAssertEqual(priorCache.retainedEntryCount, priorData.count)
        XCTAssertEqual(priorCache.totalDecodedByteCount, 0)
        XCTAssertEqual(promotedCache.totalDecodedByteCount, 0)
        XCTAssertNotNil(presentation.staticThemeBackgroundImage)
        XCTAssertEqual(promotedCache.totalDecodedByteCount, 4)
        XCTAssertEqual(
            renderedResourceIDs,
            [nextStaticFixture.reference.id]
        )
        XCTAssertEqual(presentation.themeBackgroundRevision, 2)
        XCTAssertEqual(retainedSettingsPreviews.count, 7)
    }
}

private struct GenerationThemeImageFixture {
    let codexID: CodexID
    let reference: ThemeResourceReference
    let resolved: ResolvedThemeResourceDTO
}

private func makeGenerationFixture(
    codexID: CodexID,
    resourceID: String,
    role: ThemeResourceRoleID,
    data: Data
) throws -> GenerationThemeImageFixture {
    let resourceID = try XCTUnwrap(ThemeResourceID(rawValue: resourceID))
    let sha256 = try XCTUnwrap(ThemeSHA256Digest(
        rawValue: RuntimeIntegrityDigest.sha256Hex(data)
    ))
    let integrity = try ThemeResourceIntegrity(
        sha256: sha256,
        byteLength: UInt64(data.count),
        pixelSize: ThemePixelSize(width: 1, height: 1)
    )
    let reference = try ThemeResourceReference(
        id: resourceID,
        role: role,
        mediaType: .png,
        requirement: .required,
        integrity: integrity,
        rightsID: ThemeProvenanceID(
            rawValue: "rights.runtime.generation-test"
        )!
    )
    return try GenerationThemeImageFixture(
        codexID: codexID,
        reference: reference,
        resolved: ResolvedThemeResourceDTO(
            codexID: codexID,
            resourceID: resourceID,
            role: role,
            mediaType: .png,
            integrity: integrity,
            verifiedSHA256: sha256,
            data: data
        )
    )
}

private let generationTestPNG = Data(
    base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
)!
