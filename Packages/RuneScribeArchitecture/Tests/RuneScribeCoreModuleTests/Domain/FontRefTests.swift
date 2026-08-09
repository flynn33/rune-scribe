import XCTest
@testable import RuneScribeCoreModule

final class FontRefTests: XCTestCase {
    func testBundledRefShape() {
        let r = FontRef.bundled
        XCTAssertEqual(r.id, "noto-sans-runic")
        XCTAssertEqual(r.version, 1)
        XCTAssertEqual(r.sha256.count, 32)
    }

    func testBundledRefUsesFixedShippingDigest() {
        let expected = Data([
            0x61, 0x5b, 0x6c, 0x11, 0x66, 0xa8, 0xc5, 0x18,
            0x16, 0xdc, 0x15, 0x36, 0x78, 0x4a, 0xcb, 0xf4,
            0x86, 0x54, 0x7e, 0x3b, 0xed, 0x03, 0xdb, 0xfd,
            0xd7, 0x09, 0x10, 0xe1, 0x00, 0x66, 0x79, 0x3b,
        ])
        XCTAssertEqual(FontRef.bundled.sha256, expected)
    }

    func testCodableRoundTrip() throws {
        let r = FontRef.bundled
        XCTAssertEqual(try JSONDecoder().decode(FontRef.self, from: JSONEncoder().encode(r)), r)
    }
}
