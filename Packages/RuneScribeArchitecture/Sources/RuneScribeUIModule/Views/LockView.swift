// RuneScrib/Views/LockView.swift

import SwiftUI

/// Full-screen lock shown over the app whenever the Core-owned lock is active.
/// Entering the correct PIN unlocks; a wrong PIN shakes and clears.
struct LockView: View {

    @EnvironmentObject private var session: RuneScribeUISession

    @State private var error: String?
    @State private var shakeToken = 0

    var body: some View {
        ZStack {
            Color.runeNavy.ignoresSafeArea()

            VStack(spacing: 0) {
                RuneHeader(runic: "ᚱᚢᚾᛖ ᛚᛟᚲ", subtitle: "Locked")

                Spacer(minLength: 0)

                PINPadView(
                    title: "Enter PIN",
                    subtitle: "Enter your 4-digit PIN to unlock Rune Scribe.",
                    error: error,
                    shakeToken: shakeToken
                ) { pin in
                    Task {
                        do {
                            switch try await session.attemptUnlock(pin) {
                            case .success:
                                error = nil
                            case .incorrect:
                                error = "Incorrect PIN. Try again."
                                shakeToken += 1
                            case .lockedOut(let seconds):
                                error = "Too many attempts. Try again in \(seconds)s."
                                shakeToken += 1
                            }
                        } catch let unlockError {
                            error = RuneScribeUISession.message(forPINError: unlockError)
                            shakeToken += 1
                        }
                    }
                }
                .padding(.horizontal, RuneMetrics.pad)

                Spacer(minLength: 0)
            }
        }
        .runeRootFrame()
        .preferredColorScheme(.dark)
    }
}
