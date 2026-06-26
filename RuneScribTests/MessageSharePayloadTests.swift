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
    func testHTTPSURLRoundTripPreservesEverything() throws {
        let cipher = Cipher.generated(label: "Sam")
        let env = MessageEnvelope.wrap(try MessageCryptor().seal("url me", with: cipher))
        let payload = MessageSharePayload(senderName: "Sam",
                                          envelope: env,
                                          embeddedCipher: CipherSharePayload(cipher: cipher))
        let url = try payload.url()
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "ravenforgesoftware.com")
        XCTAssertEqual(url.path, "/rune-scribe/m")

        let parsed = try MessageSharePayload(url: url)
        XCTAssertEqual(parsed.senderName, "Sam")
        XCTAssertEqual(parsed.envelope, env)
        XCTAssertEqual(parsed.embeddedCipher?.keyMaterial, cipher.keyMaterial)
    }

    func testLegacyCustomSchemeURLParses() throws {
        let cipher = Cipher.generated(label: "Leg")
        let env = MessageEnvelope.wrap(try MessageCryptor().seal("legacy", with: cipher))
        let payload = MessageSharePayload(senderName: "Leg", envelope: env, embeddedCipher: nil)
        let p = payload.encoded().base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let legacy = URL(string: "runescribe://m?v=1&p=\(p)")!
        let parsed = try MessageSharePayload(url: legacy)
        XCTAssertEqual(parsed.senderName, "Leg")
        XCTAssertEqual(parsed.envelope, env)
    }

    func testIsMessageURLClassifies() {
        // message URLs
        XCTAssertTrue(MessageSharePayload.isMessageURL("https://ravenforgesoftware.com/rune-scribe/m?v=1&p=AAA"))
        XCTAssertTrue(MessageSharePayload.isMessageURL("runescribe://m?v=1&p=AAA"))
        // a cipher import URL must NOT be classified as a message
        XCTAssertFalse(MessageSharePayload.isMessageURL("https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAA"))
        XCTAssertFalse(MessageSharePayload.isMessageURL("runescribe://import?v=3&p=AAA"))
        // junk
        XCTAssertFalse(MessageSharePayload.isMessageURL("https://example.com/x"))
        XCTAssertFalse(MessageSharePayload.isMessageURL("hello world"))
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
