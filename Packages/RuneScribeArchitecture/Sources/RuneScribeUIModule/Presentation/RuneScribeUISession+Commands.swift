import Foundation
import RuneScribeContracts

extension RuneScribeUISession {
    @discardableResult
    func addCipher(label: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await requireApplicationService().createCipher(CreateCipherCommand(name: label))
        }
        return viewState(for: summary)
    }

    @discardableResult
    func renameCipher(id: UUID, to label: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await requireApplicationService().renameCipher(
                RenameCipherCommand(cipherID: CipherID(rawValue: id), name: label)
            )
        }
        return viewState(for: summary)
    }

    func deleteCipher(id: UUID) async throws {
        try await perform {
            try await requireApplicationService().deleteCipher(id: CipherID(rawValue: id))
        }
    }

    func setActive(id: UUID) async throws {
        try await perform {
            try await requireApplicationService().setActiveCipher(
                SetActiveCipherCommand(cipherID: CipherID(rawValue: id))
            )
        }
    }

    func setContact(cipherID: UUID, contactID: UUID?) async throws {
        try await perform {
            try await requireApplicationService().assignContact(
                AssignContactCommand(
                    cipherID: CipherID(rawValue: cipherID),
                    contactID: contactID.map(ContactID.init(rawValue:))
                )
            )
        }
    }

    func encode(_ plaintext: String, cipherID: UUID?) async throws -> EncodedMessageResult {
        try await perform {
            try await requireApplicationService().encode(
                EncodeMessageCommand(
                    plaintext: plaintext,
                    cipherID: cipherID.map(CipherID.init(rawValue:))
                )
            )
        }
    }

    func decode(_ runes: String) async throws -> DecodedMessageResult {
        try await perform {
            try await requireApplicationService().decode(DecodeMessageCommand(runes: runes))
        }
    }

    func prepareCipherShare(
        cipherID: UUID,
        displayName: String?,
        representation: ShareRepresentationDTO
    ) async throws -> ShareArtifactDTO {
        try await perform {
            try await requireApplicationService().prepareCipherShare(
                PrepareCipherShareCommand(
                    cipherID: CipherID(rawValue: cipherID),
                    displayName: displayName,
                    representation: representation
                )
            )
        }
    }

    func prepareMessageShare(
        runes: String,
        senderName: String,
        cipherID: UUID
    ) async throws -> ShareArtifactDTO {
        try await perform {
            try await requireApplicationService().prepareMessageShare(
                PrepareMessageShareCommand(
                    runes: runes,
                    senderName: senderName,
                    cipherID: CipherID(rawValue: cipherID)
                )
            )
        }
    }

    func completeShareArtifact(
        id: ShareArtifactID,
        outcome: ShareArtifactOutcomeDTO
    ) async throws -> ShareArtifactCompletionResultDTO {
        try await perform {
            try await requireApplicationService().completeShareArtifact(
                CompleteShareArtifactCommand(artifactID: id, outcome: outcome)
            )
        }
    }

    func releaseShareArtifact(id: ShareArtifactID) async {
        guard let service = try? requireApplicationService() else { return }
        await service.releaseShareArtifact(id: id)
    }

    func shareTransfer(for id: ShareArtifactID) async throws -> OpaqueShareTransfer {
        try await requireSharePresentation().transfer(for: id)
    }

    func importFile(
        _ url: URL,
        source: InboundDeliverySourceDTO = .fileImporter,
        isColdStart: Bool = false
    ) async throws -> ImportResultDTO {
        try await perform {
            try await requireApplicationService().importFile(
                InboundFileDTO(
                    metadata: inboundMetadata(source: source, isColdStart: isColdStart),
                    fileURL: url
                )
            )
        }
    }

    func importURL(
        _ url: URL,
        source: InboundDeliverySourceDTO = .qrScanner,
        isColdStart: Bool = false
    ) async throws -> ImportResultDTO {
        try await perform {
            try await requireApplicationService().importURL(
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
        fileURL: URL,
        source: InboundDeliverySourceDTO = .fileImporter,
        isColdStart: Bool = false
    ) async {
        do {
            _ = try await importFile(fileURL, source: source, isColdStart: isColdStart)
            importErrorMessage = nil
        } catch {
            importErrorMessage = lastError ?? "This isn't a valid Rune Scribe cipher file."
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
            try await requireApplicationService().confirmImport(
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
        guard let service = try? requireApplicationService() else { return }
        await service.cancelImport(id: id)
    }

    func cancelPendingImport() {
        guard let id = pendingImport?.id else { return }
        Task { @MainActor [weak self] in
            await self?.cancelImport(id: id)
        }
    }

    func dismissReceivedMessage(id: MessageID) async {
        guard let service = try? requireApplicationService() else { return }
        await service.dismissReceivedMessage(id: id)
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
