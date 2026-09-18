import Foundation
@testable import RuneScribeCoreModule
import XCTest

final class InboundRoutingTests: XCTestCase {
    func testFileRouterStrictlyDecodesCompleteCipherAndMessageFiles() throws {
        let cipher = Cipher.generated(label: "Fixture")
        let cipherBytes = try CipherSharePayload(cipher: cipher).encodedFile(
            fontBytes: Data("font".utf8)
        )
        guard case .cipher(let cipherPayload, let cipherFont) = try FileRouter.decode(cipherBytes)
        else { return XCTFail("Expected cipher file") }
        XCTAssertEqual(cipherPayload.keyMaterial, cipher.keyMaterial)
        XCTAssertEqual(cipherFont, Data("font".utf8))

        let sealed = try MessageCryptor().seal("hello", with: cipher)
        let message = MessageSharePayload(
            senderName: "Fixture",
            envelope: MessageEnvelope.wrap(sealed),
            embeddedCipher: CipherSharePayload(cipher: cipher)
        )
        let messageBytes = try message.encodedFile(fontBytes: Data("font".utf8))
        guard case .message(let messagePayload, let messageFont) = try FileRouter.decode(messageBytes)
        else { return XCTFail("Expected message file") }
        XCTAssertEqual(messagePayload.senderName, "Fixture")
        XCTAssertEqual(messageFont, Data("font".utf8))
    }

    func testFileRouterRejectsUnknownTruncatedAndCorruptFiles() throws {
        XCTAssertThrowsError(try FileRouter.decode(Data())) { error in
            XCTAssertEqual(error as? FileRouterError, .empty)
        }
        XCTAssertThrowsError(try FileRouter.decode(Data([0x7f]))) { error in
            XCTAssertEqual(error as? FileRouterError, .unsupportedVersion(0x7f))
        }
        XCTAssertThrowsError(
            try FileRouter.decode(Data([UInt8(3), 0, 1]))
        ) { error in
            XCTAssertEqual(error as? FileRouterError, .malformedCipher)
        }

        var message = try MessageSharePayload(
            senderName: "Sender",
            envelope: Data([1, 2, 3]),
            embeddedCipher: nil
        ).encoded()
        message[message.index(before: message.endIndex)] ^= 1
        XCTAssertThrowsError(try FileRouter.decode(message)) { error in
            XCTAssertEqual(error as? FileRouterError, .malformedMessage)
        }
    }

    func testLinkRouterAcceptsCompatibleCustomAndLegacyLinks() throws {
        let cipher = Cipher.generated(label: "Fixture")
        let custom = try CipherSharePayload(cipher: cipher).url(name: "Fixture")
        XCTAssertEqual(try LinkRouter.decodeCipher(custom).keyMaterial, cipher.keyMaterial)
        XCTAssertEqual(
            URLComponents(url: custom, resolvingAgainstBaseURL: false)?.path,
            "/rune-scribe/"
        )

        let token = try CipherSharePayload(cipher: cipher).encoded()
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let legacy = try XCTUnwrap(
            URL(string: "https://www.ravenforgesoftware.com/rune-scribe/import?v=3&p=\(token)&n=Fixture")
        )
        XCTAssertEqual(try LinkRouter.decodeCipher(legacy).keyMaterial, cipher.keyMaterial)

        let missingMarker = try XCTUnwrap(
            URL(string: "https://ravenforgesoftware.com/rune-scribe/?v=3&p=\(token)")
        )
        XCTAssertThrowsError(try LinkRouter.decodeCipher(missingMarker)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidQuery)
        }
    }

    func testLinkRouterRejectsAmbiguousRoutesQueriesAndBounds() throws {
        let cipher = Cipher.generated(label: "Fixture")
        let token = try CipherSharePayload(cipher: cipher).encoded()
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let suffix = try XCTUnwrap(
            URL(string: "https://ravenforgesoftware.com/rune-scribe/import/extra?v=3&p=\(token)")
        )
        XCTAssertThrowsError(try LinkRouter.decodeCipher(suffix)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidRoute)
        }

        let duplicate = try XCTUnwrap(
            URL(string: "runescribe://import?v=3&p=\(token)&p=\(token)")
        )
        XCTAssertThrowsError(try LinkRouter.decodeCipher(duplicate)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidQuery)
        }

        let longName = String(repeating: "a", count: LinkRouter.maximumNameByteCount + 1)
        let named = try XCTUnwrap(
            URL(string: "runescribe://import?v=3&p=\(token)&n=\(longName)")
        )
        XCTAssertThrowsError(try LinkRouter.decodeCipher(named)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidQuery)
        }

        let oversized = try XCTUnwrap(
            URL(string: "runescribe://import?v=3&p=\(token)&n="
                + String(repeating: "a", count: LinkRouter.maximumURLByteCount))
        )
        XCTAssertThrowsError(try LinkRouter.decodeCipher(oversized)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidQuery)
        }

        let unrelated = try XCTUnwrap(URL(string: "https://example.com/hello"))
        XCTAssertThrowsError(try LinkRouter.decodeCipher(unrelated)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidRoute)
        }

        let legacyMessage = try XCTUnwrap(
            URL(string: "https://example.com/rune-scribe/m?v=1&p=AAAA")
        )
        XCTAssertThrowsError(try LinkRouter.decodeCipher(legacyMessage)) { error in
            XCTAssertEqual(error as? LinkRouterError, .invalidRoute)
        }
    }

}
