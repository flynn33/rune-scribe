import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum RuneScribeProgressionModuleBootstrap {
    public static let moduleID = RuneScribeModuleIDs.progression

    /// Exposed for host registration only. Progression never resolves or reads
    /// files from this bundle; all resource bytes cross the runtime I/O rail.
    public static var resourceBundle: Bundle { .module }
    public static var ownerScopedResourceBundles: [ModuleIdentifier: Bundle] {
        [moduleID: resourceBundle]
    }
    public static let manifestResource =
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor.resource
    public static let manifestExpectedSHA256 =
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor.expectedSHA256
    public static let manifestMaximumByteCount =
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor.maximumByteCount

    public static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(46)),
        kind: .service,
        criticality: .optional,
        entryPoint: "RuneScribeProgressionModule",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [
            RuneScribeCapabilities.moduleStateAccess,
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.runtimeAvailabilityRead,
        ],
        requiredServices: [
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.moduleStateStore,
        ],
        requiredResources: ProgressionCatalogResourceCatalog.all,
        publishedEndpoints: RuntimeProgressionEndpointCatalog.publishedEndpointIDs.union(
            RuntimeProgressionEndpointCatalog.existingUserMigrationEndpointIDs
        )
    )

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeProgressionModule.self)
    }

    public static func register(with runtime: RuneScribeRuntime) async throws {
        try await runtime.register(
            manifestResource: manifestResource,
            expectedSHA256: manifestExpectedSHA256,
            maximumByteCount: manifestMaximumByteCount,
            factory: factory()
        )
    }
}

public typealias ProgressionCatalogLoadOperation = @Sendable (
    RuntimeIOClient
) async throws -> ValidatedProgressionCatalogBundle

/// PRG-2 bootstrap lifecycle. Activation validates the controlling resources,
/// opens the runtime-owned state namespace, and registers the durable service.
public struct RuneScribeProgressionModule: RuntimeConstructibleModule {
    public static let moduleDescriptor = RuneScribeProgressionModuleBootstrap.descriptor
    public let descriptor = Self.moduleDescriptor

    private let lifecycle = RuneScribeProgressionModuleLifecycle()
    private let loadCatalog: ProgressionCatalogLoadOperation

    public init() {
        loadCatalog = { runtimeIO in
            try await ProgressionCatalogResources.loadValidatedBundle(using: runtimeIO)
        }
    }

    public init(loadCatalog: @escaping ProgressionCatalogLoadOperation) {
        self.loadCatalog = loadCatalog
    }

    public func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        let resources = try await loadCatalog(runtimeIO)
        let stateClient = try await context.moduleStateClient()
        let availabilityClient = try await context.runtimeAvailabilityClient()
        let externalSyncClient = try await context.progressionExternalSyncClient()
        let service = try await RuneScribeProgressionServiceActor.bootstrap(
            catalogBundle: resources,
            stateClient: stateClient,
            availabilityClient: availabilityClient
        )
        do {
            try await context.registerProgressionEndpoints(service)
            let observationMetadata = RuntimeOperationMetadata(
                schemaVersion: RuntimeSchemaVersions.v1,
                operationID: "operation.progression.external-sync.observe",
                correlationID: "correlation.progression.external-sync.observe",
                sourceModuleID: RuneScribeModuleIDs.progression,
                destinationModuleID: RuneScribeModuleIDs.progression,
                runtimeGeneration: 1,
                timestampUTC: context.runtimeTimestamp(),
                operationIdentifier: "progression.external-sync.observe",
                privacyClass: .internalData
            )
            await lifecycle.start(
                service,
                client: externalSyncClient,
                observationMetadata: observationMetadata
            )
        } catch {
            await service.shutdown()
            throw error
        }
    }

    public func stop() async {
        await lifecycle.stop()
    }
}

enum ProgressionExternalSyncTerminalReason: Equatable, Sendable {
    case staleDelivery
    case contextEnded
    case invalidData
    case permanentFailure
    case snapshotProjectionFailed
}

private enum ProgressionExternalRetryDecision {
    case retry
    case terminal(ProgressionExternalSyncTerminalReason)
}

private func progressionExternalRetryDecision(
    for error: Error,
    invalidRequestIsStale: Bool
) -> ProgressionExternalRetryDecision {
    if error is CancellationError { return .terminal(.contextEnded) }
    if let stateError = error as? ModuleStateStoreError {
        switch stateError {
        case .unavailable, .revisionConflict, .injectedFailure:
            return .retry
        case .invalidRequest:
            return .terminal(invalidRequestIsStale ? .staleDelivery : .invalidData)
        case .payloadTooLarge, .transactionTooLarge, .quarantined,
             .integrityMismatch, .unreadable, .corrupt:
            return .terminal(.invalidData)
        }
    }
    if let runtimeError = error as? RuneScribeRuntimeError {
        switch runtimeError {
        case .runtimeBusy, .serviceUnavailable, .endpointUnavailable,
             .operationRateLimitExceeded, .operationSessionLimitExceeded:
            return .retry
        case .runtimeNotRunning, .contextInactive, .moduleNotActive,
             .staleClient, .operationCancelled:
            return .terminal(.contextEnded)
        default:
            return .terminal(.permanentFailure)
        }
    }
    return .terminal(.permanentFailure)
}

enum ProgressionExternalMergeDeliveryState: Equatable, Sendable {
    case stopped
    case idle
    case processing(deliveryID: UUID)
    case retrying(deliveryID: UUID, failedAttemptCount: UInt16)
    case terminal(deliveryID: UUID, reason: ProgressionExternalSyncTerminalReason)
}

actor ProgressionExternalMergeDeliveryProcessor {
    typealias Apply = @Sendable (
        RuntimeProgressionExternalMergeDelivery
    ) async throws -> ProgressionExternalSyncState
    typealias Acknowledge = @Sendable (
        UUID,
        ProgressionExternalSyncState
    ) async throws -> Void

    private let sleep: @Sendable (TimeInterval) async -> Void
    private var isRunning = true
    private var processingDeliveries: Set<UUID> = []
    private var currentState: ProgressionExternalMergeDeliveryState = .idle

    init(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            guard delay > 0 else { return }
            let nanoseconds = UInt64(min(delay, 60) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
    }

    func start() {
        isRunning = true
        currentState = .idle
    }

    func stop() {
        isRunning = false
        processingDeliveries.removeAll()
        currentState = .stopped
    }

    func state() -> ProgressionExternalMergeDeliveryState { currentState }

    func process(
        _ delivery: RuntimeProgressionExternalMergeDelivery,
        apply: @escaping Apply,
        acknowledge: @escaping Acknowledge
    ) async {
        guard isRunning,
              processingDeliveries.insert(delivery.deliveryID).inserted
        else { return }
        defer { processingDeliveries.remove(delivery.deliveryID) }
        currentState = .processing(deliveryID: delivery.deliveryID)
        var failedAttemptCount: UInt16 = 0
        while isRunning, !Task.isCancelled {
            do {
                let state = try await apply(delivery)
                try await acknowledge(delivery.deliveryID, state)
                currentState = .idle
                return
            } catch {
                switch progressionExternalRetryDecision(
                    for: error,
                    invalidRequestIsStale: true
                ) {
                case let .terminal(reason):
                    currentState = .terminal(
                        deliveryID: delivery.deliveryID,
                        reason: reason
                    )
                    return
                case .retry:
                    break
                }
                failedAttemptCount = min(failedAttemptCount &+ 1, 10)
                currentState = .retrying(
                    deliveryID: delivery.deliveryID,
                    failedAttemptCount: failedAttemptCount
                )
                let delay = min(TimeInterval(1 << failedAttemptCount) * 0.125, 4)
                await sleep(delay)
            }
        }
    }
}

enum ProgressionExternalSnapshotSubmitState: Equatable, Sendable {
    case stopped
    case idle
    case pending(revision: UInt64)
    case retrying(revision: UInt64, failedAttemptCount: UInt16)
    case terminal(revision: UInt64, reason: ProgressionExternalSyncTerminalReason)
}

actor ProgressionExternalSnapshotSubmitProcessor {
    typealias Produce = @Sendable (ProgressionSnapshotDTO) async throws
        -> ProgressionExternalSyncState
    typealias Submit = @Sendable (ProgressionExternalSyncState) async throws
        -> RuntimeProgressionExternalMergeDelivery?
    typealias Delivery = @Sendable (RuntimeProgressionExternalMergeDelivery) async -> Void

    private let sleep: @Sendable (TimeInterval) async -> Void
    private var pending: ProgressionSnapshotDTO?
    private var worker: Task<Void, Never>?
    private var isRunning = true
    private var currentState: ProgressionExternalSnapshotSubmitState = .idle

    init(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { delay in
            guard delay > 0 else { return }
            let nanoseconds = UInt64(min(delay, 60) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.sleep = sleep
    }

    func start() {
        isRunning = true
        currentState = .idle
    }

    func stop() {
        isRunning = false
        pending = nil
        worker?.cancel()
        worker = nil
        currentState = .stopped
    }

    func state() -> ProgressionExternalSnapshotSubmitState { currentState }

    func enqueue(
        _ snapshot: ProgressionSnapshotDTO,
        produce: @escaping Produce,
        submit: @escaping Submit,
        onDelivery: @escaping Delivery
    ) {
        if pending.map({ $0.revision <= snapshot.revision }) ?? true {
            pending = snapshot
        }
        currentState = .pending(revision: pending?.revision ?? snapshot.revision)
        guard worker == nil, isRunning else { return }
        worker = Task { [weak self] in
            await self?.drain(
                produce: produce,
                submit: submit,
                onDelivery: onDelivery
            )
        }
    }

    private func drain(
        produce: @escaping Produce,
        submit: @escaping Submit,
        onDelivery: @escaping Delivery
    ) async {
        var failedAttemptCount: UInt16 = 0
        while isRunning, !Task.isCancelled, let snapshot = pending {
            pending = nil
            do {
                let state = try await produce(snapshot)
                if let delivery = try await submit(state) {
                    await onDelivery(delivery)
                }
                failedAttemptCount = 0
                currentState = pending.map { .pending(revision: $0.revision) } ?? .idle
            } catch {
                switch progressionExternalRetryDecision(
                    for: error,
                    invalidRequestIsStale: false
                ) {
                case let .terminal(reason):
                    pending = nil
                    currentState = .terminal(
                        revision: snapshot.revision,
                        reason: reason
                    )
                    worker = nil
                    return
                case .retry:
                    break
                }
                if pending.map({ $0.revision < snapshot.revision }) ?? true {
                    pending = snapshot
                }
                failedAttemptCount = min(failedAttemptCount &+ 1, 10)
                currentState = .retrying(
                    revision: pending?.revision ?? snapshot.revision,
                    failedAttemptCount: failedAttemptCount
                )
                let delay = min(TimeInterval(1 << failedAttemptCount) * 0.125, 4)
                await sleep(delay)
            }
        }
        worker = nil
        if isRunning, pending != nil {
            enqueue(
                pending!,
                produce: produce,
                submit: submit,
                onDelivery: onDelivery
            )
        } else if isRunning {
            currentState = .idle
        }
    }
}

enum ProgressionExternalLifecycleState: Equatable, Sendable {
    case stopped
    case running
    case retryingMergeStream(failedAttemptCount: UInt16)
    case terminal(ProgressionExternalSyncTerminalReason)
}

actor RuneScribeProgressionModuleLifecycle {
    private var service: RuneScribeProgressionServiceActor?
    private var snapshotTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    private let deliveryProcessor = ProgressionExternalMergeDeliveryProcessor()
    private let snapshotProcessor = ProgressionExternalSnapshotSubmitProcessor()
    private var externalLifecycleState: ProgressionExternalLifecycleState = .stopped

    func externalSyncLifecycleState() -> ProgressionExternalLifecycleState {
        externalLifecycleState
    }

    func start(
        _ service: RuneScribeProgressionServiceActor,
        client: RuntimeProgressionExternalSyncClient,
        observationMetadata: RuntimeOperationMetadata
    ) async {
        self.service = service
        externalLifecycleState = .running
        await deliveryProcessor.start()
        await snapshotProcessor.start()
        let snapshots = service.stateStream(metadata: observationMetadata)
        snapshotTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                await self?.enqueueSnapshot(
                    snapshot,
                    service: service,
                    client: client
                )
            }
            guard !Task.isCancelled else { return }
            let reason = await service.stateStreamTerminationReason() ?? .contextEnded
            await self?.terminateExternalSync(reason: reason)
        }
        mergeTask = Task { [weak self] in
            var failedAttemptCount: UInt16 = 0
            while !Task.isCancelled {
                do {
                    let deliveries = try await client.mergeDeliveries()
                    guard !Task.isCancelled else { return }
                    failedAttemptCount = 0
                    await self?.setExternalLifecycleState(.running)
                    for await delivery in deliveries {
                        guard !Task.isCancelled else { return }
                        await self?.handle(delivery, service: service, client: client)
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    switch progressionExternalRetryDecision(
                        for: error,
                        invalidRequestIsStale: false
                    ) {
                    case let .terminal(reason):
                        await self?.setExternalLifecycleState(.terminal(reason))
                        return
                    case .retry:
                        failedAttemptCount = min(failedAttemptCount &+ 1, 10)
                        await self?.setExternalLifecycleState(.retryingMergeStream(
                            failedAttemptCount: failedAttemptCount
                        ))
                        let delay = min(
                            TimeInterval(1 << failedAttemptCount) * 0.125,
                            4
                        )
                        let nanoseconds = UInt64(delay * 1_000_000_000)
                        try? await Task.sleep(nanoseconds: nanoseconds)
                    }
                }
            }
        }
    }

    func stop() async {
        snapshotTask?.cancel()
        mergeTask?.cancel()
        snapshotTask = nil
        mergeTask = nil
        await deliveryProcessor.stop()
        await snapshotProcessor.stop()
        externalLifecycleState = .stopped
        let service = self.service
        self.service = nil
        await service?.shutdown()
    }

    private func setExternalLifecycleState(_ state: ProgressionExternalLifecycleState) {
        switch externalLifecycleState {
        case .stopped, .terminal:
            return
        case .running, .retryingMergeStream:
            break
        }
        externalLifecycleState = state
    }

    private func terminateExternalSync(
        reason: ProgressionExternalSyncTerminalReason
    ) async {
        guard externalLifecycleState != .stopped else { return }
        externalLifecycleState = .terminal(reason)
        mergeTask?.cancel()
        mergeTask = nil
        await deliveryProcessor.stop()
        await snapshotProcessor.stop()
    }

    private func handle(
        _ delivery: RuntimeProgressionExternalMergeDelivery,
        service: RuneScribeProgressionServiceActor,
        client: RuntimeProgressionExternalSyncClient
    ) async {
        await deliveryProcessor.process(
            delivery,
            apply: { delivery in
                try await service.applyExternalMerge(delivery)
            },
            acknowledge: { deliveryID, state in
                try await client.acknowledge(
                    deliveryID: deliveryID,
                    updatedSnapshot: state.snapshot,
                    updatedProjection: state.projection
                )
            }
        )
    }

    private func enqueueSnapshot(
        _ snapshot: ProgressionSnapshotDTO,
        service: RuneScribeProgressionServiceActor,
        client: RuntimeProgressionExternalSyncClient
    ) async {
        await snapshotProcessor.enqueue(
            snapshot,
            produce: { snapshot in
                try await service.externalSyncState(capturedAt: snapshot.capturedAt)
            },
            submit: { state in
                try await client.submit(
                    state.snapshot,
                    projection: state.projection
                )
            },
            onDelivery: { [weak self] delivery in
                await self?.handle(delivery, service: service, client: client)
            }
        )
    }
}
