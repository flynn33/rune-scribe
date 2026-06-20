// RuneScribTests/FriendDecodeRoundTripTests.swift

import XCTest
@testable import RuneScrib

/// End-to-end tests for the real-world scenario that matters most before release:
/// one person encodes a message and shares their decoder file; a *different*
/// person, on a *different* install with no shared keys, imports that file and
/// decodes the message back to the exact original.
///
/// Every step goes through the same code the app uses:
///   • encode  — `CipherEngine(key:).encode(_:)`           (ContentView)
///   • export  — `JSONEncoder([.prettyPrinted, .sortedKeys]).encode(RuneKeyExport.from(_:))`  (KeyManager.exportData)
///   • import  — `ImportedDecoder.parse(_:)` → `RuneKey(keyId:createdAt:mapping:)`             (KeyManager.importCipher)
///   • decode  — `CipherEngine(key:).decode(_:)`            (ContentView)
///
/// The exported decoder is plain JSON of the mapping — it is NOT tied to the
/// sender's device keychain or AES key — which is why it works across installs.
final class FriendDecodeRoundTripTests: XCTestCase {

    // MARK: - The exact app paths, as two separate "devices"

    /// Sender side: make a fresh cipher and produce (runes, decoder-file-bytes)
    /// exactly as the app would when you encode and then export the decoder.
    private func senderEncodesAndExports(_ message: String) throws -> (runes: String, decoderFile: Data) {
        let senderKey = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let runes = CipherEngine(key: senderKey).encode(message)

        // Identical to KeyManager.exportData(for:)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoderFile = try encoder.encode(RuneKeyExport.from(senderKey))

        return (runes, decoderFile)
    }

    /// Recipient side: import the decoder file (no access to the sender's device)
    /// and decode the runes — exactly as KeyManager.importCipher + ContentView do.
    private func recipientImportsAndDecodes(runes: String, decoderFile: Data) throws -> String {
        let imported = try ImportedDecoder.parse(decoderFile)
        let recipientKey = RuneKey(keyId: imported.keyId,
                                   createdAt: imported.createdAt,
                                   mapping: imported.mapping)
        return CipherEngine(key: recipientKey).decode(runes)
    }

    /// Full Alice → file → Bob round trip for one message.
    private func assertFriendRecovers(_ message: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) throws {
        let sent = try senderEncodesAndExports(message)
        let recovered = try recipientImportsAndDecodes(runes: sent.runes, decoderFile: sent.decoderFile)
        XCTAssertEqual(recovered, message,
                       "the recipient must recover the exact original message",
                       file: file, line: line)
    }

    // MARK: - Realistic messages

    func testTypicalMessages() throws {
        let messages = [
            "Meet me at the old oak at midnight.",
            "The password is Mjolnir7!",
            "Bring 3 horses and 250 gold coins.",
            "Are we still on for dinner tonight?",
            "I left the key under the second stone by the door.",
            "Happy birthday, my friend — see you Saturday at 8.",
            "Coordinates: 59.9139 N, 10.7522 E",
            "Don't trust Bjorn. He talked to the guards.",
        ]
        for message in messages {
            try assertFriendRecovers(message)
        }
    }

    // MARK: - Edge cases that appear in real messages

    func testMultiLineMessage() throws {
        try assertFriendRecovers("""
        Line one of the plan.
        Line two with details.

        Final line after a blank line.
        """)
    }

    func testEmojiAndSymbolsPassThrough() throws {
        // Emoji and characters outside the 89-char set are not encoded; they must
        // survive the round trip unchanged.
        try assertFriendRecovers("See you at 8pm 🍺🔥 — bring the map 🗺️")
        try assertFriendRecovers("Café, naïve, résumé, jalapeño, Zürich")
        try assertFriendRecovers("Привет / 你好 / こんにちは")
    }

    func testPunctuationHeavy() throws {
        try assertFriendRecovers("Hello, World! (test) [123] {abc} #$%&*+=< ... \"quoted\" 'single'")
    }

    func testAllNumbersAndMixedCase() throws {
        try assertFriendRecovers("AaBbCcZz 0123456789 MixEd CaSe 9876543210")
    }

    func testSingleCharacterAndWhitespace() throws {
        try assertFriendRecovers("A")
        try assertFriendRecovers(" ")
        try assertFriendRecovers("   spaced   out   ")
        try assertFriendRecovers("\n\n")
    }

    func testEmptyMessage() throws {
        try assertFriendRecovers("")
    }

    func testEveryEncodableCharacter() throws {
        // The full 89-character input set in one message — proves every mapped
        // character encodes and decodes correctly across devices.
        try assertFriendRecovers(RuneCharacterSet.inputCharacters.joined())
    }

    func testLongMessage() throws {
        let paragraph = String(
            repeating: "The quick brown fox jumps over the lazy dog 1234567890. ", count: 40)
        try assertFriendRecovers(paragraph)
    }

    // MARK: - Volume / statistical confidence

    func testManyRandomKeysAndMessages() throws {
        // 100 independent ciphers, each used to round-trip a spread of messages.
        let messages = [
            "Attack at dawn.",
            "Retreat to the river!",
            "Gold is buried beneath the third pine, 40 paces north.",
            "Meet @ the docks #7 — 50% now, 50% later.",
            "Mixing 123 & symbols <> with emoji 🔥 and accents é",
            "",
            "🔥",
        ]
        for _ in 0..<100 {
            for message in messages {
                try assertFriendRecovers(message)
            }
        }
    }

    // MARK: - The decoder file itself

    func testExportedDecoderFileIsValidAndComplete() throws {
        let key = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileBytes = try encoder.encode(RuneKeyExport.from(key))

        // Must be valid JSON.
        let json = try JSONSerialization.jsonObject(with: fileBytes) as? [String: Any]
        XCTAssertNotNil(json, "decoder file must be valid JSON")
        XCTAssertEqual(json?["applicationName"] as? String, "RuneScrib")
        XCTAssertEqual((json?["mapping"] as? [String: String])?.count, 89)
        XCTAssertEqual((json?["reverseMapping"] as? [String: String])?.count, 89)

        // And it must import cleanly.
        let imported = try ImportedDecoder.parse(fileBytes)
        XCTAssertEqual(imported.keyId, key.keyId, "import preserves the sender's key id")
        XCTAssertEqual(imported.mapping, key.mapping)
    }

    func testEveryRuneInThePoolDecodes() throws {
        // Build a message that, once encoded, contains every rune in the pool, and
        // confirm the recipient decodes each one back to the right character.
        let key = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let allInput = RuneCharacterSet.inputCharacters.joined()
        let runes = CipherEngine(key: key).encode(allInput)

        // Every encoded glyph should be a rune from the pool.
        for character in runes {
            XCTAssertTrue(RuneCharacterSet.runicPool.contains(String(character)),
                          "encoded glyph \(character) should be a pool rune")
        }

        // Export → import → decode recovers all 89 characters.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fileBytes = try encoder.encode(RuneKeyExport.from(key))
        let imported = try ImportedDecoder.parse(fileBytes)
        let recipientKey = RuneKey(keyId: imported.keyId, createdAt: imported.createdAt, mapping: imported.mapping)
        XCTAssertEqual(CipherEngine(key: recipientKey).decode(runes), allInput)
    }

    // MARK: - Sanity: the cipher actually matters

    func testWrongDecoderDoesNotRecoverMessage() throws {
        let message = "The secret is in the cellar."
        let senderKey = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let runes = CipherEngine(key: senderKey).encode(message)

        // A different person with the WRONG decoder cannot read it.
        let wrongKey = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let wrongDecode = CipherEngine(key: wrongKey).decode(runes)
        XCTAssertNotEqual(wrongDecode, message,
                          "a different cipher must not decode the message correctly")
    }

    // MARK: - Known, documented limitation

    func testLiteralRunesInPlaintextAreADocumentedNonRoundTripCase() throws {
        // The cipher's OUTPUT alphabet is the runic block, so if a *plaintext*
        // message itself contains literal rune characters (U+16A0–U+16F8), those
        // particular characters pass through on encode but are decoded as if they
        // were ciphertext — they do not round-trip. Everything around them does.
        // This is a deliberate property of a runic substitution cipher, not a bug:
        // real messages are not typed in Norse runes.
        let key = RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
        let engine = CipherEngine(key: key)

        let withRunes = "ᚱᚢᚾᛖ and normal text"
        let recovered = engine.decode(engine.encode(withRunes))

        XCTAssertTrue(recovered.hasSuffix(" and normal text"),
                      "normal text alongside literal runes still round-trips correctly")
        XCTAssertNotEqual(recovered, withRunes,
                          "literal runes in the plaintext are a documented non-round-trip case")
    }

    func testSameFileImportedTwiceDecodesIdentically() throws {
        // Importing the same decoder file on two devices yields identical decodes.
        let sent = try senderEncodesAndExports("Consistency check across two imports.")
        let a = try recipientImportsAndDecodes(runes: sent.runes, decoderFile: sent.decoderFile)
        let b = try recipientImportsAndDecodes(runes: sent.runes, decoderFile: sent.decoderFile)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, "Consistency check across two imports.")
    }
}
