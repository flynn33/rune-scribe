import Foundation
import RuneScribeContracts
import RuneScribePlatform
import XCTest

final class SystemValueAdapterTests: XCTestCase {
    func testPlatformSeamsProvideSystemValues() {
        let before = Date()
        let clock: any ClockProviding = SystemClock()
        let now = clock.now()
        let after = Date()

        XCTAssertGreaterThanOrEqual(now, before)
        XCTAssertLessThanOrEqual(now, after)
    }

    func testPublicSystemUUIDProviderConformsToContract() {
        let provider: any UUIDProviding = SystemUUIDProvider()
        let first = provider.nextUUID()
        let second = provider.nextUUID()

        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first.uuidString))
    }
}
