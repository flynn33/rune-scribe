import Foundation

public enum MessagesOpenResult: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case rejected
    case unknown
}

public enum MessagesImportAppState: String, Codable, Equatable, Sendable {
    case awaitingDelivery
    case presented
    case completed
    case declined
}

public struct MessagesImportEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let handoffID: String
    public let invitationURL: URL
    public let confirmedAtEpochMilliseconds: Int64
    public var openAttemptedAtEpochMilliseconds: Int64
    public var openResult: MessagesOpenResult
    public var appState: MessagesImportAppState

    public init(
        invitation: MessagesValidatedInvitation,
        confirmedAt: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        handoffID = invitation.handoffID
        invitationURL = invitation.URL
        confirmedAtEpochMilliseconds = confirmedAt.epochMilliseconds
        openAttemptedAtEpochMilliseconds = 0
        openResult = .pending
        appState = .awaitingDelivery
    }

    public mutating func recordOpenAttempt(at date: Date) {
        openAttemptedAtEpochMilliseconds = date.epochMilliseconds
        openResult = .pending
    }

    public mutating func recordOpenResult(_ result: MessagesOpenResult) {
        openResult = result
    }

    public mutating func recordAppState(_ state: MessagesImportAppState) {
        appState = state
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              handoffID.count == 64,
              handoffID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              try MessagesInvitationValidator.validate(invitationURL).handoffID == handoffID,
              confirmedAtEpochMilliseconds > 0,
              openAttemptedAtEpochMilliseconds >= 0
        else {
            throw MessagesAppGroupInboxError.invalidEnvelope
        }
    }
}

private extension Date {
    var epochMilliseconds: Int64 {
        Int64((timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}
