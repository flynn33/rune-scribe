// RuneScrib/Views/ReceivedMessageView.swift

import SwiftUI

/// One-tap view of a decrypted inbound message arriving over the wire (deep link,
/// Universal Link, or clipboard). Shows who sent it and the plaintext, and lets the
/// user jump straight to composing a reply with the same cipher.
///
/// Presentation-agnostic: it dismisses itself and reports a reply request via
/// `onReply`, so it can be hosted app-wide (RootView) without coupling to a
/// particular presenter — the same contract `ImportConfirmView` uses.
struct ReceivedMessageView: View {

    @Environment(\.dismiss) private var dismiss

    let pending: PendingMessageViewState
    var onReply: ((PendingMessageViewState) -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛗᛖᛋᛋᚨᚷᛖ",
                subtitle: "Message",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    RuneEyebrow(title: "From", systemImage: "person.crop.circle.fill")
                    Text(pending.senderName)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    RunePanel(title: "Decoded Message", systemImage: "envelope.open.fill") {
                        Text(pending.plaintext)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.white)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 44,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }

                    Text("Decoded with the “\(pending.cipherName)” cipher.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.runeSilver.opacity(0.8))
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())

                Button {
                    onReply?(pending)
                    dismiss()
                } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
            }
            .padding(RuneMetrics.pad)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
    }
}
