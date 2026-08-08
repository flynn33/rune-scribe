#if os(macOS)
import RuneScribeContracts
import SwiftUI

public struct RuneScribeCommands: Commands {
    private let onCommand: @MainActor @Sendable (ApplicationMenuCommandDTO) -> Void

    public init(
        onCommand: @escaping @MainActor @Sendable (ApplicationMenuCommandDTO) -> Void
    ) {
        self.onCommand = onCommand
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {}

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                onCommand(.openSettings)
            }
            .keyboardShortcut(",", modifiers: [.command])
        }

        CommandMenu("Cipher") {
            Button("Cipher Library…") {
                onCommand(.openCipherLibrary)
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
#endif
