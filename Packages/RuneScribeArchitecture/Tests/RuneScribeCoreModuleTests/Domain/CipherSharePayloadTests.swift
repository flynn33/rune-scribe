import XCTest
@testable import RuneScribeCoreModule

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
        var bytes = try CipherSharePayload(cipher: .generated(label: "x")).encoded()
        bytes[10] ^= 0x01
        XCTAssertThrowsError(try CipherSharePayload(decoding: bytes))
    }

    func testWrongVersionRejected() throws {
        var bytes = try CipherSharePayload(cipher: .generated(label: "x")).encoded()
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
    func testV3ByteCount() throws {
        XCTAssertEqual(try CipherSharePayload(cipher: .generated(label: "x")).encoded().count, 129)
        XCTAssertEqual(CipherSharePayload.byteCount, 129)
    }
}

extension CipherSharePayloadTests {
    func testFileFormRoundTripsPayloadAndFontBytes() throws {
        let c = Cipher.generated(label: "Bob")
        let font = Data("synthetic-font-fixture".utf8)
        let file = try CipherSharePayload(cipher: c).encodedFile(fontBytes: font)
        let (payload, bytes) = try CipherSharePayload.decodeFile(file)
        XCTAssertEqual(payload.keyMaterial, c.keyMaterial)
        XCTAssertEqual(bytes, font)
    }
    func testFileFormWithoutFontIsCompactOnly() throws {
        let c = Cipher.generated(label: "C")
        let (payload, bytes) = try CipherSharePayload.decodeFile(
            CipherSharePayload(cipher: c).encoded()
        )
        XCTAssertEqual(payload.publicID, c.publicID)
        XCTAssertNil(bytes)
    }
    func testShareURLUsesProductPageUniversalLink() throws {
        let c = Cipher.generated(label: "Dee")
        let url = try CipherSharePayload(cipher: c).url(name: "Dee")
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "ravenforgesoftware.com")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.path,
            "/rune-scribe/"
        )
        XCTAssertTrue(url.query?.contains("runescribe=import") == true)
        let parsed = try CipherSharePayload(url: url)
        XCTAssertEqual(parsed.keyMaterial, c.keyMaterial)
        XCTAssertEqual(parsed.parsedName, "Dee")
    }

    func testLegacyHTTPSURLStillParses() throws {
        let c = Cipher.generated(label: "Dee")
        let p = try CipherSharePayload(cipher: c).encoded()
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let https = URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=\(p)&n=Dee")!
        let parsed = try CipherSharePayload(url: https)
        XCTAssertEqual(parsed.keyMaterial, c.keyMaterial)
        XCTAssertEqual(parsed.parsedName, "Dee")
    }
    func testLegacyCustomSchemeStillParses() throws {
        let c = Cipher.generated(label: "E")
        let p = try CipherSharePayload(cipher: c).encoded()
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let legacy = URL(string: "runescribe://import?v=3&p=\(p)")!
        XCTAssertEqual(try CipherSharePayload(url: legacy).keyMaterial, c.keyMaterial)
    }
    func testIsShareURL() {
        XCTAssertTrue(CipherSharePayload.isShareURL("https://ravenforgesoftware.com/rune-scribe/?runescribe=import&v=3&p=AAA"))
        XCTAssertTrue(CipherSharePayload.isShareURL("https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAA"))
        XCTAssertTrue(CipherSharePayload.isShareURL("runescribe://import?v=3&p=AAA"))
        XCTAssertFalse(CipherSharePayload.isShareURL("https://example.com/x"))
        XCTAssertFalse(CipherSharePayload.isShareURL("hello world"))
    }

    func testEncodingRejectsInvalidKeyBearingShapes() {
        let invalidPublicID = CipherSharePayload(
            publicID: Data(repeating: 0, count: 7),
            keyMaterial: Data(repeating: 1, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: .bundled
        )
        XCTAssertThrowsError(try invalidPublicID.encoded()) { error in
            XCTAssertEqual(error as? CipherShareError, .invalidPublicIDLength)
        }

        let invalidKey = CipherSharePayload(
            publicID: Data(repeating: 0, count: 8),
            keyMaterial: Data(repeating: 1, count: 31),
            decorativeMapping: Array(0..<32),
            fontRef: .bundled
        )
        XCTAssertThrowsError(try invalidKey.encoded()) { error in
            XCTAssertEqual(error as? CipherShareError, .invalidKeyMaterialLength)
        }

        let invalidMapping = CipherSharePayload(
            publicID: Data(repeating: 0, count: 8),
            keyMaterial: Data(repeating: 1, count: 32),
            decorativeMapping: Array(repeating: 0, count: 32),
            fontRef: .bundled
        )
        XCTAssertThrowsError(try invalidMapping.encoded()) { error in
            XCTAssertEqual(error as? CipherShareError, .notAMapping)
        }

        let invalidFont = CipherSharePayload(
            publicID: Data(repeating: 0, count: 8),
            keyMaterial: Data(repeating: 1, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: FontRef(id: "", version: 1, sha256: Data(repeating: 0, count: 32))
        )
        XCTAssertThrowsError(try invalidFont.encoded()) { error in
            XCTAssertEqual(error as? CipherShareError, .invalidFontReference)
        }

        let invalidFontVersion = CipherSharePayload(
            publicID: Data(repeating: 0, count: 8),
            keyMaterial: Data(repeating: 1, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: FontRef(
                id: "fixture-font",
                version: 0,
                sha256: Data(repeating: 0, count: 32)
            )
        )
        XCTAssertThrowsError(try invalidFontVersion.encoded()) { error in
            XCTAssertEqual(error as? CipherShareError, .invalidFontReference)
        }
    }
}
