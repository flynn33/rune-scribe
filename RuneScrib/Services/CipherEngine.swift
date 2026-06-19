// RuneScrib/Services/CipherEngine.swift

import Foundation

// MARK: - CipherEngine

/// Stateless encoder/decoder that operates on a given RuneKey.
/// Thread-safe: RuneKey is a value type; CipherEngine holds no mutable state.
struct CipherEngine {

    // MARK: - Properties

    private let key: RuneKey

    // MARK: - Initialiser

    init(key: RuneKey) {
        self.key = key
    }

    // MARK: - Encode

    /// Encodes a plain-text String into a rune String.
    ///
    /// - For each character in `text`:
    ///   - If the character is in the mapping, replace with its rune.
    ///   - Otherwise, pass the character through unchanged.
    /// - Newlines always pass through unchanged.
    ///
    /// - Parameter text: The plain-text String to encode.
    /// - Returns: The rune-encoded String.
    func encode(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        for character in text {
            let charStr = String(character)
            if let rune = key.mapping[charStr] {
                result += rune
            } else {
                // Pass through: newlines, emoji, accented letters, etc.
                result += charStr
            }
        }

        return result
    }

    // MARK: - Decode

    /// Decodes a rune String back to the original plain-text String.
    ///
    /// - For each character in `runeText`:
    ///   - If the character is a known rune in the reverse mapping, replace with the original.
    ///   - Otherwise, pass through unchanged.
    ///
    /// - Parameter runeText: A rune-encoded String.
    /// - Returns: The decoded plain-text String.
    func decode(_ runeText: String) -> String {
        var result = ""
        result.reserveCapacity(runeText.count)

        for character in runeText {
            let charStr = String(character)
            if let original = key.reverseMapping[charStr] {
                result += original
            } else {
                result += charStr
            }
        }

        return result
    }
}
