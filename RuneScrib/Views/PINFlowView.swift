// RuneScrib/Views/PINFlowView.swift

import SwiftUI

/// A guided PIN flow presented from Settings to set, change, or disable the
/// app-lock PIN. Drives the reusable `PINPadView` through the required steps.
struct PINFlowView: View {

    /// Which operation this flow performs.
    enum Mode: String, Identifiable {
        case set, change, disable
        var id: String { rawValue }
    }

    private enum Step { case current, create, confirm }

    let mode: Mode

    @EnvironmentObject private var appLock: AppLock
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step
    @State private var currentPIN = ""
    @State private var firstPIN = ""
    @State private var error: String?
    @State private var shakeToken = 0

    init(mode: Mode) {
        self.mode = mode
        _step = State(initialValue: mode == .set ? .create : .current)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: headerRunic,
                subtitle: headerSubtitle,
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Cancel") { dismiss() }]
            )

            Spacer(minLength: 0)

            PINPadView(
                title: stepTitle,
                subtitle: stepSubtitle,
                error: error,
                shakeToken: shakeToken
            ) { pin in
                Task { await handle(pin) }
            }
            .padding(.horizontal, RuneMetrics.pad)

            Spacer(minLength: 0)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
    }

    // MARK: - Step Handling

    private func handle(_ pin: String) async {
        error = nil
        switch step {
        case .current:
            do {
                guard try await appLock.verify(pin) else {
                    fail("Incorrect PIN.")
                    return
                }
            } catch {
                fail(error.localizedDescription)
                return
            }
            currentPIN = pin
            if mode == .disable {
                await finishDisable()
            } else {
                step = .create
            }

        case .create:
            guard AppLock.isValidFormat(pin) else { fail("Enter a 4-digit PIN."); return }
            firstPIN = pin
            step = .confirm

        case .confirm:
            guard pin == firstPIN else {
                firstPIN = ""
                step = .create
                fail("PINs didn't match. Start again.")
                return
            }
            await finishSet()
        }
    }

    private func finishSet() async {
        do {
            if mode == .change {
                try await appLock.changePIN(current: currentPIN, new: firstPIN)
            } else {
                try await appLock.setPIN(firstPIN)
            }
            dismiss()
        } catch {
            step = .create
            firstPIN = ""
            fail(error.localizedDescription)
        }
    }

    private func finishDisable() async {
        do {
            try await appLock.disablePIN(current: currentPIN)
            dismiss()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        error = message
        shakeToken += 1
    }

    // MARK: - Copy

    private var headerRunic: String {
        switch mode {
        case .set:     return "ᛋᛖᛏ ᛈᛁᚾ"
        case .change:  return "ᚲᚺᚨᚾᚷᛖ"
        case .disable: return "ᛞᛁᛋᚨᛒᛚᛖ"
        }
    }

    private var headerSubtitle: String {
        switch mode {
        case .set:     return "Set PIN"
        case .change:  return "Change PIN"
        case .disable: return "Disable PIN"
        }
    }

    private var stepTitle: String {
        switch step {
        case .current: return "Enter Current PIN"
        case .create:  return mode == .change ? "Enter New PIN" : "Create a PIN"
        case .confirm: return "Confirm PIN"
        }
    }

    private var stepSubtitle: String {
        switch step {
        case .current:
            return mode == .disable
                ? "Enter your current PIN to turn off the app lock."
                : "Enter your current PIN to continue."
        case .create:
            return "Choose a 4-digit PIN you'll remember."
        case .confirm:
            return "Re-enter the PIN to confirm."
        }
    }
}
