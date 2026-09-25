import RuneScribeContracts
import RuneScribeMessagesShared
import RuneScribeUIRuntime

#if os(macOS)
import AppKit
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let runtime: RuneScribeRuntimeComposition
    override init() { runtime = RuneScribeRuntimeComposition(); super.init() }
    init(runtime: RuneScribeRuntimeComposition) { self.runtime = runtime; super.init() }
    var rootPresentationStore: RootViewPresentationStore { runtime.rootPresentationStore }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { Task { await runtime.start() } }
    }
    func applicationDidBecomeActive(_ notification: Notification) { receive(lifecycle: .didBecomeActive) }
    func applicationWillResignActive(_ notification: Notification) { receive(lifecycle: .willResignActive) }
    func applicationDidResignActive(_ notification: Notification) { receive(lifecycle: .didEnterBackground) }
    func applicationWillTerminate(_ notification: Notification) {
        receive(lifecycle: .willTerminate)
        Task { await runtime.stop() }
    }
    func application(_ application: NSApplication, open urls: [URL]) { runtime.receive(urls: urls, source: .applicationOpen) }
    func receive(menu: ApplicationMenuCommandDTO) { runtime.receive(menu: menu) }
    @discardableResult func receive(lifecycle event: ApplicationLifecycleInputDTO) -> InboundInputDispositionDTO { runtime.receive(lifecycle: event) }
}
#elseif os(iOS)
import UIKit
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let runtime: RuneScribeRuntimeComposition
    private let messagesInboxDrainer: MessagesImportInboxDrainer
    override init() {
        let messagesInboxDrainer = MessagesImportInboxDrainer()
        self.messagesInboxDrainer = messagesInboxDrainer
        runtime = RuneScribeRuntimeComposition(
            messagesImportStateHandler: { handoffID, state in
                await messagesInboxDrainer.recordTerminalState(
                    handoffID: handoffID,
                    state: state
                )
            }
        )
        super.init()
    }
    init(
        runtime: RuneScribeRuntimeComposition,
        messagesInboxDrainer: MessagesImportInboxDrainer = MessagesImportInboxDrainer()
    ) {
        self.runtime = runtime
        self.messagesInboxDrainer = messagesInboxDrainer
        super.init()
    }
    var rootPresentationStore: RootViewPresentationStore { runtime.rootPresentationStore }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            Task {
                await runtime.start()
                await drainMessagesInbox()
            }
        }
        return true
    }
    func applicationDidBecomeActive(_ application: UIApplication) {
        receive(lifecycle: .didBecomeActive)
        Task { await drainMessagesInbox() }
    }
    func applicationWillResignActive(_ application: UIApplication) { receive(lifecycle: .willResignActive) }
    func applicationDidEnterBackground(_ application: UIApplication) { receive(lifecycle: .didEnterBackground) }
    func applicationWillEnterForeground(_ application: UIApplication) { receive(lifecycle: .willEnterForeground) }
    func applicationWillTerminate(_ application: UIApplication) {
        receive(lifecycle: .willTerminate)
        Task { await runtime.stop() }
    }
    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        receive(urls: [url], source: .applicationOpen)
        return true
    }
    @discardableResult func receive(urls: [URL], source: InboundDeliverySourceDTO) -> [InboundInputDispositionDTO] {
        let dispositions = runtime.receive(urls: urls, source: source)
        for (URL, disposition) in zip(urls, dispositions) {
            Task {
                await messagesInboxDrainer.acknowledgeDirectDelivery(
                    of: URL,
                    disposition: disposition
                )
            }
        }
        return dispositions
    }
    @discardableResult func receive(userActivity: NSUserActivity) -> [InboundInputDispositionDTO] {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL else { return [] }
        return receive(urls: [url], source: .webBrowsingActivity)
    }
    @discardableResult func receive(lifecycle event: ApplicationLifecycleInputDTO) -> InboundInputDispositionDTO { runtime.receive(lifecycle: event) }

    private func drainMessagesInbox() async {
        await messagesInboxDrainer.drain { [runtime] URL in
            runtime.receive(
                urls: [URL],
                source: .webBrowsingActivity
            ).first ?? .rejected
        }
    }
}
#endif
