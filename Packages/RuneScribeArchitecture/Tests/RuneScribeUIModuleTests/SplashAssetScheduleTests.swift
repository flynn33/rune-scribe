import AVFoundation
import Foundation
@testable import RuneScribeUIModule
import XCTest

final class SplashAssetScheduleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private let videoURL = URL(fileURLWithPath: "/fixture/splash.mp4")

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
        XCTAssertTrue(SplashAsset.shouldShow(videoURL: videoURL, defaults: defaults))
        XCTAssertFalse(SplashAsset.shouldShow(videoURL: nil, defaults: defaults))
    }

    func testSplashDoesNotShowWithinThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        SplashAsset.markShown(now: now, defaults: defaults)

        XCTAssertFalse(
            SplashAsset.shouldShow(
                videoURL: videoURL,
                now: now.addingTimeInterval(SplashAsset.replayInterval - 1),
                defaults: defaults
            )
        )
    }

    func testSplashShowsAtAndAfterThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        SplashAsset.markShown(now: now, defaults: defaults)

        XCTAssertTrue(
            SplashAsset.shouldShow(
                videoURL: videoURL,
                now: now.addingTimeInterval(SplashAsset.replayInterval),
                defaults: defaults
            )
        )
        XCTAssertTrue(
            SplashAsset.shouldShow(
                videoURL: videoURL,
                now: now.addingTimeInterval(SplashAsset.replayInterval + 60),
                defaults: defaults
            )
        )
    }

    func testMarkShownPersistsDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        SplashAsset.markShown(now: now, defaults: defaults)
        XCTAssertEqual(
            defaults.object(forKey: SplashAsset.lastShownDefaultsKey) as? Date,
            now
        )
    }

    @MainActor
    func testPlaybackCompletionAndSkipEachFinishExactlyOnce() throws {
        let natural = SplashModel(url: videoURL)
        var naturalFinishCount = 0
        natural.start { naturalFinishCount += 1 }
        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: try XCTUnwrap(natural.player.currentItem)
        )
        natural.finish()
        XCTAssertEqual(naturalFinishCount, 1)

        let skipped = SplashModel(url: videoURL)
        var skippedFinishCount = 0
        skipped.start { skippedFinishCount += 1 }
        skipped.finish()
        skipped.finish()
        XCTAssertEqual(skippedFinishCount, 1)
    }
}
