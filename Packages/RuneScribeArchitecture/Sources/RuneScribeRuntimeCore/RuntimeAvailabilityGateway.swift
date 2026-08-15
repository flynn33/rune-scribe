import Foundation
import RuneScribeContracts

public struct RuntimeOptionalModuleAvailabilitySnapshot: Equatable, Sendable {
    public let moduleID: ModuleIdentifier
    public let role: ModuleRole
    public let lifecycleState: ModuleLifecycleState

    public init(
        moduleID: ModuleIdentifier,
        role: ModuleRole,
        lifecycleState: ModuleLifecycleState
    ) {
        self.moduleID = moduleID
        self.role = role
        self.lifecycleState = lifecycleState
    }
}

/// Immutable, runtime-owned availability state suitable for presentation by
/// the sole UI module. It reports optional feature lifecycle and canonical
/// entitlements without exposing or retaining any optional module instance.
public struct RuntimeAvailabilitySnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let capturedAt: Date
    public let optionalModules: [RuntimeOptionalModuleAvailabilitySnapshot]
    public let entitlementSnapshot: ProgressionEntitlementSnapshotDTO

    public init(
        revision: UInt64,
        capturedAt: Date,
        optionalModules: [RuntimeOptionalModuleAvailabilitySnapshot],
        entitlementSnapshot: ProgressionEntitlementSnapshotDTO
    ) {
        self.revision = revision
        self.capturedAt = capturedAt
        self.optionalModules = optionalModules.sorted { $0.moduleID < $1.moduleID }
        self.entitlementSnapshot = entitlementSnapshot
    }

    public subscript(role role: ModuleRole) -> RuntimeOptionalModuleAvailabilitySnapshot? {
        optionalModules.first { $0.role == role }
    }
}

public struct RuntimeAvailabilityClient: Sendable {
    private let gateway: RuntimeAvailabilityGateway
    private let lease: ModuleContextLease

    init(gateway: RuntimeAvailabilityGateway, lease: ModuleContextLease) {
        self.gateway = gateway
        self.lease = lease
    }

    public func snapshot() async throws -> RuntimeAvailabilitySnapshot {
        try await lease.requireActive()
        let value = try await gateway.snapshot()
        try await lease.requireActive()
        return value
    }

    public func snapshots() async throws -> AsyncStream<RuntimeAvailabilitySnapshot> {
        try await lease.requireActive()
        let source = try await gateway.stream()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                for await value in source {
                    do {
                        try await lease.requireActive()
                        continuation.yield(value)
                    } catch {
                        continuation.finish()
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

actor RuntimeAvailabilityGateway {
    private let environment: RuntimeEnvironment
    private var runtimeIsActive = false
    private var revision: UInt64 = 0
    private var latest: RuntimeAvailabilitySnapshot?
    private var continuations: [
        UUID: AsyncStream<RuntimeAvailabilitySnapshot>.Continuation
    ] = [:]

    init(environment: RuntimeEnvironment) {
        self.environment = environment
    }

    func activateRuntime(
        optionalModules: [RuntimeOptionalModuleAvailabilitySnapshot],
        entitlementSnapshot: ProgressionEntitlementSnapshotDTO
    ) {
        runtimeIsActive = true
        revision = 0
        latest = RuntimeAvailabilitySnapshot(
            revision: revision,
            capturedAt: environment.now(),
            optionalModules: optionalModules,
            entitlementSnapshot: entitlementSnapshot
        )
    }

    func update(
        optionalModules: [RuntimeOptionalModuleAvailabilitySnapshot],
        entitlementSnapshot: ProgressionEntitlementSnapshotDTO
    ) {
        guard runtimeIsActive else { return }
        let sortedModules = optionalModules.sorted { $0.moduleID < $1.moduleID }
        if let latest,
           latest.optionalModules == sortedModules,
           latest.entitlementSnapshot == entitlementSnapshot
        {
            return
        }
        guard revision < UInt64.max else { return }
        revision += 1
        let snapshot = RuntimeAvailabilitySnapshot(
            revision: revision,
            capturedAt: environment.now(),
            optionalModules: sortedModules,
            entitlementSnapshot: entitlementSnapshot
        )
        latest = snapshot
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    func deactivateRuntime() {
        runtimeIsActive = false
        latest = nil
        let activeContinuations = continuations.values
        continuations.removeAll()
        for continuation in activeContinuations { continuation.finish() }
    }

    func snapshot() throws -> RuntimeAvailabilitySnapshot {
        guard runtimeIsActive, let latest else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        return latest
    }

    func stream() throws -> AsyncStream<RuntimeAvailabilitySnapshot> {
        guard runtimeIsActive, let latest else {
            throw RuneScribeRuntimeError.runtimeNotRunning
        }
        let id = environment.nextUUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(latest)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}
