import RuneScribeContracts
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
        .commands {
            #if os(macOS)
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.receive(menu: .openSettings)
                    NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            #endif
            CommandMenu("Cipher") {
                Button("Cipher Library…") {
                    appDelegate.receive(menu: .openCipherLibrary)
                    NotificationCenter.default.post(name: .openLibraryRequested, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
    @ViewBuilder
    private var rootContent: some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            EmptyView()
        } else {
            RootView()
                .environmentObject(appDelegate.keyManager)
                .environmentObject(appDelegate.appLock)
                .environmentObject(appDelegate.importCoordinator)
                .environmentObject(appDelegate.messageCoordinator)
                .environmentObject(appDelegate.contactManager)
        }
    }
}

extension Notification.Name {
    static let openLibraryRequested = Notification.Name("com.runescribe.openLibraryRequested")
    static let openSettingsRequested = Notification.Name("com.runescribe.openSettingsRequested")
    static let replyToMessageRequested = Notification.Name("com.runescribe.replyToMessageRequested")
}
