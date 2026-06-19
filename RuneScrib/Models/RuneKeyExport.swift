// RuneScrib/Models/RuneKeyExport.swift

import Foundation

/// The single decoder/decrypter file written on export. It can be imported back
/// into RuneScrib (Key Management → Import Decoder) to decode messages, or shared
/// with an AI model (Claude, ChatGPT, Grok, etc.) which reads the table directly.
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
            usageInstructions: "To decode in the RuneScrib app: Key Management → Import " +
                                "Decoder, choose this file, then paste the runes into the " +
                                "Decode tab. To decode by hand or with an AI model: for each " +
                                "rune in the message, look it up in 'reverseMapping' to get the " +
                                "original character. Characters absent from the mapping pass " +
                                "through unchanged (e.g. newlines, emoji).",
            characterSetSize: 89,
            mapping: key.mapping,
            reverseMapping: key.reverseMapping
        )
    }
}
