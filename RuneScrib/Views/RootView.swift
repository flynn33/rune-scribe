// RuneScrib/Views/RootView.swift

import SwiftUI

/// Hosts the main interface and overlays the lock screen whenever the app is
/// locked. Re-locks (if a PIN is set) when the app moves to the background.
struct RootView: View {

    @EnvironmentObject private var appLock: AppLock
    @EnvironmentObject private var keyManager: KeyManager
    @EnvironmentObject private var coordinator: ImportCoordinator
    @Environment(\.scenePhase) private var scenePhase

    /// The pasteboard change counter last inspected, so a foreground only reads the
    /// clipboard (which can briefly notify the user on iOS) when its contents change.
    @State private var lastClipboardChangeCount = 0

    var body: some View {
        ZStack {
            ContentView()

            if appLock.isLocked {
                LockView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background: appLock.lockIfEnabled()
            case .active:     checkClipboardForCipher()
            default:          break
            }
        }
        // Import confirmation. The `get` returns nil while locked, so a deep link or
        // clipboard cipher waits behind the PIN and presents the moment it unlocks.
        .sheet(item: Binding(
            get: { appLock.isLocked ? nil : coordinator.pending },
            // Only clear on a genuine, unlocked dismissal — not when the lock
            // engaging flips `get` to nil (which must preserve the pending import).
            set: { if $0 == nil && !appLock.isLocked { coordinator.pending = nil } }
        )) { pending in
            ImportConfirmView(pending: pending) { result in
                if case .failure(let error) = result {
                    coordinator.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            .environmentObject(keyManager)
        }
        .alert("Import Failed", isPresented: Binding(
            get: { coordinator.errorMessage != nil && !appLock.isLocked },
            // Only clear on an unlocked dismissal, so the lock engaging doesn't wipe
            // the error before the user can see it after unlocking.
            set: { if !$0 && !appLock.isLocked { coordinator.errorMessage = nil } }
        )) {
            Button("OK") { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
    }

    /// On returning to the foreground, offer to import a `runescribe://` cipher
    /// sitting on the clipboard (e.g. a link a friend texted and the user copied).
    private func checkClipboardForCipher() {
        guard !appLock.isLocked, coordinator.pending == nil else { return }
        let count = Clipboard.changeCount
        guard count != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = count
        if let urlString = Clipboard.runeScribeURLString() {
            coordinator.ingest(urlString: urlString)
        }
    }
}
