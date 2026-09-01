import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

enum CodexCatalogTab: String, CaseIterable, Equatable, Sendable {
    case relics = "Relics"
    case seals = "Seals"
}

struct CodexCatalogTabAccessibilityState: Equatable, Sendable {
    let isSelected: Bool

    init(tab: CodexCatalogTab, selection: CodexCatalogTab) {
        isSelected = tab == selection
    }
}

enum CodexCatalogVariant: Equatable, Sendable {
    /// The currently selected Codex, with its default Relic featured first.
    case featuredSelected

    /// The acquisition presentation used after a Codex has been encountered.
    /// Encountered and owned qualification seeds intentionally resolve to this
    /// one visual state because their canonical authority is byte-identical.
    case acquisition
}

struct CodexCatalogItemModel: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let name: String
    let summary: String
    let facets: [String]
    let kind: ThemeVisualArtifactKind
    let rarity: ThemeRarityToken
    let availability: ThemeArtifactAvailability
    let state: ThemeVisualContentState
    let ordinal: Int
    let isDefault: Bool
    let thumbnailResourceID: ThemeResourceID
    let standardResourceID: ThemeResourceID
    let accessibilityLabel: String
    let accessibilityHint: String?
    let isSelectable: Bool
}

struct CodexCatalogContentModel: Equatable, Sendable {
    let title: String
    let summary: String
    let relics: [CodexCatalogItemModel]
    let seals: [CodexCatalogItemModel]
    let variant: CodexCatalogVariant
    let unlockProgress: ProgressionNumericProgressDTO?

    init(
        descriptor: ThemeDescriptor,
        visualPlan: ActiveThemeVisualResourcePlan,
        variant: CodexCatalogVariant,
        runtimeState: ThemeArtifactCatalogRuntimeState? = nil
    ) {
        precondition(descriptor.codex.id == visualPlan.codexID)
        self.title = descriptor.codex.displayName.fallbackValue
        self.summary = descriptor.codex.longDescription.fallbackValue
        self.variant = variant
        unlockProgress = runtimeState?.unlockProgress

        let firstUnlockableRelicID = visualPlan.relics.first(where: {
            $0.availability != .included
        })?.id
        relics = visualPlan.relics.enumerated().map { index, artifact in
            let isDefault = artifact.id == descriptor.codex.defaultRelicID
            var state = runtimeState?.stateByArtifactID[artifact.id]
                ?? Self.contentState(
                    availability: artifact.availability,
                    isSelected: artifact.id == visualPlan.selectedRelicID
                )
            if variant == .acquisition,
               artifact.id == firstUnlockableRelicID,
               let progress = runtimeState?.unlockProgress,
               progress.current > 0,
               !progress.isComplete,
               state != .owned,
               state != .selected {
                state = .progress
            }
            return Self.item(
                artifact,
                state: state,
                ordinal: index + 1,
                isDefault: isDefault,
                isSelectable: runtimeState?.selectableArtifactIDs.contains(artifact.id)
                    ?? Self.isSelectable(state)
            )
        }
        seals = visualPlan.seals.enumerated().map { index, artifact in
            let state = runtimeState?.stateByArtifactID[artifact.id]
                ?? Self.contentState(
                    availability: artifact.availability,
                    isSelected: artifact.id == visualPlan.selectedSealID
                )
            return Self.item(
                artifact,
                state: state,
                ordinal: index + 1,
                isDefault: false,
                isSelectable: runtimeState?.selectableArtifactIDs.contains(artifact.id)
                    ?? Self.isSelectable(state)
            )
        }
    }

    var defaultRelic: CodexCatalogItemModel? {
        relics.first(where: \.isDefault)
    }

    var supportingRelics: [CodexCatalogItemModel] {
        relics.filter { !$0.isDefault }
    }

    var includedSeals: [CodexCatalogItemModel] {
        seals.filter { $0.availability == .included }
    }

    var unlockableSeals: [CodexCatalogItemModel] {
        seals.filter { $0.availability != .included }
    }

    var primaryActionTitle: String {
        switch variant {
        case .featuredSelected:
            "View \(title)"
        case .acquisition:
            "Use This Codex"
        }
    }

    var moduleSummary: String {
        switch variant {
        case .featuredSelected:
            "Use this Codex's relics and seals across all of your ciphers."
        case .acquisition:
            "Unlock this Codex to use its relic and seals across all of your ciphers."
        }
    }

    var navigationTitle: String {
        title
    }

    var requiredCatalogResourceIDs: Set<ThemeResourceID> {
        Set(relics.map(\.thumbnailResourceID) + seals.map(\.thumbnailResourceID))
            .union(defaultRelic.map { [$0.standardResourceID] } ?? [])
    }

    private static func item(
        _ artifact: ThemeArtifactVisualPlan,
        state: ThemeVisualContentState,
        ordinal: Int,
        isDefault: Bool,
        isSelectable: Bool
    ) -> CodexCatalogItemModel {
        CodexCatalogItemModel(
            id: artifact.id,
            name: artifact.displayName,
            summary: artifact.description,
            facets: artifact.facets,
            kind: artifact.kind,
            rarity: artifact.rarity,
            availability: artifact.availability,
            state: state,
            ordinal: ordinal,
            isDefault: isDefault,
            thumbnailResourceID: artifact.thumbnail.id,
            standardResourceID: artifact.standard.id,
            accessibilityLabel: artifact.accessibilityLabel,
            accessibilityHint: artifact.accessibilityHint,
            isSelectable: isSelectable
        )
    }

    private static func contentState(
        availability: ThemeArtifactAvailability,
        isSelected: Bool
    ) -> ThemeVisualContentState {
        if isSelected { return .selected }
        switch availability {
        case .included:
            return .owned
        case .encountered:
            return .encountered
        case .earned, .mastery:
            return .locked
        case .reservedInactive:
            return .unavailable
        }
    }

    private static func isSelectable(_ state: ThemeVisualContentState) -> Bool {
        state == .owned || state == .selected
    }
}

/// Production Codex catalog shared by interactive pickers and deterministic
/// qualification. Layout and state are provider-neutral; every image comes
/// from the active runtime-admitted descriptor revision.
@MainActor
struct CodexCatalogRoot: View {
    let descriptor: ThemeDescriptor
    let presentation: ActiveThemeVisualPresentation
    let model: CodexCatalogContentModel
    let onDismiss: () -> Void
    let onSelectRelic: (ArtifactID) -> Void
    let onSelectSeal: (ArtifactID) -> Void
    let onClearSeal: (() -> Void)?
    let onPrimaryAction: () -> Void

    @State private var selectedTab: CodexCatalogTab
    @State private var showsGuide = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    init(
        descriptor: ThemeDescriptor,
        presentation: ActiveThemeVisualPresentation,
        initialTab: CodexCatalogTab = .relics,
        variant: CodexCatalogVariant = .featuredSelected,
        runtimeState: ThemeArtifactCatalogRuntimeState? = nil,
        onDismiss: @escaping () -> Void = {},
        onSelectRelic: @escaping (ArtifactID) -> Void = { _ in },
        onSelectSeal: @escaping (ArtifactID) -> Void = { _ in },
        onClearSeal: (() -> Void)? = nil,
        onPrimaryAction: @escaping () -> Void = {}
    ) {
        self.descriptor = descriptor
        self.presentation = presentation
        self.model = CodexCatalogContentModel(
            descriptor: descriptor,
            visualPlan: presentation.plan,
            variant: variant,
            runtimeState: runtimeState
        )
        self.onDismiss = onDismiss
        self.onSelectRelic = onSelectRelic
        self.onSelectSeal = onSelectSeal
        self.onClearSeal = onClearSeal
        self.onPrimaryAction = onPrimaryAction
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = CodexCatalogMetrics(
                viewportWidth: geometry.size.width,
                usesAccessibleLayout: dynamicTypeSize.isAccessibilitySize,
                variant: model.variant,
                featuredRelicAspectRatio: featuredRelicAspectRatio
            )
            ScrollView {
                VStack(spacing: metrics.sectionSpacing) {
                    CodexNavigationChrome(
                        title: model.navigationTitle,
                        metrics: metrics,
                        onDismiss: onDismiss,
                        onGuide: { showsGuide = true }
                    )

                    CodexPicker(
                        selection: $selectedTab,
                        metrics: metrics
                    )
                    .frame(maxWidth: metrics.pickerMaximumWidth)

                    switch selectedTab {
                    case .relics:
                        relicCatalog(metrics: metrics)
                    case .seals:
                        sealCatalog(metrics: metrics)
                    }
                }
                .frame(width: metrics.contentWidth)
                .padding(.horizontal, metrics.outerPadding)
                .padding(.top, metrics.topPadding)
                .padding(.bottom, metrics.bottomPadding)
                .frame(width: geometry.size.width)
            }
            .scrollIndicators(.hidden)
            .frame(
                width: geometry.size.width,
                height: geometry.size.height
            )
            .background {
                catalogBackground(
                    metrics: metrics,
                    viewportSize: geometry.size
                )
            }
            .clipped()
            .background {
                Color.clear
                    .accessibilityElement()
                    .accessibilityLabel("Codex catalog")
                    .accessibilityIdentifier("codex.catalog.root")
                    .allowsHitTesting(false)
            }
            .runtimeViewportFrameProbe("codex.catalog.root")
        }
        .sheet(isPresented: $showsGuide) {
            CodexGuideSheet(
                title: descriptor.codex.displayName.fallbackValue,
                summary: descriptor.codex.longDescription.fallbackValue,
                relicCount: model.relics.count,
                sealCount: model.seals.count
            )
        }
    }

    @ViewBuilder
    private func relicCatalog(metrics: CodexCatalogMetrics) -> some View {
        if let featured = model.defaultRelic {
            if featured.isSelectable {
                Button {
                    onSelectRelic(featured.id)
                } label: {
                    featuredRelic(featured, metrics: metrics)
                }
                .buttonStyle(.plain)
            } else {
                featuredRelic(featured, metrics: metrics)
            }
        }

        if model.variant == .acquisition {
            CodexAcquisitionRelicList(
                items: model.supportingRelics,
                presentation: presentation,
                metrics: metrics,
                unlockProgress: model.unlockProgress,
                select: onSelectRelic
            )
        } else {
            ForEach(model.supportingRelics) { item in
                CodexArtifactRow(
                    item: item,
                    metrics: metrics,
                    action: { onSelectRelic(item.id) }
                ) {
                    catalogImage(item.thumbnailResourceID, kind: .relic)
                }
            }
        }

        if model.variant == .acquisition {
            CodexIncludedSealSummary(
                seals: model.includedSeals,
                presentation: presentation,
                metrics: metrics,
                clearSelection: nil,
                select: onSelectSeal
            )

            CodexPanel(metrics: metrics) {
                HStack(spacing: metrics.compactSpacing) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: metrics.moduleIconSize, weight: .regular))
                        .foregroundStyle(Color.runeGold)
                        .frame(
                            width: metrics.moduleIconFrame,
                            height: metrics.moduleIconFrame
                        )
                        .background(Circle().fill(Color.runeNavy.opacity(0.45)))
                        .overlay {
                            Circle().strokeBorder(
                                Color.runeGold.opacity(0.48),
                                lineWidth: 1
                            )
                        }
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: metrics.microSpacing) {
                        Text("Theme Module")
                            .font(.system(size: metrics.supportingTitleSize, design: .serif))
                            .foregroundStyle(Color.runeTextPrimary)
                        Text(model.moduleSummary)
                            .font(.system(size: metrics.bodySize, design: .serif))
                            .foregroundStyle(Color.runeSilver)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        CodexPrimaryAction(
            title: model.primaryActionTitle,
            presentation: presentation,
            metrics: metrics,
            action: onPrimaryAction
        )
    }

    private func featuredRelic(
        _ item: CodexCatalogItemModel,
        metrics: CodexCatalogMetrics
    ) -> some View {
        CodexFeaturedRelic(
            item: item,
            descriptor: descriptor,
            presentation: presentation,
            showsOwnedBadge: model.variant == .acquisition,
            metrics: metrics
        )
    }

    private func sealCatalog(metrics: CodexCatalogMetrics) -> some View {
        VStack(spacing: metrics.sectionSpacing) {
            CodexSealSection(
                title: "Included Seals",
                items: model.includedSeals,
                presentation: presentation,
                metrics: metrics,
                clearSelection: onClearSeal,
                select: onSelectSeal
            )
            if !model.unlockableSeals.isEmpty {
                CodexSealSection(
                    title: "Unlockable Seals",
                    items: model.unlockableSeals,
                    presentation: presentation,
                    metrics: metrics,
                    clearSelection: nil,
                    select: onSelectSeal
                )
            }
            CodexPrimaryAction(
                title: model.primaryActionTitle,
                presentation: presentation,
                metrics: metrics,
                action: onPrimaryAction
            )
        }
    }

    @ViewBuilder
    private func catalogImage(
        _ resourceID: ThemeResourceID,
        kind: ThemeVisualArtifactKind
    ) -> some View {
        if let image = presentation.image(for: resourceID) {
            image
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            ThemeVisualPlaceholder(
                systemImage: kind.systemImage,
                label: "\(kind.rawValue) artwork unavailable"
            )
        }
    }

    @ViewBuilder
    private func catalogBackground(
        metrics: CodexCatalogMetrics,
        viewportSize: CGSize
    ) -> some View {
        ZStack {
            if let image = presentation.image(for: backgroundImagePlan.id) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(
                        width: viewportSize.width,
                        height: viewportSize.height
                    )
                    .clipped()
            }
            Color.runeNavy.opacity(metrics.backgroundScrimOpacity)
        }
        .frame(width: viewportSize.width, height: viewportSize.height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var backgroundImagePlan: ThemeVisualImagePlan {
        if colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast {
            return presentation.plan.backgroundHighContrast
        }
        if accessibilityReduceMotion || accessibilityPreferences.forcesReduceMotion {
            return presentation.plan.backgroundReduceMotion
        }
        return presentation.plan.backgroundStatic
    }

    private var featuredRelicAspectRatio: Double? {
        guard let featured = model.defaultRelic,
              let visual = presentation.plan.relics.first(where: {
                  $0.id == featured.id
              }),
              let pixels = [visual.standard, visual.thumbnail, visual.primary]
                  .first(where: { $0.id == featured.standardResourceID })?.pixelSize
        else { return nil }
        return Double(pixels.width) / Double(pixels.height)
    }
}

struct CodexCatalogMetrics: Equatable {
    let viewportWidth: CGFloat
    let usesAccessibleLayout: Bool
    let variant: CodexCatalogVariant
    let featuredRelicAspectRatio: Double?

    init(
        viewportWidth: CGFloat,
        usesAccessibleLayout: Bool,
        variant: CodexCatalogVariant,
        featuredRelicAspectRatio: Double? = nil
    ) {
        self.viewportWidth = viewportWidth
        self.usesAccessibleLayout = usesAccessibleLayout
        self.variant = variant
        self.featuredRelicAspectRatio = featuredRelicAspectRatio
    }

    private var normalizedWidth: CGFloat {
        min(max(320, viewportWidth), 941)
    }

    var scale: CGFloat { normalizedWidth / 941 }
    var maximumContentWidth: CGFloat { 941 }
    var outerPadding: CGFloat { max(12, 31 * scale) }
    var contentWidth: CGFloat {
        max(0, min(maximumContentWidth, viewportWidth - outerPadding * 2))
    }
    var topPadding: CGFloat { max(8, 14 * scale) }
    var bottomPadding: CGFloat { max(20, 32 * scale) }
    var sectionSpacing: CGFloat {
        max(10, (variant == .acquisition ? 15 : 22) * scale)
    }
    var compactSpacing: CGFloat { max(8, 18 * scale) }
    var microSpacing: CGFloat { max(4, 8 * scale) }
    var headerHeight: CGFloat {
        max(88, (variant == .acquisition ? 128 : 140) * scale)
    }
    var navigationButtonSize: CGFloat { max(48, 80 * scale) }
    var eyebrowSize: CGFloat { max(13, 27 * scale) }
    var titleSize: CGFloat { max(23, 49 * scale) }
    var pickerHeight: CGFloat { max(50, 78 * scale) }
    var pickerFontSize: CGFloat { max(18, 32 * scale) }
    var pickerMaximumWidth: CGFloat { min(viewportWidth, max(300, 670 * scale)) }
    var panelRadius: CGFloat { max(12, 26 * scale) }
    var panelPadding: CGFloat {
        max(12, (variant == .acquisition ? 20 : 22) * scale)
    }
    var landscapeHeroHeight: CGFloat {
        if usesAccessibleLayout { return max(520, 610 * scale) }
        return max(255, (variant == .acquisition ? 387 : 540) * scale)
    }
    var portraitHeroHeight: CGFloat {
        if usesAccessibleLayout { return max(560, 680 * scale) }
        return max(310, (variant == .acquisition ? 420 : 610) * scale)
    }
    var heroArtworkWidth: CGFloat { usesAccessibleLayout ? 1 : 0.60 }
    var heroDetailsTopInset: CGFloat {
        max(12, (variant == .acquisition ? 14 : 72) * scale)
    }
    var heroTitleSize: CGFloat { max(24, 40 * scale) }
    var supportingTitleSize: CGFloat { max(18, 32 * scale) }
    var statusSize: CGFloat { max(14, 25 * scale) }
    var bodySize: CGFloat { max(14, 25 * scale) }
    var captionSize: CGFloat { max(12, 20 * scale) }
    var rowHeight: CGFloat {
        if usesAccessibleLayout { return max(240, 420 * scale) }
        return max(145, (featuredRelicIsPortrait ? 268 : 302) * scale)
    }
    var artifactRowLayoutMode: CodexArtifactRowLayoutMode {
        usesAccessibleLayout ? .intrinsicStacked : .boundedHorizontal
    }
    var artifactRowMinimumContentHeight: CGFloat {
        max(1, rowHeight - panelPadding * 2)
    }
    var stackedArtifactArtworkHeight: CGFloat {
        max(132, rowHeight * 0.55)
    }
    var acquisitionRowHeight: CGFloat { max(118, 144 * scale) }
    var acquisitionArtworkWidth: CGFloat { max(92, 154 * scale) }
    var rowArtworkWidth: CGFloat { usesAccessibleLayout ? 0.30 : 0.31 }
    var sealCardHeight: CGFloat {
        max(132, (variant == .acquisition ? 164 : 230) * scale)
    }
    var primaryActionHeight: CGFloat { max(54, 108 * scale) }
    var primaryActionFontSize: CGFloat { max(21, 39 * scale) }
    var primaryActionCornerRadius: CGFloat { primaryActionHeight / 2 }
    var tagPadding: CGFloat { max(7, 13 * scale) }
    var moduleIconSize: CGFloat { max(25, 50 * scale) }
    var moduleIconFrame: CGFloat { max(48, 86 * scale) }
    var usesStackedHero: Bool { usesAccessibleLayout || viewportWidth < 350 }
    var backgroundScrimOpacity: Double { variant == .acquisition ? 0.14 : 0.08 }
    var featuredRelicIsPortrait: Bool {
        guard let featuredRelicAspectRatio else { return false }
        return featuredRelicAspectRatio < 1
    }
}

enum CodexArtifactRowLayoutMode: Equatable {
    case boundedHorizontal
    case intrinsicStacked
}

private struct CodexNavigationChrome: View {
    let title: String
    let metrics: CodexCatalogMetrics
    let onDismiss: () -> Void
    let onGuide: () -> Void

    var body: some View {
        HStack(spacing: metrics.compactSpacing) {
            navigationButton(systemImage: "arrow.left", label: "Back", action: onDismiss)
            VStack(spacing: metrics.microSpacing) {
                Text("Rune Scribe")
                    .font(.system(size: metrics.eyebrowSize, design: .serif))
                    .foregroundStyle(Color.runeSilver)
                Text(title)
                    .font(.system(size: metrics.titleSize, design: .serif))
                    .foregroundStyle(Color.runeTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity)
            navigationButton(
                systemImage: "book.closed",
                label: "Codex guide",
                action: onGuide
            )
        }
        .frame(height: metrics.headerHeight)
        .overlay(alignment: .bottom) {
            ZStack {
                Rectangle()
                    .fill(Color.runeGold.opacity(0.25))
                    .frame(height: 1)
                ThemeChromeImage(slot: .divider)
                    .frame(height: max(8, 14 * metrics.scale))
                    .opacity(0.22)
            }
            .allowsHitTesting(false)
        }
    }

    private func navigationButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(
                    size: max(18, 31 * metrics.scale),
                    weight: .light
                ))
                .foregroundStyle(Color.runeTextPrimary)
                .frame(
                    width: metrics.navigationButtonSize,
                    height: metrics.navigationButtonSize
                )
                .background(Circle().fill(Color.runeNavy.opacity(0.58)))
                .overlay {
                    Circle().strokeBorder(Color.runeGold.opacity(0.55), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct CodexGuideSheet: View {
    let title: String
    let summary: String
    let relicCount: Int
    let sealCount: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(title)
                        .font(.title.bold())
                        .foregroundStyle(Color.runeTextPrimary)
                    Text(summary)
                        .font(.body)
                        .foregroundStyle(Color.runeSilver)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("\(relicCount) relics", systemImage: "rectangle.portrait")
                    Label("\(sealCount) seals", systemImage: "seal")
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(RuneMetrics.pad)
            }
            .background(Color.runeNavy)
            .navigationTitle("Codex Guide")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityIdentifier("codex.catalog.guide")
    }
}

private struct CodexPicker: View {
    @Binding var selection: CodexCatalogTab
    let metrics: CodexCatalogMetrics

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CodexCatalogTab.allCases, id: \.self) { tab in
                let accessibilityState = CodexCatalogTabAccessibilityState(
                    tab: tab,
                    selection: selection
                )
                Button {
                    selection = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: metrics.pickerFontSize, design: .serif))
                        .foregroundStyle(
                            selection == tab ? Color.runeTextPrimary : Color.runeSilver
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background {
                            if selection == tab {
                                ZStack {
                                    RoundedRectangle(
                                        cornerRadius: metrics.panelRadius,
                                        style: .continuous
                                    )
                                    .fill(Color.runeSurfaceElevated.opacity(0.90))
                                    ThemeChromeImage(slot: .tabSelector)
                                        .opacity(0.24)
                                }
                                .clipShape(RoundedRectangle(
                                    cornerRadius: metrics.panelRadius,
                                    style: .continuous
                                ))
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(
                    accessibilityState.isSelected ? .isSelected : []
                )
                .accessibilityIdentifier("codex.catalog.tab.\(tab.rawValue.lowercased())")
            }
        }
        .frame(height: metrics.pickerHeight)
        .background(Color.runeNavy.opacity(0.72))
        .clipShape(RoundedRectangle(
            cornerRadius: metrics.panelRadius,
            style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.panelRadius, style: .continuous)
                .strokeBorder(Color.runeGold.opacity(0.52), lineWidth: 1)
        }
    }
}

private struct CodexPanel<Content: View>: View {
    let metrics: CodexCatalogMetrics
    private let content: Content

    init(
        metrics: CodexCatalogMetrics,
        @ViewBuilder content: () -> Content
    ) {
        self.metrics = metrics
        self.content = content()
    }

    var body: some View {
        content
            .padding(metrics.panelPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Color.runeNavy.opacity(0.88)
                    Color.runeParchment.opacity(0.52)
                }
            }
            .clipShape(RoundedRectangle(
                cornerRadius: metrics.panelRadius,
                style: .continuous
            ))
            .overlay {
                RoundedRectangle(cornerRadius: metrics.panelRadius, style: .continuous)
                    .strokeBorder(Color.runeGold.opacity(0.34), lineWidth: 1)
            }
            .overlay {
                ThemeChromeImage(slot: .panelBorder)
                    .opacity(0.04)
                    .clipShape(RoundedRectangle(
                        cornerRadius: metrics.panelRadius,
                        style: .continuous
                    ))
                    .allowsHitTesting(false)
            }
    }
}

private struct CodexFeaturedRelic: View {
    let item: CodexCatalogItemModel
    let descriptor: ThemeDescriptor
    let presentation: ActiveThemeVisualPresentation
    let showsOwnedBadge: Bool
    let metrics: CodexCatalogMetrics

    var body: some View {
        let heroHeight = resolvedHeroHeight
        Group {
            if showsOwnedBadge {
                CodexPanel(metrics: metrics) {
                    heroContent(height: heroHeight)
                }
            } else {
                heroContent(height: heroHeight)
            }
        }
        .frame(width: metrics.contentWidth)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.state.rawValue)
        .accessibilityHint(item.accessibilityHint ?? "")
        .accessibilityIdentifier("codex.catalog.featured-relic")
    }

    @ViewBuilder
    private func heroContent(height: CGFloat) -> some View {
        Group {
            if metrics.usesStackedHero {
                VStack(alignment: .leading, spacing: metrics.compactSpacing) {
                    CodexRelicCanvas(
                        item: item,
                        descriptor: descriptor,
                        presentation: presentation
                    )
                    .frame(height: height * 0.58)
                    details
                }
            } else {
                HStack(alignment: .top, spacing: metrics.panelPadding) {
                    CodexRelicCanvas(
                        item: item,
                        descriptor: descriptor,
                        presentation: presentation
                    )
                    .frame(width: resolvedArtworkWidth, height: height)
                    .layoutPriority(1)
                    details
                        .frame(
                            width: resolvedDetailsWidth,
                            alignment: .leading
                        )
                        .padding(.top, metrics.heroDetailsTopInset)
                }
            }
        }
        .frame(width: resolvedHeroContentWidth, height: height)
    }

    private var resolvedHeroHeight: CGFloat {
        artworkIsPortrait
            ? metrics.portraitHeroHeight
            : metrics.landscapeHeroHeight
    }

    private var resolvedDetailsWidth: CGFloat {
        return max(
            190,
            metrics.viewportWidth * (1 - metrics.heroArtworkWidth)
                - metrics.outerPadding * 2
        )
    }

    private var resolvedHeroContentWidth: CGFloat {
        max(
            1,
            metrics.contentWidth
                - (showsOwnedBadge ? metrics.panelPadding * 2 : 0)
        )
    }

    private var resolvedArtworkWidth: CGFloat {
        max(
            1,
            resolvedHeroContentWidth
                - resolvedDetailsWidth
                - metrics.panelPadding
        )
    }

    private var artworkIsPortrait: Bool {
        guard let visual = presentation.plan.relics.first(where: {
            $0.id == item.id
        }),
        let pixels = [visual.standard, visual.thumbnail, visual.primary]
            .first(where: { $0.id == item.standardResourceID })?.pixelSize
        else { return false }
        return pixels.width < pixels.height
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: metrics.compactSpacing) {
            if showsOwnedBadge {
                Label("Owned", systemImage: "checkmark")
                    .font(.system(size: metrics.captionSize, weight: .medium, design: .serif))
                    .foregroundStyle(Color.runeSuccess)
                    .padding(.horizontal, metrics.tagPadding)
                    .padding(.vertical, metrics.microSpacing)
                    .overlay {
                        RoundedRectangle(cornerRadius: metrics.panelRadius)
                            .strokeBorder(Color.runeSuccess.opacity(0.55), lineWidth: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text(item.name)
                .font(.system(size: metrics.heroTitleSize, design: .serif))
                .foregroundStyle(Color.runeTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Default Relic")
                .font(.system(size: metrics.statusSize, design: .serif))
                .foregroundStyle(Color.runeSuccess)
            ThemeChromeImage(slot: .divider)
                .frame(height: max(10, 18 * metrics.scale))
                .opacity(0.22)
            Text(item.summary)
                .font(.system(size: metrics.bodySize, design: .serif))
                .foregroundStyle(Color.runeTextPrimary)
                .lineSpacing(max(2, 5 * metrics.scale))
                .lineLimit(metrics.variant == .acquisition ? 4 : 7)
                .fixedSize(horizontal: false, vertical: true)
            if !showsOwnedBadge, !item.facets.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: metrics.microSpacing) { semanticTags }
                    VStack(alignment: .leading, spacing: metrics.microSpacing) {
                        semanticTags
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var semanticTags: some View {
        ForEach(item.facets, id: \.self) { facet in
            CodexTag(title: facet, metrics: metrics)
        }
    }
}

private struct CodexRelicCanvas: View {
    let item: CodexCatalogItemModel
    let descriptor: ThemeDescriptor
    let presentation: ActiveThemeVisualPresentation

    var body: some View {
        if let image = presentation.image(for: item.standardResourceID),
           let backgroundImage = presentation.image(
               for: descriptor.codex.background.staticBaseResourceID
           ),
           let relic = descriptor.codex.relics.first(where: {
               $0.metadata.id == item.id
           }),
           let layout = relic.layouts.first(where: {
               $0.id == relic.defaultLayoutID
           }),
           let script = descriptor.codex.scripts.first(where: {
               $0.id == descriptor.codex.primaryScriptID
           }) {
            let aspectRatio = artworkAspectRatio(
                resourceID: item.standardResourceID,
                fallback: layout.aspectRatio
            )
            CodexArtifactSpecimenCard(
                item: ThemeArtifactBrowserItem(
                    id: item.id,
                    resourceID: item.standardResourceID,
                    name: item.name,
                    description: item.summary,
                    facets: item.facets,
                    kind: item.kind,
                    rarity: item.rarity,
                    state: item.state,
                    accessibilityLabel: item.accessibilityLabel,
                    accessibilityHint: item.accessibilityHint,
                    provenance: nil,
                    isSelectable: item.isSelectable,
                    ordinal: item.ordinal,
                    availability: item.availability
                ),
                relicLayout: layout,
                artworkAspectRatio: aspectRatio,
                backgroundImage: backgroundImage
            ) {
                ThemeRelicSpecimenArtwork(
                    image: image,
                    plan: ThemeRelicSpecimenPlan(
                        inscription: inscription(script: script, layout: layout),
                        fontPostScriptName: script.fontPostScriptName?.rawValue
                            ?? RuneThemePaletteInterpreter.fontPostScriptName,
                        glyphSafeRegion: layout.glyphSafeRegion,
                        artworkAspectRatio: aspectRatio,
                        minimumGlyphScale: layout.minimumGlyphScale,
                        usesPrimaryTextColor: usesPrimaryTextColor(relic: relic)
                    )
                )
            }
        } else {
            ThemeVisualPlaceholder(
                systemImage: ThemeVisualArtifactKind.relic.systemImage,
                label: "Relic artwork unavailable"
            )
        }
    }

    private func inscription(
        script: ThemeScriptDescriptor,
        layout: ThemeShareLayoutPreset
    ) -> String {
        let rows = Int(
            layout.catalogSpecimenRows
                ?? (descriptor.criticality == .requiredBase ? 3 : 0)
        )
        let columns = Int(
            layout.catalogSpecimenColumns
                ?? (descriptor.criticality == .requiredBase ? 5 : 0)
        )
        guard rows > 0, columns > 0 else { return "" }
        let glyphs = script.glyphs.map(\.textToken)
        guard !glyphs.isEmpty else { return "" }
        return (0 ..< rows).map { row in
            (0 ..< columns).map { column in
                glyphs[(row * columns + column) % glyphs.count]
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func artworkAspectRatio(
        resourceID: ThemeResourceID,
        fallback: ThemeAspectRatio
    ) -> Double {
        if let visual = presentation.plan.relics.first(where: { $0.id == item.id }),
           let pixels = [visual.standard, visual.thumbnail, visual.primary]
               .first(where: { $0.id == resourceID })?.pixelSize {
            return Double(pixels.width) / Double(pixels.height)
        }
        return Double(fallback.width) / Double(fallback.height)
    }

    private func usesPrimaryTextColor(relic: ThemeRelicDescriptor) -> Bool {
        let semanticDescription = [
            relic.metadata.accessibility.label.fallbackValue,
            relic.metadata.accessibility.hint?.fallbackValue ?? "",
        ].joined(separator: " ").lowercased()
        return semanticDescription.contains("dark")
            || semanticDescription.contains("charcoal")
            || semanticDescription.contains("obsidian")
    }
}

private struct CodexAcquisitionRelicList: View {
    let items: [CodexCatalogItemModel]
    let presentation: ActiveThemeVisualPresentation
    let metrics: CodexCatalogMetrics
    let unlockProgress: ProgressionNumericProgressDTO?
    let select: (ArtifactID) -> Void

    var body: some View {
        CodexPanel(metrics: metrics) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        guard item.isSelectable else { return }
                        select(item.id)
                    } label: {
                        HStack(spacing: metrics.compactSpacing) {
                            acquisitionArtwork(item)
                                .frame(
                                    width: metrics.acquisitionArtworkWidth,
                                    height: metrics.acquisitionRowHeight
                                        - metrics.microSpacing * 2
                                )
                                .opacity(isUnavailable(item) ? 0.58 : 1)

                            VStack(alignment: .leading, spacing: metrics.microSpacing) {
                                Text(item.name)
                                    .font(.system(
                                        size: metrics.supportingTitleSize,
                                        design: .serif
                                    ))
                                    .foregroundStyle(Color.runeTextPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                                acquisitionState(item)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(isUnavailable(item) ? 0.66 : 1)

                            Image(systemName: "chevron.right")
                                .font(.system(
                                    size: metrics.statusSize,
                                    weight: .light
                                ))
                                .foregroundStyle(Color.runeSilver)
                                .accessibilityHidden(true)
                        }
                        .frame(height: metrics.acquisitionRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.isSelectable)
                    .allowsHitTesting(item.isSelectable)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(item.accessibilityLabel)
                    .accessibilityValue(item.state.rawValue)
                    .accessibilityHint(item.accessibilityHint ?? "")
                    .accessibilityIdentifier("codex.catalog.artifact.\(item.ordinal)")

                    if index < items.count - 1 {
                        Rectangle()
                            .fill(Color.runeGold.opacity(0.20))
                            .frame(height: 1)
                    }
                }
            }
        }
        .accessibilityIdentifier("codex.catalog.acquisition-relics")
    }

    @ViewBuilder
    private func acquisitionArtwork(_ item: CodexCatalogItemModel) -> some View {
        if let image = presentation.image(for: item.thumbnailResourceID) {
            image
                .resizable()
                .scaledToFit()
                .accessibilityHidden(true)
        } else {
            ThemeVisualPlaceholder(
                systemImage: ThemeVisualArtifactKind.relic.systemImage,
                label: "Relic artwork unavailable"
            )
        }
    }

    @ViewBuilder
    private func acquisitionState(_ item: CodexCatalogItemModel) -> some View {
        if item.state == .progress {
            Text("Partially Unlocked")
                .font(.system(size: metrics.statusSize, design: .serif))
                .foregroundStyle(Color.runeWarning)
            HStack(spacing: metrics.compactSpacing) {
                ProgressView(
                    value: Double(unlockProgress?.current ?? 0),
                    total: Double(unlockProgress?.target ?? 1)
                )
                    .tint(Color.runeWarning)
                    .frame(maxWidth: max(96, 166 * metrics.scale))
                Text(unlockProgressLabel)
                    .lineLimit(1)
            }
            .font(.system(size: metrics.captionSize, design: .serif))
            .foregroundStyle(Color.runeSilver)
        } else {
            Label(item.state.rawValue, systemImage: item.state.systemImage)
                .font(.system(size: metrics.statusSize, design: .serif))
                .foregroundStyle(item.state == .encountered
                    ? Color.runeEncountered : Color.runeLocked)
            Text(item.state == .encountered ? "Continue in Vault" : "Unlock in Vault")
                .font(.system(size: metrics.captionSize, design: .serif))
                .foregroundStyle(Color.runeSilver)
        }
    }

    private var unlockProgressLabel: String {
        guard let unlockProgress else { return "In Progress" }
        return "\(unlockProgress.current)/\(unlockProgress.target) Complete"
    }

    private func isUnavailable(_ item: CodexCatalogItemModel) -> Bool {
        item.state == .locked || item.state == .unavailable
    }
}

private struct CodexArtifactRow<Artwork: View>: View {
    let item: CodexCatalogItemModel
    let metrics: CodexCatalogMetrics
    let action: () -> Void
    private let artwork: Artwork

    init(
        item: CodexCatalogItemModel,
        metrics: CodexCatalogMetrics,
        action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.item = item
        self.metrics = metrics
        self.action = action
        self.artwork = artwork()
    }

    var body: some View {
        Button {
            guard item.isSelectable else { return }
            action()
        } label: {
            CodexPanel(metrics: metrics) {
                artifactRowContent
                    .opacity(isUnavailable ? 0.66 : 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!item.isSelectable)
        .allowsHitTesting(item.isSelectable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.state.rawValue)
        .accessibilityHint(item.accessibilityHint ?? "")
        .accessibilityIdentifier("codex.catalog.artifact.\(item.ordinal)")
    }

    @ViewBuilder
    private var artifactRowContent: some View {
        switch metrics.artifactRowLayoutMode {
        case .intrinsicStacked:
            VStack(alignment: .leading, spacing: metrics.panelPadding) {
                artwork
                    .frame(maxWidth: .infinity)
                    .frame(height: metrics.stackedArtifactArtworkHeight)
                HStack(alignment: .top, spacing: metrics.panelPadding) {
                    artifactDetails
                    disclosureIndicator
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(
                minHeight: metrics.artifactRowMinimumContentHeight,
                alignment: .topLeading
            )
        case .boundedHorizontal:
            HStack(spacing: metrics.panelPadding) {
                artwork
                    .frame(
                        width: max(98, metrics.viewportWidth * metrics.rowArtworkWidth),
                        height: metrics.artifactRowMinimumContentHeight
                    )
                artifactDetails
                disclosureIndicator
            }
            .frame(height: metrics.artifactRowMinimumContentHeight)
        }
    }

    private var artifactDetails: some View {
        VStack(alignment: .leading, spacing: metrics.microSpacing) {
            Text(item.name)
                .font(.system(size: metrics.supportingTitleSize, design: .serif))
                .foregroundStyle(Color.runeTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(roleTitle)
                .font(.system(size: metrics.statusSize, design: .serif))
                .foregroundStyle(statusColor)
            Text(item.summary)
                .font(.system(size: metrics.bodySize, design: .serif))
                .foregroundStyle(Color.runeTextPrimary)
                .lineLimit(metrics.usesAccessibleLayout ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
            if !item.facets.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: metrics.microSpacing) {
                        artifactFacets
                    }
                    VStack(alignment: .leading, spacing: metrics.microSpacing) {
                        artifactFacets
                    }
                }
            }
            stateBadge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosureIndicator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: metrics.statusSize, weight: .light))
            .foregroundStyle(Color.runeSilver)
            .accessibilityHidden(true)
    }

    private var isUnavailable: Bool {
        item.state == .locked || item.state == .unavailable
    }

    private var roleTitle: String {
        if item.state == .progress { return "Unlockable \(item.kind.rawValue)" }
        if item.ordinal > 2 { return "Advanced \(item.kind.rawValue)" }
        return item.kind.rawValue
    }

    private var statusColor: Color {
        switch item.state {
        case .progress, .encountered:
            Color.runeEncountered
        case .locked, .unavailable:
            Color.runeLocked
        case .owned:
            Color.runeSuccess
        case .selected:
            Color.runeSelected
        }
    }

    @ViewBuilder
    private var artifactFacets: some View {
        ForEach(item.facets, id: \.self) { facet in
            CodexTag(title: facet, metrics: metrics)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        if item.state == .progress {
            Label("Partially Unlocked", systemImage: "lock.fill")
                .lineLimit(1)
                .font(.system(size: metrics.captionSize, design: .serif))
                .foregroundStyle(Color.runeWarning)
                .padding(.horizontal, metrics.tagPadding)
                .padding(.vertical, metrics.microSpacing)
                .overlay {
                    Capsule().strokeBorder(
                        Color.runeWarning.opacity(0.58),
                        lineWidth: 1
                    )
                }
        } else {
            Label(item.state.rawValue, systemImage: item.state.systemImage)
                .font(.system(size: metrics.captionSize, design: .serif))
                .foregroundStyle(statusColor)
                .padding(.horizontal, metrics.tagPadding)
                .padding(.vertical, metrics.microSpacing)
                .overlay {
                    Capsule().strokeBorder(statusColor.opacity(0.58), lineWidth: 1)
                }
        }
    }
}

private struct CodexIncludedSealSummary: View {
    let seals: [CodexCatalogItemModel]
    let presentation: ActiveThemeVisualPresentation
    let metrics: CodexCatalogMetrics
    let clearSelection: (() -> Void)?
    let select: (ArtifactID) -> Void

    var body: some View {
        CodexSealSection(
            title: "Included Seals",
            items: seals,
            presentation: presentation,
            metrics: metrics,
            clearSelection: clearSelection,
            select: select
        )
    }
}

private struct CodexSealSection: View {
    let title: String
    let items: [CodexCatalogItemModel]
    let presentation: ActiveThemeVisualPresentation
    let metrics: CodexCatalogMetrics
    let clearSelection: (() -> Void)?
    let select: (ArtifactID) -> Void

    var body: some View {
        CodexPanel(metrics: metrics) {
            VStack(alignment: .leading, spacing: metrics.compactSpacing) {
                HStack {
                    Text(title)
                        .font(.system(size: metrics.supportingTitleSize, design: .serif))
                        .foregroundStyle(Color.runeTextPrimary)
                    Spacer()
                    if title == "Included Seals" {
                        Label("\(items.count) Included", systemImage: "checkmark.circle")
                            .font(.system(size: metrics.captionSize, design: .serif))
                            .foregroundStyle(Color.runeSuccess)
                    }
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: metrics.compactSpacing),
                        GridItem(.flexible(), spacing: metrics.compactSpacing),
                    ],
                    spacing: metrics.compactSpacing
                ) {
                    if let clearSelection {
                        Button(action: clearSelection) {
                            VStack(spacing: metrics.microSpacing) {
                                Image(systemName: "nosign")
                                    .font(.system(
                                        size: metrics.sealCardHeight * 0.32,
                                        weight: .light
                                    ))
                                    .foregroundStyle(Color.runeSilver)
                                    .frame(maxHeight: metrics.sealCardHeight * 0.82)
                                Text("No Seal")
                                    .font(.system(
                                        size: metrics.captionSize,
                                        design: .serif
                                    ))
                                    .foregroundStyle(Color.runeTextPrimary)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: metrics.sealCardHeight)
                            .background(Color.runeNavy.opacity(0.34))
                            .clipShape(RoundedRectangle(
                                cornerRadius: metrics.panelRadius * 0.62,
                                style: .continuous
                            ))
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: metrics.panelRadius * 0.62,
                                    style: .continuous
                                )
                                .strokeBorder(Color.runeSilver.opacity(0.32), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use no Seal")
                        .accessibilityIdentifier("codex.catalog.seal.none")
                    }

                    ForEach(items) { item in
                        Button { select(item.id) } label: {
                            VStack(spacing: metrics.microSpacing) {
                                sealSpecimen(item)
                                    .frame(maxHeight: metrics.sealCardHeight * 0.82)
                                HStack(spacing: metrics.microSpacing) {
                                    Text(item.name)
                                        .font(.system(size: metrics.captionSize, design: .serif))
                                        .foregroundStyle(Color.runeTextPrimary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                    if item.state == .owned || item.state == .selected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.runeSuccess)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: metrics.sealCardHeight)
                            .background(Color.runeNavy.opacity(0.34))
                            .clipShape(RoundedRectangle(
                                cornerRadius: metrics.panelRadius * 0.62,
                                style: .continuous
                            ))
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: metrics.panelRadius * 0.62,
                                    style: .continuous
                                )
                                .strokeBorder(
                                    item.state == .selected
                                        ? Color.runeSelected : Color.runeSilver.opacity(0.32),
                                    lineWidth: item.state == .selected ? 2 : 1
                                )
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.isSelectable)
                        .accessibilityLabel(item.accessibilityLabel)
                        .accessibilityValue(item.state.rawValue)
                    }
                }
            }
        }
        .accessibilityIdentifier("codex.catalog.section.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    @ViewBuilder
    private func sealSpecimen(_ item: CodexCatalogItemModel) -> some View {
        if let image = presentation.image(for: item.thumbnailResourceID),
           let background = presentation.image(
               for: presentation.plan.backgroundStatic.id
           ) {
            CodexArtifactSpecimenCard(
                item: ThemeArtifactBrowserItem(
                    id: item.id,
                    resourceID: item.thumbnailResourceID,
                    name: item.name,
                    description: item.summary,
                    facets: item.facets,
                    kind: item.kind,
                    rarity: item.rarity,
                    state: item.state,
                    accessibilityLabel: item.accessibilityLabel,
                    accessibilityHint: item.accessibilityHint,
                    provenance: nil,
                    isSelectable: item.isSelectable,
                    ordinal: item.ordinal,
                    availability: item.availability
                ),
                artworkAspectRatio: sealAspectRatio(item),
                backgroundImage: background
            ) {
                image.resizable().scaledToFit()
            }
        } else {
            ThemeVisualPlaceholder(
                systemImage: ThemeVisualArtifactKind.seal.systemImage,
                label: "Seal artwork unavailable"
            )
        }
    }

    private func sealAspectRatio(_ item: CodexCatalogItemModel) -> Double {
        guard let visual = presentation.plan.seals.first(where: {
            $0.id == item.id
        }), let pixels = visual.thumbnail.pixelSize else { return 1 }
        return Double(pixels.width) / Double(pixels.height)
    }
}

enum CodexPrimaryActionChromeGeometry {
    static func capInsets(
        pixelWidth: CGFloat,
        pixelHeight: CGFloat
    ) -> EdgeInsets {
        ThemeChromeNineSliceGeometry.capInsets(
            for: .primaryButton,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) ?? EdgeInsets()
    }

    static func renderPlan(
        pixelWidth: CGFloat,
        pixelHeight: CGFloat,
        renderedSize: CGSize
    ) -> ThemeChromeNineSliceRenderPlan? {
        ThemeChromeNineSliceGeometry.renderPlan(
            for: .primaryButton,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            renderedSize: renderedSize
        )
    }
}

private struct CodexPrimaryAction: View {
    let title: String
    let presentation: ActiveThemeVisualPresentation
    let metrics: CodexCatalogMetrics
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .font(.system(size: metrics.primaryActionFontSize, design: .serif))
                .foregroundStyle(Color.runeTextPrimary)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.primaryActionHeight)
                .background {
                    ZStack {
                        RoundedRectangle(
                            cornerRadius: metrics.primaryActionCornerRadius,
                            style: .continuous
                        )
                        .fill(Color.runeBackgroundSecondary.opacity(0.96))
                        RoundedRectangle(
                            cornerRadius: metrics.primaryActionCornerRadius,
                            style: .continuous
                        )
                        .fill(Color.runeGold.opacity(0.34))
                        primaryButtonChrome
                    }
                    .clipShape(RoundedRectangle(
                        cornerRadius: metrics.primaryActionCornerRadius,
                        style: .continuous
                    ))
                }
                .overlay {
                    RoundedRectangle(
                        cornerRadius: metrics.primaryActionCornerRadius,
                        style: .continuous
                    )
                    .strokeBorder(Color.runeGoldBright.opacity(0.92), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("codex.catalog.primary-action")
    }

    @ViewBuilder
    private var primaryButtonChrome: some View {
        if let plan = presentation.plan.chrome.primaryButton,
           let reference = presentation.imageReference(for: plan) {
            let pixelWidth = CGFloat(plan.pixelSize?.width ?? 1_200)
            let pixelHeight = CGFloat(plan.pixelSize?.height ?? 320)
            GeometryReader { proxy in
                if let renderPlan = CodexPrimaryActionChromeGeometry.renderPlan(
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    renderedSize: proxy.size
                ), let image = reference.image(
                    pixelsPerPoint: renderPlan.pixelsPerPoint
                ) {
                    image
                        .resizable(
                            capInsets: renderPlan.capInsets,
                            resizingMode: .stretch
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .opacity(0.82)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

private struct CodexTag: View {
    let title: String
    let metrics: CodexCatalogMetrics

    var body: some View {
        Text(title)
            .font(.system(size: metrics.captionSize, design: .serif))
            .foregroundStyle(Color.runeSilver)
            .lineLimit(1)
            .padding(.horizontal, metrics.tagPadding)
            .padding(.vertical, metrics.microSpacing)
            .overlay {
                Capsule().strokeBorder(Color.runeSilver.opacity(0.42), lineWidth: 1)
            }
    }
}
