import RuneScribeContracts
import SwiftUI

enum RuneScribeShortcutKey: Equatable, Sendable {
    case character(Character)
    case returnKey

    var keyEquivalent: KeyEquivalent {
        switch self {
        case let .character(character): KeyEquivalent(character)
        case .returnKey: .return
        }
    }
}

struct RuneScribeShortcutModifiers: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    static let command = Self(rawValue: 1 << 0)
    static let shift = Self(rawValue: 1 << 1)

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}

struct RuneScribeCommandDescriptor: Equatable, Sendable {
    let title: String
    let command: ApplicationMenuCommandDTO?
    let key: RuneScribeShortcutKey
    let modifiers: RuneScribeShortcutModifiers
}

enum RuneScribeCommandCatalog {
    static let removesSystemNewItem = true
    static let settings = RuneScribeCommandDescriptor(
        title: "Settings…",
        command: .openSettings,
        key: .character(","),
        modifiers: [.command]
    )
    static let cipherLibrary = RuneScribeCommandDescriptor(
        title: "Cipher Library…",
        command: .openCipherLibrary,
        key: .character("l"),
        modifiers: [.command, .shift]
    )
    static let primaryAction = RuneScribeCommandDescriptor(
        title: "Rune Scribe",
        command: nil,
        key: .returnKey,
        modifiers: [.command]
    )
}

#if os(macOS)
public struct RuneScribeCommands: Commands {
    private let onCommand: @MainActor @Sendable (ApplicationMenuCommandDTO) -> Void

    public init(
        onCommand: @escaping @MainActor @Sendable (ApplicationMenuCommandDTO) -> Void
    ) {
        self.onCommand = onCommand
    }

    public var body: some Commands {
        if RuneScribeCommandCatalog.removesSystemNewItem {
            CommandGroup(replacing: .newItem) {}
        }

        CommandGroup(replacing: .appSettings) {
            Button(RuneScribeCommandCatalog.settings.title) {
                onCommand(RuneScribeCommandCatalog.settings.command ?? .openSettings)
            }
            .keyboardShortcut(
                RuneScribeCommandCatalog.settings.key.keyEquivalent,
                modifiers: RuneScribeCommandCatalog.settings.modifiers.eventModifiers
            )
        }

        CommandMenu("Cipher") {
            Button(RuneScribeCommandCatalog.cipherLibrary.title) {
                onCommand(RuneScribeCommandCatalog.cipherLibrary.command ?? .openCipherLibrary)
            }
            .keyboardShortcut(
                RuneScribeCommandCatalog.cipherLibrary.key.keyEquivalent,
                modifiers: RuneScribeCommandCatalog.cipherLibrary.modifiers.eventModifiers
            )
        }
    }
}
#endif
