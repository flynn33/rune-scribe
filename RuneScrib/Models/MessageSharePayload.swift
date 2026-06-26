import Foundation
import CryptoKit

enum MessageShareError: Error, LocalizedError, Equatable {
    case tooShort, unsupportedVersion(UInt8), badChecksum
    case invalidURL, badBase64, missingPayload
    var errorDescription: String? {
        switch self {
        case .tooShort, .badBase64:     return "The message's data is corrupted."
        case .badChecksum:              return "The message failed its integrity check."
        case .unsupportedVersion:       return "This message uses a newer format. Update Rune Scribe."
        case .invalidURL:               return "This isn't a Rune Scribe message link."
        case .missingPayload:           return "The message link is missing its data."
        }
    }
}

/// The wire format for sharing a single encrypted message (deep-link / iMessage).
/// v1 layout:
///   version(1) | flags(1; bit0 = hasCipher) | nameLen(1, UInt8) | name(utf8, ≤255)
///   | envLen(2, UInt16 big-endian) | envelope | [embeddedCipher.encoded() 129B if flag] | checksum(4)
struct MessageSharePayload: Equatable {
    static let version: UInt8 = 1
    static let scheme = "runescribe"
    static let host = "m"
    static let webHost = "ravenforgesoftware.com"
    static let webPath = "/rune-scribe/m"

    let senderName: String
    let envelope: Data
    let embeddedCipher: CipherSharePayload?

    init(senderName: String, envelope: Data, embeddedCipher: CipherSharePayload?) {
        self.senderName = senderName
        self.envelope = envelope
        self.embeddedCipher = embeddedCipher
    }

    // MARK: binary

    func encoded() -> Data {
        let nameBytes = Data(senderName.utf8).prefix(255)
        var body = Data([Self.version])
        body.append(embeddedCipher == nil ? 0x00 : 0x01)        // flags
        body.append(UInt8(nameBytes.count))                     // nameLen
        body.append(Data(nameBytes))                            // name
        var envLen = UInt16(envelope.count).bigEndian
        body.append(Data(bytes: &envLen, count: 2))             // envLen (BE)
        body.append(envelope)
        if let embeddedCipher { body.append(embeddedCipher.encoded()) }   // 129 bytes
        body.append(Self.checksum(of: body))
        return body
    }

    init(decoding data: Data) throws {
        // Minimum: version + flags + nameLen + envLen(2) + checksum(4) = 9 bytes.
        guard data.count >= 9 else { throw MessageShareError.tooShort }
        let body = data.prefix(data.count - 4)
        let given = Data(data.suffix(4))
        guard Self.checksum(of: body) == given else { throw MessageShareError.badChecksum }

        var i = data.startIndex
        guard data[i] == Self.version else { throw MessageShareError.unsupportedVersion(data[i]) }
        i = data.index(i, offsetBy: 1)
        let hasCipher = (data[i] & 0x01) != 0
        i = data.index(i, offsetBy: 1)
        let nameLen = Int(data[i])
        i = data.index(i, offsetBy: 1)
        guard data.distance(from: i, to: data.endIndex) >= nameLen + 2 + 4 else { throw MessageShareError.tooShort }
        let nameData = data.subdata(in: i ..< data.index(i, offsetBy: nameLen))
        i = data.index(i, offsetBy: nameLen)
        let envLen = Int(data.subdata(in: i ..< data.index(i, offsetBy: 2)).reduce(0) { ($0 << 8) | Int($1) })
        i = data.index(i, offsetBy: 2)
        let needed = envLen + (hasCipher ? CipherSharePayload.byteCount : 0) + 4
        guard data.distance(from: i, to: data.endIndex) >= needed else { throw MessageShareError.tooShort }
        let env = data.subdata(in: i ..< data.index(i, offsetBy: envLen))
        i = data.index(i, offsetBy: envLen)

        var embedded: CipherSharePayload?
        if hasCipher {
            let blob = data.subdata(in: i ..< data.index(i, offsetBy: CipherSharePayload.byteCount))
            embedded = try CipherSharePayload(decoding: blob)
        }
        self.init(senderName: String(decoding: nameData, as: UTF8.self),
                  envelope: Data(env), embeddedCipher: embedded)
    }

    private static func checksum(of data: Data) -> Data {
        Data(SHA256.hash(data: data).prefix(4))
    }

    // MARK: URL

    /// True for a Rune Scribe message link in either the https or legacy custom-scheme form.
    /// Deliberately does NOT match a cipher import link (`/rune-scribe/import`).
    static func isMessageURL(_ string: String) -> Bool {
        let s = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("\(scheme)://\(host)?") || s == "\(scheme)://\(host)" || s.hasPrefix("\(scheme)://\(host)/") {
            return true
        }
        for base in ["https://\(webHost)\(webPath)", "https://www.\(webHost)\(webPath)"] {
            if s == base || s.hasPrefix("\(base)?") || s.hasPrefix("\(base)/") { return true }
        }
        return false
    }

    /// The sender name travels inside the binary body, so the URL carries no `n=` item;
    /// `init(url:)` never reads one back.
    func url() throws -> URL {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = Self.webHost; comps.path = Self.webPath
        comps.queryItems = [URLQueryItem(name: "v", value: String(Self.version)),
                            URLQueryItem(name: "p", value: Self.base64url(encoded()))]
        guard let url = comps.url else { throw MessageShareError.invalidURL }
        return url
    }

    /// Parse a Rune Scribe message URL in either the https universal-link or legacy `runescribe://m` form.
    init(url: URL) throws {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw MessageShareError.invalidURL }
        let isHTTPS = url.scheme?.lowercased() == "https"
            && (comps.host?.lowercased() == Self.webHost || comps.host?.lowercased() == "www.\(Self.webHost)")
            && comps.path.lowercased().hasPrefix(Self.webPath)
        let isScheme = url.scheme?.lowercased() == Self.scheme
            && ((comps.host ?? comps.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == Self.host)
        guard isHTTPS || isScheme else { throw MessageShareError.invalidURL }
        let items = comps.queryItems ?? []
        guard let p = items.first(where: { $0.name == "p" })?.value, !p.isEmpty else { throw MessageShareError.missingPayload }
        try self.init(decoding: Self.bytesFromBase64url(p))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func bytesFromBase64url(_ s: String) throws -> Data {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = b.count % 4; if rem > 0 { b += String(repeating: "=", count: 4 - rem) }
        guard let data = Data(base64Encoded: b) else { throw MessageShareError.badBase64 }
        return data
    }
}
