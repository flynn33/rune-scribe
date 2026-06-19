// RuneScribTests/DecoderImportTests.swift

import XCTest
@testable import RuneScrib

final class DecoderImportTests: XCTestCase {

    private func makeKey() -> RuneKey {
        RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
    }

    /// The single exported decoder file parses back to the same mapping.
    func testExportDataParsesBackToSameMapping() throws {
        let key = makeKey()
        let data = try JSONEncoder().encode(RuneKeyExport.from(key))

        let decoder = try ImportedDecoder.parse(data)
        XCTAssertEqual(decoder.keyId, key.keyId)
        XCTAssertEqual(decoder.mapping, key.mapping)
        XCTAssertEqual(decoder.reverseMapping, key.reverseMapping)
    }

    /// A message encoded with a key decodes correctly through an imported decoder
    /// built from that key's exported file (the core import-and-decode path).
    func testImportedDecoderDecodesEncodedMessage() throws {
        let key = makeKey()
        let message = "Meet at dawn, pier 9! Bring the map & 2 horses."
        let runes = CipherEngine(key: key).encode(message)

        let data = try JSONEncoder().encode(RuneKeyExport.from(key))
        let decoder = try ImportedDecoder.parse(data)
        let decoded = CipherEngine(decoder: decoder).decode(runes)

        XCTAssertEqual(decoded, message)
    }

    /// Decoding with the wrong imported decoder does not reproduce the message.
    func testWrongDecoderDoesNotRecoverMessage() throws {
        let sender = makeKey()
        let stranger = makeKey()
        let message = "The longhouse, midnight."
        let runes = CipherEngine(key: sender).encode(message)

        let strangerData = try JSONEncoder().encode(RuneKeyExport.from(stranger))
        let decoder = try ImportedDecoder.parse(strangerData)
        let decoded = CipherEngine(decoder: decoder).decode(runes)

        XCTAssertNotEqual(decoded, message)
    }

    /// Non-RuneScrib JSON is rejected.
    func testParseRejectsForeignJSON() {
        let data = Data(#"{"foo":"bar"}"#.utf8)
        XCTAssertThrowsError(try ImportedDecoder.parse(data))
    }

    /// A file whose reverse map isn't the inverse of the forward map is rejected.
    func testParseRejectsInconsistentMapping() throws {
        let key = makeKey()
        let data = try JSONEncoder().encode(RuneKeyExport.from(key))
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var reverse = object["reverseMapping"] as! [String: String]
        if let firstRune = reverse.keys.sorted().first { reverse[firstRune] = "##" }
        object["reverseMapping"] = reverse
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try ImportedDecoder.parse(tampered))
    }
}
