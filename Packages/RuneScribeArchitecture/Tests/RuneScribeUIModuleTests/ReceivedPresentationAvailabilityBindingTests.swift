import Foundation
import RuneScribeContracts
import RuneScribeNorseThemeModule
@testable import RuneScribeUIModule
import XCTest

@MainActor
final class ReceivedPresentationAvailabilityBindingTests: XCTestCase {
    func testLiveProviderStatesResolveRequestedCodexOrNorseFallback() throws {
        let cases: [(ThemeProviderState, ShareProviderAvailability)] = [
            (.available, .available),
            (.locked, .locked),
            (.unavailable, .unavailable),
            (.incompatible, .incompatible),
            (.invalidResources, .corrupt),
        ]

        for (providerState, expectedAvailability) in cases {
            let retained = try presentation(
                availability: .unknown,
                safePreviewStatus: .valid,
                provenanceStatus: .verified
            )
            let resolved = ReceivedPresentationAvailabilityBinding.resolve(
                retained,
                against: try snapshot(providerState: providerState)
            )

            XCTAssertEqual(resolved.providerAvailability, expectedAvailability)
            XCTAssertEqual(resolved.safePreviewStatus, .valid)
            XCTAssertEqual(resolved.provenanceStatus, .verified)
            XCTAssertEqual(resolved.encounterRecordingStatus, .recorded)
            if expectedAvailability == .available {
                XCTAssertEqual(resolved.renderMode, .requestedCodex)
                XCTAssertEqual(resolved.effectiveCodexID, receivedCodexID)
            } else {
                XCTAssertEqual(resolved.renderMode, .norseInteractiveFallback)
                XCTAssertEqual(resolved.effectiveCodexID, RuneScribeCodexIDs.norse)
            }
        }
    }

    func testMissingSnapshotOrProviderResolvesUnknownWithoutLosingObservation() throws {
        let retained = try presentation(
            availability: .available,
            safePreviewStatus: .invalid,
            provenanceStatus: .unverified
        )

        for snapshot in [nil, try self.snapshot(providerState: nil)] {
            let resolved = ReceivedPresentationAvailabilityBinding.resolve(
                retained,
                against: snapshot
            )
            XCTAssertEqual(resolved.requestedSelection, retained.requestedSelection)
            XCTAssertEqual(resolved.providerAvailability, .unknown)
            XCTAssertEqual(resolved.renderMode, .norseInteractiveFallback)
            XCTAssertEqual(resolved.effectiveCodexID, RuneScribeCodexIDs.norse)
            XCTAssertEqual(resolved.safePreviewStatus, .invalid)
            XCTAssertEqual(resolved.provenanceStatus, .unverified)
        }
    }

    func testUnsupportedPresentationVersionRemainsIncompatibleWithAvailableProvider() throws {
        let retained = try presentation(
            presentationVersion: 2,
            availability: .unknown,
            safePreviewStatus: .absent,
            provenanceStatus: .unavailable
        )

        let resolved = ReceivedPresentationAvailabilityBinding.resolve(
            retained,
            against: try snapshot(providerState: .available)
        )

        XCTAssertEqual(resolved.providerAvailability, .incompatible)
        XCTAssertEqual(resolved.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(resolved.effectiveCodexID, RuneScribeCodexIDs.norse)
    }

    func testAvailableProviderFallsBackForCrossCodexSelectionAndHashDrift() throws {
        let crossCodexSelection = try SharePresentationSelection(
            codexID: receivedCodexID,
            scriptID: ScriptID(rawValue: "script.sunspire")!,
            relicID: ArtifactID(rawValue: "relic.received-test.tablet")!
        )
        let crossCodex = try ReceivedSharePresentation(
            requestedSelection: crossCodexSelection,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: .unknown,
            renderMode: .norseInteractiveFallback,
            safePreviewStatus: .valid,
            provenanceStatus: .unverified
        )
        let availableSnapshot = try snapshot(providerState: .available)
        let incompatible = ReceivedPresentationAvailabilityBinding.resolve(
            crossCodex,
            against: availableSnapshot
        )
        XCTAssertEqual(incompatible.providerAvailability, .incompatible)
        XCTAssertEqual(incompatible.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(incompatible.effectiveCodexID, RuneScribeCodexIDs.norse)

        let expectedResource = try presentationResource(digestCharacter: "a")
        let mismatchedResource = try presentationResource(digestCharacter: "b")
        let retained = try presentation(
            availability: .unknown,
            safePreviewStatus: .valid,
            provenanceStatus: .unverified,
            resourceMetadata: [mismatchedResource]
        )
        let corrupt = ReceivedPresentationAvailabilityBinding.resolve(
            retained,
            against: try snapshot(
                providerState: .available,
                receivedInventory: receivedInventory(resources: [expectedResource])
            )
        )
        XCTAssertEqual(corrupt.providerAvailability, .corrupt)
        XCTAssertEqual(corrupt.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(corrupt.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(corrupt.resourceMetadata, [mismatchedResource])
    }

    func testPendingMessageProductionBindingPreservesSafePreviewBytes() throws {
        let safePreview = Data([0x89, 0x50, 0x4e, 0x47])
        let retained = try presentation(
            availability: .available,
            safePreviewStatus: .valid,
            provenanceStatus: .invalid
        )
        let received = try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            plaintext: "Readable message",
            senderName: "Sender",
            cipherID: CipherID(rawValue: UUID()),
            cipherName: "Cipher",
            presentation: retained,
            safePreviewData: safePreview
        )

        let pending = PendingMessageViewState(
            received,
            themeSnapshot: try snapshot(providerState: .locked)
        )

        XCTAssertEqual(pending.presentation?.providerAvailability, .locked)
        XCTAssertEqual(pending.presentation?.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(pending.presentation?.provenanceStatus, .invalid)
        XCTAssertEqual(pending.safePreviewData, safePreview)
        XCTAssertEqual(pending.plaintext, received.plaintext)
    }

    func testEncounterSummaryDistinguishesRecordedFromUnavailable() throws {
        let recorded = ReceivedPresentationViewModel(try presentation(
            availability: .unknown,
            safePreviewStatus: .absent,
            provenanceStatus: .unavailable,
            encounterRecordingStatus: .recorded
        ))
        let unavailable = ReceivedPresentationViewModel(try presentation(
            availability: .unknown,
            safePreviewStatus: .absent,
            provenanceStatus: .unavailable,
            encounterRecordingStatus: .unavailable
        ))

        XCTAssertTrue(recorded.encounterDetail.contains("recorded"))
        XCTAssertTrue(unavailable.encounterDetail.contains("could not be recorded"))
        XCTAssertNotEqual(recorded.encounterDetail, unavailable.encounterDetail)
    }

    private let receivedCodexID = CodexID(rawValue: "codex.received-test")!
    private let receivedModuleID = ModuleIdentifier(
        rawValue: "com.runescribe.module.theme.received-test"
    )

    private func presentation(
        presentationVersion: UInt16 = 1,
        availability: ShareProviderAvailability,
        safePreviewStatus: ShareSafePreviewStatus,
        provenanceStatus: ShareProvenanceVerificationStatus,
        encounterRecordingStatus: ShareEncounterRecordingStatus = .recorded,
        resourceMetadata: [SharePresentationResourceMetadata] = []
    ) throws -> ReceivedSharePresentation {
        let selection = try SharePresentationSelection(
            codexID: receivedCodexID,
            scriptID: ScriptID(rawValue: "script.received-test")!,
            relicID: ArtifactID(rawValue: "relic.received-test.tablet")!,
            presentationVersion: presentationVersion
        )
        return try ReceivedSharePresentation(
            requestedSelection: selection,
            effectiveCodexID: availability == .available
                ? receivedCodexID
                : RuneScribeCodexIDs.norse,
            providerAvailability: availability,
            renderMode: availability == .available
                ? .requestedCodex
                : .norseInteractiveFallback,
            safePreviewStatus: safePreviewStatus,
            provenanceStatus: provenanceStatus,
            encounterRecordingStatus: encounterRecordingStatus,
            resourceMetadata: resourceMetadata
        )
    }

    private func snapshot(
        providerState: ThemeProviderState?,
        receivedInventory: SharePresentationProviderInventory? = nil
    ) throws -> ThemeCoordinatorSnapshotDTO {
        let descriptor = RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        var providers = [
            ThemeProviderSummaryDTO(
                codexID: RuneScribeCodexIDs.norse,
                moduleID: RuneScribeModuleIDs.norseTheme,
                displayName: "Norse",
                state: .available,
                isOwned: true,
                isSelectable: true,
                isSelected: true
            ),
        ]
        if let providerState {
            providers.append(
                ThemeProviderSummaryDTO(
                    codexID: receivedCodexID,
                    moduleID: receivedModuleID,
                    displayName: "Received Test",
                    state: providerState,
                    isOwned: providerState != .locked,
                    isSelectable: providerState == .available,
                    isSelected: false
                )
            )
        }
        var inventories = [
            try SharePresentationProviderInventory(descriptor: descriptor),
        ]
        if providerState != nil {
            inventories.append(try receivedInventory ?? self.receivedInventory())
        }
        return try ThemeCoordinatorSnapshotDTO(
            revision: 7,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            preferredCodexID: RuneScribeCodexIDs.norse,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            fallbackReason: .none,
            effectiveTheme: descriptor,
            providers: providers,
            presentationInventories: inventories
        )
    }

    private func receivedInventory(
        resources: [SharePresentationResourceMetadata] = []
    ) throws -> SharePresentationProviderInventory {
        try SharePresentationProviderInventory(
            codexID: receivedCodexID,
            scriptIDs: [ScriptID(rawValue: "script.received-test")!],
            relicIDs: [ArtifactID(rawValue: "relic.received-test.tablet")!],
            sealIDs: [],
            frameIDs: [],
            resources: try resources.map(
                SharePresentationProviderResourceInventory.init(metadata:)
            )
        )
    }

    private func presentationResource(
        digestCharacter: Character
    ) throws -> SharePresentationResourceMetadata {
        try SharePresentationResourceMetadata(
            resourceID: ThemeResourceID(rawValue: "resource.received-test.background")!,
            role: ThemeResourceRoles.backgroundStaticBase,
            mediaType: .pdf,
            byteLength: 512,
            sha256: ThemeSHA256Digest(
                rawValue: String(repeating: digestCharacter, count: 64)
            )!
        )
    }
}
