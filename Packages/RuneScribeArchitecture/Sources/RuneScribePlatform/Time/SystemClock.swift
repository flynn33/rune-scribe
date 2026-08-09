import Foundation
import RuneScribeContracts

public struct SystemClock: ClockProviding {
    public init() {}

    public func now() -> Date {
        Date()
    }
}
