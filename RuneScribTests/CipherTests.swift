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

extension CipherTests {
    func testNewCipherHasNoContact() { XCTAssertNil(Cipher.generated(label: "x").contactID) }
    func testLegacyCipherWithoutContactIDDecodesNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","label":"old","origin":"generated","createdAt":0,
         "formatVersion":1,"publicID":"AAAAAAAAAAA=","keyMaterial":"\(Data(repeating:1,count:32).base64EncodedString())",
         "decorativeMapping":[\((0..<32).map(String.init).joined(separator: ","))]}
        """
        XCTAssertNil(try JSONDecoder().decode(Cipher.self, from: Data(json.utf8)).contactID)
    }
}

extension CipherTests {
    func testNewCipherIsNotDelivered() {
        XCTAssertFalse(Cipher.generated(label: "x").delivered)
    }

    func testDeliveredSurvivesCodableRoundTrip() throws {
        var c = Cipher.generated(label: "Bob")
        c.delivered = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Cipher.self, from: data)
        XCTAssertTrue(back.delivered)
        XCTAssertEqual(c, back)
    }

    func testLegacyCipherWithoutDeliveredDecodesFalse() throws {
        // Simulate a Phase-1/2/3 stored cipher: JSON object with no `delivered` key.
        let json = """
        {"id":"\(UUID().uuidString)","label":"old","origin":"generated","createdAt":0,
         "formatVersion":1,"publicID":"AAAAAAAAAAA=","keyMaterial":"\(Data(repeating:1,count:32).base64EncodedString())",
         "decorativeMapping":[\((0..<32).map(String.init).joined(separator: ","))]}
        """
        XCTAssertFalse(try JSONDecoder().decode(Cipher.self, from: Data(json.utf8)).delivered)
    }
}
