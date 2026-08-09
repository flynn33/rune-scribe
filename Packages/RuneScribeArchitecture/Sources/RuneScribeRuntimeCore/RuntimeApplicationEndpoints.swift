import Foundation
import RuneScribeContracts

public struct RuntimeEmptyPayload: Hashable, Sendable {
    public init() {}
}

public enum RuntimeApplicationEndpointCatalog {
    private static let coreDestination = RuntimeEndpointDestination.role(RuneScribeRoles.core)
    private static let version = RuntimeSchemaVersions.v1
    private static let requestLimit: UInt64 = 16 * 1_024 * 1_024
    private static let responseLimit: UInt64 = 16 * 1_024 * 1_024

    private static func endpoint<Request: Sendable, Response: Sendable>(
        _ id: RuntimeEndpointIdentifier,
        kind: RuntimeEndpointKind = .command,
        capability: CapabilityIdentifier = RuneScribeCapabilities.applicationCommands,
        privacyClass: RuntimePrivacyClass = .sensitiveRedacted
    ) -> RuntimeEndpointKey<Request, Response> {
        RuntimeEndpointDescriptor(
            endpointID: id,
            kind: kind,
            destination: coreDestination,
            requestSchemaVersion: version,
            responseSchemaVersion: version,
            requiredCapability: capability,
            privacyClass: privacyClass,
            maximumRequestBytes: requestLimit,
            maximumResponseBytes: responseLimit
        ).key
    }

    private static func state<State: Sendable>(
        _ id: RuntimeEndpointIdentifier
    ) -> RuntimeStateEndpointDescriptor<State> {
        RuntimeStateEndpointDescriptor(
            endpointID: id,
            destination: coreDestination,
            subscriptionSchemaVersion: version,
            stateSchemaVersion: version,
            requiredCapability: RuneScribeCapabilities.applicationStateRead,
            privacyClass: .sensitiveRedacted,
            maximumSubscriptionBytes: 0,
            maximumStateBytes: responseLimit
        )
    }

    public static let applicationState: RuntimeStateEndpointDescriptor<RuneScribeApplicationSnapshot> =
        state("application.state")
    public static let menuCommands: RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO> =
        state("application.menu-commands")
    public static let encode: RuntimeEndpointKey<EncodeMessageCommand, EncodedMessageResult> =
        endpoint("application.encode")
    public static let decode: RuntimeEndpointKey<DecodeMessageCommand, DecodedMessageResult> =
        endpoint("application.decode")
    public static let createCipher: RuntimeEndpointKey<CreateCipherCommand, CipherSummary> =
        endpoint("application.cipher.create")
    public static let renameCipher: RuntimeEndpointKey<RenameCipherCommand, CipherSummary> =
        endpoint("application.cipher.rename")
    public static let deleteCipher: RuntimeEndpointKey<CipherID, RuntimeEmptyPayload> =
        endpoint("application.cipher.delete")
    public static let setActiveCipher: RuntimeEndpointKey<SetActiveCipherCommand, RuntimeEmptyPayload> =
        endpoint("application.cipher.set-active")
    public static let assignContact: RuntimeEndpointKey<AssignContactCommand, RuntimeEmptyPayload> =
        endpoint("application.cipher.assign-contact")
    public static let createContact: RuntimeEndpointKey<CreateContactCommand, ContactSummary> =
        endpoint("application.contact.create")
    public static let updateContact: RuntimeEndpointKey<UpdateContactCommand, ContactSummary> =
        endpoint("application.contact.update")
    public static let deleteContacts: RuntimeEndpointKey<Set<ContactID>, RuntimeEmptyPayload> =
        endpoint("application.contact.delete")
    public static let deleteAllImportedContacts: RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload> =
        endpoint("application.contact.delete-imported")
    public static let importContacts: RuntimeEndpointKey<ImportContactsCommand, [ContactSummary]> =
        endpoint("application.contact.import")
    public static let requestSystemContacts: RuntimeEndpointKey<RuntimeEmptyPayload, [SystemContactDTO]> =
        endpoint("application.contact.system", kind: .query)
    public static let prepareCipherShare: RuntimeEndpointKey<PrepareCipherShareCommand, ShareArtifactDTO> =
        endpoint("application.share.cipher.prepare")
    public static let prepareMessageShare: RuntimeEndpointKey<PrepareMessageShareCommand, ShareArtifactDTO> =
        endpoint("application.share.message.prepare")
    public static let completeShareArtifact: RuntimeEndpointKey<CompleteShareArtifactCommand, ShareArtifactCompletionResultDTO> =
        endpoint("application.share.complete")
    public static let releaseShareArtifact: RuntimeEndpointKey<ShareArtifactID, RuntimeEmptyPayload> =
        endpoint("application.share.release")
    public static let importFile: RuntimeEndpointKey<InboundFileDTO, ImportResultDTO> =
        endpoint("application.import.file")
    public static let importURL: RuntimeEndpointKey<InboundURLDTO, ImportResultDTO> =
        endpoint("application.import.url")
    public static let confirmImport: RuntimeEndpointKey<ConfirmImportCommand, CipherSummary> =
        endpoint("application.import.confirm")
    public static let cancelImport: RuntimeEndpointKey<ImportID, RuntimeEmptyPayload> =
        endpoint("application.import.cancel")
    public static let dismissReceivedMessage: RuntimeEndpointKey<MessageID, RuntimeEmptyPayload> =
        endpoint("application.message.dismiss")
    public static let lock: RuntimeEndpointKey<RuntimeEmptyPayload, RuntimeEmptyPayload> =
        endpoint("application.lock")
    public static let verifyPIN: RuntimeEndpointKey<PINInput, Bool> =
        endpoint("application.pin.verify")
    public static let unlock: RuntimeEndpointKey<UnlockCommand, UnlockResultDTO> =
        endpoint("application.unlock")
    public static let setPIN: RuntimeEndpointKey<SetPINCommand, RuntimeEmptyPayload> =
        endpoint("application.pin.set")
    public static let changePIN: RuntimeEndpointKey<ChangePINCommand, RuntimeEmptyPayload> =
        endpoint("application.pin.change")
    public static let disablePIN: RuntimeEndpointKey<DisablePINCommand, RuntimeEmptyPayload> =
        endpoint("application.pin.disable")
    public static let inboundInput: RuntimeEndpointKey<RuneScribeInboundInput, InboundInputDispositionDTO> =
        endpoint(
            "application.ingress.input",
            kind: .ingress,
            capability: RuneScribeCapabilities.inboundInput
        )

    public static let applicationEndpointIDs: Set<RuntimeEndpointIdentifier> = [
        applicationState.endpointID, menuCommands.endpointID, encode.descriptor.endpointID,
        decode.descriptor.endpointID, createCipher.descriptor.endpointID,
        renameCipher.descriptor.endpointID, deleteCipher.descriptor.endpointID,
        setActiveCipher.descriptor.endpointID, assignContact.descriptor.endpointID,
        createContact.descriptor.endpointID, updateContact.descriptor.endpointID,
        deleteContacts.descriptor.endpointID, deleteAllImportedContacts.descriptor.endpointID,
        importContacts.descriptor.endpointID, requestSystemContacts.descriptor.endpointID,
        prepareCipherShare.descriptor.endpointID, prepareMessageShare.descriptor.endpointID,
        completeShareArtifact.descriptor.endpointID, releaseShareArtifact.descriptor.endpointID,
        importFile.descriptor.endpointID, importURL.descriptor.endpointID,
        confirmImport.descriptor.endpointID, cancelImport.descriptor.endpointID,
        dismissReceivedMessage.descriptor.endpointID, lock.descriptor.endpointID,
        verifyPIN.descriptor.endpointID, unlock.descriptor.endpointID,
        setPIN.descriptor.endpointID, changePIN.descriptor.endpointID,
        disablePIN.descriptor.endpointID,
    ]

    public static let ingressEndpointIDs: Set<RuntimeEndpointIdentifier> = [
        inboundInput.descriptor.endpointID
    ]

    static func consumedEndpointIDs(
        for services: Set<ServiceIdentifier>
    ) -> Set<RuntimeEndpointIdentifier> {
        var result: Set<RuntimeEndpointIdentifier> = []
        if services.contains(RuneScribeServiceIDs.application) {
            result.formUnion(applicationEndpointIDs)
        }
        if services.contains(RuneScribeServiceIDs.inboundInput) {
            result.formUnion(ingressEndpointIDs)
        }
        return result
    }

    static func publishedEndpointIDs(
        for services: Set<ServiceIdentifier>
    ) -> Set<RuntimeEndpointIdentifier> {
        consumedEndpointIDs(for: services)
    }
}

public extension ModuleContext {
    func registerApplicationEndpoints(_ service: any RuneScribeApplicationService) async throws {
        func register<Request: Sendable, Response: Sendable>(
            _ key: RuntimeEndpointKey<Request, Response>,
            _ handler: @escaping @Sendable (Request) async throws -> Response
        ) async throws {
            try await registerEndpoint(
                key,
                handler: { _, request in try await handler(request) }
            )
        }

        try await registerStateEndpoint(
            RuntimeApplicationEndpointCatalog.applicationState,
            handler: { _ in service.stateStream() }
        )
        try await registerStateEndpoint(
            RuntimeApplicationEndpointCatalog.menuCommands,
            handler: { _ in service.menuCommandStream() }
        )
        try await register(RuntimeApplicationEndpointCatalog.encode, service.encode)
        try await register(RuntimeApplicationEndpointCatalog.decode, service.decode)
        try await register(RuntimeApplicationEndpointCatalog.createCipher, service.createCipher)
        try await register(RuntimeApplicationEndpointCatalog.renameCipher, service.renameCipher)
        try await register(RuntimeApplicationEndpointCatalog.deleteCipher) { id in
            try await service.deleteCipher(id: id); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.setActiveCipher) { command in
            try await service.setActiveCipher(command); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.assignContact) { command in
            try await service.assignContact(command); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.createContact, service.createContact)
        try await register(RuntimeApplicationEndpointCatalog.updateContact, service.updateContact)
        try await register(RuntimeApplicationEndpointCatalog.deleteContacts) { ids in
            try await service.deleteContacts(ids: ids); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.deleteAllImportedContacts) { _ in
            try await service.deleteAllImportedContacts(); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.importContacts, service.importContacts)
        try await register(RuntimeApplicationEndpointCatalog.requestSystemContacts) { _ in
            try await service.requestSystemContacts()
        }
        try await register(RuntimeApplicationEndpointCatalog.prepareCipherShare, service.prepareCipherShare)
        try await register(RuntimeApplicationEndpointCatalog.prepareMessageShare, service.prepareMessageShare)
        try await register(RuntimeApplicationEndpointCatalog.completeShareArtifact, service.completeShareArtifact)
        try await register(RuntimeApplicationEndpointCatalog.releaseShareArtifact) { id in
            await service.releaseShareArtifact(id: id); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.importFile, service.importFile)
        try await register(RuntimeApplicationEndpointCatalog.importURL, service.importURL)
        try await register(RuntimeApplicationEndpointCatalog.confirmImport, service.confirmImport)
        try await register(RuntimeApplicationEndpointCatalog.cancelImport) { id in
            await service.cancelImport(id: id); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.dismissReceivedMessage) { id in
            await service.dismissReceivedMessage(id: id); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.lock) { _ in
            await service.lock(); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.verifyPIN, service.verifyPIN)
        try await register(RuntimeApplicationEndpointCatalog.unlock, service.unlock)
        try await register(RuntimeApplicationEndpointCatalog.setPIN) { command in
            try await service.setPIN(command); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.changePIN) { command in
            try await service.changePIN(command); return RuntimeEmptyPayload()
        }
        try await register(RuntimeApplicationEndpointCatalog.disablePIN) { command in
            try await service.disablePIN(command); return RuntimeEmptyPayload()
        }
    }

    func registerInboundInputEndpoint(_ service: any RuneScribeInboundInputService) async throws {
        try await registerEndpoint(
            RuntimeApplicationEndpointCatalog.inboundInput,
            handler: { _, input in try await service.receive(input) }
        )
    }

    func applicationServiceClient() async throws -> any RuneScribeApplicationService {
        let destination: RuntimeEndpointDestination = .role(RuneScribeRoles.core)
        let command = try await commandClient(to: destination)
        let query = try await queryClient(to: destination)
        let state = try await stateClient(to: destination)
        let applicationState = try await state.subscribe(
            to: RuntimeApplicationEndpointCatalog.applicationState
        )
        let menuCommands = try await state.subscribe(
            to: RuntimeApplicationEndpointCatalog.menuCommands
        )
        return RuntimeApplicationServiceProxy(
            command: command,
            query: query,
            applicationState: applicationState.map(\.payload),
            menuCommands: menuCommands.map(\.payload)
        )
    }
}

private struct RuntimeApplicationServiceProxy: RuneScribeApplicationService {
    let command: RuntimeCommandClient
    let query: RuntimeQueryClient
    let applicationState: AsyncStream<RuneScribeApplicationSnapshot>
    let menuCommands: AsyncStream<ApplicationMenuCommandDTO>

    func stateStream() -> AsyncStream<RuneScribeApplicationSnapshot> { applicationState }
    func menuCommandStream() -> AsyncStream<ApplicationMenuCommandDTO> { menuCommands }
    func encode(_ value: EncodeMessageCommand) async throws -> EncodedMessageResult { try await command.send(value, to: RuntimeApplicationEndpointCatalog.encode) }
    func decode(_ value: DecodeMessageCommand) async throws -> DecodedMessageResult { try await command.send(value, to: RuntimeApplicationEndpointCatalog.decode) }
    func createCipher(_ value: CreateCipherCommand) async throws -> CipherSummary { try await command.send(value, to: RuntimeApplicationEndpointCatalog.createCipher) }
    func renameCipher(_ value: RenameCipherCommand) async throws -> CipherSummary { try await command.send(value, to: RuntimeApplicationEndpointCatalog.renameCipher) }
    func deleteCipher(id: CipherID) async throws { _ = try await command.send(id, to: RuntimeApplicationEndpointCatalog.deleteCipher) }
    func setActiveCipher(_ value: SetActiveCipherCommand) async throws { _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.setActiveCipher) }
    func assignContact(_ value: AssignContactCommand) async throws { _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.assignContact) }
    func createContact(_ value: CreateContactCommand) async throws -> ContactSummary { try await command.send(value, to: RuntimeApplicationEndpointCatalog.createContact) }
    func updateContact(_ value: UpdateContactCommand) async throws -> ContactSummary { try await command.send(value, to: RuntimeApplicationEndpointCatalog.updateContact) }
    func deleteContacts(ids: Set<ContactID>) async throws { _ = try await command.send(ids, to: RuntimeApplicationEndpointCatalog.deleteContacts) }
    func deleteAllImportedContacts() async throws { _ = try await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.deleteAllImportedContacts) }
    func importContacts(_ value: ImportContactsCommand) async throws -> [ContactSummary] { try await command.send(value, to: RuntimeApplicationEndpointCatalog.importContacts) }
    func requestSystemContacts() async throws -> [SystemContactDTO] { try await query.fetch(RuntimeEmptyPayload(), from: RuntimeApplicationEndpointCatalog.requestSystemContacts) }
    func prepareCipherShare(_ value: PrepareCipherShareCommand) async throws -> ShareArtifactDTO { try await command.send(value, to: RuntimeApplicationEndpointCatalog.prepareCipherShare) }
    func prepareMessageShare(_ value: PrepareMessageShareCommand) async throws -> ShareArtifactDTO { try await command.send(value, to: RuntimeApplicationEndpointCatalog.prepareMessageShare) }
    func completeShareArtifact(_ value: CompleteShareArtifactCommand) async throws -> ShareArtifactCompletionResultDTO { try await command.send(value, to: RuntimeApplicationEndpointCatalog.completeShareArtifact) }
    func releaseShareArtifact(id: ShareArtifactID) async { _ = try? await command.send(id, to: RuntimeApplicationEndpointCatalog.releaseShareArtifact) as RuntimeEmptyPayload }
    func importFile(_ value: InboundFileDTO) async throws -> ImportResultDTO { try await command.send(value, to: RuntimeApplicationEndpointCatalog.importFile) }
    func importURL(_ value: InboundURLDTO) async throws -> ImportResultDTO { try await command.send(value, to: RuntimeApplicationEndpointCatalog.importURL) }
    func confirmImport(_ value: ConfirmImportCommand) async throws -> CipherSummary { try await command.send(value, to: RuntimeApplicationEndpointCatalog.confirmImport) }
    func cancelImport(id: ImportID) async { _ = try? await command.send(id, to: RuntimeApplicationEndpointCatalog.cancelImport) as RuntimeEmptyPayload }
    func dismissReceivedMessage(id: MessageID) async { _ = try? await command.send(id, to: RuntimeApplicationEndpointCatalog.dismissReceivedMessage) as RuntimeEmptyPayload }
    func lock() async { _ = try? await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.lock) as RuntimeEmptyPayload }
    func verifyPIN(_ value: PINInput) async throws -> Bool { try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN) }
    func unlock(_ value: UnlockCommand) async throws -> UnlockResultDTO { try await command.send(value, to: RuntimeApplicationEndpointCatalog.unlock) }
    func setPIN(_ value: SetPINCommand) async throws { _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.setPIN) }
    func changePIN(_ value: ChangePINCommand) async throws { _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.changePIN) }
    func disablePIN(_ value: DisablePINCommand) async throws { _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.disablePIN) }
}

struct RuntimeInboundInputServiceProxy: RuneScribeInboundInputService {
    let client: RuntimeIngressClient

    func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        try await client.submit(input, to: RuntimeApplicationEndpointCatalog.inboundInput)
    }
}

private extension AsyncStream where Element: Sendable {
    func map<Transformed: Sendable>(
        _ transform: @escaping @Sendable (Element) -> Transformed
    ) -> AsyncStream<Transformed> {
        let source = self
        return AsyncStream<Transformed>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @Sendable in
                for await value in source {
                    continuation.yield(transform(value))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
