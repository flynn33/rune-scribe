import Foundation
import CryptoKit

enum MessageShareError: Error, LocalizedError, Equatable, Sendable {
    case tooShort, unsupportedVersion(UInt8), unsupportedFlags(UInt8), badChecksum
    case senderNameTooLong, invalidSenderName, envelopeTooLarge, invalidEnvelopeLength
    var errorDescription: String? {
        switch self {
        case .tooShort, .unsupportedFlags, .invalidSenderName, .invalidEnvelopeLength:
            return "The message's data is corrupted."
        case .badChecksum:        return "The message failed its integrity check."
        case .unsupportedVersion: return "This message uses a newer format. Update Rune Scribe."
        case .senderNameTooLong:  return "The sender name is too long to share."
        case .envelopeTooLarge:   return "The encrypted message is too large to share."
        }
    }
}

/// The wire format for sharing a single encrypted message (file attachment / QR).
/// v1 layout:
///   version(1) | flags(1; bit0 = hasCipher) | nameLen(1, UInt8) | name(utf8, ≤255)
///   | envLen(2, UInt16 big-endian) | envelope | [embeddedCipher.encoded() 129B if flag] | checksum(4)
struct MessageSharePayload: Equatable, Sendable {
    static let version: UInt8 = 1

    let senderName: String
    let envelope: Data
    let embeddedCipher: CipherSharePayload?

    init(senderName: String, envelope: Data, embeddedCipher: CipherSharePayload?) {
        self.senderName = senderName
        self.envelope = envelope
        self.embeddedCipher = embeddedCipher
    }

    // MARK: binary

    func encoded() throws -> Data {
        let nameBytes = Data(senderName.utf8)
        guard nameBytes.count <= Int(UInt8.max) else {
            throw MessageShareError.senderNameTooLong
        }
        guard !envelope.isEmpty else { throw MessageShareError.invalidEnvelopeLength }
        guard envelope.count <= Int(UInt16.max) else {
            throw MessageShareError.envelopeTooLarge
        }

        var body = Data([Self.version])
        body.append(embeddedCipher == nil ? 0x00 : 0x01)        // flags
        body.append(UInt8(nameBytes.count))                     // nameLen
        body.append(nameBytes)                                  // name
        var envLen = UInt16(envelope.count).bigEndian
        body.append(Data(bytes: &envLen, count: 2))             // envLen (BE)
        body.append(envelope)
        if let embeddedCipher { body.append(try embeddedCipher.encoded()) }   // 129 bytes
        body.append(Self.checksum(of: body))
        return body
    }

    /// Decodes one payload from the front of `data`, returning it and the exact number of
    /// bytes it consumed (so a file form can treat any trailing bytes as the font blob).
    /// The 4-byte checksum is validated over `data[0 ..< consumed - 4]`.
    static func decodeConsuming(_ data: Data) throws -> (MessageSharePayload, consumed: Int) {
        // Minimum: version + flags + nameLen + envLen(2) + checksum(4) = 9 bytes.
        guard data.count >= 9 else { throw MessageShareError.tooShort }

        var i = data.startIndex
        guard data[i] == version else { throw MessageShareError.unsupportedVersion(data[i]) }
        i = data.index(i, offsetBy: 1)
        let flags = data[i]
        guard flags & ~0x01 == 0 else { throw MessageShareError.unsupportedFlags(flags) }
        let hasCipher = (flags & 0x01) != 0
        i = data.index(i, offsetBy: 1)
        let nameLen = Int(data[i])
        i = data.index(i, offsetBy: 1)
        guard data.distance(from: i, to: data.endIndex) >= nameLen + 2 + 4 else { throw MessageShareError.tooShort }
        let nameData = data.subdata(in: i ..< data.index(i, offsetBy: nameLen))
        i = data.index(i, offsetBy: nameLen)
        let envLen = Int(data.subdata(in: i ..< data.index(i, offsetBy: 2)).reduce(0) { ($0 << 8) | Int($1) })
        i = data.index(i, offsetBy: 2)
        guard envLen > 0 else { throw MessageShareError.invalidEnvelopeLength }
        let needed = envLen + (hasCipher ? CipherSharePayload.byteCount : 0) + 4
        guard data.distance(from: i, to: data.endIndex) >= needed else { throw MessageShareError.tooShort }
        let env = data.subdata(in: i ..< data.index(i, offsetBy: envLen))
        i = data.index(i, offsetBy: envLen)

        var embedded: CipherSharePayload?
        if hasCipher {
            let blob = data.subdata(in: i ..< data.index(i, offsetBy: CipherSharePayload.byteCount))
            embedded = try CipherSharePayload(decoding: blob)
            i = data.index(i, offsetBy: CipherSharePayload.byteCount)
        }

        let consumed = data.distance(from: data.startIndex, to: i) + 4
        let body = data.prefix(consumed - 4)
        let given = Data(data.subdata(in: i ..< data.index(i, offsetBy: 4)))
        guard checksum(of: body) == given else { throw MessageShareError.badChecksum }

        guard let senderName = String(data: nameData, encoding: .utf8) else {
            throw MessageShareError.invalidSenderName
        }
        let payload = MessageSharePayload(
            senderName: senderName,
            envelope: Data(env),
            embeddedCipher: embedded
        )
        return (payload, consumed)
    }

    /// Strict decode: rejects trailing bytes (preserves the QR / back-compat contract).
    init(decoding data: Data) throws {
        let (payload, consumed) = try Self.decodeConsuming(data)
        guard consumed == data.count else { throw MessageShareError.tooShort }
        self = payload
    }

    // MARK: file form

    /// Self-contained file form: the encoded payload followed by the raw font bytes (if any).
    func encodedFile(fontBytes: Data?) throws -> Data {
        guard let fontBytes, !fontBytes.isEmpty else { return try encoded() }
        return try encoded() + fontBytes
    }

    /// Splits a file form into (payload, fontBytes?). Bytes past the payload are the font;
    /// nil when none follow.
    static func decodeFile(_ data: Data) throws -> (MessageSharePayload, fontBytes: Data?) {
        let (payload, consumed) = try decodeConsuming(data)
        let rest = consumed == data.count ? nil
            : Data(data.suffix(from: data.index(data.startIndex, offsetBy: consumed)))
        return (payload, rest)
    }

    private static func checksum(of data: Data) -> Data {
        Data(SHA256.hash(data: data).prefix(4))
    }
}
