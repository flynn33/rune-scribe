import XCTest
import CryptoKit
@testable import RuneScrib

final class CipherTests: XCTestCase {
    func testGeneratedCipherHasValidShape() {
        let c = Cipher.generated(label: "Alice")
        XCTAssertEqual(c.label, "Alice")
        XCTAssertEqual(c.origin, .generated)
        XCTAssertEqual(c.keyMaterial.count, 32)        // AES-256
        XCTAssertEqual(c.publicID.count, 8)
        XCTAssertEqual(c.decorativeMapping.count, 32)
        XCTAssertEqual(Set(c.decorativeMapping), Set(0..<32), "mapping must be a permutation of 0..<32")
    }
    func testTwoGeneratedCiphersDiffer() {
        XCTAssertNotEqual(Cipher.generated(label: "A").keyMaterial,
                          Cipher.generated(label: "B").keyMaterial)
    }
    func testCodableRoundTrip() throws {
        let c = Cipher.generated(label: "Bob")
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Cipher.self, from: data)
        XCTAssertEqual(c, back)
    }
    func testSymmetricKeyMatchesKeyMaterial() {
        let c = Cipher.generated(label: "K")
        let raw = c.symmetricKey.withUnsafeBytes { Data($0) }
        XCTAssertEqual(raw, c.keyMaterial)
    }
}

extension CipherTests {
    func testGeneratedCipherUsesBundledFont() {
        XCTAssertEqual(Cipher.generated(label: "x").fontRef, .bundled)
    }
    func testDecodingALegacyCipherWithoutFontRefDefaultsToBundled() throws {
        // Simulate a Phase-1 stored cipher: a JSON object with no fontRef key.
        let json = """
        {"id":"\(UUID().uuidString)","label":"old","origin":"generated","createdAt":0,
         "formatVersion":1,"publicID":"AAAAAAAAAAA=","keyMaterial":"\(Data(repeating:1,count:32).base64EncodedString())",
         "decorativeMapping":[\((0..<32).map(String.init).joined(separator: ","))]}
        """
        let c = try JSONDecoder().decode(Cipher.self, from: Data(json.utf8))
        XCTAssertEqual(c.fontRef, .bundled)
    }
}
