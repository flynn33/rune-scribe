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
        FontRegistration.registerBundledFonts()
    }

    /// Handles runescribe:// links on macOS, including cold launch — where SwiftUI's
    /// `.onOpenURL` can miss a URL that arrives before the scene is ready.
    /// `ImportCoordinator` dedupes if `.onOpenURL` also delivers the same link.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { ImportCoordinator.shared.ingest(url: url) }
    }
}

#elseif os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        FontRegistration.registerBundledFonts()
        return true
    }
}
#endif
