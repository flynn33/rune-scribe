import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

struct PreparedShareBuilderArtifact {
    let artifact: ShareArtifactDTO
    let transfer: OpaqueShareTransfer
}

@MainActor
extension RuneScribeUISession {
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
                + codex.frames.map { ($0.metadata.id, $0.staticFallbackResourceID) }
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
    ) async throws -> OutboundSharePresentationDTO {
        let selection = try catalog.validatedSelection()
        let operationKind: String = switch source.purpose {
        case .encryptedMessage: "message"
        case .cipherInvitation: "cipher"
        }
        return try await makeOutboundSharePresentation(
            inscription: source.inscription,
            accessibilityLabel: "Rune Scribe share preview for \(source.displayName)",
            operationID: RuntimeOperationID(
                rawValue: "share.preview.\(operationKind).\(source.cipherID.uuidString.lowercased())"
            ),
            capturedAt: snapshot?.capturedAt ?? Date(),
            cipherID: source.cipherID,
            selection: selection,
            descriptor: catalog.descriptor,
            effects: catalog.draft.effects,
            colorMode: colorMode,
            systemReduceMotion: systemReduceMotion
        )
    }

    func prepareShareBuilderArtifact(
        source: ShareBuilderSource,
        catalog: ShareBuilderCatalog,
        colorMode: ShareArtifactColorMode = .standard,
        systemReduceMotion: Bool = false
    ) async throws -> PreparedShareBuilderArtifact {
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
                systemReduceMotion: systemReduceMotion
            )
        case .cipherInvitation:
            artifact = try await prepareCipherShare(
                cipherID: source.cipherID,
                displayName: source.displayName,
                representation: .file,
                selection: selection,
                descriptor: catalog.descriptor,
                effects: catalog.draft.effects,
                colorMode: colorMode,
                systemReduceMotion: systemReduceMotion
            )
        }
        var transfer: OpaqueShareTransfer?
        do {
            try Task.checkCancellation()
            switch artifact.reference {
            case .file:
                transfer = try await shareTransfer(for: artifact.id)
            case .opaque:
                transfer = try await textShareTransfer(
                    source.inscription,
                    artifactID: artifact.id
                )
            }
            try Task.checkCancellation()
            guard let transfer else {
                throw OpaqueSharePresentationError.unavailable
            }
            return PreparedShareBuilderArtifact(artifact: artifact, transfer: transfer)
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
