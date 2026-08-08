import XCTest
@testable import RuneScribeCoreModule

final class MessageCryptorTests: XCTestCase {
    private let cryptor = MessageCryptor()

    func testRoundTrip() throws {
        let c = Cipher.generated(label: "x")
        let sealed = try cryptor.seal("Hello, runes! 🜨\nLine2", with: c)
        XCTAssertEqual(try cryptor.open(sealed, with: c), "Hello, runes! 🜨\nLine2")
    }
    func testWrongCipherFails() throws {
        let sealed = try cryptor.seal("secret", with: Cipher.generated(label: "a"))
        XCTAssertThrowsError(try cryptor.open(sealed, with: Cipher.generated(label: "b")))
    }
    func testTamperFails() throws {
        let c = Cipher.generated(label: "x")
        var sealed = try cryptor.seal("secret", with: c)
        sealed[sealed.count - 1] ^= 0x01
        XCTAssertThrowsError(try cryptor.open(sealed, with: c))
    }
    func testTwoSealsDifferentCiphertext() throws {
        let c = Cipher.generated(label: "x")
        XCTAssertNotEqual(try cryptor.seal("same", with: c), try cryptor.seal("same", with: c),
                          "fresh nonce each time")
    }
}
