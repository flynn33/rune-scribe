import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

extension RuneScribeUISession {
    @discardableResult
    func addCipher(label: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await requireApplicationClient().createCipher(CreateCipherCommand(name: label))
        }
        return viewState(for: summary)
    }

    @discardableResult
    func renameCipher(id: UUID, to label: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await requireApplicationClient().renameCipher(
                RenameCipherCommand(cipherID: CipherID(rawValue: id), name: label)
            )
        }
        return viewState(for: summary)
    }

    func deleteCipher(id: UUID) async throws {
        return try await perform {
            try await requireApplicationClient().deleteCipher(id: CipherID(rawValue: id))
        }
    }

    func setActive(id: UUID) async throws {
        return try await perform {
            try await requireApplicationClient().setActiveCipher(
                SetActiveCipherCommand(cipherID: CipherID(rawValue: id))
            )
        }
    }

    func setContact(cipherID: UUID, contactID: UUID?) async throws {
        try await perform {
            try await requireApplicationClient().assignContact(
                AssignContactCommand(
                    cipherID: CipherID(rawValue: cipherID),
                    contactID: contactID.map(ContactID.init(rawValue:))
                )
            )
        }
    }

    func encode(_ plaintext: String, cipherID: UUID?) async throws -> EncodedMessageResult {
        try await perform {
            try await requireApplicationClient().encode(
                EncodeMessageCommand(
                    plaintext: plaintext,
                    cipherID: cipherID.map(CipherID.init(rawValue:))
                )
            )
        }
    }

    func decode(_ runes: String) async throws -> DecodedMessageResult {
        try await perform {
            try await requireApplicationClient().decode(DecodeMessageCommand(runes: runes))
        }
    }

    func prepareCipherShare(
        cipherID: UUID,
        displayName: String?,
        representation: ShareRepresentationDTO
    ) async throws -> ShareArtifactDTO {
        let presentationPreparation: OutboundSharePresentationPreparation
        if representation == .file {
            presentationPreparation = await makeOutboundSharePresentationWithLegacyFallback(
                inscription: displayName ?? "Rune Scribe cipher invitation",
                accessibilityLabel: "Rune Scribe themed cipher invitation"
            )
        } else {
            presentationPreparation = OutboundSharePresentationPreparation(
                presentation: nil,
                status: .idle
            )
        }
        let artifact = try await perform {
            try await requireApplicationClient().prepareCipherShare(
                PrepareCipherShareCommand(
                    cipherID: CipherID(rawValue: cipherID),
                    displayName: displayName,
                    representation: representation,
                    presentation: presentationPreparation.presentation
                )
            )
        }
        recordOutboundSharePresentationStatus(presentationPreparation.status)
        return artifact
    }

    func prepareMessageShare(
        runes: String,
        senderName: String,
        cipherID: UUID,
        shareHandle: EncodedMessageHandle
    ) async throws -> ShareArtifactDTO {
        let presentationPreparation = await makeOutboundSharePresentationWithLegacyFallback(
            inscription: runes,
            accessibilityLabel: "Rune Scribe themed encrypted message"
        )
        let artifact = try await perform {
            try await requireApplicationClient().prepareMessageShare(
                PrepareMessageShareCommand(
                    runes: runes,
                    senderName: senderName,
                    cipherID: CipherID(rawValue: cipherID),
                    shareHandle: shareHandle,
                    presentation: presentationPreparation.presentation
                )
            )
        }
        recordOutboundSharePresentationStatus(presentationPreparation.status)
        return artifact
    }

    func completeShareArtifact(
        evidence: ShareArtifactCompletionEvidenceDTO
    ) async throws -> ShareArtifactCompletionResultDTO {
        try await perform {
            try await requireApplicationClient().completeShareArtifact(
                CompleteShareArtifactCommand(evidence: evidence)
            )
        }
    }

    func releaseShareArtifact(id: ShareArtifactID) async {
        guard let client = try? requireApplicationClient() else { return }
        try? await client.releaseShareArtifact(id: id)
    }

    func shareTransfer(for id: ShareArtifactID) async throws -> OpaqueShareTransfer {
        let runtimeIO = try requireRuntimeIOClient()
        let presentationSession = try await runtimeIO.sharePresentationSession(
            artifactID: id
        )
        return try await OpaqueShareTransfer.open(
            artifactID: id,
            session: presentationSession
        )
    }

    func textShareTransfer(
        _ text: String,
        artifactID: ShareArtifactID
    ) async throws -> OpaqueShareTransfer {
        let runtimeIO = try requireRuntimeIOClient()
        let presentationSession = try await runtimeIO.textSharePresentationSession(
            text,
            artifactID: artifactID
        )
        return try await OpaqueShareTransfer.open(
            artifactID: artifactID,
            session: presentationSession
        )
    }

    func importURL(
        _ url: URL,
        source: InboundDeliverySourceDTO = .qrScanner,
        isColdStart: Bool = false
    ) async throws -> ImportResultDTO {
        try await perform {
            try await requireApplicationClient().importURL(
                InboundURLDTO(
                    metadata: inboundMetadata(source: source, isColdStart: isColdStart),
                    url: url
                )
            )
        }
    }

    func ingest(
        url: URL,
        source: InboundDeliverySourceDTO = .qrScanner,
        isColdStart: Bool = false
    ) async {
        do {
            _ = try await importURL(url, source: source, isColdStart: isColdStart)
            importErrorMessage = nil
        } catch {
            importErrorMessage = lastError ?? "This isn't a valid Rune Scribe cipher link."
        }
    }

    func ingest(
        urlString: String,
        source: InboundDeliverySourceDTO = .clipboard
    ) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { return }
        await ingest(url: url, source: source)
    }

    @discardableResult
    func confirmImport(id: ImportID, name: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await requireApplicationClient().confirmImport(
                ConfirmImportCommand(importID: id, name: name)
            )
        }
        return viewState(for: summary)
    }

    @discardableResult
    func confirmImport(name: String) async throws -> CipherViewState {
        guard let pendingImport else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .itemNotFound)
            )
        }
        return try await confirmImport(id: pendingImport.id, name: name)
    }

    func cancelImport(id: ImportID) async {
        guard let client = try? requireApplicationClient() else { return }
        try? await client.cancelImport(id: id)
    }

    func cancelPendingImport() {
        guard let id = pendingImport?.id else { return }
        Task { @MainActor [weak self] in
            await self?.cancelImport(id: id)
        }
    }

    func dismissReceivedMessage(id: MessageID) async {
        guard let client = try? requireApplicationClient() else { return }
        try? await client.dismissReceivedMessage(id: id)
    }

    func dismissPendingMessage() {
        guard let id = pendingMessage?.id else { return }
        Task { @MainActor [weak self] in
            await self?.dismissReceivedMessage(id: id)
        }
    }

    private func inboundMetadata(
        source: InboundDeliverySourceDTO,
        isColdStart: Bool
    ) -> InboundInputMetadataDTO {
        InboundInputMetadataDTO(
            id: InboundInputID(rawValue: UUID()),
            receivedAt: Date(),
            source: source,
            isColdStart: isColdStart
        )
    }
}
