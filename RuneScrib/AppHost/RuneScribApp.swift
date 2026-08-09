import RuneScribeContracts
import RuneScribeUIModule
import RuneScribeUIRuntime
import SwiftUI
@main
struct RuneScribApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    #endif
    var body: some Scene {
        WindowGroup {
            rootContent
            #if os(iOS)
            .onOpenURL { appDelegate.receive(urls: [$0], source: .sceneOpen) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { _ = appDelegate.receive(userActivity: $0) }
            .onChange(of: scenePhase) { previous, current in
                Self.lifecycleInputs(from: previous, to: current).forEach { _ = appDelegate.receive(lifecycle: $0) }
            }
            #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 600, height: 720)
        .windowResizability(.contentMinSize)
        #endif
        #if os(macOS)
        .commands {
            RuneScribeCommands { command in
                appDelegate.receive(menu: command)
            }
        }
        #endif
    }
    @ViewBuilder
    private var rootContent: some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            EmptyView()
        } else {
            RuntimePresentedRootView(store: appDelegate.rootPresentationStore)
        }
    }
    #if os(iOS)
    static func lifecycleInputs(from previous: ScenePhase, to current: ScenePhase) -> [ApplicationLifecycleInputDTO] {
        if current == .background { return [.didEnterBackground] }
        if current == .active { return previous == .background ? [.willEnterForeground, .didBecomeActive] : [.didBecomeActive] }
        if current == .inactive { return previous == .background ? [.willEnterForeground] : previous == .active ? [.willResignActive] : [] }
        return []
    }
    #endif
}
