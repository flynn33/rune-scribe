import Foundation
import RuneScribeContracts

/// Internal control signal proving host ingress failed before any destination
/// handler was invoked. The rail may retry only this signal; provider errors
/// remain ambiguous and are never replayed.
enum RuntimeHostIngressRoutingError: Error {
    case destinationUnavailableBeforeInvocation
}

public enum RuntimeCallLedgerFailure: String, Equatable, Sendable {
    case runtimeUnavailable
    case staleClient
    case inactiveSource
    case inactiveDestination
    case undeclaredSource
    case undeclaredDestination
    case capabilityDenied
    case endpointUnavailable
    case descriptorMismatch
    case typeMismatch
    case kindMismatch
    case schemaMismatch
    case requestTooLarge
    case responseTooLarge
    case sessionLimit
    case rateLimit
    case cancelled
    case handlerFailure
}

public enum RuntimeCallLedgerOutcome: Equatable, Sendable {
    case inFlight
    case succeeded
    case denied(RuntimeCallLedgerFailure)
    case failed(RuntimeCallLedgerFailure)
    case cancelled
}

/// Secret-safe operation evidence. Payloads, results, error descriptions, file
/// paths, URLs, PINs, and user content are intentionally absent.
public struct RuntimeCallLedgerRecord: Equatable, Sendable {
    public let metadata: RuntimeOperationMetadata
    public let hadIdempotencyKey: Bool
    public let endpointKind: RuntimeEndpointKind
    public let requestByteCount: UInt64
    public let responseByteCount: UInt64?
    public let completedAtUTC: Date?
    public let outcome: RuntimeCallLedgerOutcome

    init(
        metadata: RuntimeOperationMetadata,
        hadIdempotencyKey: Bool,
        endpointKind: RuntimeEndpointKind,
        requestByteCount: UInt64,
        responseByteCount: UInt64? = nil,
        completedAtUTC: Date? = nil,
        outcome: RuntimeCallLedgerOutcome
    ) {
        self.metadata = metadata
        self.hadIdempotencyKey = hadIdempotencyKey
        self.endpointKind = endpointKind
        self.requestByteCount = requestByteCount
        self.responseByteCount = responseByteCount
        self.completedAtUTC = completedAtUTC
        self.outcome = outcome
    }
}

enum RuntimeDispatchLifecycle: Sendable {
    case registered
    case activating
    case active
    case stopping
    case stopped
    case failed
}

enum RuntimeHostIdentity {
    static let moduleID: ModuleIdentifier = "application.host.runtime-source"
}

struct RuntimeClientLease: Sendable {
    let runtimeGeneration: UInt64
    let sourceModuleID: ModuleIdentifier
    let sourceGeneration: UInt64
    let destinationModuleID: ModuleIdentifier
    let destinationGeneration: UInt64
}

private struct RuntimeModuleDispatchRecord: Sendable {
    let moduleID: ModuleIdentifier
    let role: ModuleRole
    let capabilities: Set<CapabilityIdentifier>
    var consumedEndpoints: Set<RuntimeEndpointIdentifier>
    var publishedEndpoints: Set<RuntimeEndpointIdentifier>
    var generation: UInt64
    var lifecycle: RuntimeDispatchLifecycle
}

private struct AnyRuntimeEndpointDescriptor: Equatable, Sendable {
    let endpointID: RuntimeEndpointIdentifier
    let kind: RuntimeEndpointKind
    let destination: RuntimeEndpointDestination
    let requestSchemaVersion: RuntimeSchemaVersion
    let responseSchemaVersion: RuntimeSchemaVersion
    let requiredCapability: CapabilityIdentifier
    let maximumRequestBytes: UInt64
    let maximumResponseBytes: UInt64
    let privacyClass: RuntimePrivacyClass

    init<Request: Sendable, Response: Sendable>(
        _ descriptor: RuntimeEndpointDescriptor<Request, Response>
    ) {
        endpointID = descriptor.endpointID
        kind = descriptor.kind
        destination = descriptor.destination
        requestSchemaVersion = descriptor.requestSchemaVersion
        responseSchemaVersion = descriptor.responseSchemaVersion
        requiredCapability = descriptor.requiredCapability
        maximumRequestBytes = descriptor.maximumRequestBytes
        maximumResponseBytes = descriptor.maximumResponseBytes
        privacyClass = descriptor.privacyClass
    }
}

private protocol RuntimeEndpointHandlerBox: Sendable {}

private struct RuntimeTypedEndpoint<Request: Sendable, Response: Sendable>:
    RuntimeEndpointHandlerBox
{
    let handler: @Sendable (RuntimeOperationMetadata, Request) async throws -> Response
}

private struct RuntimeTypedStateEndpoint<State: Sendable>: RuntimeEndpointHandlerBox {
    let bufferingPolicy: RuntimeStateRelayBufferingPolicy
    let handler: @Sendable (RuntimeOperationMetadata) -> AsyncStream<State>
}

private struct RuntimeMenuCommandEndpoint: RuntimeEndpointHandlerBox {
    let bufferingPolicy: RuntimeStateRelayBufferingPolicy
}

private struct RuntimeEndpointEntry: Sendable {
    let descriptor: AnyRuntimeEndpointDescriptor
    let ownerModuleID: ModuleIdentifier
    let ownerGeneration: UInt64
    let requestType: ObjectIdentifier
    let responseType: ObjectIdentifier
    let handlerBox: any RuntimeEndpointHandlerBox
}

private struct RuntimeInFlightOperation: Sendable {
    let operationID: RuntimeOperationID
    let sourceModuleID: ModuleIdentifier
    let destinationModuleID: ModuleIdentifier
    let endpointID: RuntimeEndpointIdentifier
    let endpointKind: RuntimeEndpointKind
    let cancel: @Sendable () -> Void
}

private final class RuntimeStateStreamRevocation: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    var isRevoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return revoked
    }

    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }
}

private struct RuntimeMenuCommandSubscription: Sendable {
    let operationID: RuntimeOperationID
    let lease: RuntimeClientLease
    let endpoint: RuntimeEndpointEntry
    let continuation: AsyncStream<
        RuntimeStateEnvelope<ApplicationMenuCommandDTO>
    >.Continuation
}

public struct RuntimeOperationRatePolicy: Equatable, Sendable {
    /// The shipping ceiling is deliberately high enough for bursty local UI work
    /// while still bounding one source to 16,384 authorized calls per minute.
    public static let shippingDefault = RuntimeOperationRatePolicy(
        maximumCallsPerSource: 16_384,
        window: 60
    )

    public let maximumCallsPerSource: Int
    public let window: TimeInterval

    init(maximumCallsPerSource: Int, window: TimeInterval) {
        precondition(maximumCallsPerSource > 0)
        precondition(window > 0)
        self.maximumCallsPerSource = maximumCallsPerSource
        self.window = window
    }
}

public actor RuntimeOperationDispatcher {
    public static let maximumLedgerRecords = 4_096
    public static let maximumInFlightOperations = 256

    private let policy: RuntimePolicy
    private let environment: RuntimeEnvironment
    private let ratePolicy: RuntimeOperationRatePolicy
    private let beforeStateDelivery: @Sendable () async -> Void
    private var modules: [ModuleIdentifier: RuntimeModuleDispatchRecord] = [:]
    private var endpoints: [RuntimeEndpointIdentifier: RuntimeEndpointEntry] = [:]
    private var inFlight: [RuntimeOperationID: RuntimeInFlightOperation] = [:]
    private var ledger: [RuntimeCallLedgerRecord] = []
    private var operationSequence: UInt64 = 0
    private var sourceCallTimes: [ModuleIdentifier: [Date]] = [:]
    private var runtimeGeneration: UInt64 = 0
    private var runtimeIsStarting = false
    private var runtimeIsRunning = false
    private var runtimeIsQuiescing = false
    private var menuCommandSubscription: RuntimeMenuCommandSubscription?

    public init(
        policy: RuntimePolicy,
        environment: RuntimeEnvironment,
        ratePolicy: RuntimeOperationRatePolicy = .shippingDefault
    ) {
        self.policy = policy
        self.environment = environment
        self.ratePolicy = ratePolicy
        beforeStateDelivery = {}
    }

    init(
        policy: RuntimePolicy,
        environment: RuntimeEnvironment,
        ratePolicy: RuntimeOperationRatePolicy,
        beforeStateDelivery: @escaping @Sendable () async -> Void
    ) {
        self.policy = policy
        self.environment = environment
        self.ratePolicy = ratePolicy
        self.beforeStateDelivery = beforeStateDelivery
    }

    func registerModule(_ descriptor: ModuleDescriptor) {
        modules[descriptor.moduleID] = RuntimeModuleDispatchRecord(
            moduleID: descriptor.moduleID,
            role: descriptor.role,
            capabilities: descriptor.requestedCapabilities,
            consumedEndpoints: descriptor.consumedEndpoints,
            publishedEndpoints: descriptor.publishedEndpoints,
            generation: 0,
            lifecycle: .registered
        )
    }

    func registerHostSource(consumedEndpoints: Set<RuntimeEndpointIdentifier>) {
        let previousGeneration = modules[RuntimeHostIdentity.moduleID]?.generation ?? 0
        modules[RuntimeHostIdentity.moduleID] = RuntimeModuleDispatchRecord(
            moduleID: RuntimeHostIdentity.moduleID,
            role: RuneScribeRoles.applicationHost,
            capabilities: [
                RuneScribeCapabilities.applicationCommands,
                RuneScribeCapabilities.inboundInput,
                RuneScribeCapabilities.progressionEventApply,
                RuneScribeCapabilities.progressionStateRead,
                RuneScribeCapabilities.progressionRecovery,
                RuneScribeCapabilities.progressionMigrationApply,
            ],
            consumedEndpoints: consumedEndpoints.union([
                RuntimeApplicationEndpointCatalog.completeShareArtifact
                    .descriptor.endpointID,
                RuntimeProgressionEndpointCatalog.applyEvent.descriptor.endpointID,
                RuntimeProgressionEndpointCatalog.entitlements.endpointID,
                RuntimeProgressionEndpointCatalog.rebuild.descriptor.endpointID,
                RuntimeProgressionEndpointCatalog.applyExistingUserMigration
                    .descriptor.endpointID,
                RuntimeProgressionEndpointCatalog.applyExistingUserMigrationPage
                    .descriptor.endpointID,
            ]),
            publishedEndpoints: [],
            generation: previousGeneration &+ 1,
            lifecycle: .active
        )
        sourceCallTimes.removeValue(forKey: RuntimeHostIdentity.moduleID)
    }

    func progressionOutboxCommandClient() throws -> RuntimeCommandClient {
        let sourceGeneration = try currentGeneration(moduleID: RuntimeHostIdentity.moduleID)
        let lease = try makeLease(
            sourceModuleID: RuntimeHostIdentity.moduleID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.progression)
        )
        return RuntimeCommandClient(dispatcher: self, lease: lease)
    }

    func shareCompletionCommandClient() throws -> RuntimeCommandClient {
        let sourceGeneration = try currentGeneration(
            moduleID: RuntimeHostIdentity.moduleID
        )
        let lease = try makeLease(
            sourceModuleID: RuntimeHostIdentity.moduleID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.core)
        )
        return RuntimeCommandClient(dispatcher: self, lease: lease)
    }

    func progressionMigrationCommandClient() throws -> RuntimeCommandClient {
        let sourceGeneration = try currentGeneration(moduleID: RuntimeHostIdentity.moduleID)
        let lease = try makeLease(
            sourceModuleID: RuntimeHostIdentity.moduleID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.progression)
        )
        return RuntimeCommandClient(dispatcher: self, lease: lease)
    }

    func progressionEntitlementStream() async throws
        -> RuntimeStateStream<ProgressionEntitlementSnapshotDTO>
    {
        let sourceGeneration = try currentGeneration(moduleID: RuntimeHostIdentity.moduleID)
        let lease = try makeLease(
            sourceModuleID: RuntimeHostIdentity.moduleID,
            sourceGeneration: sourceGeneration,
            destination: .role(RuneScribeRoles.progression)
        )
        return try await RuntimeStateClient(dispatcher: self, lease: lease).subscribe(
            to: RuntimeProgressionEndpointCatalog.entitlements
        )
    }

    func replaceDeclarations(
        moduleID: ModuleIdentifier,
        consumed: Set<RuntimeEndpointIdentifier>,
        published: Set<RuntimeEndpointIdentifier>
    ) {
        modules[moduleID]?.consumedEndpoints = consumed
        modules[moduleID]?.publishedEndpoints = published
    }

    func beginRuntimeStart() -> UInt64 {
        runtimeGeneration &+= 1
        sourceCallTimes.removeAll(keepingCapacity: true)
        menuCommandSubscription = nil
        runtimeIsStarting = true
        runtimeIsRunning = false
        runtimeIsQuiescing = false
        return runtimeGeneration
    }

    func markRuntimeRunning() {
        runtimeIsStarting = false
        runtimeIsRunning = true
        runtimeIsQuiescing = false
    }

    func beginRuntimeQuiesce() {
        runtimeIsStarting = false
        runtimeIsRunning = false
        runtimeIsQuiescing = true
        cancelInFlight {
            $0.sourceModuleID != RuntimeHostIdentity.moduleID
                && $0.endpointKind != .state
        }
    }

    func beginRuntimeStop() {
        runtimeIsStarting = false
        runtimeIsRunning = false
        runtimeIsQuiescing = false
        cancelInFlight { _ in true }
        menuCommandSubscription = nil
    }

    func beginActivation(moduleID: ModuleIdentifier) throws -> UInt64 {
        guard var module = modules[moduleID] else {
            throw RuneScribeRuntimeError.moduleNotActive(moduleID)
        }
        module.generation &+= 1
        module.lifecycle = .activating
        modules[moduleID] = module
        endpoints = endpoints.filter { $0.value.ownerModuleID != moduleID }
        sourceCallTimes.removeValue(forKey: moduleID)
        cancelInFlight {
            $0.sourceModuleID == moduleID || $0.destinationModuleID == moduleID
        }
        return module.generation
    }

    func markActive(moduleID: ModuleIdentifier, generation: UInt64) throws {
        guard var module = modules[moduleID], module.generation == generation else {
            throw RuneScribeRuntimeError.staleClient(moduleID)
        }
        module.lifecycle = .active
        modules[moduleID] = module
    }

    func invalidateModule(moduleID: ModuleIdentifier, failed: Bool = false) {
        guard var module = modules[moduleID] else { return }
        module.lifecycle = .stopping
        module.generation &+= 1
        modules[moduleID] = module
        endpoints = endpoints.filter { $0.value.ownerModuleID != moduleID }
        sourceCallTimes.removeValue(forKey: moduleID)
        cancelInFlight {
            $0.sourceModuleID == moduleID || $0.destinationModuleID == moduleID
        }
        module.lifecycle = failed ? .failed : .stopped
        modules[moduleID] = module
    }

    func currentGeneration(moduleID: ModuleIdentifier) throws -> UInt64 {
        guard let module = modules[moduleID] else {
            throw RuneScribeRuntimeError.moduleNotActive(moduleID)
        }
        return module.generation
    }

    func publishedEndpointsAvailable(
        moduleID: ModuleIdentifier,
        generation: UInt64,
        endpointIDs: Set<RuntimeEndpointIdentifier>
    ) -> Bool {
        endpointIDs.allSatisfy {
            endpoints[$0]?.ownerModuleID == moduleID
                && endpoints[$0]?.ownerGeneration == generation
        }
    }

    func makeLease(
        sourceModuleID: ModuleIdentifier,
        sourceGeneration: UInt64,
        destination: RuntimeEndpointDestination
    ) throws -> RuntimeClientLease {
        guard let source = modules[sourceModuleID], source.generation == sourceGeneration else {
            throw RuneScribeRuntimeError.staleClient(sourceModuleID)
        }
        let destinationModule = try resolveDestination(destination)
        return RuntimeClientLease(
            runtimeGeneration: runtimeGeneration,
            sourceModuleID: sourceModuleID,
            sourceGeneration: sourceGeneration,
            destinationModuleID: destinationModule.moduleID,
            destinationGeneration: destinationModule.generation
        )
    }

    /// Selects the currently active Core destination for each offered host item.
    /// No destination generation is retained between queue elements.
    func dispatchHostIngress(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        let lease: RuntimeClientLease
        do {
            let sourceGeneration = try currentGeneration(
                moduleID: RuntimeHostIdentity.moduleID
            )
            lease = try makeLease(
                sourceModuleID: RuntimeHostIdentity.moduleID,
                sourceGeneration: sourceGeneration,
                destination: .role(RuneScribeRoles.core)
            )
        } catch RuneScribeRuntimeError.messageDestinationUnavailable {
            let error = RuneScribeRuntimeError.ingressDestinationUnavailable
            recordHostIngressResolutionFailure(error)
            throw RuntimeHostIngressRoutingError
                .destinationUnavailableBeforeInvocation
        } catch {
            recordHostIngressResolutionFailure(error)
            throw error
        }
        let disposition = try await dispatch(
            lease: lease,
            key: RuntimeApplicationEndpointCatalog.inboundInput,
            expectedKind: .ingress,
            request: input,
            requestSchemaVersion: RuntimeApplicationEndpointCatalog.inboundInput
                .descriptor.requestSchemaVersion,
            responseSchemaVersion: RuntimeApplicationEndpointCatalog.inboundInput
                .descriptor.responseSchemaVersion
        )
        guard disposition == .accepted,
              case .menu(let menu) = input
        else { return disposition }
        return offerMenuCommand(menu.command)
    }

    func registerEndpoint<Request: Sendable, Response: Sendable>(
        ownerModuleID: ModuleIdentifier,
        ownerGeneration: UInt64,
        key: RuntimeEndpointKey<Request, Response>,
        handler: @escaping @Sendable (RuntimeOperationMetadata, Request) async throws -> Response
    ) throws {
        let descriptor = key.descriptor
        guard let owner = modules[ownerModuleID],
              owner.generation == ownerGeneration,
              owner.lifecycle == .activating,
              (runtimeIsStarting || runtimeIsRunning)
        else {
            throw RuneScribeRuntimeError.staleClient(ownerModuleID)
        }
        guard owner.publishedEndpoints.contains(descriptor.endpointID) else {
            throw RuneScribeRuntimeError.endpointNotDeclared(
                moduleID: ownerModuleID,
                endpoint: descriptor.endpointID
            )
        }
        guard destinationMatches(descriptor.destination, module: owner) else {
            throw RuneScribeRuntimeError.endpointDestinationMismatch(descriptor.endpointID)
        }
        guard endpoints[descriptor.endpointID] == nil else {
            throw RuneScribeRuntimeError.endpointAlreadyRegistered(descriptor.endpointID)
        }
        endpoints[descriptor.endpointID] = RuntimeEndpointEntry(
            descriptor: AnyRuntimeEndpointDescriptor(descriptor),
            ownerModuleID: ownerModuleID,
            ownerGeneration: ownerGeneration,
            requestType: ObjectIdentifier(Request.self),
            responseType: ObjectIdentifier(Response.self),
            handlerBox: RuntimeTypedEndpoint(handler: handler)
        )
    }

    func registerStateEndpoint<State: Sendable>(
        ownerModuleID: ModuleIdentifier,
        ownerGeneration: UInt64,
        descriptor: RuntimeStateEndpointDescriptor<State>,
        handler: @escaping @Sendable (RuntimeOperationMetadata) -> AsyncStream<State>
    ) throws {
        let endpointDescriptor = descriptor.endpoint
        guard let owner = modules[ownerModuleID],
              owner.generation == ownerGeneration,
              owner.lifecycle == .activating,
              (runtimeIsStarting || runtimeIsRunning)
        else {
            throw RuneScribeRuntimeError.staleClient(ownerModuleID)
        }
        guard owner.publishedEndpoints.contains(endpointDescriptor.endpointID) else {
            throw RuneScribeRuntimeError.endpointNotDeclared(
                moduleID: ownerModuleID,
                endpoint: endpointDescriptor.endpointID
            )
        }
        guard destinationMatches(endpointDescriptor.destination, module: owner) else {
            throw RuneScribeRuntimeError.endpointDestinationMismatch(endpointDescriptor.endpointID)
        }
        guard endpoints[endpointDescriptor.endpointID] == nil else {
            throw RuneScribeRuntimeError.endpointAlreadyRegistered(endpointDescriptor.endpointID)
        }
        endpoints[endpointDescriptor.endpointID] = RuntimeEndpointEntry(
            descriptor: AnyRuntimeEndpointDescriptor(endpointDescriptor),
            ownerModuleID: ownerModuleID,
            ownerGeneration: ownerGeneration,
            requestType: ObjectIdentifier(RuntimeStateSubscription.self),
            responseType: ObjectIdentifier(State.self),
            handlerBox: RuntimeTypedStateEndpoint(
                bufferingPolicy: descriptor.bufferingPolicy,
                handler: handler
            )
        )
    }

    func registerRuntimeMenuCommandEndpoint(
        ownerModuleID: ModuleIdentifier,
        ownerGeneration: UInt64,
        descriptor: RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO>
    ) throws {
        let endpointDescriptor = descriptor.endpoint
        guard let owner = modules[ownerModuleID],
              owner.generation == ownerGeneration,
              owner.lifecycle == .activating,
              (runtimeIsStarting || runtimeIsRunning)
        else {
            throw RuneScribeRuntimeError.staleClient(ownerModuleID)
        }
        guard owner.publishedEndpoints.contains(endpointDescriptor.endpointID) else {
            throw RuneScribeRuntimeError.endpointNotDeclared(
                moduleID: ownerModuleID,
                endpoint: endpointDescriptor.endpointID
            )
        }
        guard destinationMatches(endpointDescriptor.destination, module: owner) else {
            throw RuneScribeRuntimeError.endpointDestinationMismatch(endpointDescriptor.endpointID)
        }
        guard endpoints[endpointDescriptor.endpointID] == nil else {
            throw RuneScribeRuntimeError.endpointAlreadyRegistered(endpointDescriptor.endpointID)
        }
        endpoints[endpointDescriptor.endpointID] = RuntimeEndpointEntry(
            descriptor: AnyRuntimeEndpointDescriptor(endpointDescriptor),
            ownerModuleID: ownerModuleID,
            ownerGeneration: ownerGeneration,
            requestType: ObjectIdentifier(RuntimeStateSubscription.self),
            responseType: ObjectIdentifier(ApplicationMenuCommandDTO.self),
            handlerBox: RuntimeMenuCommandEndpoint(
                bufferingPolicy: descriptor.bufferingPolicy
            )
        )
    }

    func dispatch<Request: Sendable, Response: Sendable>(
        lease: RuntimeClientLease,
        key: RuntimeEndpointKey<Request, Response>,
        expectedKind: RuntimeEndpointKind,
        request: Request,
        requestSchemaVersion: RuntimeSchemaVersion,
        responseSchemaVersion: RuntimeSchemaVersion,
        idempotencyKey: RuntimeIdempotencyKey? = nil
    ) async throws -> Response {
        let endpointID = key.descriptor.endpointID
        let operationID = nextOperationID()
        let correlationID = RuntimeCorrelationID(environment.nextUUID().uuidString.lowercased())
        let metadata = RuntimeOperationMetadata(
            schemaVersion: requestSchemaVersion,
            operationID: operationID,
            correlationID: correlationID,
            sourceModuleID: lease.sourceModuleID,
            destinationModuleID: lease.destinationModuleID,
            runtimeGeneration: runtimeGeneration,
            timestampUTC: environment.now(),
            operationIdentifier: RuntimeOperationIdentifier(endpointID.rawValue),
            privacyClass: .internalData,
            idempotencyKey: idempotencyKey
        )

        appendLedgerStart(
            metadata: metadata,
            endpointKind: expectedKind,
            requestByteCount: 0
        )

        do {
            let endpoint = try validateBeforeCall(
                lease: lease,
                key: key,
                expectedKind: expectedKind,
                requestType: Request.self,
                responseType: Response.self,
                requestSchemaVersion: requestSchemaVersion,
                responseSchemaVersion: responseSchemaVersion,
                request: request,
                operationID: operationID
            )
            guard let typedEndpoint = endpoint.handlerBox as? RuntimeTypedEndpoint<Request, Response> else {
                throw RuneScribeRuntimeError.endpointTypeMismatch(endpointID)
            }
            try validateSessionBounds()
            try validateRateBounds(sourceModuleID: lease.sourceModuleID)
            let authorizedMetadata = authoritativeMetadata(
                from: metadata,
                endpoint: endpoint
            )

            let task = Task<Response, Error> {
                try Task.checkCancellation()
                return try await typedEndpoint.handler(authorizedMetadata, request)
            }
            inFlight[operationID] = RuntimeInFlightOperation(
                operationID: operationID,
                sourceModuleID: lease.sourceModuleID,
                destinationModuleID: endpoint.ownerModuleID,
                endpointID: endpointID,
                endpointKind: expectedKind,
                cancel: { task.cancel() }
            )

            let response: Response
            do {
                response = try await task.value
            } catch is CancellationError {
                throw RuneScribeRuntimeError.operationCancelled(operationID)
            } catch let handlerError {
                try validateAfterCall(
                    lease: lease,
                    endpoint: endpoint,
                    allowStartingState: false
                )
                throw handlerError
            }
            inFlight.removeValue(forKey: operationID)

            try validateAfterCall(lease: lease, endpoint: endpoint)
            let responseBytes = RuntimePayloadSizer.byteCount(
                response,
                maximum: endpoint.descriptor.maximumResponseBytes
            )
            updateLedgerResponseByteCount(
                operationID: operationID,
                responseByteCount: responseBytes
            )
            guard responseBytes <= endpoint.descriptor.maximumResponseBytes else {
                throw RuneScribeRuntimeError.operationResponseTooLarge(
                    endpoint: endpointID,
                    maximumBytes: endpoint.descriptor.maximumResponseBytes
                )
            }
            completeLedger(
                operationID: operationID,
                responseByteCount: responseBytes,
                outcome: .succeeded
            )
            return response
        } catch {
            inFlight.removeValue(forKey: operationID)
            completeLedger(
                operationID: operationID,
                responseByteCount: nil,
                outcome: ledgerOutcome(for: error, metadata: metadata)
            )
            throw error
        }
    }

    func openStateRelay<State: Sendable>(
        lease: RuntimeClientLease,
        descriptor: RuntimeStateEndpointDescriptor<State>,
        subscriptionSchemaVersion: RuntimeSchemaVersion,
        stateSchemaVersion: RuntimeSchemaVersion
    ) throws -> RuntimeStateStream<State> {
        let key = descriptor.key
        let endpointID = descriptor.endpointID
        let operationID = nextOperationID()
        let metadata = makeMetadata(
            operationID: operationID,
            lease: lease,
            endpointID: endpointID,
            destinationModuleID: lease.destinationModuleID,
            schemaVersion: subscriptionSchemaVersion,
            privacyClass: .internalData
        )
        appendLedgerStart(metadata: metadata, endpointKind: .state, requestByteCount: 0)

        do {
            let endpoint = try validateBeforeCall(
                lease: lease,
                key: key,
                expectedKind: .state,
                requestType: RuntimeStateSubscription.self,
                responseType: State.self,
                requestSchemaVersion: subscriptionSchemaVersion,
                responseSchemaVersion: stateSchemaVersion,
                request: RuntimeStateSubscription(),
                operationID: operationID
            )
            guard let typedEndpoint = endpoint.handlerBox as? RuntimeTypedStateEndpoint<State> else {
                throw RuneScribeRuntimeError.endpointTypeMismatch(endpointID)
            }
            guard typedEndpoint.bufferingPolicy == descriptor.bufferingPolicy else {
                throw RuneScribeRuntimeError.endpointDescriptorMismatch(endpointID)
            }
            try validateSessionBounds()
            try validateRateBounds(sourceModuleID: lease.sourceModuleID)
            let authorizedMetadata = authoritativeMetadata(
                from: metadata,
                endpoint: endpoint
            )
            let providerStream = typedEndpoint.handler(authorizedMetadata)
            let relayBufferingPolicy: AsyncStream<RuntimeStateEnvelope<State>>.Continuation
                .BufferingPolicy
            switch typedEndpoint.bufferingPolicy.ordering {
            case .newest:
                relayBufferingPolicy = .bufferingNewest(
                    Int(typedEndpoint.bufferingPolicy.capacity)
                )
            case .oldest:
                relayBufferingPolicy = .bufferingOldest(
                    Int(typedEndpoint.bufferingPolicy.capacity)
                )
            }
            let (relay, continuation) = AsyncStream<RuntimeStateEnvelope<State>>.makeStream(
                bufferingPolicy: relayBufferingPolicy
            )
            let revocation = RuntimeStateStreamRevocation()
            let relayTask = Task { [dispatcher = self] in
                var outcome: RuntimeCallLedgerOutcome = .succeeded
                var lastResponseByteCount: UInt64?
                do {
                    for await state in providerStream {
                        try Task.checkCancellation()
                        let byteCount = try await dispatcher.deliverState(
                            state,
                            operationID: operationID,
                            lease: lease,
                            endpointID: endpointID,
                            ownerGeneration: endpoint.ownerGeneration,
                            stateSchemaVersion: stateSchemaVersion,
                            continuation: continuation
                        )
                        lastResponseByteCount = byteCount
                    }
                    try Task.checkCancellation()
                } catch is CancellationError {
                    outcome = .cancelled
                } catch let error as RuneScribeRuntimeError {
                    outcome = await dispatcher.ledgerOutcome(
                        for: error,
                        metadata: metadata
                    )
                } catch {
                    outcome = .failed(.handlerFailure)
                }
                await dispatcher.finishStateRelay(
                    operationID: operationID,
                    responseByteCount: lastResponseByteCount,
                    outcome: outcome
                )
                continuation.finish()
            }
            inFlight[operationID] = RuntimeInFlightOperation(
                operationID: operationID,
                sourceModuleID: lease.sourceModuleID,
                destinationModuleID: endpoint.ownerModuleID,
                endpointID: endpointID,
                endpointKind: .state,
                cancel: {
                    revocation.revoke()
                    relayTask.cancel()
                }
            )
            continuation.onTermination = { @Sendable termination in
                if case .cancelled = termination {
                    revocation.revoke()
                }
                relayTask.cancel()
            }
            return RuntimeStateStream(
                stream: relay,
                dispatcher: self,
                operationID: operationID,
                lease: lease,
                endpointID: endpointID,
                ownerGeneration: endpoint.ownerGeneration,
                revocation: revocation
            )
        } catch {
            completeLedger(
                operationID: operationID,
                responseByteCount: nil,
                outcome: ledgerOutcome(for: error, metadata: metadata)
            )
            throw error
        }
    }

    func openMenuCommandRelay(
        lease: RuntimeClientLease,
        descriptor: RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO>
    ) throws -> RuntimeStateStream<ApplicationMenuCommandDTO> {
        let endpointID = descriptor.endpointID
        let operationID = nextOperationID()
        let metadata = makeMetadata(
            operationID: operationID,
            lease: lease,
            endpointID: endpointID,
            destinationModuleID: lease.destinationModuleID,
            schemaVersion: descriptor.subscriptionSchemaVersion,
            privacyClass: .internalData
        )
        appendLedgerStart(metadata: metadata, endpointKind: .state, requestByteCount: 0)

        do {
            let endpoint = try validateBeforeCall(
                lease: lease,
                key: descriptor.key,
                expectedKind: .state,
                requestType: RuntimeStateSubscription.self,
                responseType: ApplicationMenuCommandDTO.self,
                requestSchemaVersion: descriptor.subscriptionSchemaVersion,
                responseSchemaVersion: descriptor.stateSchemaVersion,
                request: RuntimeStateSubscription(),
                operationID: operationID
            )
            guard let marker = endpoint.handlerBox as? RuntimeMenuCommandEndpoint,
                  marker.bufferingPolicy == descriptor.bufferingPolicy
            else {
                throw RuneScribeRuntimeError.endpointDescriptorMismatch(endpointID)
            }
            try validateSessionBounds()
            try validateRateBounds(sourceModuleID: lease.sourceModuleID)
            guard menuCommandSubscription == nil else {
                throw RuneScribeRuntimeError.operationSessionLimitExceeded(maximum: 1)
            }
            let bufferingPolicy: AsyncStream<
                RuntimeStateEnvelope<ApplicationMenuCommandDTO>
            >.Continuation.BufferingPolicy
            switch marker.bufferingPolicy.ordering {
            case .newest:
                bufferingPolicy = .bufferingNewest(
                    Int(clamping: marker.bufferingPolicy.capacity)
                )
            case .oldest:
                bufferingPolicy = .bufferingOldest(
                    Int(clamping: marker.bufferingPolicy.capacity)
                )
            }
            let (stream, continuation) = AsyncStream<
                RuntimeStateEnvelope<ApplicationMenuCommandDTO>
            >.makeStream(bufferingPolicy: bufferingPolicy)
            let revocation = RuntimeStateStreamRevocation()
            menuCommandSubscription = RuntimeMenuCommandSubscription(
                operationID: operationID,
                lease: lease,
                endpoint: endpoint,
                continuation: continuation
            )
            inFlight[operationID] = RuntimeInFlightOperation(
                operationID: operationID,
                sourceModuleID: lease.sourceModuleID,
                destinationModuleID: endpoint.ownerModuleID,
                endpointID: endpointID,
                endpointKind: .state,
                cancel: {
                    revocation.revoke()
                    continuation.finish()
                }
            )
            continuation.onTermination = { @Sendable [dispatcher = self] termination in
                if case .cancelled = termination {
                    revocation.revoke()
                }
                Task {
                    await dispatcher.finishMenuCommandRelay(
                        operationID: operationID,
                        termination: termination
                    )
                }
            }
            return RuntimeStateStream(
                stream: stream,
                dispatcher: self,
                operationID: operationID,
                lease: lease,
                endpointID: endpointID,
                ownerGeneration: endpoint.ownerGeneration,
                revocation: revocation
            )
        } catch {
            completeLedger(
                operationID: operationID,
                responseByteCount: nil,
                outcome: ledgerOutcome(for: error, metadata: metadata)
            )
            throw error
        }
    }

    public func ledgerSnapshot() -> [RuntimeCallLedgerRecord] {
        ledger
    }

    private func offerMenuCommand(
        _ command: ApplicationMenuCommandDTO
    ) -> InboundInputDispositionDTO {
        guard let subscription = menuCommandSubscription else { return .rejected }
        do {
            try validateStateDelivery(
                lease: subscription.lease,
                endpointID: subscription.endpoint.descriptor.endpointID,
                ownerGeneration: subscription.endpoint.ownerGeneration
            )
            let byteCount = RuntimePayloadSizer.byteCount(
                command,
                maximum: subscription.endpoint.descriptor.maximumResponseBytes
            )
            guard byteCount <= subscription.endpoint.descriptor.maximumResponseBytes else {
                return .rejected
            }
            let stateMetadata = makeStateMetadata(
                lease: subscription.lease,
                endpoint: subscription.endpoint.descriptor,
                schemaVersion: subscription.endpoint.descriptor.responseSchemaVersion
            )
            let yieldResult = subscription.continuation.yield(
                RuntimeStateEnvelope(metadata: stateMetadata, payload: command),
            )
            let disposition: InboundInputDispositionDTO
            switch yieldResult {
            case .enqueued:
                disposition = .accepted
            case .dropped, .terminated:
                disposition = .rejected
            @unknown default:
                disposition = .rejected
            }
            if disposition == .accepted {
                updateLedgerResponseByteCount(
                    operationID: subscription.operationID,
                    responseByteCount: byteCount
                )
            }
            return disposition
        } catch {
            return .rejected
        }
    }

    private func finishMenuCommandRelay(
        operationID: RuntimeOperationID,
        termination: AsyncStream<RuntimeStateEnvelope<ApplicationMenuCommandDTO>>
            .Continuation.Termination
    ) {
        guard menuCommandSubscription?.operationID == operationID else { return }
        menuCommandSubscription = nil
        guard inFlight.removeValue(forKey: operationID) != nil else { return }
        let outcome: RuntimeCallLedgerOutcome
        switch termination {
        case .cancelled:
            outcome = .cancelled
        case .finished:
            outcome = .succeeded
        @unknown default:
            outcome = .cancelled
        }
        completeLedger(
            operationID: operationID,
            responseByteCount: nil,
            outcome: outcome
        )
    }

    private func finishStateRelay(
        operationID: RuntimeOperationID,
        responseByteCount: UInt64?,
        outcome: RuntimeCallLedgerOutcome
    ) {
        guard inFlight.removeValue(forKey: operationID) != nil else { return }
        completeLedger(
            operationID: operationID,
            responseByteCount: responseByteCount,
            outcome: outcome
        )
    }

    func stateRelayIsCurrent(
        lease: RuntimeClientLease,
        endpointID: RuntimeEndpointIdentifier,
        ownerGeneration: UInt64
    ) -> Bool {
        guard let endpoint = endpoints[endpointID],
              endpoint.ownerGeneration == ownerGeneration
        else {
            return false
        }
        do {
            try validateAfterCall(
                lease: lease,
                endpoint: endpoint,
                allowStartingState: true
            )
            return true
        } catch {
            return false
        }
    }

    func cancelStateRelay(operationID: RuntimeOperationID) {
        guard let operation = inFlight[operationID], operation.endpointKind == .state else {
            return
        }
        operation.cancel()
        if menuCommandSubscription?.operationID == operationID {
            menuCommandSubscription = nil
        }
        inFlight.removeValue(forKey: operationID)
        completeLedger(
            operationID: operationID,
            responseByteCount: nil,
            outcome: .cancelled
        )
    }

    private func validateSessionBounds() throws {
        guard inFlight.count < Self.maximumInFlightOperations else {
            throw RuneScribeRuntimeError.operationSessionLimitExceeded(
                maximum: Self.maximumInFlightOperations
            )
        }
    }

    private func validateRateBounds(sourceModuleID: ModuleIdentifier) throws {
        let now = environment.now()
        let cutoff = now.addingTimeInterval(-ratePolicy.window)
        var callTimes = sourceCallTimes[sourceModuleID, default: []]
        callTimes.removeAll { $0 <= cutoff }
        guard callTimes.count < ratePolicy.maximumCallsPerSource else {
            sourceCallTimes[sourceModuleID] = callTimes
            throw RuneScribeRuntimeError.operationRateLimitExceeded(
                maximumCalls: ratePolicy.maximumCallsPerSource,
                window: ratePolicy.window
            )
        }
        callTimes.append(now)
        sourceCallTimes[sourceModuleID] = callTimes
    }

    private func cancelInFlight(
        where shouldCancel: (RuntimeInFlightOperation) -> Bool
    ) {
        let operations = inFlight.values.filter(shouldCancel)
        for operation in operations {
            operation.cancel()
            if menuCommandSubscription?.operationID == operation.operationID {
                menuCommandSubscription = nil
            }
            inFlight.removeValue(forKey: operation.operationID)
            completeLedger(
                operationID: operation.operationID,
                responseByteCount: nil,
                outcome: .cancelled
            )
        }
    }

    private func nextOperationID() -> RuntimeOperationID {
        operationSequence &+= 1
        return RuntimeOperationID(
            "\(environment.nextUUID().uuidString.lowercased())-\(operationSequence)"
        )
    }

    private func deliverState<State: Sendable>(
        _ state: State,
        operationID: RuntimeOperationID,
        lease: RuntimeClientLease,
        endpointID: RuntimeEndpointIdentifier,
        ownerGeneration: UInt64,
        stateSchemaVersion: RuntimeSchemaVersion,
        continuation: AsyncStream<RuntimeStateEnvelope<State>>.Continuation
    ) async throws -> UInt64 {
        // The test coordinator suspends before the final actor-isolated gate.
        // In production it is a no-op. Every real suspension therefore occurs
        // before the generation check, metadata stamp, and yield below.
        await beforeStateDelivery()
        try Task.checkCancellation()
        guard let endpoint = endpoints[endpointID], endpoint.ownerGeneration == ownerGeneration else {
            throw RuneScribeRuntimeError.staleClient(lease.destinationModuleID)
        }
        try validateAfterCall(lease: lease, endpoint: endpoint, allowStartingState: true)
        let byteCount = RuntimePayloadSizer.byteCount(
            state,
            maximum: endpoint.descriptor.maximumResponseBytes
        )
        updateLedgerResponseByteCount(
            operationID: operationID,
            responseByteCount: byteCount
        )
        guard byteCount <= endpoint.descriptor.maximumResponseBytes else {
            throw RuneScribeRuntimeError.operationResponseTooLarge(
                endpoint: endpointID,
                maximumBytes: endpoint.descriptor.maximumResponseBytes
            )
        }
        let stateMetadata = makeMetadata(
            operationID: nextOperationID(),
            lease: lease,
            endpointID: endpointID,
            destinationModuleID: lease.destinationModuleID,
            schemaVersion: stateSchemaVersion,
            privacyClass: endpoint.descriptor.privacyClass
        )
        continuation.yield(
            RuntimeStateEnvelope(metadata: stateMetadata, payload: state)
        )
        return byteCount
    }

    /// Menu delivery already executes entirely inside one dispatcher actor
    /// turn, so these synchronous helpers preserve its existing atomic path.
    private func validateStateDelivery(
        lease: RuntimeClientLease,
        endpointID: RuntimeEndpointIdentifier,
        ownerGeneration: UInt64
    ) throws {
        guard let endpoint = endpoints[endpointID],
              endpoint.ownerGeneration == ownerGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.destinationModuleID)
        }
        try validateAfterCall(
            lease: lease,
            endpoint: endpoint,
            allowStartingState: true
        )
    }

    private func makeStateMetadata(
        lease: RuntimeClientLease,
        endpoint: AnyRuntimeEndpointDescriptor,
        schemaVersion: RuntimeSchemaVersion
    ) -> RuntimeOperationMetadata {
        makeMetadata(
            operationID: nextOperationID(),
            lease: lease,
            endpointID: endpoint.endpointID,
            destinationModuleID: lease.destinationModuleID,
            schemaVersion: schemaVersion,
            privacyClass: endpoint.privacyClass
        )
    }

    private func makeMetadata(
        operationID: RuntimeOperationID,
        lease: RuntimeClientLease,
        endpointID: RuntimeEndpointIdentifier,
        destinationModuleID: ModuleIdentifier,
        schemaVersion: RuntimeSchemaVersion,
        privacyClass: RuntimePrivacyClass,
        idempotencyKey: RuntimeIdempotencyKey? = nil
    ) -> RuntimeOperationMetadata {
        RuntimeOperationMetadata(
            schemaVersion: schemaVersion,
            operationID: operationID,
            correlationID: RuntimeCorrelationID(environment.nextUUID().uuidString.lowercased()),
            sourceModuleID: lease.sourceModuleID,
            destinationModuleID: destinationModuleID,
            runtimeGeneration: runtimeGeneration,
            timestampUTC: environment.now(),
            operationIdentifier: RuntimeOperationIdentifier(endpointID.rawValue),
            privacyClass: privacyClass,
            idempotencyKey: idempotencyKey
        )
    }

    private func authoritativeMetadata(
        from metadata: RuntimeOperationMetadata,
        endpoint: RuntimeEndpointEntry
    ) -> RuntimeOperationMetadata {
        RuntimeOperationMetadata(
            schemaVersion: metadata.schemaVersion,
            operationID: metadata.operationID,
            correlationID: metadata.correlationID,
            sourceModuleID: metadata.sourceModuleID,
            destinationModuleID: endpoint.ownerModuleID,
            runtimeGeneration: metadata.runtimeGeneration,
            timestampUTC: metadata.timestampUTC,
            operationIdentifier: RuntimeOperationIdentifier(
                endpoint.descriptor.endpointID.rawValue
            ),
            privacyClass: endpoint.descriptor.privacyClass,
            idempotencyKey: metadata.idempotencyKey
        )
    }

    private func validateBeforeCall<Request: Sendable, Response: Sendable>(
        lease: RuntimeClientLease,
        key: RuntimeEndpointKey<Request, Response>,
        expectedKind: RuntimeEndpointKind,
        requestType: Request.Type,
        responseType: Response.Type,
        requestSchemaVersion: RuntimeSchemaVersion,
        responseSchemaVersion: RuntimeSchemaVersion,
        request: Request,
        operationID: RuntimeOperationID
    ) throws -> RuntimeEndpointEntry {
        let endpointID = key.descriptor.endpointID
        try validateRuntimeGeneration(lease)
        let source = try validateSourceLifecycle(lease: lease, expectedKind: expectedKind)
        let destination = try validateDestinationLifecycle(lease: lease)
        guard let endpoint = endpoints[endpointID] else {
            throw RuneScribeRuntimeError.endpointUnavailable(endpointID)
        }
        updateLedgerEndpointMetadata(operationID: operationID, endpoint: endpoint)
        guard endpoint.ownerModuleID == destination.moduleID,
              endpoint.ownerGeneration == destination.generation
        else { throw RuneScribeRuntimeError.staleClient(lease.destinationModuleID) }
        try validateEndpointDeclarations(
            endpointID: endpointID,
            source: source,
            destination: destination
        )
        try validateCapability(source: source, endpoint: endpoint)
        try validateDescriptorAndSchemas(
            key: key,
            endpoint: endpoint,
            expectedKind: expectedKind,
            requestType: requestType,
            responseType: responseType,
            requestSchemaVersion: requestSchemaVersion,
            responseSchemaVersion: responseSchemaVersion
        )
        let requestByteCount = RuntimePayloadSizer.byteCount(
            request,
            maximum: endpoint.descriptor.maximumRequestBytes
        )
        updateLedgerRequestByteCount(
            operationID: operationID,
            requestByteCount: requestByteCount
        )
        try validateRequestBounds(requestByteCount, endpoint: endpoint)
        return endpoint
    }

    private func validateRuntimeGeneration(_ lease: RuntimeClientLease) throws {
        guard lease.runtimeGeneration == runtimeGeneration else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
    }

    private func validateSourceLifecycle(
        lease: RuntimeClientLease,
        expectedKind: RuntimeEndpointKind
    ) throws -> RuntimeModuleDispatchRecord {
        guard let source = modules[lease.sourceModuleID] else {
            throw RuneScribeRuntimeError.moduleNotActive(lease.sourceModuleID)
        }
        guard source.generation == lease.sourceGeneration else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        let activationAllowed = expectedKind == .state
            && runtimeIsStarting
            && source.lifecycle == .activating
        let quiescingIngressAllowed = runtimeIsQuiescing
            && expectedKind == .ingress
            && source.moduleID == RuntimeHostIdentity.moduleID
        guard runtimeIsRunning || activationAllowed || quiescingIngressAllowed else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard source.lifecycle == .active || activationAllowed else {
            throw RuneScribeRuntimeError.moduleNotActive(source.moduleID)
        }
        return source
    }

    private func validateDestinationLifecycle(
        lease: RuntimeClientLease
    ) throws -> RuntimeModuleDispatchRecord {
        guard let destination = modules[lease.destinationModuleID] else {
            throw RuneScribeRuntimeError.moduleNotActive(lease.destinationModuleID)
        }
        guard destination.generation == lease.destinationGeneration else {
            throw RuneScribeRuntimeError.staleClient(lease.destinationModuleID)
        }
        guard destination.lifecycle == .active else {
            throw RuneScribeRuntimeError.moduleNotActive(destination.moduleID)
        }
        return destination
    }

    private func validateEndpointDeclarations(
        endpointID: RuntimeEndpointIdentifier,
        source: RuntimeModuleDispatchRecord,
        destination: RuntimeModuleDispatchRecord
    ) throws {
        guard source.consumedEndpoints.contains(endpointID) else {
            throw RuneScribeRuntimeError.endpointNotDeclared(moduleID: source.moduleID, endpoint: endpointID)
        }
        guard destination.publishedEndpoints.contains(endpointID) else {
            throw RuneScribeRuntimeError.endpointNotDeclared(moduleID: destination.moduleID, endpoint: endpointID)
        }
    }

    private func validateCapability(
        source: RuntimeModuleDispatchRecord,
        endpoint: RuntimeEndpointEntry
    ) throws {
        guard source.capabilities.contains(endpoint.descriptor.requiredCapability),
              policy.capabilities.allows(endpoint.descriptor.requiredCapability, for: source.role)
        else {
            throw RuneScribeRuntimeError.capabilityDenied(moduleID: source.moduleID, capability: endpoint.descriptor.requiredCapability)
        }
    }

    private func validateDescriptorAndSchemas<Request: Sendable, Response: Sendable>(
        key: RuntimeEndpointKey<Request, Response>,
        endpoint: RuntimeEndpointEntry,
        expectedKind: RuntimeEndpointKind,
        requestType: Request.Type,
        responseType: Response.Type,
        requestSchemaVersion: RuntimeSchemaVersion,
        responseSchemaVersion: RuntimeSchemaVersion
    ) throws {
        let endpointID = key.descriptor.endpointID
        guard endpoint.descriptor.kind == expectedKind else {
            throw RuneScribeRuntimeError.endpointKindMismatch(
                endpoint: endpointID,
                expected: expectedKind,
                actual: endpoint.descriptor.kind
            )
        }
        let requestedDescriptor = AnyRuntimeEndpointDescriptor(key.descriptor)
        guard requestedDescriptor == endpoint.descriptor else {
            throw RuneScribeRuntimeError.endpointDescriptorMismatch(endpointID)
        }
        guard endpoint.requestType == ObjectIdentifier(requestType),
              endpoint.responseType == ObjectIdentifier(responseType)
        else {
            throw RuneScribeRuntimeError.endpointTypeMismatch(endpointID)
        }
        guard requestSchemaVersion == endpoint.descriptor.requestSchemaVersion else {
            throw RuneScribeRuntimeError.operationSchemaMismatch(
                endpoint: endpointID,
                expected: endpoint.descriptor.requestSchemaVersion,
                actual: requestSchemaVersion
            )
        }
        guard responseSchemaVersion == endpoint.descriptor.responseSchemaVersion else {
            throw RuneScribeRuntimeError.operationSchemaMismatch(
                endpoint: endpointID,
                expected: endpoint.descriptor.responseSchemaVersion,
                actual: responseSchemaVersion
            )
        }
    }

    private func validateRequestBounds(
        _ requestByteCount: UInt64,
        endpoint: RuntimeEndpointEntry
    ) throws {
        guard requestByteCount <= endpoint.descriptor.maximumRequestBytes else {
            throw RuneScribeRuntimeError.operationRequestTooLarge(
                endpoint: endpoint.descriptor.endpointID,
                maximumBytes: endpoint.descriptor.maximumRequestBytes
            )
        }
    }

    private func validateAfterCall(
        lease: RuntimeClientLease,
        endpoint: RuntimeEndpointEntry,
        allowStartingState: Bool = false
    ) throws {
        let quiescingIngressAllowed = runtimeIsQuiescing
            && endpoint.descriptor.kind == .ingress
            && lease.sourceModuleID == RuntimeHostIdentity.moduleID
        let existingStateRelayAllowed = runtimeIsQuiescing
            && allowStartingState
            && endpoint.descriptor.kind == .state
        guard runtimeIsRunning
                || (allowStartingState && runtimeIsStarting)
                || quiescingIngressAllowed
                || existingStateRelayAllowed
        else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        guard lease.runtimeGeneration == runtimeGeneration else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        guard let source = modules[lease.sourceModuleID],
              source.generation == lease.sourceGeneration,
              source.lifecycle == .active
                || (allowStartingState && source.lifecycle == .activating)
        else {
            throw RuneScribeRuntimeError.staleClient(lease.sourceModuleID)
        }
        guard let destination = modules[lease.destinationModuleID],
              destination.generation == lease.destinationGeneration,
              destination.lifecycle == .active,
              endpoint.ownerGeneration == destination.generation,
              endpoints[endpoint.descriptor.endpointID]?.ownerGeneration
                == endpoint.ownerGeneration
        else {
            throw RuneScribeRuntimeError.staleClient(lease.destinationModuleID)
        }
    }

    private func resolveDestination(
        _ destination: RuntimeEndpointDestination
    ) throws -> RuntimeModuleDispatchRecord {
        switch destination {
        case .module(let moduleID):
            guard let module = modules[moduleID] else {
                throw RuneScribeRuntimeError.moduleNotActive(moduleID)
            }
            return module
        case .role(let role):
            let matches = modules.values.filter { $0.role == role && $0.lifecycle == .active }
            guard matches.count == 1, let module = matches.first else {
                throw RuneScribeRuntimeError.messageDestinationUnavailable(role)
            }
            return module
        }
    }

    private func destinationMatches(
        _ destination: RuntimeEndpointDestination,
        module: RuntimeModuleDispatchRecord
    ) -> Bool {
        switch destination {
        case .module(let moduleID): moduleID == module.moduleID
        case .role(let role): role == module.role
        }
    }

    private func appendLedgerStart(
        metadata: RuntimeOperationMetadata,
        endpointKind: RuntimeEndpointKind,
        requestByteCount: UInt64
    ) {
        if ledger.count == Self.maximumLedgerRecords {
            ledger.removeFirst()
        }
        let secretSafeMetadata = RuntimeOperationMetadata(
            schemaVersion: metadata.schemaVersion,
            operationID: metadata.operationID,
            correlationID: metadata.correlationID,
            sourceModuleID: metadata.sourceModuleID,
            destinationModuleID: metadata.destinationModuleID,
            runtimeGeneration: metadata.runtimeGeneration,
            timestampUTC: metadata.timestampUTC,
            operationIdentifier: metadata.operationIdentifier,
            privacyClass: metadata.privacyClass,
            idempotencyKey: nil
        )
        ledger.append(
            RuntimeCallLedgerRecord(
                metadata: secretSafeMetadata,
                hadIdempotencyKey: metadata.idempotencyKey != nil,
                endpointKind: endpointKind,
                requestByteCount: requestByteCount,
                outcome: .inFlight
            )
        )
    }

    private func recordHostIngressResolutionFailure(_ error: Error) {
        let endpoint = RuntimeApplicationEndpointCatalog.inboundInput.descriptor
        let operationID = nextOperationID()
        let metadata = RuntimeOperationMetadata(
            schemaVersion: endpoint.requestSchemaVersion,
            operationID: operationID,
            correlationID: RuntimeCorrelationID(
                environment.nextUUID().uuidString.lowercased()
            ),
            sourceModuleID: RuntimeHostIdentity.moduleID,
            destinationModuleID: nil,
            runtimeGeneration: runtimeGeneration,
            timestampUTC: environment.now(),
            operationIdentifier: RuntimeOperationIdentifier(endpoint.endpointID.rawValue),
            privacyClass: endpoint.privacyClass,
            idempotencyKey: nil
        )
        appendLedgerStart(
            metadata: metadata,
            endpointKind: .ingress,
            requestByteCount: 0
        )
        completeLedger(
            operationID: operationID,
            responseByteCount: nil,
            outcome: ledgerOutcome(for: error, metadata: metadata)
        )
    }

    private func updateLedgerRequestByteCount(
        operationID: RuntimeOperationID,
        requestByteCount: UInt64
    ) {
        guard let index = ledger.lastIndex(where: {
            $0.metadata.operationID == operationID
        }) else { return }
        let initial = ledger[index]
        ledger[index] = RuntimeCallLedgerRecord(
            metadata: initial.metadata,
            hadIdempotencyKey: initial.hadIdempotencyKey,
            endpointKind: initial.endpointKind,
            requestByteCount: requestByteCount,
            responseByteCount: initial.responseByteCount,
            completedAtUTC: initial.completedAtUTC,
            outcome: initial.outcome
        )
    }

    private func updateLedgerEndpointMetadata(
        operationID: RuntimeOperationID,
        endpoint: RuntimeEndpointEntry
    ) {
        guard let index = ledger.lastIndex(where: {
            $0.metadata.operationID == operationID
        }) else { return }
        let initial = ledger[index]
        let metadata = RuntimeOperationMetadata(
            schemaVersion: initial.metadata.schemaVersion,
            operationID: initial.metadata.operationID,
            correlationID: initial.metadata.correlationID,
            sourceModuleID: initial.metadata.sourceModuleID,
            destinationModuleID: endpoint.ownerModuleID,
            runtimeGeneration: initial.metadata.runtimeGeneration,
            timestampUTC: initial.metadata.timestampUTC,
            operationIdentifier: RuntimeOperationIdentifier(
                endpoint.descriptor.endpointID.rawValue
            ),
            privacyClass: endpoint.descriptor.privacyClass,
            idempotencyKey: nil
        )
        ledger[index] = RuntimeCallLedgerRecord(
            metadata: metadata,
            hadIdempotencyKey: initial.hadIdempotencyKey,
            endpointKind: initial.endpointKind,
            requestByteCount: initial.requestByteCount,
            responseByteCount: initial.responseByteCount,
            completedAtUTC: initial.completedAtUTC,
            outcome: initial.outcome
        )
    }

    private func updateLedgerResponseByteCount(
        operationID: RuntimeOperationID,
        responseByteCount: UInt64
    ) {
        guard let index = ledger.lastIndex(where: {
            $0.metadata.operationID == operationID
        }) else { return }
        let initial = ledger[index]
        ledger[index] = RuntimeCallLedgerRecord(
            metadata: initial.metadata,
            hadIdempotencyKey: initial.hadIdempotencyKey,
            endpointKind: initial.endpointKind,
            requestByteCount: initial.requestByteCount,
            responseByteCount: responseByteCount,
            completedAtUTC: initial.completedAtUTC,
            outcome: initial.outcome
        )
    }

    private func completeLedger(
        operationID: RuntimeOperationID,
        responseByteCount: UInt64?,
        outcome: RuntimeCallLedgerOutcome
    ) {
        guard let index = ledger.lastIndex(where: {
            $0.metadata.operationID == operationID
        }) else { return }
        let initial = ledger[index]
        ledger[index] = RuntimeCallLedgerRecord(
            metadata: initial.metadata,
            hadIdempotencyKey: initial.hadIdempotencyKey,
            endpointKind: initial.endpointKind,
            requestByteCount: initial.requestByteCount,
            responseByteCount: responseByteCount ?? initial.responseByteCount,
            completedAtUTC: environment.now(),
            outcome: outcome
        )
    }

    private func ledgerOutcome(
        for error: Error,
        metadata: RuntimeOperationMetadata
    ) -> RuntimeCallLedgerOutcome {
        guard let runtimeError = error as? RuneScribeRuntimeError else {
            return .failed(.handlerFailure)
        }
        switch runtimeError {
        case .runtimeNotRunning, .runtimeBusy:
            return .denied(.runtimeUnavailable)
        case .ingressDestinationUnavailable, .messageDestinationUnavailable:
            return .denied(.inactiveDestination)
        case .staleClient:
            return .denied(.staleClient)
        case .moduleNotActive(let moduleID):
            return .denied(
                moduleID == metadata.sourceModuleID
                    ? .inactiveSource
                    : .inactiveDestination
            )
        case .endpointNotDeclared(let moduleID, _):
            return .denied(
                moduleID == metadata.sourceModuleID
                    ? .undeclaredSource
                    : .undeclaredDestination
            )
        case .capabilityDenied:
            return .denied(.capabilityDenied)
        case .endpointUnavailable:
            return .denied(.endpointUnavailable)
        case .endpointDescriptorMismatch, .endpointDestinationMismatch:
            return .denied(.descriptorMismatch)
        case .endpointTypeMismatch:
            return .denied(.typeMismatch)
        case .endpointKindMismatch:
            return .denied(.kindMismatch)
        case .operationSchemaMismatch:
            return .denied(.schemaMismatch)
        case .operationRequestTooLarge:
            return .denied(.requestTooLarge)
        case .operationResponseTooLarge:
            return .failed(.responseTooLarge)
        case .operationSessionLimitExceeded:
            return .denied(.sessionLimit)
        case .operationRateLimitExceeded:
            return .denied(.rateLimit)
        case .operationCancelled:
            return .cancelled
        default:
            return .failed(.handlerFailure)
        }
    }
}

public struct RuntimeCommandClient: Sendable {
    private let dispatcher: RuntimeOperationDispatcher
    private let lease: RuntimeClientLease

    init(dispatcher: RuntimeOperationDispatcher, lease: RuntimeClientLease) {
        self.dispatcher = dispatcher
        self.lease = lease
    }

    public func send<Request: Sendable, Response: Sendable>(
        _ request: Request,
        to key: RuntimeEndpointKey<Request, Response>,
        requestSchemaVersion: RuntimeSchemaVersion? = nil,
        responseSchemaVersion: RuntimeSchemaVersion? = nil,
        idempotencyKey: RuntimeIdempotencyKey? = nil
    ) async throws -> Response {
        try await dispatcher.dispatch(
            lease: lease,
            key: key,
            expectedKind: .command,
            request: request,
            requestSchemaVersion: requestSchemaVersion
                ?? key.descriptor.requestSchemaVersion,
            responseSchemaVersion: responseSchemaVersion
                ?? key.descriptor.responseSchemaVersion,
            idempotencyKey: idempotencyKey
        )
    }
}

public struct RuntimeQueryClient: Sendable {
    private let dispatcher: RuntimeOperationDispatcher
    private let lease: RuntimeClientLease

    init(dispatcher: RuntimeOperationDispatcher, lease: RuntimeClientLease) {
        self.dispatcher = dispatcher
        self.lease = lease
    }

    public func fetch<Request: Sendable, Response: Sendable>(
        _ request: Request,
        from key: RuntimeEndpointKey<Request, Response>,
        requestSchemaVersion: RuntimeSchemaVersion? = nil,
        responseSchemaVersion: RuntimeSchemaVersion? = nil
    ) async throws -> Response {
        try await dispatcher.dispatch(
            lease: lease,
            key: key,
            expectedKind: .query,
            request: request,
            requestSchemaVersion: requestSchemaVersion
                ?? key.descriptor.requestSchemaVersion,
            responseSchemaVersion: responseSchemaVersion
                ?? key.descriptor.responseSchemaVersion
        )
    }
}

public struct RuntimeIngressClient: Sendable {
    private let dispatcher: RuntimeOperationDispatcher
    private let lease: RuntimeClientLease

    init(dispatcher: RuntimeOperationDispatcher, lease: RuntimeClientLease) {
        self.dispatcher = dispatcher
        self.lease = lease
    }

    public func submit<Request: Sendable, Response: Sendable>(
        _ request: Request,
        to key: RuntimeEndpointKey<Request, Response>,
        requestSchemaVersion: RuntimeSchemaVersion? = nil,
        responseSchemaVersion: RuntimeSchemaVersion? = nil,
        idempotencyKey: RuntimeIdempotencyKey? = nil
    ) async throws -> Response {
        try await dispatcher.dispatch(
            lease: lease,
            key: key,
            expectedKind: .ingress,
            request: request,
            requestSchemaVersion: requestSchemaVersion
                ?? key.descriptor.requestSchemaVersion,
            responseSchemaVersion: responseSchemaVersion
                ?? key.descriptor.responseSchemaVersion,
            idempotencyKey: idempotencyKey
        )
    }
}

/// A generation-pinned runtime state sequence. The underlying AsyncStream may
/// retain values that were buffered before its continuation was finished, so
/// each iterator revalidates the runtime lease and endpoint immediately before
/// and after awaiting a value. Revoked clients therefore discard unread values
/// instead of draining stale application or menu state after stop/replacement.
public struct RuntimeStateStream<State: Sendable>: AsyncSequence, Sendable {
    public typealias Element = RuntimeStateEnvelope<State>

    private let stream: AsyncStream<Element>
    private let dispatcher: RuntimeOperationDispatcher
    private let operationID: RuntimeOperationID
    private let lease: RuntimeClientLease
    private let endpointID: RuntimeEndpointIdentifier
    private let ownerGeneration: UInt64
    private let revocation: RuntimeStateStreamRevocation

    fileprivate init(
        stream: AsyncStream<Element>,
        dispatcher: RuntimeOperationDispatcher,
        operationID: RuntimeOperationID,
        lease: RuntimeClientLease,
        endpointID: RuntimeEndpointIdentifier,
        ownerGeneration: UInt64,
        revocation: RuntimeStateStreamRevocation
    ) {
        self.stream = stream
        self.dispatcher = dispatcher
        self.operationID = operationID
        self.lease = lease
        self.endpointID = endpointID
        self.ownerGeneration = ownerGeneration
        self.revocation = revocation
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(
            base: stream.makeAsyncIterator(),
            dispatcher: dispatcher,
            operationID: operationID,
            lease: lease,
            endpointID: endpointID,
            ownerGeneration: ownerGeneration,
            revocation: revocation
        )
    }

    public struct Iterator: AsyncIteratorProtocol {
        private var base: AsyncStream<Element>.Iterator
        private let dispatcher: RuntimeOperationDispatcher
        private let operationID: RuntimeOperationID
        private let lease: RuntimeClientLease
        private let endpointID: RuntimeEndpointIdentifier
        private let ownerGeneration: UInt64
        private let revocation: RuntimeStateStreamRevocation

        fileprivate init(
            base: AsyncStream<Element>.Iterator,
            dispatcher: RuntimeOperationDispatcher,
            operationID: RuntimeOperationID,
            lease: RuntimeClientLease,
            endpointID: RuntimeEndpointIdentifier,
            ownerGeneration: UInt64,
            revocation: RuntimeStateStreamRevocation
        ) {
            self.base = base
            self.dispatcher = dispatcher
            self.operationID = operationID
            self.lease = lease
            self.endpointID = endpointID
            self.ownerGeneration = ownerGeneration
            self.revocation = revocation
        }

        public mutating func next() async -> Element? {
            guard !Task.isCancelled, !revocation.isRevoked else {
                await dispatcher.cancelStateRelay(operationID: operationID)
                return nil
            }
            guard await dispatcher.stateRelayIsCurrent(
                lease: lease,
                endpointID: endpointID,
                ownerGeneration: ownerGeneration
            ) else {
                await dispatcher.cancelStateRelay(operationID: operationID)
                return nil
            }
            guard let value = await base.next() else {
                if Task.isCancelled || revocation.isRevoked {
                    await dispatcher.cancelStateRelay(operationID: operationID)
                }
                return nil
            }
            guard !Task.isCancelled, !revocation.isRevoked else {
                await dispatcher.cancelStateRelay(operationID: operationID)
                return nil
            }
            guard await dispatcher.stateRelayIsCurrent(
                lease: lease,
                endpointID: endpointID,
                ownerGeneration: ownerGeneration
            ) else {
                await dispatcher.cancelStateRelay(operationID: operationID)
                return nil
            }
            return value
        }
    }
}

public struct RuntimeStateClient: Sendable {
    private let dispatcher: RuntimeOperationDispatcher
    private let lease: RuntimeClientLease

    init(dispatcher: RuntimeOperationDispatcher, lease: RuntimeClientLease) {
        self.dispatcher = dispatcher
        self.lease = lease
    }

    public func subscribe<State: Sendable>(
        to descriptor: RuntimeStateEndpointDescriptor<State>,
        subscriptionSchemaVersion: RuntimeSchemaVersion? = nil,
        stateSchemaVersion: RuntimeSchemaVersion? = nil
    ) async throws -> RuntimeStateStream<State> {
        try await dispatcher.openStateRelay(
            lease: lease,
            descriptor: descriptor,
            subscriptionSchemaVersion: subscriptionSchemaVersion
                ?? descriptor.subscriptionSchemaVersion,
            stateSchemaVersion: stateSchemaVersion ?? descriptor.stateSchemaVersion
        )
    }

    func subscribeToMenuCommands(
        _ descriptor: RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO>
    ) async throws -> RuntimeStateStream<ApplicationMenuCommandDTO> {
        try await dispatcher.openMenuCommandRelay(
            lease: lease,
            descriptor: descriptor
        )
    }
}
