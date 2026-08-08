@testable import RuneScribeUIModule
import XCTest

final class PINFormatTests: XCTestCase {
    func testAcceptsExactlyFourASCIIDigits() {
        XCTAssertTrue(RuneScribeUISession.isValidPINFormat("0000"))
        XCTAssertTrue(RuneScribeUISession.isValidPINFormat("1234"))
        XCTAssertTrue(RuneScribeUISession.isValidPINFormat("9876"))
    }

    func testRejectsInvalidPINShapes() {
        XCTAssertFalse(RuneScribeUISession.isValidPINFormat(""))
        XCTAssertFalse(RuneScribeUISession.isValidPINFormat("123"))
        XCTAssertFalse(RuneScribeUISession.isValidPINFormat("12345"))
        XCTAssertFalse(RuneScribeUISession.isValidPINFormat("12a4"))
        XCTAssertFalse(RuneScribeUISession.isValidPINFormat("12 4"))
        XCTAssertFalse(RuneScribeUISession.isValidPINFormat("１２３４"))
    }
}
