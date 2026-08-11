import Foundation
import RuneScribeContracts
import RuneScribeUIPresentationContracts

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

    let descriptor: ModuleDescriptor
    let policy: RuntimePolicy
    private let events: RuntimeEventBus
    private let messages: DirectedMessageRouter
    private let dispatcher: RuntimeOperationDispatcher
    private let moduleGeneration: UInt64
    private let runtimeIOGateway: RuntimeIOGateway
    private let runtimeIOGeneration: UInt64
    private let rootPresentationGateway: RuntimeRootPresentationGateway
    private let rootPresentationGeneration: UInt64
    private let environment: RuntimeEnvironment
    let lease: ModuleContextLease

    init(
        descriptor: ModuleDescriptor,
        policy: RuntimePolicy,
        events: RuntimeEventBus,
        messages: DirectedMessageRouter,
        dispatcher: RuntimeOperationDispatcher,
        moduleGeneration: UInt64,
        runtimeIOGateway: RuntimeIOGateway,
        runtimeIOGeneration: UInt64,
        rootPresentationGateway: RuntimeRootPresentationGateway,
        rootPresentationGeneration: UInt64,
        environment: RuntimeEnvironment,
        lease: ModuleContextLease
    ) {
        moduleID = descriptor.moduleID
        role = descriptor.role
        self.descriptor = descriptor
        self.policy = policy
        self.events = events
        self.messages = messages
        self.dispatcher = dispatcher
        self.moduleGeneration = moduleGeneration
        self.runtimeIOGateway = runtimeIOGateway
        self.runtimeIOGeneration = runtimeIOGeneration
        self.rootPresentationGateway = rootPresentationGateway
        self.rootPresentationGeneration = rootPresentationGeneration
        self.environment = environment
        self.lease = lease
    }

    public func registerEndpoint<Request: Sendable, Response: Sendable>(
        _ key: RuntimeEndpointKey<Request, Response>,
        handler: @escaping @Sendable (RuntimeOperationMetadata, Request) async throws -> Response
    ) async throws {
        try await lease.requireActive()
        try await dispatcher.registerEndpoint(
            ownerModuleID: moduleID,
            ownerGeneration: moduleGeneration,
            key: key,
            handler: handler
        )
    }

    public func registerStateEndpoint<State: Sendable>(
        _ descriptor: RuntimeStateEndpointDescriptor<State>,
        handler: @escaping @Sendable (RuntimeOperationMetadata) -> AsyncStream<State>
    ) async throws {
        try await lease.requireActive()
        try await dispatcher.registerStateEndpoint(
            ownerModuleID: moduleID,
            ownerGeneration: moduleGeneration,
            descriptor: descriptor,
            handler: handler
        )
    }

    public func registerRuntimeMenuCommandEndpoint(
        _ descriptor: RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO>
    ) async throws {
        try await lease.requireActive()
        try await dispatcher.registerRuntimeMenuCommandEndpoint(
            ownerModuleID: moduleID,
            ownerGeneration: moduleGeneration,
            descriptor: descriptor
        )
    }

    public func commandClient(
        to destination: RuntimeEndpointDestination
    ) async throws -> RuntimeCommandClient {
        try await lease.requireActive()
        let clientLease = try await dispatcher.makeLease(
            sourceModuleID: moduleID,
            sourceGeneration: moduleGeneration,
            destination: destination
        )
        return RuntimeCommandClient(dispatcher: dispatcher, lease: clientLease)
    }

    public func queryClient(
        to destination: RuntimeEndpointDestination
    ) async throws -> RuntimeQueryClient {
        try await lease.requireActive()
        let clientLease = try await dispatcher.makeLease(
            sourceModuleID: moduleID,
            sourceGeneration: moduleGeneration,
            destination: destination
        )
        return RuntimeQueryClient(dispatcher: dispatcher, lease: clientLease)
    }

    public func ingressClient(
        to destination: RuntimeEndpointDestination
    ) async throws -> RuntimeIngressClient {
        try await lease.requireActive()
        let clientLease = try await dispatcher.makeLease(
            sourceModuleID: moduleID,
            sourceGeneration: moduleGeneration,
            destination: destination
        )
        return RuntimeIngressClient(dispatcher: dispatcher, lease: clientLease)
    }

    public func stateClient(
        to destination: RuntimeEndpointDestination
    ) async throws -> RuntimeStateClient {
        try await lease.requireActive()
        let clientLease = try await dispatcher.makeLease(
            sourceModuleID: moduleID,
            sourceGeneration: moduleGeneration,
            destination: destination
        )
        return RuntimeStateClient(dispatcher: dispatcher, lease: clientLease)
    }

    public func runtimeIOClient() async throws -> RuntimeIOClient {
        try await lease.requireActive()
        return try await runtimeIOGateway.makeClient(
            sourceModuleID: moduleID,
            sourceModuleGeneration: moduleGeneration,
            runtimeGeneration: runtimeIOGeneration
        )
    }

    public func rootPresentationClient() async throws
        -> RuntimeRootPresentationClient
    {
        try await lease.requireActive()
        return try await rootPresentationGateway.makeClient(
            sourceModuleID: moduleID,
            sourceModuleGeneration: moduleGeneration,
            runtimeGeneration: rootPresentationGeneration,
            policy: policy
        )
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
        await rootPresentationGateway.invalidateModule(
            moduleID,
            generation: moduleGeneration
        )
        await runtimeIOGateway.invalidateModule(
            moduleID,
            generation: moduleGeneration
        )
        await lease.deactivate()
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
