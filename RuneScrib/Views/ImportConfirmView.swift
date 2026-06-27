// RuneScrib/Views/ImportConfirmView.swift

import SwiftUI

/// One-tap confirmation for a cipher arriving over the wire (deep link, QR, or
/// clipboard). Shows what's being imported and lets the user name it before it's
/// saved — the guard that keeps a tapped link from silently adding a cipher.
///
/// Presentation-agnostic: it dismisses itself and reports the outcome via
/// `onResult`, so it can be hosted app-wide (RootView) or from the library's
/// scanner without coupling to a particular presenter.
struct ImportConfirmView: View {

    @EnvironmentObject private var keyManager: KeyManager
    @Environment(\.dismiss) private var dismiss

    let pending: ImportCoordinator.PendingImport
    var onResult: ((Result<Cipher, Error>) -> Void)? = nil

    @State private var name: String = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛁᛗᛈᛟᚱᛏ",
                subtitle: "Import Cipher",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Cancel") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    RunePanel(title: "Shared Cipher", systemImage: "key.fill") {
                        Text("Someone shared a cipher with you. Import it to decode their "
                             + "runes — and to write messages back with the same key.")
                            .font(.system(size: 13))
                            .foregroundColor(.runeSilver)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        RuneEyebrow(title: "Name", systemImage: "tag.fill")
                        TextField("Cipher name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .fill(Color.runeParchment))
                            .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .strokeBorder(Color.runeGold.opacity(0.25), lineWidth: 1))
                        Text("Give it a label so you can find it in your library.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.runeSilver.opacity(0.8))
                    }
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())

                Button { confirm() } label: {
                    Label("Import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
                .disabled(trimmedName.isEmpty)
            }
            .padding(RuneMetrics.pad)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .onAppear { if name.isEmpty { name = pending.suggestedName } }
    }

    private func confirm() {
        let label = trimmedName.isEmpty ? nil : trimmedName
        do {
            // When the cipher arrived as a file with its font, install the font first so
            // the imported cipher renders correctly; both succeed or the import fails.
            if let fontBytes = pending.fontBytes {
                try FontStore.shared.importFont(fontBytes, expecting: pending.payload.fontRef)
            }
            let cipher = try keyManager.importCipher(pending.payload, label: label)
            onResult?(.success(cipher))
        } catch {
            onResult?(.failure(error))
        }
        dismiss()
    }
}
