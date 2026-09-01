import Foundation
import RuneScribeContracts
@testable import RuneScribeNorseThemeModule
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
@testable import RuneScribeThemeCoordinatorModule
import RuneScribeThemeMoonleafModule
import XCTest

final class ThemeCoordinatorConformanceTests: XCTestCase {
    func testDamagedRequiredNorseFontUsesEmergencyPresentationWithoutStoppingRuntime()
        async throws
    {
        let unavailableFont = NorseBaseBundledResourceCatalog.notoSansRunic
        let harness = try await makeHarness(
            providers: [],
            permitsDiagnostics: true,
            includeDiagnosticsClient: true,
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
        let failure = try XCTUnwrap(snapshot.requiredBaseResourceFailures.first)
        XCTAssertEqual(snapshot.requiredBaseResourceFailures.count, 1)
        XCTAssertEqual(failure.moduleID, RuneScribeModuleIDs.norseTheme)
        XCTAssertEqual(failure.codexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(failure.resourceID, fontID)
        XCTAssertEqual(failure.stage, .resourceRead)
        XCTAssertEqual(failure.errorCode, .resourceUnavailable)

        let diagnostics = try await harness.diagnostics.query()
        XCTAssertEqual(diagnostics.fallbackReason, .invalidResources)
        XCTAssertEqual(diagnostics.requiredBaseResourceFailures, [failure])

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
        do {
            _ = try await harness.probe.resolve(
                ResolveThemeResourceRequestDTO(
                    codexID: fontTheme.codexID,
                    resourceID: lockedCardResourceID
                )
            )
            XCTFail("An unselected provider must not resolve active presentation bytes")
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

    func testShareRenderingRequiresOwnedAvailableProviderButNotActiveSelection()
        async throws
    {
        let definition = try SyntheticThemeDefinition.make(
            slug: "sharewood",
            portability: .fontDependent,
            displayName: "Sharewood Test Codex"
        )
        let control = SyntheticThemeProviderControl()
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(
                    definition: definition,
                    mode: .normal,
                    control: control
                ),
            ]
        )
        defer { Task { await harness.runtime.stop() } }

        let resourceID = try XCTUnwrap(
            definition.descriptor.codex.relics.first(where: {
                $0.metadata.availability != .reservedInactive
            })?.staticFallbackResourceID
        )
        let shareRequest = ResolveThemeResourceRequestDTO(
            codexID: definition.codexID,
            resourceID: resourceID,
            purpose: .shareRendering
        )
        let initiallyLocked = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: definition.codexID)?.state == .locked
        }
        XCTAssertFalse(
            try XCTUnwrap(provider(in: initiallyLocked, codexID: definition.codexID))
                .isOwned
        )

        func assertDenied(
            _ request: ResolveThemeResourceRequestDTO,
            _ reason: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) async {
            do {
                _ = try await harness.probe.resolve(request)
                XCTFail(reason, file: file, line: line)
            } catch {
                XCTAssertEqual(
                    error as? ThemeCoordinatorModuleError,
                    .resourceUnavailable(request),
                    file: file,
                    line: line
                )
            }
        }

        await assertDenied(
            shareRequest,
            "Locked, unowned providers must not expose share-rendering resources"
        )

        try await harness.runtime.reconcileEntitlements(
            try entitlementSnapshot(revision: 1, earned: [definition.unlockID])
        )
        let available = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: definition.codexID)?.state == .available
        }
        XCTAssertEqual(available.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertTrue(
            try XCTUnwrap(provider(in: available, codexID: definition.codexID)).isOwned
        )
        let activeRequest = ResolveThemeResourceRequestDTO(
            codexID: definition.codexID,
            resourceID: resourceID,
            purpose: .activePresentation
        )
        await assertDenied(
            activeRequest,
            "Active presentation must remain limited to the effective provider"
        )
        let resolved = try await harness.probe.resolve(shareRequest)
        XCTAssertEqual(resolved.resourceID, resourceID)

        try await control.revoke()
        _ = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: definition.codexID)?.state == .unavailable
        }
        await assertDenied(
            shareRequest,
            "Unavailable providers must not expose share-rendering resources"
        )

        await harness.runtime.stop()
    }

    func testShareRenderingAllowsOnlyDeclaredStaticCompositionResources() throws {
        let definition = try SyntheticThemeDefinition.make(
            slug: "sharepolicy",
            portability: .fontDependent,
            displayName: "Share Policy Test Codex"
        )
        let descriptor = definition.descriptor
        let codex = descriptor.codex
        let primaryScript = try XCTUnwrap(
            codex.scripts.first(where: { $0.id == codex.primaryScriptID })
        )
        var allowedResourceIDs = Set([
            codex.background.staticBaseResourceID,
            codex.background.reduceMotionResourceID,
            codex.background.highContrastResourceID,
        ])
        if let fontResourceID = primaryScript.fontResourceID {
            allowedResourceIDs.insert(fontResourceID)
        }
        for relic in codex.relics
            where relic.metadata.availability != .reservedInactive
        {
            allowedResourceIDs.formUnion([
                relic.staticFallbackResourceID,
                relic.highContrastResourceID,
            ])
        }
        for seal in codex.seals
            where seal.metadata.availability != .reservedInactive
        {
            allowedResourceIDs.insert(seal.monochromeFallbackResourceID)
            allowedResourceIDs.formUnion(
                [seal.colorResourceID, seal.vectorResourceID].compactMap { $0 }
            )
        }
        for frame in codex.frames
            where frame.metadata.availability != .reservedInactive
        {
            allowedResourceIDs.insert(frame.staticFallbackResourceID)
        }

        for reference in descriptor.resources {
            XCTAssertEqual(
                ThemeCoordinatorService.isShareRenderingResource(
                    reference,
                    descriptor: descriptor
                ),
                allowedResourceIDs.contains(reference.id),
                reference.id.rawValue
            )
        }

        let deniedGroups: [(String, [ThemeResourceID])] = [
            (
                "reserved-inactive",
                codex.relics.filter {
                    $0.metadata.availability == .reservedInactive
                }.flatMap {
                    [$0.staticFallbackResourceID, $0.highContrastResourceID]
                }
            ),
            (
                "thumbnails",
                codex.relics.map(\.thumbnailResourceID)
                    + codex.seals.map(\.thumbnailResourceID)
                    + codex.frames.compactMap(\.thumbnailResourceID)
            ),
            (
                "vault",
                [
                    codex.vault.cardResourceID,
                    codex.vault.lockedSilhouetteResourceID,
                    codex.vault.encounteredResourceID,
                    codex.vault.selectedResourceID,
                ] + [codex.vault.unavailableResourceID].compactMap { $0 }
            ),
            (
                "crest",
                codex.crests.flatMap {
                    [$0.vectorResourceID, $0.staticFallbackResourceID]
                        + [$0.thumbnailResourceID].compactMap { $0 }
                }
            ),
            (
                "audio",
                descriptor.resources.filter {
                    [.m4a, .caf, .wav].contains($0.mediaType)
                }.map(\.id)
            ),
        ]
        for (name, resourceIDs) in deniedGroups {
            XCTAssertFalse(resourceIDs.isEmpty, name)
            for resourceID in resourceIDs {
                let reference = try XCTUnwrap(
                    descriptor.resources.first(where: { $0.id == resourceID })
                )
                XCTAssertFalse(
                    ThemeCoordinatorService.isShareRenderingResource(
                        reference,
                        descriptor: descriptor
                    ),
                    "\(name):\(resourceID.rawValue)"
                )
            }
        }

        let backgroundReference = try XCTUnwrap(
            descriptor.resources.first(where: {
                $0.id == codex.background.staticBaseResourceID
            })
        )
        let spoofedRole = try ThemeResourceReference(
            id: backgroundReference.id,
            role: ThemeResourceRoles.vaultCard,
            mediaType: backgroundReference.mediaType,
            requirement: backgroundReference.requirement,
            integrity: backgroundReference.integrity,
            rightsID: backgroundReference.rightsID
        )
        XCTAssertFalse(
            ThemeCoordinatorService.isShareRenderingResource(
                spoofedRole,
                descriptor: descriptor
            )
        )
        let motionVideo = try ThemeResourceReference(
            id: ThemeResourceID(rawValue: "resource.sharepolicy.motion-video")!,
            role: ThemeResourceRoles.backgroundMotion,
            mediaType: .mp4,
            requirement: .optional,
            integrity: backgroundReference.integrity,
            rightsID: backgroundReference.rightsID
        )
        XCTAssertFalse(
            ThemeCoordinatorService.isShareRenderingResource(
                motionVideo,
                descriptor: descriptor
            )
        )

        let receivedRoles = [
            ThemeResourceRoles.receivedPrimarySenderAvatar,
            ThemeResourceRoles.receivedShareSenderAvatar,
            ThemeResourceRoles.receivedShareCodexBadge,
            ThemeResourceRoles.receivedPrimaryMedallion,
            ThemeResourceRoles.receivedShareMedallion,
        ]
        for (index, role) in receivedRoles.enumerated() {
            let reference = try ThemeResourceReference(
                id: ThemeResourceID(
                    rawValue: "resource.sharepolicy.received-identity.\(index)"
                )!,
                role: role,
                mediaType: .png,
                requirement: .required,
                integrity: backgroundReference.integrity,
                rightsID: backgroundReference.rightsID
            )
            XCTAssertFalse(
                ThemeCoordinatorService.isShareRenderingResource(
                    reference,
                    descriptor: descriptor
                ),
                reference.id.rawValue
            )
        }
    }

    func testCatalogPreviewAllowsFrameThumbnailButShareRenderingDoesNot() throws {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let frame = try XCTUnwrap(descriptor.codex.frames.first)
        let thumbnailResourceID = try XCTUnwrap(frame.thumbnailResourceID)
        let reference = try XCTUnwrap(descriptor.resources.first(where: {
            $0.id == thumbnailResourceID
        }))

        XCTAssertEqual(reference.role, ThemeResourceRoles.frameThumbnail)
        XCTAssertTrue(ThemeCoordinatorService.isCatalogPreviewResource(
            reference,
            descriptor: descriptor
        ))
        XCTAssertFalse(ThemeCoordinatorService.isShareRenderingResource(
            reference,
            descriptor: descriptor
        ))
    }

    func testReceivedPresentationPurposeDoesNotBypassNonOwnedProviderRuntimeGate()
        async throws
    {
        let definition = try SyntheticThemeDefinition.make(
            slug: "receivedpolicy",
            portability: .fontDependent,
            displayName: "Received Policy Test Codex",
            includesReceivedPresentation: true
        )
        let harness = try await makeHarness(
            providers: [ProviderRegistration(definition: definition, mode: .normal)]
        )
        defer { Task { await harness.runtime.stop() } }

        let snapshot = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: definition.codexID)?.state == .locked
        }
        let providerSummary = try XCTUnwrap(
            provider(in: snapshot, codexID: definition.codexID)
        )
        XCTAssertFalse(providerSummary.isOwned)
        XCTAssertFalse(providerSummary.isSelectable)
        XCTAssertFalse(providerSummary.isSelected)
        XCTAssertEqual(snapshot.effectiveCodexID, RuneScribeCodexIDs.norse)

        do {
            _ = try await harness.probe.descriptor(
                codexID: definition.codexID,
                purpose: .selection
            )
            XCTFail("A received encounter must not grant selection authority")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .codexNotSelectable(definition.codexID)
            )
        }
        do {
            _ = try await harness.probe.descriptor(
                codexID: definition.codexID,
                purpose: .receivedPresentation
            )
            XCTFail("A provider whose module is entitlement-gated is not runtime-available")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .codexNotSelectable(definition.codexID)
            )
        }

        let descriptor = definition.descriptor
        let received = try XCTUnwrap(descriptor.codex.receivedPresentation)
        let selection = try SharePresentationSelection(
            codexID: descriptor.codex.id,
            scriptID: descriptor.codex.primaryScriptID,
            relicID: descriptor.codex.defaultRelicID
        )
        let receivedRequest = ResolveThemeResourceRequestDTO(
            codexID: descriptor.codex.id,
            resourceID: received.primarySenderAvatarResourceID,
            purpose: .receivedPresentation,
            receivedPresentationSelection: selection
        )
        do {
            _ = try await harness.probe.resolve(receivedRequest)
            XCTFail("Received presentation reads must require a running provider")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .resourceUnavailable(receivedRequest)
            )
        }

        await harness.runtime.stop()
    }

    func testReceivedPresentationAllowsOnlySelectedCompositionAndDeclaredIdentityResources()
        throws
    {
        let descriptor = RuneScribeThemeMoonleafModuleBootstrap.discoveryDescriptor
        let codex = descriptor.codex
        let seal = try XCTUnwrap(
            codex.seals.first(where: {
                $0.metadata.availability != .reservedInactive
            })
        )
        let relic = try XCTUnwrap(
            codex.relics.first(where: {
                $0.metadata.id == codex.defaultRelicID
            })
        )
        let received = try XCTUnwrap(codex.receivedPresentation)
        let selection = try SharePresentationSelection(
            codexID: codex.id,
            scriptID: codex.primaryScriptID,
            relicID: relic.metadata.id,
            sealID: seal.metadata.id
        )
        var allowedResourceIDs = Set([
            codex.background.staticBaseResourceID,
            codex.background.reduceMotionResourceID,
            relic.staticFallbackResourceID,
            seal.standardResourceID,
            received.primarySenderAvatarResourceID,
            received.shareSenderAvatarResourceID,
            received.shareCodexBadgeResourceID,
            received.primaryMedallion.resourceID,
            received.shareMedallion.resourceID,
        ])
        let primaryScript = try XCTUnwrap(
            codex.scripts.first(where: { $0.id == codex.primaryScriptID })
        )
        if let fontResourceID = primaryScript.fontResourceID {
            allowedResourceIDs.insert(fontResourceID)
        }

        for reference in descriptor.resources {
            XCTAssertEqual(
                ThemeCoordinatorService.isReceivedPresentationResource(
                    reference,
                    descriptor: descriptor,
                    selection: selection
                ),
                allowedResourceIDs.contains(reference.id),
                reference.id.rawValue
            )
        }

        let otherRelic = try XCTUnwrap(codex.relics.first(where: {
            $0.metadata.id != relic.metadata.id
                && $0.metadata.availability != .reservedInactive
        }))
        let otherRelicReference = try XCTUnwrap(
            descriptor.resources.first(where: {
                $0.id == otherRelic.staticFallbackResourceID
            })
        )
        XCTAssertFalse(
            ThemeCoordinatorService.isReceivedPresentationResource(
                otherRelicReference,
                descriptor: descriptor,
                selection: selection
            )
        )
        let vaultReference = try XCTUnwrap(
            descriptor.resources.first(where: {
                $0.id == codex.vault.selectedResourceID
            })
        )
        XCTAssertFalse(
            ThemeCoordinatorService.isReceivedPresentationResource(
                vaultReference,
                descriptor: descriptor,
                selection: selection
            )
        )
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

    func testSuspendedActiveResolutionCannotReturnAfterSelectionChanges()
        async throws
    {
        let theme = try SyntheticThemeDefinition.make(
            slug: "resolutionrace",
            portability: .fontDependent,
            displayName: "Resolution Race Test Codex"
        )
        let resourceGate = SyntheticThemeResourceLoadGate()
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(
                    definition: theme,
                    mode: .normal,
                    resourceGate: resourceGate
                ),
            ]
        )
        defer { Task { await harness.runtime.stop() } }

        try await harness.runtime.reconcileEntitlements(
            try entitlementSnapshot(revision: 1, earned: [theme.unlockID])
        )
        let available = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: theme.codexID)?.state == .available
        }
        let selected = try await harness.probe.select(
            SelectThemeCodexCommand(
                codexID: theme.codexID,
                expectedSnapshotRevision: available.revision
            )
        )
        XCTAssertEqual(selected.effectiveCodexID, theme.codexID)

        let resourceID = theme.descriptor.codex.vault.cardResourceID
        let request = ResolveThemeResourceRequestDTO(
            codexID: theme.codexID,
            resourceID: resourceID
        )
        await resourceGate.arm(resourceID: resourceID)
        let resolution = Task { try await harness.probe.resolve(request) }
        await resourceGate.waitUntilSuspended()

        do {
            let baseSelected = try await harness.probe.select(
                SelectThemeCodexCommand(codexID: RuneScribeCodexIDs.norse)
            )
            XCTAssertEqual(baseSelected.effectiveCodexID, RuneScribeCodexIDs.norse)
            await resourceGate.release()
        } catch {
            await resourceGate.release()
            throw error
        }

        do {
            _ = try await resolution.value
            XCTFail("A stale active-presentation resolution must not return bytes")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .resourceUnavailable(request)
            )
        }
    }

    func testSelectionDoesNotReportSuccessWhenProviderRevokedAfterSettingsWrite()
        async throws
    {
        let theme = try SyntheticThemeDefinition.make(
            slug: "selectionrace",
            portability: .fontDependent,
            displayName: "Selection Race Test Codex"
        )
        let providerControl = SyntheticThemeProviderControl()
        let selectionGate = SelectionPostWriteGate()
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(
                    definition: theme,
                    mode: .normal,
                    control: providerControl
                ),
            ],
            selectionDidWrite: { codexID in
                await selectionGate.suspendIfArmed(codexID: codexID)
            }
        )
        defer { Task { await harness.runtime.stop() } }

        try await harness.runtime.reconcileEntitlements(
            try entitlementSnapshot(revision: 1, earned: [theme.unlockID])
        )
        let available = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: theme.codexID)?.state == .available
        }
        await selectionGate.arm(codexID: theme.codexID)
        let selection = Task {
            try await harness.probe.select(
                SelectThemeCodexCommand(
                    codexID: theme.codexID,
                    expectedSnapshotRevision: available.revision
                )
            )
        }
        await selectionGate.waitUntilSuspended()

        do {
            try await providerControl.revoke()
            _ = try await harness.probe.waitForSnapshot { snapshot in
                snapshot.preferredCodexID == theme.codexID
                    && snapshot.effectiveCodexID == RuneScribeCodexIDs.norse
                    && provider(in: snapshot, codexID: theme.codexID)?.state
                        == .unavailable
            }
            await selectionGate.release()
        } catch {
            await selectionGate.release()
            throw error
        }

        do {
            _ = try await selection.value
            XCTFail("Selection must not report success after the provider is revoked")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .codexNotSelectable(theme.codexID)
            )
        }
    }

    func testSelectionRevalidatesCachedAcceptanceBeforeWritingSettings()
        async throws
    {
        let theme = try SyntheticThemeDefinition.make(
            slug: "selectionpayload",
            portability: .fontDependent,
            displayName: "Selection Payload Test Codex"
        )
        let resourceID = try XCTUnwrap(
            theme.descriptor.resources
                .filter { $0.requirement == .required }
                .sorted { $0.id < $1.id }
                .first?.id
        )
        let payloadControl = SyntheticThemePayloadMutationControl(
            corruptOnLoad: 2,
            resourceID: resourceID
        )
        let writeProbe = ThemeSelectionWriteProbe()
        let harness = try await makeHarness(
            providers: [
                ProviderRegistration(
                    definition: theme,
                    mode: .normal,
                    payloadControl: payloadControl
                ),
            ],
            selectionDidWrite: { codexID in
                await writeProbe.record(codexID)
            }
        )
        defer { Task { await harness.runtime.stop() } }

        try await harness.runtime.reconcileEntitlements(
            try entitlementSnapshot(revision: 1, earned: [theme.unlockID])
        )
        let available = try await harness.probe.waitForSnapshot { snapshot in
            provider(in: snapshot, codexID: theme.codexID)?.state == .available
        }
        let firstSelection = try await harness.probe.select(
            SelectThemeCodexCommand(
                codexID: theme.codexID,
                expectedSnapshotRevision: available.revision
            )
        )
        XCTAssertEqual(firstSelection.effectiveCodexID, theme.codexID)
        let firstLoadCount = await payloadControl.targetLoadCount()
        XCTAssertEqual(firstLoadCount, 1)

        let baseSelection = try await harness.probe.select(
            SelectThemeCodexCommand(codexID: RuneScribeCodexIDs.norse)
        )
        XCTAssertEqual(baseSelection.effectiveCodexID, RuneScribeCodexIDs.norse)
        let writesBeforeRejectedSelection = await writeProbe.recordedCodexIDs()
        XCTAssertEqual(
            writesBeforeRejectedSelection,
            [theme.codexID, RuneScribeCodexIDs.norse]
        )

        do {
            _ = try await harness.probe.select(
                SelectThemeCodexCommand(codexID: theme.codexID)
            )
            XCTFail("Selection must revalidate deferred bytes before writing settings")
        } catch {
            XCTAssertEqual(
                error as? ThemeCoordinatorModuleError,
                .codexNotSelectable(theme.codexID)
            )
        }

        let finalLoadCount = await payloadControl.targetLoadCount()
        XCTAssertEqual(finalLoadCount, 2)
        let writesAfterRejectedSelection = await writeProbe.recordedCodexIDs()
        XCTAssertEqual(writesAfterRejectedSelection, writesBeforeRejectedSelection)
    }

    private func makeHarness(
        providers: [ProviderRegistration],
        permitsDiagnostics: Bool = false,
        includeDiagnosticsClient: Bool = false,
        serviceCapture: ThemeCoordinatorServiceCapture? = nil,
        unavailableBaseResource: ApplicationResource? = nil,
        selectionDidWrite: ThemeCoordinatorSelectionDidWriteHook? = nil
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
        let coordinatorServiceCapture: ThemeCoordinatorServiceCapture?
        if let serviceCapture {
            coordinatorServiceCapture = serviceCapture
        } else if selectionDidWrite != nil {
            coordinatorServiceCapture = ThemeCoordinatorServiceCapture()
        } else {
            coordinatorServiceCapture = nil
        }
        if let coordinatorServiceCapture {
            coordinatorFactory = AnyModuleFactory(
                descriptor: RuneScribeThemeCoordinatorModuleBootstrap.descriptor
            ) {
                SuspensibleThemeCoordinatorModule(
                    serviceCapture: coordinatorServiceCapture,
                    selectionDidWrite: selectionDidWrite ?? { _ in }
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
                    resourceLoader: { resourceID in
                        if let resourceGate = registration.resourceGate {
                            await resourceGate.suspendIfArmed(resourceID: resourceID)
                        }
                        if let payloadControl = registration.payloadControl {
                            return await payloadControl.payload(
                                for: resourceID,
                                validPayload: payloads[resourceID]
                            )
                        }
                        return payloads[resourceID]
                    }
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
                        resourceLoader: { opaqueResourceID in
                            guard let resourceID = ThemeResourceID(
                                rawValue: opaqueResourceID.rawValue
                            ) else { return nil }
                            return payloads[resourceID]
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

private actor SyntheticThemeResourceLoadGate {
    private var armedResourceID: ThemeResourceID?
    private var suspendedResourceID: ThemeResourceID?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func arm(resourceID: ThemeResourceID) {
        armedResourceID = resourceID
    }

    func suspendIfArmed(resourceID: ThemeResourceID) async {
        guard armedResourceID == resourceID else { return }
        armedResourceID = nil
        suspendedResourceID = resourceID
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if suspendedResourceID != nil { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        suspendedResourceID = nil
        let continuation = releaseContinuation
        releaseContinuation = nil
        continuation?.resume()
    }
}

private actor SyntheticThemePayloadMutationControl {
    private let corruptOnLoad: Int
    private let resourceID: ThemeResourceID
    private var loadCount = 0

    init(corruptOnLoad: Int, resourceID: ThemeResourceID) {
        self.corruptOnLoad = corruptOnLoad
        self.resourceID = resourceID
    }

    func payload(
        for resourceID: ThemeResourceID,
        validPayload: Data?
    ) -> Data? {
        guard resourceID == self.resourceID else { return validPayload }
        loadCount += 1
        guard loadCount >= corruptOnLoad, var validPayload else {
            return validPayload
        }
        validPayload.append(0)
        return validPayload
    }

    func targetLoadCount() -> Int {
        loadCount
    }
}

private actor ThemeSelectionWriteProbe {
    private var codexIDs: [CodexID] = []

    func record(_ codexID: CodexID) {
        codexIDs.append(codexID)
    }

    func recordedCodexIDs() -> [CodexID] {
        codexIDs
    }
}

private actor SelectionPostWriteGate {
    private var armedCodexID: CodexID?
    private var suspendedCodexID: CodexID?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func arm(codexID: CodexID) {
        armedCodexID = codexID
    }

    func suspendIfArmed(codexID: CodexID) async {
        guard armedCodexID == codexID else { return }
        armedCodexID = nil
        suspendedCodexID = codexID
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilSuspended() async {
        if suspendedCodexID != nil { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func release() {
        suspendedCodexID = nil
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
    let selectionDidWrite: ThemeCoordinatorSelectionDidWriteHook

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
            },
            selectionDidWrite: selectionDidWrite
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
    let resourceGate: SyntheticThemeResourceLoadGate?
    let payloadControl: SyntheticThemePayloadMutationControl?

    init(
        definition: SyntheticThemeDefinition,
        mode: SyntheticProviderMode,
        control: SyntheticThemeProviderControl? = nil,
        resourceGate: SyntheticThemeResourceLoadGate? = nil,
        payloadControl: SyntheticThemePayloadMutationControl? = nil
    ) {
        self.definition = definition
        self.mode = mode
        self.control = control
        self.resourceGate = resourceGate
        self.payloadControl = payloadControl
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
        sharedRightsID: String? = nil,
        includesReceivedPresentation: Bool = false
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
        if var relics = codex["relics"] as? [[String: Any]],
           let reservedIndex = relics.indices.last,
           var metadata = relics[reservedIndex]["metadata"] as? [String: Any]
        {
            metadata["availability"] = ThemeArtifactAvailability.reservedInactive.rawValue
            relics[reservedIndex]["metadata"] = metadata
            codex["relics"] = relics
        }

        var additionalSources: [(ThemeResourceID, ThemeResourceID)] = []
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
            additionalSources.append((vectorID, sourceID))
        }

        if includesReceivedPresentation {
            let roles: [(String, ThemeResourceRoleID)] = [
                ("primary.sender-avatar", ThemeResourceRoles.receivedPrimarySenderAvatar),
                ("share.sender-avatar", ThemeResourceRoles.receivedShareSenderAvatar),
                ("share.codex-badge", ThemeResourceRoles.receivedShareCodexBadge),
                ("primary.medallion", ThemeResourceRoles.receivedPrimaryMedallion),
                ("share.medallion", ThemeResourceRoles.receivedShareMedallion),
            ]
            let sourceReferences = base.resources.filter {
                $0.mediaType == .png
            }
            guard sourceReferences.count >= roles.count else {
                throw CoordinatorTestError.invalidSyntheticDescriptor
            }
            var receivedIDs: [String: ThemeResourceID] = [:]
            for (index, entry) in roles.enumerated() {
                let source = sourceReferences[index]
                guard let sourceIndex = base.resources.firstIndex(where: {
                    $0.id == source.id
                }), var resource = resources[safe: sourceIndex]
                else { throw CoordinatorTestError.invalidSyntheticDescriptor }
                let resourceID = ThemeResourceID(
                    rawValue: "resource.received.\(slug).\(entry.0)"
                )!
                resource["id"] = resourceID.rawValue
                resource["role"] = entry.1.rawValue
                resources.append(resource)
                receivedIDs[entry.0] = resourceID
                additionalSources.append((resourceID, source.id))
            }
            codex["receivedPresentation"] = [
                "familyDisplayName": [
                    "key": "codex.\(slug).received-family.name",
                    "fallbackValue": "\(displayName) Received",
                ],
                "primarySenderAvatarResourceID":
                    receivedIDs["primary.sender-avatar"]!.rawValue,
                "shareSenderAvatarResourceID":
                    receivedIDs["share.sender-avatar"]!.rawValue,
                "shareCodexBadgeResourceID":
                    receivedIDs["share.codex-badge"]!.rawValue,
                "primaryMedallion": [
                    "resourceID": receivedIDs["primary.medallion"]!.rawValue,
                    "anchor": ["x": 0.8, "y": 0.8],
                    "scale": 0.2,
                ],
                "shareMedallion": [
                    "resourceID": receivedIDs["share.medallion"]!.rawValue,
                    "anchor": ["x": 0.75, "y": 0.8],
                    "scale": 0.16,
                ],
            ]
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
        for additionalSource in additionalSources {
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

    func descriptor(
        codexID: CodexID,
        purpose: ThemeProviderDescriptorPurpose
    ) async throws -> ThemeDescriptor {
        guard let client else { throw CoordinatorTestError.clientUnavailable }
        return try await client.providerDescriptor(
            for: codexID,
            purpose: purpose
        )
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
