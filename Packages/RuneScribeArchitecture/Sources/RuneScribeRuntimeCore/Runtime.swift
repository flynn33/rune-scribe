import Foundation
import RuneScribeContracts
import RuneScribeGameCenterModule
import RuneScribeUIPresentationContracts

public enum RuntimeStatus: Equatable, Sendable {
    case idle
    case starting
    case running
    case stopping
    case stopped
    case failed
}

public struct RuntimeSnapshot: Equatable, Sendable {
    public let status: RuntimeStatus
    public let moduleStates: [ModuleIdentifier: ModuleLifecycleState]
    public let activationOrder: [ModuleIdentifier]
    public let activeUIModuleID: ModuleIdentifier?
    public let entitlementSnapshot: ProgressionEntitlementSnapshotDTO
    public let cloudGameCenterStatus: RuntimeCloudGameCenterStatusSnapshotDTO

    public init(
        status: RuntimeStatus,
        moduleStates: [ModuleIdentifier: ModuleLifecycleState],
        activationOrder: [ModuleIdentifier],
        activeUIModuleID: ModuleIdentifier?,
        entitlementSnapshot: ProgressionEntitlementSnapshotDTO,
        cloudGameCenterStatus: RuntimeCloudGameCenterStatusSnapshotDTO
    ) {
        self.status = status
        self.moduleStates = moduleStates
        self.activationOrder = activationOrder
        self.activeUIModuleID = activeUIModuleID
        self.entitlementSnapshot = entitlementSnapshot
        self.cloudGameCenterStatus = cloudGameCenterStatus
    }
}

protocol RuntimeStartCoordinating: Sendable {
    func beforeInfrastructureActivation() async
    func afterRuntimeMarkedRunningBeforeIngressActivation() async
    func afterClientQuiesceBeforeIngressDrain() async
}

extension RuntimeStartCoordinating {
    func afterRuntimeMarkedRunningBeforeIngressActivation() async {}
    func afterClientQuiesceBeforeIngressDrain() async {}
}

private struct ImmediateRuntimeStartCoordinator: RuntimeStartCoordinating {
    func beforeInfrastructureActivation() async {}
}

public actor RuneScribeRuntime {
    private struct Registration: Sendable {
        let manifest: ModuleManifest
        let factory: AnyModuleFactory
        let themeDiscovery: ThemeDescriptor?
    }

    private struct ActiveModule: Sendable {
        let module: any RuneScribeModule
        let context: ModuleContext
    }

    public let runtimeVersion: SemanticVersion
    public let platform: SupportedPlatform

    private let policy: RuntimePolicy
    private let eligibility: any ModuleEligibilityProviding
    private let environment: RuntimeEnvironment
    private let dispatcher: RuntimeOperationDispatcher
    private nonisolated let hostIngress: RuntimeHostIngressRail
    private let startCoordinator: any RuntimeStartCoordinating
    private let platformBridge = RuntimePlatformBridge()
    private let cloudGameCenterGateway: RuntimeCloudGameCenterGateway
    private let cloudGameCenterCoordinator: RuntimeCloudGameCenterCoordinator
    private let runtimeIOGateway: RuntimeIOGateway
    private let moduleStateGateway: RuntimeModuleStateGateway
    private let settingsGateway: RuntimeSettingsGateway
    private let availabilityGateway: RuntimeAvailabilityGateway
    private let unlockFeedbackGateway: RuntimeUnlockFeedbackGateway
    private let progressionOutbox: RuntimeProgressionOutbox
    private let existingUserMigrationHandoff: RuntimeExistingUserMigrationHandoff
    private let rootPresentationGateway = RuntimeRootPresentationGateway()
    private let contributionRegistry: RuntimeContributionRegistry
    private let opaqueResourceRegistry: RuntimeOpaqueResourceRegistry
    private let events = RuntimeEventBus()
    private let messages = DirectedMessageRouter()

    private var registrations: [ModuleIdentifier: Registration] = [:]
    private var failedOptionalDescriptors: [ModuleIdentifier: ModuleDescriptor] = [:]
    private var failedOptionalThemeDiscoveries: [ModuleIdentifier: ThemeDescriptor] = [:]
    private var entryPoints: Set<String> = []
    private var roles: Set<ModuleRole> = []
    private var moduleStates: [ModuleIdentifier: ModuleLifecycleState] = [:]
    private var activeModules: [ModuleIdentifier: ActiveModule] = [:]
    private var activationOrder: [ModuleIdentifier] = []
    private var activeUIModuleID: ModuleIdentifier?
    private var entitlementSnapshot: ProgressionEntitlementSnapshotDTO
    private var lastObservedEntitlementSnapshot: ProgressionEntitlementSnapshotDTO
    private var entitlementObservationTask: Task<Void, Never>?
    private var status: RuntimeStatus = .idle
    private var stopRequestedWhileStarting = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        runtimeVersion: SemanticVersion,
        platform: SupportedPlatform,
        policy: RuntimePolicy = .patternBFoundation,
        eligibility: any ModuleEligibilityProviding = AlwaysEligibleProvider(),
        environment: RuntimeEnvironment = .live
    ) {
        self.runtimeVersion = runtimeVersion
        self.platform = platform
        self.policy = policy
        self.eligibility = eligibility
        self.environment = environment
        let cloudGameCenterGateway = RuntimeCloudGameCenterGateway(environment: environment)
        self.cloudGameCenterGateway = cloudGameCenterGateway
        let opaqueResourceRegistry = RuntimeOpaqueResourceRegistry()
        self.opaqueResourceRegistry = opaqueResourceRegistry
        unlockFeedbackGateway = RuntimeUnlockFeedbackGateway(
            resources: opaqueResourceRegistry
        )
        contributionRegistry = RuntimeContributionRegistry(
            publishCapabilityID: RuneScribeCapabilities.contributionPublish,
            readCapabilityID: RuneScribeCapabilities.contributionRead,
            authorization: { descriptor, capability in
                policy.capabilities.allows(
                    capability,
                    for: descriptor.policyClass
                )
            },
            canonicalRules: RuntimeContributionCatalog.canonicalRules
        )
        let initialEntitlements = Self.initialEntitlementSnapshot(environment: environment)
        entitlementSnapshot = initialEntitlements
        lastObservedEntitlementSnapshot = initialEntitlements
        let dispatcher = RuntimeOperationDispatcher(policy: policy, environment: environment)
        self.dispatcher = dispatcher
        let moduleStateGateway = RuntimeModuleStateGateway(policy: policy)
        self.moduleStateGateway = moduleStateGateway
        let settingsGateway = RuntimeSettingsGateway(
            state: moduleStateGateway,
            environment: environment
        )
        self.settingsGateway = settingsGateway
        cloudGameCenterCoordinator = RuntimeCloudGameCenterCoordinator(
            stateGateway: moduleStateGateway,
            platformGateway: cloudGameCenterGateway,
            environment: environment,
            settingsGateway: settingsGateway
        )
        availabilityGateway = RuntimeAvailabilityGateway(environment: environment)
        progressionOutbox = RuntimeProgressionOutbox(
            state: moduleStateGateway,
            dispatcher: dispatcher,
            environment: environment
        )
        existingUserMigrationHandoff = RuntimeExistingUserMigrationHandoff(
            state: moduleStateGateway,
            dispatcher: dispatcher,
            environment: environment
        )
        let runtimeIOGateway = RuntimeIOGateway(
            policy: policy,
            environment: environment,
            operationContextAuthority: progressionOutbox
        )
        self.runtimeIOGateway = runtimeIOGateway
        hostIngress = RuntimeHostIngressRail(
            environment: environment,
            normalizeFile: { request in
                try await runtimeIOGateway.readHostInboundFile(request)
            }
        )
        startCoordinator = ImmediateRuntimeStartCoordinator()
    }

    init(
        runtimeVersion: SemanticVersion,
        platform: SupportedPlatform,
        policy: RuntimePolicy = .patternBFoundation,
        eligibility: any ModuleEligibilityProviding = AlwaysEligibleProvider(),
        environment: RuntimeEnvironment = .live,
        startCoordinator: any RuntimeStartCoordinating
    ) {
        self.runtimeVersion = runtimeVersion
        self.platform = platform
        self.policy = policy
        self.eligibility = eligibility
        self.environment = environment
        let cloudGameCenterGateway = RuntimeCloudGameCenterGateway(environment: environment)
        self.cloudGameCenterGateway = cloudGameCenterGateway
        let opaqueResourceRegistry = RuntimeOpaqueResourceRegistry()
        self.opaqueResourceRegistry = opaqueResourceRegistry
        unlockFeedbackGateway = RuntimeUnlockFeedbackGateway(
            resources: opaqueResourceRegistry
        )
        contributionRegistry = RuntimeContributionRegistry(
            publishCapabilityID: RuneScribeCapabilities.contributionPublish,
            readCapabilityID: RuneScribeCapabilities.contributionRead,
            authorization: { descriptor, capability in
                policy.capabilities.allows(
                    capability,
                    for: descriptor.policyClass
                )
            },
            canonicalRules: RuntimeContributionCatalog.canonicalRules
        )
        let initialEntitlements = Self.initialEntitlementSnapshot(environment: environment)
        entitlementSnapshot = initialEntitlements
        lastObservedEntitlementSnapshot = initialEntitlements
        let dispatcher = RuntimeOperationDispatcher(policy: policy, environment: environment)
        self.dispatcher = dispatcher
        let moduleStateGateway = RuntimeModuleStateGateway(policy: policy)
        self.moduleStateGateway = moduleStateGateway
        let settingsGateway = RuntimeSettingsGateway(
            state: moduleStateGateway,
            environment: environment
        )
        self.settingsGateway = settingsGateway
        cloudGameCenterCoordinator = RuntimeCloudGameCenterCoordinator(
            stateGateway: moduleStateGateway,
            platformGateway: cloudGameCenterGateway,
            environment: environment,
            settingsGateway: settingsGateway
        )
        availabilityGateway = RuntimeAvailabilityGateway(environment: environment)
        progressionOutbox = RuntimeProgressionOutbox(
            state: moduleStateGateway,
            dispatcher: dispatcher,
            environment: environment
        )
        existingUserMigrationHandoff = RuntimeExistingUserMigrationHandoff(
            state: moduleStateGateway,
            dispatcher: dispatcher,
            environment: environment
        )
        let runtimeIOGateway = RuntimeIOGateway(
            policy: policy,
            environment: environment,
            operationContextAuthority: progressionOutbox
        )
        self.runtimeIOGateway = runtimeIOGateway
        hostIngress = RuntimeHostIngressRail(
            environment: environment,
            normalizeFile: { request in
                try await runtimeIOGateway.readHostInboundFile(request)
            }
        )
        self.startCoordinator = startCoordinator
    }

    public func register(
        manifest: ModuleManifest,
        factory: AnyModuleFactory,
        themeDiscovery: ThemeDescriptor? = nil
    ) throws {
        guard registrations[manifest.moduleID] == nil,
              failedOptionalDescriptors[manifest.moduleID] == nil
        else {
            throw RuneScribeRuntimeError.duplicateModuleID(manifest.moduleID)
        }
        guard !entryPoints.contains(manifest.entryPoint) else {
            throw RuneScribeRuntimeError.duplicateEntryPoint(manifest.entryPoint)
        }
        guard !roles.contains(manifest.defaultRole) else {
            throw RuneScribeRuntimeError.duplicateRole(manifest.defaultRole)
        }

        try ModuleManifestValidator.validate(
            manifest: manifest,
            descriptor: factory.descriptor,
            runtimeVersion: runtimeVersion,
            platform: platform,
            policy: policy
        )

        try Self.validateThemeDiscovery(
            themeDiscovery,
            manifest: manifest,
            module: factory.descriptor
        )

        registrations[manifest.moduleID] = Registration(
            manifest: manifest,
            factory: factory,
            themeDiscovery: themeDiscovery
        )
        entryPoints.insert(manifest.entryPoint)
        roles.insert(manifest.defaultRole)
        moduleStates[manifest.moduleID] = .registered
    }

    public func register(
        manifestData: Data,
        factory: AnyModuleFactory,
        themeDiscovery: ThemeDescriptor? = nil
    ) throws {
        try ModuleManifestValidator.validateCriticality(factory.descriptor)
        let moduleID = factory.descriptor.moduleID
        guard registrations[moduleID] == nil,
              failedOptionalDescriptors[moduleID] == nil
        else {
            throw RuneScribeRuntimeError.duplicateModuleID(moduleID)
        }
        do {
            let manifest = try ModuleManifestDecoder.decode(manifestData)
            try register(
                manifest: manifest,
                factory: factory,
                themeDiscovery: themeDiscovery
            )
        } catch {
            guard factory.descriptor.criticality == .optional else {
                throw error
            }
            recordOptionalRegistrationFailure(
                factory.descriptor,
                themeDiscovery: themeDiscovery
            )
        }
    }

    public func register(
        manifestResource: ApplicationResource,
        expectedSHA256: Data,
        maximumByteCount: Int,
        factory: AnyModuleFactory,
        themeDiscovery: ThemeDescriptor? = nil
    ) async throws {
        try ModuleManifestValidator.validateCriticality(factory.descriptor)
        let moduleID = factory.descriptor.moduleID
        guard registrations[moduleID] == nil,
              failedOptionalDescriptors[moduleID] == nil
        else {
            throw RuneScribeRuntimeError.duplicateModuleID(moduleID)
        }
        do {
            let manifestData = try await runtimeIOGateway
                .readHostVerifiedApplicationResource(
                    manifestResource,
                    expectedSHA256: expectedSHA256,
                    maximumByteCount: maximumByteCount,
                    descriptor: factory.descriptor
                )
            try register(
                manifestData: manifestData,
                factory: factory,
                themeDiscovery: themeDiscovery
            )
        } catch {
            guard factory.descriptor.criticality == .optional else {
                throw error
            }
            recordOptionalRegistrationFailure(
                factory.descriptor,
                themeDiscovery: themeDiscovery
            )
        }
    }

    private func recordOptionalRegistrationFailure(
        _ descriptor: ModuleDescriptor,
        themeDiscovery: ThemeDescriptor? = nil
    ) {
        failedOptionalDescriptors[descriptor.moduleID] = descriptor
        failedOptionalThemeDiscoveries[descriptor.moduleID] = themeDiscovery
        moduleStates[descriptor.moduleID] = .failed
    }

    private static func validateThemeDiscovery(
        _ discovery: ThemeDescriptor?,
        manifest: ModuleManifest,
        module: ModuleDescriptor
    ) throws {
        guard let discovery else { return }
        try RuntimeContributionCatalog.validateThemeDescriptor(
            discovery,
            RuntimeThemeContributionCatalog.key(for: discovery.codex.id),
            module
        )
        guard module.policyClass == RuneScribePolicyClasses.themeProvider,
              manifest.effectivePolicyClass == RuneScribePolicyClasses.themeProvider
        else {
            throw RuntimeContributionRegistryError.canonicalIdentityMismatch(
                RuntimeThemeContributionCatalog.key(for: discovery.codex.id)
            )
        }
        let requirement = manifest.entitlementRequirement
        switch discovery.criticality {
        case .requiredBase:
            guard requirement?.kind == .always,
                  requirement?.identifier == RuneScribeUnlockIDs.norseCodex
            else {
                throw RuntimeContributionRegistryError.canonicalCriticalityMismatch(
                    RuntimeThemeContributionCatalog.key(for: discovery.codex.id)
                )
            }
        case .optional:
            guard requirement?.kind == .earned,
                  requirement?.identifier == discovery.codex.entitlementID
            else {
                throw RuntimeContributionRegistryError.canonicalCriticalityMismatch(
                    RuntimeThemeContributionCatalog.key(for: discovery.codex.id)
                )
            }
        }
    }

    private func authorizePlatformAdapterInstallation(
        _ serviceID: ServiceIdentifier,
        expected: ServiceIdentifier
    ) throws {
        guard status == .idle || status == .stopped || status == .failed else {
            throw RuneScribeRuntimeError.runtimeBusy
        }
        guard serviceID == expected,
              let rule = policy.services.rule(for: serviceID),
              rule.allowsPublisher(role: RuneScribeRoles.applicationHost)
        else {
            throw RuneScribeRuntimeError.hostServiceAccessDenied(serviceID)
        }
    }

    public func installPlatformAdapter(_ value: any SecureValueStore, for key: ServiceKey<any SecureValueStore>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.secureValueStore); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ProtectedFileStore, for key: ServiceKey<any ProtectedFileStore>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.protectedFileStore); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any InboundFileReader, for key: ServiceKey<any InboundFileReader>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.inboundFileReader); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ShareArtifactStore, for key: ServiceKey<any ShareArtifactStore>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.shareArtifactStore); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any SharePresentationProviding, for key: ServiceKey<any SharePresentationProviding>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.sharePresentation); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ApplicationResourceLocator, for key: ServiceKey<any ApplicationResourceLocator>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.applicationResourceLocator); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any SystemFontRegistrar, for key: ServiceKey<any SystemFontRegistrar>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.systemFontRegistrar); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ContactAccessService, for key: ServiceKey<any ContactAccessService>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.contactAccess); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ClipboardReading, for key: ServiceKey<any ClipboardReading>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.clipboardRead); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ClipboardWriting, for key: ServiceKey<any ClipboardWriting>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.clipboardWrite); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any ClockProviding, for key: ServiceKey<any ClockProviding>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.clock); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(_ value: any UUIDProviding, for key: ServiceKey<any UUIDProviding>) async throws { try authorizePlatformAdapterInstallation(key.identifier, expected: RuneScribeServiceIDs.uuid); try await platformBridge.register(value); await runtimeIOGateway.install(value) }
    public func installPlatformAdapter(
        _ value: any CloudSyncTransport,
        for key: ServiceKey<any CloudSyncTransport>
    ) async throws {
        try authorizePlatformAdapterInstallation(
            key.identifier,
            expected: RuneScribeServiceIDs.cloudSyncTransport
        )
        try await cloudGameCenterGateway.install(value)
    }
    public func installPlatformAdapter(
        _ value: any GameCenterReporting,
        for key: ServiceKey<any GameCenterReporting>
    ) async throws {
        try authorizePlatformAdapterInstallation(
            key.identifier,
            expected: RuneScribeServiceIDs.gameCenterReporting
        )
        try await cloudGameCenterGateway.install(value)
    }
    public func installPlatformAdapter(
        _ value: any UnlockFeedbackProviding,
        for key: ServiceKey<any UnlockFeedbackProviding>
    ) async throws {
        try authorizePlatformAdapterInstallation(
            key.identifier,
            expected: RuneScribeUnlockFeedback.serviceID
        )
        try await unlockFeedbackGateway.install(value)
    }
    public func installPlatformAdapter(
        _ value: any ModuleStateStore,
        for key: ServiceKey<any ModuleStateStore>
    ) async throws {
        try authorizePlatformAdapterInstallation(
            key.identifier,
            expected: RuneScribeServiceIDs.moduleStateStore
        )
        try await platformBridge.register(value)
        try await moduleStateGateway.install(value)
    }

    public func installStandardPort(
        _ adapter: RuntimeRootPresentationHostAdapter,
        for key: RuntimeRootPresentationPortKey
    ) async throws {
        guard status == .idle || status == .stopped || status == .failed else {
            throw RuneScribeRuntimeError.runtimeBusy
        }
        try await rootPresentationGateway.install(adapter, for: key)
    }

    @_spi(RuntimeOperationAuthority)
    public func cloudSyncClient() async throws -> RuntimeCloudSyncClient {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await cloudGameCenterGateway.cloudClient()
    }

    @_spi(RuntimeOperationAuthority)
    public func gameCenterClient() async throws -> RuntimeGameCenterClient {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return try await cloudGameCenterGateway.gameCenterClient()
    }

    @_spi(RuntimeOperationAuthority)
    public func submitCloudProgressionProjection(
        _ projection: RuntimeCloudProgressionProjection
    ) async throws {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try await cloudGameCenterCoordinator.submitCloudProjection(projection)
    }

    @_spi(RuntimeOperationAuthority)
    public func pendingCloudProgressionMerge()
        async throws -> RuntimeCloudProgressionMergeDelivery?
    {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        return await cloudGameCenterCoordinator.pendingCloudMergeDelivery()
    }

    @_spi(RuntimeOperationAuthority)
    public func acknowledgeCloudProgressionMerge(
        deliveryID: UUID,
        updatedProjection: RuntimeCloudProgressionProjection
    ) async throws {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try await cloudGameCenterCoordinator.acknowledgeCloudMerge(
            deliveryID: deliveryID,
            updatedProjection: updatedProjection
        )
    }

    @_spi(RuntimeOperationAuthority)
    public func submitGameCenterCandidates(
        _ candidates: [GameCenterReportCandidate]
    ) async throws {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try await cloudGameCenterCoordinator.submitGameCenterCandidates(candidates)
    }

    @_spi(RuntimeOperationAuthority)
    public func rebindCloudAccount() async throws {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        try await cloudGameCenterCoordinator.rebindCloudAccount()
    }

    @_spi(RuntimeOperationAuthority)
    public func wakeExternalServices(
        _ reason: RuntimeExternalServiceWakeReason
    ) async {
        guard status == .running else { return }
        await cloudGameCenterCoordinator.wake(reason)
    }

    @_spi(RuntimeOperationAuthority)
    public func runExternalServiceMaintenance() async throws {
        guard status == .running else { throw RuneScribeRuntimeError.runtimeNotRunning }
        await cloudGameCenterCoordinator.runPendingWork()
    }

    @discardableResult
    public nonisolated func submit(
        _ input: ExternalInputEnvelope
    ) -> InboundInputDispositionDTO {
        hostIngress.submit(input)
    }

    @discardableResult
    public nonisolated func submit(
        contentsOf inputs: [ExternalInputEnvelope]
    ) -> [InboundInputDispositionDTO] {
        hostIngress.submit(contentsOf: inputs)
    }

    public nonisolated var hostIngressSnapshot: RuntimeHostIngressSnapshot {
        hostIngress.snapshot
    }

    public nonisolated func observeHostIngressFailures(
        _ observer: @escaping @Sendable (RuntimeHostIngressFailure) -> Void
    ) {
        hostIngress.observeFailures(observer)
    }

    public func start() async throws {
        if status == .running {
            return
        }
        guard status != .starting, status != .stopping else {
            throw RuneScribeRuntimeError.runtimeBusy
        }

        status = .starting
        stopRequestedWhileStarting = false
        cancelEntitlementObservation()
        await startCoordinator.beforeInfrastructureActivation()
        if stopRequestedWhileStarting {
            await finishInterruptedStart()
            return
        }
        _ = await dispatcher.beginRuntimeStart()
        if stopRequestedWhileStarting {
            await finishInterruptedStart()
            return
        }
        _ = await platformBridge.activateRuntime()
        await cloudGameCenterGateway.activateRuntime()
        _ = await moduleStateGateway.activateRuntime()
        await cloudGameCenterCoordinator.activateRuntime()
        await settingsGateway.activateRuntime()
        await availabilityGateway.activateRuntime(
            optionalModules: optionalAvailabilitySnapshots(),
            themeProviders: themeProviderAvailabilitySnapshots(),
            entitlementSnapshot: entitlementSnapshot
        )
        await progressionOutbox.activateRuntime()
        await existingUserMigrationHandoff.activateRuntime()
        _ = await runtimeIOGateway.activateRuntime()
        _ = await rootPresentationGateway.activateRuntime()
        _ = await contributionRegistry.activateRuntime()
        _ = await opaqueResourceRegistry.activateRuntime()
        if stopRequestedWhileStarting {
            await finishInterruptedStart()
            return
        }
        activeUIModuleID = nil
        activationOrder = []

        do {
            let eligible = try await eligibleRegistrations()
            for registration in eligible {
                await dispatcher.registerModule(registration.factory.descriptor)
            }
            await dispatcher.registerHostSource(
                consumedEndpoints: RuntimeApplicationEndpointCatalog.ingressEndpointIDs
            )
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            let uiModules = eligible.filter { $0.manifest.moduleType == .ui }
            guard !uiModules.isEmpty else {
                throw RuneScribeRuntimeError.noEligibleUIModule
            }
            guard uiModules.count == 1 else {
                throw RuneScribeRuntimeError.multipleEligibleUIModules(
                    uiModules.map(\.manifest.moduleID).sorted()
                )
            }

            activeUIModuleID = uiModules[0].manifest.moduleID
            let plan = try activationPlan(for: eligible)
            for registration in plan {
                do {
                    try await activate(registration)
                } catch {
                    guard registration.factory.descriptor.criticality == .optional else {
                        throw error
                    }
                }
                await publishAvailabilitySnapshot()
                if stopRequestedWhileStarting {
                    await finishInterruptedStart()
                    return
                }
            }
            await dispatcher.markRuntimeRunning()
            await progressionOutbox.runtimeDidStart()
            await existingUserMigrationHandoff.runtimeDidStart()
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            await startCoordinator.afterRuntimeMarkedRunningBeforeIngressActivation()
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            hostIngress.activate { [dispatcher] input in
                try await dispatcher.dispatchHostIngress(input)
            }
            await hostIngress.flush()
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            hostIngress.noteSuccessfulActivation()
            status = .running
            await publishAvailabilitySnapshot()
            startEntitlementObservation()
            await reconcileEligibleOptionalModules()
        } catch {
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            await stopActivatedModules(markFailed: true)
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            activeUIModuleID = nil
            activationOrder = []
            status = .failed
            cancelEntitlementObservation()
            hostIngress.suspend()
            await dispatcher.beginRuntimeStop()
            await runtimeIOGateway.deactivateRuntime()
            await cloudGameCenterCoordinator.deactivateRuntime()
            await cloudGameCenterGateway.deactivateRuntime()
            await progressionOutbox.deactivateRuntime()
            await existingUserMigrationHandoff.deactivateRuntime()
            await settingsGateway.deactivateRuntime()
            await availabilityGateway.deactivateRuntime()
            await moduleStateGateway.deactivateRuntime()
            await platformBridge.deactivateRuntime()
            await rootPresentationGateway.deactivateRuntime()
            await contributionRegistry.deactivateRuntime()
            await opaqueResourceRegistry.deactivateRuntime()
            resumeStopWaiters()
            throw error
        }
    }

    public func stop() async {
        if status == .idle || status == .stopped {
            cancelEntitlementObservation()
            hostIngress.suspend()
            hostIngress.resumeAdmissions()
            status = .stopped
            return
        }
        if status == .starting {
            stopRequestedWhileStarting = true
            status = .stopping
            cancelEntitlementObservation()
            hostIngress.quiesceAdmissions()
            hostIngress.suspend()
            await dispatcher.beginRuntimeStop()
            await runtimeIOGateway.deactivateRuntime()
            await cloudGameCenterCoordinator.deactivateRuntime()
            await cloudGameCenterGateway.deactivateRuntime()
            await progressionOutbox.deactivateRuntime()
            await existingUserMigrationHandoff.deactivateRuntime()
            await settingsGateway.deactivateRuntime()
            await availabilityGateway.deactivateRuntime()
            await moduleStateGateway.deactivateRuntime()
            await platformBridge.deactivateRuntime()
            await rootPresentationGateway.deactivateRuntime()
            await contributionRegistry.deactivateRuntime()
            await opaqueResourceRegistry.deactivateRuntime()
            await hostIngress.flush()
            if status == .stopped {
                return
            }
            await waitForStopCompletion()
            return
        }
        if status == .stopping {
            await waitForStopCompletion()
            return
        }

        status = .stopping
        cancelEntitlementObservation()
        hostIngress.quiesceAdmissions()
        await dispatcher.beginRuntimeQuiesce()
        await startCoordinator.afterClientQuiesceBeforeIngressDrain()
        await hostIngress.flush()
        hostIngress.suspend()
        await dispatcher.beginRuntimeStop()
        await runtimeIOGateway.deactivateRuntime()
        await cloudGameCenterCoordinator.deactivateRuntime()
        await cloudGameCenterGateway.deactivateRuntime()
        await progressionOutbox.deactivateRuntime()
        await existingUserMigrationHandoff.deactivateRuntime()
        await settingsGateway.deactivateRuntime()
        await availabilityGateway.deactivateRuntime()
        await moduleStateGateway.deactivateRuntime()
        await platformBridge.deactivateRuntime()
        await rootPresentationGateway.deactivateRuntime()
        await contributionRegistry.deactivateRuntime()
        await opaqueResourceRegistry.deactivateRuntime()
        await hostIngress.flush()
        await stopActivatedModules(markFailed: false)
        activeUIModuleID = nil
        hostIngress.resumeAdmissions()
        status = .stopped
        resumeStopWaiters()
    }

    public func snapshot() async -> RuntimeSnapshot {
        let cloudGameCenterStatus = await cloudGameCenterCoordinator
            .statusSnapshotIncludingInactive()
        return RuntimeSnapshot(
            status: status,
            moduleStates: moduleStates,
            activationOrder: activationOrder,
            activeUIModuleID: activeUIModuleID,
            entitlementSnapshot: entitlementSnapshot,
            cloudGameCenterStatus: cloudGameCenterStatus
        )
    }

    func optionalAvailabilitySnapshots()
        -> [RuntimeOptionalModuleAvailabilitySnapshot]
    {
        var snapshots: [RuntimeOptionalModuleAvailabilitySnapshot] =
            registrations.values.compactMap { registration in
            let descriptor = registration.factory.descriptor
            guard descriptor.criticality == .optional else { return nil }
            return RuntimeOptionalModuleAvailabilitySnapshot(
                moduleID: descriptor.moduleID,
                role: descriptor.role,
                lifecycleState: moduleStates[descriptor.moduleID] ?? .registered
            )
        }
        snapshots.append(contentsOf: failedOptionalDescriptors.values.map { descriptor in
            RuntimeOptionalModuleAvailabilitySnapshot(
                moduleID: descriptor.moduleID,
                role: descriptor.role,
                lifecycleState: .failed
            )
        })
        return snapshots.sorted { $0.moduleID < $1.moduleID }
    }

    private func publishAvailabilitySnapshot() async {
        await availabilityGateway.update(
            optionalModules: optionalAvailabilitySnapshots(),
            themeProviders: themeProviderAvailabilitySnapshots(),
            entitlementSnapshot: entitlementSnapshot
        )
    }

    private func themeProviderAvailabilitySnapshots()
        -> [RuntimeThemeProviderAvailabilitySnapshot]
    {
        var snapshots = registrations.values.compactMap { registration in
            registration.themeDiscovery.map {
                RuntimeThemeProviderAvailabilitySnapshot(
                    descriptor: $0,
                    lifecycleState: moduleStates[registration.manifest.moduleID]
                        ?? .registered
                )
            }
        }
        snapshots.append(contentsOf: failedOptionalThemeDiscoveries.values.map {
            RuntimeThemeProviderAvailabilitySnapshot(
                descriptor: $0,
                lifecycleState: .failed
            )
        })
        return snapshots.sorted { $0.descriptor.codex.id < $1.descriptor.codex.id }
    }

    public func reconcileEntitlements(
        _ incoming: ProgressionEntitlementSnapshotDTO
    ) async throws {
        guard incoming.revision >= lastObservedEntitlementSnapshot.revision else {
            return
        }
        if incoming.revision == lastObservedEntitlementSnapshot.revision {
            guard Self.hasSameEntitlementTruth(
                incoming,
                lastObservedEntitlementSnapshot
            ) else {
                throw RuneScribeRuntimeError.entitlementRevisionConflict(incoming.revision)
            }
            lastObservedEntitlementSnapshot = incoming
            return
        }

        let included = Set(entitlementSnapshot.includedUnlockIDs)
            .union(incoming.includedUnlockIDs)
            .union([RuneScribeUnlockIDs.norseCodex])
        let earned = Set(entitlementSnapshot.earnedUnlockIDs)
            .union(incoming.earnedUnlockIDs)
        entitlementSnapshot = try ProgressionEntitlementSnapshotDTO(
            revision: incoming.revision,
            capturedAt: max(entitlementSnapshot.capturedAt, incoming.capturedAt),
            includedUnlockIDs: included.sorted(),
            earnedUnlockIDs: earned.sorted()
        )
        lastObservedEntitlementSnapshot = incoming
        await publishAvailabilitySnapshot()

        guard status == .running else { return }
        await reconcileEligibleOptionalModules()
        await publishAvailabilitySnapshot()
    }

    private static func hasSameEntitlementTruth(
        _ lhs: ProgressionEntitlementSnapshotDTO,
        _ rhs: ProgressionEntitlementSnapshotDTO
    ) -> Bool {
        lhs.revision == rhs.revision &&
            Set(lhs.includedUnlockIDs) == Set(rhs.includedUnlockIDs) &&
            Set(lhs.earnedUnlockIDs) == Set(rhs.earnedUnlockIDs)
    }

    public func callLedgerSnapshot() async -> [RuntimeCallLedgerRecord] {
        await dispatcher.ledgerSnapshot()
    }

    private func eligibleRegistrations() async throws -> [Registration] {
        var result: [Registration] = []
        for registration in registrations.values.sorted(by: registrationOrder) {
            moduleStates[registration.manifest.moduleID] = .validated
            if await isEligible(registration) {
                moduleStates[registration.manifest.moduleID] = .eligible
                result.append(registration)
            } else if registration.factory.descriptor.criticality == .required {
                moduleStates[registration.manifest.moduleID] = .failed
                throw RuneScribeRuntimeError.activationFailed(
                    registration.manifest.moduleID
                )
            }
        }
        return result
    }

    private func isEligible(_ registration: Registration) async -> Bool {
        guard await eligibility.isEligible(registration.manifest) else {
            return false
        }
        guard let requirement = registration.manifest.entitlementRequirement else {
            return true
        }
        switch requirement.kind {
        case .always:
            return true
        case .earned:
            return entitlementSnapshot.earnedUnlockIDs.contains(requirement.identifier)
        case .purchase, .composite:
            return false
        }
    }

    private func reconcileEligibleOptionalModules() async {
        let activeIDs = Set(activeModules.keys)
        var candidates: [Registration] = []

        for registration in registrations.values.sorted(by: registrationOrder) {
            let descriptor = registration.factory.descriptor
            guard descriptor.criticality == .optional,
                  !activeIDs.contains(descriptor.moduleID),
                  moduleStates[descriptor.moduleID] != .failed
            else { continue }

            moduleStates[descriptor.moduleID] = .validated
            if await isEligible(registration) {
                moduleStates[descriptor.moduleID] = .eligible
                candidates.append(registration)
                await dispatcher.registerModule(descriptor)
            }
        }

        let activeRoles = Set(activeModules.values.map { $0.module.descriptor.role })
        guard let plan = try? activationPlan(
            for: candidates,
            satisfiedRoles: activeRoles
        ) else { return }

        for registration in plan {
            do {
                try await activate(registration)
                if registration.factory.descriptor.role == RuneScribeRoles.progression {
                    await progressionOutbox.progressionDidActivate()
                    await existingUserMigrationHandoff.progressionDidActivate()
                    startEntitlementObservation()
                }
            } catch {}
        }
    }

    private func startEntitlementObservation() {
        cancelEntitlementObservation()
        let dispatcher = dispatcher
        entitlementObservationTask = Task { [weak self] in
            do {
                let stream = try await dispatcher.progressionEntitlementStream()
                for await envelope in stream {
                    guard !Task.isCancelled else { return }
                    try await self?.reconcileEntitlements(envelope.payload)
                }
            } catch {}
        }
    }

    private func cancelEntitlementObservation() {
        entitlementObservationTask?.cancel()
        entitlementObservationTask = nil
    }

    private static func initialEntitlementSnapshot(
        environment: RuntimeEnvironment
    ) -> ProgressionEntitlementSnapshotDTO {
        try! ProgressionEntitlementSnapshotDTO(
            revision: 0,
            capturedAt: environment.now(),
            includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
            earnedUnlockIDs: []
        )
    }

    private func activationPlan(
        for eligible: [Registration],
        satisfiedRoles: Set<ModuleRole> = []
    ) throws -> [Registration] {
        var candidates = eligible

        while true {
            let availableRoles = satisfiedRoles.union(candidates.map(\.manifest.defaultRole))
            let missingDependencies = candidates.compactMap { registration -> (Registration, ModuleRole)? in
                guard let role = registration.factory.descriptor.requiredModuleRoles
                    .sorted()
                    .first(where: { !availableRoles.contains($0) })
                else { return nil }
                return (registration, role)
            }
            guard !missingDependencies.isEmpty else { break }

            if let requiredFailure = missingDependencies.first(where: {
                $0.0.factory.descriptor.criticality == .required
            }) {
                throw RuneScribeRuntimeError.missingRequiredRole(
                    moduleID: requiredFailure.0.manifest.moduleID,
                    role: requiredFailure.1
                )
            }

            let failedIDs = Set(missingDependencies.map { $0.0.manifest.moduleID })
            for moduleID in failedIDs {
                moduleStates[moduleID] = .failed
            }
            candidates.removeAll { failedIDs.contains($0.manifest.moduleID) }
        }

        let byRole = Dictionary(
            uniqueKeysWithValues: candidates.map { ($0.manifest.defaultRole, $0) }
        )
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.manifest.moduleID, $0) })
        var dependencies: [ModuleIdentifier: Set<ModuleIdentifier>] = [:]

        for registration in candidates {
            var moduleDependencies = Set<ModuleIdentifier>()
            for role in registration.factory.descriptor.requiredModuleRoles.sorted() {
                if satisfiedRoles.contains(role) {
                    continue
                }
                guard let dependency = byRole[role] else {
                    throw RuneScribeRuntimeError.missingRequiredRole(
                        moduleID: registration.manifest.moduleID,
                        role: role
                    )
                }
                moduleDependencies.insert(dependency.manifest.moduleID)
            }
            dependencies[registration.manifest.moduleID] = moduleDependencies
        }

        var plan: [Registration] = []
        while !dependencies.isEmpty {
            let ready = dependencies
                .filter { $0.value.isEmpty }
                .map(\.key)
                .sorted { lhs, rhs in
                    guard let lhsRegistration = byID[lhs],
                          let rhsRegistration = byID[rhs]
                    else { return lhs < rhs }
                    let lhsPriority = activationPriority(lhsRegistration)
                    let rhsPriority = activationPriority(rhsRegistration)
                    return lhsPriority == rhsPriority ? lhs < rhs : lhsPriority < rhsPriority
                }
            guard !ready.isEmpty else {
                let cycleIDs = dependencies.keys.sorted()
                let includesRequired = cycleIDs.contains {
                    byID[$0]?.factory.descriptor.criticality == .required
                }
                guard !includesRequired else {
                    throw RuneScribeRuntimeError.dependencyCycle(cycleIDs)
                }
                for moduleID in cycleIDs {
                    moduleStates[moduleID] = .failed
                }
                break
            }
            for moduleID in ready {
                guard let registration = byID[moduleID] else { continue }
                plan.append(registration)
                dependencies.removeValue(forKey: moduleID)
                for dependencyID in dependencies.keys {
                    dependencies[dependencyID]?.remove(moduleID)
                }
            }
        }
        return plan
    }

    private func activationPriority(_ registration: Registration) -> Int {
        switch (
            registration.factory.descriptor.criticality,
            registration.manifest.moduleType
        ) {
        case (.required, .service): 0
        case (.optional, .service): 1
        case (.required, .ui): 2
        case (.optional, .ui): 3
        }
    }

    private func activate(_ registration: Registration) async throws {
        let moduleID = registration.manifest.moduleID
        moduleStates[moduleID] = .activating

        for requiredRole in registration.factory.descriptor.requiredModuleRoles.sorted() {
            let roleIsActive = activeModules.values.contains {
                $0.module.descriptor.role == requiredRole
            }
            guard roleIsActive else {
                moduleStates[moduleID] = .failed
                await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
                throw RuneScribeRuntimeError.activationFailed(moduleID)
            }
        }

        for serviceID in registration.factory.descriptor.requiredServices.sorted() {
            guard await platformBridge.contains(serviceID) else {
                moduleStates[moduleID] = .failed
                await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
                throw RuneScribeRuntimeError.activationFailed(moduleID)
            }
        }

        let module: any RuneScribeModule
        do {
            module = try registration.factory.makeModule()
        } catch {
            moduleStates[moduleID] = .failed
            await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
            throw RuneScribeRuntimeError.activationFailed(moduleID)
        }
        guard module.descriptor == registration.factory.descriptor else {
            moduleStates[moduleID] = .failed
            await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
            throw RuneScribeRuntimeError.factoryDescriptorMismatch(moduleID)
        }

        let moduleGeneration: UInt64
        do {
            moduleGeneration = try await dispatcher.beginActivation(moduleID: moduleID)
        } catch {
            moduleStates[moduleID] = .failed
            await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
            throw RuneScribeRuntimeError.activationFailed(moduleID)
        }

        let lease = ModuleContextLease(moduleID: moduleID)
        do {
            try await runtimeIOGateway.activateModule(
                descriptor: registration.factory.descriptor,
                generation: moduleGeneration
            )
            try await moduleStateGateway.activateModule(
                descriptor: registration.factory.descriptor,
                generation: moduleGeneration
            )
            try await rootPresentationGateway.activateModule(
                descriptor: registration.factory.descriptor,
                generation: moduleGeneration
            )
            try await contributionRegistry.activateModule(
                descriptor: registration.factory.descriptor,
                generation: moduleGeneration
            )
            try await opaqueResourceRegistry.activateModule(
                descriptor: registration.factory.descriptor,
                generation: moduleGeneration
            )
        } catch {
            await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
            await runtimeIOGateway.invalidateModule(
                moduleID,
                generation: moduleGeneration
            )
            await moduleStateGateway.invalidateModule(
                moduleID,
                generation: moduleGeneration
            )
            await rootPresentationGateway.invalidateModule(
                moduleID,
                generation: moduleGeneration
            )
            await contributionRegistry.invalidateModule(
                moduleID,
                generation: moduleGeneration
            )
            await opaqueResourceRegistry.invalidateModule(
                moduleID,
                generation: moduleGeneration
            )
            moduleStates[moduleID] = .failed
            throw RuneScribeRuntimeError.activationFailed(moduleID)
        }
        let context = ModuleContext(
            descriptor: registration.factory.descriptor,
            runtimePlatform: platform,
            policy: policy,
            events: events,
            messages: messages,
            dispatcher: dispatcher,
            moduleGeneration: moduleGeneration,
            runtimeIOGateway: runtimeIOGateway,
            runtimeIOGeneration: await runtimeIOGateway.currentGeneration(),
            moduleStateGateway: moduleStateGateway,
            moduleStateGeneration: await moduleStateGateway.currentGeneration(),
            settingsGateway: settingsGateway,
            availabilityGateway: availabilityGateway,
            unlockFeedbackGateway: unlockFeedbackGateway,
            progressionOutbox: progressionOutbox,
            existingUserMigrationHandoff: existingUserMigrationHandoff,
            cloudGameCenterCoordinator: cloudGameCenterCoordinator,
            rootPresentationGateway: rootPresentationGateway,
            rootPresentationGeneration: await rootPresentationGateway.currentGeneration(),
            contributionRegistry: contributionRegistry,
            contributionRegistryGeneration: await contributionRegistry.currentGeneration(),
            opaqueResourceRegistry: opaqueResourceRegistry,
            opaqueResourceRegistryGeneration: await opaqueResourceRegistry.currentGeneration(),
            environment: environment,
            lease: lease
        )

        do {
            try await module.start(context: context)
            guard await dispatcher.publishedEndpointsAvailable(
                moduleID: moduleID,
                generation: moduleGeneration,
                endpointIDs: registration.factory.descriptor.publishedEndpoints
            ) else {
                throw RuneScribeRuntimeError.activationFailed(moduleID)
            }
            try await dispatcher.markActive(
                moduleID: moduleID,
                generation: moduleGeneration
            )
        } catch {
            await dispatcher.invalidateModule(moduleID: moduleID, failed: true)
            await context.invalidate()
            await module.stop()
            moduleStates[moduleID] = .failed
            throw RuneScribeRuntimeError.activationFailed(moduleID)
        }

        activeModules[moduleID] = ActiveModule(module: module, context: context)
        activationOrder.append(moduleID)
        moduleStates[moduleID] = .active
    }

    private func stopActivatedModules(markFailed: Bool) async {
        for moduleID in activationOrder.reversed() {
            guard let active = activeModules[moduleID] else { continue }
            moduleStates[moduleID] = .stopping
            await dispatcher.invalidateModule(moduleID: moduleID, failed: markFailed)
            await active.context.invalidate()
            await active.module.stop()
            moduleStates[moduleID] = markFailed ? .failed : .stopped
        }
        activeModules.removeAll()
    }

    private func finishInterruptedStart() async {
        status = .stopping
        cancelEntitlementObservation()
        hostIngress.suspend()
        await dispatcher.beginRuntimeStop()
        await runtimeIOGateway.deactivateRuntime()
        await cloudGameCenterCoordinator.deactivateRuntime()
        await cloudGameCenterGateway.deactivateRuntime()
        await progressionOutbox.deactivateRuntime()
        await existingUserMigrationHandoff.deactivateRuntime()
        await settingsGateway.deactivateRuntime()
        await availabilityGateway.deactivateRuntime()
        await moduleStateGateway.deactivateRuntime()
        await platformBridge.deactivateRuntime()
        await rootPresentationGateway.deactivateRuntime()
        await contributionRegistry.deactivateRuntime()
        await opaqueResourceRegistry.deactivateRuntime()
        await hostIngress.flush()
        await stopActivatedModules(markFailed: false)
        activeUIModuleID = nil
        activationOrder = []
        stopRequestedWhileStarting = false
        hostIngress.resumeAdmissions()
        status = .stopped
        resumeStopWaiters()
    }

    private func waitForStopCompletion() async {
        await withCheckedContinuation { continuation in
            stopWaiters.append(continuation)
        }
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func registrationOrder(_ lhs: Registration, _ rhs: Registration) -> Bool {
        lhs.manifest.moduleID < rhs.manifest.moduleID
    }
}
