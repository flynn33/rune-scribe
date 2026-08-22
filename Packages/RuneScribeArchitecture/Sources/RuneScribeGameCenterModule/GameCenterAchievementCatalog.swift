import CryptoKit
import Foundation
import RuneScribeContracts

public enum GameCenterCatalogError: Error, Equatable, Sendable {
    case inputTooLarge(maximum: Int, actual: Int)
    case integrityMismatch(expected: String, actual: String)
    case unsupportedSchemaVersion(UInt16)
    case invalidCatalogIdentity
    case invalidCatalogVersion
    case invalidInventory
    case invalidPointTotal
    case duplicateAchievement
    case duplicateGameCenterIdentifier
    case invalidAchievement(String)
    case invalidLocalization(String)
    case placeholderIdentifier(String)
    case unknownField(String)
}

private struct GameCenterAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func gameCenterRejectUnknownKeys<Key>(
    from decoder: Decoder,
    allowedBy _: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: GameCenterAnyCodingKey.self)
    let allowed = Set(Key.allCases.map(\.stringValue))
    if let unknown = container.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
        throw GameCenterCatalogError.unknownField(unknown.stringValue)
    }
}

public enum GameCenterCatalogStatus: String, Codable, CaseIterable, Sendable {
    case frozenSourceControlled = "frozen-source-controlled"
}

public enum GameCenterPlatformStrategy: String, Codable, CaseIterable, Sendable {
    case sharedCatalogGameCenterGroupIfSeparateAppRecords =
        "shared-catalog-game-center-group-if-separate-app-records"
}

public struct GameCenterAchievementLocalization: Codable, Equatable, Sendable {
    public let locale: String
    public let title: String
    public let description: String

    public init(locale: String, title: String, description: String) throws {
        guard Self.isValidLocale(locale),
              Self.isBoundedText(title, maximum: 120),
              Self.isBoundedText(description, maximum: 255)
        else { throw GameCenterCatalogError.invalidLocalization(locale) }
        self.locale = locale
        self.title = title
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        try gameCenterRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            locale: container.decode(String.self, forKey: .locale),
            title: container.decode(String.self, forKey: .title),
            description: container.decode(String.self, forKey: .description)
        )
    }

    private static func isValidLocale(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return false }
        return parts.allSatisfy { part in
            (2 ... 8).contains(part.utf8.count)
                && part.utf8.allSatisfy {
                    (65 ... 90).contains($0) || (97 ... 122).contains($0)
                }
        }
    }

    private static func isBoundedText(_ value: String, maximum: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case locale
        case title
        case description
    }
}

public struct GameCenterAchievementDefinition: Codable, Equatable, Sendable {
    public let achievementID: AchievementID
    public let gameCenterIdentifier: String
    public let points: UInt16
    public let hidden: Bool
    public let repeatable: Bool
    public let progressTarget: UInt64
    public let localizationKeyPrefix: String
    public let artReference: String
    public let localizations: [GameCenterAchievementLocalization]

    public init(
        achievementID: AchievementID,
        gameCenterIdentifier: String,
        points: UInt16,
        hidden: Bool,
        repeatable: Bool,
        progressTarget: UInt64,
        localizationKeyPrefix: String,
        artReference: String,
        localizations: [GameCenterAchievementLocalization]
    ) throws {
        guard Self.isValidGameCenterIdentifier(gameCenterIdentifier),
              gameCenterIdentifier == "com.runescribe.\(achievementID.rawValue)",
              (1 ... 100).contains(points),
              progressTarget > 0,
              !repeatable,
              localizationKeyPrefix == "gamecenter.\(achievementID.rawValue)",
              artReference.hasPrefix("progression-catalog://fallback-system-image/"),
              artReference.utf8.count <= 160,
              localizations.contains(where: { $0.locale == "en" }),
              Set(localizations.map(\.locale)).count == localizations.count
        else { throw GameCenterCatalogError.invalidAchievement(achievementID.rawValue) }
        let normalizedIdentifier = gameCenterIdentifier.lowercased()
        if ["placeholder", "example", "temporary", "tbd", "todo", "beta"].contains(
            where: normalizedIdentifier.contains
        ) {
            throw GameCenterCatalogError.placeholderIdentifier(gameCenterIdentifier)
        }
        self.achievementID = achievementID
        self.gameCenterIdentifier = gameCenterIdentifier
        self.points = points
        self.hidden = hidden
        self.repeatable = repeatable
        self.progressTarget = progressTarget
        self.localizationKeyPrefix = localizationKeyPrefix
        self.artReference = artReference
        self.localizations = localizations.sorted { $0.locale < $1.locale }
    }

    public init(from decoder: Decoder) throws {
        try gameCenterRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            achievementID: container.decode(AchievementID.self, forKey: .achievementID),
            gameCenterIdentifier: container.decode(
                String.self,
                forKey: .gameCenterIdentifier
            ),
            points: container.decode(UInt16.self, forKey: .points),
            hidden: container.decode(Bool.self, forKey: .hidden),
            repeatable: container.decode(Bool.self, forKey: .repeatable),
            progressTarget: container.decode(UInt64.self, forKey: .progressTarget),
            localizationKeyPrefix: container.decode(
                String.self,
                forKey: .localizationKeyPrefix
            ),
            artReference: container.decode(String.self, forKey: .artReference),
            localizations: container.decode(
                [GameCenterAchievementLocalization].self,
                forKey: .localizations
            )
        )
    }

    static func isValidGameCenterIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard value.hasPrefix("com.runescribe.achievement."),
              bytes.count <= 100,
              !bytes.isEmpty
        else { return false }
        var previousSeparator = false
        for (index, byte) in bytes.enumerated() {
            let alphanumeric = (48 ... 57).contains(byte) || (97 ... 122).contains(byte)
            let separator = byte == 45 || byte == 46
            guard alphanumeric || separator else { return false }
            if separator {
                guard index > 0, index < bytes.count - 1, !previousSeparator else {
                    return false
                }
            }
            previousSeparator = separator
        }
        return true
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case achievementID
        case gameCenterIdentifier
        case points
        case hidden
        case repeatable
        case progressTarget
        case localizationKeyPrefix
        case artReference
        case localizations
    }
}

public struct GameCenterAchievementCatalog: Codable, Equatable, Sendable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let requiredAchievementCount = 15
    public static let requiredPointTotal: UInt16 = 220
    public static let requiredCatalogID = "com.runescribe.gamecenter.achievements"

    public let schemaVersion: UInt16
    public let catalogID: String
    public let catalogVersion: UInt64
    public let status: GameCenterCatalogStatus
    public let pointTotal: UInt16
    public let leaderboardsEnabled: Bool
    public let platformStrategy: GameCenterPlatformStrategy
    public let achievements: [GameCenterAchievementDefinition]

    public init(
        schemaVersion: UInt16,
        catalogID: String,
        catalogVersion: UInt64,
        status: GameCenterCatalogStatus,
        pointTotal: UInt16,
        leaderboardsEnabled: Bool,
        platformStrategy: GameCenterPlatformStrategy,
        achievements: [GameCenterAchievementDefinition]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GameCenterCatalogError.unsupportedSchemaVersion(schemaVersion)
        }
        guard catalogID == Self.requiredCatalogID else {
            throw GameCenterCatalogError.invalidCatalogIdentity
        }
        guard catalogVersion > 0 else { throw GameCenterCatalogError.invalidCatalogVersion }
        guard achievements.count == Self.requiredAchievementCount,
              !leaderboardsEnabled
        else { throw GameCenterCatalogError.invalidInventory }
        guard achievements.reduce(UInt16(0), { $0 + $1.points }) == pointTotal,
              pointTotal == Self.requiredPointTotal
        else { throw GameCenterCatalogError.invalidPointTotal }
        guard Set(achievements.map(\.achievementID)).count == achievements.count else {
            throw GameCenterCatalogError.duplicateAchievement
        }
        guard Set(achievements.map(\.gameCenterIdentifier)).count == achievements.count else {
            throw GameCenterCatalogError.duplicateGameCenterIdentifier
        }
        self.schemaVersion = schemaVersion
        self.catalogID = catalogID
        self.catalogVersion = catalogVersion
        self.status = status
        self.pointTotal = pointTotal
        self.leaderboardsEnabled = leaderboardsEnabled
        self.platformStrategy = platformStrategy
        self.achievements = achievements.sorted { $0.achievementID < $1.achievementID }
    }

    public init(from decoder: Decoder) throws {
        try gameCenterRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(UInt16.self, forKey: .schemaVersion),
            catalogID: container.decode(String.self, forKey: .catalogID),
            catalogVersion: container.decode(UInt64.self, forKey: .catalogVersion),
            status: container.decode(GameCenterCatalogStatus.self, forKey: .status),
            pointTotal: container.decode(UInt16.self, forKey: .pointTotal),
            leaderboardsEnabled: container.decode(Bool.self, forKey: .leaderboardsEnabled),
            platformStrategy: container.decode(
                GameCenterPlatformStrategy.self,
                forKey: .platformStrategy
            ),
            achievements: container.decode(
                [GameCenterAchievementDefinition].self,
                forKey: .achievements
            )
        )
    }

    public func definition(for achievementID: AchievementID) -> GameCenterAchievementDefinition? {
        achievements.first { $0.achievementID == achievementID }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case catalogID
        case catalogVersion
        case status
        case pointTotal
        case leaderboardsEnabled
        case platformStrategy
        case achievements
    }
}

public enum GameCenterCatalogResourceCatalog {
    public static let ownerModuleID: ModuleIdentifier = "com.runescribe.module.game-center"
    public static let catalog = ApplicationResource(
        name: "GameCenter-Achievement-Catalog-v1.0",
        fileExtension: "json",
        ownerModuleID: ownerModuleID
    )
    public static let expectedByteCount = 8_368
    public static let maximumByteCount = 16 * 1_024
    public static let expectedSHA256 =
        "a513bbc9e06eb0cc7963945d380306275eba58179f86cddb22e60d58acdaeb36"

    /// Host-only mapping for runtime-owned application-resource registration.
    public static var ownerScopedResourceBundles: [ModuleIdentifier: Bundle] {
        [ownerModuleID: .module]
    }

    public static func decodeAndValidate(_ data: Data) throws -> GameCenterAchievementCatalog {
        guard data.count <= maximumByteCount else {
            throw GameCenterCatalogError.inputTooLarge(maximum: maximumByteCount, actual: data.count)
        }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == expectedByteCount, actual == expectedSHA256 else {
            throw GameCenterCatalogError.integrityMismatch(
                expected: expectedSHA256,
                actual: actual
            )
        }
        return try JSONDecoder().decode(GameCenterAchievementCatalog.self, from: data)
    }
}
