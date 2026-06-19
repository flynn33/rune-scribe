// RuneScrib/Services/FontRegistration.swift

import Foundation
import CoreText

/// Registers fonts bundled inside the app (Noto Sans Runic) into the process so
/// every Unicode Runic code point renders. The default system fonts on macOS and
/// iOS lack glyphs for U+16F1–U+16F8, which would otherwise appear as
/// missing-glyph boxes in the encoded output.
enum FontRegistration {
    static func registerBundledFonts() {
        for name in ["NotoSansRunic-Regular"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
