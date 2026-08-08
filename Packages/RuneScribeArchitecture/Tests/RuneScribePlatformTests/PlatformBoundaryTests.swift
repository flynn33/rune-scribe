import Foundation
import RuneScribePlatform
import XCTest

final class PlatformBoundaryTests: XCTestCase {
    func testPlatformSeamsProvideSystemValues() {
        let before = Date()
        let now = SystemClock().now()
        let after = Date()

        XCTAssertEqual(RuneScribePlatformBoundary.contractVersion, 1)
        XCTAssertGreaterThanOrEqual(now, before)
        XCTAssertLessThanOrEqual(now, after)
        XCTAssertNotEqual(SystemUUIDProvider().nextUUID(), UUID())
    }
}
