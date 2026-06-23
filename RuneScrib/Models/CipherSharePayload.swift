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
/// Replaces `RuneCipherLink`. Carries the real key + public id + decorative mapping;
/// the rune FONT is added to this package in Phase 2.
struct CipherSharePayload: Equatable {
    static let version: UInt8 = 2
    static let scheme = "runescribe"
    static let host = "import"
    static let byteCount = 1 + 8 + 32 + 32 + 4   // 77

    let publicID: Data        // 8
    let keyMaterial: Data     // 32
    let decorativeMapping: [Int]  // 32, permutation of 0..<32

    /// The display name parsed from a URL (nil for binary/file decode).
    private(set) var parsedName: String?

    init(publicID: Data, keyMaterial: Data, decorativeMapping: [Int]) {
        self.publicID = publicID
        self.keyMaterial = keyMaterial
        self.decorativeMapping = decorativeMapping
    }

    init(cipher: Cipher) {
        self.init(publicID: cipher.publicID, keyMaterial: cipher.keyMaterial,
                  decorativeMapping: cipher.decorativeMapping)
    }

    /// Reconstructs an importable `Cipher` (fresh id, `.imported`).
    func cipher(label: String) -> Cipher {
        Cipher(label: label, origin: .imported, publicID: publicID,
               keyMaterial: keyMaterial, decorativeMapping: decorativeMapping)
    }

    // MARK: binary

    func encoded() -> Data {
        var body = Data([Self.version])
        body.append(publicID)
        body.append(keyMaterial)
        body.append(Data(decorativeMapping.map { UInt8($0) }))
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
        self.init(publicID: pid, keyMaterial: key, decorativeMapping: map)
    }

    private static func checksum(of data: Data) -> Data {
        Data(SHA256.hash(data: data).prefix(4))
    }

    // MARK: URL

    func url(name: String?) throws -> URL {
        var comps = URLComponents()
        comps.scheme = Self.scheme
        comps.host = Self.host
        var items = [URLQueryItem(name: "v", value: String(Self.version)),
                     URLQueryItem(name: "p", value: Self.base64url(encoded()))]
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            items.append(URLQueryItem(name: "n", value: name))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw CipherShareError.invalidURL }
        return url
    }

    /// Parse `runescribe://import?...`; tolerate the `runescribe:import?...` path form.
    init(url: URL) throws {
        guard url.scheme?.lowercased() == Self.scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw CipherShareError.invalidURL }
        let marker = (comps.host ?? comps.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard marker == Self.host else { throw CipherShareError.invalidURL }
        let items = comps.queryItems ?? []
        guard let p = items.first(where: { $0.name == "p" })?.value, !p.isEmpty else { throw CipherShareError.missingPayload }
        let decoded = try CipherSharePayload(decoding: Self.bytesFromBase64url(p))
        self.init(publicID: decoded.publicID, keyMaterial: decoded.keyMaterial, decorativeMapping: decoded.decorativeMapping)
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
