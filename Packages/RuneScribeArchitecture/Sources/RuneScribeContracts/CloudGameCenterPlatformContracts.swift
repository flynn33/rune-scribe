import Foundation

public enum CloudSyncTransportError: Error, Equatable, Sendable {
    case payloadTooLarge
    case invalidChangeTag
    case accountUnavailable
    case accountChanged
    case offline
    case rateLimited(retryAfter: Date?)
    case serviceUnavailable
    case conflict
    case corruptRemote
    case configurationUnavailable
}

public struct CloudAccountScopeDigestDTO: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let digest = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid account scope digest.")
            )
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "<redacted-account-scope>" }
}

public enum CloudAccountStateValueDTO: String, Codable, CaseIterable, Sendable {
    case available
    case noAccount = "no-account"
    case restricted
    case temporarilyUnavailable = "temporarily-unavailable"
    case couldNotDetermine = "could-not-determine"
}

public struct CloudAccountStateDTO: Codable, Equatable, Sendable {
    public let state: CloudAccountStateValueDTO
    public let accountScopeDigest: CloudAccountScopeDigestDTO?

    public init(
        state: CloudAccountStateValueDTO,
        accountScopeDigest: CloudAccountScopeDigestDTO?
    ) throws {
        guard (state == .available) == (accountScopeDigest != nil) else {
            throw CloudSyncTransportError.accountUnavailable
        }
        self.state = state
        self.accountScopeDigest = accountScopeDigest
    }
}

public struct CloudSyncFetchResultDTO: Codable, Equatable, Sendable {
    public static let maximumPayloadByteCount = 2 * 1_024 * 1_024

    public let payload: Data?
    public let changeTag: String?

    public init(payload: Data?, changeTag: String?) throws {
        guard payload?.count ?? 0 <= Self.maximumPayloadByteCount else {
            throw CloudSyncTransportError.payloadTooLarge
        }
        guard Self.isValidChangeTag(changeTag), (payload == nil) == (changeTag == nil) else {
            throw CloudSyncTransportError.invalidChangeTag
        }
        self.payload = payload
        self.changeTag = changeTag
    }

    static func isValidChangeTag(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty
            && value.utf8.count <= 256
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public struct CloudSyncSaveRequestDTO: Codable, Equatable, Sendable {
    public let payload: Data
    public let expectedChangeTag: String?

    public init(payload: Data, expectedChangeTag: String?) throws {
        guard payload.count <= CloudSyncFetchResultDTO.maximumPayloadByteCount else {
            throw CloudSyncTransportError.payloadTooLarge
        }
        guard CloudSyncFetchResultDTO.isValidChangeTag(expectedChangeTag) else {
            throw CloudSyncTransportError.invalidChangeTag
        }
        self.payload = payload
        self.expectedChangeTag = expectedChangeTag
    }
}

public struct CloudSyncSaveResultDTO: Codable, Equatable, Sendable {
    public let changeTag: String

    public init(changeTag: String) throws {
        guard CloudSyncFetchResultDTO.isValidChangeTag(changeTag), !changeTag.isEmpty else {
            throw CloudSyncTransportError.invalidChangeTag
        }
        self.changeTag = changeTag
    }
}

/// Private-database transport only. Schema validation and merge remain outside
/// this adapter; scheduling and every invocation are runtime-owned.
public protocol CloudSyncTransport: Sendable {
    func accountState() async throws -> CloudAccountStateDTO
    func fetchPrivateProgression() async throws -> CloudSyncFetchResultDTO
    func savePrivateProgression(_ request: CloudSyncSaveRequestDTO) async throws
        -> CloudSyncSaveResultDTO
}

public enum GameCenterReportingTransportError: Error, Equatable, Sendable {
    case invalidReport
    case notAuthenticated
    case denied
    case restricted
    case cancelled
    case authenticationPresentationUnavailable
    case offline
    case rateLimited(retryAfter: Date?)
    case serviceUnavailable
    case configurationUnavailable
}

public enum GameCenterAuthenticationStateDTO: String, Codable, CaseIterable, Sendable {
    case notAuthenticated = "not-authenticated"
    case authenticated
    case restricted
    case unavailable
}

public struct GameCenterAccountScopeDigestDTO: RawRepresentable, Codable, Hashable,
    Sendable, Comparable, CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 64,
              rawValue.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 102).contains($0)
              })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Game Center account scope digest."
                )
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "<redacted-game-center-account-scope>" }
}

public struct GameCenterAchievementReportDTO: Codable, Equatable, Sendable {
    public let identifier: String
    public let percentage: UInt8

    public init(identifier: String, percentage: UInt8) throws {
        guard identifier.hasPrefix("com.runescribe.achievement."),
              identifier.utf8.count <= 100,
              identifier.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (97 ... 122).contains($0)
                    || $0 == 45 || $0 == 46
              }),
              percentage <= 100
        else { throw GameCenterReportingTransportError.invalidReport }
        self.identifier = identifier
        self.percentage = percentage
    }
}

/// Reporting-only GameKit seam. It intentionally exposes no player identifier,
/// ownership mutation, unlock mutation, or mandatory first-run authentication API.
public protocol GameCenterReporting: Sendable {
    func authenticationState() async -> GameCenterAuthenticationStateDTO
    func accountScopeDigest() async -> GameCenterAccountScopeDigestDTO?
    func requestAuthentication() async throws -> GameCenterAuthenticationStateDTO
    func report(_ achievements: [GameCenterAchievementReportDTO]) async throws
}

public extension GameCenterReporting {
    func accountScopeDigest() async -> GameCenterAccountScopeDigestDTO? { nil }

    func requestAuthentication() async throws -> GameCenterAuthenticationStateDTO {
        await authenticationState()
    }
}

public extension RuneScribeServiceIDs {
    static var cloudSyncTransport: ServiceIdentifier { "CloudSyncTransport" }
    static var gameCenterReporting: ServiceIdentifier { "GameCenterReporting" }
}

public extension RuneScribeServiceKeys {
    static var cloudSyncTransport: ServiceKey<any CloudSyncTransport> {
        ServiceKey(RuneScribeServiceIDs.cloudSyncTransport)
    }

    static var gameCenterReporting: ServiceKey<any GameCenterReporting> {
        ServiceKey(RuneScribeServiceIDs.gameCenterReporting)
    }
}
