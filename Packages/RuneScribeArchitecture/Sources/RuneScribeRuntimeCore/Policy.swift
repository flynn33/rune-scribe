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
    private let allowedPolicyClassesByCapability: [
        CapabilityIdentifier: Set<ModulePolicyClass>
    ]

    public init(
        allowedRolesByCapability: [CapabilityIdentifier: Set<ModuleRole>],
        additionalPolicyClassesByCapability: [
            CapabilityIdentifier: Set<ModulePolicyClass>
        ] = [:]
    ) {
        var mapped = allowedRolesByCapability.mapValues { roles in
            Set(roles.map(ModulePolicyClass.init(role:)))
        }
        for (capability, policyClasses) in additionalPolicyClassesByCapability {
            mapped[capability, default: []].formUnion(policyClasses)
        }
        allowedPolicyClassesByCapability = mapped
    }

    public init(
        allowedPolicyClassesByCapability: [
            CapabilityIdentifier: Set<ModulePolicyClass>
        ]
    ) {
        self.allowedPolicyClassesByCapability = allowedPolicyClassesByCapability
    }

    public func allows(_ capability: CapabilityIdentifier, for role: ModuleRole) -> Bool {
        allows(capability, for: ModulePolicyClass(role: role))
    }

    public func allows(
        _ capability: CapabilityIdentifier,
        for policyClass: ModulePolicyClass
    ) -> Bool {
        allowedPolicyClassesByCapability[capability]?.contains(policyClass) == true
    }

    public func allows(
        _ capability: CapabilityIdentifier,
        for descriptor: ModuleDescriptor
    ) -> Bool {
        allows(capability, for: descriptor.policyClass)
    }
}

public struct ServiceAccessRule: Hashable, Sendable {
    public let serviceID: ServiceIdentifier
    public let requiredCapability: CapabilityIdentifier
    public let publisherRoles: Set<ModuleRole>
    public let consumerRoles: Set<ModuleRole>
    public let publisherPolicyClasses: Set<ModulePolicyClass>
    public let consumerPolicyClasses: Set<ModulePolicyClass>

    public init(
        serviceID: ServiceIdentifier,
        requiredCapability: CapabilityIdentifier,
        publisherRoles: Set<ModuleRole>,
        consumerRoles: Set<ModuleRole>,
        additionalPublisherPolicyClasses: Set<ModulePolicyClass> = [],
        additionalConsumerPolicyClasses: Set<ModulePolicyClass> = []
    ) {
        self.serviceID = serviceID
        self.requiredCapability = requiredCapability
        self.publisherRoles = publisherRoles
        self.consumerRoles = consumerRoles
        publisherPolicyClasses = Set(
            publisherRoles.map(ModulePolicyClass.init(role:))
        ).union(additionalPublisherPolicyClasses)
        consumerPolicyClasses = Set(
            consumerRoles.map(ModulePolicyClass.init(role:))
        ).union(additionalConsumerPolicyClasses)
    }

    public func allowsPublisher(_ descriptor: ModuleDescriptor) -> Bool {
        publisherPolicyClasses.contains(descriptor.policyClass)
    }

    public func allowsPublisher(role: ModuleRole) -> Bool {
        publisherPolicyClasses.contains(ModulePolicyClass(role: role))
    }

    public func allowsConsumer(_ descriptor: ModuleDescriptor) -> Bool {
        consumerPolicyClasses.contains(descriptor.policyClass)
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
    public let settings: RuntimeSettingAccessPolicy

    public init(
        vocabulary: CapabilityVocabulary,
        capabilities: CapabilityPolicy,
        services: ServiceAccessPolicy,
        settings: RuntimeSettingAccessPolicy = .denyAll
    ) {
        self.vocabulary = vocabulary
        self.capabilities = capabilities
        self.services = services
        self.settings = settings
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
            RuneScribeCapabilities.fileImportUI: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.shareArtifactStorage: [RuneScribeRoles.core],
            RuneScribeCapabilities.resourceRead: [
                RuneScribeRoles.core,
                RuneScribeRoles.primaryUI,
                RuneScribeRoles.progression,
            ],
            RuneScribeCapabilities.fontRegistration: [
                RuneScribeRoles.core,
                RuneScribeRoles.primaryUI,
            ],
            RuneScribeCapabilities.contactRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.clipboardRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.clipboardWrite: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.clockRead: [RuneScribeRoles.core],
            RuneScribeCapabilities.uuidGenerate: [RuneScribeRoles.core],
            RuneScribeCapabilities.inboundInput: [
                RuneScribeRoles.core,
                RuneScribeRoles.applicationHost,
            ],
            RuneScribeCapabilities.applicationCommands: [
                RuneScribeRoles.primaryUI,
                RuneScribeRoles.applicationHost,
            ],
            RuneScribeCapabilities.applicationStateRead: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.shareUI: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.messagesUI: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.moduleStateAccess: [
                RuneScribeRoles.core,
                RuneScribeRoles.progression,
            ],
            RuneScribeCapabilities.runtimeSettingsRead: [
                RuneScribeRoles.primaryUI,
                RuneScribeRoles.progression,
            ],
            RuneScribeCapabilities.runtimeSettingsWrite: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.runtimeAvailabilityRead: [
                RuneScribeRoles.primaryUI,
                RuneScribeRoles.progression,
            ],
            RuneScribeCapabilities.progressionEventSubmit: [RuneScribeRoles.core],
            RuneScribeCapabilities.progressionEventApply: [RuneScribeRoles.applicationHost],
            RuneScribeCapabilities.progressionStateRead: [
                RuneScribeRoles.primaryUI,
                RuneScribeRoles.applicationHost,
            ],
            RuneScribeCapabilities.progressionCommands: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.themeStateRead: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.themeSelection: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.themeResourceRead: [RuneScribeRoles.primaryUI],
            RuneScribeCapabilities.progressionRecovery: [RuneScribeRoles.applicationHost],
            RuneScribeCapabilities.progressionMigrationSubmit: [RuneScribeRoles.core],
            RuneScribeCapabilities.progressionMigrationApply: [
                RuneScribeRoles.applicationHost,
            ],
        ], additionalPolicyClassesByCapability: [
            RuneScribeCapabilities.contributionPublish: [
                RuneScribePolicyClasses.themeProvider,
            ],
            RuneScribeCapabilities.contributionRead: [
                RuneScribePolicyClasses.themeCoordinator,
            ],
            RuneScribeCapabilities.opaqueResourcePublish: [
                RuneScribePolicyClasses.themeProvider,
            ],
            RuneScribeCapabilities.opaqueResourceResolve: [
                RuneScribePolicyClasses.themeCoordinator,
            ],
            RuneScribeCapabilities.resourceRead: [
                RuneScribePolicyClasses.themeProvider,
            ],
            RuneScribeCapabilities.runtimeSettingsRead: [
                RuneScribePolicyClasses.themeCoordinator,
            ],
            RuneScribeCapabilities.runtimeSettingsWrite: [
                RuneScribePolicyClasses.themeCoordinator,
            ],
            RuneScribeCapabilities.runtimeAvailabilityRead: [
                RuneScribePolicyClasses.themeCoordinator,
            ],
            RuneScribeCapabilities.publishEvents: [
                RuneScribePolicyClasses.themeCoordinator,
            ],
            RuneScribeCapabilities.themeDiagnostics: [
                RuneScribePolicyClasses.supportTooling,
            ],
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
                serviceID: RuneScribeServiceIDs.sharePresentation,
                requiredCapability: RuneScribeCapabilities.shareUI,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.primaryUI]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.applicationResourceLocator,
                requiredCapability: RuneScribeCapabilities.resourceRead,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [
                    RuneScribeRoles.core,
                    RuneScribeRoles.primaryUI,
                    RuneScribeRoles.progression,
                ],
                additionalConsumerPolicyClasses: [
                    RuneScribePolicyClasses.themeProvider,
                ]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.systemFontRegistrar,
                requiredCapability: RuneScribeCapabilities.fontRegistration,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core, RuneScribeRoles.primaryUI]
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
            ServiceAccessRule(
                serviceID: RuneScribeServiceIDs.moduleStateStore,
                requiredCapability: RuneScribeCapabilities.moduleStateAccess,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.core, RuneScribeRoles.progression]
            ),
            ServiceAccessRule(
                serviceID: RuneScribeUnlockFeedback.serviceID,
                requiredCapability: RuneScribeCapabilities.resolveService,
                publisherRoles: [RuneScribeRoles.applicationHost],
                consumerRoles: [RuneScribeRoles.primaryUI]
            ),
        ]),
        settings: RuntimeSettingAccessPolicy(
            writableSettingIDsByPolicyClass: [
                RuneScribePolicyClasses.primaryUI: [
                    RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
                    RuneScribeRuntimeSettings.unlockFeedbackHapticsEnabled,
                    RuneScribeRuntimeSettings.unlockFeedbackAnimationEnabled,
                    RuneScribeRuntimeSettings.selectedRelicByCodex,
                    RuneScribeRuntimeSettings.selectedSealByCodex,
                ],
                RuneScribePolicyClasses.themeCoordinator: [
                    RuneScribeRuntimeSettings.selectedCodex,
                ],
            ]
        )
    )
}

public struct RuntimeSettingAccessPolicy: Sendable {
    private let writableSettingIDsByPolicyClass: [
        ModulePolicyClass: Set<RuntimeSettingID>
    ]

    public init(
        writableSettingIDsByPolicyClass: [
            ModulePolicyClass: Set<RuntimeSettingID>
        ]
    ) {
        self.writableSettingIDsByPolicyClass = writableSettingIDsByPolicyClass
    }

    public func writableSettingIDs(
        for policyClass: ModulePolicyClass
    ) -> Set<RuntimeSettingID> {
        writableSettingIDsByPolicyClass[policyClass] ?? []
    }

    public static let denyAll = RuntimeSettingAccessPolicy(
        writableSettingIDsByPolicyClass: [:]
    )
}
