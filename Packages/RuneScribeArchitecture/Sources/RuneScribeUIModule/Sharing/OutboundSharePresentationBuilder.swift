import CryptoKit
import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

enum OutboundShareFontFallbackReason: Equatable, Sendable {
    case cipherUnavailable
    case importedFontUnregistered
    case importedFontUnsupported
}

enum OutboundShareFontProjection: Equatable, Sendable {
    case themeScript
    case registeredImportedFont(ThemeFontPostScriptName)
    case themeScriptFallback(OutboundShareFontFallbackReason)

    var fontPostScriptNameOverride: ThemeFontPostScriptName? {
        guard case .registeredImportedFont(let postScriptName) = self else {
            return nil
        }
        return postScriptName
    }

    var shareFallbackNotice: String? {
        switch self {
        case .themeScriptFallback(.importedFontUnregistered),
             .themeScriptFallback(.importedFontUnsupported):
            "Custom script unavailable — shares use the Codex script."
        case .themeScriptFallback(.cipherUnavailable):
            "Cipher unavailable — shares use the Codex script."
        case .themeScript, .registeredImportedFont:
            nil
        }
    }
}

enum OutboundShareFontPolicy {
    static func projection(
        for cipherID: UUID?,
        in ciphers: [CipherViewState]
    ) -> OutboundShareFontProjection {
        guard let cipherID else { return .themeScript }
        guard let cipher = ciphers.first(where: { $0.id == cipherID }) else {
            return .themeScriptFallback(.cipherUnavailable)
        }
        guard cipher.fontSource == .imported else { return .themeScript }
        guard cipher.fontIsRegistered else {
            return .themeScriptFallback(.importedFontUnregistered)
        }
        guard let postScriptName = ThemeFontPostScriptName(
            rawValue: cipher.fontName
        ) else {
            return .themeScriptFallback(.importedFontUnsupported)
        }
        return .registeredImportedFont(postScriptName)
    }
}

@MainActor
extension RuneScribeUISession {
    func makeOutboundSharePresentationWithLegacyFallback(
        inscription: String,
        accessibilityLabel: String,
        operationID: RuntimeOperationID,
        cipherID: UUID? = nil,
        selection: SharePresentationSelection? = nil,
        descriptor: ThemeDescriptor? = nil,
        effects: RuntimeEffectsPreference? = nil,
        colorMode: ShareArtifactColorMode = .standard,
        systemReduceMotion: Bool = false
    ) async -> OutboundSharePresentationPreparation {
        guard let capturedAt = snapshot?.capturedAt else {
            return OutboundSharePresentationPreparation(
                presentation: nil,
                status: .legacyFallback(.themeUnavailable)
            )
        }
        do {
            let output = try await makeOutboundSharePresentationOutput(
                inscription: inscription,
                accessibilityLabel: accessibilityLabel,
                operationID: operationID,
                capturedAt: capturedAt,
                cipherID: cipherID,
                selection: selection,
                descriptor: descriptor,
                effects: effects,
                colorMode: colorMode,
                systemReduceMotion: systemReduceMotion
            )
            return OutboundSharePresentationPreparation(
                presentation: output.presentation,
                status: .themed,
                rendererOutputID: output.rendererOutputID
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
        capturedAt: Date,
        cipherID: UUID? = nil,
        selection requestedSelection: SharePresentationSelection? = nil,
        descriptor requestedDescriptor: ThemeDescriptor? = nil,
        effects: RuntimeEffectsPreference? = nil,
        colorMode: ShareArtifactColorMode = .standard,
        systemReduceMotion: Bool = false
    ) async throws -> OutboundSharePresentationDTO {
        try await makeOutboundSharePresentationOutput(
            inscription: inscription,
            accessibilityLabel: accessibilityLabel,
            operationID: operationID,
            capturedAt: capturedAt,
            cipherID: cipherID,
            selection: requestedSelection,
            descriptor: requestedDescriptor,
            effects: effects,
            colorMode: colorMode,
            systemReduceMotion: systemReduceMotion
        ).presentation
    }

    private func makeOutboundSharePresentationOutput(
        inscription: String,
        accessibilityLabel: String,
        operationID: RuntimeOperationID,
        capturedAt: Date,
        cipherID: UUID?,
        selection requestedSelection: SharePresentationSelection?,
        descriptor requestedDescriptor: ThemeDescriptor?,
        effects: RuntimeEffectsPreference?,
        colorMode: ShareArtifactColorMode,
        systemReduceMotion: Bool
    ) async throws -> (
        presentation: OutboundSharePresentationDTO,
        rendererOutputID: String
    ) {
        guard let snapshot = themeSnapshot,
              !snapshot.isEmergencyPresentation,
              let themeCoordinatorClientHandle
        else { throw ShareArtifactRenderError.unavailableSelection }

        let descriptor = requestedDescriptor ?? snapshot.effectiveTheme
        guard let provider = snapshot.providers.first(where: {
            $0.codexID == descriptor.codex.id
        }) else { throw ShareArtifactRenderError.unavailableSelection }
        let selection = if let requestedSelection {
            try requestedSelectionValidated(
                requestedSelection,
                descriptor: descriptor,
                provider: provider
            )
        } else {
            try makeShareBuilderCatalog(
                descriptor: descriptor,
                provider: provider
            ).validatedSelection()
        }
        let effectiveEffects = (effects ?? appearanceEffectsPreference).effective(
            systemReduceMotion: systemReduceMotion
        )
        let fontProjection = OutboundShareFontPolicy.projection(
            for: cipherID,
            in: ciphers
        )
        let request = try ShareArtifactRenderRequest(
            selection: selection,
            inscription: inscription,
            operationID: operationID,
            capturedAt: capturedAt,
            localeIdentifier: descriptor.defaultLocaleIdentifier,
            scale: 1,
            colorMode: colorMode,
            reduceMotion: effectiveEffects != .full,
            accessibilityLabel: accessibilityLabel,
            provenanceLabel: "Source details included",
            fontPostScriptNameOverride: fontProjection.fontPostScriptNameOverride
        )
        let plan = try ShareArtifactRenderPolicy.plan(
            request: request,
            descriptor: descriptor
        )
        var resourceData: [ThemeResourceID: Data] = [:]
        var imageReferences: [ThemeResourceID: RuntimeThemeImageReference] = [:]
        for resource in plan.resourceMetadata {
            try Task.checkCancellation()
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
                            contentRevision: snapshot.revision
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
        try Task.checkCancellation()
        guard themeSnapshot?.revision == snapshot.revision
        else { throw ShareArtifactRenderError.unavailableSelection }
        let output = try ShareArtifactStaticRenderer.render(
            plan: plan,
            resourceData: resourceData,
            imageReferences: imageReferences,
            contentRevision: snapshot.revision
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
        return (
            presentation: try OutboundSharePresentationDTO(
                metadata: metadata,
                safePreviewData: safePreviewData,
                signedProvenance: nil
            ),
            rendererOutputID: output.rendererOutputID
        )
    }

    private func requestedSelectionValidated(
        _ selection: SharePresentationSelection,
        descriptor: ThemeDescriptor,
        provider: ThemeProviderSummaryDTO
    ) throws -> SharePresentationSelection {
        let validated = try ShareBuilderPolicy.selection(
            descriptor: descriptor,
            codexOwned: provider.isOwned,
            providerAvailable: provider.state == .available,
            ownedArtifactIDs: ownedThemeArtifactIDs,
            relicID: selection.relicID,
            sealID: selection.sealID,
            frameID: selection.frameID
        )
        guard validated == selection else {
            throw ShareArtifactRenderError.unknownSelection
        }
        return validated
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
        // Share metadata intentionally omits vector page dimensions. The
        // provider-owned resolved resource remains the authority for those
        // dimensions and is decoded again before rendering.
        let pixelSizeMatches = expected.mediaType == .pdf
            ? expected.pixelSize == nil
            : resolved.integrity.pixelSize == expected.pixelSize
        guard resolved.codexID == codexID,
              resolved.resourceID == expected.resourceID,
              resolved.role == expected.role,
              resolved.mediaType == expected.mediaType,
              resolved.integrity.byteLength == expected.byteLength,
              pixelSizeMatches,
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
