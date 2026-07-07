// RuneScrib/App/AppDelegate.swift
//
// Per-platform application delegate. Both register the bundled runic font at
// launch; macOS additionally enforces single-window / no-tabbing behaviour. Every
// inbound URL/file open routes through the one canonical `InboundOpenRouter`.

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
    /// `.onOpenURL` can miss a URL that arrives before the scene is ready. Routes through
    /// the canonical `InboundOpenRouter`: a `.runescribe` file goes to `FileRouter`
    /// (message vs. cipher by version byte), a runescribe:// link to `LinkRouter`. Both
    /// coordinators dedupe if `.onOpenURL` also delivers the same item.
    func application(_ application: NSApplication, open urls: [URL]) {
        InboundOpenRouter.route(urls: urls)
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

    /// Attaches the scene delegate so scene-level URL/document opens — the modern iOS
    /// intake path for a `.runescribe` attachment tapped in Messages, especially at cold
    /// launch — are captured. Only `delegateClass` is set; `sceneClass` is deliberately
    /// left to SwiftUI so the `WindowGroup` keeps creating and rendering the UI.
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = RuneScribeSceneDelegate.self
        return configuration
    }

    /// Fallback URL open. With a scene delegate attached, iOS delivers opens through the
    /// scene's URL contexts instead, so this rarely fires now — it stays as a
    /// belt-and-suspenders path (alongside SwiftUI's `.onOpenURL`) and routes through the
    /// same canonical `InboundOpenRouter`.
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        InboundOpenRouter.route(url: url)
        return true
    }
}

/// The iOS scene delegate: the scene-lifecycle entry point for URL/document opens. It
/// captures cold-launch opens (`connectionOptions.urlContexts` — how a `.runescribe` file
/// tapped in Messages arrives when the app was not running), opens while running
/// (`openURLContexts`), and web-browsing continuation for legacy https import links, and
/// funnels every one through the single canonical `InboundOpenRouter`.
///
/// It deliberately never touches the window — no `self.window`, no root view controller —
/// so SwiftUI keeps hosting the `WindowGroup`. `UIWindowSceneDelegate` is main-actor
/// isolated, so these callbacks call the main-actor router directly.
final class RuneScribeSceneDelegate: UIResponder, UIWindowSceneDelegate {

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        InboundOpenRouter.route(urls: connectionOptions.urlContexts.map(\.url))
        for activity in connectionOptions.userActivities {
            InboundOpenRouter.route(userActivity: activity)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        InboundOpenRouter.route(urls: URLContexts.map(\.url))
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        InboundOpenRouter.route(userActivity: userActivity)
    }
}
#endif
