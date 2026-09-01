import Foundation
@testable import RuneScribeUIModule
import XCTest

final class ThemeRootRemediationTests: XCTestCase {
    func testEmergencyWarningWaitsForCriticalRootPresentations() {
        XCTAssertTrue(
            RootEmergencyThemeWarningPolicy.shouldShow(
                isEmergencyPresentation: true,
                isDismissed: false,
                showSplash: false,
                isLocked: false,
                hasPendingImport: false,
                hasPendingMessage: false,
                hasActiveReveal: false
            )
        )

        let blockedStates: [(Bool, Bool, Bool, Bool, Bool, Bool)] = [
            (true, false, false, false, false, false),
            (false, true, false, false, false, false),
            (false, false, true, false, false, false),
            (false, false, false, true, false, false),
            (false, false, false, false, true, false),
            (false, false, false, false, false, true),
        ]
        for state in blockedStates {
            XCTAssertFalse(
                RootEmergencyThemeWarningPolicy.shouldShow(
                    isEmergencyPresentation: true,
                    isDismissed: state.0,
                    showSplash: state.1,
                    isLocked: state.2,
                    hasPendingImport: state.3,
                    hasPendingMessage: state.4,
                    hasActiveReveal: state.5
                )
            )
        }
        XCTAssertFalse(
            RootEmergencyThemeWarningPolicy.shouldShow(
                isEmergencyPresentation: false,
                isDismissed: false,
                showSplash: false,
                isLocked: false,
                hasPendingImport: false,
                hasPendingMessage: false,
                hasActiveReveal: false
            )
        )
    }

    func testReceivedCipherOpenCodexRoutesToAppearanceSettings() throws {
        XCTAssertEqual(
            RootReceivedMessageNavigationPolicy.openCodexRoute,
            .openSettings
        )

        let views = viewsDirectory()
        let root = try source("RootView.swift", in: views)
        let received = try source("ReceivedMessageView.swift", in: views)

        XCTAssertTrue(root.contains("onOpenCodex:"))
        XCTAssertTrue(
            root.contains("RootReceivedMessageNavigationPolicy.openCodexRoute")
        )
        XCTAssertTrue(received.contains("onOpenCodex?()"))
        XCTAssertFalse(received.contains("libraryAction: { dismiss() }"))
    }

    func testApplicationShellOwnsRuntimeBackgroundAndHeaderUsesScrim() throws {
        let views = viewsDirectory()
        let root = try source("RootView.swift", in: views)
        let header = try source("RuneTheme.swift", in: views)
        let content = try source("ContentView.swift", in: views)

        XCTAssertTrue(root.contains("RuntimeMetalBackground()"))
        XCTAssertTrue(root.contains(".ignoresSafeArea()"))
        XCTAssertTrue(root.contains(".clipped()"))
        XCTAssertFalse(header.contains("RuntimeMetalBackground()"))
        XCTAssertTrue(header.contains("Color.runeNavy.opacity(0.24)"))
        XCTAssertFalse(content.contains("Color.runeNavy.ignoresSafeArea()"))
        XCTAssertTrue(content.contains("Color.clear.ignoresSafeArea()"))
    }

    func testAccessibilityWorkspaceScrollsBelowAStableHeader() throws {
        let views = viewsDirectory()
        let content = try source("ContentView.swift", in: views)
        let header = try source("RuneTheme.swift", in: views)

        XCTAssertTrue(content.contains("private var workspaceBodyContainer"))
        XCTAssertTrue(content.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(content.contains("GeometryReader { proxy in"))
        XCTAssertTrue(
            content.contains(
                "let viewportWidth: CGFloat? = qualificationViewportWidth ?? proxy.size.width"
            )
        )
        XCTAssertTrue(content.contains("let maximumCanvasWidth = viewportWidth.map"))
        XCTAssertTrue(content.contains("ScrollView {\n                    workspaceBody"))
        XCTAssertTrue(content.contains(".frame(minHeight: proxy.size.height, alignment: .top)"))
        XCTAssertTrue(content.contains(".scrollPosition(id: $initialScrollTarget, anchor: .bottom)"))
        XCTAssertTrue(content.contains(".id(ContentViewInitialViewport.resultActions.rawValue)"))
        XCTAssertTrue(content.contains(".scrollTargetLayout()"))
        XCTAssertTrue(content.contains("workspaceTextFrameMinimumHeight("))
        XCTAssertTrue(content.contains(".scrollDismissesKeyboard(.immediately)"))
        XCTAssertTrue(content.contains(".scrollBounceBehavior(.basedOnSize)"))
        XCTAssertTrue(content.contains("ThemeChromeProtectedContentLayout("))
        XCTAssertTrue(content.contains("panelPixelSize: panelBorderPixelSize"))
        XCTAssertTrue(content.contains("private var panelBorderPixelSize: ThemePixelSize?"))
        XCTAssertTrue(
            content.contains(".themeCaptureViewportIdentifier(composeCaptureIdentifier)")
        )
        XCTAssertFalse(content.contains(".themeCaptureIdentifier(composeCaptureIdentifier)"))
        XCTAssertTrue(content.contains("@FocusState private var inputIsFocused: Bool"))
        XCTAssertTrue(content.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        XCTAssertTrue(content.contains("if inputIsFocused"))
        XCTAssertFalse(content.contains("ToolbarItem(placement: .keyboard)"))
        XCTAssertFalse(content.contains("ToolbarItemGroup(placement: .keyboard)"))
        XCTAssertTrue(content.contains("Button(\"Done\") { inputIsFocused = false }"))
        XCTAssertTrue(content.contains(".accessibilityIdentifier(\"workspace.keyboard.done\")"))
        XCTAssertFalse(header.contains("let id = UUID()"))
        XCTAssertTrue(header.contains("var id: String { \"\\(systemImage).\\(help)\" }"))

        let qualification = try source("ThemeFidelityQualificationRoute.swift", in: views)
        let largeTextStart = try XCTUnwrap(qualification.range(of: "case .largeText:"))
        let largeTextSource = qualification[largeTextStart.lowerBound...]
        XCTAssertTrue(largeTextSource.contains("initialViewport: .resultActions"))
    }

    func testWorkspaceCanvasSizingIncludesMultiPagePreviewChrome() {
        XCTAssertEqual(ContentView.workspaceCanvasVerticalInset(pageCount: nil), 24)
        XCTAssertEqual(ContentView.workspaceCanvasVerticalInset(pageCount: 1), 24)
        XCTAssertEqual(ContentView.workspaceCanvasVerticalInset(pageCount: 2), 78)
        XCTAssertEqual(ContentView.workspaceCanvasVerticalInset(pageCount: 16), 78)

        XCTAssertNil(ContentView.workspaceTextFrameMinimumHeight(
            maximumCanvasWidth: nil,
            pageCount: 1
        ))
        XCTAssertEqual(
            ContentView.workspaceTextFrameMinimumHeight(
                maximumCanvasWidth: 320,
                pageCount: 1
            ),
            264
        )
        XCTAssertEqual(
            ContentView.workspaceTextFrameMinimumHeight(
                maximumCanvasWidth: 320,
                pageCount: 2
            ),
            318
        )
    }

    func testPrimaryPresentationsUseSharedSemanticSurfaces() throws {
        let views = viewsDirectory()
        let theme = try source("RuneTheme.swift", in: views)
        XCTAssertTrue(theme.contains("func runeSemanticPresentationSurface("))
        XCTAssertTrue(theme.contains("Color.runeBackgroundSecondary.opacity(tintOpacity)"))
        XCTAssertTrue(theme.contains(".presentationBackground(.clear)"))
        XCTAssertTrue(theme.contains("case privacy"))

        let standardPresentations = [
            ("SettingsView.swift", views),
            ("CipherLibraryView.swift", views),
            ("ContactsView.swift", views),
            ("VaultProgressView.swift", views),
            ("ImportConfirmView.swift", views),
            ("ReceivedMessageView.swift", views),
            ("ShareBuilderView.swift", sharingDirectory()),
        ]
        for (filename, directory) in standardPresentations {
            let presentation = try source(filename, in: directory)
            XCTAssertTrue(
                presentation.contains(".runeSemanticPresentationSurface()"),
                "\(filename) must preserve the root Theme through a shared semantic surface"
            )
            XCTAssertFalse(
                presentation.contains(".background(Color.runeNavy)"),
                "\(filename) must not replace the root Theme with an opaque legacy background"
            )
        }

        let lock = try source("LockView.swift", in: views)
        XCTAssertTrue(lock.contains(".runeSemanticPresentationSurface(.privacy)"))
        XCTAssertFalse(lock.contains("Color.runeNavy.ignoresSafeArea()"))
    }

    func testEmergencyWarningHasStableAccessibleNonmodalControls() throws {
        let root = try source("RootView.swift", in: viewsDirectory())

        XCTAssertTrue(root.contains("Appearance resources could not be verified."))
        XCTAssertTrue(root.contains("Your ciphers and messages remain available."))
        XCTAssertTrue(root.contains("required-base-theme-warning"))
        XCTAssertTrue(root.contains("accessibilityLabel(accessibilityMessage)"))
        XCTAssertTrue(root.contains("showsDetails.toggle()"))
        XCTAssertTrue(root.contains("Dismiss appearance warning"))
        XCTAssertFalse(root.contains("alert(\"Appearance resources"))
    }

    func testUnlockRevealPrefersVerifiedProviderArtworkWithoutCropping() throws {
        let reveal = try source("UnlockRevealView.swift", in: viewsDirectory())

        XCTAssertTrue(reveal.contains("private var primaryRewardThemeImage: Image?"))
        XCTAssertTrue(reveal.contains("presentation.imageReference(for: $0)?.image"))
        XCTAssertTrue(reveal.contains("if let image = primaryRewardThemeImage"))
        XCTAssertTrue(
            reveal.contains(
                "Image(systemName: reveal.primaryRewardPresentation.fallbackSystemImageName)"
            )
        )
        XCTAssertFalse(reveal.contains(".scaledToFill()"))
        XCTAssertTrue(reveal.contains("ThemeChromeImage(slot: .panelBorder)"))
        XCTAssertTrue(reveal.contains("ThemeChromeProtectedContentLayout("))
        XCTAssertTrue(reveal.contains("panelPixelSize: panelBorderPixelSize"))
        XCTAssertTrue(reveal.contains(".allowsHitTesting(false)"))
        XCTAssertFalse(reveal.contains(".padding(18)"))
    }

    func testPickerVaultAndShareArtworkRemainAspectFit() throws {
        let settings = try source("SettingsView.swift", in: viewsDirectory())
        let vault = try source("VaultProgressView.swift", in: viewsDirectory())
        let share = try source("ShareBuilderView.swift", in: sharingDirectory())

        XCTAssertFalse(settings.contains(".scaledToFill()"))
        XCTAssertFalse(vault.contains(".scaledToFill()"))
        XCTAssertFalse(share.contains(".scaledToFill()"))
        XCTAssertTrue(settings.contains("image.resizable().scaledToFit()"))
        XCTAssertTrue(settings.contains("Text(selected?.name ?? \"None\")"))
        XCTAssertTrue(settings.contains(".layoutPriority(1)"))
        XCTAssertTrue(settings.contains(".contentShape(Rectangle())\n            .accessibilityHidden(true)"))
        XCTAssertTrue(settings.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(settings.contains(".accessibilityValue(selected?.name ?? \"None\")"))
        let effectsDetailStart = try XCTUnwrap(
            settings.range(of: "Text(appearanceEffectsDetail)")
        )
        let defaultsPreviewStart = try XCTUnwrap(
            settings.range(
                of: "appearanceDefaultsPreview",
                range: effectsDetailStart.upperBound..<settings.endIndex
            )
        )
        let effectsDetailSource = String(
            settings[effectsDetailStart.lowerBound..<defaultsPreviewStart.lowerBound]
        )
        XCTAssertTrue(
            effectsDetailSource.contains(".fixedSize(horizontal: false, vertical: true)")
        )
        XCTAssertTrue(vault.contains("image.resizable().scaledToFit()"))
        XCTAssertTrue(share.contains("image.resizable().scaledToFit()"))
    }

    func testShareVaultAndCatalogControlsRemainTruthfulAndActionable() throws {
        let views = viewsDirectory()
        let share = try source("ShareBuilderView.swift", in: sharingDirectory())
        let vault = try source("VaultProgressView.swift", in: views)
        let catalog = try source("CodexCatalogRoot.swift", in: views)
        let assemblies = try source("CodexProductionAssemblies.swift", in: views)

        XCTAssertTrue(share.contains("if let image = renderedPreviewImage"))
        XCTAssertFalse(share.contains("CodexSharePreviewCard("))
        XCTAssertFalse(share.contains("runescribe://message"))

        XCTAssertTrue(vault.contains("let state = activeCodexVisualState(descriptor)"))
        XCTAssertTrue(vault.contains("heading: \"Current Vault State\""))
        XCTAssertTrue(vault.contains("vault-progress.section-picker"))
        XCTAssertTrue(vault.contains("vault-progress.section.\\(item.rawValue.lowercased())"))
        XCTAssertFalse(vault.contains("heading: \"Vault Codex States\""))
        XCTAssertFalse(vault.contains(".frame(height: 760)"))

        XCTAssertTrue(catalog.contains("onGuide: { showsGuide = true }"))
        XCTAssertFalse(catalog.contains("label: \"Codex guide\", action: {}"))
        XCTAssertGreaterThanOrEqual(
            catalog.components(separatedBy: ".disabled(!item.isSelectable)").count - 1,
            2
        )
        XCTAssertTrue(
            assemblies.contains(
                "var selectState: ((CodexVaultCardStateModel) -> Void)? = nil"
            )
        )
    }

    private func viewsDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
            .appendingPathComponent("Views", isDirectory: true)
    }

    private func sharingDirectory() -> URL {
        viewsDirectory()
            .deletingLastPathComponent()
            .appendingPathComponent("Sharing", isDirectory: true)
    }

    private func source(_ filename: String, in directory: URL) throws -> String {
        try String(
            contentsOf: directory.appendingPathComponent(filename),
            encoding: .utf8
        )
    }
}
