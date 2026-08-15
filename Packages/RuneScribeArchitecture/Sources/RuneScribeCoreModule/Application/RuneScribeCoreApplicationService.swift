import CryptoKit
import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
import RuneScribeRuntimeCore

protocol CoreExistingUserMigrationSubmitting: Sendable {
    func submit(ciphers: [ExistingUserMigrationCipherDTO]) async throws
}

private struct RuntimeExistingUserMigrationSubmitter:
    CoreExistingUserMigrationSubmitting
{
    let client: RuntimeExistingUserMigrationClient

    func submit(ciphers: [ExistingUserMigrationCipherDTO]) async throws {
        _ = try await client.submit(ciphers: ciphers)
    }
}

/// The Core-owned, key-free application facade. Key-bearing ciphers and
/// persistence entities remain behind the private repository actor.
public actor RuneScribeCoreApplicationService: RuneScribeOperationAwareApplicationService,
    RuneScribeOperationAwareInboundInputService
{
    private enum InitializationState {
        case notStarted
        case loading
        case ready
        case failed
    }

    private struct QueuedInbound: Sendable {
        let input: RuneScribeInboundInput
        let progressionContext: RuntimePersistableOperationContext?
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

    private struct ShareTerminalProgressionFingerprint: Codable, Sendable {
        let artifactID: ShareArtifactID
        let report: SharePresentationReportDTO
    }

    static let encodedMessageRetryWindow = 64

    private let repository: CipherRepository
    private let runtimeIO: RuntimeIOClient
    private let progression: CoreProgressionCoordinator
    private let hasProgressionOutbox: Bool
    private let progressionOutboxClient: RuntimeProgressionOutboxClient?
    private let existingUserMigration: (any CoreExistingUserMigrationSubmitting)?
    private let messageService = MessageService()
    private let appLock: AppLockService
    private let artifactRegistry: ShareArtifactRegistry
    private var fontIntegration: (any CoreFontIntegrating)? = nil
    private var contactIntegration: (any CoreMessageContactAssociating)? = nil
    private var fontCatalog: FontCatalog? = nil
    private var contactManager: ContactManager? = nil

    private var initializationState: InitializationState = .notStarted
    private var didSweepRelaunchedEncodedHandles = false
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
    private var shareJournalAvailable = false
    private var pendingShareTerminalEvidence: [
        ShareArtifactID: ShareArtifactCompletionEvidenceDTO
    ] = [:]
    private var isRetryingShareTerminalEvidence = false
    private var shareAuthorizationGeneration: UInt64 = 0
    private var seenInboundIDs: Set<InboundInputID> = []
    private var seenInboundIDOrder: [InboundInputID] = []
    private var lastClipboardChangeCount = 0

    private var nextSubscriberID: UInt64 = 0
    private var subscribers: [UInt64: AsyncStream<RuneScribeApplicationSnapshot>.Continuation] = [:]

    // Service methods can interleave while awaiting the repository. Serializing
    // complete use cases prevents an older result from replacing newer state.
    private var useCaseInProgress = false
    private var useCaseWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        runtimeIO: RuntimeIOClient,
        progressionOutbox: RuntimeProgressionOutboxClient? = nil,
        existingUserMigration: RuntimeExistingUserMigrationClient? = nil
    ) {
        let repository = CipherRepository(runtimeIO: runtimeIO)
        let fontCatalog = FontCatalog(runtimeIO: runtimeIO)
        let contactManager = ContactManager(
            repository: EncryptedContactRepository(runtimeIO: runtimeIO),
            runtimeIO: runtimeIO
        )
        self.repository = repository
        self.runtimeIO = runtimeIO
        progression = CoreProgressionCoordinator(
            repository: repository,
            runtimeIO: runtimeIO,
            outbox: progressionOutbox
        )
        hasProgressionOutbox = progressionOutbox != nil
        progressionOutboxClient = progressionOutbox
        self.existingUserMigration = existingUserMigration.map {
            RuntimeExistingUserMigrationSubmitter(client: $0)
        }
        appLock = AppLockService(runtimeIO: runtimeIO)
        artifactRegistry = ShareArtifactRegistry(runtimeIO: runtimeIO)
        self.fontCatalog = fontCatalog
        self.contactManager = contactManager
        fontIntegration = fontCatalog
        contactIntegration = contactManager
    }

    init(
        runtimeIO: RuntimeIOClient,
        fontCatalog: FontCatalog?,
        contactManager: ContactManager?,
        progressionOutbox: RuntimeProgressionOutboxClient? = nil,
        existingUserMigration: RuntimeExistingUserMigrationClient? = nil
    ) {
        let repository = CipherRepository(runtimeIO: runtimeIO)
        self.repository = repository
        self.runtimeIO = runtimeIO
        progression = CoreProgressionCoordinator(
            repository: repository,
            runtimeIO: runtimeIO,
            outbox: progressionOutbox
        )
        hasProgressionOutbox = progressionOutbox != nil
        progressionOutboxClient = progressionOutbox
        self.existingUserMigration = existingUserMigration.map {
            RuntimeExistingUserMigrationSubmitter(client: $0)
        }
        appLock = AppLockService(runtimeIO: runtimeIO)
        artifactRegistry = ShareArtifactRegistry(runtimeIO: runtimeIO)
        self.fontCatalog = fontCatalog
        self.contactManager = contactManager
        fontIntegration = fontCatalog
        contactIntegration = contactManager
    }

    init(
        runtimeIO: RuntimeIOClient,
        fontCatalog: FontCatalog?,
        contactManager: ContactManager?,
        progressionTransport: (any CoreProgressionOutboxTransport)?,
        progressionTokens: any CoreProgressionTokenDeriving,
        existingUserMigration: (any CoreExistingUserMigrationSubmitting)? = nil
    ) {
        let repository = CipherRepository(runtimeIO: runtimeIO)
        self.repository = repository
        self.runtimeIO = runtimeIO
        progression = CoreProgressionCoordinator(
            repository: repository,
            tokens: progressionTokens,
            outbox: progressionTransport
        )
        hasProgressionOutbox = progressionTransport != nil
        progressionOutboxClient = nil
        self.existingUserMigration = existingUserMigration
        appLock = AppLockService(runtimeIO: runtimeIO)
        artifactRegistry = ShareArtifactRegistry(runtimeIO: runtimeIO)
        self.fontCatalog = fontCatalog
        self.contactManager = contactManager
        fontIntegration = fontCatalog
        contactIntegration = contactManager
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
        try await encode(command, progressionContext: nil)
    }

    public func encode(
        _ command: EncodeMessageCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> EncodedMessageResult {
        try await encode(command, progressionContext: context)
    }

    private func encode(
        _ command: EncodeMessageCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> EncodedMessageResult {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let progressionReady = await progressionEvidenceIsReady(
                for: progressionContext
            )
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
            var resultLibrary = library
            var shareHandle: EncodedMessageHandle?
            var instrumentationStatus: ProgressionInstrumentationStatusDTO = .unavailable

            if let progressionContext, progressionReady {
                do {
                    await compactEncodedMessageEvidenceForNewHandle()
                    let messageToken = try await progression.messageToken()
                    let handle = EncodedMessageHandle(
                        rawValue: try await runtimeIO.nextUUID()
                    )
                    var pending: [CorePendingProgressionBatch] = []
                    if let cipherSeed = try await repository
                        .cipherProgressionSeed(cipherID: cipher.id) {
                        do {
                            let cipherToken = try await progression.cipherToken(
                                for: cipherSeed
                            )
                            pending = try progressionBatches(
                                context: progressionContext,
                                facts: [try CoreProgressionFactFactory.messageEncoded(
                                    messageToken: messageToken,
                                    cipherToken: cipherToken
                                )]
                            )
                        } catch {
                            // Preserve the random message token and logical
                            // share handle even if only HMAC derivation fails.
                            pending = []
                        }
                    }
                    let record = try CoreEncodedMessageProgressionRecord(
                        handle: handle,
                        cipherID: cipher.id,
                        originatingContext: progressionContext,
                        encodedMessageDigest: CoreProgressionCoordinator.commandDigest(runes),
                        messageToken: messageToken,
                        codexIDs: [CoreProgressionFactFactory.implicitNorseCodexID],
                        artifactIDs: []
                    )
                    let mutation = try await repository
                        .commitEncodedMessageProgressionEvidence(
                            record,
                            pendingBatches: pending
                        )
                    do {
                        try await artifactRegistry.retainEncodedMessageHandle(handle)
                    } catch {
                        _ = try? await repository
                            .abandonEncodedMessageProgressionEvidence(handle: handle)
                        throw error
                    }
                    resultLibrary = mutation.library
                    shareHandle = handle
                    instrumentationStatus = pending.isEmpty
                        ? .degraded
                        : await instrumentationStatusAfterDrain(
                            evidenceWasRetained: true
                        )
                } catch {
                    // Encoding is a utility operation. A progression-only
                    // failure is surfaced in the typed result and never drops
                    // the authenticated rune output.
                    instrumentationStatus = .degraded
                }
            } else if progressionContext != nil {
                instrumentationStatus = hasProgressionOutbox ? .degraded : .unavailable
            }

            await adoptSuccessfulRead(resultLibrary)
            return EncodedMessageResult(
                runes: runes,
                cipherID: CipherID(rawValue: cipher.id),
                shareHandle: shareHandle,
                progressionInstrumentationStatus: instrumentationStatus
            )
        } catch {
            throw await record(error)
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
            await adoptSuccessfulRead(library)
            return DecodedMessageResult(
                plaintext: decoded.plaintext,
                cipherID: CipherID(rawValue: decoded.cipher.id),
                cipherName: decoded.cipher.label
            )
        } catch {
            throw await record(error)
        }
    }

    // MARK: - Cipher library

    public func createCipher(_ command: CreateCipherCommand) async throws -> CipherSummary {
        try await createCipher(command, progressionContext: nil)
    }

    public func createCipher(
        _ command: CreateCipherCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> CipherSummary {
        try await createCipher(command, progressionContext: context)
    }

    private func createCipher(
        _ command: CreateCipherCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> CipherSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let progressionReady = await progressionEvidenceIsReady(
                for: progressionContext
            )
            let mutation: CipherRepositoryMutation<Cipher>
            var retainedFacts = false
            if progressionReady {
                let seed = await resilientCipherProgressionSeed()
                var pending: [CorePendingProgressionBatch] = []
                if let progressionContext {
                    do {
                        let token = try await progression.cipherToken(for: seed)
                        pending = try progressionBatches(
                            context: progressionContext,
                            facts: [try CoreProgressionFactFactory.cipherCreated(
                                cipherToken: token
                            )]
                        )
                    } catch {
                        // The randomized encrypted seed remains useful for a
                        // future snapshot even when token derivation is down.
                        pending = []
                    }
                }
                do {
                    mutation = try await repository.createCipher(
                        label: command.name,
                        progressionSeed: seed,
                        pendingBatches: pending
                    )
                    retainedFacts = !pending.isEmpty
                } catch let error as CoreProgressionEvidenceError {
                    guard error == .collectionLimitExceeded else {
                        throw error
                    }
                    mutation = try await repository
                        .createCipherWithoutProgressionEvidence(
                        label: command.name,
                        pendingBatches: pending
                    )
                    retainedFacts = !pending.isEmpty
                }
            } else {
                mutation = try await repository.createCipher(label: command.name)
            }
            await adoptMutation(mutation.library)
            if retainedFacts { _ = await progression.drain() }
            return Self.summary(for: mutation.value, in: mutation.library)
        } catch {
            throw await record(error)
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
            await adoptMutation(mutation.library)
            return Self.summary(for: cipher, in: mutation.library)
        } catch {
            throw await record(error)
        }
    }

    public func deleteCipher(id: CipherID) async throws {
        try await deleteCipher(id: id, progressionContext: nil)
    }

    public func deleteCipher(
        id: CipherID,
        context: RuntimePersistableOperationContext
    ) async throws {
        try await deleteCipher(id: id, progressionContext: context)
    }

    private func deleteCipher(
        id: CipherID,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let progressionReady = await progressionEvidenceIsReady(
                for: progressionContext
            )
            let mutation: CipherRepositoryMutation<Bool>
            var retainedFacts = false
            if progressionReady {
                let library = try await repository.snapshot()
                let createsReplacement = library.ciphers.count == 1
                    && library.ciphers.first?.id == id.rawValue
                let replacementSeed = createsReplacement
                    ? await resilientCipherProgressionSeed()
                    : nil
                var pending: [CorePendingProgressionBatch] = []
                if let progressionContext, let replacementSeed {
                    do {
                        let token = try await progression.cipherToken(
                            for: replacementSeed
                        )
                        pending = try progressionBatches(
                            context: progressionContext,
                            facts: [try CoreProgressionFactFactory.cipherCreated(
                                cipherToken: token
                            )]
                        )
                    } catch {
                        pending = []
                    }
                }
                mutation = try await repository.deleteCipher(
                    id: id.rawValue,
                    replacementProgressionSeed: replacementSeed,
                    pendingBatches: pending
                )
                retainedFacts = !pending.isEmpty
            } else {
                mutation = try await repository.deleteCipher(id: id.rawValue)
            }
            await adoptMutation(mutation.library)
            if retainedFacts { _ = await progression.drain() }
        } catch {
            throw await record(error)
        }
    }

    public func setActiveCipher(_ command: SetActiveCipherCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let mutation = try await repository.setActiveCipher(id: command.cipherID.rawValue)
            await adoptMutation(mutation.library)
        } catch {
            throw await record(error)
        }
    }

    public func assignContact(_ command: AssignContactCommand) async throws {
        try await assignContact(command, progressionContext: nil)
    }

    public func assignContact(
        _ command: AssignContactCommand,
        context: RuntimePersistableOperationContext
    ) async throws {
        try await assignContact(command, progressionContext: context)
    }

    private func assignContact(
        _ command: AssignContactCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            let progressionReady = await progressionEvidenceIsReady(
                for: progressionContext
            )
            let mutation: CipherRepositoryMutation<Bool>
            if progressionReady {
                let relationshipSeed: Data?
                if let contactID = command.contactID?.rawValue,
                   try await repository.relationshipProgressionEvidence(
                       cipherID: command.cipherID.rawValue,
                       contactID: contactID
                   ) == nil {
                    relationshipSeed = await resilientRelationshipProgressionSeed()
                } else {
                    relationshipSeed = nil
                }
                do {
                    mutation = try await repository.assignContact(
                        cipherID: command.cipherID.rawValue,
                        contactID: command.contactID?.rawValue,
                        relationshipSeed: relationshipSeed,
                        pendingBatches: []
                    )
                } catch let error as CoreProgressionEvidenceError {
                    guard error == .collectionLimitExceeded else { throw error }
                    mutation = try await repository
                        .assignContactWithoutProgressionEvidence(
                        cipherID: command.cipherID.rawValue,
                        contactID: command.contactID?.rawValue,
                        pendingBatches: []
                    )
                }
            } else {
                mutation = try await repository.assignContact(
                    cipherID: command.cipherID.rawValue,
                    contactID: command.contactID?.rawValue
                )
            }
            await adoptMutation(mutation.library)
        } catch {
            throw await record(error)
        }
    }

    // MARK: - P4B operations

    public func createContact(_ command: CreateContactCommand) async throws -> ContactSummary {
        try await createContact(command, progressionContext: nil)
    }

    public func createContact(
        _ command: CreateContactCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ContactSummary {
        try await createContact(command, progressionContext: context)
    }

    private func createContact(
        _ command: CreateContactCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> ContactSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = await progressionEvidenceIsReady(for: progressionContext)
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let mutation = try await contactManager.create(command)
            let library = try await reconcileContactAssociations(
                in: mutation.book,
                progressionContext: progressionContext
            )
            await adoptContactMutation(mutation.book, library: library)
            return Self.contactSummary(
                mutation.value,
                linkedCount: Self.linkedCounts(in: library)[mutation.value.id, default: 0]
            )
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw await record(error)
        }
    }

    public func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary {
        try await updateContact(command, progressionContext: nil)
    }

    public func updateContact(
        _ command: UpdateContactCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> ContactSummary {
        try await updateContact(command, progressionContext: context)
    }

    private func updateContact(
        _ command: UpdateContactCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> ContactSummary {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = await progressionEvidenceIsReady(for: progressionContext)
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let mutation = try await contactManager.update(command)
            let library = try await reconcileContactAssociations(
                in: mutation.book,
                progressionContext: progressionContext
            )
            await adoptContactMutation(mutation.book, library: library)
            return Self.contactSummary(
                mutation.value,
                linkedCount: Self.linkedCounts(in: library)[mutation.value.id, default: 0]
            )
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw await record(error)
        }
    }

    public func deleteContacts(ids: Set<ContactID>) async throws {
        try await deleteContacts(ids: ids, progressionContext: nil)
    }

    public func deleteContacts(
        ids: Set<ContactID>,
        context: RuntimePersistableOperationContext
    ) async throws {
        try await deleteContacts(ids: ids, progressionContext: context)
    }

    private func deleteContacts(
        ids: Set<ContactID>,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = await progressionEvidenceIsReady(for: progressionContext)
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let removal = try await contactManager.delete(ids: Set(ids.map(\.rawValue)))
            let library = try await reconcileContactAssociations(
                in: removal.book,
                progressionContext: progressionContext
            )
            await adoptContactMutation(removal.book, library: library)
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw await record(error)
        }
    }

    public func deleteAllImportedContacts() async throws {
        try await deleteAllImportedContacts(progressionContext: nil)
    }

    public func deleteAllImportedContacts(
        context: RuntimePersistableOperationContext
    ) async throws {
        try await deleteAllImportedContacts(progressionContext: context)
    }

    private func deleteAllImportedContacts(
        progressionContext: RuntimePersistableOperationContext?
    ) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = await progressionEvidenceIsReady(for: progressionContext)
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let removal = try await contactManager.deleteAllImported()
            let library = try await reconcileContactAssociations(
                in: removal.book,
                progressionContext: progressionContext
            )
            await adoptContactMutation(removal.book, library: library)
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw await record(error)
        }
    }

    public func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary] {
        try await importContacts(command, progressionContext: nil)
    }

    public func importContacts(
        _ command: ImportContactsCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> [ContactSummary] {
        try await importContacts(command, progressionContext: context)
    }

    private func importContacts(
        _ command: ImportContactsCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> [ContactSummary] {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        var contactCommitMayHaveOccurred = false
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            _ = await progressionEvidenceIsReady(for: progressionContext)
            _ = try await repository.snapshot()
            contactCommitMayHaveOccurred = true
            let contactMutation = try await contactManager.importContacts(command)
            let library = try await reconcileContactAssociations(
                in: contactMutation.book,
                progressionContext: progressionContext
            )
            await adoptContactMutation(contactMutation.book, library: library)
            let counts = Self.linkedCounts(in: library)
            return contactMutation.added.map {
                Self.contactSummary($0, linkedCount: counts[$0.id, default: 0])
            }
        } catch {
            if contactCommitMayHaveOccurred {
                await repairContactAssociationsIndependently()
            }
            throw await record(error)
        }
    }

    public func requestSystemContacts() async throws -> [SystemContactDTO] {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            try await requireUnlocked()
            guard let contactManager else { throw unavailableError() }
            let granted = try await contactManager.requestAccess()
            let capturedAt = await snapshotTimestamp()
            contactAuthorization = await contactManager.authorizationStatus()
            guard granted else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .authorizationDenied)
                )
            }
            let contacts = try await contactManager.fetchSystemContacts()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            return contacts
        } catch {
            throw await record(error)
        }
    }

    public func prepareCipherShare(
        _ command: PrepareCipherShareCommand
    ) async throws -> ShareArtifactDTO {
        try await prepareCipherShare(command, persistsMetadata: false)
    }

    public func prepareCipherShare(
        _ command: PrepareCipherShareCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactDTO {
        try await prepareCipherShare(command, persistsMetadata: true)
    }

    private func prepareCipherShare(
        _ command: PrepareCipherShareCommand,
        persistsMetadata: Bool
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

            let artifactID = ShareArtifactID(rawValue: try await runtimeIO.nextUUID())
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
                    messageCipherID: nil,
                    persistsMetadata: persistsMetadata
                )
            case .link, .qrCode:
                let url = try payload.url(name: command.displayName)
                artifact = try await artifactRegistry.createLink(
                    url: url,
                    id: artifactID,
                    displayName: command.displayName ?? cipher.label,
                    persistsMetadata: persistsMetadata
                )
            }
            try await validatePreparedArtifactStillActive(
                artifact,
                requestGeneration: requestGeneration
            )
            await adoptSuccessfulRead(library)
            return artifact
        } catch {
            throw await record(error)
        }
    }

    public func prepareMessageShare(
        _ command: PrepareMessageShareCommand
    ) async throws -> ShareArtifactDTO {
        try await prepareMessageShare(command, persistsMetadata: false)
    }

    public func prepareMessageShare(
        _ command: PrepareMessageShareCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactDTO {
        try await prepareMessageShare(command, persistsMetadata: true)
    }

    private func prepareMessageShare(
        _ command: PrepareMessageShareCommand,
        persistsMetadata: Bool
    ) async throws -> ShareArtifactDTO {
        await retryPendingShareTerminalEvidence()
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

            var retainedShareHandle: EncodedMessageHandle?
            if let shareHandle = command.shareHandle,
               let evidence = try await repository
                .encodedMessageProgressionEvidence(handle: shareHandle) {
                guard evidence.cipherID == cipher.id,
                      evidence.encodedMessageDigest
                        == (try CoreProgressionCoordinator.commandDigest(command.runes))
                else {
                    throw RuneScribeProductError.failure(
                        RuneScribeFailureDTO(code: .invalidInput)
                    )
                }
                retainedShareHandle = shareHandle
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
            let artifactID = ShareArtifactID(rawValue: try await runtimeIO.nextUUID())
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
                    messageCipherID: cipher.id,
                    encodedMessageHandle: retainedShareHandle,
                    persistsMetadata: persistsMetadata
                )
            } else {
                artifact = try await artifactRegistry.createOpaqueMessage(
                    id: artifactID,
                    cipherID: cipher.id,
                    encodedMessageHandle: retainedShareHandle,
                    persistsMetadata: persistsMetadata
                )
            }
            try await validatePreparedArtifactStillActive(
                artifact,
                requestGeneration: requestGeneration
            )
            await adoptSuccessfulRead(library)
            return artifact
        } catch {
            throw await record(error)
        }
    }

    public func completeShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        if let evidence = command.evidence {
            return try await completeShareArtifact(
                evidence: evidence
            )
        }
        return try await completeLegacyShareArtifact(command)
    }

    public func completeShareArtifact(
        _ command: CompleteShareArtifactCommand,
        context _: RuntimePersistableOperationContext
    ) async throws -> ShareArtifactCompletionResultDTO {
        guard let evidence = command.evidence else {
            return try await completeLegacyShareArtifact(command)
        }
        return try await completeShareArtifact(evidence: evidence)
    }

    private func completeLegacyShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            let artifact = try await artifactRegistry.artifact(id: command.artifactID)
            guard artifact.encodedMessageHandle == nil else {
                throw RuneScribeProductError.failure(
                    RuneScribeFailureDTO(code: .invalidInput)
                )
            }
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
                await adoptMutation(mutation.library)
                recordedDelivery = true
            }
            try await artifactRegistry.release(id: command.artifactID)
            return recordedDelivery ? .deliveryRecorded : .released
        } catch {
            throw await record(error)
        }
    }

    private func completeShareArtifact(
        evidence: ShareArtifactCompletionEvidenceDTO
    ) async throws -> ShareArtifactCompletionResultDTO {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            let fingerprint = ShareTerminalProgressionFingerprint(
                artifactID: evidence.artifactID,
                report: evidence.report
            )
            let commandDigest = try CoreProgressionCoordinator.commandDigest(
                fingerprint
            )
            let resultDigest = try CoreProgressionCoordinator.commandDigest(
                evidence.report
            )
            let contextDigest = try CoreProgressionDigest.canonical(
                evidence.operationContext
            )
            let durable = try await artifactRegistry.journalTerminal(evidence)
            pendingShareTerminalEvidence[evidence.artifactID] = evidence

            if let completed = durable.completionDisposition {
                pendingShareTerminalEvidence.removeValue(forKey: evidence.artifactID)
                do {
                    try await compactCompletedShareTerminalEvidence()
                } catch {
                    shareCleanupNeedsRetry = true
                    return .retainedForRetry
                }
                return completed
            }

            let progressionReady = await progressionEvidenceIsReady(
                for: evidence.operationContext
            )
            guard progressionReady else {
                do {
                    try await artifactRegistry.releaseTerminalArtifact(durable)
                } catch {
                    shareCleanupNeedsRetry = true
                }
                shareCleanupNeedsRetry = true
                return .retainedForRetry
            }

            if let terminal = try await repository.shareTerminalProgressionEvidence(
                artifactID: evidence.artifactID
            ) {
                guard terminal.contextDigest == contextDigest,
                      terminal.commandDigest == commandDigest,
                      terminal.resultDigest == resultDigest
                else {
                    throw RuneScribeProductError.failure(
                        RuneScribeFailureDTO(code: .invalidInput)
                    )
                }
                if terminal.cleanupPending {
                    do {
                        try await artifactRegistry.releaseTerminalArtifact(durable)
                        let cleanup = try await repository
                            .markShareTerminalCleanupComplete(
                            artifactID: evidence.artifactID
                        )
                        await adoptMutation(cleanup.library)
                    } catch {
                        shareCleanupNeedsRetry = true
                        return .retainedForRetry
                    }
                }
                let disposition = durable.plannedDisposition ?? .released
                do {
                    _ = try await artifactRegistry.completeTerminal(
                        artifactID: evidence.artifactID,
                        disposition: disposition
                    )
                    try await compactCompletedShareTerminalEvidence()
                } catch {
                    shareCleanupNeedsRetry = true
                    return .retainedForRetry
                }
                pendingShareTerminalEvidence.removeValue(forKey: evidence.artifactID)
                shareCleanupNeedsRetry = !pendingShareTerminalEvidence.isEmpty
                return disposition
            }

            let encodedRecord: CoreEncodedMessageProgressionRecord?
            if let handle = durable.encodedMessageHandle {
                guard let record = try await repository
                    .encodedMessageProgressionEvidence(handle: handle)
                else {
                    throw RuneScribeProductError.failure(
                        RuneScribeFailureDTO(code: .itemNotFound)
                    )
                }
                encodedRecord = record
            } else {
                encodedRecord = nil
            }

            let library = try await repository.snapshot()
            let cipher = durable.messageCipherID.flatMap { cipherID in
                library.ciphers.first { $0.id == cipherID }
            }
            let contactID = cipher?.contactID
            let relationship: CoreRelationshipProgressionRecord?
            if let cipher, let contactID {
                relationship = try await repository.relationshipProgressionEvidence(
                    cipherID: cipher.id,
                    contactID: contactID
                )
            } else {
                relationship = nil
            }
            let relationshipToken: RelationshipToken?
            if let relationship {
                relationshipToken = try? await progression.relationshipToken(
                    for: relationship.seed
                )
            } else {
                relationshipToken = nil
            }

            let eligible = evidence.report.isEligibleTerminal(
                requiresKeyDelivery: durable.requiresKeyDelivery
            )
            let domainLinked = cipher != nil && contactID != nil
            let linkedRelationship = relationship != nil
            let completesKeyDelivery = eligible
                && durable.requiresKeyDelivery
                && domainLinked
                && cipher?.keyDeliveryState.requiresDelivery == true
            let needsFirstDeliveryEvent = eligible
                && linkedRelationship
                && relationship?.firstDeliveryEventCommitted == false
                && (completesKeyDelivery
                    || relationship?.keyDeliveryState == .completed)
            let establishesBidirectional = eligible
                && linkedRelationship
                && relationshipToken != nil
                && relationship?.hasAuthenticatedInbound == true
                && relationship?.bidirectionalEventCommitted == false

            var facts: [ProgressionEventFact] = []
            if let encodedRecord,
               let share = try CoreProgressionFactFactory.shareCompleted(
                   report: evidence.report,
                   messageToken: encodedRecord.messageToken,
                   codexIDs: encodedRecord.codexIDs,
                   artifactIDs: encodedRecord.artifactIDs,
                   keyIncluded: durable.requiresKeyDelivery,
                   relationshipToken: relationshipToken,
                   linkedRelationship: linkedRelationship
               ) {
                facts.append(share)
            }
            var commitsFirstDeliveryEvent = false
            if needsFirstDeliveryEvent, let cipher, let relationshipToken,
               let cipherSeed = try await repository.cipherProgressionSeed(
                   cipherID: cipher.id
               ), let cipherToken = try? await progression.cipherToken(
                   for: cipherSeed
               ), let firstDelivery = try? CoreProgressionFactFactory
                   .firstDeliveryCompleted(
                       cipherToken: cipherToken,
                       relationshipToken: relationshipToken
                   ) {
                facts.append(firstDelivery)
                commitsFirstDeliveryEvent = true
            }
            if establishesBidirectional, let relationshipToken {
                facts.append(try CoreProgressionFactFactory.bidirectionalEstablished(
                    relationshipToken: relationshipToken
                ))
            }
            let batches = try progressionBatches(
                context: evidence.operationContext,
                facts: facts
            )
            let plannedDisposition: ShareArtifactCompletionResultDTO =
                completesKeyDelivery ? .deliveryRecorded : .released
            let planned = try await artifactRegistry.planTerminalDisposition(
                artifactID: evidence.artifactID,
                disposition: plannedDisposition
            )
            let mutation = try await repository.commitShareTerminalProgression(
                artifactID: evidence.artifactID,
                context: evidence.operationContext,
                commandDigest: commandDigest,
                resultDigest: resultDigest,
                // A terminal consumes the artifact lease, not the logical
                // encoded result. UI reparses a fresh artifact for the same
                // handle; semantic message-token dedupe remains authoritative.
                encodedMessageHandle: nil,
                cipherID: domainLinked ? cipher?.id : nil,
                contactID: domainLinked ? contactID : nil,
                completesKeyDelivery: completesKeyDelivery,
                commitsFirstDeliveryEvent: commitsFirstDeliveryEvent,
                activity: CoreProgressionRelationshipActivity(
                    eligibleOutbound: eligible && linkedRelationship,
                    bidirectionalCommitted: establishesBidirectional
                ),
                pendingBatches: batches
            )
            await adoptMutation(mutation.library)
            guard mutation.value.keyDeliveryTransitioned
                    == (plannedDisposition == .deliveryRecorded)
            else {
                throw ShareArtifactRegistryError.terminalEvidenceCollision
            }
            let drainResult: CoreProgressionDrainResult? = batches.isEmpty
                ? nil
                : await progression.drain()

            do {
                try await artifactRegistry.releaseTerminalArtifact(planned)
                let cleanup = try await repository.markShareTerminalCleanupComplete(
                    artifactID: evidence.artifactID
                )
                await adoptMutation(cleanup.library)
                _ = try await artifactRegistry.completeTerminal(
                    artifactID: evidence.artifactID,
                    disposition: plannedDisposition
                )
                try await compactCompletedShareTerminalEvidence()
                pendingShareTerminalEvidence.removeValue(forKey: evidence.artifactID)
            } catch {
                shareCleanupNeedsRetry = true
                return .retainedForRetry
            }

            if drainResult != nil, drainResult != .durable {
                return .retainedForRetry
            }
            shareCleanupNeedsRetry = !pendingShareTerminalEvidence.isEmpty
            return plannedDisposition
        } catch {
            if pendingShareTerminalEvidence[evidence.artifactID] != nil {
                if let intent = try? await artifactRegistry.terminalIntent(
                    artifactID: evidence.artifactID
                ) {
                    try? await artifactRegistry.releaseTerminalArtifact(intent)
                }
                shareCleanupNeedsRetry = true
                return .retainedForRetry
            }
            throw await record(error)
        }
    }

    public func releaseShareArtifact(id: ShareArtifactID) async {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            try await artifactRegistry.release(id: id)
        } catch {
            shareCleanupNeedsRetry = true
            _ = await record(error)
        }
    }

    private func retryPendingShareTerminalEvidence() async {
        guard !isRetryingShareTerminalEvidence,
              !pendingShareTerminalEvidence.isEmpty
        else { return }
        isRetryingShareTerminalEvidence = true
        defer { isRetryingShareTerminalEvidence = false }
        let retained = pendingShareTerminalEvidence.values.sorted {
            if $0.operationContext.runtimeOccurredAtUTC
                != $1.operationContext.runtimeOccurredAtUTC {
                return $0.operationContext.runtimeOccurredAtUTC
                    < $1.operationContext.runtimeOccurredAtUTC
            }
            return $0.artifactID.rawValue.uuidString
                < $1.artifactID.rawValue.uuidString
        }
        for evidence in retained {
            _ = try? await completeShareArtifact(evidence: evidence)
        }
    }

    private func restoreDurableShareTerminalEvidence() async throws {
        let intents = try await artifactRegistry.terminalIntents()
        for intent in intents {
            guard let evidence = intent.terminalEvidence else {
                throw ShareArtifactRegistryError.storageUnavailable
            }
            if let retained = pendingShareTerminalEvidence[intent.artifactID] {
                guard retained == evidence else {
                    throw ShareArtifactRegistryError.terminalEvidenceCollision
                }
            } else {
                pendingShareTerminalEvidence[intent.artifactID] = evidence
            }
        }
    }

    public func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO {
        try await importFile(input, progressionContext: nil)
    }

    public func importFile(
        _ input: InboundFileDTO,
        context: RuntimePersistableOperationContext
    ) async throws -> ImportResultDTO {
        try await importFile(input, progressionContext: context)
    }

    private func importFile(
        _ input: InboundFileDTO,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> ImportResultDTO {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }

        do {
            try await requireUnlocked()
            guard input.data.count <= Self.maximumInboundFileByteCount else {
                throw InboundFileReaderError.contentTooLarge
            }
            let data = input.data
            let dedupeKey = Self.digest(data)
            if activeImportDedupeKeys.contains(dedupeKey) {
                restoreImportStateAfterDuplicate()
                return ImportResultDTO(disposition: .duplicate)
            }
            guard activeImportID == nil, messageState.pendingMessage == nil else {
                return ImportResultDTO(disposition: .ignored)
            }
            let capturedAt = await snapshotTimestamp()
            importState = ImportStateDTO(phase: .validating)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            let result = try await ingestFileData(
                data,
                dedupeKey: dedupeKey,
                source: .file,
                progressionRoute: Self.progressionRoute(
                    for: input.metadata.source
                ),
                progressionContext: progressionContext
            )
            return result
        } catch {
            importState = ImportStateDTO(
                phase: .failed,
                lastFailure: Self.failure(for: error)
            )
            throw await record(error)
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
            let capturedAt = await snapshotTimestamp()
            importState = ImportStateDTO(phase: .validating)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            let source = Self.importSource(for: input.metadata.source)
            let pending = ImportUseCase.pending(
                payload: payload,
                fontBytes: nil,
                id: ImportID(rawValue: try await runtimeIO.nextUUID()),
                source: source,
                dedupeKey: dedupeKey
            )
            await setPendingImport(pending)
            return ImportResultDTO(
                disposition: .awaitingConfirmation,
                pendingImport: pending.summary
            )
        } catch {
            importState = ImportStateDTO(
                phase: .failed,
                lastFailure: Self.failure(for: error)
            )
            throw await record(error)
        }
    }

    public func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary {
        try await confirmImport(command, progressionContext: nil)
    }

    public func confirmImport(
        _ command: ConfirmImportCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> CipherSummary {
        try await confirmImport(command, progressionContext: context)
    }

    private func confirmImport(
        _ command: ConfirmImportCommand,
        progressionContext: RuntimePersistableOperationContext?
    ) async throws -> CipherSummary {
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
            let capturedAt = await snapshotTimestamp()
            importState = ImportStateDTO(phase: .importing, pending: pending.summary)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))

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
            let progressionReady = await progressionEvidenceIsReady(
                for: progressionContext
            )
            let mutation: CipherRepositoryMutation<Cipher>
            var retainedFacts = false
            if progressionReady {
                let seed = await resilientCipherProgressionSeed()
                var batches: [CorePendingProgressionBatch] = []
                if let progressionContext {
                    do {
                        let token = try await progression.cipherToken(for: seed)
                        batches = try progressionBatches(
                            context: progressionContext,
                            facts: [try CoreProgressionFactFactory.cipherImported(
                                cipherToken: token,
                                routeClass: Self.progressionRoute(for: pending.source)
                            )]
                        )
                    } catch {
                        batches = []
                    }
                }
                do {
                    mutation = try await repository.importCipher(
                        pending.payload,
                        label: command.name,
                        progressionSeed: seed,
                        pendingBatches: batches
                    )
                    retainedFacts = !batches.isEmpty
                } catch let error as CoreProgressionEvidenceError {
                    guard error == .collectionLimitExceeded else {
                        throw error
                    }
                    mutation = try await repository
                        .importCipherWithoutProgressionEvidence(
                        pending.payload,
                        label: command.name,
                        pendingBatches: batches
                    )
                    retainedFacts = !batches.isEmpty
                }
            } else {
                mutation = try await repository.importCipher(
                    pending.payload,
                    label: command.name
                )
            }
            await refreshFontSummaries(for: mutation.library)
            removePendingImport(pending)
            confirmingImportIDs.remove(command.importID)
            committingImportIDs.remove(command.importID)
            importCancellationGenerations.removeValue(forKey: command.importID)
            importState = ImportStateDTO(phase: .completed)
            await adoptMutation(mutation.library)
            if retainedFacts { _ = await progression.drain() }
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
            throw await record(error)
        }
    }

    public func cancelImport(id: ImportID) async {
        let capturedAt = await snapshotTimestamp()
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
        broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        if useCaseInProgress { return }
        await drainInboundQueueIfPossible()
    }

    public func dismissReceivedMessage(id: MessageID) async {
        let capturedAt = await snapshotTimestamp()
        guard messageState.pendingMessage?.id == id else { return }
        if let key = messageDedupeKeys.removeValue(forKey: id) {
            forgetHandledDedupeKey(key)
        }
        if let sourceKey = messageSourceDedupeKeys.removeValue(forKey: id) {
            queuedInboundDedupeKeys.remove(sourceKey)
        }
        messageState = MessageStateDTO(phase: .idle)
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        await drainInboundQueueIfPossible()
    }

    public func lock() async {
        let capturedAt = await snapshotTimestamp()
        shareAuthorizationGeneration &+= 1
        do {
            try await appLock.lockIfEnabled()
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        } catch {
            lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
            _ = await record(error)
        }
    }

    public func verifyPIN(_ input: PINInput) async throws -> Bool {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        do {
            return try await appLock.verifyForManagement(input)
        } catch {
            throw await record(error)
        }
    }

    public func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO {
        await acquireUseCasePermit()
        let capturedAt = await snapshotTimestamp()
        do {
            let result = try await appLock.unlock(command.input)
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            releaseUseCasePermit()
            if case .unlocked = result {
                await drainInboundQueueIfPossible()
            }
            return result
        } catch {
            releaseUseCasePermit()
            throw await record(error)
        }
    }

    public func setPIN(_ command: SetPINCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        let capturedAt = await snapshotTimestamp()
        do {
            try await appLock.setPIN(command.input)
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        } catch {
            await refreshLockStateAfterSecurityFailure()
            throw await record(error)
        }
    }

    public func changePIN(_ command: ChangePINCommand) async throws {
        await acquireUseCasePermit()
        defer { releaseUseCasePermit() }
        let capturedAt = await snapshotTimestamp()
        do {
            try await appLock.changePIN(
                current: command.current,
                replacement: command.replacement
            )
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        } catch {
            await refreshLockStateAfterSecurityFailure()
            throw await record(error)
        }
    }

    public func disablePIN(_ command: DisablePINCommand) async throws {
        await acquireUseCasePermit()
        let capturedAt = await snapshotTimestamp()
        do {
            try await appLock.disablePIN(current: command.current)
            lockState = try await appLock.state()
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            releaseUseCasePermit()
            await drainInboundQueueIfPossible()
        } catch {
            await refreshLockStateAfterSecurityFailure()
            releaseUseCasePermit()
            throw await record(error)
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
            if let progressionOutboxClient {
                do {
                    let outstanding = try await progressionOutboxClient
                        .outstandingShareCompletionArtifactIDs()
                    _ = try await artifactRegistry.reconcilePreparedArtifacts(
                        retaining: outstanding
                    )
                } catch {
                    // Query failure is fail-safe: retain all prepared linkage.
                    shareCleanupNeedsRetry = true
                }
            }
            do {
                try await restoreDurableShareTerminalEvidence()
                shareJournalAvailable = true
                await retryPendingShareTerminalEvidence()
            } catch {
                // Legacy/direct utility remains available without the optional
                // durable share rail. Operation-aware preparation still fails
                // closed when it attempts to persist its descriptor.
                shareJournalAvailable = false
                shareCleanupNeedsRetry = true
            }
            // A new activation must first prove that no stale key-bearing
            // artifact survived the previous lifetime. Prepared metadata and
            // exact terminal intents remain encrypted for Runtime redelivery.
            try await artifactRegistry.releaseAll(
                updatingDurableJournal: shareJournalAvailable
            )
            if shareJournalAvailable {
                await retryPendingShareTerminalEvidence()
            }
            if shareJournalAvailable,
               pendingShareTerminalEvidence.isEmpty {
                try await reconcileRelaunchedShareTerminalEvidence()
            }
            if shareJournalAvailable {
                await sweepRelaunchedEncodedHandles()
            }
            if let current = try? await repository.snapshot() {
                lastKnownLibrary = current
            }
            let capturedAt = await snapshotTimestamp()
            acceptsSharePreparation = true
            if pendingShareTerminalEvidence.isEmpty,
               shareCleanupNeedsRetry,
               lastFailure?.code == .shareUnavailable {
                lastFailure = nil
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            }
            shareCleanupNeedsRetry = !pendingShareTerminalEvidence.isEmpty
        } catch {
            acceptsSharePreparation = false
            shareCleanupNeedsRetry = true
            _ = await record(error)
        }
        await drainInboundQueueIfPossible()
    }

    /// Runtime stop revokes every outstanding share lease and returns inbound
    /// delivery to its pre-start queued state for a later restart.
    public func stopInboundProcessing() async {
        acceptsSharePreparation = false
        shareAuthorizationGeneration &+= 1
        await retryPendingShareTerminalEvidence()
        await acquireUseCasePermit()
        inboundStarted = false
        do {
            let wasRetryingCleanup = shareCleanupNeedsRetry
            try await artifactRegistry.releaseAll(
                updatingDurableJournal: shareJournalAvailable
            )
            let capturedAt = await snapshotTimestamp()
            shareCleanupNeedsRetry = !pendingShareTerminalEvidence.isEmpty
            if wasRetryingCleanup,
               lastFailure?.code == .shareUnavailable {
                lastFailure = nil
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            }
        } catch {
            // Registry retains every lease on failure; the next start retries
            // authoritative store cleanup before enabling new shares.
            shareCleanupNeedsRetry = true
            _ = await record(error)
        }
        releaseUseCasePermit()
    }

    public func receive(
        _ input: RuneScribeInboundInput
    ) async throws -> InboundInputDispositionDTO {
        await enqueueInbound(input, progressionContext: nil)
    }

    public func receive(
        _ input: RuneScribeInboundInput,
        context: RuntimePersistableOperationContext
    ) async throws -> InboundInputDispositionDTO {
        await enqueueInbound(input, progressionContext: context)
    }

    private func enqueueInbound(
        _ input: RuneScribeInboundInput,
        progressionContext: RuntimePersistableOperationContext?
    ) async -> InboundInputDispositionDTO {
        guard Self.hasBoundedInboundMetadata(input) else {
            return await rejectInbound(code: .invalidInput)
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
            else { return await rejectInbound(code: .temporarilyUnavailable) }
        } else {
            guard totalCount < Self.maximumQueuedInputs else {
                return await rejectInbound(code: .temporarilyUnavailable)
            }
        }

        let queued = QueuedInbound(
            input: input,
            progressionContext: progressionContext,
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
    ) async -> InboundInputDispositionDTO {
        _ = await record(
            RuneScribeProductError.failure(
                RuneScribeFailureDTO(code: code)
            )
        )
        return .rejected
    }

    private func processInbound(
        _ queued: QueuedInbound
    ) async throws -> InboundInputDispositionDTO {
        let input = queued.input
        switch input {
        case .file(let file):
            let result: ImportResultDTO
            if let context = queued.progressionContext {
                result = try await importFile(file, context: context)
            } else {
                result = try await importFile(file)
            }
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
        case .menu:
            // Menu presentation is admitted by the single runtime-owned route
            // rail after Core has processed this ordered ingress item.
            return .accepted
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
                        let disposition = try await processInbound(probe)
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
                let disposition = try await processInbound(next)
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
              let clipboard = try? await runtimeIO.clipboardSnapshot()
        else { return }
        guard clipboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = clipboard.changeCount
        guard let raw = clipboard.string else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= LinkRouter.maximumURLByteCount,
              let url = URL(string: trimmed),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              LinkRouter.isSupportedRoute(components)
        else { return }

        guard let inputID = try? await runtimeIO.nextUUID() else { return }
        let clipboardInput = InboundURLDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: inputID),
                receivedAt: metadata.receivedAt,
                source: .clipboard,
                isColdStart: false
            ),
            url: url
        )
        _ = try? await importURL(clipboardInput)
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
            return digest(value.data)
        case .lifecycle, .menu:
            return nil
        }
    }

    private static let maximumQueuedInputs = 512
    private static let maximumQueuedDataInputs = 496
    private static let maximumInboundFileByteCount = 16 * 1_024 * 1_024
    private static let maximumDeclaredContentTypeByteCount = 256

    private static func hasBoundedInboundMetadata(
        _ input: RuneScribeInboundInput
    ) -> Bool {
        switch input {
        case .url(let value):
            value.url.absoluteString.utf8.count <= LinkRouter.maximumURLByteCount
        case .file(let value):
            value.data.count <= maximumInboundFileByteCount
                && (value.declaredContentType?.utf8.count ?? 0)
                    <= maximumDeclaredContentTypeByteCount
        case .lifecycle, .menu:
            true
        }
    }

    // MARK: - Optional progression evidence

    /// Existing direct-service callers remain on the v1 utility rail until an
    /// operation-aware context or the production outbox is present. Once a
    /// library is v2, every mutation continues through the v2 APIs even if the
    /// optional outbox is temporarily unavailable.
    private func progressionEvidenceIsReady(
        for context: RuntimePersistableOperationContext?
    ) async -> Bool {
        do {
            let library = try await repository.snapshot()
            if library.version == CipherLibrary.currentVersion { return true }
            guard context != nil || hasProgressionOutbox else { return false }
            let migrated = try await progression.migrateEvidenceIfNeeded()
            return migrated.version == CipherLibrary.currentVersion
        } catch {
            return false
        }
    }

    /// Progression token entropy is optional instrumentation. Once the library
    /// is v2, utility mutations still need a valid encrypted seed even when the
    /// injected token provider is unavailable, so fall back to fresh local
    /// cryptographic randomness and omit only facts that cannot be derived.
    private func resilientCipherProgressionSeed() async -> Data {
        (try? await progression.cipherSeed()) ?? Self.randomizedProgressionSeed()
    }

    private func resilientRelationshipProgressionSeed() async -> Data {
        (try? await progression.relationshipSeed())
            ?? Self.randomizedProgressionSeed()
    }

    private nonisolated static func randomizedProgressionSeed() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private func progressionBatches(
        context: RuntimePersistableOperationContext,
        facts: [ProgressionEventFact]
    ) throws -> [CorePendingProgressionBatch] {
        try CoreProgressionCoordinator.pendingBatches(
            context: context,
            commandDigest: CoreProgressionCoordinator.commandDigest(facts),
            facts: facts
        )
    }

    private func instrumentationStatusAfterDrain(
        evidenceWasRetained: Bool
    ) async -> ProgressionInstrumentationStatusDTO {
        guard evidenceWasRetained else { return .degraded }
        switch await progression.drain() {
        case .durable:
            return .durable
        case .retainedForRetry, .unavailable:
            return .retainedForRetry
        }
    }

    /// Startup retries the Runtime-owned, schema-keyed handoff from encrypted
    /// Core evidence. Handoff failure cannot block utility and does not erase
    /// the randomized seeds needed to derive the exact same snapshot later.
    private func reconcileProgressionAtStartup(
        _ library: CipherLibrary
    ) async -> CipherLibrary {
        guard hasProgressionOutbox || existingUserMigration != nil,
              let migrated = try? await progression.migrateEvidenceIfNeeded()
        else { return library }

        let reconciled = await reconcileDeferredFirstDeliveryEvents(in: migrated)

        if let existingUserMigration,
           let coreSnapshot = try? await progression.existingUserMigrationSnapshot(),
           let ciphers = try? Self.existingUserMigrationCiphers(
               from: coreSnapshot
           ) {
            try? await existingUserMigration.submit(ciphers: ciphers)
        }
        if hasProgressionOutbox {
            _ = await progression.drain()
        }
        return reconciled
    }

    /// If crypto delivery committed while token derivation was unavailable,
    /// retry only the missing first-delivery fact with fresh Runtime authority.
    /// Migrated-unverified legacy delivery is deliberately ineligible here.
    private func reconcileDeferredFirstDeliveryEvents(
        in library: CipherLibrary
    ) async -> CipherLibrary {
        guard hasProgressionOutbox,
              let ledger = try? await repository.progressionEvidenceSnapshot()
        else { return library }
        var current = library
        let deferred = ledger.relationships.filter {
            $0.keyDeliveryState == .completed
                && $0.hasEligibleOutbound
                && !$0.firstDeliveryEventCommitted
        }
        for relationship in deferred {
            do {
                let identity = relationship.identity
                guard let cipherSeed = try await repository.cipherProgressionSeed(
                    cipherID: identity.cipherID
                ) else { continue }
                let context = try await progression.issueContext(
                    for: .coreReconciliation
                )
                let fact = try CoreProgressionFactFactory.firstDeliveryCompleted(
                    cipherToken: try await progression.cipherToken(for: cipherSeed),
                    relationshipToken: try await progression.relationshipToken(
                        for: relationship.seed
                    )
                )
                let batches = try progressionBatches(
                    context: context,
                    facts: [fact]
                )
                let mutation = try await repository.recordRelationshipProgressionActivity(
                    cipherID: identity.cipherID,
                    contactID: identity.contactID,
                    completesKeyDelivery: false,
                    commitsFirstDeliveryEvent: true,
                    activity: .init(),
                    pendingBatches: batches
                )
                current = mutation.library
            } catch {
                // Encrypted state remains retryable on the next activation.
                continue
            }
        }
        return current
    }

    static func existingUserMigrationDTO(
        from snapshot: CoreProgressionMigrationSnapshot
    ) throws -> ExistingUserMigrationSnapshotDTO {
        try ExistingUserMigrationSnapshotDTO(
            ciphers: existingUserMigrationCiphers(from: snapshot)
        )
    }

    static func existingUserMigrationCiphers(
        from snapshot: CoreProgressionMigrationSnapshot
    ) throws -> [ExistingUserMigrationCipherDTO] {
        try snapshot.ciphers.map { cipher in
            let origin: DomainEventOrigin = switch cipher.origin {
            case .generated: .generated
            case .imported: .imported
            }
            return try ExistingUserMigrationCipherDTO(
                cipherToken: cipher.cipherToken,
                origin: origin
            )
        }
    }

    /// Logical encoded handles are process-session leases. Their already
    /// committed event batches are independent encrypted records, so a new Core
    /// service may discard stale handles only after first attempting receipt and
    /// pending-fact reconciliation. This runs once per service construction.
    private func sweepRelaunchedEncodedHandles() async {
        guard !didSweepRelaunchedEncodedHandles else { return }
        guard let ledger = try? await repository.progressionEvidenceSnapshot()
        else { return }
        for record in ledger.encodedMessages {
            let retained: Bool
            do {
                retained = try await artifactRegistry.hasRetainedArtifact(
                    encodedMessageHandle: record.handle
                )
            } catch {
                return
            }
            guard !retained else { continue }
            if let mutation = try? await repository
                .abandonEncodedMessageProgressionEvidence(handle: record.handle),
               mutation.value {
                try? await artifactRegistry.releaseEncodedMessageHandle(record.handle)
            }
        }
        didSweepRelaunchedEncodedHandles = true
    }

    /// Keeps the session-scoped handle rail below its repository hard cap.
    /// Persisted chronology is authoritative; any handle still referenced by
    /// a prepared artifact or incomplete terminal remains protected.
    private func compactEncodedMessageEvidenceForNewHandle() async {
        guard let ledger = try? await repository.progressionEvidenceSnapshot()
        else { return }
        var remaining = ledger.encodedMessages.count
        guard remaining >= Self.encodedMessageRetryWindow else { return }
        guard let chronology = try? await artifactRegistry
            .encodedMessageHandleChronology()
        else { return }
        let records = Dictionary(uniqueKeysWithValues: ledger.encodedMessages.map {
            ($0.handle, $0)
        })
        for stale in chronology where records[stale] == nil {
            try? await artifactRegistry.releaseEncodedMessageHandle(stale)
        }
        for handle in chronology where remaining >= Self.encodedMessageRetryWindow {
            guard let record = records[handle] else { continue }
            let isRetained: Bool
            do {
                isRetained = try await artifactRegistry.hasRetainedArtifact(
                    encodedMessageHandle: record.handle
                )
            } catch {
                return
            }
            guard !isRetained else { continue }
            if let mutation = try? await repository
                .abandonEncodedMessageProgressionEvidence(handle: record.handle),
               mutation.value {
                remaining -= 1
                try? await artifactRegistry.releaseEncodedMessageHandle(
                    record.handle
                )
            }
        }
    }

    /// Registry tombstones retain the deterministic retry window. Any older
    /// cleanup-complete repository tombstone is now redundant and may be
    /// compacted without touching pending facts or incomplete cleanup.
    private func compactCompletedShareTerminalEvidence() async throws {
        let retained = try await artifactRegistry.retainedCompletedTerminalIDs()
        let incomplete = Set(try await artifactRegistry.terminalIntents().map(
            \.artifactID
        ))
        let ledger = try await repository.progressionEvidenceSnapshot()
        let retired: Set<ShareArtifactID> = Set(
            ledger.shareTerminals.compactMap { terminal -> ShareArtifactID? in
            guard !terminal.cleanupPending,
                  !retained.contains(terminal.artifactID),
                  !incomplete.contains(terminal.artifactID)
            else { return nil }
            return terminal.artifactID
        })
        guard !retired.isEmpty else { return }
        let mutation = try await repository.retireShareTerminalEvidence(
            artifactIDs: retired
        )
        await adoptMutation(mutation.library)
    }

    /// Global startup cleanup proves that no artifact from the prior process is
    /// still externally addressable. Its terminal tombstones can therefore be
    /// completed and retired before new callbacks become possible.
    private func reconcileRelaunchedShareTerminalEvidence() async throws {
        guard !didSweepRelaunchedEncodedHandles,
              let ledger = try? await repository.progressionEvidenceSnapshot()
        else { return }
        let pendingCleanup = ledger.shareTerminals.filter(\.cleanupPending)
        for terminal in pendingCleanup {
            _ = try await repository.markShareTerminalCleanupComplete(
                artifactID: terminal.artifactID
            )
        }
        try await compactCompletedShareTerminalEvidence()
    }

    // MARK: - Import/message internals

    private func ingestFileData(
        _ data: Data,
        dedupeKey: Data,
        source: ImportSourceDTO,
        progressionRoute: DomainEventRouteClass,
        progressionContext: RuntimePersistableOperationContext?
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
                id: ImportID(rawValue: try await runtimeIO.nextUUID()),
                source: source,
                dedupeKey: dedupeKey
            )
            await setPendingImport(pending)
            return ImportResultDTO(
                disposition: .awaitingConfirmation,
                pendingImport: pending.summary
            )

        case .message(let payload, let fontBytes):
            let progressionReady = await progressionEvidenceIsReady(
                for: progressionContext
            )
            var admittedPackageToken: PackageToken?
            var admissionEvidenceRetained = false
            if progressionReady, let progressionContext {
                do {
                    let packageToken = try await progression.packageToken(
                        for: data
                    )
                    let fact = try CoreProgressionFactFactory.messageImported(
                        packageToken: packageToken,
                        routeClass: progressionRoute,
                        embeddedCipher: payload.embeddedCipher != nil
                    )
                    let batches = try progressionBatches(
                        context: progressionContext,
                        facts: [fact]
                    )
                    _ = try await repository.appendPendingProgressionBatches(batches)
                    admittedPackageToken = packageToken
                    admissionEvidenceRetained = true
                    // Admission is committed before AEAD and may be drained
                    // immediately; failure leaves the exact batch encrypted.
                    _ = await progression.drain()
                } catch {
                    // Package utility remains available. A later decoded fact is
                    // deliberately suppressed unless its admission fact was
                    // durably retained first.
                }
            }

            let capturedAt = await snapshotTimestamp()
            messageState = MessageStateDTO(phase: .receiving)
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
            do {
                // Optional instrumentation entropy must never become a
                // prerequisite for authenticated message utility. A missing
                // seed keeps a new embedded cipher transient and skips only a
                // new relationship record; AEAD can still succeed.
                let embeddedCipherSeed: Data? = if progressionReady
                    && payload.embeddedCipher != nil {
                    await resilientCipherProgressionSeed()
                } else {
                    nil
                }
                let relationshipSeed: Data? = if progressionReady {
                    await resilientRelationshipProgressionSeed()
                } else {
                    nil
                }
                let mutation = try await MessageImportUseCase.ingest(
                    payload: payload,
                    fontBytes: fontBytes,
                    repository: repository,
                    messageService: messageService,
                    fontIntegration: fontIntegration,
                    contactIntegration: contactIntegration,
                    runtimeIO: runtimeIO,
                    progression: progression,
                    usesProgressionEvidence: progressionReady,
                    admittedPackageToken: admissionEvidenceRetained
                        ? admittedPackageToken
                        : nil,
                    progressionRoute: progressionRoute,
                    embeddedCipherProgressionSeed: embeddedCipherSeed,
                    relationshipProgressionSeed: relationshipSeed
                )
                let resultingLibrary = mutation.library
                if let contactManager,
                   let contactBook = try? await contactManager.snapshot() {
                    lastKnownContactBook = contactBook
                }
                await refreshFontSummaries(for: resultingLibrary)
                rememberHandledDedupeKey(dedupeKey)
                messageDedupeKeys[mutation.message.id] = dedupeKey
                messageState = MessageStateDTO(
                    phase: .received,
                    pendingMessage: mutation.message
                )
                importState = ImportStateDTO(phase: .completed)
                await adoptMutation(resultingLibrary)
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

    private func setPendingImport(_ pending: PendingCipherImport) async {
        let capturedAt = await snapshotTimestamp()
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
        broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
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
                let reconciliationContext = try? await progression.issueContext(
                    for: .coreReconciliation
                )
                let state = try await Self.recoverAndReconcileContactAssociations(
                    contactManager: contactManager,
                    repository: repository,
                    progression: progression,
                    progressionContext: reconciliationContext
                )
                library = state.library
                lastKnownContactBook = state.book
                contactAuthorization = await contactManager.authorizationStatus()
            }
            library = await reconcileProgressionAtStartup(library)
            if let fontCatalog {
                // Shipping launch treated font-registration failures as
                // nonfatal. Strict catalog operations remain available to the
                // import path, but a corrupt optional font cannot block Core.
                _ = try? await fontCatalog.registerAvailableFonts()
            }
            await refreshFontSummaries(for: library)
            let capturedAt = await snapshotTimestamp()
            lastKnownLibrary = library
            lockState = loadedLock
            lastFailure = nil
            initializationState = .ready
            revision &+= 1
            broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        } catch {
            lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
            initializationState = .failed
            _ = await record(error)
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

    private static func progressionRoute(
        for source: ImportSourceDTO
    ) -> DomainEventRouteClass {
        switch source {
        case .file, .embeddedMessage:
            return .file
        case .link:
            return .customURL
        case .qrCode:
            return .qrCode
        case .clipboard:
            return .clipboard
        }
    }

    private static func progressionRoute(
        for source: InboundDeliverySourceDTO
    ) -> DomainEventRouteClass {
        switch source {
        case .qrScanner:
            return .qrCode
        case .clipboard:
            return .clipboard
        case .webBrowsingActivity:
            return .customURL
        case .applicationOpen, .sceneOpen, .fileImporter:
            return .file
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
        let capturedAt = await snapshotTimestamp()

        switch initializationState {
        case .notStarted:
            initializationState = .loading
            continuation.yield(makeSnapshot(isLoading: true, capturedAt: capturedAt))
            await acquireUseCasePermit()
            do {
                var library = try await repository.snapshot()
                let loadedLock = try await appLock.state()
                if let contactManager {
                    let reconciliationContext = try? await progression.issueContext(
                        for: .coreReconciliation
                    )
                    let state = try await Self.recoverAndReconcileContactAssociations(
                        contactManager: contactManager,
                        repository: repository,
                        progression: progression,
                        progressionContext: reconciliationContext
                    )
                    library = state.library
                    lastKnownContactBook = state.book
                    contactAuthorization = await contactManager.authorizationStatus()
                }
                library = await reconcileProgressionAtStartup(library)
                if let fontCatalog {
                    _ = try? await fontCatalog.registerAvailableFonts()
                }
                await refreshFontSummaries(for: library)
                let readyCapturedAt = await snapshotTimestamp()
                lastKnownLibrary = library
                lockState = loadedLock
                lastFailure = nil
                initializationState = .ready
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false, capturedAt: readyCapturedAt))
            } catch {
                // Secure-state uncertainty fails closed; a nonloading snapshot is
                // never published as unlocked when PIN storage could not be read.
                lockState = ApplicationLockStateDTO(isPINSet: true, isLocked: true)
                initializationState = .failed
                _ = await record(error)
            }
            releaseUseCasePermit()

        case .loading:
            continuation.yield(makeSnapshot(isLoading: true, capturedAt: capturedAt))

        case .ready, .failed:
            continuation.yield(makeSnapshot(isLoading: false, capturedAt: capturedAt))
        }
    }

    private func detach(_ subscriberID: UInt64) {
        subscribers.removeValue(forKey: subscriberID)
    }

    private func adoptSuccessfulRead(_ library: CipherLibrary) async {
        let capturedAt = await snapshotTimestamp()
        let stateChanged = initializationState != .ready || lastFailure != nil
        lastKnownLibrary = library
        lastFailure = nil
        initializationState = .ready
        guard stateChanged else { return }
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
    }

    private func adoptMutation(_ library: CipherLibrary) async {
        let capturedAt = await snapshotTimestamp()
        lastKnownLibrary = library
        lastFailure = nil
        initializationState = .ready
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
    }

    private func adoptContactMutation(_ book: ContactBook, library: CipherLibrary) async {
        let capturedAt = await snapshotTimestamp()
        lastKnownContactBook = book
        lastKnownLibrary = library
        lastFailure = nil
        initializationState = .ready
        revision &+= 1
        broadcast(makeSnapshot(isLoading: false, capturedAt: capturedAt))
    }

    /// Applies the complete cross-store invariant from the committed contact
    /// book in one encrypted cipher-library write. Manual and local-only
    /// message contacts remain valid association targets, while only persisted
    /// system imports require an automatically generated linked cipher.
    private func reconcileContactAssociations(
        in book: ContactBook,
        progressionContext: RuntimePersistableOperationContext? = nil
    ) async throws -> CipherLibrary {
        try await Self.reconcileContactAssociations(
            book: book,
            repository: repository,
            progression: progression,
            progressionContext: progressionContext
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
        let progression = progression
        let repair = Task.detached(priority: nil) {
            do {
                let state = try await Self.recoverAndReconcileContactAssociations(
                    contactManager: contactManager,
                    repository: repository,
                    progression: progression
                )
                return ContactRepairOutcome.repaired(state)
            } catch {
                return ContactRepairOutcome.failed
            }
        }

        switch await repair.value {
        case .repaired(let state):
            await adoptContactMutation(state.book, library: state.library)
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
        repository: CipherRepository,
        progression: CoreProgressionCoordinator,
        progressionContext: RuntimePersistableOperationContext? = nil
    ) async throws -> ReconciledContactState {
        let contacts = book.contacts.compactMap { contact -> ImportedContactCipherSeed? in
            guard contact.source == .imported,
                  contact.appleContactID != nil
            else { return nil }
            return ImportedContactCipherSeed(
                contactID: contact.id,
                displayName: contact.displayName
            )
        }
        let validContactIDs = Set(book.contacts.map(\.id))
        let current = try await repository.snapshot()
        let mutation: CipherRepositoryMutation<Int>
        if current.version == CipherLibrary.currentVersion {
            let uniqueContacts = Dictionary(
                contacts.map { ($0.contactID, $0) },
                uniquingKeysWith: { first, _ in first }
            ).values.sorted { $0.contactID.uuidString < $1.contactID.uuidString }
            var generatedSeeds: [CoreGeneratedContactProgressionSeed] = []
            for contact in uniqueContacts where !current.ciphers.contains(where: {
                $0.contactID == contact.contactID
            }) {
                generatedSeeds.append(CoreGeneratedContactProgressionSeed(
                    contact: contact,
                    cipherSeed: (try? await progression.cipherSeed())
                        ?? Self.randomizedProgressionSeed(),
                    relationshipSeed: (try? await progression.relationshipSeed())
                        ?? Self.randomizedProgressionSeed()
                ))
            }
            var batches: [CorePendingProgressionBatch] = []
            if let progressionContext, !generatedSeeds.isEmpty {
                do {
                    var facts: [ProgressionEventFact] = []
                    for seed in generatedSeeds {
                        facts.append(try CoreProgressionFactFactory.cipherCreated(
                            cipherToken: try await progression.cipherToken(
                                for: seed.cipherSeed
                            )
                        ))
                    }
                    batches = try CoreProgressionCoordinator.pendingBatches(
                        context: progressionContext,
                        commandDigest: CoreProgressionCoordinator.commandDigest(facts),
                        facts: facts
                    )
                } catch {
                    batches = []
                }
            }
            let progressed: CipherRepositoryMutation<
                CoreProgressionContactReconciliationResult
            >
            let retainedBatches = !batches.isEmpty
            do {
                progressed = try await repository.reconcileContactAssociations(
                    generatedSeeds: generatedSeeds,
                    validContactIDs: validContactIDs,
                    pendingBatches: batches
                )
            } catch let error as CoreProgressionEvidenceError {
                guard error == .collectionLimitExceeded else {
                    throw error
                }
                progressed = try await repository
                    .reconcileContactAssociationsWithoutProgressionEvidence(
                    generatedSeeds: generatedSeeds,
                    validContactIDs: validContactIDs,
                    pendingBatches: batches
                )
            }
            if retainedBatches { _ = await progression.drain() }
            mutation = CipherRepositoryMutation(
                value: progressed.value.changes,
                library: progressed.library
            )
        } else {
            mutation = try await repository.reconcileContactAssociations(
                systemImportedSeeds: contacts,
                validContactIDs: validContactIDs
            )
        }
        return ReconciledContactState(book: book, library: mutation.library)
    }

    private nonisolated static func recoverAndReconcileContactAssociations(
        contactManager: ContactManager,
        repository: CipherRepository,
        progression: CoreProgressionCoordinator,
        progressionContext: RuntimePersistableOperationContext? = nil
    ) async throws -> ReconciledContactState {
        if let recovery = try await contactManager.prepareMessageAssociationRecovery() {
            let validContactIDs = Set(recovery.book.contacts.map(\.id))
            let restoredContactID = recovery.intent.previousContactID.flatMap {
                validContactIDs.contains($0) ? $0 : nil
            }
            let current = try await repository.snapshot()
            let restored: CipherRepositoryMutation<Bool>
            if current.version == CipherLibrary.currentVersion {
                let relationshipSeed: Data?
                if let restoredContactID,
                   try await repository.relationshipProgressionEvidence(
                       cipherID: recovery.intent.cipherID,
                       contactID: restoredContactID
                   ) == nil {
                    relationshipSeed = (try? await progression.relationshipSeed())
                        ?? Self.randomizedProgressionSeed()
                } else {
                    relationshipSeed = nil
                }
                do {
                    restored = try await repository.assignContact(
                        cipherID: recovery.intent.cipherID,
                        contactID: restoredContactID,
                        relationshipSeed: relationshipSeed,
                        pendingBatches: []
                    )
                } catch let error as CoreProgressionEvidenceError {
                    guard error == .collectionLimitExceeded else { throw error }
                    restored = try await repository
                        .assignContactWithoutProgressionEvidence(
                        cipherID: recovery.intent.cipherID,
                        contactID: restoredContactID,
                        pendingBatches: []
                    )
                }
            } else {
                restored = try await repository.assignContact(
                    cipherID: recovery.intent.cipherID,
                    contactID: restoredContactID
                )
            }
            guard restored.value else {
                throw MessageImportError.cipherAssociationUnavailable
            }
            let state = try await reconcileContactAssociations(
                book: recovery.book,
                repository: repository,
                progression: progression,
                progressionContext: progressionContext
            )
            try await contactManager.completeMessageAssociationRecovery(
                recovery.intent
            )
            return state
        }

        let book = try await contactManager.snapshot()
        return try await reconcileContactAssociations(
            book: book,
            repository: repository,
            progression: progression,
            progressionContext: progressionContext
        )
    }

    @discardableResult
    private func record(_ error: Error) async -> RuneScribeProductError {
        let capturedAt = await snapshotTimestamp()
        let failure = Self.failure(for: error)
        lastFailure = failure
        revision &+= 1
        broadcast(makeSnapshot(
            isLoading: initializationState == .loading,
            capturedAt: capturedAt
        ))
        return .failure(failure)
    }

    private func unavailableError() -> RuneScribeProductError {
        .failure(RuneScribeFailureDTO(code: .temporarilyUnavailable))
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

    private func snapshotTimestamp() async -> Date {
        (try? await runtimeIO.now()) ?? .distantPast
    }

    private func makeSnapshot(
        isLoading: Bool,
        capturedAt: Date
    ) -> RuneScribeApplicationSnapshot {
        let activeID = lastKnownLibrary.activeCipher?.id
        let summaries = lastKnownLibrary.ciphers.map { cipher in
            Self.summary(for: cipher, activeID: activeID)
        }

        return RuneScribeApplicationSnapshot(
            revision: revision,
            capturedAt: capturedAt,
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
            case .unsupportedVersion,
                 .unsupportedContainerVersion,
                 .unsupportedPayloadKind,
                 .unsupportedPayloadVersion,
                 .unknownRequiredSection,
                 .unsupportedRequiredSectionVersion:
                return RuneScribeFailureDTO(code: .unsupportedFormat)
            case .empty, .malformedContainer, .malformedCipher, .malformedMessage:
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
            case .terminalEvidenceCollision:
                return RuneScribeFailureDTO(code: .invalidInput)
            case .terminalJournalFull, .storageUnavailable:
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
                 .invalidSymbolPermutation,
                 .invalidFontReference,
                 .invalidDeliveryState:
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
