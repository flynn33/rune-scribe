import Foundation
import RuneScribeContracts
import Testing
@testable import RuneScribeProgressionModule

@Test
func rejectsUnknownRootAndNestedFields() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let rootMutation = try mutate(catalogData) { root in
        root["unexpected"] = true
    }
    #expect(validationFailure { _ = try ProgressionCatalogDecoder.decodeCatalog(rootMutation) })

    let nestedMutation = try mutate(catalogData) { root in
        var content = root["content"] as! [[String: Any]]
        content[0]["providerURL"] = "file:///forbidden"
        root["content"] = content
    }
    #expect(validationFailure { _ = try ProgressionCatalogDecoder.decodeCatalog(nestedMutation) })
}

@Test
func rejectsUnknownOperatorAndInvalidThresholds() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let unknownOperator = try mutate(catalogData) { root in
        var achievements = root["achievements"] as! [[String: Any]]
        var rule = achievements[0]["rule"] as! [String: Any]
        rule["op"] = "awardEverything"
        achievements[0]["rule"] = rule
        root["achievements"] = achievements
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(unknownOperator)
    })

    for invalidThreshold in [0, 1_000_001] {
        let mutation = try mutate(catalogData) { root in
            var achievements = root["achievements"] as! [[String: Any]]
            var rule = achievements[0]["rule"] as! [String: Any]
            rule["threshold"] = invalidThreshold
            achievements[0]["rule"] = rule
            root["achievements"] = achievements
        }
        #expect(validationFailure {
            _ = try ProgressionCatalogDecoder.decodeCatalog(mutation)
        })
    }
}

@Test
func rejectsUnknownMissingAddedAndSwappedStatisticFilters() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )

    let unknown = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let index = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.share.relic-used.unique"
        }!
        statistics[index]["filter"] = "owned artifact IDs only"
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(unknown)
    })

    let missing = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let index = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.share.relic-used.unique"
        }!
        statistics[index].removeValue(forKey: "filter")
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(missing)
    })

    let added = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let index = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.message.encoded.unique"
        }!
        statistics[index]["filter"] = "owned relic IDs only"
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(added)
    })

    let swapped = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let index = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.share.relic-used.unique"
        }!
        statistics[index]["filter"] = "owned seal IDs only"
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(swapped)
    })
}

@Test
func rejectsUnsupportedStatisticDimensionsAndUnreachableBuckets() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let eventData = try fixtureData(
        ProgressionCatalogResourceCatalog.eventCatalogDescriptor
    )
    let bindingData = try fixtureData(
        ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
    )

    let unavailableDimension = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let index = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.cipher.created-or-imported.unique"
        }!
        statistics[index]["dimension"] = "messageToken"
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeAndValidateBundle(
            catalogData: unavailableDimension,
            eventCatalogData: eventData,
            futureThemeBindingData: bindingData,
            integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
        )
    })

    let unknownBucket = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.moonleaf.first-share"
        }!
        var rule = milestones[index]["rule"] as! [String: Any]
        var conditions = rule["conditions"] as! [[String: Any]]
        let conditionIndex = conditions.firstIndex {
            $0["op"] as? String == "distinctCountAtLeast"
        }!
        conditions[conditionIndex]["bucketID"] = "codex.unknown"
        rule["conditions"] = conditions
        milestones[index]["rule"] = rule
        root["milestones"] = milestones
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(unknownBucket)
    })

    let unreachableBucketCount = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.gloamthorn.beyond-the-gloam"
        }!
        var rule = milestones[index]["rule"] as! [String: Any]
        var conditions = rule["conditions"] as! [[String: Any]]
        let conditionIndex = conditions.firstIndex {
            $0["op"] as? String == "bucketCountAtLeast"
        }!
        conditions[conditionIndex]["minimumBuckets"] = 6
        rule["conditions"] = conditions
        milestones[index]["rule"] = rule
        root["milestones"] = milestones
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(unreachableBucketCount)
    })

    let selfGatedBucketCount = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.gloamthorn.beyond-the-gloam"
        }!
        var rule = milestones[index]["rule"] as! [String: Any]
        var conditions = rule["conditions"] as! [[String: Any]]
        let conditionIndex = conditions.firstIndex {
            $0["op"] as? String == "bucketCountAtLeast"
        }!
        conditions[conditionIndex]["minimumBuckets"] = 5
        rule["conditions"] = conditions
        milestones[index]["rule"] = rule

        var components = milestones[index]["progressComponents"] as! [[String: Any]]
        let componentIndex = components.firstIndex {
            $0["type"] as? String == "bucket-threshold"
        }!
        components[componentIndex]["minimumBuckets"] = 5
        milestones[index]["progressComponents"] = components
        root["milestones"] = milestones
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(selfGatedBucketCount)
    })
}

@Test
func rejectsDerivedEventStorageAndFilterDimensionMismatches() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let eventData = try fixtureData(
        ProgressionCatalogResourceCatalog.eventCatalogDescriptor
    )
    let bindingData = try fixtureData(
        ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
    )

    let storageSwap = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let externalIndex = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.cipher.created-or-imported.unique"
        }!
        let derivedIndex = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.ownership.artifact-count"
        }!
        statistics[externalIndex]["storage"] = "derived"
        statistics[derivedIndex]["storage"] = "distinct-set"
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeAndValidateBundle(
            catalogData: storageSwap,
            eventCatalogData: eventData,
            futureThemeBindingData: bindingData,
            integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
        )
    })

    let wrongFilterDimension = try mutate(catalogData) { root in
        var statistics = root["statistics"] as! [[String: Any]]
        let index = statistics.firstIndex {
            $0["statisticID"] as? String == "stat.share.relic-used.unique"
        }!
        statistics[index]["dimension"] = "messageToken"
        root["statistics"] = statistics
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeAndValidateBundle(
            catalogData: wrongFilterDimension,
            eventCatalogData: eventData,
            futureThemeBindingData: bindingData,
            integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
        )
    })
}

@Test
func rejectsFiniteDomainThresholdsAndUngrantableRuleContent() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )

    let codexThreshold = try mutate(catalogData) { root in
        var achievements = root["achievements"] as! [[String: Any]]
        let index = achievements.firstIndex {
            $0["achievementID"] as? String == "achievement.many-worlds"
        }!
        var rule = achievements[index]["rule"] as! [String: Any]
        rule["threshold"] = 6
        achievements[index]["rule"] = rule
        var progress = achievements[index]["progress"] as! [String: Any]
        progress["target"] = 6
        achievements[index]["progress"] = progress
        root["achievements"] = achievements
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(codexThreshold)
    })

    let excludedAchievementThreshold = try mutate(catalogData) { root in
        var achievements = root["achievements"] as! [[String: Any]]
        let index = achievements.firstIndex {
            $0["achievementID"] as? String == "achievement.master-scribe"
        }!
        var rule = achievements[index]["rule"] as! [String: Any]
        rule["threshold"] = 15
        achievements[index]["rule"] = rule
        var progress = achievements[index]["progress"] as! [String: Any]
        progress["target"] = 15
        achievements[index]["progress"] = progress
        root["achievements"] = achievements
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(excludedAchievementThreshold)
    })

    let frozenMastery = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.norse.mastery"
        }!
        var rule = milestones[index]["rule"] as! [String: Any]
        var conditions = rule["conditions"] as! [[String: Any]]
        let conditionIndex = conditions.firstIndex {
            $0["op"] as? String == "allListedContentUsed"
        }!
        var ruleContent = conditions[conditionIndex]["contentIDs"] as! [String]
        ruleContent[0] = "relic.norse.runestone.frozen"
        conditions[conditionIndex]["contentIDs"] = ruleContent
        rule["conditions"] = conditions
        milestones[index]["rule"] = rule

        var components = milestones[index]["progressComponents"] as! [[String: Any]]
        let componentIndex = components.firstIndex {
            $0["type"] as? String == "all-content-used"
        }!
        var componentContent = components[componentIndex]["contentIDs"] as! [String]
        componentContent[0] = "relic.norse.runestone.frozen"
        components[componentIndex]["contentIDs"] = componentContent
        milestones[index]["progressComponents"] = components
        root["milestones"] = milestones
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(frozenMastery)
    })
}

@Test
func rejectsImpossibleOwnedDomainsAndMisclassifiedIncludedContent() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )

    let ungrantableRelicThreshold = try mutate(catalogData) { root in
        var achievements = root["achievements"] as! [[String: Any]]
        let index = achievements.firstIndex {
            $0["achievementID"] as? String == "achievement.relic-bearer"
        }!
        var rule = achievements[index]["rule"] as! [String: Any]
        rule["threshold"] = 19
        achievements[index]["rule"] = rule
        var progress = achievements[index]["progress"] as! [String: Any]
        progress["target"] = 19
        achievements[index]["progress"] = progress
        root["achievements"] = achievements
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(ungrantableRelicThreshold)
    })

    let initiallyOwnedEncounterThreshold = try mutate(catalogData) { root in
        var achievements = root["achievements"] as! [[String: Any]]
        let index = achievements.firstIndex {
            $0["achievementID"] as? String == "achievement.explorer"
        }!
        var rule = achievements[index]["rule"] as! [String: Any]
        rule["threshold"] = 5
        achievements[index]["rule"] = rule
        var progress = achievements[index]["progress"] as! [String: Any]
        progress["target"] = 5
        achievements[index]["progress"] = progress
        root["achievements"] = achievements
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(initiallyOwnedEncounterThreshold)
    })

    let includedOutsideStartingGrant = try mutate(catalogData) { root in
        var content = root["content"] as! [[String: Any]]
        let echoIndex = content.firstIndex {
            $0["contentID"] as? String == "seal.progression.echo"
        }!
        let knotworkIndex = content.firstIndex {
            $0["contentID"] as? String == "seal.norse.knotwork"
        }!
        content[echoIndex]["availability"] = "included"
        content[knotworkIndex]["availability"] = "permanent"
        root["content"] = content
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(includedOutsideStartingGrant)
    })
}

@Test
func rejectsRewardEffectSelfDeadlock() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let mutation = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.moonleaf.first-share"
        }!
        var rule = milestones[index]["rule"] as! [String: Any]
        var conditions = rule["conditions"] as! [[String: Any]]
        let conditionIndex = conditions.firstIndex {
            $0["op"] as? String == "contentOwned"
        }!
        conditions[conditionIndex]["contentID"] = "seal.moonleaf.night-owl"
        rule["conditions"] = conditions
        milestones[index]["rule"] = rule
        root["milestones"] = milestones
    }
    let error = capturedValidationError {
        _ = try ProgressionCatalogDecoder.decodeCatalog(mutation)
    }
    guard case .dependencyCycle = error else {
        Issue.record("Expected reward-effect self-deadlock rejection.")
        return
    }

    let twoNodeCycle = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let mutations = [
            ("rule.codex.moonleaf.first-share", "seal.moonleaf.moonwell"),
            ("rule.codex.moonleaf.incoming-five", "seal.moonleaf.night-owl"),
        ]
        for (ruleID, requiredContentID) in mutations {
            let index = milestones.firstIndex { $0["ruleID"] as? String == ruleID }!
            var rule = milestones[index]["rule"] as! [String: Any]
            var conditions = rule["conditions"] as! [[String: Any]]
            let conditionIndex = conditions.firstIndex {
                $0["op"] as? String == "contentOwned"
            }!
            conditions[conditionIndex]["contentID"] = requiredContentID
            rule["conditions"] = conditions
            milestones[index]["rule"] = rule
        }
        root["milestones"] = milestones
    }
    let cycleError = capturedValidationError {
        _ = try ProgressionCatalogDecoder.decodeCatalog(twoNodeCycle)
    }
    guard case .dependencyCycle = cycleError else {
        Issue.record("Expected mandatory two-node reward cycle rejection.")
        return
    }
}

@Test
func rejectsDuplicateIdentifiersAndUnknownGrantReferences() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let duplicateContent = try mutate(catalogData) { root in
        var content = root["content"] as! [[String: Any]]
        content[1]["contentID"] = content[0]["contentID"]
        root["content"] = content
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(duplicateContent)
    })

    let unknownGrant = try mutate(catalogData) { root in
        var groups = root["grantGroups"] as! [[String: Any]]
        var items = groups[1]["items"] as! [[String: Any]]
        items[0]["contentID"] = "seal.unknown.not-cataloged"
        groups[1]["items"] = items
        groups[1]["primaryContentID"] = "seal.unknown.not-cataloged"
        root["grantGroups"] = groups
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(unknownGrant)
    })
}

@Test
func frozenRuneStoneCannotReceiveAVersionOneGrant() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let mutation = try mutate(catalogData) { root in
        var groups = root["grantGroups"] as! [[String: Any]]
        var items = groups[0]["items"] as! [[String: Any]]
        items.append([
            "contentID": "relic.norse.runestone.frozen",
            "grantKind": "permanent",
        ])
        groups[0]["items"] = items
        root["grantGroups"] = groups
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(mutation)
    })
}

@Test
func rejectsRevealShapeAndVocabularyMutations() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let durationMutation = try mutate(catalogData) { root in
        var policy = root["revealPolicy"] as! [String: Any]
        var tiers = policy["tiers"] as! [[String: Any]]
        tiers[0]["durationSeconds"] = [0.9, 0.6]
        policy["tiers"] = tiers
        root["revealPolicy"] = policy
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(durationMutation)
    })

    let duplicateSetting = try mutate(catalogData) { root in
        var policy = root["revealPolicy"] as! [String: Any]
        var settings = policy["settings"] as! [[String: Any]]
        settings[1]["settingID"] = settings[0]["settingID"]
        policy["settings"] = settings
        root["revealPolicy"] = policy
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(duplicateSetting)
    })
}

@Test
func rejectsWrongCodexBucketAndForeignRelicInAllContentRules() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let wrongBucket = try mutate(catalogData) { root in
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.norse.mastery"
        }!
        var rule = milestones[index]["rule"] as! [String: Any]
        var conditions = rule["conditions"] as! [[String: Any]]
        let listedIndex = conditions.firstIndex {
            $0["op"] as? String == "allListedContentUsed"
        }!
        conditions[listedIndex]["bucketID"] = "codex.moonleaf"
        rule["conditions"] = conditions
        milestones[index]["rule"] = rule
        root["milestones"] = milestones
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(wrongBucket)
    })

    let foreignRelic = try mutate(catalogData) { root in
        let content = root["content"] as! [[String: Any]]
        let moonleafRelic = content.first {
            $0["kind"] as? String == "relic"
                && $0["codexID"] as? String == "codex.moonleaf"
        }!["contentID"] as! String
        var milestones = root["milestones"] as! [[String: Any]]
        let index = milestones.firstIndex {
            $0["ruleID"] as? String == "rule.codex.norse.mastery"
        }!
        var components = milestones[index]["progressComponents"] as! [[String: Any]]
        let listedIndex = components.firstIndex {
            $0["type"] as? String == "all-content-used"
        }!
        var contentIDs = components[listedIndex]["contentIDs"] as! [String]
        contentIDs[0] = moonleafRelic
        components[listedIndex]["contentIDs"] = contentIDs
        milestones[index]["progressComponents"] = components
        root["milestones"] = milestones
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeCatalog(foreignRelic)
    })
}

@Test
func rejectsDirectRuleCyclesWithoutRejectingApprovedRewardFixpoint() throws {
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let directCycle = try mutate(catalogData) { root in
        var achievements = root["achievements"] as! [[String: Any]]
        let index = achievements.firstIndex {
            $0["achievementID"] as? String == "achievement.master-scribe"
        }!
        achievements[index]["rule"] = [
            "op": "achievementCompleted",
            "achievementID": "achievement.master-scribe",
        ]
        root["achievements"] = achievements
    }
    let error = capturedValidationError {
        _ = try ProgressionCatalogDecoder.decodeCatalog(directCycle)
    }
    guard case .dependencyCycle = error else {
        Issue.record("Expected a direct dependency-cycle rejection.")
        return
    }

    let bundle = try fixtureBundle()
    let approved = bundle.dependencyAnalysis.rewardEffectStronglyConnectedComponents
    #expect(approved == [[
        "achievement.collector",
        "achievement.master-scribe",
        "rule.codex.gloamthorn.beyond-the-gloam",
        "rule.codex.gloamthorn.first-share",
        "rule.codex.gloamthorn.incoming-five",
        "rule.codex.gloamthorn.mastery",
        "rule.codex.gloamthorn.ten-shares",
        "rule.codex.gloamthorn.three-shares",
    ]])
}

@Test
func rejectsEventShapeAndNestedUnknownFieldMutations() throws {
    let eventData = try fixtureData(
        ProgressionCatalogResourceCatalog.eventCatalogDescriptor
    )
    let missingRequired = try mutate(eventData) { root in
        var events = root["events"] as! [[String: Any]]
        var required = events[0]["requiredPayload"] as! [String]
        required.removeLast()
        events[0]["requiredPayload"] = required
        root["events"] = events
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeEventCatalog(missingRequired)
    })

    let unknownNested = try mutate(eventData) { root in
        var routes = root["shareRoutePolicy"] as! [[String: Any]]
        routes[0]["recipientIdentity"] = "forbidden"
        root["shareRoutePolicy"] = routes
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeEventCatalog(unknownNested)
    })

    let routeEligibility = try mutate(eventData) { root in
        var routes = root["shareRoutePolicy"] as! [[String: Any]]
        let index = routes.firstIndex {
            $0["routeClass"] as? String == "file-export"
        }!
        routes[index]["progressionEligible"] = true
        root["shareRoutePolicy"] = routes
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeEventCatalog(routeEligibility)
    })

    let missingForbiddenClass = try mutate(eventData) { root in
        var forbidden = root["forbiddenData"] as! [String]
        forbidden.removeLast()
        root["forbiddenData"] = forbidden
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeEventCatalog(missingForbiddenClass)
    })
}

@Test
func rejectsDuplicateAndDanglingFutureThemeBindings() throws {
    let bindingData = try fixtureData(
        ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
    )
    let duplicate = try mutate(bindingData) { root in
        var bindings = root["bindings"] as! [[String: Any]]
        bindings[1]["codexID"] = bindings[0]["codexID"]
        root["bindings"] = bindings
    }
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeFutureThemeBindings(duplicate)
    })

    let dangling = try mutate(bindingData) { root in
        var bindings = root["bindings"] as! [[String: Any]]
        bindings[1]["gateRuleID"] = "rule.codex.unknown.never"
        root["bindings"] = bindings
    }
    let catalogData = try fixtureData(
        ProgressionCatalogResourceCatalog.catalogDescriptor
    )
    let eventData = try fixtureData(
        ProgressionCatalogResourceCatalog.eventCatalogDescriptor
    )
    #expect(validationFailure {
        _ = try ProgressionCatalogDecoder.decodeAndValidateBundle(
            catalogData: catalogData,
            eventCatalogData: eventData,
            futureThemeBindingData: dangling,
            integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
        )
    })
}

@Test
func rejectsDuplicateJSONObjectKeys() throws {
    let duplicate = Data(#"{"schemaVersion":"1.0","schemaVersion":"1.0"}"#.utf8)
    let error = capturedValidationError {
        _ = try ProgressionCatalogDecoder.decodeCatalog(duplicate)
    }
    guard case .duplicateJSONKey = error else {
        Issue.record("Expected duplicate JSON key rejection.")
        return
    }
}

private func fixtureBundle() throws -> ValidatedProgressionCatalogBundle {
    try ProgressionCatalogDecoder.decodeAndValidateBundle(
        catalogData: fixtureData(ProgressionCatalogResourceCatalog.catalogDescriptor),
        eventCatalogData: fixtureData(
            ProgressionCatalogResourceCatalog.eventCatalogDescriptor
        ),
        futureThemeBindingData: fixtureData(
            ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
        ),
        integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
    )
}

private func fixtureData(
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

private func mutate(
    _ data: Data,
    _ mutation: (inout [String: Any]) -> Void
) throws -> Data {
    var root = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    mutation(&root)
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func validationFailure(_ operation: () throws -> Void) -> Bool {
    capturedValidationError(operation) != nil
}

private func capturedValidationError(
    _ operation: () throws -> Void
) -> ProgressionCatalogValidationError? {
    do {
        try operation()
        return nil
    } catch let error as ProgressionCatalogValidationError {
        return error
    } catch {
        Issue.record("Expected ProgressionCatalogValidationError, received \(error).")
        return nil
    }
}
