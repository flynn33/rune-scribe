import Foundation
import RuneScribeContracts

/// The Core-owned, key-free application facade. Key-bearing ciphers and
/// persistence entities remain behind the private repository actor.
public actor RuneScribeCoreApplicationService: RuneScribeApplicationService {
    private enum InitializationState {
        case notStarted
        case loading
        case ready
        case failed
    }

    private let repository: CipherRepository
    private let clock: any ClockProviding
    private let messageService = MessageService()

    private var initializationState: InitializationState = .notStarted
    private var lastKnownLibrary: CipherLibrary = .empty
    private var lastFailure: RuneScribeFailureDTO?
    private var revision: UInt64 = 0

    private var importState = ImportStateDTO(phase: .idle)
    private var messageState = MessageStateDTO(phase: .idle)
    private var lockState = ApplicationLockStateDTO(isPINSet: false, isLocked: false)

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
        repository = CipherRepository(
            secureValueStore: secureValueStore,
            clock: clock,
            uuid: uuid
        )
        self.clock = clock
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
        throw unavailable()
    }

    public func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary {
        throw unavailable()
    }

    public func deleteContacts(ids: Set<ContactID>) async throws {
        throw unavailable()
    }

    public func deleteAllImportedContacts() async throws {
        throw unavailable()
    }

    public func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary] {
        throw unavailable()
    }

    public func prepareCipherShare(
        _ command: PrepareCipherShareCommand
    ) async throws -> ShareArtifactDTO {
        // A key-bearing URL must never cross this contract boundary.
        throw unavailable()
    }

    public func prepareMessageShare(
        _ command: PrepareMessageShareCommand
    ) async throws -> ShareArtifactDTO {
        throw unavailable()
    }

    public func completeShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        throw unavailable()
    }

    public func releaseShareArtifact(id: ShareArtifactID) async {
        // Artifact ownership moves in P4B. This service is not routed until then.
    }

    public func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO {
        // Recording broadcasts the failed import snapshot synchronously before
        // this async operation returns to its caller. P4B opens a security scope
        // only when it is ready to read, and balances it around that read.
        throw unavailableImport()
    }

    public func importURL(_ input: InboundURLDTO) async throws -> ImportResultDTO {
        throw unavailableImport()
    }

    public func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary {
        throw unavailableImport()
    }

    public func cancelImport(id: ImportID) async {
        // Pending import ownership moves in P4B. This service is not routed until then.
    }

    public func dismissReceivedMessage(id: MessageID) async {
        // Received-message ownership moves in P4B. This service is not routed until then.
    }

    public func lock() async {
        // Lock ownership moves in P4B. A no-op lock must not be routed by the UI.
    }

    public func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO {
        throw unavailable()
    }

    public func setPIN(_ command: SetPINCommand) async throws {
        throw unavailable()
    }

    public func changePIN(_ command: ChangePINCommand) async throws {
        throw unavailable()
    }

    public func disablePIN(_ command: DisablePINCommand) async throws {
        throw unavailable()
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
                let library = try await repository.snapshot()
                lastKnownLibrary = library
                lastFailure = nil
                initializationState = .ready
                revision &+= 1
                broadcast(makeSnapshot(isLoading: false))
            } catch {
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

    private func unavailableImport() -> RuneScribeProductError {
        let failure = RuneScribeFailureDTO(code: .temporarilyUnavailable)
        importState = ImportStateDTO(phase: .failed, lastFailure: failure)
        return record(RuneScribeProductError.failure(failure))
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
            contactLibrary: ContactLibraryStateDTO(
                contacts: [],
                importedCount: 0,
                authorization: .notDetermined
            ),
            fonts: Self.fontSummaries(for: lastKnownLibrary),
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
