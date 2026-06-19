// RuneScrib/Views/ResultPopupView.swift

import SwiftUI

struct ResultPopupView: View {

    // MARK: - Input

    let encodedText: String
    let originalText: String

    // MARK: - State

    @State private var showDecoded: Bool = false
    @State private var copyConfirmed: Bool = false
    @Environment(\.dismiss) private var dismiss

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            RuneHeader(
                runic: "ᛖᚾᚲᛟᛞᛖᛞ",
                subtitle: "Encoded Runes",
                trailingButton: RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }
            )

            VStack(spacing: RuneMetrics.sectionGap) {

                // ── Output display ────────────────────────────────────────────
                RunePanel(title: showDecoded ? "Decoded Preview" : "Rune Output",
                          systemImage: showDecoded ? "eye" : "sparkles",
                          accent: showDecoded ? .runeSilver : .runeGold) {
                    ScrollView {
                        Text(showDecoded ? originalText : encodedText)
                            .font(showDecoded ? .system(size: 22, design: .monospaced) : .runic(24))
                            .foregroundColor(showDecoded ? .runeSilver : .runeGold)
                            .textSelection(.enabled)
                            .lineSpacing(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                            .animation(.easeInOut(duration: 0.2), value: showDecoded)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)

                // ── Balanced control row ──────────────────────────────────────
                HStack(spacing: 14) {
                    Button {
                        showDecoded.toggle()
                    } label: {
                        Label(showDecoded ? "Show Runes" : "Preview Decoded",
                              systemImage: showDecoded ? "character" : "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())

                    Button {
                        copyToClipboard()
                    } label: {
                        Label(copyConfirmed ? "Copied!" : "Copy Runes",
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

    // MARK: - Actions

    private func copyToClipboard() {
        Clipboard.copy(encodedText)

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
