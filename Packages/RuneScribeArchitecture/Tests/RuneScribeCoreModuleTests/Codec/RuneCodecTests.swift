import XCTest
import RuneScribeContracts
@testable import RuneScribeCoreModule

final class RuneCodecTests: XCTestCase {
    func testDecorativeAlphabetIs32UniqueRunesWithBroadCoverage() {
        let a = RuneCharacterSet.decorativeAlphabet
        XCTAssertEqual(a.count, 32)
        XCTAssertEqual(Set(a).count, 32, "alphabet runes must be unique")
        for ch in a {
            let v = ch.unicodeScalars.first!.value
            XCTAssertTrue((0x16A0...0x16BF).contains(v), "rune \(ch) outside the broadly-supported range")
        }
    }
}

extension RuneCodecTests {
    func testRoundTripArbitraryBytes() throws {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        for len in [0, 1, 2, 3, 4, 5, 7, 16, 33, 128] {
            let data = Data((0..<len).map { _ in UInt8.random(in: .min ... .max) })
            let runes = codec.encode(data, with: c)
            XCTAssertEqual(try codec.decode(runes, with: c), data, "len=\(len)")
        }
    }
    func testOutputUsesOnlyAlphabetRunes() {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        let runes = codec.encode(Data([0xDE, 0xAD, 0xBE, 0xEF]), with: c)
        let allowed = Set(RuneCharacterSet.decorativeAlphabet)
        XCTAssertTrue(runes.allSatisfy { allowed.contains($0) })
    }

    func testBaseScriptIsExactlyTheLegacyAlphabetAndOutput() throws {
        let codec = RuneCodec()
        let cipher = Cipher.generated(label: "base")
        let bytes = Data([0xDE, 0xAD, 0xBE, 0xEF])

        XCTAssertEqual(ScriptDescriptor.baseRune.portableAlphabet, RuneCharacterSet.decorativeAlphabet)
        XCTAssertEqual(
            codec.encode(bytes, with: cipher),
            try codec.encode(bytes, with: cipher, script: .baseRune)
        )
    }

    func testDifferentScriptChangesOnlyPresentationAndRoundTrips() throws {
        let glyphs = (0..<32).map { index in
            ScriptGlyphDescriptor(
                id: "test-glyph-\(index)",
                textToken: Character(Unicode.Scalar(0xE000 + index)!)
            )
        }
        let script = try ScriptDescriptor(
            id: try XCTUnwrap(ScriptID(rawValue: "script.test-alternate")),
            version: 1,
            portability: .unicodePortable,
            glyphs: glyphs
        )
        let cipher = Cipher.generated(label: "alternate")
        let keyBefore = cipher.keyMaterial
        let publicIDBefore = cipher.publicID
        let permutationBefore = cipher.symbolPermutation
        let bytes = Data((0..<128).map(UInt8.init))

        let encoded = try RuneCodec().encode(bytes, with: cipher, script: script)
        XCTAssertEqual(try RuneCodec().decode(encoded, with: cipher, script: script), bytes)
        XCTAssertEqual(cipher.keyMaterial, keyBefore)
        XCTAssertEqual(cipher.publicID, publicIDBefore)
        XCTAssertEqual(cipher.symbolPermutation, permutationBefore)
        XCTAssertNotEqual(encoded, RuneCodec().encode(bytes, with: cipher))
    }

    func testLegacyFontCompatibilityDoesNotChangeSymbols() throws {
        let custom = FontRef(id: "fixture-font", version: 7, sha256: Data(repeating: 4, count: 32))
        let script = try ScriptDescriptor.legacyCompatibility(fontRef: custom)

        XCTAssertEqual(script.portableAlphabet, RuneCharacterSet.decorativeAlphabet)
        XCTAssertEqual(script.renderingFont, custom)
        XCTAssertEqual(script.portability, .fontDependent)
    }

    func testScriptCodableRoundTripRevalidatesCharacterTokens() throws {
        let encoded = try JSONEncoder().encode(ScriptDescriptor.baseRune)
        XCTAssertEqual(
            try JSONDecoder().decode(ScriptDescriptor.self, from: encoded),
            .baseRune
        )

        let malformed = String(data: encoded, encoding: .utf8)!
            .replacingOccurrences(of: "ᚠ", with: "two")
        XCTAssertThrowsError(
            try JSONDecoder().decode(ScriptDescriptor.self, from: Data(malformed.utf8))
        ) { error in
            XCTAssertEqual(error as? ScriptValidationError, .invalidTextToken)
        }
    }

    func testScriptValidationRejectsMalformedGlyphIDsAndPartialVectorText() throws {
        var malformedIDs = ScriptDescriptor.baseRune.glyphs
        malformedIDs[0] = ScriptGlyphDescriptor(id: "Bad Glyph", textToken: "ᚠ")
        XCTAssertThrowsError(
            try ScriptDescriptor(
                id: XCTUnwrap(ScriptID(rawValue: "script.invalid-glyph")),
                version: 1,
                portability: .unicodePortable,
                glyphs: malformedIDs
            )
        ) { error in
            XCTAssertEqual(error as? ScriptValidationError, .invalidGlyphID)
        }

        var partialVector = ScriptDescriptor.baseRune.glyphs.map {
            ScriptGlyphDescriptor(id: $0.id, textToken: nil)
        }
        partialVector[0] = ScriptGlyphDescriptor(id: partialVector[0].id, textToken: "ᚠ")
        XCTAssertThrowsError(
            try ScriptDescriptor(
                id: XCTUnwrap(ScriptID(rawValue: "script.partial-vector")),
                version: 1,
                portability: .vectorRendered,
                glyphs: partialVector
            )
        ) { error in
            XCTAssertEqual(error as? ScriptValidationError, .invalidTextToken)
        }
    }
    func testDecodeRejectsForeignCharacter() {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        XCTAssertThrowsError(try codec.decode("A", with: c)) { error in
            XCTAssertEqual(error as? RuneCodecError, .foreignCharacter)
        }
    }

    func testDecodeRejectsImpossibleZeroPaddedGroupCount() {
        let codec = RuneCodec()
        let cipher = Cipher.generated(label: "x")
        let zeroRune = RuneCharacterSet.decorativeAlphabet[cipher.decorativeMapping[0]]

        XCTAssertThrowsError(try codec.decode(String(zeroRune), with: cipher)) { error in
            XCTAssertEqual(error as? RuneCodecError, .invalidLength)
        }
    }

    func testDecodeRejectsNonzeroTrailingBits() {
        let codec = RuneCodec()
        let cipher = Cipher.generated(label: "x")
        let alphabet = RuneCharacterSet.decorativeAlphabet
        let first = alphabet[cipher.decorativeMapping[0]]
        let nonzeroPadding = alphabet[cipher.decorativeMapping[1]]

        XCTAssertThrowsError(
            try codec.decode(String([first, nonzeroPadding]), with: cipher)
        ) { error in
            XCTAssertEqual(error as? RuneCodecError, .invalidLength)
        }
    }
}
