import Foundation

public enum RuneScribeEventIDs {
    public static let applicationSnapshotChanged: EventIdentifier =
        "com.runescribe.event.application-snapshot-changed"
    public static let cipherLibraryChanged: EventIdentifier =
        "com.runescribe.event.cipher-library-changed"
    public static let contactsChanged: EventIdentifier =
        "com.runescribe.event.contacts-changed"
    public static let importStateChanged: EventIdentifier =
        "com.runescribe.event.import-state-changed"
    public static let messageStateChanged: EventIdentifier =
        "com.runescribe.event.message-state-changed"
    public static let lockStateChanged: EventIdentifier =
        "com.runescribe.event.lock-state-changed"

    public static let all: Set<EventIdentifier> = [
        applicationSnapshotChanged,
        cipherLibraryChanged,
        contactsChanged,
        importStateChanged,
        messageStateChanged,
        lockStateChanged,
    ]
}

public struct ApplicationSnapshotChangedEvent: Codable, Equatable, Sendable {
    public let revision: UInt64
    public let occurredAt: Date

    public init(revision: UInt64, occurredAt: Date) {
        self.revision = revision
        self.occurredAt = occurredAt
    }
}

public struct CipherLibraryChangedEvent: Codable, Equatable, Sendable {
    public let cipherCount: Int
    public let activeCipherID: CipherID?

    public init(cipherCount: Int, activeCipherID: CipherID?) {
        self.cipherCount = cipherCount
        self.activeCipherID = activeCipherID
    }
}

public struct ContactsChangedEvent: Codable, Equatable, Sendable {
    public let contactCount: Int
    public let importedCount: Int

    public init(contactCount: Int, importedCount: Int) {
        self.contactCount = contactCount
        self.importedCount = importedCount
    }
}

public struct ImportStateChangedEvent: Codable, Equatable, Sendable {
    public let phase: ImportPhaseDTO
    public let hasPendingConfirmation: Bool
    public let failureCode: RuneScribeFailureCode?

    public init(
        phase: ImportPhaseDTO,
        hasPendingConfirmation: Bool,
        failureCode: RuneScribeFailureCode?
    ) {
        self.phase = phase
        self.hasPendingConfirmation = hasPendingConfirmation
        self.failureCode = failureCode
    }
}

public struct MessageStateChangedEvent: Codable, Equatable, Sendable {
    public let phase: MessagePhaseDTO
    public let hasPendingMessage: Bool
    public let failureCode: RuneScribeFailureCode?

    public init(
        phase: MessagePhaseDTO,
        hasPendingMessage: Bool,
        failureCode: RuneScribeFailureCode?
    ) {
        self.phase = phase
        self.hasPendingMessage = hasPendingMessage
        self.failureCode = failureCode
    }
}

public struct LockStateChangedEvent: Codable, Equatable, Sendable {
    public let isPINSet: Bool
    public let isLocked: Bool
    public let isThrottled: Bool

    public init(isPINSet: Bool, isLocked: Bool, isThrottled: Bool) {
        self.isPINSet = isPINSet
        self.isLocked = isLocked
        self.isThrottled = isThrottled
    }
}
