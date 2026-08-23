import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

@MainActor
extension RuneScribeUISession {
    func makeOutboundSharePresentationWithLegacyFallback(
        inscription: String,
        accessibilityLabel: String,
        operationID: RuntimeOperationID
    ) async -> OutboundSharePresentationPreparation {
        guard let capturedAt = snapshot?.capturedAt else {
            return OutboundSharePresentationPreparation(
                presentation: nil,
                status: .legacyFallback(.themeUnavailable)
            )
        }
        do {
            let presentation = try await makeOutboundSharePresentation(
                inscription: inscription,
                accessibilityLabel: accessibilityLabel,
                operationID: operationID,
                capturedAt: capturedAt
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
        accessibilityLabel: String,
        operationID: RuntimeOperationID,
        capturedAt: Date
    ) async throws -> OutboundSharePresentationDTO {
        guard let snapshot = themeSnapshot,
              !snapshot.isEmergencyPresentation,
              let themeCoordinatorClientHandle,
              let provider = snapshot.providers.first(where: {
                  $0.codexID == snapshot.effectiveCodexID
              }),
              let activeVisuals = activeThemeVisualPresentation,
              activeVisuals.plan.codex.codexID == snapshot.effectiveCodexID
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
        let request = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: inscription,
            operationID: operationID,
            capturedAt: capturedAt,
            localeIdentifier: descriptor.defaultLocaleIdentifier,
            scale: 1,
            accessibilityLabel: accessibilityLabel,
            provenanceLabel: "Source details included",
            fontPostScriptNameOverride: activeCipher?.fontSource == .imported
                && activeCipher?.fontIsRegistered == true
                ? ThemeFontPostScriptName(rawValue: inscriptionFontPostScriptName)
                : nil
        )
        let plan = try ShareArtifactRenderPolicy.plan(
            request: request,
            descriptor: descriptor
        )
        var resourceData: [ThemeResourceID: Data] = [:]
        var imageReferences: [ThemeResourceID: RuntimeThemeImageReference] = [:]
        for resource in plan.resourceMetadata {
            let resolved: ResolvedThemeResourceDTO
            do {
                resolved = try await themeCoordinatorClientHandle.resolveResource(
                    ResolveThemeResourceRequestDTO(
                        codexID: descriptor.codex.id,
                        resourceID: resource.resourceID
                    )
                )
            } catch {
                throw Self.outboundShareResourceResolutionError(
                    for: resource.resourceID,
                    underlying: error
                )
            }
            try Self.validateOutboundShareResolvedResource(
                resolved,
                expected: resource,
                codexID: descriptor.codex.id
            )
            switch resource.mediaType {
            case .png, .heif, .pdf:
                do {
                    imageReferences[resource.resourceID] = try resourcePresentation
                        .makeThemeImageReference(
                            resolvedResource: resolved,
                            expectedInventory: SharePresentationProviderResourceInventory(
                                metadata: resource
                            ),
                            expectedCodexID: descriptor.codex.id,
                            contentRevision: activeVisuals.revision
                        )
                } catch {
                    throw Self.outboundShareImageReferenceError(
                        for: resource.resourceID,
                        underlying: error
                    )
                }
            case .ttf, .otf:
                resourceData[resource.resourceID] = resolved.data
            case .json, .mp4, .quickTime, .m4a, .caf, .wav:
                throw ShareArtifactRenderError.invalidResource(resource.resourceID)
            }
        }
        guard themeSnapshot?.revision == snapshot.revision,
              let currentVisuals = activeThemeVisualPresentation,
              currentVisuals.revision == activeVisuals.revision,
              currentVisuals.plan == activeVisuals.plan
        else { throw ShareArtifactRenderError.unavailableSelection }
        let output = try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: resourceData,
            imageReferences: imageReferences,
            contentRevision: activeVisuals.revision
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

    static func validateOutboundShareResolvedResource(
        _ resolved: ResolvedThemeResourceDTO,
        expected: SharePresentationResourceMetadata,
        codexID: CodexID
    ) throws {
        let digest = SHA256.hash(data: resolved.data).map {
            String(format: "%02x", $0)
        }.joined()
        guard resolved.codexID == codexID,
              resolved.resourceID == expected.resourceID,
              resolved.role == expected.role,
              resolved.mediaType == expected.mediaType,
              resolved.integrity.byteLength == expected.byteLength,
              resolved.integrity.pixelSize == expected.pixelSize,
              resolved.integrity.sha256 == expected.sha256,
              UInt64(resolved.data.count) == expected.byteLength,
              digest == expected.sha256.rawValue
        else { throw ShareArtifactRenderError.invalidResource(expected.resourceID) }
    }

    static func outboundShareImageReferenceError(
        for resourceID: ThemeResourceID,
        underlying error: Error
    ) -> ShareArtifactRenderError {
        guard let referenceError = error as? RuntimeThemeImageReferenceError else {
            return .renderingFailed
        }
        switch referenceError {
        case .presentationClosed:
            return .unavailableSelection
        case .cacheCapacityExceeded:
            return .renderingFailed
        case .codexIdentityMismatch, .resourceIdentityMismatch, .roleMismatch,
             .mediaTypeMismatch, .integrityMismatch, .encodedContentMismatch,
             .pixelDimensionsMismatch, .unsupportedImage:
            return .invalidResource(resourceID)
        }
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
