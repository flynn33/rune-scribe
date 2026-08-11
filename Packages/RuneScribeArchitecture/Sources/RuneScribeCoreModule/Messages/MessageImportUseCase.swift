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
        runtimeIO: RuntimeIOClient
    ) async throws -> MessageImportMutation {
        var transientCandidate: Cipher?
        var library: CipherLibrary

        if let embedded = payload.embeddedCipher {
            // Font installation on inbound messages remains best effort: inability
            // to render a custom face must never prevent authenticated decryption.
            if let fontIntegration {
                try? await fontIntegration.ensureAvailable(
                    reference: embedded.fontRef,
                    suppliedBytes: fontBytes
                )
            }
            switch try await repository.ingestMessageCipher(
                embedded,
                label: payload.senderName
            ) {
            case .existing(let cipher, let current), .persisted(let cipher, let current):
                transientCandidate = cipher
                library = current
            case .transient(let cipher, _):
                transientCandidate = cipher
                library = (try? await repository.snapshot()) ?? .empty
            }
        } else {
            library = try await repository.snapshot()
        }

        var candidates: [Cipher] = []
        if let transientCandidate {
            candidates.append(transientCandidate)
        }
        candidates.append(contentsOf: library.ciphers.filter { stored in
            stored.id != transientCandidate?.id
        })

        let decoded = try messageService.read(
            envelope: payload.envelope,
            tryingCiphers: candidates
        )

        if library.ciphers.contains(where: { $0.id == decoded.cipher.id }),
           let contactIntegration {
            let prepared = try await contactIntegration.prepareImportedContact(
                named: payload.senderName
            )
            if decoded.cipher.contactID != prepared.contact.id
                || prepared.requiresCommit {
                let intent = try await contactIntegration.stageMessageAssociation(
                    prepared,
                    cipherID: decoded.cipher.id,
                    previousContactID: decoded.cipher.contactID
                )
                let associated = try await repository.assignContact(
                   cipherID: decoded.cipher.id,
                   contactID: prepared.contact.id
                )
                guard associated.value else {
                    throw MessageImportError.cipherAssociationUnavailable
                }
                library = associated.library
                if prepared.requiresCommit {
                    _ = try await contactIntegration.commitPreparedImportedContact(prepared)
                }
                try await contactIntegration.completeMessageAssociation(intent)
            }
        }

        return MessageImportMutation(
            message: ReceivedMessageDTO(
                id: MessageID(rawValue: try await runtimeIO.nextUUID()),
                plaintext: decoded.plaintext,
                senderName: payload.senderName,
                cipherID: CipherID(rawValue: decoded.cipher.id),
                cipherName: decoded.cipher.label
            ),
            library: library
        )
    }
}
