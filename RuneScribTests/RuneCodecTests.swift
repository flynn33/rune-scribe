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
