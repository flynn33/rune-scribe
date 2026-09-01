import RuneScribeContracts
import SwiftUI

struct ThemeChromeNineSliceRenderPlan {
    let capInsets: EdgeInsets
    let sourceToRenderedScale: CGFloat
    let pixelsPerPoint: CGFloat
}

enum ThemeChromePanelContentGeometry {
    static let railClearance: CGFloat = 4

    /// Returns content insets that stay outside the panel's protected rails.
    /// Width is sufficient to derive a conservative upper bound because the
    /// nine-slice renderer can only choose an equal or smaller height scale.
    static func protectedInsets(
        pixelSize: ThemePixelSize?,
        renderedWidth: CGFloat,
        minimumInsets: EdgeInsets
    ) -> EdgeInsets {
        guard let pixelSize,
              renderedWidth.isFinite,
              renderedWidth > 0,
              let sourceInsets = ThemeChromeNineSliceGeometry.capInsets(
                  for: .panelBorder,
                  pixelSize: pixelSize
              )
        else { return minimumInsets }

        let scale = min(1, renderedWidth / CGFloat(pixelSize.width))
        return EdgeInsets(
            top: max(minimumInsets.top, sourceInsets.top * scale + railClearance),
            leading: max(
                minimumInsets.leading,
                sourceInsets.leading * scale + railClearance
            ),
            bottom: max(
                minimumInsets.bottom,
                sourceInsets.bottom * scale + railClearance
            ),
            trailing: max(
                minimumInsets.trailing,
                sourceInsets.trailing * scale + railClearance
            )
        )
    }
}

struct ThemeChromeProtectedContentLayout: Layout {
    let panelPixelSize: ThemePixelSize?
    let minimumInsets: EdgeInsets

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }

        let proposedWidth = finitePositive(proposal.width)
        let idealContentSize = content.sizeThatFits(.unspecified)
        let width = proposedWidth ?? (
            idealContentSize.width + minimumInsets.leading + minimumInsets.trailing
        )
        let insets = ThemeChromePanelContentGeometry.protectedInsets(
            pixelSize: panelPixelSize,
            renderedWidth: width,
            minimumInsets: minimumInsets
        )
        let availableWidth = max(0, width - insets.leading - insets.trailing)
        let measuredContentSize = content.sizeThatFits(
            ProposedViewSize(width: availableWidth, height: nil)
        )
        let minimumHeight = measuredContentSize.height + insets.top + insets.bottom
        let height = max(finitePositive(proposal.height) ?? minimumHeight, minimumHeight)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        guard let content = subviews.first else { return }
        let insets = ThemeChromePanelContentGeometry.protectedInsets(
            pixelSize: panelPixelSize,
            renderedWidth: bounds.width,
            minimumInsets: minimumInsets
        )
        content.place(
            at: CGPoint(
                x: bounds.minX + insets.leading,
                y: bounds.minY + insets.top
            ),
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: max(0, bounds.width - insets.leading - insets.trailing),
                height: max(0, bounds.height - insets.top - insets.bottom)
            )
        )
    }

    private func finitePositive(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }
}

enum ThemeChromeNineSliceGeometry {
    static func renderPlan(
        for slot: ThemeChromeVisualSlot,
        pixelSize: ThemePixelSize,
        renderedSize: CGSize
    ) -> ThemeChromeNineSliceRenderPlan? {
        renderPlan(
            for: slot,
            pixelWidth: CGFloat(pixelSize.width),
            pixelHeight: CGFloat(pixelSize.height),
            renderedSize: renderedSize
        )
    }

    static func renderPlan(
        for slot: ThemeChromeVisualSlot,
        pixelWidth width: CGFloat,
        pixelHeight height: CGFloat,
        renderedSize: CGSize
    ) -> ThemeChromeNineSliceRenderPlan? {
        guard let sourceInsets = capInsets(
            for: slot,
            pixelWidth: width,
            pixelHeight: height
        ) else { return nil }
        guard width > 0,
              height > 0,
              renderedSize.width > 0,
              renderedSize.height > 0
        else { return nil }

        let scale = min(
            1,
            renderedSize.width / width,
            renderedSize.height / height
        )
        guard scale.isFinite, scale > 0 else { return nil }
        return ThemeChromeNineSliceRenderPlan(
            capInsets: EdgeInsets(
                top: sourceInsets.top * scale,
                leading: sourceInsets.leading * scale,
                bottom: sourceInsets.bottom * scale,
                trailing: sourceInsets.trailing * scale
            ),
            sourceToRenderedScale: scale,
            pixelsPerPoint: 1 / scale
        )
    }

    static func capInsets(
        for slot: ThemeChromeVisualSlot,
        pixelSize: ThemePixelSize
    ) -> EdgeInsets? {
        capInsets(
            for: slot,
            pixelWidth: CGFloat(pixelSize.width),
            pixelHeight: CGFloat(pixelSize.height)
        )
    }

    static func capInsets(
        for slot: ThemeChromeVisualSlot,
        pixelWidth width: CGFloat,
        pixelHeight height: CGFloat
    ) -> EdgeInsets? {
        switch slot {
        case .panelBorder:
            return EdgeInsets(
                top: height * 0.15,
                leading: width * 0.10625,
                bottom: height * 0.15,
                trailing: width * 0.10625
            )
        case .divider:
            return EdgeInsets(
                top: height * 0.375,
                leading: width * 0.225,
                bottom: height * 0.375,
                trailing: width * 0.225
            )
        case .primaryButton:
            return EdgeInsets(
                top: height * 0.325,
                leading: width * 0.1583333333,
                bottom: height * 0.325,
                trailing: width * 0.1583333333
            )
        case .tabSelector:
            return EdgeInsets(
                top: height * 0.3166666667,
                leading: width * 0.17,
                bottom: height * 0.3166666667,
                trailing: width * 0.17
            )
        case .cornerOrnament:
            return nil
        }
    }
}

/// Displays an optional provider-owned chrome resource without exposing Theme
/// implementation details to the shared UI. Each resource stays bound to the
/// active visual-plan revision through `ActiveThemeVisualPresentation`.
struct ThemeChromeImage: View {
    @EnvironmentObject private var session: RuneScribeUISession

    let slot: ThemeChromeVisualSlot

    var body: some View {
        if let reference = session.activeThemeVisualPresentation?
            .chromeImageReference(for: slot) {
            switch slot {
            case .cornerOrnament:
                if let image = reference.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .accessibilityHidden(true)
                }
            case .panelBorder, .divider, .primaryButton, .tabSelector:
                if let pixelSize = reference.integrity.pixelSize,
                   ThemeChromeNineSliceGeometry.capInsets(
                       for: slot,
                       pixelSize: pixelSize
                   ) != nil {
                    GeometryReader { proxy in
                        if let renderPlan = ThemeChromeNineSliceGeometry.renderPlan(
                            for: slot,
                            pixelSize: pixelSize,
                            renderedSize: proxy.size
                        ), let image = reference.image(
                            pixelsPerPoint: renderPlan.pixelsPerPoint
                        ) {
                            image
                                .resizable(
                                    capInsets: renderPlan.capInsets,
                                    resizingMode: .stretch
                                )
                                .frame(
                                    width: proxy.size.width,
                                    height: proxy.size.height
                                )
                                .clipped()
                        }
                    }
                    .accessibilityHidden(true)
                } else if let image = reference.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .clipped()
                        .accessibilityHidden(true)
                }
            }
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }
}

enum ThemeVisualContentState: String, Equatable, Hashable, Sendable {
    case owned = "Owned"
    case locked = "Locked"
    case encountered = "Encountered"
    case progress = "Progress"
    case unavailable = "Unavailable"
    case selected = "Selected"

    var systemImage: String {
        switch self {
        case .owned: "checkmark.seal"
        case .locked: "lock.fill"
        case .encountered: "eye"
        case .progress: "circle.dashed"
        case .unavailable: "exclamationmark.circle"
        case .selected: "checkmark.circle.fill"
        }
    }
}

struct ThemeVisualPlaceholder: View {
    let systemImage: String
    var label: String? = nil

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.runeNavy.opacity(0.88), Color.runeBlue.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: systemImage)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Color.runeSilver)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.runeSilver.opacity(0.22), lineWidth: 1)
        }
        .accessibilityLabel(label ?? "Artwork unavailable")
    }
}

/// A provider-neutral Codex card. Artwork is supplied by the runtime or by the
/// safe placeholder caller; the component owns all state and accessibility UI.
struct ThemeCodexCardView<Artwork: View>: View {
    let codexID: CodexID
    let displayName: String
    let summary: String
    let state: ThemeVisualContentState
    let accessibilityLabel: String
    let accessibilityHint: String
    let isEnabled: Bool
    let identifierPrefix: String
    let captureIdentifier: String?
    let action: () -> Void
    private let artwork: Artwork
    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.themeCaptureIdentifiersEnabled) private var captureIdentifiersEnabled

    init(
        codexID: CodexID,
        displayName: String,
        summary: String,
        state: ThemeVisualContentState,
        accessibilityLabel: String,
        accessibilityHint: String = "",
        isEnabled: Bool,
        identifierPrefix: String = "theme.codex-card",
        captureIdentifier: String? = nil,
        action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.codexID = codexID
        self.displayName = displayName
        self.summary = summary
        self.state = state
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.isEnabled = isEnabled
        self.identifierPrefix = identifierPrefix
        self.captureIdentifier = captureIdentifier
        self.action = action
        self.artwork = artwork()
    }

    var body: some View {
        Button(action: action) {
            ThemeChromeProtectedContentLayout(
                panelPixelSize: panelBorderPixelSize,
                minimumInsets: EdgeInsets(
                    top: 12,
                    leading: 12,
                    bottom: 12,
                    trailing: 12
                )
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    GeometryReader { geometry in
                        artwork
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)

                    HStack(alignment: .bottom, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(displayName)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.runeTextPrimary)
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(Color.runeSilver)
                                .lineLimit(3)
                        }
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Label(state.rawValue, systemImage: state.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                state == .selected ? Color.runeSelected : Color.runeSilver
                            )
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .overlay {
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder(
                    state == .selected ? Color.runeSelected : Color.runeSilver.opacity(0.2),
                    lineWidth: state == .selected ? 2 : 1
                )
        }
        .overlay {
            ThemeChromeImage(slot: .panelBorder)
                .opacity(0.72)
                .clipped()
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(state.rawValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier(resolvedAccessibilityIdentifier)
        .runtimeViewportFrameProbe(resolvedAccessibilityIdentifier)
    }

    private var resolvedAccessibilityIdentifier: String {
        if captureIdentifiersEnabled, let captureIdentifier {
            return captureIdentifier
        }
        return "\(identifierPrefix).\(codexID.rawValue)"
    }

    private var panelBorderPixelSize: ThemePixelSize? {
        session.activeThemeVisualPresentation?
            .chromeImageReference(for: .panelBorder)?
            .integrity.pixelSize
    }
}

struct ThemeArtifactSelectionControl<Artwork: View>: View {
    let title: String
    let item: ThemeArtifactPickerItem?
    let kind: ThemeVisualArtifactKind
    let state: ThemeVisualContentState
    let allowsNone: Bool
    let action: () -> Void
    private let artwork: Artwork
    @Environment(\.themeCaptureIdentifiersEnabled) private var captureIdentifiersEnabled

    init(
        title: String,
        item: ThemeArtifactPickerItem?,
        kind: ThemeVisualArtifactKind,
        state: ThemeVisualContentState,
        allowsNone: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.title = title
        self.item = item
        self.kind = kind
        self.state = state
        self.allowsNone = allowsNone
        self.action = action
        self.artwork = artwork()
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                artwork
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.runeSilver)
                        .padding(.vertical, 1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item?.name ?? (allowsNone ? "None" : "Unavailable"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.runeTextPrimary)
                        .padding(.vertical, 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if allowsNone, item == nil, state != .unavailable {
                        Label("No frame selected", systemImage: "rectangle.slash")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.runeSilver)
                            .padding(.vertical, 1)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label(state.rawValue, systemImage: state.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(
                                state == .unavailable ? Color.runeWarning : Color.runeSilver
                            )
                            .padding(.vertical, 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.runeSilver)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.runeBackgroundSecondary.opacity(0.88))
                    ThemeChromeImage(slot: .tabSelector)
                        .opacity(0.72)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled(!allowsNone && item == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected \(title), \(item?.name ?? (allowsNone ? "None" : "Unavailable"))")
        .accessibilityValue(selectionState)
        .accessibilityHint("Opens the \(title.lowercased()) browser")
        .accessibilityIdentifier(accessibilityIdentifier)
        .runtimeViewportFrameProbe(
            "workspace.artifact-control.\(kind.rawValue.lowercased())"
        )
    }

    private var accessibilityIdentifier: String {
        if captureIdentifiersEnabled {
            return "workspace.artifact-control.\(kind.rawValue.lowercased())"
        }
        return item.map { "theme.artifact-thumbnail.\($0.id.rawValue)" }
            ?? "theme.artifact-selection.\(kind.rawValue.lowercased())"
    }

    private var selectionState: String {
        guard state != .unavailable else { return state.rawValue }
        guard let item else { return allowsNone ? "No frame selected" : state.rawValue }
        if state == .selected { return item.isOwned ? "Owned and selected" : "Selected" }
        return state.rawValue
    }
}

struct ThemeArtifactBrowserItem: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let resourceID: ThemeResourceID
    let name: String
    let description: String
    let facets: [String]
    let kind: ThemeVisualArtifactKind
    let rarity: ThemeRarityToken
    let state: ThemeVisualContentState
    let accessibilityLabel: String
    let accessibilityHint: String?
    let provenance: String?
    let isSelectable: Bool

    /// Stable provider catalog order and entitlement semantics. They are kept
    /// alongside the visual item so the shared card can reproduce the provider
    /// authority without branching on a Theme or artifact identifier.
    let ordinal: Int?
    let availability: ThemeArtifactAvailability?

    init(
        id: ArtifactID,
        resourceID: ThemeResourceID,
        name: String,
        description: String,
        facets: [String] = [],
        kind: ThemeVisualArtifactKind,
        rarity: ThemeRarityToken,
        state: ThemeVisualContentState,
        accessibilityLabel: String,
        accessibilityHint: String?,
        provenance: String?,
        isSelectable: Bool,
        ordinal: Int? = nil,
        availability: ThemeArtifactAvailability? = nil
    ) {
        self.id = id
        self.resourceID = resourceID
        self.name = name
        self.description = description
        self.facets = facets
        self.kind = kind
        self.rarity = rarity
        self.state = state
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.provenance = provenance
        self.isSelectable = isSelectable
        self.ordinal = ordinal
        self.availability = availability
    }
}

enum ThemeArtifactSpecimenStyle: Equatable, Sendable {
    case catalogCard
    case artwork
}

struct ThemeRelicSpecimenPlan: Equatable, Sendable {
    let inscription: String
    let fontPostScriptName: String
    let glyphSafeRegion: ThemeNormalizedRegion
    let artworkAspectRatio: Double
    let minimumGlyphScale: Double
    let usesPrimaryTextColor: Bool
}

/// Shared production Relic rendering for catalog specimens. Provider master
/// artwork remains unmodified; the Script inscription is composed at runtime
/// inside the descriptor-authored safe region.
struct ThemeRelicSpecimenArtwork: View {
    let image: Image
    let plan: ThemeRelicSpecimenPlan

    var body: some View {
        GeometryReader { geometry in
            let artworkRect = fittedArtworkRect(in: geometry.size)
            ZStack {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)

                Text(plan.inscription)
                    .font(.custom(
                        plan.fontPostScriptName,
                        size: max(9, artworkRect.width * 0.078)
                    ))
                    .minimumScaleFactor(CGFloat(plan.minimumGlyphScale))
                    .multilineTextAlignment(.center)
                    .lineSpacing(max(1, artworkRect.height * 0.012))
                    .foregroundStyle(specimenTextColor.opacity(0.90))
                    .frame(
                        width: artworkRect.width * CGFloat(plan.glyphSafeRegion.width),
                        height: artworkRect.height * CGFloat(plan.glyphSafeRegion.height)
                    )
                    .position(
                        x: artworkRect.minX + artworkRect.width
                            * CGFloat(plan.glyphSafeRegion.x + plan.glyphSafeRegion.width / 2),
                        y: artworkRect.minY + artworkRect.height
                            * CGFloat(plan.glyphSafeRegion.y + plan.glyphSafeRegion.height / 2)
                    )
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHidden(true)
    }

    private func fittedArtworkRect(in size: CGSize) -> CGRect {
        let aspect = max(0.01, CGFloat(plan.artworkAspectRatio))
        let containerAspect = size.width / max(1, size.height)
        if aspect >= containerAspect {
            let height = size.width / aspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * aspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private var specimenTextColor: Color {
        plan.usesPrimaryTextColor ? .runeTextPrimary : .runeTextInverse
    }
}

/// The production artifact specimen used by pickers and by fixed-size
/// qualification hosts. The host selects only the semantic presentation style;
/// artwork always comes from the runtime-owned Theme resource path.
struct ThemeArtifactSpecimenView<Artwork: View>: View {
    let item: ThemeArtifactBrowserItem
    let style: ThemeArtifactSpecimenStyle
    let relicLayout: ThemeShareLayoutPreset?
    let backgroundImage: Image?
    let artworkAspectRatio: Double
    private let artwork: Artwork
    @EnvironmentObject private var session: RuneScribeUISession

    init(
        item: ThemeArtifactBrowserItem,
        style: ThemeArtifactSpecimenStyle,
        relicLayout: ThemeShareLayoutPreset? = nil,
        backgroundImage: Image? = nil,
        artworkAspectRatio: Double? = nil,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.item = item
        self.style = style
        self.relicLayout = relicLayout
        self.backgroundImage = backgroundImage
        self.artworkAspectRatio = artworkAspectRatio
            ?? relicLayout.map {
                Double($0.aspectRatio.width) / Double($0.aspectRatio.height)
            }
            ?? 1
        self.artwork = artwork()
    }

    @ViewBuilder
    var body: some View {
        switch style {
        case .catalogCard:
            catalogCard
        case .artwork:
            GeometryReader { geometry in
                let layout = CodexArtifactSpecimenLayout(
                    kind: item.kind,
                    maximumGlyphLines: relicLayout?.maximumGlyphLines
                )
                let artworkFrame = layout.artworkFrame(
                    in: geometry.size,
                    artworkAspectRatio: artworkAspectRatio
                )
                ZStack {
                    specimenBackground(in: geometry.size)

                    artworkSurface
                        .frame(
                            width: artworkFrame.width,
                            height: artworkFrame.height
                        )
                        .position(x: artworkFrame.midX, y: artworkFrame.midY)

                    specimenFacets(in: geometry.size)
                    specimenBorder(in: geometry.size)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
    }

    private var catalogCard: some View {
        ThemeChromeProtectedContentLayout(
            panelPixelSize: panelBorderPixelSize,
            minimumInsets: EdgeInsets(
                top: 0,
                leading: 0,
                bottom: 0,
                trailing: 0
            )
        ) {
            GeometryReader { geometry in
                let scale = max(
                    0.5,
                    min(geometry.size.width / 172, geometry.size.height / 307)
                )
                VStack(spacing: 0) {
                    VStack(spacing: 2 * scale) {
                        Text(catalogHeading)
                            .font(.system(
                                size: 10 * scale,
                                weight: .medium,
                                design: .rounded
                            ))
                            .fontWidth(.condensed)
                            .tracking(0.45 * scale)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(catalogAvailability)
                            .font(.system(
                                size: 9 * scale,
                                weight: .medium,
                                design: .rounded
                            ))
                            .fontWidth(.condensed)
                            .tracking(0.35 * scale)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Color.runeTextPrimary)
                    .frame(height: 42 * scale, alignment: .top)
                    .padding(.top, 4 * scale)

                    artworkSurface
                        .frame(height: 187 * scale)
                        .padding(.horizontal, 8 * scale)

                    Text(item.description)
                        .font(.system(
                            size: 10 * scale,
                            weight: .regular,
                            design: .rounded
                        ))
                        .fontWidth(.condensed)
                        .foregroundStyle(Color.runeTextPrimary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(1.6 * scale)
                        .lineLimit(5)
                        .minimumScaleFactor(0.82)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .top
                        )
                        .padding(.horizontal, 14 * scale)
                        .padding(.top, 7 * scale)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .background {
            Color.runeNavy.opacity(0.97)
        }
        .overlay {
            ThemeChromeImage(slot: .panelBorder)
                .allowsHitTesting(false)
        }
        .aspectRatio(172 / 307, contentMode: .fit)
    }

    private var panelBorderPixelSize: ThemePixelSize? {
        session.activeThemeVisualPresentation?
            .chromeImageReference(for: .panelBorder)?
            .integrity.pixelSize
    }

    private var catalogHeading: String {
        let prefix = item.ordinal.map { "\($0). " } ?? ""
        return "\(prefix)\(item.name.uppercased())"
    }

    private var catalogAvailability: String {
        switch item.availability {
        case .included:
            "(INCLUDED)"
        case .earned, .mastery:
            "(UNLOCK)"
        case .encountered:
            "(ENCOUNTERED)"
        case .reservedInactive:
            "(UNAVAILABLE)"
        case nil:
            "(\(item.state.rawValue.uppercased()))"
        }
    }

    private var artworkSurface: some View {
        GeometryReader { geometry in
            artwork
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func specimenBackground(in size: CGSize) -> some View {
        if let backgroundImage {
            backgroundImage
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            Color.runeNavy
        }
    }

    @ViewBuilder
    private func specimenBorder(in size: CGSize) -> some View {
        ThemeChromeImage(slot: .panelBorder)
            .padding(.horizontal, borderHorizontalInset(in: size))
            .padding(.top, borderTopInset(in: size))
            .padding(.bottom, borderBottomInset(in: size))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func specimenFacets(in size: CGSize) -> some View {
        if specimenShape == .tablet, !item.facets.isEmpty {
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
            .position(x: size.width * 0.52, y: size.height * 0.925)
        }
    }

    private enum SpecimenShape: Equatable {
        case seal
        case plaque
        case tablet
        case stele
    }

    private var specimenShape: SpecimenShape {
        guard item.kind != .seal else { return .seal }
        guard let maximumGlyphLines = relicLayout?.maximumGlyphLines else {
            return .tablet
        }
        if maximumGlyphLines <= 4 { return .plaque }
        if maximumGlyphLines >= 7 { return .stele }
        return .tablet
    }

    private func borderHorizontalInset(in size: CGSize) -> CGFloat {
        switch specimenShape {
        case .seal: size.width * 0.055
        case .plaque: 0
        case .tablet: 8
        case .stele: 5
        }
    }

    private func borderTopInset(in size: CGSize) -> CGFloat {
        switch specimenShape {
        case .seal: size.width * 0.055
        case .plaque: 8
        case .tablet: 20
        case .stele: 5
        }
    }

    private func borderBottomInset(in size: CGSize) -> CGFloat {
        switch specimenShape {
        case .seal: size.width * 0.055
        case .plaque: -8
        case .tablet: -12
        case .stele: 5
        }
    }
}

struct ThemeArtifactTile<Artwork: View>: View {
    let item: ThemeArtifactBrowserItem
    let identifierPrefix: String
    let isInteractive: Bool
    let action: () -> Void
    private let artwork: Artwork

    init(
        item: ThemeArtifactBrowserItem,
        identifierPrefix: String = "theme.artifact-picker",
        isInteractive: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork
    ) {
        self.item = item
        self.identifierPrefix = identifierPrefix
        self.isInteractive = isInteractive
        self.action = action
        self.artwork = artwork()
    }

    var body: some View {
        Group {
            if isInteractive {
                Button(action: action) { tileContent }
                    .buttonStyle(.plain)
                    .disabled(!item.isSelectable)
            } else {
                tileContent
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(item.accessibilityHint ?? "")
        .accessibilityIdentifier("\(identifierPrefix).\(item.id.rawValue)")
        .runtimeViewportFrameProbe("\(identifierPrefix).\(item.id.rawValue)")
    }

    private var tileContent: some View {
        ThemeArtifactSpecimenView(item: item, style: .catalogCard) {
            artwork
        }
    }

    private var accessibilityValue: String {
        let base = "\(item.kind.rawValue), \(item.state.rawValue)"
        return item.provenance.map { "\(base), Source \($0)" } ?? base
    }
}

struct ThemeArtifactBrowserView<Artwork: View>: View {
    let title: String
    let items: [ThemeArtifactBrowserItem]
    let includesNone: Bool
    let canSelectNone: Bool
    let captureIdentifier: String?
    let selectNone: () -> Void
    let select: (ThemeArtifactBrowserItem) -> Void
    let artwork: (ThemeArtifactBrowserItem) -> Artwork
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        title: String,
        items: [ThemeArtifactBrowserItem],
        includesNone: Bool,
        canSelectNone: Bool,
        captureIdentifier: String? = nil,
        selectNone: @escaping () -> Void,
        select: @escaping (ThemeArtifactBrowserItem) -> Void,
        @ViewBuilder artwork: @escaping (ThemeArtifactBrowserItem) -> Artwork
    ) {
        self.title = title
        self.items = items
        self.includesNone = includesNone
        self.canSelectNone = canSelectNone
        self.captureIdentifier = captureIdentifier
        self.selectNone = selectNone
        self.select = select
        self.artwork = artwork
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if includesNone {
                    Button(action: selectNone) {
                        Label("No Frame", systemImage: "rectangle.slash")
                            .frame(maxWidth: .infinity, minHeight: 88)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                    .disabled(!canSelectNone)
                    .accessibilityIdentifier("theme.artifact-none.frame")
                }
                ForEach(items) { item in
                    ThemeArtifactTile(item: item, action: { select(item) }) {
                        artwork(item)
                    }
                }
            }
            .padding(RuneMetrics.pad)
            .themeCaptureIdentifier(captureIdentifier)
        }
        .navigationTitle(title)
        .accessibilityIdentifier("theme.artifact-picker")
        .runtimeViewportFrameProbe("theme.artifact-picker")
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 170, maximum: 260), spacing: 12, alignment: .top)]
    }
}

struct ThemeArtifactPreviewPageCursor: Equatable, Sendable {
    private(set) var index = 0

    mutating func reset() {
        index = 0
    }

    mutating func movePrevious() {
        index = max(0, index - 1)
    }

    mutating func moveNext(pageCount: Int) {
        guard pageCount > 0 else {
            index = 0
            return
        }
        index = min(pageCount - 1, index + 1)
    }

    func page<Page>(in pages: [Page]) -> Page? {
        guard pages.indices.contains(index) else { return pages.first }
        return pages[index]
    }
}

struct ThemeArtifactPreview: View {
    let plan: ThemeArtifactCompositionPlan
    let captureIdentifier: String?
    let maximumCanvasWidth: CGFloat?
    let image: (ThemeResourceID) -> Image?
    @State private var pageCursor = ThemeArtifactPreviewPageCursor()

    init(
        plan: ThemeArtifactCompositionPlan,
        captureIdentifier: String? = nil,
        maximumCanvasWidth: CGFloat? = nil,
        image: @escaping (ThemeResourceID) -> Image?
    ) {
        self.plan = plan
        self.captureIdentifier = captureIdentifier
        self.maximumCanvasWidth = maximumCanvasWidth
        self.image = image
    }

    var body: some View {
        VStack(spacing: 8) {
            if hasRequiredImages, let page = currentPage {
                artifactCanvas(page: page)
                    .accessibilityHidden(true)
                    .overlay { artifactCanvasAccessibilityElement(page: page) }

                if plan.pages.count > 1 {
                    HStack {
                        Button("Previous") { pageCursor.movePrevious() }
                            .disabled(pageCursor.index == 0)
                        Spacer()
                        Text("Page \(pageCursor.index + 1) of \(plan.pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.runeSilver)
                        Spacer()
                        Button("Next") {
                            pageCursor.moveNext(pageCount: plan.pages.count)
                        }
                        .disabled(pageCursor.index == plan.pages.count - 1)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                }
            } else {
                ThemeVisualPlaceholder(
                    systemImage: "photo.artframe",
                    label: "Artifact preview unavailable"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("theme.artifact-preview")
        .runtimeViewportFrameProbe("theme.artifact-preview")
        .onChange(of: plan.selection) { _, _ in pageCursor.reset() }
        .onChange(of: plan.pages) { _, _ in pageCursor.reset() }
    }

    private var currentPage: ShareArtifactRenderPage? {
        pageCursor.page(in: plan.pages)
    }

    private var artifactCanvasIdentifier: String {
        ThemeCaptureIdentifier.artifactPreview(relicID: plan.selection.relicID)
    }

    @ViewBuilder
    private func artifactCanvas(page: ShareArtifactRenderPage) -> some View {
        let canvas = ThemeArtifactCanvas(
            plan: plan,
            page: page,
            context: .interactivePreview,
            maximumWidth: maximumCanvasWidth,
            image: { requiredImage($0) }
        )
        canvas
    }

    private func artifactCanvasAccessibilityElement(
        page: ShareArtifactRenderPage
    ) -> some View {
        return Rectangle()
            .fill(Color.clear)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(plan.accessibilityLabel))
            .accessibilityValue(Text(page.inscription))
            .accessibilityHint(
                Text("The sender-rendered inscription remains available when its Codex is not.")
            )
            .accessibilityIdentifier(artifactCanvasIdentifier)
            .runtimeViewportFrameProbe(artifactCanvasIdentifier)
            .themeCaptureIdentifier(captureIdentifier)
            .allowsHitTesting(false)
    }

    private var hasRequiredImages: Bool {
        let resourceIDs = [
            plan.relicResourceID,
            plan.sealResourceID,
            plan.frameResourceID,
            plan.backgroundResourceID,
        ].compactMap { $0 }
        return resourceIDs.allSatisfy { image($0) != nil }
    }

    private func requiredImage(_ resourceID: ThemeResourceID) -> Image {
        image(resourceID) ?? Image(systemName: "photo")
    }
}
