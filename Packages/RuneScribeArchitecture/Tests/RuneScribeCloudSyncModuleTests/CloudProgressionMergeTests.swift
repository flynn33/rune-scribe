import Foundation
import RuneScribeContracts
import RuneScribeProgressionSyncDomain
import Testing
@testable import RuneScribeProgressionSyncDomain

@Test
func twoDeviceMergeIsCommutativeIdempotentAndPreservesDomainRules() throws {
    let first = try replica(
        device: opaque("a"),
        completionDate: date(200),
        counter: 4,
        selectedCodex: "codex.moonleaf",
        selectionClock: 2,
        pendingPercentage: 40,
        encounterFirst: date(150),
        encounterLast: date(200),
        content: "relic.moonleaf.tablet"
    )
    let second = try replica(
        device: opaque("b"),
        completionDate: date(100),
        counter: 7,
        selectedCodex: "codex.gloamthorn",
        selectionClock: 3,
        pendingPercentage: 70,
        encounterFirst: date(125),
        encounterLast: date(250),
        content: "relic.sunspire.tablet"
    )
    let context = try mergeContext()

    let forward = try CloudProgressionMergeEngine.mergeValidated(
        local: first,
        remote: second,
        context: context
    )
    let reverse = try CloudProgressionMergeEngine.mergeValidated(
        local: second,
        remote: first,
        context: context
    )
    let replay = try CloudProgressionMergeEngine.mergeValidated(
        local: forward,
        remote: second,
        context: context
    )

    #expect(forward == reverse)
    #expect(replay == forward)
    #expect(forward.achievementCompletions.single?.firstCompletedAt == date(100))
    #expect(forward.grants.count == 3)
    #expect(forward.grants.first {
        $0.grantID.rawValue == "transaction.shared-achievement-grant"
    }?.firstGrantedAt == date(100))
    #expect(forward.ownedContentIDs.map(\.rawValue) == [
        "relic.moonleaf.tablet", "relic.sunspire.tablet",
    ])
    #expect(forward.deviceCounterShards.map(\.value).sorted() == [4, 7])
    #expect(forward.encounters.single?.firstEncounteredAt == date(125))
    #expect(forward.encounters.single?.lastEncounteredAt == date(250))
    #expect(forward.pendingGameCenterReports.single?.percentage == 70)
    #expect(forward.selectedCodex?.codexID.rawValue == "codex.moonleaf")

    let outcome = try CloudProgressionMergeEngine.merge(
        local: first,
        remoteData: CloudProgressionCodec.encode(second),
        context: context
    )
    #expect(outcome.status == .merged)
    #expect(outcome.effectiveCodexID.rawValue == "codex.moonleaf")
}

@Test
func oneGrantTransactionCanContainAndMergeMultipleContentItems() throws {
    let transaction = GrantTransactionID(rawValue: "transaction.multi-item-grant")!
    let seal = content("seal.norse.raven")
    let relic = content("relic.norse.raven-medallion")
    let first = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        grants: [
            CloudGrant(
                grantID: transaction,
                contentID: seal,
                firstGrantedAt: date(200),
                provenanceReference: opaque("a")
            ),
            CloudGrant(
                grantID: transaction,
                contentID: relic,
                firstGrantedAt: date(200),
                provenanceReference: opaque("b")
            ),
        ]
    )
    let second = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 3,
        grants: [CloudGrant(
            grantID: transaction,
            contentID: seal,
            firstGrantedAt: date(100),
            provenanceReference: opaque("a")
        )]
    )
    let context = try mergeContext()

    let forward = try CloudProgressionMergeEngine.mergeValidated(
        local: first,
        remote: second,
        context: context
    )
    let reverse = try CloudProgressionMergeEngine.mergeValidated(
        local: second,
        remote: first,
        context: context
    )

    #expect(forward == reverse)
    #expect(forward.grants.map(\.contentID) == [relic, seal])
    #expect(forward.grants.first { $0.contentID == seal }?.firstGrantedAt == date(100))
}

@Test
func selectedCodexLWWUsesClockThenWriterWhenBothSelectionsAreAvailable() throws {
    let norse = codex("codex.norse")
    let moonleaf = codex("codex.moonleaf")
    let first = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 5,
        selectedCodex: CloudCodexSelection(
            codexID: norse,
            logicalTimestamp: 4,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    )
    let higherClock = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 6,
        selectedCodex: CloudCodexSelection(
            codexID: moonleaf,
            logicalTimestamp: 5,
            writerDeviceID: opaque("a"),
            updatedAt: date(101)
        )
    )
    let context = try mergeContext()
    let clockWinner = try CloudProgressionMergeEngine.mergeValidated(
        local: first,
        remote: higherClock,
        context: context
    )
    #expect(clockWinner.selectedCodex?.codexID == moonleaf)

    let tieWinner = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 6,
        selectedCodex: CloudCodexSelection(
            codexID: norse,
            logicalTimestamp: 5,
            writerDeviceID: opaque("b"),
            updatedAt: date(101)
        )
    )
    let forward = try CloudProgressionMergeEngine.mergeValidated(
        local: higherClock,
        remote: tieWinner,
        context: context
    )
    let reverse = try CloudProgressionMergeEngine.mergeValidated(
        local: tieWinner,
        remote: higherClock,
        context: context
    )
    #expect(forward == reverse)
    #expect(forward.selectedCodex?.codexID == norse)
    #expect(forward.selectedCodex?.writerDeviceID == opaque("b"))
}

@Test
func canonicalEncodingIsStableAcrossInputOrdering() throws {
    let first = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        ownedContentIDs: [content("seal.norse.raven"), content("relic.norse.tablet")],
        unlockIDs: [unlock("unlock.codex.sunspire"), unlock("unlock.codex.moonleaf")],
        provenanceReferences: [opaque("b"), opaque("a")]
    )
    let second = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        ownedContentIDs: [content("relic.norse.tablet"), content("seal.norse.raven")],
        unlockIDs: [unlock("unlock.codex.moonleaf"), unlock("unlock.codex.sunspire")],
        provenanceReferences: [opaque("a"), opaque("b")]
    )

    #expect(try CloudProgressionCodec.encode(first) == CloudProgressionCodec.encode(second))
    #expect(try CloudProgressionCodec.decode(CloudProgressionCodec.encode(first)) == first)
}

@Test
func corruptOrSecretBearingRemoteIsQuarantinedWithoutChangingLocalTruth() throws {
    let local = try replica(
        device: opaque("a"),
        completionDate: date(100),
        counter: 5,
        selectedCodex: "codex.moonleaf",
        selectionClock: 2,
        pendingPercentage: 20,
        encounterFirst: date(100),
        encounterLast: date(100),
        content: "relic.moonleaf.tablet"
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: CloudProgressionCodec.encode(local))
            as? [String: Any]
    )
    object["cipherKey"] = "must-never-sync"
    let remoteData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let outcome = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: remoteData,
        context: mergeContext()
    )

    #expect(outcome.status == .remoteQuarantinedLocalPreserved)
    #expect(outcome.replica.achievementCompletions == local.achievementCompletions)
    #expect(outcome.replica.grants == local.grants)
    #expect(outcome.replica.quarantineDiagnostics.count == 1)
    #expect(outcome.replica.quarantineDiagnostics.single?.category == .prohibitedField)
}

@Test
func accountChangeAndOfflineModesPreserveLocalWithoutRemoteOverwrite() throws {
    let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
    let remote = try CloudProgressionReplica(
        catalogVersion: 2,
        logicalClock: 9,
        unlockIDs: [unlock("unlock.codex.gloamthorn")]
    )
    let remoteData = try CloudProgressionCodec.encode(remote)
    let changedContext = try CloudProgressionMergeContext(
        localAccountScope: opaque("a"),
        remoteAccountScope: opaque("b"),
        serviceAvailability: .available,
        availableCodexIDs: [codex("codex.norse")],
        fallbackCodexID: codex("codex.norse"),
        now: date(300)
    )
    let changed = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: remoteData,
        context: changedContext
    )
    #expect(changed.status == .accountChangedLocalPreserved)
    #expect(changed.replica.unlockIDs.isEmpty)
    #expect(!changed.shouldUploadLocalReplica)

    let offlineContext = try CloudProgressionMergeContext(
        localAccountScope: opaque("a"),
        remoteAccountScope: opaque("a"),
        serviceAvailability: .offline,
        availableCodexIDs: [codex("codex.norse")],
        fallbackCodexID: codex("codex.norse"),
        now: date(300)
    )
    let offline = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: Data("not-json".utf8),
        context: offlineContext
    )
    #expect(offline.status == .offlineLocalOnly)
    #expect(offline.replica == local)
    #expect(offline.replica.quarantineDiagnostics.isEmpty)
}

@Test
func supportedMigrationScaleDistinctTokensRoundTripsAt4096AndRejects4097() throws {
    let tokens = try (0 ..< CloudProgressionReplica.maximumDistinctStatisticTokenRecords)
        .map { index in
            try CloudDistinctStatisticToken(
                statisticID: statistic("stat.cipher.created.unique"),
                token: CloudOpaqueIdentifier(
                    rawValue: String(format: "%064llx", UInt64(index))
                )!,
                firstObservedAt: date(100)
            )
        }
    let supported = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 1,
        distinctStatisticTokens: tokens
    )
    let payload = try CloudProgressionCodec.encode(supported)

    #expect(payload.count <= CloudSyncFetchResultDTO.maximumPayloadByteCount)
    #expect(try CloudProgressionCodec.decode(payload) == supported)
    #expect(throws: CloudProgressionSchemaError.collectionLimitExceeded(
        "distinct-statistic-tokens"
    )) {
        _ = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: 1,
            distinctStatisticTokens: tokens + [
                try CloudDistinctStatisticToken(
                    statisticID: statistic("stat.cipher.created.unique"),
                    token: opaque("f"),
                    firstObservedAt: date(100)
                ),
            ]
        )
    }
}

@Test
func semanticFutureAndCatalogMismatchAreQuarantined() throws {
    let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
    let future = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        achievementCompletions: [
            try CloudAchievementCompletion(
                achievementID: achievement("achievement.first-inscription"),
                firstCompletedAt: date(401)
            ),
        ]
    )
    let unknownCatalog = try CloudProgressionReplica(
        catalogVersion: 2,
        logicalClock: 2
    )

    let futureOutcome = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: CloudProgressionCodec.encode(future),
        context: mergeContext()
    )
    let catalogOutcome = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: CloudProgressionCodec.encode(unknownCatalog),
        context: mergeContext()
    )

    #expect(futureOutcome.status == .remoteQuarantinedLocalPreserved)
    #expect(catalogOutcome.status == .remoteQuarantinedLocalPreserved)
    #expect(futureOutcome.replica.achievementCompletions.isEmpty)
    #expect(catalogOutcome.replica.catalogVersion == 1)
}

@Test
func overflowingAggregateCounterRemoteIsQuarantined() throws {
    let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
    let valid = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        deviceCounterShards: [
            try CloudDeviceCounterShard(
                statisticID: statistic("stat.message.encoded.unique"),
                deviceID: opaque("a"),
                value: UInt64.max,
                lastUpdatedAt: date(100)
            ),
            try CloudDeviceCounterShard(
                statisticID: statistic("stat.message.encoded.unique"),
                deviceID: opaque("b"),
                value: 0,
                lastUpdatedAt: date(100)
            ),
        ]
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: CloudProgressionCodec.encode(valid))
            as? [String: Any]
    )
    var shards = try #require(object["deviceCounterShards"] as? [[String: Any]])
    shards[1]["value"] = 1
    object["deviceCounterShards"] = shards
    let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

    let outcome = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: payload,
        context: mergeContext()
    )

    #expect(outcome.status == .remoteQuarantinedLocalPreserved)
    #expect(outcome.replica.deviceCounterShards.isEmpty)
}

@Test
func titleClearIsAnExplicitLWWTombstoneAndCodecRoundTripsIt() throws {
    let titleID = TitleID(rawValue: "title.first-inscription")!
    let writerA = opaque("a")
    let writerB = opaque("b")
    let selected = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        titleIDs: [titleID],
        selectedTitle: CloudTitleSelection(
            titleID: titleID,
            logicalTimestamp: 2,
            writerDeviceID: writerA,
            updatedAt: date(200)
        )
    )
    let cleared = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 3,
        titleIDs: [titleID],
        selectedTitle: CloudTitleSelection(
            titleID: nil,
            logicalTimestamp: 3,
            writerDeviceID: writerB,
            updatedAt: date(300)
        )
    )
    let context = try strictMergeContext(
        availableTitleIDs: [titleID],
        knownContentIDs: [titleID.rawValue],
        knownTitleIDs: [titleID]
    )

    let forward = try CloudProgressionMergeEngine.mergeValidated(
        local: selected,
        remote: cleared,
        context: context
    )
    let reverse = try CloudProgressionMergeEngine.mergeValidated(
        local: cleared,
        remote: selected,
        context: context
    )
    #expect(forward == reverse)
    #expect(forward.selectedTitle?.titleID == nil)
    #expect(forward.selectedTitle?.logicalTimestamp == 3)

    let payload = try CloudProgressionCodec.encode(cleared)
    #expect(try CloudProgressionCodec.decode(payload) == cleared)
    let object = try #require(
        JSONSerialization.jsonObject(with: payload) as? [String: Any]
    )
    let wireSelection = try #require(object["selectedTitle"] as? [String: Any])
    #expect(wireSelection["titleID"] == nil)
}

@Test
func remoteNewlyOwnedTitleCanBeSelectedButLockedSelectionsAreSanitized() throws {
    let titleID = TitleID(rawValue: "title.first-inscription")!
    let remoteOwned = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        titleIDs: [titleID],
        selectedTitle: CloudTitleSelection(
            titleID: titleID,
            logicalTimestamp: 2,
            writerDeviceID: opaque("b"),
            updatedAt: date(200)
        )
    )
    let context = try strictMergeContext(
        knownContentIDs: [titleID.rawValue],
        knownTitleIDs: [titleID]
    )
    let adopted = try CloudProgressionMergeEngine.mergeValidated(
        local: CloudProgressionReplica(catalogVersion: 1, logicalClock: 1),
        remote: remoteOwned,
        context: context
    )
    #expect(adopted.titleIDs == [titleID])
    #expect(adopted.selectedTitle?.titleID == titleID)

    let localClear = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 1,
        selectedTitle: CloudTitleSelection(
            titleID: nil,
            logicalTimestamp: 1,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    )
    let locked = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 3,
        selectedTitle: CloudTitleSelection(
            titleID: titleID,
            logicalTimestamp: 3,
            writerDeviceID: opaque("b"),
            updatedAt: date(300)
        )
    )
    let sanitized = try CloudProgressionMergeEngine.mergeValidated(
        local: localClear,
        remote: locked,
        context: context
    )
    #expect(sanitized.selectedTitle?.titleID == nil)
    #expect(sanitized.selectedTitle?.logicalTimestamp == 1)
}

@Test
func knownLockedCodexFactsSurviveWhileLockedSelectionFallsBack() throws {
    let norse = codex("codex.norse")
    let moonleaf = codex("codex.moonleaf")
    let statisticID = statistic("stat.cipher.created.unique")
    let local = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 1,
        selectedCodex: CloudCodexSelection(
            codexID: norse,
            logicalTimestamp: 1,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    )
    let remote = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        distinctStatisticTokens: [
            CloudDistinctStatisticToken(
                statisticID: statisticID,
                codexID: moonleaf,
                token: opaque("c"),
                firstObservedAt: date(150)
            ),
        ],
        selectedCodex: CloudCodexSelection(
            codexID: moonleaf,
            logicalTimestamp: 2,
            writerDeviceID: opaque("b"),
            updatedAt: date(200)
        )
    )
    let context = try strictMergeContext(
        availableCodexIDs: [norse],
        knownStatisticIDs: [statisticID],
        statisticSchemas: [
            statisticID: CloudStatisticMergeSchema(
                representation: .distinctToken,
                requiresCodexBucket: true
            ),
        ],
        knownCodexIDs: [norse, moonleaf]
    )

    let merged = try CloudProgressionMergeEngine.mergeValidated(
        local: local,
        remote: remote,
        context: context
    )
    #expect(merged.distinctStatisticTokens.count == 1)
    #expect(merged.distinctStatisticTokens.single?.codexID == moonleaf)
    #expect(merged.selectedCodex?.codexID == norse)
}

@Test
func semanticCatalogMismatchesAndUncorroboratedReportsAreQuarantined() throws {
    let achievementID = achievement("achievement.first-inscription")
    let statisticID = statistic("stat.cipher.created.unique")
    let moonleaf = codex("codex.moonleaf")
    let context = try strictMergeContext(
        availableCodexIDs: [codex("codex.norse")],
        knownStatisticIDs: [statisticID],
        knownAchievementIDs: [achievementID],
        knownContentIDs: ["relic.moonleaf.tablet", "title.moonleaf.warden"],
        knownArtifactIDs: [ArtifactID(rawValue: "relic.moonleaf.tablet")!],
        achievementTargets: [achievementID: 1],
        statisticSchemas: [
            statisticID: CloudStatisticMergeSchema(
                representation: .distinctToken,
                requiresCodexBucket: true
            ),
        ],
        knownCodexIDs: [codex("codex.norse"), moonleaf]
    )
    let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
    let invalidStatisticShape = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        deviceCounterShards: [
            CloudDeviceCounterShard(
                statisticID: statisticID,
                codexID: moonleaf,
                deviceID: opaque("a"),
                value: 1,
                lastUpdatedAt: date(100)
            ),
        ]
    )
    let forgedReport = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        achievementProgress: [
            CloudAchievementProgress(
                achievementID: achievementID,
                current: 1,
                target: 1,
                lastUpdatedAt: date(100)
            ),
        ],
        pendingGameCenterReports: [
            CloudPendingGameCenterReport(
                achievementID: achievementID,
                percentage: 100,
                firstQueuedAt: date(100),
                lastUpdatedAt: date(100)
            ),
        ]
    )
    let unknownArtifact = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: 2,
        encounters: [
            CloudEncounter(
                encounterID: opaque("e"),
                codexID: moonleaf,
                // Catalog-known content of the wrong kind must not be accepted
                // as encounter evidence.
                artifactIDs: [ArtifactID(rawValue: "title.moonleaf.warden")!],
                firstEncounteredAt: date(100),
                lastEncounteredAt: date(100),
                encounterCount: 1
            ),
        ]
    )

    for remote in [invalidStatisticShape, forgedReport, unknownArtifact] {
        let outcome = try CloudProgressionMergeEngine.merge(
            local: local,
            remoteData: CloudProgressionCodec.encode(remote),
            context: context
        )
        #expect(outcome.status == .remoteQuarantinedLocalPreserved)
        #expect(outcome.shouldUploadLocalReplica)
    }
}

@Test
func incrementableLogicalClocksRejectMaximumValueAndUnboundedRemoteAdvance() throws {
    #expect(throws: CloudProgressionSchemaError.invalidLogicalClock) {
        _ = try CloudProgressionReplica(
            catalogVersion: 1,
            logicalClock: UInt64.max
        )
    }
    #expect(throws: CloudProgressionSchemaError.invalidLogicalClock) {
        _ = try CloudCodexSelection(
            codexID: codex("codex.norse"),
            logicalTimestamp: UInt64.max,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    }
    #expect(throws: CloudProgressionSchemaError.invalidLogicalClock) {
        _ = try CloudTitleSelection(
            titleID: nil,
            logicalTimestamp: UInt64.max,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    }
    let unadvanceableRemote = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: UInt64.max - 2,
        selectedCodex: CloudCodexSelection(
            codexID: codex("codex.norse"),
            logicalTimestamp: UInt64.max - 2,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    )
    let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: 1)
    let outcome = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: CloudProgressionCodec.encode(unadvanceableRemote),
        context: mergeContext()
    )
    #expect(outcome.status == .remoteQuarantinedLocalPreserved)
    #expect(outcome.replica.selectedCodex == nil)
}

@Test
func boundedRemoteLogicalClockCanBeSupersededByTheNextLocalSelection() throws {
    let localClock: UInt64 = 40
    let remoteClock = localClock
        + CloudProgressionReplica.maximumRemoteLogicalClockAdvance
    let local = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: localClock,
        selectedCodex: CloudCodexSelection(
            codexID: codex("codex.norse"),
            logicalTimestamp: localClock,
            writerDeviceID: opaque("a"),
            updatedAt: date(100)
        )
    )
    let remote = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: remoteClock,
        selectedCodex: CloudCodexSelection(
            codexID: codex("codex.moonleaf"),
            logicalTimestamp: remoteClock,
            writerDeviceID: opaque("b"),
            updatedAt: date(101)
        )
    )

    let merged = try CloudProgressionMergeEngine.mergeValidated(
        local: local,
        remote: remote,
        context: mergeContext()
    )
    #expect(merged.selectedCodex?.codexID == codex("codex.moonleaf"))

    let localOverrideClock = remoteClock + 1
    let localOverride = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: localOverrideClock,
        selectedCodex: CloudCodexSelection(
            codexID: codex("codex.norse"),
            logicalTimestamp: localOverrideClock,
            writerDeviceID: opaque("a"),
            updatedAt: date(102)
        )
    )
    let superseded = try CloudProgressionMergeEngine.mergeValidated(
        local: merged,
        remote: localOverride,
        context: mergeContext()
    )
    #expect(superseded.selectedCodex?.codexID == codex("codex.norse"))
    #expect(superseded.selectedCodex?.logicalTimestamp == localOverrideClock)
}

@Test
func remoteLogicalClockBeyondBoundedAdvanceIsQuarantined() throws {
    let localClock: UInt64 = 40
    let rejectedClock = localClock
        + CloudProgressionReplica.maximumRemoteLogicalClockAdvance
        + 1
    let local = try CloudProgressionReplica(catalogVersion: 1, logicalClock: localClock)
    let remote = try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: rejectedClock,
        selectedTitle: CloudTitleSelection(
            titleID: nil,
            logicalTimestamp: rejectedClock,
            writerDeviceID: opaque("b"),
            updatedAt: date(101)
        )
    )

    let outcome = try CloudProgressionMergeEngine.merge(
        local: local,
        remoteData: CloudProgressionCodec.encode(remote),
        context: mergeContext()
    )
    #expect(outcome.status == .remoteQuarantinedLocalPreserved)
    #expect(outcome.replica.logicalClock == localClock)
    #expect(outcome.replica.selectedTitle == nil)
}

private func replica(
    device: CloudOpaqueIdentifier,
    completionDate: Date,
    counter: UInt64,
    selectedCodex: String,
    selectionClock: UInt64,
    pendingPercentage: UInt8,
    encounterFirst: Date,
    encounterLast: Date,
    content contentValue: String
) throws -> CloudProgressionReplica {
    let achievement = achievement("achievement.first-inscription")
    return try CloudProgressionReplica(
        catalogVersion: 1,
        logicalClock: selectionClock,
        achievementCompletions: [
            try CloudAchievementCompletion(
                achievementID: achievement,
                firstCompletedAt: completionDate
            ),
        ],
        grants: [
            try CloudGrant(
                grantID: GrantTransactionID(
                    rawValue: "transaction.shared-achievement-grant"
                )!,
                contentID: content("seal.norse.raven"),
                firstGrantedAt: completionDate,
                provenanceReference: opaque("c")
            ),
            try CloudGrant(
                grantID: GrantTransactionID(
                    rawValue: "transaction.device.\(device.rawValue)"
                )!,
                contentID: content(contentValue),
                firstGrantedAt: completionDate,
                provenanceReference: device
            ),
        ],
        ownedContentIDs: [content(contentValue)],
        encounters: [
            try CloudEncounter(
                encounterID: opaque("e"),
                codexID: codex("codex.moonleaf"),
                firstEncounteredAt: encounterFirst,
                lastEncounteredAt: encounterLast,
                encounterCount: counter
            ),
        ],
        deviceCounterShards: [
            try CloudDeviceCounterShard(
                statisticID: statistic("stat.message.encoded.unique"),
                deviceID: device,
                value: counter,
                lastUpdatedAt: encounterLast
            ),
        ],
        achievementProgress: [
            try CloudAchievementProgress(
                achievementID: achievement,
                current: min(counter, 10),
                target: 10,
                lastUpdatedAt: encounterLast
            ),
        ],
        selectedCodex: try CloudCodexSelection(
            codexID: codex(selectedCodex),
            logicalTimestamp: selectionClock,
            writerDeviceID: device,
            updatedAt: encounterLast
        ),
        pendingGameCenterReports: [
            try CloudPendingGameCenterReport(
                achievementID: achievement,
                percentage: pendingPercentage,
                firstQueuedAt: encounterFirst,
                lastUpdatedAt: encounterLast
            ),
        ]
    )
}

private func mergeContext() throws -> CloudProgressionMergeContext {
    try CloudProgressionMergeContext(
        localAccountScope: opaque("a"),
        remoteAccountScope: opaque("a"),
        serviceAvailability: .available,
        availableCodexIDs: [codex("codex.norse"), codex("codex.moonleaf")],
        fallbackCodexID: codex("codex.norse"),
        now: date(400)
    )
}

private func strictMergeContext(
    availableCodexIDs: Set<CodexID> = [CodexID(rawValue: "codex.norse")!],
    availableTitleIDs: Set<TitleID> = [],
    knownStatisticIDs: Set<StatisticID> = [],
    knownAchievementIDs: Set<AchievementID> = [],
    knownContentIDs: Set<String> = [],
    knownArtifactIDs: Set<ArtifactID> = [],
    achievementTargets: [AchievementID: UInt64] = [:],
    statisticSchemas: [StatisticID: CloudStatisticMergeSchema] = [:],
    knownCodexIDs: Set<CodexID> = [CodexID(rawValue: "codex.norse")!],
    knownTitleIDs: Set<TitleID> = []
) throws -> CloudProgressionMergeContext {
    try CloudProgressionMergeContext(
        localAccountScope: opaque("a"),
        remoteAccountScope: opaque("a"),
        serviceAvailability: .available,
        availableCodexIDs: availableCodexIDs,
        fallbackCodexID: codex("codex.norse"),
        availableTitleIDs: availableTitleIDs,
        knownStatisticIDs: knownStatisticIDs,
        knownAchievementIDs: knownAchievementIDs,
        knownContentIDs: knownContentIDs,
        knownArtifactIDs: knownArtifactIDs,
        achievementTargets: achievementTargets,
        validatesCatalogMembership: true,
        statisticSchemas: statisticSchemas,
        knownCodexIDs: knownCodexIDs,
        knownTitleIDs: knownTitleIDs,
        now: date(400)
    )
}

private func date(_ value: TimeInterval) -> Date { Date(timeIntervalSince1970: value) }
private func opaque(_ character: Character) -> CloudOpaqueIdentifier {
    CloudOpaqueIdentifier(rawValue: String(repeating: character, count: 64))!
}
private func content(_ value: String) -> CloudProgressionContentID {
    CloudProgressionContentID(rawValue: value)!
}
private func codex(_ value: String) -> CodexID { CodexID(rawValue: value)! }
private func unlock(_ value: String) -> UnlockID { UnlockID(rawValue: value)! }
private func achievement(_ value: String) -> AchievementID { AchievementID(rawValue: value)! }
private func statistic(_ value: String) -> StatisticID { StatisticID(rawValue: value)! }

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
