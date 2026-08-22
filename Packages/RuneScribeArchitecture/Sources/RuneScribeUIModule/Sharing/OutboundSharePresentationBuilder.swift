import CryptoKit
import Foundation
import RuneScribeContracts

@MainActor
extension RuneScribeUISession {
    func makeOutboundSharePresentationWithLegacyFallback(
        inscription: String,
        accessibilityLabel: String
    ) async -> OutboundSharePresentationPreparation {
        do {
            let presentation = try await makeOutboundSharePresentation(
                inscription: inscription,
                accessibilityLabel: accessibilityLabel
            )
            return OutboundSharePresentationPreparation(
                presentation: presentation,
                status: .themed
            )
        } catch {
            return OutboundSharePresentationPreparation(
                presentation: nil,
                status: .legacyFallback(
                    Self.outboundSharePresentationFallbackReason(for: error)
                )
            )
        }
    }

    func makeOutboundSharePresentation(
        inscription: String,
        accessibilityLabel: String
    ) async throws -> OutboundSharePresentationDTO {
        guard let snapshot = themeSnapshot,
              !snapshot.isEmergencyPresentation,
              let runtimeIOHandle,
              let themeCoordinatorClientHandle,
              let provider = snapshot.providers.first(where: {
                  $0.codexID == snapshot.effectiveCodexID
              })
        else { throw ShareArtifactRenderError.unavailableSelection }

        let descriptor = snapshot.effectiveTheme
        let selection = try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: provider.isOwned,
            providerAvailable: provider.state == .available,
            ownedArtifactIDs: ownedThemeArtifactIDs,
            relicID: selectedThemeRelicID,
            sealID: selectedThemeSealID,
            frameID: selectedThemeFrameID
        )
        let operationUUID = try await runtimeIOHandle.nextUUID()
        let capturedAt = try await runtimeIOHandle.now()
        let request = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: inscription,
            operationID: RuntimeOperationID(
                rawValue: "share.render.\(operationUUID.uuidString.lowercased())"
            ),
            capturedAt: capturedAt,
            localeIdentifier: descriptor.defaultLocaleIdentifier,
            scale: 1,
            accessibilityLabel: accessibilityLabel,
            provenanceLabel: "Source details included"
        )
        let plan = try ShareArtifactRenderPolicy.plan(
            request: request,
            descriptor: descriptor
        )
        var resourceData: [ThemeResourceID: Data] = [:]
        for resource in plan.resourceMetadata {
            do {
                let resolved = try await themeCoordinatorClientHandle.resolveResource(
                    ResolveThemeResourceRequestDTO(
                        codexID: descriptor.codex.id,
                        resourceID: resource.resourceID
                    )
                )
                resourceData[resource.resourceID] = resolved.data
            } catch {
                throw Self.outboundShareResourceResolutionError(
                    for: resource.resourceID,
                    underlying: error
                )
            }
        }
        let output = try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: resourceData
        )
        let provenance = try outboundProvenance(
            descriptor: descriptor,
            selection: selection
        )
        let metadata = try output.presentationMetadata(
            for: plan,
            provenance: provenance
        )
        guard let safePreviewData = output.pagePNGData.first else {
            throw ShareArtifactRenderError.renderingFailed
        }
        return try OutboundSharePresentationDTO(
            metadata: metadata,
            safePreviewData: safePreviewData,
            signedProvenance: nil
        )
    }

    private func outboundProvenance(
        descriptor: ThemeDescriptor,
        selection: SharePresentationSelection
    ) throws -> ShareProvenanceReference? {
        let referencedRightsIDs = Set(
            descriptor.codex.relics.filter {
                $0.metadata.id == selection.relicID
            }.map(\.metadata.rightsID)
                + descriptor.codex.seals.filter {
                    $0.metadata.id == selection.sealID
                }.map(\.metadata.rightsID)
                + descriptor.codex.frames.filter {
                    $0.metadata.id == selection.frameID
                }.map(\.metadata.rightsID)
        )
        guard let rights = descriptor.rights.first(where: {
            referencedRightsIDs.contains($0.id)
        }) ?? descriptor.rights.first else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let statement = try encoder.encode(rights)
        let digestValue = SHA256.hash(data: statement).map {
            String(format: "%02x", $0)
        }.joined()
        guard let digest = ThemeSHA256Digest(rawValue: digestValue) else {
            throw SharePresentationContractError.invalidProvenance
        }
        return try ShareProvenanceReference(
            referenceID: rights.id,
            statementSHA256: digest,
            status: .unverified
        )
    }

    static func outboundShareResourceResolutionError(
        for resourceID: ThemeResourceID,
        underlying _: Error
    ) -> ShareArtifactRenderError {
        .missingResource(resourceID)
    }

    static func outboundSharePresentationFallbackReason(
        for error: Error
    ) -> OutboundSharePresentationFallbackReason {
        if error is SharePresentationContractError {
            return .invalidPresentation
        }
        guard let renderError = error as? ShareArtifactRenderError else {
            return .themeUnavailable
        }
        switch renderError {
        case .unavailableSelection:
            return .themeUnavailable
        case .unknownSelection, .lockedSelection, .incompatibleFrame,
             .unavailableSealAnchor:
            return .selectionUnavailable
        case .missingResource, .invalidResource:
            return .resourceUnavailable
        case .invalidRequest, .inscriptionTooLong, .renderingFailed,
             .outputTooLarge:
            return .renderingUnavailable
        }
    }
}
