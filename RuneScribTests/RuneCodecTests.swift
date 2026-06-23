import XCTest
@testable import RuneScrib

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
    func testDecodeRejectsForeignCharacter() {
        let codec = RuneCodec()
        let c = Cipher.generated(label: "x")
        XCTAssertThrowsError(try codec.decode("A", with: c))
    }
}
