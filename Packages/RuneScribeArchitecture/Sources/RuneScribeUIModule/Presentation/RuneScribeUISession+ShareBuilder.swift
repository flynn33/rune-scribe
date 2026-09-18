import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

struct PreparedShareBuilderArtifact {
    let artifact: ShareArtifactDTO
    let transfer: OpaqueShareTransfer
    let themeRevision: ShareBuilderThemeAuthorityRevision
    let colorMode: ShareArtifactColorMode
    let systemReduceMotion: Bool
    let previewImageData: Data?

    init(
        artifact: ShareArtifactDTO,
        transfer: OpaqueShareTransfer,
        themeRevision: ShareBuilderThemeAuthorityRevision,
        colorMode: ShareArtifactColorMode,
        systemReduceMotion: Bool,
        previewImageData: Data? = nil
    ) {
        self.artifact = artifact
        self.transfer = transfer
        self.themeRevision = themeRevision
        self.colorMode = colorMode
        self.systemReduceMotion = systemReduceMotion
        self.previewImageData = previewImageData
    }
}

@MainActor
extension RuneScribeUISession {
    func shareBuilderThemeAuthorityRevision(
        for catalog: ShareBuilderCatalog
    ) throws -> ShareBuilderThemeAuthorityRevision {
        guard let themeSnapshot else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        guard let provider = themeSnapshot.providers.first(where: {
            $0.codexID == catalog.descriptor.codex.id
        }),
            provider.moduleID == catalog.provider.moduleID,
            provider.state == .available,
            provider.isOwned,
            provider.isSelectable
        else { throw ShareArtifactRenderError.unavailableSelection }
        let providerContentRevision: UInt64
        if themeSnapshot.effectiveCodexID == catalog.descriptor.codex.id {
            guard themeSnapshot.effectiveTheme == catalog.descriptor,
                  let activeThemeVisualPresentation,
                  activeThemeVisualPresentation.plan.themeID == catalog.descriptor.id,
                  activeThemeVisualPresentation.plan.codexID
                    == catalog.descriptor.codex.id,
                  activeThemeVisualPresentation.plan.revision
                    == activeThemeVisualPresentation.revision
            else { throw ShareArtifactRenderError.unavailableSelection }
            providerContentRevision = activeThemeVisualPresentation.revision
        } else {
            providerContentRevision = themeSnapshot.revision
        }
        return ShareBuilderThemeAuthorityRevision(
            coordinatorRevision: themeSnapshot.revision,
            providerContentRevision: providerContentRevision
        )
    }

    func loadShareBuilderCatalog(
        codexID: CodexID
    ) async throws -> ShareBuilderCatalog {
        guard let snapshot = themeSnapshot,
              let provider = snapshot.providers.first(where: {
                  $0.codexID == codexID
              }),
              provider.isSelectable,
              let themeCoordinatorClientHandle
        else { throw ShareArtifactRenderError.unavailableSelection }
        let descriptor: ThemeDescriptor
        if snapshot.effectiveCodexID == codexID {
            descriptor = snapshot.effectiveTheme
        } else {
            descriptor = try await themeCoordinatorClientHandle.providerDescriptor(for: codexID)
        }
        try Task.checkCancellation()
        guard themeSnapshot?.revision == snapshot.revision else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        return try makeShareBuilderCatalog(
            descriptor: descriptor,
            provider: provider
        )
    }

    func loadShareBuilderArtwork(
        for catalog: ShareBuilderCatalog
    ) async -> [ArtifactID: RuntimeThemeImageReference] {
        guard let themeCoordinatorClientHandle,
              let revision = themeSnapshot?.revision
        else { return [:] }
        let codex = catalog.descriptor.codex
        let requested: [(ArtifactID, ThemeResourceID)] =
            codex.relics.map { ($0.metadata.id, $0.thumbnailResourceID) }
                + codex.seals.map { ($0.metadata.id, $0.thumbnailResourceID) }
                + codex.frames.map {
                    ($0.metadata.id, $0.thumbnailResourceID ?? $0.staticFallbackResourceID)
                }
        var result: [ArtifactID: RuntimeThemeImageReference] = [:]
        for (artifactID, resourceID) in requested {
            guard let expected = catalog.descriptor.resources.first(where: {
                $0.id == resourceID
            }) else { continue }
            do {
                let resolved = try await themeCoordinatorClientHandle.resolveResource(
                    ResolveThemeResourceRequestDTO(
                        codexID: codex.id,
                        resourceID: resourceID,
                        purpose: .catalogPreview
                    )
                )
                result[artifactID] = try resourcePresentation.makeThemeImageReference(
                    resolvedResource: resolved,
                    expectedReference: expected,
                    expectedCodexID: codex.id,
                    contentRevision: revision
                )
            } catch {
                continue
            }
        }
        return result
    }

    func renderShareBuilderPreview(
        source: ShareBuilderSource,
        catalog: ShareBuilderCatalog,
        colorMode: ShareArtifactColorMode = .standard,
        systemReduceMotion: Bool = false
    ) async throws -> RenderedShareBuilderPreview {
        let themeRevision = try shareBuilderThemeAuthorityRevision(for: catalog)
        guard let themeCapturedAt = themeSnapshot?.capturedAt else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        let selection = try catalog.validatedSelection()
        let operationID: RuntimeOperationID
        switch source.purpose {
        case .encryptedMessage:
            guard let messageHandle = source.messageHandle else {
                throw OpaqueSharePresentationError.unavailable
            }
            operationID = RuntimeOperationID(
                rawValue: "share.render.message.\(messageHandle.rawValue.uuidString.lowercased())"
            )
        case .cipherInvitation:
            operationID = RuntimeOperationID(
                rawValue: "share.render.cipher.\(source.cipherID.uuidString.lowercased())"
            )
        }
        let presentation = try await makeOutboundSharePresentation(
            inscription: source.inscription,
            accessibilityLabel: "Rune Scribe share preview for \(source.displayName)",
            operationID: operationID,
            capturedAt: snapshot?.capturedAt ?? themeCapturedAt,
            cipherID: source.cipherID,
            selection: selection,
            descriptor: catalog.descriptor,
            effects: catalog.draft.effects,
            colorMode: colorMode,
            systemReduceMotion: systemReduceMotion
        )
        guard (try? shareBuilderThemeAuthorityRevision(for: catalog))
                == themeRevision
        else {
            throw ShareArtifactRenderError.unavailableSelection
        }
        return try RenderedShareBuilderPreview(
            source: source,
            catalog: catalog,
            themeRevision: themeRevision,
            colorMode: colorMode,
            systemReduceMotion: systemReduceMotion,
            presentation: presentation
        )
    }

    func prepareShareBuilderArtifact(
        source: ShareBuilderSource,
        catalog: ShareBuilderCatalog,
        renderedPreview: RenderedShareBuilderPreview,
        colorMode: ShareArtifactColorMode = .standard,
        systemReduceMotion: Bool = false
    ) async throws -> PreparedShareBuilderArtifact {
        guard let themeRevision = try? shareBuilderThemeAuthorityRevision(for: catalog),
              renderedPreview.matches(
                  source: source,
                  catalog: catalog,
                  themeRevision: themeRevision,
                  colorMode: colorMode,
                  systemReduceMotion: systemReduceMotion
              )
        else { throw ShareArtifactRenderError.unavailableSelection }
        let selection = try catalog.validatedSelection()
        let artifact: ShareArtifactDTO
        switch source.purpose {
        case .encryptedMessage:
            guard let messageHandle = source.messageHandle else {
                throw OpaqueSharePresentationError.unavailable
            }
            artifact = try await prepareMessageShare(
                runes: source.inscription,
                senderName: source.displayName,
                cipherID: source.cipherID,
                shareHandle: messageHandle,
                selection: selection,
                descriptor: catalog.descriptor,
                effects: catalog.draft.effects,
                colorMode: colorMode,
                systemReduceMotion: systemReduceMotion,
                renderedPresentation: renderedPreview.presentation
            )
        case .cipherInvitation:
            artifact = try await prepareCipherShare(
                cipherID: source.cipherID,
                displayName: source.displayName,
                representation: .link,
                selection: selection,
                descriptor: catalog.descriptor,
                effects: catalog.draft.effects,
                colorMode: colorMode,
                systemReduceMotion: systemReduceMotion,
                renderedPresentation: renderedPreview.presentation
            )
        }
        guard let currentThemeRevision = try? shareBuilderThemeAuthorityRevision(
                  for: catalog
              ),
              renderedPreview.matches(
                  source: source,
                  catalog: catalog,
                  themeRevision: currentThemeRevision,
                  colorMode: colorMode,
                  systemReduceMotion: systemReduceMotion
              )
        else {
            await releaseShareArtifact(id: artifact.id)
            throw ShareArtifactRenderError.unavailableSelection
        }
        var transfer: OpaqueShareTransfer?
        do {
            try Task.checkCancellation()
            switch artifact.reference {
            case .file:
                transfer = try await shareTransfer(for: artifact.id)
            case .opaque:
                if source.purpose == .cipherInvitation {
                    transfer = try await shareTransfer(for: artifact.id)
                } else {
                    transfer = try await textShareTransfer(
                        source.inscription,
                        artifactID: artifact.id
                    )
                }
            }
            try Task.checkCancellation()
            guard let transfer else {
                throw OpaqueSharePresentationError.unavailable
            }
            guard let currentThemeRevision = try? shareBuilderThemeAuthorityRevision(
                      for: catalog
                  ),
                  renderedPreview.matches(
                      source: source,
                      catalog: catalog,
                      themeRevision: currentThemeRevision,
                      colorMode: colorMode,
                      systemReduceMotion: systemReduceMotion
                  )
            else { throw ShareArtifactRenderError.unavailableSelection }
            return PreparedShareBuilderArtifact(
                artifact: artifact,
                transfer: transfer,
                themeRevision: currentThemeRevision,
                colorMode: colorMode,
                systemReduceMotion: systemReduceMotion,
                previewImageData: renderedPreview.presentation.safePreviewData
            )
        } catch {
            await transfer?.close()
            await releaseShareArtifact(id: artifact.id)
            throw error
        }
    }

    func finishShareBuilderArtifact(
        _ prepared: PreparedShareBuilderArtifact,
        completion: SharePresentationCompletion
    ) async throws -> ShareRouteResultDTO {
        let terminalError: (any Error)?
        let terminalResult: ShareRouteResultDTO?
        switch completion {
        case .success(let evidence):
            if evidence.artifactID == prepared.artifact.id {
                do {
                    _ = try await completeShareArtifact(evidence: evidence)
                    terminalError = nil
                    terminalResult = evidence.report.result
                } catch {
                    terminalError = error
                    terminalResult = nil
                }
            } else {
                terminalError = OpaqueSharePresentationError.revoked
                terminalResult = nil
            }
        case .failure(let error):
            terminalError = error
            terminalResult = nil
        }
        await prepared.transfer.close()
        await releaseShareArtifact(id: prepared.artifact.id)
        if let terminalError { throw terminalError }
        guard let terminalResult else {
            throw OpaqueSharePresentationError.revoked
        }
        return terminalResult
    }
}
