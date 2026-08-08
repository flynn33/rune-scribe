#if os(macOS)
import AppKit
import RuneScribeContracts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtimeComposition = RuneScribeRuntimeComposition()
    lazy var keyManager = KeyManager(service: runtimeComposition.applicationService)
    lazy var contactManager = ContactManager(keyManager: keyManager)
    lazy var importCoordinator = ImportCoordinator(keyManager: keyManager)
    lazy var messageCoordinator = MessageCoordinator(
        keyManager: keyManager,
        contactManager: contactManager
    )
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        FontStore.shared.registerBundledAndImportedFonts()
        Task { await runtimeComposition.start() }
    }
    func applicationWillTerminate(_ notification: Notification) {
        Task { await runtimeComposition.stop() }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        InboundOpenRouter.route(
            urls: urls,
            coordinator: importCoordinator,
            source: .applicationOpen
        )
    }
}

#elseif os(iOS)
import RuneScribeContracts
import UIKit

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let runtimeComposition = RuneScribeRuntimeComposition()
    lazy var keyManager = KeyManager(service: runtimeComposition.applicationService)
    lazy var contactManager = ContactManager(keyManager: keyManager)
    lazy var importCoordinator = ImportCoordinator(keyManager: keyManager)
    lazy var messageCoordinator = MessageCoordinator(
        keyManager: keyManager,
        contactManager: contactManager
    )
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        FontStore.shared.registerBundledAndImportedFonts()
        Task { await runtimeComposition.start() }
        return true
    }
    func applicationWillTerminate(_ application: UIApplication) {
        Task { await runtimeComposition.stop() }
    }
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: nil,
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = RuneScribeSceneDelegate.self
        return configuration
    }

    func application(
        _ application: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        InboundOpenRouter.route(
            url: url,
            coordinator: importCoordinator,
            source: .applicationOpen
        )
        return true
    }
}

@MainActor
final class RuneScribeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var importCoordinator: ImportCoordinator? {
        (UIApplication.shared.delegate as? AppDelegate)?.importCoordinator
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let importCoordinator else { return }
        InboundOpenRouter.route(
            urls: connectionOptions.urlContexts.map(\.url),
            coordinator: importCoordinator,
            source: .sceneOpen,
            isColdStart: true
        )
        for activity in connectionOptions.userActivities {
            InboundOpenRouter.route(
                userActivity: activity,
                coordinator: importCoordinator,
                isColdStart: true
            )
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let importCoordinator else { return }
        InboundOpenRouter.route(
            urls: contexts.map(\.url),
            coordinator: importCoordinator,
            source: .sceneOpen
        )
    }

    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard let importCoordinator else { return }
        InboundOpenRouter.route(
            userActivity: userActivity,
            coordinator: importCoordinator
        )
    }
}
#endif
