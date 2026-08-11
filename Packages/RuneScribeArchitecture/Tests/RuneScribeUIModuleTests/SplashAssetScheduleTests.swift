import Foundation
@testable import RuneScribeUIRuntime
import XCTest

final class SplashAssetScheduleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        super.setUp()
        suiteName = "runescribe.tests.splash.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testNeverPresentedSplashShowsOnlyWhenResourceExists() {
        XCTAssertTrue(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: Date(),
                defaults: defaults
            )
        )
        XCTAssertFalse(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: false,
                now: Date(),
                defaults: defaults
            )
        )
    }

    func testSplashDoesNotShowWithinThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        RuntimeSplashSchedule.markShown(now: now, defaults: defaults)

        XCTAssertFalse(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now.addingTimeInterval(RuntimeSplashSchedule.replayInterval - 1),
                defaults: defaults
            )
        )
    }

    func testSplashShowsAtAndAfterThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        RuntimeSplashSchedule.markShown(now: now, defaults: defaults)

        XCTAssertTrue(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now.addingTimeInterval(RuntimeSplashSchedule.replayInterval),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            RuntimeSplashSchedule.shouldShow(
                resourceAvailable: true,
                now: now.addingTimeInterval(RuntimeSplashSchedule.replayInterval + 60),
                defaults: defaults
            )
        )
    }

    func testMarkShownPersistsDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        RuntimeSplashSchedule.markShown(now: now, defaults: defaults)
        XCTAssertEqual(
            defaults.object(
                forKey: RuntimeSplashSchedule.lastShownDefaultsKey
            ) as? Date,
            now
        )
    }
}
