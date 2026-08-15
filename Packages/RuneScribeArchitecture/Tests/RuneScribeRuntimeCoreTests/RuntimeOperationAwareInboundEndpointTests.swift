import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

@MainActor
final class RuntimeOperationAwareInboundEndpointTests: XCTestCase {
    func testInboundEndpointPassesRuntimeIssuedContextToOperationAwareService() async throws {
        let now = Date(timeIntervalSince1970: 23_456.789_123)
        let probe = OperationAwareInboundProbe()
        let coreDescriptor = Self.coreDescriptor
        let uiDescriptor = Self.uiDescriptor
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(now: { now }, nextUUID: { UUID() })
        )
        try await runtime.register(
            manifest: manifest(for: coreDescriptor),
            factory: AnyModuleFactory(descriptor: coreDescriptor) {
                OperationAwareInboundModule(
                    descriptor: coreDescriptor,
                    probe: probe
                )
            }
        )
        try await runtime.register(
            manifest: manifest(for: uiDescriptor),
            factory: AnyModuleFactory(descriptor: uiDescriptor) {
                EmptyOperationAwareInboundUIModule(descriptor: uiDescriptor)
            }
        )
        XCTAssertEqual(runtime.submit(.menu(.openSettings)), .accepted)

        try await runtime.start()

        let capturedObservation = await probe.observation()
        let observation = try XCTUnwrap(capturedObservation)
        guard case .menu(let menu) = observation.input else {
            return XCTFail("Expected the menu input to reach Core")
        }
        XCTAssertEqual(menu.command, .openSettings)
        XCTAssertEqual(observation.context.authorityScope, .runtimeGeneration)
        XCTAssertEqual(observation.context.issuingRuntimeGeneration, 1)
        XCTAssertEqual(
            observation.context.runtimeOperationIdentifier.rawValue,
            RuntimeApplicationEndpointCatalog.inboundInput.descriptor.endpointID.rawValue
        )
        XCTAssertEqual(
            observation.context.runtimeOccurredAtUTC.timeIntervalSince1970,
            23_456.789,
            accuracy: 0.000_001
        )
        await runtime.stop()
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )

    private static let coreDescriptor = ModuleDescriptor(
        moduleID: "com.runescribe.test.operation-aware-inbound-core",
        moduleVersion: version,
        kind: .service,
        entryPoint: "OperationAwareInboundModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.inboundInput],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.ingressEndpointIDs
    )

    private static let uiDescriptor = ModuleDescriptor(
        moduleID: "com.runescribe.test.operation-aware-inbound-ui",
        moduleVersion: version,
        kind: .ui,
        entryPoint: "EmptyOperationAwareInboundUIModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [RuneScribeCapabilities.rootUI],
        requiredModuleRoles: [RuneScribeRoles.core]
    )

    private func manifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
        ModuleManifest(
            runtimeVersion: Self.version,
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
}

private struct OperationAwareInboundModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let probe: OperationAwareInboundProbe

    func start(context: ModuleContext) async throws {
        try await context.registerInboundInputEndpoint(probe)
    }

    func stop() async {}
}

private struct EmptyOperationAwareInboundUIModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    func start(context: ModuleContext) async throws {}
    func stop() async {}
}

private struct OperationAwareInboundObservation: Sendable {
    let input: RuneScribeInboundInput
    let context: RuntimePersistableOperationContext
}

private actor OperationAwareInboundProbe: RuneScribeOperationAwareInboundInputService {
    private var storedObservation: OperationAwareInboundObservation?

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        throw OperationAwareInboundProbeError.legacyPath
    }

    func receive(
        _ input: RuneScribeInboundInput,
        context: RuntimePersistableOperationContext
    ) async throws -> InboundInputDispositionDTO {
        storedObservation = OperationAwareInboundObservation(
            input: input,
            context: context
        )
        return .accepted
    }

    func observation() -> OperationAwareInboundObservation? {
        storedObservation
    }
}

private enum OperationAwareInboundProbeError: Error {
    case legacyPath
}
