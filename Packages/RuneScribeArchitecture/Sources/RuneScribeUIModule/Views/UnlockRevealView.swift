import Accessibility
import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

struct UnlockRevealView: View {
    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    let reveal: ProgressionRevealSummaryDTO
    let initialThemeVisualPresentation: ActiveThemeVisualPresentation?

    @State private var plan: UnlockRevealPresentationPlan?
    @State private var isVisible = false
    @State private var finishRequested = false

    init(
        reveal: ProgressionRevealSummaryDTO,
        initialPlan: UnlockRevealPresentationPlan? = nil,
        initialThemeVisualPresentation: ActiveThemeVisualPresentation? = nil
    ) {
        self.reveal = reveal
        self.initialThemeVisualPresentation = initialThemeVisualPresentation
        _plan = State(initialValue: initialPlan)
        _isVisible = State(initialValue: initialPlan != nil)
    }

    var body: some View {
        ZStack {
            VStack {
                Spacer()
                HStack {
                    Spacer(minLength: 12)
                    revealCard
                        .frame(maxWidth: 520)
                        .opacity(isVisible ? 1 : 0)
                        .scaleEffect(movementScale)
                        .offset(y: movementOffset)
                    Spacer(minLength: 12)
                }
                .padding(.bottom, 18)
            }
            if let identifier = masteryScreenCaptureIdentifier {
                Rectangle()
                    .fill(Color.black.opacity(0.001))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Mastery screen")
                    .accessibilityIdentifier(identifier)
                    .runtimeViewportFrameProbe(identifier)
                    .allowsHitTesting(false)
            }
        }
        .task(id: reveal.revealID) {
            await session.loadActiveThemeCatalogVisuals()
        }
        .task(id: reveal.revealID) {
            guard plan == nil else { return }
            while !Task.isCancelled {
                if let newPlan = await session.revealPresentationDidStart(
                    revealID: reveal.revealID,
                    reduceMotion: reduceMotion
                        || accessibilityPreferences.forcesReduceMotion
                ) {
                    plan = newPlan
                    present(using: newPlan)
                    if let announcement = newPlan.announcement {
                        AccessibilityNotification.Announcement(announcement).post()
                    }
                    if let delay = newPlan.automaticFinishDelaySeconds {
                        do {
                            try await Task.sleep(for: .seconds(delay))
                        } catch {
                            return
                        }
                        await requestFinish()
                    }
                    return
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private var revealCard: some View {
        ThemeChromeProtectedContentLayout(
            panelPixelSize: panelBorderPixelSize,
            minimumInsets: EdgeInsets(
                top: 18,
                leading: 18,
                bottom: 18,
                trailing: 18
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    primaryRewardVisual

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(reveal.rarity.rawValue) Unlock")
                            .font(.caption.weight(.bold))
                            .textCase(.uppercase)
                            .tracking(1.5)
                            .foregroundColor(.runeGoldBright)
                        Text(reveal.primaryRewardPresentation.displayName)
                            .font(.title3.bold())
                            .foregroundColor(.runeTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button("Dismiss") {
                        Task { await requestFinish() }
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.runeSilver)
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(finishRequested)
                }

                if let summary = reveal.primaryRewardPresentation.summary {
                    Text(summary)
                        .font(.body)
                        .foregroundColor(.runeSilver)
                        .fixedSize(horizontal: false, vertical: true)
                }

                masteryRewardVisuals

                if !reveal.secondaryRewardIDs.isEmpty {
                    Divider().overlay(Color.runeSilver.opacity(0.25))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Also unlocked")
                            .font(.caption.weight(.bold))
                            .foregroundColor(.runeSilver)
                        ForEach(
                            Array(reveal.secondaryRewardIDs.enumerated()),
                            id: \.offset
                        ) { _, reward in
                            Label(
                                rewardName(reward),
                                systemImage: "plus.circle.fill"
                            )
                            .font(.subheadline)
                            .foregroundColor(.runeTextPrimary)
                            .themeCaptureIdentifier(masteryRewardIdentifier(reward))
                        }
                    }
                }

                Text(sourceSummary)
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)
        )
        .overlay(
            ThemeChromeImage(slot: .panelBorder)
                .opacity(plan?.visualMode == .crossfadeHighlight ? 0.96 : 0.78)
                .allowsHitTesting(false)
        )
        .shadow(color: Color.black.opacity(0.38), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProgressionRevealPresentationPolicy.announcement(for: reveal))
        .accessibilityHint("Dismiss to continue; the rest of Rune Scribe remains available")
        .accessibilityHidden(plan == nil)
        .allowsHitTesting(plan != nil)
        .runtimeViewportFrameProbe("progression.unlock-reveal")
        .themeCaptureIdentifier(masteryPanelCaptureIdentifier)
    }

    private var panelBorderPixelSize: ThemePixelSize? {
        session.activeThemeVisualPresentation?
            .chromeImageReference(for: .panelBorder)?
            .integrity.pixelSize
    }

    @ViewBuilder
    private var primaryRewardVisual: some View {
        if let image = primaryRewardThemeImage {
            image
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
        } else {
            Image(systemName: reveal.primaryRewardPresentation.fallbackSystemImageName)
                .font(.title2.bold())
                .foregroundColor(.runeGoldBright)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.runeGold.opacity(0.18)))
                .accessibilityHidden(true)
        }
    }

    private var primaryRewardThemeImage: Image? {
        guard let presentation = masteryVisualPresentation else { return nil }

        let imagePlan: ThemeVisualImagePlan?
        switch reveal.primaryRewardID {
        case .codex(let codexID) where codexID == presentation.plan.codexID:
            imagePlan = presentation.plan.codex.card
        case .artifact(let artifactID):
            imagePlan = presentation.plan.catalog.first(where: {
                $0.id == artifactID
            })?.primary
        case .crest(let crestID):
            imagePlan = presentation.plan.crests.first(where: {
                $0.id.rawValue == crestID.rawValue
            })?.primary
        case .codex, .title, .entitlement, .unknown:
            imagePlan = nil
        }

        return imagePlan.flatMap {
            presentation.imageReference(for: $0)?.image
        }
    }

    @ViewBuilder
    private var masteryRewardVisuals: some View {
        if let presentation = masteryVisualPresentation,
           let frame = masteryFrameVisual,
           let crest = masteryCrestVisual,
           let frameImage = presentation.imageReference(for: frame.thumbnail)?.image,
           let crestImage = presentation.imageReference(for: crest.visual.thumbnail)?.image {
            Divider().overlay(Color.runeSilver.opacity(0.25))
            let titleReward = masteryTitleReward
            let frameIdentifier = ThemeCaptureIdentifier.masteryFrame(
                artifactID: frame.id
            )
            let crestIdentifier = ThemeCaptureIdentifier.masteryCrest(
                crestID: crest.id
            )
            CodexMasteryRewardsPanel(
                model: CodexMasteryRewardsPanelModel(
                    heading: "Mastery Rewards",
                    frameName: frame.displayName,
                    crestName: crest.visual.displayName,
                    titleName: titleReward?.name ?? "Mastery Title",
                    titleInscription: titleReward?.name ?? "Mastery",
                    titleGlyphInscription: masteryGlyphInscription,
                    accomplishment: reveal.primaryRewardPresentation.summary
                        ?? sourceSummary,
                    frameResourceID: frame.thumbnail.id,
                    crestResourceID: crest.visual.thumbnail.id,
                    frameCaptureIdentifier: frameIdentifier,
                    crestCaptureIdentifier: crestIdentifier,
                    titleCaptureIdentifier: titleReward.map {
                        ThemeCaptureIdentifier.masteryTitle(titleID: $0.id)
                    }
                ),
                style: .overview,
                image: { resourceID in
                    if resourceID == frame.thumbnail.id { return frameImage }
                    if resourceID == crest.visual.thumbnail.id { return crestImage }
                    preconditionFailure(
                        "Missing admitted mastery image: \(resourceID.rawValue)"
                    )
                }
            )
            .frame(height: 300)
        }
    }

    private var masteryTitleReward: (id: TitleID, name: String)? {
        for reward in allRewardIDs {
            guard case let .title(titleID) = reward else { continue }
            let name = session.progressionSnapshot?.titles.first(where: {
                $0.titleID == titleID
            })?.presentation.displayName ?? rewardName(reward)
            return (titleID, name)
        }
        return nil
    }

    private var masteryGlyphInscription: String? {
        guard let descriptor = session.themeSnapshot?.effectiveTheme,
              let script = descriptor.codex.scripts.first(where: {
                  $0.id == descriptor.codex.primaryScriptID
              })
        else { return nil }
        let inscription = script.glyphs.prefix(7).map(\.textToken).joined(separator: " ")
        return inscription.isEmpty ? nil : inscription
    }

    private var masteryCodexID: CodexID? {
        guard reveal.tier == .mastery else { return nil }
        for reward in allRewardIDs {
            if case .codex(let codexID) = reward { return codexID }
        }
        return nil
    }

    private var masteryFrameVisual: ThemeArtifactVisualPlan? {
        guard let presentation = masteryVisualPresentation else { return nil }
        let frameIDs = Set(allRewardIDs.compactMap { reward -> ArtifactID? in
            if case .artifact(let artifactID) = reward { return artifactID }
            return nil
        })
        return presentation.plan.frames.first(where: { frameIDs.contains($0.id) })
    }

    private var masteryCrestVisual: (id: CrestID, visual: ThemeArtifactVisualPlan)? {
        guard let presentation = masteryVisualPresentation else { return nil }
        for reward in allRewardIDs {
            guard case .crest(let crestID) = reward,
                  let visual = presentation.plan.crests.first(where: {
                      $0.id.rawValue == crestID.rawValue
                  })
            else { continue }
            return (crestID, visual)
        }
        return nil
    }

    private var allRewardIDs: [ProgressionContentReference] {
        [reveal.primaryRewardID] + reveal.secondaryRewardIDs
    }

    private func masteryRewardIdentifier(
        _ reward: ProgressionContentReference
    ) -> String? {
        guard case .title(let titleID) = reward else { return nil }
        return ThemeCaptureIdentifier.masteryTitle(titleID: titleID)
    }

    private func rewardName(_ reward: ProgressionContentReference) -> String {
        if case .title(let titleID) = reward,
           let title = session.progressionSnapshot?.titles.first(where: {
               $0.titleID == titleID
           }) {
            return title.presentation.displayName
        }
        return ProgressionRevealPresentationPolicy.contentName(reward)
    }

    private var masteryVisualsAreReady: Bool {
        guard let presentation = masteryVisualPresentation,
              let frame = masteryFrameVisual,
              let crest = masteryCrestVisual
        else { return false }
        return presentation.imageReference(for: frame.thumbnail)?.image != nil
            && presentation.imageReference(for: crest.visual.thumbnail)?.image != nil
    }

    private var masteryVisualPresentation: ActiveThemeVisualPresentation? {
        initialThemeVisualPresentation ?? session.activeThemeVisualPresentation
    }

    private var masteryPanelCaptureIdentifier: String? {
        guard plan != nil,
              masteryVisualsAreReady,
              let codexID = masteryCodexID
        else { return nil }
        return ThemeCaptureIdentifier.mastery(codexID: codexID)
    }

    private var masteryScreenCaptureIdentifier: String? {
        guard plan != nil,
              masteryVisualsAreReady,
              let codexID = masteryCodexID
        else { return nil }
        return ThemeCaptureIdentifier.masteryScreen(codexID: codexID)
    }

    private var sourceSummary: String {
        let achievements = reveal.sourceAchievementIDs.count
        let rules = reveal.sourceRuleIDs.count
        return switch (achievements, rules) {
        case (0, let rules):
            "Unlocked by \(rules) journey requirement\(rules == 1 ? "" : "s")."
        case (let achievements, 0):
            "Unlocked by \(achievements) achievement\(achievements == 1 ? "" : "s")."
        default:
            "Unlocked by \(achievements) achievement\(achievements == 1 ? "" : "s") and \(rules) journey requirement\(rules == 1 ? "" : "s")."
        }
    }

    private var movementScale: CGFloat {
        guard plan?.visualMode == .movement else { return 1 }
        return isVisible ? 1 : 0.96
    }

    private var movementOffset: CGFloat {
        guard plan?.visualMode == .movement else { return 0 }
        return isVisible ? 0 : 18
    }

    private func present(using plan: UnlockRevealPresentationPlan) {
        switch plan.visualMode {
        case .movement:
            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                isVisible = true
            }
        case .crossfadeHighlight:
            withAnimation(.easeInOut(duration: 0.28)) {
                isVisible = true
            }
        case .none:
            isVisible = true
        }
    }

    @MainActor
    private func requestFinish() async {
        guard !finishRequested else { return }
        finishRequested = true
        await session.finishRevealPresentation(revealID: reveal.revealID)
        finishRequested = false
    }
}
