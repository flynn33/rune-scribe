// RuneScrib/App/RuneScribApp.swift
// Rune-Scribe — Norse Runic Substitution Cipher
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
            RootView()
                .environmentObject(KeyManager.shared)
                .environmentObject(AppLock.shared)
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
}

// MARK: - Notification Names

extension Notification.Name {
    static let openLibraryRequested  = Notification.Name("com.runescribe.openLibraryRequested")
    static let openSettingsRequested = Notification.Name("com.runescribe.openSettingsRequested")
}
