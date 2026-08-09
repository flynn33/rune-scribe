import Foundation
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

    func testPINFailuresUseClosedSafeMessages() {
        enum FixtureError: Error {
            case sensitiveInternalDetail
        }

        XCTAssertEqual(
            RuneScribeUISession.message(forPINError: RuneScribeUISession.PINError.invalidFormat),
            "Enter a 4-digit PIN."
        )
        XCTAssertEqual(
            RuneScribeUISession.message(forPINError: RuneScribeUISession.PINError.wrongPIN),
            "Incorrect PIN."
        )
        XCTAssertEqual(
            RuneScribeUISession.message(forPINError: FixtureError.sensitiveInternalDetail),
            "App Lock is temporarily unavailable."
        )
    }

    func testPINViewsDoNotSurfaceRawLocalizedDescriptions() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsDirectory = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("RuneScribeUIModule", isDirectory: true)
            .appendingPathComponent("Views", isDirectory: true)

        for filename in ["PINFlowView.swift", "LockView.swift"] {
            let source = try String(
                contentsOf: viewsDirectory.appendingPathComponent(filename),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("localizedDescription"))
        }
    }
}
