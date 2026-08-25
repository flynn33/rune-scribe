import Foundation
import RuneScribeContracts
import SwiftUI

enum VaultProgressSection: String, CaseIterable, Identifiable, Sendable {
    case journey = "Journey"
    case achievements = "Achievements"
    case statistics = "Statistics"
    case vault = "Vault"
    case archive = "Archive"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .journey: "map"
        case .achievements: "medal"
        case .statistics: "chart.bar.xaxis"
        case .vault: "lock.open"
        case .archive: "books.vertical"
        }
    }
}

enum VaultProgressInitialViewport: Hashable, Sendable {
    case journey(CodexID)
    case achievement(AchievementID)
    case artifact(ArtifactID)

    var id: String {
        switch self {
        case .journey(let codexID): "journey.\(codexID.rawValue)"
        case .achievement(let achievementID): "achievement.\(achievementID.rawValue)"
        case .artifact(let artifactID): "artifact.\(artifactID.rawValue)"
        }
    }
}

enum ProgressionAchievementPath: String, CaseIterable, Sendable {
    case scribe = "Scribe"
    case courier = "Courier"
    case archivist = "Archivist"
    case crossPath = "Cross-path"
}

struct AchievementCardPresentation: Equatable, Sendable {
    let title: String
    let summary: String
    let systemImage: String
    let status: String
    let progressValue: UInt64
    let progressTarget: UInt64
    let points: UInt16
    let rewardCount: Int
    let completedAt: Date?
    let isSecretPlaceholder: Bool
}

struct ThemeCatalogCardPresentation: Identifiable, Equatable, Sendable {
    let id: String
    let artifactID: ArtifactID
    let name: String
    let description: String
    let kind: ThemeVisualArtifactKind
    let rarity: ThemeRarityToken
    let resourceID: ThemeResourceID
    let state: ThemeVisualContentState
    let accessibilityLabel: String
    let accessibilityHint: String?
    let provenance: String?

    var isOwned: Bool { state == .owned || state == .selected }
}

enum VaultProgressPresentation {
    private static let scribeIDs: Set<String> = [
        "achievement.first-inscription",
        "achievement.archivist-1",
        "achievement.archivist-2",
    ]
    private static let courierIDs: Set<String> = [
        "achievement.first-dispatch",
        "achievement.courier-1",
        "achievement.courier-2",
        "achievement.five-circles",
    ]
    private static let archivistIDs: Set<String> = [
        "achievement.echo-returns",
        "achievement.correspondent",
        "achievement.explorer",
    ]

    static func journeyColumnCount(for width: CGFloat) -> Int {
        width >= 720 ? 2 : 1
    }

    static func achievementPath(
        for achievementID: AchievementID
    ) -> ProgressionAchievementPath {
        let rawValue = achievementID.rawValue
        if scribeIDs.contains(rawValue) { return .scribe }
        if courierIDs.contains(rawValue) { return .courier }
        if archivistIDs.contains(rawValue) { return .archivist }
        return .crossPath
    }

    static func achievementCard(
        for achievement: ProgressionAchievementDTO
    ) -> AchievementCardPresentation {
        if achievement.isHidden && achievement.completedAt == nil {
            return AchievementCardPresentation(
                title: "Hidden Achievement",
                summary: "Keep exploring to discover this achievement.",
                systemImage: "questionmark.diamond",
                status: "Undiscovered",
                progressValue: 0,
                progressTarget: 1,
                points: 0,
                rewardCount: 0,
                completedAt: nil,
                isSecretPlaceholder: true
            )
        }

        return AchievementCardPresentation(
            title: achievement.presentation.displayName,
            summary: achievement.presentation.summary ?? "Achievement details unavailable.",
            systemImage: achievement.presentation.fallbackSystemImageName,
            status: achievement.completedAt == nil ? "In progress" : "Completed",
            progressValue: achievement.progress.current,
            progressTarget: achievement.progress.target,
            points: achievement.localPointWeight,
            rewardCount: rewardCount(achievement.rewards),
            completedAt: achievement.completedAt,
            isSecretPlaceholder: false
        )
    }

    static func rewardCount(_ rewards: ProgressionRewardSummaryDTO) -> Int {
        rewards.codexIDs.count
            + rewards.contentIDs.count
            + rewards.entitlementIDs.count
            + rewards.titleIDs.count
            + rewards.crestIDs.count
    }

    static func ownedContent(
        from ownership: [ProgressionOwnershipDTO]
    ) -> [ProgressionOwnershipDTO] {
        ownership.filter { $0.state == .owned }
    }

    static func themeCatalog(
        descriptor: ThemeDescriptor,
        ownership: [ProgressionOwnershipDTO],
        providerAvailable: Bool = true,
        selectedArtifactIDs: Set<ArtifactID> = []
    ) -> [ThemeCatalogCardPresentation] {
        let ownershipByID = Dictionary(uniqueKeysWithValues: ownership.compactMap {
            item -> (String, ProgressionContentOwnershipState)? in
            switch item.reference {
            case .artifact(let id): return (id.rawValue, item.state)
            case .crest(let id): return (id.rawValue, item.state)
            default: return nil
            }
        })
        let rightsByID = Dictionary(uniqueKeysWithValues: descriptor.rights.map {
            ($0.id, $0.sourceReference)
        })
        let relics = descriptor.codex.relics.compactMap { relic -> ThemeCatalogCardPresentation? in
            guard relic.metadata.availability != .reservedInactive else { return nil }
            return catalogItem(
                relic.metadata,
                kind: .relic,
                resourceID: relic.thumbnailResourceID,
                ownershipByID: ownershipByID,
                rightsByID: rightsByID,
                providerAvailable: providerAvailable,
                selectedArtifactIDs: selectedArtifactIDs
            )
        }
        let seals = descriptor.codex.seals.compactMap { seal -> ThemeCatalogCardPresentation? in
            guard seal.metadata.availability != .reservedInactive else { return nil }
            return catalogItem(
                seal.metadata,
                kind: .seal,
                resourceID: seal.thumbnailResourceID,
                ownershipByID: ownershipByID,
                rightsByID: rightsByID,
                providerAvailable: providerAvailable,
                selectedArtifactIDs: selectedArtifactIDs
            )
        }
        let frames = descriptor.codex.frames.compactMap { frame -> ThemeCatalogCardPresentation? in
            guard frame.metadata.availability != .reservedInactive else { return nil }
            return catalogItem(
                frame.metadata,
                kind: .frame,
                resourceID: frame.staticFallbackResourceID,
                ownershipByID: ownershipByID,
                rightsByID: rightsByID,
                providerAvailable: providerAvailable,
                selectedArtifactIDs: selectedArtifactIDs
            )
        }
        let crests = descriptor.codex.crests.compactMap { crest -> ThemeCatalogCardPresentation? in
            guard crest.metadata.availability != .reservedInactive else { return nil }
            return catalogItem(
                crest.metadata,
                kind: .crest,
                resourceID: crest.staticFallbackResourceID,
                ownershipByID: ownershipByID,
                rightsByID: rightsByID,
                providerAvailable: providerAvailable,
                selectedArtifactIDs: selectedArtifactIDs
            )
        }
        return relics + seals + frames + crests
    }

    private static func catalogItem(
        _ metadata: ThemeArtifactMetadata,
        kind: ThemeVisualArtifactKind,
        resourceID: ThemeResourceID,
        ownershipByID: [String: ProgressionContentOwnershipState],
        rightsByID: [ThemeProvenanceID: String],
        providerAvailable: Bool,
        selectedArtifactIDs: Set<ArtifactID>
    ) -> ThemeCatalogCardPresentation {
        let ownership = ownershipByID[metadata.id.rawValue]
        let state: ThemeVisualContentState = if !providerAvailable {
            .unavailable
        } else if selectedArtifactIDs.contains(metadata.id)
                    && (metadata.availability == .included || ownership == .owned) {
            .selected
        } else if metadata.availability == .included || ownership == .owned {
            .owned
        } else if ownership == .encountered {
            .encountered
        } else {
            .locked
        }
        return ThemeCatalogCardPresentation(
            id: metadata.id.rawValue,
            artifactID: metadata.id,
            name: metadata.displayName.fallbackValue,
            description: metadata.description.fallbackValue,
            kind: kind,
            rarity: metadata.rarity,
            resourceID: resourceID,
            state: state,
            accessibilityLabel: metadata.accessibility.label.fallbackValue,
            accessibilityHint: metadata.accessibility.hint?.fallbackValue,
            provenance: rightsByID[metadata.rightsID]
        )
    }

    static func providerLabel(
        availability: ProgressionProviderAvailability,
        renderState: ProgressionContentRenderState
    ) -> String {
        switch (availability, renderState) {
        case (.active, .providerAvailable):
            "Provider active"
        case (.failed, .providerFailed):
            "Provider unavailable — standard presentation in use"
        case (.eligible, .genericFallback):
            "Provider eligible — standard presentation in use"
        default:
            "Standard presentation"
        }
    }

    static func archiveTitle(for entry: ProgressionArchiveEntryDTO) -> String {
        switch entry.supportState {
        case .known: entry.presentation.displayName
        case .unsupported: "Unsupported encountered content"
        case .unknown: "Unknown encountered content"
        }
    }

    static func archiveSupportLabel(
        _ state: ProgressionArchiveSupportState
    ) -> String {
        switch state {
        case .known: "Known"
        case .unsupported: "Unsupported — shown generically"
        case .unknown: "Unknown — shown generically"
        }
    }

    static func contentKindLabel(_ kind: ProgressionContentKind) -> String {
        switch kind {
        case .codex: "Codex"
        case .crest: "Crest"
        case .entitlement: "Entitlement"
        case .frame: "Frame"
        case .relic: "Relic"
        case .script: "Script"
        case .seal: "Seal"
        case .title: "Title"
        case .unknown: "Unknown"
        }
    }

    static func provenanceLabel(_ status: DomainEventProvenanceStatus) -> String {
        switch status {
        case .absent: "No provenance"
        case .unverified: "Unverified provenance"
        case .verified: "Verified provenance"
        case .invalid: "Invalid provenance"
        case .unsupported: "Unsupported provenance"
        }
    }
}

struct VaultProgressView: View {
    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var section: VaultProgressSection
    @State private var initialScrollTarget: String?

    init(
        initialSection: VaultProgressSection = .journey,
        initialViewport: VaultProgressInitialViewport? = nil
    ) {
        _section = State(initialValue: initialSection)
        _initialScrollTarget = State(initialValue: initialViewport?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .vault,
                subtitle: "Vault & Progress",
                trailingButtons: [
                    RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() },
                ]
            )

            sectionPicker

            Group {
                switch session.progressionRailState {
                case .loading:
                    loadingView
                case .unavailable:
                    unavailableView
                case .available, .degraded:
                    if let snapshot = session.progressionSnapshot {
                        availableContent(snapshot)
                    } else {
                        unavailableView
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSemanticPresentationSurface()
        .preferredColorScheme(.dark)
        .modifier(VaultProgressFrameModifier())
        .task { await session.loadActiveThemeCatalogVisuals() }
        .alert("Progress Unavailable", isPresented: Binding(
            get: { session.progressionCommandError != nil },
            set: { if !$0 { session.dismissProgressionCommandError() } }
        )) {
            Button("OK") { session.dismissProgressionCommandError() }
        } message: {
            Text(session.progressionCommandError ?? "")
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VaultProgressSection.allCases) { item in
                    Button {
                        section = item
                    } label: {
                        Label(item.rawValue, systemImage: item.systemImage)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(
                                Capsule()
                                    .fill(section == item
                                          ? Color.runeSelected.opacity(0.22)
                                          : Color.runeParchment)
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    section == item ? Color.runeSelected : Color.runeSilver.opacity(0.2),
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(section == item ? .runeSelected : .runeTextPrimary)
                    .accessibilityValue(section == item ? "Selected" : "Not selected")
                }
            }
            .padding(.horizontal, RuneMetrics.pad)
            .padding(.vertical, 12)
        }
        .background(Color.runeBackgroundSecondary.opacity(0.48))
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.runeGold)
            Text("Loading local progress…")
                .foregroundColor(.runeSilver)
        }
        .accessibilityElement(children: .combine)
    }

    private var unavailableView: some View {
        VStack {
            RunePanel(title: "Progress", systemImage: "circle.dashed", accent: .runeSilver) {
                Label(
                    "Progress and Vault details are temporarily unavailable. Rune Scribe remains ready for messages and ciphers.",
                    systemImage: "info.circle"
                )
                .font(.body)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560)
        }
        .padding(RuneMetrics.pad)
    }

    @ViewBuilder
    private func availableContent(_ snapshot: ProgressionSnapshotDTO) -> some View {
        VStack(spacing: 0) {
            if session.progressionRailState == .degraded {
                Label(
                    "Progress is read-only while local records recover.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote.weight(.semibold))
                .foregroundColor(.runeGoldBright)
                .padding(.horizontal, RuneMetrics.pad)
                .padding(.bottom, 8)
                .accessibilityLabel("Progress is read only while local records recover")
            }

            GeometryReader { geometry in
                ScrollView {
                    Group {
                        switch section {
                        case .journey:
                            journey(snapshot, width: geometry.size.width)
                        case .achievements:
                            achievements(snapshot)
                        case .statistics:
                            statistics(snapshot)
                        case .vault:
                            vault(snapshot)
                        case .archive:
                            archive(snapshot)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.automatic)
                .scrollPosition(id: $initialScrollTarget, anchor: .center)
            }
        }
    }

    private func journey(
        _ snapshot: ProgressionSnapshotDTO,
        width: CGFloat
    ) -> some View {
        let columnCount = VaultProgressPresentation.journeyColumnCount(for: width)
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: RuneMetrics.sectionGap, alignment: .top),
            count: columnCount
        )
        let ownershipByCodex = Dictionary(
            uniqueKeysWithValues: snapshot.ownership.compactMap { item -> (CodexID, ProgressionOwnershipDTO)? in
                guard case .codex(let codexID) = item.reference else { return nil }
                return (codexID, item)
            }
        )

        return VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
            Text("The Journey")
                .font(.title2.bold())
                .foregroundColor(.runeTextPrimary)
            Text("Codices unlock permanently as every listed component is completed. Later activity never removes an unlocked Codex.")
                .font(.body)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, alignment: .leading, spacing: RuneMetrics.sectionGap) {
                ForEach(snapshot.codexGates.sorted(by: { $0.journeyOrder < $1.journeyOrder }), id: \.codexID) { gate in
                    journeyCard(gate, ownership: ownershipByCodex[gate.codexID])
                        .id(VaultProgressInitialViewport.journey(gate.codexID).id)
                }
            }
            .scrollTargetLayout()

            if snapshot.codexGates.isEmpty {
                emptyState(
                    title: "Journey not available",
                    detail: "Codex requirements will appear when the Progression provider supplies them."
                )
            }
        }
        .padding(RuneMetrics.pad)
    }

    private func journeyCard(
        _ gate: ProgressionCodexGateDTO,
        ownership: ProgressionOwnershipDTO?
    ) -> some View {
        RunePanel(
            title: gate.presentation.displayName,
            systemImage: gate.presentation.fallbackSystemImageName,
            accent: gate.unlockedAt == nil ? .runeBlue : .runeGold
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    gate.unlockedAt == nil ? "In progress" : "Permanently unlocked",
                    systemImage: gate.unlockedAt == nil ? "circle.dashed" : "checkmark.seal.fill"
                )
                .font(.subheadline.bold())
                .foregroundColor(gate.unlockedAt == nil ? .runeSilver : .runeGoldBright)

                if let summary = gate.presentation.summary {
                    Text(summary)
                        .font(.body)
                        .foregroundColor(.runeSilver)
                }

                ProgressView(
                    value: Double(gate.progress.current),
                    total: Double(gate.progress.target)
                )
                .tint(gate.unlockedAt == nil ? .runeBlue : .runeGold)
                .accessibilityLabel("Codex progress")
                .accessibilityValue("\(gate.progress.current) of \(gate.progress.target)")

                Label(
                    "\(gate.completedRuleCount) of \(gate.requiredRuleCount) requirements complete",
                    systemImage: "list.bullet.clipboard"
                )
                .font(.footnote)
                .foregroundColor(.runeSilver)

                if !gate.components.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(gate.components, id: \.componentID) { component in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: component.isComplete
                                      ? "checkmark.circle.fill"
                                      : "circle.dashed")
                                    .accessibilityHidden(true)
                                Text(component.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(component.current)/\(component.target)")
                                    .monospacedDigit()
                            }
                            .font(.footnote)
                            .foregroundColor(component.isComplete ? .runeGoldBright : .runeSilver)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(component.label)
                            .accessibilityValue(
                                "\(component.isComplete ? "Complete" : "In progress"), "
                                    + "\(component.current) of \(component.target)"
                            )
                        }
                    }
                }

                if let ownership {
                    Text(VaultProgressPresentation.providerLabel(
                        availability: ownership.providerAvailability,
                        renderState: ownership.renderState
                    ))
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                } else {
                    Text("Standard Codex card")
                        .font(.footnote)
                        .foregroundColor(.runeSilver)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func achievements(_ snapshot: ProgressionSnapshotDTO) -> some View {
        VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
            Text("Achievements")
                .font(.title2.bold())
                .foregroundColor(.runeTextPrimary)

            ForEach(ProgressionAchievementPath.allCases, id: \.self) { path in
                let items = snapshot.achievements.filter {
                    VaultProgressPresentation.achievementPath(for: $0.achievementID) == path
                }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(path.rawValue)
                            .font(.headline)
                            .foregroundColor(.runeGoldBright)
                        ForEach(items, id: \.achievementID) { achievement in
                            achievementCard(achievement)
                                .id(VaultProgressInitialViewport
                                    .achievement(achievement.achievementID).id)
                        }
                    }
                    .scrollTargetLayout()
                }
            }

            if snapshot.achievements.isEmpty {
                emptyState(
                    title: "Achievements not available",
                    detail: "Achievement progress will appear when local progress is available."
                )
            }
        }
        .padding(RuneMetrics.pad)
    }

    private func achievementCard(_ achievement: ProgressionAchievementDTO) -> some View {
        let card = VaultProgressPresentation.achievementCard(for: achievement)
        return RunePanel(
            title: card.title,
            systemImage: card.systemImage,
            accent: card.completedAt == nil ? .runeBlue : .runeGold
        ) {
            VStack(alignment: .leading, spacing: 9) {
                Label(
                    card.status,
                    systemImage: card.completedAt == nil ? "circle.dashed" : "checkmark.circle.fill"
                )
                .font(.subheadline.bold())
                .foregroundColor(card.completedAt == nil ? .runeSilver : .runeGoldBright)

                Text(card.summary)
                    .font(.body)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if !card.isSecretPlaceholder {
                    ProgressView(value: Double(card.progressValue), total: Double(card.progressTarget))
                        .tint(card.completedAt == nil ? .runeBlue : .runeGold)
                        .accessibilityLabel("Achievement progress")
                        .accessibilityValue("\(card.progressValue) of \(card.progressTarget)")

                    Text("\(card.points) points • \(card.rewardCount) rewards")
                        .font(.footnote.monospacedDigit())
                        .foregroundColor(.runeSilver)

                    if let completedAt = card.completedAt {
                        Text("Completed \(completedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote)
                            .foregroundColor(.runeSilver)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
        .accessibilityIdentifier("progression.achievement.\(achievement.achievementID.rawValue)")
        .runtimeViewportFrameProbe(
            "progression.achievement.\(achievement.achievementID.rawValue)"
        )
    }

    private func statistics(_ snapshot: ProgressionSnapshotDTO) -> some View {
        VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
            Text("Statistics")
                .font(.title2.bold())
                .foregroundColor(.runeTextPrimary)
            Text("On-device totals only. Names, message text, keys, contacts, and package contents are never shown here.")
                .font(.body)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(snapshot.statistics, id: \.statisticID) { statistic in
                RunePanel(
                    title: statistic.presentation.displayName,
                    systemImage: statistic.presentation.fallbackSystemImageName,
                    accent: .runeBlue
                ) {
                    HStack(alignment: .firstTextBaseline) {
                        if let summary = statistic.presentation.summary {
                            Text(summary)
                                .font(.body)
                                .foregroundColor(.runeSilver)
                        }
                        Spacer(minLength: 12)
                        Text(statistic.value.formatted())
                            .font(.title2.bold().monospacedDigit())
                            .foregroundColor(.runeTextPrimary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(statistic.value.formatted())
                }
            }

            if snapshot.statistics.isEmpty {
                emptyState(
                    title: "No statistics yet",
                    detail: "Privacy-safe local totals will appear after activity is recorded."
                )
            }
        }
        .padding(RuneMetrics.pad)
    }

    private func vault(_ snapshot: ProgressionSnapshotDTO) -> some View {
        let ownedContent = VaultProgressPresentation.ownedContent(from: snapshot.ownership)
        let ownedTitles = snapshot.titles.filter(\.isOwned)

        return VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
            Text("Vault")
                .font(.title2.bold())
                .foregroundColor(.runeTextPrimary)
            Text("Browse the active Codex catalog. Locked rewards remain unavailable until Progression grants them.")
                .font(.body)
                .foregroundColor(.runeSilver)

            if let descriptor = session.themeSnapshot?.effectiveTheme {
                activeCodexCard(descriptor)
                themeCollection(
                    VaultProgressPresentation.themeCatalog(
                        descriptor: descriptor,
                        ownership: snapshot.ownership,
                        providerAvailable: session.themeSnapshot?.isEmergencyPresentation == false,
                        selectedArtifactIDs: Set([
                            session.selectedThemeRelicID,
                            session.selectedThemeSealID,
                            session.selectedThemeFrameID,
                        ].compactMap { $0 })
                    )
                )
            }

            RunePanel(title: "Selected Title", systemImage: "textformat", accent: .runeGold) {
                Picker("Selected Title", selection: Binding(
                    get: { snapshot.selectedTitleID },
                    set: { titleID in
                        Task { await session.selectProgressionTitle(titleID) }
                    }
                )) {
                    Text("No title").tag(Optional<TitleID>.none)
                    ForEach(ownedTitles, id: \.titleID) { title in
                        Text(title.presentation.displayName)
                            .tag(Optional(title.titleID))
                    }
                }
                .pickerStyle(.menu)
                .disabled(session.progressionRailState != .available)
                .accessibilityHint("Selects the title shown by Rune Scribe")
            }

            ForEach(ownedContent.indices, id: \.self) { index in
                ownedContentCard(ownedContent[index])
            }

            if ownedContent.isEmpty {
                emptyState(
                    title: "Vault is empty",
                    detail: "Permanently granted Codices, titles, relics, seals, scripts, frames, and crests will appear here."
                )
            }
        }
        .padding(RuneMetrics.pad)
    }

    private func themeCollection(_ items: [ThemeCatalogCardPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Codex Collection")
                .font(.headline)
                .foregroundColor(.runeGoldBright)
            LazyVGrid(columns: themeCatalogColumns, alignment: .leading, spacing: 12) {
                ForEach(items) { item in
                    let viewportID = VaultProgressInitialViewport.artifact(item.artifactID).id
                    ThemeArtifactTile(
                        item: ThemeArtifactBrowserItem(
                            id: item.artifactID,
                            resourceID: item.resourceID,
                            name: item.name,
                            description: item.description,
                            kind: item.kind,
                            rarity: item.rarity,
                            state: item.state,
                            accessibilityLabel: item.accessibilityLabel,
                            accessibilityHint: item.accessibilityHint,
                            provenance: item.provenance,
                            isSelectable: false
                        ),
                        identifierPrefix: "theme.vault-artifact",
                        isInteractive: false,
                        action: {}
                    ) {
                        vaultArtifactArtwork(item)
                    }
                    .overlay {
                        if initialScrollTarget == viewportID {
                            RoundedRectangle(
                                cornerRadius: RuneMetrics.corner,
                                style: .continuous
                            )
                            .strokeBorder(Color.runeGoldBright, lineWidth: 2)
                            .shadow(color: Color.runeGold.opacity(0.35), radius: 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .id(viewportID)
                }
            }
            .scrollTargetLayout()
        }
    }

    private func activeCodexCard(_ descriptor: ThemeDescriptor) -> some View {
        let isAvailable = session.themeSnapshot?.isEmergencyPresentation == false
        let provider = session.themeSnapshot?.providers.first(where: {
            $0.codexID == descriptor.codex.id
        })
        let selectedArtifacts = [
            session.activeThemeVisualPresentation?.plan.selectedRelic?.displayName,
            session.activeThemeVisualPresentation?.plan.selectedSeal?.displayName,
            session.activeThemeVisualPresentation?.plan.selectedFrame?.displayName,
        ].compactMap { $0 }.joined(separator: ", ")
        return RunePanel(title: "Active Codex", systemImage: "books.vertical", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 10) {
                ThemeCodexCardView(
                    codexID: descriptor.codex.id,
                    displayName: descriptor.codex.displayName.fallbackValue,
                    summary: descriptor.codex.shortDescription.fallbackValue,
                    state: isAvailable ? .selected : .unavailable,
                    accessibilityLabel: descriptor.codex.accessibility.label.fallbackValue,
                    accessibilityHint: descriptor.codex.accessibility.hint?.fallbackValue ?? "",
                    isEnabled: false,
                    identifierPrefix: "theme.vault",
                    action: {}
                ) {
                    vaultCodexArtwork(descriptor, unavailable: !isAvailable)
                }
                Label(
                    isAvailable ? "Provider available" : "Provider unavailable; safe presentation in use",
                    systemImage: isAvailable ? "checkmark.circle" : "exclamationmark.circle"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(isAvailable ? Color.runeGoldBright : Color.runeWarning)
                Label(
                    provider?.isOwned == true ? "Owned and selected" : "Ownership unavailable",
                    systemImage: provider?.isOwned == true ? "checkmark.seal" : "lock.fill"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(provider?.isOwned == true ? Color.runeGoldBright : Color.runeLocked)
                Text("Script: \(descriptor.codex.primaryScriptID.rawValue)")
                    .font(.footnote)
                    .foregroundStyle(Color.runeSilver)
                if !selectedArtifacts.isEmpty {
                    Text("Selected artifacts: \(selectedArtifacts)")
                        .font(.footnote)
                        .foregroundStyle(Color.runeSilver)
                }
            }
        }
    }

    private var themeCatalogColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 12, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 12, alignment: .top)]
    }

    private func vaultCodexArtwork(
        _ descriptor: ThemeDescriptor,
        unavailable: Bool
    ) -> AnyView {
        if let presentation = session.activeThemeVisualPresentation {
            let imagePlan = unavailable
                ? presentation.plan.codex.unavailable
                : presentation.plan.codex.selected
            if let image = presentation.imageReference(for: imagePlan)?.image {
                return AnyView(image.resizable().scaledToFill())
            }
        }
        return AnyView(ThemeVisualPlaceholder(
            systemImage: "books.vertical",
            label: "\(descriptor.codex.displayName.fallbackValue) artwork unavailable"
        ))
    }

    private func vaultArtifactArtwork(_ item: ThemeCatalogCardPresentation) -> AnyView {
        if let image = session.activeThemeVisualPresentation?.image(for: item.resourceID) {
            return AnyView(image.resizable().scaledToFill())
        }
        return AnyView(ThemeVisualPlaceholder(
            systemImage: item.kind.systemImage,
            label: "\(item.name) artwork unavailable"
        ))
    }

    private func ownedContentCard(_ item: ProgressionOwnershipDTO) -> some View {
        RunePanel(
            title: item.presentation.displayName,
            systemImage: item.presentation.fallbackSystemImageName,
            accent: .runeGold
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Owned", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.bold())
                    .foregroundColor(.runeGoldBright)
                Text("Type: \(VaultProgressPresentation.contentKindLabel(item.kind))")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                Text(VaultProgressPresentation.providerLabel(
                    availability: item.providerAvailability,
                    renderState: item.renderState
                ))
                .font(.footnote)
                .foregroundColor(.runeSilver)
                Text(item.sourceRuleIDs.isEmpty
                     ? "Source: local grant"
                     : "Source: \(item.sourceRuleIDs.count) progression grant rules")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                if let grantedAt = item.grantedAt {
                    Text("Granted \(grantedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                        .foregroundColor(.runeSilver)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func archive(_ snapshot: ProgressionSnapshotDTO) -> some View {
        VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
            Text("Archive")
                .font(.title2.bold())
                .foregroundColor(.runeTextPrimary)
            Text("A record of encountered Codices and artifacts. Encountered does not mean owned.")
                .font(.body)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(snapshot.archive.indices, id: \.self) { index in
                archiveCard(snapshot.archive[index])
            }

            if snapshot.archive.isEmpty {
                emptyState(
                    title: "No encounters yet",
                    detail: "Encountered Codices and artifacts will appear without granting ownership."
                )
            }
        }
        .padding(RuneMetrics.pad)
    }

    private func archiveCard(_ entry: ProgressionArchiveEntryDTO) -> some View {
        RunePanel(
            title: VaultProgressPresentation.archiveTitle(for: entry),
            systemImage: entry.supportState != .known
                ? "questionmark.square.dashed"
                : entry.presentation.fallbackSystemImageName,
            accent: .runeSilver
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Encountered", systemImage: "eye")
                    .font(.subheadline.bold())
                    .foregroundColor(.runeTextPrimary)
                Text("Type: \(VaultProgressPresentation.contentKindLabel(entry.kind))")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                Text(VaultProgressPresentation.archiveSupportLabel(entry.supportState))
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                Text("First seen \(entry.firstEncounteredAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                Text("Last seen \(entry.lastEncounteredAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                Text("\(entry.encounterCount) encounters • \(VaultProgressPresentation.provenanceLabel(entry.provenanceStatus))")
                    .font(.footnote.monospacedDigit())
                    .foregroundColor(.runeSilver)
            }
            .accessibilityElement(children: .combine)
            .accessibilityHint("Archive encounter record; this does not indicate ownership")
        }
    }

    private func emptyState(title: String, detail: String) -> some View {
        RunePanel(title: title, systemImage: "tray", accent: .runeSilver) {
            Text(detail)
                .font(.body)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VaultProgressFrameModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content.frame(minWidth: 620, idealWidth: 900, minHeight: 680, idealHeight: 760)
        #else
        content.frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}
