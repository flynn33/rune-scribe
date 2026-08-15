import Foundation

public enum RuneScribeModuleIDs {
    public static let core: ModuleIdentifier = "com.runescribe.module.core"
    public static let primaryUI: ModuleIdentifier = "com.runescribe.module.ui"
    public static let progression: ModuleIdentifier = "com.runescribe.module.progression"
    public static let themeCoordinator: ModuleIdentifier =
        "com.runescribe.module.theme-coordinator"
    public static let norseTheme: ModuleIdentifier = "com.runescribe.module.theme.norse"
}

public enum RuneScribeUnlockIDs {
    public static let norseCodex = UnlockID(rawValue: "unlock.codex.norse")!
}

public enum RuneScribeCodexIDs {
    public static let norse = CodexID(rawValue: "codex.norse")!
}

public enum RuneScribeRoles {
    public static let core: ModuleRole = "runescribe.core"
    public static let primaryUI: ModuleRole = "runescribe.ui.primary"
    public static let applicationHost: ModuleRole = "application.host"
    public static let progression: ModuleRole = "runescribe.progression"
    public static let themeCoordinator: ModuleRole = "runescribe.theme.coordinator"
    public static let norseTheme: ModuleRole = "runescribe.theme.norse"
}

public enum RuneScribePolicyClasses {
    public static let core = ModulePolicyClass(role: RuneScribeRoles.core)
    public static let primaryUI = ModulePolicyClass(role: RuneScribeRoles.primaryUI)
    public static let applicationHost = ModulePolicyClass(
        role: RuneScribeRoles.applicationHost
    )
    public static let progression = ModulePolicyClass(role: RuneScribeRoles.progression)
    public static let themeProvider: ModulePolicyClass = "policy.theme-provider"
    public static let themeCoordinator: ModulePolicyClass = "policy.theme-coordinator"
    public static let supportTooling: ModulePolicyClass = "policy.support-tooling"
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
    public static let fileImportUI: CapabilityIdentifier = "ui.file-import"
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
    public static let moduleStateAccess: CapabilityIdentifier = "runtime.module-state.access"
    public static let runtimeSettingsRead: CapabilityIdentifier = "runtime.settings.read"
    public static let runtimeSettingsWrite: CapabilityIdentifier = "runtime.settings.write"
    public static let runtimeAvailabilityRead: CapabilityIdentifier =
        "runtime.availability.read"
    public static let progressionEventSubmit: CapabilityIdentifier =
        "progression.events.submit"
    public static let progressionEventApply: CapabilityIdentifier =
        "progression.events.apply"
    public static let progressionStateRead: CapabilityIdentifier =
        "progression.state.read"
    public static let progressionCommands: CapabilityIdentifier =
        "progression.commands"
    public static let progressionRecovery: CapabilityIdentifier =
        "progression.recovery"
    public static let progressionMigrationSubmit: CapabilityIdentifier =
        "progression.migration.submit"
    public static let progressionMigrationApply: CapabilityIdentifier =
        "progression.migration.apply"
    public static let contributionPublish: CapabilityIdentifier =
        "runtime.contributions.publish"
    public static let contributionRead: CapabilityIdentifier =
        "runtime.contributions.read"
    public static let opaqueResourcePublish: CapabilityIdentifier =
        "runtime.resources.opaque.publish"
    public static let opaqueResourceResolve: CapabilityIdentifier =
        "runtime.resources.opaque.resolve"
    public static let themeStateRead: CapabilityIdentifier = "theme.state.read"
    public static let themeSelection: CapabilityIdentifier = "theme.selection"
    public static let themeResourceRead: CapabilityIdentifier = "theme.resources.read"
    public static let themeDiagnostics: CapabilityIdentifier = "theme.diagnostics"

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
        fileImportUI,
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
        moduleStateAccess,
        runtimeSettingsRead,
        runtimeSettingsWrite,
        runtimeAvailabilityRead,
        progressionEventSubmit,
        progressionEventApply,
        progressionStateRead,
        progressionCommands,
        progressionRecovery,
        progressionMigrationSubmit,
        progressionMigrationApply,
        contributionPublish,
        contributionRead,
        opaqueResourcePublish,
        opaqueResourceResolve,
        themeStateRead,
        themeSelection,
        themeResourceRead,
        themeDiagnostics,
    ]
}

public protocol ClockProviding: Sendable {
    func now() -> Date
}

public protocol UUIDProviding: Sendable {
    func nextUUID() -> UUID
}
