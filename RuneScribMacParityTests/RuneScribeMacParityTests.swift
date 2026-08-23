import AppKit
import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import RuneScribeNorseThemeModule
import RuneScribePlatform
@_spi(RuntimeFileImportHost) @_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
import RuneScribeThemeMoonleafModule
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import SwiftUI
import XCTest

@MainActor
final class RuneScribeMacParityTests: XCTestCase {
    func testNorseVisualPresentationRendersRuntimeBackedMacSurfacesAndRetainsStateAcrossResize()
        async throws
    {
        var normalEvidenceDigests = Set<String>()
        try await withHarness { harness in
            let snapshot = try XCTUnwrap(harness.session.themeSnapshot)
            XCTAssertEqual(snapshot.effectiveTheme.id.rawValue, "theme.norse.base")
            XCTAssertEqual(snapshot.effectiveCodexID.rawValue, "codex.norse")
            XCTAssertFalse(snapshot.isEmergencyPresentation)
            XCTAssertEqual(
                harness.session.selectedThemeRelicID?.rawValue,
                "relic.norse.runestone.weathered"
            )
            XCTAssertEqual(
                harness.session.selectedThemeSealID?.rawValue,
                "seal.norse.knotwork"
            )
            XCTAssertNil(harness.session.selectedThemeFrameID)

            let settingsAdoptionFinished = await eventually {
                harness.session.runtimePresentationSettingsReady
                    && harness.session.runtimeSettingsSnapshot != nil
                    && (harness.session.activeThemeVisualPresentation?.revision ?? 0) > 1
            }
            XCTAssertTrue(settingsAdoptionFinished)
            await harness.session.loadActiveThemeCatalogVisuals()
            await harness.session.loadThemeCodexCardPreviews()

            let presentation = try XCTUnwrap(
                harness.session.activeThemeVisualPresentation
            )
            XCTAssertEqual(presentation.revision, presentation.plan.revision)
            XCTAssertEqual(presentation.plan.themeID.rawValue, "theme.norse.base")
            XCTAssertEqual(presentation.plan.codexID.rawValue, "codex.norse")
            XCTAssertEqual(presentation.plan.relics.count, 5)
            XCTAssertEqual(presentation.plan.seals.count, 6)
            XCTAssertEqual(presentation.plan.frames.count, 1)
            XCTAssertEqual(presentation.plan.crests.count, 1)

            let requiredVisuals = [
                presentation.plan.codex.selected,
                presentation.plan.backgroundStatic,
                presentation.plan.backgroundReduceMotion,
                presentation.plan.backgroundHighContrast,
                try XCTUnwrap(presentation.plan.selectedRelic).thumbnail,
                try XCTUnwrap(presentation.plan.selectedRelic).standard,
                try XCTUnwrap(presentation.plan.selectedRelic).highContrast,
                try XCTUnwrap(presentation.plan.selectedSeal).thumbnail,
                try XCTUnwrap(presentation.plan.selectedSeal).standard,
                try XCTUnwrap(presentation.plan.selectedSeal).highContrast,
            ]
            for visual in requiredVisuals {
                let reference = try XCTUnwrap(
                    presentation.imageReference(for: visual),
                    visual.id.rawValue
                )
                XCTAssertEqual(reference.codexID, visual.codexID)
                XCTAssertEqual(reference.resourceID, visual.id)
                XCTAssertEqual(reference.role, visual.role)
                XCTAssertEqual(reference.mediaType, visual.mediaType)
                XCTAssertEqual(reference.integrity.byteLength, visual.byteLength)
                XCTAssertEqual(reference.integrity.pixelSize, visual.pixelSize)
                XCTAssertEqual(reference.integrity.sha256, visual.sha256)
                XCTAssertEqual(reference.contentRevision, presentation.revision)
                XCTAssertGreaterThan(reference.pixelWidth, 0)
                XCTAssertGreaterThan(reference.pixelHeight, 0)
                XCTAssertNotNil(reference.image)
            }
            for visual in presentation.plan.catalog {
                XCTAssertNotNil(
                    presentation.imageReference(for: visual.thumbnail),
                    visual.thumbnail.id.rawValue
                )
            }
            let settingsCodexReference = try XCTUnwrap(
                harness.session.themeCodexCardImageReferences[snapshot.effectiveCodexID]
            )
            XCTAssertEqual(
                settingsCodexReference.resourceID,
                presentation.plan.codex.selected.id
            )
            XCTAssertNotNil(settingsCodexReference.image)

            let selectedState = MacSelectedThemeState(session: harness.session)
            let workspace = AnyView(RootView(session: harness.session))
            let workspacePNG = try renderPNG(
                workspace,
                size: CGSize(width: 720, height: 780)
            )
            try assertDetailedPNG(workspacePNG, minimumUniqueSampleColors: 48)
            attachPNG(workspacePNG, name: "macos-workspace-pre-encode-norse")

            let focus = inspectKeyboardFocus(
                workspace,
                size: CGSize(width: 720, height: 780)
            )
            XCTAssertGreaterThanOrEqual(focus.keyViewCount, 3)
            XCTAssertGreaterThan(focus.focusableViewCount, 0)
            XCTAssertTrue(focus.acceptedFirstResponder)

            let resizeReport = try inspectWindowResize(
                workspace,
                sizes: [
                    CGSize(width: 560, height: 640),
                    CGSize(width: 980, height: 720),
                    CGSize(width: 720, height: 780),
                ]
            )
            XCTAssertEqual(resizeReport.renderedSizes.count, 3)
            XCTAssertTrue(resizeReport.renderedSizes.allSatisfy {
                $0.width > 0 && $0.height > 0
            })
            XCTAssertEqual(
                MacSelectedThemeState(session: harness.session),
                selectedState,
                "Window resizing must not reset the selected visual state."
            )

            let settingsPNG = try renderPNG(
                AnyView(
                    SettingsView()
                        .environmentObject(harness.session)
                ),
                size: CGSize(width: 760, height: 900)
            )
            try assertDetailedPNG(settingsPNG, minimumUniqueSampleColors: 48)
            attachPNG(settingsPNG, name: "macos-settings-norse")

            let pickerItems = presentation.plan.catalog.map { visual in
                ThemeArtifactBrowserItem(
                    id: visual.id,
                    resourceID: visual.thumbnail.id,
                    name: visual.displayName,
                    description: visual.description,
                    kind: visual.kind,
                    rarity: visual.rarity,
                    state: visual.id == presentation.plan.selectedRelicID
                        || visual.id == presentation.plan.selectedSealID
                        || visual.id == presentation.plan.selectedFrameID
                        ? .selected
                        : visual.availability == .included ? .owned : .locked,
                    accessibilityLabel: visual.accessibilityLabel,
                    accessibilityHint: visual.accessibilityHint,
                    provenance: snapshot.effectiveTheme.rights.first(where: {
                        $0.id == visual.rightsID
                    })?.sourceReference,
                    isSelectable: visual.availability == .included
                )
            }
            let knotworkID = try XCTUnwrap(ArtifactID(rawValue: "seal.norse.knotwork"))
            let forgeFlameID = try XCTUnwrap(ArtifactID(rawValue: "seal.norse.forge-flame"))
            let knotwork = try XCTUnwrap(pickerItems.first(where: { $0.id == knotworkID }))
            let forgeFlame = try XCTUnwrap(pickerItems.first(where: { $0.id == forgeFlameID }))
            XCTAssertEqual(knotwork.name, "Knotwork Mark")
            XCTAssertEqual(knotwork.state, .selected)
            XCTAssertEqual(forgeFlame.name, "Forge Flame")
            XCTAssertEqual(forgeFlame.state, .owned)
            for item in [knotwork, forgeFlame] {
                let visual = try XCTUnwrap(
                    presentation.plan.catalog.first(where: { $0.id == item.id })
                )
                XCTAssertEqual(item.resourceID, visual.thumbnail.id)
                XCTAssertNotNil(presentation.imageReference(for: visual.thumbnail)?.image)
            }
            let pickerPNG = try renderPNG(
                AnyView(
                    ThemeArtifactBrowserView(
                        title: "Choose Artifact",
                        items: pickerItems,
                        includesNone: false,
                        canSelectNone: false,
                        selectNone: {},
                        select: { _ in }
                    ) { item in
                        if let visual = presentation.plan.catalog.first(where: {
                            $0.id == item.id
                        }),
                        let image = presentation.imageReference(
                            for: visual.thumbnail
                        )?.image {
                            AnyView(image.resizable().scaledToFill())
                        } else {
                            AnyView(
                                ThemeVisualPlaceholder(
                                    systemImage: item.kind.systemImage,
                                    label: "\(item.name) artwork unavailable"
                                )
                            )
                        }
                    }
                    .background(Color.runeNavy)
                ),
                size: CGSize(width: 820, height: 760)
            )
            try assertDetailedPNG(pickerPNG, minimumUniqueSampleColors: 64)
            attachPNG(pickerPNG, name: "macos-artifact-picker-norse")

            let lockedItem = try XCTUnwrap(
                pickerItems.first(where: { $0.state == .locked })
            )
            let lockedVisual = try XCTUnwrap(
                presentation.plan.catalog.first(where: { $0.id == lockedItem.id })
            )
            let lockedReference = try XCTUnwrap(
                presentation.imageReference(for: lockedVisual.thumbnail)
            )
            let lockedImage = try XCTUnwrap(lockedReference.image)
            XCTAssertEqual(lockedItem.resourceID, lockedVisual.thumbnail.id)
            XCTAssertEqual(lockedReference.resourceID, lockedItem.resourceID)
            XCTAssertFalse(lockedItem.isSelectable)
            XCTAssertNotEqual(lockedVisual.availability, .included)
            let lockedTilePNG = try renderPNG(
                AnyView(
                    VStack(alignment: .leading, spacing: 8) {
                        Text("LOCKED ARTIFACT")
                            .font(.caption.bold().monospaced())
                            .foregroundStyle(Color.runeGoldBright)
                        Text(lockedItem.resourceID.rawValue)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Color.runeSilver)
                        ThemeArtifactTile(item: lockedItem, action: {}) {
                            lockedImage.resizable().scaledToFill()
                        }
                    }
                    .padding(24)
                    .background(Color.runeNavy)
                ),
                size: CGSize(width: 360, height: 540)
            )
            try assertDetailedPNG(lockedTilePNG, minimumUniqueSampleColors: 48)
            attachPNG(lockedTilePNG, name: "macos-locked-artifact-norse")

            let activeCipher = try XCTUnwrap(harness.session.activeCipher)
            let encoded = try await harness.session.encode(
                "Norse hosted visual parity",
                cipherID: activeCipher.id
            )
            let selection = try SharePresentationSelection(
                codexID: presentation.plan.codexID,
                scriptID: presentation.plan.scriptID,
                relicID: presentation.plan.selectedRelicID,
                sealID: presentation.plan.selectedSealID,
                frameID: presentation.plan.selectedFrameID,
                presentationVersion:
                    SharePresentationSelection.supportedPresentationVersion
            )
            let composition = try ThemeArtifactCompositionPolicy.interactivePlan(
                selection: selection,
                inscription: encoded.runes,
                descriptor: snapshot.effectiveTheme,
                colorMode: .standard,
                reduceMotion: false,
                accessibilityLabel:
                    "Settled Norse artifact using Weathered Rune Stone and Knotwork Seal",
                provenanceLabel: "Runtime-admitted Norse resources"
            )
            XCTAssertEqual(composition.selection, selection)
            XCTAssertEqual(
                composition.relicResourceID,
                try XCTUnwrap(presentation.plan.selectedRelic).standard.id
            )
            XCTAssertEqual(
                composition.sealResourceID,
                try XCTUnwrap(presentation.plan.selectedSeal).standard.id
            )
            XCTAssertEqual(
                composition.backgroundResourceID,
                presentation.plan.backgroundStatic.id
            )
            for resourceID in [
                composition.relicResourceID,
                composition.sealResourceID,
                composition.frameResourceID,
                Optional(composition.backgroundResourceID),
            ].compactMap({ $0 }) {
                XCTAssertNotNil(
                    presentation.image(for: resourceID),
                    resourceID.rawValue
                )
            }

            let previewPNG = try renderPNG(
                artifactEvidencePreview(
                    title: "Settled encoded preview",
                    plan: composition,
                    presentation: presentation
                ),
                size: CGSize(width: 760, height: 590)
            )
            try assertDetailedPNG(previewPNG, minimumUniqueSampleColors: 96)
            let fallbackPreviewPNG = try renderPNG(
                AnyView(
                    ThemeVisualPlaceholder(
                        systemImage: "photo.artframe",
                        label: "Artifact preview unavailable"
                    )
                ),
                size: CGSize(width: 760, height: 590)
            )
            XCTAssertNotEqual(
                Self.digestHex(previewPNG),
                Self.digestHex(fallbackPreviewPNG),
                "The settled preview must not collapse to the semantic placeholder."
            )
            attachPNG(previewPNG, name: "macos-settled-preview-norse")

            let settledWorkspacePNG = try renderPNG(
                AnyView(
                    ContentView(
                        initialSettledArtifact: ContentViewSettledArtifactSeed(
                            composition: composition,
                            presentation: presentation
                        )
                    )
                    .environmentObject(harness.session)
                    .environment(
                        \.runtimeApplicationResourcePresentation,
                        harness.session.resourcePresentation
                    )
                ),
                size: CGSize(width: 720, height: 780)
            )
            try assertDetailedPNG(
                settledWorkspacePNG,
                minimumUniqueSampleColors: 96
            )
            XCTAssertNotEqual(
                Self.digestHex(settledWorkspacePNG),
                Self.digestHex(workspacePNG),
                "The required workspace evidence must show the settled encoded canvas."
            )
            attachPNG(settledWorkspacePNG, name: "macos-workspace-norse")

            let highContrastComposition = try ThemeArtifactCompositionPolicy
                .interactivePlan(
                    selection: selection,
                    inscription: encoded.runes,
                    descriptor: snapshot.effectiveTheme,
                    colorMode: .highContrast,
                    reduceMotion: false,
                    accessibilityLabel: "High Contrast Norse artifact preview",
                    provenanceLabel: "Runtime-admitted Norse resources"
                )
            XCTAssertEqual(
                highContrastComposition.relicResourceID,
                try XCTUnwrap(presentation.plan.selectedRelic).highContrast.id
            )
            XCTAssertEqual(
                highContrastComposition.sealResourceID,
                try XCTUnwrap(presentation.plan.selectedSeal).highContrast.id
            )
            XCTAssertEqual(
                highContrastComposition.backgroundResourceID,
                presentation.plan.backgroundHighContrast.id
            )
            for resourceID in [
                highContrastComposition.relicResourceID,
                highContrastComposition.sealResourceID,
                Optional(highContrastComposition.backgroundResourceID),
            ].compactMap({ $0 }) {
                XCTAssertNotNil(presentation.image(for: resourceID), resourceID.rawValue)
            }
            let highContrastPNG = try renderPNG(
                artifactEvidencePreview(
                    title: "High Contrast preview",
                    plan: highContrastComposition,
                    presentation: presentation
                ),
                size: CGSize(width: 760, height: 590)
            )
            try assertDetailedPNG(highContrastPNG, minimumUniqueSampleColors: 96)
            XCTAssertNotEqual(
                Self.digestHex(highContrastPNG),
                Self.digestHex(previewPNG)
            )
            attachPNG(highContrastPNG, name: "macos-high-contrast-preview-norse")

            let reduceMotionComposition = try ThemeArtifactCompositionPolicy
                .interactivePlan(
                    selection: selection,
                    inscription: encoded.runes,
                    descriptor: snapshot.effectiveTheme,
                    colorMode: .standard,
                    reduceMotion: true,
                    accessibilityLabel: "Reduce Motion Norse artifact preview",
                    provenanceLabel: "Runtime-admitted Norse resources"
                )
            XCTAssertEqual(
                reduceMotionComposition.relicResourceID,
                try XCTUnwrap(presentation.plan.selectedRelic).standard.id
            )
            XCTAssertEqual(
                reduceMotionComposition.sealResourceID,
                try XCTUnwrap(presentation.plan.selectedSeal).standard.id
            )
            XCTAssertEqual(
                reduceMotionComposition.backgroundResourceID,
                presentation.plan.backgroundReduceMotion.id
            )
            XCTAssertEqual(
                reduceMotionComposition.backgroundResourceID,
                composition.backgroundResourceID
            )
            for resourceID in [
                reduceMotionComposition.relicResourceID,
                reduceMotionComposition.sealResourceID,
                Optional(reduceMotionComposition.backgroundResourceID),
            ].compactMap({ $0 }) {
                XCTAssertNotNil(presentation.image(for: resourceID), resourceID.rawValue)
            }
            let reduceMotionPNG = try renderPNG(
                artifactEvidencePreview(
                    title: "Reduce Motion preview",
                    plan: reduceMotionComposition,
                    presentation: presentation
                ),
                size: CGSize(width: 760, height: 590)
            )
            try assertDetailedPNG(reduceMotionPNG, minimumUniqueSampleColors: 96)
            let reduceMotionDigest = Self.digestHex(reduceMotionPNG)
            XCTAssertNotEqual(reduceMotionDigest, Self.digestHex(previewPNG))
            XCTAssertNotEqual(reduceMotionDigest, Self.digestHex(highContrastPNG))
            attachPNG(reduceMotionPNG, name: "macos-reduce-motion-preview-norse")

            harness.session.progressionSnapshot = try ProgressionSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                availability: .available,
                storeHealth: .loaded,
                catalogID: nil,
                catalogVersion: nil
            )
            harness.session.progressionRailState = .available
            let initialVaultPNG = try renderPNG(
                AnyView(
                    VaultProgressView()
                        .environmentObject(harness.session)
                ),
                size: CGSize(width: 840, height: 940)
            )
            let vaultPNG = try renderPNG(
                AnyView(
                    VaultProgressView()
                        .environmentObject(harness.session)
                ),
                size: CGSize(width: 840, height: 940),
                afterClicking: CGPoint(x: 400, y: 140)
            )
            XCTAssertNotEqual(
                Self.digestHex(vaultPNG),
                Self.digestHex(initialVaultPNG),
                "The hosted Vault control must switch from Journey to Vault."
            )
            try assertMaterialPNGChange(
                from: initialVaultPNG,
                to: vaultPNG,
                minimumChangedSampleRatio: 0.15
            )
            try assertDetailedPNG(vaultPNG, minimumUniqueSampleColors: 64)
            attachPNG(vaultPNG, name: "macos-vault-norse")

            let screenshotDigests = Set([
                settledWorkspacePNG,
                settingsPNG,
                pickerPNG,
                previewPNG,
                lockedTilePNG,
                highContrastPNG,
                reduceMotionPNG,
                vaultPNG,
            ].map(Self.digestHex))
            XCTAssertEqual(
                screenshotDigests.count,
                8,
                "Every macOS evidence surface must be a distinct rendered image."
            )
            normalEvidenceDigests = screenshotDigests
            XCTAssertEqual(
                MacSelectedThemeState(session: harness.session),
                selectedState,
                "Rendering Settings, picker, preview, and Vault must retain selection."
            )
        }

        let unavailableFont = NorseBaseBundledResourceCatalog.notoSansRunic
        try await withHarness(unavailableThemeResource: unavailableFont) { harness in
            let emergencyReady = await eventually {
                harness.session.themeSnapshot?.isEmergencyPresentation == true
                    && harness.session.runtimePresentationSettingsReady
            }
            XCTAssertTrue(emergencyReady)
            let snapshot = try XCTUnwrap(harness.session.themeSnapshot)
            XCTAssertTrue(snapshot.isEmergencyPresentation)
            XCTAssertEqual(snapshot.effectiveCodexID.rawValue, "codex.norse")
            XCTAssertEqual(snapshot.fallbackReason, .invalidResources)
            let script = try XCTUnwrap(
                snapshot.effectiveTheme.codex.scripts.first(where: {
                    $0.id == snapshot.effectiveTheme.codex.primaryScriptID
                })
            )
            XCTAssertEqual(
                script.fontResourceID?.rawValue,
                "resource.font.norse.noto-sans-runic"
            )
            XCTAssertEqual(unavailableFont.name, "NotoSansRunic-Regular")
            XCTAssertNil(harness.session.activeThemeVisualPresentation)
            XCTAssertTrue(harness.session.themeCodexCardImageReferences.isEmpty)
            XCTAssertNil(harness.session.selectedThemeRelicID)
            XCTAssertNil(harness.session.selectedThemeSealID)
            XCTAssertNil(harness.session.selectedThemeFrameID)

            let emergencyPNG = try renderPNG(
                AnyView(RootView(session: harness.session)),
                size: CGSize(width: 720, height: 780)
            )
            try assertDetailedPNG(emergencyPNG, minimumUniqueSampleColors: 24)
            let emergencyDigest = Self.digestHex(emergencyPNG)
            XCTAssertFalse(
                normalEvidenceDigests.contains(emergencyDigest),
                "Emergency presentation evidence must differ from every runtime-backed surface."
            )
            attachPNG(emergencyPNG, name: "macos-emergency-fallback-norse")
        }
    }

    func testDefaultContentViewStartsWithAnEmptyEditableWorkspace() async throws {
        try await withHarness { harness in
            let state = inspectContentEditingState(
                AnyView(
                    ContentView()
                        .environmentObject(harness.session)
                        .environment(
                            \.runtimeApplicationResourcePresentation,
                            harness.session.resourcePresentation
                        )
                ),
                size: CGSize(width: 720, height: 780)
            )
            XCTAssertTrue(state.hasEditableTextView)
            XCTAssertEqual(state.text, "")
        }
    }

    func testRealViewsRenderWithFocusableWorkspaceAndExactCommandCatalog() async throws {
        try await withHarness { harness in
            let workspace = AnyView(RootView(session: harness.session))
            let settings = AnyView(
                SettingsView()
                    .environmentObject(harness.session)
            )

            let workspacePNG = try renderPNG(
                workspace,
                size: CGSize(width: 600, height: 720)
            )
            let settingsPNG = try renderPNG(
                settings,
                size: CGSize(width: 600, height: 720)
            )
            XCTAssertGreaterThan(workspacePNG.count, 10_000)
            XCTAssertGreaterThan(settingsPNG.count, 10_000)
            attachPNG(workspacePNG, name: "mac-workspace")
            attachPNG(settingsPNG, name: "mac-settings")

            let focus = inspectKeyboardFocus(
                workspace,
                size: CGSize(width: 600, height: 720)
            )
            XCTAssertGreaterThanOrEqual(focus.keyViewCount, 3)
            XCTAssertGreaterThan(focus.focusableViewCount, 0)
            XCTAssertTrue(focus.acceptedFirstResponder)

            XCTAssertTrue(RuneScribeCommandCatalog.removesSystemNewItem)
            XCTAssertEqual(RuneScribeCommandCatalog.settings.title, "Settings…")
            XCTAssertEqual(RuneScribeCommandCatalog.settings.command, .openSettings)
            XCTAssertEqual(RuneScribeCommandCatalog.settings.key, .character(","))
            XCTAssertEqual(RuneScribeCommandCatalog.settings.modifiers, [.command])
            XCTAssertEqual(RuneScribeCommandCatalog.cipherLibrary.title, "Cipher Library…")
            XCTAssertEqual(
                RuneScribeCommandCatalog.cipherLibrary.command,
                .openCipherLibrary
            )
            XCTAssertEqual(
                RuneScribeCommandCatalog.cipherLibrary.key,
                .character("l")
            )
            XCTAssertEqual(
                RuneScribeCommandCatalog.cipherLibrary.modifiers,
                [.command, .shift]
            )
            XCTAssertNil(RuneScribeCommandCatalog.primaryAction.command)
            XCTAssertEqual(RuneScribeCommandCatalog.primaryAction.key, .returnKey)
            XCTAssertEqual(
                RuneScribeCommandCatalog.primaryAction.modifiers,
                [.command]
            )
        }
    }

    func testCustomFontSuccessAndFailureProjectThroughRealSession() async throws {
        try await withHarness { harness in
            let productionFontBytes = try productionMoonleafFontBytes()
            let productionFontReference = FontRef(
                id: "mac-custom",
                version: 1,
                sha256: Data(SHA256.hash(data: productionFontBytes))
            )
            let compatibilityScript = try ScriptDescriptor.legacyCompatibility(
                fontRef: productionFontReference
            )
            XCTAssertEqual(compatibilityScript.portability, .fontDependent)
            XCTAssertEqual(compatibilityScript.renderingFont, productionFontReference)
            XCTAssertEqual(
                compatibilityScript.portableAlphabet,
                ScriptDescriptor.baseRune.portableAlphabet
            )

            let validURL = URL(
                fileURLWithPath: "/in-memory-input/mac-valid-custom-font.runescribe"
            )
            let validFixture = try makeCipherFile(
                publicID: Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7]),
                fontID: "mac-custom",
                expectedFontBytes: productionFontBytes,
                suppliedFontBytes: productionFontBytes
            )
            await harness.inboundFiles.set(validFixture, for: validURL)

            let validResult = try await harness.importSelectedFile(validURL)
            XCTAssertEqual(validResult.disposition, .awaitingConfirmation)
            let validPending = try XCTUnwrap(validResult.pendingImport)
            XCTAssertTrue(validPending.includesFont)
            let validPendingObserved = await eventually {
                harness.session.pendingImport?.id == validPending.id
            }
            XCTAssertTrue(validPendingObserved)

            let confirmationPNG = try renderPNG(
                AnyView(
                    ImportConfirmView(
                        pending: validPending,
                        confirmImport: { label in
                            try await harness.session.confirmImport(
                                id: validPending.id,
                                name: label
                            )
                        }
                    )
                ),
                size: CGSize(width: 600, height: 720)
            )
            XCTAssertGreaterThan(confirmationPNG.count, 10_000)
            attachPNG(confirmationPNG, name: "mac-import-confirmation")

            let validOutcome = await ImportConfirmationFlow.attempt(
                label: "Mac Custom Font"
            ) { label in
                try await harness.session.confirmImport(
                    id: validPending.id,
                    name: label
                )
            }
            guard case let .imported(imported) = validOutcome else {
                return XCTFail("The valid custom-font fixture was not imported.")
            }
            XCTAssertTrue(validOutcome.shouldDismiss)
            XCTAssertEqual(imported.label, "Mac Custom Font")
            let importedStateObserved = await eventually {
                harness.session.activeCipher?.label == "Mac Custom Font"
                    && harness.session.ciphers.count == 2
            }
            XCTAssertTrue(importedStateObserved)

            let validDigest = Self.digestHex(productionFontBytes)
            let validPath = try ProtectedPath.fontsDirectory
                .appending("\(validDigest).ttf")
            let persistedValidFont = try await harness.protectedFiles.read(
                relativePath: validPath,
                maximumByteCount: RuneScribePackageResource.maximumDataLength
            )
            XCTAssertEqual(
                persistedValidFont,
                productionFontBytes
            )
            let inspectedPostScriptName = try await harness.fontRegistrar.postScriptName(
                forFontData: productionFontBytes
            )
            XCTAssertEqual(inspectedPostScriptName, Self.moonleafPostScriptName)
            XCTAssertTrue(harness.session.snapshot?.fonts.contains {
                $0.id == FontID(rawValue: "mac-custom")
                    && $0.source == .imported
                    && $0.isRegistered
                    && $0.displayName == Self.moonleafPostScriptName
            } == true)
            let activeImportedCipher = try XCTUnwrap(harness.session.activeCipher)
            XCTAssertEqual(activeImportedCipher.fontSource, .imported)
            XCTAssertTrue(activeImportedCipher.fontIsRegistered)
            XCTAssertEqual(activeImportedCipher.fontName, Self.moonleafPostScriptName)
            XCTAssertEqual(
                harness.session.inscriptionFontPostScriptName,
                Self.moonleafPostScriptName
            )
            XCTAssertTrue(harness.session.inscriptionVectorDataByToken.isEmpty)
            let resolvedFont = try XCTUnwrap(
                NSFont(name: harness.session.inscriptionFontPostScriptName, size: 32)
            )
            XCTAssertEqual(resolvedFont.fontName, Self.moonleafPostScriptName)

            let plaintext = "Moonleaf parity specimen"
            let encoded = try await harness.session.encode(
                plaintext,
                cipherID: activeImportedCipher.id
            )
            let decoded = try await harness.session.decode(encoded.runes)
            XCTAssertEqual(decoded.plaintext, plaintext)
            XCTAssertEqual(decoded.cipherID.rawValue, activeImportedCipher.id)

            let encodedInscription = RuneInscriptionText(
                source: plaintext,
                target: encoded.runes,
                start: .distantPast,
                direction: .encode,
                fontSize: 32,
                fontName: harness.session.inscriptionFontPostScriptName,
                vectorDataByToken: harness.session.inscriptionVectorDataByToken,
                settled: true
            )
            XCTAssertFalse(encodedInscription.usesVectorPresentation)
            let encodedPNG = try renderPNG(
                AnyView(encodedInscription.padding(16)),
                size: CGSize(width: 600, height: 180)
            )
            let decodedPNG = try renderPNG(
                AnyView(
                    RuneInscriptionText(
                        source: encoded.runes,
                        target: decoded.plaintext,
                        start: .distantPast,
                        direction: .decode,
                        fontSize: 32,
                        fontName: harness.session.inscriptionFontPostScriptName,
                        vectorDataByToken: harness.session.inscriptionVectorDataByToken,
                        settled: true
                    )
                    .padding(16)
                ),
                size: CGSize(width: 600, height: 180)
            )
            XCTAssertGreaterThan(encodedPNG.count, 2_000)
            XCTAssertGreaterThan(decodedPNG.count, 2_000)
            attachPNG(encodedPNG, name: "mac-moonleaf-encoded-inscription")
            attachPNG(decodedPNG, name: "mac-moonleaf-decoded-inscription")

            let invalidURL = URL(
                fileURLWithPath: "/in-memory-input/mac-invalid-custom-font.runescribe"
            )
            let expectedInvalidBytes = Data("expected-mac-font".utf8)
            let invalidFixture = try makeCipherFile(
                publicID: Data([0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7]),
                fontID: "mac-rejected",
                expectedFontBytes: expectedInvalidBytes,
                suppliedFontBytes: Data("hash-mismatched-font".utf8)
            )
            await harness.inboundFiles.set(invalidFixture, for: invalidURL)

            let invalidResult = try await harness.importSelectedFile(invalidURL)
            XCTAssertEqual(invalidResult.disposition, .awaitingConfirmation)
            let invalidPending = try XCTUnwrap(invalidResult.pendingImport)
            let invalidPendingObserved = await eventually {
                harness.session.pendingImport?.id == invalidPending.id
            }
            XCTAssertTrue(invalidPendingObserved)

            let invalidOutcome = await ImportConfirmationFlow.attempt(
                label: "Rejected Mac Font"
            ) { label in
                try await harness.session.confirmImport(
                    id: invalidPending.id,
                    name: label
                )
            }
            guard case let .failed(importError) = invalidOutcome else {
                return XCTFail("The hash-mismatched custom font was accepted.")
            }
            XCTAssertFalse(invalidOutcome.shouldDismiss)
            harness.session.importErrorMessage = RuneScribeUISession.message(
                for: importError
            )
            let invalidFailureObserved = await eventually {
                harness.session.pendingImport?.id == invalidPending.id
                    && harness.session.lastError != nil
            }
            XCTAssertTrue(invalidFailureObserved)
            XCTAssertEqual(harness.session.activeCipher?.label, "Mac Custom Font")
            XCTAssertEqual(
                harness.session.ciphers.map(\.label).sorted(),
                ["Mac Custom Font", "My Cipher"]
            )
            XCTAssertFalse(
                RootImportFailurePresentation.shouldShowAlert(
                    message: harness.session.importErrorMessage,
                    hasPendingImport: harness.session.pendingImport != nil,
                    isLocked: harness.session.isLocked,
                    showSplash: false
                )
            )

            let invalidDigest = Self.digestHex(expectedInvalidBytes)
            let invalidPath = try ProtectedPath.fontsDirectory
                .appending("\(invalidDigest).ttf")
            let persistedInvalidFont = try await harness.protectedFiles.read(
                relativePath: invalidPath,
                maximumByteCount: RuneScribePackageResource.maximumDataLength
            )
            XCTAssertNil(persistedInvalidFont)
            let persistedFontPaths = try await harness.protectedFiles.contents(
                of: .fontsDirectory,
                matchingExtension: "ttf"
            )
            XCTAssertEqual(
                persistedFontPaths,
                [validPath]
            )

            try await harness.protectedFiles.remove(relativePath: validPath)
            let unavailableHarness = try await harness.makeRelaunchedHarness()
            do {
                try await unavailableHarness.start()
                let unavailableStateObserved = await eventually {
                    unavailableHarness.session.activeCipher?.label == "Mac Custom Font"
                        && unavailableHarness.session.isLoading == false
                }
                XCTAssertTrue(unavailableStateObserved)
                let unavailableCipher = try XCTUnwrap(
                    unavailableHarness.session.activeCipher
                )
                XCTAssertEqual(unavailableCipher.fontSource, .imported)
                XCTAssertFalse(unavailableCipher.fontIsRegistered)
                XCTAssertNotEqual(
                    unavailableHarness.session.inscriptionFontPostScriptName,
                    Self.moonleafPostScriptName
                )
                XCTAssertEqual(
                    unavailableHarness.session.inscriptionFontPostScriptName,
                    unavailableHarness.session.themeScriptPresentation.fontPostScriptName
                )
                XCTAssertEqual(
                    unavailableHarness.session.inscriptionVectorDataByToken,
                    unavailableHarness.session.themeScriptPresentation.vectorDataByToken
                )
                XCTAssertTrue(
                    ThemeScriptFontSelector.usesThemeVectors(
                        cipherFontSource: unavailableCipher.fontSource,
                        cipherFontIsRegistered: unavailableCipher.fontIsRegistered
                    )
                )
                let fallbackInscription = RuneInscriptionText(
                    source: "A",
                    target: "ᚠ",
                    start: .distantPast,
                    direction: .encode,
                    fontSize: 32,
                    fontName: unavailableHarness.session.inscriptionFontPostScriptName,
                    vectorDataByToken: unavailableHarness.session
                        .inscriptionVectorDataByToken,
                    settled: true
                )
                XCTAssertEqual(
                    fallbackInscription.usesVectorPresentation,
                    !unavailableHarness.session.inscriptionVectorDataByToken.isEmpty
                )
                let fallbackPNG = try renderPNG(
                    AnyView(fallbackInscription.padding(16)),
                    size: CGSize(width: 320, height: 120)
                )
                XCTAssertGreaterThan(fallbackPNG.count, 1_000)
                attachPNG(fallbackPNG, name: "mac-unavailable-font-theme-fallback")
                await unavailableHarness.stop()
            } catch {
                await unavailableHarness.stop()
                throw error
            }
        }
    }

    func testProductionShareControlsRenderAndCoreReleasesScopedArtifacts() async throws {
        try await withHarness { harness in
            let activeCipher = try XCTUnwrap(harness.session.activeCipher)
            let linkArtifact = try await harness.session.prepareCipherShare(
                cipherID: activeCipher.id,
                displayName: activeCipher.label,
                representation: .link
            )
            guard case .opaque = linkArtifact.reference else {
                return XCTFail("The cipher share did not produce an opaque link artifact.")
            }
            let transfer = try await harness.session.shareTransfer(
                for: linkArtifact.id
            )

            let fileArtifact = try await harness.session.prepareCipherShare(
                cipherID: activeCipher.id,
                displayName: activeCipher.label,
                representation: .file
            )
            guard case let .file(fileArtifactID) = fileArtifact.reference else {
                return XCTFail("The cipher share did not produce a file artifact.")
            }
            XCTAssertEqual(fileArtifactID, fileArtifact.id)
            let fileTransfer = try await harness.session.shareTransfer(
                for: fileArtifact.id
            )
            let fileURL = try await harness.shareURL(for: fileArtifact.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            let controlsPNG = try renderPNG(
                AnyView(
                    VStack(spacing: 12) {
                        RuneScribeCipherLinkShareLink(
                            transfer: transfer,
                            cipherLabel: activeCipher.label
                        ) {
                            Label("Share link", systemImage: "link")
                        }
                        RuneScribeFileShareLink(transfer: fileTransfer)
                    }
                    .frame(width: 320, height: 160)
                ),
                size: CGSize(width: 320, height: 160)
            )
            XCTAssertGreaterThan(controlsPNG.count, 4_000)
            attachPNG(controlsPNG, name: "mac-share-controls")

            let cancelledReport = try SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .cancelled
            )
            let linkEvidence = try await transfer.finish(cancelledReport)
            let linkCompletion = try await harness.session.completeShareArtifact(
                evidence: linkEvidence
            )
            let fileEvidence = try await fileTransfer.finish(cancelledReport)
            let fileCompletion = try await harness.session.completeShareArtifact(
                evidence: fileEvidence
            )
            XCTAssertEqual(linkCompletion, .released)
            XCTAssertEqual(fileCompletion, .released)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            do {
                _ = try await harness.session.shareTransfer(for: linkArtifact.id)
                XCTFail("Cancelled share link remained available after Core cleanup.")
            } catch {
                // The opaque link lease was released by Core.
            }
            await transfer.close()
            await fileTransfer.close()
        }
    }

    private func withHarness(
        unavailableThemeResource: ApplicationResource? = nil,
        _ operation: (MacParityHarness) async throws -> Void
    ) async throws {
        let fontURL = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "NotoSansRunic-Regular",
                withExtension: "ttf"
            )
        )
        let harness = try await MacParityHarness(
            bundledFontURL: fontURL,
            unavailableThemeResource: unavailableThemeResource
        )
        do {
            try await harness.start()
            let initialStateObserved = await eventually {
                harness.session.activeCipher?.label == "My Cipher"
                    && harness.session.isLoading == false
            }
            XCTAssertTrue(initialStateObserved)
            try await operation(harness)
            await harness.stop()
        } catch {
            await harness.stop()
            throw error
        }
    }

    private func makeCipherFile(
        publicID: Data,
        fontID: String,
        expectedFontBytes: Data,
        suppliedFontBytes: Data
    ) throws -> Data {
        let cipher = Cipher(
            label: "Fixture",
            origin: .imported,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            publicID: publicID,
            keyMaterial: Data(0 ..< 32),
            decorativeMapping: Array(0 ..< 32),
            fontRef: FontRef(
                id: fontID,
                version: 1,
                sha256: Data(SHA256.hash(data: expectedFontBytes))
            )
        )
        return try CipherSharePayload(cipher: cipher)
            .encodedFile(fontBytes: suppliedFontBytes)
    }

    private func productionMoonleafFontBytes() throws -> Data {
        let url = try XCTUnwrap(
            RuneScribeThemeMoonleafModuleBootstrap.resourceBundle.url(
                forResource: "moonleaf-script-primary",
                withExtension: "ttf"
            )
        )
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, Self.moonleafFontByteCount)
        XCTAssertEqual(Self.digestHex(data), Self.moonleafFontSHA256Hex)
        return data
    }

    private func artifactEvidencePreview(
        title: String,
        plan: ThemeArtifactCompositionPlan,
        presentation: ActiveThemeVisualPresentation
    ) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased())
                    .font(.caption.bold().monospaced())
                    .foregroundStyle(Color.runeGoldBright)
                Text([
                    plan.relicResourceID.rawValue,
                    plan.sealResourceID?.rawValue,
                    plan.frameResourceID?.rawValue,
                    plan.backgroundResourceID.rawValue,
                ].compactMap { $0 }.joined(separator: " • "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.runeSilver)
                    .lineLimit(2)
                ThemeArtifactPreview(
                    plan: plan,
                    image: { presentation.image(for: $0) }
                )
            }
            .padding(16)
            .background(Color.runeNavy)
        )
    }

    private func inspectContentEditingState(
        _ view: AnyView,
        size: CGSize
    ) -> ContentEditingState {
        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        let window = makeInteractiveOffscreenWindow(size: size)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()
        let textView = viewDescendants(of: hostingView)
            .compactMap { $0 as? NSTextView }
            .first(where: { $0.isEditable })
        return ContentEditingState(
            hasEditableTextView: textView != nil,
            text: textView?.string
        )
    }

    private func viewDescendants(of root: NSView) -> [NSView] {
        root.subviews.reduce(into: [root]) { result, child in
            result.append(contentsOf: viewDescendants(of: child))
        }
    }

    private func renderPNG(_ view: AnyView, size: CGSize) throws -> Data {
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func renderPNG(
        _ view: AnyView,
        size: CGSize,
        afterClicking point: CGPoint
    ) throws -> Data {
        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        let window = makeInteractiveOffscreenWindow(size: size)
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()
        _ = try XCTUnwrap(
            hostingView.hitTest(point),
            "The deterministic hosted click did not hit the Vault section control."
        )
        let eventLocation = hostingView.convert(point, to: nil)
        let mouseDown = try hostedMouseEvent(
            type: .leftMouseDown,
            location: eventLocation,
            window: window,
            eventNumber: 1,
            pressure: 1
        )
        let mouseUp = try hostedMouseEvent(
            type: .leftMouseUp,
            location: eventLocation,
            window: window,
            eventNumber: 2,
            pressure: 0
        )
        window.sendEvent(mouseDown)
        window.sendEvent(mouseUp)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func attachPNG(_ data: Data, name: String) {
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertDetailedPNG(
        _ data: Data,
        minimumUniqueSampleColors: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(data: data),
            "The rendered evidence is not a decodable PNG.",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, file: file, line: line)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, file: file, line: line)

        let stepX = max(1, bitmap.pixelsWide / 64)
        let stepY = max(1, bitmap.pixelsHigh / 64)
        var sampledColors = Set<UInt32>()
        var opaqueSampleCount = 0
        var totalSampleCount = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let source = bitmap.colorAt(x: x, y: y),
                      let color = source.usingColorSpace(.deviceRGB)
                else { continue }
                let red = UInt32((color.redComponent * 255).rounded())
                let green = UInt32((color.greenComponent * 255).rounded())
                let blue = UInt32((color.blueComponent * 255).rounded())
                let alpha = UInt32((color.alphaComponent * 255).rounded())
                sampledColors.insert(
                    (red << 24) | (green << 16) | (blue << 8) | alpha
                )
                opaqueSampleCount += alpha >= 250 ? 1 : 0
                totalSampleCount += 1
            }
        }
        XCTAssertGreaterThanOrEqual(
            sampledColors.count,
            minimumUniqueSampleColors,
            "The evidence image lacks the expected visual detail.",
            file: file,
            line: line
        )
        XCTAssertGreaterThan(
            opaqueSampleCount,
            totalSampleCount / 2,
            "Most of the evidence image must contain visible pixels.",
            file: file,
            line: line
        )
    }

    private func assertMaterialPNGChange(
        from baselineData: Data,
        to changedData: Data,
        minimumChangedSampleRatio: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let baseline = try XCTUnwrap(
            NSBitmapImageRep(data: baselineData),
            file: file,
            line: line
        )
        let changed = try XCTUnwrap(
            NSBitmapImageRep(data: changedData),
            file: file,
            line: line
        )
        XCTAssertEqual(baseline.pixelsWide, changed.pixelsWide, file: file, line: line)
        XCTAssertEqual(baseline.pixelsHigh, changed.pixelsHigh, file: file, line: line)

        let stepX = max(1, baseline.pixelsWide / 80)
        let stepY = max(1, baseline.pixelsHigh / 80)
        var sampleCount = 0
        var changedSampleCount = 0
        for y in stride(from: 0, to: baseline.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: baseline.pixelsWide, by: stepX) {
                guard let before = baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let after = changed.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else { continue }
                let componentDelta = abs(before.redComponent - after.redComponent)
                    + abs(before.greenComponent - after.greenComponent)
                    + abs(before.blueComponent - after.blueComponent)
                    + abs(before.alphaComponent - after.alphaComponent)
                changedSampleCount += componentDelta > 0.04 ? 1 : 0
                sampleCount += 1
            }
        }
        XCTAssertGreaterThan(
            Double(changedSampleCount) / Double(max(1, sampleCount)),
            minimumChangedSampleRatio,
            "The hosted interaction did not materially change the rendered surface.",
            file: file,
            line: line
        )
    }

    private func inspectKeyboardFocus(
        _ view: AnyView,
        size: CGSize
    ) -> KeyboardFocusReport {
        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        let window = makeOffscreenWindow(size: size)
        window.contentView = hostingView
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.recalculateKeyViewLoop()

        var chain: [NSView] = []
        var seen: Set<ObjectIdentifier> = []
        var current = window.initialFirstResponder ?? hostingView.nextKeyView
        while let view = current,
              seen.insert(ObjectIdentifier(view)).inserted,
              chain.count < 128 {
            chain.append(view)
            current = view.nextKeyView
        }

        let focusable = chain.filter(\.acceptsFirstResponder)
        let accepted = focusable.first.map(window.makeFirstResponder) ?? false
        return KeyboardFocusReport(
            keyViewCount: chain.count,
            focusableViewCount: focusable.count,
            acceptedFirstResponder: accepted
        )
    }

    private func makeOffscreenWindow(size: CGSize) -> NSWindow {
        let minimumX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minimumY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let window = NSWindow(
            contentRect: NSRect(
                x: minimumX - 10_000,
                y: minimumY - 10_000,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        return window
    }

    private func makeInteractiveOffscreenWindow(size: CGSize) -> NSWindow {
        let minimumX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minimumY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let window = NSWindow(
            contentRect: NSRect(
                x: minimumX - 10_000,
                y: minimumY - 10_000,
                width: size.width,
                height: size.height
            ),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.hasShadow = false
        return window
    }

    private func hostedMouseEvent(
        type: NSEvent.EventType,
        location: CGPoint,
        window: NSWindow,
        eventNumber: Int,
        pressure: Float
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: pressure
            )
        )
    }

    private func inspectWindowResize(
        _ view: AnyView,
        sizes: [CGSize]
    ) throws -> WindowResizeReport {
        _ = NSApplication.shared
        let initialSize = try XCTUnwrap(sizes.first)
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        var renderedSizes: [CGSize] = []
        for size in sizes {
            window.setContentSize(size)
            hostingView.frame = NSRect(origin: .zero, size: size)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
            hostingView.layoutSubtreeIfNeeded()
            hostingView.displayIfNeeded()
            let bitmap = try XCTUnwrap(
                hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
            )
            hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            renderedSizes.append(hostingView.bounds.size)
        }
        return WindowResizeReport(renderedSizes: renderedSizes)
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 2_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let moonleafFontByteCount = 111_892
    private static let moonleafFontSHA256Hex =
        "7fa08b061fbbe897e4305dea1bf456ec87b491a2c34e2df4cf2f6845647f0f3e"
    private static let moonleafPostScriptName = "RavenForgeMoonleafScript-Regular"
}

private struct MacParityPersistentState: Sendable {
    let secureValues = InMemorySecureValueStore()
    let protectedFiles = InMemoryProtectedFileStore()
}

private struct MacParityThemeResourceLocator: ApplicationResourceLocator, Sendable {
    let bundled: BundleApplicationResourceLocator
    let unavailableResource: ApplicationResource?

    func data(for resource: ApplicationResource) async throws -> Data {
        try requireAvailable(resource)
        return try await bundled.data(for: resource)
    }

    func data(
        for resource: ApplicationResource,
        maximumByteCount: Int
    ) async throws -> Data {
        try requireAvailable(resource)
        return try await bundled.data(
            for: resource,
            maximumByteCount: maximumByteCount
        )
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try requireAvailable(resource)
        return try await bundled.url(for: resource)
    }

    private func requireAvailable(_ resource: ApplicationResource) throws {
        guard resource != unavailableResource else {
            throw ApplicationResourceLocatorError.resourceNotFound(resource)
        }
    }
}

@MainActor
private final class MacParityHarness {
    let session: RuneScribeUISession
    let service: RuneScribeCoreApplicationService
    let inboundFiles: InMemoryInboundFileReader
    let protectedFiles: InMemoryProtectedFileStore
    let fontRegistrar: CoreTextFontRegistrar

    private let bundledFontURL: URL
    private let persistentState: MacParityPersistentState
    private let shareArtifacts: AppleShareArtifactStore
    private let runtime: RuneScribeRuntime
    private let temporaryRoot: URL

    init(
        bundledFontURL: URL,
        unavailableThemeResource: ApplicationResource? = nil,
        persistentState: MacParityPersistentState = MacParityPersistentState()
    ) async throws {
        self.bundledFontURL = bundledFontURL
        self.persistentState = persistentState
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuneScribeMacParityTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )

        let secureValues = persistentState.secureValues
        let protectedFiles = persistentState.protectedFiles
        let inboundFiles = InMemoryInboundFileReader()
        let shareArtifacts = AppleShareArtifactStore(
            temporaryDirectory: temporaryRoot.appendingPathComponent(
                "share",
                isDirectory: true
            )
        )
        let resources = MappedApplicationResourceLocator(
            locations: [.bundledRuneFont: bundledFontURL]
        )
        let themeResources = MacParityThemeResourceLocator(
            bundled: BundleApplicationResourceLocator(
                bundle: .main,
                moduleBundles:
                    RuneScribeNorseThemeModuleBootstrap.ownerScopedResourceBundles
            ),
            unavailableResource: unavailableThemeResource
        )
        let fontRegistrar = CoreTextFontRegistrar()
        let contacts = InMemoryContactAccessService(authorizationStatus: .denied)
        let clipboard = InMemoryClipboardService()
        let clock = SystemClock()
        let uuid = SystemUUIDProvider()
        let runtimeIO = RuntimeIOClient(
            secureValueData: {
                try await secureValues.data(service: $0, account: $1)
            },
            setSecureValue: {
                try await secureValues.set($0, service: $1, account: $2)
            },
            deleteSecureValue: {
                try await secureValues.delete(service: $0, account: $1)
            },
            readProtectedFile: {
                try await protectedFiles.read(
                    relativePath: $0,
                    maximumByteCount: $1
                )
            },
            writeProtectedFile: {
                try await protectedFiles.write($0, relativePath: $1)
            },
            removeProtectedFile: {
                try await protectedFiles.remove(relativePath: $0)
            },
            protectedFileExists: {
                try await protectedFiles.exists(relativePath: $0)
            },
            protectedFileContents: {
                try await protectedFiles.contents(of: $0, matchingExtension: $1)
            },
            now: { clock.now() },
            nextUUID: { uuid.nextUUID() },
            clipboardSnapshot: {
                let initialChangeCount = await clipboard.changeCount()
                let initialString = await clipboard.string()
                let finalChangeCount = await clipboard.changeCount()
                return RuntimeClipboardSnapshot(
                    changeCount: finalChangeCount,
                    string: initialChangeCount == finalChangeCount
                        ? initialString
                        : await clipboard.string()
                )
            },
            contactAuthorizationStatus: {
                await contacts.authorizationStatus()
            },
            requestContactAccess: {
                try await contacts.requestAccess()
            },
            fetchSystemContacts: {
                try await contacts.fetchContacts()
            },
            readInboundFile: {
                try await inboundFiles.read(
                    $0.fileURL,
                    requiresSecurityScope: $0.requiresSecurityScopedAccess,
                    maximumByteCount: $0.maximumByteCount
                )
            },
            registerBundledSystemFont: {
                let data = try await resources.data(for: $0)
                guard Data(SHA256.hash(data: data)) == $1 else {
                    throw RuntimeBundledFontFailure.integrityMismatch
                }
                let postScriptName = try await fontRegistrar.postScriptName(
                    forFontData: data
                )
                guard !postScriptName.isEmpty else {
                    throw RuntimeBundledFontFailure.unreadableFont
                }
                return try await fontRegistrar.registerFont(data)
            },
            systemFontPostScriptName: {
                try await fontRegistrar.postScriptName(forFontData: $0)
            },
            registerSystemFont: {
                try await fontRegistrar.registerFont($0)
            },
            createShareArtifact: {
                try await shareArtifacts.create(
                    $0,
                    artifactID: $1,
                    filename: $2,
                    fileExtension: $3
                )
            },
            storeShareArtifactLink: {
                try await shareArtifacts.storeLink($0, artifactID: $1)
            },
            removeShareArtifactLink: {
                try await shareArtifacts.removeLink(artifactID: $0)
            },
            removeShareArtifact: { try await shareArtifacts.remove(artifactID: $0) },
            removeAllShareArtifacts: { try await shareArtifacts.removeAll() }
        )
        let service = RuneScribeCoreApplicationService(runtimeIO: runtimeIO)
        let runtime = RuneScribeRuntime(
            runtimeVersion: MacParityRuntimeModules.version,
            platform: .macOS
        )
        let clientCapture = MacParityApplicationClientCapture()
        try await runtime.installPlatformAdapter(
            themeResources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            fontRegistrar,
            for: RuneScribeServiceKeys.systemFontRegistrar
        )
        try await runtime.installPlatformAdapter(
            clipboard,
            for: RuneScribeServiceKeys.clipboardWrite
        )
        try await runtime.register(
            manifest: MacParityRuntimeModules.coreManifest,
            factory: AnyModuleFactory(
                descriptor: MacParityRuntimeModules.coreDescriptor
            ) {
                MacParityApplicationPublishingModule(service: service)
            }
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: AnyModuleFactory(
                descriptor: RuneScribeUIModuleBootstrap.descriptor
            ) {
                MacParityApplicationClientModule(capture: clientCapture)
            }
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.installPlatformAdapter(
            InMemoryModuleStateStore(),
            for: RuneScribeServiceKeys.moduleStateStore
        )
        try await runtime.installPlatformAdapter(
            inboundFiles,
            for: RuneScribeServiceKeys.inboundFileReader
        )
        try await runtime.start()
        let applicationClient = try await clientCapture.requireClient()
        let uiRuntimeIO = try await clientCapture.requireRuntimeIO()
        let inboundFileImportSession = try await uiRuntimeIO.inboundFileImportSession {
            [applicationClient] input in
            try await applicationClient.importFile(input)
        }

        self.service = service
        self.inboundFiles = inboundFiles
        self.protectedFiles = protectedFiles
        self.fontRegistrar = fontRegistrar
        self.shareArtifacts = shareArtifacts
        self.runtime = runtime
        session = RuneScribeUISession(
            applicationClient: applicationClient,
            runtimeIO: uiRuntimeIO,
            availabilityClient: try await clientCapture.requireAvailabilityClient(),
            themeCoordinatorClient: try await clientCapture.requireThemeCoordinatorClient(),
            runtimeSettingsClient: try await clientCapture.requireRuntimeSettingsClient(),
            inboundFileImportSession: inboundFileImportSession,
            resourcePresentation: RuntimeApplicationResourcePresentation(
                splashVideo: nil,
                metalLibrary: nil
            ),
            productMetadata: RuneScribeUIProductMetadata(
                version: "Parity Test",
                buildNumber: "1"
            )
        )
        try await session.prepareInitialTheme()
    }

    func start() async throws {
        try session.start()
        await service.startInboundProcessing()
    }

    func stop() async {
        await service.stopInboundProcessing()
        await session.stop()
        await runtime.stop()
        try? await shareArtifacts.removeAll()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func shareURL(for artifactID: ShareArtifactID) async throws -> URL {
        try await shareArtifacts.presentationURL(for: artifactID)
    }

    func importSelectedFile(_ fileURL: URL) async throws -> ImportResultDTO {
        try await session.inboundFileImportSession.importSelectedFile(fileURL)
    }

    func makeRelaunchedHarness() async throws -> MacParityHarness {
        try await MacParityHarness(
            bundledFontURL: bundledFontURL,
            persistentState: persistentState
        )
    }
}

private enum MacParityRuntimeModules {
    static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    static let coreID: ModuleIdentifier = "com.runescribe.test.mac-parity-core"
    static let clientID: ModuleIdentifier = "com.runescribe.test.mac-parity-ui"

    static let coreDescriptor = ModuleDescriptor(
        moduleID: coreID,
        moduleVersion: version,
        kind: .service,
        entryPoint: "RuneScribeMacParityCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.inboundInput],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
            RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
    )
    static let clientDescriptor = ModuleDescriptor(
        moduleID: clientID,
        moduleVersion: version,
        kind: .ui,
        entryPoint: "RuneScribeMacParityClientModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.fileImportUI,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        requiredServices: [RuneScribeServiceIDs.sharePresentation],
        requiredModuleRoles: [RuneScribeRoles.core],
        consumedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs
    )

    static let coreManifest = ModuleManifest(
        runtimeVersion: version,
        moduleID: coreID,
        displayName: "Rune Scribe Mac Parity Core",
        moduleVersion: version,
        moduleType: .service,
        criticality: coreDescriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: [RuneScribeCapabilities.inboundInput],
        entryPoint: coreDescriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(),
        defaultRole: RuneScribeRoles.core,
        consumedEndpoints: coreDescriptor.consumedEndpoints.sorted(),
        publishedEndpoints: coreDescriptor.publishedEndpoints.sorted()
    )
    static let clientManifest = ModuleManifest(
        runtimeVersion: version,
        moduleID: clientID,
        displayName: "Rune Scribe Mac Parity UI",
        moduleVersion: version,
        moduleType: .ui,
        criticality: clientDescriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.fileImportUI,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        entryPoint: clientDescriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: [RuneScribeServiceIDs.sharePresentation],
            requiredModuleRoles: [RuneScribeRoles.core]
        ),
        defaultRole: RuneScribeRoles.primaryUI,
        consumedEndpoints: clientDescriptor.consumedEndpoints.sorted(),
        publishedEndpoints: clientDescriptor.publishedEndpoints.sorted()
    )
}

private struct MacParityApplicationPublishingModule: RuneScribeModule {
    let descriptor = MacParityRuntimeModules.coreDescriptor
    let service: RuneScribeCoreApplicationService

    func start(context: ModuleContext) async throws {
        try await context.registerApplicationEndpoints(service)
        try await context.registerInboundInputEndpoint(service)
    }

    func stop() async {}
}

private actor MacParityApplicationClientCapture {
    private var client: RuntimeApplicationClient?
    private var runtimeIO: RuntimeIOClient?
    private var availabilityClient: RuntimeAvailabilityClient?
    private var themeCoordinatorClient: RuntimeThemeCoordinatorClient?
    private var runtimeSettingsClient: RuntimeSettingsClient?

    func store(
        _ client: RuntimeApplicationClient,
        runtimeIO: RuntimeIOClient,
        availabilityClient: RuntimeAvailabilityClient,
        themeCoordinatorClient: RuntimeThemeCoordinatorClient,
        runtimeSettingsClient: RuntimeSettingsClient
    ) {
        self.client = client
        self.runtimeIO = runtimeIO
        self.availabilityClient = availabilityClient
        self.themeCoordinatorClient = themeCoordinatorClient
        self.runtimeSettingsClient = runtimeSettingsClient
    }

    func requireClient() throws -> RuntimeApplicationClient {
        guard let client else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return client
    }

    func requireRuntimeIO() throws -> RuntimeIOClient {
        guard let runtimeIO else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return runtimeIO
    }

    func requireAvailabilityClient() throws -> RuntimeAvailabilityClient {
        guard let availabilityClient else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return availabilityClient
    }

    func requireThemeCoordinatorClient() throws -> RuntimeThemeCoordinatorClient {
        guard let themeCoordinatorClient else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return themeCoordinatorClient
    }

    func requireRuntimeSettingsClient() throws -> RuntimeSettingsClient {
        guard let runtimeSettingsClient else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return runtimeSettingsClient
    }
}

private struct MacParityApplicationClientModule: RuneScribeModule {
    let descriptor = RuneScribeUIModuleBootstrap.descriptor
    let capture: MacParityApplicationClientCapture

    func start(context: ModuleContext) async throws {
        let client = try await context.applicationClient()
        let runtimeIO = try await context.runtimeIOClient()
        let availabilityClient = try await context.runtimeAvailabilityClient()
        let themeCoordinatorClient = try await context.themeCoordinatorClient()
        let runtimeSettingsClient = try await context.runtimeSettingsClient()
        await capture.store(
            client,
            runtimeIO: runtimeIO,
            availabilityClient: availabilityClient,
            themeCoordinatorClient: themeCoordinatorClient,
            runtimeSettingsClient: runtimeSettingsClient
        )
    }

    func stop() async {}
}

private enum MacParityHarnessError: Error {
    case applicationClientUnavailable
}

private struct KeyboardFocusReport {
    let keyViewCount: Int
    let focusableViewCount: Int
    let acceptedFirstResponder: Bool
}

private struct ContentEditingState {
    let hasEditableTextView: Bool
    let text: String?
}

private struct WindowResizeReport {
    let renderedSizes: [CGSize]
}

@MainActor
private struct MacSelectedThemeState: Equatable {
    let revision: UInt64?
    let relicID: ArtifactID?
    let sealID: ArtifactID?
    let frameID: ArtifactID?

    init(session: RuneScribeUISession) {
        revision = session.activeThemeVisualPresentation?.revision
        relicID = session.selectedThemeRelicID
        sealID = session.selectedThemeSealID
        frameID = session.selectedThemeFrameID
    }
}
