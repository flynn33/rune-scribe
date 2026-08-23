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

    func testActiveVisualPlanBindsCodexArtifactsAndDescriptorAccessibility() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        XCTAssertEqual(descriptor.id.rawValue, "theme.norse.base")
        XCTAssertEqual(descriptor.codex.id.rawValue, "codex.norse")
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

        let plan = try ActiveThemeVisualResourcePlan(
            descriptor: descriptor,
            revision: 41,
            selection: selection
        )

        XCTAssertEqual(plan.revision, 41)
        XCTAssertEqual(plan.themeID.rawValue, "theme.norse.base")
        XCTAssertEqual(plan.codexID.rawValue, "codex.norse")
        XCTAssertEqual(plan.codex.codexID, descriptor.codex.id)
        XCTAssertEqual(plan.codex.card.id, descriptor.codex.vault.cardResourceID)
        XCTAssertEqual(plan.codex.selected.id, descriptor.codex.vault.selectedResourceID)
        XCTAssertEqual(plan.selectedRelicID, descriptor.codex.defaultRelicID)
        XCTAssertEqual(
            plan.selectedRelic?.primary.id,
            descriptor.codex.relics.first(where: { $0.metadata.id == plan.selectedRelicID })?
                .primaryResourceID
        )
        XCTAssertEqual(
            plan.selectedRelic?.defaultLayoutID,
            descriptor.codex.relics.first(where: { $0.metadata.id == plan.selectedRelicID })?
                .defaultLayoutID
        )
        XCTAssertEqual(plan.selectedSeal?.thumbnail.id, includedSeal.thumbnailResourceID)
        XCTAssertEqual(plan.selectedSeal?.sealAllowedAnchors, includedSeal.allowedAnchors)
        XCTAssertEqual(
            plan.selectedSeal?.accessibilityLabel,
            includedSeal.metadata.accessibility.label.fallbackValue
        )
        XCTAssertFalse(plan.catalog.contains(where: {
            $0.availability == .reservedInactive
        }))
        XCTAssertTrue(plan.catalog.allSatisfy { $0.codexID == descriptor.codex.id })
    }

    func testNorseActiveVisualPlanDeclaresExactCatalogFallbacksAndOptionalFrame() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let seal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.id.rawValue == "seal.norse.knotwork"
        }))
        let frame = try XCTUnwrap(descriptor.codex.frames.first(where: {
            $0.metadata.id.rawValue == "frame.norse.carved-knotwork"
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
        let plan = try ActiveThemeVisualResourcePlan(
            descriptor: descriptor,
            revision: 42,
            selection: selection
        )

        XCTAssertEqual(plan.codex.card.id, descriptor.codex.vault.cardResourceID)
        XCTAssertEqual(plan.codex.locked.id, descriptor.codex.vault.lockedSilhouetteResourceID)
        XCTAssertEqual(plan.codex.encountered.id, descriptor.codex.vault.encounteredResourceID)
        XCTAssertEqual(plan.codex.selected.id, descriptor.codex.vault.selectedResourceID)
        XCTAssertEqual(Set(plan.relics.map(\.id.rawValue)), [
            "relic.norse.runestone.weathered",
            "relic.norse.raven-medallion",
            "relic.norse.ironbound-shield",
            "relic.norse.sealed-parchment",
            "relic.norse.runestone.blackstone",
        ])
        XCTAssertEqual(Set(plan.seals.map(\.id.rawValue)), [
            "seal.norse.knotwork",
            "seal.norse.forge-flame",
            "seal.norse.raven",
            "seal.norse.longship",
            "seal.norse.forge-hammer",
            "seal.norse.echo-rune",
        ])
        XCTAssertEqual(plan.frames.map(\.id.rawValue), ["frame.norse.carved-knotwork"])
        XCTAssertEqual(plan.crests.map(\.id.rawValue), ["crest.norse.forge-master"])
        XCTAssertEqual(plan.selectedFrame?.id, frame.metadata.id)
        XCTAssertEqual(plan.selectedFrame?.primary.id, frame.vectorResourceID)
        XCTAssertEqual(plan.selectedFrame?.standard.id, frame.staticFallbackResourceID)
        XCTAssertEqual(plan.selectedSeal?.highContrast.id, seal.monochromeFallbackResourceID)

        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map {
            ($0.id, $0)
        })
        let imagePlans = [
            plan.codex.card,
            plan.codex.locked,
            plan.codex.encountered,
            plan.codex.selected,
            plan.backgroundStatic,
            plan.backgroundReduceMotion,
            plan.backgroundHighContrast,
        ] + plan.catalog.flatMap {
            [$0.primary, $0.thumbnail, $0.standard, $0.highContrast]
        }
        for imagePlan in imagePlans {
            let reference = try XCTUnwrap(references[imagePlan.id])
            XCTAssertEqual(imagePlan.role, reference.role)
            XCTAssertEqual(imagePlan.mediaType, reference.mediaType)
            XCTAssertEqual(imagePlan.byteLength, reference.integrity.byteLength)
            XCTAssertEqual(imagePlan.pixelSize, reference.integrity.pixelSize)
            XCTAssertEqual(imagePlan.sha256, reference.integrity.sha256)
        }
    }

    func testThemeVisualComponentsExposeStableAccessibilityAndAutomationHooks() throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let views = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeUIModule/Views"
        )
        let componentSource = try String(
            contentsOf: views.appendingPathComponent("ThemeVisualComponents.swift"),
            encoding: .utf8
        )
        let contentSource = try String(
            contentsOf: views.appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: views.appendingPathComponent("SettingsView.swift"),
            encoding: .utf8
        )
        let vaultSource = try String(
            contentsOf: views.appendingPathComponent("VaultProgressView.swift"),
            encoding: .utf8
        )

        for identifier in [
            "theme.codex-card",
            "theme.artifact-thumbnail",
            "theme.artifact-picker",
            "theme.artifact-none.frame",
            "theme.artifact-preview",
        ] {
            XCTAssertTrue(componentSource.contains(identifier), identifier)
        }
        XCTAssertTrue(contentSource.contains("ThemeArtifactPreview("))
        XCTAssertTrue(settingsSource.contains("ThemeCodexCardView("))
        XCTAssertTrue(vaultSource.contains("identifierPrefix: \"theme.vault\""))
        XCTAssertTrue(vaultSource.contains("identifierPrefix: \"theme.vault-artifact\""))
        XCTAssertTrue(vaultSource.contains("GridItem(.adaptive"))
    }

    func testVaultCatalogUsesDescriptorVisualsWithoutInventingEncounterState() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let catalog = VaultProgressPresentation.themeCatalog(
            descriptor: descriptor,
            ownership: [],
            selectedArtifactIDs: [descriptor.codex.defaultRelicID]
        )

        XCTAssertEqual(
            catalog.first(where: { $0.artifactID == descriptor.codex.defaultRelicID })?.state,
            .selected
        )
        XCTAssertFalse(catalog.contains(where: { item in
            let metadata = descriptor.codex.relics.map(\.metadata)
                + descriptor.codex.seals.map(\.metadata)
                + descriptor.codex.frames.map(\.metadata)
                + descriptor.codex.crests.map(\.metadata)
            return metadata.first(where: { $0.id == item.artifactID })?.availability
                == .reservedInactive
        }))
        if let encounteredSeal = descriptor.codex.seals.first(where: {
            $0.metadata.availability == .encountered
        }) {
            XCTAssertEqual(
                catalog.first(where: { $0.artifactID == encounteredSeal.metadata.id })?.state,
                .locked
            )
            XCTAssertEqual(
                catalog.first(where: { $0.artifactID == encounteredSeal.metadata.id })?.resourceID,
                encounteredSeal.thumbnailResourceID
            )
        }
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
