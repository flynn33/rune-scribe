import CryptoKit
import Foundation
import RuneScribeContracts

/// The Core-owned, key-free application facade. Key-bearing ciphers and
/// persistence entities remain behind the private repository actor.
public actor RuneScribeCoreApplicationService: RuneScribeApplicationService,
    RuneScribeInboundInputService
{
    private enum InitializationState {
        case notStarted
        case loading
        case ready
        case failed
    }

    private struct QueuedInbound: Sendable {
        let input: RuneScribeInboundInput
        let dedupeKey: Data?
        let sequence: UInt64
    }

    private struct ReconciledContactState: Sendable {
        let book: ContactBook
        let library: CipherLibrary
    }

    private enum ContactRepairOutcome: Sendable {
        case repaired(ReconciledContactState)
        case failed
    }

    private let repository: CipherRepository
    private let clock: any ClockProviding
    private let uuid: any UUIDProviding
    private let messageService = MessageService()
    private let appLock: AppLockService
    private let artifactRegistry: ShareArtifactRegistry
    private let fileReader: any InboundFileReader
    private var clipboardReading: (any ClipboardReading)? = nil
    private var fontIntegration: (any CoreFontIntegrating)? = nil
    private var contactIntegration: (any CoreMessageContactAssociating)? = nil
    private var fontCatalog: FontCatalog? = nil
    private var contactManager: ContactManager? = nil

    private var initializationState: InitializationState = .notStarted
    private var lastKnownLibrary: CipherLibrary = .empty
    private var lastKnownContactBook: ContactBook = .empty
    private var contactAuthorization: ContactAuthorizationDTO = .notDetermined
    private var lastKnownFontSummaries: [FontSummary] = []
    private var lastFailure: RuneScribeFailureDTO?
    private var revision: UInt64 = 0

    private var importState = ImportStateDTO(phase: .idle)
    private var messageState = MessageStateDTO(phase: .idle)
    private var lockState = ApplicationLockStateDTO(isPINSet: false, isLocked: false)
    private var pendingImports: [ImportID: PendingCipherImport] = [:]
    private var activeImportID: ImportID?
    private var activeImportDedupeKeys: Set<Data> = []
    private var activeImportDedupeKeyOrder: [Data] = []
    private var messageDedupeKeys: [MessageID: Data] = [:]
    private var importSourceDedupeKeys: [ImportID: Data] = [:]
    private var messageSourceDedupeKeys: [MessageID: Data] = [:]
    private var importCancellationGenerations: [ImportID: UInt64] = [:]
    private var confirmingImportIDs: Set<ImportID> = []
    private var committingImportIDs: Set<ImportID> = []

    private var inboundStarted = false
    private var inboundDataQueue: [QueuedInbound] = []
    private var inboundControlQueue: [QueuedInbound] = []
    private var queuedInboundDedupeKeys: Set<Data> = []
    private var isDrainingInbound = false
    private var nextInboundSequence: UInt64 = 0
    private var acceptsSharePreparation = false
    private var shareCleanupNeedsRetry = false
    private var shareAuthorizationGeneration: UInt64 = 0
    private var seenInboundIDs: Set<InboundInputID> = []
    private var seenInboundIDOrder: [InboundInputID] = []
    private var lastClipboardChangeCount = 0

    private var nextMenuSubscriberID: UInt64 = 0
    private var menuSubscribers:
        [UInt64: AsyncStream<ApplicationMenuCommandDTO>.Continuation] = [:]
    private var pendingMenuCommands: [ApplicationMenuCommandDTO] = []

    private var nextSubscriberID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<RuneScribeApplicationSnapshot>.Continuation] = [:]

    // Service methods can interleave while awaiting the repository. Serializing
    // complete use cases prevents an older result from replacing newer state.
    private var useCaseInProgress = false
    private var useCaseWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        secureValueStore: any SecureValueStore,
        clock: any ClockProviding,
        uuid: any UUIDProviding
    ) {
        let unavailableStore = UnavailableShareArtifactStore()
        repository = CipherRepository(
            secureValueStore: secureValueStore,
            clock: clock,
            uuid: uuid
        )
        self.clock = clock
        self.uuid = uuid
        appLock = AppLockService(secureValueStore: secureValueStore, clock: clock)
        artifactRegistry = ShareArtifactRegistry(store: unavailableStore)
        fileReader = UnavailableInboundFileReader()
        fontCatalog = nil
        contactManager = nil
    }

    public init(
        secureValueStore: any SecureValueStore,
        shareArtifactStore: any ShareArtifactStore,
        clock: any ClockProviding,
        uuid: any UUIDProviding
    ) {
        repository = CipherRepository(
            secureValueStore: secureValueStore,
            clock: clock,
            uuid: uuid
        )
        self.clock = clock
        self.uuid = uuid
        appLock = AppLockService(secureValueStore: secureValueStore, clock: clock)
        artifactRegistry = ShareArtifactRegistry(store: shareArtifactStore)
        fileReader = UnavailableInboundFileReader()
        fontCatalog = nil
        contactManager = nil
    }

    public init(
        secureValueStore: any SecureValueStore,
        protectedFileStore: any ProtectedFileStore,
        inboundFileReader: any InboundFileReader,
        shareArtifactStore: any ShareArtifactStore,
        applicationResourceLocator: any ApplicationResourceLocator,
        systemFontRegistrar: any SystemFontRegistrar,
        contactAccess: any ContactAccessService,
        clipboardReading: any ClipboardReading,
        clock: any ClockProviding,
        uuid: any UUIDProviding
    ) {
        let repository = CipherRepository(
            secureValueStore: secureValueStore,
            clock: clock,
            uuid: uuid
        )
        let fontCatalog = FontCatalog(
            protectedFileStore: protectedFileStore,
            registrar: systemFontRegistrar,
            resources: applicationResourceLocator
        )
        let contactManager = ContactManager(
            repository: EncryptedContactRepository(
                secureValueStore: secureValueStore,
                protectedFileStore: protectedFileStore
            ),
            contactAccess: contactAccess,
            clock: clock,
            uuid: uuid
        )
        self.repository = repository
        self.clock = clock
        self.uuid = uuid
        appLock = AppLockService(secureValueStore: secureValueStore, clock: clock)
        artifactRegistry = ShareArtifactRegistry(store: shareArtifactStore)
        fileReader = inboundFileReader
        self.fontCatalog = fontCatalog
        self.contactManager = contactManager
        fontIntegration = fontCatalog
        contactIntegration = contactManager
        self.clipboardReading = clipboardReading
    }

    public nonisolated func stateStream() -> AsyncStream<RuneScribeApplicationSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            Task {
                await self.attach(continuation)
            }
        }
    }

    // MARK: - Messages

    public func encode(_ command: EncodeMessageCommand) async throws -> EncodedMessageResult {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let library = try await repository.snapshot()
            let cipher: Cipher?
            if let requestedID = command.cipherID?.rawValue {
                cipher = library.ciphers.first(where: { $0.id == requestedID })
            } else {
                cipher = library.activeCipher
            }
            guard let cipher else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .itemNotFound)
                )
            }

            let runes = try messageService.compose(command.plaintext, with: cipher)
            adoptSuccessfulRead(library)
            return EncodedMessageResult(
                runes: runes,
                cipherID: CipherID(rawValue: cipher.id)
            )
        } catch {
            throw record(error)
        }
    }

    public func decode(_ command: DecodeMessageCommand) async throws -> DecodedMessageResult {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let library = try await repository.snapshot()
            let decoded = try messageService.read(
                command.runes,
                tryingCiphers: library.ciphers
            )
            adoptSuccessfulRead(library)
            return DecodedMessageResult(
                plaintext: decoded.plaintext,
                cipherID: CipherID(rawValue: decoded.cipher.id),
                cipherName: decoded.cipher.label
            )
        } catch {
            throw record(error)
        }
    }

    // MARK: - Cipher library

    public func createCipher(_ command: CreateCipherCommand) async throws -> CipherSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let mutation = try await repository.createCipher(label: command.name)
            adoptMutation(mutation.library)
            return Self.summary(for: mutation.value, in: mutation.library)
        } catch {
            throw record(error)
        }
    }

    public func renameCipher(_ command: RenameCipherCommand) async throws -> CipherSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let mutation = try await repository.renameCipher(
                id: command.cipherID.rawValue,
                label: command.name
            )
            guard let cipher = mutation.value else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .itemNotFound)
                )
            }
            adoptMutation(mutation.library)
            return Self.summary(for: cipher, in: mutation.library)
        } catch {
            throw record(error)
        }
    }

    public func deleteCipher(id: CipherID) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let mutation = try await repository.deleteCipher(id: id.rawValue)
            adoptMutation(mutation.library)
        } catch {
            throw record(error)
        }
    }

    public func setActiveCipher(_ command: SetActiveCipherCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let mutation = try await repository.setActiveCipher(id: command.cipherID.rawValue)
            adoptMutation(mutation.library)
        } catch {
            throw record(error)
        }
    }

    public func assignContact(_ command: AssignContactCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let mutation = try await repository.assignContact(
                cipherID: command.cipherID.rawValue,
                contactID: command.contactID?.rawValue
            )
            adoptMutation(mutation.library)
        } catch {
            throw record(error)
        }
    }

    // MARK: - P4B operations

    public func createContact(_ command: CreateContactCommand) async throws -> ContactSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let mutation = try await contactManager.create(command)
            let library = try await reconcileContactAssociations(in: mutation.book)
            adoptContactMutation(mutation.book, library: library)
            return Self.contactSummary(
                mutation.value,
                linkedCount: Self.linkedCounts(in: library)[mutation.value.id, default: 0]
            )
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw record(error)
        }
    }

    public func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let mutation = try await contactManager.update(command)
            let library = try await reconcileContactAssociations(in: mutation.book)
            adoptContactMutation(mutation.book, library: library)
            return Self.contactSummary(
                mutation.value,
                linkedCount: Self.linkedCounts(in: library)[mutation.value.id, default: 0]
            )
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw record(error)
        }
    }

    public func deleteContacts(ids: Set<ContactID>) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let removal = try await contactManager.delete(ids: Set(ids.map(\.rawValue)))
            let library = try await reconcileContactAssociations(in: removal.book)
            adoptContactMutation(removal.book, library: library)
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw record(error)
        }
    }

    public func deleteAllImportedContacts() async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let removal = try await contactManager.deleteAllImported()
            let library = try await reconcileContactAssociations(in: removal.book)
            adoptContactMutation(removal.book, library: library)
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw record(error)
        }
    }

    public func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary] {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let contactMutation = try await contactManager.importContacts(command)
            let library = try await reconcileContactAssociations(in: contactMutation.book)
            adoptContactMutation(contactMutation.book, library: library)
            let counts = Self.linkedCounts(in: library)
            return contactMutation.added.map {
                Self.contactSummary($0, linkedCount: counts[$0.id, default: 0])
            }
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw record(error)
        }
    }

    public func requestSystemContacts() async throws -> [SystemContactDTO] {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            let granted = try await contactManager.requestAccess()
            contactAuthorization = await contactManager.authorizationStatus()
            guard granted else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .authorizationDenied)
                )
            }
            let contacts = try await contactManager.fetchSystemContacts()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
            return contacts
        } catch {
            throw record(error)
        }
    }

    public func prepareCipherShare(
        _ command: PrepareCipherShareCommand
    ) async throws -> ShareArtifactDTO {
        let requestGeneration = shareAuthorizationGeneration
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            guard acceptsSharePreparation else { throw unavailableError() }
            try await requireUnlocked()
            let library = try await repository.snapshot()
            guard let cipher = library.ciphers.first(where: {
                $0.id == command.cipherID.rawValue
            }) else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .itemNotFound)
                )
            }

            let artifactID = ShareArtifactID(rawValue: uuid.nextUUID())
            let payload = CipherSharePayload(cipher: cipher)
            let artifact: ShareArtifactDTO
            switch command.representation {
            case .file:
                let fontBytes = try await fontIntegration?.data(for: cipher.fontRef) ?? Data()
                let bytes = try payload.encodedFile(fontBytes: fontBytes)
                artifact = try await artifactRegistry.createFile(
                    data: bytes,
                    id: artifactID,
                    filename: Self.exportFilename(for: cipher),
                    displayName: cipher.label,
                    contentType: RuneScribeWireFormat.contentType,
                    fileExtension: RuneScribeWireFormat.fileExtension,
                    requiresKeyDelivery: true,
                    messageCipherID: nil
                )
            case .link, .qrCode:
                let url = try payload.url(name: command.displayName)
                artifact = try await artifactRegistry.createLink(
                    url: url,
                    id: artifactID,
                    displayName: command.displayName ?? cipher.label
                )
            }
            try await validatePreparedArtifactStillActive(
                artifact,
                requestGeneration: requestGeneration
            )
            adoptSuccessfulRead(library)
            return artifact
        } catch {
            throw record(error)
        }
    }

    public func prepareMessageShare(
        _ command: PrepareMessageShareCommand
    ) async throws -> ShareArtifactDTO {
        let requestGeneration = shareAuthorizationGeneration
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            guard acceptsSharePreparation else { throw unavailableError() }
            try await requireUnlocked()
            let library = try await repository.snapshot()
            guard let cipher = library.ciphers.first(where: {
                $0.id == command.cipherID.rawValue
            }) else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .itemNotFound)
                )
            }

            let includeKey = MessageSend.shouldIncludeKey(cipher)
            // Always validate that the runes belong to the requested cipher;
            // the sender label remains the explicit user-selected share value.
            let payload = try MessageSend.payload(
                runes: command.runes,
                senderName: command.senderName,
                cipher: cipher,
                includeKey: includeKey
            )
            let artifactID = ShareArtifactID(rawValue: uuid.nextUUID())
            let artifact: ShareArtifactDTO
            if includeKey {
                let fontBytes: Data?
                if cipher.fontRef == .bundled {
                    fontBytes = nil
                } else {
                    fontBytes = try await fontIntegration?.data(for: cipher.fontRef)
                }
                let bytes = try payload.encodedFile(fontBytes: fontBytes)
                artifact = try await artifactRegistry.createFile(
                    data: bytes,
                    id: artifactID,
                    filename: MessageSend.filename,
                    displayName: "Rune Scribe Message",
                    contentType: RuneScribeWireFormat.contentType,
                    fileExtension: RuneScribeWireFormat.fileExtension,
                    requiresKeyDelivery: true,
                    messageCipherID: cipher.id
                )
            } else {
                artifact = await artifactRegistry.createOpaqueMessage(
                    id: artifactID,
                    cipherID: cipher.id
                )
            }
            try await validatePreparedArtifactStillActive(
                artifact,
                requestGeneration: requestGeneration
            )
            adoptSuccessfulRead(library)
            return artifact
        } catch {
            throw record(error)
        }
    }

    public func completeShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            let artifact = try await artifactRegistry.artifact(id: command.artifactID)
            var recordedDelivery = false
            if let cipherID = artifact.messageCipherID,
               MessageSend.shouldRecordDelivery(
                   outcome: command.outcome,
                   requiresKeyDelivery: artifact.dto.requiresKeyDelivery
               ) {
                let mutation = try await repository.markDelivered(cipherID: cipherID)
                guard mutation.value else {
                    throw RuneScribeProductError.failure(
                        RuneScribeFailureDTO(code: .itemNotFound)
                    )
                }
                adoptMutation(mutation.library)
                recordedDelivery = true
            }
            try await artifactRegistry.release(id: command.artifactID)
            return recordedDelivery ? .deliveryRecorded : .released
        } catch {
            throw record(error)
        }
    }

    public func releaseShareArtifact(id: ShareArtifactID) async {
        do {
            try await artifactRegistry.release(id: id)
        } catch {
            shareCleanupNeedsRetry = true
            _ = record(error)
        }
    }

    public func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            // The scope begins immediately before the actual read and is balanced
            // by the reader before parsing or any actor suspension occurs.
            let data = try await fileReader.read(
                input.fileURL,
                requiresSecurityScope: input.requiresSecurityScopedAccess,
                maximumByteCount: 16 * 1_024 * 1_024
            )
            let dedupeKey = Self.digest(data)
            if activeImportDedupeKeys.contains(dedupeKey) {
                restoreImportStateAfterDuplicate()
                return ImportResultDTO(disposition: .duplicate)
            }
            guard activeImportID == nil, messageState.pendingMessage == nil else {
                return ImportResultDTO(disposition: .ignored)
            }
            importState = ImportStateDTO(phase: .validating)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
            let result = try await ingestFileData(
                data,
                dedupeKey: dedupeKey,
                source: .file
            )
            return result
        } catch {
            importState = ImportStateDTO(
                phase: .failed,
                lastFailure: Self.failure(for: error)
            )
            throw record(error)
        }
    }

    public func importURL(_ input: InboundURLDTO) async throws -> ImportResultDTO {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let payload = try LinkRouter.decodeCipher(input.url)
            let dedupeKey = Self.inboundURLDedupeKey(input.url)
            guard !activeImportDedupeKeys.contains(dedupeKey) else {
                restoreImportStateAfterDuplicate()
                return ImportResultDTO(disposition: .duplicate)
            }
            guard activeImportID == nil, messageState.pendingMessage == nil else {
                return ImportResultDTO(disposition: .ignored)
            }
            importState = ImportStateDTO(phase: .validating)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
            let source = Self.importSource(for: input.metadata.source)
            let pending = ImportUseCase.pending(
                payload: payload,
                fontBytes: nil,
                id: ImportID(rawValue: uuid.nextUUID()),
                source: source,
                dedupeKey: dedupeKey
            )
            setPendingImport(pending)
            return ImportResultDTO(
                disposition: .awaitingConfirmation,
                pendingImport: pending.summary
            )
        } catch {
            importState = ImportStateDTO(
                phase: .failed,
                lastFailure: Self.failure(for: error)
            )
            throw record(error)
        }
    }

    public func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary {
        await acquireUseCasePermit()
        var cancellationGeneration: UInt64?

        do {
            guard let pending = pendingImports[command.importID],
                  activeImportID == command.importID
            else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .itemNotFound)
                )
            }
            confirmingImportIDs.insert(command.importID)
            let generation = importCancellationGenerations[command.importID, default: 0]
            cancellationGeneration = generation
            try await requireUnlocked()
            try ensureImportConfirmationCurrent(
                id: command.importID,
                generation: generation
            )
            importState = ImportStateDTO(phase: .importing, pending: pending.summary)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))

            if let fontIntegration {
                try await fontIntegration.ensureAvailable(
                    reference: pending.payload.fontRef,
                    suppliedBytes: pending.fontBytes
                )
            } else if pending.payload.fontRef != .bundled {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .resourceUnavailable)
                )
            }
            try ensureImportConfirmationCurrent(
                id: command.importID,
                generation: generation
            )
            committingImportIDs.insert(command.importID)
            let mutation = try await repository.importCipher(
                pending.payload,
                label: command.name
            )
            await refreshFontSummaries(for: mutation.library)
            removePendingImport(pending)
            confirmingImportIDs.remove(command.importID)
            committingImportIDs.remove(command.importID)
            importCancellationGenerations.removeValue(forKey: command.importID)
            importState = ImportStateDTO(phase: .completed)
            adoptMutation(mutation.library)
            let summary = Self.summary(for: mutation.value, in: mutation.library)
            releaseUseCasePermit()
            await drainInboundQueueIfPossible()
            return summary
        } catch {
            confirmingImportIDs.remove(command.importID)
            committingImportIDs.remove(command.importID)
            let wasCancelled = cancellationGeneration.map {
                importConfirmationWasCancelled(
                    id: command.importID,
                    generation: $0
                )
            } ?? false
            if wasCancelled {
                importCancellationGenerations.removeValue(forKey: command.importID)
                releaseUseCasePermit()
                await drainInboundQueueIfPossible()
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .operationCancelled)
                )
            }
            importState = ImportStateDTO(
                phase: .failed,
                pending: activeImportID.flatMap { pendingImports[$0]?.summary },
                lastFailure: Self.failure(for: error)
            )
            releaseUseCasePermit()
            throw record(error)
        }
    }

    public func cancelImport(id: ImportID) async {
        guard let pending = pendingImports[id] else { return }
        // Once the encrypted library commit begins, confirmation wins. Before
        // that point cancellation advances a generation observed after every
        // suspension and immediately frees the presentation rail.
        guard !committingImportIDs.contains(id) else { return }
        importCancellationGenerations[id, default: 0] &+= 1
        removePendingImport(pending)
        if !confirmingImportIDs.contains(id) {
            importCancellationGenerations.removeValue(forKey: id)
        }
        importState = ImportStateDTO(phase: .idle)
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false))
        if useCaseInProgress { return }
        await drainInboundQueueIfPossible()
    }

    public func dismissReceivedMessage(id: MessageID) async {
        guard messageState.pendingMessage?.id == id else { return }
        if let key = messageDedupeKeys.removeValue(forKey: id) {
            forgetHandledDedupeKey(key)
        }
        if let sourceKey = messageSourceDedupeKeys.removeValue(forKey: id) {
            queuedInboundDedupeKeys.remove(sourceKey)
        }
        messageState = MessageStateDTO(phase: .idle)
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false))
        await drainInboundQueueIfPossible()
    }

    public func lock() async {
        shareAuthorizationGeneration &+= 1
        do {
            try await appLock.lockIfEnabled()
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
        } catch {
            lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
            _ = record(error)
        }
    }

    public func verifyPIN(_ input: PINInput) async throws -> Bool {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            return try await appLock.verifyForManagement(input)
        } catch {
            throw record(error)
        }
    }

    public func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO {
        await acquireUseCasePermit()
        do {
            let result = try await appLock.unlock(command.input)
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
            releaseUseCasePermit()
            if case .unlocked = result {
                await drainInboundQueueIfPossible()
            }
            return result
        } catch {
            releaseUseCasePermit()
            throw record(error)
        }
    }

    public func setPIN(_ command: SetPINCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            try await appLock.setPIN(command.input)
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
        } catch {
            await refreshLockStateAfterSecurityFailure()
            throw record(error)
        }
    }

    public func changePIN(_ command: ChangePINCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            try await appLock.changePIN(
                current: command.current,
                replacement: command.replacement
            )
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
        } catch {
            await refreshLockStateAfterSecurityFailure()
            throw record(error)
        }
    }

    public func disablePIN(_ command: DisablePINCommand) async throws {
        await acquireUseCasePermit()
        do {
            try await appLock.disablePIN(current: command.current)
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
            releaseUseCasePermit()
            await drainInboundQueueIfPossible()
        } catch {
            await refreshLockStateAfterSecurityFailure()
            releaseUseCasePermit()
            throw record(error)
        }
    }

    // MARK: - Canonical inbound input

    /// Activates ordered processing after Runtime has published the service. Calls
    /// received before activation remain queued in arrival order.
    public func startInboundProcessing() async {
        await initializeForInboundProcessing()
        guard case .ready = initializationState else {
            acceptsSharePreparation = false
            inboundStarted = false
            return
        }
        inboundStarted = true
        do {
            // A new activation must first prove that no stale key-bearing
            // artifact survived the previous lifetime.
            try await artifactRegistry.releaseAll()
            acceptsSharePreparation = true
            if shareCleanupNeedsRetry,
               lastFailure?.code == .shareUnavailable {
                lastFailure = nil
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false))
            }
            shareCleanupNeedsRetry = false
        } catch {
            acceptsSharePreparation = false
            shareCleanupNeedsRetry = true
            _ = record(error)
        }
        await drainInboundQueueIfPossible()
    }

    /// Runtime stop revokes every outstanding share lease and returns inbound
    /// delivery to its pre-start queued state for a later restart.
    public func stopInboundProcessing() async {
        acceptsSharePreparation = false
        shareAuthorizationGeneration &+= 1
        await acquireUseCasePermit()
        inboundStarted = false
        do {
            let wasRetryingCleanup = shareCleanupNeedsRetry
            try await artifactRegistry.releaseAll()
            shareCleanupNeedsRetry = false
            if wasRetryingCleanup,
               lastFailure?.code == .shareUnavailable {
                lastFailure = nil
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false))
            }
        } catch {
            // Registry retains every lease on failure; the next start retries
            // authoritative store cleanup before enabling new shares.
            shareCleanupNeedsRetry = true
            _ = record(error)
        }
        releaseUseCasePermit()
    }

    public func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        guard Self.hasBoundedInboundMetadata(input) else {
            return rejectInbound(code: .invalidInput)
        }
        guard !seenInboundIDs.contains(input.metadata.id) else { return .duplicate }
        let dedupeKey = Self.queuedDedupeKey(for: input)
        if let dedupeKey,
           queuedInboundDedupeKeys.contains(dedupeKey)
            || activeImportDedupeKeys.contains(dedupeKey) {
            return .duplicate
        }
        let totalCount = inboundDataQueue.count + inboundControlQueue.count
        if Self.requiresClearPresentation(input) {
            guard inboundDataQueue.count < Self.maximumQueuedDataInputs,
                  totalCount < Self.maximumQueuedInputs
            else { return rejectInbound(code: .temporarilyUnavailable) }
        } else {
            guard totalCount < Self.maximumQueuedInputs else {
                return rejectInbound(code: .temporarilyUnavailable)
            }
        }

        let queued = QueuedInbound(
            input: input,
            dedupeKey: dedupeKey,
            sequence: nextInboundSequence
        )
        nextInboundSequence &+= 1
        _ = rememberInboundID(input.metadata.id)
        if Self.requiresClearPresentation(input) {
            inboundDataQueue.append(queued)
        } else {
            inboundControlQueue.append(queued)
        }
        if let dedupeKey { queuedInboundDedupeKeys.insert(dedupeKey) }
        if inboundStarted {
            await drainInboundQueueIfPossible()
        }
        return .accepted
    }

    private func rejectInbound(
        code: RuneScribeFailureCode
    ) -> InboundInputDispositionDTO {
        _ = record(
            RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: code)
            )
        )
        return .rejected
    }

    /// Hosted navigation can subscribe without giving Core any presentation API.
    public nonisolated func menuCommandStream() -> AsyncStream<ApplicationMenuCommandDTO> {
        AsyncStream(bufferingPolicy: .bufferingOldest(Self.maximumPendingMenuCommands)) {
            continuation in
            Task { await self.attachMenuSubscriber(continuation) }
        }
    }

    private func processInbound(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        switch input {
        case .file(let file):
            let result = try await importFile(file)
            switch result.disposition {
            case .duplicate: return .duplicate
            case .ignored: return .ignored
            default: return .accepted
            }
        case .url(let url):
            let result = try await importURL(url)
            switch result.disposition {
            case .duplicate: return .duplicate
            case .ignored: return .ignored
            default: return .accepted
            }
        case .lifecycle(let lifecycle):
            if lifecycle.event == .didEnterBackground {
                await lock()
            } else if lifecycle.event == .didBecomeActive {
                await importChangedClipboardIfEligible(metadata: lifecycle.metadata)
            }
            return .accepted
        case .menu(let menu):
            guard !menuSubscribers.isEmpty else {
                guard pendingMenuCommands.count < Self.maximumPendingMenuCommands else {
                    return rejectInbound(code: .temporarilyUnavailable)
                }
                pendingMenuCommands.append(menu.command)
                return .accepted
            }
            var delivered = false
            for continuation in menuSubscribers.values {
                switch continuation.yield(menu.command) {
                case .enqueued:
                    delivered = true
                case .dropped, .terminated:
                    break
                @unknown default:
                    break
                }
            }
            return delivered ? .accepted : rejectInbound(code: .temporarilyUnavailable)
        }
    }

    private func drainInboundQueueIfPossible() async {
        guard inboundStarted, !isDrainingInbound else { return }
        isDrainingInbound = true
        defer { isDrainingInbound = false }
        while !inboundDataQueue.isEmpty || !inboundControlQueue.isEmpty {
            let presentationIsBusy = activeImportID != nil
                || messageState.pendingMessage != nil
            let dataIsPaused = presentationIsBusy || lockState.isLocked
            let next: QueuedInbound
            if dataIsPaused {
                // Security/control delivery has a dedicated bounded lane so a
                // background lock cannot sit behind hundreds of paused files.
                if !inboundControlQueue.isEmpty {
                    next = inboundControlQueue.removeFirst()
                } else if presentationIsBusy,
                          !lockState.isLocked,
                          let probe = inboundDataQueue.first,
                          case .file = probe.input {
                    do {
                        let disposition = try await processInbound(probe.input)
                        guard disposition == .duplicate else { return }
                    } catch {
                        // The pending presentation remains authoritative while
                        // an inaccessible queued probe fails safely forward.
                        restoreImportStateAfterDuplicate()
                    }
                    inboundDataQueue.removeFirst()
                    if let dedupeKey = probe.dedupeKey {
                        queuedInboundDedupeKeys.remove(dedupeKey)
                    }
                    continue
                } else {
                    return
                }
            } else if let data = inboundDataQueue.first,
                      let control = inboundControlQueue.first {
                if data.sequence < control.sequence {
                    next = inboundDataQueue.removeFirst()
                } else {
                    next = inboundControlQueue.removeFirst()
                }
            } else if !inboundDataQueue.isEmpty {
                next = inboundDataQueue.removeFirst()
            } else {
                next = inboundControlQueue.removeFirst()
            }
            var retainsSourceDedupeKey = false
            do {
                let disposition = try await processInbound(next.input)
                if disposition == .accepted,
                   let sourceKey = next.dedupeKey,
                   Self.requiresClearPresentation(next.input) {
                    if let activeImportID {
                        importSourceDedupeKeys[activeImportID] = sourceKey
                        retainsSourceDedupeKey = true
                    } else if let messageID = messageState.pendingMessage?.id {
                        messageSourceDedupeKeys[messageID] = sourceKey
                        retainsSourceDedupeKey = true
                    }
                }
            } catch {
                // Import/message methods publish a safe failure before returning.
                // Continue fail-forward so one malformed item cannot reorder or
                // permanently block later cold-start deliveries.
            }
            if let dedupeKey = next.dedupeKey,
               !retainsSourceDedupeKey {
                queuedInboundDedupeKeys.remove(dedupeKey)
            }
        }
    }

    private func rememberInboundID(_ id: InboundInputID) -> Bool {
        guard seenInboundIDs.insert(id).inserted else { return false }
        seenInboundIDOrder.append(id)
        if seenInboundIDOrder.count > 512 {
            seenInboundIDs.remove(seenInboundIDOrder.removeFirst())
        }
        return true
    }

    private func importChangedClipboardIfEligible(
        metadata: InboundInputMetadataDTO
    ) async {
        guard !lockState.isLocked,
              activeImportID == nil,
              messageState.pendingMessage == nil,
              let clipboardReading
        else { return }
        let changeCount = await clipboardReading.changeCount()
        guard changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = changeCount
        guard let raw = await clipboardReading.string() else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= LinkRouter.maximumURLByteCount,
              let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              LinkRouter.isSupportedRoute(components)
        else { return }

        let clipboardInput = InboundURLDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: uuid.nextUUID()),
                receivedAt: metadata.receivedAt,
                source: .clipboard,
                isColdStart: false
            ),
            url: url
        )
        _ = try? await importURL(clipboardInput)
    }

    private func attachMenuSubscriber(
        _ continuation: AsyncStream<ApplicationMenuCommandDTO>.Continuation
    ) {
        let id = nextMenuSubscriberID
        nextMenuSubscriberID &+= 1
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.detachMenuSubscriber(id) }
        }
        let isFirstSubscriber = menuSubscribers.isEmpty
        menuSubscribers[id] = continuation
        guard isFirstSubscriber, !pendingMenuCommands.isEmpty else { return }

        var deliveredCount = 0
        for command in pendingMenuCommands {
            switch continuation.yield(command) {
            case .enqueued:
                deliveredCount += 1
            case .dropped, .terminated:
                break
            @unknown default:
                break
            }
            if deliveredCount == 0 { break }
        }
        pendingMenuCommands.removeFirst(deliveredCount)
    }

    private func detachMenuSubscriber(_ id: UInt64) {
        menuSubscribers.removeValue(forKey: id)
    }

    private static func requiresClearPresentation(_ input: RuneScribeInboundInput) -> Bool {
        switch input {
        case .file, .url: true
        case .lifecycle, .menu: false
        }
    }

    private static func queuedDedupeKey(for input: RuneScribeInboundInput) -> Data? {
        switch input {
        case .url(let value):
            guard value.url.absoluteString.utf8.count <= LinkRouter.maximumURLByteCount else {
                return digest(Data("oversized-url".utf8))
            }
            return inboundURLDedupeKey(value.url)
        case .file(let value):
            return digest(Data("file:\(value.fileURL.standardizedFileURL.absoluteString)".utf8))
        case .lifecycle, .menu:
            return nil
        }
    }

    private static let maximumQueuedInputs = 512
    private static let maximumQueuedDataInputs = 496
    private static let maximumPendingMenuCommands = 16
    private static let maximumInboundFileURLByteCount = 4_096
    private static let maximumDeclaredContentTypeByteCount = 256

    private static func hasBoundedInboundMetadata(
        _ input: RuneScribeInboundInput
    ) -> Bool {
        switch input {
        case .url(let value):
            value.url.absoluteString.utf8.count <= LinkRouter.maximumURLByteCount
        case .file(let value):
            value.fileURL.absoluteString.utf8.count <= maximumInboundFileURLByteCount
                && (value.declaredContentType?.utf8.count ?? 0)
                    <= maximumDeclaredContentTypeByteCount
        case .lifecycle, .menu:
            true
        }
    }

    // MARK: - Import/message internals

    private func ingestFileData(
        _ data: Data,
        dedupeKey: Data,
        source: ImportSourceDTO
    ) async throws -> ImportResultDTO {
        guard !activeImportDedupeKeys.contains(dedupeKey) else {
            restoreImportStateAfterDuplicate()
            return ImportResultDTO(disposition: .duplicate)
        }

        switch try FileRouter.decode(data) {
        case .cipher(let payload, let fontBytes):
            let pending = ImportUseCase.pending(
                payload: payload,
                fontBytes: fontBytes,
                id: ImportID(rawValue: uuid.nextUUID()),
                source: source,
                dedupeKey: dedupeKey
            )
            setPendingImport(pending)
            return ImportResultDTO(
                disposition: .awaitingConfirmation,
                pendingImport: pending.summary
            )

        case .message(let payload, let fontBytes):
            messageState = MessageStateDTO(phase: .receiving)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
            do {
                let mutation = try await MessageImportUseCase.ingest(
                    payload: payload,
                    fontBytes: fontBytes,
                    repository: repository,
                    messageService: messageService,
                    fontIntegration: fontIntegration,
                    contactIntegration: contactIntegration,
                    uuid: uuid
                )
                if let contactManager,
                   let contactBook = try? await contactManager.snapshot() {
                    lastKnownContactBook = contactBook
                }
                await refreshFontSummaries(for: mutation.library)
                rememberHandledDedupeKey(dedupeKey)
                messageDedupeKeys[mutation.message.id] = dedupeKey
                messageState = MessageStateDTO(
                    phase: .received,
                    pendingMessage: mutation.message
                )
                importState = ImportStateDTO(phase: .completed)
                adoptMutation(mutation.library)
                return ImportResultDTO(
                    disposition: .receivedMessage,
                    receivedMessageID: mutation.message.id
                )
            } catch {
                // Association can commit to either durable store before the
                // second write fails. Always await independent reconciliation;
                // precommit parsing/decryption failures reduce to a safe no-op.
                _ = await repairContactAssociationsIndependently()
                messageState = MessageStateDTO(
                    phase: .failed,
                    lastFailure: Self.failure(for: error)
                )
                throw error
            }
        }
    }

    private func setPendingImport(_ pending: PendingCipherImport) {
        pendingImports[pending.id] = pending
        activeImportID = pending.id
        importCancellationGenerations[pending.id] = 0
        rememberHandledDedupeKey(pending.dedupeKey)
        lastFailure = nil
        importState = ImportStateDTO(
            phase: .awaitingConfirmation,
            pending: pending.summary
        )
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false))
    }

    private func removePendingImport(_ pending: PendingCipherImport) {
        pendingImports.removeValue(forKey: pending.id)
        forgetHandledDedupeKey(pending.dedupeKey)
        if let sourceKey = importSourceDedupeKeys.removeValue(forKey: pending.id) {
            queuedInboundDedupeKeys.remove(sourceKey)
        }
        if activeImportID == pending.id { activeImportID = nil }
    }

    private func rememberHandledDedupeKey(_ key: Data) {
        guard activeImportDedupeKeys.insert(key).inserted else { return }
        activeImportDedupeKeyOrder.append(key)
        if activeImportDedupeKeyOrder.count > 512 {
            activeImportDedupeKeys.remove(activeImportDedupeKeyOrder.removeFirst())
        }
    }

    private func forgetHandledDedupeKey(_ key: Data) {
        activeImportDedupeKeys.remove(key)
        activeImportDedupeKeyOrder.removeAll { $0 == key }
    }

    private func restoreImportStateAfterDuplicate() {
        if let activeImportID, let pending = pendingImports[activeImportID] {
            importState = ImportStateDTO(
                phase: .awaitingConfirmation,
                pending: pending.summary
            )
        } else if messageState.pendingMessage != nil {
            importState = ImportStateDTO(phase: .completed)
        } else {
            importState = ImportStateDTO(phase: .idle)
        }
    }

    private func ensureImportConfirmationCurrent(
        id: ImportID,
        generation: UInt64
    ) throws {
        guard !importConfirmationWasCancelled(id: id, generation: generation) else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .operationCancelled)
            )
        }
    }

    private func importConfirmationWasCancelled(
        id: ImportID,
        generation: UInt64
    ) -> Bool {
        importCancellationGenerations[id, default: 0] != generation
            || activeImportID != id
            || pendingImports[id] == nil
    }

    private func requireUnlocked() async throws {
        do {
            lockState = try await appLock.state()
        } catch {
            lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
            throw error
        }
        guard !lockState.isLocked else {
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .authenticationFailed)
            )
        }
    }

    private func validatePreparedArtifactStillActive(
        _ artifact: ShareArtifactDTO,
        requestGeneration: UInt64
    ) async throws {
        let currentLock: ApplicationLockStateDTO
        do {
            currentLock = try await appLock.state()
        } catch {
            do {
                try await artifactRegistry.release(id: artifact.id)
            } catch {
                shareCleanupNeedsRetry = true
                throw ShareArtifactRegistryError.storageUnavailable
            }
            throw error
        }
        guard acceptsSharePreparation,
              requestGeneration == shareAuthorizationGeneration,
              !currentLock.isLocked
        else {
            do {
                try await artifactRegistry.release(id: artifact.id)
            } catch {
                shareCleanupNeedsRetry = true
                throw ShareArtifactRegistryError.storageUnavailable
            }
            throw RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .shareUnavailable)
            )
        }
    }

    private func initializeForInboundProcessing() async {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        guard case .notStarted = initializationState else { return }
        initializationState = .loading
        do {
            var library = try await repository.snapshot()
            let loadedLock = try await appLock.state()
            if let contactManager {
                let state = try await Self.recoverAndReconcileContactAssociations(
                    contactManager: contactManager,
                    repository: repository
                )
                library = state.library
                lastKnownContactBook = state.book
                contactAuthorization = await contactManager.authorizationStatus()
            }
            if let fontCatalog {
                // Shipping launch treated font-registration failures as
                // nonfatal. Strict catalog operations remain available to the
                // import path, but a corrupt optional font cannot block Core.
                _ = try? await fontCatalog.registerAvailableFonts()
            }
            await refreshFontSummaries(for: library)
            lastKnownLibrary = library
            lockState = loadedLock
            lastFailure = nil
            initializationState = .ready
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false))
        } catch {
            lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
            initializationState = .failed
            _ = record(error)
        }
    }

    private static func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private static func inboundURLDedupeKey(_ url: URL) -> Data {
        digest(Data("url:\(url.absoluteString)".utf8))
    }

    private static func importSource(
        for deliverySource: InboundDeliverySourceDTO
    ) -> ImportSourceDTO {
        switch deliverySource {
        case .clipboard: .clipboard
        case .qrScanner: .qrCode
        default: .link
        }
    }

    private static func exportFilename(for cipher: Cipher) -> String {
        let allowed = CharacterSet.alphanumerics
        let slug = String(cipher.label.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : Character("-")
        })
        let collapsed = slug.split(separator: "-").joined(separator: "-")
        let base = collapsed.isEmpty ? "cipher" : String(collapsed.prefix(32))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "RuneScrib-\(base)-\(formatter.string(from: cipher.createdAt))"
    }

    // MARK: - State stream

    private func attach(
        _ continuation: AsyncStream<RuneScribeApplicationSnapshot>.Continuation
    ) async {
        let subscriberID = nextSubscriberID
        nextSubscriberID &+= 1
        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task {
                await self.detach(subscriberID)
            }
        }
        subscribers[subscriberID] = continuation

        switch initializationState {
        case .notStarted:
            initializationState = .loading
            continuation.yield(makeSnapshot(isLoading: true))
            await acquireUseCasePermit()
            do {
                var library = try await repository.snapshot()
                let loadedLock = try await appLock.state()
                if let contactManager {
                    let state = try await Self.recoverAndReconcileContactAssociations(
                        contactManager: contactManager,
                        repository: repository
                    )
                    library = state.library
                    lastKnownContactBook = state.book
                    contactAuthorization = await contactManager.authorizationStatus()
                }
                if let fontCatalog {
                    _ = try? await fontCatalog.registerAvailableFonts()
                }
                await refreshFontSummaries(for: library)
                lastKnownLibrary = library
                lockState = loadedLock
                lastFailure = nil
                initializationState = .ready
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false))
            } catch {
                // Secure-state uncertainty fails closed; a nonloading snapshot is
                // never published as unlocked when PIN storage could not be read.
                lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
                initializationState = .failed
                _ = record(error)
            }
            releaseUseCasePermit()

        case .loading:
            continuation.yield(makeSnapshot(isLoading: true))

        case .ready, .failed:
            continuation.yield(makeSnapshot(isLoading: false))
        }
    }

    private func detach(_ subscriberID: UInt64) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func adoptSuccessfulRead(_ library: CipherLibrary) {
        let stateChanged = initializationState != .ready || lastFailure != nil
        lastKnownLibrary = library
        lastFailure = nil
        initializationState = .ready
        guard stateChanged else { return }
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false))
    }

    private func adoptMutation(_ library: CipherLibrary) {
        lastKnownLibrary = library
        lastFailure = nil
        initializationState = .ready
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false))
    }

    private func adoptContactMutation(_ book: ContactBook, library: CipherLibrary) {
        lastKnownContactBook = book
        lastKnownLibrary = library
        lastFailure = nil
        initializationState = .ready
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false))
    }

    /// Applies the complete cross-store invariant from the committed contact
    /// book in one encrypted cipher-library write. Manual and local-only
    /// message contacts remain valid association targets, while only persisted
    /// system imports require an automatically generated linked cipher.
    private func reconcileContactAssociations(
        in book: ContactBook
    ) async throws -> CipherLibrary {
        try await Self.reconcileContactAssociations(
            book: book,
            repository: repository
        ).library
    }

    /// A contact-file write can commit before the cipher-library write fails or
    /// the calling task is cancelled. Repair runs in a fresh task and is awaited
    /// before the original error is surfaced, so cancellation cannot strand the
    /// two durable stores in a known partial-commit state.
    @discardableResult
    private func repairContactAssociationsIndependently() async
        -> ReconciledContactState? {
        guard let contactManager else { return nil }
        let repository = repository
        let repair = Task.detached(priority: nil) {
            do {
                let state = try await Self.recoverAndReconcileContactAssociations(
                    contactManager: contactManager,
                    repository: repository
                )
                return ContactRepairOutcome.repaired(state)
            } catch {
                return ContactRepairOutcome.failed
            }
        }

        switch await repair.value {
        case .repaired(let state):
            adoptContactMutation(state.book, library: state.library)
            return state
        case .failed:
            // Keep the last known consistent projection. A reconstructed service
            // retries the same deterministic reconciliation before publishing
            // ready state.
            return nil
        }
    }

    private nonisolated static func reconcileContactAssociations(
        book: ContactBook,
        repository: CipherRepository
    ) async throws -> ReconciledContactState {
        let seeds = book.contacts.compactMap { contact -> ImportedContactCipherSeed? in
            guard contact.source == .imported,
                  contact.appleContactID != nil
            else { return nil }
            return ImportedContactCipherSeed(
                contactID: contact.id,
                displayName: contact.displayName
            )
        }
        let mutation = try await repository.reconcileContactAssociations(
            systemImportedSeeds: seeds,
            validContactIDs: Set(book.contacts.map(\.id))
        )
        return ReconciledContactState(book: book, library: mutation.library)
    }

    private nonisolated static func recoverAndReconcileContactAssociations(
        contactManager: ContactManager,
        repository: CipherRepository
    ) async throws -> ReconciledContactState {
        if let recovery = try await contactManager.prepareMessageAssociationRecovery() {
            let validContactIDs = Set(recovery.book.contacts.map(\.id))
            let restoredContactID = recovery.intent.previousContactID.flatMap {
                validContactIDs.contains($0) ? $0 : nil
            }
            let restored = try await repository.assignContact(
                cipherID: recovery.intent.cipherID,
                contactID: restoredContactID
            )
            guard restored.value else {
                throw MessageImportError.cipherAssociationUnavailable
            }
            let state = try await reconcileContactAssociations(
                book: recovery.book,
                repository: repository
            )
            try await contactManager.completeMessageAssociationRecovery(
                recovery.intent
            )
            return state
        }

        let book = try await contactManager.snapshot()
        return try await reconcileContactAssociations(
            book: book,
            repository: repository
        )
    }

    @discardableResult
    private func record(_ error: Error) -> RuneScribeProductError {
        let failure = Self.failure(for: error)
        lastFailure = failure
        revision &+= 1
        broadcast(makeSnapshot(isLoading: initializationState == .loading))
        return .failure(failure)
    }

    private func unavailable() -> RuneScribeProductError {
        record(
            RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: .temporarilyUnavailable)
            )
        )
    }

    private func unavailableError() -> RuneScribeProductError {
        .failure(RuneScribeFailureDTO(code: .temporarilyUnavailable))
    }

    private func unavailableImport() -> RuneScribeProductError {
        let failure = RuneScribeFailureDTO(code: .temporarilyUnavailable)
        importState = ImportStateDTO(phase: .failed, lastFailure: failure)
        return record(RuneScribeProductError.failure(failure))
    }

    private func refreshLockStateAfterSecurityFailure() async {
        do {
            lockState = try await appLock.state()
        } catch {
            // Persisted lock uncertainty must never project as unlocked.
            lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
        }
    }

    private func broadcast(_ snapshot: RuneScribeApplicationSnapshot) {
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    // MARK: - Use-case serialization

    private func acquireUseCasePermit() async {
        if !useCaseInProgress {
            useCaseInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            useCaseWaiters.append(continuation)
        }
    }

    private func releaseUseCasePermit() {
        if useCaseWaiters.isEmpty {
            useCaseInProgress = false
        } else {
            useCaseWaiters.removeFirst().resume()
        }
    }

    private func makeSnapshot(isLoading: Bool) -> RuneScribeApplicationSnapshot {
        let activeID = lastKnownLibrary.activeCipher?.id
        let summaries = lastKnownLibrary.ciphers.map { cipher in
            Self.summary(for: cipher, activeID: activeID)
        }

        return RuneScribeApplicationSnapshot(
            revision: revision,
            capturedAt: clock.now(),
            cipherLibrary: CipherLibraryStateDTO(
                ciphers: summaries,
                activeCipherID: activeID.map(CipherID.init(rawValue:)),
                isLoading: isLoading
            ),
            contactLibrary: Self.contactState(
                book: lastKnownContactBook,
                library: lastKnownLibrary,
                authorization: contactAuthorization
            ),
            fonts: lastKnownFontSummaries.isEmpty
                ? Self.fontSummaries(for: lastKnownLibrary)
                : lastKnownFontSummaries,
            importState: importState,
            messageState: messageState,
            lockState: lockState,
            lastFailure: lastFailure
        )
    }

    // MARK: - Key-free projection

    private static func summary(for cipher: Cipher, in library: CipherLibrary) -> CipherSummary {
        summary(for: cipher, activeID: library.activeCipher?.id)
    }

    private static func summary(for cipher: Cipher, activeID: UUID?) -> CipherSummary {
        CipherSummary(
            id: CipherID(rawValue: cipher.id),
            name: cipher.label,
            origin: cipher.origin == .generated ? .generated : .imported,
            createdAt: cipher.createdAt,
            isActive: cipher.id == activeID,
            assignedContactID: cipher.contactID.map(ContactID.init(rawValue:)),
            hasBeenDelivered: cipher.delivered,
            publicIdentifier: cipher.shortPublicID,
            fontID: FontID(rawValue: cipher.fontRef.id)
        )
    }

    private static func contactState(
        book: ContactBook,
        library: CipherLibrary,
        authorization: ContactAuthorizationDTO
    ) -> ContactLibraryStateDTO {
        let counts = linkedCounts(in: library)
        let summaries = ContactManager.summaries(
            for: book,
            linkedCipherCounts: counts
        )
        return ContactLibraryStateDTO(
            contacts: summaries,
            importedCount: book.contacts.filter { $0.source == .imported }.count,
            authorization: authorization
        )
    }

    private static func contactSummary(
        _ contact: Contact,
        linkedCount: Int
    ) -> ContactSummary {
        ContactSummary(
            id: ContactID(rawValue: contact.id),
            displayName: contact.displayName,
            phoneNumbers: contact.phones,
            emailAddresses: contact.emails,
            source: contact.source == .manual ? .manual : .imported,
            createdAt: contact.createdAt,
            linkedCipherCount: linkedCount
        )
    }

    private static func linkedCounts(in library: CipherLibrary) -> [UUID: Int] {
        library.ciphers.reduce(into: [:]) { counts, cipher in
            if let contactID = cipher.contactID {
                counts[contactID, default: 0] += 1
            }
        }
    }

    private static func fontSummaries(for library: CipherLibrary) -> [FontSummary] {
        var references: [String: FontRef] = [:]
        for cipher in library.ciphers where references[cipher.fontRef.id] == nil {
            references[cipher.fontRef.id] = cipher.fontRef
        }
        return references.values.sorted { $0.id < $1.id }.map { reference in
            let isBundled = reference == .bundled
            return FontSummary(
                id: FontID(rawValue: reference.id),
                displayName: isBundled ? "Noto Sans Runic" : reference.id,
                version: reference.version,
                contentHash: reference.sha256.map { String(format: "%02x", $0) }.joined(),
                source: isBundled ? .bundled : .imported,
                isRegistered: isBundled
            )
        }
    }

    private func refreshFontSummaries(for library: CipherLibrary) async {
        guard let fontCatalog else { return }
        var references: [String: FontRef] = [:]
        for cipher in library.ciphers where references[cipher.fontRef.id] == nil {
            references[cipher.fontRef.id] = cipher.fontRef
        }
        var summaries: [FontSummary] = []
        for reference in references.values.sorted(by: { $0.id < $1.id }) {
            summaries.append(await fontCatalog.summary(for: reference))
        }
        lastKnownFontSummaries = summaries
    }

    private static func failure(for error: Error) -> RuneScribeFailureDTO {
        if let productError = error as? RuneScribeProductError,
           case .failure(let failure) = productError {
            return failure
        }
        if error is CancellationError {
            return RuneScribeFailureDTO(code: .operationCancelled)
        }
        if let repositoryError = error as? CipherRepositoryError {
            switch repositoryError {
            case .secureStorageUnavailable:
                return RuneScribeFailureDTO(code: .secureStorageUnavailable)
            case .invalidSymmetricKey, .corruptedLibrary:
                return RuneScribeFailureDTO(code: .corruptedContent)
            case .unsupportedLibraryVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .encryptionFailed:
                return RuneScribeFailureDTO(code: .internalFailure)
            }
        }
        if error is MessageError {
            return RuneScribeFailureDTO(code: .noMatchingCipher)
        }
        if let lockError = error as? AppLockServiceError {
            switch lockError {
            case .invalidPINFormat:
                return RuneScribeFailureDTO(code: .invalidInput)
            case .incorrectPIN:
                return RuneScribeFailureDTO(code: .authenticationFailed)
            case .secureStorageUnavailable:
                return RuneScribeFailureDTO(code: .secureStorageUnavailable)
            }
        }
        if let fileError = error as? FileRouterError {
            switch fileError {
            case .unsupportedVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .empty, .malformedCipher, .malformedMessage:
                return RuneScribeFailureDTO(code: .corruptedContent)
            }
        }
        if let linkError = error as? LinkRouterError {
            switch linkError {
            case .invalidRoute, .invalidQuery:
                return RuneScribeFailureDTO(code: .invalidInput)
            case .invalidPayload:
                return RuneScribeFailureDTO(code: .corruptedContent)
            }
        }
        if let registryError = error as? ShareArtifactRegistryError {
            switch registryError {
            case .artifactNotFound:
                return RuneScribeFailureDTO(code: .itemNotFound)
            case .storageUnavailable:
                return RuneScribeFailureDTO(code: .shareUnavailable)
            }
        }
        if let readerError = error as? InboundFileReaderError {
            switch readerError {
            case .notFileURL, .invalidPath, .unsupportedFileType:
                return RuneScribeFailureDTO(code: .invalidInput)
            case .securityScopeDenied, .unavailable:
                return RuneScribeFailureDTO(code: .protectedFileUnavailable)
            case .contentTooLarge:
                return RuneScribeFailureDTO(code: .invalidInput)
            }
        }
        if let messageShareError = error as? MessageShareError {
            switch messageShareError {
            case .unsupportedVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .tooShort, .unsupportedFlags, .badChecksum, .invalidSenderName,
                 .invalidEnvelopeLength, .senderNameTooLong, .envelopeTooLarge:
                return RuneScribeFailureDTO(code: .corruptedContent)
            }
        }
        if let contactError = error as? ContactManagerError {
            switch contactError {
            case .contactNotFound:
                return RuneScribeFailureDTO(code: .itemNotFound)
            case .preparedContactConflict, .associationRecoveryRequired:
                return RuneScribeFailureDTO(code: .temporarilyUnavailable)
            }
        }
        if let contactRepositoryError = error as? ContactRepositoryError {
            switch contactRepositoryError {
            case .secureStorageUnavailable, .missingSymmetricKey, .invalidSymmetricKey:
                return RuneScribeFailureDTO(code: .secureStorageUnavailable)
            case .protectedStorageUnavailable:
                return RuneScribeFailureDTO(code: .protectedFileUnavailable)
            case .corruptedStore:
                return RuneScribeFailureDTO(code: .corruptedContent)
            case .unsupportedStoreVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .encryptionFailed:
                return RuneScribeFailureDTO(code: .internalFailure)
            }
        }
        if let fontError = error as? FontCatalogError {
            switch fontError {
            case .invalidReference:
                return RuneScribeFailureDTO(code: .invalidInput)
            case .unavailableFont, .resourceUnavailable:
                return RuneScribeFailureDTO(code: .resourceUnavailable)
            case .hashMismatch, .unreadableFont, .corruptedStoredFont:
                return RuneScribeFailureDTO(code: .corruptedContent)
            case .cannotRegister:
                return RuneScribeFailureDTO(code: .resourceUnavailable)
            case .protectedStorageUnavailable, .rollbackFailed:
                return RuneScribeFailureDTO(code: .protectedFileUnavailable)
            }
        }
        if let validationError = error as? CipherValidationError {
            switch validationError {
            case .unsupportedFormatVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .invalidPublicIDLength,
                 .invalidKeyMaterialLength,
                 .invalidDecorativeMapping,
                 .invalidFontReference:
                return RuneScribeFailureDTO(code: .corruptedContent)
            }
        }
        if let shareError = error as? CipherShareError {
            switch shareError {
            case .unsupportedVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .wrongSize, .badChecksum, .notAMapping,
                 .invalidPublicIDLength, .invalidKeyMaterialLength,
                 .invalidFontReference, .badBase64, .missingPayload:
                return RuneScribeFailureDTO(code: .corruptedContent)
            case .invalidURL:
                return RuneScribeFailureDTO(code: .invalidInput)
            }
        }
        return RuneScribeFailureDTO(code: .internalFailure)
    }
}
