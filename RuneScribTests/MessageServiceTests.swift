import XCTest
@testable import RuneScrib

final class MessageServiceTests: XCTestCase {
    private let svc = MessageService()

    func testComposeProducesRunesThatReadBack() throws {
        let c = Cipher.generated(label: "x")
        let runes = try svc.compose("meet at dawn", with: c)
        XCTAssertTrue(runes.allSatisfy { Set(RuneCharacterSet.decorativeAlphabet).contains($0) })
        let result = try svc.read(runes, tryingCiphers: [c])
        XCTAssertEqual(result.plaintext, "meet at dawn")
        XCTAssertEqual(result.cipher, c)
    }
    func testReadPicksCorrectCipherAmongMany() throws {
        let target = Cipher.generated(label: "target")
        let others = (0..<5).map { Cipher.generated(label: "other\($0)") }
        let runes = try svc.compose("hidden", with: target)
        let result = try svc.read(runes, tryingCiphers: others + [target])
        XCTAssertEqual(result.plaintext, "hidden")
        XCTAssertEqual(result.cipher, target)
    }
    func testReadFailsWhenNoCipherMatches() throws {
        let runes = try svc.compose("nope", with: Cipher.generated(label: "a"))
        XCTAssertThrowsError(try svc.read(runes, tryingCiphers: [Cipher.generated(label: "b")]))
    }
    func testReadToleratesSurroundingWhitespace() throws {
        let c = Cipher.generated(label: "x")
        let runes = try svc.compose("hi there", with: c)
        let messy = "\n  \(runes)\n"   // as if pasted from a chat app
        XCTAssertEqual(try svc.read(messy, tryingCiphers: [c]).plaintext, "hi there")
    }
}
