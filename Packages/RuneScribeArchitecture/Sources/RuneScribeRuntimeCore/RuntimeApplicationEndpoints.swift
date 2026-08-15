import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts

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
        _ id: RuntimeEndpointIdentifier,
        bufferingPolicy: RuntimeStateRelayBufferingPolicy = .bufferingNewest(1)
    ) -> RuntimeStateEndpointDescriptor<State> {
        RuntimeStateEndpointDescriptor(
            endpointID: id,
            destination: coreDestination,
            subscriptionSchemaVersion: version,
            stateSchemaVersion: version,
            requiredCapability: RuneScribeCapabilities.applicationStateRead,
            privacyClass: .sensitiveRedacted,
            maximumSubscriptionBytes: 0,
            maximumStateBytes: responseLimit,
            bufferingPolicy: bufferingPolicy
        )
    }

    public static let applicationState: RuntimeStateEndpointDescriptor<RuneScribeApplicationSnapshot> =
        state("application.state")
    public static let menuCommands: RuntimeStateEndpointDescriptor<ApplicationMenuCommandDTO> =
        state("application.menu-commands", bufferingPolicy: .bufferingOldest(16))
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

}

public extension ModuleContext {
    func registerApplicationEndpoints(_ service: any RuneScribeApplicationService) async throws {
        let operationAware = service as? any RuneScribeOperationAwareApplicationService

        func register<Request: Sendable, Response: Sendable>(
            _ key: RuntimeEndpointKey<Request, Response>,
            legacy: @escaping @Sendable (Request) async throws -> Response,
            operationAware awareHandler: @escaping @Sendable (
                any RuneScribeOperationAwareApplicationService,
                Request,
                RuntimePersistableOperationContext
            ) async throws -> Response
        ) async throws {
            try await registerEndpoint(
                key,
                handler: { metadata, request in
                    guard let operationAware else {
                        return try await legacy(request)
                    }
                    let context = try await persistableOperationContext(
                        from: metadata
                    )
                    return try await awareHandler(operationAware, request, context)
                }
            )
        }

        try await registerStateEndpoint(
            RuntimeApplicationEndpointCatalog.applicationState,
            handler: { _ in service.stateStream() }
        )
        try await registerRuntimeMenuCommandEndpoint(
            RuntimeApplicationEndpointCatalog.menuCommands
        )
        try await register(
            RuntimeApplicationEndpointCatalog.encode,
            legacy: service.encode,
            operationAware: { try await $0.encode($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.decode,
            legacy: service.decode,
            operationAware: { try await $0.decode($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.createCipher,
            legacy: service.createCipher,
            operationAware: { try await $0.createCipher($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.renameCipher,
            legacy: service.renameCipher,
            operationAware: { try await $0.renameCipher($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.deleteCipher,
            legacy: { id in
                try await service.deleteCipher(id: id)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, id, context in
                try await aware.deleteCipher(id: id, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.setActiveCipher,
            legacy: { command in
                try await service.setActiveCipher(command)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, command, context in
                try await aware.setActiveCipher(command, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.assignContact,
            legacy: { command in
                try await service.assignContact(command)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, command, context in
                try await aware.assignContact(command, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.createContact,
            legacy: service.createContact,
            operationAware: { try await $0.createContact($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.updateContact,
            legacy: service.updateContact,
            operationAware: { try await $0.updateContact($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.deleteContacts,
            legacy: { ids in
                try await service.deleteContacts(ids: ids)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, ids, context in
                try await aware.deleteContacts(ids: ids, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.deleteAllImportedContacts,
            legacy: { _ in
                try await service.deleteAllImportedContacts()
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, _, context in
                try await aware.deleteAllImportedContacts(context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.importContacts,
            legacy: service.importContacts,
            operationAware: { try await $0.importContacts($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.requestSystemContacts,
            legacy: { _ in try await service.requestSystemContacts() },
            operationAware: { aware, _, context in
                try await aware.requestSystemContacts(context: context)
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.prepareCipherShare,
            legacy: service.prepareCipherShare,
            operationAware: { try await $0.prepareCipherShare($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.prepareMessageShare,
            legacy: service.prepareMessageShare,
            operationAware: { try await $0.prepareMessageShare($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.completeShareArtifact,
            legacy: service.completeShareArtifact,
            operationAware: { try await $0.completeShareArtifact($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.releaseShareArtifact,
            legacy: { id in
                await service.releaseShareArtifact(id: id)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, id, context in
                await aware.releaseShareArtifact(id: id, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.importFile,
            legacy: service.importFile,
            operationAware: { try await $0.importFile($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.importURL,
            legacy: service.importURL,
            operationAware: { try await $0.importURL($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.confirmImport,
            legacy: service.confirmImport,
            operationAware: { try await $0.confirmImport($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.cancelImport,
            legacy: { id in
                await service.cancelImport(id: id)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, id, context in
                await aware.cancelImport(id: id, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.dismissReceivedMessage,
            legacy: { id in
                await service.dismissReceivedMessage(id: id)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, id, context in
                await aware.dismissReceivedMessage(id: id, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.lock,
            legacy: { _ in
                await service.lock()
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, _, context in
                await aware.lock(context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.verifyPIN,
            legacy: service.verifyPIN,
            operationAware: { try await $0.verifyPIN($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.unlock,
            legacy: service.unlock,
            operationAware: { try await $0.unlock($1, context: $2) }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.setPIN,
            legacy: { command in
                try await service.setPIN(command)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, command, context in
                try await aware.setPIN(command, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.changePIN,
            legacy: { command in
                try await service.changePIN(command)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, command, context in
                try await aware.changePIN(command, context: context)
                return RuntimeEmptyPayload()
            }
        )
        try await register(
            RuntimeApplicationEndpointCatalog.disablePIN,
            legacy: { command in
                try await service.disablePIN(command)
                return RuntimeEmptyPayload()
            },
            operationAware: { aware, command, context in
                try await aware.disablePIN(command, context: context)
                return RuntimeEmptyPayload()
            }
        )
    }

    func registerInboundInputEndpoint(_ service: any RuneScribeInboundInputService) async throws {
        let operationAware = service as? any RuneScribeOperationAwareInboundInputService
        try await registerEndpoint(
            RuntimeApplicationEndpointCatalog.inboundInput,
            handler: { metadata, input in
                guard let operationAware else {
                    return try await service.receive(input)
                }
                let context = try await persistableOperationContext(from: metadata)
                return try await operationAware.receive(input, context: context)
            }
        )
    }

    func applicationClient() async throws -> RuntimeApplicationClient {
        let destination: RuntimeEndpointDestination = .role(RuneScribeRoles.core)
        let command = try await self.commandClient(to: destination)
        let query = try await self.queryClient(to: destination)
        let state = try await self.stateClient(to: destination)
        let applicationState = try await state.subscribe(
            to: RuntimeApplicationEndpointCatalog.applicationState
        )
        let menuCommands = try await state.subscribeToMenuCommands(
            RuntimeApplicationEndpointCatalog.menuCommands
        )
        return RuntimeApplicationClient(
            command: command,
            query: query,
            applicationStateEnvelopes: applicationState,
            menuCommandEnvelopes: menuCommands
        )
    }
}

public struct RuntimeApplicationClient: Sendable {
    private let command: RuntimeCommandClient
    private let query: RuntimeQueryClient
    public let applicationStateEnvelopes: RuntimeStateStream<RuneScribeApplicationSnapshot>
    public let menuCommandEnvelopes: RuntimeStateStream<ApplicationMenuCommandDTO>

    init(
        command: RuntimeCommandClient,
        query: RuntimeQueryClient,
        applicationStateEnvelopes: RuntimeStateStream<RuneScribeApplicationSnapshot>,
        menuCommandEnvelopes: RuntimeStateStream<ApplicationMenuCommandDTO>
    ) {
        self.command = command
        self.query = query
        self.applicationStateEnvelopes = applicationStateEnvelopes
        self.menuCommandEnvelopes = menuCommandEnvelopes
    }

    public func encode(_ value: EncodeMessageCommand) async throws -> EncodedMessageResult {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.encode)
    }

    public func decode(_ value: DecodeMessageCommand) async throws -> DecodedMessageResult {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.decode)
    }

    public func createCipher(_ value: CreateCipherCommand) async throws -> CipherSummary {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.createCipher)
    }

    public func renameCipher(_ value: RenameCipherCommand) async throws -> CipherSummary {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.renameCipher)
    }

    public func deleteCipher(id: CipherID) async throws {
        _ = try await command.send(id, to: RuntimeApplicationEndpointCatalog.deleteCipher)
    }

    public func setActiveCipher(_ value: SetActiveCipherCommand) async throws {
        _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.setActiveCipher)
    }

    public func assignContact(_ value: AssignContactCommand) async throws {
        _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.assignContact)
    }

    public func createContact(_ value: CreateContactCommand) async throws -> ContactSummary {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.createContact)
    }

    public func updateContact(_ value: UpdateContactCommand) async throws -> ContactSummary {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.updateContact)
    }

    public func deleteContacts(ids: Set<ContactID>) async throws {
        _ = try await command.send(ids, to: RuntimeApplicationEndpointCatalog.deleteContacts)
    }

    public func deleteAllImportedContacts() async throws {
        _ = try await command.send(
            RuntimeEmptyPayload(),
            to: RuntimeApplicationEndpointCatalog.deleteAllImportedContacts
        )
    }

    public func importContacts(
        _ value: ImportContactsCommand
    ) async throws -> [ContactSummary] {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.importContacts)
    }

    public func requestSystemContacts() async throws -> [SystemContactDTO] {
        try await query.fetch(
            RuntimeEmptyPayload(),
            from: RuntimeApplicationEndpointCatalog.requestSystemContacts
        )
    }

    public func prepareCipherShare(
        _ value: PrepareCipherShareCommand
    ) async throws -> ShareArtifactDTO {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.prepareCipherShare)
    }

    public func prepareMessageShare(
        _ value: PrepareMessageShareCommand
    ) async throws -> ShareArtifactDTO {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.prepareMessageShare)
    }

    public func completeShareArtifact(
        _ value: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.completeShareArtifact)
    }

    public func releaseShareArtifact(id: ShareArtifactID) async throws {
        _ = try await command.send(id, to: RuntimeApplicationEndpointCatalog.releaseShareArtifact)
    }

    public func importFile(_ value: InboundFileDTO) async throws -> ImportResultDTO {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.importFile)
    }

    public func importURL(_ value: InboundURLDTO) async throws -> ImportResultDTO {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.importURL)
    }

    public func confirmImport(_ value: ConfirmImportCommand) async throws -> CipherSummary {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.confirmImport)
    }

    public func cancelImport(id: ImportID) async throws {
        _ = try await command.send(id, to: RuntimeApplicationEndpointCatalog.cancelImport)
    }

    public func dismissReceivedMessage(id: MessageID) async throws {
        _ = try await command.send(id, to: RuntimeApplicationEndpointCatalog.dismissReceivedMessage)
    }

    public func lock() async throws {
        _ = try await command.send(RuntimeEmptyPayload(), to: RuntimeApplicationEndpointCatalog.lock)
    }

    public func verifyPIN(_ value: PINInput) async throws -> Bool {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.verifyPIN)
    }

    public func unlock(_ value: UnlockCommand) async throws -> UnlockResultDTO {
        try await command.send(value, to: RuntimeApplicationEndpointCatalog.unlock)
    }

    public func setPIN(_ value: SetPINCommand) async throws {
        _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.setPIN)
    }

    public func changePIN(_ value: ChangePINCommand) async throws {
        _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.changePIN)
    }

    public func disablePIN(_ value: DisablePINCommand) async throws {
        _ = try await command.send(value, to: RuntimeApplicationEndpointCatalog.disablePIN)
    }
}
