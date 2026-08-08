import Foundation
import XCTest
@testable import RuneScribeCoreModule

final class WireCompatibilityTests: XCTestCase {
    private static let cipherV3Base64 = "AwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8fHh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1ydW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhN"
    private static let messageV1Base64 = "AQEIQmFzZWxpbmUABQGqu8zdAwABAgMEBQYHEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8fHh0cGxoZGBcWFRQTEhEQDw4NDAsKCQgHBgUEAwIBAG5vdG8tc2Fucy1ydW5pYwAAAAABYVtsEWaoxRgW3BU2eErL9IZUfjvtA9v91wkQ4QBmeTsMHGhNp8lXWg=="

    func testCipherV3GoldenFixtureDecodesAndReencodesExactly() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.cipherV3Base64))
        XCTAssertEqual(bytes.count, 129)

        let payload = try CipherSharePayload(decoding: bytes)
        XCTAssertEqual(payload.publicID, Data((0...7).map(UInt8.init)))
        XCTAssertEqual(payload.keyMaterial, Data((0x10...0x2f).map(UInt8.init)))
        XCTAssertEqual(payload.decorativeMapping, Array((0..<32).reversed()))
        XCTAssertEqual(payload.fontRef, .bundled)
        XCTAssertEqual(try payload.encoded(), bytes)
    }

    func testMessageV1GoldenFixtureDecodesAndReencodesExactly() throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: Self.messageV1Base64))
        XCTAssertEqual(bytes.count, 151)

        let payload = try MessageSharePayload(decoding: bytes)
        XCTAssertEqual(payload.senderName, "Baseline")
        XCTAssertEqual(payload.envelope, Data([0x01, 0xaa, 0xbb, 0xcc, 0xdd]))
        XCTAssertEqual(try payload.embeddedCipher?.encoded(), try cipherV3Fixture())
        XCTAssertEqual(try payload.encoded(), bytes)
    }

    func testGoldenCipherParsesFromCustomAndLegacyLinks() throws {
        let token = base64URL(try cipherV3Fixture())
        let custom = try XCTUnwrap(
            URL(string: "runescribe://import?v=3&p=\(token)&n=Baseline%20Custom")
        )
        let legacy = try XCTUnwrap(
            URL(
                string: "https://www.ravenforgesoftware.com/rune-scribe/import"
                    + "?v=3&p=\(token)&n=Baseline%20Legacy"
            )
        )

        let customPayload = try CipherSharePayload(url: custom)
        let legacyPayload = try CipherSharePayload(url: legacy)
        XCTAssertEqual(customPayload.parsedName, "Baseline Custom")
        XCTAssertEqual(legacyPayload.parsedName, "Baseline Legacy")
        XCTAssertEqual(try customPayload.encoded(), try cipherV3Fixture())
        XCTAssertEqual(try legacyPayload.encoded(), try cipherV3Fixture())
    }

    func testGoldenFixturesRejectCorruptionTruncationAndOversize() throws {
        var cipher = try cipherV3Fixture()
        cipher[9] ^= 0x01
        XCTAssertThrowsError(try CipherSharePayload(decoding: cipher)) { error in
            XCTAssertEqual(error as? CipherShareError, .badChecksum)
        }
        XCTAssertThrowsError(
            try CipherSharePayload(decoding: Data(try cipherV3Fixture().dropLast()))
        ) { error in
            XCTAssertEqual(error as? CipherShareError, .wrongSize)
        }
        XCTAssertThrowsError(
            try CipherSharePayload(decoding: try cipherV3Fixture() + Data([0]))
        ) { error in
            XCTAssertEqual(error as? CipherShareError, .wrongSize)
        }

        var message = try messageV1Fixture()
        message[14] ^= 0x01
        XCTAssertThrowsError(try MessageSharePayload(decoding: message)) { error in
            XCTAssertEqual(error as? MessageShareError, .badChecksum)
        }
        XCTAssertThrowsError(
            try MessageSharePayload(decoding: Data(try messageV1Fixture().dropLast()))
        ) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
        XCTAssertThrowsError(
            try MessageSharePayload(decoding: try messageV1Fixture() + Data([0]))
        ) { error in
            XCTAssertEqual(error as? MessageShareError, .tooShort)
        }
    }

    private func cipherV3Fixture() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.cipherV3Base64))
    }

    private func messageV1Fixture() throws -> Data {
        try XCTUnwrap(Data(base64Encoded: Self.messageV1Base64))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
