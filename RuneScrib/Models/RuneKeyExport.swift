// RuneScrib/Models/RuneKeyExport.swift

import Foundation

/// The structure written to disk when the user exports the cipher key.
/// This is what gets shared with AI models (Claude, ChatGPT, Grok, etc.)
/// for pre-loading the decryption table.
struct RuneKeyExport: Codable {
    let applicationName: String
    let version: Int
    let keyId: String
    let createdAt: String           // ISO 8601 string for readability
    let description: String
    let usageInstructions: String
    let characterSetSize: Int
    let mapping: [String: String]         // input char → rune char (forward)
    let reverseMapping: [String: String]  // rune char → input char (decode)

    static func from(_ key: RuneKey) -> RuneKeyExport {
        return RuneKeyExport(
            applicationName: "RuneScrib",
            version: key.version,
            keyId: key.keyId,
            createdAt: ISO8601DateFormatter().string(from: key.createdAt),
            description: "RuneScrib substitution cipher key. Each standard character " +
                         "maps to a unique Unicode Runic character (U+16A0–U+16F8). " +
                         "The mapping is a random bijection generated and stored " +
                         "encrypted on the originating device.",
            usageInstructions: "To decode a RuneScrib message: for each rune character " +
                                "in the encoded string, look up the rune in 'reverseMapping' " +
                                "to find the original character. Characters not in the " +
                                "mapping pass through unchanged (e.g. newlines, emoji).",
            characterSetSize: 89,
            mapping: key.mapping,
            reverseMapping: key.reverseMapping
        )
    }
}
