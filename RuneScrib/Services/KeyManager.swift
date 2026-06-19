// RuneScrib/Services/KeyManager.swift

import Foundation
import CryptoKit

// MARK: - KeyManager Errors

enum KeyManagerError: Error, LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case noKeyAvailable
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:     return "Failed to encrypt the cipher mapping."
        case .decryptionFailed:     return "Failed to decrypt the cipher mapping."
        case .noKeyAvailable:       return "No cipher key is currently loaded."
        case .exportFailed(let m):  return "Key export failed: \(m)"
        }
    }
}

// MARK: - KeyManager

/// Manages the full lifecycle of the cipher key:
/// load from Keychain, generate on first launch, rotate, and export.
///
/// Published as a singleton and injected as an @EnvironmentObject.
/// All published property mutations occur on the main actor.
@MainActor
final class KeyManager: ObservableObject {

    // MARK: - Singleton

    static let shared = KeyManager()

    // MARK: - Published State

    @Published private(set) var currentKey: RuneKey?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    // MARK: - Private Dependencies

    private let keychain = KeychainService.shared

    // MARK: - Init

    private init() {
        Task { await loadOrCreateKey() }
    }

    // MARK: - Load or Create

    /// Attempts to load the existing cipher key from Keychain.
    /// If none exists (first launch), generates a new random key and stores it.
    func loadOrCreateKey() async {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        do {
            if let encryptedMapping = try keychain.retrieveEncryptedMapping(),
               let aesKeyData = try keychain.retrieveSymmetricKeyData() {
                // Both exist — decrypt and load
                let aesKey = SymmetricKey(data: aesKeyData)
                let key = try decryptMapping(encryptedMapping, using: aesKey)
                currentKey = key
            } else {
                // First launch — create everything from scratch
                try generateAndStoreNewKey()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Rotate Key

    /// Generates a new random cipher mapping and stores it in Keychain,
    /// overwriting the previous mapping. The AES key is preserved.
    ///
    /// ⚠️ After rotation, any previously encoded messages are permanently undecodable.
    func rotateKey() async throws {
        isLoading = true
        lastError = nil
        defer { isLoading = false }

        try generateAndStoreNewKey()
    }

    // MARK: - Export Key

    /// Decrypts the current key and writes two export files to `directory`:
    /// 1. `RuneScrib-Key-[timestamp].json` — machine-readable for AI models
    /// 2. `RuneScrib-Key-[timestamp].md`   — human-readable table
    ///
    /// - Parameter directory: The URL of the directory to write into.
    /// - Returns: The URLs that were written: the `.json`, the `.md`, and the
    ///            bundled runic font + its licence.
    @discardableResult
    func exportKey(to directory: URL) throws -> [URL] {
        guard let key = currentKey else {
            throw KeyManagerError.noKeyAvailable
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: key.createdAt)
        let baseName = "RuneScrib-Key-\(timestamp)"

        // Write JSON
        let jsonURL = directory.appendingPathComponent("\(baseName).json")
        let jsonData = try buildJSONExport(key: key)
        try jsonData.write(to: jsonURL, options: .atomicWrite)

        // Write Markdown
        let mdURL = directory.appendingPathComponent("\(baseName).md")
        let mdString = buildMarkdownExport(key: key)
        guard let mdData = mdString.data(using: .utf8) else {
            throw KeyManagerError.exportFailed("Could not encode Markdown as UTF-8.")
        }
        try mdData.write(to: mdURL, options: .atomicWrite)

        // Bundle the runic font (+ licence) alongside the key so the exported
        // decipher is self-contained: whoever receives it can install the font and
        // see every rune render, including the ones default system fonts lack.
        let fontURLs = copyBundledFonts(to: directory)

        return [jsonURL, mdURL] + fontURLs
    }

    /// Copies the bundled Noto Sans Runic font and its SIL Open Font License into
    /// `directory`. Failures are non-fatal — the `.json`/`.md` key files are the
    /// essential output, and the font is only needed to *display* runes (decoding
    /// works from the tables regardless, since the code points survive copy/paste).
    private func copyBundledFonts(to directory: URL) -> [URL] {
        let items: [(resource: String, ext: String, destName: String)] = [
            ("NotoSansRunic-Regular", "ttf", "NotoSansRunic-Regular.ttf"),
            ("OFL",                   "txt", "NotoSansRunic-OFL.txt")
        ]
        let fm = FileManager.default
        var written: [URL] = []
        for item in items {
            guard let src = Bundle.main.url(forResource: item.resource, withExtension: item.ext) else { continue }
            let dest = directory.appendingPathComponent(item.destName)
            do {
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: src, to: dest)
                written.append(dest)
            } catch {
                continue   // skip this file; the key export still succeeds
            }
        }
        return written
    }

    // MARK: - Private Helpers

    /// Generates a new random RuneKey, encrypts it, and persists both the
    /// cipher mapping and (if needed) the AES key to Keychain.
    private func generateAndStoreNewKey() throws {
        // 1. Generate new random mapping
        let newMapping = RuneCharacterSet.generateRandomMapping()
        let newKey = RuneKey(mapping: newMapping)

        // 2. Get or create the AES symmetric key
        let aesKey: SymmetricKey
        if let existingData = try keychain.retrieveSymmetricKeyData() {
            aesKey = SymmetricKey(data: existingData)
        } else {
            aesKey = SymmetricKey(size: .bits256)
            let keyData = aesKey.withUnsafeBytes { Data($0) }
            try keychain.storeSymmetricKeyData(keyData)
        }

        // 3. Encrypt and store the new mapping
        let encryptedData = try encryptMapping(newKey, using: aesKey)
        try keychain.storeEncryptedMapping(encryptedData)

        // 4. Update published state (already on MainActor)
        currentKey = newKey
    }

    /// Encrypts a RuneKey to AES-GCM combined Data.
    private func encryptMapping(_ key: RuneKey, using aesKey: SymmetricKey) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let plaintext = try encoder.encode(key)

        let sealedBox = try AES.GCM.seal(plaintext, using: aesKey)
        guard let combined = sealedBox.combined else {
            throw KeyManagerError.encryptionFailed
        }
        return combined
    }

    /// Decrypts AES-GCM combined Data to a RuneKey.
    private func decryptMapping(_ data: Data, using aesKey: SymmetricKey) throws -> RuneKey {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let plaintext = try AES.GCM.open(sealedBox, using: aesKey)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RuneKey.self, from: plaintext)
    }

    // MARK: - Export Builders

    private func buildJSONExport(key: RuneKey) throws -> Data {
        let export = RuneKeyExport.from(key)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(export)
    }

    private func buildMarkdownExport(key: RuneKey) -> String {
        let isoDate = ISO8601DateFormatter().string(from: key.createdAt)

        var md = """
        # RuneScrib Cipher Key

        | Field | Value |
        |---|---|
        | Application | RuneScrib v1.0 |
        | Key Version | \(key.version) |
        | Key ID | `\(key.keyId)` |
        | Created | \(isoDate) |
        | Character Set Size | 89 |

        ## How to Use This Key (for AI Models)

        This document contains the substitution cipher mapping for RuneScrib.
        To **decode** a RuneScrib-encoded message:
        1. For each character in the encoded string, find it in the **Rune** column below.
        2. Replace it with the value in the **Input Character** column.
        3. Characters not present in this table pass through unchanged (newlines, emoji, etc.).

        The mapping is **case-sensitive**: uppercase and lowercase letters are distinct.
        Space is encoded as the rune listed next to `[SPACE]` in the table.

        ## Displaying the Runes

        A copy of the **Noto Sans Runic** font (`NotoSansRunic-Regular.ttf`) is bundled
        alongside this key, with its licence in `NotoSansRunic-OFL.txt` (SIL Open Font
        License). Install it to render every rune — most systems lack glyphs for a few
        of them (U+16F1–U+16F8) and show empty boxes instead. The font is only needed to
        *see* the runes; decoding from the tables below always works, because the original
        Unicode code points are preserved on copy and paste.

        ## Forward Mapping (Plain Text → Rune)

        | Input Character | Label | Rune | Unicode |
        |---|---|---|---|

        """

        // Sort for readability: uppercase, lowercase, digits, space, punctuation
        let sortedInputChars = RuneCharacterSet.inputCharacters
        for inputChar in sortedInputChars {
            guard let rune = key.mapping[inputChar] else { continue }
            let label: String
            switch inputChar {
            case " ":  label = "[SPACE]"
            case "\"": label = "[DQUOTE]"
            case "'":  label = "[SQUOTE]"
            default:   label = inputChar
            }
            let codePoint = rune.unicodeScalars.first.map {
                "U+\(String(format: "%04X", $0.value))"
            } ?? "?"

            md += "| `\(escapeMarkdown(inputChar))` | \(label) | \(rune) | \(codePoint) |\n"
        }

        md += """

        ## Reverse Mapping (Rune → Plain Text)

        | Rune | Unicode | Decoded Character | Label |
        |---|---|---|---|

        """

        let sortedRunes = key.reverseMapping.keys.sorted()
        for rune in sortedRunes {
            guard let inputChar = key.reverseMapping[rune] else { continue }
            let label: String
            switch inputChar {
            case " ":  label = "[SPACE]"
            case "\"": label = "[DQUOTE]"
            case "'":  label = "[SQUOTE]"
            default:   label = inputChar
            }
            let codePoint = rune.unicodeScalars.first.map {
                "U+\(String(format: "%04X", $0.value))"
            } ?? "?"

            md += "| \(rune) | \(codePoint) | `\(escapeMarkdown(inputChar))` | \(label) |\n"
        }

        md += "\n---\n*Generated by RuneScrib. Keep this file secure — it decodes your messages.*\n"

        return md
    }

    private func escapeMarkdown(_ str: String) -> String {
        str.replacingOccurrences(of: "|", with: "\\|")
           .replacingOccurrences(of: "`", with: "\\`")
    }
}
