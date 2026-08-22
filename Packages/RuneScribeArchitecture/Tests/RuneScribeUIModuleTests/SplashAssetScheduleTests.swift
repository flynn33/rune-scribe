import Foundation
@testable import RuneScribeUIRuntime
import XCTest

final class SplashAssetScheduleTests: XCTestCase {
    func testNeverPresentedSplashShowsOnlyWhenResourceExists() {
        XCTAssertTrue(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: Date(),
                lastShownAt: nil
            )
        )
        XCTAssertFalse(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: false,
                now: Date(),
                lastShownAt: nil
            )
        )
    }

    func testSplashDoesNotShowWithinThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now.addingTimeInterval(RuntimeSplashSchedule.replayInterval - 1),
                lastShownAt: now
            )
        )
    }

    func testSplashShowsAtAndAfterThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now.addingTimeInterval(RuntimeSplashSchedule.replayInterval),
                lastShownAt: now
            )
        )
        XCTAssertTrue(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now.addingTimeInterval(RuntimeSplashSchedule.replayInterval + 60),
                lastShownAt: now
            )
        )
    }

    func testFutureLastShownDateFailsClosedUntilIntervalElapses() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now,
                lastShownAt: now.addingTimeInterval(60)
            )
        )
    }
}
