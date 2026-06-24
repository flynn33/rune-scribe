import XCTest
import CryptoKit
@testable import RuneScrib

final class FontRefTests: XCTestCase {
    func testBundledRefShape() {
        let r = FontRef.bundled
        XCTAssertEqual(r.id, "noto-sans-runic")
        XCTAssertEqual(r.version, 1)
        XCTAssertEqual(r.sha256.count, 32)
    }

    func testBundledRefHashMatchesTheBundledFontFile() throws {
        let url = try XCTUnwrap(Bundle(for: FontRefTests.self).url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
            ?? Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf"))
        let expected = Data(SHA256.hash(data: try Data(contentsOf: url)))
        XCTAssertEqual(FontRef.bundled.sha256, expected)
    }

    func testCodableRoundTrip() throws {
        let r = FontRef.bundled
        XCTAssertEqual(try JSONDecoder().decode(FontRef.self, from: JSONEncoder().encode(r)), r)
    }
}
