import Foundation
import RuneScribeContracts
@testable import RuneScribeNorseThemeModule
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
@testable import RuneScribeThemeCoordinatorModule
import XCTest

final class ThemeCoordinatorConformanceTests: XCTestCase {
    func testDamagedRequiredNorseFontUsesEmergencyPresentationWithoutStoppingRuntime()
        async throws
    {
        let unavailableFont = NorseBaseBundledResourceCatalog.notoSansRunic
        let harness = try await makeHarness(
            providers: [],
            unavailableBaseResource: unavailableFont
        )
        defer { Task { await harness.runtime.stop() } }

        let snapshot = try await harness.probe.waitForSnapshot {
            $0.isEmergencyPresentation
        }
        XCTAssertEqual(snapshot.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(snapshot.fallbackReason, .invalidResources)
        let base = try XCTUnwrap(
            provider(in: snapshot, codexID: RuneScribeCodexIDs.norse)
        )
        XCTAssertEqual(base.state, .invalidResources)
        XCTAssertTrue(base.isOwned)
        XCTAssertFalse(base.isSelectable)
        XCTAssertTrue(base.isSelected)

        let fontID = try XCTUnwrap(
            snapshot.effectiveTheme.codex.scripts.first?.fontResourceID
        )
        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: RuneScribeCodexIDs.norse,
                    resourceID: fontID
                )
            )
            XCTFail("Emergency presentation must not expose an unverified font")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .resourceUnavailable(
                    ResolveThemeResourceRequestDTO(
                        codexID: RuneScribeCodexIDs.norse,
                        resourceID: fontID
                    )
                )
            )
        }

        let runtimeSnapshot = await harness.runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.status, .running)
        XCTAssertEqual(
            runtimeSnapshot.moduleStates[RuneScribeModuleIDs.norseTheme],
            .active
        )
        XCTAssertEqual(
            runtimeSnapshot.moduleStates[RuneScribeModuleIDs.themeCoordinator],
            .active
        )
    }

    func testLockedProvidersActivateSelectResolveAndFallBackAfterRevocation()
        async throws
    {
        let fontTheme = try SyntheticThemeDefinition.make(
            slug: "fontwood",
            portability: .fontDependent,
            displayName: "Fontwood Test Codex"
        )
        let vectorTheme = try SyntheticThemeDefinition.make(
            slug: "vectorleaf",
            portability: .vectorRendered,
            displayName: "Vectorleaf Test Codex"
        )
        let vectorControl = SyntheticThemeProviderControl()
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(definition: fontTheme, mode: .normal),
                ProviderRegistration(
                    definition: vectorTheme,
                    mode: .normal,
                    control: vectorControl
                ),
            ]
        )
        defer { Task { await harness.runtime.stop() } }

        let initial = try await harness.probe.waitForSnapshot { snapshot in
            snapshot.providers.count == 3
        }
        XCTAssertEqual(initial.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(initial.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
        XCTAssertEqual(
            provider(in: initial, codexID: fontTheme.codexID)?.state,
            .locked
        )
        XCTAssertEqual(
            provider(in: initial, codexID: vectorTheme.codexID)?.state,
            .locked
        )
        XCTAssertFalse(
            try XCTUnwrap(provider(in: initial, codexID: fontTheme.codexID)).isOwned
        )
        XCTAssertFalse(
            try XCTUnwrap(provider(in: initial, codexID: vectorTheme.codexID)).isSelectable
        )
        let lockedRuntimeSnapshot = await harness.runtime.snapshot()
        XCTAssertEqual(
            lockedRuntimeSnapshot.moduleStates[fontTheme.moduleID],
            .active
        )
        XCTAssertEqual(
            lockedRuntimeSnapshot.moduleStates[vectorTheme.moduleID],
            .active
        )
        for descriptor in [
            ProviderRegistration(definition: fontTheme, mode: .normal).descriptor,
            ProviderRegistration(definition: vectorTheme, mode: .normal).descriptor,
        ] {
            XCTAssertFalse(
                descriptor.requestedCapabilities.contains(
                    RuneScribeCapabilities.themeSelection
                )
            )
            XCTAssertEqual(
                descriptor.requestedCapabilities,
                [
                    RuneScribeCapabilities.contributionPublish,
                    RuneScribeCapabilities.opaqueResourcePublish,
                ]
            )
        }
        XCTAssertEqual(
            fontTheme.descriptor.codex.scripts.first?.portability,
            .fontDependent
        )
        XCTAssertEqual(
            vectorTheme.descriptor.codex.scripts.first?.portability,
            .vectorRendered
        )
        XCTAssertNotEqual(
            fontTheme.descriptor.codex.palette,
            vectorTheme.descriptor.codex.palette
        )
        XCTAssertNotEqual(
            fontTheme.descriptor.codex.palette,
            RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor.codex.palette
        )

        let lockedCardResourceID = fontTheme.descriptor.codex.vault
            .lockedSilhouetteResourceID
        let lockedCard = try await harness.probe.resolveCatalogPreview(
            codexID: fontTheme.codexID,
            resourceID: lockedCardResourceID
        )
        XCTAssertEqual(lockedCard.resourceID, lockedCardResourceID)
        XCTAssertTrue([
            ThemeResourceRoles.vaultCard,
            ThemeResourceRoles.vaultLockedSilhouette,
        ].contains(lockedCard.role))

        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: fontTheme.codexID,
                    resourceID: lockedCardResourceID
                )
            )
            XCTFail("Locked providers must not resolve active presentation resources")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .resourceUnavailable(
                    ResolveThemeResourceRequestDTO(
                        codexID: fontTheme.codexID,
                        resourceID: lockedCardResourceID
                    )
                )
            )
        }

        let lockedFontResourceID = try XCTUnwrap(
            fontTheme.descriptor.codex.scripts.first?.fontResourceID
        )
        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: fontTheme.codexID,
                    resourceID: lockedFontResourceID,
                    purpose: .catalogPreview
                )
            )
            XCTFail("Catalog preview must not expose non-preview script resources")
        } catch {
            XCTAssertNotNil(error as? ThemeCoordinatorModuleError)
        }

        let reservedRelic = try XCTUnwrap(
            fontTheme.descriptor.codex.relics.first(where: {
                $0.metadata.availability == .reservedInactive
            })
        )
        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: fontTheme.codexID,
                    resourceID: reservedRelic.thumbnailResourceID,
                    purpose: .catalogPreview
                )
            )
            XCTFail("Reserved-inactive artifacts must not expose catalog previews")
        } catch {
            XCTAssertNotNil(error as? ThemeCoordinatorModuleError)
        }

        do {
            _ = try await harness.probe.select(
                SelectThemeCodexCommand(codexID: fontTheme.codexID)
            )
            XCTFail("Locked Theme providers must not be selectable")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .codexNotSelectable(fontTheme.codexID)
            )
        }

        do {
            try await harness.runtime.reconcileEntitlements(
                try entitlementSnapshot(
                    revision: 1,
                    earned: [fontTheme.unlockID]
                )
            )
        } catch {
            throw CoordinatorTestError.stageFailure(
                "font-entitlement",
                String(reflecting: error)
            )
        }
        let fontAvailable = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: fontTheme.codexID)?.state == .available
        }
        XCTAssertTrue(
            try XCTUnwrap(provider(in: fontAvailable, codexID: fontTheme.codexID))
                .isSelectable
        )
        XCTAssertEqual(
            provider(in: fontAvailable, codexID: vectorTheme.codexID)?.state,
            .locked
        )

        let fontSelected = try await harness.probe.select(
            SelectThemeCodexCommand(
                codexID: fontTheme.codexID,
                expectedSnapshotRevision: fontAvailable.revision
            )
        )
        XCTAssertEqual(fontSelected.preferredCodexID, fontTheme.codexID)
        XCTAssertEqual(fontSelected.effectiveCodexID, fontTheme.codexID)
        XCTAssertEqual(fontSelected.fallbackReason, .none)
        XCTAssertEqual(
            fontSelected.effectiveTheme.codex.scripts.first?.portability,
            .fontDependent
        )
        let fontResourceID = try XCTUnwrap(
            fontTheme.descriptor.codex.scripts.first?.fontResourceID
        )
        let resolvedFont = try await harness.probe.resolve(
            ResolveThemeResourceRequestDTO(
                codexID: fontTheme.codexID,
                resourceID: fontResourceID
            )
        )
        XCTAssertEqual(resolvedFont.mediaType, .ttf)
        XCTAssertEqual(resolvedFont.role, ThemeResourceRoles.scriptFont)
        XCTAssertFalse(resolvedFont.data.isEmpty)

        do {
            try await harness.runtime.reconcileEntitlements(
                try entitlementSnapshot(
                    revision: 2,
                    earned: [fontTheme.unlockID, vectorTheme.unlockID]
                )
            )
        } catch {
            throw CoordinatorTestError.stageFailure(
                "vector-entitlement",
                String(reflecting: error)
            )
        }
        let vectorAvailable = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: vectorTheme.codexID)?.state == .available
        }
        let vectorSelected = try await harness.probe.select(
            SelectThemeCodexCommand(
                codexID: vectorTheme.codexID,
                expectedSnapshotRevision: vectorAvailable.revision
            )
        )
        XCTAssertEqual(vectorSelected.effectiveCodexID, vectorTheme.codexID)
        XCTAssertEqual(
            vectorSelected.effectiveTheme.codex.scripts.first?.portability,
            .vectorRendered
        )
        let vectorResourceID = try XCTUnwrap(
            vectorTheme.descriptor.codex.scripts.first?.glyphs.first?.vectorResourceID
        )
        let resolvedVector = try await harness.probe.resolve(
            ResolveThemeResourceRequestDTO(
                codexID: vectorTheme.codexID,
                resourceID: vectorResourceID
            )
        )
        XCTAssertEqual(resolvedVector.mediaType, .pdf)
        XCTAssertEqual(resolvedVector.role, ThemeResourceRoles.scriptGlyphVector)
        XCTAssertFalse(resolvedVector.data.isEmpty)

        try await vectorControl.revoke()
        do {
            _ = try await harness.probe.select(
                SelectThemeCodexCommand(codexID: vectorTheme.codexID)
            )
            XCTFail("A revoked provider must no longer be selectable")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .codexNotSelectable(vectorTheme.codexID)
            )
        }
        let fallback = try await harness.probe.waitForSnapshot { snapshot in
            snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                && snapshot.preferredCodexID == vectorTheme.codexID
                && snapshot.fallbackReason == .unavailable
        }
        XCTAssertEqual(
            provider(in: fallback, codexID: vectorTheme.codexID)?.state,
            .unavailable
        )
        XCTAssertEqual(fallback.effectiveTheme.codex.id, RuneScribeCodexIDs.norse)
        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: vectorTheme.codexID,
                    resourceID: vectorResourceID
                )
            )
            XCTFail("Resources from a revoked provider must be unavailable")
        } catch {
            XCTAssertNotNil(error as? ThemeCoordinatorModuleError)
        }
        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: vectorTheme.codexID,
                    resourceID: vectorTheme.descriptor.codex.vault.cardResourceID,
                    purpose: .catalogPreview
                )
            )
            XCTFail("Revoked providers must not expose catalog previews")
        } catch {
            XCTAssertNotNil(error as? ThemeCoordinatorModuleError)
        }

        await harness.runtime.stop()
        do {
            _ = try await harness.probe.select(
                SelectThemeCodexCommand(codexID: RuneScribeCodexIDs.norse)
            )
            XCTFail("Runtime stop must revoke the UI's coordinator client")
        } catch {
            XCTAssertNotNil(error as? RuneScribeRuntimeError)
        }
    }

    func testFaultsInvalidResourcesAndStableIDCollisionsRemainIsolatedFromBase()
        async throws
    {
        let failed = try SyntheticThemeDefinition.make(
            slug: "faulted",
            portability: .fontDependent,
            displayName: "Faulted Test Codex"
        )
        let mismatched = try SyntheticThemeDefinition.make(
            slug: "mismatch",
            portability: .vectorRendered,
            displayName: "Mismatched Test Codex"
        )
        let missing = try SyntheticThemeDefinition.make(
            slug: "missing",
            portability: .fontDependent,
            displayName: "Missing Resource Test Codex"
        )
        let collisionA = try SyntheticThemeDefinition.make(
            slug: "collisiona",
            portability: .fontDependent,
            displayName: "Collision A Test Codex",
            sharedRightsID: "rights.test.shared-collision"
        )
        let collisionB = try SyntheticThemeDefinition.make(
            slug: "collisionb",
            portability: .vectorRendered,
            displayName: "Collision B Test Codex",
            sharedRightsID: "rights.test.shared-collision"
        )
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(definition: failed, mode: .throwAfterPublish),
                ProviderRegistration(definition: mismatched, mode: .resourceMismatch),
                ProviderRegistration(definition: missing, mode: .descriptorOnly),
                ProviderRegistration(definition: collisionA, mode: .normal),
                ProviderRegistration(definition: collisionB, mode: .normal),
            ],
            permitsDiagnostics: true,
            includeDiagnosticsClient: true
        )
        defer { Task { await harness.runtime.stop() } }

        let discovered = try await harness.probe.waitForSnapshot { snapshot in
            snapshot.providers.count == 6
        }
        XCTAssertEqual(discovered.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(
            provider(in: discovered, codexID: collisionA.codexID)?.state,
            .unavailable
        )
        XCTAssertEqual(
            provider(in: discovered, codexID: collisionB.codexID)?.state,
            .unavailable
        )

        try await harness.runtime.reconcileEntitlements(
            try entitlementSnapshot(
                revision: 1,
                earned: [failed.unlockID, mismatched.unlockID, missing.unlockID]
            )
        )
        let isolated = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: failed.codexID)?.state == .unavailable
                && provider(in: snapshot, codexID: mismatched.codexID)?.state
                    == .invalidResources
                && provider(in: snapshot, codexID: missing.codexID)?.state
                    == .invalidResources
        }
        XCTAssertEqual(isolated.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertTrue(
            try XCTUnwrap(provider(in: isolated, codexID: RuneScribeCodexIDs.norse))
                .isSelectable
        )
        let runtimeSnapshot = await harness.runtime.snapshot()
        XCTAssertEqual(runtimeSnapshot.moduleStates[failed.moduleID], .failed)
        XCTAssertEqual(runtimeSnapshot.moduleStates[mismatched.moduleID], .active)
        XCTAssertEqual(runtimeSnapshot.moduleStates[missing.moduleID], .active)

        let diagnostics = try await harness.diagnostics.query()
        XCTAssertEqual(
            diagnostic(in: diagnostics, codexID: failed.codexID)?.code,
            .lifecycleUnavailable
        )
        XCTAssertEqual(
            diagnostic(in: diagnostics, codexID: mismatched.codexID)?.code,
            .resourceMismatch
        )
        XCTAssertEqual(
            diagnostic(in: diagnostics, codexID: missing.codexID)?.code,
            .missingResource
        )
        XCTAssertEqual(
            diagnostic(in: diagnostics, codexID: collisionA.codexID)?.code,
            .stableIDCollision
        )
        XCTAssertEqual(
            diagnostic(in: diagnostics, codexID: collisionB.codexID)?.code,
            .stableIDCollision
        )
        XCTAssertEqual(
            diagnostic(in: diagnostics, codexID: RuneScribeCodexIDs.norse)?.code,
            .accepted
        )
        await harness.runtime.stop()
    }

    func testDiagnosticsEndpointIsDeniedInProductionAndEnabledByDebugGate()
        async throws
    {
        let production = try await makeHarness(
            providers: [],
            permitsDiagnostics: false,
            includeDiagnosticsClient: true
        )
        do {
            _ = try await production.diagnostics.query()
            XCTFail("Production must deny Theme diagnostics")
        } catch {
            XCTAssertEqual(error as? RuntimeThemeDiagnosticsError, .disabled)
        }
        await production.runtime.stop()

        let debug = try await makeHarness(
            providers: [],
            permitsDiagnostics: true,
            includeDiagnosticsClient: true
        )
        let diagnostics = try await debug.diagnostics.query()
        XCTAssertEqual(diagnostics.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(diagnostics.providers.count, 1)
        XCTAssertEqual(diagnostics.providers.first?.code, .accepted)
        await debug.runtime.stop()
    }

    func testSuspendedOlderReconcileCannotReplaceNewerProviderState()
        async throws
    {
        let theme = try SyntheticThemeDefinition.make(
            slug: "reconcileorder",
            portability: .fontDependent,
            displayName: "Reconcile Order Test Codex"
        )
        let providerControl = SyntheticThemeProviderControl()
        let commitGate = ReconcileCommitGate()
        let serviceCapture = ThemeCoordinatorServiceCapture()
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(
                    definition: theme,
                    mode: .normal,
                    control: providerControl
                ),
            ],
            permitsDiagnostics: true,
            includeDiagnosticsClient: true,
            serviceCapture: serviceCapture
        )
        defer { Task { await harness.runtime.stop() } }

        try await harness.runtime.reconcileEntitlements(
            try entitlementSnapshot(revision: 1, earned: [theme.unlockID])
        )
        _ = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: theme.codexID)?.state == .available
        }

        await commitGate.arm()
        let service = try await serviceCapture.waitUntilReady()
        let olderReconcile = Task {
            try await service.reconcile { generation in
                await commitGate.suspendIfArmed(generation: generation)
            }
        }
        _ = await commitGate.waitUntilSuspended()

        try await providerControl.revoke()
        let newerReconcile = Task { try await service.reconcile() }
        await commitGate.release()
        try await olderReconcile.value
        try await newerReconcile.value

        let newer = try await currentSnapshot(from: service)
        XCTAssertEqual(
            provider(in: newer, codexID: theme.codexID)?.state,
            .unavailable
        )

        let final = try await currentSnapshot(from: service)
        XCTAssertEqual(final.revision, newer.revision)
        XCTAssertEqual(
            provider(in: final, codexID: theme.codexID)?.state,
            .unavailable
        )
        XCTAssertEqual(final.effectiveCodexID, RuneScribeCodexIDs.norse)
        await harness.runtime.stop()
    }

    private func makeHarness(
        providers: [ProviderRegistration],
        permitsDiagnostics: Bool = false,
        includeDiagnosticsClient: Bool = false,
        serviceCapture: ThemeCoordinatorServiceCapture? = nil,
        unavailableBaseResource: ApplicationResource? = nil
    ) async throws -> CoordinatorHarness {
        let syntheticPayloadSource = SyntheticThemePayloadSource()
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(
                now: { Date(timeIntervalSince1970: 1_776_211_200) },
                nextUUID: { UUID() },
                operatingSystemVersion: {
                    RuntimeOperatingSystemVersion(major: 15, minor: 0, patch: 0)
                },
                permitsThemeDiagnostics: permitsDiagnostics
            )
        )
        try await runtime.installPlatformAdapter(
            CoordinatorNorseResourceLocator(
                unavailableResource: unavailableBaseResource
            ),
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            InMemoryModuleStateStore(
                now: { Date(timeIntervalSince1970: 1_776_211_200) }
            ),
            for: RuneScribeServiceKeys.moduleStateStore
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        if !providers.isEmpty {
            await syntheticPayloadSource.install(
                try syntheticBaseThemeFixture()
            )
        }

        for provider in providers {
            try await runtime.register(
                manifest: manifest(
                    for: provider.descriptor,
                    entitlement: EntitlementRequirement(
                        kind: .earned,
                        identifier: provider.definition.unlockID
                    )
                ),
                factory: providerFactory(
                    provider,
                    payloadSource: syntheticPayloadSource
                ),
                themeDiscovery: provider.definition.descriptor
            )
        }

        let coordinatorFactory: AnyModuleFactory
        if let serviceCapture {
            coordinatorFactory = AnyModuleFactory(
                descriptor: RuneScribeThemeCoordinatorModuleBootstrap.descriptor
            ) {
                SuspensibleThemeCoordinatorModule(
                    serviceCapture: serviceCapture
                )
            }
        } else {
            coordinatorFactory = RuneScribeThemeCoordinatorModuleBootstrap.factory()
        }
        try await runtime.register(
            manifest: RuneScribeThemeCoordinatorModuleBootstrap.manifest(),
            factory: coordinatorFactory
        )
        let diagnosticsProbe = ThemeDiagnosticsProbe()
        if includeDiagnosticsClient {
            let descriptor = diagnosticsDescriptor()
            try await runtime.register(
                manifest: manifest(for: descriptor),
                factory: factory(for: descriptor) { context in
                    let query = try await context.queryClient(
                        to: .role(RuneScribeRoles.themeCoordinator)
                    )
                    await diagnosticsProbe.capture(query)
                }
            )
        }
        let probe = ThemeCoordinatorClientProbe()
        let ui = uiDescriptor()
        try await runtime.register(
            manifest: manifest(for: ui),
            factory: factory(for: ui) { context in
                await probe.capture(try await context.themeCoordinatorClient())
            }
        )
        do {
            try await runtime.start()
        } catch {
            await runtime.stop()
            throw error
        }
        _ = try await probe.waitForSnapshot { _ in true }
        if !providers.isEmpty {
            let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
            var payloads: [ThemeResourceID: Data] = [:]
            for resource in descriptor.resources {
                let resolved: ResolvedThemeResourceDTO
                do {
                    resolved = try await probe.resolve(
                        ResolveThemeResourceRequestDTO(
                            codexID: descriptor.codex.id,
                            resourceID: resource.id
                        )
                    )
                } catch {
                    await runtime.stop()
                    throw CoordinatorTestError.baseResourceResolveFailed(
                        resource.id,
                        String(reflecting: error)
                    )
                }
                guard resolved.mediaType == resource.mediaType,
                      resolved.role == resource.role
                else {
                    await runtime.stop()
                    throw CoordinatorTestError.baseResourceMismatch(resource.id)
                }
                payloads[resource.id] = resolved.data
            }
            await syntheticPayloadSource.install(
                ValidatedNorseBaseTheme(
                    descriptor: descriptor,
                    resourcePayloads: payloads
                )
            )
        }
        if includeDiagnosticsClient {
            try await diagnosticsProbe.waitUntilReady()
        }
        return CoordinatorHarness(
            runtime: runtime,
            probe: probe,
            diagnostics: diagnosticsProbe
        )
    }

    private func syntheticBaseThemeFixture() throws -> ValidatedNorseBaseTheme {
        let bundle = RuneScribeNorseThemeModuleBootstrap.resourceBundle
        let payloads = try Dictionary(
            uniqueKeysWithValues: NorseBaseThemeResourceCatalog.definitions.map {
                definition in
                guard let url = bundle.url(
                    forResource: definition.resource.name,
                    withExtension: definition.resource.fileExtension,
                    subdirectory: definition.resource.subdirectory
                )
                else {
                    throw CoordinatorTestError.applicationResourceUnavailable(
                        definition.resource
                    )
                }
                return (definition.id, try Data(contentsOf: url))
            }
        )
        guard NorseBaseThemeResourceCatalog.validates(payloads) else {
            throw CoordinatorTestError.basePayloadUnavailable
        }
        return ValidatedNorseBaseTheme(
            descriptor: RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor,
            resourcePayloads: payloads
        )
    }

    private func currentSnapshot(
        from service: ThemeCoordinatorService
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        let stream = service.stateStream(
            metadata: RuntimeOperationMetadata(
                schemaVersion: RuntimeSchemaVersions.v1,
                operationID: "theme-reconcile-order-snapshot",
                correlationID: "theme-reconcile-order-correlation",
                sourceModuleID: "com.runescribe.test.theme-coordinator-ui",
                destinationModuleID: RuneScribeModuleIDs.themeCoordinator,
                runtimeGeneration: 1,
                timestampUTC: Date(timeIntervalSince1970: 1_776_211_200),
                operationIdentifier: "theme.state",
                privacyClass: .internalData
            )
        )
        var iterator = stream.makeAsyncIterator()
        guard let snapshot = await iterator.next() else {
            throw CoordinatorTestError.snapshotTimeout("state-stream-finished")
        }
        return snapshot
    }

    private func providerFactory(
        _ registration: ProviderRegistration,
        payloadSource: SyntheticThemePayloadSource
    ) -> AnyModuleFactory {
        factory(for: registration.descriptor) { context in
            let base = try await payloadSource.baseTheme()
            let payloads = try registration.definition.payloads(from: base)
            switch registration.mode {
            case .normal, .throwAfterPublish:
                try await context.publishTheme(
                    descriptor: registration.definition.descriptor,
                    resourcePayloads: payloads
                )
            case .descriptorOnly:
                _ = try await context.publishThemeDescriptor(
                    registration.definition.descriptor
                )
            case .resourceMismatch:
                let resourceProvider = try await context.opaqueResourceProviderClient()
                let firstResourceID = registration.definition.descriptor.resources.first?.id
                try await resourceProvider.register(
                    OpaqueResourceNamespaceRegistration(
                        namespace: RuntimeThemeContributionCatalog.resourceNamespace(
                            for: registration.definition.codexID
                        ),
                        declarations: registration.definition.descriptor.resources.map {
                            reference in
                            OpaqueResourceDeclaration(
                                resourceID: OpaqueResourceID(
                                    rawValue: reference.id.rawValue
                                ),
                                semanticRole: reference.id == firstResourceID
                                    ? "role.test.mismatch"
                                    : reference.role.rawValue,
                                mediaType: reference.mediaType.opaqueMediaType,
                                byteCount: Int(reference.integrity.byteLength),
                                sha256: reference.integrity.sha256.rawValue,
                                pixelSize: reference.integrity.pixelSize.map {
                                    OpaqueResourcePixelSize(
                                        width: Int($0.width),
                                        height: Int($0.height)
                                    )
                                },
                                isRequired: reference.requirement == .required
                            )
                        },
                        payloads: payloads.map {
                            OpaqueResourcePayload(
                                resourceID: OpaqueResourceID(rawValue: $0.key.rawValue),
                                data: $0.value
                            )
                        }
                    )
                )
                _ = try await context.publishThemeDescriptor(
                    registration.definition.descriptor
                )
            }

            if let control = registration.control {
                await control.capture(
                    publisher: try await context.contributionPublisherClient(),
                    resourceProvider: try await context.opaqueResourceProviderClient(),
                    descriptor: registration.definition.descriptor
                )
            }
            if registration.mode == .throwAfterPublish {
                throw CoordinatorTestError.expectedProviderFailure
            }
        }
    }

    private func uiDescriptor() -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.test.theme-coordinator-ui",
            moduleVersion: Self.version,
            kind: .ui,
            criticality: .required,
            entryPoint: "ThemeCoordinatorConformanceUI",
            role: RuneScribeRoles.primaryUI,
            requestedCapabilities: [
                RuneScribeCapabilities.rootUI,
                RuneScribeCapabilities.themeStateRead,
                RuneScribeCapabilities.themeSelection,
                RuneScribeCapabilities.themeResourceRead,
            ],
            requiredModuleRoles: [RuneScribeRoles.themeCoordinator],
            consumedEndpoints: RuntimeThemeEndpointCatalog.UIEndpointIDs
        )
    }

    private func diagnosticsDescriptor() -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: "com.runescribe.test.theme-diagnostics",
            moduleVersion: Self.version,
            kind: .service,
            criticality: .required,
            entryPoint: "ThemeCoordinatorDiagnosticsProbe",
            role: "runescribe.test.theme-diagnostics",
            policyClass: RuneScribePolicyClasses.supportTooling,
            requestedCapabilities: [RuneScribeCapabilities.themeDiagnostics],
            requiredModuleRoles: [RuneScribeRoles.themeCoordinator],
            consumedEndpoints: [RuntimeThemeEndpointCatalog.diagnostics.descriptor.endpointID]
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
            CoordinatorTestModule(descriptor: descriptor, startAction: start)
        }
    }

    private func entitlementSnapshot(
        revision: UInt64,
        earned: [UnlockID]
    ) throws -> ProgressionEntitlementSnapshotDTO {
        try ProgressionEntitlementSnapshotDTO(
            revision: revision,
            capturedAt: Date(timeIntervalSince1970: 1_776_211_200 + Double(revision)),
            includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
            earnedUnlockIDs: earned
        )
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
}

private struct CoordinatorHarness {
    let runtime: RuneScribeRuntime
    let probe: ThemeCoordinatorClientProbe
    let diagnostics: ThemeDiagnosticsProbe
}

private actor ReconcileCommitGate {
    private var isArmed = false
    private var suspendedGeneration: UInt64?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<UInt64, Never>] = []

    func arm() {
        isArmed = true
    }

    func suspendIfArmed(generation: UInt64) async {
        guard isArmed else { return }
        isArmed = false
        suspendedGeneration = generation
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume(returning: generation) }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async -> UInt64 {
        if let suspendedGeneration { return suspendedGeneration }
        return await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        suspendedGeneration = nil
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private actor ThemeCoordinatorServiceCapture {
    private var service: ThemeCoordinatorService?
    private var waiters: [CheckedContinuation<ThemeCoordinatorService, Never>] = []

    func capture(_ service: ThemeCoordinatorService) {
        self.service = service
        let activeWaiters = waiters
        waiters.removeAll()
        activeWaiters.forEach { $0.resume(returning: service) }
    }

    func waitUntilReady() async throws -> ThemeCoordinatorService {
        if let service { return service }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func shutdown() async {
        let service = self.service
        self.service = nil
        await service?.shutdown()
    }
}

private struct SuspensibleThemeCoordinatorModule: RuneScribeModule {
    let descriptor = RuneScribeThemeCoordinatorModuleBootstrap.descriptor
    let serviceCapture: ThemeCoordinatorServiceCapture

    func start(context: ModuleContext) async throws {
        let service = try await ThemeCoordinatorService.bootstrap(
            contributionReader: try await context.contributionReaderClient(),
            resourceResolver: try await context.opaqueResourceResolverClient(),
            settings: try await context.runtimeSettingsClient(),
            availability: try await context.runtimeAvailabilityClient(),
            platform: context.runtimePlatform,
            operatingSystemVersion: context.runtimeOperatingSystemVersion(),
            now: { context.runtimeTimestamp() },
            publishEvent: { type, payload in
                _ = try await context.publishEvent(type, payload: payload)
            }
        )
        do {
            try await context.registerThemeCoordinatorEndpoints(service)
            await serviceCapture.capture(service)
        } catch {
            await service.shutdown()
            throw error
        }
    }

    func stop() async {
        await serviceCapture.shutdown()
    }
}

private enum SyntheticProviderMode: Equatable, Sendable {
    case normal
    case throwAfterPublish
    case descriptorOnly
    case resourceMismatch
}

private struct ProviderRegistration: Sendable {
    let definition: SyntheticThemeDefinition
    let mode: SyntheticProviderMode
    let control: SyntheticThemeProviderControl?

    init(
        definition: SyntheticThemeDefinition,
        mode: SyntheticProviderMode,
        control: SyntheticThemeProviderControl? = nil
    ) {
        self.definition = definition
        self.mode = mode
        self.control = control
    }

    var descriptor: ModuleDescriptor {
        ModuleDescriptor(
            moduleID: definition.moduleID,
            moduleVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            kind: .service,
            criticality: .optional,
            entryPoint: definition.moduleID.rawValue.replacingOccurrences(
                of: ".",
                with: "_"
            ),
            role: ModuleRole(rawValue: definition.descriptor.moduleRole.rawValue),
            policyClass: RuneScribePolicyClasses.themeProvider,
            requestedCapabilities: [
                RuneScribeCapabilities.contributionPublish,
                RuneScribeCapabilities.opaqueResourcePublish,
            ]
        )
    }
}

private struct SyntheticThemeDefinition: Sendable {
    let descriptor: ThemeDescriptor
    let sourceResourceByResourceID: [ThemeResourceID: ThemeResourceID]

    var codexID: CodexID { descriptor.codex.id }
    var unlockID: UnlockID { descriptor.codex.entitlementID }
    var moduleID: ModuleIdentifier {
        ModuleIdentifier(rawValue: descriptor.moduleID.rawValue)
    }

    static func make(
        slug: String,
        portability: ThemeScriptPortability,
        displayName: String,
        sharedRightsID: String? = nil
    ) throws -> Self {
        let base = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let encoded = try JSONEncoder().encode(base)
        let raw = try JSONSerialization.jsonObject(with: encoded)
        let providerScoped = replaceStrings(in: raw, from: "norse", to: slug)
        guard var root = replaceStrings(
            in: providerScoped,
            from: "base-runes",
            to: "\(slug)-runes"
        )
            as? [String: Any],
            var codex = root["codex"] as? [String: Any],
            var scripts = codex["scripts"] as? [[String: Any]],
            !scripts.isEmpty,
            var resources = root["resources"] as? [[String: Any]]
        else {
            throw CoordinatorTestError.invalidSyntheticDescriptor
        }
        root["criticality"] = ThemeCriticality.optional.rawValue
        root["fallbackCodexID"] = RuneScribeCodexIDs.norse.rawValue
        root["contentVersion"] = portability == .fontDependent ? 2 : 3
        if var display = codex["displayName"] as? [String: Any] {
            display["fallbackValue"] = displayName
            codex["displayName"] = display
        }
        if var palette = codex["palette"] as? [String: Any] {
            switch portability {
            case .fontDependent:
                palette["backgroundPrimary"] = "#041A15"
                palette["backgroundSecondary"] = "#0B2A20"
                palette["surfacePrimary"] = "#12352A"
                palette["surfaceElevated"] = "#19483A"
                palette["textSecondary"] = "#D4E8DE"
                palette["textInverse"] = "#041A15"
                palette["accentPrimary"] = "#8DD9B0"
                palette["selected"] = "#8DD9B0"
                palette["focus"] = "#B8F2CF"
                palette["keyboardFocus"] = "#69B7FF"
            case .vectorRendered:
                palette["backgroundPrimary"] = "#180A24"
                palette["backgroundSecondary"] = "#27103A"
                palette["surfacePrimary"] = "#2A1638"
                palette["surfaceElevated"] = "#3A2050"
                palette["textSecondary"] = "#E3D4F0"
                palette["textInverse"] = "#180A24"
                palette["accentPrimary"] = "#D8A8FF"
                palette["selected"] = "#D8A8FF"
                palette["focus"] = "#E8CBFF"
                palette["keyboardFocus"] = "#B98CFF"
            case .unicodePortable:
                break
            }
            codex["palette"] = palette
        }
        scripts[0]["portability"] = portability.rawValue

        var additionalSource: (ThemeResourceID, ThemeResourceID)?
        if portability == .vectorRendered {
            guard let sourceIndex = base.resources.firstIndex(where: {
                $0.mediaType == .pdf
            }),
                var vectorResource = resources[safe: sourceIndex],
                let sourceID = ThemeResourceID(
                    rawValue: base.resources[sourceIndex].id.rawValue
                )
            else {
                throw CoordinatorTestError.invalidSyntheticDescriptor
            }
            let vectorID = ThemeResourceID(
                rawValue: "resource.\(slug).script.glyph-vector"
            )!
            vectorResource["id"] = vectorID.rawValue
            vectorResource["role"] = ThemeResourceRoles.scriptGlyphVector.rawValue
            resources.append(vectorResource)
            guard var glyphs = scripts[0]["glyphs"] as? [[String: Any]] else {
                throw CoordinatorTestError.invalidSyntheticDescriptor
            }
            for index in glyphs.indices {
                glyphs[index]["vectorResourceID"] = vectorID.rawValue
            }
            scripts[0]["glyphs"] = glyphs
            additionalSource = (vectorID, sourceID)
        }

        codex["scripts"] = scripts
        root["codex"] = codex
        root["resources"] = resources
        if let sharedRightsID,
           let rights = root["rights"] as? [[String: Any]],
           let oldRightsID = rights.first?["id"] as? String
        {
            guard let rewritten = replaceStrings(
                in: root,
                from: oldRightsID,
                to: sharedRightsID
            ) as? [String: Any] else {
                throw CoordinatorTestError.invalidSyntheticDescriptor
            }
            root = rewritten
        }
        let descriptorData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.sortedKeys]
        )
        let descriptor = try JSONDecoder().decode(
            ThemeDescriptor.self,
            from: descriptorData
        )
        var mapping = Dictionary(uniqueKeysWithValues: base.resources.map {
            source in
            let transformedRawValue = source.id.rawValue
                .replacingOccurrences(of: "norse", with: slug)
                .replacingOccurrences(of: "base-runes", with: "\(slug)-runes")
            let transformed = ThemeResourceID(rawValue: transformedRawValue)!
            return (transformed, source.id)
        })
        if let additionalSource {
            mapping[additionalSource.0] = additionalSource.1
        }
        return Self(
            descriptor: descriptor,
            sourceResourceByResourceID: mapping
        )
    }

    func payloads(
        from base: ValidatedNorseBaseTheme
    ) throws -> [ThemeResourceID: Data] {
        var result: [ThemeResourceID: Data] = [:]
        for resource in descriptor.resources {
            guard let sourceID = sourceResourceByResourceID[resource.id],
                  let data = base.resourcePayloads[sourceID]
            else {
                throw CoordinatorTestError.resourceMappingMissing(resource.id)
            }
            result[resource.id] = data
        }
        return result
    }

    private static func replaceStrings(
        in value: Any,
        from: String,
        to: String
    ) -> Any {
        if let string = value as? String {
            return string.replacingOccurrences(of: from, with: to)
        }
        if let values = value as? [Any] {
            return values.map { replaceStrings(in: $0, from: from, to: to) }
        }
        if let values = value as? [String: Any] {
            return values.mapValues { replaceStrings(in: $0, from: from, to: to) }
        }
        return value
    }
}

private actor SyntheticThemeProviderControl {
    private var publisher: RuntimeContributionPublisherClient?
    private var resourceProvider: RuntimeOpaqueResourceProviderClient?
    private var descriptor: ThemeDescriptor?

    func capture(
        publisher: RuntimeContributionPublisherClient,
        resourceProvider: RuntimeOpaqueResourceProviderClient,
        descriptor: ThemeDescriptor
    ) {
        self.publisher = publisher
        self.resourceProvider = resourceProvider
        self.descriptor = descriptor
    }

    func revoke() async throws {
        guard let publisher, let resourceProvider, let descriptor else {
            throw CoordinatorTestError.providerControlUnavailable
        }
        try await resourceProvider.unregister(
            RuntimeThemeContributionCatalog.resourceNamespace(for: descriptor.codex.id)
        )
        _ = try await publisher.remove(
            key: RuntimeThemeContributionCatalog.key(for: descriptor.codex.id),
            type: RuntimeThemeContributionCatalog.descriptor
        )
    }
}

private actor SyntheticThemePayloadSource {
    private var value: ValidatedNorseBaseTheme?

    func install(_ value: ValidatedNorseBaseTheme) {
        self.value = value
    }

    func baseTheme() throws -> ValidatedNorseBaseTheme {
        guard let value else {
            throw CoordinatorTestError.basePayloadUnavailable
        }
        return value
    }
}

private actor ThemeCoordinatorClientProbe {
    private var client: RuntimeThemeCoordinatorClient?
    private var snapshots: [ThemeCoordinatorSnapshotDTO] = []
    private var observation: Task<Void, Never>?

    func capture(_ client: RuntimeThemeCoordinatorClient) {
        self.client = client
        observation?.cancel()
        observation = Task { [weak self] in
            for await envelope in client.stateEnvelopes {
                guard !Task.isCancelled else { return }
                await self?.record(envelope.payload)
            }
        }
    }

    func select(
        _ command: SelectThemeCodexCommand
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        guard let client else { throw CoordinatorTestError.clientUnavailable }
        return try await client.selectCodex(command)
    }

    func resolve(
        _ request: ResolveThemeResourceRequestDTO
    ) async throws -> ResolvedThemeResourceDTO {
        guard let client else { throw CoordinatorTestError.clientUnavailable }
        return try await client.resolveResource(request)
    }

    func resolveCatalogPreview(
        codexID: CodexID,
        resourceID: ThemeResourceID
    ) async throws -> ResolvedThemeResourceDTO {
        guard let client else { throw CoordinatorTestError.clientUnavailable }
        return try await client.resolveCatalogPreviewResource(
            codexID: codexID,
            resourceID: resourceID
        )
    }

    func waitForSnapshot(
        matching predicate: @escaping @Sendable (ThemeCoordinatorSnapshotDTO) -> Bool
    ) async throws -> ThemeCoordinatorSnapshotDTO {
        for _ in 0 ..< 400 {
            if let snapshot = snapshots.last(where: predicate) {
                return snapshot
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let summary = snapshots.last.map { snapshot in
            snapshot.providers.map {
                "\($0.codexID.rawValue)=\($0.state.rawValue)"
            }.joined(separator: ",")
        } ?? "no-snapshot"
        throw CoordinatorTestError.snapshotTimeout(summary)
    }

    private func record(_ snapshot: ThemeCoordinatorSnapshotDTO) {
        snapshots.append(snapshot)
    }
}

private actor ThemeDiagnosticsProbe {
    private var queryClient: RuntimeQueryClient?

    func capture(_ queryClient: RuntimeQueryClient) {
        self.queryClient = queryClient
    }

    func waitUntilReady() async throws {
        for _ in 0 ..< 400 {
            if queryClient != nil { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CoordinatorTestError.clientUnavailable
    }

    func query() async throws -> ThemeCoordinatorDiagnosticsDTO {
        guard let queryClient else { throw CoordinatorTestError.clientUnavailable }
        return try await queryClient.fetch(
            RuntimeEmptyPayload(),
            from: RuntimeThemeEndpointCatalog.diagnostics
        )
    }
}

private struct CoordinatorTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private struct CoordinatorNorseResourceLocator: ApplicationResourceLocator, Sendable {
    let unavailableResource: ApplicationResource?

    init(unavailableResource: ApplicationResource? = nil) {
        self.unavailableResource = unavailableResource
    }

    func data(for resource: ApplicationResource) async throws -> Data {
        try Data(contentsOf: try location(for: resource))
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        guard resource != unavailableResource,
              resource.ownerModuleID == RuneScribeModuleIDs.norseTheme,
              let location = RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                  forResource: resource.name,
                  withExtension: resource.fileExtension,
                  subdirectory: resource.subdirectory
              )
        else {
            throw CoordinatorTestError.applicationResourceUnavailable(resource)
        }
        return location
    }
}

private enum CoordinatorTestError: Error {
    case invalidSyntheticDescriptor
    case resourceMappingMissing(ThemeResourceID)
    case providerControlUnavailable
    case clientUnavailable
    case snapshotTimeout(String)
    case expectedProviderFailure
    case applicationResourceUnavailable(ApplicationResource)
    case basePayloadUnavailable
    case baseResourceMismatch(ThemeResourceID)
    case baseResourceResolveFailed(ThemeResourceID, String)
    case stageFailure(String, String)
}

private func provider(
    in snapshot: ThemeCoordinatorSnapshotDTO,
    codexID: CodexID
) -> ThemeProviderSummaryDTO? {
    snapshot.providers.first { $0.codexID == codexID }
}

private func diagnostic(
    in diagnostics: ThemeCoordinatorDiagnosticsDTO,
    codexID: CodexID
) -> ThemeProviderDiagnosticDTO? {
    diagnostics.providers.first { $0.codexID == codexID }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
