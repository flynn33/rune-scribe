import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeUIRuntime

struct ReceivedCipherPresentationRequest: Equatable, Sendable {
    let messageID: MessageID
    let senderIdentityStatus: ReceivedSenderIdentityStatusDTO
    let plaintext: String
    let presentation: ReceivedSharePresentation?
    let themeSnapshotRevision: UInt64?
    let state: ReceivedCipherPresentationState
    let reduceMotion: Bool

    init(
        pending: PendingMessageViewState,
        themeSnapshotRevision: UInt64?,
        state: ReceivedCipherPresentationState,
        reduceMotion: Bool
    ) {
        messageID = pending.id
        senderIdentityStatus = pending.senderIdentityStatus
        plaintext = pending.plaintext
        presentation = pending.presentation
        self.themeSnapshotRevision = themeSnapshotRevision
        self.state = state
        self.reduceMotion = reduceMotion
    }
}

struct ReceivedCipherPresentationAuthority {
    let request: ReceivedCipherPresentationRequest
    let content: ReceivedCipherPresentationContent
    let presentation: ActiveThemeVisualPresentation

    func matches(
        pending: PendingMessageViewState,
        state: ReceivedCipherPresentationState,
        themeSnapshotRevision: UInt64,
        reduceMotion: Bool
    ) -> Bool {
        request == ReceivedCipherPresentationRequest(
            pending: pending,
            themeSnapshotRevision: themeSnapshotRevision,
            state: state,
            reduceMotion: reduceMotion
        )
            && content.state == state
            && pending.presentation?.providerAvailability == .available
            && pending.presentation?.renderMode == .requestedCodex
            && pending.presentation?.effectiveSelection == content.plan.selection
    }
}

struct ReceivedCipherPresentationDowngrade {
    let messageID: MessageID
    let themeSnapshotRevision: UInt64
    let requestedSelection: SharePresentationSelection
    let providerAvailability: ShareProviderAvailability
}

enum ReceivedCipherPresentationLoadState {
    case idle
    case prepared(ReceivedCipherPresentationAuthority)
    case downgraded(ReceivedCipherPresentationDowngrade)
}

@MainActor
extension RuneScribeUISession {
    func prepareActiveReceivedCipherPresentation(
        pending: PendingMessageViewState,
        state: ReceivedCipherPresentationState,
        reduceMotion: Bool
    ) async throws {
        let request = ReceivedCipherPresentationRequest(
            pending: pending,
            themeSnapshotRevision: themeSnapshot?.revision,
            state: state,
            reduceMotion: reduceMotion
        )
        receivedCipherPresentationGeneration &+= 1
        let generation = receivedCipherPresentationGeneration
        setReceivedCipherPresentationLoadState(.idle)

        guard pending.senderIdentityStatus != .awaitingCipherConfirmation,
              let retainedPresentation = pending.presentation,
              retainedPresentation.providerAvailability == .available,
              retainedPresentation.renderMode == .requestedCodex
        else { return }

        guard let snapshot = themeSnapshot,
              let client = themeCoordinatorClientHandle
        else {
            applyReceivedCipherDowngrade(
                pending: pending,
                snapshotRevision: themeSnapshot?.revision ?? 0,
                availability: .unknown,
                generation: generation
            )
            throw ThemePresentationResourceError.stateUnavailable
        }

        let livePresentation = ReceivedPresentationAvailabilityBinding.resolve(
            retainedPresentation,
            against: snapshot
        )
        guard livePresentation.providerAvailability == .available,
              livePresentation.renderMode == .requestedCodex,
              let selection = livePresentation.effectiveSelection
        else {
            applyReceivedCipherDowngrade(
                pending: pending,
                snapshotRevision: snapshot.revision,
                availability: livePresentation.providerAvailability,
                generation: generation
            )
            return
        }
        let livePending = PendingMessageViewState(
            copying: pending,
            presentation: livePresentation
        )

        do {
            let descriptor: ThemeDescriptor
            if snapshot.effectiveCodexID == selection.codexID {
                descriptor = snapshot.effectiveTheme
            } else {
                descriptor = try await client.providerDescriptor(
                    for: selection.codexID,
                    purpose: .receivedPresentation
                )
            }
            guard let content = try ReceivedCipherPresentationContent.resolve(
                state: state,
                pending: livePending,
                descriptor: descriptor,
                reduceMotion: reduceMotion
            ), let script = descriptor.codex.scripts.first(where: {
                $0.id == content.plan.selection.scriptID
            }) else {
                throw ThemePresentationResourceError.identityMismatch
            }

            var requiredResourceIDs = content.requiredImageResourceIDs
            if let fontResourceID = script.fontResourceID {
                requiredResourceIDs.insert(fontResourceID)
            }
            let visualPlan = try ActiveThemeVisualResourcePlan(
                descriptor: descriptor,
                revision: snapshot.revision,
                selection: content.plan.selection
            )
            let expectedReferences = Dictionary(
                uniqueKeysWithValues: descriptor.resources.map { ($0.id, $0) }
            )
            let resolved = try await Self.resolveReceivedCipherResources(
                codexID: descriptor.codex.id,
                selection: content.plan.selection,
                resourceIDs: requiredResourceIDs,
                expectedReferences: expectedReferences,
                client: client
            )
            try Task.checkCancellation()

            if let fontResourceID = script.fontResourceID {
                guard let runtimeIOHandle,
                      let font = resolved[fontResourceID],
                      let expectedPostScriptName = script.fontPostScriptName?.rawValue
                else { throw ThemePresentationResourceError.missing(fontResourceID) }
                let inspectedName = try await runtimeIOHandle.systemFontPostScriptName(
                    for: font.data
                )
                guard inspectedName == expectedPostScriptName else {
                    throw ThemePresentationResourceError.fontIdentityMismatch
                }
                let registered = try await runtimeIOHandle.registerSystemFont(font.data)
                guard registered.postScriptName == inspectedName else {
                    throw ThemePresentationResourceError.fontIdentityMismatch
                }
            }
            try Task.checkCancellation()

            var imageReferences: [ThemeResourceID: RuntimeThemeImageReference] = [:]
            for resourceID in content.requiredImageResourceIDs.sorted() {
                guard let resource = resolved[resourceID],
                      let expected = expectedReferences[resourceID]
                else { throw ThemePresentationResourceError.missing(resourceID) }
                imageReferences[resourceID] = try resourcePresentation
                    .makeThemeImageReference(
                        resolvedResource: resource,
                        expectedReference: expected,
                        expectedCodexID: descriptor.codex.id,
                        contentRevision: snapshot.revision
                    )
            }
            let presentation = ActiveThemeVisualPresentation(
                revision: snapshot.revision,
                plan: visualPlan,
                imageReferences: imageReferences
            )
            guard content.requiredImageResourceIDs.allSatisfy({
                presentation.image(for: $0) != nil
            }) else {
                throw ThemePresentationResourceError.identityMismatch
            }
            try Task.checkCancellation()
            guard receivedCipherPresentationGeneration == generation,
                  themeSnapshot?.revision == snapshot.revision,
                  request.themeSnapshotRevision == snapshot.revision
            else { throw CancellationError() }

            setReceivedCipherPresentationLoadState(.prepared(
                ReceivedCipherPresentationAuthority(
                    request: request,
                    content: content,
                    presentation: presentation
                )
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            applyReceivedCipherDowngrade(
                pending: livePending,
                snapshotRevision: snapshot.revision,
                availability: Self.receivedCipherDowngradeAvailability(
                    for: error
                ),
                generation: generation
            )
            throw error
        }
    }

    func activeReceivedCipherPresentationBinding(
        pending: PendingMessageViewState,
        state: ReceivedCipherPresentationState,
        relativeDate: Date,
        reduceMotion: Bool
    ) -> ReceivedCipherPresentationBinding? {
        guard let snapshot = themeSnapshot,
              case .prepared(let authority) = receivedCipherPresentationLoadState,
              authority.matches(
                  pending: pending,
                  state: state,
                  themeSnapshotRevision: snapshot.revision,
                  reduceMotion: reduceMotion
              )
        else { return nil }

        return ReceivedCipherPresentationBinding(
            content: authority.content,
            pending: pending,
            receivedAt: pending.receivedAt,
            relativeDate: relativeDate,
            presentation: authority.presentation
        )
    }

    func receivedCipherPendingMessage(
        _ message: ReceivedMessageDTO
    ) -> PendingMessageViewState {
        let pending = PendingMessageViewState(
            message,
            themeSnapshot: themeSnapshot
        )
        guard let snapshotRevision = themeSnapshot?.revision,
              case .downgraded(let downgrade) = receivedCipherPresentationLoadState,
              downgrade.messageID == pending.id,
              downgrade.themeSnapshotRevision == snapshotRevision,
              let presentation = pending.presentation,
              presentation.requestedSelection == downgrade.requestedSelection
        else { return pending }
        return PendingMessageViewState(
            copying: pending,
            presentation: ReceivedPresentationAvailabilityBinding.downgrade(
                presentation,
                to: downgrade.providerAvailability
            )
        )
    }

    private func applyReceivedCipherDowngrade(
        pending: PendingMessageViewState,
        snapshotRevision: UInt64,
        availability: ShareProviderAvailability,
        generation: UInt64
    ) {
        guard availability != .available,
              receivedCipherPresentationGeneration == generation,
              themeSnapshot?.revision == snapshotRevision,
              let presentation = pending.presentation
        else { return }
        setReceivedCipherPresentationLoadState(.downgraded(
            ReceivedCipherPresentationDowngrade(
                messageID: pending.id,
                themeSnapshotRevision: snapshotRevision,
                requestedSelection: presentation.requestedSelection,
                providerAvailability: availability
            )
        ))
    }

    private static func resolveReceivedCipherResources(
        codexID: CodexID,
        selection: SharePresentationSelection,
        resourceIDs: Set<ThemeResourceID>,
        expectedReferences: [ThemeResourceID: ThemeResourceReference],
        client: RuntimeThemeCoordinatorClient
    ) async throws -> [ThemeResourceID: ResolvedThemeResourceDTO] {
        try await withThrowingTaskGroup(
            of: (ThemeResourceID, ResolvedThemeResourceDTO).self,
            returning: [ThemeResourceID: ResolvedThemeResourceDTO].self
        ) { group in
            for resourceID in resourceIDs {
                guard let expected = expectedReferences[resourceID] else {
                    throw ThemePresentationResourceError.missing(resourceID)
                }
                group.addTask {
                    let resolved = try await client.resolveResource(
                        ResolveThemeResourceRequestDTO(
                            codexID: codexID,
                            resourceID: resourceID,
                            purpose: .receivedPresentation,
                            receivedPresentationSelection: selection
                        )
                    )
                    guard resolved.codexID == codexID,
                          resolved.resourceID == resourceID,
                          resolved.role == expected.role,
                          resolved.mediaType == expected.mediaType,
                          resolved.integrity == expected.integrity
                    else {
                        throw ThemePresentationResourceError.identityMismatch
                    }
                    return (resourceID, resolved)
                }
            }
            var result: [ThemeResourceID: ResolvedThemeResourceDTO] = [:]
            for try await (resourceID, resource) in group {
                result[resourceID] = resource
            }
            return result
        }
    }

    private static func receivedCipherDowngradeAvailability(
        for error: Error
    ) -> ShareProviderAvailability {
        if let error = error as? ThemePresentationResourceError {
            return switch error {
            case .missing, .identityMismatch, .fontIdentityMismatch: .corrupt
            case .stateUnavailable: .unknown
            }
        }
        if let error = error as? RuntimeThemeImageReferenceError {
            return switch error {
            case .presentationClosed, .cacheCapacityExceeded: .unknown
            case .codexIdentityMismatch, .resourceIdentityMismatch, .roleMismatch,
                 .mediaTypeMismatch, .integrityMismatch, .encodedContentMismatch,
                 .pixelDimensionsMismatch, .unsupportedImage:
                .corrupt
            }
        }
        return .unknown
    }
}

private extension PendingMessageViewState {
    init(
        copying source: PendingMessageViewState,
        presentation: ReceivedSharePresentation?
    ) {
        id = source.id
        receivedAt = source.receivedAt
        plaintext = source.plaintext
        senderName = source.senderName
        cipherID = source.cipherID
        cipherName = source.cipherName
        senderIdentityStatus = source.senderIdentityStatus
        self.presentation = presentation
        safePreviewData = source.safePreviewData
    }
}
