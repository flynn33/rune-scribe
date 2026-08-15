// RuneScrib/Views/ImportConfirmView.swift

import SwiftUI
import RuneScribeContracts
#if os(iOS)
import UIKit
#endif

@MainActor
enum ImportConfirmationOutcome {
    case imported(CipherViewState)
    case failed(Error)

    var shouldDismiss: Bool {
        if case .imported = self {
            return true
        }
        return false
    }
}

@MainActor
enum ImportConfirmationFlow {
    static func attempt(
        label: String,
        confirm: (String) async throws -> CipherViewState
    ) async -> ImportConfirmationOutcome {
        do {
            return .imported(try await confirm(label))
        } catch {
            return .failed(error)
        }
    }
}

/// One-tap confirmation for a cipher arriving over the wire (deep link, QR, or
/// clipboard). Shows what's being imported and lets the user name it before it's
/// saved — the guard that keeps a tapped link from silently adding a cipher.
///
/// Presentation-agnostic: it dismisses itself and reports the outcome via
/// `onResult`, so it can be hosted app-wide (RootView) or from the library's
/// scanner without coupling to a particular presenter.
struct ImportConfirmView: View {

    @Environment(\.dismiss) private var dismiss

    let pending: PendingImportSummary
    let confirmImport: (String) async throws -> CipherViewState
    var cancelImport: () -> Void = {}
    var onResult: ((Result<CipherViewState, Error>) -> Void)? = nil

    @State private var name: String = ""
    @State private var confirmationError: String?
    @State private var isConfirming = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛁᛗᛈᛟᚱᛏ",
                subtitle: "Import Cipher",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Cancel") {
                    cancelImport()
                    dismiss()
                }]
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
                        cipherNameField
                            .frame(minHeight: 48)
                            .padding(.horizontal, 12)
                            .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .fill(Color.runeParchment))
                            .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .strokeBorder(Color.runeGold.opacity(0.25), lineWidth: 1))
                        Text("Give it a label so you can find it in your library.")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.runeSilver.opacity(0.8))
                    }

                    if let confirmationError {
                        RunePanel(title: "Import Failed", systemImage: "exclamationmark.triangle.fill") {
                            Text(confirmationError)
                                .font(.system(size: 13))
                                .foregroundColor(.runeSilver)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityIdentifier("import-confirmation-error")
                    }
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button {
                    cancelImport()
                    dismiss()
                } label: {
                    Label("Cancel", systemImage: "xmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())

                Button { confirm() } label: {
                    Label("Import", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
                .disabled(trimmedName.isEmpty || isConfirming)
            }
            .padding(RuneMetrics.pad)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .onAppear { if name.isEmpty { name = pending.suggestedName } }
    }

    @ViewBuilder
    private var cipherNameField: some View {
        #if os(iOS)
        RuneCipherNameTextField(text: $name)
        #else
        TextField("Cipher name", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 15, design: .monospaced))
            .foregroundColor(.runeTextPrimary)
        #endif
    }

    private func confirm() {
        let label = trimmedName
        confirmationError = nil
        isConfirming = true
        Task {
            let outcome = await ImportConfirmationFlow.attempt(
                label: label,
                confirm: confirmImport
            )
            switch outcome {
            case let .imported(cipher):
                onResult?(.success(cipher))
            case let .failed(error):
                confirmationError = RuneScribeUISession.message(for: error)
                onResult?(.failure(error))
            }
            isConfirming = false
            if outcome.shouldDismiss {
                dismiss()
            }
        }
    }
}

#if os(iOS)
private struct RuneCipherNameTextField: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.backgroundColor = .clear
        field.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        applyThemeColors(to: field)
        field.placeholder = "Cipher name"
        field.accessibilityLabel = "Cipher name"
        field.returnKeyType = .done
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textChanged(_:)),
            for: .editingChanged
        )
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text {
            field.text = text
        }
        applyThemeColors(to: field)
        context.coordinator.text = $text
    }

    private func applyThemeColors(to field: UITextField) {
        field.textColor = UIColor(Color.runeTextPrimary)
        field.tintColor = UIColor(Color.runeKeyboardFocus)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func textChanged(_ sender: UITextField) {
            text.wrappedValue = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }
    }
}
#endif
