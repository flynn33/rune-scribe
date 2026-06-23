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
