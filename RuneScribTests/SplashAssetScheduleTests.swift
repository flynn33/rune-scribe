// RuneScribTests/SplashAssetScheduleTests.swift

import XCTest
@testable import RuneScrib

/// Schedule rules for the cold-launch intro video (once every 30 days).
final class SplashAssetScheduleTests: XCTestCase {

    private var defaults: UserDefaults!
    private let suiteName = "rf.tests.splash.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testShouldShowWhenNeverPresented() {
        // Asset may be missing in unit-test host; only assert the date side when present.
        guard SplashAsset.url != nil else {
            XCTAssertFalse(SplashAsset.shouldShow(defaults: defaults))
            return
        }
        XCTAssertTrue(SplashAsset.shouldShow(defaults: defaults))
    }

    func testShouldNotShowWithinThirtyDays() {
        guard SplashAsset.url != nil else { return }

        let now = Date()
        SplashAsset.markShown(now: now, defaults: defaults)

        XCTAssertFalse(
            SplashAsset.shouldShow(now: now.addingTimeInterval(1), defaults: defaults)
        )
        XCTAssertFalse(
            SplashAsset.shouldShow(
                now: now.addingTimeInterval(SplashAsset.replayInterval - 1),
                defaults: defaults
            )
        )
    }

    func testShouldShowAfterThirtyDays() {
        guard SplashAsset.url != nil else { return }

        let now = Date()
        SplashAsset.markShown(now: now, defaults: defaults)

        XCTAssertTrue(
            SplashAsset.shouldShow(
                now: now.addingTimeInterval(SplashAsset.replayInterval),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            SplashAsset.shouldShow(
                now: now.addingTimeInterval(SplashAsset.replayInterval + 60),
                defaults: defaults
            )
        )
    }

    func testMarkShownPersistsDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        SplashAsset.markShown(now: now, defaults: defaults)
        let stored = defaults.object(forKey: SplashAsset.lastShownDefaultsKey) as? Date
        XCTAssertEqual(stored, now)
    }
}
