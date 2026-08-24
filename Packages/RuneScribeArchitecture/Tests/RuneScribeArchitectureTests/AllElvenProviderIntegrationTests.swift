import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribeNorseThemeModule
import RuneScribePlatform
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
import RuneScribeThemeGloamthornModule
import RuneScribeThemeMoonleafModule
import RuneScribeThemeSunspireModule
import RuneScribeThemeWildwoodModule
@testable import RuneScribeUIModule
import XCTest

final class AllElvenProviderIntegrationTests: XCTestCase {
    func testSelectedMoonleafCorruptionKeepsCoreUINorseUsableWithoutBaseWarning()
        async throws
    {
        let stateStore = InMemoryModuleStateStore(
            now: { Date(timeIntervalSince1970: 1_776_211_200) }
        )
        let providers = allElvenProviders()
        let entitlements = try entitlementSnapshot(for: providers)

        let healthyCapture = AllElvenUICapture()
        let healthyRuntime = try await makeRuntime(
            stateStore: stateStore,
            capture: healthyCapture
        )
        do {
            try await healthyRuntime.start()
            let clients = try await healthyCapture.waitForClients()
            try await healthyRuntime.reconcileEntitlements(entitlements)
            _ = try await waitForSnapshot(from: clients.theme) { snapshot in
                providerSummary(
                    in: snapshot,
                    codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID
                )?.isSelectable == true
            }
            let selected = try await clients.theme.selectCodex(
                SelectThemeCodexCommand(
                    codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID
                )
            )
            XCTAssertEqual(
                selected.effectiveCodexID,
                RuneScribeThemeMoonleafModuleBootstrap.codexID
            )
        } catch {
            await healthyRuntime.stop()
            throw error
        }
        await healthyRuntime.stop()

        let corruptedResource = try XCTUnwrap(
            MoonleafThemeBundledResourceCatalog.all.first { resource in
                resource != MoonleafThemeBundledResourceCatalog.moduleManifest
                    && resource != MoonleafThemeBundledResourceCatalog.integrityManifest
            }
        )
        let isolatedCapture = AllElvenUICapture()
        let isolatedRuntime = try await makeRuntime(
            stateStore: stateStore,
            capture: isolatedCapture,
            corruptResource: corruptedResource
        )
        do {
            try await isolatedRuntime.reconcileEntitlements(entitlements)
            try await isolatedRuntime.start()
            let clients = try await isolatedCapture.waitForClients()
            let isolated = try await waitForSnapshot(from: clients.theme) { snapshot in
                snapshot.preferredCodexID
                    == RuneScribeThemeMoonleafModuleBootstrap.codexID
                    && snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                    && providerSummary(
                        in: snapshot,
                        codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID
                    )?.state == .unavailable
            }

            XCTAssertEqual(isolated.fallbackReason, .unavailable)
            XCTAssertFalse(isolated.isEmergencyPresentation)
            XCTAssertEqual(isolated.requiredBaseResourceFailures, [])
            XCTAssertFalse(
                RootEmergencyThemeWarningPolicy.shouldShow(
                    isEmergencyPresentation: isolated.isEmergencyPresentation,
                    isDismissed: false,
                    showSplash: false,
                    isLocked: false,
                    hasPendingImport: false,
                    hasPendingMessage: false,
                    hasActiveReveal: false
                ),
                "Optional provider corruption must not show the required-Base warning."
            )
            XCTAssertEqual(
                providerSummary(
                    in: isolated,
                    codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID
                )?.isSelectable,
                false
            )
            try await assertCoreRoundTrip(
                using: clients.application,
                message: "Optional Moonleaf corruption remains isolated"
            )

            let running = await isolatedRuntime.snapshot()
            XCTAssertEqual(running.status, .running)
            assertRequiredModulesAreActive(running)
            XCTAssertEqual(
                running.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID],
                .failed
            )
        } catch {
            await isolatedRuntime.stop()
            throw error
        }
        await isolatedRuntime.stop()
    }

    func testAllRealProvidersActivateResolveAndIsolateCorruptionAndCollision()
        async throws
    {
        let stateStore = InMemoryModuleStateStore(
            now: { Date(timeIntervalSince1970: 1_776_211_200) }
        )
        let providers = allElvenProviders()

        let firstCapture = AllElvenUICapture()
        let firstRuntime = try await makeRuntime(
            stateStore: stateStore,
            capture: firstCapture
        )
        do {
            try await firstRuntime.start()
            let clients = try await firstCapture.waitForClients()
            let locked = try await waitForSnapshot(from: clients.theme) { snapshot in
                snapshot.providers.count == 5
                    && providers.allSatisfy { provider in
                        providerSummary(in: snapshot, codexID: provider.descriptor.codex.id)?
                            .state == .locked
                    }
            }
            XCTAssertEqual(locked.effectiveCodexID, RuneScribeCodexIDs.norse)
            XCTAssertTrue(providers.allSatisfy { provider in
                providerSummary(in: locked, codexID: provider.descriptor.codex.id)?
                    .isOwned == false
            })

            try await firstRuntime.reconcileEntitlements(
                try entitlementSnapshot(for: providers)
            )
            let available = try await waitForSnapshot(from: clients.theme) { snapshot in
                providers.allSatisfy { provider in
                    guard let summary = providerSummary(
                        in: snapshot,
                        codexID: provider.descriptor.codex.id
                    ) else { return false }
                    return summary.state == .available
                        && summary.isOwned
                        && summary.isSelectable
                }
            }
            XCTAssertEqual(available.effectiveCodexID, RuneScribeCodexIDs.norse)

            for provider in providers {
                let selected = try await clients.theme.selectCodex(
                    SelectThemeCodexCommand(codexID: provider.descriptor.codex.id)
                )
                XCTAssertEqual(selected.preferredCodexID, provider.descriptor.codex.id)
                XCTAssertEqual(selected.effectiveCodexID, provider.descriptor.codex.id)
                XCTAssertEqual(selected.effectiveTheme, provider.descriptor)
                XCTAssertEqual(selected.fallbackReason, .none)

                for reference in provider.descriptor.resources {
                    let resolved = try await clients.theme.resolveResource(
                        ResolveThemeResourceRequestDTO(
                            codexID: provider.descriptor.codex.id,
                            resourceID: reference.id
                        )
                    )
                    XCTAssertEqual(resolved.role, reference.role)
                    XCTAssertEqual(resolved.mediaType, reference.mediaType)
                    XCTAssertEqual(resolved.integrity, reference.integrity)
                    XCTAssertEqual(resolved.data.count, Int(reference.integrity.byteLength))
                    XCTAssertEqual(
                        sha256Hex(resolved.data),
                        reference.integrity.sha256.rawValue
                    )
                }
            }

            try await assertCoreRoundTrip(
                using: clients.application,
                message: "All Elven providers remain runtime mediated"
            )
            let running = await firstRuntime.snapshot()
            XCTAssertEqual(running.status, .running)
            assertRequiredModulesAreActive(running)
            for provider in providers {
                XCTAssertEqual(running.moduleStates[provider.moduleID], .active)
            }
        } catch {
            await firstRuntime.stop()
            throw error
        }
        await firstRuntime.stop()

        let collision = try makeMoonleafCollision()
        let corruptedResource = try XCTUnwrap(
            GloamthornThemeBundledResourceCatalog.all.first { resource in
                resource != GloamthornThemeBundledResourceCatalog.moduleManifest
                    && resource != GloamthornThemeBundledResourceCatalog.integrityManifest
            }
        )
        let secondCapture = AllElvenUICapture()
        let secondRuntime = try await makeRuntime(
            stateStore: stateStore,
            capture: secondCapture,
            corruptResource: corruptedResource,
            collision: collision
        )
        do {
            try await secondRuntime.reconcileEntitlements(
                try entitlementSnapshot(for: providers)
            )
            try await secondRuntime.start()
            let clients = try await secondCapture.waitForClients()
            let isolated = try await waitForSnapshot(from: clients.theme) { snapshot in
                guard snapshot.preferredCodexID
                    == RuneScribeThemeGloamthornModuleBootstrap.codexID,
                    snapshot.effectiveCodexID == RuneScribeCodexIDs.norse,
                    let moonleaf = providerSummary(
                        in: snapshot,
                        codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID
                    ),
                    let gloamthorn = providerSummary(
                        in: snapshot,
                        codexID: RuneScribeThemeGloamthornModuleBootstrap.codexID
                    )
                else { return false }
                return moonleaf.state == .unavailable
                    && moonleaf.isOwned
                    && !moonleaf.isSelectable
                    && gloamthorn.state == .unavailable
                    && gloamthorn.isOwned
                    && !gloamthorn.isSelectable
            }
            XCTAssertEqual(isolated.fallbackReason, .unavailable)
            XCTAssertEqual(isolated.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
            XCTAssertEqual(isolated.providers.count, 5)
            XCTAssertEqual(
                providerSummary(
                    in: isolated,
                    codexID: RuneScribeThemeSunspireModuleBootstrap.codexID
                )?.state,
                .available
            )
            XCTAssertEqual(
                providerSummary(
                    in: isolated,
                    codexID: RuneScribeThemeWildwoodModuleBootstrap.codexID
                )?.state,
                .available
            )

            do {
                _ = try await clients.theme.selectCodex(
                    SelectThemeCodexCommand(
                        codexID: RuneScribeThemeMoonleafModuleBootstrap.codexID
                    )
                )
                XCTFail("A colliding provider identity must not be selectable")
            } catch {
                XCTAssertEqual(
                    error as? ThemeCoordinatorModuleError,
                    .codexNotSelectable(RuneScribeThemeMoonleafModuleBootstrap.codexID)
                )
            }
            do {
                _ = try await clients.theme.selectCodex(
                    SelectThemeCodexCommand(
                        codexID: RuneScribeThemeGloamthornModuleBootstrap.codexID
                    )
                )
                XCTFail("A failed provider must not be selectable")
            } catch {
                XCTAssertEqual(
                    error as? ThemeCoordinatorModuleError,
                    .codexNotSelectable(RuneScribeThemeGloamthornModuleBootstrap.codexID)
                )
            }

            let recovered = try await clients.theme.selectCodex(
                SelectThemeCodexCommand(
                    codexID: RuneScribeThemeSunspireModuleBootstrap.codexID
                )
            )
            XCTAssertEqual(
                recovered.effectiveCodexID,
                RuneScribeThemeSunspireModuleBootstrap.codexID
            )
            try await assertCoreRoundTrip(
                using: clients.application,
                message: "Core remains available after optional provider isolation"
            )

            let running = await secondRuntime.snapshot()
            XCTAssertEqual(running.status, .running)
            assertRequiredModulesAreActive(running)
            XCTAssertEqual(
                running.moduleStates[RuneScribeThemeGloamthornModuleBootstrap.moduleID],
                .failed
            )
            XCTAssertEqual(
                running.moduleStates[RuneScribeThemeMoonleafModuleBootstrap.moduleID],
                .active
            )
            XCTAssertEqual(running.moduleStates[collision.moduleDescriptor.moduleID], .active)
            XCTAssertEqual(
                running.moduleStates[RuneScribeThemeSunspireModuleBootstrap.moduleID],
                .active
            )
            XCTAssertEqual(
                running.moduleStates[RuneScribeThemeWildwoodModuleBootstrap.moduleID],
                .active
            )
        } catch {
            await secondRuntime.stop()
            throw error
        }
        await secondRuntime.stop()
    }

    private func makeRuntime(
        stateStore: InMemoryModuleStateStore,
        capture: AllElvenUICapture,
        corruptResource: ApplicationResource? = nil,
        collision: AllElvenCollision? = nil
    ) async throws -> RuneScribeRuntime {
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_200) },
                nextUUID: { UUID() },
                operatingSystemVersion: {
                    RuntimeOperatingSystemVersion(major: 15, minor: 0, patch: 0)
                }
            )
        )
        try await installPlatformServices(
            on: runtime,
            stateStore: stateStore,
            corruptResource: corruptResource
        )
        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory()
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeMoonleafModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeSunspireModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeWildwoodModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeGloamthornModuleBootstrap.register(with: runtime)
        if let collision {
            try await runtime.register(
                manifest: collision.manifest,
                factory: AnyModuleFactory(descriptor: collision.moduleDescriptor) {
                    AllElvenIntegrationModule(descriptor: collision.moduleDescriptor) { _ in }
                },
                themeDiscovery: collision.themeDescriptor
            )
        }
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: AnyModuleFactory(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                AllElvenIntegrationModule(
                    descriptor: RuneScribeUIModuleBootstrap.descriptor
                ) { context in
                    await capture.store(
                        application: try await context.applicationClient(),
                        theme: try await context.themeCoordinatorClient()
                    )
                }
            }
        )
        return runtime
    }

    private func installPlatformServices(
        on runtime: RuneScribeRuntime,
        stateStore: InMemoryModuleStateStore,
        corruptResource: ApplicationResource?
    ) async throws {
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { repositoryRoot.deleteLastPathComponent() }
        let bundledFontURL = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/NotoSansRunic-Regular.ttf"
        )
        let bundledFontData = try Data(contentsOf: bundledFontURL)
        let shareArtifacts = InMemoryShareArtifactStore()
        let clipboard = InMemoryClipboardService()
        let bundles = RuneScribeNorseThemeModuleBootstrap.ownerScopedResourceBundles
            .merging(
                RuneScribeThemeMoonleafModuleBootstrap.ownerScopedResourceBundles,
                uniquingKeysWith: { current, _ in current }
            )
            .merging(
                RuneScribeThemeSunspireModuleBootstrap.ownerScopedResourceBundles,
                uniquingKeysWith: { current, _ in current }
            )
            .merging(
                RuneScribeThemeWildwoodModuleBootstrap.ownerScopedResourceBundles,
                uniquingKeysWith: { current, _ in current }
            )
            .merging(
                RuneScribeThemeGloamthornModuleBootstrap.ownerScopedResourceBundles,
                uniquingKeysWith: { current, _ in current }
            )
        let resources = AllElvenApplicationResources(
            standardLocations: [
                .bundledRuneFont: bundledFontURL,
                .splashVideo: URL(fileURLWithPath: "/fixture/splash.mp4"),
                .defaultMetalLibrary: URL(fileURLWithPath: "/fixture/default.metallib"),
            ],
            ownerBundles: bundles,
            corruptResource: corruptResource
        )

        try await runtime.installPlatformAdapter(
            InMemorySecureValueStore(),
            for: RuneScribeServiceKeys.secureValueStore
        )
        try await runtime.installPlatformAdapter(
            InMemoryProtectedFileStore(),
            for: RuneScribeServiceKeys.protectedFileStore
        )
        try await runtime.installPlatformAdapter(
            InMemoryInboundFileReader(),
            for: RuneScribeServiceKeys.inboundFileReader
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.shareArtifactStore
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.installPlatformAdapter(
            resources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            InMemoryFontRegistrar(namesByData: [bundledFontData: "NotoSansRunic-Regular"]),
            for: RuneScribeServiceKeys.systemFontRegistrar
        )
        try await runtime.installPlatformAdapter(
            InMemoryContactAccessService(),
            for: RuneScribeServiceKeys.contactAccess
        )
        try await runtime.installPlatformAdapter(
            clipboard,
            for: RuneScribeServiceKeys.clipboardRead
        )
        try await runtime.installPlatformAdapter(
            clipboard,
            for: RuneScribeServiceKeys.clipboardWrite
        )
        try await runtime.installPlatformAdapter(
            SystemClock(),
            for: RuneScribeServiceKeys.clock
        )
        try await runtime.installPlatformAdapter(
            SystemUUIDProvider(),
            for: RuneScribeServiceKeys.uuid
        )
        try await runtime.installPlatformAdapter(
            stateStore,
            for: RuneScribeServiceKeys.moduleStateStore
        )
    }

    private func waitForSnapshot(
        from client: RuntimeThemeCoordinatorClient,
        matching predicate: @escaping @Sendable (ThemeCoordinatorSnapshotDTO) -> Bool
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        for _ in 0 ..< 400 {
            let snapshot = try await client.snapshot()
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AllElvenIntegrationError.snapshotTimeout
    }

    private func assertCoreRoundTrip(
        using application: RuntimeApplicationClient,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let cipher = try await application.createCipher(
            CreateCipherCommand(name: "All Elven Integration Cipher")
        )
        let encoded = try await application.encode(
            EncodeMessageCommand(plaintext: message, cipherID: cipher.id)
        )
        let decoded = try await application.decode(
            DecodeMessageCommand(runes: encoded.runes)
        )
        XCTAssertEqual(decoded.plaintext, message, file: file, line: line)
        XCTAssertEqual(decoded.cipherID, cipher.id, file: file, line: line)
    }

    private func assertRequiredModulesAreActive(
        _ snapshot: RuntimeSnapshot,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            snapshot.moduleStates[RuneScribeModuleIDs.core],
            .active,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.moduleStates[RuneScribeModuleIDs.norseTheme],
            .active,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.moduleStates[RuneScribeModuleIDs.themeCoordinator],
            .active,
            file: file,
            line: line
        )
        XCTAssertEqual(
            snapshot.moduleStates[RuneScribeModuleIDs.primaryUI],
            .active,
            file: file,
            line: line
        )
    }

    private func entitlementSnapshot(
        for providers: [AllElvenProvider]
    ) throws -> ProgressionEntitlementSnapshotDTO {
        try ProgressionEntitlementSnapshotDTO(
            revision: 1,
            capturedAt: Date(timeIntervalSince1970: 1_776_211_201),
            includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
            earnedUnlockIDs: providers.map(\.unlockID).sorted()
        )
    }

    private func makeMoonleafCollision() throws -> AllElvenCollision {
        let encoded = try JSONEncoder().encode(
            RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        )
        guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        else { throw AllElvenIntegrationError.invalidCollisionDescriptor }
        root["id"] = "theme.moonleaf.collision"
        root["moduleID"] = "com.runescribe.module.theme.moonleaf-collision"
        root["moduleRole"] = "runescribe.theme.moonleaf-collision"
        let themeDescriptor = try JSONDecoder().decode(
            ThemeDescriptor.self,
            from: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        )
        let moduleDescriptor = ModuleDescriptor(
            moduleID: "com.runescribe.module.theme.moonleaf-collision",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .optional,
            entryPoint: "MoonleafCollisionThemeProvider",
            role: "runescribe.theme.moonleaf-collision",
            policyClass: RuneScribePolicyClasses.themeProvider,
            requestedCapabilities: []
        )
        let manifest = ModuleManifest(
            runtimeVersion: Self.version,
            moduleID: moduleDescriptor.moduleID,
            displayName: moduleDescriptor.entryPoint,
            moduleVersion: moduleDescriptor.moduleVersion,
            moduleType: moduleDescriptor.kind,
            criticality: moduleDescriptor.criticality,
            supportedPlatforms: [.macOS],
            capabilitiesRequested: [],
            entryPoint: moduleDescriptor.entryPoint,
            runtimeRequirements: ModuleRuntimeRequirements(),
            defaultRole: moduleDescriptor.role,
            policyClass: moduleDescriptor.policyClass,
            entitlementRequirement: EntitlementRequirement(
                kind: .earned,
                identifier: RuneScribeThemeMoonleafModuleBootstrap.unlockID
            )
        )
        return AllElvenCollision(
            themeDescriptor: themeDescriptor,
            moduleDescriptor: moduleDescriptor,
            manifest: manifest
        )
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
}

private struct AllElvenProvider: Sendable {
    let moduleID: ModuleIdentifier
    let unlockID: UnlockID
    let descriptor: ThemeDescriptor
}

private func allElvenProviders() -> [AllElvenProvider] {
    [
        AllElvenProvider(
            moduleID: RuneScribeThemeMoonleafModuleBootstrap.moduleID,
            unlockID: RuneScribeThemeMoonleafModuleBootstrap.unlockID,
            descriptor: RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        ),
        AllElvenProvider(
            moduleID: RuneScribeThemeSunspireModuleBootstrap.moduleID,
            unlockID: RuneScribeThemeSunspireModuleBootstrap.unlockID,
            descriptor: RuneScribeThemeSunspireModuleBootstrap.discoveryDescriptor
        ),
        AllElvenProvider(
            moduleID: RuneScribeThemeWildwoodModuleBootstrap.moduleID,
            unlockID: RuneScribeThemeWildwoodModuleBootstrap.unlockID,
            descriptor: RuneScribeThemeWildwoodModuleBootstrap.discoveryDescriptor
        ),
        AllElvenProvider(
            moduleID: RuneScribeThemeGloamthornModuleBootstrap.moduleID,
            unlockID: RuneScribeThemeGloamthornModuleBootstrap.unlockID,
            descriptor: RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor
        ),
    ]
}

private struct AllElvenCollision: Sendable {
    let themeDescriptor: ThemeDescriptor
    let moduleDescriptor: ModuleDescriptor
    let manifest: ModuleManifest
}

private struct AllElvenApplicationResources: ApplicationResourceLocator, Sendable {
    let standardLocations: [ApplicationResource: URL]
    let ownerBundles: [ModuleIdentifier: Bundle]
    let corruptResource: ApplicationResource?

    func data(for resource: ApplicationResource) async throws -> Data {
        var data = try Data(contentsOf: try location(for: resource))
        if resource == corruptResource, !data.isEmpty {
            data[0] ^= 0x01
        }
        return data
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        if let ownerModuleID = resource.ownerModuleID,
           let bundle = ownerBundles[ownerModuleID],
           let location = bundle.url(
               forResource: resource.name,
               withExtension: resource.fileExtension,
               subdirectory: resource.subdirectory
           )
        {
            return location
        }
        guard let location = standardLocations[resource] else {
            throw MappedApplicationResourceLocatorError.resourceNotFound(resource)
        }
        return location
    }
}

private actor AllElvenUICapture {
    struct Clients: Sendable {
        let application: RuntimeApplicationClient
        let theme: RuntimeThemeCoordinatorClient
    }

    private var clients: Clients?

    func store(
        application: RuntimeApplicationClient,
        theme: RuntimeThemeCoordinatorClient
    ) {
        clients = Clients(application: application, theme: theme)
    }

    func waitForClients() async throws -> Clients {
        for _ in 0 ..< 400 {
            if let clients { return clients }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw AllElvenIntegrationError.clientTimeout
    }
}

private struct AllElvenIntegrationModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    init(
        descriptor: ModuleDescriptor,
        start: @escaping @Sendable (ModuleContext) async throws -> Void
    ) {
        self.descriptor = descriptor
        startAction = start
    }

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private enum AllElvenIntegrationError: Error {
    case snapshotTimeout
    case clientTimeout
    case invalidCollisionDescriptor
}

private func providerSummary(
    in snapshot: ThemeCoordinatorSnapshotDTO,
    codexID: CodexID
) -> ThemeProviderSummaryDTO? {
    snapshot.providers.first { $0.codexID == codexID }
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
