// RuneScrib/Views/Components/RuneScribButtonStyle.swift

import SwiftUI

/// Primary action button: a solid gold "rune-stone" with navy lettering.
/// The strongest accent in the UI — used for the one main action per view.
struct RuneScribButtonStyle: ButtonStyle {

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeBody(configuration: Configuration) -> some View {
        let increasedContrast = colorSchemeContrast == .increased

        configuration.label
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundColor(isEnabled ? .runeTextInverse : .runeSilver)
            .padding(.horizontal, 24)
            .frame(minHeight: 46)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                        .fill(
                            isEnabled
                                ? LinearGradient(
                                    colors: [Color.runeGoldBright, Color.runeGold],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [
                                        Color.runeUnavailable.opacity(0.34),
                                        Color.runeUnavailable.opacity(0.22),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                    ThemeChromeImage(slot: .primaryButton)
                        .opacity(isEnabled ? 0.34 : 0.16)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .strokeBorder(
                        Color.white.opacity(
                            isEnabled ? (increasedContrast ? 0.46 : 0.30) : 0.10
                        ),
                        lineWidth: increasedContrast ? 1.5 : 1
                    )
            }
            .shadow(
                color: Color.runeGold.opacity(isEnabled ? 0.30 : 0),
                radius: 16,
                y: 7
            )
            .shadow(color: Color.black.opacity(isEnabled ? 0.24 : 0), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .opacity(isEnabled ? 1.0 : 0.55)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// Secondary button: a quiet outlined "rune-stone" for supporting actions.
struct RuneSecondaryButtonStyle: ButtonStyle {

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeBody(configuration: Configuration) -> some View {
        let increasedContrast = colorSchemeContrast == .increased

        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .tracking(0.25)
            .foregroundColor(isEnabled ? .runeTextPrimary : .runeSilver.opacity(0.5))
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                        .fill(.thinMaterial)
                    RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                        .fill(Color.runeSurfaceElevated.opacity(isEnabled ? 0.64 : 0.34))
                    ThemeChromeImage(slot: .tabSelector)
                        .opacity(isEnabled ? 0.25 : 0.12)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .strokeBorder(
                        Color.runeGold.opacity(
                            isEnabled ? (increasedContrast ? 0.58 : 0.30) : 0.12
                        ),
                        lineWidth: increasedContrast ? 1.5 : 1
                    )
            }
            .shadow(color: Color.black.opacity(isEnabled ? 0.20 : 0), radius: 9, y: 4)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .opacity(isEnabled ? 1.0 : 0.6)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}
