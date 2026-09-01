import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

struct MessageImportMutation: Sendable {
    let message: ReceivedMessageDTO
    let library: CipherLibrary
    let pendingEmbeddedCipher: CipherSharePayload?
}

enum MessageImportError: Error, Equatable, Sendable {
    case cipherAssociationUnavailable
}

enum MessageImportUseCase {
    static func ingest(
        payload: MessageSharePayload,
        receivedAt: Date,
        fontBytes _: Data?,
        repository: CipherRepository,
        messageService: MessageService,
        fontIntegration _: (any CoreFontIntegrating)?,
        contactIntegration _: (any CoreMessageContactAssociating)?,
        runtimeIO: RuntimeIOClient,
        progression: CoreProgressionCoordinator,
        usesProgressionEvidence: Bool,
        admittedPackageToken: PackageToken?,
        progressionRoute _: DomainEventRouteClass,
        embeddedCipherProgressionSeed _: Data?,
        relationshipProgressionSeed: Data?,
        presentation: SharePresentationIntake = .absent
    ) async throws -> MessageImportMutation {
        let prepared: PreparedMessageCipher?
        let initialLibrary: CipherLibrary
        if let embedded = payload.embeddedCipher {
            let candidate = try await repository.prepareMessageCipher(
                embedded,
                label: payload.senderName
            )
            prepared = candidate
            initialLibrary = candidate.library
        } else {
            prepared = nil
            initialLibrary = try await repository.snapshot()
        }

        var candidates: [Cipher] = []
        if let prepared { candidates.append(prepared.cipher) }
        candidates.append(contentsOf: initialLibrary.ciphers.filter { stored in
            stored.id != prepared?.cipher.id
        })

        // No cipher, contact, or relationship mutation occurs before AEAD.
        // Success with a key embedded by the same package proves integrity but
        // not sender identity, so that key remains transient until confirmed.
        let decoded = try messageService.read(
            envelope: payload.envelope,
            tryingCiphers: candidates
        )
        let requiresCipherConfirmation = prepared?.requiresPersistence == true
            && prepared?.cipher.id == decoded.cipher.id

        if !usesProgressionEvidence {
            return try await commitLegacyImport(
                payload: payload,
                receivedAt: receivedAt,
                decoded: decoded,
                initialLibrary: initialLibrary,
                runtimeIO: runtimeIO,
                requiresCipherConfirmation: requiresCipherConfirmation,
                presentation: presentation
            )
        }

        return try await commitProgressionImport(
            payload: payload,
            receivedAt: receivedAt,
            decoded: decoded,
            initialLibrary: initialLibrary,
            repository: repository,
            runtimeIO: runtimeIO,
            progression: progression,
            admittedPackageToken: admittedPackageToken,
            relationshipProgressionSeed: relationshipProgressionSeed,
            requiresCipherConfirmation: requiresCipherConfirmation,
            presentation: presentation
        )
    }

    private static func commitLegacyImport(
        payload: MessageSharePayload,
        receivedAt: Date,
        decoded: (plaintext: String, cipher: Cipher),
        initialLibrary: CipherLibrary,
        runtimeIO: RuntimeIOClient,
        requiresCipherConfirmation: Bool,
        presentation: SharePresentationIntake
    ) async throws -> MessageImportMutation {
        let durableCipher = decoded.cipher

        return MessageImportMutation(
            message: try await receivedMessage(
                payload: payload,
                receivedAt: receivedAt,
                decoded: decoded,
                cipher: durableCipher,
                runtimeIO: runtimeIO,
                senderIdentityStatus: requiresCipherConfirmation
                    ? .awaitingCipherConfirmation
                    : .trustedLocalCipher,
                presentation: presentation,
                encounterRecordingStatus: .unavailable
            ),
            library: initialLibrary,
            pendingEmbeddedCipher: requiresCipherConfirmation
                ? payload.embeddedCipher
                : nil
        )
    }

    private static func commitProgressionImport(
        payload: MessageSharePayload,
        receivedAt: Date,
        decoded: (plaintext: String, cipher: Cipher),
        initialLibrary: CipherLibrary,
        repository: CipherRepository,
        runtimeIO: RuntimeIOClient,
        progression: CoreProgressionCoordinator,
        admittedPackageToken: PackageToken?,
        relationshipProgressionSeed: Data?,
        requiresCipherConfirmation: Bool,
        presentation: SharePresentationIntake
    ) async throws -> MessageImportMutation {
        let canPersistDecodedCipher = !requiresCipherConfirmation
        var targetContactID = decoded.cipher.contactID

        var relationship: CoreRelationshipProgressionRecord? = if let targetContactID {
            try? await repository.relationshipProgressionEvidence(
                cipherID: decoded.cipher.id,
                contactID: targetContactID
            )
        } else {
            nil
        }
        var finalRelationshipSeed = relationship?.seed
        if finalRelationshipSeed == nil, targetContactID != nil {
            finalRelationshipSeed = relationshipProgressionSeed
        }
        if targetContactID != nil, finalRelationshipSeed == nil {
            // Do not make fresh relationship entropy a message-read
            // dependency. Existing contact metadata remains untouched.
            targetContactID = nil
            relationship = nil
        }

        let relationshipToken: RelationshipToken?
        if let finalRelationshipSeed {
            relationshipToken = try? await progression.relationshipToken(
                for: finalRelationshipSeed
            )
        } else {
            relationshipToken = nil
        }
        let establishesBidirectional = relationshipToken != nil
            && relationship?.hasEligibleOutbound == true
            && relationship?.bidirectionalEventCommitted == false

        var batches: [CorePendingProgressionBatch] = []
        if let admittedPackageToken {
            do {
                let context = try await progression.issueContext(
                    for: .coreReconciliation
                )
                let projection = SharePresentationProgressionProjection.inbound(
                    presentation
                )
                var facts = [try CoreProgressionFactFactory.messageDecoded(
                    packageToken: admittedPackageToken,
                    relationshipToken: relationshipToken,
                    codexIDs: projection.codexIDs,
                    artifactIDs: projection.artifactIDs,
                    provenanceStatus: projection.provenanceStatus
                )]
                facts.append(try CoreProgressionFactFactory.presentationObserved(
                    packageToken: admittedPackageToken,
                    codexIDs: projection.codexIDs,
                    artifactIDs: projection.artifactIDs,
                    provenanceStatus: projection.provenanceStatus
                ))
                if establishesBidirectional, let relationshipToken {
                    facts.append(try CoreProgressionFactFactory.bidirectionalEstablished(
                        relationshipToken: relationshipToken
                    ))
                }
                batches = try CoreProgressionCoordinator.pendingBatches(
                    context: context,
                    commandDigest: CoreProgressionCoordinator.commandDigest(facts),
                    facts: facts
                )
            } catch {
                // Optional fact construction never changes message utility or
                // a pre-existing local cipher relationship.
                batches = []
            }
        }

        guard canPersistDecodedCipher else {
            let retained = try? await repository.appendPendingProgressionBatches(
                batches
            )
            if retained != nil { _ = await progression.drain() }
            let encounterRecordingStatus: ShareEncounterRecordingStatus =
                presentation.metadata != nil && !batches.isEmpty && retained != nil
                    ? .recorded
                    : .unavailable
            return MessageImportMutation(
                message: try await receivedMessage(
                    payload: payload,
                    receivedAt: receivedAt,
                    decoded: decoded,
                    cipher: decoded.cipher,
                    runtimeIO: runtimeIO,
                    senderIdentityStatus: .awaitingCipherConfirmation,
                    presentation: presentation,
                    encounterRecordingStatus: encounterRecordingStatus
                ),
                library: retained?.library ?? initialLibrary,
                pendingEmbeddedCipher: payload.embeddedCipher
            )
        }

        let activity = CoreProgressionRelationshipActivity(
            authenticatedInbound: targetContactID != nil
                && relationshipToken != nil
                && !batches.isEmpty,
            bidirectionalCommitted: establishesBidirectional
                && !batches.isEmpty
        )
        let ingestion: MessageCipherIngestionResult
        do {
            ingestion = try await repository.commitAuthenticatedMessageImport(
                candidate: decoded.cipher,
                contactID: targetContactID,
                relationshipProgressionSeed: relationship == nil
                    ? finalRelationshipSeed
                    : nil,
                activity: activity,
                pendingBatches: batches
            )
        } catch let error as CoreProgressionEvidenceError {
            guard error == .collectionLimitExceeded else {
                throw error
            }
            // Seed/relationship capacity is optional. The authenticated
            // cipher/contact commit and its exact decoded fact group remain
            // atomic while every existing evidence row is preserved.
            ingestion = try await repository
                .commitAuthenticatedMessageImportWithoutProgressionEvidence(
                    candidate: decoded.cipher,
                    contactID: targetContactID,
                activity: activity,
                pendingBatches: batches
            )
        }

        let committedCipher: Cipher
        let committedLibrary: CipherLibrary
        switch ingestion {
        case .existing(let cipher, let library),
             .persisted(let cipher, let library):
            committedCipher = cipher
            committedLibrary = library
            _ = await progression.drain()
        case .transient(_, let failure):
            // The existing local cipher mutation failed durably; do not expose
            // a message whose relationship evidence was not committed.
            throw failure
        }

        return MessageImportMutation(
            message: try await receivedMessage(
                payload: payload,
                receivedAt: receivedAt,
                decoded: decoded,
                cipher: committedCipher,
                runtimeIO: runtimeIO,
                senderIdentityStatus: .trustedLocalCipher,
                presentation: presentation,
                encounterRecordingStatus: presentation.metadata != nil
                    && !batches.isEmpty
                    ? .recorded
                    : .unavailable
            ),
            library: committedLibrary,
            pendingEmbeddedCipher: nil
        )
    }

    private static func receivedMessage(
        payload: MessageSharePayload,
        receivedAt: Date,
        decoded: (plaintext: String, cipher: Cipher),
        cipher: Cipher,
        runtimeIO: RuntimeIOClient,
        senderIdentityStatus: ReceivedSenderIdentityStatusDTO,
        presentation: SharePresentationIntake,
        encounterRecordingStatus: ShareEncounterRecordingStatus
    ) async throws -> ReceivedMessageDTO {
        let receivedPresentation: ReceivedSharePresentation?
        if let metadata = presentation.metadata {
            receivedPresentation = try SharePresentationResolver.resolve(
                metadata: metadata,
                providerAvailability: metadata.selection.codexID
                    == RuneScribeCodexIDs.norse ? .available : .unknown,
                safePreviewStatus: presentation.safePreviewStatus,
                provenanceStatus: presentation.provenanceStatus,
                encounterRecordingStatus: encounterRecordingStatus
            )
        } else {
            receivedPresentation = nil
        }
        return try ReceivedMessageDTO(
            id: MessageID(rawValue: try await runtimeIO.nextUUID()),
            receivedAt: receivedAt,
            plaintext: decoded.plaintext,
            senderName: senderIdentityStatus == .awaitingCipherConfirmation
                ? payload.senderName
                : cipher.label,
            cipherID: CipherID(rawValue: cipher.id),
            cipherName: senderIdentityStatus == .awaitingCipherConfirmation
                ? "Unconfirmed cipher"
                : cipher.label,
            senderIdentityStatus: senderIdentityStatus,
            presentation: receivedPresentation,
            safePreviewData: presentation.safePreviewData
        )
    }
}
