// RuneScrib/Views/Components/PINPadView.swift

import SwiftUI

/// A reusable 4-digit PIN entry pad: a row of dots that fill as digits are typed,
/// plus a 3×4 number pad. Calls `onComplete` with the 4-digit string once the
/// fourth digit is entered, then clears itself. The parent drives error feedback
/// by incrementing `shakeToken` (which shakes the dots and clears the entry).
struct PINPadView: View {

    let title: String
    let subtitle: String
    var error: String? = nil
    /// Increment to trigger a shake + clear (e.g. after a wrong PIN).
    var shakeToken: Int = 0
    let onComplete: (String) -> Void

    @State private var entry: String = ""
    @State private var shakeOffset: CGFloat = 0

    private let pinLength = 4

    private let keys: [PadKey] = [
        .digit("1"), .digit("2"), .digit("3"),
        .digit("4"), .digit("5"), .digit("6"),
        .digit("7"), .digit("8"), .digit("9"),
        .blank,      .digit("0"), .delete
    ]

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(.runeGold)
                Text(subtitle)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.runeSilver)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            dots.offset(x: shakeOffset)

            Text(error ?? " ")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.red)
                .opacity(error == nil ? 0 : 1)

            pad
        }
        .onChange(of: shakeToken) { _, _ in
            entry = ""
            shake()
        }
    }

    // MARK: - Subviews

    private var dots: some View {
        HStack(spacing: 18) {
            ForEach(0..<pinLength, id: \.self) { index in
                Circle()
                    .strokeBorder(Color.runeSilver.opacity(0.5), lineWidth: 1.5)
                    .background(Circle().fill(index < entry.count ? Color.runeGold : Color.clear))
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("PIN entry")
        .accessibilityValue("\(entry.count) of \(pinLength) digits entered")
    }

    private var pad: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
            ForEach(keys) { key in
                padButton(key)
            }
        }
        .frame(maxWidth: 280)
    }

    @ViewBuilder
    private func padButton(_ key: PadKey) -> some View {
        switch key.kind {
        case .blank:
            Color.clear.frame(height: 58)
        case .digit(let digit):
            Button { append(digit) } label: {
                Text(digit)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).frame(height: 58)
            }
            .buttonStyle(PINKeyStyle())
        case .delete:
            Button { deleteLast() } label: {
                Image(systemName: "delete.left")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 58)
            }
            .buttonStyle(PINKeyStyle())
            .accessibilityLabel("Delete last digit")
            .disabled(entry.isEmpty)
        }
    }

    // MARK: - Input

    private func append(_ digit: String) {
        guard entry.count < pinLength else { return }
        entry += digit
        guard entry.count == pinLength else { return }

        // Let the fourth dot fill before reporting completion, then clear.
        let value = entry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            onComplete(value)
            entry = ""
        }
    }

    private func deleteLast() {
        if !entry.isEmpty { entry.removeLast() }
    }

    private func shake() {
        withAnimation(.easeInOut(duration: 0.06).repeatCount(5, autoreverses: true)) {
            shakeOffset = 9
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            shakeOffset = 0
        }
    }
}

// MARK: - Pad Key

private struct PadKey: Identifiable {
    enum Kind { case blank, digit(String), delete }
    let kind: Kind

    /// Stable, content-derived id so the grid doesn't churn on every render.
    var id: String {
        switch kind {
        case .blank:            return "blank"
        case .digit(let value): return "d\(value)"
        case .delete:           return "delete"
        }
    }

    static func digit(_ value: String) -> PadKey { PadKey(kind: .digit(value)) }
    static let blank = PadKey(kind: .blank)
    static let delete = PadKey(kind: .delete)
}

// MARK: - Key Button Style

/// A quiet rune-stone key for the PIN pad.
private struct PINKeyStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.runeSilver)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.runeParchment)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.runeSilver.opacity(0.22), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.35)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
