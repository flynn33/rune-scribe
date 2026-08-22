import Foundation
import RuneScribeContracts
import Testing
@testable import RuneScribeGameCenterModule

@Test
func frozenCatalogHasExactApprovedInventoryAndProductionIdentifiers() throws {
    let catalog = try bundledCatalog()
    let expectedIDs = [
        "achievement.archivist-1",
        "achievement.archivist-2",
        "achievement.collector",
        "achievement.correspondent",
        "achievement.courier-1",
        "achievement.courier-2",
        "achievement.echo-returns",
        "achievement.explorer",
        "achievement.first-dispatch",
        "achievement.first-inscription",
        "achievement.five-circles",
        "achievement.many-worlds",
        "achievement.master-scribe",
        "achievement.relic-bearer",
        "achievement.seal-keeper",
    ]

    #expect(catalog.achievements.map(\.achievementID.rawValue) == expectedIDs)
    #expect(catalog.pointTotal == 220)
    #expect(catalog.achievements.reduce(0, { $0 + Int($1.points) }) == 220)
    #expect(Set(catalog.achievements.map(\.gameCenterIdentifier)).count == 15)
    #expect(catalog.achievements.allSatisfy {
        $0.gameCenterIdentifier.hasPrefix("com.runescribe.achievement.")
            && !$0.repeatable
            && $0.localizations.contains(where: { $0.locale == "en" })
            && $0.artReference.hasPrefix(
                "progression-catalog://fallback-system-image/"
            )
    })
    #expect(catalog.definition(for: achievement("achievement.explorer"))?.hidden == true)
    #expect(catalog.achievements.filter(\.hidden).count == 1)
    #expect(!catalog.leaderboardsEnabled)
    #expect(
        catalog.platformStrategy
            == .sharedCatalogGameCenterGroupIfSeparateAppRecords
    )
}

@Test
func resourceIntegrityAndStrictUnknownFieldChecksFailClosed() throws {
    let data = try bundledCatalogData()
    var mutated = data
    mutated[mutated.startIndex] ^= 1
    #expect(throws: GameCenterCatalogError.self) {
        _ = try GameCenterCatalogResourceCatalog.decodeAndValidate(mutated)
    }

    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["placeholderIdentifier"] = "tbd"
    let unknown = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    #expect(throws: GameCenterCatalogError.self) {
        _ = try JSONDecoder().decode(GameCenterAchievementCatalog.self, from: unknown)
    }
}

func bundledCatalog() throws -> GameCenterAchievementCatalog {
    try GameCenterCatalogResourceCatalog.decodeAndValidate(bundledCatalogData())
}

func bundledCatalogData() throws -> Data {
    let bundle = try #require(
        GameCenterCatalogResourceCatalog.ownerScopedResourceBundles[
            GameCenterCatalogResourceCatalog.ownerModuleID
        ]
    )
    let url = try #require(
        bundle.url(
            forResource: "GameCenter-Achievement-Catalog-v1.0",
            withExtension: "json"
        )
    )
    return try Data(contentsOf: url)
}

func achievement(_ value: String) -> AchievementID { AchievementID(rawValue: value)! }
