import Foundation
import RuneScribeContracts

public struct CapabilityVocabulary: Sendable {
    public let knownCapabilities: Set<CapabilityIdentifier>

    public init(knownCapabilities: Set<CapabilityIdentifier>) {
        self.knownCapabilities = knownCapabilities
    }

    public func contains(_ capability: CapabilityIdentifier) -> Bool {
        knownCapabilities.contains(capability)
    }
}

public struct CapabilityPolicy: Sendable {
    private let allowedRolesByCapability: [CapabilityIdentifier: Set<ModuleRole>]

    public init(allowedRolesByCapability: [CapabilityIdentifier: Set<ModuleRole>]) {
        self.allowedRolesByCapability = allowedRolesByCapability
    }

    public func allows(_ capability: CapabilityIdentifier, for role: ModuleRole) -> Bool {
        allowedRolesByCapability[capability]?.contains(role) == true
    }
}

public struct ServiceAccessRule: Hashable, Sendable {
    public let serviceID: ServiceIdentifier
    public let requiredCapability: CapabilityIdentifier
    public let publisherRoles: Set<ModuleRole>
    public let consumerRoles: Set<ModuleRole>

    public init(
        serviceID: ServiceIdentifier,
        requiredCapability: CapabilityIdentifier,
        publisherRoles: Set<ModuleRole>,
        consumerRoles: Set<ModuleRole>
    ) {
        self.serviceID = serviceID
        self.requiredCapability = requiredCapability
        self.publisherRoles = publisherRoles
        self.consumerRoles = consumerRoles
    }
}

public struct ServiceAccessPolicy: Sendable {
    private let rules: [ServiceIdentifier: ServiceAccessRule]

    public init(rules: [ServiceAccessRule]) {
        self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.serviceID, $0) })
    }

    public func rule(for serviceID: ServiceIdentifier) -> ServiceAccessRule? {
        rules[serviceID]
    }
}

public struct RuntimePolicy: Sendable {
    public let vocabulary: CapabilityVocabulary
    public let capabilities: CapabilityPolicy
    public let services: ServiceAccessPolicy

    public init(
        vocabulary: CapabilityVocabulary,
        capabilities: CapabilityPolicy,
        services: ServiceAccessPolicy
    ) {
        self.vocabulary = vocabulary
        self.capabilities = capabilities
        self.services = services
    }

    public static let patternBFoundation = RuntimePolicy(
        vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
        capabilities: CapabilityPolicy(allowedRolesByCapability: [
            RuneScribeCapabilities.publishService: [RuneScribeRoles.core],
            RuneScribeCapabilities.resolveService: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.publishEvents: [RuneScribeRoles.core],
            RuneScribeCapabilities.subscribeEvents: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.sendMessages: [RuneScribeRoles.core, RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.receiveMessages: [RuneScribeRoles.core, RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.keychainStorage: [RuneScribeRoles.core],
            RuneScribeCapabilities.protectedFileStorage: [RuneScribeRoles.core],
            RuneScribeCapabilities.inboundFileRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.shareArtifactStorage: [RuneScribeRoles.core],
            RuneScribeCapabilities.resourceRead: [RuneScribeRoles.core, RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.fontRegistration: [RuneScribeRoles.core],
            RuneScribeCapabilities.contactRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.clipboardRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.clipboardWrite: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.clockRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.uuidGenerate: [RuneScribeRoles.core],
            RuneScribeCapabilities.inboundInput: [
                RuneScribeRoles.core,
                RuneScribeRoles.applicationHost,
            ],
            RuneScribeCapabilities.applicationCommands: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.applicationStateRead: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.shareUI: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.messagesUI: [RuneScribeRoles.primaryUI],
        ]),
        services: ServiceAccessPolicy(rules: [
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.secureValueStore,
                requiredCapability: RuneScribeCapabilities.keychainStorage,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.protectedFileStore,
                requiredCapability: RuneScribeCapabilities.protectedFileStorage,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.inboundFileReader,
                requiredCapability: RuneScribeCapabilities.inboundFileRead,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.shareArtifactStore,
                requiredCapability: RuneScribeCapabilities.shareArtifactStorage,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.applicationResourceLocator,
                requiredCapability: RuneScribeCapabilities.resourceRead,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core, RuneScribeRoles.primaryUI]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.systemFontRegistrar,
                requiredCapability: RuneScribeCapabilities.fontRegistration,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.contactAccess,
                requiredCapability: RuneScribeCapabilities.contactRead,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.clipboardRead,
                requiredCapability: RuneScribeCapabilities.clipboardRead,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.clipboardWrite,
                requiredCapability: RuneScribeCapabilities.clipboardWrite,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.primaryUI]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.clock,
                requiredCapability: RuneScribeCapabilities.clockRead,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.uuid,
                requiredCapability: RuneScribeCapabilities.uuidGenerate,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core]
            ),
        ])
    )
}
