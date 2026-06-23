// RuneScrib/App/RuneScribApp.swift
// Rune Scribe — Norse Runic Substitution Cipher
// Universal app: macOS 15.0+ and iOS 17.0+ | Swift 6.0 | SwiftUI

import SwiftUI

@main
struct RuneScribApp: App {

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            rootContent
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 720)
        .windowResizability(.contentMinSize)
        #endif
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            #endif
            CommandMenu("Cipher") {
                Button("Cipher Library…") {
                    NotificationCenter.default.post(name: .openLibraryRequested, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }

    /// Under XCTest the app-hosted test host renders nothing and touches none of the
    /// Keychain-backed singletons (`KeyManager`/`AppLock`) or the splash/Metal UI, so
    /// unit tests launch instantly and non-interactively — no Keychain authorization
    /// prompt — in a headless context. The real UI is exercised by the user and UI tests.
    @ViewBuilder
    private var rootContent: some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            EmptyView()
        } else {
            RootView()
                .environmentObject(KeyManager.shared)
                .environmentObject(AppLock.shared)
                .environmentObject(ImportCoordinator.shared)
                // A tapped runescribe://import link (Messages, Mail, Camera-app QR,
                // etc.) lands here on both platforms, even from a cold launch.
                .onOpenURL { ImportCoordinator.shared.ingest(url: $0) }
        }
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openLibraryRequested  = Notification.Name("com.runescribe.openLibraryRequested")
    static let openSettingsRequested = Notification.Name("com.runescribe.openSettingsRequested")
}
