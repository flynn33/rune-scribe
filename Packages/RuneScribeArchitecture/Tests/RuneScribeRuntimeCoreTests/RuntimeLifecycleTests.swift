import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class RuntimeLifecycleTests: XCTestCase {
    func testFactoriesAreLazyAndServiceActivatesBeforeUI() async throws {
        let recorder = RuntimeRecorder()
        let coreCounter = FactoryCounter()
        let uiCounter = FactoryCounter()
        let core = descriptor(
            id: "com.runescribe.module.test-core",
            kind: .service,
            entryPoint: "TestCoreModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishEvents]
        )
        let ui = descriptor(
            id: "com.runescribe.module.test-ui",
            kind: .ui,
            entryPoint: "TestUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.subscribeEvents,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime()

        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, label: "ui", recorder: recorder, counter: uiCounter)
        )
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, label: "core", recorder: recorder, counter: coreCounter)
        )

        XCTAssertEqual(coreCounter.value, 0)
        XCTAssertEqual(uiCounter.value, 0)

        try await runtime.start()
        try await runtime.start()

        XCTAssertEqual(coreCounter.value, 1)
        XCTAssertEqual(uiCounter.value, 1)
        let startedValues = await recorder.values()
        let runningSnapshot = await runtime.snapshot()
        XCTAssertEqual(startedValues, ["start:core", "start:ui"])
        XCTAssertEqual(
            runningSnapshot.activationOrder,
            [core.moduleID, ui.moduleID]
        )

        await runtime.stop()
        await runtime.stop()
        let stoppedValues = await recorder.values()
        XCTAssertEqual(
            stoppedValues,
            ["start:core", "start:ui", "stop:ui", "stop:core"]
        )
    }

    func testExactlyOneEligibleUIIsRequired() async throws {
        let core = descriptor(
            id: "com.runescribe.module.test-core",
            kind: .service,
            entryPoint: "TestCoreModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishEvents]
        )
        let noUIRuntime = makeRuntime()
        try await noUIRuntime.register(
            manifest: manifest(for: core),
            factory: factory(for: core)
        )

        do {
            try await noUIRuntime.start()
            XCTFail("Expected the no-UI invariant to fail.")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .noEligibleUIModule)
        }

        let secondaryRole: ModuleRole = "runescribe.ui.secondary"
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                RuneScribeCapabilities.publishEvents: [RuneScribeRoles.core],
                RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI, secondaryRole],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
        let firstUI = descriptor(
            id: "com.runescribe.module.first-ui",
            kind: .ui,
            entryPoint: "FirstUIModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let secondUI = descriptor(
            id: "com.runescribe.module.second-ui",
            kind: .ui,
            entryPoint: "SecondUIModule",
            role: secondaryRole,
            capabilities: [RuneScribeCapabilities.rootUI]
        )
        let multipleUIRuntime = makeRuntime(policy: policy)
        for item in [core, firstUI, secondUI] {
            try await multipleUIRuntime.register(
                manifest: manifest(for: item),
                factory: factory(for: item)
            )
        }

        do {
            try await multipleUIRuntime.start()
            XCTFail("Expected the multiple-UI invariant to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .multipleEligibleUIModules([firstUI.moduleID, secondUI.moduleID])
            )
        }
    }

    func testDeclaredServicePublishesThenResolvesThroughPolicy() async throws {
        let serviceID: ServiceIdentifier = "TestValueService"
        let serviceKey = ServiceKey<TestValue>(serviceID)
        let rule = ServiceAccessRule(
            serviceID: serviceID,
            requiredCapability: RuneScribeCapabilities.resolveService,
            publisherRoles: [RuneScribeRoles.core],
            consumerRoles: [RuneScribeRoles.primaryUI]
        )
        let policy = RuntimePolicy(
            vocabulary: CapabilityVocabulary(knownCapabilities: RuneScribeCapabilities.all),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                RuneScribeCapabilities.publishService: [RuneScribeRoles.core],
                RuneScribeCapabilities.resolveService: [RuneScribeRoles.primaryUI],
                RuneScribeCapabilities.rootUI: [RuneScribeRoles.primaryUI],
            ]),
            services: ServiceAccessPolicy(rules: [rule])
        )
        let core = descriptor(
            id: "com.runescribe.module.service-provider",
            kind: .service,
            entryPoint: "ServiceProviderModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishService],
            publishedServices: [serviceID]
        )
        let ui = descriptor(
            id: "com.runescribe.module.service-consumer",
            kind: .ui,
            entryPoint: "ServiceConsumerModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.resolveService,
                RuneScribeCapabilities.rootUI,
            ],
            requiredServices: [serviceID],
            requiredRoles: [RuneScribeRoles.core]
        )
        let recorder = RuntimeRecorder()
        let runtime = makeRuntime(policy: policy)

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                try await context.publishService(TestValue(value: 42), for: serviceKey)
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                let value = try await context.resolveService(serviceKey)
                await recorder.record(number: value.value)
            })
        )

        try await runtime.start()
        let resolvedNumber = await recorder.number()
        XCTAssertEqual(resolvedNumber, 42)
        await runtime.stop()
    }

    func testUnmappedServiceAndUnknownCapabilityAreDeniedAtRegistration() async throws {
        let serviceID: ServiceIdentifier = "UnmappedService"
        let serviceDescriptor = descriptor(
            id: "com.runescribe.module.unmapped",
            kind: .service,
            entryPoint: "UnmappedModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.publishService],
            publishedServices: [serviceID]
        )
        let runtime = makeRuntime()
        do {
            try await runtime.register(
                manifest: manifest(for: serviceDescriptor),
                factory: factory(for: serviceDescriptor)
            )
            XCTFail("Expected unmapped service registration to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceMappingMissing(moduleID: serviceDescriptor.moduleID, service: serviceID)
            )
        }

        let unknown: CapabilityIdentifier = "runtime.unknown"
        let unknownDescriptor = descriptor(
            id: "com.runescribe.module.unknown-capability",
            kind: .service,
            entryPoint: "UnknownCapabilityModule",
            role: RuneScribeRoles.core,
            capabilities: [unknown]
        )
        do {
            try await runtime.register(
                manifest: manifest(for: unknownDescriptor),
                factory: factory(for: unknownDescriptor)
            )
            XCTFail("Expected unknown capability registration to fail.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .unknownCapability(moduleID: unknownDescriptor.moduleID, capability: unknown)
            )
        }
    }

    func testClipboardCapabilityPolicyDeniesCoreWriteAndUIRead() async throws {
        let coreWriter = descriptor(
            id: "com.runescribe.module.clipboard-core-writer",
            kind: .service,
            entryPoint: "ClipboardCoreWriterModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardWrite],
            requiredServices: [RuneScribeServiceIDs.clipboardWrite]
        )
        let coreRuntime = makeRuntime()

        do {
            try await coreRuntime.register(
                manifest: manifest(for: coreWriter),
                factory: factory(for: coreWriter)
            )
            XCTFail("Expected Core clipboard-write access to be denied.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: coreWriter.moduleID,
                    capability: RuneScribeCapabilities.clipboardWrite
                )
            )
        }

        let uiReader = descriptor(
            id: "com.runescribe.module.clipboard-ui-reader",
            kind: .ui,
            entryPoint: "ClipboardUIReaderModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.clipboardRead,
                RuneScribeCapabilities.rootUI,
            ],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let uiRuntime = makeRuntime()

        do {
            try await uiRuntime.register(
                manifest: manifest(for: uiReader),
                factory: factory(for: uiReader)
            )
            XCTFail("Expected UI clipboard-read access to be denied.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: uiReader.moduleID,
                    capability: RuneScribeCapabilities.clipboardRead
                )
            )
        }
    }

    func testClipboardRoleSpecificServicesResolveAllowedOperations() async throws {
        let clipboard = ClipboardRuntimeProbe(string: "seed", changeCount: 3)
        let reader: any ClipboardReading = clipboard
        let writer: any ClipboardWriting = clipboard
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.clipboard-reader",
            kind: .service,
            entryPoint: "ClipboardReaderModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clipboardRead],
            requiredServices: [RuneScribeServiceIDs.clipboardRead]
        )
        let ui = descriptor(
            id: "com.runescribe.module.clipboard-writer",
            kind: .ui,
            entryPoint: "ClipboardWriterModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.clipboardWrite,
                RuneScribeCapabilities.rootUI,
            ],
            requiredServices: [RuneScribeServiceIDs.clipboardWrite],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime()

        try await runtime.registerHostService(reader, for: RuneScribeServiceKeys.clipboardRead)
        try await runtime.registerHostService(writer, for: RuneScribeServiceKeys.clipboardWrite)
        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                let service = try await context.resolveService(RuneScribeServiceKeys.clipboardRead)
                let value = await service.string()
                await recorder.append("read:\(value ?? "nil")")
                await recorder.record(number: await service.changeCount())
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                let service = try await context.resolveService(RuneScribeServiceKeys.clipboardWrite)
                try await service.setString("updated")
            })
        )

        try await runtime.start()

        let recordedValues = await recorder.values()
        let recordedNumber = await recorder.number()
        let finalString = await clipboard.string()
        let finalChangeCount = await clipboard.changeCount()
        XCTAssertEqual(recordedValues, ["read:seed"])
        XCTAssertEqual(recordedNumber, 3)
        XCTAssertEqual(finalString, "updated")
        XCTAssertEqual(finalChangeCount, 4)
        await runtime.stop()
    }

    func testClockAndUUIDServicesRequireTheirOwnCapabilities() async throws {
        let clockUsingInboundCapability = descriptor(
            id: "com.runescribe.module.clock-with-inbound",
            kind: .service,
            entryPoint: "ClockWithInboundModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.inboundInput],
            requiredServices: [RuneScribeServiceIDs.clock]
        )
        let clockRuntime = makeRuntime()

        do {
            try await clockRuntime.register(
                manifest: manifest(for: clockUsingInboundCapability),
                factory: factory(for: clockUsingInboundCapability)
            )
            XCTFail("Expected the unrelated inbound-input capability to be rejected.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceCapabilityMissing(
                    moduleID: clockUsingInboundCapability.moduleID,
                    service: RuneScribeServiceIDs.clock
                )
            )
        }

        let uuidUsingClockCapability = descriptor(
            id: "com.runescribe.module.uuid-with-clock",
            kind: .service,
            entryPoint: "UUIDWithClockModule",
            role: RuneScribeRoles.core,
            capabilities: [RuneScribeCapabilities.clockRead],
            requiredServices: [RuneScribeServiceIDs.uuid]
        )
        let uuidRuntime = makeRuntime()

        do {
            try await uuidRuntime.register(
                manifest: manifest(for: uuidUsingClockCapability),
                factory: factory(for: uuidUsingClockCapability)
            )
            XCTFail("Expected the clock capability not to authorize UUID generation.")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .serviceCapabilityMissing(
                    moduleID: uuidUsingClockCapability.moduleID,
                    service: RuneScribeServiceIDs.uuid
                )
            )
        }
    }

    func testRuntimeStampsEventsAndDirectedMessages() async throws {
        let date = Date(timeIntervalSince1970: 123)
        let eventUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let messageUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let uuidSequence = UUIDSequence([eventUUID, messageUUID])
        let environment = RuntimeEnvironment(
            now: { date },
            nextUUID: { uuidSequence.next() }
        )
        let recorder = RuntimeRecorder()
        let core = descriptor(
            id: "com.runescribe.module.runtime-source",
            kind: .service,
            entryPoint: "RuntimeSourceModule",
            role: RuneScribeRoles.core,
            capabilities: [
                RuneScribeCapabilities.publishEvents,
                RuneScribeCapabilities.receiveMessages,
            ]
        )
        let ui = descriptor(
            id: "com.runescribe.module.runtime-sender",
            kind: .ui,
            entryPoint: "RuntimeSenderModule",
            role: RuneScribeRoles.primaryUI,
            capabilities: [
                RuneScribeCapabilities.sendMessages,
                RuneScribeCapabilities.rootUI,
            ],
            requiredRoles: [RuneScribeRoles.core]
        )
        let runtime = makeRuntime(environment: environment)

        try await runtime.register(
            manifest: manifest(for: core),
            factory: factory(for: core, start: { context in
                let event = try await context.publishEvent(
                    "test.ready",
                    payload: TestValue(value: 7)
                )
                await recorder.record(event: event)
                try await context.registerMessageHandler { message in
                    await recorder.record(message: message)
                }
            })
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui, start: { context in
                try await context.sendMessage(
                    "test.command",
                    to: RuneScribeRoles.core,
                    payload: TestValue(value: 9)
                )
            })
        )

        try await runtime.start()
        let recordedEvent = await recorder.event()
        let recordedMessage = await recorder.message()
        let event = try XCTUnwrap(recordedEvent)
        let message = try XCTUnwrap(recordedMessage)
        XCTAssertEqual(event.eventID, eventUUID)
        XCTAssertEqual(event.sourceModuleID, core.moduleID)
        XCTAssertEqual(event.timestamp, date)
        XCTAssertEqual(try event.decodePayload(as: TestValue.self), TestValue(value: 7))
        XCTAssertEqual(message.messageID, messageUUID)
        XCTAssertEqual(message.sourceModuleID, ui.moduleID)
        XCTAssertEqual(message.destinationRole, RuneScribeRoles.core)
        XCTAssertEqual(try message.decodePayload(as: TestValue.self), TestValue(value: 9))
        await runtime.stop()
    }
}

private struct TestValue: Codable, Equatable, Sendable {
    let value: Int
}

private actor ClipboardRuntimeProbe: ClipboardReading, ClipboardWriting {
    private var storedString: String?
    private var counter: Int

    init(string: String?, changeCount: Int) {
        storedString = string
        counter = changeCount
    }

    func changeCount() async -> Int {
        counter
    }

    func string() async -> String? {
        storedString
    }

    func setString(_ value: String) async throws {
        storedString = value
        counter += 1
    }
}

private actor RuntimeRecorder {
    private var entries: [String] = []
    private var recordedNumber: Int?
    private var recordedEvent: RuntimeEvent?
    private var recordedMessage: DirectedMessage?

    func append(_ value: String) {
        entries.append(value)
    }

    func values() -> [String] {
        entries
    }

    func record(number: Int) {
        recordedNumber = number
    }

    func number() -> Int? {
        recordedNumber
    }

    func record(event: RuntimeEvent) {
        recordedEvent = event
    }

    func event() -> RuntimeEvent? {
        recordedEvent
    }

    func record(message: DirectedMessage) {
        recordedMessage = message
    }

    func message() -> DirectedMessage? {
        recordedMessage
    }
}

private final class FactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class UUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]

    init(_ values: [UUID]) {
        self.values = values
    }

    func next() -> UUID {
        lock.withLock {
            precondition(!values.isEmpty)
            return values.removeFirst()
        }
    }
}

private struct ProbeModule: RuneScribeModule {
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

private func descriptor(
    id: ModuleIdentifier,
    kind: ModuleKind,
    entryPoint: String,
    role: ModuleRole,
    capabilities: Set<CapabilityIdentifier>,
    requiredServices: Set<ServiceIdentifier> = [],
    publishedServices: Set<ServiceIdentifier> = [],
    requiredRoles: Set<ModuleRole> = []
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
        requiredModuleRoles: requiredRoles
    )
}

private func manifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
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

private func factory(
    for descriptor: ModuleDescriptor,
    label: String? = nil,
    recorder: RuntimeRecorder? = nil,
    counter: FactoryCounter? = nil,
    start: @escaping @Sendable (ModuleContext) async throws -> Void = { _ in }
) -> AnyModuleFactory {
    AnyModuleFactory(descriptor: descriptor) {
        counter?.increment()
        return ProbeModule(
            descriptor: descriptor,
            startAction: { context in
                if let label, let recorder {
                    await recorder.append("start:\(label)")
                }
                try await start(context)
            },
            stopAction: {
                if let label, let recorder {
                    await recorder.append("stop:\(label)")
                }
            }
        )
    }
}

private func makeRuntime(
    policy: RuntimePolicy = .patternBFoundation,
    environment: RuntimeEnvironment = .live
) -> RuneScribeRuntime {
    RuneScribeRuntime(
        runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        platform: .macOS,
        policy: policy,
        environment: environment
    )
}
