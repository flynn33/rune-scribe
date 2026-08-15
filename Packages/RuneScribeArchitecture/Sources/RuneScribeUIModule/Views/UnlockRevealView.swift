import Accessibility
import RuneScribeContracts
import SwiftUI

struct UnlockRevealView: View {
    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let reveal: ProgressionRevealSummaryDTO

    @State private var plan: UnlockRevealPresentationPlan?
    @State private var isVisible = false
    @State private var finishRequested = false

    var body: some View {
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
        .accessibilityElement(children: .contain)
        .task(id: reveal.revealID) {
            while !Task.isCancelled {
                if let newPlan = await session.revealPresentationDidStart(
                    revealID: reveal.revealID,
                    reduceMotion: reduceMotion
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: reveal.primaryRewardPresentation.fallbackSystemImageName)
                    .font(.title2.bold())
                    .foregroundColor(.runeGoldBright)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Color.runeGold.opacity(0.18)))
                    .accessibilityHidden(true)

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

            if !reveal.secondaryRewardIDs.isEmpty {
                Divider().overlay(Color.runeSilver.opacity(0.25))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Also unlocked")
                        .font(.caption.weight(.bold))
                        .foregroundColor(.runeSilver)
                    ForEach(Array(reveal.secondaryRewardIDs.enumerated()), id: \.offset) { _, reward in
                        Label(
                            ProgressionRevealPresentationPolicy.contentName(reward),
                            systemImage: "plus.circle.fill"
                        )
                        .font(.subheadline)
                        .foregroundColor(.runeTextPrimary)
                    }
                }
            }

            Text(sourceSummary)
                .font(.footnote)
                .foregroundColor(.runeSilver)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder(highlightColor, lineWidth: 2)
        )
        .shadow(color: Color.black.opacity(0.38), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ProgressionRevealPresentationPolicy.announcement(for: reveal))
        .accessibilityHint("Dismiss to continue; the rest of Rune Scribe remains available")
        .accessibilityHidden(plan == nil)
        .allowsHitTesting(plan != nil)
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

    private var highlightColor: Color {
        plan?.visualMode == .crossfadeHighlight
            ? Color.runeGoldBright.opacity(isVisible ? 0.8 : 0.25)
            : Color.runeGold.opacity(0.55)
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
