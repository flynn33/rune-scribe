import Foundation

enum MessageEnvelopeError: Error { case empty, unsupportedVersion(UInt8) }

/// The on-the-wire message framing: a 1-byte version followed by the AES-GCM sealed box.
/// No cipher identifier is included — the receiver tries its stored ciphers (the AEAD
/// tag authenticates the right one).
enum MessageEnvelope {
    static let version: UInt8 = 1

    static func wrap(_ sealed: Data) -> Data {
        var out = Data([version])
        out.append(sealed)
        return out
    }

    static func unwrap(_ data: Data) throws -> Data {
        guard let v = data.first else { throw MessageEnvelopeError.empty }
        guard v == version else { throw MessageEnvelopeError.unsupportedVersion(v) }
        return data.subdata(in: data.index(after: data.startIndex)..<data.endIndex)
    }
}
