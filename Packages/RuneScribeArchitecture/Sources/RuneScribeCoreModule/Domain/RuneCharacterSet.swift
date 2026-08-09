// RuneScrib/Models/RuneCharacterSet.swift

import Foundation

/// The fixed rune glyphs used to present encrypted messages. A cipher's decorative
/// mapping (a permutation of `0..<32`) decides which rune stands for each 5-bit value;
/// this enum only supplies the alphabet of glyphs.
enum RuneCharacterSet {

    /// The 32-rune alphabet used by the DECORATIVE base-32 message encoding (not the
    /// cipher). Drawn from U+16A0…U+16BF — core Elder Futhark, broadly covered by
    /// system fonts so messages render consistently even outside Rune Scribe.
    static let decorativeAlphabet: [Character] = (0x16A0...0x16BF).map {
        Character(Unicode.Scalar($0)!)
    }
}
