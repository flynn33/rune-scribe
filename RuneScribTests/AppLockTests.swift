// RuneScribTests/AppLockTests.swift

import XCTest
@testable import RuneScrib

/// Tests for the pure (Keychain-independent) parts of the app-lock PIN logic.
final class AppLockTests: XCTestCase {

    func testValidPINFormats() {
        XCTAssertTrue(AppLock.isValidFormat("0000"))
        XCTAssertTrue(AppLock.isValidFormat("1234"))
        XCTAssertTrue(AppLock.isValidFormat("9876"))
    }

    func testInvalidPINFormats() {
        XCTAssertFalse(AppLock.isValidFormat(""),      "empty is invalid")
        XCTAssertFalse(AppLock.isValidFormat("123"),   "too short")
        XCTAssertFalse(AppLock.isValidFormat("12345"), "too long")
        XCTAssertFalse(AppLock.isValidFormat("12a4"),  "letters are invalid")
        XCTAssertFalse(AppLock.isValidFormat("12 4"),  "spaces are invalid")
        XCTAssertFalse(AppLock.isValidFormat("１２３４"), "full-width digits are invalid")
    }
}
