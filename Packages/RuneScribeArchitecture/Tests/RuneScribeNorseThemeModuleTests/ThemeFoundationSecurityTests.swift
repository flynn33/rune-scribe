import Foundation
import RuneScribeContracts
@testable import RuneScribeNorseThemeModule
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

final class ThemeFoundationSecurityTests: XCTestCase {
    func testRawCanonicalThemePublicationRejectsIdentityKeyAndCriticalityBypasses()
        async throws
    {
        let theme = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor

        do {
            let registry = makeCanonicalRegistry()
            let runtimeGeneration = await registry.activateRuntime()
            let spoof = moduleDescriptor(
                moduleID: "com.runescribe.test.theme-spoof",
                role: "runescribe.theme.spoof",
                criticality: .optional,
                policyClass: RuneScribePolicyClasses.themeProvider,
                capabilities: [RuneScribeCapabilities.contributionPublish]
            )
            try await registry.activateModule(descriptor: spoof, generation: 1)
            let publisher = try await registry.makePublisherClient(
                sourceModuleID: spoof.moduleID,
                sourceModuleGeneration: 1,
                runtimeGeneration: runtimeGeneration
            )
            do {
                _ = try await publisher.publish(
                    theme,
                    type: RuntimeThemeContributionCatalog.descriptor,
                    key: RuntimeThemeContributionCatalog.key(for: theme.codex.id)
                )
                XCTFail("A raw publisher must not claim another Theme provider's identity")
            } catch {
                XCTAssertEqual(
                    error as? RuntimeContributionRegistryError,
                    .canonicalIdentityMismatch(
                        RuntimeThemeContributionCatalog.key(for: theme.codex.id)
                    )
                )
            }
        }

        do {
            let registry = makeCanonicalRegistry()
            let runtimeGeneration = await registry.activateRuntime()
            let provider = RuneScribeNorseThemeModuleBootstrap.descriptor
            try await registry.activateModule(descriptor: provider, generation: 2)
            let publisher = try await registry.makePublisherClient(
                sourceModuleID: provider.moduleID,
                sourceModuleGeneration: 2,
                runtimeGeneration: runtimeGeneration
            )
            let wrongKey = try XCTUnwrap(
                RuntimeContributionKey(rawValue: "codex.wrong-key")
            )
            do {
                _ = try await publisher.publish(
                    theme,
                    type: RuntimeThemeContributionCatalog.descriptor,
                    key: wrongKey
                )
                XCTFail("A raw publisher must not detach a Theme from its Codex key")
            } catch {
                XCTAssertEqual(
                    error as? RuntimeContributionRegistryError,
                    .canonicalKeyMismatch(wrongKey)
                )
            }
        }

        do {
            let registry = makeCanonicalRegistry()
            let runtimeGeneration = await registry.activateRuntime()
            let optionalBaseClaim = optionalNorseDescriptor()
            try await registry.activateModule(
                descriptor: optionalBaseClaim,
                generation: 3
            )
            let publisher = try await registry.makePublisherClient(
                sourceModuleID: optionalBaseClaim.moduleID,
                sourceModuleGeneration: 3,
                runtimeGeneration: runtimeGeneration
            )
            let key = RuntimeThemeContributionCatalog.key(for: theme.codex.id)
            do {
                _ = try await publisher.publish(
                    theme,
                    type: RuntimeThemeContributionCatalog.descriptor,
                    key: key
                )
                XCTFail("An optional provider must not claim the required Base Theme")
            } catch {
                XCTAssertEqual(
                    error as? RuntimeContributionRegistryError,
                    .canonicalCriticalityMismatch(key)
                )
            }
        }
    }

    func testCanonicalThemeRulesDoNotSpecializeTheGenericContributionRegistry()
        async throws
    {
        let registry = makeCanonicalRegistry()
        let runtimeGeneration = await registry.activateRuntime()
        let provider = moduleDescriptor(
            moduleID: "com.runescribe.test.generic-contributor",
            role: "runescribe.test.generic-contributor",
            criticality: .optional,
            policyClass: "policy.test.generic-contributor",
            capabilities: [RuneScribeCapabilities.contributionPublish]
        )
        let reader = moduleDescriptor(
            moduleID: "com.runescribe.test.generic-reader",
            role: "runescribe.test.generic-reader",
            criticality: .optional,
            policyClass: "policy.test.generic-reader",
            capabilities: [RuneScribeCapabilities.contributionRead]
        )
        try await registry.activateModule(descriptor: provider, generation: 1)
        try await registry.activateModule(descriptor: reader, generation: 1)
        let publisher = try await registry.makePublisherClient(
            sourceModuleID: provider.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration
        )
        let readClient = try await registry.makeReaderClient(
            sourceModuleID: reader.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration
        )
        let type = RuntimeContributionType<GenericContribution>(
            id: RuntimeContributionTypeID(rawValue: "runtime.generic-test")!
        )
        let key = RuntimeContributionKey(rawValue: "generic.entry")!
        _ = try await publisher.publish(
            GenericContribution(value: 7),
            type: type,
            key: key
        )

        let snapshot = try await readClient.snapshot(for: type)
        XCTAssertEqual(snapshot.entries.map(\.value), [GenericContribution(value: 7)])
    }

    func testTypedThemePublishRollsBackResourcesWhenCanonicalPublicationFails()
        async throws
    {
        let probe = ThemeRollbackProbe()
        let runtime = makeRuntime()
        try await runtime.installPlatformAdapter(
            NorseBundleResourceLocator(),
            for: RuneScribeServiceKeys.applicationResourceLocator
        )

        let coordinator = coordinatorDescriptor()
        let optionalBaseClaim = optionalNorseDescriptor(
            requiredModuleRoles: [coordinator.role]
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
            manifest: manifest(
                for: optionalBaseClaim,
                entitlement: EntitlementRequirement(
                    kind: .always,
                    identifier: RuneScribeUnlockIDs.norseCodex
                )
            ),
            factory: factory(for: optionalBaseClaim) { context in
                let runtimeIO = try await context.runtimeIOClient()
                let theme = try await NorseBaseThemeResources.loadValidated(
                    using: runtimeIO
                )
                do {
                    try await context.publishTheme(
                        descriptor: theme.descriptor,
                        resourcePayloads: theme.resourcePayloads
                    )
                    await probe.recordUnexpectedSuccess()
                } catch {
                    let expectedKey = RuntimeThemeContributionCatalog.key(
                        for: theme.descriptor.codex.id
                    )
                    let isExpectedFailure = (error as? RuntimeContributionRegistryError)
                        == .canonicalCriticalityMismatch(expectedKey)
                    let counts = try await probe.currentCounts()
                    await probe.recordRollback(
                        matchedExpectedError: isExpectedFailure,
                        contributionCount: counts.contributions,
                        resourceCount: counts.resources
                    )
                    throw error
                }
            }
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui)
        )

        try await runtime.start()
        let runtimeSnapshot = await runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(
            runtimeSnapshot.moduleStates[optionalBaseClaim.moduleID],
            .failed
        )
        let rollbackValue = await probe.rollbackResult()
        let rollback = try XCTUnwrap(rollbackValue)
        XCTAssertTrue(rollback.matchedExpectedError)
        XCTAssertEqual(rollback.contributionCount, 0)
        XCTAssertEqual(rollback.resourceCount, 0)

        await runtime.stop()
    }

    func testThemeDiscoveryEntitlementMismatchIsRejectedWithoutRegistrationResidue()
        async throws
    {
        let runtime = makeRuntime()
        let descriptor = RuneScribeNorseThemeModuleBootstrap.descriptor
        let discovery = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let wrongEntitlement = EntitlementRequirement(
            kind: .earned,
            identifier: RuneScribeUnlockIDs.norseCodex
        )
        let key = RuntimeThemeContributionCatalog.key(for: discovery.codex.id)

        do {
            try await runtime.register(
                manifest: manifest(
                    for: descriptor,
                    entitlement: wrongEntitlement
                ),
                factory: RuneScribeNorseThemeModuleBootstrap.factory(),
                themeDiscovery: discovery
            )
            XCTFail("Required Base discovery must use the always entitlement contract")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .canonicalCriticalityMismatch(key)
            )
        }

        try await runtime.register(
            manifest: manifest(
                for: descriptor,
                entitlement: EntitlementRequirement(
                    kind: .always,
                    identifier: RuneScribeUnlockIDs.norseCodex
                )
            ),
            factory: RuneScribeNorseThemeModuleBootstrap.factory(),
            themeDiscovery: discovery
        )
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.moduleStates[descriptor.moduleID], .registered)
    }

    func testOptionalProviderCannotRegisterRequiredBaseDiscoveryAndFailureIsIsolated()
        async throws
    {
        let runtime = makeRuntime()
        let optionalBaseClaim = optionalNorseDescriptor()
        let discovery = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let key = RuntimeThemeContributionCatalog.key(for: discovery.codex.id)
        let candidateManifest = manifest(
            for: optionalBaseClaim,
            entitlement: EntitlementRequirement(
                kind: .earned,
                identifier: RuneScribeUnlockIDs.norseCodex
            )
        )

        do {
            try await runtime.register(
                manifest: candidateManifest,
                factory: factory(for: optionalBaseClaim),
                themeDiscovery: discovery
            )
            XCTFail("Optional registration must not advertise required Base discovery")
        } catch {
            XCTAssertEqual(
                error as? RuntimeContributionRegistryError,
                .canonicalCriticalityMismatch(key)
            )
        }

        try await runtime.register(
            manifest: candidateManifest,
            factory: factory(for: optionalBaseClaim)
        )
        let snapshot = await runtime.snapshot()
        XCTAssertEqual(snapshot.moduleStates[optionalBaseClaim.moduleID], .registered)
    }

    func testOptionalManifestFailureRetainsSuppliedThemeDiscoveryAsUnavailable()
        async throws
    {
        let runtime = makeRuntime()
        let discovery = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let failedProvider = optionalNorseDescriptor()
        let availabilityProbe = ThemeAvailabilityProbe()
        let coordinator = moduleDescriptor(
            moduleID: "com.runescribe.test.failed-discovery-coordinator",
            role: RuneScribeRoles.themeCoordinator,
            criticality: .required,
            policyClass: RuneScribePolicyClasses.themeCoordinator,
            capabilities: [RuneScribeCapabilities.runtimeAvailabilityRead]
        )
        let ui = uiDescriptor()

        try await runtime.register(
            manifestData: Data("{".utf8),
            factory: factory(for: failedProvider),
            themeDiscovery: discovery
        )
        try await runtime.register(
            manifest: manifest(for: coordinator),
            factory: factory(for: coordinator) { context in
                await availabilityProbe.capture(
                    try await context.runtimeAvailabilityClient()
                )
            }
        )
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui)
        )

        try await runtime.start()
        let availability = try await availabilityProbe.snapshot()

        XCTAssertEqual(
            availability.themeProviders,
            [
                RuntimeThemeProviderAvailabilitySnapshot(
                    descriptor: discovery,
                    lifecycleState: .failed
                ),
            ]
        )
        XCTAssertEqual(
            availability.optionalModules.first(where: {
                $0.moduleID == failedProvider.moduleID
            })?.lifecycleState,
            .failed
        )
        await runtime.stop()
    }

    private func makeCanonicalRegistry() -> RuntimeContributionRegistry {
        RuntimeContributionRegistry(
            publishCapabilityID: RuneScribeCapabilities.contributionPublish,
            readCapabilityID: RuneScribeCapabilities.contributionRead,
            authorization: { _, _ in true },
            canonicalRules: RuntimeContributionCatalog.canonicalRules
        )
    }

    private func makeRuntime() -> RuneScribeRuntime {
        RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_200) },
                nextUUID: {
                    UUID(uuidString: "00000000-0000-0000-0000-000000000401")!
                }
            )
        )
    }

    private func optionalNorseDescriptor(
        requiredModuleRoles: Set<ModuleRole> = []
    ) -> ModuleDescriptor {
        let source = RuneScribeNorseThemeModuleBootstrap.descriptor
        return ModuleDescriptor(
            moduleID: source.moduleID,
            moduleVersion: source.moduleVersion,
            kind: source.kind,
            criticality: .optional,
            entryPoint: source.entryPoint,
            role: source.role,
            policyClass: source.policyClass,
            requestedCapabilities: source.requestedCapabilities,
            requiredServices: source.requiredServices,
            requiredResources: source.requiredResources,
            publishedServices: source.publishedServices,
            requiredModuleRoles: source.requiredModuleRoles.union(requiredModuleRoles),
            consumedEndpoints: source.consumedEndpoints,
            publishedEndpoints: source.publishedEndpoints
        )
    }

    private func coordinatorDescriptor() -> ModuleDescriptor {
        moduleDescriptor(
            moduleID: "com.runescribe.test.theme-rollback-coordinator",
            role: RuneScribeRoles.themeCoordinator,
            criticality: .required,
            policyClass: RuneScribePolicyClasses.themeCoordinator,
            capabilities: [
                RuneScribeCapabilities.contributionRead,
                RuneScribeCapabilities.opaqueResourceResolve,
            ]
        )
    }

    private func uiDescriptor() -> ModuleDescriptor {
        moduleDescriptor(
            moduleID: "com.runescribe.test.theme-rollback-ui",
            role: RuneScribeRoles.primaryUI,
            criticality: .required,
            policyClass: ModulePolicyClass(role: RuneScribeRoles.primaryUI),
            capabilities: [RuneScribeCapabilities.rootUI],
            kind: .ui
        )
    }

    private func moduleDescriptor(
        moduleID: ModuleIdentifier,
        role: ModuleRole,
        criticality: ModuleCriticality,
        policyClass: ModulePolicyClass,
        capabilities: Set<CapabilityIdentifier>,
        kind: ModuleKind = .service
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: moduleID,
            moduleVersion: Self.version,
            kind: kind,
            criticality: criticality,
            entryPoint: moduleID.rawValue.replacingOccurrences(of: ".", with: "_"),
            role: role,
            policyClass: policyClass,
            requestedCapabilities: capabilities
        )
    }

    private func manifest(
        for descriptor: ModuleDescriptor,
        entitlement: EntitlementRequirement? = nil
    ) -> ModuleManifest {
        ModuleManifest(
            runtimeVersion: Self.version,
            moduleID: descriptor.moduleID,
            displayName: descriptor.entryPoint,
            moduleVersion: descriptor.moduleVersion,
            moduleType: descriptor.kind,
            criticality: descriptor.criticality,
            supportedPlatforms: [.macOS],
            capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
            entryPoint: descriptor.entryPoint,
            runtimeRequirements: ModuleRuntimeRequirements(
                requiredServices: descriptor.requiredServices.sorted(),
                requiredResources: Array(descriptor.requiredResources),
                requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
            ),
            defaultRole: descriptor.role,
            policyClass: descriptor.policyClass,
            consumedEndpoints: descriptor.consumedEndpoints.sorted(),
            publishedEndpoints: descriptor.publishedEndpoints.sorted(),
            entitlementRequirement: entitlement
        )
    }

    private func factory(
        for descriptor: ModuleDescriptor,
        start: @escaping @Sendable (ModuleContext) async throws -> Void = { _ in }
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            ThemeFoundationTestModule(
                descriptor: descriptor,
                startAction: start
            )
        }
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
}

private struct GenericContribution: Equatable, Sendable {
    let value: Int
}

private struct ThemeFoundationTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private actor ThemeRollbackProbe {
    struct Counts: Sendable {
        let contributions: Int
        let resources: Int
    }

    struct Result: Sendable {
        let matchedExpectedError: Bool
        let contributionCount: Int
        let resourceCount: Int
    }

    private var reader: RuntimeContributionReaderClient?
    private var resolver: RuntimeOpaqueResourceResolverClient?
    private var result: Result?

    func capture(
        reader: RuntimeContributionReaderClient,
        resolver: RuntimeOpaqueResourceResolverClient
    ) {
        self.reader = reader
        self.resolver = resolver
    }

    func currentCounts() async throws -> Counts {
        guard let reader, let resolver else {
            throw ThemeFoundationTestError.missingProbeClient
        }
        async let contributionSnapshot = reader.snapshot(
            for: RuntimeThemeContributionCatalog.descriptor
        )
        async let resourceSnapshot = resolver.snapshot()
        let (contributions, resources) = try await (
            contributionSnapshot,
            resourceSnapshot
        )
        return Counts(
            contributions: contributions.entries.count,
            resources: resources.resources.count
        )
    }

    func recordRollback(
        matchedExpectedError: Bool,
        contributionCount: Int,
        resourceCount: Int
    ) {
        result = Result(
            matchedExpectedError: matchedExpectedError,
            contributionCount: contributionCount,
            resourceCount: resourceCount
        )
    }

    func recordUnexpectedSuccess() {
        result = Result(
            matchedExpectedError: false,
            contributionCount: -1,
            resourceCount: -1
        )
    }

    func rollbackResult() -> Result? {
        result
    }
}

private actor ThemeAvailabilityProbe {
    private var client: RuntimeAvailabilityClient?

    func capture(_ client: RuntimeAvailabilityClient) {
        self.client = client
    }

    func snapshot() async throws -> RuntimeAvailabilitySnapshot {
        guard let client else {
            throw ThemeFoundationTestError.missingProbeClient
        }
        return try await client.snapshot()
    }
}

private struct NorseBundleResourceLocator: ApplicationResourceLocator, Sendable {
    func data(for resource: ApplicationResource) async throws -> Data {
        try Data(contentsOf: try location(for: resource))
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        guard resource.ownerModuleID == RuneScribeModuleIDs.norseTheme,
              let location = RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else {
            throw ThemeFoundationTestError.resourceUnavailable(resource)
        }
        return location
    }
}

private enum ThemeFoundationTestError: Error {
    case missingProbeClient
    case resourceUnavailable(ApplicationResource)
}
