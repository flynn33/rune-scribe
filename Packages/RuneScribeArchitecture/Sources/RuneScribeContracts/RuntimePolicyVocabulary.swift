import Foundation

public enum RuneScribeModuleIDs {
    public static let core: ModuleIdentifier = "com.runescribe.module.core"
    public static let primaryUI: ModuleIdentifier = "com.runescribe.module.ui"
}

public enum RuneScribeRoles {
    public static let core: ModuleRole = "runescribe.core"
    public static let primaryUI: ModuleRole = "runescribe.ui.primary"
    public static let applicationHost: ModuleRole = "application.host"
}

public enum RuneScribeCapabilities {
    public static let publishService: CapabilityIdentifier = "runtime.service.publish"
    public static let resolveService: CapabilityIdentifier = "runtime.service.resolve"
    public static let publishEvents: CapabilityIdentifier = "runtime.events.publish"
    public static let subscribeEvents: CapabilityIdentifier = "runtime.events.subscribe"
    public static let sendMessages: CapabilityIdentifier = "runtime.messages.send"
    public static let receiveMessages: CapabilityIdentifier = "runtime.messages.receive"
    public static let rootUI: CapabilityIdentifier = "ui.root"

    public static let all: Set<CapabilityIdentifier> = [
        publishService,
        resolveService,
        publishEvents,
        subscribeEvents,
        sendMessages,
        receiveMessages,
        rootUI,
    ]
}

public protocol ClockProviding: Sendable {
    func now() -> Date
}

public protocol UUIDProviding: Sendable {
    func nextUUID() -> UUID
}
