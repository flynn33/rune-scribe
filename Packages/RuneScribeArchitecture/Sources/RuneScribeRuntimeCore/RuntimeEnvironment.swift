import Foundation
import RuneScribeContracts

public struct RuntimeOperatingSystemVersion: Equatable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public struct RuntimeEnvironment: Sendable {
    private let nowProvider: @Sendable () -> Date
    private let uuidProvider: @Sendable () -> UUID
    private let operatingSystemVersionProvider:
        @Sendable () -> RuntimeOperatingSystemVersion
    let permitsProgressionRecovery: Bool
    public let permitsThemeDiagnostics: Bool

    public init(
        now: @escaping @Sendable () -> Date,
        nextUUID: @escaping @Sendable () -> UUID,
        operatingSystemVersion: @escaping @Sendable () -> RuntimeOperatingSystemVersion = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return RuntimeOperatingSystemVersion(
                major: version.majorVersion,
                minor: version.minorVersion,
                patch: version.patchVersion
            )
        },
        permitsProgressionRecovery: Bool = false,
        permitsThemeDiagnostics: Bool = false
    ) {
        nowProvider = now
        uuidProvider = nextUUID
        operatingSystemVersionProvider = operatingSystemVersion
        self.permitsProgressionRecovery = permitsProgressionRecovery
        self.permitsThemeDiagnostics = permitsThemeDiagnostics
    }

    public init(
        clock: any ClockProviding,
        uuidProvider: any UUIDProviding,
        operatingSystemVersion: @escaping @Sendable () -> RuntimeOperatingSystemVersion = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            return RuntimeOperatingSystemVersion(
                major: version.majorVersion,
                minor: version.minorVersion,
                patch: version.patchVersion
            )
        },
        permitsProgressionRecovery: Bool = false,
        permitsThemeDiagnostics: Bool = false
    ) {
        nowProvider = { clock.now() }
        self.uuidProvider = { uuidProvider.nextUUID() }
        operatingSystemVersionProvider = operatingSystemVersion
        self.permitsProgressionRecovery = permitsProgressionRecovery
        self.permitsThemeDiagnostics = permitsThemeDiagnostics
    }

    public func now() -> Date {
        nowProvider()
    }

    public func nextUUID() -> UUID {
        uuidProvider()
    }

    public func operatingSystemVersion() -> RuntimeOperatingSystemVersion {
        operatingSystemVersionProvider()
    }

    public static let live = RuntimeEnvironment(
        now: { Date() },
        nextUUID: { UUID() }
    )
}
