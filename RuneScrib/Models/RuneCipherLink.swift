// RuneScrib/Models/RuneCipherLink.swift

import Foundation

/// The compact, shareable wire format for a cipher — the backbone of the QR,
/// deep-link, clipboard, and in-app-scanner import paths.
///
/// Because both alphabets are fixed and app-known (`RuneCharacterSet.inputCharacters`
/// and `RuneCharacterSet.runicPool`, 89 entries each, canonical order), a cipher is
/// fully described by a *permutation*: for each `inputCharacters[i]`, which
/// `runicPool` index it maps to. That's 89 bytes — small enough for a QR code and a
/// URL, unlike the multi-kilobyte `RuneKeyExport` JSON.
///
/// Canonical URL:
/// ```
/// runescribe://import?v=1&p=<base64url-of-89-bytes>&n=<percent-encoded-name>
/// ```
/// - `v` format version (only `1` accepted).
/// - `p` required; base64url (no padding) of the 89-byte permutation.
/// - `n` optional display name.
///
/// `keyId`/`createdAt` are intentionally **not** transmitted: the permutation fully
/// defines the cipher, and the receiver mints a fresh identity — exactly like a file
/// import. Every channel decodes a URL to a permutation, then funnels through
/// `exportJSONData(forPermutation:)` into the unchanged `KeyManager.importCipher(data:label:)`.
enum RuneCipherLink {

    // MARK: - Constants

    /// URL scheme registered for both app targets (see project.yml).
    static let scheme = "runescribe"
    /// URL host that marks an import link.
    static let host = "import"
    /// Current wire-format version.
    static let version = 1
    /// Permutation length — always the full character set.
    static let length = 89

    // MARK: - Errors

    enum LinkError: Error, LocalizedError, Equatable {
        case invalidURL
        case unsupportedVersion(Int)
        case missingPayload
        case badBase64
        case wrongPayloadSize(Int)
        case notAPermutation
        case mappingIncomplete

        var errorDescription: String? {
            switch self {
            case .invalidURL:            return "This isn't a Rune Scribe cipher link."
            case .unsupportedVersion(let v):
                return "This cipher link uses a newer format (v\(v)). Update Rune Scribe to import it."
            case .missingPayload:        return "The cipher link is missing its cipher data."
            case .badBase64:             return "The cipher link's data is corrupted."
            case .wrongPayloadSize(let n):
                return "The cipher data has \(n) entries; a valid cipher has \(length)."
            case .notAPermutation:       return "The cipher data is not a valid cipher mapping."
            case .mappingIncomplete:     return "This cipher can't be shared as a link or QR code."
            }
        }
    }

    // MARK: - Lookup

    /// Rune → its canonical `runicPool` index, for O(1) permutation building.
    private static let runeToIndex: [String: Int] = {
        var map: [String: Int] = [:]
        map.reserveCapacity(length)
        for (index, rune) in RuneCharacterSet.runicPool.enumerated() { map[rune] = index }
        return map
    }()

    // MARK: - Encode

    /// Builds the canonical `runescribe://import` URL for a cipher.
    ///
    /// Throws `.mappingIncomplete` only for an exotic imported cipher whose runes
    /// aren't drawn from the canonical runic pool (a hand-crafted decoder file);
    /// every app-generated cipher and every normal import encodes cleanly.
    static func encodeURL(for key: RuneKey, name: String?) throws -> URL {
        let perm = try permutation(for: key)

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "p", value: base64url(perm)),
        ]
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { items.append(URLQueryItem(name: "n", value: trimmed)) }
        }
        components.queryItems = items

        guard let url = components.url else { throw LinkError.invalidURL }
        return url
    }

    /// The 89-element permutation for a key: `permutation[i]` is the `runicPool`
    /// index that `inputCharacters[i]` maps to.
    static func permutation(for key: RuneKey) throws -> [UInt8] {
        var perm = [UInt8](repeating: 0, count: length)
        for (i, input) in RuneCharacterSet.inputCharacters.enumerated() {
            guard let rune = key.mapping[input], let index = runeToIndex[rune] else {
                throw LinkError.mappingIncomplete
            }
            perm[i] = UInt8(index)
        }
        return perm
    }

    /// base64url (RFC 4648 §5): `-`/`_` alphabet, no `=` padding.
    static func base64url(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Decode

    /// Parses a `runescribe://import` URL into a permutation and optional name.
    static func decodeURL(_ url: URL) throws -> (perm: [UInt8], name: String?) {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw LinkError.invalidURL }

        // Accept the host form (runescribe://import?…); tolerate the path form
        // (runescribe:import?…) that some clients produce.
        let marker = (components.host ?? components.path)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard marker == host else { throw LinkError.invalidURL }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        guard let rawVersion = value("v"), let v = Int(rawVersion) else {
            throw LinkError.unsupportedVersion(0)
        }
        guard v == version else { throw LinkError.unsupportedVersion(v) }

        guard let payload = value("p"), !payload.isEmpty else { throw LinkError.missingPayload }
        let perm = try decodePayload(payload)

        let name = value("n")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (perm, (name?.isEmpty ?? true) ? nil : name)
    }

    /// Decodes a base64url payload to a validated 89-byte permutation.
    static func decodePayload(_ payload: String) throws -> [UInt8] {
        let bytes = try bytesFromBase64url(payload)
        guard bytes.count == length else { throw LinkError.wrongPayloadSize(bytes.count) }
        guard isValidPermutation(bytes) else { throw LinkError.notAPermutation }
        return bytes
    }

    /// Decodes base64url (re-padding and swapping the `-`/`_` alphabet back).
    static func bytesFromBase64url(_ string: String) throws -> [UInt8] {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: base64) else { throw LinkError.badBase64 }
        return [UInt8](data)
    }

    /// True when `bytes` is a true permutation of `0..<89` (each index exactly once).
    static func isValidPermutation(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == length else { return false }
        var seen = [Bool](repeating: false, count: length)
        for byte in bytes {
            let index = Int(byte)
            guard index < length, !seen[index] else { return false }
            seen[index] = true
        }
        return true
    }

    // MARK: - Bridge to the existing import path

    /// Reconstructs the forward mapping from a permutation.
    /// `mapping[inputCharacters[i]] = runicPool[permutation[i]]`.
    static func mapping(forPermutation perm: [UInt8]) -> [String: String] {
        var map: [String: String] = [:]
        map.reserveCapacity(length)
        for (i, input) in RuneCharacterSet.inputCharacters.enumerated() {
            map[input] = RuneCharacterSet.runicPool[Int(perm[i])]
        }
        return map
    }

    /// Converts a permutation into the exact `RuneKeyExport` JSON bytes a file
    /// import would carry, so every wire channel reuses the unchanged
    /// `KeyManager.importCipher(data:label:)` funnel and its validation.
    static func exportJSONData(forPermutation perm: [UInt8]) throws -> Data {
        guard isValidPermutation(perm) else { throw LinkError.notAPermutation }
        let key = RuneKey(mapping: mapping(forPermutation: perm))
        return try JSONEncoder().encode(RuneKeyExport.from(key))
    }
}
