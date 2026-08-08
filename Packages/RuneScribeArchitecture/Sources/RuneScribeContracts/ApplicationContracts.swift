import Foundation

public enum CipherOriginDTO: String, Codable, Hashable, Sendable {
    case generated
    case imported
}

public enum FontSourceDTO: String, Codable, Hashable, Sendable {
    case bundled
    case imported
}

public struct FontSummary: Codable, Equatable, Hashable, Sendable {
    public let id: FontID
    public let displayName: String
    public let version: Int
    public let contentHash: String
    public let source: FontSourceDTO
    public let isRegistered: Bool

    public init(
        id: FontID,
        displayName: String,
        version: Int,
        contentHash: String,
        source: FontSourceDTO,
        isRegistered: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.contentHash = contentHash
        self.source = source
        self.isRegistered = isRegistered
    }
}

public struct CipherSummary: Codable, Equatable, Hashable, Sendable {
    public let id: CipherID
    public let name: String
    public let origin: CipherOriginDTO
    public let createdAt: Date
    public let isActive: Bool
    public let assignedContactID: ContactID?
    public let hasBeenDelivered: Bool
    public let publicIdentifier: String
    public let fontID: FontID

    public init(
        id: CipherID,
        name: String,
        origin: CipherOriginDTO,
        createdAt: Date,
        isActive: Bool,
        assignedContactID: ContactID?,
        hasBeenDelivered: Bool,
        publicIdentifier: String,
        fontID: FontID
    ) {
        self.id = id
        self.name = name
        self.origin = origin
        self.createdAt = createdAt
        self.isActive = isActive
        self.assignedContactID = assignedContactID
        self.hasBeenDelivered = hasBeenDelivered
        self.publicIdentifier = publicIdentifier
        self.fontID = fontID
    }

    public var hasAssignedContact: Bool {
        assignedContactID != nil
    }
}

public struct CipherLibraryStateDTO: Codable, Equatable, Sendable {
    public let ciphers: [CipherSummary]
    public let activeCipherID: CipherID?
    public let isLoading: Bool

    public init(
        ciphers: [CipherSummary],
        activeCipherID: CipherID?,
        isLoading: Bool = false
    ) {
        self.ciphers = ciphers
        self.activeCipherID = activeCipherID
        self.isLoading = isLoading
    }
}

public enum ContactSourceDTO: String, Codable, Hashable, Sendable {
    case manual
    case imported
}

public struct ContactSummary: Codable, Equatable, Hashable, Sendable {
    public let id: ContactID
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]
    public let source: ContactSourceDTO
    public let createdAt: Date
    public let linkedCipherCount: Int

    public init(
        id: ContactID,
        displayName: String,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = [],
        source: ContactSourceDTO,
        createdAt: Date,
        linkedCipherCount: Int
    ) {
        self.id = id
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.source = source
        self.createdAt = createdAt
        self.linkedCipherCount = linkedCipherCount
    }
}

public struct ContactLibraryStateDTO: Codable, Equatable, Sendable {
    public let contacts: [ContactSummary]
    public let importedCount: Int
    public let authorization: ContactAuthorizationDTO

    public init(
        contacts: [ContactSummary],
        importedCount: Int,
        authorization: ContactAuthorizationDTO
    ) {
        self.contacts = contacts
        self.importedCount = importedCount
        self.authorization = authorization
    }
}

public enum RuneScribeFailureCode: String, Codable, Hashable, Sendable {
    case invalidInput
    case itemNotFound
    case unsupportedFormat
    case corruptedContent
    case noMatchingCipher
    case authorizationDenied
    case authenticationFailed
    case lockedOut
    case secureStorageUnavailable
    case protectedFileUnavailable
    case resourceUnavailable
    case shareUnavailable
    case operationCancelled
    case temporarilyUnavailable
    case internalFailure
}

public struct RuneScribeFailureDTO: Codable, Equatable, Hashable, Sendable {
    public let code: RuneScribeFailureCode
    public let retryAfter: Date?

    public init(code: RuneScribeFailureCode, retryAfter: Date? = nil) {
        self.code = code
        self.retryAfter = retryAfter
    }
}

public enum RuneScribeProductError: Error, Equatable, Sendable {
    case failure(RuneScribeFailureDTO)
}

public enum ImportSourceDTO: String, Codable, Hashable, Sendable {
    case file
    case link
    case qrCode
    case clipboard
    case embeddedMessage
}

public enum ImportPhaseDTO: String, Codable, Hashable, Sendable {
    case idle
    case validating
    case awaitingConfirmation
    case importing
    case completed
    case failed
}

public struct PendingImportSummary: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: ImportID
    public let suggestedName: String
    public let source: ImportSourceDTO
    public let includesFont: Bool

    public init(
        id: ImportID,
        suggestedName: String,
        source: ImportSourceDTO,
        includesFont: Bool
    ) {
        self.id = id
        self.suggestedName = suggestedName
        self.source = source
        self.includesFont = includesFont
    }
}

public struct ImportStateDTO: Codable, Equatable, Sendable {
    public let phase: ImportPhaseDTO
    public let pending: PendingImportSummary?
    public let lastFailure: RuneScribeFailureDTO?

    public init(
        phase: ImportPhaseDTO,
        pending: PendingImportSummary? = nil,
        lastFailure: RuneScribeFailureDTO? = nil
    ) {
        self.phase = phase
        self.pending = pending
        self.lastFailure = lastFailure
    }
}

public enum ImportDispositionDTO: String, Codable, Hashable, Sendable {
    case awaitingConfirmation
    case importedCipher
    case receivedMessage
    case duplicate
    case ignored
}

public struct ImportResultDTO: Codable, Equatable, Sendable {
    public let disposition: ImportDispositionDTO
    public let pendingImport: PendingImportSummary?
    public let importedCipher: CipherSummary?
    public let receivedMessageID: MessageID?

    public init(
        disposition: ImportDispositionDTO,
        pendingImport: PendingImportSummary? = nil,
        importedCipher: CipherSummary? = nil,
        receivedMessageID: MessageID? = nil
    ) {
        self.disposition = disposition
        self.pendingImport = pendingImport
        self.importedCipher = importedCipher
        self.receivedMessageID = receivedMessageID
    }
}

public enum MessagePhaseDTO: String, Codable, Hashable, Sendable {
    case idle
    case composing
    case encoded
    case receiving
    case received
    case failed
}

public struct ReceivedMessageDTO: Equatable, Sendable {
    public let id: MessageID
    public let plaintext: String
    public let senderName: String
    public let cipherID: CipherID
    public let cipherName: String

    public init(
        id: MessageID,
        plaintext: String,
        senderName: String,
        cipherID: CipherID,
        cipherName: String
    ) {
        self.id = id
        self.plaintext = plaintext
        self.senderName = senderName
        self.cipherID = cipherID
        self.cipherName = cipherName
    }
}

public struct MessageStateDTO: Equatable, Sendable {
    public let phase: MessagePhaseDTO
    public let pendingMessage: ReceivedMessageDTO?
    public let lastFailure: RuneScribeFailureDTO?

    public init(
        phase: MessagePhaseDTO,
        pendingMessage: ReceivedMessageDTO? = nil,
        lastFailure: RuneScribeFailureDTO? = nil
    ) {
        self.phase = phase
        self.pendingMessage = pendingMessage
        self.lastFailure = lastFailure
    }
}

public struct ApplicationLockStateDTO: Codable, Equatable, Sendable {
    public let isPINSet: Bool
    public let isLocked: Bool
    public let retryAfter: Date?

    public init(isPINSet: Bool, isLocked: Bool, retryAfter: Date? = nil) {
        self.isPINSet = isPINSet
        self.isLocked = isLocked
        self.retryAfter = retryAfter
    }
}

public struct RuneScribeApplicationSnapshot: Equatable, Sendable {
    public let revision: UInt64
    public let capturedAt: Date
    public let cipherLibrary: CipherLibraryStateDTO
    public let contactLibrary: ContactLibraryStateDTO
    public let fonts: [FontSummary]
    public let importState: ImportStateDTO
    public let messageState: MessageStateDTO
    public let lockState: ApplicationLockStateDTO
    public let lastFailure: RuneScribeFailureDTO?

    public init(
        revision: UInt64,
        capturedAt: Date,
        cipherLibrary: CipherLibraryStateDTO,
        contactLibrary: ContactLibraryStateDTO,
        fonts: [FontSummary],
        importState: ImportStateDTO,
        messageState: MessageStateDTO,
        lockState: ApplicationLockStateDTO,
        lastFailure: RuneScribeFailureDTO? = nil
    ) {
        self.revision = revision
        self.capturedAt = capturedAt
        self.cipherLibrary = cipherLibrary
        self.contactLibrary = contactLibrary
        self.fonts = fonts
        self.importState = importState
        self.messageState = messageState
        self.lockState = lockState
        self.lastFailure = lastFailure
    }
}

public struct EncodeMessageCommand: Sendable {
    public let plaintext: String
    public let cipherID: CipherID?

    public init(plaintext: String, cipherID: CipherID? = nil) {
        self.plaintext = plaintext
        self.cipherID = cipherID
    }
}

public struct EncodedMessageResult: Equatable, Sendable {
    public let runes: String
    public let cipherID: CipherID

    public init(runes: String, cipherID: CipherID) {
        self.runes = runes
        self.cipherID = cipherID
    }
}

public struct DecodeMessageCommand: Sendable {
    public let runes: String

    public init(runes: String) {
        self.runes = runes
    }
}

public struct DecodedMessageResult: Equatable, Sendable {
    public let plaintext: String
    public let cipherID: CipherID
    public let cipherName: String

    public init(plaintext: String, cipherID: CipherID, cipherName: String) {
        self.plaintext = plaintext
        self.cipherID = cipherID
        self.cipherName = cipherName
    }
}

public struct CreateCipherCommand: Codable, Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct RenameCipherCommand: Codable, Equatable, Sendable {
    public let cipherID: CipherID
    public let name: String

    public init(cipherID: CipherID, name: String) {
        self.cipherID = cipherID
        self.name = name
    }
}

public struct SetActiveCipherCommand: Codable, Equatable, Sendable {
    public let cipherID: CipherID

    public init(cipherID: CipherID) {
        self.cipherID = cipherID
    }
}

public struct AssignContactCommand: Codable, Equatable, Sendable {
    public let cipherID: CipherID
    public let contactID: ContactID?

    public init(cipherID: CipherID, contactID: ContactID?) {
        self.cipherID = cipherID
        self.contactID = contactID
    }
}

public struct CreateContactCommand: Codable, Equatable, Sendable {
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        displayName: String,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = []
    ) {
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public struct UpdateContactCommand: Codable, Equatable, Sendable {
    public let contactID: ContactID
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        contactID: ContactID,
        displayName: String,
        phoneNumbers: [String],
        emailAddresses: [String]
    ) {
        self.contactID = contactID
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public struct ImportContactsCommand: Codable, Equatable, Sendable {
    public let contacts: [SystemContactDTO]

    public init(contacts: [SystemContactDTO]) {
        self.contacts = contacts
    }
}

public enum ShareRepresentationDTO: String, Codable, Hashable, Sendable {
    case file
    case link
    case qrCode
}

public struct PrepareCipherShareCommand: Codable, Equatable, Sendable {
    public let cipherID: CipherID
    public let displayName: String?
    public let representation: ShareRepresentationDTO

    public init(
        cipherID: CipherID,
        displayName: String? = nil,
        representation: ShareRepresentationDTO
    ) {
        self.cipherID = cipherID
        self.displayName = displayName
        self.representation = representation
    }
}

public struct PrepareMessageShareCommand: Sendable {
    public let runes: String
    public let senderName: String
    public let cipherID: CipherID

    public init(runes: String, senderName: String, cipherID: CipherID) {
        self.runes = runes
        self.senderName = senderName
        self.cipherID = cipherID
    }
}

public enum ShareArtifactReference: Codable, Equatable, Hashable, Sendable {
    case file(URL)
    case opaque(ShareArtifactID)
    case link(URL)
}

public enum ShareArtifactLifetime: Codable, Equatable, Hashable, Sendable {
    case singleUse
    case applicationSession
    case expires(Date)
}

public struct ShareArtifactDTO: Codable, Equatable, Hashable, Sendable {
    public let id: ShareArtifactID
    public let reference: ShareArtifactReference
    public let displayName: String
    public let contentType: String
    public let fileExtension: String?
    public let lifetime: ShareArtifactLifetime
    public let requiresKeyDelivery: Bool

    public init(
        id: ShareArtifactID,
        reference: ShareArtifactReference,
        displayName: String,
        contentType: String,
        fileExtension: String?,
        lifetime: ShareArtifactLifetime,
        requiresKeyDelivery: Bool
    ) {
        self.id = id
        self.reference = reference
        self.displayName = displayName
        self.contentType = contentType
        self.fileExtension = fileExtension
        self.lifetime = lifetime
        self.requiresKeyDelivery = requiresKeyDelivery
    }
}

public enum ShareArtifactOutcomeDTO: Codable, Equatable, Hashable, Sendable {
    case handedOff
    case messageSent(requiredAttachmentAccepted: Bool)
    case cancelled
    case failed
}

public struct CompleteShareArtifactCommand: Codable, Equatable, Hashable, Sendable {
    public let artifactID: ShareArtifactID
    public let outcome: ShareArtifactOutcomeDTO

    public init(artifactID: ShareArtifactID, outcome: ShareArtifactOutcomeDTO) {
        self.artifactID = artifactID
        self.outcome = outcome
    }
}

public enum ShareArtifactCompletionResultDTO: String, Codable, Hashable, Sendable {
    case released
    case deliveryRecorded
    case retainedForRetry
}

public struct ConfirmImportCommand: Codable, Equatable, Sendable {
    public let importID: ImportID
    public let name: String

    public init(importID: ImportID, name: String) {
        self.importID = importID
        self.name = name
    }
}

public struct PINInput: Sendable {
    private let value: String

    public init(_ value: String) {
        self.value = value
    }

    public func withValue<Result>(_ operation: (String) throws -> Result) rethrows -> Result {
        try operation(value)
    }
}

public struct UnlockCommand: Sendable {
    public let input: PINInput

    public init(input: PINInput) {
        self.input = input
    }
}

public struct SetPINCommand: Sendable {
    public let input: PINInput

    public init(input: PINInput) {
        self.input = input
    }
}

public struct ChangePINCommand: Sendable {
    public let current: PINInput
    public let replacement: PINInput

    public init(current: PINInput, replacement: PINInput) {
        self.current = current
        self.replacement = replacement
    }
}

public struct DisablePINCommand: Sendable {
    public let current: PINInput

    public init(current: PINInput) {
        self.current = current
    }
}

public enum UnlockResultDTO: Equatable, Sendable {
    case unlocked
    case incorrect
    case lockedOut(retryAfter: Date)
}

public protocol RuneScribeApplicationService: Sendable {
    func stateStream() -> AsyncStream<RuneScribeApplicationSnapshot>

    func encode(_ command: EncodeMessageCommand) async throws -> EncodedMessageResult
    func decode(_ command: DecodeMessageCommand) async throws -> DecodedMessageResult

    func createCipher(_ command: CreateCipherCommand) async throws -> CipherSummary
    func renameCipher(_ command: RenameCipherCommand) async throws -> CipherSummary
    func deleteCipher(id: CipherID) async throws
    func setActiveCipher(_ command: SetActiveCipherCommand) async throws
    func assignContact(_ command: AssignContactCommand) async throws

    func createContact(_ command: CreateContactCommand) async throws -> ContactSummary
    func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary
    func deleteContacts(ids: Set<ContactID>) async throws
    func deleteAllImportedContacts() async throws
    func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary]

    func prepareCipherShare(_ command: PrepareCipherShareCommand) async throws -> ShareArtifactDTO
    func prepareMessageShare(_ command: PrepareMessageShareCommand) async throws -> ShareArtifactDTO
    func completeShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO
    func releaseShareArtifact(id: ShareArtifactID) async

    func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO
    func importURL(_ input: InboundURLDTO) async throws -> ImportResultDTO
    func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary
    func cancelImport(id: ImportID) async
    func dismissReceivedMessage(id: MessageID) async

    func lock() async
    func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO
    func setPIN(_ command: SetPINCommand) async throws
    func changePIN(_ command: ChangePINCommand) async throws
    func disablePIN(_ command: DisablePINCommand) async throws
}
