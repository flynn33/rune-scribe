import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

struct MessageImportMutation: Sendable {
    let message: ReceivedMessageDTO
    let library: CipherLibrary
}

enum MessageImportError: Error, Equatable, Sendable {
    case cipherAssociationUnavailable
}

enum MessageImportUseCase {
    static func ingest(
        payload: MessageSharePayload,
        fontBytes: Data?,
        repository: CipherRepository,
        messageService: MessageService,
        fontIntegration: (any CoreFontIntegrating)?,
        contactIntegration: (any CoreMessageContactAssociating)?,
        runtimeIO: RuntimeIOClient,
        progression: CoreProgressionCoordinator,
        usesProgressionEvidence: Bool,
        admittedPackageToken: PackageToken?,
        progressionRoute: DomainEventRouteClass,
        embeddedCipherProgressionSeed: Data?,
        relationshipProgressionSeed: Data?,
        presentation: SharePresentationIntake = .absent
    ) async throws -> MessageImportMutation {
        let prepared: PreparedMessageCipher?
        let initialLibrary: CipherLibrary
        if let embedded = payload.embeddedCipher {
            // Rendering compatibility remains best effort and is unrelated to
            // whether the authenticated envelope can be opened.
            if let fontIntegration {
                try? await fontIntegration.ensureAvailable(
                    reference: embedded.fontRef,
                    suppliedBytes: fontBytes
                )
            }
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

        // No cipher, contact, or relationship mutation occurs before this
        // authentication boundary.
        let decoded = try messageService.read(
            envelope: payload.envelope,
            tryingCiphers: candidates
        )

        if !usesProgressionEvidence {
            return try await commitLegacyImport(
                payload: payload,
                prepared: prepared,
                decoded: decoded,
                initialLibrary: initialLibrary,
                repository: repository,
                contactIntegration: contactIntegration,
                runtimeIO: runtimeIO,
                presentation: presentation
            )
        }

        return try await commitProgressionImport(
            payload: payload,
            prepared: prepared,
            decoded: decoded,
            initialLibrary: initialLibrary,
            repository: repository,
            contactIntegration: contactIntegration,
            runtimeIO: runtimeIO,
            progression: progression,
            admittedPackageToken: admittedPackageToken,
            progressionRoute: progressionRoute,
            embeddedCipherProgressionSeed: embeddedCipherProgressionSeed,
            relationshipProgressionSeed: relationshipProgressionSeed,
            presentation: presentation
        )
    }

    private static func commitLegacyImport(
        payload: MessageSharePayload,
        prepared: PreparedMessageCipher?,
        decoded: (plaintext: String, cipher: Cipher),
        initialLibrary: CipherLibrary,
        repository: CipherRepository,
        contactIntegration: (any CoreMessageContactAssociating)?,
        runtimeIO: RuntimeIOClient,
        presentation: SharePresentationIntake
    ) async throws -> MessageImportMutation {
        var durableCipher = decoded.cipher
        var library = initialLibrary
        if let embedded = payload.embeddedCipher,
           prepared?.cipher.id == decoded.cipher.id {
            let ingestion = try await repository.ingestMessageCipher(
                embedded,
                label: payload.senderName
            )
            switch ingestion {
            case .existing(let cipher, let current),
                 .persisted(let cipher, let current):
                durableCipher = cipher
                library = current
            case .transient(let cipher, _):
                durableCipher = cipher
            }
        }

        if library.ciphers.contains(where: { $0.id == durableCipher.id }),
           let contactIntegration {
            let preparedContact = try await contactIntegration.prepareImportedContact(
                named: payload.senderName
            )
            if durableCipher.contactID != preparedContact.contact.id
                || preparedContact.requiresCommit {
                let intent = try await contactIntegration.stageMessageAssociation(
                    preparedContact,
                    cipherID: durableCipher.id,
                    previousContactID: durableCipher.contactID
                )
                let associated = try await repository.assignContact(
                    cipherID: durableCipher.id,
                    contactID: preparedContact.contact.id
                )
                guard associated.value else {
                    throw MessageImportError.cipherAssociationUnavailable
                }
                library = associated.library
                if preparedContact.requiresCommit {
                    _ = try await contactIntegration.commitPreparedImportedContact(
                        preparedContact
                    )
                }
                try await contactIntegration.completeMessageAssociation(intent)
            }
        }

        return MessageImportMutation(
            message: try await receivedMessage(
                payload: payload,
                decoded: decoded,
                cipher: durableCipher,
                runtimeIO: runtimeIO,
                presentation: presentation,
                encounterRecordingStatus: .unavailable
            ),
            library: library
        )
    }

    private static func commitProgressionImport(
        payload: MessageSharePayload,
        prepared: PreparedMessageCipher?,
        decoded: (plaintext: String, cipher: Cipher),
        initialLibrary: CipherLibrary,
        repository: CipherRepository,
        contactIntegration: (any CoreMessageContactAssociating)?,
        runtimeIO: RuntimeIOClient,
        progression: CoreProgressionCoordinator,
        admittedPackageToken: PackageToken?,
        progressionRoute: DomainEventRouteClass,
        embeddedCipherProgressionSeed: Data?,
        relationshipProgressionSeed: Data?,
        presentation: SharePresentationIntake
    ) async throws -> MessageImportMutation {
        let persistsPreparedCipher = prepared?.requiresPersistence == true
            && prepared?.cipher.id == decoded.cipher.id
        let canPersistDecodedCipher = !persistsPreparedCipher
            || embeddedCipherProgressionSeed != nil

        var preparedContact: PreparedMessageContact?
        var targetContactID = decoded.cipher.contactID
        if canPersistDecodedCipher, let contactIntegration {
            let candidate = try await contactIntegration.prepareImportedContact(
                named: payload.senderName
            )
            let existing = try? await repository.relationshipProgressionEvidence(
                cipherID: decoded.cipher.id,
                contactID: candidate.contact.id
            )
            if existing != nil || relationshipProgressionSeed != nil {
                preparedContact = candidate
                targetContactID = candidate.contact.id
            }
        }

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
            preparedContact = nil
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
                if persistsPreparedCipher,
                   let embeddedCipherProgressionSeed,
                   let cipherToken = try? await progression.cipherToken(
                       for: embeddedCipherProgressionSeed
                   ), let imported = try? CoreProgressionFactFactory.cipherImported(
                       cipherToken: cipherToken,
                       routeClass: progressionRoute
                   ) {
                    facts.append(imported)
                }
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
                // Optional fact construction never changes authenticated
                // message utility or its durable cipher/contact association.
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
                    decoded: decoded,
                    cipher: decoded.cipher,
                    runtimeIO: runtimeIO,
                    presentation: presentation,
                    encounterRecordingStatus: encounterRecordingStatus
                ),
                library: retained?.library ?? initialLibrary
            )
        }

        let needsContactCommit = preparedContact.map {
            decoded.cipher.contactID != $0.contact.id || $0.requiresCommit
        } ?? false
        var associationIntent: MessageContactAssociationIntent?
        if needsContactCommit, let preparedContact, let contactIntegration {
            associationIntent = try await contactIntegration.stageMessageAssociation(
                preparedContact,
                cipherID: decoded.cipher.id,
                previousContactID: decoded.cipher.contactID
            )
            // The recovery intent makes this ordering safe: Core facts cannot
            // claim a linked relationship unless the contact already exists.
            if preparedContact.requiresCommit {
                _ = try await contactIntegration.commitPreparedImportedContact(
                    preparedContact
                )
            }
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
                persistCandidate: persistsPreparedCipher,
                contactID: targetContactID,
                cipherProgressionSeed: embeddedCipherProgressionSeed,
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
                persistCandidate: persistsPreparedCipher,
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
            if preparedContact != nil, let contactIntegration, needsContactCommit {
                if let associationIntent {
                    try await contactIntegration.completeMessageAssociation(
                        associationIntent
                    )
                }
            }
            _ = await progression.drain()
        case .transient(_, let failure):
            // The staged recovery intent remains authoritative. AppService
            // removes any just-created contact and restores the prior cipher
            // binding before it reports the failed durable mutation.
            throw failure
        }

        return MessageImportMutation(
            message: try await receivedMessage(
                payload: payload,
                decoded: decoded,
                cipher: committedCipher,
                runtimeIO: runtimeIO,
                presentation: presentation,
                encounterRecordingStatus: presentation.metadata != nil
                    && !batches.isEmpty
                    ? .recorded
                    : .unavailable
            ),
            library: committedLibrary
        )
    }

    private static func receivedMessage(
        payload: MessageSharePayload,
        decoded: (plaintext: String, cipher: Cipher),
        cipher: Cipher,
        runtimeIO: RuntimeIOClient,
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
            plaintext: decoded.plaintext,
            senderName: payload.senderName,
            cipherID: CipherID(rawValue: cipher.id),
            cipherName: cipher.label,
            presentation: receivedPresentation,
            safePreviewData: presentation.safePreviewData
        )
    }
}
