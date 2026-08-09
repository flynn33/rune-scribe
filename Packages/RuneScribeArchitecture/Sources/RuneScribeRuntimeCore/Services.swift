import Foundation
import RuneScribeContracts

public actor ScopedServiceRegistry {
    private struct Entry: Sendable {
        let owner: ModuleIdentifier?
        let value: any Sendable
    }

    private var entries: [ServiceIdentifier: Entry] = [:]

    public init() {}

    public func registerHostService<Value: Sendable>(
        _ value: Value,
        for key: ServiceKey<Value>
    ) throws {
        try register(value, for: key, owner: nil)
    }

    public func contains(_ serviceID: ServiceIdentifier) -> Bool {
        entries[serviceID] != nil
    }

    public func registeredServiceIDs() -> Set<ServiceIdentifier> {
        Set(entries.keys)
    }

    func registerModuleService<Value: Sendable>(
        _ value: Value,
        for key: ServiceKey<Value>,
        owner: ModuleIdentifier
    ) throws {
        try register(value, for: key, owner: owner)
    }

    func resolve<Value: Sendable>(_ key: ServiceKey<Value>) throws -> Value {
        guard let entry = entries[key.identifier] else {
            throw RuneScribeRuntimeError.serviceUnavailable(key.identifier)
        }
        guard let value = entry.value as? Value else {
            throw RuneScribeRuntimeError.serviceTypeMismatch(key.identifier)
        }
        return value
    }

    func removeServices(publishedBy owner: ModuleIdentifier) {
        entries = entries.filter { $0.value.owner != owner }
    }

    private func register<Value: Sendable>(
        _ value: Value,
        for key: ServiceKey<Value>,
        owner: ModuleIdentifier?
    ) throws {
        guard entries[key.identifier] == nil else {
            throw RuneScribeRuntimeError.duplicateService(key.identifier)
        }
        entries[key.identifier] = Entry(owner: owner, value: value)
    }
}

actor ModuleContextLease {
    let moduleID: ModuleIdentifier
    private var active = true

    init(moduleID: ModuleIdentifier) {
        self.moduleID = moduleID
    }

    func requireActive() throws {
        guard active else {
            throw RuneScribeRuntimeError.contextInactive(moduleID)
        }
    }

    func deactivate() {
        active = false
    }
}

public struct ModuleContext: Sendable {
    public let moduleID: ModuleIdentifier
    public let role: ModuleRole

    private let descriptor: ModuleDescriptor
    private let policy: RuntimePolicy
    private let services: ScopedServiceRegistry
    private let events: RuntimeEventBus
    private let messages: DirectedMessageRouter
    private let environment: RuntimeEnvironment
    private let lease: ModuleContextLease

    init(
        descriptor: ModuleDescriptor,
        policy: RuntimePolicy,
        services: ScopedServiceRegistry,
        events: RuntimeEventBus,
        messages: DirectedMessageRouter,
        environment: RuntimeEnvironment,
        lease: ModuleContextLease
    ) {
        moduleID = descriptor.moduleID
        role = descriptor.role
        self.descriptor = descriptor
        self.policy = policy
        self.services = services
        self.events = events
        self.messages = messages
        self.environment = environment
        self.lease = lease
    }

    public func publishService<Value: Sendable>(
        _ value: Value,
        for key: ServiceKey<Value>
    ) async throws {
        try await lease.requireActive()
        guard descriptor.publishedServices.contains(key.identifier) else {
            throw RuneScribeRuntimeError.serviceNotDeclared(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        guard descriptor.requestedCapabilities.contains(RuneScribeCapabilities.publishService),
              policy.capabilities.allows(RuneScribeCapabilities.publishService, for: role)
        else {
            throw RuneScribeRuntimeError.serviceCapabilityMissing(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        guard let rule = policy.services.rule(for: key.identifier),
              rule.publisherRoles.contains(role)
        else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        try await services.registerModuleService(value, for: key, owner: moduleID)
    }

    public func resolveService<Value: Sendable>(_ key: ServiceKey<Value>) async throws -> Value {
        try await lease.requireActive()
        guard descriptor.requiredServices.contains(key.identifier) else {
            throw RuneScribeRuntimeError.serviceNotDeclared(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        guard let rule = policy.services.rule(for: key.identifier) else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        guard descriptor.requestedCapabilities.contains(rule.requiredCapability) else {
            throw RuneScribeRuntimeError.serviceCapabilityMissing(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        guard policy.capabilities.allows(rule.requiredCapability, for: role),
              rule.consumerRoles.contains(role)
        else {
            throw RuneScribeRuntimeError.serviceAccessDenied(
                moduleID: moduleID,
                service: key.identifier
            )
        }
        return try await services.resolve(key)
    }

    public func publishEvent<Payload: Encodable & Sendable>(
        _ type: EventIdentifier,
        payload: Payload
    ) async throws -> RuntimeEvent {
        try await requireCapability(RuneScribeCapabilities.publishEvents)
        let data = try JSONEncoder().encode(payload)
        return await events.publish(
            type: type,
            source: moduleID,
            timestamp: environment.now(),
            eventID: environment.nextUUID(),
            payload: data
        )
    }

    public func eventStream() async throws -> AsyncStream<RuntimeEvent> {
        try await requireCapability(RuneScribeCapabilities.subscribeEvents)
        return await events.subscribe(owner: moduleID, subscriptionID: environment.nextUUID())
    }

    public func registerMessageHandler(
        _ handler: @escaping @Sendable (DirectedMessage) async -> Void
    ) async throws {
        try await requireCapability(RuneScribeCapabilities.receiveMessages)
        try await messages.register(role: role, owner: moduleID, handler: handler)
    }

    public func sendMessage<Payload: Encodable & Sendable>(
        _ type: MessageIdentifier,
        to destinationRole: ModuleRole,
        payload: Payload
    ) async throws {
        try await requireCapability(RuneScribeCapabilities.sendMessages)
        let message = DirectedMessage(
            messageID: environment.nextUUID(),
            type: type,
            sourceModuleID: moduleID,
            destinationRole: destinationRole,
            timestamp: environment.now(),
            payload: try JSONEncoder().encode(payload)
        )
        try await messages.send(message)
    }

    func invalidate() async {
        await lease.deactivate()
        await services.removeServices(publishedBy: moduleID)
        await events.removeSubscriptions(ownedBy: moduleID)
        await messages.removeDestination(ownedBy: moduleID)
    }

    private func requireCapability(_ capability: CapabilityIdentifier) async throws {
        try await lease.requireActive()
        guard descriptor.requestedCapabilities.contains(capability),
              policy.capabilities.allows(capability, for: role)
        else {
            throw RuneScribeRuntimeError.capabilityDenied(
                moduleID: moduleID,
                capability: capability
            )
        }
    }
}
