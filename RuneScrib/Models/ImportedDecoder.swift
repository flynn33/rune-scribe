// RuneScrib/Models/ImportedDecoder.swift

import Foundation

/// A cipher key imported from a decoder file, used to decode rune messages that
/// were encoded with another RuneScrib key (e.g. a correspondent's, or your own
/// from another device). Decoding needs only the reverse mapping; the forward
/// mapping and metadata are retained for display and validation.
struct ImportedDecoder: Codable, Equatable, Identifiable {

    let version: Int
    let keyId: String
    let createdAt: Date
    let mapping: [String: String]         // input char → rune
    let reverseMapping: [String: String]  // rune → input char

    var id: String { keyId }

    // MARK: - Errors

    enum ImportError: Error, LocalizedError {
        case notRuneScrib
        case wrongSize(Int)
        case inconsistent
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .notRuneScrib:     return "This file is not a RuneScrib decoder key."
            case .wrongSize(let n): return "Decoder has \(n) entries; a valid key has 89."
            case .inconsistent:     return "The decoder's forward and reverse maps don't match."
            case .unreadable(let m): return "Couldn't read the decoder file: \(m)"
            }
        }
    }

    // MARK: - Parsing

    /// Parses and validates a decoder file (the JSON produced by export) into an
    /// `ImportedDecoder`. Throws `ImportError` if the file isn't a well-formed,
    /// 89-character RuneScrib key.
    static func parse(_ data: Data) throws -> ImportedDecoder {
        let export: RuneKeyExport
        do {
            export = try JSONDecoder().decode(RuneKeyExport.self, from: data)
        } catch {
            throw ImportError.unreadable(error.localizedDescription)
        }

        guard export.applicationName == "RuneScrib" else { throw ImportError.notRuneScrib }
        guard export.mapping.count == 89, export.reverseMapping.count == 89 else {
            throw ImportError.wrongSize(export.mapping.count)
        }
        // The reverse map must be the exact inverse of the forward map.
        for (input, rune) in export.mapping where export.reverseMapping[rune] != input {
            throw ImportError.inconsistent
        }

        let created = ISO8601DateFormatter().date(from: export.createdAt) ?? Date()
        return ImportedDecoder(
            version: export.version,
            keyId: export.keyId,
            createdAt: created,
            mapping: export.mapping,
            reverseMapping: export.reverseMapping
        )
    }
}
