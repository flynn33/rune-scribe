import Foundation

public enum RuntimeSplashSchedule {
    static let lastShownDefaultsKey = "rf.splash.lastShownAt"
    public static let replayInterval: TimeInterval = 30 * 24 * 60 * 60

    public static func shouldShow(
        resourceAvailable: Bool,
        now: Date = Date()
    ) -> Bool {
        shouldShow(
            resourceAvailable: resourceAvailable,
            now: now,
            defaults: .standard
        )
    }

    public static func markShown(now: Date = Date()) {
        markShown(now: now, defaults: .standard)
    }

    static func shouldShow(
        resourceAvailable: Bool,
        now: Date,
        defaults: UserDefaults
    ) -> Bool {
        guard resourceAvailable else { return false }
        guard let lastShown = defaults.object(
            forKey: lastShownDefaultsKey
        ) as? Date else {
            return true
        }
        return now.timeIntervalSince(lastShown) >= replayInterval
    }

    static func markShown(
        now: Date,
        defaults: UserDefaults
    ) {
        defaults.set(now, forKey: lastShownDefaultsKey)
    }
}
