/// Additive application-service surface for domain implementations that must
/// journal runtime-issued operation context with durable mutations. Existing
/// service fakes continue to conform only to `RuneScribeApplicationService`.
public protocol RuneScribeOperationAwareApplicationService:
    RuneScribeApplicationService
{
    func encode(
        _ command: EncodeMessageCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> EncodedMessageResult
    func decode(
        _ command: DecodeMessageCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> DecodedMessageResult

    func createCipher(
        _ command: CreateCipherCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> CipherSummary
    func renameCipher(
        _ command: RenameCipherCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> CipherSummary
    func deleteCipher(
        id: CipherID,
        context: RuntimePersistableOperationContext
    ) async throws
    func setActiveCipher(
        _ command: SetActiveCipherCommand,
        context: RuntimePersistableOperationContext
    ) async throws
    func assignContact(
        _ command: AssignContactCommand,
        context: RuntimePersistableOperationContext
    ) async throws

    func createContact(
        _ command: CreateContactCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ContactSummary
    func updateContact(
        _ command: UpdateContactCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ContactSummary
    func deleteContacts(
        ids: Set<ContactID>,
        context: RuntimePersistableOperationContext
    ) async throws
    func deleteAllImportedContacts(
        context: RuntimePersistableOperationContext
    ) async throws
    func importContacts(
        _ command: ImportContactsCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> [ContactSummary]
    func requestSystemContacts(
        context: RuntimePersistableOperationContext
    ) async throws -> [SystemContactDTO]

    func prepareCipherShare(
        _ command: PrepareCipherShareCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactDTO
    func prepareMessageShare(
        _ command: PrepareMessageShareCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactDTO
    func completeShareArtifact(
        _ command: CompleteShareArtifactCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactCompletionResultDTO
    func releaseShareArtifact(
        id: ShareArtifactID,
        context: RuntimePersistableOperationContext
    ) async

    func importFile(
        _ input: InboundFileDTO,
        context: RuntimePersistableOperationContext
    ) async throws -> ImportResultDTO
    func importURL(
        _ input: InboundURLDTO,
        context: RuntimePersistableOperationContext
    ) async throws -> ImportResultDTO
    func confirmImport(
        _ command: ConfirmImportCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> CipherSummary
    func cancelImport(
        id: ImportID,
        context: RuntimePersistableOperationContext
    ) async
    func dismissReceivedMessage(
        id: MessageID,
        context: RuntimePersistableOperationContext
    ) async

    func lock(context: RuntimePersistableOperationContext) async
    func verifyPIN(
        _ input: PINInput,
        context: RuntimePersistableOperationContext
    ) async throws -> Bool
    func unlock(
        _ command: UnlockCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> UnlockResultDTO
    func setPIN(
        _ command: SetPINCommand,
        context: RuntimePersistableOperationContext
    ) async throws
    func changePIN(
        _ command: ChangePINCommand,
        context: RuntimePersistableOperationContext
    ) async throws
    func disablePIN(
        _ command: DisablePINCommand,
        context: RuntimePersistableOperationContext
    ) async throws
}

public extension RuneScribeOperationAwareApplicationService {
    func encode(
        _ command: EncodeMessageCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> EncodedMessageResult { try await encode(command) }

    func decode(
        _ command: DecodeMessageCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> DecodedMessageResult { try await decode(command) }

    func createCipher(
        _ command: CreateCipherCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> CipherSummary { try await createCipher(command) }

    func renameCipher(
        _ command: RenameCipherCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> CipherSummary { try await renameCipher(command) }

    func deleteCipher(
        id: CipherID,
        context _: RuntimePersistableOperationContext
    ) async throws { try await deleteCipher(id: id) }

    func setActiveCipher(
        _ command: SetActiveCipherCommand,
        context _: RuntimePersistableOperationContext
    ) async throws { try await setActiveCipher(command) }

    func assignContact(
        _ command: AssignContactCommand,
        context _: RuntimePersistableOperationContext
    ) async throws { try await assignContact(command) }

    func createContact(
        _ command: CreateContactCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ContactSummary { try await createContact(command) }

    func updateContact(
        _ command: UpdateContactCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ContactSummary { try await updateContact(command) }

    func deleteContacts(
        ids: Set<ContactID>,
        context _: RuntimePersistableOperationContext
    ) async throws { try await deleteContacts(ids: ids) }

    func deleteAllImportedContacts(
        context _: RuntimePersistableOperationContext
    ) async throws { try await deleteAllImportedContacts() }

    func importContacts(
        _ command: ImportContactsCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> [ContactSummary] { try await importContacts(command) }

    func requestSystemContacts(
        context _: RuntimePersistableOperationContext
    ) async throws -> [SystemContactDTO] { try await requestSystemContacts() }

    func prepareCipherShare(
        _ command: PrepareCipherShareCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactDTO { try await prepareCipherShare(command) }

    func prepareMessageShare(
        _ command: PrepareMessageShareCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactDTO { try await prepareMessageShare(command) }

    func completeShareArtifact(
        _ command: CompleteShareArtifactCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactCompletionResultDTO {
        try await completeShareArtifact(command)
    }

    func releaseShareArtifact(
        id: ShareArtifactID,
        context _: RuntimePersistableOperationContext
    ) async { await releaseShareArtifact(id: id) }

    func importFile(
        _ input: InboundFileDTO,
        context _: RuntimePersistableOperationContext
    ) async throws -> ImportResultDTO { try await importFile(input) }

    func importURL(
        _ input: InboundURLDTO,
        context _: RuntimePersistableOperationContext
    ) async throws -> ImportResultDTO { try await importURL(input) }

    func confirmImport(
        _ command: ConfirmImportCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> CipherSummary { try await confirmImport(command) }

    func cancelImport(
        id: ImportID,
        context _: RuntimePersistableOperationContext
    ) async { await cancelImport(id: id) }

    func dismissReceivedMessage(
        id: MessageID,
        context _: RuntimePersistableOperationContext
    ) async { await dismissReceivedMessage(id: id) }

    func lock(context _: RuntimePersistableOperationContext) async { await lock() }

    func verifyPIN(
        _ input: PINInput,
        context _: RuntimePersistableOperationContext
    ) async throws -> Bool { try await verifyPIN(input) }

    func unlock(
        _ command: UnlockCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> UnlockResultDTO { try await unlock(command) }

    func setPIN(
        _ command: SetPINCommand,
        context _: RuntimePersistableOperationContext
    ) async throws { try await setPIN(command) }

    func changePIN(
        _ command: ChangePINCommand,
        context _: RuntimePersistableOperationContext
    ) async throws { try await changePIN(command) }

    func disablePIN(
        _ command: DisablePINCommand,
        context _: RuntimePersistableOperationContext
    ) async throws { try await disablePIN(command) }
}
