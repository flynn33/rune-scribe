// RuneScribTests/RuneScribTests.swift

import XCTest
@testable import RuneScrib

final class RuneScribTests: XCTestCase {

    // MARK: - RuneCharacterSet Tests

    func testInputCharacterCount() {
        XCTAssertEqual(RuneCharacterSet.inputCharacters.count, 89,
                       "inputCharacters must contain exactly 89 entries.")
    }

    func testRunicPoolCount() {
        XCTAssertEqual(RuneCharacterSet.runicPool.count, 89,
                       "runicPool must contain exactly 89 entries.")
    }

    func testRunicPoolUniqueness() {
        let pool = RuneCharacterSet.runicPool
        let uniqueSet = Set(pool)
        XCTAssertEqual(pool.count, uniqueSet.count,
                       "runicPool must contain all unique characters.")
    }

    func testInputCharactersUniqueness() {
        let chars = RuneCharacterSet.inputCharacters
        let uniqueSet = Set(chars)
        XCTAssertEqual(chars.count, uniqueSet.count,
                       "inputCharacters must all be unique.")
    }

    func testRunicPoolRange() {
        // All rune characters must be in the Unicode Runic block (U+16A0–U+16F8)
        for rune in RuneCharacterSet.runicPool {
            guard let scalar = rune.unicodeScalars.first else {
                XCTFail("Runic pool contains empty string."); continue
            }
            XCTAssertTrue((0x16A0...0x16F8).contains(Int(scalar.value)),
                          "Rune \(rune) (U+\(String(format: "%04X", scalar.value))) is outside the Runic block.")
        }
    }

    // MARK: - Key Generation Tests

    func testGenerateRandomMappingCount() {
        let mapping = RuneCharacterSet.generateRandomMapping()
        XCTAssertEqual(mapping.count, 89,
                       "Generated mapping must have exactly 89 entries.")
    }

    func testGenerateRandomMappingBijection() {
        let mapping = RuneCharacterSet.generateRandomMapping()
        let uniqueValues = Set(mapping.values)
        XCTAssertEqual(uniqueValues.count, 89,
                       "Generated mapping must be a bijection: all rune values must be unique.")
    }

    func testGeneratedMappingCoversAllInputChars() {
        let mapping = RuneCharacterSet.generateRandomMapping()
        for inputChar in RuneCharacterSet.inputCharacters {
            XCTAssertNotNil(mapping[inputChar],
                            "Mapping missing entry for input character: '\(inputChar)'")
        }
    }

    func testTwoGenerationsAreDifferent() {
        // With 89! possible permutations, two random generations will essentially never be equal
        let mapping1 = RuneCharacterSet.generateRandomMapping()
        let mapping2 = RuneCharacterSet.generateRandomMapping()
        XCTAssertNotEqual(mapping1, mapping2,
                          "Two independently generated mappings should differ.")
    }

    // MARK: - RuneKey Tests

    func testRuneKeyInit() {
        let mapping = RuneCharacterSet.generateRandomMapping()
        let key = RuneKey(mapping: mapping)

        XCTAssertEqual(key.version, 1)
        XCTAssertFalse(key.keyId.isEmpty)
        XCTAssertEqual(key.mapping.count, 89)
        XCTAssertEqual(key.reverseMapping.count, 89)
    }

    func testReverseMappingConsistency() {
        let mapping = RuneCharacterSet.generateRandomMapping()
        let key = RuneKey(mapping: mapping)

        for (inputChar, rune) in key.mapping {
            XCTAssertEqual(key.reverseMapping[rune], inputChar,
                           "reverseMapping[\(rune)] should be '\(inputChar)'")
        }
    }

    // MARK: - CipherEngine Tests

    var testKey: RuneKey {
        let mapping = RuneCharacterSet.generateRandomMapping()
        return RuneKey(mapping: mapping)
    }

    func testEncodeProducesRuneCharacters() {
        let key = testKey
        let engine = CipherEngine(key: key)
        let encoded = engine.encode("Hello")

        XCTAssertEqual(encoded.count, 5, "Encoded string should have same character count as input.")

        for char in encoded {
            let charStr = String(char)
            // Every character in encoded output should be a rune
            XCTAssertTrue(RuneCharacterSet.runicPool.contains(charStr),
                          "Encoded character '\(char)' is not in the runic pool.")
        }
    }

    func testRoundTrip() {
        let key = testKey
        let engine = CipherEngine(key: key)
        let original = "Hello World! 42 #test"
        let encoded  = engine.encode(original)
        let decoded  = engine.decode(encoded)

        XCTAssertEqual(decoded, original,
                       "Round-trip encode→decode must return the original string.")
    }

    func testCaseSensitivity() {
        let key = testKey
        let engine = CipherEngine(key: key)

        let encodedUpper = engine.encode("A")
        let encodedLower = engine.encode("a")

        XCTAssertNotEqual(encodedUpper, encodedLower,
                          "Uppercase and lowercase must encode to different runes.")
    }

    func testUnknownCharacterPassthrough() {
        let key = testKey
        let engine = CipherEngine(key: key)

        // Emoji and non-Latin chars not in the map should pass through
        let emoji = "🔥"
        let encoded = engine.encode(emoji)
        XCTAssertEqual(encoded, emoji, "Unknown characters should pass through unchanged.")
    }

    func testNewlinePassthrough() {
        let key = testKey
        let engine = CipherEngine(key: key)
        let input = "Line1\nLine2"
        let encoded = engine.encode(input)
        // The \n should pass through; the letters should be encoded
        XCTAssertTrue(encoded.contains("\n"), "Newline should pass through encoding.")
    }

    func testSpaceIsEncoded() {
        let key = testKey
        let engine = CipherEngine(key: key)
        let encoded = engine.encode(" ")
        XCTAssertNotEqual(encoded, " ", "Space should be encoded to a rune, not left as a literal space.")
        XCTAssertEqual(encoded.count, 1, "Space should encode to exactly one rune character.")
    }

    func testFullAlphabetRoundTrip() {
        let key = testKey
        let engine = CipherEngine(key: key)
        let fullSet = RuneCharacterSet.inputCharacters.joined()
        let encoded = engine.encode(fullSet)
        let decoded = engine.decode(encoded)
        XCTAssertEqual(decoded, fullSet, "Full input character set must survive a round-trip.")
    }

    // MARK: - RuneKeyExport Tests

    func testExportFromKey() {
        let mapping = RuneCharacterSet.generateRandomMapping()
        let key = RuneKey(mapping: mapping)
        let export = RuneKeyExport.from(key)

        XCTAssertEqual(export.applicationName, "RuneScrib")
        XCTAssertEqual(export.version, key.version)
        XCTAssertEqual(export.keyId, key.keyId)
        XCTAssertEqual(export.mapping.count, 89)
        XCTAssertEqual(export.reverseMapping.count, 89)
    }
}
