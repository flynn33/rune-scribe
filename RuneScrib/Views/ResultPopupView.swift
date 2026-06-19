// RuneScrib/Views/ResultPopupView.swift

import SwiftUI

struct ResultPopupView: View {

    /// Which way the conversion went, deciding which side is the primary result.
    enum Direction { case encode, decode }

    // MARK: - Input

    let runes: String
    let plain: String
    var direction: Direction = .encode

    // MARK: - State

    /// When false, the view shows the direction's primary side (runes for encode,
    /// plain text for decode); when true, it shows the other side.
    @State private var showingAlternate: Bool = false
    @State private var copyConfirmed: Bool = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Derived

    private var showingRunes: Bool {
        (direction == .encode && !showingAlternate) || (direction == .decode && showingAlternate)
    }
    private var displayedText: String { showingRunes ? runes : plain }
    private var headerRunic: String { direction == .encode ? "ᛖᚾᚲᛟᛞᛖᛞ" : "ᛞᛖᚲᛟᛞᛖᛞ" }
    private var headerSubtitle: String { direction == .encode ? "Encoded Runes" : "Decoded Text" }
    private var panelTitle: String { showingRunes ? "Rune Output" : "Plain Text" }
    private var panelIcon: String { showingRunes ? "sparkles" : "text.alignleft" }
    private var toggleLabel: String { showingRunes ? "Show Text" : "Show Runes" }
    private var toggleIcon: String { showingRunes ? "text.alignleft" : "eye" }
    private var copyValue: String { direction == .encode ? runes : plain }
    private var copyLabel: String { direction == .encode ? "Copy Runes" : "Copy Text" }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            RuneHeader(
                runic: headerRunic,
                subtitle: headerSubtitle,
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            VStack(spacing: RuneMetrics.sectionGap) {

                // ── Output display ────────────────────────────────────────────
                RunePanel(title: panelTitle,
                          systemImage: panelIcon,
                          accent: showingRunes ? .runeGold : .runeSilver) {
                    ScrollView {
                        runeText
                            .textSelection(.enabled)
                            .lineSpacing(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .animation(.easeInOut(duration: 0.2), value: showingAlternate)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                // ── Balanced control row ──────────────────────────────────────
                HStack(spacing: 14) {
                    Button {
                        showingAlternate.toggle()
                    } label: {
                        Label(toggleLabel, systemImage: toggleIcon)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())

                    Button {
                        copyToClipboard()
                    } label: {
                        Label(copyConfirmed ? "Copied!" : copyLabel,
                              systemImage: copyConfirmed ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }
            }
            .padding(RuneMetrics.pad)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
    }

    // MARK: - Output Text

    /// The output glyphs. When showing runes, a faint Metal glow blooms around
    /// them; the plain-text side renders without the effect.
    @ViewBuilder
    private var runeText: some View {
        if showingRunes {
            Text(displayedText)
                .font(.runic(24))
                .foregroundColor(.runeGold)
                .runeGlow()
        } else {
            Text(displayedText)
                .font(.system(size: 22, design: .monospaced))
                .foregroundColor(.runeSilver)
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        Clipboard.copy(copyValue)

        withAnimation {
            copyConfirmed = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation {
                copyConfirmed = false
            }
        }
    }
}
