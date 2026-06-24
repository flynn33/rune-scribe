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
