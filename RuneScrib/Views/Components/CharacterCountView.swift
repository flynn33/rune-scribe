// RuneScrib/Views/Components/CharacterCountView.swift

import SwiftUI

/// A live row of small "stat chips" beneath the input: total characters, how many
/// are recognised (encodable to runes, or decodable from runes), and how many pass
/// through unchanged.
struct CharacterCountView: View {

    let text: String
    /// The set of characters the current operation recognises (input chars for
    /// encoding, or known runes for decoding).
    let recognized: Set<String>
    /// Label for the recognised count, e.g. "encodable" or "decodable".
    let recognizedLabel: String
    var recognizedAccent: Color = .runeBlue

    private var count: Int { text.count }
    private var recognizedCount: Int {
        text.filter { recognized.contains(String($0)) }.count
    }
    private var passthroughCount: Int { count - recognizedCount }

    var body: some View {
        HStack(spacing: 8) {
            chip(value: count, label: "chars", icon: "textformat", accent: .runeSilver)
            chip(value: recognizedCount, label: recognizedLabel, icon: "checkmark.seal", accent: recognizedAccent)
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
