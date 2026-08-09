import Foundation
import RuneScribeContracts

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

    public init(
        status: RuntimeStatus,
        moduleStates: [ModuleIdentifier: ModuleLifecycleState],
        activationOrder: [ModuleIdentifier],
        activeUIModuleID: ModuleIdentifier?
    ) {
        self.status = status
        self.moduleStates = moduleStates
        self.activationOrder = activationOrder
        self.activeUIModuleID = activeUIModuleID
    }
}

public actor RuneScribeRuntime {
    private struct Registration: Sendable {
        let manifest: ModuleManifest
        let factory: AnyModuleFactory
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
    private let platformBridge = RuntimePlatformBridge()
    private let events = RuntimeEventBus()
    private let messages = DirectedMessageRouter()

    private var registrations: [ModuleIdentifier: Registration] = [:]
    private var entryPoints: Set<String> = []
    private var roles: Set<ModuleRole> = []
    private var moduleStates: [ModuleIdentifier: ModuleLifecycleState] = [:]
    private var activeModules: [ModuleIdentifier: ActiveModule] = [:]
    private var activationOrder: [ModuleIdentifier] = []
    private var activeUIModuleID: ModuleIdentifier?
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
        dispatcher = RuntimeOperationDispatcher(policy: policy, environment: environment)
    }

    public func register(
        manifest: ModuleManifest,
        factory: AnyModuleFactory
    ) throws {
        guard registrations[manifest.moduleID] == nil else {
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

        registrations[manifest.moduleID] = Registration(manifest: manifest, factory: factory)
        entryPoints.insert(manifest.entryPoint)
        roles.insert(manifest.defaultRole)
        moduleStates[manifest.moduleID] = .registered
    }

    private func authorizeHostRegistration(
        _ serviceID: ServiceIdentifier,
        expected: ServiceIdentifier
    ) throws {
        guard status == .idle || status == .stopped || status == .failed else {
            throw RuneScribeRuntimeError.runtimeBusy
        }
        guard serviceID == expected,
              let rule = policy.services.rule(for: serviceID),
              rule.publisherRoles.contains(RuneScribeRoles.applicationHost)
        else {
            throw RuneScribeRuntimeError.hostServiceAccessDenied(serviceID)
        }
    }

    public func registerHostService(_ value: any SecureValueStore, for key: ServiceKey<any SecureValueStore>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.secureValueStore); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ProtectedFileStore, for key: ServiceKey<any ProtectedFileStore>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.protectedFileStore); try await platformBridge.register(value) }
    public func registerHostService(_ value: any InboundFileReader, for key: ServiceKey<any InboundFileReader>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.inboundFileReader); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ShareArtifactStore, for key: ServiceKey<any ShareArtifactStore>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.shareArtifactStore); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ApplicationResourceLocator, for key: ServiceKey<any ApplicationResourceLocator>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.applicationResourceLocator); try await platformBridge.register(value) }
    public func registerHostService(_ value: any SystemFontRegistrar, for key: ServiceKey<any SystemFontRegistrar>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.systemFontRegistrar); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ContactAccessService, for key: ServiceKey<any ContactAccessService>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.contactAccess); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ClipboardReading, for key: ServiceKey<any ClipboardReading>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.clipboardRead); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ClipboardWriting, for key: ServiceKey<any ClipboardWriting>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.clipboardWrite); try await platformBridge.register(value) }
    public func registerHostService(_ value: any ClockProviding, for key: ServiceKey<any ClockProviding>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.clock); try await platformBridge.register(value) }
    public func registerHostService(_ value: any UUIDProviding, for key: ServiceKey<any UUIDProviding>) async throws { try authorizeHostRegistration(key.identifier, expected: RuneScribeServiceIDs.uuid); try await platformBridge.register(value) }

    public func resolveHostService(
        _ key: ServiceKey<any RuneScribeInboundInputService>
    ) async throws -> any RuneScribeInboundInputService {
        guard status == .running else {
            throw RuneScribeRuntimeError.runtimeBusy
        }
        guard key.identifier == RuneScribeServiceIDs.inboundInput else {
            throw RuneScribeRuntimeError.hostServiceAccessDenied(key.identifier)
        }
        let generation = try await dispatcher.currentGeneration(
            moduleID: RuntimeHostIdentity.moduleID
        )
        let lease = try await dispatcher.makeLease(
            sourceModuleID: RuntimeHostIdentity.moduleID,
            sourceGeneration: generation,
            destination: .role(RuneScribeRoles.core)
        )
        return RuntimeInboundInputServiceProxy(
            client: RuntimeIngressClient(dispatcher: dispatcher, lease: lease)
        )
    }

    public func start() async throws {
        if status == .running {
            return
        }
        guard status != .starting, status != .stopping else {
            throw RuneScribeRuntimeError.runtimeBusy
        }

        status = .starting
        _ = await dispatcher.beginRuntimeStart()
        _ = await platformBridge.activateRuntime()
        stopRequestedWhileStarting = false
        activeUIModuleID = nil
        activationOrder = []

        do {
            let eligible = await eligibleRegistrations()
            for registration in eligible {
                let descriptor = registration.factory.descriptor
                await dispatcher.registerModule(descriptor)
                await dispatcher.mergeDeclarations(
                    moduleID: descriptor.moduleID,
                    consumed: descriptor.consumedEndpoints.union(
                        RuntimeApplicationEndpointCatalog.consumedEndpointIDs(
                            for: descriptor.requiredServices
                        )
                    ),
                    published: descriptor.publishedEndpoints.union(
                        RuntimeApplicationEndpointCatalog.publishedEndpointIDs(
                            for: descriptor.publishedServices
                        )
                    )
                )
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
                try await activate(registration)
                if stopRequestedWhileStarting {
                    await finishInterruptedStart()
                    return
                }
            }
            await dispatcher.markRuntimeRunning()
            status = .running
        } catch {
            if stopRequestedWhileStarting {
                await finishInterruptedStart()
                return
            }
            await stopActivatedModules(markFailed: true)
            if stopRequestedWhileStarting {
                activeUIModuleID = nil
                activationOrder = []
                stopRequestedWhileStarting = false
                status = .stopped
                resumeStopWaiters()
                return
            }
            activeUIModuleID = nil
            activationOrder = []
            status = .failed
            await dispatcher.beginRuntimeStop()
            await platformBridge.deactivateRuntime()
            resumeStopWaiters()
            throw error
        }
    }

    public func stop() async {
        if status == .idle || status == .stopped {
            status = .stopped
            return
        }
        if status == .starting {
            stopRequestedWhileStarting = true
            status = .stopping
            await dispatcher.beginRuntimeStop()
            await platformBridge.deactivateRuntime()
            await waitForStopCompletion()
            return
        }
        if status == .stopping {
            await waitForStopCompletion()
            return
        }

        status = .stopping
        await dispatcher.beginRuntimeStop()
        await platformBridge.deactivateRuntime()
        await stopActivatedModules(markFailed: false)
        activeUIModuleID = nil
        status = .stopped
        resumeStopWaiters()
    }

    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            status: status,
            moduleStates: moduleStates,
            activationOrder: activationOrder,
            activeUIModuleID: activeUIModuleID
        )
    }

    public func callLedgerSnapshot() async -> [RuntimeCallLedgerRecord] {
        await dispatcher.ledgerSnapshot()
    }

    private func eligibleRegistrations() async -> [Registration] {
        var result: [Registration] = []
        for registration in registrations.values.sorted(by: registrationOrder) {
            moduleStates[registration.manifest.moduleID] = .validated
            if await eligibility.isEligible(registration.manifest) {
                moduleStates[registration.manifest.moduleID] = .eligible
                result.append(registration)
            }
        }
        return result
    }

    private func activationPlan(for eligible: [Registration]) throws -> [Registration] {
        let byRole = Dictionary(
            uniqueKeysWithValues: eligible.map { ($0.manifest.defaultRole, $0) }
        )
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.manifest.moduleID, $0) })
        let serviceIDs = Set(
            eligible
                .filter { $0.manifest.moduleType == .service }
                .map(\.manifest.moduleID)
        )
        var dependencies: [ModuleIdentifier: Set<ModuleIdentifier>] = [:]

        for registration in eligible {
            var moduleDependencies = Set<ModuleIdentifier>()
            for role in registration.factory.descriptor.requiredModuleRoles.sorted() {
                guard let dependency = byRole[role] else {
                    throw RuneScribeRuntimeError.missingRequiredRole(
                        moduleID: registration.manifest.moduleID,
                        role: role
                    )
                }
                moduleDependencies.insert(dependency.manifest.moduleID)
            }
            if registration.manifest.moduleType == .ui {
                moduleDependencies.formUnion(serviceIDs)
                moduleDependencies.remove(registration.manifest.moduleID)
            }
            dependencies[registration.manifest.moduleID] = moduleDependencies
        }

        var plan: [Registration] = []
        while !dependencies.isEmpty {
            let ready = dependencies
                .filter { $0.value.isEmpty }
                .map(\.key)
                .sorted()
            guard !ready.isEmpty else {
                throw RuneScribeRuntimeError.dependencyCycle(dependencies.keys.sorted())
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

    private func activate(_ registration: Registration) async throws {
        let moduleID = registration.manifest.moduleID
        moduleStates[moduleID] = .activating

        for serviceID in registration.factory.descriptor.requiredServices.sorted() {
            if serviceID == RuneScribeServiceIDs.application {
                let available = await dispatcher.endpointsAvailable(
                    RuntimeApplicationEndpointCatalog.applicationEndpointIDs
                )
                guard available else {
                    moduleStates[moduleID] = .failed
                    throw RuneScribeRuntimeError.activationFailed(moduleID)
                }
                continue
            }
            guard await platformBridge.contains(serviceID) else {
                moduleStates[moduleID] = .failed
                throw RuneScribeRuntimeError.activationFailed(moduleID)
            }
        }

        let module: any RuneScribeModule
        do {
            module = try registration.factory.makeModule()
        } catch {
            moduleStates[moduleID] = .failed
            throw RuneScribeRuntimeError.activationFailed(moduleID)
        }
        guard module.descriptor == registration.factory.descriptor else {
            moduleStates[moduleID] = .failed
            throw RuneScribeRuntimeError.factoryDescriptorMismatch(moduleID)
        }

        let moduleGeneration: UInt64
        do {
            moduleGeneration = try await dispatcher.beginActivation(moduleID: moduleID)
        } catch {
            moduleStates[moduleID] = .failed
            throw RuneScribeRuntimeError.activationFailed(moduleID)
        }

        let lease = ModuleContextLease(moduleID: moduleID)
        let context = ModuleContext(
            descriptor: registration.factory.descriptor,
            policy: policy,
            events: events,
            messages: messages,
            dispatcher: dispatcher,
            moduleGeneration: moduleGeneration,
            platformBridge: platformBridge,
            platformGeneration: await platformBridge.currentGeneration(),
            environment: environment,
            lease: lease
        )

        do {
            try await module.start(context: context)
            try await dispatcher.markActive(
                moduleID: moduleID,
                generation: moduleGeneration
            )
            for serviceID in registration.factory.descriptor.publishedServices.sorted() {
                let endpointIDs = RuntimeApplicationEndpointCatalog.publishedEndpointIDs(
                    for: [serviceID]
                )
                guard !endpointIDs.isEmpty,
                      await dispatcher.endpointsAvailable(endpointIDs)
                else {
                    throw RuneScribeRuntimeError.serviceUnavailable(serviceID)
                }
            }
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
        await stopActivatedModules(markFailed: false)
        activeUIModuleID = nil
        activationOrder = []
        stopRequestedWhileStarting = false
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
