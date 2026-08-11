import RuneScribeContracts
@testable import RuneScribeRuntimeCore
@testable import RuneScribeUIPresentationContracts
import SwiftUI
import XCTest

@MainActor
final class RuntimeRootPresentationGatewayTests: XCTestCase {
    func testClientCreationRequiresRootUICapabilityBeforeHostInvocation() async throws {
        let probe = RootPresentationProbe()
        let gateway = RuntimeRootPresentationGateway()
        try await gateway.install(
            probe.adapter(productMetadata: .unavailable),
            for: .standard
        )
        let runtimeGeneration = await gateway.activateRuntime()
        let descriptor = makeDescriptor(capabilities: [])
        try await gateway.activateModule(descriptor: descriptor, generation: 1)

        do {
            _ = try await gateway.makeClient(
                sourceModuleID: descriptor.moduleID,
                sourceModuleGeneration: 1,
                runtimeGeneration: runtimeGeneration,
                policy: .patternBFoundation
            )
            XCTFail("A module without ui.root must not receive the standard port")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: descriptor.moduleID,
                    capability: RuneScribeCapabilities.rootUI
                )
            )
        }

        XCTAssertEqual(probe.presentedModuleIDs, [])
        XCTAssertEqual(probe.dismissedModuleIDs, [])
    }

    func testClientReturnsImmutableMetadataAndPresentsAndDismissesRoot() async throws {
        let metadata = RuneScribeUIProductMetadata(
            version: "9.8.7",
            buildNumber: "654"
        )
        let probe = RootPresentationProbe()
        let gateway = RuntimeRootPresentationGateway()
        try await gateway.install(
            probe.adapter(productMetadata: metadata),
            for: .standard
        )
        let runtimeGeneration = await gateway.activateRuntime()
        let descriptor = makeDescriptor()
        try await gateway.activateModule(descriptor: descriptor, generation: 3)
        let client = try await gateway.makeClient(
            sourceModuleID: descriptor.moduleID,
            sourceModuleGeneration: 3,
            runtimeGeneration: runtimeGeneration,
            policy: .patternBFoundation
        )

        let receivedMetadata = try await client.productMetadata()
        XCTAssertEqual(receivedMetadata, metadata)
        try await client.present(
            RootViewContribution(moduleID: descriptor.moduleID) {
                AnyView(EmptyView())
            }
        )
        XCTAssertEqual(probe.presentedModuleIDs, [descriptor.moduleID])

        try await client.dismiss()
        XCTAssertEqual(probe.dismissedModuleIDs, [descriptor.moduleID])
    }

    func testModuleInvalidationRevokesClientAndDismissesExactlyOnce() async throws {
        let probe = RootPresentationProbe()
        let gateway = RuntimeRootPresentationGateway()
        try await gateway.install(
            probe.adapter(productMetadata: .unavailable),
            for: .standard
        )
        let runtimeGeneration = await gateway.activateRuntime()
        let descriptor = makeDescriptor()
        try await gateway.activateModule(descriptor: descriptor, generation: 7)
        let client = try await gateway.makeClient(
            sourceModuleID: descriptor.moduleID,
            sourceModuleGeneration: 7,
            runtimeGeneration: runtimeGeneration,
            policy: .patternBFoundation
        )
        try await client.present(
            RootViewContribution(moduleID: descriptor.moduleID) {
                AnyView(EmptyView())
            }
        )

        await gateway.invalidateModule(descriptor.moduleID, generation: 7)
        await gateway.invalidateModule(descriptor.moduleID, generation: 7)

        XCTAssertEqual(probe.dismissedModuleIDs, [descriptor.moduleID])
        do {
            _ = try await client.productMetadata()
            XCTFail("A client from an invalidated module generation must be stale")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .staleClient(descriptor.moduleID)
            )
        }
    }

    func testRuntimeGenerationReplacementRevokesOldClient() async throws {
        let probe = RootPresentationProbe()
        let gateway = RuntimeRootPresentationGateway()
        try await gateway.install(
            probe.adapter(productMetadata: .unavailable),
            for: .standard
        )
        let firstRuntimeGeneration = await gateway.activateRuntime()
        let descriptor = makeDescriptor()
        try await gateway.activateModule(descriptor: descriptor, generation: 1)
        let oldClient = try await gateway.makeClient(
            sourceModuleID: descriptor.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: firstRuntimeGeneration,
            policy: .patternBFoundation
        )

        await gateway.deactivateRuntime()
        _ = await gateway.activateRuntime()
        try await gateway.activateModule(descriptor: descriptor, generation: 2)

        do {
            _ = try await oldClient.productMetadata()
            XCTFail("A client from an earlier runtime generation must not revive")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }
    }

    private func makeDescriptor(
        capabilities: Set<CapabilityIdentifier> = [RuneScribeCapabilities.rootUI]
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.test.root-presentation",
            moduleVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            kind: .ui,
            entryPoint: "TestRootPresentationModule",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: capabilities
        )
    }
}

@MainActor
private final class RootPresentationProbe {
    private(set) var presentedModuleIDs: [ModuleIdentifier] = []
    private(set) var dismissedModuleIDs: [ModuleIdentifier] = []

    func adapter(
        productMetadata: RuneScribeUIProductMetadata
    ) -> RuntimeRootPresentationHostAdapter {
        RuntimeRootPresentationHostAdapter(
            productMetadata: productMetadata,
            present: { [weak self] contribution in
                self?.presentedModuleIDs.append(contribution.moduleID)
            },
            dismiss: { [weak self] moduleID in
                self?.dismissedModuleIDs.append(moduleID)
            }
        )
    }
}
