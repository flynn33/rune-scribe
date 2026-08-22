import Foundation
#if os(macOS)
import AppKit
#endif
import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeUIRuntime
import SwiftUI
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class SemanticThemePresentationTests: XCTestCase {
    func testInterpreterUsesEffectiveDescriptorPaletteAndPrimaryScriptFont() throws {
        defer { RuneThemePaletteInterpreter.reset() }
        let descriptor = try descriptor(
            replacingBackgroundPrimaryWith: "#101B2CFF"
        )

        RuneThemePaletteInterpreter.install(descriptor)

        XCTAssertEqual(
            RuneThemePaletteInterpreter.current.backgroundPrimary.rawValue,
            "#101B2CFF"
        )
        XCTAssertEqual(
            RuneThemePaletteInterpreter.fontPostScriptName,
            "NotoSansRunic-Regular"
        )
        let components = RuneThemePaletteInterpreter.rgba(
            ThemeSemanticColor(rawValue: "#12345678")!
        )
        XCTAssertEqual(components.red, 0x12 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(components.green, 0x34 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(components.blue, 0x56 / 255.0, accuracy: 0.000_001)
        XCTAssertEqual(components.alpha, 0x78 / 255.0, accuracy: 0.000_001)
    }

    func testResetRestoresBaseSemanticFallback() throws {
        defer { RuneThemePaletteInterpreter.reset() }
        RuneThemePaletteInterpreter.install(
            try descriptor(replacingBackgroundPrimaryWith: "#123456")
        )

        RuneThemePaletteInterpreter.reset()

        XCTAssertEqual(
            RuneThemePaletteInterpreter.current.backgroundPrimary.rawValue,
            "#080A1E"
        )
        XCTAssertEqual(
            RuneThemePaletteInterpreter.fontPostScriptName,
            "NotoSansRunic-Regular"
        )
    }

    func testResourcePlanBindsFontBackgroundVariantsAndRendererParameters() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor

        let plan = try ThemePresentationResourcePlan(descriptor: descriptor)

        XCTAssertEqual(plan.codexID, RuneScribeCodexIDs.norse)
        XCTAssertNotNil(plan.fontResourceID)
        XCTAssertEqual(plan.expectedFontPostScriptName, "NotoSansRunic-Regular")
        XCTAssertEqual(
            plan.backgroundRendererParametersResourceID,
            descriptor.codex.background.rendererParametersResourceID
        )
        XCTAssertTrue(plan.vectorResourceIDByToken.isEmpty)
        XCTAssertEqual(plan.unlockAnimationResourceIDByTier.count, 4)
    }

    func testNorseUnlockAnimationParametersDriveAllRevealTierDurations() throws {
        let plan = try ThemePresentationResourcePlan(
            descriptor: RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        )
        let expected: [(ProgressionRevealTier, Double)] = [
            (.micro, 0.78),
            (.artifact, 1.28),
            (.codex, 2.2),
            (.mastery, 2.65),
        ]
        for (tier, duration) in expected {
            let resourceID = try XCTUnwrap(
                plan.unlockAnimationResourceIDByTier[tier.rawValue]
            )
            let reference = try XCTUnwrap(
                RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor.resources
                    .first(where: { $0.id == resourceID })
            )
            let url = try XCTUnwrap(
                RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                    forResource: URL(fileURLWithPath: resourceID.rawValue).lastPathComponent
                        .replacingOccurrences(of: "resource.effect.norse.", with: "effect.norse."),
                    withExtension: "json"
                )
            )
            XCTAssertEqual(reference.role.rawValue, "unlock-animation-cue")
            XCTAssertEqual(
                ThemeUnlockCueSelector.animationDuration(try Data(contentsOf: url)),
                duration
            )
        }
        XCTAssertNil(ThemeUnlockCueSelector.animationDuration(Data("{}".utf8)))
    }

    func testDecorativeHeadingCatalogInstallsAllApprovedSlotsAndFailsClosed() throws {
        defer { RuneThemeHeadingInterpreter.reset() }
        let url = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "Norse-Decorative-Heading-Slots-v1.0",
                withExtension: "json"
            )
        )

        RuneThemeHeadingInterpreter.install(try Data(contentsOf: url))

        XCTAssertEqual(RuneThemeHeadingInterpreter.current.count, 13)
        XCTAssertNotEqual(
            RuneThemeHeadingInterpreter.value(for: .workspace, fallback: "Rune Scribe"),
            "Rune Scribe"
        )
        XCTAssertEqual(
            RuneThemeHeadingInterpreter.value(for: .vault, fallback: "Vault"),
            "Vault"
        )

        RuneThemeHeadingInterpreter.install(Data("{".utf8))
        XCTAssertEqual(RuneThemeHeadingInterpreter.current, [:])
        XCTAssertEqual(
            RuneThemeHeadingInterpreter.value(for: .settings, fallback: "Settings"),
            "Settings"
        )
    }

    func testUIModuleSourcesContainNoHardCodedRunicLiterals() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let sources = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule"
        )
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        var violatingFiles: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.unicodeScalars.contains(where: { (0x16A0 ... 0x16FF).contains($0.value) }) {
                violatingFiles.append(url.lastPathComponent)
            }
        }
        XCTAssertEqual(violatingFiles, [])
    }

    func testPerCodexArtifactSelectionUsesTypedContractAndFailsClosed() throws {
        let legacy = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.elven=relic.elven.one;codex.norse=relic.norse.raven-medallion"
        ))
        let decoded = try RuntimeArtifactSelectionCodec.decodeForRead(
            legacy,
            expectedKind: .relic
        )
        XCTAssertEqual(decoded.encoding, .legacyUnversioned)
        XCTAssertEqual(
            decoded.value[try XCTUnwrap(CodexID(rawValue: "codex.elven"))]?.rawValue,
            "relic.elven.one"
        )
        let broken = try XCTUnwrap(RuntimeSettingText(
            rawValue: "codex.norse=relic.norse.first;codex.norse=relic.norse.second"
        ))
        XCTAssertThrowsError(try RuntimeArtifactSelectionCodec.decodeForRead(
            broken,
            expectedKind: .relic
        ))
    }

    func testImportedCipherFontIsTheExplicitThemeScriptCompatibilityException() {
        XCTAssertEqual(
            ThemeScriptFontSelector.postScriptName(
                themePostScriptName: "SelectedTheme-Regular",
                cipherFontName: "ImportedCipher-Regular",
                cipherFontSource: .imported
            ),
            "ImportedCipher-Regular"
        )
        XCTAssertEqual(
            ThemeScriptFontSelector.postScriptName(
                themePostScriptName: "SelectedTheme-Regular",
                cipherFontName: "BundledCipher-Regular",
                cipherFontSource: .bundled
            ),
            "SelectedTheme-Regular"
        )
        XCTAssertFalse(
            ThemeScriptFontSelector.usesThemeVectors(cipherFontSource: .imported)
        )
        XCTAssertTrue(
            ThemeScriptFontSelector.usesThemeVectors(cipherFontSource: .bundled)
        )
        XCTAssertEqual(
            ThemeScriptFontSelector.postScriptName(
                themePostScriptName: "SelectedTheme-Regular",
                cipherFontName: "UnavailableImported-Regular",
                cipherFontSource: .imported,
                cipherFontIsRegistered: false
            ),
            "SelectedTheme-Regular"
        )
        XCTAssertTrue(
            ThemeScriptFontSelector.usesThemeVectors(
                cipherFontSource: .imported,
                cipherFontIsRegistered: false
            )
        )
    }

    func testVectorRunPreservesMappingWhitespaceLineBreakAndUnmappedText() {
        let glyphData = Data([0x25, 0x50, 0x44, 0x46])
        let run = RuntimeThemeGlyphRun(
            text: "ᚠ X\nᚡ",
            glyphDataByTextToken: ["ᚠ": glyphData]
        )

        XCTAssertEqual(
            run.tokens,
            [
                .glyph(textToken: "ᚠ", data: glyphData),
                .space(" "),
                .text("X"),
                .lineBreak,
                .text("ᚡ"),
            ]
        )
    }

    func testVectorPresentationIsLimitedToSettledEncodedRunes() {
        let vectors = ["ᚠ": Data([0x25, 0x50, 0x44, 0x46])]
        let encoded = RuneInscriptionText(
            source: "A",
            target: "ᚠ",
            start: Date(timeIntervalSince1970: 0),
            direction: .encode,
            vectorDataByToken: vectors,
            settled: true
        )
        let decoded = RuneInscriptionText(
            source: "ᚠ",
            target: "A",
            start: Date(timeIntervalSince1970: 0),
            direction: .decode,
            vectorDataByToken: vectors,
            settled: true
        )
        let animating = RuneInscriptionText(
            source: "A",
            target: "ᚠ",
            start: Date(timeIntervalSince1970: 0),
            direction: .encode,
            vectorDataByToken: vectors,
            settled: false
        )

        XCTAssertTrue(encoded.usesVectorPresentation)
        XCTAssertFalse(decoded.usesVectorPresentation)
        XCTAssertFalse(animating.usesVectorPresentation)
    }

    #if os(macOS)
    func testVectorPresentationRendersARealProviderPDFGlyph() throws {
        let url = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "seal.norse.raven",
                withExtension: "pdf"
            )
        )
        let vector = try Data(contentsOf: url)
        let view = RuntimeThemeVectorText(
            text: "ᚠ",
            glyphDataByTextToken: ["ᚠ": vector],
            pointSize: 72,
            color: .black
        )
        .frame(width: 180, height: 120, alignment: .topLeading)
        .background(Color.white)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 120)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds)
        )
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))

        XCTAssertGreaterThan(png.count, 500)
    }
    #endif

    private func descriptor(
        replacingBackgroundPrimaryWith value: String
    ) throws -> ThemeDescriptor {
        let encoded = try JSONEncoder().encode(
            RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        )
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var codex = try XCTUnwrap(root["codex"] as? [String: Any])
        var palette = try XCTUnwrap(codex["palette"] as? [String: Any])
        palette["backgroundPrimary"] = value
        codex["palette"] = palette
        root["codex"] = codex
        return try JSONDecoder().decode(
            ThemeDescriptor.self,
            from: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        )
    }
}
