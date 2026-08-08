import Foundation
import RuneScribeContracts

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum SystemClipboardServiceError: Error, Equatable, Sendable {
    case writeFailed
}

/// Main-actor adapter for the system pasteboard.
///
/// It deliberately returns the raw pasteboard string. Rune Scribe link
/// recognition and whitespace policy remain Core responsibilities.
@MainActor
public final class SystemClipboardService: ClipboardReading, ClipboardWriting {
    private let operations: ClipboardOperations

    public init() {
        operations = .system
    }

    init(operations: ClipboardOperations) {
        self.operations = operations
    }

    public func changeCount() async -> Int {
        changeCountSynchronously()
    }

    public func string() async -> String? {
        stringSynchronously()
    }

    public func setString(_ value: String) async throws {
        try setStringSynchronously(value)
    }

    public func changeCountSynchronously() -> Int {
        operations.changeCount()
    }

    public func stringSynchronously() -> String? {
        operations.string()
    }

    public func setStringSynchronously(_ value: String) throws {
        guard operations.setString(value) else {
            throw SystemClipboardServiceError.writeFailed
        }
    }
}

struct ClipboardOperations: Sendable {
    let changeCount: @MainActor @Sendable () -> Int
    let string: @MainActor @Sendable () -> String?
    let setString: @MainActor @Sendable (String) -> Bool

    static let system = ClipboardOperations(
        changeCount: {
            #if os(macOS)
            NSPasteboard.general.changeCount
            #elseif os(iOS)
            UIPasteboard.general.changeCount
            #else
            0
            #endif
        },
        string: {
            #if os(macOS)
            NSPasteboard.general.string(forType: .string)
            #elseif os(iOS)
            guard UIPasteboard.general.hasStrings else { return nil }
            return UIPasteboard.general.string
            #else
            nil
            #endif
        },
        setString: { value in
            #if os(macOS)
            NSPasteboard.general.clearContents()
            return NSPasteboard.general.setString(value, forType: .string)
            #elseif os(iOS)
            UIPasteboard.general.string = value
            return true
            #else
            return false
            #endif
        }
    )
}
