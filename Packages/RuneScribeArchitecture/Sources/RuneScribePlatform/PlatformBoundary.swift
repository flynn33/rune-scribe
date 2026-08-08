import Foundation
import RuneScribeContracts

public enum RuneScribePlatformBoundary {
    public static let contractVersion = 1
}

public struct SystemClock: ClockProviding {
    public init() {}

    public func now() -> Date {
        Date()
    }
}

public struct SystemUUIDProvider: UUIDProviding {
    public init() {}

    public func nextUUID() -> UUID {
        UUID()
    }
}
