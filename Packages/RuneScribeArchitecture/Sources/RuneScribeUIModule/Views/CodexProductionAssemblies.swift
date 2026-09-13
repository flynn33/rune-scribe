import RuneScribeContracts
import SwiftUI

enum CodexComposeNavigationItem: String, CaseIterable, Identifiable, Sendable {
    case compose = "Compose"
    case cipher = "Cipher"
    case vault = "Vault"
    case settings = "Settings"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .compose: "square.and.pencil"
        case .cipher: "character.book.closed"
        case .vault: "lock.square.stack"
        case .settings: "gearshape"
        }
    }
}

struct CodexComposeWorkspacePanelModel: Equatable, Sendable {
    let composition: ThemeArtifactCompositionPlan
    let cipherName: String
    let relicName: String
    let sealName: String
    let primaryActionTitle: String

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        composition.requiredImageResourceIDs
    }
}

enum CodexMessagePanelFormat: String, Equatable, Sendable {
    case short
    case long

    var title: String {
        switch self {
        case .short: "Short Message"
        case .long: "Long Message"
        }
    }

    var relicWidthFraction: CGFloat {
        switch self {
        case .short: 0.93
        case .long: 0.968
        }
    }

    var relicHeightFraction: CGFloat {
        switch self {
        case .short: 0.543
        case .long: 0.664
        }
    }

    var headingFontWidthFraction: CGFloat {
        switch self {
        case .short: 0.064
        case .long: 0.052
        }
    }

    var headingSubtitleFontWidthFraction: CGFloat {
        switch self {
        case .short: 0.058
        case .long: 0.047
        }
    }

    var headingSpacingFraction: CGFloat {
        switch self {
        case .short: 0.012
        case .long: 0.004
        }
    }

    var artworkSpacingFraction: CGFloat {
        switch self {
        case .short: 0.028
        case .long: 0.007
        }
    }

    var artworkVerticalOffsetFraction: CGFloat {
        switch self {
        case .short: 0
        case .long: -0.036
        }
    }

    var topPaddingFraction: CGFloat {
        switch self {
        case .short: 0.036
        case .long: 0.036
        }
    }
}

enum CodexRelicMessageCanvasSizing: CaseIterable, Equatable, Sendable {
    /// The default host treatment. Every treatment below preserves the
    /// supplied canvas ratio and normalized composition geometry.
    case descriptorAspectFit

    /// The production Compose host treatment.
    case composeWorkspace

    /// The message and share-card host treatment.
    case fillComponentSlot
}

/// Aspect-fit geometry shared by every interactive Relic host. Sizing
/// identifies the surrounding UI context only; it never changes the supplied
/// canvas ratio or normalized composition geometry.
struct CodexRelicMessageCanvasGeometry {
    let hostSize: CGSize
    let canvasAspectRatio: CGFloat
    let sizing: CodexRelicMessageCanvasSizing

    init(
        hostSize: CGSize,
        descriptorAspectRatio: ThemeAspectRatio,
        sizing: CodexRelicMessageCanvasSizing
    ) {
        self.init(
            hostSize: hostSize,
            canvasAspectRatio: CGFloat(descriptorAspectRatio.width)
                / CGFloat(descriptorAspectRatio.height),
            sizing: sizing
        )
    }

    init(
        hostSize: CGSize,
        canvasAspectRatio: CGFloat,
        sizing: CodexRelicMessageCanvasSizing
    ) {
        self.hostSize = hostSize
        self.canvasAspectRatio = canvasAspectRatio
        self.sizing = sizing
    }

    var canvasRect: CGRect {
        let hostWidth = max(0, hostSize.width)
        let hostHeight = max(0, hostSize.height)
        guard hostWidth > 0, hostHeight > 0 else { return .zero }

        // Keep the context exhaustive so adding a sizing mode cannot silently
        // opt out of the caller-supplied canvas geometry.
        switch sizing {
        case .descriptorAspectFit, .composeWorkspace, .fillComponentSlot:
            break
        }

        let aspect = canvasAspectRatio.isFinite && canvasAspectRatio > 0
            ? canvasAspectRatio
            : 1
        let availableAspect = hostWidth / hostHeight
        if aspect > availableAspect {
            let height = hostWidth / aspect
            return CGRect(
                x: 0,
                y: (hostHeight - height) / 2,
                width: hostWidth,
                height: height
            )
        }
        let width = hostHeight * aspect
        return CGRect(
            x: (hostWidth - width) / 2,
            y: 0,
            width: width,
            height: hostHeight
        )
    }

    func rect(for region: ThemeNormalizedRegion) -> CGRect {
        let canvasRect = canvasRect
        return CGRect(
            x: canvasRect.minX + canvasRect.width * CGFloat(region.x),
            y: canvasRect.minY + canvasRect.height * CGFloat(region.y),
            width: canvasRect.width * CGFloat(region.width),
            height: canvasRect.height * CGFloat(region.height)
        )
    }

    func point(for anchor: ThemeNormalizedPoint) -> CGPoint {
        let canvasRect = canvasRect
        return CGPoint(
            x: canvasRect.minX + canvasRect.width * CGFloat(anchor.x),
            y: canvasRect.minY + canvasRect.height * CGFloat(anchor.y)
        )
    }

    func sealSideLength(
        in relicRect: CGRect,
        normalizedScale: Double
    ) -> CGFloat {
        min(relicRect.width, relicRect.height) * CGFloat(normalizedScale)
    }
}

struct CodexMessagePanelModel: Equatable, Sendable {
    let format: CodexMessagePanelFormat
    let composition: ThemeArtifactCompositionPlan
    let pageIndex: Int

    init(
        format: CodexMessagePanelFormat,
        composition: ThemeArtifactCompositionPlan,
        pageIndex: Int = 0
    ) {
        self.format = format
        self.composition = composition
        self.pageIndex = pageIndex
    }

    var page: ShareArtifactRenderPage? {
        guard composition.pages.indices.contains(pageIndex) else {
            return composition.pages.first
        }
        return composition.pages[pageIndex]
    }

    var pageStatusLabel: String {
        guard !composition.pages.isEmpty else { return "Preview unavailable" }
        let boundedIndex = composition.pages.indices.contains(pageIndex) ? pageIndex : 0
        return "Page \(boundedIndex + 1) of \(composition.pages.count)"
    }

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        composition.requiredImageResourceIDs
    }
}

struct CodexSharePreviewCardModel: Equatable, Sendable {
    let heading: String
    let productName: String
    let attribution: String
    let deepLinkLabel: String
    let composition: ThemeArtifactCompositionPlan
    let pageIndex: Int

    init(
        heading: String,
        productName: String,
        attribution: String,
        deepLinkLabel: String,
        composition: ThemeArtifactCompositionPlan,
        pageIndex: Int = 0
    ) {
        self.heading = heading
        self.productName = productName
        self.attribution = attribution
        self.deepLinkLabel = deepLinkLabel
        self.composition = composition
        self.pageIndex = pageIndex
    }

    var page: ShareArtifactRenderPage? {
        guard composition.pages.indices.contains(pageIndex) else {
            return composition.pages.first
        }
        return composition.pages[pageIndex]
    }

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        composition.requiredImageResourceIDs
    }
}

struct CodexBackgroundTreatmentPanelModel: Equatable, Sendable {
    let title: String
    let summary: String
    let backgroundResourceID: ThemeResourceID

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        [backgroundResourceID]
    }
}

enum CodexMasteryPanelStyle: Equatable, Sendable {
    case overview
    case detail
}

struct CodexMasteryRewardsPanelModel: Equatable, Sendable {
    let heading: String
    let frameName: String
    let crestName: String
    let titleName: String
    let titleInscription: String
    let titleGlyphInscription: String?
    let accomplishment: String
    let frameResourceID: ThemeResourceID
    let crestResourceID: ThemeResourceID
    let frameCaptureIdentifier: String?
    let crestCaptureIdentifier: String?
    let titleCaptureIdentifier: String?

    init(
        heading: String,
        frameName: String,
        crestName: String,
        titleName: String,
        titleInscription: String,
        titleGlyphInscription: String? = nil,
        accomplishment: String,
        frameResourceID: ThemeResourceID,
        crestResourceID: ThemeResourceID,
        frameCaptureIdentifier: String? = nil,
        crestCaptureIdentifier: String? = nil,
        titleCaptureIdentifier: String? = nil
    ) {
        self.heading = heading
        self.frameName = frameName
        self.crestName = crestName
        self.titleName = titleName
        self.titleInscription = titleInscription
        self.titleGlyphInscription = titleGlyphInscription
        self.accomplishment = accomplishment
        self.frameResourceID = frameResourceID
        self.crestResourceID = crestResourceID
        self.frameCaptureIdentifier = frameCaptureIdentifier
        self.crestCaptureIdentifier = crestCaptureIdentifier
        self.titleCaptureIdentifier = titleCaptureIdentifier
    }

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        [frameResourceID, crestResourceID]
    }
}

struct CodexVaultCardStateModel: Identifiable, Equatable, Sendable {
    let state: ThemeVisualContentState
    let heading: String
    let detail: String
    let resourceID: ThemeResourceID
    let isApplicable: Bool

    var id: String { "\(state.rawValue)|\(resourceID.rawValue)" }
}

struct CodexVaultCardStateStackModel: Equatable, Sendable {
    let heading: String
    let codexName: String
    let codexSubtitle: String
    let cards: [CodexVaultCardStateModel]

    var requiredImageResourceIDs: Set<ThemeResourceID> {
        Set(cards.map(\.resourceID))
    }
}

enum CodexArtifactSpecimenFamily: Equatable, Sendable {
    case tablet
    case plaque
    case stele
    case seal
}

/// Provider-neutral geometry for production artifact specimens. The family is
/// derived from descriptor semantics while the artwork keeps its own aspect
/// ratio, so a canonical host never stretches or masks a provider resource.
struct CodexArtifactSpecimenLayout: Equatable, Sendable {
    let family: CodexArtifactSpecimenFamily

    init(kind: ThemeVisualArtifactKind, maximumGlyphLines: UInt8?) {
        if kind == .seal {
            family = .seal
        } else if let maximumGlyphLines, maximumGlyphLines <= 4 {
            family = .plaque
        } else if let maximumGlyphLines, maximumGlyphLines >= 7 {
            family = .stele
        } else {
            family = .tablet
        }
    }

    func artworkFrame(
        in size: CGSize,
        artworkAspectRatio: Double
    ) -> CGRect {
        let hostSize = CGSize(
            width: max(0, size.width),
            height: max(0, size.height)
        )
        guard hostSize.width > 0, hostSize.height > 0 else { return .zero }

        let width = max(1, hostSize.width * artworkWidthFraction)
        let aspect = artworkAspectRatio.isFinite && artworkAspectRatio > 0
            ? CGFloat(artworkAspectRatio)
            : 1
        let height = width / aspect
        let desired = CGRect(
            x: hostSize.width * artworkCenter.x - width / 2,
            y: hostSize.height * artworkCenter.y - height / 2,
            width: width,
            height: height
        )
        return containedAspectFitFrame(desired, in: hostSize)
    }

    func panelFrame(in size: CGSize) -> CGRect {
        let desired = switch family {
        case .tablet:
            CGRect(
                x: size.width * 0.017,
                y: size.height * 0.036,
                width: size.width * 1.006,
                height: size.height * 0.99
            )
        case .plaque:
            CGRect(
                x: size.width * 0.015,
                y: size.height * 0.028,
                width: size.width * 1.02,
                height: size.height * 0.94
            )
        case .stele:
            CGRect(
                x: size.width * 0.014,
                y: size.height * 0.126,
                width: size.width * 1.08,
                height: size.height * 0.84
            )
        case .seal:
            CGRect(
                x: size.width * 0.025,
                y: size.height * 0.105,
                width: size.width * 0.89,
                height: size.height * 0.97
            )
        }
        return containedFrame(desired, in: size)
    }

    var showsFacetRow: Bool { family == .tablet }

    func facetRowCenter(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width * 0.518, y: size.height * 0.927)
    }

    private var artworkWidthFraction: CGFloat {
        switch family {
        case .tablet: 1.063
        case .plaque: 1.18
        case .stele: 0.979
        case .seal: 1.12
        }
    }

    private var artworkCenter: CGPoint {
        switch family {
        case .tablet: CGPoint(x: 0.505, y: 0.471)
        case .plaque: CGPoint(x: 0.56, y: 0.54)
        case .stele: CGPoint(x: 0.681, y: 0.620)
        case .seal: CGPoint(x: 0.510, y: 0.486)
        }
    }

    private func containedAspectFitFrame(
        _ desired: CGRect,
        in size: CGSize
    ) -> CGRect {
        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: max(0, size.width), height: max(0, size.height))
        )
        guard !bounds.isEmpty, desired.width > 0, desired.height > 0 else {
            return .zero
        }

        let scale = min(
            1,
            bounds.width / desired.width,
            bounds.height / desired.height
        )
        let containedSize = CGSize(
            width: desired.width * scale,
            height: desired.height * scale
        )
        let center = CGPoint(
            x: min(
                max(desired.midX, containedSize.width / 2),
                bounds.width - containedSize.width / 2
            ),
            y: min(
                max(desired.midY, containedSize.height / 2),
                bounds.height - containedSize.height / 2
            )
        )
        return CGRect(
            x: center.x - containedSize.width / 2,
            y: center.y - containedSize.height / 2,
            width: containedSize.width,
            height: containedSize.height
        )
    }

    private func containedFrame(_ desired: CGRect, in size: CGSize) -> CGRect {
        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: max(0, size.width), height: max(0, size.height))
        )
        guard !bounds.isEmpty else { return .zero }

        let containedSize = CGSize(
            width: min(max(0, desired.width), bounds.width),
            height: min(max(0, desired.height), bounds.height)
        )
        return CGRect(
            x: min(max(0, desired.minX), bounds.width - containedSize.width),
            y: min(max(0, desired.minY), bounds.height - containedSize.height),
            width: containedSize.width,
            height: containedSize.height
        )
    }
}

/// Production specimen composition shared by pickers and canonical component
/// hosts. Runtime-owned provider images supply all visible artwork; the shared
/// layer contributes only semantic surface, spacing, and metadata treatment.
@MainActor
struct CodexArtifactSpecimenCard<Artwork: View>: View {
    let item: ThemeArtifactBrowserItem
    let relicLayout: ThemeShareLayoutPreset?
    let artworkAspectRatio: Double
    let backgroundImage: Image
    private let artwork: Artwork

    init(
        item: ThemeArtifactBrowserItem,
        relicLayout: ThemeShareLayoutPreset? = nil,
        artworkAspectRatio: Double,
        backgroundImage: Image,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.item = item
        self.relicLayout = relicLayout
        self.artworkAspectRatio = artworkAspectRatio
        self.backgroundImage = backgroundImage
        self.artwork = artwork()
    }

    var body: some View {
        GeometryReader { geometry in
            let layout = CodexArtifactSpecimenLayout(
                kind: item.kind,
                maximumGlyphLines: relicLayout?.maximumGlyphLines
            )
            let artworkFrame = layout.artworkFrame(
                in: geometry.size,
                artworkAspectRatio: artworkAspectRatio
            )
            let panelFrame = layout.panelFrame(in: geometry.size)

            ZStack {
                backgroundImage
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()

                specimenPanel(
                    family: layout.family,
                    frame: panelFrame,
                    size: geometry.size
                )

                artwork
                    .frame(width: artworkFrame.width, height: artworkFrame.height)
                    .position(x: artworkFrame.midX, y: artworkFrame.midY)
                    .accessibilityHidden(true)

                if layout.showsFacetRow, !item.facets.isEmpty {
                    specimenFacets(
                        center: layout.facetRowCenter(in: geometry.size),
                        size: geometry.size
                    )
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(item.state.rawValue)
        .accessibilityHint(item.accessibilityHint ?? "")
    }

    @ViewBuilder
    private func specimenPanel(
        family: CodexArtifactSpecimenFamily,
        frame: CGRect,
        size: CGSize
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(panelFill(family: family))
            ThemeChromeImage(slot: .panelBorder)
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .clipped()
        .allowsHitTesting(false)
    }

    private func specimenFacets(center: CGPoint, size: CGSize) -> some View {
        HStack(spacing: max(7, size.width * 0.018)) {
            ForEach(item.facets, id: \.self) { facet in
                Text(facet)
                    .font(.system(
                        size: max(12, size.width * 0.038),
                        weight: .regular,
                        design: .serif
                    ))
                    .foregroundStyle(Color.runeSilver)
                    .lineLimit(1)
                    .padding(.horizontal, max(8, size.width * 0.020))
                    .padding(.vertical, max(4, size.height * 0.010))
                    .background {
                        ThemeChromeImage(slot: .tabSelector)
                            .opacity(0.72)
                    }
            }
        }
        .position(center)
    }

    private func panelFill(family: CodexArtifactSpecimenFamily) -> Color {
        switch family {
        case .seal:
            Color.runeParchment.opacity(0.96)
        case .tablet, .plaque, .stele:
            Color.runeNavy.opacity(0.26)
        }
    }
}

extension ThemeArtifactCompositionPlan {
    var requiredImageResourceIDs: Set<ThemeResourceID> {
        Set([
            relicResourceID,
            sealResourceID,
            frameResourceID,
            backgroundResourceID,
        ].compactMap { $0 })
    }
}

/// The production Relic composition used by Compose, message, and share-card
/// assemblies. It consumes a descriptor-derived plan and already-admitted
/// runtime images; no provider bundle or authority asset is read here.
@MainActor
struct CodexRelicMessageCanvas: View {
    let composition: ThemeArtifactCompositionPlan
    let page: ShareArtifactRenderPage
    let image: (ThemeResourceID) -> Image
    var sizing: CodexRelicMessageCanvasSizing = .descriptorAspectFit

    var body: some View {
        GeometryReader { geometry in
            let canvasRect = CodexRelicMessageCanvasGeometry(
                hostSize: geometry.size,
                canvasAspectRatio: CGFloat(ShareArtifactRenderPlan.outputWidth)
                    / CGFloat(ShareArtifactRenderPlan.outputHeight),
                sizing: sizing
            ).canvasRect
            ZStack {
                ThemeArtifactCanvas(
                    plan: composition,
                    page: page,
                    context: .interactivePreview,
                    image: image
                )
                .accessibilityHidden(true)

                artifactCanvasAccessibilityElement
            }
            .frame(width: canvasRect.width, height: canvasRect.height)
            .position(x: canvasRect.midX, y: canvasRect.midY)
        }
    }

    private var artifactCanvasIdentifier: String {
        ThemeCaptureIdentifier.artifactPreview(
            relicID: composition.selection.relicID
        )
    }

    private var artifactCanvasAccessibilityElement: some View {
        Rectangle()
            .fill(Color.clear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(composition.accessibilityLabel))
            .accessibilityValue(Text(page.inscription))
            .accessibilityHint(
                Text("The sender-rendered inscription remains available when its Codex is not.")
            )
            .accessibilityIdentifier(artifactCanvasIdentifier)
            .runtimeViewportFrameProbe(artifactCanvasIdentifier)
            .allowsHitTesting(false)
    }
}

@MainActor
struct CodexComposeWorkspacePanel: View {
    let model: CodexComposeWorkspacePanelModel
    let image: (ThemeResourceID) -> Image
    var navigate: (CodexComposeNavigationItem) -> Void = { _ in }
    var selectCipher: () -> Void = {}
    var selectRelic: () -> Void = {}
    var selectSeal: () -> Void = {}
    var performPrimaryAction: () -> Void = {}

    var body: some View {
        GeometryReader { geometry in
            let horizontalPadding = geometry.size.width * 0.0415
            let railWidth = max(82, geometry.size.width * 0.127)
            let railSpacing = geometry.size.width * 0.046
            let workspaceWidth = max(
                1,
                geometry.size.width
                    - (horizontalPadding * 2)
                    - railWidth
                    - railSpacing
            )
            let scale = CodexComposeWorkspaceLayout.scale(
                containerSize: geometry.size,
                workspaceWidth: workspaceWidth
            )
            ZStack {
                CodexAssemblyBackdrop(
                    backgroundResourceID: model.composition.backgroundResourceID,
                    image: image,
                    imageOpacity: 0.16
                )

                Group {
                    if geometry.size.width >= 560 {
                        HStack(alignment: .top, spacing: railSpacing) {
                            navigationRail(scale: scale)
                                .frame(width: railWidth)
                                .frame(maxHeight: .infinity)
                            workspace(scale: scale)
                                .frame(width: workspaceWidth)
                        }
                        .frame(
                            width: geometry.size.width - (horizontalPadding * 2),
                            height: geometry.size.height - (24 * scale),
                            alignment: .top
                        )
                    } else {
                        VStack(spacing: 12 * scale) {
                            compactNavigation(scale: scale)
                            workspace(scale: scale)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 12 * scale)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay { CodexAssemblyBorder() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Compose workspace")
        .accessibilityIdentifier("theme.artifact-preview")
        .runtimeViewportFrameProbe("theme.artifact-preview")
    }

    private func navigationRail(scale: CGFloat) -> some View {
        VStack(spacing: 7 * scale) {
            ForEach(CodexComposeNavigationItem.allCases) { item in
                navigationButton(item, scale: scale, compact: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14 * scale)
        .background(Color.runeParchment.opacity(0.82))
        .overlay { CodexAssemblyBorder(cornerRadius: 10 * scale, opacity: 0.22) }
        .clipShape(RoundedRectangle(cornerRadius: 10 * scale, style: .continuous))
    }

    private func compactNavigation(scale: CGFloat) -> some View {
        HStack(spacing: 4 * scale) {
            ForEach(CodexComposeNavigationItem.allCases) { item in
                navigationButton(item, scale: scale, compact: true)
            }
        }
        .padding(4 * scale)
        .background(Color.runeParchment.opacity(0.82))
        .clipShape(Capsule())
    }

    private func navigationButton(
        _ item: CodexComposeNavigationItem,
        scale: CGFloat,
        compact: Bool
    ) -> some View {
        Button { navigate(item) } label: {
            VStack(spacing: 5) {
                Image(systemName: item.systemImage)
                    .font(compact ? .caption : .body)
                Text(item.rawValue)
                    .font(.caption)
            }
            .foregroundStyle(item == .compose ? Color.runeTextPrimary : Color.runeSilver)
            .frame(
                maxWidth: .infinity,
                minHeight: max(
                    minimumInteractiveDimension,
                    (compact ? 36 : 62) * scale
                )
            )
            .background {
                if item == .compose {
                    RoundedRectangle(cornerRadius: 8 * scale, style: .continuous)
                        .fill(Color.runeAccentSecondary.opacity(0.30))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item == .compose ? .isSelected : [])
    }

    private func workspace(scale: CGFloat) -> some View {
        VStack(spacing: 9 * scale) {
            CodexRelicMessageCanvas(
                composition: model.composition,
                page: model.composition.pages[0],
                image: image,
                sizing: .composeWorkspace
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(1.39, contentMode: .fit)

            selectionRow(
                title: "Cipher",
                value: model.cipherName,
                systemImage: "character.book.closed",
                scale: scale,
                action: selectCipher
            )
            selectionRow(
                title: "Relic",
                value: model.relicName,
                systemImage: "rectangle.portrait",
                scale: scale,
                action: selectRelic
            )
            selectionRow(
                title: "Seal",
                value: model.sealName,
                systemImage: "seal",
                scale: scale,
                action: selectSeal
            )

            Button(action: performPrimaryAction) {
                Text(model.primaryActionTitle)
                    .font(.headline)
                    .foregroundStyle(Color.runeTextPrimary)
                    .frame(maxWidth: .infinity, minHeight: minimumInteractiveDimension)
                    .background(Color.runeAccentSecondary.opacity(0.54))
                    .overlay { ThemeChromeImage(slot: .primaryButton).opacity(0.36) }
                    .clipShape(RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
                    .overlay { CodexAssemblyBorder(cornerRadius: 8 * scale, opacity: 0.52) }
            }
            .buttonStyle(.plain)
        }
    }

    private func selectionRow(
        title: String,
        value: String,
        systemImage: String,
        scale: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10 * scale) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.runeTextPrimary)
                .frame(width: 75 * scale, alignment: .leading)
            Button(action: action) {
                HStack(spacing: 8 * scale) {
                    Image(systemName: systemImage)
                        .foregroundStyle(Color.runeSilver)
                    Text(value)
                        .lineLimit(1)
                        .minimumScaleFactor(0.70)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .font(.body)
                .foregroundStyle(Color.runeTextPrimary)
                .frame(maxWidth: .infinity, minHeight: minimumInteractiveDimension)
                .padding(.horizontal, 12 * scale)
                .background(Color.runeParchment.opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 7 * scale, style: .continuous))
                .overlay { CodexAssemblyBorder(cornerRadius: 7 * scale, opacity: 0.22) }
            }
            .buttonStyle(.plain)
        }
    }

    private var minimumInteractiveDimension: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }
}

enum CodexComposeWorkspaceLayout {
    private static let referenceDimension: CGFloat = 648
    private static let minimumScale: CGFloat = 0.58
    private static let maximumScale: CGFloat = 1.35
    private static let wideLayoutThreshold: CGFloat = 560
    private static let previewAspectRatio: CGFloat = 1.39
    private static let scaledWorkspaceChromeHeight: CGFloat = 210
    private static let scaledOuterVerticalPadding: CGFloat = 24

    static func scale(
        containerSize: CGSize,
        workspaceWidth: CGFloat
    ) -> CGFloat {
        let widthScale = min(containerSize.width, containerSize.height)
            / referenceDimension
        guard containerSize.width >= wideLayoutThreshold else {
            return clamp(widthScale)
        }
        let canvasHeight = max(1, workspaceWidth) / previewAspectRatio
        let heightScale = (containerSize.height - canvasHeight)
            / (scaledWorkspaceChromeHeight + scaledOuterVerticalPadding)
        return clamp(min(widthScale, heightScale))
    }

    static func wideRequiredWorkspaceHeight(
        workspaceWidth: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        max(1, workspaceWidth) / previewAspectRatio
            + scaledWorkspaceChromeHeight * scale
    }

    static func wideAvailableWorkspaceHeight(
        containerHeight: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        containerHeight - scaledOuterVerticalPadding * scale
    }

    private static func clamp(_ scale: CGFloat) -> CGFloat {
        max(minimumScale, min(maximumScale, scale))
    }
}

@MainActor
struct CodexMessagePanel: View {
    let model: CodexMessagePanelModel
    let image: (ThemeResourceID) -> Image

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height)
            ZStack(alignment: .top) {
                CodexAssemblyBackdrop(
                    backgroundResourceID: model.composition.backgroundResourceID,
                    image: image,
                    imageOpacity: 0.045
                )

                VStack(spacing: geometry.size.height * model.format.artworkSpacingFraction) {
                    VStack(spacing: unit * model.format.headingSpacingFraction) {
                        Text(model.format.title.uppercased())
                            .font(.runic(
                                geometry.size.width
                                    * model.format.headingFontWidthFraction,
                                fontName: model.composition.fontPostScriptName
                            ))
                            .fontWidth(.compressed)
                        Text("(\(model.pageStatusLabel.uppercased()))")
                            .font(.runic(
                                geometry.size.width
                                    * model.format.headingSubtitleFontWidthFraction,
                                fontName: model.composition.fontPostScriptName
                            ))
                            .fontWidth(.compressed)
                    }
                    .foregroundStyle(Color.runeTextPrimary.opacity(0.84))
                    .multilineTextAlignment(.center)

                    if let page = model.page {
                        CodexRelicMessageCanvas(
                            composition: model.composition,
                            page: page,
                            image: image,
                            sizing: .fillComponentSlot
                        )
                        .frame(
                            width: geometry.size.width * model.format.relicWidthFraction,
                            height: geometry.size.height * model.format.relicHeightFraction
                        )
                        .offset(
                            y: geometry.size.height
                                * model.format.artworkVerticalOffsetFraction
                        )
                    } else {
                        ThemeVisualPlaceholder(
                            systemImage: "photo.artframe",
                            label: "Artifact preview unavailable"
                        )
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, geometry.size.height * model.format.topPaddingFraction)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay { CodexAssemblyBorder(inset: 4) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.format.title), \(model.pageStatusLabel)")
        .accessibilityIdentifier("theme.artifact-preview")
        .runtimeViewportFrameProbe("theme.artifact-preview")
    }
}

@MainActor
struct CodexSharePreviewCard: View {
    let model: CodexSharePreviewCardModel
    let image: (ThemeResourceID) -> Image

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height)
            let panelWidth = geometry.size.width * 0.945
            ZStack(alignment: .leading) {
                CodexAssemblyBackdrop(
                    backgroundResourceID: model.composition.backgroundResourceID,
                    image: image,
                    imageOpacity: 0.07
                )

                ZStack {
                    VStack(spacing: unit * 0.054) {
                        VStack(spacing: unit * 0.004) {
                            Text(model.heading.uppercased())
                                .font(.runic(unit * 0.050))
                                .fontWidth(.compressed)
                            Text("(.\(shareNamespace.uppercased()))")
                                .font(.runic(unit * 0.038))
                                .fontWidth(.condensed)
                                .tracking(unit * 0.002)
                        }
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Color.runeTextPrimary.opacity(0.84))

                        shareCard(unit: unit)
                            .frame(
                                width: geometry.size.width * 0.826,
                                height: geometry.size.height * 0.787
                            )
                    }
                    .offset(y: -unit * 0.009)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: panelWidth, height: geometry.size.height)
                .clipped()
                .overlay { CodexAssemblyBorder(opacity: 0.28, inset: 4) }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay { CodexAssemblyBorder(opacity: 0.22, inset: 2) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.heading)
    }

    private var shareNamespace: String {
        let scheme = model.deepLinkLabel.split(separator: ":", maxSplits: 1).first
        return scheme.map(String.init) ?? model.productName
    }

    private func shareCard(unit: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack {
                image(model.composition.backgroundResourceID)
                    .resizable()
                    .scaledToFill()
                    .clipped()

                Color.runeNavy.opacity(0.14)

                LinearGradient(
                    colors: [
                        Color.runeNavy.opacity(0.12),
                        Color.runeNavy.opacity(0.02),
                        Color.runeNavy.opacity(0.80),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Text(model.productName)
                    .font(.runic(unit * 0.046))
                    .foregroundStyle(Color.runeTextPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: .infinity)
                    .position(
                        x: geometry.size.width * 0.50,
                        y: geometry.size.height * 0.060
                    )

                ThemeChromeImage(slot: .cornerOrnament)
                    .frame(width: unit * 0.090, height: unit * 0.090)
                    .scaleEffect(x: -1, y: 1)
                    .position(
                        x: geometry.size.width * 0.91,
                        y: geometry.size.height * 0.060
                    )

                if let page = model.page {
                    CodexRelicMessageCanvas(
                        composition: model.composition,
                        page: page,
                        image: image,
                        sizing: .fillComponentSlot
                    )
                    .frame(
                        width: geometry.size.width * 0.70,
                        height: geometry.size.height * 0.516
                    )
                    .position(
                        x: geometry.size.width * 0.55,
                        y: geometry.size.height * 0.504
                    )
                }

                Image(systemName: "checkmark")
                    .font(.system(size: unit * 0.042, weight: .semibold))
                    .foregroundStyle(Color.runeGoldBright)
                    .position(
                        x: geometry.size.width * 0.55,
                        y: geometry.size.height * 0.155
                    )

                VStack(alignment: .leading, spacing: unit * 0.006) {
                    Text(model.attribution)
                        .font(.runic(unit * 0.037))
                    Text(model.deepLinkLabel)
                        .font(.runic(unit * 0.028))
                }
                .foregroundStyle(Color.runeTextPrimary)
                .frame(
                    width: geometry.size.width * 0.78,
                    alignment: .leading
                )
                .position(
                    x: geometry.size.width * 0.46,
                    y: geometry.size.height * 0.88
                )

                Image(systemName: "person.2.circle")
                    .font(.system(size: unit * 0.075, weight: .regular))
                    .foregroundStyle(Color.runeTextPrimary)
                    .position(
                        x: geometry.size.width * 0.89,
                        y: geometry.size.height * 0.88
                    )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: unit * 0.050, style: .continuous))
        .overlay {
            CodexAssemblyBorder(
                cornerRadius: unit * 0.050,
                opacity: 0.52,
                inset: 3
            )
        }
        .overlay { ThemeChromeImage(slot: .panelBorder).opacity(0.16).allowsHitTesting(false) }
    }
}

@MainActor
struct CodexBackgroundTreatmentPanel: View {
    let model: CodexBackgroundTreatmentPanelModel
    let image: (ThemeResourceID) -> Image

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                CodexAssemblySurface()

                VStack(spacing: 0) {
                    Text(model.title.uppercased())
                        .font(.runic(
                            min(geometry.size.width, geometry.size.height) * 0.054
                        ))
                        .fontWidth(.condensed)
                        .tracking(1.2)
                        .foregroundStyle(Color.runeTextPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: geometry.size.height * 0.16
                        )
                        .padding(.horizontal, geometry.size.width * 0.04)

                    image(model.backgroundResourceID)
                        .resizable()
                        .scaledToFill()
                        .frame(height: geometry.size.height * 0.67)
                        .clipped()
                        .overlay(alignment: .bottom) {
                            ZStack {
                                Color.runeNavy.opacity(0.18)
                                LinearGradient(
                                    colors: [.clear, Color.runeNavy.opacity(0.52)],
                                    startPoint: .center,
                                    endPoint: .bottom
                                )
                            }
                        }

                    Text(model.summary)
                        .font(.runic(
                            min(geometry.size.width, geometry.size.height) * 0.043
                        ))
                        .fontWidth(.condensed)
                        .foregroundStyle(Color.runeTextPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.78)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, geometry.size.width * 0.04)
                }
                .padding(.horizontal, geometry.size.width * 0.016)
                .padding(.vertical, geometry.size.height * 0.010)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay { CodexAssemblyBorder(inset: 5) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
        .accessibilityValue(model.summary)
    }
}

@MainActor
struct CodexMasteryRewardsPanel: View {
    let model: CodexMasteryRewardsPanelModel
    let style: CodexMasteryPanelStyle
    let image: (ThemeResourceID) -> Image
    @EnvironmentObject private var session: RuneScribeUISession

    var body: some View {
        GeometryReader { geometry in
            let unit = min(geometry.size.width, geometry.size.height)
            VStack(spacing: unit * 0.018) {
                Text(model.heading.uppercased())
                    .font(.runic(unit * 0.060))
                    .fontWidth(.condensed)
                    .tracking(unit * 0.003)
                    .foregroundStyle(Color.runeTextPrimary)
                    .frame(height: geometry.size.height * 0.14)

                Rectangle()
                    .fill(Color.runeSilver.opacity(0.20))
                    .frame(height: 1)
                    .padding(.horizontal, geometry.size.width * 0.04)

                rewardsRow(size: geometry.size, unit: unit)
            }
            .padding(.top, geometry.size.height * 0.025)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background { CodexAssemblySurface() }
            .clipped()
            .overlay { CodexAssemblyBorder(inset: 4) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.heading)
    }

    private func rewardsRow(size: CGSize, unit: CGFloat) -> some View {
        HStack(alignment: .top, spacing: size.width * 0.0175) {
            rewardArtwork(
                heading: "Mastery Frame",
                accessibilityLabel: model.frameName,
                resourceID: model.frameResourceID,
                width: size.width * 0.32,
                unit: unit,
                captureIdentifier: model.frameCaptureIdentifier
            )
            rewardArtwork(
                heading: "Mastery Crest",
                accessibilityLabel: model.crestName,
                resourceID: model.crestResourceID,
                width: size.width * 0.295,
                unit: unit,
                captureIdentifier: model.crestCaptureIdentifier
            )
            titleReward(width: size.width * 0.308, unit: unit)
        }
        .padding(.horizontal, size.width * 0.021)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func rewardArtwork(
        heading: String,
        accessibilityLabel: String,
        resourceID: ThemeResourceID,
        width: CGFloat,
        unit: CGFloat,
        captureIdentifier: String?
    ) -> some View {
        VStack(spacing: unit * 0.018) {
            Text(heading.uppercased())
                .font(.runic(unit * 0.038))
                .fontWidth(.condensed)
                .foregroundStyle(Color.runeTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            image(resourceID)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, unit * 0.010)
        }
        .frame(width: width)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .themeCaptureIdentifier(captureIdentifier)
    }

    private func titleReward(width: CGFloat, unit: CGFloat) -> some View {
        VStack(spacing: unit * 0.018) {
            Text("MASTERY TITLE")
                .font(.runic(unit * 0.038))
                .fontWidth(.condensed)
                .foregroundStyle(Color.runeTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)

            Spacer()
                .frame(height: unit * 0.075)

            ThemeChromeProtectedContentLayout(
                panelPixelSize: panelBorderPixelSize,
                minimumInsets: EdgeInsets(
                    top: 0,
                    leading: unit * 0.025,
                    bottom: 0,
                    trailing: unit * 0.025
                )
            ) {
                VStack(spacing: unit * 0.010) {
                    Text(model.titleInscription.uppercased())
                        .font(.runic(unit * 0.047))
                        .fontWidth(.condensed)
                        .tracking(unit * 0.002)
                    if let titleGlyphInscription = model.titleGlyphInscription {
                        Text(titleGlyphInscription)
                            .font(.runic(unit * 0.032))
                            .opacity(0.72)
                    }
                }
                .foregroundStyle(Color.runeGoldBright)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, minHeight: unit * 0.18)
            .background(Color.runeNavy.opacity(0.88))
            .overlay { ThemeChromeImage(slot: .panelBorder).opacity(0.28) }
            .overlay {
                CodexAssemblyBorder(
                    cornerRadius: unit * 0.015,
                    opacity: 0.44,
                    color: .runeGold,
                    inset: 2
                )
            }

            Text(model.accomplishment)
                .font(.runic(unit * 0.038))
                .fontWidth(.condensed)
                .foregroundStyle(Color.runeTextPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(style == .overview ? 3 : 2)
                .minimumScaleFactor(0.72)
                .padding(.top, unit * 0.030)
        }
        .frame(width: width)
        .accessibilityElement(children: .combine)
        .themeCaptureIdentifier(model.titleCaptureIdentifier)
    }

    private var panelBorderPixelSize: ThemePixelSize? {
        session.activeThemeVisualPresentation?
            .chromeImageReference(for: .panelBorder)?
            .integrity.pixelSize
    }
}

@MainActor
struct CodexVaultCardStateStack: View {
    let model: CodexVaultCardStateStackModel
    let image: (ThemeResourceID) -> Image
    var selectState: ((CodexVaultCardStateModel) -> Void)? = nil

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width
            ZStack {
                CodexAssemblySurface()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: unit * 0.024) {
                        Text(model.heading.uppercased())
                            .font(.runic(unit * 0.048))
                            .fontWidth(.compressed)
                            .foregroundStyle(Color.runeTextPrimary.opacity(0.86))

                        Rectangle()
                            .fill(Color.runeSilver.opacity(0.22))
                            .frame(height: 1)

                        ForEach(model.cards) { card in
                            stateCard(card, unit: unit)
                        }
                    }
                    .frame(width: geometry.size.width * 0.81)
                    .padding(.vertical, unit * 0.038)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .overlay { CodexAssemblyBorder(inset: 4) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.heading)
    }

    private func stateCard(_ card: CodexVaultCardStateModel, unit: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: unit * 0.020) {
            Text(card.heading.uppercased())
                .font(.runic(unit * 0.039))
                .fontWidth(.compressed)
                .foregroundStyle(Color.runeTextPrimary.opacity(0.86))
                .padding(.leading, unit * 0.10)

            Group {
                if card.isApplicable, let selectState {
                    Button { selectState(card) } label: {
                        stateCardContent(card, unit: unit)
                    }
                    .buttonStyle(.plain)
                } else {
                    stateCardContent(card, unit: unit)
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(vaultCardAspectRatio(for: card.state), contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: unit * 0.035, style: .continuous))
            .overlay {
                CodexAssemblyBorder(
                    cornerRadius: unit * 0.035,
                    opacity: 0.48,
                    inset: 2
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(model.codexName), \(card.heading)")
            .accessibilityValue(card.detail)
        }
    }

    private func stateCardContent(
        _ card: CodexVaultCardStateModel,
        unit: CGFloat
    ) -> some View {
        ZStack(alignment: .bottomLeading) {
            image(card.resourceID)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            LinearGradient(
                colors: [Color.clear, Color.runeNavy.opacity(0.88)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: unit * 0.007) {
                Text(model.codexName)
                    .font(.runic(unit * 0.062))
                Text(model.codexSubtitle)
                    .font(.runic(unit * 0.042))
                Spacer(minLength: unit * 0.02)
                HStack {
                    if card.state != .owned && card.state != .selected {
                        Text(card.detail)
                            .font(.runic(unit * 0.034))
                    }
                    Spacer(minLength: 4)
                    Image(systemName: stateSystemImage(card.state))
                        .font(.system(size: unit * 0.060, weight: .medium))
                        .foregroundStyle(
                            card.state == .owned || card.state == .selected
                                ? Color.runeSuccess : Color.runeSilver
                        )
                }
            }
            .foregroundStyle(Color.runeTextPrimary)
            .padding(unit * 0.045)
            // This overlay is fixed-ratio card artwork, not flowing interface text.
            // The semantic wrapper below keeps the complete label and value available.
            .dynamicTypeSize(.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func vaultCardAspectRatio(for state: ThemeVisualContentState) -> CGFloat {
        16 / 9
    }

    private func stateSystemImage(_ state: ThemeVisualContentState) -> String {
        switch state {
        case .owned: "checkmark.circle"
        case .selected: "checkmark.circle.fill"
        case .encountered: "eye"
        case .progress: "circle.dashed"
        case .locked: "lock"
        case .unavailable: "slash.circle"
        }
    }
}

@MainActor
private struct CodexAssemblyBackdrop: View {
    let backgroundResourceID: ThemeResourceID
    let image: (ThemeResourceID) -> Image
    let imageOpacity: Double

    var body: some View {
        ZStack {
            CodexAssemblySurface()
            image(backgroundResourceID)
                .resizable()
                .scaledToFill()
                .opacity(imageOpacity)
                .clipped()
        }
        .clipped()
    }
}

private struct CodexAssemblySurface: View {
    var body: some View {
        Color(red: 5 / 255, green: 19 / 255, blue: 32 / 255)
    }
}

private struct CodexAssemblyBorder: View {
    var cornerRadius: CGFloat = 0
    var opacity: Double = 0.28
    var color: Color = .runeSilver
    var inset: CGFloat = 0

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(color.opacity(opacity), lineWidth: 1)

            if inset > 0 {
                RoundedRectangle(
                    cornerRadius: max(0, cornerRadius - inset),
                    style: .continuous
                )
                .strokeBorder(color.opacity(opacity * 0.44), lineWidth: 1)
                .padding(inset)
            }
        }
        .allowsHitTesting(false)
    }
}
