import Foundation
import RuneScribeContracts

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
    let fontSource: FontSourceDTO
    let fontIsRegistered: Bool

    var contractID: CipherID {
        CipherID(rawValue: id)
    }

    var shortPublicID: String {
        String(publicIdentifier.prefix(8))
    }
}

struct ContactViewState: Identifiable, Equatable, Sendable {
    let id: UUID
    var displayName: String
    var phones: [String]
    var emails: [String]
    var systemIdentifier: String?
    let source: ContactSourceDTO
    let createdAt: Date

    init(
        id: UUID = UUID(),
        displayName: String,
        phones: [String] = [],
        emails: [String] = [],
        systemIdentifier: String? = nil,
        source: ContactSourceDTO,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.phones = phones
        self.emails = emails
        self.systemIdentifier = systemIdentifier
        self.source = source
        self.createdAt = createdAt
    }

    init(summary: ContactSummary, systemIdentifier: String? = nil) {
        id = summary.id.rawValue
        displayName = summary.displayName
        phones = summary.phoneNumbers
        emails = summary.emailAddresses
        self.systemIdentifier = systemIdentifier
        source = summary.source
        createdAt = summary.createdAt
    }

    init(systemContact: SystemContactDTO) {
        self.init(
            displayName: systemContact.displayName,
            phones: systemContact.phoneNumbers,
            emails: systemContact.emailAddresses,
            systemIdentifier: systemContact.systemIdentifier,
            source: .imported
        )
    }
}

struct PendingMessageViewState: Identifiable, Equatable, Sendable {
    let id: MessageID
    let plaintext: String
    let senderName: String
    let cipherID: UUID
    let cipherName: String
    let senderIdentityStatus: ReceivedSenderIdentityStatusDTO
    let presentation: ReceivedSharePresentation?
    let safePreviewData: Data?

    init(_ message: ReceivedMessageDTO) {
        id = message.id
        plaintext = message.plaintext
        senderName = message.senderName
        cipherID = message.cipherID.rawValue
        cipherName = message.cipherName
        senderIdentityStatus = message.senderIdentityStatus
        presentation = message.presentation
        safePreviewData = message.safePreviewData
    }

    init(
        _ message: ReceivedMessageDTO,
        themeSnapshot: ThemeCoordinatorSnapshotDTO?
    ) {
        id = message.id
        plaintext = message.plaintext
        senderName = message.senderName
        cipherID = message.cipherID.rawValue
        cipherName = message.cipherName
        senderIdentityStatus = message.senderIdentityStatus
        presentation = message.presentation.map {
            ReceivedPresentationAvailabilityBinding.resolve(
                $0,
                against: themeSnapshot
            )
        }
        safePreviewData = message.safePreviewData
    }
}
