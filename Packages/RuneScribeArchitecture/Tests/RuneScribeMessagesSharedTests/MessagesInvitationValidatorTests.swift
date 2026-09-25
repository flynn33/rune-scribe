import CryptoKit
import Foundation
import XCTest
@testable import RuneScribeMessagesShared

final class MessagesInvitationValidatorTests: XCTestCase {
    func testAcceptsExactV3HTTPSInvitationAndProducesStableHandoffID() throws {
        let URL = try fixtureURL(name: "Freyja")

        let first = try MessagesInvitationValidator.validate(URL)
        let second = try MessagesInvitationValidator.validate(URL)

        XCTAssertEqual(first.URL, URL)
        XCTAssertEqual(first.handoffID, second.handoffID)
        XCTAssertEqual(first.handoffID.count, 64)
    }

    func testRejectsWWWCustomSchemeCredentialsPortFragmentAndLegacyPath() throws {
        let valid = try fixtureURL()
        let payload = try XCTUnwrap(
            URLComponents(url: valid, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "p" })?.value
        )
        let invalid = [
            "https://www.ravenforgesoftware.com/rune-scribe/?runescribe=import&v=3&p=\(payload)",
            "runescribe://import?v=3&p=\(payload)",
            "https://user@ravenforgesoftware.com/rune-scribe/?runescribe=import&v=3&p=\(payload)",
            "https://ravenforgesoftware.com:443/rune-scribe/?runescribe=import&v=3&p=\(payload)",
            "https://ravenforgesoftware.com/rune-scribe/?runescribe=import&v=3&p=\(payload)#fragment",
            "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=\(payload)",
        ]

        for string in invalid {
            XCTAssertThrowsError(
                try MessagesInvitationValidator.validate(XCTUnwrap(URL(string: string))),
                string
            )
        }
    }

    func testRejectsDuplicateUnexpectedAndMalformedQueryItems() throws {
        let valid = try fixtureURL()
        let base = valid.absoluteString
        for string in [
            base + "&v=3",
            base + "&runescribe=import",
            base + "&extra=value",
            base.replacingOccurrences(of: "v=3", with: "v=2"),
            base.replacingOccurrences(of: "runescribe=import", with: "runescribe=open"),
        ] {
            XCTAssertThrowsError(
                try MessagesInvitationValidator.validate(XCTUnwrap(URL(string: string))),
                string
            )
        }
    }

    func testRejectsBadChecksumAndInvalidMapping() throws {
        var badChecksum = fixturePayload()
        badChecksum[10] ^= 0xff
        XCTAssertThrowsError(
            try MessagesInvitationValidator.validate(try fixtureURL(payload: badChecksum))
        )

        var badMapping = fixturePayload()
        badMapping[1 + 8 + 32] = 1
        let body = badMapping.dropLast(4)
        badMapping.replaceSubrange(
            (badMapping.count - 4)..<badMapping.count,
            with: Data(SHA256.hash(data: body).prefix(4))
        )
        XCTAssertThrowsError(
            try MessagesInvitationValidator.validate(try fixtureURL(payload: badMapping))
        )
    }
}

func fixtureURL(name: String? = nil, payload: Data = fixturePayload()) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "ravenforgesoftware.com"
    components.path = "/rune-scribe/"
    components.queryItems = [
        URLQueryItem(name: "runescribe", value: "import"),
        URLQueryItem(name: "v", value: "3"),
        URLQueryItem(name: "p", value: base64URL(payload)),
    ]
    if let name {
        components.queryItems?.append(URLQueryItem(name: "n", value: name))
    }
    return try XCTUnwrap(components.url)
}

func fixturePayload() -> Data {
    var body = Data([3])
    body.append(Data(repeating: 0x11, count: 8))
    body.append(Data(repeating: 0x22, count: 32))
    body.append(Data(0..<32))
    var fontID = Data("noto-sans-runic".utf8)
    fontID.append(0)
    body.append(fontID)
    body.append(contentsOf: [0, 0, 0, 1])
    body.append(Data(repeating: 0x33, count: 32))
    body.append(Data(SHA256.hash(data: body).prefix(4)))
    return body
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
