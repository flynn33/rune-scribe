import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
import RuneScribeThemeGloamthornModule
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class ShareBuilderModelTests: XCTestCase {
    func testFixedSecuritySummariesCoverEveryPurpose() {
        XCTAssertEqual(
            ShareBuilderPurpose.encryptedMessage(requiresKeyDelivery: true)
                .securitySummary,
            "Key included — this first delivery contains the shared cipher."
        )
        XCTAssertEqual(
            ShareBuilderPurpose.encryptedMessage(requiresKeyDelivery: false)
                .securitySummary,
            "Uses your shared key — this message does not resend the cipher."
        )
        XCTAssertEqual(
            ShareBuilderPurpose.cipherInvitation.securitySummary,
            "Contains shared cipher — anyone who imports this invitation receives the decoder for this cipher."
        )
        XCTAssertEqual(
            ShareBuilderPurpose.encryptedMessage(requiresKeyDelivery: true)
                .securityAccessibilityIdentifier,
            "share-builder.security.first-delivery"
        )
        XCTAssertEqual(
            ShareBuilderPurpose.encryptedMessage(requiresKeyDelivery: false)
                .securityAccessibilityIdentifier,
            "share-builder.security.established"
        )
        XCTAssertEqual(
            ShareBuilderPurpose.cipherInvitation.securityAccessibilityIdentifier,
            "share-builder.security.cipher-invitation"
        )
    }

    func testExplicitSealAndFrameNoneInitializeResetAndRemainValid() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let settings = try settingsSnapshot(
            descriptor: descriptor,
            sealID: nil,
            frameID: nil,
            effects: .off
        )
        var catalog = try makeCatalog(descriptor: descriptor, settings: settings)

        XCTAssertEqual(catalog.draft.relicID, descriptor.codex.defaultRelicID)
        XCTAssertNil(catalog.draft.sealID)
        XCTAssertNil(catalog.draft.frameID)
        XCTAssertEqual(catalog.draft.effects, .off)
        let explicitNoneSelection = try catalog.validatedSelection()
        XCTAssertNil(explicitNoneSelection.sealID)
        XCTAssertNil(explicitNoneSelection.frameID)

        let includedSeal = try XCTUnwrap(catalog.seals.first(where: {
            $0.access == .owned
        }))
        try catalog.selectSeal(includedSeal.id)
        catalog.selectEffects(.reduced)
        XCTAssertTrue(catalog.hasChangesFromDefaults)

        catalog.resetToDefaults()
        XCTAssertNil(catalog.draft.sealID)
        XCTAssertNil(catalog.draft.frameID)
        XCTAssertEqual(catalog.draft.effects, .off)
        XCTAssertFalse(catalog.hasChangesFromDefaults)
    }

    func testStaleStoredSealFallsBackWithoutConflatingExplicitNone() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let staleSealID = try XCTUnwrap(
            ArtifactID(rawValue: "seal.gloamthorn.thornmoon")
        )
        let settings = try settingsSnapshot(
            descriptor: descriptor,
            sealID: staleSealID,
            frameID: nil,
            effects: .full
        )
        let catalog = try makeCatalog(descriptor: descriptor, settings: settings)
        let expectedFallback = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))

        XCTAssertEqual(catalog.draft.sealID, expectedFallback.metadata.id)
        XCTAssertNoThrow(try catalog.validatedSelection())
    }

    func testStaleAndMissingFrameFallBackWithoutConflatingExplicitNone() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let fallbackFrame = try XCTUnwrap(descriptor.codex.frames.first)
        let staleFrameID = try XCTUnwrap(
            ArtifactID(rawValue: "frame.gloamthorn.briar-court")
        )
        let owned = Set([fallbackFrame.metadata.id])

        let staleSettings = try settingsSnapshot(
            descriptor: descriptor,
            sealID: nil,
            frameID: staleFrameID,
            effects: .full
        )
        let staleCatalog = try makeCatalog(
            descriptor: descriptor,
            settings: staleSettings,
            ownedArtifactIDs: owned
        )
        XCTAssertEqual(staleCatalog.draft.frameID, fallbackFrame.metadata.id)
        XCTAssertNoThrow(try staleCatalog.validatedSelection())

        let missingSettings = try settingsSnapshot(
            descriptor: descriptor,
            sealID: nil,
            frameID: nil,
            effects: .full,
            includeFramePreference: false
        )
        let missingCatalog = try makeCatalog(
            descriptor: descriptor,
            settings: missingSettings,
            ownedArtifactIDs: owned
        )
        XCTAssertEqual(missingCatalog.draft.frameID, fallbackFrame.metadata.id)
        XCTAssertNoThrow(try missingCatalog.validatedSelection())
    }

    func testLockedAndEncounteredArtifactsRemainVisibleButCannotBeSelected() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let earnedSeals = descriptor.codex.seals.filter {
            $0.metadata.availability == .earned
        }
        let locked = try XCTUnwrap(earnedSeals.first)
        let encountered = try XCTUnwrap(earnedSeals.dropFirst().first)
        var catalog = try makeCatalog(
            descriptor: descriptor,
            encounteredArtifactIDs: [encountered.metadata.id]
        )

        XCTAssertEqual(
            catalog.seals.first(where: { $0.id == locked.metadata.id })?.access,
            .locked
        )
        XCTAssertEqual(
            catalog.seals.first(where: { $0.id == encountered.metadata.id })?.access,
            .encountered
        )
        XCTAssertThrowsError(try catalog.selectSeal(locked.metadata.id)) {
            XCTAssertEqual(
                $0 as? ShareArtifactRenderError,
                .lockedSelection(locked.metadata.id)
            )
        }
        XCTAssertThrowsError(try catalog.selectSeal(encountered.metadata.id)) {
            XCTAssertEqual(
                $0 as? ShareArtifactRenderError,
                .lockedSelection(encountered.metadata.id)
            )
        }
    }

    func testArtifactAccessibilityValuesDistinguishSelectionAndAvailability() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let earnedSeals = descriptor.codex.seals.filter {
            $0.metadata.availability == .earned
        }
        let lockedID = try XCTUnwrap(earnedSeals.first?.metadata.id)
        let encounteredID = try XCTUnwrap(earnedSeals.dropFirst().first?.metadata.id)
        let catalog = try makeCatalog(
            descriptor: descriptor,
            encounteredArtifactIDs: [encounteredID]
        )
        let owned = try XCTUnwrap(catalog.seals.first(where: { $0.access == .owned }))
        let locked = try XCTUnwrap(catalog.seals.first(where: { $0.id == lockedID }))
        let encountered = try XCTUnwrap(catalog.seals.first(where: {
            $0.id == encounteredID
        }))
        let unavailable = ShareBuilderArtifactChoice(
            id: owned.id,
            displayName: owned.displayName,
            detail: owned.detail,
            rarity: owned.rarity,
            access: .unavailable,
            isCompatible: true
        )
        let incompatible = ShareBuilderArtifactChoice(
            id: owned.id,
            displayName: owned.displayName,
            detail: owned.detail,
            rarity: owned.rarity,
            access: .owned,
            isCompatible: false
        )

        XCTAssertEqual(
            owned.accessibilityValue(isSelected: true),
            "Selected, Owned, available"
        )
        XCTAssertEqual(
            locked.accessibilityValue(isSelected: false),
            "Not selected, Locked, unavailable"
        )
        XCTAssertEqual(
            encountered.accessibilityValue(isSelected: false),
            "Not selected, Encountered, locked, unavailable"
        )
        XCTAssertEqual(
            unavailable.accessibilityValue(isSelected: false),
            "Not selected, Unavailable"
        )
        XCTAssertEqual(
            incompatible.accessibilityValue(isSelected: false),
            "Not selected, Owned, incompatible, unavailable"
        )
    }

    func testUnavailableProviderRejectsBuilderCatalog() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let provider = ThemeProviderSummaryDTO(
            codexID: descriptor.codex.id,
            moduleID: RuneScribeModuleIDs.norseTheme,
            displayName: descriptor.codex.displayName.fallbackValue,
            state: .unavailable,
            isOwned: true,
            isSelectable: false,
            isSelected: false
        )
        XCTAssertThrowsError(try ShareBuilderCatalog(
            descriptor: descriptor,
            provider: provider,
            settings: nil,
            ownedArtifactIDs: [],
            encounteredArtifactIDs: []
        )) {
            XCTAssertEqual($0 as? ShareArtifactRenderError, .unavailableSelection)
        }
    }

    func testProviderFailureStateOverridesSelectedIdentity() {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        for state in [
            ThemeProviderState.unavailable,
            .incompatible,
            .invalidResources,
        ] {
            let provider = ThemeProviderSummaryDTO(
                codexID: descriptor.codex.id,
                moduleID: RuneScribeModuleIDs.norseTheme,
                displayName: descriptor.codex.displayName.fallbackValue,
                state: state,
                isOwned: true,
                isSelectable: false,
                isSelected: true
            )
            XCTAssertEqual(
                ShareBuilderProviderPresentationPolicy.state(
                    for: provider,
                    selectedCodexID: descriptor.codex.id
                ),
                .unavailable
            )
        }

        let locked = ThemeProviderSummaryDTO(
            codexID: descriptor.codex.id,
            moduleID: RuneScribeModuleIDs.norseTheme,
            displayName: descriptor.codex.displayName.fallbackValue,
            state: .locked,
            isOwned: true,
            isSelectable: false,
            isSelected: true
        )
        XCTAssertEqual(
            ShareBuilderProviderPresentationPolicy.state(
                for: locked,
                selectedCodexID: descriptor.codex.id
            ),
            .locked
        )
    }

    func testRenderedPreviewBindingRejectsEveryStaleInputAndAlteredBytes() throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let catalog = try makeCatalog(descriptor: descriptor)
        let source = ShareBuilderSource.cipherInvitation(
            cipherID: UUID(uuidString: "e0a70000-0000-0000-0000-000000000001")!,
            displayName: "Bound invitation"
        )
        let previewData = Data("rendered-preview".utf8)
        let presentation = try makePresentation(
            selection: catalog.validatedSelection(),
            safePreviewData: previewData
        )
        let rendered = try RenderedShareBuilderPreview(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false,
            presentation: presentation
        )

        XCTAssertTrue(rendered.matches(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false
        ))
        XCTAssertFalse(rendered.matches(
            source: .cipherInvitation(
                cipherID: source.cipherID,
                displayName: "Changed invitation"
            ),
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false
        ))

        var changedDraft = catalog
        changedDraft.selectEffects(catalog.draft.effects == .off ? .full : .off)
        XCTAssertFalse(rendered.matches(
            source: source,
            catalog: changedDraft,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false
        ))
        XCTAssertFalse(rendered.matches(
            source: source,
            catalog: try makeCatalog(
                descriptor: RuneScribeThemeGloamthornModuleBootstrap
                    .discoveryDescriptor
            ),
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false
        ))
        XCTAssertFalse(rendered.matches(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 42, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false
        ))
        XCTAssertFalse(rendered.matches(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 10),
            colorMode: .standard,
            systemReduceMotion: false
        ))
        XCTAssertFalse(rendered.matches(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .highContrast,
            systemReduceMotion: false
        ))
        XCTAssertFalse(rendered.matches(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: true
        ))

        let altered = try OutboundSharePresentationDTO(
            metadata: presentation.metadata,
            safePreviewData: Data(repeating: 0xff, count: previewData.count)
        )
        XCTAssertThrowsError(try RenderedShareBuilderPreview(
            source: source,
            catalog: catalog,
            themeRevision: revision(coordinator: 41, provider: 9),
            colorMode: .standard,
            systemReduceMotion: false,
            presentation: altered
        )) {
            XCTAssertEqual($0 as? ShareArtifactRenderError, .renderingFailed)
        }
    }

    func testRelicChangeRemovesAnIncompatibleFrame() throws {
        let source = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let defaultRelicID = source.codex.defaultRelicID
        let alternateRelic = try XCTUnwrap(source.codex.relics.first(where: {
            $0.metadata.id != defaultRelicID
                && $0.metadata.availability != .reservedInactive
        }))
        let originalFrame = try XCTUnwrap(source.codex.frames.first)
        let restrictedFrame = try ThemeFrameDescriptor(
            metadata: originalFrame.metadata,
            vectorResourceID: originalFrame.vectorResourceID,
            staticFallbackResourceID: originalFrame.staticFallbackResourceID,
            thumbnailResourceID: originalFrame.thumbnailResourceID,
            compatibleRelicIDs: [defaultRelicID],
            allowsStaticShare: true
        )
        let descriptor = try replacingFrames(in: source, with: [restrictedFrame])
        let owned: Set<ArtifactID> = [
            alternateRelic.metadata.id,
            restrictedFrame.metadata.id,
        ]
        var catalog = try makeCatalog(
            descriptor: descriptor,
            ownedArtifactIDs: owned
        )

        try catalog.selectFrame(restrictedFrame.metadata.id)
        XCTAssertEqual(catalog.draft.frameID, restrictedFrame.metadata.id)
        try catalog.selectRelic(alternateRelic.metadata.id)
        XCTAssertEqual(catalog.draft.relicID, alternateRelic.metadata.id)
        XCTAssertNil(catalog.draft.frameID)
    }

    func testEffectsPreferenceHonorsSystemReduceMotionWithoutChangingStoredDraft() throws {
        var catalog = try makeCatalog(
            descriptor: RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        )
        catalog.selectEffects(.full)

        XCTAssertEqual(catalog.draft.effects, .full)
        XCTAssertEqual(catalog.draft.effects.effective(systemReduceMotion: false), .full)
        XCTAssertEqual(catalog.draft.effects.effective(systemReduceMotion: true), .reduced)
        XCTAssertEqual(RuntimeEffectsPreference.off.effective(systemReduceMotion: true), .off)
        XCTAssertEqual(catalog.draft.effects, .full)
    }

    func testPerCodexDefaultsResolveIndependentlyAndUnavailableReplacementRetainsDraft() throws {
        let norse = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let gloamthorn = RuneScribeThemeGloamthornModuleBootstrap.discoveryDescriptor
        let norseSeal = try XCTUnwrap(norse.codex.seals.first(where: {
            $0.metadata.availability == .included
        }))
        let gloamthornSeal = try XCTUnwrap(gloamthorn.codex.seals.last(where: {
            $0.metadata.availability == .included
        }))
        let settings = try multiCodexSettingsSnapshot(
            selections: [
                (
                    descriptor: norse,
                    relicID: norse.codex.defaultRelicID,
                    sealID: norseSeal.metadata.id,
                    frameID: nil
                ),
                (
                    descriptor: gloamthorn,
                    relicID: gloamthorn.codex.defaultRelicID,
                    sealID: gloamthornSeal.metadata.id,
                    frameID: nil
                ),
            ],
            effects: .reduced
        )

        let norseCatalog = try makeCatalog(descriptor: norse, settings: settings)
        let gloamthornCatalog = try makeCatalog(
            descriptor: gloamthorn,
            settings: settings
        )
        XCTAssertEqual(norseCatalog.draft.codexID, norse.codex.id)
        XCTAssertEqual(norseCatalog.draft.sealID, norseSeal.metadata.id)
        XCTAssertNil(norseCatalog.draft.frameID)
        XCTAssertEqual(gloamthornCatalog.draft.codexID, gloamthorn.codex.id)
        XCTAssertEqual(gloamthornCatalog.draft.sealID, gloamthornSeal.metadata.id)
        XCTAssertNil(gloamthornCatalog.draft.frameID)
        XCTAssertEqual(gloamthornCatalog.draft.effects, .reduced)

        var retainedCatalog = norseCatalog
        let unavailable = ThemeProviderSummaryDTO(
            codexID: gloamthorn.codex.id,
            moduleID: RuneScribeThemeGloamthornModuleBootstrap.moduleID,
            displayName: gloamthorn.codex.displayName.fallbackValue,
            state: .invalidResources,
            isOwned: true,
            isSelectable: false,
            isSelected: false
        )
        XCTAssertThrowsError(try ShareBuilderCatalog(
            descriptor: gloamthorn,
            provider: unavailable,
            settings: settings,
            ownedArtifactIDs: [],
            encounteredArtifactIDs: []
        )) {
            XCTAssertEqual($0 as? ShareArtifactRenderError, .unavailableSelection)
        }
        XCTAssertEqual(retainedCatalog, norseCatalog)
        retainedCatalog.resetToDefaults()
        XCTAssertEqual(retainedCatalog, norseCatalog)
    }

    func testDefaultsPersistenceMarksOnlySuccessfulDraftAndRetainsFailedDraft() async throws {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        let alternateSeal = try XCTUnwrap(descriptor.codex.seals.first(where: {
            $0.metadata.availability == .included
                && $0.metadata.id != descriptor.codex.seals.first?.metadata.id
        }))
        var successful = try makeCatalog(descriptor: descriptor)
        try successful.selectSeal(alternateSeal.metadata.id)
        let successfulDraft = successful.draft
        var persistedDraft: ShareBuilderDraft?

        try await successful.persistCurrentDraft { candidate in
            persistedDraft = candidate.draft
        }

        XCTAssertEqual(persistedDraft, successfulDraft)
        XCTAssertFalse(successful.hasChangesFromDefaults)
        XCTAssertEqual(successful.draft, successfulDraft)

        var failing = try makeCatalog(descriptor: descriptor)
        try failing.selectSeal(alternateSeal.metadata.id)
        let failedDraft = failing.draft
        do {
            try await failing.persistCurrentDraft { _ in
                throw DefaultsPersistenceFailure.injected
            }
            XCTFail("Injected persistence failure must propagate")
        } catch DefaultsPersistenceFailure.injected {
            // Expected. The builder keeps the valid draft available for retry.
        }
        XCTAssertEqual(failing.draft, failedDraft)
        XCTAssertTrue(failing.hasChangesFromDefaults)
    }

    func testRapidPreviewGenerationsRejectEveryStaleCompletionAndInvalidation() async {
        var gate = ShareBuilderPreviewGenerationGate()
        let first = gate.begin()
        let second = gate.begin()

        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second))

        for _ in 0 ..< 1_000 {
            _ = gate.begin()
        }
        XCTAssertFalse(gate.accepts(second))
        let latest = gate.current
        XCTAssertTrue(gate.accepts(latest))

        gate.invalidate()
        XCTAssertFalse(gate.accepts(latest))

        var previewTask: Task<Void, Never>?
        let cancellationCapture = PreviewCancellationCapture()
        let cancellablePreview = Task<Void, Never> {
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                await cancellationCapture.record()
            } catch {
                return
            }
        }
        replaceShareBuilderPreviewTask(&previewTask) { cancellablePreview }
        await Task.yield()
        replaceShareBuilderPreviewTask(&previewTask) { Task {} }
        await cancellablePreview.value
        let cancellationObserved = await cancellationCapture.wasRecorded
        XCTAssertTrue(cancellationObserved)
        previewTask?.cancel()
    }

    func testSharePreparationGenerationRejectsAccessibilityInvalidation() {
        var gate = ShareBuilderPreparationGenerationGate()
        let inFlight = gate.begin()
        XCTAssertTrue(gate.accepts(inFlight))

        gate.invalidate()

        XCTAssertFalse(gate.accepts(inFlight))
        let replacement = gate.begin()
        XCTAssertTrue(gate.accepts(replacement))
        XCTAssertFalse(gate.accepts(inFlight))
    }

    func testInitialAndSuspendedSelectionCatalogLoadsRejectSupersededThemeAuthority() async throws {
        var generation = ShareBuilderCatalogLoadGenerationGate()
        let initialLoad = generation.begin(themeRevision: 41)
        let suspendedSelection = generation.begin(themeRevision: 41)
        XCTAssertFalse(generation.accepts(
            initialLoad,
            currentThemeRevision: 41
        ))
        XCTAssertTrue(generation.accepts(
            suspendedSelection,
            currentThemeRevision: 41
        ))
        let suspension = CatalogLoadSuspensionGate()
        let load = Task { @MainActor in
            await suspension.suspendUntilReleased()
            return suspendedSelection
        }
        await suspension.waitUntilSuspended()

        generation.invalidate()
        let replacement = generation.begin(themeRevision: 42)
        await suspension.release()
        let returnedSelection = await load.value

        XCTAssertFalse(generation.accepts(
            returnedSelection,
            currentThemeRevision: 42
        ))
        XCTAssertTrue(generation.accepts(
            replacement,
            currentThemeRevision: 42
        ))
        XCTAssertFalse(generation.accepts(
            replacement,
            currentThemeRevision: 43
        ))
    }

    func testTerminalGenerationPreventsOverlappingShareCompletion() throws {
        var gate = ShareBuilderTerminalGenerationGate()
        let first = try XCTUnwrap(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertTrue(gate.accepts(first))
        XCTAssertNil(gate.begin())

        XCTAssertTrue(gate.complete(first))
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.accepts(first))

        let second = try XCTUnwrap(gate.begin())
        gate.invalidate()
        XCTAssertFalse(gate.isActive)
        XCTAssertFalse(gate.complete(second))
    }

    func testPreparedPresentationAuthorityRejectsEveryVisibleOutputChange() {
        let captured = ShareBuilderThemeAuthorityRevision(
            coordinatorRevision: 8,
            providerContentRevision: 13
        )
        XCTAssertTrue(ShareBuilderPreparedPresentationPolicy.isAuthorized(
            capturedThemeRevision: captured,
            capturedColorMode: .standard,
            capturedSystemReduceMotion: false,
            currentThemeRevision: captured,
            currentColorMode: .standard,
            currentSystemReduceMotion: false
        ))

        let changedTheme = ShareBuilderThemeAuthorityRevision(
            coordinatorRevision: 9,
            providerContentRevision: 13
        )
        XCTAssertFalse(ShareBuilderPreparedPresentationPolicy.isAuthorized(
            capturedThemeRevision: captured,
            capturedColorMode: .standard,
            capturedSystemReduceMotion: false,
            currentThemeRevision: changedTheme,
            currentColorMode: .standard,
            currentSystemReduceMotion: false
        ))
        XCTAssertFalse(ShareBuilderPreparedPresentationPolicy.isAuthorized(
            capturedThemeRevision: captured,
            capturedColorMode: .standard,
            capturedSystemReduceMotion: false,
            currentThemeRevision: captured,
            currentColorMode: .highContrast,
            currentSystemReduceMotion: false
        ))
        XCTAssertFalse(ShareBuilderPreparedPresentationPolicy.isAuthorized(
            capturedThemeRevision: captured,
            capturedColorMode: .standard,
            capturedSystemReduceMotion: false,
            currentThemeRevision: captured,
            currentColorMode: .standard,
            currentSystemReduceMotion: true
        ))
        XCTAssertFalse(ShareBuilderPreparedPresentationPolicy.isAuthorized(
            capturedThemeRevision: captured,
            capturedColorMode: .standard,
            capturedSystemReduceMotion: false,
            currentThemeRevision: nil,
            currentColorMode: .standard,
            currentSystemReduceMotion: false
        ))
    }

    private func makeCatalog(
        descriptor: ThemeDescriptor,
        settings: RuntimeSettingsSnapshotDTO? = nil,
        ownedArtifactIDs: Set<ArtifactID> = [],
        encounteredArtifactIDs: Set<ArtifactID> = []
    ) throws -> ShareBuilderCatalog {
        try ShareBuilderCatalog(
            descriptor: descriptor,
            provider: availableProvider(for: descriptor),
            settings: settings,
            ownedArtifactIDs: ownedArtifactIDs,
            encounteredArtifactIDs: encounteredArtifactIDs
        )
    }

    private func makePresentation(
        selection: SharePresentationSelection,
        safePreviewData: Data
    ) throws -> OutboundSharePresentationDTO {
        let digest = SHA256.hash(data: safePreviewData).map {
            String(format: "%02x", $0)
        }.joined()
        let safePreview = try ShareSafePreviewMetadata(
            mediaType: .png,
            byteLength: UInt32(safePreviewData.count),
            pixelSize: ThemePixelSize(width: 4, height: 3),
            sha256: ThemeSHA256Digest(rawValue: digest)!
        )
        let metadata = try SharePresentationMetadata(
            selection: selection,
            safePreview: safePreview,
            compatibility: SharePresentationCompatibilityFlags.safePreviewPresent
                .union(.norseInteractiveFallback)
        )
        return try OutboundSharePresentationDTO(
            metadata: metadata,
            safePreviewData: safePreviewData
        )
    }

    private func revision(
        coordinator: UInt64,
        provider: UInt64
    ) -> ShareBuilderThemeAuthorityRevision {
        ShareBuilderThemeAuthorityRevision(
            coordinatorRevision: coordinator,
            providerContentRevision: provider
        )
    }

    private func availableProvider(
        for descriptor: ThemeDescriptor
    ) -> ThemeProviderSummaryDTO {
        ThemeProviderSummaryDTO(
            codexID: descriptor.codex.id,
            moduleID: descriptor.codex.id == RuneScribeCodexIDs.norse
                ? RuneScribeModuleIDs.norseTheme
                : RuneScribeThemeGloamthornModuleBootstrap.moduleID,
            displayName: descriptor.codex.displayName.fallbackValue,
            state: .available,
            isOwned: true,
            isSelectable: true,
            isSelected: true
        )
    }

    private func multiCodexSettingsSnapshot(
        selections: [(
            descriptor: ThemeDescriptor,
            relicID: ArtifactID,
            sealID: ArtifactID?,
            frameID: ArtifactID?
        )],
        effects: RuntimeEffectsPreference
    ) throws -> RuntimeSettingsSnapshotDTO {
        var relics = RuneScribeRuntimeSettings.defaultArtifactSelections(for: .relic)
        var seals = RuneScribeRuntimeSettings.defaultArtifactSelections(for: .seal)
        var frames = RuneScribeRuntimeSettings.defaultArtifactSelections(for: .frame)
        for selection in selections {
            relics = try relics.setting(
                selection.relicID,
                for: selection.descriptor.codex.id
            )
            seals = try seals.setting(
                selection.sealID,
                for: selection.descriptor.codex.id
            )
            frames = try frames.setting(
                selection.frameID,
                for: selection.descriptor.codex.id
            )
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return try RuntimeSettingsSnapshotDTO(
            revision: 1,
            capturedAt: now,
            settings: [
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.selectedRelicByCodex,
                    value: .text(try RuntimeArtifactSelectionCodec.encode(relics)),
                    revision: 1,
                    updatedAt: now
                ),
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.selectedSealByCodex,
                    value: .text(try RuntimeArtifactSelectionCodec.encode(seals)),
                    revision: 1,
                    updatedAt: now
                ),
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.selectedFrameByCodex,
                    value: .text(try RuntimeArtifactSelectionCodec.encode(frames)),
                    revision: 1,
                    updatedAt: now
                ),
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.effectsPreference,
                    value: effects.settingValue,
                    revision: 1,
                    updatedAt: now
                ),
            ]
        )
    }

    private func settingsSnapshot(
        descriptor: ThemeDescriptor,
        sealID: ArtifactID?,
        frameID: ArtifactID?,
        effects: RuntimeEffectsPreference,
        includeFramePreference: Bool = true
    ) throws -> RuntimeSettingsSnapshotDTO {
        let codexID = descriptor.codex.id
        let relics = try RuneScribeRuntimeSettings
            .defaultArtifactSelections(for: .relic)
            .setting(descriptor.codex.defaultRelicID, for: codexID)
        let seals = try RuneScribeRuntimeSettings
            .defaultArtifactSelections(for: .seal)
            .setting(sealID, for: codexID)
        let frames = if includeFramePreference {
            try RuneScribeRuntimeSettings
                .defaultArtifactSelections(for: .frame)
                .setting(frameID, for: codexID)
        } else {
            try RuntimeCodexArtifactSelectionMap(kind: .frame)
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return try RuntimeSettingsSnapshotDTO(
            revision: 1,
            capturedAt: now,
            settings: [
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.selectedRelicByCodex,
                    value: .text(try RuntimeArtifactSelectionCodec.encode(relics)),
                    revision: 1,
                    updatedAt: now
                ),
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.selectedSealByCodex,
                    value: .text(try RuntimeArtifactSelectionCodec.encode(seals)),
                    revision: 1,
                    updatedAt: now
                ),
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.selectedFrameByCodex,
                    value: .text(try RuntimeArtifactSelectionCodec.encode(frames)),
                    revision: 1,
                    updatedAt: now
                ),
                RuntimeSettingDTO(
                    settingID: RuneScribeRuntimeSettings.effectsPreference,
                    value: effects.settingValue,
                    revision: 1,
                    updatedAt: now
                ),
            ]
        )
    }

    private func replacingFrames(
        in descriptor: ThemeDescriptor,
        with frames: [ThemeFrameDescriptor]
    ) throws -> ThemeDescriptor {
        let codex = descriptor.codex
        let replacementCodex = try ThemeCodexDescriptor(
            id: codex.id,
            entitlementID: codex.entitlementID,
            displayName: codex.displayName,
            shortDescription: codex.shortDescription,
            longDescription: codex.longDescription,
            accessibility: codex.accessibility,
            palette: codex.palette,
            primaryScriptID: codex.primaryScriptID,
            fallbackScriptID: codex.fallbackScriptID,
            defaultRelicID: codex.defaultRelicID,
            scripts: codex.scripts,
            relics: codex.relics,
            seals: codex.seals,
            frames: frames,
            crests: codex.crests,
            background: codex.background,
            vault: codex.vault,
            rightsID: codex.rightsID
        )
        return try ThemeDescriptor(
            id: descriptor.id,
            moduleID: descriptor.moduleID,
            moduleRole: descriptor.moduleRole,
            policyClass: descriptor.policyClass,
            criticality: descriptor.criticality,
            schemaVersion: descriptor.schemaVersion,
            contentVersion: descriptor.contentVersion,
            minimumUIContractVersion: descriptor.minimumUIContractVersion,
            platformCompatibility: descriptor.platformCompatibility,
            fallbackCodexID: descriptor.fallbackCodexID,
            codex: replacementCodex,
            resources: descriptor.resources,
            localizations: descriptor.localizations,
            defaultLocaleIdentifier: descriptor.defaultLocaleIdentifier,
            rights: descriptor.rights
        )
    }
}

private actor PreviewCancellationCapture {
    private(set) var wasRecorded = false

    func record() {
        wasRecorded = true
    }
}

private actor CatalogLoadSuspensionGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private enum DefaultsPersistenceFailure: Error {
    case injected
}
