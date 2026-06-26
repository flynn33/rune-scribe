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

extension MessageServiceTests {
    /// Builds the on-the-wire envelope (version byte ‖ AES-GCM sealed box) for `cipher`,
    /// the same bytes a `MessageSharePayload.envelope` carries.
    private func envelope(_ plaintext: String, with cipher: Cipher) throws -> Data {
        let sealed = try MessageCryptor().seal(plaintext, with: cipher)
        return MessageEnvelope.wrap(sealed)
    }

    func testReadEnvelopeRecoversUnderCorrectCipherAmongCandidates() throws {
        let a = Cipher.generated(label: "a")
        let b = Cipher.generated(label: "b")
        let env = try envelope("rendezvous at dusk", with: a)
        // Wrong cipher first, correct one second: only A's key authenticates.
        let result = try svc.read(envelope: env, tryingCiphers: [b, a])
        XCTAssertEqual(result.plaintext, "rendezvous at dusk")
        XCTAssertEqual(result.cipher, a)
    }

    func testReadEnvelopeThrowsWhenNoCipherMatches() throws {
        let env = try envelope("nope", with: Cipher.generated(label: "a"))
        XCTAssertThrowsError(try svc.read(envelope: env, tryingCiphers: [Cipher.generated(label: "b")])) { error in
            XCTAssertEqual(error as? MessageError, .noMatchingCipher)
        }
    }

    func testReadEnvelopeRejectsTamperedBytesNoFalsePositive() throws {
        let a = Cipher.generated(label: "a")
        var env = try envelope("authentic", with: a)
        // Flip a byte inside the sealed box (skip the version byte at index 0) so the
        // GCM tag no longer verifies — the correct cipher must still refuse to open it.
        env[env.count - 1] ^= 0xFF
        XCTAssertThrowsError(try svc.read(envelope: env, tryingCiphers: [a])) { error in
            XCTAssertEqual(error as? MessageError, .noMatchingCipher)
        }
    }
}
