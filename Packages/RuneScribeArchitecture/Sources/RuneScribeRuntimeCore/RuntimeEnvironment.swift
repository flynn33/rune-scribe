import Foundation
import RuneScribeContracts

public struct RuntimeEnvironment: Sendable {
    private let nowProvider: @Sendable () -> Date
    private let uuidProvider: @Sendable () -> UUID

    public init(
        now: @escaping @Sendable () -> Date,
        nextUUID: @escaping @Sendable () -> UUID
    ) {
        nowProvider = now
        uuidProvider = nextUUID
    }

    public init(clock: any ClockProviding, uuidProvider: any UUIDProviding) {
        nowProvider = { clock.now() }
        self.uuidProvider = { uuidProvider.nextUUID() }
    }

    public func now() -> Date {
        nowProvider()
    }

    public func nextUUID() -> UUID {
        uuidProvider()
    }

    public static let live = RuntimeEnvironment(
        now: { Date() },
        nextUUID: { UUID() }
    )
}
