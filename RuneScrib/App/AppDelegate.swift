// RuneScrib/App/AppDelegate.swift
//
// Per-platform application delegate. Both register the bundled runic font at
// launch; macOS additionally enforces single-window / no-tabbing behaviour.

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        FontStore.shared.registerBundledAndImportedFonts()
    }

    /// Handles runescribe:// links on macOS, including cold launch — where SwiftUI's
    /// `.onOpenURL` can miss a URL that arrives before the scene is ready.
    /// `LinkRouter` dispatches to the right coordinator, which dedupes if
    /// `.onOpenURL` also delivers the same link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { LinkRouter.route(url) }
    }
}

#elseif os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FontStore.shared.registerBundledAndImportedFonts()
        return true
    }
}
#endif
