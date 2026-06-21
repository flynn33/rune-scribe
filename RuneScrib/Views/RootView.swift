// RuneScrib/Views/RootView.swift

import SwiftUI

/// Hosts the main interface and overlays the lock screen whenever the app is
/// locked. Re-locks (if a PIN is set) when the app moves to the background.
struct RootView: View {

    @EnvironmentObject private var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase

    /// Shown once per process. Because this `@State` is created when the scene is
    /// first built (a cold launch) and persists across background/foreground
    /// cycles, the splash plays on first open and on the first open after the app
    /// has been fully closed — but not when merely resuming from the background.
    @State private var showSplash = (SplashAsset.url != nil)

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
                    withAnimation(.easeInOut(duration: 0.45)) { showSplash = false }
                }
                .transition(.opacity)
                .zIndex(2)
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appLock.isLocked)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background { appLock.lockIfEnabled() }
        }
    }
}
