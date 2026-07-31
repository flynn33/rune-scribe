// RuneScrib/Views/RootView.swift

import SwiftUI

/// Hosts the main interface and overlays the lock screen whenever the app is
/// locked. Re-locks (if a PIN is set) when the app moves to the background, and
/// plays the launch splash on a cold start when the 30-day intro schedule allows.
struct RootView: View {

    @EnvironmentObject private var appLock: AppLock
    @EnvironmentObject private var keyManager: KeyManager
    @EnvironmentObject private var coordinator: ImportCoordinator
    @EnvironmentObject private var messageCoordinator: MessageCoordinator
    @Environment(\.scenePhase) private var scenePhase

    /// The pasteboard change counter last inspected, so a foreground only reads the
    /// clipboard (which can briefly notify the user on iOS) when its contents change.
    @State private var lastClipboardChangeCount = 0

    /// Shown at most once per process, and only when `SplashAsset.shouldShow` is
    /// true (asset present and ≥ 30 days since last intro). Because this `@State`
    /// is created when the scene is first built (a cold launch) and persists across
    /// background/foreground cycles, the splash never restarts when merely
    /// resuming from the background — only a full quit/relaunch re-evaluates the
    /// 30-day schedule.
    @State private var showSplash = SplashAsset.shouldShow()

    var body: some View {
        ZStack {
            ContentView()

            if appLock.isLocked {
                LockView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showSplash, let url = SplashAsset.url {
                VideoSplashView(videoURL: url) {
                    // Record presentation so the next cold launches skip until the
                    // 30-day window elapses (finish, skip, and timeout all land here).
                    SplashAsset.markShown()
                    withAnimation(.easeInOut(duration: 0.45)) { showSplash = false }
                }
                .transition(.opacity)
                .zIndex(2)
                .ignoresSafeArea()
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
        // Import confirmation. The `get` returns nil while the splash is up or the
        // app is locked, so a deep link or clipboard cipher waits and presents the
        // moment the splash ends and the app unlocks.
        .sheet(item: Binding(
            get: { (showSplash || appLock.isLocked) ? nil : coordinator.pending },
            // Only clear on a genuine, unlocked dismissal — not when the splash or
            // lock flips `get` to nil (which must preserve the pending import).
            set: { if $0 == nil && !appLock.isLocked && !showSplash { coordinator.pending = nil } }
        )) { pending in
            ImportConfirmView(pending: pending) { result in
                if case .failure(let error) = result {
                    coordinator.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
            .environmentObject(keyManager)
        }
        // Inbound decrypted message. Same splash/lock gating as the import host: a
        // tapped message link waits and presents the moment the splash ends and the
        // app unlocks.
        .sheet(item: Binding(
            get: { (showSplash || appLock.isLocked) ? nil : messageCoordinator.pending },
            set: { if $0 == nil && !appLock.isLocked && !showSplash { messageCoordinator.pending = nil } }
        )) { pending in
            ReceivedMessageView(pending: pending) { message in
                // Reply: hand ContentView the cipher to compose with via a notification;
                // it switches the active cipher and drops to the editor.
                NotificationCenter.default.post(name: .replyToMessageRequested, object: message.cipher.id)
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: { coordinator.errorMessage != nil && !appLock.isLocked && !showSplash },
            // Only clear on an unlocked dismissal, so the splash/lock doesn't wipe
            // the error before the user can see it.
            set: { if !$0 && !appLock.isLocked && !showSplash { coordinator.errorMessage = nil } }
        )) {
            Button("OK") { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        // A tapped/pasted message link that can't be read (corrupt link or no matching
        // cipher) surfaces here, with the same splash/lock gating as the import error.
        .alert("Couldn't Read Message", isPresented: Binding(
            get: { messageCoordinator.errorMessage != nil && !appLock.isLocked && !showSplash },
            set: { if !$0 && !appLock.isLocked && !showSplash { messageCoordinator.errorMessage = nil } }
        )) {
            Button("OK") { messageCoordinator.errorMessage = nil }
        } message: {
            Text(messageCoordinator.errorMessage ?? "")
        }
    }

    /// On returning to the foreground, offer to import a `runescribe://` cipher
    /// sitting on the clipboard (e.g. a link a friend texted and the user copied).
    private func checkClipboardForCipher() {
        guard !showSplash, !appLock.isLocked, coordinator.pending == nil else { return }
        let count = Clipboard.changeCount
        guard count != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = count
        if let urlString = Clipboard.runeScribeURLString() {
            LinkRouter.route(urlString: urlString)
        }
    }
}
