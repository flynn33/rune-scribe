import Foundation
import CryptoKit

enum CipherShareError: Error, LocalizedError {
    case wrongSize, unsupportedVersion(UInt8), badChecksum, notAMapping
    case invalidURL, badBase64, missingPayload
    var errorDescription: String? {
        switch self {
        case .wrongSize, .badBase64, .notAMapping: return "The cipher's data is corrupted."
        case .badChecksum:                          return "The cipher's data failed its integrity check."
        case .unsupportedVersion:                   return "This cipher uses a newer format. Update Rune Scribe."
        case .invalidURL:                           return "This isn't a Rune Scribe cipher link."
        case .missingPayload:                       return "The cipher link is missing its data."
        }
    }
}

/// The compact, validated wire format for sharing a cipher (QR / deep-link / file).
/// v3 layout (129 bytes):
///   version(1) | publicID(8) | keyMaterial(32) | decorativeMapping(32)
///   | fontId(16, utf8 zero-padded) | fontVersion(4, big-endian) | fontSha256(32)
///   | checksum(4)
struct CipherSharePayload: Equatable {
    static let version: UInt8 = 3
    static let scheme = "runescribe"
    static let host = "import"
    static let byteCount = 1 + 8 + 32 + 32 + 16 + 4 + 32 + 4   // 129
    static let webHost = "ravenforgesoftware.com"
    static let webPath = "/rune-scribe/import"

    let publicID: Data        // 8
    let keyMaterial: Data     // 32
    let decorativeMapping: [Int]  // 32, permutation of 0..<32
    let fontRef: FontRef      // 16 + 4 + 32

    /// The display name parsed from a URL (nil for binary/file decode).
    private(set) var parsedName: String?

    init(publicID: Data, keyMaterial: Data, decorativeMapping: [Int], fontRef: FontRef) {
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.decorativeMapping = decorativeMapping
        self.fontRef = fontRef
    }

    init(cipher: Cipher) {
        self.init(publicID: cipher.publicID, keyMaterial: cipher.keyMaterial,
                  decorativeMapping: cipher.decorativeMapping, fontRef: cipher.fontRef)
    }

    /// Reconstructs an importable `Cipher` (fresh id, `.imported`).
    func cipher(label: String) -> Cipher {
        Cipher(label: label, origin: .imported, publicID: publicID,
               keyMaterial: keyMaterial, decorativeMapping: decorativeMapping,
               fontRef: fontRef)
    }

    // MARK: binary

    func encoded() -> Data {
        var body = Data([Self.version])
        body.append(publicID)
        body.append(keyMaterial)
        body.append(Data(decorativeMapping.map { UInt8($0) }))
        body.append(Self.fixedID(fontRef.id))                       // 16 bytes
        var v = UInt32(fontRef.version).bigEndian
        body.append(Data(bytes: &v, count: 4))                      // 4 bytes
        body.append(fontRef.sha256)                                 // 32 bytes
        body.append(Self.checksum(of: body))
        return body
    }

    init(decoding data: Data) throws {
        guard data.count == Self.byteCount else { throw CipherShareError.wrongSize }
        let body = data.prefix(Self.byteCount - 4)
        let given = data.suffix(4)
        guard Self.checksum(of: body) == Data(given) else { throw CipherShareError.badChecksum }
        var i = data.startIndex
        guard data[i] == Self.version else { throw CipherShareError.unsupportedVersion(data[i]) }
        i = data.index(i, offsetBy: 1)
        let pid  = data.subdata(in: i ..< data.index(i, offsetBy: 8));  i = data.index(i, offsetBy: 8)
        let key  = data.subdata(in: i ..< data.index(i, offsetBy: 32)); i = data.index(i, offsetBy: 32)
        let map  = data.subdata(in: i ..< data.index(i, offsetBy: 32)).map { Int($0) }
        guard Set(map) == Set(0..<32) else { throw CipherShareError.notAMapping }
        i = data.index(i, offsetBy: 32)
        let fontIdData   = data.subdata(in: i ..< data.index(i, offsetBy: 16)); i = data.index(i, offsetBy: 16)
        let fontVerData  = data.subdata(in: i ..< data.index(i, offsetBy: 4));  i = data.index(i, offsetBy: 4)
        let fontSha      = data.subdata(in: i ..< data.index(i, offsetBy: 32))
        let fontId      = Self.parseID(fontIdData)
        let fontVersion = Int(fontVerData.reduce(0) { ($0 << 8) | UInt32($1) })
        let ref = FontRef(id: fontId, version: fontVersion, sha256: fontSha)
        self.init(publicID: pid, keyMaterial: key, decorativeMapping: map, fontRef: ref)
    }

    // MARK: file form

    /// Self-contained file form: the 129-byte compact payload followed by the raw font bytes.
    func encodedFile(fontBytes: Data) -> Data { encoded() + fontBytes }

    /// Splits a file form into (payload, fontBytes?). A file exactly `byteCount` long has no font.
    static func decodeFile(_ data: Data) throws -> (CipherSharePayload, Data?) {
        guard data.count >= byteCount else { throw CipherShareError.wrongSize }
        let payload = try CipherSharePayload(decoding: data.prefix(byteCount))
        let rest = data.count == byteCount ? nil
            : Data(data.suffix(from: data.index(data.startIndex, offsetBy: byteCount)))
        return (payload, rest)
    }

    /// True for a Rune Scribe share link in either the https or legacy custom-scheme form.
    static func isShareURL(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("runescribe:") { return true }
        return s.hasPrefix("https://\(webHost)\(webPath)") || s.hasPrefix("https://www.\(webHost)\(webPath)")
    }

    private static func checksum(of data: Data) -> Data {
        Data(SHA256.hash(data: data).prefix(4))
    }

    private static func fixedID(_ id: String) -> Data {
        var d = Data(id.utf8).prefix(16)
        d.append(Data(repeating: 0, count: 16 - d.count))
        return Data(d)
    }

    private static func parseID(_ d: Data) -> String {
        String(decoding: Data(d.prefix { $0 != 0 }), as: UTF8.self)
    }

    // MARK: URL

    func url(name: String?) throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = Self.webHost; comps.path = Self.webPath
        var items = [URLQueryItem(name: "v", value: String(Self.version)),
                     URLQueryItem(name: "p", value: Self.base64url(encoded()))]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            items.append(URLQueryItem(name: "n", value: name))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw CipherShareError.invalidURL }
        return url
    }

    /// Parse a Rune Scribe share URL in either the https universal-link or legacy `runescribe://import` form.
    init(url: URL) throws {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CipherShareError.invalidURL }
        let isHTTPS = url.scheme?.lowercased() == "https"
            && (comps.host?.lowercased() == Self.webHost || comps.host?.lowercased() == "www.\(Self.webHost)")
            && comps.path.lowercased().hasPrefix("/rune-scribe/import")
        let isScheme = url.scheme?.lowercased() == "runescribe"
            && ((comps.host ?? comps.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "import")
        guard isHTTPS || isScheme else { throw CipherShareError.invalidURL }
        let items = comps.queryItems ?? []
        guard let p = items.first(where: { $0.name == "p" })?.value, !p.isEmpty else { throw CipherShareError.missingPayload }
        let decoded = try CipherSharePayload(decoding: Self.bytesFromBase64url(p))
        self.init(publicID: decoded.publicID, keyMaterial: decoded.keyMaterial,
                  decorativeMapping: decoded.decorativeMapping, fontRef: decoded.fontRef)
        self.parsedName = items.first(where: { $0.name == "n" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func bytesFromBase64url(_ s: String) throws -> Data {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b.count % 4; if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b) else { throw CipherShareError.badBase64 }
        return data
    }
}
