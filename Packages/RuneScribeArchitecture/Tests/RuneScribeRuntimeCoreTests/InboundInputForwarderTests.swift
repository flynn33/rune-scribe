import Foundation
import RuneScribeContracts
@testable import RuneScribeRuntimeCore
import XCTest

final class InboundInputForwarderTests: XCTestCase {
    func testRuntimeIngressPreservesFIFOAndAuthoritativeMetadata() async throws {
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let thirdDate = Date(timeIntervalSince1970: 300)
        let values = DeterministicIngressValues(
            dates: [firstDate, secondDate, thirdDate],
            uuids: [inputUUID(1), inputUUID(2), inputUUID(3)]
        )
        let rail = RuntimeHostIngressRail(
            environment: RuntimeEnvironment(
                now: { values.nextDate() },
                nextUUID: { values.nextUUID() }
            )
        )
        let recorder = IngressRecorder()
        let firstURL = URL(string: "runescribe://import?p=first")!
        let secondFile = URL(fileURLWithPath: "/in-memory/second.runescribe")

        XCTAssertEqual(
            rail.submit(contentsOf: [
                .url(firstURL, source: .sceneOpen),
                .file(
                    secondFile,
                    declaredContentType: RuneScribeWireFormat.contentType,
                    source: .fileImporter
                ),
            ]),
            [.accepted, .accepted]
        )
        rail.activate { input in
            await recorder.record(input)
            return .accepted
        }
        await rail.flush()
        rail.noteSuccessfulActivation()

        XCTAssertEqual(rail.submit(.menu(.openSettings)), .accepted)
        await rail.flush()

        let received = await recorder.snapshot()
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received.map(\.metadata.id), [
            InboundInputID(rawValue: inputUUID(1)),
            InboundInputID(rawValue: inputUUID(2)),
            InboundInputID(rawValue: inputUUID(3)),
        ])
        XCTAssertEqual(received.map(\.metadata.receivedAt), [
            firstDate, secondDate, thirdDate,
        ])
        XCTAssertEqual(received.map(\.metadata.isColdStart), [true, true, false])
        XCTAssertEqual(received.map(\.metadata.source), [
            .sceneOpen, .fileImporter, .applicationOpen,
        ])
        guard case .url(let receivedURL) = received[0],
              case .file(let receivedFile) = received[1],
              case .menu(let receivedMenu) = received[2]
        else {
            return XCTFail("Runtime ingress changed the callback payload kinds.")
        }
        XCTAssertEqual(receivedURL.url, firstURL)
        XCTAssertEqual(receivedFile.fileURL, secondFile)
        XCTAssertEqual(receivedFile.declaredContentType, RuneScribeWireFormat.contentType)
        XCTAssertTrue(receivedFile.requiresSecurityScopedAccess)
        XCTAssertEqual(receivedMenu.command, .openSettings)
        XCTAssertEqual(rail.snapshot.queuedInputCount, 0)
    }

    func testRuntimeIngressEnforcesBoundsCapacityAndSecurityReserves() async {
        let rail = RuntimeHostIngressRail(environment: .live)
        let oversizedURL = URL(
            string: "runescribe://import?p=" + String(
                repeating: "x",
                count: RuntimeHostIngressRail.maximumURLByteCount
            )
        )!
        let validFile = URL(fileURLWithPath: "/in-memory/valid.runescribe")

        XCTAssertEqual(
            rail.submit(.url(oversizedURL, source: .applicationOpen)),
            .rejected
        )
        XCTAssertEqual(
            rail.submit(
                .file(
                    validFile,
                    declaredContentType: String(
                        repeating: "x",
                        count: RuntimeHostIngressRail.maximumContentTypeByteCount + 1
                    ),
                    source: .fileImporter
                )
            ),
            .rejected
        )

        let dataInputs = (0..<600).map {
            ExternalInputEnvelope.url(
                URL(string: "runescribe://import?p=data-\($0)")!,
                source: .applicationOpen
            )
        }
        let dataDispositions = rail.submit(contentsOf: dataInputs)
        XCTAssertEqual(
            dataDispositions.filter { $0 == .accepted }.count,
            RuntimeHostIngressRail.queueCapacity
                - RuntimeHostIngressRail.reservedControlCapacity
        )

        let ordinaryControlCapacity = RuntimeHostIngressRail.reservedControlCapacity
            - RuntimeHostIngressRail.reservedSecurityLifecycleCapacity
        let ordinaryControls = (0..<ordinaryControlCapacity).map { index in
            ExternalInputEnvelope.lifecycle(
                index.isMultiple(of: 2) ? .didBecomeActive : .willResignActive
            )
        }
        XCTAssertEqual(
            rail.submit(contentsOf: ordinaryControls),
            Array(repeating: .accepted, count: ordinaryControlCapacity)
        )
        XCTAssertEqual(rail.submit(.lifecycle(.willEnterForeground)), .rejected)
        XCTAssertEqual(rail.submit(.lifecycle(.didEnterBackground)), .accepted)
        XCTAssertEqual(rail.submit(.lifecycle(.didEnterBackground)), .duplicate)
        XCTAssertEqual(rail.submit(.lifecycle(.willTerminate)), .accepted)
        XCTAssertEqual(rail.submit(.menu(.openCipherLibrary)), .rejected)

        let snapshot = rail.snapshot
        XCTAssertEqual(snapshot.queuedInputCount, RuntimeHostIngressRail.queueCapacity)
        XCTAssertEqual(
            snapshot.rejectedInputCount,
            4 + dataDispositions.filter { $0 == .rejected }.count
        )
        XCTAssertEqual(snapshot.failedDeliveryCount, 0)
        XCTAssertTrue(snapshot.hasDeliveryFailures)
    }

    func testRuntimeIngressRejectsMenuCapacityPlusOneAndReleasesAfterOffer() async {
        let menuRail = RuntimeHostIngressRail(environment: .live)
        let menuInputs = (0...RuntimeHostIngressRail.menuCapacity).map { index in
            ExternalInputEnvelope.menu(
                index.isMultiple(of: 2) ? .openSettings : .openCipherLibrary
            )
        }
        XCTAssertEqual(
            menuRail.submit(contentsOf: menuInputs),
            Array(repeating: .accepted, count: RuntimeHostIngressRail.menuCapacity)
                + [.rejected]
        )
        XCTAssertEqual(
            menuRail.snapshot.queuedInputCount,
            RuntimeHostIngressRail.menuCapacity
        )

        menuRail.activate { _ in .accepted }
        await menuRail.flush()
        XCTAssertEqual(menuRail.submit(.menu(.openSettings)), .accepted)
        await menuRail.flush()
        XCTAssertEqual(menuRail.snapshot.queuedInputCount, 0)
    }

    func testQuiescedFlushWaitsForAcceptedReservationStampingBeforeSuspend() async {
        let stampingBarrier = BlockingIngressUUIDProvider(uuid: inputUUID(9_001))
        let rail = RuntimeHostIngressRail(
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 9_001) },
                nextUUID: { stampingBarrier.nextUUID() }
            )
        )
        let recorder = IngressRecorder()
        let flushProbe = FlushCompletionProbe()
        rail.activate { input in
            await recorder.record(input)
            return .accepted
        }

        let submission = Task.detached {
            rail.submit(.menu(.openSettings))
        }
        stampingBarrier.waitUntilEntered()
        rail.quiesceAdmissions()

        let stopSequence = Task {
            await flushProbe.markStarted()
            await rail.flush()
            rail.suspend()
            await flushProbe.markFinished()
        }
        await flushProbe.waitUntilStarted()
        for _ in 0..<1_000 {
            if await flushProbe.isFinished() { break }
            await Task.yield()
        }
        let flushFinishedBeforeStamping = await flushProbe.isFinished()
        XCTAssertFalse(
            flushFinishedBeforeStamping,
            "Flush escaped an accepted reservation before metadata stamping completed."
        )

        stampingBarrier.release()
        let submissionDisposition = await submission.value
        XCTAssertEqual(submissionDisposition, .accepted)
        await stopSequence.value

        let received = await recorder.snapshot()
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.metadata.id.rawValue, inputUUID(9_001))
        XCTAssertEqual(rail.snapshot.queuedInputCount, 0)
    }

    func testRuntimeIngressRetainsAcrossStopStartAndRoutesToReplacement() async throws {
        let firstDestination = IngressRecorder()
        let replacementDestination = IngressRecorder()
        let factoryState = ReplacementIngressFactoryState(
            destinations: [firstDestination, replacementDestination]
        )
        let coreDescriptor = ModuleDescriptor(
            moduleID: "com.runescribe.test.ingress-core",
            moduleVersion: Self.moduleVersion,
            kind: .service,
            entryPoint: "RuntimeIngressCoreProbe",
            role: RuneScribeRoles.core,
            requestedCapabilities: [RuneScribeCapabilities.inboundInput],
            requiredServices: [],
            publishedServices: [],
            requiredModuleRoles: [],
            publishedEndpoints: RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
        let uiDescriptor = ModuleDescriptor(
            moduleID: "com.runescribe.test.ingress-ui",
            moduleVersion: Self.moduleVersion,
            kind: .ui,
            entryPoint: "RuntimeIngressUIProbe",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI],
            requiredServices: [],
            publishedServices: [],
            requiredModuleRoles: [RuneScribeRoles.core]
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.runtimeVersion,
            platform: .macOS
        )
        try await runtime.register(
            manifest: manifest(for: coreDescriptor),
            factory: AnyModuleFactory(descriptor: coreDescriptor) {
                RuntimeIngressCoreProbe(
                    descriptor: coreDescriptor,
                    destination: factoryState.nextDestination()
                )
            }
        )
        try await runtime.register(
            manifest: manifest(for: uiDescriptor),
            factory: AnyModuleFactory(descriptor: uiDescriptor) {
                RuntimeIngressUIProbe(descriptor: uiDescriptor)
            }
        )

        XCTAssertEqual(
            runtime.submit(.url(
                URL(string: "runescribe://import?p=cold")!,
                source: .applicationOpen
            )),
            .accepted
        )
        try await runtime.start()
        await runtime.stop()

        XCTAssertEqual(
            runtime.submit(contentsOf: [
                .url(
                    URL(string: "runescribe://import?p=warm")!,
                    source: .webBrowsingActivity
                ),
                .lifecycle(.didEnterBackground),
            ]),
            [.accepted, .accepted]
        )
        XCTAssertEqual(runtime.hostIngressSnapshot.queuedInputCount, 2)

        try await runtime.start()

        let firstInputs = await firstDestination.snapshot()
        let replacementInputs = await replacementDestination.snapshot()
        XCTAssertEqual(firstInputs.count, 1)
        XCTAssertEqual(replacementInputs.count, 2)
        XCTAssertEqual(firstInputs.map(\.metadata.isColdStart), [true])
        XCTAssertEqual(replacementInputs.map(\.metadata.isColdStart), [false, false])
        XCTAssertEqual(
            Set((firstInputs + replacementInputs).map(\.metadata.id)).count,
            3
        )
        XCTAssertEqual(runtime.hostIngressSnapshot.queuedInputCount, 0)
        await runtime.stop()
    }

    func testRuntimeIngressDoesNotReplayOfferedInputAcrossReplacement() async {
        let rail = RuntimeHostIngressRail(environment: .live)
        let barrier = OfferedInputBarrier()
        let firstDestination = IngressRecorder()
        let replacementDestination = IngressRecorder()
        let inputs: [ExternalInputEnvelope] = [
            .menu(.openSettings),
            .lifecycle(.didBecomeActive),
            .lifecycle(.willResignActive),
        ]

        rail.activate { input in
            await firstDestination.record(input)
            await barrier.enterAndWait()
            return .accepted
        }
        XCTAssertEqual(
            rail.submit(contentsOf: inputs),
            [.accepted, .accepted, .accepted]
        )
        await barrier.waitUntilEntered()

        rail.suspend()
        rail.activate { input in
            await replacementDestination.record(input)
            return .accepted
        }
        await barrier.release()
        await rail.flush()

        let firstInputs = await firstDestination.snapshot()
        let replacementInputs = await replacementDestination.snapshot()
        XCTAssertEqual(firstInputs.count, 1)
        XCTAssertEqual(replacementInputs.count, 2)
        let allIDs = (firstInputs + replacementInputs).map(\.metadata.id)
        XCTAssertEqual(Set(allIDs).count, 3)
        XCTAssertEqual(allIDs.count, 3)
        guard firstInputs.count == 1, replacementInputs.count == 2 else {
            return
        }
        guard case .menu = firstInputs[0],
              case .lifecycle(let second) = replacementInputs[0],
              case .lifecycle(let third) = replacementInputs[1]
        else {
            return XCTFail("Replacement changed ingress FIFO kinds.")
        }
        XCTAssertEqual(second.event, .didBecomeActive)
        XCTAssertEqual(third.event, .willResignActive)
        XCTAssertEqual(rail.snapshot.queuedInputCount, 0)
    }

    func testRuntimeIngressRetriesDestinationResolutionOnceWithoutReordering() async {
        let values = DeterministicIngressValues(
            dates: [
                Date(timeIntervalSince1970: 4_001),
                Date(timeIntervalSince1970: 4_002),
            ],
            uuids: [inputUUID(4_001), inputUUID(4_002)]
        )
        let rail = RuntimeHostIngressRail(
            environment: RuntimeEnvironment(
                now: { values.nextDate() },
                nextUUID: { values.nextUUID() }
            )
        )
        let destination = ReplacingIngressDestination()
        rail.activate { input in
            try await destination.deliver(input)
        }

        XCTAssertEqual(
            rail.submit(contentsOf: [
                .url(
                    URL(string: "runescribe://import?p=first")!,
                    source: .applicationOpen
                ),
                .url(
                    URL(string: "runescribe://import?p=second")!,
                    source: .applicationOpen
                ),
            ]),
            [.accepted, .accepted]
        )
        await rail.flush()

        let result = await destination.snapshot()
        XCTAssertEqual(RuntimeHostIngressRail.maximumDestinationResolutionRetries, 1)
        XCTAssertEqual(result.attemptedIDs, [
            InboundInputID(rawValue: inputUUID(4_001)),
            InboundInputID(rawValue: inputUUID(4_001)),
            InboundInputID(rawValue: inputUUID(4_002)),
        ])
        XCTAssertEqual(result.deliveredIDs, [
            InboundInputID(rawValue: inputUUID(4_001)),
            InboundInputID(rawValue: inputUUID(4_002)),
        ])
        XCTAssertEqual(rail.snapshot.queuedInputCount, 0)
        XCTAssertEqual(rail.snapshot.failedDeliveryCount, 0)
    }

    func testRuntimeIngressReportsNoEligibleDestinationWithBoundedCounts() async {
        let dispatcher = RuntimeOperationDispatcher(
            policy: .patternBFoundation,
            environment: .live
        )
        _ = await dispatcher.beginRuntimeStart()
        await dispatcher.registerHostSource(
            consumedEndpoints: RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
        await dispatcher.markRuntimeRunning()

        let rail = RuntimeHostIngressRail(environment: .live)
        let failureCapture = IngressFailureCapture()
        rail.observeFailures { failure in
            failureCapture.record(failure)
        }
        rail.activate { input in
            try await dispatcher.dispatchHostIngress(input)
        }
        XCTAssertEqual(
            rail.submit(.url(
                URL(string: "runescribe://import?p=unroutable")!,
                source: .applicationOpen
            )),
            .accepted
        )
        await rail.flush()

        let snapshot = rail.snapshot
        XCTAssertEqual(snapshot.queuedInputCount, 0)
        XCTAssertEqual(snapshot.rejectedInputCount, 0)
        XCTAssertEqual(snapshot.failedDeliveryCount, 1)
        XCTAssertTrue(snapshot.hasDeliveryFailures)
        XCTAssertEqual(snapshot.lastFailure, .destinationUnavailable)
        XCTAssertEqual(failureCapture.snapshot(), [.destinationUnavailable])

        let ledger = await dispatcher.ledgerSnapshot()
        XCTAssertEqual(
            ledger.count,
            RuntimeHostIngressRail.maximumDestinationResolutionRetries + 1
        )
        XCTAssertTrue(ledger.allSatisfy { entry in
            entry.endpointKind == .ingress
                && entry.metadata.destinationModuleID == nil
                && entry.requestByteCount == 0
                && entry.outcome == .denied(.inactiveDestination)
        })
        XCTAssertNotNil(RuneScribeRuntimeError.ingressDestinationUnavailable.errorDescription)
    }

    private func inputUUID(_ value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-0000-0000-%012llx",
                value
            )
        )!
    }

    private func manifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
        ModuleManifest(
            runtimeVersion: Self.runtimeVersion,
            moduleID: descriptor.moduleID,
            displayName: descriptor.entryPoint,
            moduleVersion: descriptor.moduleVersion,
            moduleType: descriptor.kind,
            supportedPlatforms: [.macOS],
            minimumOS: MinimumOSVersions(macOS: "15.0"),
            capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
            entryPoint: descriptor.entryPoint,
            runtimeRequirements: ModuleRuntimeRequirements(
                requiredServices: descriptor.requiredServices.sorted(),
                requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
            ),
            defaultRole: descriptor.role
        )
    }

    private static let runtimeVersion = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    private static let moduleVersion = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(1)
    )
}

private actor IngressRecorder: RuneScribeInboundInputService {
    private var inputs: [RuneScribeInboundInput] = []

    func record(_ input: RuneScribeInboundInput) {
        inputs.append(input)
    }

    func snapshot() -> [RuneScribeInboundInput] {
        inputs
    }

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        inputs.append(input)
        return .accepted
    }
}

private actor ReplacingIngressDestination {
    private var attemptedIDs: [InboundInputID] = []
    private var deliveredIDs: [InboundInputID] = []
    private var destinationIsAvailable = false

    func deliver(
        _ input: RuneScribeInboundInput
    ) throws -> InboundInputDispositionDTO {
        attemptedIDs.append(input.metadata.id)
        if !destinationIsAvailable {
            destinationIsAvailable = true
            throw RuntimeHostIngressRoutingError
                .destinationUnavailableBeforeInvocation
        }
        deliveredIDs.append(input.metadata.id)
        return .accepted
    }

    func snapshot() -> (attemptedIDs: [InboundInputID], deliveredIDs: [InboundInputID]) {
        (attemptedIDs, deliveredIDs)
    }
}

private final class IngressFailureCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [RuntimeHostIngressFailure] = []

    func record(_ failure: RuntimeHostIngressFailure) {
        lock.lock()
        failures.append(failure)
        lock.unlock()
    }

    func snapshot() -> [RuntimeHostIngressFailure] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }
}

private struct RuntimeIngressCoreProbe: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let destination: IngressRecorder

    func start(context: ModuleContext) async throws {
        try await context.registerInboundInputEndpoint(destination)
    }

    func stop() async {}
}

private struct RuntimeIngressUIProbe: RuneScribeModule {
    let descriptor: ModuleDescriptor

    func start(context: ModuleContext) async throws {}
    func stop() async {}
}

private final class ReplacementIngressFactoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var destinations: [IngressRecorder]

    init(destinations: [IngressRecorder]) {
        self.destinations = destinations
    }

    func nextDestination() -> IngressRecorder {
        lock.lock()
        defer { lock.unlock() }
        precondition(!destinations.isEmpty)
        return destinations.removeFirst()
    }
}

private actor OfferedInputBarrier {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor FlushCompletionProbe {
    private var started = false
    private var finished = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func markFinished() {
        finished = true
    }

    func isFinished() -> Bool {
        finished
    }
}

private final class BlockingIngressUUIDProvider: @unchecked Sendable {
    private let condition = NSCondition()
    private let uuid: UUID
    private var entered = false
    private var released = false

    init(uuid: UUID) {
        self.uuid = uuid
    }

    func nextUUID() -> UUID {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
        return uuid
    }

    func waitUntilEntered() {
        condition.lock()
        while !entered {
            condition.wait()
        }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class DeterministicIngressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var dates: [Date]
    private var uuids: [UUID]

    init(dates: [Date], uuids: [UUID]) {
        self.dates = dates
        self.uuids = uuids
    }

    func nextDate() -> Date {
        withLock { dates.removeFirst() }
    }

    func nextUUID() -> UUID {
        withLock { uuids.removeFirst() }
    }

    private func withLock<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
