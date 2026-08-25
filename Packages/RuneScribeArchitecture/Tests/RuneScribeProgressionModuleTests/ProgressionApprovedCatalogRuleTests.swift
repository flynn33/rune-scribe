import Foundation
import RuneScribeContracts
import Testing
@testable import RuneScribeProgressionModule

@Test
func approvedAchievementWeightsJourneyAndRuleMappingsAreExact() throws {
    let bundle = try approvedCatalogBundle()
    let achievements = bundle.catalog.achievements.map {
        "\($0.achievementID.rawValue)|\($0.localPointWeight)|" +
            $0.rewardGrantGroupID.rawValue
    }
    #expect(achievements == [
        "achievement.first-inscription|5|grant-group.first-inscription",
        "achievement.first-dispatch|5|grant-group.first-dispatch",
        "achievement.echo-returns|10|grant-group.echo-returns",
        "achievement.correspondent|10|grant-group.correspondent",
        "achievement.courier-1|10|grant-group.courier-1",
        "achievement.courier-2|20|grant-group.courier-2",
        "achievement.five-circles|25|grant-group.codex.moonleaf.unlock",
        "achievement.archivist-1|10|grant-group.archivist-1",
        "achievement.archivist-2|25|grant-group.archivist-2",
        "achievement.relic-bearer|10|grant-group.relic-bearer",
        "achievement.seal-keeper|10|grant-group.seal-keeper",
        "achievement.many-worlds|20|grant-group.many-worlds",
        "achievement.explorer|10|grant-group.explorer",
        "achievement.collector|20|grant-group.collector",
        "achievement.master-scribe|30|grant-group.master-scribe",
    ])
    #expect(bundle.catalog.achievements.reduce(UInt16(0)) {
        $0 + $1.localPointWeight
    } == 220)
    #expect(bundle.catalog.gameCenterPolicy.localCatalogPointTotal == 220)

    let milestones = bundle.catalog.milestones.map {
        "\($0.ruleID.rawValue)|\($0.grantGroupID.rawValue)"
    }
    #expect(milestones == approvedMilestoneGrantMappings)
    #expect(milestones.count == 30)

    let nodes = bundle.catalog.journeyGraph.nodes.sorted { $0.order < $1.order }.map {
        "\($0.nodeID.rawValue)|\($0.contentID.rawValue)|\($0.order)"
    }
    #expect(nodes == [
        "journey.codex.norse|codex.norse|0",
        "journey.codex.moonleaf|codex.moonleaf|1",
        "journey.codex.sunspire|codex.sunspire|2",
        "journey.codex.wildwood|codex.wildwood|3",
        "journey.codex.gloamthorn|codex.gloamthorn|4",
    ])
    #expect(bundle.catalog.journeyGraph.edges.map {
        "\($0.from.rawValue)>\($0.to.rawValue)"
    } == [
        "journey.codex.norse>journey.codex.moonleaf",
        "journey.codex.moonleaf>journey.codex.sunspire",
        "journey.codex.sunspire>journey.codex.wildwood",
        "journey.codex.wildwood>journey.codex.gloamthorn",
    ])
}

@Test
func approvedGrantGroupsHaveExactRewardsPrimariesAndRevealTiers() throws {
    let actual = try approvedCatalogBundle().catalog.grantGroups.map { group in
        let items = group.items.map(\.contentID.rawValue).joined(separator: ",")
        return "\(group.grantGroupID.rawValue)|\(group.revealTier.rawValue)|" +
            "\(group.primaryContentID.rawValue)|\(items)"
    }
    #expect(actual == approvedGrantGroupDefinitions)
    #expect(actual.count == 45)
}

@Test
func everyApprovedAchievementAndMilestoneRuleHasExactBoundaryBehavior() throws {
    let bundle = try approvedCatalogBundle()
    let achievementUniverse = bundle.catalog.achievements.map(\.achievementID)
    let codexUniverse = bundle.catalog.content.compactMap { content -> CodexID? in
        guard content.kind == .codex else { return nil }
        return CodexID(rawValue: content.contentID.rawValue)
    }
    let rules: [ApprovedRuleCase] = bundle.catalog.achievements.map {
        ("achievement:\($0.achievementID.rawValue)", toRule: $0.rule)
    } + bundle.catalog.milestones.map {
        ("milestone:\($0.ruleID.rawValue)", toRule: $0.rule)
    }

    #expect(rules.count == 45)
    for item in rules {
        var exact = ApprovedFactAccumulator()
        exact.satisfy(
            item.toRule,
            achievementUniverse: achievementUniverse,
            codexUniverse: codexUniverse
        )
        #expect(
            ProgressionRuleEvaluator.evaluate(
                item.toRule,
                facts: exact.facts
            ).isSatisfied,
            Comment(rawValue: "Expected satisfied rule: \(item.0)")
        )

        var duplicate = exact
        duplicate.satisfy(
            item.toRule,
            achievementUniverse: achievementUniverse,
            codexUniverse: codexUniverse
        )
        #expect(
            duplicate == exact,
            Comment(rawValue: "Duplicate facts changed rule input: \(item.0)")
        )
        #expect(ProgressionRuleEvaluator.evaluate(
            item.toRule,
            facts: duplicate.facts
        ).isSatisfied)

        var above = ApprovedFactAccumulator()
        above.satisfyAbove(
            item.toRule,
            achievementUniverse: achievementUniverse,
            codexUniverse: codexUniverse
        )
        #expect(
            ProgressionRuleEvaluator.evaluate(
                item.toRule,
                facts: above.facts
            ).isSatisfied,
            Comment(rawValue: "Expected above-threshold rule: \(item.0)")
        )

        var oneBelow = ApprovedFactAccumulator()
        oneBelow.satisfyOneBelow(
            item.toRule,
            achievementUniverse: achievementUniverse,
            codexUniverse: codexUniverse
        )
        #expect(
            !ProgressionRuleEvaluator.evaluate(
                item.toRule,
                facts: oneBelow.facts
            ).isSatisfied,
            Comment(rawValue: "Expected one-below rule: \(item.0)")
        )

        let unrelated = ApprovedFactAccumulator(
            counters: ["stat.unrelated": 1],
            distinctValues: ["stat.unrelated": ["unrelated-value"]]
        )
        #expect(
            !ProgressionRuleEvaluator.evaluate(
                item.toRule,
                facts: unrelated.facts
            ).isSatisfied,
            Comment(rawValue: "Unrelated facts completed rule: \(item.0)")
        )
    }
}

@Test
func approvedPreownershipCollectorMasterAndCurrentNorseSemanticsAreExplicit() throws {
    let catalog = try approvedCatalogBundle().catalog
    let incoming = try #require(catalog.milestones.first {
        $0.ruleID.rawValue == "rule.codex.moonleaf.incoming-five"
    })
    let encounter = try #require(catalog.milestones.first {
        $0.ruleID.rawValue == "rule.codex.moonleaf.encounter"
    })
    let collector = try #require(catalog.achievements.first {
        $0.achievementID.rawValue == "achievement.collector"
    })
    let master = try #require(catalog.achievements.first {
        $0.achievementID.rawValue == "achievement.master-scribe"
    })

    let incomingKey = ProgressionRuleFacts.counterKey(
        StatisticID(rawValue: "stat.codex.incoming-decode.unique-package")!,
        CodexID(rawValue: "codex.moonleaf")!
    )
    let preownership = ProgressionRuleFacts(
        counters: [incomingKey: 5],
        distinctValues: [:],
        ownedContentIDs: [],
        completedAchievementIDs: []
    )
    #expect(!ProgressionRuleEvaluator.evaluate(incoming.rule, facts: preownership).isSatisfied)

    let withOwnership = ProgressionRuleFacts(
        counters: preownership.counters,
        distinctValues: [:],
        ownedContentIDs: [ProgressionContentID(rawValue: "codex.moonleaf")!],
        completedAchievementIDs: []
    )
    #expect(ProgressionRuleEvaluator.evaluate(incoming.rule, facts: withOwnership).isSatisfied)

    var encounterFacts = ApprovedFactAccumulator()
    encounterFacts.satisfy(encounter.rule, achievementUniverse: [], codexUniverse: [])
    #expect(encounterFacts.facts.ownedContentIDs.isEmpty)
    #expect(ProgressionRuleEvaluator.evaluate(
        encounter.rule,
        facts: encounterFacts.facts
    ).isSatisfied)

    guard case let .distinctCountAtLeast(collectorStatistic, threshold, bucket) =
        collector.rule
    else {
        Issue.record("Collector must remain a direct artifact-ownership threshold.")
        return
    }
    #expect(collectorStatistic.rawValue == "stat.ownership.artifact-count")
    #expect(threshold == 20)
    #expect(bucket == nil)

    guard case let .completedAchievementCountAtLeast(masterThreshold, excluding) =
        master.rule
    else {
        Issue.record("Master Scribe must remain self-excluding achievement count.")
        return
    }
    #expect(masterThreshold == 10)
    #expect(excluding.map(\.rawValue) == ["achievement.master-scribe"])

    let currentNorseContent = Set(catalog.content.compactMap { content -> String? in
        let value = content.contentID.rawValue
        return value.contains(".norse.") ? value : nil
    })
    #expect(currentNorseContent == [
        "crest.norse.raven-mastery",
        "frame.norse.carved-knotwork",
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
}

@Test
func sunspireUnlockRequiresEveryApprovedConditionCombination() throws {
    let catalog = try approvedCatalogBundle().catalog
    let sunspire = try #require(catalog.milestones.first {
        $0.ruleID.rawValue == "rule.codex.sunspire.reciprocal-light"
    })
    let moonleaf = ProgressionContentID(rawValue: "codex.moonleaf")!
    let relationshipStatistic = StatisticID(
        rawValue: "stat.relationship.bidirectional.unique"
    )!
    let incomingStatistic = StatisticID(
        rawValue: "stat.message.incoming-decoded.unique"
    )!

    for ownsMoonleaf in [false, true] {
        for relationshipCount in [UInt64(2), 3] {
            for incomingCount in [UInt64(9), 10] {
                let facts = ProgressionRuleFacts(
                    counters: [
                        ProgressionRuleFacts.counterKey(
                            relationshipStatistic,
                            nil
                        ): relationshipCount,
                        ProgressionRuleFacts.counterKey(
                            incomingStatistic,
                            nil
                        ): incomingCount,
                    ],
                    distinctValues: [:],
                    ownedContentIDs: ownsMoonleaf ? [moonleaf] : [],
                    completedAchievementIDs: []
                )
                let expected = ownsMoonleaf
                    && relationshipCount == 3
                    && incomingCount == 10
                #expect(
                    ProgressionRuleEvaluator.evaluate(
                        sunspire.rule,
                        facts: facts
                    ).isSatisfied == expected,
                    Comment(
                        rawValue: "Sunspire combination ownership=\(ownsMoonleaf) " +
                            "relationships=\(relationshipCount) incoming=\(incomingCount)"
                    )
                )
            }
        }
    }
}

@Test
func gloamthornRequiresFiveSharesInEachOfThreeCodexBuckets() throws {
    let catalog = try approvedCatalogBundle().catalog
    let gloamthorn = try #require(catalog.milestones.first {
        $0.ruleID.rawValue == "rule.codex.gloamthorn.beyond-the-gloam"
    })
    let shareStatistic = StatisticID(
        rawValue: "stat.codex.share.unique-message"
    )!
    let relationshipStatistic = StatisticID(
        rawValue: "stat.relationship.bidirectional.unique"
    )!
    let incomingStatistic = StatisticID(
        rawValue: "stat.message.incoming-decoded.unique"
    )!
    let buckets = [
        CodexID(rawValue: "codex.norse")!,
        CodexID(rawValue: "codex.moonleaf")!,
        CodexID(rawValue: "codex.sunspire")!,
    ]

    for testedBucket in buckets {
        var counters = [
            ProgressionRuleFacts.counterKey(relationshipStatistic, nil): UInt64(5),
            ProgressionRuleFacts.counterKey(incomingStatistic, nil): UInt64(25),
        ]
        for bucket in buckets {
            counters[ProgressionRuleFacts.counterKey(shareStatistic, bucket)] = 5
        }
        counters[ProgressionRuleFacts.counterKey(shareStatistic, testedBucket)] = 4
        let oneBelow = ProgressionRuleFacts(
            counters: counters,
            distinctValues: [:],
            ownedContentIDs: [
                ProgressionContentID(rawValue: "codex.wildwood")!,
            ],
            completedAchievementIDs: [
                AchievementID(rawValue: "achievement.master-scribe")!,
            ]
        )
        #expect(
            !ProgressionRuleEvaluator.evaluate(
                gloamthorn.rule,
                facts: oneBelow
            ).isSatisfied,
            Comment(rawValue: "Gloamthorn accepted 4/5 in \(testedBucket.rawValue)")
        )

        counters[ProgressionRuleFacts.counterKey(shareStatistic, testedBucket)] = 5
        let exact = ProgressionRuleFacts(
            counters: counters,
            distinctValues: [:],
            ownedContentIDs: oneBelow.ownedContentIDs,
            completedAchievementIDs: oneBelow.completedAchievementIDs
        )
        #expect(
            ProgressionRuleEvaluator.evaluate(
                gloamthorn.rule,
                facts: exact
            ).isSatisfied,
            Comment(rawValue: "Gloamthorn rejected 5/5 in \(testedBucket.rawValue)")
        )
    }
}

@Test
func collectorRewardDoesNotCompleteCollectorFromNineteenArtifacts() throws {
    let bundle = try approvedCatalogBundle()
    let collectorID = AchievementID(rawValue: "achievement.collector")!
    let collectorRewardID = ProgressionContentID(
        rawValue: "relic.progression.collector"
    )!
    let occurredAt = Date(timeIntervalSince1970: 2_000_008_000)
    var projection = try ProgressionReducer.initialProjection(bundle: bundle)
    let initiallyOwnedArtifacts: [ProgressionContentID] = projection.records(
        matching: { record -> ProgressionContentID? in
        guard case let .ownership(ownership) = record,
              bundle.catalog.content(id: ownership.contentID)?.countsAsArtifact == true
        else { return nil }
        return ownership.contentID
    })
    var desiredArtifacts = Set(initiallyOwnedArtifacts)
    for content in bundle.catalog.content where
        content.countsAsArtifact
        && content.contentID != collectorRewardID
        && desiredArtifacts.count < 19
    {
        desiredArtifacts.insert(content.contentID)
    }
    #expect(desiredArtifacts.count == 19)

    for contentID in desiredArtifacts {
        guard projection.records["ownership|\(contentID.rawValue)"] == nil else {
            continue
        }
        try projection.upsert(.ownership(OwnershipRecord(
            generation: projection.metadata.activeGeneration,
            contentID: contentID,
            sourceGrantKeys: [
                "grant|test.collector-seed|\(contentID.rawValue)|achievement.test-seed",
            ],
            grantedAt: occurredAt.addingTimeInterval(-1)
        )))
    }
    let envelope = try DomainEventEnvelope(
        schemaVersion: 1,
        eventID: EventID(
            rawValue: UUID(uuidString: "93000000-0000-0000-0000-000000000001")!
        ),
        correlationID: CorrelationID(
            rawValue: UUID(uuidString: "93000000-0000-0000-0000-000000000002")!
        ),
        eventType: EventIdentifier(rawValue: "runescribe.message.imported"),
        sourceModuleID: RuneScribeModuleIDs.core,
        occurredAt: occurredAt,
        eligibility: DomainEventEligibilityMetadata(
            state: .eligible,
            reason: EligibilityReasonID(
                rawValue: "eligibility.eligible.domain-commit"
            )!
        ),
        payload: DomainEventPayload(
            packageToken: PackageToken(
                rawValue: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            ),
            origin: .imported,
            routeClass: .clipboard,
            codexIDs: [CodexID(rawValue: "codex.norse")!],
            embeddedCipher: false
        )
    )
    guard case let .accepted(validated) = ProgressionEventValidator.validate(
        envelope,
        bundle: bundle
    ) else {
        Issue.record("The Collector transaction fixture event did not validate.")
        return
    }
    let state = ProgressionRepositoryState(
        projection: projection,
        nextPendingReveal: nil,
        inactiveShards: [:],
        health: ModuleStateHealthSnapshot(
            namespace: ModuleStateNamespace(moduleID: RuneScribeModuleIDs.progression),
            loadState: .loaded,
            storeRevision: 1,
            namespaceSchemaVersion: ProgressionRepository.namespaceSchemaVersion,
            recordCount: UInt64(projection.records.count + 1),
            capturedAt: occurredAt
        )
    )
    let reduced = try ProgressionReducer.apply(
        validated,
        to: state,
        existingLifetimeTokens: [],
        queueTail: nil,
        suppressReveal: true,
        bundle: bundle
    )

    #expect(
        reduced.projection.records[
            "achievement-completion|\(collectorID.rawValue)"
        ] == nil
    )
    #expect(
        reduced.projection.records[
            "ownership|\(collectorRewardID.rawValue)"
        ] == nil
    )
    let artifactRecord: ProgressionLogicalRecord? = reduced.projection.records[
        "counter|stat.ownership.artifact-count|-"
    ]
    guard case let .statisticCounter(artifactCount)? = artifactRecord else {
        Issue.record("The Collector transaction did not recompute artifact ownership.")
        return
    }
    #expect(artifactCount.value == 19)
}

private typealias ApprovedRuleCase = (String, toRule: ProgressionRule)

private struct ApprovedFactAccumulator: Equatable {
    var counters: [String: UInt64] = [:]
    var distinctValues: [String: Set<String>] = [:]
    var ownedContentIDs: Set<ProgressionContentID> = []
    var completedAchievementIDs: Set<AchievementID> = []

    var facts: ProgressionRuleFacts {
        ProgressionRuleFacts(
            counters: counters,
            distinctValues: distinctValues,
            ownedContentIDs: ownedContentIDs,
            completedAchievementIDs: completedAchievementIDs
        )
    }

    mutating func satisfy(
        _ rule: ProgressionRule,
        achievementUniverse: [AchievementID],
        codexUniverse: [CodexID]
    ) {
        switch rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            counters[ProgressionRuleFacts.counterKey(statisticID, bucketID)] =
                UInt64(threshold)
        case let .contentOwned(contentID):
            ownedContentIDs.insert(contentID)
        case let .achievementCompleted(achievementID):
            completedAchievementIDs.insert(achievementID)
        case let .completedAchievementCountAtLeast(threshold, excluding):
            for achievementID in achievementUniverse where
                !excluding.contains(achievementID)
                && completedAchievementIDs.count < Int(threshold)
            {
                completedAchievementIDs.insert(achievementID)
            }
        case let .all(conditions):
            for condition in conditions {
                satisfy(
                    condition,
                    achievementUniverse: achievementUniverse,
                    codexUniverse: codexUniverse
                )
            }
        case let .any(conditions):
            if let first = conditions.first {
                satisfy(
                    first,
                    achievementUniverse: achievementUniverse,
                    codexUniverse: codexUniverse
                )
            }
        case let .bucketCountAtLeast(statisticID, minimumBuckets, minimumValue):
            for codexID in codexUniverse.prefix(Int(minimumBuckets)) {
                counters[ProgressionRuleFacts.counterKey(statisticID, codexID)] =
                    UInt64(minimumValue)
            }
        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            distinctValues[ProgressionRuleFacts.counterKey(statisticID, bucketID)] =
                Set(contentIDs.map(\.rawValue))
        }
    }

    mutating func satisfyAbove(
        _ rule: ProgressionRule,
        achievementUniverse: [AchievementID],
        codexUniverse: [CodexID]
    ) {
        satisfy(
            rule,
            achievementUniverse: achievementUniverse,
            codexUniverse: codexUniverse
        )
        switch rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            counters[ProgressionRuleFacts.counterKey(statisticID, bucketID)] =
                UInt64(threshold) + 1
        case .contentOwned:
            ownedContentIDs.insert(ProgressionContentID(rawValue: "content.unrelated")!)
        case .achievementCompleted:
            completedAchievementIDs.insert(
                AchievementID(rawValue: "achievement.unrelated")!
            )
        case let .completedAchievementCountAtLeast(threshold, excluding):
            for achievementID in achievementUniverse where
                !excluding.contains(achievementID)
                && completedAchievementIDs.count <= Int(threshold)
            {
                completedAchievementIDs.insert(achievementID)
            }
        case let .all(conditions):
            for condition in conditions {
                satisfyAbove(
                    condition,
                    achievementUniverse: achievementUniverse,
                    codexUniverse: codexUniverse
                )
            }
        case let .any(conditions):
            for condition in conditions {
                satisfy(
                    condition,
                    achievementUniverse: achievementUniverse,
                    codexUniverse: codexUniverse
                )
            }
        case let .bucketCountAtLeast(statisticID, minimumBuckets, minimumValue):
            for codexID in codexUniverse.prefix(Int(minimumBuckets)) {
                counters[ProgressionRuleFacts.counterKey(statisticID, codexID)] =
                    UInt64(minimumValue) + 1
            }
        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            var values = Set(contentIDs.map(\.rawValue))
            values.insert("content.unrelated")
            distinctValues[ProgressionRuleFacts.counterKey(statisticID, bucketID)] = values
        }
    }

    mutating func satisfyOneBelow(
        _ rule: ProgressionRule,
        achievementUniverse: [AchievementID],
        codexUniverse: [CodexID]
    ) {
        switch rule {
        case let .distinctCountAtLeast(statisticID, threshold, bucketID):
            counters[ProgressionRuleFacts.counterKey(statisticID, bucketID)] =
                UInt64(threshold - 1)
        case .contentOwned, .achievementCompleted:
            break
        case let .completedAchievementCountAtLeast(threshold, excluding):
            for achievementID in achievementUniverse where
                !excluding.contains(achievementID)
                && completedAchievementIDs.count < Int(threshold - 1)
            {
                completedAchievementIDs.insert(achievementID)
            }
        case let .all(conditions):
            guard let first = conditions.first else { return }
            for condition in conditions.dropFirst() {
                satisfy(
                    condition,
                    achievementUniverse: achievementUniverse,
                    codexUniverse: codexUniverse
                )
            }
            satisfyOneBelow(
                first,
                achievementUniverse: achievementUniverse,
                codexUniverse: codexUniverse
            )
        case .any:
            break
        case let .bucketCountAtLeast(statisticID, minimumBuckets, minimumValue):
            for codexID in codexUniverse.prefix(Int(minimumBuckets)) {
                counters[ProgressionRuleFacts.counterKey(statisticID, codexID)] =
                    UInt64(minimumValue)
            }
            if let last = codexUniverse.prefix(Int(minimumBuckets)).last {
                counters[ProgressionRuleFacts.counterKey(statisticID, last)] =
                    UInt64(minimumValue - 1)
            }
        case let .allListedContentUsed(statisticID, bucketID, contentIDs):
            distinctValues[ProgressionRuleFacts.counterKey(statisticID, bucketID)] =
                Set(contentIDs.dropLast().map(\.rawValue))
        }
    }
}

private let approvedMilestoneGrantMappings = [
    "rule.codex.moonleaf.known-in-five-circles|grant-group.codex.moonleaf.unlock",
    "rule.codex.sunspire.reciprocal-light|grant-group.codex.sunspire.unlock",
    "rule.codex.wildwood.roots-of-memory|grant-group.codex.wildwood.unlock",
    "rule.codex.gloamthorn.beyond-the-gloam|grant-group.codex.gloamthorn.unlock",
    "rule.codex.moonleaf.first-share|grant-group.codex.moonleaf.first-share",
    "rule.codex.moonleaf.three-shares|grant-group.codex.moonleaf.three-shares",
    "rule.codex.moonleaf.incoming-five|grant-group.codex.moonleaf.incoming-five",
    "rule.codex.moonleaf.ten-shares|grant-group.codex.moonleaf.ten-shares",
    "rule.codex.moonleaf.encounter|grant-group.codex.moonleaf.encounter",
    "rule.codex.moonleaf.mastery|grant-group.codex.moonleaf.mastery",
    "rule.codex.sunspire.first-share|grant-group.codex.sunspire.first-share",
    "rule.codex.sunspire.three-shares|grant-group.codex.sunspire.three-shares",
    "rule.codex.sunspire.incoming-five|grant-group.codex.sunspire.incoming-five",
    "rule.codex.sunspire.ten-shares|grant-group.codex.sunspire.ten-shares",
    "rule.codex.sunspire.encounter|grant-group.codex.sunspire.encounter",
    "rule.codex.sunspire.mastery|grant-group.codex.sunspire.mastery",
    "rule.codex.wildwood.first-share|grant-group.codex.wildwood.first-share",
    "rule.codex.wildwood.three-shares|grant-group.codex.wildwood.three-shares",
    "rule.codex.wildwood.incoming-five|grant-group.codex.wildwood.incoming-five",
    "rule.codex.wildwood.ten-shares|grant-group.codex.wildwood.ten-shares",
    "rule.codex.wildwood.encounter|grant-group.codex.wildwood.encounter",
    "rule.codex.wildwood.mastery|grant-group.codex.wildwood.mastery",
    "rule.codex.gloamthorn.first-share|grant-group.codex.gloamthorn.first-share",
    "rule.codex.gloamthorn.three-shares|grant-group.codex.gloamthorn.three-shares",
    "rule.codex.gloamthorn.incoming-five|grant-group.codex.gloamthorn.incoming-five",
    "rule.codex.gloamthorn.ten-shares|grant-group.codex.gloamthorn.ten-shares",
    "rule.codex.gloamthorn.encounter|grant-group.codex.gloamthorn.encounter",
    "rule.codex.gloamthorn.mastery|grant-group.codex.gloamthorn.mastery",
    "rule.codex.norse.echo-five|grant-group.codex.norse.echo-five",
    "rule.codex.norse.mastery|grant-group.codex.norse.mastery",
]

private let approvedGrantGroupDefinitions = """
grant-group.base.norse.included|none|codex.norse|unlock.codex.norse,codex.norse,script.base-runes,relic.norse.runestone-tablet,seal.norse.valknut,seal.norse.ravenshield
grant-group.first-inscription|micro|seal.norse.mjolnir|seal.norse.mjolnir
grant-group.first-dispatch|artifact|relic.norse.dragonwood-plaque|relic.norse.dragonwood-plaque
grant-group.echo-returns|micro|title.listener|title.listener
grant-group.correspondent|micro|seal.norse.wolkin|seal.norse.wolkin
grant-group.courier-1|micro|seal.norse.yggdrasil|seal.norse.yggdrasil
grant-group.courier-2|artifact|relic.norse.stormforged-stele|relic.norse.stormforged-stele
grant-group.archivist-1|artifact|frame.norse.carved-knotwork|frame.norse.carved-knotwork
grant-group.archivist-2|artifact|title.archivist|title.archivist,seal.norse.berserk
grant-group.relic-bearer|micro|seal.progression.relic-bearer|seal.progression.relic-bearer
grant-group.seal-keeper|artifact|frame.progression.collector|frame.progression.collector
grant-group.many-worlds|micro|title.wayfarer|title.wayfarer
grant-group.explorer|micro|seal.progression.echo|seal.progression.echo
grant-group.collector|artifact|relic.progression.collector|relic.progression.collector
grant-group.master-scribe|artifact|title.master-scribe|title.master-scribe,frame.progression.mastery
grant-group.codex.moonleaf.unlock|codex|codex.moonleaf|unlock.codex.moonleaf,codex.moonleaf,script.moonleaf,relic.moonleaf.tablet,seal.moonleaf.crescentleaf,seal.moonleaf.woodland-stag
grant-group.codex.sunspire.unlock|codex|codex.sunspire|unlock.codex.sunspire,codex.sunspire,script.sunspire,relic.sunspire.dawnfire-tablet,seal.sunspire.sunleaf-crest,seal.sunspire.golden-lark
grant-group.codex.wildwood.unlock|codex|codex.wildwood|unlock.codex.wildwood,codex.wildwood,script.wildwood,relic.wildwood.rootsong-tablet,seal.wildwood.rooted-tree,seal.wildwood.lantern-moth
grant-group.codex.gloamthorn.unlock|codex|codex.gloamthorn|unlock.codex.gloamthorn,codex.gloamthorn,script.gloamthorn,relic.gloamthorn.nightthorn-tablet,seal.gloamthorn.thornmoon,seal.gloamthorn.nightglass-moth
grant-group.codex.moonleaf.first-share|micro|seal.moonleaf.night-owl|seal.moonleaf.night-owl
grant-group.codex.moonleaf.three-shares|artifact|relic.moonleaf.ivybound-plaque|relic.moonleaf.ivybound-plaque
grant-group.codex.moonleaf.incoming-five|micro|seal.moonleaf.moonwell|seal.moonleaf.moonwell
grant-group.codex.moonleaf.ten-shares|artifact|relic.moonleaf.whisperbark-stele|relic.moonleaf.whisperbark-stele,seal.moonleaf.starflower
grant-group.codex.moonleaf.encounter|micro|seal.moonleaf.echo-firefly|seal.moonleaf.echo-firefly
grant-group.codex.moonleaf.mastery|mastery|crest.moonleaf.moonbloom|frame.moonleaf.silvervine,crest.moonleaf.moonbloom
grant-group.codex.sunspire.first-share|micro|seal.sunspire.dawnflower|seal.sunspire.dawnflower
grant-group.codex.sunspire.three-shares|artifact|relic.sunspire.solvine-plaque|relic.sunspire.solvine-plaque
grant-group.codex.sunspire.incoming-five|micro|seal.sunspire.sunwheel|seal.sunspire.sunwheel
grant-group.codex.sunspire.ten-shares|artifact|relic.sunspire.auric-stele|relic.sunspire.auric-stele,seal.sunspire.radiant-spire
grant-group.codex.sunspire.encounter|micro|seal.sunspire.echo-ember|seal.sunspire.echo-ember
grant-group.codex.sunspire.mastery|mastery|crest.sunspire.first-light|frame.sunspire.laurel-of-dawn,crest.sunspire.first-light
grant-group.codex.wildwood.first-share|micro|seal.wildwood.acorn-knot|seal.wildwood.acorn-knot
grant-group.codex.wildwood.three-shares|artifact|relic.wildwood.mossbound-plaque|relic.wildwood.mossbound-plaque
grant-group.codex.wildwood.incoming-five|micro|seal.wildwood.fern-spiral|seal.wildwood.fern-spiral
grant-group.codex.wildwood.ten-shares|artifact|relic.wildwood.elderbark-stele|relic.wildwood.elderbark-stele,seal.wildwood.wild-fox
grant-group.codex.wildwood.encounter|micro|seal.wildwood.echo-seed|seal.wildwood.echo-seed
grant-group.codex.wildwood.mastery|mastery|crest.wildwood.heartwood-crown|frame.wildwood.living-root,crest.wildwood.heartwood-crown
grant-group.codex.gloamthorn.first-share|micro|seal.gloamthorn.eclipse-bloom|seal.gloamthorn.eclipse-bloom
grant-group.codex.gloamthorn.three-shares|artifact|relic.gloamthorn.umbral-plaque|relic.gloamthorn.umbral-plaque
grant-group.codex.gloamthorn.incoming-five|micro|seal.gloamthorn.veiled-serpent|seal.gloamthorn.veiled-serpent
grant-group.codex.gloamthorn.ten-shares|artifact|relic.gloamthorn.duskbriar-stele|relic.gloamthorn.duskbriar-stele,seal.gloamthorn.pact-crown
grant-group.codex.gloamthorn.encounter|micro|seal.gloamthorn.echo-wisp|seal.gloamthorn.echo-wisp
grant-group.codex.gloamthorn.mastery|mastery|crest.gloamthorn.gloam-sovereign|frame.gloamthorn.briar-court,crest.gloamthorn.gloam-sovereign
grant-group.codex.norse.echo-five|micro|seal.norse.yggdrasil|seal.norse.yggdrasil
grant-group.codex.norse.mastery|mastery|crest.norse.raven-mastery|crest.norse.raven-mastery,title.norse.master-of-runes
""".split(separator: "\n").map(String.init)

private func approvedCatalogBundle() throws -> ValidatedProgressionCatalogBundle {
    try ProgressionCatalogDecoder.decodeAndValidateBundle(
        catalogData: approvedResourceData(
            ProgressionCatalogResourceCatalog.catalogDescriptor
        ),
        eventCatalogData: approvedResourceData(
            ProgressionCatalogResourceCatalog.eventCatalogDescriptor
        ),
        futureThemeBindingData: approvedResourceData(
            ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
        ),
        integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
    )
}

private func approvedResourceData(
    _ descriptor: ProgressionCatalogResourceDescriptor
) throws -> Data {
    let resource = descriptor.resource
    let url = try #require(RuneScribeProgressionModuleBootstrap.resourceBundle.url(
        forResource: resource.name,
        withExtension: resource.fileExtension,
        subdirectory: resource.subdirectory
    ))
    return try Data(contentsOf: url)
}
