// RuneScrib/Views/Components/CharacterCountView.swift

import SwiftUI

/// A live row of small "stat chips" beneath the input: total characters,
/// how many will encode to runes, and how many pass through unchanged.
struct CharacterCountView: View {

    let text: String
    let limit: Int = 4000

    private var count: Int { text.count }
    private var encodableCount: Int {
        text.filter { RuneCharacterSet.inputCharacterSet.contains(String($0)) }.count
    }
    private var passthroughCount: Int { count - encodableCount }

    var body: some View {
        HStack(spacing: 8) {
            chip(value: count, label: "chars", icon: "textformat", accent: .runeSilver)
            chip(value: encodableCount, label: "encodable", icon: "checkmark.seal", accent: .runeBlue)
            if passthroughCount > 0 {
                chip(value: passthroughCount, label: "pass-through", icon: "arrow.uturn.right", accent: .runeGold)
            }
            Spacer()
        }
    }

    private func chip(value: Int, label: String, icon: String, accent: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(accent)
            Text("\(value)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.runeSilver)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.runeParchment))
        .overlay(Capsule().strokeBorder(accent.opacity(0.28), lineWidth: 1))
    }
}
