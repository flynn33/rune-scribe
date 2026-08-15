import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class ProgressionContractSafetyTests: XCTestCase {
    func testAllCatalogEventPayloadShapesRoundTripAndRejectMissingFields() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for eventCase in try catalogEventCases() {
            let fact = try ProgressionEventFact(
                eventType: eventCase.eventType,
                eligibility: eligibility,
                payload: eventCase.payload
            )
            XCTAssertEqual(
                try decoder.decode(
                    ProgressionEventFact.self,
                    from: encoder.encode(fact)
                ),
                fact,
                eventCase.eventType.rawValue
            )
            XCTAssertThrowsError(
                try ProgressionEventFact(
                    eventType: eventCase.eventType,
                    eligibility: eligibility,
                    payload: DomainEventPayload()
                ),
                eventCase.eventType.rawValue
            )
        }
    }

    func testCatalogEventPayloadCompatibilityRejectsUnknownExtraneousAndWrongFixedValues() throws {
        XCTAssertThrowsError(
            try ProgressionEventFact(
                eventType: "runescribe.future.event",
                eligibility: eligibility,
                payload: DomainEventPayload()
            )
        )
        XCTAssertThrowsError(
            try ProgressionEventFact(
                eventType: "runescribe.cipher.created",
                eligibility: eligibility,
                payload: DomainEventPayload(
                    cipherToken: cipherToken,
                    messageToken: messageToken,
                    origin: .generated
                )
            )
        )
        XCTAssertThrowsError(
            try ProgressionEventFact(
                eventType: "runescribe.cipher.first-delivery-completed",
                eligibility: eligibility,
                payload: DomainEventPayload(
                    cipherToken: cipherToken,
                    relationshipToken: relationshipToken,
                    keyIncluded: false,
                    linkedRelationship: true
                )
            )
        )
        XCTAssertThrowsError(
            try ProgressionEventFact(
                eventType: "runescribe.cipher.imported",
                eligibility: eligibility,
                payload: DomainEventPayload(
                    cipherToken: cipherToken,
                    origin: .generated,
                    routeClass: .file
                )
            )
        )
    }

    func testNestedPayloadAndProgressionDTOUnknownKeysAreRejected() throws {
        let fact = try ProgressionEventFact(
            eventType: "runescribe.cipher.created",
            eligibility: eligibility,
            payload: DomainEventPayload(cipherToken: cipherToken, origin: .generated)
        )
        var factObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fact)) as? [String: Any]
        )
        var payloadObject = try XCTUnwrap(factObject["payload"] as? [String: Any])
        payloadObject["plaintext"] = "forbidden"
        factObject["payload"] = payloadObject
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProgressionEventFact.self,
                from: JSONSerialization.data(withJSONObject: factObject)
            )
        )

        var snapshotObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(validSnapshot()))
                as? [String: Any]
        )
        var achievements = try XCTUnwrap(
            snapshotObject["achievements"] as? [[String: Any]]
        )
        var achievement = try XCTUnwrap(achievements.first)
        var presentationObject = try XCTUnwrap(
            achievement["presentation"] as? [String: Any]
        )
        presentationObject["unboundedMetadata"] = "forbidden"
        achievement["presentation"] = presentationObject
        achievements[0] = achievement
        snapshotObject["achievements"] = achievements
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProgressionSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: snapshotObject)
            )
        )
    }

    func testCatalogVersionIsPositiveNumericAndGrantIdentifiersRemainDistinct() throws {
        let version = try XCTUnwrap(ProgressionCatalogVersion(rawValue: 1))
        XCTAssertEqual(try JSONEncoder().encode(version), Data("1".utf8))
        XCTAssertEqual(
            try JSONDecoder().decode(ProgressionCatalogVersion.self, from: Data("1".utf8)),
            version
        )
        XCTAssertNil(ProgressionCatalogVersion(rawValue: 0))
        XCTAssertThrowsError(
            try JSONDecoder().decode(ProgressionCatalogVersion.self, from: Data("0".utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProgressionCatalogVersion.self,
                from: Data("\"1\"".utf8)
            )
        )

        let group = try XCTUnwrap(GrantGroupID(rawValue: "grant-group.test"))
        let transaction = try XCTUnwrap(
            GrantTransactionID(rawValue: "grant-group.test")
        )
        XCTAssertEqual(group.rawValue, transaction.rawValue)
        acceptGrantGroup(group)
        acceptGrantTransaction(transaction)
    }

    func testValidSnapshotRoundTripsWithStableOrderingAndSafePresentation() throws {
        let snapshot = try validSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProgressionSnapshotDTO.self, from: data)

        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.codexGates.map(\.journeyOrder), [1])
        XCTAssertEqual(decoded.selectedTitleID, titleID)
        XCTAssertEqual(decoded.nextReveal?.tier, .artifact)
        XCTAssertEqual(decoded.nextReveal?.rarity, .rare)
        XCTAssertEqual(decoded.nextReveal?.contentGrantCount, 2)
        XCTAssertEqual(decoded.archive.first?.provenanceStatus, .verified)
        XCTAssertEqual(decoded.ownership.first?.providerAvailability, .unavailable)
        XCTAssertEqual(decoded.ownership.first?.renderState, .genericFallback)
    }

    func testProgressCompletionAndSelectedTitleInvariantsRejectContradictions() throws {
        XCTAssertThrowsError(try ProgressionNumericProgressDTO(current: 2, target: 1))
        XCTAssertThrowsError(try ProgressionNumericProgressDTO(current: 0, target: 0))
        XCTAssertThrowsError(
            try ProgressionCodexGateDTO(
                codexID: codexID,
                presentation: presentation,
                journeyOrder: 1,
                completedRuleCount: 1,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(current: 0, target: 1),
                components: [
                    try ProgressionGateComponentDTO(
                        componentID: "rule.test.component.1",
                        label: "Complete the requirement",
                        current: 1,
                        target: 1,
                        isComplete: true
                    ),
                ],
                unlockedAt: nil
            )
        )
        XCTAssertThrowsError(
            try ProgressionAchievementDTO(
                achievementID: achievementID,
                presentation: presentation,
                completedRuleCount: 1,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(current: 1, target: 1),
                completedAt: nil,
                isHidden: false,
                localPointWeight: 5,
                rewards: ProgressionRewardSummaryDTO()
            )
        )
        XCTAssertThrowsError(
            try ProgressionTitleDTO(
                titleID: titleID,
                presentation: presentation,
                isOwned: false,
                isSelected: true
            )
        )

        let unselected = try ProgressionTitleDTO(
            titleID: titleID,
            presentation: presentation,
            isOwned: true,
            isSelected: false
        )
        XCTAssertThrowsError(
            try baseSnapshot(titles: [unselected], selectedTitleID: titleID)
        )
    }

    func testIncludedRootJourneyGateSupportsZeroRuleCompletion() throws {
        let gate = try ProgressionCodexGateDTO(
            codexID: codexID,
            presentation: presentation,
            journeyOrder: 0,
            completedRuleCount: 0,
            requiredRuleCount: 0,
            progress: ProgressionNumericProgressDTO(current: 1, target: 1),
            components: [],
            unlockedAt: earlier
        )
        XCTAssertEqual(gate.completedRuleCount, 0)
        XCTAssertEqual(gate.requiredRuleCount, 0)
        XCTAssertNotNil(gate.unlockedAt)
    }

    func testGateComponentsRoundTripRejectUnknownKeysAndEnforceBounds() throws {
        let component = try ProgressionGateComponentDTO(
            componentID: "rule.test.component.1",
            label: "Create five ciphers",
            current: 4,
            target: 5,
            isComplete: false
        )
        let data = try JSONEncoder().encode(component)
        XCTAssertEqual(
            try JSONDecoder().decode(ProgressionGateComponentDTO.self, from: data),
            component
        )

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["rawToken"] = "forbidden"
        XCTAssertThrowsError(try JSONDecoder().decode(
            ProgressionGateComponentDTO.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
        XCTAssertThrowsError(try ProgressionGateComponentDTO(
            componentID: component.componentID,
            label: component.label,
            current: component.current,
            target: component.target,
            isComplete: true
        ))

        let maximum = try (0 ..< ProgressionCodexGateDTO.maximumComponentCount).map {
            try ProgressionGateComponentDTO(
                componentID: "rule.test.component.\($0 + 1)",
                label: "Requirement \($0 + 1)",
                current: 0,
                target: 1,
                isComplete: false
            )
        }
        XCTAssertNoThrow(try ProgressionCodexGateDTO(
            codexID: codexID,
            presentation: presentation,
            journeyOrder: 1,
            completedRuleCount: 0,
            requiredRuleCount: UInt16(maximum.count),
            progress: ProgressionNumericProgressDTO(
                current: 0,
                target: UInt64(maximum.count)
            ),
            components: maximum,
            unlockedAt: nil
        ))
        XCTAssertThrowsError(try ProgressionCodexGateDTO(
            codexID: codexID,
            presentation: presentation,
            journeyOrder: 1,
            completedRuleCount: 0,
            requiredRuleCount: UInt16(maximum.count + 1),
            progress: ProgressionNumericProgressDTO(
                current: 0,
                target: UInt64(maximum.count + 1)
            ),
            components: maximum + [try ProgressionGateComponentDTO(
                componentID: "rule.test.component.overflow",
                label: "Overflow",
                current: 0,
                target: 1,
                isComplete: false
            )],
            unlockedAt: nil
        ))
    }

    func testHiddenAchievementAndPresentationBoundsDoNotLeakSecretCopy() throws {
        let hiddenPresentation = try ProgressionPresentationDTO(
            displayName: "Hidden achievement",
            summary: nil,
            fallbackSystemImageName: "questionmark.square.dashed"
        )
        XCTAssertNoThrow(
            try ProgressionAchievementDTO(
                achievementID: achievementID,
                presentation: hiddenPresentation,
                completedRuleCount: 0,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(current: 0, target: 1),
                completedAt: nil,
                isHidden: true,
                localPointWeight: 10,
                rewards: ProgressionRewardSummaryDTO()
            )
        )
        XCTAssertThrowsError(
            try ProgressionAchievementDTO(
                achievementID: achievementID,
                presentation: presentation,
                completedRuleCount: 0,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(current: 0, target: 1),
                completedAt: nil,
                isHidden: true,
                localPointWeight: 10,
                rewards: ProgressionRewardSummaryDTO()
            )
        )
        XCTAssertThrowsError(
            try ProgressionPresentationDTO(
                displayName: String(
                    repeating: "x",
                    count: ProgressionPresentationDTO.maximumDisplayNameUTF8Count + 1
                ),
                summary: nil,
                fallbackSystemImageName: "star"
            )
        )
        XCTAssertThrowsError(
            try ProgressionPresentationDTO(
                displayName: "Name",
                summary: "Summary",
                fallbackSystemImageName: "INVALID IMAGE"
            )
        )
    }

    func testOwnershipRenderAndArchiveStatesAreExplicitAndValidated() throws {
        let locked = try ProgressionOwnershipDTO(
            kind: .relic,
            reference: .artifact(artifactID),
            presentation: presentation,
            state: .locked,
            renderState: .locked
        )
        XCTAssertEqual(locked.providerAvailability, .unavailable)

        let encountered = try ProgressionOwnershipDTO(
            kind: .relic,
            reference: .artifact(artifactID),
            presentation: presentation,
            state: .encountered,
            firstEncounteredAt: earlier,
            renderState: .genericFallback
        )
        XCTAssertEqual(encountered.state, .encountered)

        let ownedUnavailable = try ProgressionOwnershipDTO(
            kind: .relic,
            reference: .artifact(artifactID),
            presentation: presentation,
            state: .owned,
            grantedAt: now,
            sourceRuleIDs: [ruleID],
            renderState: .genericFallback
        )
        XCTAssertEqual(ownedUnavailable.providerAvailability, .unavailable)

        XCTAssertThrowsError(
            try ProgressionOwnershipDTO(
                kind: .relic,
                reference: .artifact(artifactID),
                presentation: presentation,
                state: .owned,
                grantedAt: now,
                providerAvailability: .active,
                renderState: .genericFallback
            )
        )

        let unknownArchive = try ProgressionArchiveEntryDTO(
            kind: .unknown,
            reference: .unknown,
            presentation: genericPresentation,
            supportState: .unknown,
            ownershipState: .encountered,
            renderState: .genericFallback,
            firstEncounteredAt: earlier,
            lastEncounteredAt: now,
            encounterCount: 1,
            provenanceStatus: .unsupported
        )
        XCTAssertEqual(unknownArchive.supportState, .unknown)
        XCTAssertThrowsError(
            try ProgressionArchiveEntryDTO(
                kind: .codex,
                reference: .codex(codexID),
                presentation: presentation,
                supportState: .unknown,
                ownershipState: .encountered,
                renderState: .genericFallback,
                firstEncounteredAt: earlier,
                lastEncounteredAt: now,
                encounterCount: 1,
                provenanceStatus: .verified
            )
        )
    }

    func testDuplicatesAndOversizedNestedCollectionsAreRejectedWithoutDedupe() throws {
        XCTAssertThrowsError(
            try ProgressionRewardSummaryDTO(contentIDs: [artifactID, artifactID])
        )
        XCTAssertThrowsError(
            try ProgressionRewardSummaryDTO(
                contentIDs: (0 ... ProgressionRewardSummaryDTO.maximumRewardCount).map {
                    ArtifactID(rawValue: "artifact.reward-\($0)")!
                }
            )
        )
        XCTAssertThrowsError(
            try ProgressionRevealSummaryDTO(
                revealID: revealID,
                transactionID: transactionID,
                createdAt: now,
                state: .pending,
                tier: .artifact,
                rarity: .rare,
                primaryRewardID: .artifact(artifactID),
                primaryRewardPresentation: presentation,
                secondaryRewardIDs: [
                    .artifact(secondaryArtifactID), .artifact(secondaryArtifactID),
                ],
                sourceRuleIDs: [ruleID]
            )
        )
        XCTAssertThrowsError(
            try ProgressionEntitlementSnapshotDTO(
                revision: 1,
                capturedAt: now,
                includedUnlockIDs: [unlockID],
                earnedUnlockIDs: [unlockID]
            )
        )

        let statistics = (0 ... ProgressionSnapshotDTO.maximumStatisticCount).map {
            ProgressionStatisticDTO(
                statisticID: StatisticID(rawValue: "stat.oversized-\($0)")!,
                presentation: presentation,
                value: 0
            )
        }
        XCTAssertThrowsError(try baseSnapshot(statistics: statistics))
    }

    func testMutatedNestedJSONRejectsProgressDateAndDuplicateViolations() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(validSnapshot()))
                as? [String: Any]
        )

        var achievements = try XCTUnwrap(object["achievements"] as? [[String: Any]])
        var achievement = try XCTUnwrap(achievements.first)
        var progress = try XCTUnwrap(achievement["progress"] as? [String: Any])
        progress["current"] = 2
        progress["target"] = 1
        achievement["progress"] = progress
        achievements[0] = achievement
        object["achievements"] = achievements
        XCTAssertThrowsError(
            try decoder.decode(
                ProgressionSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(validSnapshot()))
                as? [String: Any]
        )
        var archive = try XCTUnwrap(object["archive"] as? [[String: Any]])
        archive[0]["firstEncounteredAt"] = "not-a-date"
        object["archive"] = archive
        XCTAssertThrowsError(
            try decoder.decode(
                ProgressionSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )

        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(validSnapshot()))
                as? [String: Any]
        )
        var statistics = try XCTUnwrap(object["statistics"] as? [[String: Any]])
        statistics.append(try XCTUnwrap(statistics.first))
        object["statistics"] = statistics
        XCTAssertThrowsError(
            try decoder.decode(
                ProgressionSnapshotDTO.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
        )
    }

    func testFiniteDatesAndPendingRevealCountConsistencyAreEnforced() throws {
        let invalidDate = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(
            try ProgressionOutboxReceipt(
                eventID: EventID(rawValue: UUID()),
                correlationID: CorrelationID(rawValue: UUID()),
                durableAt: invalidDate,
                outboxRevision: 1
            )
        )
        XCTAssertThrowsError(
            try ProgressionEncounterDTO(
                codexID: codexID,
                firstEncounteredAt: now,
                lastEncounteredAt: earlier,
                encounterCount: 1,
                provenanceStatus: .verified
            )
        )
        XCTAssertThrowsError(
            try ProgressionRecoveryResult(rebuiltAt: invalidDate, revision: 1)
        )
        XCTAssertThrowsError(
            try baseSnapshot(pendingRevealCount: 0, nextReveal: validReveal())
        )
        XCTAssertThrowsError(
            try baseSnapshot(pendingRevealCount: 1, nextReveal: nil)
        )

        let acknowledged = try ProgressionRevealSummaryDTO(
            revealID: revealID,
            transactionID: transactionID,
            createdAt: now,
            state: .acknowledged,
            tier: .artifact,
            rarity: .rare,
            primaryRewardID: .artifact(artifactID),
            primaryRewardPresentation: presentation,
            sourceRuleIDs: [ruleID]
        )
        XCTAssertThrowsError(
            try baseSnapshot(pendingRevealCount: 1, nextReveal: acknowledged)
        )
    }

    func testAllApplyOutcomesRoundTripAndMalformedAppliedResultsFail() throws {
        let reason = try XCTUnwrap(
            ProgressionRejectionCode(rawValue: "event.invalid-payload")
        )
        let outcomes: [ProgressionEventApplyResult] = [
            .applied(
                transactionID: transactionID,
                revision: 1,
                delta: ProgressionStateDeltaSummary(
                    changedStatisticCount: 1,
                    completedAchievementCount: 2,
                    completedMilestoneCount: 3,
                    grantedContentCount: 4,
                    grantedEntitlementCount: 5,
                    queuedRevealCount: 1
                )
            ),
            .duplicate,
            .ignoredIneligible,
            .rejectedPermanent(reason: reason),
            .deferredUnsupportedSchema,
            .deferredStoreUnavailable,
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for outcome in outcomes {
            XCTAssertEqual(
                try decoder.decode(
                    ProgressionEventApplyResult.self,
                    from: encoder.encode(outcome)
                ),
                outcome
            )
        }
        XCTAssertThrowsError(
            try encoder.encode(
                ProgressionEventApplyResult.applied(
                    transactionID: transactionID,
                    revision: 0,
                    delta: ProgressionStateDeltaSummary()
                )
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(
                ProgressionEventApplyResult.self,
                from: Data(
                    """
                    {"outcome":"applied","transactionID":"grant.transaction-1","revision":0,"delta":{"changedStatisticCount":0,"completedAchievementCount":0,"completedMilestoneCount":0,"grantedContentCount":0,"grantedEntitlementCount":0,"queuedRevealCount":0}}
                    """.utf8
                )
            )
        )
        XCTAssertThrowsError(
            try decoder.decode(
                ProgressionEventApplyResult.self,
                from: Data("{\"outcome\":\"duplicate\",\"reason\":\"event.extra\"}".utf8)
            )
        )
    }

    func testDiagnosticsAreBoundedTypedAndContainNoRawTokenFields() throws {
        let diagnostics = try validDiagnostics()
        let data = try JSONEncoder().encode(diagnostics)
        XCTAssertEqual(
            try JSONDecoder().decode(ProgressionDiagnosticsSummaryDTO.self, from: data),
            diagnostics
        )
        XCTAssertEqual(diagnostics.stateNamespaceSchemaVersion, 1)
        XCTAssertEqual(diagnostics.logicalRecordSchemaVersion, 1)
        XCTAssertNil(ProgressionSHA256Digest(rawValue: String(repeating: "A", count: 64)))
        XCTAssertNil(ProgressionSHA256Digest(rawValue: String(repeating: "a", count: 63)))
        XCTAssertThrowsError(
            try ProgressionDiagnosticRecordCountDTO(
                category: .metadata,
                count: ProgressionDiagnosticRecordCountDTO.maximumRecordCount + 1
            )
        )
        XCTAssertThrowsError(
            try ProgressionDiagnosticErrorDTO(
                category: .integrity,
                count: 0,
                mostRecentCode: nil
            )
        )
        XCTAssertThrowsError(
            try ProgressionDiagnosticsSummaryDTO(
                capturedAt: now,
                availability: .available,
                storeHealth: .loaded,
                catalogID: catalogID,
                catalogVersion: catalogVersion,
                stateNamespaceSchemaVersion: 1,
                logicalRecordSchemaVersion: 1,
                pendingOutboxCount: 0,
                recordCounts: [
                    ProgressionDiagnosticRecordCountDTO(category: .metadata, count: 1),
                    ProgressionDiagnosticRecordCountDTO(category: .metadata, count: 2),
                ]
            )
        )
        XCTAssertThrowsError(
            try ProgressionDiagnosticsSummaryDTO(
                capturedAt: now,
                availability: .available,
                storeHealth: .loaded,
                catalogID: catalogID,
                catalogVersion: catalogVersion,
                pendingOutboxCount: 0
            )
        )
        XCTAssertThrowsError(
            try ProgressionDiagnosticsSummaryDTO(
                capturedAt: now,
                availability: .available,
                storeHealth: .loaded,
                catalogID: catalogID,
                catalogVersion: catalogVersion,
                stateNamespaceSchemaVersion: 1,
                logicalRecordSchemaVersion: nil,
                pendingOutboxCount: 0
            )
        )
        XCTAssertThrowsError(
            try ProgressionDiagnosticsSummaryDTO(
                capturedAt: now,
                availability: .available,
                storeHealth: .loaded,
                catalogID: catalogID,
                catalogVersion: catalogVersion,
                stateNamespaceSchemaVersion: 0,
                logicalRecordSchemaVersion: 1,
                pendingOutboxCount: 0
            )
        )
        var diagnosticsObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        diagnosticsObject["rawEvent"] = "forbidden"
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProgressionDiagnosticsSummaryDTO.self,
                from: JSONSerialization.data(withJSONObject: diagnosticsObject)
            )
        )

        let snapshotJSON = try XCTUnwrap(
            String(data: JSONEncoder().encode(validSnapshot()), encoding: .utf8)
        )
        let diagnosticsJSON = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in [
            "cipherToken", "messageToken", "packageToken", "relationshipToken",
            "plaintext", "keyMaterial", "contactName", "email", "phoneNumber",
        ] {
            XCTAssertFalse(snapshotJSON.contains(forbidden), forbidden)
            XCTAssertFalse(diagnosticsJSON.contains(forbidden), forbidden)
        }
    }

    func testEndpointCatalogPublishesExactlyEightTypedCapabilityBoundaries() {
        let expected: Set<RuntimeEndpointIdentifier> = [
            "progression.event.apply",
            "progression.state",
            "progression.entitlements",
            "progression.reveal.mark-presented",
            "progression.reveal.acknowledge",
            "progression.title.select",
            "progression.diagnostics.summary",
            "progression.recovery.rebuild",
        ]
        XCTAssertEqual(RuntimeProgressionEndpointCatalog.publishedEndpointIDs, expected)
        XCTAssertEqual(RuntimeProgressionEndpointCatalog.publishedEndpointIDs.count, 8)
        XCTAssertEqual(RuntimeProgressionEndpointCatalog.UIEndpointIDs.count, 6)
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.applyEvent.descriptor.requiredCapability,
            RuneScribeCapabilities.progressionEventApply
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.progressionState.requiredCapability,
            RuneScribeCapabilities.progressionStateRead
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.entitlements.requiredCapability,
            RuneScribeCapabilities.progressionStateRead
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.markRevealPresented.descriptor
                .requiredCapability,
            RuneScribeCapabilities.progressionCommands
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.acknowledgeReveal.descriptor.requiredCapability,
            RuneScribeCapabilities.progressionCommands
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.selectTitle.descriptor.requiredCapability,
            RuneScribeCapabilities.progressionCommands
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.diagnosticsSummary.descriptor.requiredCapability,
            RuneScribeCapabilities.progressionStateRead
        )
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.rebuild.descriptor.requiredCapability,
            RuneScribeCapabilities.progressionRecovery
        )
        XCTAssertFalse(
            RuntimeProgressionEndpointCatalog.UIEndpointIDs.contains(
                RuntimeProgressionEndpointCatalog.rebuild.descriptor.endpointID
            )
        )
    }

    func testMarkRevealPresentedCommandRoundTripsAndRejectsUnknownFields() throws {
        let command = MarkProgressionRevealPresentedCommand(
            revealID: RevealID(rawValue: "reveal.contract.presented")!
        )
        let encoded = try JSONEncoder().encode(command)
        XCTAssertEqual(
            try JSONDecoder().decode(
                MarkProgressionRevealPresentedCommand.self,
                from: encoded
            ),
            command
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["unexpected"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(
            MarkProgressionRevealPresentedCommand.self,
            from: JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testMaximumBoundedSnapshotEncodesBelowEndpointLimit() throws {
        let snapshot = try maximumBoundedSnapshot()
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertLessThanOrEqual(data.count, 4 * 1_024 * 1_024)
        XCTAssertEqual(
            try JSONDecoder().decode(ProgressionSnapshotDTO.self, from: data),
            snapshot
        )
    }

    func testProgressionContractTypesAreSendable() {
        assertSendable(ProgressionEventFact.self)
        assertSendable(ProgressionSnapshotDTO.self)
        assertSendable(ProgressionEntitlementSnapshotDTO.self)
        assertSendable(ProgressionDiagnosticsSummaryDTO.self)
        assertSendable(ProgressionArchiveEntryDTO.self)
        assertSendable(ProgressionContentReference.self)
        assertSendable(ProgressionRevealSummaryDTO.self)
    }

    private struct CatalogEventCase {
        let eventType: EventIdentifier
        let payload: DomainEventPayload
    }

    private func catalogEventCases() throws -> [CatalogEventCase] {
        [
            CatalogEventCase(
                eventType: "runescribe.cipher.created",
                payload: try DomainEventPayload(
                    cipherToken: cipherToken,
                    origin: .generated
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.cipher.imported",
                payload: try DomainEventPayload(
                    cipherToken: cipherToken,
                    origin: .imported,
                    routeClass: .file
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.message.encoded",
                payload: try DomainEventPayload(
                    cipherToken: cipherToken,
                    messageToken: messageToken,
                    origin: .generated,
                    codexIDs: [codexID]
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.share.completed",
                payload: try DomainEventPayload(
                    messageToken: messageToken,
                    relationshipToken: relationshipToken,
                    routeClass: .shareSheet,
                    codexIDs: [codexID],
                    artifactIDs: [artifactID],
                    keyIncluded: false,
                    linkedRelationship: true
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.cipher.first-delivery-completed",
                payload: try DomainEventPayload(
                    cipherToken: cipherToken,
                    relationshipToken: relationshipToken,
                    keyIncluded: true,
                    linkedRelationship: true
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.message.imported",
                payload: try DomainEventPayload(
                    packageToken: packageToken,
                    origin: .imported,
                    routeClass: .customURL,
                    codexIDs: [codexID],
                    artifactIDs: [artifactID],
                    embeddedCipher: false,
                    provenanceStatus: .verified
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.message.decoded",
                payload: try DomainEventPayload(
                    packageToken: packageToken,
                    relationshipToken: relationshipToken,
                    origin: .imported,
                    codexIDs: [codexID],
                    artifactIDs: [artifactID],
                    provenanceStatus: .verified
                )
            ),
            CatalogEventCase(
                eventType: "runescribe.exchange.bidirectional-established",
                payload: try DomainEventPayload(relationshipToken: relationshipToken)
            ),
            CatalogEventCase(
                eventType: "runescribe.presentation.observed",
                payload: try DomainEventPayload(
                    packageToken: packageToken,
                    codexIDs: [codexID],
                    artifactIDs: [artifactID],
                    provenanceStatus: .unsupported
                )
            ),
        ]
    }

    private func validSnapshot() throws -> ProgressionSnapshotDTO {
        let gate = try ProgressionCodexGateDTO(
            codexID: codexID,
            presentation: presentation,
            journeyOrder: 1,
            completedRuleCount: 0,
            requiredRuleCount: 1,
            progress: ProgressionNumericProgressDTO(current: 0, target: 5),
            components: [
                try ProgressionGateComponentDTO(
                    componentID: "rule.test.component.1",
                    label: "Create five ciphers",
                    current: 0,
                    target: 5,
                    isComplete: false
                ),
            ],
            unlockedAt: nil
        )
        let rewards = try ProgressionRewardSummaryDTO(
            codexIDs: [codexID],
            contentIDs: [artifactID],
            entitlementIDs: [unlockID],
            titleIDs: [titleID],
            crestIDs: [crestID]
        )
        let achievement = try ProgressionAchievementDTO(
            achievementID: achievementID,
            presentation: presentation,
            completedRuleCount: 1,
            requiredRuleCount: 1,
            progress: ProgressionNumericProgressDTO(current: 1, target: 1),
            completedAt: now,
            isHidden: false,
            localPointWeight: 10,
            rewards: rewards
        )
        let statistic = ProgressionStatisticDTO(
            statisticID: statisticID,
            presentation: presentation,
            codexID: codexID,
            value: 4
        )
        let ownership = try ProgressionOwnershipDTO(
            kind: .relic,
            reference: .artifact(artifactID),
            presentation: presentation,
            state: .owned,
            firstEncounteredAt: earlier,
            grantedAt: now,
            sourceRuleIDs: [ruleID],
            renderState: .genericFallback
        )
        let encounter = try ProgressionEncounterDTO(
            codexID: codexID,
            firstEncounteredAt: earlier,
            lastEncounteredAt: now,
            encounterCount: 2,
            provenanceStatus: .verified
        )
        let archive = try ProgressionArchiveEntryDTO(
            kind: .codex,
            reference: .codex(codexID),
            presentation: presentation,
            supportState: .known,
            ownershipState: .encountered,
            renderState: .genericFallback,
            firstEncounteredAt: earlier,
            lastEncounteredAt: now,
            encounterCount: 2,
            provenanceStatus: .verified
        )
        let title = try ProgressionTitleDTO(
            titleID: titleID,
            presentation: presentation,
            isOwned: true,
            isSelected: true
        )
        return try ProgressionSnapshotDTO(
            revision: 7,
            capturedAt: now,
            availability: .available,
            storeHealth: .loaded,
            catalogID: catalogID,
            catalogVersion: catalogVersion,
            codexGates: [gate],
            achievements: [achievement],
            statistics: [statistic],
            ownership: [ownership],
            encounters: [encounter],
            archive: [archive],
            titles: [title],
            selectedTitleID: titleID,
            pendingRevealCount: 1,
            nextReveal: validReveal(),
            entitlementIDs: [unlockID]
        )
    }

    private func baseSnapshot(
        statistics: [ProgressionStatisticDTO] = [],
        titles: [ProgressionTitleDTO] = [],
        selectedTitleID: TitleID? = nil,
        pendingRevealCount: UInt16 = 0,
        nextReveal: ProgressionRevealSummaryDTO? = nil
    ) throws -> ProgressionSnapshotDTO {
        try ProgressionSnapshotDTO(
            revision: 1,
            capturedAt: now,
            availability: .available,
            storeHealth: .loaded,
            catalogID: catalogID,
            catalogVersion: catalogVersion,
            statistics: statistics,
            titles: titles,
            selectedTitleID: selectedTitleID,
            pendingRevealCount: pendingRevealCount,
            nextReveal: nextReveal
        )
    }

    private func validReveal() throws -> ProgressionRevealSummaryDTO {
        try ProgressionRevealSummaryDTO(
            revealID: revealID,
            transactionID: transactionID,
            createdAt: now,
            state: .pending,
            tier: .artifact,
            rarity: .rare,
            primaryRewardID: .artifact(artifactID),
            primaryRewardPresentation: presentation,
            secondaryRewardIDs: [.artifact(secondaryArtifactID)],
            sourceAchievementIDs: [achievementID],
            sourceRuleIDs: [ruleID]
        )
    }

    private func validDiagnostics() throws -> ProgressionDiagnosticsSummaryDTO {
        try ProgressionDiagnosticsSummaryDTO(
            capturedAt: now,
            availability: .available,
            storeHealth: .loaded,
            catalogID: catalogID,
            catalogVersion: catalogVersion,
            stateNamespaceSchemaVersion: 1,
            logicalRecordSchemaVersion: 1,
            pendingOutboxCount: 2,
            recordCounts: [
                ProgressionDiagnosticRecordCountDTO(
                    category: .processedEvent,
                    count: 10
                ),
                ProgressionDiagnosticRecordCountDTO(category: .ownership, count: 3),
            ],
            hashes: [
                ProgressionDiagnosticHashDTO(
                    kind: .catalog,
                    digest: ProgressionSHA256Digest(
                        rawValue: String(repeating: "a", count: 64)
                    )!
                ),
            ],
            errors: [
                ProgressionDiagnosticErrorDTO(
                    category: .integrity,
                    count: 1,
                    mostRecentCode: ProgressionRejectionCode(
                        rawValue: "record.integrity-mismatch"
                    )
                ),
            ]
        )
    }

    private func maximumBoundedSnapshot() throws -> ProgressionSnapshotDTO {
        let maximumPresentation = try ProgressionPresentationDTO(
            displayName: String(
                repeating: "d",
                count: ProgressionPresentationDTO.maximumDisplayNameUTF8Count
            ),
            summary: String(
                repeating: "s",
                count: ProgressionPresentationDTO.maximumSummaryUTF8Count
            ),
            fallbackSystemImageName: String(
                repeating: "i",
                count: ProgressionPresentationDTO.maximumSystemImageNameUTF8Count
            )
        )
        let maximumRewards = try ProgressionRewardSummaryDTO(
            codexIDs: try identifiers(
                count: ProgressionRewardSummaryDTO.maximumRewardCount,
                prefix: "codex.max-codex.",
                make: CodexID.init(rawValue:)
            ),
            contentIDs: try identifiers(
                count: ProgressionRewardSummaryDTO.maximumRewardCount,
                prefix: "artifact.max-content.",
                make: ArtifactID.init(rawValue:)
            ),
            entitlementIDs: try identifiers(
                count: ProgressionRewardSummaryDTO.maximumRewardCount,
                prefix: "unlock.max-entitlement.",
                make: UnlockID.init(rawValue:)
            ),
            titleIDs: try identifiers(
                count: ProgressionRewardSummaryDTO.maximumRewardCount,
                prefix: "title.max-title.",
                make: TitleID.init(rawValue:)
            ),
            crestIDs: try identifiers(
                count: ProgressionRewardSummaryDTO.maximumRewardCount,
                prefix: "crest.max-crest.",
                make: CrestID.init(rawValue:)
            )
        )
        let maximumSourceRules: [RuleID] = try identifiers(
            count: ProgressionOwnershipDTO.maximumSourceRuleCount,
            prefix: "rule.max-source.",
            make: RuleID.init(rawValue:)
        )

        let gates = try (0 ..< ProgressionSnapshotDTO.maximumCodexGateCount).map {
            try ProgressionCodexGateDTO(
                codexID: CodexID(rawValue: boundedID(prefix: "codex.max.", index: $0))!,
                presentation: maximumPresentation,
                journeyOrder: UInt16($0),
                completedRuleCount: 0,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(current: 0, target: 1),
                components: [
                    try ProgressionGateComponentDTO(
                        componentID: "rule.max.\($0).component.1",
                        label: "Complete the requirement",
                        current: 0,
                        target: 1,
                        isComplete: false
                    ),
                ],
                unlockedAt: nil
            )
        }
        let achievements = try (0 ..< ProgressionSnapshotDTO.maximumAchievementCount).map {
            try ProgressionAchievementDTO(
                achievementID: AchievementID(
                    rawValue: boundedID(prefix: "achievement.max.", index: $0)
                )!,
                presentation: maximumPresentation,
                completedRuleCount: 1,
                requiredRuleCount: 1,
                progress: ProgressionNumericProgressDTO(current: 1, target: 1),
                completedAt: now,
                isHidden: false,
                localPointWeight: 100,
                rewards: maximumRewards
            )
        }
        let statistics = (0 ..< ProgressionSnapshotDTO.maximumStatisticCount).map {
            ProgressionStatisticDTO(
                statisticID: StatisticID(
                    rawValue: boundedID(prefix: "stat.max.", index: $0)
                )!,
                presentation: maximumPresentation,
                value: UInt64($0)
            )
        }
        let ownership = try (0 ..< ProgressionSnapshotDTO.maximumOwnershipCount).map {
            try ProgressionOwnershipDTO(
                kind: .relic,
                reference: .artifact(
                    ArtifactID(rawValue: boundedID(prefix: "relic.max.", index: $0))!
                ),
                presentation: maximumPresentation,
                state: .owned,
                grantedAt: now,
                sourceRuleIDs: maximumSourceRules,
                renderState: .genericFallback
            )
        }
        let encounters = try (0 ..< ProgressionSnapshotDTO.maximumEncounterCount).map {
            try ProgressionEncounterDTO(
                codexID: CodexID(
                    rawValue: boundedID(prefix: "codex.encounter.", index: $0)
                )!,
                firstEncounteredAt: earlier,
                lastEncounteredAt: now,
                encounterCount: 1,
                provenanceStatus: .verified
            )
        }
        let archive = try (0 ..< ProgressionSnapshotDTO.maximumArchiveCount).map {
            try ProgressionArchiveEntryDTO(
                kind: .seal,
                reference: .artifact(
                    ArtifactID(rawValue: boundedID(prefix: "seal.archive.", index: $0))!
                ),
                presentation: maximumPresentation,
                supportState: .unsupported,
                ownershipState: .encountered,
                renderState: .genericFallback,
                firstEncounteredAt: earlier,
                lastEncounteredAt: now,
                encounterCount: 1,
                provenanceStatus: .unsupported
            )
        }
        let titles = try (0 ..< ProgressionSnapshotDTO.maximumTitleCount).map {
            try ProgressionTitleDTO(
                titleID: TitleID(rawValue: boundedID(prefix: "title.max.", index: $0))!,
                presentation: maximumPresentation,
                isOwned: true,
                isSelected: false
            )
        }
        let entitlements: [UnlockID] = try identifiers(
            count: ProgressionSnapshotDTO.maximumEntitlementCount,
            prefix: "unlock.max-snapshot.",
            make: UnlockID.init(rawValue:)
        )

        return try ProgressionSnapshotDTO(
            revision: 1,
            capturedAt: now,
            availability: .available,
            storeHealth: .loaded,
            catalogID: catalogID,
            catalogVersion: catalogVersion,
            codexGates: gates,
            achievements: achievements,
            statistics: statistics,
            ownership: ownership,
            encounters: encounters,
            archive: archive,
            titles: titles,
            entitlementIDs: entitlements
        )
    }

    private func identifiers<ID>(
        count: Int,
        prefix: String,
        make: (String) -> ID?
    ) throws -> [ID] {
        try (0 ..< count).map {
            try XCTUnwrap(make(boundedID(prefix: prefix, index: $0)))
        }
    }

    private func boundedID(prefix: String, index: Int) -> String {
        let suffix = String(index)
        return prefix
            + String(
                repeating: "a",
                count: 96 - prefix.utf8.count - suffix.utf8.count
            )
            + suffix
    }

    private var eligibility: DomainEventEligibilityMetadata {
        DomainEventEligibilityMetadata(
            state: .eligible,
            reason: EligibilityReasonID(rawValue: "eligibility.progression-test")!
        )
    }

    private var presentation: ProgressionPresentationDTO {
        try! ProgressionPresentationDTO(
            displayName: "Test reward",
            summary: "A bounded presentation summary.",
            fallbackSystemImageName: "star.circle"
        )
    }

    private var genericPresentation: ProgressionPresentationDTO {
        try! ProgressionPresentationDTO(
            displayName: "Unknown content",
            summary: "This presentation is not supported.",
            fallbackSystemImageName: "questionmark.square.dashed"
        )
    }

    private var now: Date { Date(timeIntervalSince1970: 10_000) }
    private var earlier: Date { Date(timeIntervalSince1970: 9_000) }
    private var cipherToken: CipherToken {
        CipherToken(rawValue: String(repeating: "c", count: 32))!
    }
    private var messageToken: MessageToken {
        MessageToken(rawValue: String(repeating: "m", count: 32))!
    }
    private var packageToken: PackageToken {
        PackageToken(rawValue: String(repeating: "p", count: 32))!
    }
    private var relationshipToken: RelationshipToken {
        RelationshipToken(rawValue: String(repeating: "r", count: 32))!
    }
    private var catalogID: ProgressionCatalogID {
        ProgressionCatalogID(rawValue: "runescribe.progression.catalog")!
    }
    private var catalogVersion: ProgressionCatalogVersion {
        ProgressionCatalogVersion(rawValue: 1)!
    }
    private var codexID: CodexID { CodexID(rawValue: "codex.norse")! }
    private var artifactID: ArtifactID { ArtifactID(rawValue: "relic.test-primary")! }
    private var secondaryArtifactID: ArtifactID {
        ArtifactID(rawValue: "seal.test-secondary")!
    }
    private var achievementID: AchievementID {
        AchievementID(rawValue: "achievement.test")!
    }
    private var statisticID: StatisticID { StatisticID(rawValue: "stat.test")! }
    private var ruleID: RuleID { RuleID(rawValue: "rule.test")! }
    private var titleID: TitleID { TitleID(rawValue: "title.test")! }
    private var crestID: CrestID { CrestID(rawValue: "crest.test")! }
    private var unlockID: UnlockID { UnlockID(rawValue: "unlock.test")! }
    private var revealID: RevealID { RevealID(rawValue: "reveal.test")! }
    private var transactionID: GrantTransactionID {
        GrantTransactionID(rawValue: "grant.transaction-1")!
    }

    private func acceptGrantGroup(_: GrantGroupID) {}
    private func acceptGrantTransaction(_: GrantTransactionID) {}
    private func assertSendable<T: Sendable>(_: T.Type) {}
}
