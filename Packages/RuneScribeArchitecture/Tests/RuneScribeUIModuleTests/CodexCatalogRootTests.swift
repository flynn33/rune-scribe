@_spi(ThemeFidelityQualification) import RuneScribeContracts
import RuneScribeThemeGloamthornModule
import RuneScribeThemeMoonleafModule
import RuneScribeThemeSunspireModule
import RuneScribeThemeWildwoodModule
@testable import RuneScribeUIModule
import SwiftUI
import XCTest

@MainActor
final class CodexCatalogRootTests: XCTestCase {
    func testCatalogModelMergesDescriptorRelicsAndSealsForEveryElvenProvider() throws {
        for descriptor in descriptors {
            let model = try model(descriptor: descriptor, variant: .featuredSelected)
            let activeRelics = descriptor.codex.relics.filter {
                $0.metadata.availability != .reservedInactive
            }
            let activeSeals = descriptor.codex.seals.filter {
                $0.metadata.availability != .reservedInactive
            }

            XCTAssertEqual(model.relics.count, activeRelics.count)
            XCTAssertEqual(model.seals.count, activeSeals.count)
            XCTAssertEqual(model.defaultRelic?.id, descriptor.codex.defaultRelicID)
            XCTAssertEqual(model.defaultRelic?.state, .selected)
            let defaultRelic = try XCTUnwrap(activeRelics.first(where: {
                $0.metadata.id == descriptor.codex.defaultRelicID
            }))
            XCTAssertEqual(
                model.defaultRelic?.standardResourceID,
                defaultRelic.staticFallbackResourceID
            )
            XCTAssertEqual(
                model.includedSeals.map(\.id),
                activeSeals.filter { $0.metadata.availability == .included }
                    .map { $0.metadata.id }
            )
            XCTAssertTrue(model.requiredCatalogResourceIDs.isSuperset(of: Set(
                activeRelics.map(\.thumbnailResourceID)
                    + activeSeals.map(\.thumbnailResourceID)
            )))
        }
    }

    func testEncounteredAndOwnedSeedsResolveToOneAcquisitionPresentation() {
        let encountered = ThemeFidelityQualificationCatalogBinding.resolve(
            surface: .vaultEncountered
        )
        let owned = ThemeFidelityQualificationCatalogBinding.resolve(
            surface: .vaultOwned
        )

        XCTAssertEqual(encountered, owned)
        XCTAssertEqual(encountered?.initialTab, .relics)
        XCTAssertEqual(encountered?.variant, .acquisition)
        XCTAssertNil(ThemeFidelityQualificationCatalogBinding.resolve(
            surface: .vaultSelected
        ))
    }

    func testAcquisitionModelDoesNotInventProgressOrProviderIdentity() throws {
        for descriptor in descriptors {
            let model = try model(descriptor: descriptor, variant: .acquisition)

            XCTAssertEqual(model.variant, .acquisition)
            XCTAssertEqual(model.primaryActionTitle, "Use This Codex")
            XCTAssertEqual(model.navigationTitle, descriptor.codex.displayName.fallbackValue)
            XCTAssertNil(model.unlockProgress)
            XCTAssertTrue(model.supportingRelics.allSatisfy { $0.state == .locked })
        }
    }

    func testCatalogModelUsesInjectedRuntimeOwnershipSelectionAndProgress() throws {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let progress = try ProgressionNumericProgressDTO(current: 3, target: 5)
        let unlockableRelic = try XCTUnwrap(descriptor.codex.relics.first(where: {
            $0.metadata.availability != .included
                && $0.metadata.availability != .reservedInactive
        }))
        let includedSeal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let runtimeState = ThemeArtifactCatalogRuntimeState(
            stateByArtifactID: [
                descriptor.codex.defaultRelicID: .selected,
                unlockableRelic.metadata.id: .encountered,
                includedSeal.metadata.id: .owned,
            ],
            selectableArtifactIDs: [descriptor.codex.defaultRelicID, includedSeal.metadata.id],
            unlockProgress: progress
        )

        let model = try model(
            descriptor: descriptor,
            variant: .acquisition,
            runtimeState: runtimeState
        )

        XCTAssertEqual(model.defaultRelic?.state, .selected)
        XCTAssertEqual(model.defaultRelic?.isSelectable, true)
        XCTAssertEqual(
            model.relics.first(where: { $0.id == unlockableRelic.metadata.id })?.state,
            .progress
        )
        XCTAssertEqual(
            model.relics.first(where: { $0.id == unlockableRelic.metadata.id })?.isSelectable,
            false
        )
        XCTAssertEqual(
            model.seals.first(where: { $0.id == includedSeal.metadata.id })?.state,
            .owned
        )
        XCTAssertEqual(model.unlockProgress, progress)
    }

    func testProductViewsHaveOrdinaryRuntimeBackedCallSites() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views")
        let content = try String(
            contentsOf: views.appendingPathComponent("ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(content.contains("ActiveThemeCodexCatalogSheet("))
        XCTAssertTrue(content.contains("CodexCatalogRoot("))
        XCTAssertTrue(content.contains("session.activeThemeArtifactCatalogRuntimeState"))
        XCTAssertTrue(content.contains("ThemeInscriptionPreviewView("))
        XCTAssertTrue(content.contains("controls: .settledResult"))
        XCTAssertFalse(content.contains("ThemeFidelityQualificationLaunch"))
    }

    func testCatalogGeometryKeepsLandscapeAndPortraitRelicsContained() {
        let landscape = CodexCatalogMetrics(
            viewportWidth: 941,
            usesAccessibleLayout: false,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )
        let portrait = CodexCatalogMetrics(
            viewportWidth: 941,
            usesAccessibleLayout: false,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 3.0 / 4.0
        )

        XCTAssertEqual(landscape.heroArtworkWidth, 0.60, accuracy: 0.001)
        XCTAssertEqual(landscape.heroDetailsTopInset, 72, accuracy: 0.001)
        XCTAssertEqual(landscape.rowHeight, 302, accuracy: 0.001)
        XCTAssertEqual(portrait.rowHeight, 268, accuracy: 0.001)
        XCTAssertEqual(landscape.primaryActionHeight, 108, accuracy: 0.001)
        XCTAssertEqual(landscape.primaryActionCornerRadius, 54, accuracy: 0.001)
        XCTAssertEqual(landscape.backgroundScrimOpacity, 0.08, accuracy: 0.001)
    }

    func testAcquisitionAndAccessibleMetricsPreserveReadableResponsiveBounds() {
        let acquisition = CodexCatalogMetrics(
            viewportWidth: 941,
            usesAccessibleLayout: false,
            variant: .acquisition,
            featuredRelicAspectRatio: 4.0 / 3.0
        )
        let accessible = CodexCatalogMetrics(
            viewportWidth: 320,
            usesAccessibleLayout: true,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )

        XCTAssertEqual(acquisition.heroDetailsTopInset, 14, accuracy: 0.001)
        XCTAssertEqual(acquisition.backgroundScrimOpacity, 0.14, accuracy: 0.001)
        XCTAssertEqual(accessible.landscapeHeroHeight, 520, accuracy: 0.001)
        XCTAssertEqual(accessible.rowHeight, 240, accuracy: 0.001)
        XCTAssertEqual(accessible.primaryActionHeight, 54, accuracy: 0.001)
        XCTAssertTrue(accessible.usesStackedHero)
    }

    func testCatalogTabAccessibilityStateTracksTheSelectedTab() throws {
        for selection in CodexCatalogTab.allCases {
            for tab in CodexCatalogTab.allCases {
                let state = CodexCatalogTabAccessibilityState(
                    tab: tab,
                    selection: selection
                )
                XCTAssertEqual(state.isSelected, tab == selection)
            }
        }

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/CodexCatalogRoot.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains(".accessibilityAddTraits("))
        XCTAssertTrue(
            source.contains("accessibilityState.isSelected ? .isSelected : []")
        )
    }

    func testCatalogContentWidthIsHardBoundedToTheViewportCrossAxis() {
        let phone = CodexCatalogMetrics(
            viewportWidth: 402,
            usesAccessibleLayout: false,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )
        let narrow = CodexCatalogMetrics(
            viewportWidth: 320,
            usesAccessibleLayout: true,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )
        let wide = CodexCatalogMetrics(
            viewportWidth: 1_366,
            usesAccessibleLayout: false,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )

        XCTAssertEqual(
            phone.contentWidth + phone.outerPadding * 2,
            phone.viewportWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(
            narrow.contentWidth + narrow.outerPadding * 2,
            narrow.viewportWidth,
            accuracy: 0.001
        )
        XCTAssertEqual(wide.contentWidth, wide.maximumContentWidth, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            wide.contentWidth + wide.outerPadding * 2,
            wide.viewportWidth
        )
    }

    func testAccessibilityArtifactRowsStackAndGrowFromAMinimumHeight() {
        let accessible = CodexCatalogMetrics(
            viewportWidth: 320,
            usesAccessibleLayout: true,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )
        let standard = CodexCatalogMetrics(
            viewportWidth: 402,
            usesAccessibleLayout: false,
            variant: .featuredSelected,
            featuredRelicAspectRatio: 4.0 / 3.0
        )

        XCTAssertEqual(accessible.artifactRowLayoutMode, .intrinsicStacked)
        XCTAssertEqual(
            accessible.artifactRowMinimumContentHeight,
            accessible.rowHeight - accessible.panelPadding * 2,
            accuracy: 0.001
        )
        XCTAssertLessThan(
            accessible.stackedArtifactArtworkHeight,
            accessible.artifactRowMinimumContentHeight
        )
        XCTAssertEqual(standard.artifactRowLayoutMode, .boundedHorizontal)
        XCTAssertEqual(
            standard.artifactRowMinimumContentHeight,
            standard.rowHeight - standard.panelPadding * 2,
            accuracy: 0.001
        )
    }

    func testFeaturedRelicAccessibilityUsesTheHardBoundedSummaryFrame() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RuneScribeUIModule/Views/CodexCatalogRoot.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct CodexFeaturedRelic"))
        let end = try XCTUnwrap(
            source.range(
                of: "private struct CodexRelicCanvas",
                range: start.upperBound..<source.endIndex
            )
        )
        let featuredRelic = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(featuredRelic.contains(".frame(width: metrics.contentWidth)"))
        XCTAssertTrue(featuredRelic.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(featuredRelic.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(featuredRelic.contains(".accessibilityLabel(item.accessibilityLabel)"))
        XCTAssertTrue(featuredRelic.contains(".accessibilityValue(item.state.rawValue)"))
        XCTAssertTrue(featuredRelic.contains("codex.catalog.featured-relic"))
    }

    func testPrimaryActionChromeUsesProtectedNineSliceGeometry() throws {
        let insets = CodexPrimaryActionChromeGeometry.capInsets(
            pixelWidth: 1_200,
            pixelHeight: 320
        )

        XCTAssertEqual(insets.top, 104, accuracy: 0.001)
        XCTAssertEqual(insets.leading, 190, accuracy: 0.001)
        XCTAssertEqual(insets.bottom, 104, accuracy: 0.001)
        XCTAssertEqual(insets.trailing, 190, accuracy: 0.001)

        let compactPlan = try XCTUnwrap(CodexPrimaryActionChromeGeometry.renderPlan(
            pixelWidth: 1_200,
            pixelHeight: 320,
            renderedSize: CGSize(width: 360, height: 54)
        ))
        XCTAssertEqual(compactPlan.sourceToRenderedScale, 0.16875, accuracy: 0.001)
        XCTAssertEqual(compactPlan.pixelsPerPoint, 5.925925926, accuracy: 0.001)
        XCTAssertEqual(compactPlan.capInsets.top, 17.55, accuracy: 0.001)
        XCTAssertEqual(compactPlan.capInsets.leading, 32.0625, accuracy: 0.001)
        XCTAssertEqual(
            compactPlan.capInsets.leading * compactPlan.pixelsPerPoint,
            insets.leading,
            accuracy: 0.001
        )
    }

    func testSharedThemeChromeUsesProviderNeutralProtectedNineSliceGeometry() throws {
        let panel = try XCTUnwrap(ThemeChromeNineSliceGeometry.capInsets(
            for: .panelBorder,
            pixelSize: try ThemePixelSize(width: 1_600, height: 1_000)
        ))
        XCTAssertEqual(panel.top, 150, accuracy: 0.001)
        XCTAssertEqual(panel.leading, 170, accuracy: 0.001)
        XCTAssertEqual(panel.bottom, 150, accuracy: 0.001)
        XCTAssertEqual(panel.trailing, 170, accuracy: 0.001)

        let compactPanel = try XCTUnwrap(ThemeChromeNineSliceGeometry.renderPlan(
            for: .panelBorder,
            pixelSize: try ThemePixelSize(width: 1_600, height: 900),
            renderedSize: CGSize(width: 390, height: 640)
        ))
        XCTAssertEqual(compactPanel.sourceToRenderedScale, 0.24375, accuracy: 0.001)
        XCTAssertEqual(compactPanel.pixelsPerPoint, 4.102564103, accuracy: 0.001)
        XCTAssertEqual(compactPanel.capInsets.top, 32.90625, accuracy: 0.001)
        XCTAssertEqual(compactPanel.capInsets.leading, 41.4375, accuracy: 0.001)
        XCTAssertEqual(compactPanel.capInsets.bottom, 32.90625, accuracy: 0.001)
        XCTAssertEqual(compactPanel.capInsets.trailing, 41.4375, accuracy: 0.001)
        XCTAssertEqual(
            compactPanel.capInsets.top * compactPanel.pixelsPerPoint,
            135,
            accuracy: 0.001
        )
        XCTAssertEqual(
            compactPanel.capInsets.leading * compactPanel.pixelsPerPoint,
            170,
            accuracy: 0.001
        )

        let divider = try XCTUnwrap(ThemeChromeNineSliceGeometry.capInsets(
            for: .divider,
            pixelSize: try ThemePixelSize(width: 1_600, height: 128)
        ))
        XCTAssertEqual(divider.top, 48, accuracy: 0.001)
        XCTAssertEqual(divider.leading, 360, accuracy: 0.001)

        let tab = try XCTUnwrap(ThemeChromeNineSliceGeometry.capInsets(
            for: .tabSelector,
            pixelSize: try ThemePixelSize(width: 1_000, height: 240)
        ))
        XCTAssertEqual(tab.top, 76, accuracy: 0.001)
        XCTAssertEqual(tab.leading, 170, accuracy: 0.001)

        XCTAssertNil(ThemeChromeNineSliceGeometry.capInsets(
            for: .cornerOrnament,
            pixelSize: try ThemePixelSize(width: 512, height: 512)
        ))
        XCTAssertNil(ThemeChromeNineSliceGeometry.renderPlan(
            for: .panelBorder,
            pixelSize: try ThemePixelSize(width: 1_600, height: 900),
            renderedSize: .zero
        ))
    }

    func testPanelContentInsetsClearProtectedRailsAtCompactAndRegularWidths() throws {
        let pixelSize = try ThemePixelSize(width: 1_600, height: 900)
        let minimum = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)

        let compact = ThemeChromePanelContentGeometry.protectedInsets(
            pixelSize: pixelSize,
            renderedWidth: 390,
            minimumInsets: minimum
        )
        XCTAssertEqual(compact.top, 36.90625, accuracy: 0.001)
        XCTAssertEqual(compact.leading, 45.4375, accuracy: 0.001)
        XCTAssertEqual(compact.bottom, 36.90625, accuracy: 0.001)
        XCTAssertEqual(compact.trailing, 45.4375, accuracy: 0.001)

        let regular = ThemeChromePanelContentGeometry.protectedInsets(
            pixelSize: pixelSize,
            renderedWidth: 760,
            minimumInsets: minimum
        )
        XCTAssertEqual(regular.top, 68.125, accuracy: 0.001)
        XCTAssertEqual(regular.leading, 84.75, accuracy: 0.001)
        XCTAssertGreaterThan(
            regular.leading,
            compact.leading,
            "wider panels must keep content beyond proportionally wider rails"
        )

        let norseCatalogCard = ThemeChromePanelContentGeometry.protectedInsets(
            pixelSize: pixelSize,
            renderedWidth: 172,
            minimumInsets: EdgeInsets()
        )
        XCTAssertEqual(norseCatalogCard.top, 18.5125, accuracy: 0.001)
        XCTAssertEqual(norseCatalogCard.leading, 22.275, accuracy: 0.001)
        XCTAssertEqual(norseCatalogCard.bottom, 18.5125, accuracy: 0.001)
        XCTAssertEqual(norseCatalogCard.trailing, 22.275, accuracy: 0.001)

        let elvenCatalogCard = ThemeChromePanelContentGeometry.protectedInsets(
            pixelSize: try ThemePixelSize(width: 1_600, height: 1_000),
            renderedWidth: 172,
            minimumInsets: EdgeInsets()
        )
        XCTAssertEqual(elvenCatalogCard.top, 20.125, accuracy: 0.001)
        XCTAssertEqual(elvenCatalogCard.leading, 22.275, accuracy: 0.001)

        XCTAssertEqual(
            ThemeChromePanelContentGeometry.protectedInsets(
                pixelSize: nil,
                renderedWidth: 390,
                minimumInsets: minimum
            ).leading,
            minimum.leading
        )
    }

    private var descriptors: [ThemeDescriptor] {
        [
            GloamthornThemeDescriptorFactory.discoveryDescriptor,
            MoonleafThemeDescriptorFactory.discoveryDescriptor,
            SunspireThemeDescriptorFactory.discoveryDescriptor,
            WildwoodThemeDescriptorFactory.discoveryDescriptor,
        ]
    }

    private func model(
        descriptor: ThemeDescriptor,
        variant: CodexCatalogVariant,
        runtimeState: ThemeArtifactCatalogRuntimeState? = nil
    ) throws -> CodexCatalogContentModel {
        let defaultSeal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let selection = try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: true,
            providerAvailable: true,
            ownedArtifactIDs: [],
            relicID: descriptor.codex.defaultRelicID,
            sealID: defaultSeal.metadata.id,
            frameID: nil
        )
        let plan = try ActiveThemeVisualResourcePlan(
            descriptor: descriptor,
            revision: 1,
            selection: selection
        )
        return CodexCatalogContentModel(
            descriptor: descriptor,
            visualPlan: plan,
            variant: variant,
            runtimeState: runtimeState
        )
    }
}
