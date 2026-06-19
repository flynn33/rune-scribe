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
}
