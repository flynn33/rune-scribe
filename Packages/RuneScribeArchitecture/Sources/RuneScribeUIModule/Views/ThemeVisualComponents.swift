import RuneScribeContracts
import SwiftUI

/// Displays an optional provider-owned chrome resource without exposing Theme
/// implementation details to the shared UI. Each resource stays bound to the
/// active visual-plan revision through `ActiveThemeVisualPresentation`.
struct ThemeChromeImage: View {
    @EnvironmentObject private var session: RuneScribeUISession

    let slot: ThemeChromeVisualSlot

    var body: some View {
        if let reference = session.activeThemeVisualPresentation?
            .chromeImageReference(for: slot),
           let image = reference.image {
            switch slot {
            case .cornerOrnament:
                image
                    .resizable()
                    .scaledToFit()
                    .accessibilityHidden(true)
            case .panelBorder, .divider, .primaryButton, .tabSelector:
                image
                    .resizable(resizingMode: .stretch)
                    .clipped()
                    .accessibilityHidden(true)
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
    case unavailable = "Unavailable"
    case selected = "Selected"

    var systemImage: String {
        switch self {
        case .owned: "checkmark.seal"
        case .locked: "lock.fill"
        case .encountered: "eye"
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
    let action: () -> Void
    private let artwork: Artwork

    init(
        codexID: CodexID,
        displayName: String,
        summary: String,
        state: ThemeVisualContentState,
        accessibilityLabel: String,
        accessibilityHint: String = "",
        isEnabled: Bool,
        identifierPrefix: String = "theme.codex-card",
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
        self.action = action
        self.artwork = artwork()
    }

    var body: some View {
        Button(action: action) {
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
            .padding(12)
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
                .opacity(0.12)
                .clipped()
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(state.rawValue)
        .accessibilityHint(accessibilityHint)
        .accessibilityIdentifier("\(identifierPrefix).\(codexID.rawValue)")
        .runtimeViewportFrameProbe("\(identifierPrefix).\(codexID.rawValue)")
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
                        .opacity(0.22)
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
        .accessibilityIdentifier(
            item.map { "theme.artifact-thumbnail.\($0.id.rawValue)" }
                ?? "theme.artifact-selection.\(kind.rawValue.lowercased())"
        )
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
    let kind: ThemeVisualArtifactKind
    let rarity: ThemeRarityToken
    let state: ThemeVisualContentState
    let accessibilityLabel: String
    let accessibilityHint: String?
    let provenance: String?
    let isSelectable: Bool
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
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                artwork
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            Text(item.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.runeTextPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(item.description)
                .font(.caption)
                .foregroundStyle(Color.runeSilver)
                .fixedSize(horizontal: false, vertical: true)
            if let provenance = item.provenance {
                Text("Source: \(provenance)")
                    .font(.caption2)
                    .foregroundStyle(Color.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(item.kind.rawValue)
                Spacer()
                Label(item.state.rawValue, systemImage: item.state.systemImage)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(item.state == .locked ? Color.runeLocked : Color.runeSilver)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)
        )
        .overlay {
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder(Color.runeRarity(item.rarity).opacity(0.45), lineWidth: 1)
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
    let selectNone: () -> Void
    let select: (ThemeArtifactBrowserItem) -> Void
    let artwork: (ThemeArtifactBrowserItem) -> Artwork
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

struct ThemeArtifactPreview: View {
    let plan: ThemeArtifactCompositionPlan
    let image: (ThemeResourceID) -> Image?
    @State private var pageIndex = 0

    var body: some View {
        VStack(spacing: 8) {
            if hasRequiredImages, let page = currentPage {
                ThemeArtifactCanvas(
                    plan: plan,
                    page: page,
                    context: .interactivePreview,
                    image: { requiredImage($0) }
                )
                .accessibilityIdentifier("theme.artifact-preview.\(plan.selection.relicID.rawValue)")

                if plan.pages.count > 1 {
                    HStack {
                        Button("Previous") { pageIndex = max(0, pageIndex - 1) }
                            .disabled(pageIndex == 0)
                        Spacer()
                        Text("Page \(pageIndex + 1) of \(plan.pages.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(Color.runeSilver)
                        Spacer()
                        Button("Next") { pageIndex = min(plan.pages.count - 1, pageIndex + 1) }
                            .disabled(pageIndex == plan.pages.count - 1)
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
        .onChange(of: plan.selection) { _, _ in pageIndex = 0 }
    }

    private var currentPage: ShareArtifactRenderPage? {
        guard plan.pages.indices.contains(pageIndex) else { return plan.pages.first }
        return plan.pages[pageIndex]
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
