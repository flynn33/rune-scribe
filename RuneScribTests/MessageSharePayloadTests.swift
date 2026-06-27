import XCTest
import CryptoKit
@testable import RuneScrib

final class MessageSharePayloadTests: XCTestCase {
    /// Builds a real envelope (version byte + AES-GCM sealed box) for a known cipher.
    private func envelope(_ plaintext: String, with cipher: Cipher) throws -> Data {
        MessageEnvelope.wrap(try MessageCryptor().seal(plaintext, with: cipher))
    }

    func testBinaryRoundTripWithoutEmbeddedCipher() throws {
        let cipher = Cipher.generated(label: "Alice")
        let env = try envelope("hello runes", with: cipher)
        let payload = MessageSharePayload(senderName: "Alice", envelope: env, embeddedCipher: nil)

        let back = try MessageSharePayload(decoding: payload.encoded())
        XCTAssertEqual(back.senderName, "Alice")
        XCTAssertEqual(back.envelope, env)
        XCTAssertNil(back.embeddedCipher)
        // The recovered envelope still decrypts under the original cipher.
        let sealed = try MessageEnvelope.unwrap(back.envelope)
        XCTAssertEqual(try MessageCryptor().open(sealed, with: cipher), "hello runes")
    }

    func testBinaryRoundTripWithEmbeddedCipher() throws {
        let cipher = Cipher.generated(label: "Bob")
        let env = try envelope("with key", with: cipher)
        let embedded = CipherSharePayload(cipher: cipher)
        let payload = MessageSharePayload(senderName: "Bob", envelope: env, embeddedCipher: embedded)

        let back = try MessageSharePayload(decoding: payload.encoded())
        XCTAssertEqual(back.senderName, "Bob")
        XCTAssertEqual(back.envelope, env)
        XCTAssertEqual(back.embeddedCipher?.keyMaterial, cipher.keyMaterial)
        XCTAssertEqual(back.embeddedCipher?.decorativeMapping, cipher.decorativeMapping)
    }
}

extension MessageSharePayloadTests {
    func testFlippedByteRejectedByChecksum() throws {
        let cipher = Cipher.generated(label: "x")
        let env = MessageEnvelope.wrap(try MessageCryptor().seal("tamper", with: cipher))
        var bytes = MessageSharePayload(senderName: "x", envelope: env, embeddedCipher: nil).encoded()
        bytes[5] ^= 0x01
        XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
            XCTAssertEqual(error as? MessageShareError, .badChecksum)
        }
    }

    func testWrongVersionRejected() throws {
        let cipher = Cipher.generated(label: "x")
        let env = MessageEnvelope.wrap(try MessageCryptor().seal("v", with: cipher))
        var bytes = MessageSharePayload(senderName: "x", envelope: env, embeddedCipher: nil).encoded()
        bytes[0] = 9
        // Recompute checksum so we exercise the version guard, not the checksum guard.
        let body = bytes.prefix(bytes.count - 4)
        let fresh = Data(SHA256.hash(data: body).prefix(4))
        bytes.replaceSubrange((bytes.count - 4)..<bytes.count, with: fresh)
        XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
            guard case MessageShareError.unsupportedVersion(9) = error else {
                return XCTFail("expected unsupportedVersion(9), got \(error)")
            }
        }
    }

    func testTooShortRejected() {
        XCTAssertThrowsError(try MessageSharePayload(decoding: Data([1, 0, 0]))) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
    }

    func testLongEnvelopeRoundTripsViaUInt16Length() throws {
        let cipher = Cipher.generated(label: "Long")
        // A plaintext well past 255 bytes -> envelope length needs the 2-byte field.
        let long = String(repeating: "rune ", count: 400)   // 2000 chars
        let env = MessageEnvelope.wrap(try MessageCryptor().seal(long, with: cipher))
        XCTAssertGreaterThan(env.count, 255)
        let payload = MessageSharePayload(senderName: "Long", envelope: env, embeddedCipher: nil)

        let back = try MessageSharePayload(decoding: payload.encoded())
        XCTAssertEqual(back.envelope, env)
        let sealed = try MessageEnvelope.unwrap(back.envelope)
        XCTAssertEqual(try MessageCryptor().open(sealed, with: cipher), long)
    }
}

extension MessageSharePayloadTests {
    /// `decodeConsuming` reports exactly the encoded length and rebuilds the payload.
    func testDecodeConsumingReportsExactLength() throws {
        let cipher = Cipher.generated(label: "Con")
        let env = try envelope("consumed", with: cipher)
        let encoded = MessageSharePayload(senderName: "Con", envelope: env,
                                          embeddedCipher: CipherSharePayload(cipher: cipher)).encoded()

        let (payload, consumed) = try MessageSharePayload.decodeConsuming(encoded)
        XCTAssertEqual(consumed, encoded.count)
        XCTAssertEqual(payload.senderName, "Con")
        XCTAssertEqual(payload.envelope, env)
        XCTAssertEqual(payload.embeddedCipher?.keyMaterial, cipher.keyMaterial)
    }

    /// Strict `init(decoding:)` must reject any trailing bytes the encoder didn't write.
    func testInitDecodingRejectsTrailingBytes() throws {
        let cipher = Cipher.generated(label: "Trail")
        let env = try envelope("no extras", with: cipher)
        let encoded = MessageSharePayload(senderName: "Trail", envelope: env, embeddedCipher: nil).encoded()
        let withTrailer = encoded + Data([0xDE, 0xAD, 0xBE, 0xEF])
        XCTAssertThrowsError(try MessageSharePayload(decoding: withTrailer)) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
    }

    /// File form with a trailing font blob: `decodeFile` splits payload from font.
    func testEncodedFileRoundTripsWithTrailingFont() throws {
        let cipher = Cipher.generated(label: "WithFont")
        let env = try envelope("font rides along", with: cipher)
        let payload = MessageSharePayload(senderName: "WithFont", envelope: env,
                                          embeddedCipher: CipherSharePayload(cipher: cipher))
        let font = Data((0..<200).map { UInt8($0 & 0xFF) })   // synthetic font blob

        let file = payload.encodedFile(fontBytes: font)
        XCTAssertEqual(file.count, payload.encoded().count + font.count)

        let (back, fontBytes) = try MessageSharePayload.decodeFile(file)
        XCTAssertEqual(back.senderName, "WithFont")
        XCTAssertEqual(back.envelope, env)
        XCTAssertEqual(back.embeddedCipher?.keyMaterial, cipher.keyMaterial)
        XCTAssertEqual(fontBytes, font)
    }

    /// File form without a font: `encodedFile(fontBytes: nil)` equals `encoded()`,
    /// and `decodeFile` reports no trailing font.
    func testEncodedFileRoundTripsWithoutFont() throws {
        let cipher = Cipher.generated(label: "NoFont")
        let env = try envelope("plain message", with: cipher)
        let payload = MessageSharePayload(senderName: "NoFont", envelope: env, embeddedCipher: nil)

        XCTAssertEqual(payload.encodedFile(fontBytes: nil), payload.encoded())
        XCTAssertEqual(payload.encodedFile(fontBytes: Data()), payload.encoded())

        let (back, fontBytes) = try MessageSharePayload.decodeFile(payload.encodedFile(fontBytes: nil))
        XCTAssertEqual(back.envelope, env)
        XCTAssertNil(fontBytes)
    }
}

extension MessageSharePayloadTests {
    /// Appends a valid 4-byte checksum so decoding reaches the bounds guards rather
    /// than failing on the checksum.
    private func withChecksum(_ body: Data) -> Data {
        body + Data(SHA256.hash(data: body).prefix(4))
    }

    func testTruncatedNameRejected() {
        // version=1, flags=0, nameLen=200 (far more than the 0 name bytes present), envLen=0.
        let bytes = withChecksum(Data([1, 0, 200, 0, 0]))
        XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
    }

    func testTruncatedEnvelopeRejected() {
        // version=1, flags=0, nameLen=0, envLen=0xFFFF (65535) but no envelope bytes follow.
        let bytes = withChecksum(Data([1, 0, 0, 0xFF, 0xFF]))
        XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
    }

    func testTruncatedEmbeddedCipherRejected() {
        // hasCipher flag set, nameLen=0, envLen=0, but no room for the 129-byte embedded cipher.
        let bytes = withChecksum(Data([1, 1, 0, 0, 0]))
        XCTAssertThrowsError(try MessageSharePayload(decoding: bytes)) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
    }
}
