import RuneScribeContracts

enum ReceivedPresentationAvailabilityBinding {
    static func downgrade(
        _ presentation: ReceivedSharePresentation,
        to availability: ShareProviderAvailability
    ) -> ReceivedSharePresentation {
        guard availability != .available else { return presentation }
        return (try? ReceivedSharePresentation(
            requestedSelection: presentation.requestedSelection,
            effectiveCodexID: RuneScribeCodexIDs.norse,
            providerAvailability: availability,
            renderMode: .norseInteractiveFallback,
            safePreviewStatus: presentation.safePreviewStatus,
            provenanceStatus: presentation.provenanceStatus,
            encounterRecordingStatus: presentation.encounterRecordingStatus,
            resourceMetadata: presentation.resourceMetadata
        )) ?? presentation
    }

    static func resolve(
        _ presentation: ReceivedSharePresentation,
        against snapshot: ThemeCoordinatorSnapshotDTO?
    ) -> ReceivedSharePresentation {
        let availability = providerAvailability(
            for: presentation.requestedSelection,
            resources: presentation.resourceMetadata,
            in: snapshot
        )
        let usesRequestedCodex = availability == .available
        return (try? ReceivedSharePresentation(
            requestedSelection: presentation.requestedSelection,
            effectiveCodexID: usesRequestedCodex
                ? presentation.requestedSelection.codexID
                : RuneScribeCodexIDs.norse,
            providerAvailability: availability,
            renderMode: usesRequestedCodex
                ? .requestedCodex
                : .norseInteractiveFallback,
            safePreviewStatus: presentation.safePreviewStatus,
            provenanceStatus: presentation.provenanceStatus,
            encounterRecordingStatus: presentation.encounterRecordingStatus,
            resourceMetadata: presentation.resourceMetadata
        )) ?? presentation
    }

    static func providerAvailability(
        for selection: SharePresentationSelection,
        resources: [SharePresentationResourceMetadata] = [],
        in snapshot: ThemeCoordinatorSnapshotDTO?
    ) -> ShareProviderAvailability {
        let provider = snapshot?.providers.first(where: {
            $0.codexID == selection.codexID
        })

        let lifecycleAvailability: ShareProviderAvailability = switch provider?.state {
        case .available?: .available
        case .locked?: .locked
        case .unavailable?: .unavailable
        case .incompatible?: .incompatible
        case .invalidResources?: .corrupt
        case nil: .unknown
        }
        return SharePresentationProviderCompatibilityResolver.resolve(
            selection: selection,
            resources: resources,
            providerAvailability: lifecycleAvailability,
            inventories: snapshot?.presentationInventories ?? []
        )
    }
}
