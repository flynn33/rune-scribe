import SwiftUI

public struct RuntimeAccessibilityPreferences: Equatable, Sendable {
    public let forcesReduceMotion: Bool
    public let forcesIncreasedContrast: Bool

    public init(
        forcesReduceMotion: Bool = false,
        forcesIncreasedContrast: Bool = false
    ) {
        self.forcesReduceMotion = forcesReduceMotion
        self.forcesIncreasedContrast = forcesIncreasedContrast
    }
}

private struct RuntimeAccessibilityPreferencesKey: EnvironmentKey {
    static let defaultValue = RuntimeAccessibilityPreferences()
}

public extension EnvironmentValues {
    var runtimeAccessibilityPreferences: RuntimeAccessibilityPreferences {
        get { self[RuntimeAccessibilityPreferencesKey.self] }
        set { self[RuntimeAccessibilityPreferencesKey.self] = newValue }
    }
}
