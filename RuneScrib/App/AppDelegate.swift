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

    /// Handles inbound URLs on macOS, including cold launch — where SwiftUI's
    /// `.onOpenURL` can miss a URL that arrives before the scene is ready. A
    /// `.runescribe` file routes through `FileRouter` (message vs. cipher by version
    /// byte); a runescribe:// link routes through `LinkRouter`. Both coordinators
    /// dedupe if `.onOpenURL` also delivers the same item.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                FileRouter.route(fileURL: url)
            } else {
                LinkRouter.route(url)
            }
        }
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
