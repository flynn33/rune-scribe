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
    #endif

    var body: some Scene {
        WindowGroup { rootContent }
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
}
