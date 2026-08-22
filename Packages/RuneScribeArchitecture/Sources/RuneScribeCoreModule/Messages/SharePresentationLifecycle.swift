import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts

enum SharePresentationResolver {
    static func resolve(
        metadata: SharePresentationMetadata,
        providerAvailability: ShareProviderAvailability,
        safePreviewStatus: ShareSafePreviewStatus,
        provenanceStatus: ShareProvenanceVerificationStatus,
        encounterRecordingStatus: ShareEncounterRecordingStatus = .unavailable,
        providerInventories: [SharePresentationProviderInventory] = []
    ) throws -> ReceivedSharePresentation {
        let effectiveAvailability = SharePresentationProviderCompatibilityResolver.resolve(
            metadata: metadata,
            providerAvailability: providerAvailability,
            inventories: providerInventories
        )
        if effectiveAvailability == .available {
            return try ReceivedSharePresentation(
                requestedSelection: metadata.selection,
                effectiveCodexID: metadata.selection.codexID,
                providerAvailability: effectiveAvailability,
                renderMode: .requestedCodex,
                safePreviewStatus: safePreviewStatus,
                provenanceStatus: provenanceStatus,
                encounterRecordingStatus: encounterRecordingStatus,
                resourceMetadata: metadata.resources
            )
        }
        return try ReceivedSharePresentation(
            requestedSelection: metadata.selection,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: effectiveAvailability,
            renderMode: .norseInteractiveFallback,
            safePreviewStatus: safePreviewStatus,
            provenanceStatus: provenanceStatus,
            encounterRecordingStatus: encounterRecordingStatus,
            resourceMetadata: metadata.resources
        )
    }
}

struct SharePresentationProgressionProjection: Equatable, Sendable {
    let codexIDs: [CodexID]
    let artifactIDs: [ArtifactID]
    let provenanceStatus: DomainEventProvenanceStatus?

    static func inbound(_ intake: SharePresentationIntake) -> Self {
        guard let metadata = intake.metadata else {
            return Self(
                codexIDs: [CoreProgressionFactFactory.implicitNorseCodexID],
                artifactIDs: [],
                provenanceStatus: nil
            )
        }
        return Self(
            codexIDs: [metadata.selection.codexID],
            artifactIDs: metadata.selection.artifactIDs,
            provenanceStatus: intake.provenanceStatus.domainEventStatus
        )
    }
}
