import XCTest
@testable import RuneScrib

final class CipherSharePayloadTests: XCTestCase {
    func testBinaryRoundTripRebuildsAWorkingCipher() throws {
        let original = Cipher.generated(label: "Alice")
        let payload = CipherSharePayload(cipher: original)
        let rebuilt = try CipherSharePayload(decoding: payload.encoded()).cipher(label: "Imported")

        XCTAssertEqual(rebuilt.keyMaterial, original.keyMaterial)
        XCTAssertEqual(rebuilt.publicID, original.publicID)
        XCTAssertEqual(rebuilt.decorativeMapping, original.decorativeMapping)
        XCTAssertEqual(rebuilt.origin, .imported)

        let runes = try MessageService().compose("ping", with: original)
        XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "ping")
    }

    func testURLRoundTrip() throws {
        let c = Cipher.generated(label: "Bob")
        let url = try CipherSharePayload(cipher: c).url(name: "Bob's cipher")
        let parsed = try CipherSharePayload(url: url)
        XCTAssertEqual(parsed.keyMaterial, c.keyMaterial)
        XCTAssertEqual(parsed.parsedName, "Bob's cipher")
    }

    func testCorruptionRejectedByChecksum() throws {
        var bytes = CipherSharePayload(cipher: .generated(label: "x")).encoded()
        bytes[10] ^= 0x01
        XCTAssertThrowsError(try CipherSharePayload(decoding: bytes))
    }

    func testWrongVersionRejected() throws {
        var bytes = CipherSharePayload(cipher: .generated(label: "x")).encoded()
        bytes[0] = 9
        XCTAssertThrowsError(try CipherSharePayload(decoding: bytes))
    }
}

extension CipherSharePayloadTests {
    func testV3CompactRoundTripIncludesFontRef() throws {
        let c = Cipher.generated(label: "Alice")
        let back = try CipherSharePayload(decoding: CipherSharePayload(cipher: c).encoded())
        XCTAssertEqual(back.keyMaterial, c.keyMaterial)
        XCTAssertEqual(back.fontRef, c.fontRef)
        XCTAssertEqual(back.cipher(label: "in").fontRef, .bundled)
    }
    func testV3ByteCount() {
        XCTAssertEqual(CipherSharePayload(cipher: .generated(label: "x")).encoded().count, 129)
        XCTAssertEqual(CipherSharePayload.byteCount, 129)
    }
}

extension CipherSharePayloadTests {
    func testFileFormRoundTripsPayloadAndFontBytes() throws {
        let c = Cipher.generated(label: "Bob")
        let font = FontRef.bundledFontData()
        let file = CipherSharePayload(cipher: c).encodedFile(fontBytes: font)
        let (payload, bytes) = try CipherSharePayload.decodeFile(file)
        XCTAssertEqual(payload.keyMaterial, c.keyMaterial)
        XCTAssertEqual(bytes, font)
    }
    func testFileFormWithoutFontIsCompactOnly() throws {
        let c = Cipher.generated(label: "C")
        let (payload, bytes) = try CipherSharePayload.decodeFile(CipherSharePayload(cipher: c).encoded())
        XCTAssertEqual(payload.publicID, c.publicID)
        XCTAssertNil(bytes)
    }
    func testHTTPSURLRoundTrip() throws {
        let c = Cipher.generated(label: "Dee")
        let url = try CipherSharePayload(cipher: c).url(name: "Dee")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "ravenforgesoftware.com")
        let parsed = try CipherSharePayload(url: url)
        XCTAssertEqual(parsed.keyMaterial, c.keyMaterial)
        XCTAssertEqual(parsed.parsedName, "Dee")
    }
    func testLegacyCustomSchemeStillParses() throws {
        let c = Cipher.generated(label: "E")
        let p = CipherSharePayload(cipher: c).encoded()
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let legacy = URL(string: "runescribe://import?v=3&p=\(p)")!
        XCTAssertEqual(try CipherSharePayload(url: legacy).keyMaterial, c.keyMaterial)
    }
    func testIsShareURL() {
        XCTAssertTrue(CipherSharePayload.isShareURL("https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAA"))
        XCTAssertTrue(CipherSharePayload.isShareURL("runescribe://import?v=3&p=AAA"))
        XCTAssertFalse(CipherSharePayload.isShareURL("https://example.com/x"))
        XCTAssertFalse(CipherSharePayload.isShareURL("hello world"))
    }
}
