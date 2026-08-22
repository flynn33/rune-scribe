import Foundation

public enum RuntimeSplashSchedule {
    public static let replayInterval: TimeInterval = 30 * 24 * 60 * 60

    public static func shouldShow(
        resourceAvailable: Bool,
        now: Date,
        lastShownAt: Date?
    ) -> Bool {
        guard resourceAvailable else { return false }
        guard let lastShownAt else { return true }
        return now.timeIntervalSince(lastShownAt) >= replayInterval
    }
}
