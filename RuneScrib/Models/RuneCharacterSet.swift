// RuneScrib/Models/RuneCharacterSet.swift

import Foundation

/// The authoritative source for the fixed character pools used by the cipher.
/// Neither array is ever modified at runtime — the KEY randomises the pairing,
/// not these arrays.
enum RuneCharacterSet {

    // MARK: - Input Characters (89, canonical order)

    /// The 89 standard characters that the cipher encodes.
    /// Order must match this specification exactly; it is used during
    /// key generation to pair input[i] with shuffledRune[i].
    static let inputCharacters: [String] = {
        var chars: [String] = []
        // Uppercase A–Z (26)
        chars += "ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
        // Lowercase a–z (26)
        chars += "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        // Digits 0–9 (10)
        chars += "0123456789".map { String($0) }
        // Space (1)
        chars += [" "]
        // Punctuation (26)
        chars += [".", ",", ":", ";", "!", "?", "'", "\"", "-", "_",
                  "(", ")", "[", "]", "{", "}", "/", "@", "#", "$",
                  "%", "&", "*", "+", "=", "<"]
        assert(chars.count == 89, "inputCharacters must have exactly 89 entries")
        return chars
    }()

    // MARK: - Runic Pool (89 Unicode Runic block characters, canonical order)

    /// The pool of 89 Unicode Runic characters that are assigned to input
    /// characters during key generation. This list is shuffled; the shuffle
    /// is the key.
    static let runicPool: [String] = {
        var pool: [String] = []

        // Group A: U+16A0 – U+16EA (75 characters, Elder Futhark and extensions)
        for codePoint in 0x16A0...0x16EA {
            pool.append(String(Unicode.Scalar(codePoint)!))
        }

        // Group B: U+16EB – U+16ED (3 runic punctuation marks)
        for codePoint in 0x16EB...0x16ED {
            pool.append(String(Unicode.Scalar(codePoint)!))
        }

        // Group C: U+16EE – U+16F8 (11 additional runes)
        for codePoint in 0x16EE...0x16F8 {
            pool.append(String(Unicode.Scalar(codePoint)!))
        }

        assert(pool.count == 89, "runicPool must have exactly 89 entries, got \(pool.count)")
        return pool
    }()

    // MARK: - Decorative Alphabet (32 runes for message encoding)

    /// The 32-rune alphabet used by the DECORATIVE base-32 message encoding (not the
    /// cipher). Drawn from U+16A0…U+16BF — core Elder Futhark, broadly covered by
    /// system fonts so messages render consistently even outside Rune Scribe.
    static let decorativeAlphabet: [Character] = (0x16A0...0x16BF).map {
        Character(Unicode.Scalar($0)!)
    }

    // MARK: - Set for O(1) Lookup

    /// Set of all input character strings, used by CipherEngine for fast membership testing.
    static let inputCharacterSet: Set<String> = Set(inputCharacters)

    // MARK: - Key Generation

    /// Generates a new random cipher mapping by shuffling the runic pool
    /// and pairing each rune with the corresponding canonical input character.
    ///
    /// Uses `SystemRandomNumberGenerator` (cryptographically secure on Apple platforms).
    ///
    /// - Returns: A [String: String] dictionary mapping each input character
    ///            to a unique rune character.
    static func generateRandomMapping() -> [String: String] {
        var shuffled = runicPool
        // NOTE: spec wrote `shuffle(using: &SystemRandomNumberGenerator())`, which
        // is a compile error (cannot pass a temporary as an inout argument). Binding
        // the generator to a variable first is the correct, behaviour-identical form:
        // Fisher-Yates shuffle driven by the cryptographically-secure system RNG.
        var rng = SystemRandomNumberGenerator()
        shuffled.shuffle(using: &rng)

        var mapping: [String: String] = [:]
        mapping.reserveCapacity(89)

        for (index, inputChar) in inputCharacters.enumerated() {
            mapping[inputChar] = shuffled[index]
        }

        return mapping
    }
}
