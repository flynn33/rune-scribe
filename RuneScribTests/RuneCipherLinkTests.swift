// RuneScribTests/RuneCipherLinkTests.swift

import XCTest
@testable import RuneScrib

/// Exercises the compact share/QR/deep-link wire format end to end: encode a key
/// to a `runescribe://import` URL, parse it back, and prove it funnels through the
/// existing `RuneKeyExport`/`ImportedDecoder` import path. Mirrors the
/// `DecoderImportTests` / `FriendDecodeRoundTripTests` style.
final class RuneCipherLinkTests: XCTestCase {

    private func makeKey() -> RuneKey {
        RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
    }

    // MARK: - Round trips

    /// A key → URL → permutation → mapping reproduces the original forward mapping,
    /// across many random keys.
    func testPayloadRoundTripPreservesMapping() throws {
        for _ in 0..<50 {
            let key = makeKey()
            let url = try RuneCipherLink.encodeURL(for: key, name: nil)
            let (perm, _) = try RuneCipherLink.decodeURL(url)
            XCTAssertEqual(RuneCipherLink.mapping(forPermutation: perm), key.mapping)
        }
    }

    /// The display name survives encoding, including spaces and URL-significant
    /// characters; an absent name decodes to nil.
    func testNameRoundTrip() throws {
        let key = makeKey()
        let tricky = "a/b c#d\"e'f&g=h?i 🔑 café"
        let (_, name) = try RuneCipherLink.decodeURL(try RuneCipherLink.encodeURL(for: key, name: tricky))
        XCTAssertEqual(name, tricky)

        let (_, none) = try RuneCipherLink.decodeURL(try RuneCipherLink.encodeURL(for: key, name: nil))
        XCTAssertNil(none)

        let (_, blank) = try RuneCipherLink.decodeURL(try RuneCipherLink.encodeURL(for: key, name: "   "))
        XCTAssertNil(blank, "whitespace-only names should decode to nil")
    }

    // MARK: - base64url

    /// The payload uses the URL-safe alphabet with no padding.
    func testBase64urlAlphabetNoPadding() throws {
        let url = try RuneCipherLink.encodeURL(for: makeKey(), name: nil)
        let payload = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "p" }?.value)
        XCTAssertFalse(payload.contains("="))
        XCTAssertFalse(payload.contains("+"))
        XCTAssertFalse(payload.contains("/"))
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        XCTAssertNil(payload.rangeOfCharacter(from: allowed.inverted))
    }

    /// Every byte value round-trips through the base64url helpers.
    func testBase64urlAllByteValues() throws {
        let bytes = (0...255).map { UInt8($0) }
        XCTAssertEqual(try RuneCipherLink.bytesFromBase64url(RuneCipherLink.base64url(bytes)), bytes)
    }

    // MARK: - Bridge to the existing import path

    /// A URL's permutation converts to `RuneKeyExport` JSON that the existing
    /// importer accepts and validates.
    func testExportJSONDataImportsCleanly() throws {
        let url = try RuneCipherLink.encodeURL(for: makeKey(), name: "Shared")
        let (perm, _) = try RuneCipherLink.decodeURL(url)
        let json = try RuneCipherLink.exportJSONData(forPermutation: perm)
        let decoder = try ImportedDecoder.parse(json)   // throws if invalid/inconsistent
        XCTAssertEqual(decoder.mapping.count, 89)
        XCTAssertEqual(decoder.reverseMapping.count, 89)
    }

    /// Full friend flow over the wire: Alice encodes, shares a link; Bob parses it,
    /// imports through the standard path, and decodes the original message.
    func testFriendLinkRoundTripDecodesMessage() throws {
        let alice = makeKey()
        let message = "Meet at dawn, pier 9! Bring the map & 2 horses. café ☕\nSecond line."
        let runes = CipherEngine(key: alice).encode(message)

        let link = try RuneCipherLink.encodeURL(for: alice, name: "Alice")
        let (perm, name) = try RuneCipherLink.decodeURL(link)
        XCTAssertEqual(name, "Alice")

        let json = try RuneCipherLink.exportJSONData(forPermutation: perm)
        let decoder = try ImportedDecoder.parse(json)
        XCTAssertEqual(CipherEngine(decoder: decoder).decode(runes), message)
    }

    // MARK: - Rejections

    func testRejectsShortPayload() {
        XCTAssertThrowsError(try RuneCipherLink.decodePayload("AAAA"))   // 3 bytes
    }

    func testRejectsNonPermutation() {
        let zeros = RuneCipherLink.base64url([UInt8](repeating: 0, count: 89))
        XCTAssertThrowsError(try RuneCipherLink.decodePayload(zeros))
    }

    func testRejectsBadBase64() {
        XCTAssertThrowsError(try RuneCipherLink.bytesFromBase64url("@@@ not base64 @@@"))
    }

    func testRejectsWrongScheme() throws {
        let payload = try payloadString()
        XCTAssertThrowsError(try RuneCipherLink.decodeURL(
            XCTUnwrap(URL(string: "https://example.com/import?v=1&p=\(payload)"))))
    }

    func testRejectsWrongHost() throws {
        let payload = try payloadString()
        XCTAssertThrowsError(try RuneCipherLink.decodeURL(
            XCTUnwrap(URL(string: "runescribe://export?v=1&p=\(payload)"))))
    }

    func testRejectsUnsupportedVersion() throws {
        let payload = try payloadString()
        XCTAssertThrowsError(try RuneCipherLink.decodeURL(
            XCTUnwrap(URL(string: "runescribe://import?v=2&p=\(payload)"))))
    }

    func testRejectsMissingPayload() throws {
        XCTAssertThrowsError(try RuneCipherLink.decodeURL(
            XCTUnwrap(URL(string: "runescribe://import?v=1"))))
    }

    func testAcceptsValidURL() throws {
        let payload = try payloadString()
        XCTAssertNoThrow(try RuneCipherLink.decodeURL(
            XCTUnwrap(URL(string: "runescribe://import?v=1&p=\(payload)"))))
    }

    // MARK: - Helpers

    /// A valid base64url payload string from a fresh random key.
    private func payloadString() throws -> String {
        let url = try RuneCipherLink.encodeURL(for: makeKey(), name: nil)
        return try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "p" }?.value)
    }
}
