import Foundation
import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeStopDuringStartTests: XCTestCase {
    func testStopDuringEarlyInfrastructureStartCannotBeErasedOrStrandWaiter() async throws {
        let gate = EarlyRuntimeStartGate()
        let probe = RuntimeStopProbe()
        let core = stopRaceDescriptor(
            id: "com.runescribe.module.early-stop-core",
            kind: .service,
            entryPoint: "EarlyStopCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let ui = stopRaceDescriptor(
            id: "com.runescribe.module.early-stop-ui",
            kind: .ui,
            entryPoint: "EarlyStopUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS,
            startCoordinator: gate
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: core),
            factory: AnyModuleFactory(descriptor: core) {
                StopRaceModule(
                    descriptor: core,
                    startAction: { _ in await probe.recordCoreStart() },
                    stopAction: { await probe.recordCoreStop() }
                )
            }
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                StopRaceModule(
                    descriptor: ui,
                    startAction: { _ in await probe.recordUIStart() },
                    stopAction: { await probe.recordUIStop() }
                )
            }
        )

        let startTask = Task { try await runtime.start() }
        await gate.waitUntilSuspended()
        let stopTask = Task { await runtime.stop() }
        let stoppingObserved = await waitForStatus(.stopping, runtime: runtime)
        XCTAssertTrue(stoppingObserved)

        await gate.release()
        let interrupted = await waitForStatus(.stopped, runtime: runtime)
        if !interrupted {
            await runtime.stop()
        }
        await stopTask.value
        try await startTask.value

        XCTAssertTrue(interrupted)
        let stoppedSnapshot = await runtime.snapshot()
        let interruptedCounts = await probe.counts()
        XCTAssertEqual(stoppedSnapshot.status, .stopped)
        XCTAssertEqual(interruptedCounts.coreStarts, 0)
        XCTAssertEqual(interruptedCounts.coreStops, 0)
        XCTAssertEqual(interruptedCounts.uiStarts, 0)
        XCTAssertEqual(interruptedCounts.uiStops, 0)

        try await runtime.start()
        let restartedSnapshot = await runtime.snapshot()
        XCTAssertEqual(restartedSnapshot.status, .running)
        await runtime.stop()
    }

    func testStopAfterRuntimeMarkedRunningCannotReopenIngressAgainstStoppedDispatcher() async throws {
        let gate = LateRuntimeActivationGate()
        let probe = RuntimeStopProbe()
        let core = stopRaceDescriptor(
            id: "com.runescribe.module.late-stop-core",
            kind: .service,
            entryPoint: "LateStopCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let ui = stopRaceDescriptor(
            id: "com.runescribe.module.late-stop-ui",
            kind: .ui,
            entryPoint: "LateStopUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS,
            startCoordinator: gate
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: core),
            factory: AnyModuleFactory(descriptor: core) {
                StopRaceModule(
                    descriptor: core,
                    startAction: { _ in await probe.recordCoreStart() },
                    stopAction: { await probe.recordCoreStop() }
                )
            }
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                StopRaceModule(
                    descriptor: ui,
                    startAction: { _ in await probe.recordUIStart() },
                    stopAction: { await probe.recordUIStop() }
                )
            }
        )

        let startTask = Task { try await runtime.start() }
        await gate.waitUntilSuspended()
        let stopTask = Task { await runtime.stop() }
        let stoppingObserved = await waitForStatus(.stopping, runtime: runtime)
        XCTAssertTrue(stoppingObserved)
        XCTAssertEqual(runtime.submit(.menu(.openSettings)), .rejected)

        await gate.release()
        await stopTask.value
        try await startTask.value

        let snapshot = await runtime.snapshot()
        let counts = await probe.counts()
        XCTAssertEqual(snapshot.status, .stopped)
        XCTAssertEqual(counts.coreStarts, 1)
        XCTAssertEqual(counts.coreStops, 1)
        XCTAssertEqual(counts.uiStarts, 1)
        XCTAssertEqual(counts.uiStops, 1)
        XCTAssertEqual(runtime.submit(.menu(.openCipherLibrary)), .accepted)
    }

    func testStopDuringFailedStartCleanupRestoresStoppedIngressAdmissions() async throws {
        let cleanupGate = FailedStartCleanupGate()
        let probe = RuntimeStopProbe()
        let core = stopRaceDescriptor(
            id: "com.runescribe.module.failed-cleanup-core",
            kind: .service,
            entryPoint: "FailedCleanupCoreModule",
            role: RuneScribeRoles.core,
            capabilities: []
        )
        let ui = stopRaceDescriptor(
            id: "com.runescribe.module.failed-cleanup-ui",
            kind: .ui,
            entryPoint: "FailedCleanupUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: core),
            factory: AnyModuleFactory(descriptor: core) {
                StopRaceModule(
                    descriptor: core,
                    startAction: { _ in await probe.recordCoreStart() },
                    stopAction: {
                        await cleanupGate.suspendIfNeeded()
                        await probe.recordCoreStop()
                    }
                )
            }
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                StopRaceModule(
                    descriptor: ui,
                    startAction: { _ in throw StopRaceTestError.activationFailed },
                    stopAction: { await probe.recordUIStop() }
                )
            }
        )

        let startTask = Task { try await runtime.start() }
        await cleanupGate.waitUntilSuspended()
        let stopTask = Task { await runtime.stop() }
        let stoppingObserved = await waitForStatus(.stopping, runtime: runtime)
        XCTAssertTrue(stoppingObserved)
        await cleanupGate.release()
        await stopTask.value
        try await startTask.value

        let snapshot = await runtime.snapshot()
        let counts = await probe.counts()
        XCTAssertEqual(snapshot.status, .stopped)
        XCTAssertEqual(counts.coreStarts, 1)
        XCTAssertEqual(counts.coreStops, 1)
        XCTAssertEqual(counts.uiStops, 1)
        XCTAssertEqual(runtime.submit(.menu(.openSettings)), .accepted)
    }

    func testInboundFileReaderRequiresDedicatedCapability() async throws {
        let denied = stopRaceDescriptor(
            id: "com.runescribe.module.inbound-file-denied",
            kind: .service,
            entryPoint: "InboundFileDeniedModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.protectedFileStorage],
            requiredServices: [RuneScribeServiceIDs.inboundFileReader]
        )
        let deniedRuntime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )
        do {
            try await deniedRuntime.register(
                manifest: stopRaceManifest(for: denied),
                factory: AnyModuleFactory(descriptor: denied) {
                    StopRaceModule(descriptor: denied, startAction: { _ in }, stopAction: {})
                }
            )
            XCTFail("Protected storage must not authorize external file reads")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceCapabilityMissing(
                    moduleID: denied.moduleID,
                    service: RuneScribeServiceIDs.inboundFileReader
                )
            )
        }

        let allowed = stopRaceDescriptor(
            id: "com.runescribe.module.inbound-file-allowed",
            kind: .service,
            entryPoint: "InboundFileAllowedModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.inboundFileRead],
            requiredServices: [RuneScribeServiceIDs.inboundFileReader]
        )
        let allowedRuntime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )
        try await allowedRuntime.register(
            manifest: stopRaceManifest(for: allowed),
            factory: AnyModuleFactory(descriptor: allowed) {
                StopRaceModule(descriptor: allowed, startAction: { _ in }, stopAction: {})
            }
        )
    }

    func testStopDuringActivationWaitsForRollbackAndRevokesPublishedServices() async throws {
        let endpointID: RuntimeEndpointIdentifier = "test.stop-during-start.query"
        let endpoint = RuntimeEndpointDescriptor<RuntimeEmptyPayload, StopDuringStartValue>(
            endpointID: endpointID,
            kind: .query,
            destination: .role(RuneScribeRoles.core),
            requestSchemaVersion: RuntimeSchemaVersions.v1,
            responseSchemaVersion: RuntimeSchemaVersions.v1,
            requiredCapability: RuneScribeCapabilities.applicationCommands,
            privacyClass: .internalData,
            maximumRequestBytes: 1,
            maximumResponseBytes: 16
        ).key
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                RuneScribeCapabilities.applicationCommands: [RuneScribeRoles.primaryUI],
                RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS,
            policy: policy
        )
        let gate = RuntimeActivationGate()
        let probe = RuntimeStopProbe()
        let core = stopRaceDescriptor(
            id: "com.runescribe.module.stop-race-core",
            kind: .service,
            entryPoint: "StopRaceCoreModule",
            role: RuneScribeRoles.core,
            capabilities: [],
            publishedEndpoints: [endpointID]
        )
        let ui = stopRaceDescriptor(
            id: "com.runescribe.module.stop-race-ui",
            kind: .ui,
            entryPoint: "StopRaceUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.applicationCommands,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core],
            consumedEndpoints: [endpointID]
        )

        try await runtime.register(
            manifest: stopRaceManifest(for: core),
            factory: AnyModuleFactory(descriptor: core) {
                StopRaceModule(
                    descriptor: core,
                    startAction: { context in
                        await probe.recordCoreStart()
                        await gate.suspend()
                        try await context.registerEndpoint(
                            endpoint,
                            handler: { _, _ in StopDuringStartValue(value: 7) }
                        )
                    },
                    stopAction: { await probe.recordCoreStop() }
                )
            }
        )
        try await runtime.register(
            manifest: stopRaceManifest(for: ui),
            factory: AnyModuleFactory(descriptor: ui) {
                StopRaceModule(
                    descriptor: ui,
                    startAction: { context in
                        let client = try await context.queryClient(
                            to: .role(RuneScribeRoles.core)
                        )
                        _ = client
                        await probe.recordUIStart()
                    },
                    stopAction: { await probe.recordUIStop() }
                )
            }
        )

        let startTask = Task { try await runtime.start() }
        await gate.waitUntilSuspended()
        let stopTask = Task { await runtime.stop() }
        let stopWasObserved = await waitForStopping(runtime)
        XCTAssertTrue(stopWasObserved)

        await gate.release()
        await stopTask.value
        try await startTask.value

        let stoppedSnapshot = await runtime.snapshot()
        let interruptedCounts = await probe.counts()
        XCTAssertEqual(stoppedSnapshot.status, .stopped)
        XCTAssertNil(stoppedSnapshot.activeUIModuleID)
        XCTAssertEqual(interruptedCounts.coreStarts, 1)
        XCTAssertEqual(interruptedCounts.coreStops, 1)
        XCTAssertEqual(interruptedCounts.uiStarts, 0)
        XCTAssertEqual(interruptedCounts.uiStops, 0)

        try await runtime.start()
        let restartedSnapshot = await runtime.snapshot()
        let restartedCounts = await probe.counts()
        XCTAssertEqual(restartedSnapshot.status, .running)
        XCTAssertEqual(restartedCounts.coreStarts, 2)
        XCTAssertEqual(restartedCounts.uiStarts, 1)

        await runtime.stop()
        let finalCounts = await probe.counts()
        XCTAssertEqual(finalCounts.coreStops, 2)
        XCTAssertEqual(finalCounts.uiStops, 1)
    }

    private func waitForStopping(_ runtime: RuneScribeRuntime) async -> Bool {
        await waitForStatus(.stopping, runtime: runtime)
    }

    private func waitForStatus(
        _ expected: RuntimeStatus,
        runtime: RuneScribeRuntime
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await runtime.snapshot().status == expected {
                return true
            }
            await Task.yield()
        }
        return false
    }
}

private struct StopDuringStartValue: Sendable {
    let value: Int
}

private enum StopRaceTestError: Error {
    case activationFailed
}

private actor EarlyRuntimeStartGate: RuntimeStartCoordinating {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func beforeInfrastructureActivation() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor LateRuntimeActivationGate: RuntimeStartCoordinating {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func beforeInfrastructureActivation() async {}

    func afterRuntimeMarkedRunningBeforeIngressActivation() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor FailedStartCleanupGate {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendIfNeeded() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RuntimeActivationGate {
    private var suspended = false
    private var released = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspend() async {
        suspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor RuntimeStopProbe {
    struct Counts: Equatable, Sendable {
        var coreStarts = 0
        var coreStops = 0
        var uiStarts = 0
        var uiStops = 0
    }

    private var storedCounts = Counts()

    func recordCoreStart() { storedCounts.coreStarts += 1 }
    func recordCoreStop() { storedCounts.coreStops += 1 }
    func recordUIStart() { storedCounts.uiStarts += 1 }
    func recordUIStop() { storedCounts.uiStops += 1 }
    func counts() -> Counts { storedCounts }
}

private struct StopRaceModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void
    let stopAction: @Sendable () async -> Void

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {
        await stopAction()
    }
}

private func stopRaceDescriptor(
    id: ModuleIdentifier,
    kind: ModuleKind,
    entryPoint: String,
    role: ModuleRole,
    capabilities: Set<CapabilityIdentifier>,
    requiredServices: Set<ServiceIdentifier> = [],
    publishedServices: Set<ServiceIdentifier> = [],
    requiredRoles: Set<ModuleRole> = [],
    consumedEndpoints: Set<RuntimeEndpointIdentifier> = [],
    publishedEndpoints: Set<RuntimeEndpointIdentifier> = []
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: id,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(33)),
        kind: kind,
        entryPoint: entryPoint,
        role: role,
        requestedCapabilities: capabilities,
        requiredServices: requiredServices,
        publishedServices: publishedServices,
        requiredModuleRoles: requiredRoles,
        consumedEndpoints: consumedEndpoints,
        publishedEndpoints: publishedEndpoints
    )
}

private func stopRaceManifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        minimumOS: MinimumOSVersions(macOS: "15.0"),
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )
}
