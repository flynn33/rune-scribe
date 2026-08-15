// RuneScrib/Views/Components/RuneScribButtonStyle.swift

import SwiftUI

/// Primary action button: a solid gold "rune-stone" with navy lettering.
/// The strongest accent in the UI — used for the one main action per view.
struct RuneScribButtonStyle: ButtonStyle {

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundColor(isEnabled ? .runeTextInverse : .runeSilver)
            .padding(.horizontal, 24)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .fill(
                        isEnabled
                        ? LinearGradient(colors: [.runeGoldBright, .runeGold],
                                         startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [Color.runeUnavailable.opacity(0.35), Color.runeUnavailable.opacity(0.30)],
                                         startPoint: .top, endPoint: .bottom)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .strokeBorder(Color.runeGoldBright.opacity(isEnabled ? 0.9 : 0), lineWidth: 1)
            )
            .shadow(color: Color.runeGold.opacity(isEnabled ? 0.35 : 0), radius: 10, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.55)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Secondary button: a quiet outlined "rune-stone" for supporting actions.
struct RuneSecondaryButtonStyle: ButtonStyle {

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .foregroundColor(isEnabled ? .runeSilver : .runeSilver.opacity(0.5))
            .padding(.horizontal, 18)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .fill(Color.runeSilver.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .strokeBorder(Color.runeSilver.opacity(isEnabled ? 0.45 : 0.2), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.6)
            .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
    }
}
