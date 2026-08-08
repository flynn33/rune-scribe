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
    public static let keychainStorage: CapabilityIdentifier = "storage.keychain"
    public static let protectedFileStorage: CapabilityIdentifier = "storage.protected-files"
    public static let inboundFileRead: CapabilityIdentifier = "files.inbound.read"
    public static let shareArtifactStorage: CapabilityIdentifier = "storage.share-artifacts"
    public static let resourceRead: CapabilityIdentifier = "resources.read"
    public static let fontRegistration: CapabilityIdentifier = "fonts.register"
    public static let contactRead: CapabilityIdentifier = "contacts.read"
    public static let clipboardRead: CapabilityIdentifier = "clipboard.read"
    public static let clipboardWrite: CapabilityIdentifier = "clipboard.write"
    public static let clockRead: CapabilityIdentifier = "clock.read"
    public static let uuidGenerate: CapabilityIdentifier = "uuid.generate"
    public static let inboundInput: CapabilityIdentifier = "application.inbound-input"
    public static let applicationCommands: CapabilityIdentifier = "application.commands"
    public static let applicationStateRead: CapabilityIdentifier = "application.state.read"
    public static let shareUI: CapabilityIdentifier = "ui.share"
    public static let messagesUI: CapabilityIdentifier = "ui.messages"

    public static let all: Set<CapabilityIdentifier> = [
        publishService,
        resolveService,
        publishEvents,
        subscribeEvents,
        sendMessages,
        receiveMessages,
        rootUI,
        keychainStorage,
        protectedFileStorage,
        inboundFileRead,
        shareArtifactStorage,
        resourceRead,
        fontRegistration,
        contactRead,
        clipboardRead,
        clipboardWrite,
        clockRead,
        uuidGenerate,
        inboundInput,
        applicationCommands,
        applicationStateRead,
        shareUI,
        messagesUI,
    ]
}

public protocol ClockProviding: Sendable {
    func now() -> Date
}

public protocol UUIDProviding: Sendable {
    func nextUUID() -> UUID
}
