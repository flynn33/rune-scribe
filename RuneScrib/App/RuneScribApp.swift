// RuneScrib/App/RuneScribApp.swift
// RuneScrib — Norse Runic Substitution Cipher
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
            ContentView()
                .environmentObject(KeyManager.shared)
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 680)
        .windowResizability(.contentMinSize)
        #endif
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) { }
            #endif
            CommandMenu("Rune Key") {
                Button("Export Key…") {
                    NotificationCenter.default.post(name: .exportKeyRequested, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])

                Button("Rotate Key…") {
                    NotificationCenter.default.post(name: .rotateKeyRequested, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let exportKeyRequested = Notification.Name("com.runescrib.exportKeyRequested")
    static let rotateKeyRequested = Notification.Name("com.runescrib.rotateKeyRequested")
}
