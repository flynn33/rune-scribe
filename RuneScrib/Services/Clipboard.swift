// RuneScrib/Services/Clipboard.swift
//
// Cross-platform clipboard wrapper so views don't depend on AppKit/UIKit directly.

import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum Clipboard {
    /// Copies `string` to the system pasteboard, replacing its current contents.
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = string
        #endif
    }

    /// The pasteboard's monotonically-increasing change counter. Reading it does
    /// not access the contents (so it never triggers the iOS paste notification);
    /// callers use it to detect newly-copied content before reading the string.
    static var changeCount: Int {
        #if os(macOS)
        return NSPasteboard.general.changeCount
        #elseif os(iOS)
        return UIPasteboard.general.changeCount
        #else
        return 0
        #endif
    }

    /// Returns a `runescribe://…` cipher link currently on the pasteboard, or nil.
    /// On iOS this reads the pasteboard string, which can briefly notify the user,
    /// so call it only when `changeCount` indicates the contents changed.
    static func runeScribeURLString() -> String? {
        #if os(macOS)
        guard let raw = NSPasteboard.general.string(forType: .string) else { return nil }
        #elseif os(iOS)
        guard UIPasteboard.general.hasStrings, let raw = UIPasteboard.general.string else { return nil }
        #else
        let raw = ""
        #endif
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept both host form (runescribe://import) and path form (runescribe:import).
        return trimmed.hasPrefix("\(RuneCipherLink.scheme):") ? trimmed : nil
    }
}
