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
    private let services = ScopedServiceRegistry()
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

    public func registerHostService<Value: Sendable>(
        _ value: Value,
        for key: ServiceKey<Value>
    ) async throws {
        guard status == .idle || status == .stopped || status == .failed else {
            throw RuneScribeRuntimeError.runtimeBusy
        }
        guard let rule = policy.services.rule(for: key.identifier),
              rule.publisherRoles.contains(RuneScribeRoles.applicationHost)
        else {
            throw RuneScribeRuntimeError.hostServiceAccessDenied(key.identifier)
        }
        try await services.registerHostService(value, for: key)
    }

    /// Resolves a module-published service for the application host only when the
    /// explicit service policy names the host as a consumer. This is used for the
    /// narrow inbound-input rail; it is not a general registry escape hatch.
    public func resolveHostService<Value: Sendable>(
        _ key: ServiceKey<Value>
    ) async throws -> Value {
        guard status == .running else {
            throw RuneScribeRuntimeError.runtimeBusy
        }
        guard let rule = policy.services.rule(for: key.identifier),
              rule.consumerRoles.contains(RuneScribeRoles.applicationHost)
        else {
            throw RuneScribeRuntimeError.hostServiceAccessDenied(key.identifier)
        }
        return try await services.resolve(key)
    }

    public func start() async throws {
        if status == .running {
            return
        }
        guard status != .starting, status != .stopping else {
            throw RuneScribeRuntimeError.runtimeBusy
        }

        status = .starting
        activeUIModuleID = nil
        activationOrder = []

        do {
            let eligible = await eligibleRegistrations()
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
            }
            status = .running
        } catch {
            await stopActivatedModules(markFailed: true)
            activeUIModuleID = nil
            activationOrder = []
            status = .failed
            throw error
        }
    }

    public func stop() async {
        if status == .idle || status == .stopped {
            status = .stopped
            return
        }
        guard status != .starting, status != .stopping else {
            return
        }

        status = .stopping
        await stopActivatedModules(markFailed: false)
        activeUIModuleID = nil
        status = .stopped
    }

    public func snapshot() -> RuntimeSnapshot {
        RuntimeSnapshot(
            status: status,
            moduleStates: moduleStates,
            activationOrder: activationOrder,
            activeUIModuleID: activeUIModuleID
        )
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
            guard await services.contains(serviceID) else {
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

        let lease = ModuleContextLease(moduleID: moduleID)
        let context = ModuleContext(
            descriptor: registration.factory.descriptor,
            policy: policy,
            services: services,
            events: events,
            messages: messages,
            environment: environment,
            lease: lease
        )

        do {
            try await module.start(context: context)
            for serviceID in registration.factory.descriptor.publishedServices.sorted() {
                guard await services.contains(serviceID) else {
                    throw RuneScribeRuntimeError.serviceUnavailable(serviceID)
                }
            }
        } catch {
            await module.stop()
            await context.invalidate()
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
            await active.module.stop()
            await active.context.invalidate()
            moduleStates[moduleID] = markFailed ? .failed : .stopped
        }
        activeModules.removeAll()
    }

    private func registrationOrder(_ lhs: Registration, _ rhs: Registration) -> Bool {
        lhs.manifest.moduleID < rhs.manifest.moduleID
    }
}
