// RuneScrib/Views/RootView.swift

import SwiftUI

/// Hosts the main interface and overlays the lock screen whenever the app is
/// locked. Re-locks (if a PIN is set) when the app moves to the background.
struct RootView: View {

    @EnvironmentObject private var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase

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
            if newPhase == .background { appLock.lockIfEnabled() }
        }
    }
}
