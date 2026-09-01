import CryptoKit
import Foundation
import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeThemeFoundationIntegrationTests: XCTestCase {
    func testEarnedProviderPublishesContributionAndOpaqueResourceWithoutRestart()
        async throws
    {
        let probe = ThemeFoundationConsumerProbe()
        let runtime = makeRuntime()
        let coordinator = coordinatorDescriptor()
        let provider = providerDescriptor(
            id: "com.runescribe.module.synthetic-theme",
            role: "runescribe.theme.synthetic"
        )
        let ui = uiDescriptor()
        let unlockID = try XCTUnwrap(UnlockID(rawValue: "unlock.codex.synthetic"))

        try await runtime.register(
            manifest: manifest(for: coordinator),
            factory: factory(for: coordinator) { context in
                await probe.capture(
                    reader: try await context.contributionReaderClient(),
                    resolver: try await context.opaqueResourceResolverClient()
                )
            }
        )
        try await runtime.register(
            manifest: manifest(
                for: provider,
                entitlement: EntitlementRequirement(kind: .earned, identifier: unlockID)
            ),
            factory: providerFactory(descriptor: provider)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui)
        )

        try await runtime.start()
        let initialContributions = try await probe.contributions()
        let initialResources = try await probe.resourceMetadata()
        XCTAssertEqual(initialContributions, [])
        XCTAssertEqual(initialResources, [])

        try await runtime.reconcileEntitlements(
            ProgressionEntitlementSnapshotDTO(
                revision: 1,
                capturedAt: Date(timeIntervalSince1970: 1),
                includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                earnedUnlockIDs: [unlockID]
            )
        )

        let contributions = try await probe.contributions()
        XCTAssertEqual(
            contributions,
            [SyntheticThemeContribution(codexID: "codex.synthetic", variant: 1)]
        )
        let metadata = try await probe.resourceMetadata()
        XCTAssertEqual(metadata.map(\.handle), [Self.resourceHandle])
        let resolvedData = try await probe.resourceData()
        XCTAssertEqual(resolvedData, Self.resourceData)
        let activeSnapshot = await runtime.snapshot()
        XCTAssertEqual(activeSnapshot.moduleStates[provider.moduleID], .active)

        await runtime.stop()
        do {
            _ = try await probe.contributions()
            XCTFail("Coordinator clients must be revoked when the runtime stops")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }
    }

    func testOptionalProviderFailureRemovesPartialPublicationAndPreservesUIStart()
        async throws
    {
        let probe = ThemeFoundationConsumerProbe()
        let runtime = makeRuntime()
        let coordinator = coordinatorDescriptor()
        let provider = providerDescriptor(
            id: "com.runescribe.module.a-failing-theme",
            role: "runescribe.theme.failing"
        )
        let ui = uiDescriptor()

        try await runtime.register(
            manifest: manifest(for: coordinator),
            factory: factory(for: coordinator) { context in
                await probe.capture(
                    reader: try await context.contributionReaderClient(),
                    resolver: try await context.opaqueResourceResolverClient()
                )
            }
        )
        try await runtime.register(
            manifest: manifest(for: provider),
            factory: providerFactory(descriptor: provider, failAfterPublication: true)
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui)
        )

        try await runtime.start()
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.status, .running)
        XCTAssertEqual(snapshot.moduleStates[provider.moduleID], .failed)
        XCTAssertEqual(snapshot.moduleStates[ui.moduleID], .active)
        let contributions = try await probe.contributions()
        let resources = try await probe.resourceMetadata()
        XCTAssertEqual(contributions, [])
        XCTAssertEqual(resources, [])

        await runtime.stop()
    }

    private func makeRuntime() -> RuneScribeRuntime {
        RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 0) },
                nextUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
            )
        )
    }

    private func coordinatorDescriptor() -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.module.theme-coordinator-test",
            moduleVersion: Self.version,
            kind: .service,
            entryPoint: "SyntheticThemeCoordinator",
            role: RuneScribeRoles.themeCoordinator,
            policyClass: RuneScribePolicyClasses.themeCoordinator,
            requestedCapabilities: [
                RuneScribeCapabilities.contributionRead,
                RuneScribeCapabilities.opaqueResourceResolve,
            ]
        )
    }

    private func providerDescriptor(
        id: ModuleIdentifier,
        role: ModuleRole
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: id,
            moduleVersion: Self.version,
            kind: .service,
            criticality: .optional,
            entryPoint: id.rawValue.replacingOccurrences(of: ".", with: "_"),
            role: role,
            policyClass: RuneScribePolicyClasses.themeProvider,
            requestedCapabilities: [
                RuneScribeCapabilities.contributionPublish,
                RuneScribeCapabilities.opaqueResourcePublish,
            ]
        )
    }

    private func uiDescriptor() -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.module.theme-foundation-ui-test",
            moduleVersion: Self.version,
            kind: .ui,
            entryPoint: "ThemeFoundationUIModule",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [RuneScribeCapabilities.rootUI]
        )
    }

    private func manifest(
        for descriptor: ModuleDescriptor,
        entitlement: EntitlementRequirement? = nil
    ) -> ModuleManifest {
        ModuleManifest(
            runtimeVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            moduleID: descriptor.moduleID,
            displayName: descriptor.entryPoint,
            moduleVersion: descriptor.moduleVersion,
            moduleType: descriptor.kind,
            criticality: descriptor.criticality,
            supportedPlatforms: [.macOS],
            capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
            entryPoint: descriptor.entryPoint,
            runtimeRequirements: ModuleRuntimeRequirements(),
            defaultRole: descriptor.role,
            policyClass: descriptor.policyClass,
            entitlementRequirement: entitlement
        )
    }

    private func factory(
        for descriptor: ModuleDescriptor,
        start: @escaping @Sendable (ModuleContext) async throws -> Void = { _ in }
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            SyntheticFoundationModule(descriptor: descriptor, startAction: start)
        }
    }

    private func providerFactory(
        descriptor: ModuleDescriptor,
        failAfterPublication: Bool = false
    ) -> AnyModuleFactory {
        factory(for: descriptor) { context in
            let publisher = try await context.contributionPublisherClient()
            _ = try await publisher.publish(
                SyntheticThemeContribution(codexID: "codex.synthetic", variant: 1),
                type: Self.contributionType,
                key: Self.contributionKey
            )
            let resourceProvider = try await context.opaqueResourceProviderClient()
            try await resourceProvider.register(Self.resourceRegistration)
            if failAfterPublication {
                throw SyntheticFoundationFailure.expected
            }
        }
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    private static let contributionType = RuntimeContributionType<SyntheticThemeContribution>(
        id: RuntimeContributionTypeID(rawValue: "theme.descriptor.synthetic")!
    )
    private static let contributionKey = RuntimeContributionKey(
        rawValue: "theme.synthetic"
    )!
    private static let resourceData = Data("{}".utf8)
    private static let resourceHandle = OpaqueResourceHandle(
        namespace: "theme.synthetic",
        resourceID: "descriptor.synthetic"
    )
    private static var resourceRegistration: OpaqueResourceNamespaceRegistration {
        OpaqueResourceNamespaceRegistration(
            namespace: resourceHandle.namespace,
            declarations: [
                OpaqueResourceDeclaration(
                    resourceID: resourceHandle.resourceID,
                    semanticRole: "theme.descriptor",
                    mediaType: .json,
                    byteCount: resourceData.count,
                    sha256: SHA256.hash(data: resourceData).map {
                        String(format: "%02x", $0)
                    }.joined()
                ),
            ],
            resourceLoader: { resourceID in
                resourceID == Self.resourceHandle.resourceID
                    ? Self.resourceData
                    : nil
            }
        )
    }
}

private struct SyntheticThemeContribution: Equatable, Sendable {
    let codexID: String
    let variant: Int
}

private enum SyntheticFoundationFailure: Error {
    case expected
}

private struct SyntheticFoundationModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private actor ThemeFoundationConsumerProbe {
    private var reader: RuntimeContributionReaderClient?
    private var resolver: RuntimeOpaqueResourceResolverClient?

    func capture(
        reader: RuntimeContributionReaderClient,
        resolver: RuntimeOpaqueResourceResolverClient
    ) {
        self.reader = reader
        self.resolver = resolver
    }

    func contributions() async throws -> [SyntheticThemeContribution] {
        guard let reader else {
            throw SyntheticFoundationFailure.expected
        }
        let snapshot = try await reader.snapshot(
            for: RuntimeContributionType<SyntheticThemeContribution>(
                id: RuntimeContributionTypeID(rawValue: "theme.descriptor.synthetic")!
            )
        )
        return snapshot.entries.map(\.value)
    }

    func resourceMetadata() async throws -> [OpaqueResourceMetadata] {
        guard let resolver else {
            throw SyntheticFoundationFailure.expected
        }
        let snapshot = try await resolver.snapshot()
        return snapshot.resources
    }

    func resourceData() async throws -> Data {
        guard let resolver else {
            throw SyntheticFoundationFailure.expected
        }
        let resource = try await resolver.resolve(
            OpaqueResourceHandle(
                namespace: "theme.synthetic",
                resourceID: "descriptor.synthetic"
            )
        )
        return resource.data
    }
}
