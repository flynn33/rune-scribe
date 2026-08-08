import Combine
import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime

/// Key-free view state used by the hosted SwiftUI screens during the module migration.
///
/// Migration owner: UIMigration. Removal phase: P5. New callers are prohibited; the
/// single UI module will observe `RuneScribeApplicationSnapshot` directly.
struct CipherViewState: Identifiable, Equatable, Sendable {
    let id: UUID
    let label: String
    let origin: CipherOriginDTO
    let createdAt: Date
    let isActive: Bool
    let contactID: UUID?
    let delivered: Bool
    let publicIdentifier: String
    let fontName: String

    var contractID: CipherID {
        CipherID(rawValue: id)
    }

    var shortPublicID: String {
        String(publicIdentifier.prefix(8))
    }
}

/// Temporary observation adapter from the key-free application service to the
/// existing hosted views. It owns no persistence, cryptography, payloads, or keys.
///
/// Migration owner: UIMigration. Removal phase: P5. This is the only permitted
/// adapter instance and must not become a second write path.
/// Architecture ratchet: temporary-application-session-adapter.
@MainActor
final class KeyManager: ObservableObject {
    @Published private(set) var snapshot: RuneScribeApplicationSnapshot?
    @Published private(set) var lastError: String?

    private let service: any RuneScribeApplicationService
    private let sharePresentation: OpaqueSharePresentationProvider
    private var stateTask: Task<Void, Never>?

    init(
        service: any RuneScribeApplicationService,
        sharePresentation: OpaqueSharePresentationProvider = .unavailable
    ) {
        self.service = service
        self.sharePresentation = sharePresentation
        stateTask = Task { [weak self, service] in
            for await state in service.stateStream() {
                guard !Task.isCancelled else { return }
                self?.snapshot = state
                self?.lastError = state.lastFailure.map(Self.message(for:))
            }
        }
    }

    var isLoading: Bool {
        snapshot?.cipherLibrary.isLoading ?? true
    }

    var ciphers: [CipherViewState] {
        guard let snapshot else { return [] }
        let fonts = Dictionary(uniqueKeysWithValues: snapshot.fonts.map { ($0.id, $0) })
        return snapshot.cipherLibrary.ciphers.map { summary in
            CipherViewState(
                id: summary.id.rawValue,
                label: summary.name,
                origin: summary.origin,
                createdAt: summary.createdAt,
                isActive: summary.isActive,
                contactID: summary.assignedContactID?.rawValue,
                delivered: summary.hasBeenDelivered,
                publicIdentifier: summary.publicIdentifier,
                fontName: fonts[summary.fontID]?.displayName ?? "Noto Sans Runic"
            )
        }
    }

    var activeCipher: CipherViewState? {
        ciphers.first(where: \.isActive)
    }

    var pendingImport: PendingImportSummary? {
        snapshot?.importState.pending
    }

    var pendingMessage: ReceivedMessageDTO? {
        snapshot?.messageState.pendingMessage
    }

    func ciphers(forContact contactID: UUID) -> [CipherViewState] {
        ciphers.filter { $0.contactID == contactID }
    }

    @discardableResult
    func addCipher(label: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await service.createCipher(CreateCipherCommand(name: label))
        }
        return viewState(for: summary)
    }

    @discardableResult
    func renameCipher(id: UUID, to label: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await service.renameCipher(
                RenameCipherCommand(cipherID: CipherID(rawValue: id), name: label)
            )
        }
        return viewState(for: summary)
    }

    func deleteCipher(id: UUID) async throws {
        try await perform {
            try await service.deleteCipher(id: CipherID(rawValue: id))
        }
    }

    func setActive(id: UUID) async throws {
        try await perform {
            try await service.setActiveCipher(
                SetActiveCipherCommand(cipherID: CipherID(rawValue: id))
            )
        }
    }

    func setContact(cipherID: UUID, contactID: UUID?) async throws {
        try await perform {
            try await service.assignContact(
                AssignContactCommand(
                    cipherID: CipherID(rawValue: cipherID),
                    contactID: contactID.map(ContactID.init(rawValue:))
                )
            )
        }
    }

    func encode(_ plaintext: String, cipherID: UUID?) async throws -> EncodedMessageResult {
        try await perform {
            try await service.encode(
                EncodeMessageCommand(
                    plaintext: plaintext,
                    cipherID: cipherID.map(CipherID.init(rawValue:))
                )
            )
        }
    }

    func decode(_ runes: String) async throws -> DecodedMessageResult {
        try await perform {
            try await service.decode(DecodeMessageCommand(runes: runes))
        }
    }

    func prepareCipherShare(
        cipherID: UUID,
        displayName: String?,
        representation: ShareRepresentationDTO
    ) async throws -> ShareArtifactDTO {
        try await perform {
            try await service.prepareCipherShare(
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
            try await service.prepareMessageShare(
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
            try await service.completeShareArtifact(
                CompleteShareArtifactCommand(artifactID: id, outcome: outcome)
            )
        }
    }

    func releaseShareArtifact(id: ShareArtifactID) async {
        await service.releaseShareArtifact(id: id)
    }

    func shareTransfer(for id: ShareArtifactID) async throws -> OpaqueShareTransfer {
        try await sharePresentation.transfer(for: id)
    }

    func importFile(
        _ url: URL,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool = false
    ) async throws -> ImportResultDTO {
        try await perform {
            try await service.importFile(
                InboundFileDTO(
                    metadata: inboundMetadata(source: source, isColdStart: isColdStart),
                    fileURL: url
                )
            )
        }
    }

    func importURL(
        _ url: URL,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool = false
    ) async throws -> ImportResultDTO {
        try await perform {
            try await service.importURL(
                InboundURLDTO(
                    metadata: inboundMetadata(source: source, isColdStart: isColdStart),
                    url: url
                )
            )
        }
    }

    @discardableResult
    func confirmImport(id: ImportID, name: String) async throws -> CipherViewState {
        let summary = try await perform {
            try await service.confirmImport(ConfirmImportCommand(importID: id, name: name))
        }
        return viewState(for: summary)
    }

    func cancelImport(id: ImportID) async {
        await service.cancelImport(id: id)
    }

    func dismissReceivedMessage(id: MessageID) async {
        await service.dismissReceivedMessage(id: id)
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

    private func viewState(for summary: CipherSummary) -> CipherViewState {
        if let current = ciphers.first(where: { $0.id == summary.id.rawValue }) {
            return current
        }
        let fontName = snapshot?.fonts.first(where: { $0.id == summary.fontID })?.displayName
            ?? "Noto Sans Runic"
        return CipherViewState(
            id: summary.id.rawValue,
            label: summary.name,
            origin: summary.origin,
            createdAt: summary.createdAt,
            isActive: summary.isActive,
            contactID: summary.assignedContactID?.rawValue,
            delivered: summary.hasBeenDelivered,
            publicIdentifier: summary.publicIdentifier,
            fontName: fontName
        )
    }

    private func perform<Result>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        do {
            let result = try await operation()
            lastError = nil
            return result
        } catch {
            lastError = Self.message(for: error)
            throw error
        }
    }

    private static func message(for error: Error) -> String {
        if let productError = error as? RuneScribeProductError,
           case .failure(let failure) = productError {
            return message(for: failure)
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func message(for failure: RuneScribeFailureDTO) -> String {
        switch failure.code {
        case .invalidInput: return "The information provided is not valid."
        case .itemNotFound: return "The requested item is no longer available."
        case .unsupportedFormat: return "This Rune Scribe format is not supported."
        case .corruptedContent: return "This Rune Scribe item is damaged or incomplete."
        case .noMatchingCipher: return "No cipher in your library can decode this message."
        case .authorizationDenied: return "Permission was not granted."
        case .authenticationFailed: return "Authentication failed."
        case .lockedOut: return "Try again later."
        case .secureStorageUnavailable: return "Secure storage is unavailable."
        case .protectedFileUnavailable: return "The protected file could not be opened."
        case .resourceUnavailable: return "A required app resource is unavailable."
        case .shareUnavailable: return "The item could not be prepared for sharing."
        case .operationCancelled: return "The operation was cancelled."
        case .temporarilyUnavailable: return "The operation is temporarily unavailable."
        case .internalFailure: return "Rune Scribe could not complete the operation."
        }
    }
}
