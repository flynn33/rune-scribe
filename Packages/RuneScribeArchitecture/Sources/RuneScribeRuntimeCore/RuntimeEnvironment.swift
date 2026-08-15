import Foundation
import RuneScribeContracts

public struct RuntimeEnvironment: Sendable {
    private let nowProvider: @Sendable () -> Date
    private let uuidProvider: @Sendable () -> UUID
    let permitsProgressionRecovery: Bool

    public init(
        now: @escaping @Sendable () -> Date,
        nextUUID: @escaping @Sendable () -> UUID,
        permitsProgressionRecovery: Bool = false
    ) {
        nowProvider = now
        uuidProvider = nextUUID
        self.permitsProgressionRecovery = permitsProgressionRecovery
    }

    public init(
        clock: any ClockProviding,
        uuidProvider: any UUIDProviding,
        permitsProgressionRecovery: Bool = false
    ) {
        nowProvider = { clock.now() }
        self.uuidProvider = { uuidProvider.nextUUID() }
        self.permitsProgressionRecovery = permitsProgressionRecovery
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
