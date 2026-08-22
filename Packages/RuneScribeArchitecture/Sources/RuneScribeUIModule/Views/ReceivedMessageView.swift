// RuneScrib/Views/ReceivedMessageView.swift

import SwiftUI

/// One-tap view of a decrypted inbound message arriving over the wire (deep link,
/// Universal Link, or clipboard). It distinguishes a locally known cipher from
/// an unverified first-delivery label before offering a reply.
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
                slot: .receivedMessage,
                subtitle: "Message",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    RuneEyebrow(
                        title: identityTitle,
                        systemImage: identitySystemImage
                    )
                    Text(pending.senderName)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.runeTextPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if pending.senderIdentityStatus == .awaitingCipherConfirmation {
                        RunePanel(
                            title: "Confirmation Required",
                            systemImage: "exclamationmark.shield.fill"
                        ) {
                            Text(
                                "This sender label and cipher arrived together. "
                                    + "Confirm the cipher before trusting the label or replying."
                            )
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.runeTextPrimary)
                        }
                    }

                    RunePanel(title: "Decoded Message", systemImage: "envelope.open.fill") {
                        Text(pending.plaintext)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.runeTextPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: 44,
                                alignment: .leading
                            )
                            .contentShape(Rectangle())
                    }

                    if let presentation = pending.presentation {
                        RunePanel(
                            title: "Sender Presentation",
                            systemImage: "sparkles.rectangle.stack.fill"
                        ) {
                            ReceivedPresentationSummary(
                                model: ReceivedPresentationViewModel(presentation),
                                safePreviewData: pending.safePreviewData
                            )
                        }
                    }

                    Text(cipherSummary)
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
                    Label(replyTitle, systemImage: "arrowshape.turn.up.left.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
                .disabled(pending.senderIdentityStatus == .awaitingCipherConfirmation)
            }
            .padding(RuneMetrics.pad)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
    }

    private var identityTitle: String {
        switch pending.senderIdentityStatus {
        case .trustedLocalCipher:
            "Locally Stored Cipher"
        case .awaitingCipherConfirmation:
            "Claimed Sender — Unverified"
        case .confirmedCipher:
            "Confirmed Cipher"
        }
    }

    private var identitySystemImage: String {
        pending.senderIdentityStatus == .awaitingCipherConfirmation
            ? "exclamationmark.shield.fill"
            : "checkmark.shield.fill"
    }

    private var cipherSummary: String {
        switch pending.senderIdentityStatus {
        case .trustedLocalCipher:
            "Authenticated with the locally stored “\(pending.cipherName)” cipher."
        case .awaitingCipherConfirmation:
            "Decoded for preview with an unconfirmed embedded cipher."
        case .confirmedCipher:
            "Decoded with the user-confirmed “\(pending.cipherName)” cipher."
        }
    }

    private var replyTitle: String {
        pending.senderIdentityStatus == .awaitingCipherConfirmation
            ? "Confirm Cipher to Reply"
            : "Reply"
    }
}
