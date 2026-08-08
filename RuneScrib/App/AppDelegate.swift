#if os(macOS)
import AppKit
import RuneScribeContracts
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime = RuneScribeRuntimeComposition()
    lazy var keyManager = KeyManager(
        service: runtime.applicationService,
        sharePresentation: runtime.sharePresentation
    )
    lazy var appLock = AppLock(service: runtime.applicationService)
    lazy var contactManager = ContactManager(applicationService: runtime.applicationService)
    lazy var importCoordinator = ImportCoordinator(keyManager: keyManager)
    lazy var messageCoordinator = MessageCoordinator(keyManager: keyManager)
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { Task { await runtime.start() } }
    }
    func applicationDidBecomeActive(_ notification: Notification) { runtime.receive(lifecycle: .didBecomeActive) }
    func applicationWillResignActive(_ notification: Notification) { runtime.receive(lifecycle: .willResignActive) }
    func applicationDidResignActive(_ notification: Notification) { runtime.receive(lifecycle: .didEnterBackground) }
    func applicationWillTerminate(_ notification: Notification) {
        runtime.receive(lifecycle: .willTerminate)
        Task { await runtime.stop() }
    }
    func application(_ application: NSApplication, open urls: [URL]) { runtime.receive(urls: urls, source: .applicationOpen) }
    func receive(menu: ApplicationMenuCommandDTO) { runtime.receive(menu: menu) }
}
#elseif os(iOS)
import RuneScribeContracts
import UIKit
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let runtime = RuneScribeRuntimeComposition()
    lazy var keyManager = KeyManager(
        service: runtime.applicationService,
        sharePresentation: runtime.sharePresentation
    )
    lazy var appLock = AppLock(service: runtime.applicationService)
    lazy var contactManager = ContactManager(applicationService: runtime.applicationService)
    lazy var importCoordinator = ImportCoordinator(keyManager: keyManager)
    lazy var messageCoordinator = MessageCoordinator(keyManager: keyManager)
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { Task { await runtime.start() } }
        return true
    }
    func applicationDidBecomeActive(_ application: UIApplication) { runtime.receive(lifecycle: .didBecomeActive) }
    func applicationWillResignActive(_ application: UIApplication) { runtime.receive(lifecycle: .willResignActive) }
    func applicationDidEnterBackground(_ application: UIApplication) { runtime.receive(lifecycle: .didEnterBackground) }
    func applicationWillEnterForeground(_ application: UIApplication) { runtime.receive(lifecycle: .willEnterForeground) }
    func applicationWillTerminate(_ application: UIApplication) {
        runtime.receive(lifecycle: .willTerminate)
        Task { await runtime.stop() }
    }
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = RuneScribeSceneDelegate.self
        return configuration
    }
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        receive(urls: [url], source: .applicationOpen)
        return true
    }
    func receive(urls: [URL], source: InboundDeliverySourceDTO, isColdStart: Bool = false) {
        runtime.receive(urls: urls, source: source, isColdStart: isColdStart)
    }
    func receive(userActivity: NSUserActivity, isColdStart: Bool = false) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return }
        receive(urls: [url], source: .webBrowsingActivity, isColdStart: isColdStart)
    }
    func receive(menu: ApplicationMenuCommandDTO) { runtime.receive(menu: menu) }
}
@MainActor
final class RuneScribeSceneDelegate: UIResponder, UIWindowSceneDelegate {
    private var appDelegate: AppDelegate? { UIApplication.shared.delegate as? AppDelegate }
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        appDelegate?.receive(
            urls: options.urlContexts.map(\.url).sorted { $0.absoluteString < $1.absoluteString },
            source: .sceneOpen,
            isColdStart: true
        )
        for activity in options.userActivities.sorted(by: { ($0.webpageURL?.absoluteString ?? "") < ($1.webpageURL?.absoluteString ?? "") }) { appDelegate?.receive(userActivity: activity, isColdStart: true) }
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        let urls = contexts.map(\.url).sorted { $0.absoluteString < $1.absoluteString }
        appDelegate?.receive(urls: urls, source: .sceneOpen)
    }
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        appDelegate?.receive(userActivity: userActivity)
    }
}
#endif
