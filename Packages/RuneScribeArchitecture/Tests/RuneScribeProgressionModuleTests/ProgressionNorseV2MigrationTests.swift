import Foundation
@_spi(RuntimeExistingUserMigrationAuthority) import RuneScribeContracts
import RuneScribeRuntimeCore
import Testing
@testable import RuneScribeProgressionModule

@Test
func norseV1AliasesAndGrantRoutesMapToTheExactV2Catalog() throws {
    let fixture = try ProgressionDurableFixture()
    let catalog = fixture.bundle.catalog
    let aliases = [
        "relic.norse.runestone.weathered": "relic.norse.runestone-tablet",
        "relic.norse.raven-medallion": "relic.norse.dragonwood-plaque",
        "relic.norse.ironbound-shield": "relic.norse.stormforged-stele",
        "relic.norse.sealed-parchment": "relic.norse.dragonwood-plaque",
        "relic.norse.runestone.blackstone": "relic.norse.stormforged-stele",
        "relic.norse.runestone.frozen": "relic.norse.runestone-tablet",
        "seal.norse.knotwork": "seal.norse.valknut",
        "seal.norse.forge-flame": "seal.norse.ravenshield",
        "seal.norse.raven": "seal.norse.ravenshield",
        "seal.norse.longship": "seal.norse.wolkin",
        "seal.norse.forge-hammer": "seal.norse.mjolnir",
        "seal.norse.echo-rune": "seal.norse.yggdrasil",
        "crest.norse.forge-master": "crest.norse.raven-mastery",
    ]

    for (legacy, expected) in aliases {
        let canonical = ProgressionNorseV2Migration.canonicalContentID(
            contentID(legacy),
            catalog: catalog
        )
        #expect(canonical?.rawValue == expected)
    }
    #expect(ProgressionNorseV2Migration.canonicalContentID(
        contentID("seal.norse.future-unknown"),
        catalog: catalog
    ) == nil)

    let routes: [(String, String, String, ProgressionGrantSource)] = [
        (
            "grant-group.base.norse.included",
            "relic.norse.runestone.weathered",
            "relic.norse.runestone-tablet",
            .migration(1)
        ),
        (
            "grant-group.base.norse.included",
            "seal.norse.knotwork",
            "seal.norse.valknut",
            .migration(1)
        ),
        (
            "grant-group.base.norse.included",
            "seal.norse.forge-flame",
            "seal.norse.ravenshield",
            .migration(1)
        ),
        (
            "grant-group.first-inscription",
            "seal.norse.raven",
            "seal.norse.mjolnir",
            .achievement(achievementID("achievement.first-inscription"))
        ),
        (
            "grant-group.first-dispatch",
            "relic.norse.raven-medallion",
            "relic.norse.dragonwood-plaque",
            .achievement(achievementID("achievement.first-dispatch"))
        ),
        (
            "grant-group.correspondent",
            "seal.norse.longship",
            "seal.norse.wolkin",
            .achievement(achievementID("achievement.correspondent"))
        ),
        (
            "grant-group.courier-1",
            "seal.norse.forge-hammer",
            "seal.norse.yggdrasil",
            .achievement(achievementID("achievement.courier-1"))
        ),
        (
            "grant-group.courier-2",
            "relic.norse.ironbound-shield",
            "relic.norse.stormforged-stele",
            .achievement(achievementID("achievement.courier-2"))
        ),
        (
            "grant-group.archivist-2",
            "relic.norse.sealed-parchment",
            "seal.norse.berserk",
            .achievement(achievementID("achievement.archivist-2"))
        ),
        (
            "grant-group.codex.norse.echo-five",
            "seal.norse.echo-rune",
            "seal.norse.yggdrasil",
            .milestone(ruleID("rule.codex.norse.echo-five"))
        ),
        (
            "grant-group.codex.norse.mastery",
            "relic.norse.runestone.blackstone",
            "crest.norse.raven-mastery",
            .milestone(ruleID("rule.codex.norse.mastery"))
        ),
        (
            "grant-group.codex.norse.mastery",
            "crest.norse.forge-master",
            "title.norse.master-of-runes",
            .milestone(ruleID("rule.codex.norse.mastery"))
        ),
    ]
    let transactionID = GrantTransactionID(rawValue: "transaction.norse-v1-route")!
    let grantedAt = Date(timeIntervalSince1970: 2_000_100_000)

    for (group, legacy, expected, source) in routes {
        let original = GrantRecord(
            generation: String(repeating: "1", count: 32),
            grantGroupID: grantGroupID(group),
            contentID: contentID(legacy),
            source: source,
            transactionID: transactionID,
            grantedAt: grantedAt
        )
        let mapped = ProgressionNorseV2Migration.mappedGrant(
            original,
            generation: String(repeating: "2", count: 32),
            catalog: catalog
        )
        #expect(mapped?.contentID.rawValue == expected)
        #expect(mapped?.source == original.source)
        #expect(mapped?.transactionID == transactionID)
        #expect(mapped?.grantedAt == grantedAt)
    }
}

@Test
func exactNorseV1FingerprintsUpgradeToV2WhileUnknownVariantsFailClosed() throws {
    let fixture = try ProgressionDurableFixture()
    let legacy = try exactNorseV1Bundle(from: fixture.bundle)
    let prior = try ProgressionCatalogCompatibility.fingerprints(for: legacy)
    let current = try ProgressionCatalogCompatibility.fingerprints(for: fixture.bundle)

    #expect(prior.count == 312)
    #expect(current.count == 310)
    try ProgressionCatalogCompatibility.validateUpgrade(
        from: prior,
        to: current,
        fromVersion: legacy.catalog.catalogVersion,
        toVersion: fixture.bundle.catalog.catalogVersion
    )

    let unknown = try currentBundleWithUnknownNorseContent(from: fixture.bundle)
    do {
        try ProgressionCatalogCompatibility.validateUpgrade(
            from: prior,
            to: ProgressionCatalogCompatibility.fingerprints(for: unknown),
            fromVersion: legacy.catalog.catalogVersion,
            toVersion: unknown.catalog.catalogVersion
        )
        Issue.record("A v1 to v2 catalog carrying unknown future Norse content was accepted.")
    } catch {
        #expect(error is ProgressionDomainError)
    }

    do {
        try ProgressionCatalogCompatibility.validateUpgrade(
            from: prior,
            to: current,
            fromVersion: legacy.catalog.catalogVersion,
            toVersion: ProgressionCatalogVersion(rawValue: 3)!
        )
        Issue.record("The special v1 to v2 rewrite was accepted as an unknown future upgrade.")
    } catch {
        #expect(error is ProgressionDomainError)
    }
}

@Test
func norseV1ProjectionMigrationPreservesProvenanceCanonicalizesAndIsIdempotent() throws {
    let fixture = try ProgressionDurableFixture()
    let legacy = try exactNorseV1Bundle(from: fixture.bundle)
    let oldGeneration = ProgressionDeterminism.digest128("norse-v1-projection")
    let newGeneration = ProgressionDeterminism.digest128("norse-v2-projection")
    let completedAt = Date(timeIntervalSince1970: 2_000_110_000)
    let completionEvent = EventID(
        rawValue: UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
    )
    let milestoneEvent = EventID(
        rawValue: UUID(uuidString: "51000000-0000-0000-0000-000000000002")!
    )
    let masteryEvent = EventID(
        rawValue: UUID(uuidString: "51000000-0000-0000-0000-000000000003")!
    )
    let replayAchievementEvent = EventID(
        rawValue: UUID(uuidString: "51000000-0000-0000-0000-000000000004")!
    )
    let replayMasteryEvent = EventID(
        rawValue: UUID(uuidString: "51000000-0000-0000-0000-000000000005")!
    )
    let grantRoutes: [(String, String, ProgressionGrantSource)] = [
        ("grant-group.base.norse.included", "relic.norse.runestone.weathered", .migration(1)),
        ("grant-group.base.norse.included", "seal.norse.knotwork", .migration(1)),
        ("grant-group.base.norse.included", "seal.norse.forge-flame", .migration(1)),
        (
            "grant-group.first-inscription",
            "seal.norse.raven",
            .achievement(achievementID("achievement.first-inscription"))
        ),
        (
            "grant-group.first-dispatch",
            "relic.norse.raven-medallion",
            .achievement(achievementID("achievement.first-dispatch"))
        ),
        (
            "grant-group.correspondent",
            "seal.norse.longship",
            .achievement(achievementID("achievement.correspondent"))
        ),
        (
            "grant-group.courier-1",
            "seal.norse.forge-hammer",
            .achievement(achievementID("achievement.courier-1"))
        ),
        (
            "grant-group.courier-2",
            "relic.norse.ironbound-shield",
            .achievement(achievementID("achievement.courier-2"))
        ),
        (
            "grant-group.archivist-1",
            "frame.norse.carved-knotwork",
            .achievement(achievementID("achievement.archivist-1"))
        ),
        (
            "grant-group.archivist-2",
            "title.archivist",
            .achievement(achievementID("achievement.archivist-2"))
        ),
        (
            "grant-group.archivist-2",
            "relic.norse.sealed-parchment",
            .achievement(achievementID("achievement.archivist-2"))
        ),
        (
            "grant-group.codex.norse.echo-five",
            "seal.norse.echo-rune",
            .milestone(ruleID("rule.codex.norse.echo-five"))
        ),
        (
            "grant-group.codex.norse.mastery",
            "relic.norse.runestone.blackstone",
            .milestone(ruleID("rule.codex.norse.mastery"))
        ),
        (
            "grant-group.codex.norse.mastery",
            "crest.norse.forge-master",
            .milestone(ruleID("rule.codex.norse.mastery"))
        ),
    ]
    let grants = grantRoutes.enumerated().map { index, route in
        GrantRecord(
            generation: oldGeneration,
            grantGroupID: grantGroupID(route.0),
            contentID: contentID(route.1),
            source: route.2,
            transactionID: GrantTransactionID(
                rawValue: "transaction.norse-v1-\(index)"
            )!,
            grantedAt: completedAt.addingTimeInterval(Double(index))
        )
    }
    let ownership = Dictionary(grouping: grants, by: \.contentID).map { content, records in
        OwnershipRecord(
            generation: oldGeneration,
            contentID: content,
            sourceGrantKeys: records.map { ProgressionLogicalRecord.grant($0).identity },
            grantedAt: records.compactMap(\.grantedAt).min()
        )
    }
    let relicUse = StatisticContentUseRecord(
        generation: oldGeneration,
        statisticID: StatisticID(rawValue: "stat.codex.relic-used.unique")!,
        bucketID: CodexID(rawValue: "codex.norse")!,
        contentIDs: [
            contentID("relic.norse.runestone.weathered"),
            contentID("relic.norse.runestone.frozen"),
            contentID("relic.norse.raven-medallion"),
            contentID("relic.norse.sealed-parchment"),
            contentID("relic.norse.ironbound-shield"),
            contentID("relic.norse.runestone.blackstone"),
        ]
    )
    let sealUse = StatisticContentUseRecord(
        generation: oldGeneration,
        statisticID: StatisticID(rawValue: "stat.codex.seal-used.unique")!,
        bucketID: CodexID(rawValue: "codex.norse")!,
        contentIDs: [
            contentID("seal.norse.knotwork"),
            contentID("seal.norse.forge-flame"),
            contentID("seal.norse.raven"),
            contentID("seal.norse.longship"),
            contentID("seal.norse.forge-hammer"),
            contentID("seal.norse.echo-rune"),
        ]
    )
    let encounter = EncounterRecord(
        generation: oldGeneration,
        codexID: CodexID(rawValue: "codex.norse")!,
        artifactIDs: [
            ArtifactID(rawValue: "relic.norse.runestone.weathered")!,
            ArtifactID(rawValue: "relic.norse.runestone.frozen")!,
            ArtifactID(rawValue: "relic.norse.raven-medallion")!,
            ArtifactID(rawValue: "seal.norse.forge-flame")!,
        ],
        firstEncounteredAt: completedAt,
        lastEncounteredAt: completedAt.addingTimeInterval(10),
        encounterCount: 4,
        provenanceStatus: .verified
    )
    var records: [ProgressionLogicalRecord] = [
        .achievementCompletion(AchievementCompletionRecord(
            generation: oldGeneration,
            achievementID: achievementID("achievement.first-inscription"),
            completedAt: completedAt,
            sourceEventID: completionEvent
        )),
        .achievementProgress(AchievementProgressRecord(
            generation: oldGeneration,
            achievementID: achievementID("achievement.first-inscription"),
            current: 1,
            target: 1
        )),
        .milestoneCompletion(MilestoneCompletionRecord(
            generation: oldGeneration,
            ruleID: ruleID("rule.codex.norse.echo-five"),
            completedAt: completedAt.addingTimeInterval(1),
            sourceEventID: milestoneEvent
        )),
        .milestoneCompletion(MilestoneCompletionRecord(
            generation: oldGeneration,
            ruleID: ruleID("rule.codex.norse.mastery"),
            completedAt: completedAt.addingTimeInterval(2),
            sourceEventID: masteryEvent
        )),
        .statisticContentUse(relicUse),
        .statisticContentUse(sealUse),
        .encounter(encounter),
    ]
    records.append(contentsOf: grants.map(ProgressionLogicalRecord.grant))
    records.append(contentsOf: ownership.map(ProgressionLogicalRecord.ownership))

    let old = try ProgressionProjection(
        metadata: ProgressionMetadataRecord(
            catalogID: legacy.catalog.catalogID,
            catalogVersion: legacy.catalog.catalogVersion,
            activeGeneration: oldGeneration
        ),
        records: records
    )
    var migrated = try ProgressionReducer.initialProjection(
        bundle: fixture.bundle,
        generation: newGeneration
    )
    try migrated.upsert(.achievementCompletion(AchievementCompletionRecord(
        generation: newGeneration,
        achievementID: achievementID("achievement.first-inscription"),
        completedAt: completedAt.addingTimeInterval(-10),
        sourceEventID: replayAchievementEvent
    )))
    try migrated.upsert(.milestoneCompletion(MilestoneCompletionRecord(
        generation: newGeneration,
        ruleID: ruleID("rule.codex.norse.mastery"),
        completedAt: completedAt.addingTimeInterval(-5),
        sourceEventID: replayMasteryEvent
    )))

    try ProgressionNorseV2Migration.migrateProjectionFacts(
        from: old,
        in: &migrated,
        catalog: fixture.bundle.catalog
    )

    guard case let .achievementCompletion(completion)? = migrated.records[
        "achievement-completion|achievement.first-inscription"
    ] else {
        Issue.record("The completed v1 achievement was not preserved.")
        return
    }
    #expect(completion.generation == newGeneration)
    #expect(completion.completedAt == completedAt)
    #expect(completion.sourceEventID == completionEvent)
    #expect(completion.sourceExistingUserMigrationTransactionID == nil)
    #expect(completion.sourceExternalMergeTransactionID == nil)

    guard case let .milestoneCompletion(milestone)? = migrated.records[
        "milestone-completion|rule.codex.norse.echo-five"
    ] else {
        Issue.record("The completed v1 milestone was not preserved.")
        return
    }
    #expect(milestone.sourceEventID == milestoneEvent)
    #expect(milestone.completedAt == completedAt.addingTimeInterval(1))

    guard case let .milestoneCompletion(mastery)? = migrated.records[
        "milestone-completion|rule.codex.norse.mastery"
    ] else {
        Issue.record("The authoritative v1 mastery completion was not preserved.")
        return
    }
    #expect(mastery.sourceEventID == masteryEvent)
    #expect(mastery.completedAt == completedAt.addingTimeInterval(2))

    let migratedGrants: [GrantRecord] = migrated.records(matching: {
        guard case let .grant(value) = $0 else { return nil }
        return value
    })
    #expect(migratedGrants.allSatisfy { grant in
        !legacyNorseContentIDs.contains(grant.contentID.rawValue)
    })
    for original in grants {
        let expected = ProgressionNorseV2Migration.mappedGrant(
            original,
            generation: newGeneration,
            catalog: fixture.bundle.catalog
        )
        #expect(expected != nil)
        #expect(expected.map(ProgressionLogicalRecord.grant).map(\.identity).map {
            migrated.records[$0] != nil
        } == true)
    }

    guard case let .ownership(yggdrasil)? = migrated.records[
        "ownership|seal.norse.yggdrasil"
    ] else {
        Issue.record("The two historical Yggdrasil routes did not converge on ownership.")
        return
    }
    #expect(yggdrasil.sourceGrantKeys.count == 2)
    #expect(migrated.records["ownership|title.archivist"] != nil)
    #expect(migrated.records["ownership|seal.norse.berserk"] != nil)
    #expect(migrated.records["ownership|title.norse.master-of-runes"] != nil)
    let migratedOwnership: [OwnershipRecord] = migrated.records(matching: {
        guard case let .ownership(value) = $0 else { return nil }
        return value
    })
    #expect(migratedOwnership.allSatisfy {
        !legacyNorseContentIDs.contains($0.contentID.rawValue)
    })

    guard case let .statisticContentUse(canonicalRelics)? = migrated.records[
        "content-use|stat.codex.relic-used.unique|codex.norse"
    ], case let .statisticContentUse(canonicalSeals)? = migrated.records[
        "content-use|stat.codex.seal-used.unique|codex.norse"
    ] else {
        Issue.record("The v1 content-use evidence was not preserved.")
        return
    }
    #expect(canonicalRelics.contentIDs.map(\.rawValue) == [
        "relic.norse.dragonwood-plaque",
        "relic.norse.runestone-tablet",
        "relic.norse.stormforged-stele",
    ])
    #expect(canonicalSeals.contentIDs.map(\.rawValue) == [
        "seal.norse.mjolnir",
        "seal.norse.ravenshield",
        "seal.norse.valknut",
        "seal.norse.wolkin",
        "seal.norse.yggdrasil",
    ])

    guard case let .encounter(canonicalEncounter)? = migrated.records[
        "encounter|codex.norse"
    ] else {
        Issue.record("The v1 encounter evidence was not preserved.")
        return
    }
    #expect(canonicalEncounter.artifactIDs.map(\.rawValue) == [
        "relic.norse.dragonwood-plaque",
        "relic.norse.runestone-tablet",
        "seal.norse.ravenshield",
    ])
    #expect(canonicalEncounter.artifactObservations.first {
        $0.artifactID.rawValue == "relic.norse.runestone-tablet"
    }?.encounterCount == 2)

    let firstMigration = migrated
    try ProgressionNorseV2Migration.migrateProjectionFacts(
        from: old,
        in: &migrated,
        catalog: fixture.bundle.catalog
    )
    #expect(migrated == firstMigration)
}

@Test
func interruptedNorseV1UpgradeResumesWithoutRepeatingHistoricalYggdrasilReveal() async throws {
    let fixture = try ProgressionDurableFixture()
    let legacy = try exactNorseV1Bundle(from: fixture.bundle)
    let v1 = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: legacy,
        stateClient: fixture.client
    )
    for index in UInt32(1) ... 5 {
        let outcome = try await v1.applyEvent(
            try norseShareEvent(index: index),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "norse-v1-share-\(index)"
            )
        )
        guard case .applied = outcome else {
            Issue.record("The v1 Courier share did not apply.")
            return
        }
    }
    try await acknowledgeEveryReveal(
        in: v1,
        fixture: fixture,
        suffix: "norse-v1-pre-upgrade"
    )
    let acknowledged = try await fixture.snapshot(from: v1, suffix: "norse-v1-acked")
    #expect(acknowledged.pendingRevealCount == 0)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "seal.norse.forge-hammer")!),
        in: acknowledged
    )?.state == .owned)

    for index in UInt32(1) ... 5 {
        let outcome = try await v1.applyEvent(
            fixture.messageDecodedEvent(
                index: index + 500,
                occurredAt: Date(timeIntervalSince1970: 2_000_120_000 + Double(index))
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "norse-v1-decode-\(index)"
            )
        )
        guard case .applied = outcome else {
            Issue.record("The v1 Norse decode did not apply.")
            return
        }
    }
    let decoded = try await fixture.snapshot(from: v1, suffix: "norse-v1-decoded")
    #expect(decoded.pendingRevealCount == 2)
    let listenerRevealID = try #require(decoded.nextReveal?.revealID)
    #expect(decoded.nextReveal?.primaryRewardID == .title(
        TitleID(rawValue: "title.listener")!
    ))
    let listenerTimestamp = Date(timeIntervalSince1970: 2_000_125_000)
    try await fixture.markPresented(
        listenerRevealID,
        using: v1,
        suffix: "norse-v1-listener-ack",
        timestamp: listenerTimestamp
    )
    try await v1.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: listenerRevealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "norse-v1-listener-ack",
            timestamp: listenerTimestamp
        )
    )
    let beforeUpgrade = try await fixture.snapshot(from: v1, suffix: "norse-v1-echo")
    #expect(beforeUpgrade.pendingRevealCount == 1)
    #expect(beforeUpgrade.nextReveal?.primaryRewardID == .artifact(
        ArtifactID(rawValue: "seal.norse.echo-rune")!
    ))
    await v1.shutdown()

    await fixture.store.injectFault(at: .afterTransactionCommit)
    do {
        let unexpectedlyActivated = try await RuneScribeProgressionServiceActor
            .bootstrapForTesting(
                catalogBundle: fixture.bundle,
                stateClient: fixture.client
            )
        await unexpectedlyActivated.shutdown()
        Issue.record("The injected v1 to v2 upgrade interruption did not fire.")
    } catch {
        // A byte-identical retry below must resume the staged migration.
    }

    let resumed = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client
    )
    let upgraded = try await fixture.snapshot(from: resumed, suffix: "norse-v2-resumed")
    #expect(upgraded.catalogVersion == ProgressionCatalogVersion(rawValue: 2))
    #expect(upgraded.pendingRevealCount == 0)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "seal.norse.yggdrasil")!),
        in: upgraded
    )?.state == .owned)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "relic.norse.dragonwood-plaque")!),
        in: upgraded
    )?.state == .owned)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "seal.norse.forge-hammer")!),
        in: upgraded
    ) == nil)
    await resumed.shutdown()

    let relaunched = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client
    )
    let afterRelaunch = try await fixture.snapshot(from: relaunched, suffix: "norse-v2-relaunch")
    #expect(afterRelaunch == upgraded)
    #expect(afterRelaunch.pendingRevealCount == 0)
    await relaunched.shutdown()
}

@Test
func norseV1ArchivistMigrationUpgradePreservesSeedsAndSuppressesItsHistoricalReveal() async throws {
    let fixture = try ProgressionDurableFixture()
    let legacy = try exactNorseV1Bundle(from: fixture.bundle)
    let transactionID = UUID(
        uuidString: "87000000-0000-0000-0000-000000000220"
    )!
    let completedAt = Date(timeIntervalSince1970: 2_000_140_000)
    let delivery = try existingUserDelivery(
        count: 20,
        transactionID: transactionID
    )
    let v1 = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: legacy,
        stateClient: fixture.client,
        requiresExistingUserMigration: true
    )
    guard case .applied = try await v1.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "norse-v1-archivist-migration",
            timestamp: completedAt
        )
    ) else {
        Issue.record("The v1 count-20 Archivist migration did not apply.")
        return
    }

    let before = try await fixture.snapshot(from: v1, suffix: "norse-v1-archivist-before")
    let historicalReveal = try #require(before.nextReveal)
    #expect(before.pendingRevealCount == 1)
    #expect(historicalReveal.primaryRewardID == .title(
        TitleID(rawValue: "title.archivist")!
    ))
    #expect(historicalReveal.secondaryRewardIDs == [
        .artifact(ArtifactID(rawValue: "frame.norse.carved-knotwork")!),
        .artifact(ArtifactID(rawValue: "relic.norse.sealed-parchment")!),
    ])

    let repository = ProgressionRepository(client: fixture.client)
    let stored = try await repository.loadExisting(bundle: legacy)
    let oldMigration = try #require(stored.projection.records(matching: {
        logical -> ExistingUserMigrationRecord? in
        guard case let .existingUserMigration(value) = logical else { return nil }
        return value
    }).first)
    let oldSeeds = try await repository.existingUserMigrationSeeds(
        generation: stored.projection.metadata.activeGeneration
    )
    #expect(oldSeeds.count == 20)
    #expect(oldMigration.transactionID == transactionID)
    #expect(oldMigration.completedAt == completedAt)
    #expect(oldMigration.revealBundle?.secondaryContentIDs.map(\.rawValue) == [
        "frame.norse.carved-knotwork",
        "relic.norse.sealed-parchment",
    ])

    try await fixture.markPresented(
        historicalReveal.revealID,
        using: v1,
        suffix: "norse-v1-archivist-ack",
        timestamp: completedAt.addingTimeInterval(1)
    )
    try await v1.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: historicalReveal.revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "norse-v1-archivist-ack",
            timestamp: completedAt.addingTimeInterval(1)
        )
    )
    await v1.shutdown()

    let upgradedService = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client,
        requiresExistingUserMigration: true
    )
    let upgraded = try await fixture.snapshot(
        from: upgradedService,
        suffix: "norse-v2-archivist-upgraded"
    )
    #expect(upgraded.catalogVersion == ProgressionCatalogVersion(rawValue: 2))
    #expect(upgraded.pendingRevealCount == 0)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "frame.norse.carved-knotwork")!),
        in: upgraded
    )?.state == .owned)
    #expect(fixture.ownership(
        .title(TitleID(rawValue: "title.archivist")!),
        in: upgraded
    )?.state == .owned)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "seal.norse.berserk")!),
        in: upgraded
    )?.state == .owned)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "relic.norse.sealed-parchment")!),
        in: upgraded
    ) == nil)

    let currentState = try await repository.loadExisting(bundle: fixture.bundle)
    let currentMigration = try #require(currentState.projection.records(matching: {
        logical -> ExistingUserMigrationRecord? in
        guard case let .existingUserMigration(value) = logical else { return nil }
        return value
    }).first)
    #expect(currentMigration.transactionID == oldMigration.transactionID)
    #expect(currentMigration.snapshotDigest == oldMigration.snapshotDigest)
    #expect(currentMigration.cipherCount == oldMigration.cipherCount)
    #expect(currentMigration.completedAt == oldMigration.completedAt)
    #expect(currentMigration.grantTransactionID == oldMigration.grantTransactionID)
    #expect(currentMigration.revealBundle?.primaryContentID.rawValue == "title.archivist")
    #expect(currentMigration.revealBundle?.secondaryContentIDs.map(\.rawValue) == [
        "frame.norse.carved-knotwork",
        "seal.norse.berserk",
    ])
    let currentSeeds = try await repository.existingUserMigrationSeeds(
        generation: currentState.projection.metadata.activeGeneration
    )
    #expect(seedEvidence(currentSeeds) == seedEvidence(oldSeeds))
    #expect(try await upgradedService.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "norse-v2-archivist-duplicate",
            timestamp: completedAt
        )
    ) == .duplicate)
    await upgradedService.shutdown()

    let relaunched = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client,
        requiresExistingUserMigration: true
    )
    let afterRelaunch = try await fixture.snapshot(
        from: relaunched,
        suffix: "norse-v2-archivist-relaunch"
    )
    #expect(afterRelaunch == upgraded)
    #expect(afterRelaunch.pendingRevealCount == 0)
    await relaunched.shutdown()
}

@Test
func exactNorseV1LegacyOutgoingShareHistoryUpgradesToCanonicalV2Ledger() async throws {
    let fixture = try ProgressionDurableFixture()
    let legacy = try exactNorseV1Bundle(from: fixture.bundle)
    let v1 = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: legacy,
        stateClient: fixture.client
    )
    let legacyArtifacts = [
        ArtifactID(rawValue: "relic.norse.runestone.weathered")!,
        ArtifactID(rawValue: "seal.norse.knotwork")!,
    ]
    guard case .applied = try await v1.applyEvent(
        try norseShareEvent(index: 850, artifactIDs: legacyArtifacts),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "norse-v1-legacy-outgoing-share"
        )
    ) else {
        Issue.record("The exact v1 service rejected its historical Norse artifact IDs.")
        await v1.shutdown()
        return
    }
    await v1.shutdown()

    let upgraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client
    )
    let upgradedSnapshot = try await fixture.snapshot(
        from: upgraded,
        suffix: "norse-v2-legacy-outgoing-upgraded"
    )
    #expect(upgradedSnapshot.catalogVersion == ProgressionCatalogVersion(rawValue: 2))

    let repository = ProgressionRepository(client: fixture.client)
    let stored = try await repository.loadExisting(bundle: fixture.bundle)
    guard case let .statisticContentUse(relicUse)? = stored.projection.records[
        "content-use|stat.share.relic-used.unique|-"
    ], case let .statisticContentUse(sealUse)? = stored.projection.records[
        "content-use|stat.share.seal-used.unique|-"
    ] else {
        Issue.record("The historical v1 share facts were not retained in v2.")
        await upgraded.shutdown()
        return
    }
    #expect(relicUse.contentIDs.map(\.rawValue) == ["relic.norse.runestone-tablet"])
    #expect(sealUse.contentIDs.map(\.rawValue) == ["seal.norse.valknut"])
    await upgraded.shutdown()

    let relaunched = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client
    )
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "norse-v2-legacy-outgoing-relaunch"
    ) == upgradedSnapshot)
    await relaunched.shutdown()
}

@Test
func freshNorseV2RejectsLegacyOutgoingShareAndCanonicalizesLegacyIncomingPresentation() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let legacyRelicAndSealIDs = [
        "relic.norse.ironbound-shield",
        "relic.norse.raven-medallion",
        "relic.norse.runestone.blackstone",
        "relic.norse.runestone.frozen",
        "relic.norse.runestone.weathered",
        "relic.norse.sealed-parchment",
        "seal.norse.echo-rune",
        "seal.norse.forge-flame",
        "seal.norse.forge-hammer",
        "seal.norse.knotwork",
        "seal.norse.longship",
        "seal.norse.raven",
    ].map { ArtifactID(rawValue: $0)! }
    let legacyPresentationIDs = legacyRelicAndSealIDs + [
        ArtifactID(rawValue: "crest.norse.forge-master")!,
    ]

    let repository = ProgressionRepository(client: fixture.client)
    let beforeOutgoingRejection = try await fixture.snapshot(
        from: service,
        suffix: "norse-v2-before-legacy-outgoing-share"
    )
    let stateBeforeOutgoingRejection = try await repository.loadExisting(
        bundle: fixture.bundle
    )
    guard case let .rejectedPermanent(legacyReason) = try await service.applyEvent(
        try norseShareEvent(index: 900, artifactIDs: legacyRelicAndSealIDs),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "norse-v2-legacy-outgoing-share"
        )
    ) else {
        Issue.record("The fresh v2 service accepted legacy artifacts in an outgoing share.")
        await service.shutdown()
        return
    }
    #expect(legacyReason == ProgressionEventValidator.invalidPayload)
    let afterOutgoingRejection = try await fixture.snapshot(
        from: service,
        suffix: "norse-v2-after-legacy-outgoing-share"
    )
    let stateAfterOutgoingRejection = try await repository.loadExisting(
        bundle: fixture.bundle
    )
    #expect(afterOutgoingRejection == beforeOutgoingRejection)
    #expect(
        stateAfterOutgoingRejection.projection.records ==
            stateBeforeOutgoingRejection.projection.records
    )
    #expect(
        stateAfterOutgoingRejection.projection.metadata.revision ==
            stateBeforeOutgoingRejection.projection.metadata.revision
    )
    #expect(
        stateAfterOutgoingRejection.projection.metadata.appliedEventCount ==
            stateBeforeOutgoingRejection.projection.metadata.appliedEventCount
    )
    #expect(
        stateAfterOutgoingRejection.projection.metadata.appliedEventDigest ==
            stateBeforeOutgoingRejection.projection.metadata.appliedEventDigest
    )

    guard case .applied = try await service.applyEvent(
        fixture.presentationEvent(
            index: 901,
            occurredAt: Date(timeIntervalSince1970: 2_000_150_001),
            artifacts: legacyPresentationIDs,
            provenance: .verified
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "norse-v2-legacy-incoming-presentation"
        )
    ) else {
        Issue.record("The v2 service rejected the legacy Norse presentation payload.")
        await service.shutdown()
        return
    }

    let stored = try await repository.loadExisting(bundle: fixture.bundle)
    guard case let .encounter(encounter)? = stored.projection.records[
        "encounter|codex.norse"
    ] else {
        Issue.record("The legacy presentation did not store Norse encounter evidence.")
        await service.shutdown()
        return
    }
    #expect(encounter.artifactIDs.map(\.rawValue) == [
        "crest.norse.raven-mastery",
        "relic.norse.dragonwood-plaque",
        "relic.norse.runestone-tablet",
        "relic.norse.stormforged-stele",
        "seal.norse.mjolnir",
        "seal.norse.ravenshield",
        "seal.norse.valknut",
        "seal.norse.wolkin",
        "seal.norse.yggdrasil",
    ])
    #expect(Set(encounter.artifactIDs).count == encounter.artifactIDs.count)
    #expect(encounter.artifactObservations.allSatisfy { $0.encounterCount == 1 })
    #expect(encounter.artifactIDs.allSatisfy {
        !legacyNorseContentIDs.contains($0.rawValue)
    })

    let snapshotBeforeRejection = try await fixture.snapshot(
        from: service,
        suffix: "norse-v2-before-unknown-artifact"
    )
    let projectionBeforeRejection = stored.projection
    let unknown = try fixture.presentationEvent(
        index: 902,
        occurredAt: Date(timeIntervalSince1970: 2_000_150_002),
        artifacts: [ArtifactID(rawValue: "seal.norse.future-unknown")!],
        provenance: .verified
    )
    guard case let .rejectedPermanent(reason) = try await service.applyEvent(
        unknown,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "norse-v2-unknown-future-artifact"
        )
    ) else {
        Issue.record("The unknown future Norse artifact did not fail closed.")
        await service.shutdown()
        return
    }
    #expect(reason == ProgressionEventValidator.invalidPayload)

    let snapshotAfterRejection = try await fixture.snapshot(
        from: service,
        suffix: "norse-v2-after-unknown-artifact"
    )
    let stateAfterRejection = try await repository.loadExisting(bundle: fixture.bundle)
    #expect(snapshotAfterRejection == snapshotBeforeRejection)
    #expect(stateAfterRejection.projection.records == projectionBeforeRejection.records)
    #expect(
        stateAfterRejection.projection.metadata.revision ==
            projectionBeforeRejection.metadata.revision
    )
    #expect(
        stateAfterRejection.projection.metadata.appliedEventCount ==
            projectionBeforeRejection.metadata.appliedEventCount
    )
    #expect(
        stateAfterRejection.projection.metadata.lastAppliedRevision ==
            projectionBeforeRejection.metadata.lastAppliedRevision
    )
    #expect(
        stateAfterRejection.projection.metadata.appliedEventDigest ==
            projectionBeforeRejection.metadata.appliedEventDigest
    )
    await service.shutdown()
}

private enum NorseV1FixtureError: Error {
    case malformedCatalog
}

private let legacyNorseContentIDs = Set([
    "crest.norse.forge-master",
    "relic.norse.ironbound-shield",
    "relic.norse.raven-medallion",
    "relic.norse.runestone.blackstone",
    "relic.norse.runestone.frozen",
    "relic.norse.runestone.weathered",
    "relic.norse.sealed-parchment",
    "seal.norse.echo-rune",
    "seal.norse.forge-flame",
    "seal.norse.forge-hammer",
    "seal.norse.knotwork",
    "seal.norse.longship",
    "seal.norse.raven",
])

private let currentNorseReplacementIDs = Set([
    "crest.norse.raven-mastery",
    "relic.norse.dragonwood-plaque",
    "relic.norse.runestone-tablet",
    "relic.norse.stormforged-stele",
    "seal.norse.berserk",
    "seal.norse.mjolnir",
    "seal.norse.ravenshield",
    "seal.norse.valknut",
    "seal.norse.wolkin",
    "seal.norse.yggdrasil",
    "title.norse.master-of-runes",
])

private func exactNorseV1Bundle(
    from current: ValidatedProgressionCatalogBundle
) throws -> ValidatedProgressionCatalogBundle {
    var root = try progressionCatalogJSONObject()
    root["catalogVersion"] = 1

    guard var content = root["content"] as? [[String: Any]],
          var groups = root["grantGroups"] as? [[String: Any]],
          var milestones = root["milestones"] as? [[String: Any]]
    else { throw NorseV1FixtureError.malformedCatalog }

    content = try content.compactMap { definition in
        guard let identifier = definition["contentID"] as? String else {
            throw NorseV1FixtureError.malformedCatalog
        }
        guard !currentNorseReplacementIDs.contains(identifier) else { return nil }
        guard identifier == "frame.norse.carved-knotwork" else { return definition }
        var legacy = definition
        legacy["displayName"] = "Carved Knotwork Frame"
        return legacy
    }
    content.append(contentsOf: legacyNorseContentDefinitions())
    root["content"] = content

    let legacyGroups: [String: (items: [String], primary: String)] = [
        "grant-group.base.norse.included": (
            [
                "unlock.codex.norse", "codex.norse", "script.base-runes",
                "relic.norse.runestone.weathered", "seal.norse.knotwork",
                "seal.norse.forge-flame",
            ],
            "codex.norse"
        ),
        "grant-group.first-inscription": (["seal.norse.raven"], "seal.norse.raven"),
        "grant-group.first-dispatch": (
            ["relic.norse.raven-medallion"],
            "relic.norse.raven-medallion"
        ),
        "grant-group.correspondent": (["seal.norse.longship"], "seal.norse.longship"),
        "grant-group.courier-1": (["seal.norse.forge-hammer"], "seal.norse.forge-hammer"),
        "grant-group.courier-2": (
            ["relic.norse.ironbound-shield"],
            "relic.norse.ironbound-shield"
        ),
        "grant-group.archivist-1": (
            ["frame.norse.carved-knotwork"],
            "frame.norse.carved-knotwork"
        ),
        "grant-group.archivist-2": (
            ["title.archivist", "relic.norse.sealed-parchment"],
            "title.archivist"
        ),
        "grant-group.codex.norse.echo-five": (
            ["seal.norse.echo-rune"],
            "seal.norse.echo-rune"
        ),
        "grant-group.codex.norse.mastery": (
            ["relic.norse.runestone.blackstone", "crest.norse.forge-master"],
            "relic.norse.runestone.blackstone"
        ),
    ]
    groups = try groups.map { group in
        guard let identifier = group["grantGroupID"] as? String else {
            throw NorseV1FixtureError.malformedCatalog
        }
        guard let replacement = legacyGroups[identifier] else { return group }
        var legacy = group
        legacy["items"] = replacement.items.map {
            ["contentID": $0, "grantKind": "permanent"]
        }
        legacy["primaryContentID"] = replacement.primary
        if identifier == "grant-group.codex.norse.echo-five" {
            legacy.removeValue(forKey: "notes")
        }
        return legacy
    }
    root["grantGroups"] = groups

    milestones = try milestones.map { milestone in
        guard let identifier = milestone["ruleID"] as? String else {
            throw NorseV1FixtureError.malformedCatalog
        }
        guard identifier == "rule.codex.norse.mastery",
              var rule = milestone["rule"] as? [String: Any],
              var conditions = rule["conditions"] as? [[String: Any]],
              var progress = milestone["progressComponents"] as? [[String: Any]]
        else { return milestone }
        for index in conditions.indices where
            conditions[index]["op"] as? String == "allListedContentUsed"
        {
            conditions[index]["contentIDs"] = legacyMasteryRelicIDs
        }
        for index in progress.indices where
            progress[index]["type"] as? String == "all-content-used"
        {
            progress[index]["contentIDs"] = legacyMasteryRelicIDs
        }
        rule["conditions"] = conditions
        var legacy = milestone
        legacy["rule"] = rule
        legacy["progressComponents"] = progress
        return legacy
    }
    root["milestones"] = milestones

    let catalog = try decodeCatalog(root)
    let eventCatalog = ProgressionEventCatalog(
        schemaVersion: current.eventCatalog.schemaVersion,
        catalogID: current.eventCatalog.catalogID,
        catalogVersion: ProgressionCatalogVersion(rawValue: 1)!,
        status: current.eventCatalog.status,
        effectiveDate: current.eventCatalog.effectiveDate,
        eventEnvelope: current.eventCatalog.eventEnvelope,
        applyOutcomes: current.eventCatalog.applyOutcomes,
        acknowledgeOutboxOn: current.eventCatalog.acknowledgeOutboxOn,
        retainOutboxOn: current.eventCatalog.retainOutboxOn,
        events: current.eventCatalog.events,
        shareRoutePolicy: current.eventCatalog.shareRoutePolicy,
        forbiddenData: current.eventCatalog.forbiddenData,
        eligibilityReasonIDs: current.eventCatalog.eligibilityReasonIDs
    )
    let bindings = ProgressionFutureThemeBindingContract(
        schemaVersion: current.futureThemeBindings.schemaVersion,
        contractID: current.futureThemeBindings.contractID,
        version: ProgressionCatalogVersion(rawValue: 1)!,
        status: current.futureThemeBindings.status,
        bindings: current.futureThemeBindings.bindings,
        rules: current.futureThemeBindings.rules,
        supersessions: current.futureThemeBindings.supersessions
    )
    return ValidatedProgressionCatalogBundle(
        catalog: catalog,
        eventCatalog: eventCatalog,
        futureThemeBindings: bindings,
        dependencyAnalysis: current.dependencyAnalysis,
        integrityMetadata: current.integrityMetadata
    )
}

private func currentBundleWithUnknownNorseContent(
    from current: ValidatedProgressionCatalogBundle
) throws -> ValidatedProgressionCatalogBundle {
    var root = try progressionCatalogJSONObject()
    guard var content = root["content"] as? [[String: Any]] else {
        throw NorseV1FixtureError.malformedCatalog
    }
    content.append([
        "contentID": "seal.norse.future-unknown",
        "kind": "seal",
        "displayName": "Unknown Future Seal",
        "countsAsArtifact": true,
        "availability": "permanent",
        "rarity": "Rare",
        "codexID": "codex.norse",
    ])
    root["content"] = content
    return ValidatedProgressionCatalogBundle(
        catalog: try decodeCatalog(root),
        eventCatalog: current.eventCatalog,
        futureThemeBindings: current.futureThemeBindings,
        dependencyAnalysis: current.dependencyAnalysis,
        integrityMetadata: current.integrityMetadata
    )
}

private func progressionCatalogJSONObject() throws -> [String: Any] {
    let descriptor = ProgressionCatalogResourceCatalog.catalogDescriptor
    let resource = descriptor.resource
    guard let url = RuneScribeProgressionModuleBootstrap.resourceBundle.url(
        forResource: resource.name,
        withExtension: resource.fileExtension,
        subdirectory: resource.subdirectory
    ), let root = try JSONSerialization.jsonObject(
        with: Data(contentsOf: url)
    ) as? [String: Any]
    else { throw NorseV1FixtureError.malformedCatalog }
    return root
}

private func decodeCatalog(_ root: [String: Any]) throws -> ProgressionCatalog {
    guard JSONSerialization.isValidJSONObject(root) else {
        throw NorseV1FixtureError.malformedCatalog
    }
    return try JSONDecoder().decode(
        ProgressionCatalog.self,
        from: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    )
}

private func acknowledgeEveryReveal(
    in service: RuneScribeProgressionServiceActor,
    fixture: ProgressionDurableFixture,
    suffix: String
) async throws {
    var index = 0
    while true {
        let snapshot = try await fixture.snapshot(
            from: service,
            suffix: "\(suffix)-snapshot-\(index)"
        )
        guard let revealID = snapshot.nextReveal?.revealID else {
            #expect(snapshot.pendingRevealCount == 0)
            return
        }
        let timestamp = Date(timeIntervalSince1970: 2_000_130_000 + Double(index))
        try await fixture.markPresented(
            revealID,
            using: service,
            suffix: "\(suffix)-\(index)",
            timestamp: timestamp
        )
        try await service.acknowledgeReveal(
            AcknowledgeProgressionRevealCommand(revealID: revealID),
            metadata: fixture.metadata(
                operation: "progression.reveal.acknowledge",
                suffix: "\(suffix)-ack-\(index)",
                timestamp: timestamp
            )
        )
        index += 1
        guard index <= 64 else { throw NorseV1FixtureError.malformedCatalog }
    }
}

private func existingUserDelivery(
    count: Int,
    transactionID: UUID
) throws -> ExistingUserMigrationDeliveryDTO {
    let ciphers = try (0 ..< count).map { index in
        try ExistingUserMigrationCipherDTO(
            cipherToken: CipherToken(
                rawValue: String(repeating: "n", count: 24) +
                    String(format: "%08x", index)
            )!,
            origin: index.isMultiple(of: 2) ? .generated : .imported
        )
    }
    return ExistingUserMigrationDeliveryDTO(
        transactionID: ExistingUserMigrationTransactionID(rawValue: transactionID),
        snapshot: try ExistingUserMigrationSnapshotDTO(ciphers: ciphers)
    )
}

private func norseShareEvent(
    index: UInt32,
    artifactIDs: [ArtifactID] = []
) throws -> DomainEventEnvelope {
    let eventSuffix = String(format: "%012x", 300_000 + index)
    let correlationSuffix = String(format: "%012x", 400_000 + index)
    return try DomainEventEnvelope(
        schemaVersion: 1,
        eventID: EventID(
            rawValue: UUID(uuidString: "52000000-0000-0000-0000-\(eventSuffix)")!
        ),
        correlationID: CorrelationID(
            rawValue: UUID(uuidString: "53000000-0000-0000-0000-\(correlationSuffix)")!
        ),
        eventType: EventIdentifier(rawValue: "runescribe.share.completed"),
        sourceModuleID: RuneScribeModuleIDs.core,
        occurredAt: Date(timeIntervalSince1970: 2_000_121_000 + Double(index)),
        eligibility: DomainEventEligibilityMetadata(
            state: .eligible,
            reason: EligibilityReasonID(
                rawValue: "eligibility.eligible.message-sent-confirmed"
            )!
        ),
        payload: DomainEventPayload(
            messageToken: MessageToken(
                rawValue: String(repeating: "m", count: 24) + String(format: "%08x", index)
            ),
            routeClass: .messages,
            codexIDs: [CodexID(rawValue: "codex.norse")!],
            artifactIDs: artifactIDs,
            keyIncluded: false,
            linkedRelationship: false
        )
    )
}

private func seedEvidence(_ records: [ExistingUserMigrationSeedRecord]) -> [String] {
    records.map {
        "\($0.cipherToken.rawValue)|\($0.origin.rawValue)|" +
            ($0.sourcePageIndex.map(String.init) ?? "-")
    }.sorted()
}

private func contentID(_ rawValue: String) -> ProgressionContentID {
    ProgressionContentID(rawValue: rawValue)!
}

private func achievementID(_ rawValue: String) -> AchievementID {
    AchievementID(rawValue: rawValue)!
}

private func ruleID(_ rawValue: String) -> RuleID {
    RuleID(rawValue: rawValue)!
}

private func grantGroupID(_ rawValue: String) -> GrantGroupID {
    GrantGroupID(rawValue: rawValue)!
}

private let legacyMasteryRelicIDs = [
    "relic.norse.runestone.weathered",
    "relic.norse.raven-medallion",
    "relic.norse.ironbound-shield",
    "relic.norse.sealed-parchment",
]

private func legacyNorseContentDefinitions() -> [[String: Any]] {
    [[
        "contentID": "crest.norse.forge-master", "kind": "crest",
        "displayName": "Forge Master Crest", "countsAsArtifact": true,
        "availability": "permanent-mastery", "rarity": "Mythic",
        "codexID": "codex.norse",
    ],
    [
        "contentID": "relic.norse.ironbound-shield", "kind": "relic",
        "displayName": "Ironbound Round Shield", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Rare", "codexID": "codex.norse",
    ],
    [
        "contentID": "relic.norse.raven-medallion", "kind": "relic",
        "displayName": "Raven Medallion", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Inscribed", "codexID": "codex.norse",
    ],
    [
        "contentID": "relic.norse.runestone.blackstone", "kind": "relic",
        "displayName": "Blackstone Rune Stone", "countsAsArtifact": true,
        "availability": "permanent-mastery", "rarity": "Mythic",
        "codexID": "codex.norse",
    ],
    [
        "contentID": "relic.norse.runestone.frozen", "kind": "relic",
        "displayName": "Frozen Rune Stone", "countsAsArtifact": true,
        "availability": "seasonal-deferred", "rarity": "Mythic",
        "codexID": "codex.norse",
        "notes": "No active v1 rule; requires a future approved Season catalog.",
    ],
    [
        "contentID": "relic.norse.runestone.weathered", "kind": "relic",
        "displayName": "Weathered Rune Stone", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Forged", "codexID": "codex.norse",
    ],
    [
        "contentID": "relic.norse.sealed-parchment", "kind": "relic",
        "displayName": "Sealed Parchment", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Inscribed", "codexID": "codex.norse",
    ],
    [
        "contentID": "seal.norse.echo-rune", "kind": "seal",
        "displayName": "Echo Rune Seal", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Rare", "codexID": "codex.norse",
    ],
    [
        "contentID": "seal.norse.forge-flame", "kind": "seal",
        "displayName": "Forge Flame", "countsAsArtifact": true,
        "availability": "included", "rarity": "Forged", "codexID": "codex.norse",
    ],
    [
        "contentID": "seal.norse.forge-hammer", "kind": "seal",
        "displayName": "Forge Hammer Seal", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Inscribed", "codexID": "codex.norse",
    ],
    [
        "contentID": "seal.norse.knotwork", "kind": "seal",
        "displayName": "Knotwork Mark", "countsAsArtifact": true,
        "availability": "included", "rarity": "Forged", "codexID": "codex.norse",
    ],
    [
        "contentID": "seal.norse.longship", "kind": "seal",
        "displayName": "Longship Seal", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Inscribed", "codexID": "codex.norse",
    ],
    [
        "contentID": "seal.norse.raven", "kind": "seal",
        "displayName": "Raven Seal", "countsAsArtifact": true,
        "availability": "permanent", "rarity": "Inscribed", "codexID": "codex.norse",
    ]]
}
