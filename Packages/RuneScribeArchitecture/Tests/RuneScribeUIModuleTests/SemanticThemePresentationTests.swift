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
        struct PlaceholderCatalog: Decodable {
            struct Asset: Decodable {
                let mediaType: String
                let data: Data
            }
            let assets: [Asset]
        }
        let url = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "NorseBasePlaceholderAssets-v1.0",
                withExtension: "json"
            )
        )
        let catalog = try JSONDecoder().decode(
            PlaceholderCatalog.self,
            from: Data(contentsOf: url)
        )
        let vector = try XCTUnwrap(
            catalog.assets.first(where: { $0.mediaType == "application/pdf" })
        )
        let view = RuntimeThemeVectorText(
            text: "ᚠ",
            glyphDataByTextToken: ["ᚠ": vector.data],
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
