import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeTestSupport
import Testing
@testable import RuneScribeProgressionModule

@Test
func durableServiceBootstrapsAnEmptyRuntimeOwnedNamespace() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: fixture.client
    )
    let metadata = try fixture.metadata(
        operation: "progression.state.stream",
        suffix: "bootstrap"
    )
    let stream = service.stateStream(metadata: metadata)
    var iterator = stream.makeAsyncIterator()
    let snapshot = await iterator.next()

    #expect(snapshot?.catalogVersion == fixture.bundle.catalog.catalogVersion)
    #expect(snapshot?.revision == 0)
    #expect(await fixture.client.recordCount() > 0)
    await service.shutdown()
}

@Test
func providerAvailabilityLifecycleProjectionIsExact() {
    let expectations: [(ModuleLifecycleState, ProgressionProviderAvailability)] = [
        (.registered, .unavailable),
        (.validated, .unavailable),
        (.eligible, .eligible),
        (.activating, .eligible),
        (.active, .active),
        (.stopping, .unavailable),
        (.stopped, .unavailable),
        (.failed, .failed),
    ]

    for (lifecycleState, expected) in expectations {
        #expect(
            ProgressionProviderAvailabilityProjection.availability(
                for: lifecycleState
            ) == expected
        )
    }
}

@Test
func runtimeAvailabilityRepublishesOnlyStateForOwnedBoundContent() async throws {
    let fixture = try ProgressionDurableFixture()
    let availabilityChannel = AsyncStream.makeStream(
        of: RuntimeAvailabilitySnapshot.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    let service = try await fixture.bootstrap(
        availabilitySnapshots: availabilityChannel.stream
    )

    for index in UInt32(1) ... 5 {
        guard case .applied = try await service.applyEvent(
            fixture.firstDeliveryEvent(
                index: index,
                occurredAt: Date(timeIntervalSince1970: 2_000_000_100 + Double(index))
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "availability-delivery-\(index)"
            )
        ) else {
            Issue.record("The fifth-delivery availability fixture did not apply.")
            return
        }
    }
    guard case .applied = try await service.applyEvent(
        fixture.codexPresentationEvent(
            index: 90_000,
            codexID: CodexID(rawValue: "codex.sunspire")!,
            occurredAt: Date(timeIntervalSince1970: 2_000_000_200)
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "availability-encounter"
        )
    ) else {
        Issue.record("The encountered-Codex availability fixture did not apply.")
        return
    }

    let before = try await fixture.snapshot(from: service, suffix: "availability-before")
    let durableRevision = before.revision
    #expect(fixture.ownership(.codex(CodexID(rawValue: "codex.moonleaf")!), in: before)?
        .providerAvailability == .unavailable)

    let probe = ProgressionAvailabilityStreamProbe()
    let stateTask = Task {
        for await snapshot in service.stateStream(metadata: try fixture.metadata(
            operation: "progression.state.stream",
            suffix: "availability-observer"
        )) {
            await probe.record(snapshot)
        }
    }
    let entitlementTask = Task {
        for await snapshot in service.entitlementStream(metadata: try fixture.metadata(
            operation: "progression.entitlements.stream",
            suffix: "availability-entitlements"
        )) {
            await probe.record(snapshot)
        }
    }
    #expect(await waitForAvailabilityProbe {
        await probe.hasInitialValues
    })
    let entitlementCountBefore = await probe.entitlementCount

    availabilityChannel.continuation.yield(try fixture.availabilitySnapshot(
        revision: 1,
        lifecycleByCodexID: [
            CodexID(rawValue: "codex.moonleaf")!: .active,
            CodexID(rawValue: "codex.sunspire")!: .active,
        ]
    ))
    #expect(await waitForAvailabilityProbe {
        await probe.latestState.flatMap {
            fixture.ownership(
                .codex(CodexID(rawValue: "codex.moonleaf")!),
                in: $0
            )
        }?.providerAvailability == .active
    })

    let active = try #require(await probe.latestState)
    #expect(active.revision == durableRevision)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "script.moonleaf")!),
        in: active
    )?.providerAvailability == .active)
    #expect(fixture.ownership(
        .artifact(ArtifactID(rawValue: "script.moonleaf")!),
        in: active
    )?.renderState == .providerAvailable)
    let lockedMoonleaf = try #require(fixture.ownership(
        .artifact(ArtifactID(rawValue: "frame.moonleaf.silvervine")!),
        in: active
    ))
    #expect(lockedMoonleaf.state == .locked)
    #expect(lockedMoonleaf.providerAvailability == .unavailable)
    #expect(lockedMoonleaf.renderState == .locked)
    let encounteredSunspire = try #require(fixture.ownership(
        .codex(CodexID(rawValue: "codex.sunspire")!),
        in: active
    ))
    #expect(encounteredSunspire.state == .encountered)
    #expect(encounteredSunspire.providerAvailability == .unavailable)
    #expect(encounteredSunspire.renderState == .genericFallback)

    availabilityChannel.continuation.yield(try fixture.availabilitySnapshot(
        revision: 2,
        lifecycleByCodexID: [
            CodexID(rawValue: "codex.moonleaf")!: .failed,
        ]
    ))
    #expect(await waitForAvailabilityProbe {
        await probe.latestState.flatMap {
            fixture.ownership(
                .codex(CodexID(rawValue: "codex.moonleaf")!),
                in: $0
            )
        }?.providerAvailability == .failed
    })
    let failed = try #require(await probe.latestState)
    #expect(failed.revision == durableRevision)
    #expect(fixture.ownership(
        .codex(CodexID(rawValue: "codex.moonleaf")!),
        in: failed
    )?.renderState == .providerFailed)
    for _ in 0 ..< 50 { await Task.yield() }
    #expect(await probe.entitlementCount == entitlementCountBefore)

    availabilityChannel.continuation.finish()
    stateTask.cancel()
    entitlementTask.cancel()
    await service.shutdown()
}

@Test
func echoSealEarnedBeforeItsCodexRemainsUnavailableUntilCodexOwnership() async throws {
    let fixture = try ProgressionDurableFixture()
    let availabilityChannel = AsyncStream.makeStream(
        of: RuntimeAvailabilitySnapshot.self,
        bufferingPolicy: .bufferingNewest(1)
    )
    let service = try await fixture.bootstrap(
        availabilitySnapshots: availabilityChannel.stream
    )
    let probe = ProgressionAvailabilityStreamProbe()
    let stateTask = Task {
        for await snapshot in service.stateStream(metadata: try fixture.metadata(
            operation: "progression.state.stream",
            suffix: "echo-preownership-observer"
        )) {
            await probe.record(snapshot)
        }
    }
    let moonleafID = CodexID(rawValue: "codex.moonleaf")!
    let echoID = ArtifactID(rawValue: "seal.moonleaf.echo-firefly")!
    availabilityChannel.continuation.yield(try fixture.availabilitySnapshot(
        revision: 1,
        lifecycleByCodexID: [
            CodexID(rawValue: "codex.norse")!: .active,
            moonleafID: .active,
        ]
    ))
    #expect(await waitForAvailabilityProbe {
        await probe.latestState.flatMap {
            fixture.norseOwnership(in: $0)
        }?.providerAvailability == .active
    })

    guard case .applied = try await service.applyEvent(
        fixture.codexPresentationEvent(
            index: 95_000,
            codexID: moonleafID,
            occurredAt: Date(timeIntervalSince1970: 2_000_008_100)
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "echo-preownership-encounter"
        )
    ) else {
        Issue.record("The pre-ownership Moonleaf encounter did not apply.")
        return
    }
    #expect(await waitForAvailabilityProbe {
        await probe.latestState.flatMap {
            fixture.ownership(.artifact(echoID), in: $0)
        }?.state == .owned
    })
    let beforeOwnership = try #require(await probe.latestState)
    let earnedEcho = try #require(fixture.ownership(
        .artifact(echoID),
        in: beforeOwnership
    ))
    #expect(earnedEcho.state == .owned)
    #expect(earnedEcho.providerAvailability == .unavailable)
    #expect(earnedEcho.renderState == .genericFallback)
    #expect(fixture.ownership(.codex(moonleafID), in: beforeOwnership)?.state != .owned)

    for index in UInt32(191) ... 195 {
        guard case .applied = try await service.applyEvent(
            fixture.firstDeliveryEvent(
                index: index,
                occurredAt: Date(
                    timeIntervalSince1970: 2_000_008_200 + Double(index)
                )
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "echo-preownership-delivery-\(index)"
            )
        ) else {
            Issue.record("The Moonleaf ownership delivery did not apply.")
            return
        }
    }
    #expect(await waitForAvailabilityProbe {
        await probe.latestState.flatMap {
            fixture.ownership(.artifact(echoID), in: $0)
        }?.providerAvailability == .active
    })
    let afterOwnership = try #require(await probe.latestState)
    let usableEcho = try #require(fixture.ownership(.artifact(echoID), in: afterOwnership))
    #expect(fixture.ownership(.codex(moonleafID), in: afterOwnership)?.state == .owned)
    #expect(usableEcho.state == .owned)
    #expect(usableEcho.providerAvailability == .active)
    #expect(usableEcho.renderState == .providerAvailable)
    #expect(usableEcho.grantedAt == earnedEcho.grantedAt)

    availabilityChannel.continuation.finish()
    stateTask.cancel()
    await service.shutdown()
}

@Test
func preownershipIncomingProgressCompletesInTheMoonleafOwnershipTransaction() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let moonleafID = CodexID(rawValue: "codex.moonleaf")!
    let moonwellID = ArtifactID(rawValue: "seal.moonleaf.moonwell")!
    let incomingRuleID = RuleID(rawValue: "rule.codex.moonleaf.incoming-five")!
    let fiveCirclesID = AchievementID(rawValue: "achievement.five-circles")!

    for index in UInt32(201) ... 205 {
        guard case .applied = try await service.applyEvent(
            fixture.messageDecodedEvent(
                index: index,
                occurredAt: Date(
                    timeIntervalSince1970: 2_000_008_400 + Double(index)
                ),
                codexID: moonleafID
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "incoming-preownership-\(index)"
            )
        ) else {
            Issue.record("The pre-ownership Moonleaf incoming event did not apply.")
            return
        }
    }
    let accumulated = try await fixture.snapshot(
        from: service,
        suffix: "incoming-preownership-accumulated"
    )
    #expect(accumulated.statistics.first {
        $0.statisticID.rawValue == "stat.codex.incoming-decode.unique-package"
            && $0.codexID == moonleafID
    }?.value == 5)
    #expect(fixture.ownership(.codex(moonleafID), in: accumulated)?.state == .locked)
    #expect(fixture.ownership(.artifact(moonwellID), in: accumulated)?.state == .locked)

    for index in UInt32(206) ... 209 {
        guard case .applied = try await service.applyEvent(
            fixture.firstDeliveryEvent(
                index: index,
                occurredAt: Date(
                    timeIntervalSince1970: 2_000_008_600 + Double(index)
                )
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "incoming-ownership-\(index)"
            )
        ) else {
            Issue.record("A pre-threshold ownership event did not apply.")
            return
        }
    }
    let beforeOwnership = try await fixture.snapshot(
        from: service,
        suffix: "incoming-before-ownership"
    )
    #expect(fixture.ownership(.codex(moonleafID), in: beforeOwnership)?.state == .locked)
    #expect(fixture.ownership(.artifact(moonwellID), in: beforeOwnership)?.state == .locked)

    let ownershipResult = try await service.applyEvent(
        fixture.firstDeliveryEvent(
            index: 210,
            occurredAt: Date(timeIntervalSince1970: 2_000_008_900)
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "incoming-ownership-threshold"
        )
    )
    guard case let .applied(_, _, delta) = ownershipResult else {
        Issue.record("The Moonleaf ownership threshold did not apply.")
        return
    }
    #expect(delta.completedAchievementCount >= 1)
    #expect(delta.completedMilestoneCount >= 2)
    let afterOwnership = try await fixture.snapshot(
        from: service,
        suffix: "incoming-after-ownership"
    )
    #expect(fixture.ownership(.codex(moonleafID), in: afterOwnership)?.state == .owned)
    #expect(fixture.ownership(.artifact(moonwellID), in: afterOwnership)?.state == .owned)

    let generation = try await fixture.client.activeMetadata().activeGeneration
    let combinedReveal = try #require(
        try await fixture.client.queuedRevealValues(generation: generation).first {
            $0.sourceRuleIDs.contains(incomingRuleID)
        }
    )
    #expect(combinedReveal.sourceAchievementIDs.contains(fiveCirclesID))
    #expect(combinedReveal.primaryContentID.rawValue == "codex.moonleaf")
    #expect(combinedReveal.secondaryContentIDs.contains(
        ProgressionContentID(rawValue: moonwellID.rawValue)!
    ))
    await service.shutdown()
}

@Test
func ambiguousEventCommitReconcilesOnRetryAndAllowsTheNextEvent() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let first = try fixture.cipherEvent(index: 1)
    await fixture.store.injectFault(at: .afterTransactionCommit)

    #expect(try await service.applyEvent(
        first,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "fault-one")
    ) == .deferredStoreUnavailable)
    #expect(try await service.applyEvent(
        first,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "retry-one")
    ) == .duplicate)

    let afterRetry = try await fixture.snapshot(from: service, suffix: "after-retry")
    #expect(afterRetry.revision == 1)
    let second = try fixture.cipherEvent(index: 2)
    guard case .applied = try await service.applyEvent(
        second,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "event-two")
    ) else {
        Issue.record("The event after an ambiguous committed transaction did not apply.")
        return
    }
    #expect(try await fixture.snapshot(from: service, suffix: "after-two").revision == 2)
    await service.shutdown()
}

@Test
func healthyRebuildCanRunTwiceAndRelaunchWithoutChangingDomainState() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let before = try await fixture.snapshot(from: service, suffix: "before-rebuild")

    let first = try await service.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "rebuild-one")
    )
    let second = try await service.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "rebuild-two")
    )
    #expect(first.revision == 1)
    #expect(second.revision == 2)
    await service.shutdown()

    let relaunched = try await fixture.bootstrap()
    let after = try await fixture.snapshot(from: relaunched, suffix: "after-rebuild")
    #expect(after.revision == 2)
    #expect(after.ownership == before.ownership)
    #expect(after.achievements == before.achievements)
    #expect(after.statistics == before.statistics)
    await relaunched.shutdown()
}

@Test
func corruptProjectionActivatesRecoveryRebuildsAndRemainsUsableAfterRelaunch() async throws {
    let fixture = try ProgressionDurableFixture()
    let initial = try await fixture.bootstrap()
    await initial.shutdown()
    try await fixture.client.corruptProjectionShard(category: .statisticCounter, shardIndex: 0)

    let degraded = try await fixture.bootstrap()
    let diagnostics = try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(operation: "progression.diagnostics.summary", suffix: "degraded")
    )
    #expect(diagnostics.availability == .degraded)
    #expect(try await degraded.applyEvent(
        fixture.cipherEvent(index: 3),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "blocked")
    ) == .deferredStoreUnavailable)

    let rebuilt = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "corrupt-rebuild")
    )
    #expect(rebuilt.revision == 1)
    await degraded.shutdown()

    let relaunched = try await fixture.bootstrap()
    guard case .applied = try await relaunched.applyEvent(
        fixture.cipherEvent(index: 3),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "after-recovery")
    ) else {
        Issue.record("Recovered storage did not accept a new valid event.")
        return
    }
    let postRecovery = try await relaunched.diagnosticsSummary(
        metadata: fixture.metadata(operation: "progression.diagnostics.summary", suffix: "post-recovery")
    )
    #expect(postRecovery.availability == .degraded)
    await relaunched.shutdown()

    try await fixture.client.corruptProjectionShard(category: .statisticCounter, shardIndex: 0)
    let degradedAgain = try await fixture.bootstrap()
    _ = try await degradedAgain.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "corrupt-rebuild-two"
        )
    )
    await degradedAgain.shutdown()
    let twiceRecovered = try await fixture.bootstrap()
    guard case .applied = try await twiceRecovered.applyEvent(
        fixture.cipherEvent(index: 4),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "after-recovery-two")
    ) else {
        Issue.record("The second recovery left the service unusable.")
        return
    }
    await twiceRecovered.shutdown()
    let upgradedAfterRecovery = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.additiveNextVersionBundle(),
        stateClient: fixture.client
    )
    #expect(try await fixture.snapshot(
        from: upgradedAfterRecovery,
        suffix: "upgrade-after-recovery"
    ).catalogVersion == ProgressionCatalogVersion(rawValue: 4))
    await upgradedAfterRecovery.shutdown()
}

@Test
func bootstrapGrantTimestampSurvivesLaterGrantShardMutationAndRelaunch() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let initial = try await fixture.snapshot(from: service, suffix: "initial-time")
    let initialNorseTime = try #require(fixture.norseOwnership(in: initial)?.grantedAt)
    let later = Date(timeIntervalSince1970: 2_000_000_500)
    fixture.clock.set(later)

    guard case .applied = try await service.applyEvent(
        fixture.messageEncodedEvent(index: 1, occurredAt: later),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "later-grant",
            timestamp: later
        )
    ) else {
        Issue.record("The single-event achievement grant did not apply.")
        return
    }
    await service.shutdown()

    let relaunched = try await fixture.bootstrap()
    let after = try await fixture.snapshot(from: relaunched, suffix: "after-later-grant")
    #expect(fixture.norseOwnership(in: after)?.grantedAt == initialNorseTime)
    await relaunched.shutdown()
}

@Test
func archivePreservesPerArtifactHistoryOwnedFirstAndDeterministicProvenance() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let firstAt = Date(timeIntervalSince1970: 2_000_001_000)
    let laterAt = Date(timeIntervalSince1970: 2_000_001_500)
    let firstArtifact = ArtifactID(rawValue: "relic.norse.stormforged-stele")!
    let laterArtifact = ArtifactID(rawValue: "relic.norse.dragonwood-plaque")!

    for event in try [
        fixture.presentationEvent(
            index: 1,
            occurredAt: firstAt,
            artifacts: [firstArtifact],
            provenance: .verified
        ),
        fixture.presentationEvent(
            index: 2,
            occurredAt: laterAt,
            artifacts: [firstArtifact, laterArtifact],
            provenance: .unverified
        ),
        fixture.presentationEvent(
            index: 3,
            occurredAt: laterAt,
            artifacts: [laterArtifact],
            provenance: .invalid
        ),
    ] {
        guard case .applied = try await service.applyEvent(
            event,
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: event.eventID.rawValue.uuidString.lowercased()
            )
        ) else {
            Issue.record("A valid Archive observation did not apply.")
            return
        }
    }
    let before = try await fixture.snapshot(from: service, suffix: "archive-before")
    let codex = try #require(before.archive.first {
        $0.reference == .codex(CodexID(rawValue: "codex.norse")!)
    })
    let first = try #require(before.archive.first { $0.reference == .artifact(firstArtifact) })
    let later = try #require(before.archive.first { $0.reference == .artifact(laterArtifact) })
    #expect(codex.ownershipState == .owned)
    #expect(codex.firstEncounteredAt == firstAt)
    #expect(codex.lastEncounteredAt == laterAt)
    #expect(codex.encounterCount == 3)
    #expect(codex.provenanceStatus == .invalid)
    #expect(first.firstEncounteredAt == firstAt)
    #expect(first.lastEncounteredAt == laterAt)
    #expect(first.encounterCount == 2)
    #expect(first.provenanceStatus == .unverified)
    #expect(later.firstEncounteredAt == laterAt)
    #expect(later.lastEncounteredAt == laterAt)
    #expect(later.encounterCount == 2)
    #expect(later.provenanceStatus == .invalid)

    _ = try await service.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "archive-rebuild")
    )
    await service.shutdown()
    let relaunched = try await fixture.bootstrap()
    #expect(try await fixture.snapshot(from: relaunched, suffix: "archive-after").archive == before.archive)
    await relaunched.shutdown()
}

@Test
func artifactFreePresentationUsesStableOptionalSemanticSentinel() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let first = try fixture.presentationEvent(
        index: 40,
        semanticIndex: 40,
        occurredAt: Date(timeIntervalSince1970: 2_000_002_000),
        artifacts: [],
        provenance: .verified
    )
    let semanticallySame = try fixture.presentationEvent(
        index: 41,
        semanticIndex: 40,
        occurredAt: Date(timeIntervalSince1970: 2_000_002_100),
        artifacts: [],
        provenance: .verified
    )
    guard case .applied = try await service.applyEvent(
        first,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "empty-artifact-first")
    ) else {
        Issue.record("Artifact-free presentation was rejected.")
        return
    }
    #expect(try await service.applyEvent(
        semanticallySame,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "empty-artifact-dupe")
    ) == .duplicate)
    let withArtifact = try fixture.presentationEvent(
        index: 42,
        semanticIndex: 40,
        occurredAt: Date(timeIntervalSince1970: 2_000_002_200),
        artifacts: [ArtifactID(rawValue: "relic.norse.stormforged-stele")!],
        provenance: .verified
    )
    guard case .applied = try await service.applyEvent(
        withArtifact,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "artifact-present")
    ) else {
        Issue.record("The optional-field sentinel collided with an artifact-present event.")
        return
    }
    await service.shutdown()
}

@Test
func revealFIFOAcknowledgementSurvivesRelaunchAndRebuildWithoutRepeating() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.messageEncodedEvent(
            index: 7,
            occurredAt: Date(timeIntervalSince1970: 2_000_003_000)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "reveal-one")
    ), case .applied = try await service.applyEvent(
        fixture.bidirectionalEvent(
            index: 8,
            occurredAt: Date(timeIntervalSince1970: 2_000_003_100)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "reveal-two")
    ) else {
        Issue.record("The reveal-producing events did not apply.")
        return
    }
    let queued = try await fixture.snapshot(from: service, suffix: "reveal-queued")
    #expect(queued.pendingRevealCount == 2)
    let firstRevealID = try #require(queued.nextReveal?.revealID)
    let acknowledgementMetadata = try fixture.metadata(
        operation: "progression.reveal.acknowledge",
        suffix: "ack-one",
        timestamp: Date(timeIntervalSince1970: 2_000_003_200)
    )
    try await fixture.markPresented(
        firstRevealID,
        using: service,
        suffix: "ack-one",
        timestamp: Date(timeIntervalSince1970: 2_000_003_200)
    )
    try await service.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: firstRevealID),
        metadata: acknowledgementMetadata
    )
    try await service.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: firstRevealID),
        metadata: acknowledgementMetadata
    )
    let afterAck = try await fixture.snapshot(from: service, suffix: "reveal-after-ack")
    #expect(afterAck.pendingRevealCount == 1)
    let secondRevealID = try #require(afterAck.nextReveal?.revealID)
    #expect(secondRevealID != firstRevealID)
    await service.shutdown()

    let relaunched = try await fixture.bootstrap()
    let afterRelaunch = try await fixture.snapshot(from: relaunched, suffix: "reveal-relaunch")
    #expect(afterRelaunch.pendingRevealCount == 1)
    #expect(afterRelaunch.nextReveal?.revealID == secondRevealID)
    _ = try await relaunched.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "reveal-rebuild",
            timestamp: Date(timeIntervalSince1970: 2_000_003_300)
        )
    )
    let afterRebuild = try await fixture.snapshot(from: relaunched, suffix: "reveal-after-rebuild")
    #expect(afterRebuild.pendingRevealCount == 1)
    #expect(afterRebuild.nextReveal?.revealID == secondRevealID)
    try await fixture.markPresented(
        secondRevealID,
        using: relaunched,
        suffix: "ack-two",
        timestamp: Date(timeIntervalSince1970: 2_000_003_400)
    )
    try await relaunched.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: secondRevealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "ack-two",
            timestamp: Date(timeIntervalSince1970: 2_000_003_400)
        )
    )
    #expect(try await fixture.snapshot(from: relaunched, suffix: "reveal-empty").pendingRevealCount == 0)
    await relaunched.shutdown()
}

@Test
func revealPresentationIsHeadOnlyIdempotentAndSurvivesRelaunchRebuildAndUpgrade() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.messageEncodedEvent(
            index: 180,
            occurredAt: Date(timeIntervalSince1970: 2_000_007_000)
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "present-source-one"
        )
    ), case .applied = try await service.applyEvent(
        fixture.bidirectionalEvent(
            index: 181,
            occurredAt: Date(timeIntervalSince1970: 2_000_007_100)
        ),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "present-source-two"
        )
    ) else {
        Issue.record("The presentation fixture did not create two reveals.")
        return
    }
    let queued = try await fixture.snapshot(from: service, suffix: "present-queued")
    let firstRevealID = try #require(queued.nextReveal?.revealID)
    let queueRecords = try await fixture.client.queuedRevealValues(
        generation: try await fixture.client.activeMetadata().activeGeneration
    )
    let secondRevealID = try #require(queueRecords.first {
        $0.revealID != firstRevealID
    }?.revealID)

    do {
        try await service.acknowledgeReveal(
            AcknowledgeProgressionRevealCommand(revealID: firstRevealID),
            metadata: fixture.metadata(
                operation: "progression.reveal.acknowledge",
                suffix: "present-queued-ack",
                timestamp: Date(timeIntervalSince1970: 2_000_007_150)
            )
        )
        Issue.record("A queued reveal was acknowledged before presentation.")
    } catch {
        // Acknowledgement is permitted only after the durable presented transition.
    }
    do {
        try await fixture.markPresented(
            secondRevealID,
            using: service,
            suffix: "present-non-head",
            timestamp: Date(timeIntervalSince1970: 2_000_007_175)
        )
        Issue.record("A non-head reveal was marked presented.")
    } catch {
        // FIFO presentation is head-only.
    }

    let presentationMetadata = try fixture.metadata(
        operation: "progression.reveal.mark-presented",
        suffix: "present-head",
        timestamp: Date(timeIntervalSince1970: 2_000_007_200)
    )
    let presentationCommand = MarkProgressionRevealPresentedCommand(
        revealID: firstRevealID
    )
    try await service.markRevealPresented(
        presentationCommand,
        metadata: presentationMetadata
    )
    let presented = try await fixture.snapshot(from: service, suffix: "presented")
    #expect(presented.nextReveal?.state == .presented)
    let presentedRevision = presented.revision
    try await service.markRevealPresented(
        presentationCommand,
        metadata: presentationMetadata
    )
    #expect(try await fixture.snapshot(
        from: service,
        suffix: "presented-retry"
    ).revision == presentedRevision)
    do {
        try await service.markRevealPresented(
            MarkProgressionRevealPresentedCommand(revealID: secondRevealID),
            metadata: presentationMetadata
        )
        Issue.record("A reused presentation operation accepted a different command.")
    } catch {
        // The operation receipt binds the exact command digest.
    }
    await service.shutdown()

    let relaunched = try await fixture.bootstrap()
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "presented-relaunch"
    ).nextReveal?.state == .presented)
    _ = try await relaunched.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(
                uuidString: "78000000-0000-0000-0000-000000000001"
            )!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "presented-rebuild",
            timestamp: Date(timeIntervalSince1970: 2_000_007_300)
        )
    )
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "presented-after-rebuild"
    ).nextReveal?.state == .presented)
    await relaunched.shutdown()

    let upgraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.additiveNextVersionBundle(),
        stateClient: fixture.client
    )
    #expect(try await fixture.snapshot(
        from: upgraded,
        suffix: "presented-after-upgrade"
    ).nextReveal?.state == .presented)
    try await upgraded.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: firstRevealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "presented-final-ack",
            timestamp: Date(timeIntervalSince1970: 2_000_007_400)
        )
    )
    let afterAck = try await fixture.snapshot(from: upgraded, suffix: "presented-after-ack")
    #expect(afterAck.pendingRevealCount == 1)
    #expect(afterAck.nextReveal?.revealID == secondRevealID)
    #expect(afterAck.nextReveal?.state == .pending)
    await upgraded.shutdown()
}

@Test
func pendingRevealSurvivesRecoveryFromACorruptGrantShard() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let event = try fixture.messageEncodedEvent(
        index: 146,
        occurredAt: Date(timeIntervalSince1970: 2_000_003_500)
    )
    guard case .applied = try await service.applyEvent(
        event,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "pending-derived-source"
        )
    ) else {
        Issue.record("The pending-reveal recovery fixture did not apply.")
        return
    }
    let before = try await fixture.snapshot(from: service, suffix: "pending-derived-before")
    let revealID = try #require(before.nextReveal?.revealID)
    #expect(before.pendingRevealCount == 1)
    await service.shutdown()
    try await fixture.client.corruptProjectionShard(category: .grant, shardIndex: 0)

    let degraded = try await fixture.bootstrap()
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(
            operation: "progression.diagnostics.summary",
            suffix: "pending-derived-degraded"
        )
    ).availability == .degraded)
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "78000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "pending-derived-rebuild"
        )
    )
    let recovered = try await fixture.snapshot(from: degraded, suffix: "pending-derived-after")
    #expect(recovered.pendingRevealCount == 1)
    #expect(recovered.nextReveal?.revealID == revealID)
    await degraded.shutdown()

    let relaunched = try await fixture.bootstrap()
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "pending-derived-relaunch"
    ).nextReveal?.revealID == revealID)
    #expect(try await relaunched.applyEvent(
        event,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "pending-derived-duplicate"
        )
    ) == .duplicate)
    await relaunched.shutdown()
}

@Test
func acknowledgedRevealSurvivesRecoveryFromACorruptCompletionShard() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let event = try fixture.messageEncodedEvent(
        index: 147,
        occurredAt: Date(timeIntervalSince1970: 2_000_003_600)
    )
    guard case .applied = try await service.applyEvent(
        event,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "ack-derived-source"
        )
    ) else {
        Issue.record("The acknowledged-reveal recovery fixture did not apply.")
        return
    }
    let revealID = try #require(try await fixture.snapshot(
        from: service,
        suffix: "ack-derived-head"
    ).nextReveal?.revealID)
    try await fixture.markPresented(
        revealID,
        using: service,
        suffix: "ack-derived-ack",
        timestamp: Date(timeIntervalSince1970: 2_000_003_700)
    )
    try await service.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "ack-derived-ack",
            timestamp: Date(timeIntervalSince1970: 2_000_003_700)
        )
    )
    #expect(try await fixture.snapshot(
        from: service,
        suffix: "ack-derived-empty"
    ).pendingRevealCount == 0)
    await service.shutdown()
    try await fixture.client.corruptProjectionShard(
        category: .achievementCompletion,
        shardIndex: 0
    )

    let degraded = try await fixture.bootstrap()
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "78000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "ack-derived-rebuild",
            timestamp: Date(timeIntervalSince1970: 2_000_003_800)
        )
    )
    #expect(try await fixture.snapshot(
        from: degraded,
        suffix: "ack-derived-after"
    ).pendingRevealCount == 0)
    await degraded.shutdown()

    let relaunched = try await fixture.bootstrap()
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "ack-derived-relaunch"
    ).pendingRevealCount == 0)
    #expect(try await relaunched.applyEvent(
        event,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "ack-derived-duplicate"
        )
    ) == .duplicate)
    await relaunched.shutdown()
}

@Test
func additiveCatalogUpgradeResumesAfterFaultGrantsNewContentAndRejectsDowngrade() async throws {
    let fixture = try ProgressionDurableFixture()
    let versionTwo = try await fixture.bootstrap()
    await versionTwo.shutdown()
    let nextVersionBundle = fixture.additiveNextVersionBundle()
    await fixture.store.injectFault(at: .afterTransactionCommit)
    do {
        _ = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
            catalogBundle: nextVersionBundle,
            stateClient: fixture.client
        )
        Issue.record("Faulted catalog upgrade unexpectedly completed activation.")
    } catch {
        // Relaunch below must resume the byte-identical staged upgrade.
    }

    let upgraded: RuneScribeProgressionServiceActor
    do {
        upgraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
            catalogBundle: nextVersionBundle,
            stateClient: fixture.client
        )
    } catch {
        Issue.record("The additive catalog upgrade failed: \(error)")
        throw error
    }
    let upgradedSnapshot = try await fixture.snapshot(from: upgraded, suffix: "upgrade-next")
    #expect(upgradedSnapshot.catalogVersion == ProgressionCatalogVersion(rawValue: 4))
    let addedTitle = TitleID(rawValue: "title.upgrade.wayfinder")!
    #expect(upgradedSnapshot.ownership.contains {
        $0.reference == .title(addedTitle) && $0.state == .owned
    })
    let immediate = try fixture.cipherEvent(index: 90)
    guard case .applied = try await upgraded.applyEvent(
        immediate,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "upgrade-immediate")
    ) else {
        Issue.record("The first event after catalog upgrade hit a stale persistence anchor.")
        return
    }
    await upgraded.shutdown()

    let relaunched = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: nextVersionBundle,
        stateClient: fixture.client
    )
    #expect(try await relaunched.applyEvent(
        immediate,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "upgrade-replay")
    ) == .duplicate)
    await relaunched.shutdown()

    do {
        _ = try await fixture.bootstrap()
        Issue.record("A newer namespace was opened with the prior catalog.")
    } catch {
        // Downgrade rejection is the expected fail-closed behavior.
    }
}

@Test
func olderCorruptProjectionActivatesWithAdditiveCatalogAndRebuildsToNextVersion() async throws {
    let fixture = try ProgressionDurableFixture()
    let versionTwo = try await fixture.bootstrap()
    guard case .applied = try await versionTwo.applyEvent(
        fixture.cipherEvent(index: 151),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "v2-q-source")
    ) else {
        Issue.record("The v2 recovery source event did not apply.")
        return
    }
    await versionTwo.shutdown()
    try await fixture.client.corruptProjectionShard(
        category: .statisticCounter,
        shardIndex: 0
    )

    let nextVersionBundle = fixture.additiveNextVersionBundle()
    let degraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: nextVersionBundle,
        stateClient: fixture.client
    )
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(
            operation: "progression.diagnostics.summary",
            suffix: "v3-q-degraded"
        )
    ).availability == .degraded)
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "v2-q-direct-v3"
        )
    )
    #expect(try await fixture.snapshot(
        from: degraded,
        suffix: "v2-q-v3-promoted"
    ).catalogVersion == ProgressionCatalogVersion(rawValue: 4))
    await degraded.shutdown()

    let relaunched = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: nextVersionBundle,
        stateClient: fixture.client
    )
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "v2-q-v3-relaunch"
    ).catalogVersion == ProgressionCatalogVersion(rawValue: 4))
    await relaunched.shutdown()
}

@Test
func appliedOrderCorruptionRebuildsFromProcessedEventAndPreservesReplayIdentity() async throws {
    let fixture = try ProgressionDurableFixture()
    let event = try fixture.cipherEvent(index: 121)
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        event,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "order-source")
    ) else {
        Issue.record("The source event did not apply.")
        return
    }
    await service.shutdown()
    try await fixture.client.corruptAndDiscoverAppliedOrder(revision: 1)

    let degraded = try await fixture.bootstrap()
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(operation: "progression.diagnostics.summary", suffix: "order-q")
    ).availability == .degraded)
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "71000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "order-repair")
    )
    #expect(try await degraded.applyEvent(
        event,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "order-replay")
    ) == .duplicate)
    await degraded.shutdown()
}

@Test
func storageValidConflictingOrderUsesTheCommittedProcessedEnvelope() async throws {
    let fixture = try ProgressionDurableFixture()
    let canonical = try fixture.cipherEvent(index: 152)
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        canonical,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "order-conflict-source"
        )
    ) else {
        Issue.record("The order conflict source did not apply.")
        return
    }
    await service.shutdown()
    try await fixture.client.rewriteAppliedOrder(
        revision: 1,
        envelope: fixture.cipherEvent(index: 153)
    )

    let relaunched = try await fixture.bootstrap()
    _ = try await relaunched.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "71000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "order-conflict-rebuild"
        )
    )
    #expect(try await relaunched.applyEvent(
        canonical,
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "order-conflict-replay"
        )
    ) == .duplicate)
    await relaunched.shutdown()
}

@Test
func additiveUpgradeRepairsAPreviouslyDiscoveredAppliedOrderQuarantine() async throws {
    let fixture = try ProgressionDurableFixture()
    let event = try fixture.cipherEvent(index: 142)
    let versionTwo = try await fixture.bootstrap()
    guard case .applied = try await versionTwo.applyEvent(
        event,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "v2-order-source")
    ) else {
        Issue.record("The v2 repair source event did not apply.")
        return
    }
    await versionTwo.shutdown()
    try await fixture.client.corruptAndDiscoverAppliedOrder(revision: 1)

    let upgraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.additiveNextVersionBundle(),
        stateClient: fixture.client
    )
    #expect(try await fixture.snapshot(
        from: upgraded,
        suffix: "v3-order-repaired"
    ).catalogVersion == ProgressionCatalogVersion(rawValue: 4))
    #expect(try await upgraded.applyEvent(
        event,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "v3-order-replay")
    ) == .duplicate)
    await upgraded.shutdown()
}

@Test
func forgedAcknowledgementReferenceBlocksRebuildAndDirectUpgradePromotion() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.messageEncodedEvent(
            index: 143,
            occurredAt: Date(timeIntervalSince1970: 1_999_999_800)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "ack-reference-source")
    ) else {
        Issue.record("The acknowledgement reference fixture did not unlock a reveal.")
        return
    }
    let revealID = try #require(try await fixture.snapshot(
        from: service,
        suffix: "ack-reference-head"
    ).nextReveal?.revealID)
    try await fixture.markPresented(
        revealID,
        using: service,
        suffix: "ack-reference-ack",
        timestamp: Date(timeIntervalSince1970: 2_000_000_000)
    )
    try await service.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "ack-reference-ack"
        )
    )
    let before = try await fixture.client.activeMetadata()
    await service.shutdown()
    try await fixture.client.rewriteAcknowledgementWithUnknownPrimary()

    let degradedV3 = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.additiveNextVersionBundle(),
        stateClient: fixture.client
    )
    #expect(try await degradedV3.diagnosticsSummary(
        metadata: fixture.metadata(
            operation: "progression.diagnostics.summary",
            suffix: "ack-reference-v3-degraded"
        )
    ).availability == .degraded)
    do {
        _ = try await degradedV3.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "77000000-0000-0000-0000-000000000002")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "ack-reference-v3-rebuild"
            )
        )
        Issue.record("A forged acknowledgement permitted direct v3 promotion.")
    } catch {
        // Irreconstructible acknowledgement evidence keeps recovery fail closed.
    }
    await degradedV3.shutdown()
    let afterUpgradeAttempt = try await fixture.client.activeMetadata()
    #expect(afterUpgradeAttempt.activeGeneration == before.activeGeneration)
    #expect(afterUpgradeAttempt.catalogVersion == before.catalogVersion)

    let degraded = try await fixture.bootstrap()
    do {
        _ = try await degraded.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "77000000-0000-0000-0000-000000000001")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "ack-reference-rebuild"
            )
        )
        Issue.record("Recovery promoted after acknowledgement evidence was quarantined.")
    } catch {
        // The active metadata anchor must remain unchanged.
    }
    let afterRebuildAttempt = try await fixture.client.activeMetadata()
    #expect(afterRebuildAttempt.activeGeneration == before.activeGeneration)
    #expect(afterRebuildAttempt.revision == before.revision)
    await degraded.shutdown()
}

@Test
func additiveUpgradeRefusesABrokenStoredGrantOwnershipLink() async throws {
    let fixture = try ProgressionDurableFixture()
    let versionTwo = try await fixture.bootstrap()
    guard case .applied = try await versionTwo.applyEvent(
        fixture.messageEncodedEvent(
            index: 144,
            occurredAt: Date(timeIntervalSince1970: 1_999_999_700)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "upgrade-link-source")
    ) else {
        Issue.record("The broken-link fixture did not earn a grant.")
        return
    }
    let before = try await fixture.client.activeMetadata()
    await versionTwo.shutdown()
    try await fixture.client.removeOneEarnedGrantWithoutUpdatingOwnership()

    let degraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.additiveNextVersionBundle(),
        stateClient: fixture.client
    )
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(
            operation: "progression.diagnostics.summary",
            suffix: "upgrade-link-degraded"
        )
    ).availability == .degraded)
    await degraded.shutdown()
    let after = try await fixture.client.activeMetadata()
    #expect(after.activeGeneration == before.activeGeneration)
    #expect(after.catalogVersion == before.catalogVersion)
    #expect(after.revision == before.revision)
}

@Test
func irreconstructibleTerminalEventCorruptionRefusesPromotionWithoutCountDrift() async throws {
    let fixture = try ProgressionDurableFixture()
    let event = try fixture.unknownEvent(index: 122)
    let service = try await fixture.bootstrap()
    guard case .rejectedPermanent = try await service.applyEvent(
        event,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "terminal-source")
    ) else {
        Issue.record("The unsupported event was not journaled as terminal.")
        return
    }
    let before = try await fixture.client.activeMetadata()
    await service.shutdown()
    try await fixture.client.corruptAndDiscoverProcessedEvent(event.eventID)

    let degraded = try await fixture.bootstrap()
    do {
        _ = try await degraded.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "72000000-0000-0000-0000-000000000001")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "terminal-refuse"
            )
        )
        Issue.record("Recovery promoted without irreconstructible terminal evidence.")
    } catch {
        // Refusal is required because terminal EventID semantics cannot be reconstructed.
    }
    let after = try await fixture.client.activeMetadata()
    #expect(after.activeGeneration == before.activeGeneration)
    #expect(after.processedEventCount == before.processedEventCount)
    #expect(after.revision == before.revision)
    await degraded.shutdown()
}

@Test
func malformedRebuildReceiptCannotDeleteTheActiveGeneration() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let request = ProgressionRecoveryRequest(
        confirmationToken: UUID(uuidString: "73000000-0000-0000-0000-000000000001")!
    )
    let operation = try fixture.metadata(
        operation: "progression.recovery.rebuild",
        suffix: "receipt-guard"
    )
    _ = try await service.rebuild(request, metadata: operation)
    let activeBefore = try await fixture.client.activeMetadata()
    try await fixture.client.rewriteRebuildReceiptCleanupToActiveGeneration()

    do {
        _ = try await service.rebuild(request, metadata: operation)
        Issue.record("A receipt targeting the active generation was accepted.")
    } catch {
        // The receipt is quarantined before any cleanup mutation is attempted.
    }
    let activeAfter = try await fixture.client.activeMetadata()
    #expect(activeAfter.activeGeneration == activeBefore.activeGeneration)
    #expect(activeAfter.revision == activeBefore.revision)
    #expect(try await fixture.client.activeProjectionShardExists(category: .catalogMigration))
    await service.shutdown()
}

@Test
func nonHeadRevealReferenceCorruptionFailsClosedWithoutAdvancingFIFO() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.messageEncodedEvent(
            index: 123,
            occurredAt: Date(timeIntervalSince1970: 2_000_004_000)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "queue-one")
    ), case .applied = try await service.applyEvent(
        fixture.bidirectionalEvent(
            index: 124,
            occurredAt: Date(timeIntervalSince1970: 2_000_004_100)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "queue-two")
    ) else {
        Issue.record("The queue fixture did not produce two reveals.")
        return
    }
    let before = try await fixture.snapshot(from: service, suffix: "queue-before-corruption")
    #expect(before.pendingRevealCount == 2)
    let headID = try #require(before.nextReveal?.revealID)
    let metadataBefore = try await fixture.client.activeMetadata()
    await service.shutdown()
    try await fixture.client.rewriteNonHeadRevealWithUnknownPrimary()

    let degraded = try await fixture.bootstrap()
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(operation: "progression.diagnostics.summary", suffix: "queue-q")
    ).availability == .degraded)
    do {
        try await degraded.acknowledgeReveal(
            AcknowledgeProgressionRevealCommand(revealID: headID),
            metadata: fixture.metadata(
                operation: "progression.reveal.acknowledge",
                suffix: "queue-no-advance"
            )
        )
        Issue.record("A degraded queue advanced past an invalid non-head record.")
    } catch {
        // Mutations are disabled while the queue is not fully trustworthy.
    }
    do {
        _ = try await degraded.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "74000000-0000-0000-0000-000000000001")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "queue-no-promote"
            )
        )
        Issue.record("Recovery promoted while the authoritative reveal queue was unknowable.")
    } catch {
        // Queue corruption is intentionally irreconstructible.
    }
    let metadataAfter = try await fixture.client.activeMetadata()
    #expect(metadataAfter.activeGeneration == metadataBefore.activeGeneration)
    #expect(metadataAfter.revision == metadataBefore.revision)
    await degraded.shutdown()
}

@Test
func maximumShareCascadeCommitsWithinPhysicalTransactionBounds() async throws {
    let fixture = try ProgressionDurableFixture()
    let bundle = fixture.maximumOwnershipBundle()
    let service = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: bundle,
        stateClient: fixture.client
    )
    let initialDiagnostics = try await service.diagnosticsSummary(
        metadata: fixture.metadata(operation: "progression.diagnostics.summary", suffix: "maximum-initial")
    )
    #expect(initialDiagnostics.availability == .available)
    await fixture.client.clearRecordedTransactions()
    let event = try fixture.maximumShareEvent(index: 125, bundle: bundle)
    let outcome = try await service.applyEvent(
        event,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "maximum-share")
    )
    guard case let .applied(_, _, delta) = outcome else {
        let health = try await fixture.client.health()
        let transactions = await fixture.client.recordedTransactions()
        Issue.record("The maximum legal share did not apply: \(outcome), health=\(health), transactions=\(transactions.map { $0.mutations.count })")
        return
    }
    #expect(event.payload.codexIDs.count == 5)
    #expect(event.payload.artifactIDs.count == DomainEventPayload.maximumArtifactIDs)
    #expect(delta.completedAchievementCount + delta.completedMilestoneCount > 1)
    #expect(delta.grantedContentCount > 0)
    #expect(delta.queuedRevealCount == 1)
    let transactions = await fixture.client.recordedTransactions()
    let eventTransaction = try #require(transactions.first {
        $0.transactionID == event.eventID.rawValue
    })
    #expect(eventTransaction.mutations.filter {
        $0.key.collectionID == ProgressionRepositoryIDs.distinctCollection
    }.count == 11)
    #expect(eventTransaction.mutations.count <= ModuleStateTransaction.maximumMutations)
    var aggregateBytes = 0
    for mutation in eventTransaction.mutations {
        if case let .upsert(upsert) = mutation {
            #expect(upsert.payload.count <= 1_048_576)
            aggregateBytes += upsert.payload.count
        }
    }
    #expect(aggregateBytes <= 8_388_608)
    let snapshot = try await fixture.snapshot(from: service, suffix: "maximum-share-snapshot")
    #expect(Set(snapshot.ownership.map(\.reference)).count == snapshot.ownership.count)
    #expect(snapshot.pendingRevealCount <= 1)
    await service.shutdown()
}

@Test
func rebuildResumesTheSameStagingOperationAfterAnAmbiguousPhaseCommit() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.cipherEvent(index: 140),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "stage-resume-event")
    ) else {
        Issue.record("The staging-resume source event did not apply.")
        return
    }
    let operation = try fixture.metadata(
        operation: "progression.recovery.rebuild",
        suffix: "stage-resume"
    )
    await fixture.store.injectFault(
        at: .afterTransactionCommit,
        afterSuccessfulCalls: 1
    )
    do {
        _ = try await service.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!
            ),
            metadata: operation
        )
        Issue.record("The injected staging fault did not interrupt rebuild.")
    } catch {
        // The same authoritative operation is retried below.
    }
    let stagedGeneration = try #require(await fixture.client.rebuildStageDestination())
    _ = try await service.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "76000000-0000-0000-0000-000000000001")!
        ),
        metadata: operation
    )
    #expect(try await fixture.client.rebuildStageDestination() == nil)
    #expect(try await fixture.client.activeMetadata().activeGeneration == stagedGeneration)
    await service.shutdown()
}

@Test
func freshRebuildOperationSweepsAnInterruptedStagingGeneration() async throws {
    let fixture = try ProgressionDurableFixture()
    let first = try await fixture.bootstrap()
    guard case .applied = try await first.applyEvent(
        fixture.cipherEvent(index: 141),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "stage-sweep-event")
    ) else {
        Issue.record("The staging-sweep source event did not apply.")
        return
    }
    await fixture.store.injectFault(
        at: .afterTransactionCommit,
        afterSuccessfulCalls: 1
    )
    do {
        _ = try await first.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "76000000-0000-0000-0000-000000000002")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "stage-sweep-first"
            )
        )
        Issue.record("The injected staging fault did not interrupt rebuild.")
    } catch {
        // A fresh operation after relaunch must sweep this staged generation.
    }
    let abandonedGeneration = try #require(await fixture.client.rebuildStageDestination())
    #expect(try await fixture.client.generationRecordCount(abandonedGeneration) > 0)
    await first.shutdown()

    let relaunched = try await fixture.bootstrap()
    _ = try await relaunched.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "76000000-0000-0000-0000-000000000003")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "stage-sweep-second"
        )
    )
    #expect(try await fixture.client.rebuildStageDestination() == nil)
    #expect(try await fixture.client.generationRecordCount(abandonedGeneration) == 0)
    #expect(try await fixture.client.activeMetadata().activeGeneration != abandonedGeneration)
    await relaunched.shutdown()
}

@Test
func sameEventIDWithDifferentEnvelopeIsRejectedWithoutMutatingState() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let original = try fixture.cipherEvent(index: 126)
    guard case .applied = try await service.applyEvent(
        original,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "collision-first")
    ) else {
        Issue.record("The collision source event did not apply.")
        return
    }
    let before = try await fixture.snapshot(from: service, suffix: "collision-before")
    let collision = try fixture.envelopeCollision(for: original, replacementIndex: 127)
    guard case .rejectedPermanent = try await service.applyEvent(
        collision,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "collision-second")
    ) else {
        Issue.record("An unequal envelope reused an existing EventID.")
        return
    }
    let after = try await fixture.snapshot(from: service, suffix: "collision-after")
    #expect(after.revision == before.revision)
    #expect(after.statistics == before.statistics)
    await service.shutdown()
}

@Test
func additiveRewardUpgradeAppendsOneRevealAndRebuildNeverResurrectsHistoricalReveals() async throws {
    let fixture = try ProgressionDurableFixture()
    let versionTwo = try await fixture.bootstrap()
    guard case .applied = try await versionTwo.applyEvent(
        fixture.messageEncodedEvent(
            index: 130,
            occurredAt: Date(timeIntervalSince1970: 1_999_999_900)
        ),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "upgrade-reward-v2")
    ) else {
        Issue.record("The historical reward event did not apply.")
        return
    }
    let versionTwoSnapshot = try await fixture.snapshot(
        from: versionTwo,
        suffix: "upgrade-reward-v2-snapshot"
    )
    let originalReveal = try #require(versionTwoSnapshot.nextReveal)
    let sourceAchievementID = try #require(originalReveal.sourceAchievementIDs.first)
    await versionTwo.shutdown()

    let nextVersionBundle = fixture.additiveEventRewardNextVersionBundle(
        sourceAchievementID: sourceAchievementID
    )
    let upgraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: nextVersionBundle,
        stateClient: fixture.client
    )
    let afterUpgrade = try await fixture.snapshot(from: upgraded, suffix: "upgrade-reward-v3")
    #expect(afterUpgrade.pendingRevealCount == 2)
    #expect(afterUpgrade.nextReveal?.revealID == originalReveal.revealID)
    let diagnostics = try await upgraded.diagnosticsSummary(
        metadata: fixture.metadata(operation: "progression.diagnostics.summary", suffix: "upgrade-hashes")
    )
    #expect(diagnostics.catalogVersion == ProgressionCatalogVersion(rawValue: 4))
    #expect(
        diagnostics.hashes.first(where: { $0.kind == .catalog })?.digest
            == nextVersionBundle.integrityMetadata.catalogSHA256
    )
    #expect(
        diagnostics.hashes.first(where: { $0.kind == .eventCatalog })?.digest
            == nextVersionBundle.integrityMetadata.eventCatalogSHA256
    )

    _ = try await upgraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "75000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "upgrade-pending-rebuild")
    )
    #expect(try await fixture.snapshot(
        from: upgraded,
        suffix: "upgrade-pending-after-rebuild"
    ).pendingRevealCount == 2)

    try await fixture.markPresented(
        originalReveal.revealID,
        using: upgraded,
        suffix: "upgrade-ack-original",
        timestamp: Date(timeIntervalSince1970: 2_000_000_000)
    )
    try await upgraded.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: originalReveal.revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "upgrade-ack-original"
        )
    )
    let replacement = try #require(try await fixture.snapshot(
        from: upgraded,
        suffix: "upgrade-replacement"
    ).nextReveal)
    #expect(replacement.revealID == RevealID(rawValue: "reveal.upgrade.3.4"))
    #expect(replacement.primaryRewardID == .title(
        TitleID(rawValue: "title.upgrade.event-reward")!
    ))
    _ = try await upgraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "75000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "upgrade-replacement-rebuild")
    )
    #expect(try await fixture.snapshot(
        from: upgraded,
        suffix: "upgrade-replacement-after-rebuild"
    ).nextReveal?.revealID == replacement.revealID)
    try await fixture.markPresented(
        replacement.revealID,
        using: upgraded,
        suffix: "upgrade-ack-replacement",
        timestamp: Date(timeIntervalSince1970: 2_000_000_000)
    )
    try await upgraded.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: replacement.revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "upgrade-ack-replacement"
        )
    )
    _ = try await upgraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "75000000-0000-0000-0000-000000000003")!
        ),
        metadata: fixture.metadata(operation: "progression.recovery.rebuild", suffix: "upgrade-empty-rebuild")
    )
    #expect(try await fixture.snapshot(
        from: upgraded,
        suffix: "upgrade-empty-after-rebuild"
    ).pendingRevealCount == 0)
    await upgraded.shutdown()
}

@Test
func complementaryAppliedSourcesRecoverOneCanonicalLedger() async throws {
    let fixture = try ProgressionDurableFixture()
    let first = try fixture.cipherEvent(index: 154)
    let second = try fixture.cipherEvent(index: 155)
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        first,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "union-first")
    ), case .applied = try await service.applyEvent(
        second,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "union-second")
    ) else {
        Issue.record("The complementary-ledger source events did not apply.")
        return
    }
    await service.shutdown()

    try await fixture.client.corruptAndDiscoverAppliedOrder(revision: 1)
    try await fixture.client.rewriteAppliedProcessedEvent(
        second.eventID,
        envelope: fixture.envelopeCollision(for: second, replacementIndex: 156)
    )

    let degraded = try await fixture.bootstrap()
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "79000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "union-rebuild"
        )
    )
    #expect(try await degraded.applyEvent(
        first,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "union-first-replay")
    ) == .duplicate)
    #expect(try await degraded.applyEvent(
        second,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "union-second-replay")
    ) == .duplicate)
    await degraded.shutdown()
}

@Test
func duplicateTerminalSurvivesSemanticIndexReconstruction() async throws {
    let fixture = try ProgressionDurableFixture()
    let first = try fixture.cipherEvent(index: 157, semanticIndex: 157)
    let duplicate = try fixture.cipherEvent(index: 158, semanticIndex: 157)
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        first,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "semantic-first")
    ) else {
        Issue.record("The semantic-index source event did not apply.")
        return
    }
    #expect(try await service.applyEvent(
        duplicate,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "semantic-terminal")
    ) == .duplicate)
    guard case let .accepted(accepted) = ProgressionEventValidator.validate(
        first,
        bundle: fixture.bundle
    ) else {
        Issue.record("The semantic-index source event did not validate.")
        return
    }
    await service.shutdown()
    try await fixture.client.corruptAndDiscoverSemantic(accepted.semanticDigest)

    let degraded = try await fixture.bootstrap()
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "79000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "semantic-rebuild"
        )
    )
    #expect(try await degraded.applyEvent(
        duplicate,
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "semantic-replay")
    ) == .duplicate)
    await degraded.shutdown()
}

@Test
func revealEvidenceUsesTheRebuiltAppliedLedgerAcrossRecoveryAndUpgrade() async throws {
    do {
        let fixture = try ProgressionDurableFixture()
        let event = try fixture.messageEncodedEvent(
            index: 159,
            occurredAt: Date(timeIntervalSince1970: 2_000_006_000)
        )
        let service = try await fixture.bootstrap()
        guard case .applied = try await service.applyEvent(
            event,
            metadata: fixture.metadata(operation: "progression.event.apply", suffix: "pending-ledger")
        ) else {
            Issue.record("The pending reveal ledger event did not apply.")
            return
        }
        let revealID = try #require(try await fixture.snapshot(
            from: service,
            suffix: "pending-ledger-before"
        ).nextReveal?.revealID)
        await service.shutdown()
        try await fixture.client.corruptAndDiscoverProcessedEvent(event.eventID)

        let degraded = try await fixture.bootstrap()
        _ = try await degraded.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "79000000-0000-0000-0000-000000000003")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "pending-ledger-rebuild"
            )
        )
        #expect(try await fixture.snapshot(
            from: degraded,
            suffix: "pending-ledger-after"
        ).nextReveal?.revealID == revealID)
        await degraded.shutdown()
    }

    do {
        let fixture = try ProgressionDurableFixture()
        let event = try fixture.messageEncodedEvent(
            index: 160,
            occurredAt: Date(timeIntervalSince1970: 2_000_006_100)
        )
        let service = try await fixture.bootstrap()
        guard case .applied = try await service.applyEvent(
            event,
            metadata: fixture.metadata(operation: "progression.event.apply", suffix: "ack-ledger")
        ) else {
            Issue.record("The acknowledged reveal ledger event did not apply.")
            return
        }
        let revealID = try #require(try await fixture.snapshot(
            from: service,
            suffix: "ack-ledger-before"
        ).nextReveal?.revealID)
        try await fixture.markPresented(
            revealID,
            using: service,
            suffix: "ack-ledger-command",
            timestamp: Date(timeIntervalSince1970: 2_000_006_200)
        )
        try await service.acknowledgeReveal(
            AcknowledgeProgressionRevealCommand(revealID: revealID),
            metadata: fixture.metadata(
                operation: "progression.reveal.acknowledge",
                suffix: "ack-ledger-command",
                timestamp: Date(timeIntervalSince1970: 2_000_006_200)
            )
        )
        await service.shutdown()
        try await fixture.client.corruptAndDiscoverProcessedEvent(event.eventID)

        let upgraded = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
            catalogBundle: fixture.additiveNextVersionBundle(),
            stateClient: fixture.client
        )
        #expect(try await upgraded.diagnosticsSummary(
            metadata: fixture.metadata(
                operation: "progression.diagnostics.summary",
                suffix: "ack-ledger-v3-degraded"
            )
        ).availability == .degraded)
        _ = try await upgraded.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "79000000-0000-0000-0000-000000000006")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "ack-ledger-v3-rebuild"
            )
        )
        let snapshot = try await fixture.snapshot(from: upgraded, suffix: "ack-ledger-v3")
        #expect(snapshot.catalogVersion == ProgressionCatalogVersion(rawValue: 4))
        #expect(snapshot.pendingRevealCount == 0)
        #expect(try await upgraded.applyEvent(
            event,
            metadata: fixture.metadata(operation: "progression.event.apply", suffix: "ack-ledger-replay")
        ) == .duplicate)
        await upgraded.shutdown()
    }
}

@Test
func hiddenInterruptedCandidateQuarantineDoesNotStrandTheActiveGeneration() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.cipherEvent(index: 161),
        metadata: fixture.metadata(operation: "progression.event.apply", suffix: "scratch-source")
    ) else {
        Issue.record("The scratch recovery source event did not apply.")
        return
    }
    await fixture.store.injectFault(at: .afterTransactionCommit, afterSuccessfulCalls: 3)
    do {
        _ = try await service.rebuild(
            ProgressionRecoveryRequest(
                confirmationToken: UUID(uuidString: "79000000-0000-0000-0000-000000000004")!
            ),
            metadata: fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "scratch-interrupted"
            )
        )
        Issue.record("The scratch staging fault did not interrupt rebuild.")
        return
    } catch {
        // The persisted marker and candidate are corrupted below.
    }
    let abandoned = try #require(await fixture.client.rebuildStageDestination())
    try await fixture.client.corruptAndDiscoverFirstRecoveryCandidate(
        generation: abandoned
    )
    await service.shutdown()

    let degraded = try await fixture.bootstrap()
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(
            operation: "progression.diagnostics.summary",
            suffix: "scratch-degraded"
        )
    ).availability == .degraded)
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "79000000-0000-0000-0000-000000000005")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "scratch-fresh"
        )
    )
    #expect(try await fixture.client.rebuildStageDestination() == nil)
    #expect(try await fixture.client.generationRecordCount(abandoned) == 0)
    await degraded.shutdown()
}

struct ProgressionDurableFixture {
    let bundle: ValidatedProgressionCatalogBundle
    let clock: ProgressionTestClock
    let store: InMemoryModuleStateStore
    let client: ProgressionTestStateClient

    init() throws {
        bundle = try ProgressionCatalogDecoder.decodeAndValidateBundle(
            catalogData: Self.resourceData(ProgressionCatalogResourceCatalog.catalogDescriptor),
            eventCatalogData: Self.resourceData(
                ProgressionCatalogResourceCatalog.eventCatalogDescriptor
            ),
            futureThemeBindingData: Self.resourceData(
                ProgressionCatalogResourceCatalog.futureThemeBindingsDescriptor
            ),
            integrityMetadata: ProgressionCatalogResourceCatalog.integrityMetadata
        )
        let clock = ProgressionTestClock(Date(timeIntervalSince1970: 2_000_000_000))
        self.clock = clock
        let store = InMemoryModuleStateStore(now: { clock.now() })
        self.store = store
        client = ProgressionTestStateClient(store: store)
    }

    func bootstrap(
        availabilitySnapshots: AsyncStream<RuntimeAvailabilitySnapshot>? = nil
    ) async throws -> RuneScribeProgressionServiceActor {
        try await RuneScribeProgressionServiceActor.bootstrapForTesting(
            catalogBundle: bundle,
            stateClient: client,
            availabilitySnapshots: availabilitySnapshots
        )
    }

    func metadata(
        operation: String,
        suffix: String,
        timestamp: Date = Date(timeIntervalSince1970: 2_000_000_000)
    ) throws -> RuntimeOperationMetadata {
        RuntimeOperationMetadata(
            schemaVersion: RuntimeSchemaVersions.v1,
            operationID: RuntimeOperationID(rawValue: "operation.\(suffix)"),
            correlationID: RuntimeCorrelationID(rawValue: "correlation.\(suffix)"),
            sourceModuleID: RuneScribeModuleIDs.core,
            destinationModuleID: RuneScribeModuleIDs.progression,
            runtimeGeneration: 1,
            timestampUTC: timestamp,
            operationIdentifier: RuntimeOperationIdentifier(rawValue: operation),
            privacyClass: .internalData
        )
    }

    func snapshot(
        from service: RuneScribeProgressionServiceActor,
        suffix: String
    ) async throws -> ProgressionSnapshotDTO {
        let stream = service.stateStream(metadata: try metadata(
            operation: "progression.state.stream",
            suffix: suffix
        ))
        var iterator = stream.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    func markPresented(
        _ revealID: RevealID,
        using service: RuneScribeProgressionServiceActor,
        suffix: String,
        timestamp: Date
    ) async throws {
        try await service.markRevealPresented(
            MarkProgressionRevealPresentedCommand(revealID: revealID),
            metadata: metadata(
                operation: "progression.reveal.mark-presented",
                suffix: "present-\(suffix)",
                timestamp: timestamp
            )
        )
    }

    func cipherEvent(index: UInt32, semanticIndex: UInt32? = nil) throws -> DomainEventEnvelope {
        try event(
            index: index,
            type: "runescribe.cipher.created",
            payload: DomainEventPayload(
                cipherToken: CipherToken(
                    rawValue: token("c", index: semanticIndex ?? index)
                ),
                origin: .generated
            )
        )
    }

    func unknownEvent(index: UInt32) throws -> DomainEventEnvelope {
        try event(
            index: index + 40_000,
            type: "runescribe.unsupported.synthetic",
            payload: DomainEventPayload()
        )
    }

    func envelopeCollision(
        for original: DomainEventEnvelope,
        replacementIndex: UInt32
    ) throws -> DomainEventEnvelope {
        try DomainEventEnvelope(
            schemaVersion: original.schemaVersion,
            eventID: original.eventID,
            correlationID: original.correlationID,
            eventType: original.eventType,
            sourceModuleID: original.sourceModuleID,
            occurredAt: original.occurredAt,
            eligibility: original.eligibility,
            payload: DomainEventPayload(
                cipherToken: CipherToken(rawValue: token("z", index: replacementIndex)),
                origin: .generated
            )
        )
    }

    func messageEncodedEvent(index: UInt32, occurredAt: Date) throws -> DomainEventEnvelope {
        try event(
            index: index + 10_000,
            type: "runescribe.message.encoded",
            occurredAt: occurredAt,
            payload: DomainEventPayload(
                cipherToken: CipherToken(rawValue: token("c", index: index)),
                messageToken: MessageToken(rawValue: token("m", index: index)),
                origin: .generated,
                codexIDs: [CodexID(rawValue: "codex.norse")!]
            )
        )
    }

    func messageDecodedEvent(
        index: UInt32,
        occurredAt: Date,
        codexID: CodexID = CodexID(rawValue: "codex.norse")!
    ) throws -> DomainEventEnvelope {
        try event(
            index: index + 70_000,
            type: "runescribe.message.decoded",
            occurredAt: occurredAt,
            payload: DomainEventPayload(
                packageToken: PackageToken(rawValue: token("p", index: index)),
                origin: .imported,
                codexIDs: [codexID]
            )
        )
    }

    func presentationEvent(
        index: UInt32,
        semanticIndex: UInt32? = nil,
        occurredAt: Date,
        artifacts: [ArtifactID],
        provenance: DomainEventProvenanceStatus
    ) throws -> DomainEventEnvelope {
        try event(
            index: index + 20_000,
            type: "runescribe.presentation.observed",
            occurredAt: occurredAt,
            payload: DomainEventPayload(
                packageToken: PackageToken(
                    rawValue: token("p", index: semanticIndex ?? index)
                ),
                codexIDs: [CodexID(rawValue: "codex.norse")!],
                artifactIDs: artifacts,
                provenanceStatus: provenance
            )
        )
    }

    func codexPresentationEvent(
        index: UInt32,
        codexID: CodexID,
        occurredAt: Date
    ) throws -> DomainEventEnvelope {
        try event(
            index: index,
            type: "runescribe.presentation.observed",
            occurredAt: occurredAt,
            payload: DomainEventPayload(
                packageToken: PackageToken(rawValue: token("p", index: index)),
                codexIDs: [codexID],
                artifactIDs: [],
                provenanceStatus: .verified
            )
        )
    }

    func bidirectionalEvent(index: UInt32, occurredAt: Date) throws -> DomainEventEnvelope {
        try event(
            index: index + 30_000,
            type: "runescribe.exchange.bidirectional-established",
            occurredAt: occurredAt,
            payload: DomainEventPayload(
                relationshipToken: RelationshipToken(rawValue: token("r", index: index))
            )
        )
    }

    func firstDeliveryEvent(index: UInt32, occurredAt: Date) throws -> DomainEventEnvelope {
        try event(
            index: index + 60_000,
            type: "runescribe.cipher.first-delivery-completed",
            occurredAt: occurredAt,
            payload: DomainEventPayload(
                cipherToken: CipherToken(rawValue: token("c", index: index)),
                relationshipToken: RelationshipToken(rawValue: token("r", index: index)),
                keyIncluded: true,
                linkedRelationship: true
            )
        )
    }

    func norseOwnership(in snapshot: ProgressionSnapshotDTO) -> ProgressionOwnershipDTO? {
        let norse = CodexID(rawValue: "codex.norse")!
        return snapshot.ownership.first { $0.reference == .codex(norse) }
    }

    func ownership(
        _ reference: ProgressionContentReference,
        in snapshot: ProgressionSnapshotDTO
    ) -> ProgressionOwnershipDTO? {
        snapshot.ownership.first { $0.reference == reference }
    }

    func availabilitySnapshot(
        revision: UInt64,
        lifecycleByCodexID: [CodexID: ModuleLifecycleState]
    ) throws -> RuntimeAvailabilitySnapshot {
        let modules = bundle.futureThemeBindings.bindings.compactMap { binding in
            lifecycleByCodexID[binding.codexID].map {
                RuntimeOptionalModuleAvailabilitySnapshot(
                    moduleID: binding.moduleID,
                    role: ModuleRole(
                        rawValue: "runescribe.theme.\(binding.codexID.rawValue)"
                    ),
                    lifecycleState: $0
                )
            }
        }
        return RuntimeAvailabilitySnapshot(
            revision: revision,
            capturedAt: Date(timeIntervalSince1970: 2_000_001_000 + Double(revision)),
            optionalModules: modules,
            entitlementSnapshot: try ProgressionEntitlementSnapshotDTO(
                revision: 0,
                capturedAt: Date(timeIntervalSince1970: 2_000_001_000),
                includedUnlockIDs: [],
                earnedUnlockIDs: []
            )
        )
    }

    func additiveNextVersionBundle() -> ValidatedProgressionCatalogBundle {
        let addedContentID = ProgressionContentID(rawValue: "title.upgrade.wayfinder")!
        let addedContent = ProgressionContentDefinition(
            contentID: addedContentID,
            kind: .title,
            displayName: "Wayfinder",
            countsAsArtifact: false,
            availability: .included,
            rarity: .forged,
            codexID: nil,
            notes: "Synthetic add-only upgrade fixture."
        )
        let groups = bundle.catalog.grantGroups.map { group in
            guard group.grantGroupID == bundle.catalog.migration.startingGrantGroupID else {
                return group
            }
            return ProgressionGrantGroup(
                grantGroupID: group.grantGroupID,
                items: group.items + [ProgressionGrantItem(
                    contentID: addedContentID,
                    grantKind: .permanent
                )],
                revealTier: group.revealTier,
                primaryContentID: group.primaryContentID,
                notes: group.notes
            )
        }
        let catalog = ProgressionCatalog(
            schemaVersion: bundle.catalog.schemaVersion,
            catalogID: bundle.catalog.catalogID,
            catalogVersion: ProgressionCatalogVersion(rawValue: 4)!,
            packageVersion: bundle.catalog.packageVersion,
            status: bundle.catalog.status,
            effectiveDate: bundle.catalog.effectiveDate,
            governingObjective: bundle.catalog.governingObjective,
            principles: bundle.catalog.principles,
            content: bundle.catalog.content + [addedContent],
            statistics: bundle.catalog.statistics,
            achievements: bundle.catalog.achievements,
            milestones: bundle.catalog.milestones,
            grantGroups: groups,
            journeyGraph: bundle.catalog.journeyGraph,
            revealPolicy: bundle.catalog.revealPolicy,
            gameCenterPolicy: bundle.catalog.gameCenterPolicy,
            migration: bundle.catalog.migration,
            deferred: bundle.catalog.deferred
        )
        let eventCatalog = ProgressionEventCatalog(
            schemaVersion: bundle.eventCatalog.schemaVersion,
            catalogID: bundle.eventCatalog.catalogID,
            catalogVersion: ProgressionCatalogVersion(rawValue: 4)!,
            status: bundle.eventCatalog.status,
            effectiveDate: bundle.eventCatalog.effectiveDate,
            eventEnvelope: bundle.eventCatalog.eventEnvelope,
            applyOutcomes: bundle.eventCatalog.applyOutcomes,
            acknowledgeOutboxOn: bundle.eventCatalog.acknowledgeOutboxOn,
            retainOutboxOn: bundle.eventCatalog.retainOutboxOn,
            events: bundle.eventCatalog.events,
            shareRoutePolicy: bundle.eventCatalog.shareRoutePolicy,
            forbiddenData: bundle.eventCatalog.forbiddenData,
            eligibilityReasonIDs: bundle.eventCatalog.eligibilityReasonIDs
        )
        let bindings = ProgressionFutureThemeBindingContract(
            schemaVersion: bundle.futureThemeBindings.schemaVersion,
            contractID: bundle.futureThemeBindings.contractID,
            version: ProgressionCatalogVersion(rawValue: 4)!,
            status: bundle.futureThemeBindings.status,
            bindings: bundle.futureThemeBindings.bindings,
            rules: bundle.futureThemeBindings.rules,
            supersessions: bundle.futureThemeBindings.supersessions
        )
        return ValidatedProgressionCatalogBundle(
            catalog: catalog,
            eventCatalog: eventCatalog,
            futureThemeBindings: bindings,
            dependencyAnalysis: bundle.dependencyAnalysis,
            integrityMetadata: ProgressionCatalogIntegrityMetadata(
                catalogSHA256: ProgressionSHA256Digest(
                    rawValue: String(repeating: "a", count: 64)
                )!,
                eventCatalogSHA256: ProgressionSHA256Digest(
                    rawValue: String(repeating: "b", count: 64)
                )!
            )
        )
    }

    func maximumOwnershipBundle() -> ValidatedProgressionCatalogBundle {
        let codexContent = bundle.catalog.content.filter { $0.kind == .codex }
        let maximumContentIDs = Set(codexContent.map(\.contentID))
        let groups = bundle.catalog.grantGroups.map { group in
            guard group.grantGroupID == bundle.catalog.migration.startingGrantGroupID else {
                return group
            }
            let existing = Set(group.items.map(\.contentID))
            let additions = maximumContentIDs.subtracting(existing).sorted().map {
                ProgressionGrantItem(contentID: $0, grantKind: .permanent)
            }
            return ProgressionGrantGroup(
                grantGroupID: group.grantGroupID,
                items: group.items + additions,
                revealTier: group.revealTier,
                primaryContentID: group.primaryContentID,
                notes: group.notes
            )
        }
        let journeyGraph = ProgressionJourneyGraph(
            nodes: bundle.catalog.journeyGraph.nodes.map { node in
                guard maximumContentIDs.contains(node.contentID) else { return node }
                return ProgressionJourneyNode(
                    nodeID: node.nodeID,
                    contentID: node.contentID,
                    state: .included,
                    gateRuleID: nil,
                    order: node.order
                )
            },
            edges: bundle.catalog.journeyGraph.edges
        )
        let catalog = ProgressionCatalog(
            schemaVersion: bundle.catalog.schemaVersion,
            catalogID: bundle.catalog.catalogID,
            catalogVersion: bundle.catalog.catalogVersion,
            packageVersion: bundle.catalog.packageVersion,
            status: bundle.catalog.status,
            effectiveDate: bundle.catalog.effectiveDate,
            governingObjective: bundle.catalog.governingObjective,
            principles: bundle.catalog.principles,
            content: bundle.catalog.content,
            statistics: bundle.catalog.statistics,
            achievements: bundle.catalog.achievements,
            milestones: bundle.catalog.milestones,
            grantGroups: groups,
            journeyGraph: journeyGraph,
            revealPolicy: bundle.catalog.revealPolicy,
            gameCenterPolicy: bundle.catalog.gameCenterPolicy,
            migration: bundle.catalog.migration,
            deferred: bundle.catalog.deferred
        )
        return ValidatedProgressionCatalogBundle(
            catalog: catalog,
            eventCatalog: bundle.eventCatalog,
            futureThemeBindings: bundle.futureThemeBindings,
            dependencyAnalysis: bundle.dependencyAnalysis,
            integrityMetadata: bundle.integrityMetadata
        )
    }

    func additiveEventRewardNextVersionBundle(
        sourceAchievementID: AchievementID
    ) -> ValidatedProgressionCatalogBundle {
        let base = additiveNextVersionBundle()
        let achievement = base.catalog.achievement(id: sourceAchievementID)!
        let contentID = ProgressionContentID(rawValue: "title.upgrade.event-reward")!
        let content = ProgressionContentDefinition(
            contentID: contentID,
            kind: .title,
            displayName: "Event Reward",
            countsAsArtifact: false,
            availability: .earned,
            rarity: .rare,
            codexID: nil,
            notes: "Synthetic additive historical-event reward."
        )
        let groups = base.catalog.grantGroups.map { group in
            guard group.grantGroupID == achievement.rewardGrantGroupID else { return group }
            return ProgressionGrantGroup(
                grantGroupID: group.grantGroupID,
                items: group.items + [ProgressionGrantItem(
                    contentID: contentID,
                    grantKind: .permanent
                )],
                revealTier: group.revealTier,
                primaryContentID: group.primaryContentID,
                notes: group.notes
            )
        }
        let catalog = ProgressionCatalog(
            schemaVersion: base.catalog.schemaVersion,
            catalogID: base.catalog.catalogID,
            catalogVersion: base.catalog.catalogVersion,
            packageVersion: base.catalog.packageVersion,
            status: base.catalog.status,
            effectiveDate: base.catalog.effectiveDate,
            governingObjective: base.catalog.governingObjective,
            principles: base.catalog.principles,
            content: base.catalog.content + [content],
            statistics: base.catalog.statistics,
            achievements: base.catalog.achievements,
            milestones: base.catalog.milestones,
            grantGroups: groups,
            journeyGraph: base.catalog.journeyGraph,
            revealPolicy: base.catalog.revealPolicy,
            gameCenterPolicy: base.catalog.gameCenterPolicy,
            migration: base.catalog.migration,
            deferred: base.catalog.deferred
        )
        return ValidatedProgressionCatalogBundle(
            catalog: catalog,
            eventCatalog: base.eventCatalog,
            futureThemeBindings: base.futureThemeBindings,
            dependencyAnalysis: base.dependencyAnalysis,
            integrityMetadata: base.integrityMetadata
        )
    }

    func maximumShareEvent(
        index: UInt32,
        bundle: ValidatedProgressionCatalogBundle
    ) throws -> DomainEventEnvelope {
        let codexIDs = bundle.catalog.content.compactMap { definition -> CodexID? in
            guard definition.kind == .codex else { return nil }
            return CodexID(rawValue: definition.contentID.rawValue)
        }
        let artifactIDs = bundle.catalog.content.compactMap { definition -> ArtifactID? in
            guard definition.countsAsArtifact else { return nil }
            return ArtifactID(rawValue: definition.contentID.rawValue)
        }.prefix(DomainEventPayload.maximumArtifactIDs)
        return try event(
            index: index + 50_000,
            type: "runescribe.share.completed",
            payload: DomainEventPayload(
                messageToken: MessageToken(rawValue: token("m", index: index)),
                relationshipToken: RelationshipToken(rawValue: token("r", index: index)),
                routeClass: .messages,
                codexIDs: codexIDs,
                artifactIDs: Array(artifactIDs),
                keyIncluded: false,
                linkedRelationship: true
            ),
            eligibilityReason: EligibilityReasonID(
                rawValue: "eligibility.eligible.message-sent-confirmed"
            )!
        )
    }

    private func event(
        index: UInt32,
        type: String,
        occurredAt: Date = Date(timeIntervalSince1970: 2_000_000_100),
        payload: DomainEventPayload,
        eligibilityReason: EligibilityReasonID = EligibilityReasonID(
            rawValue: "eligibility.eligible.domain-commit"
        )!
    ) throws -> DomainEventEnvelope {
        let suffix = String(format: "%012x", index)
        let correlationSuffix = String(format: "%012x", index + 1_000_000)
        return try DomainEventEnvelope(
            schemaVersion: 1,
            eventID: EventID(
                rawValue: UUID(uuidString: "30000000-0000-0000-0000-\(suffix)")!
            ),
            correlationID: CorrelationID(
                rawValue: UUID(uuidString: "40000000-0000-0000-0000-\(correlationSuffix)")!
            ),
            eventType: EventIdentifier(rawValue: type),
            sourceModuleID: RuneScribeModuleIDs.core,
            occurredAt: occurredAt,
            eligibility: DomainEventEligibilityMetadata(
                state: .eligible,
                reason: eligibilityReason
            ),
            payload: payload
        )
    }

    private func token(_ prefix: Character, index: UInt32) -> String {
        String(repeating: String(prefix), count: 24) + String(format: "%08x", index)
    }

    private static func resourceData(
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
}

private actor ProgressionAvailabilityStreamProbe {
    private(set) var states: [ProgressionSnapshotDTO] = []
    private(set) var entitlementCount = 0

    var stateCount: Int { states.count }
    var latestState: ProgressionSnapshotDTO? { states.last }
    var hasInitialValues: Bool { !states.isEmpty && entitlementCount > 0 }

    func record(_ snapshot: ProgressionSnapshotDTO) {
        states.append(snapshot)
    }

    func record(_: ProgressionEntitlementSnapshotDTO) {
        entitlementCount += 1
    }
}

private func waitForAvailabilityProbe(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

final class ProgressionTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

actor ProgressionTestStateClient: ProgressionStateClient {
    private let store: InMemoryModuleStateStore
    private let namespace = ModuleStateNamespace(moduleID: RuneScribeModuleIDs.progression)
    private var transactions: [ModuleStateTransaction] = []

    init(store: InMemoryModuleStateStore) {
        self.store = store
    }

    func prepare(schemaVersion: UInt32) async throws -> ModuleStateHealthSnapshot {
        try await store.prepareNamespace(namespace, schemaVersion: schemaVersion)
    }

    func fetch(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID
    ) async throws -> ModuleStateRecord? {
        try await store.fetch(
            namespace: namespace,
            key: ModuleStateRecordKey(collectionID: collectionID, recordID: recordID)
        )
    }

    func scan(_ request: ModuleStateScanRequest) async throws -> ModuleStateScanPage {
        try await store.scan(namespace: namespace, request: request)
    }

    func transact(
        _ transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        transactions.append(transaction)
        return try await store.transact(namespace: namespace, transaction: transaction)
    }

    func quarantine(diagnosticCode: String) async throws -> ModuleStateHealthSnapshot {
        try await store.quarantine(namespace: namespace, diagnosticCode: diagnosticCode)
    }

    func quarantineRecord(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try await store.quarantineRecord(
            namespace: namespace,
            key: ModuleStateRecordKey(collectionID: collectionID, recordID: recordID),
            expectedRevision: expectedRevision,
            diagnosticCode: diagnosticCode
        )
    }

    func health() async throws -> ModuleStateHealthSnapshot {
        await store.health(namespace: namespace)
    }

    func recordCount() async -> Int {
        await store.recordCount(namespace: namespace)
    }

    func activeMetadata() async throws -> ProgressionMetadataRecord {
        let physical = try #require(try await store.fetch(
            namespace: namespace,
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.metadataCollection,
                recordID: ProgressionRepositoryIDs.activeMetadataRecord
            )
        ))
        return try ProgressionDeterminism.decoder().decode(
            ProgressionMetadataRecord.self,
            from: physical.payload
        )
    }

    func queuedRevealValues(generation: String) async throws -> [PendingRevealRecord] {
        let page = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: ProgressionRepositoryIDs.revealQueueCollection,
                limit: ModuleStateScanRequest.maximumLimit
            )
        )
        return try page.records.compactMap { physical in
            let record = try ProgressionDeterminism.decoder().decode(
                PendingRevealRecord.self,
                from: physical.payload
            )
            return record.generation == generation ? record : nil
        }
    }

    func rebuildStageDestination() async throws -> String? {
        guard let physical = try await store.fetch(
            namespace: namespace,
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.metadataCollection,
                recordID: ProgressionRepositoryIDs.rebuildStageMarkerRecord
            )
        ) else { return nil }
        let marker = try ProgressionDeterminism.decoder().decode(
            ProgressionRebuildStageMarkerRecord.self,
            from: physical.payload
        )
        try marker.validate()
        return marker.destinationGeneration
    }

    func generationRecordCount(_ generation: String) async throws -> Int {
        var count = 0
        for collection in [
            ProgressionRepositoryIDs.eventCollection(generation),
            ProgressionRepositoryIDs.eventOrderCollection(generation),
            ProgressionRepositoryIDs.semanticCollection(generation),
            ProgressionRepositoryIDs.recoveryEventCollection(generation),
            ProgressionRepositoryIDs.revealAcknowledgementCollection(generation),
            ProgressionRepositoryIDs.commandCollection(generation),
        ] {
            count += try await recordCount(in: collection) { _ in true }
        }
        count += try await recordCount(
            in: ProgressionRepositoryIDs.distinctCollection
        ) { $0.key.recordID.rawValue.hasPrefix("distinct.\(generation).") }
        count += try await recordCount(
            in: ProgressionRepositoryIDs.revealQueueCollection
        ) { $0.key.recordID.rawValue.hasPrefix("reveal.\(generation).") }
        count += try await recordCount(
            in: ProgressionRepositoryIDs.existingUserMigrationSeedCollection
        ) { $0.key.recordID.rawValue.hasPrefix("migration-seed.\(generation).") }
        count += try await recordCount(
            in: ProgressionRepositoryIDs.projectionCollection
        ) { physical in
            guard let shard = try? ProgressionDeterminism.decoder().decode(
                ProgressionProjectionShard.self,
                from: physical.payload
            ) else { return false }
            return shard.generation == generation
        }
        return count
    }

    private func recordCount(
        in collection: ModuleStateCollectionID,
        where predicate: (ModuleStateRecord) -> Bool
    ) async throws -> Int {
        var count = 0
        var cursor: ModuleStateScanCursor?
        repeat {
            let page = try await store.scan(
                namespace: namespace,
                request: try ModuleStateScanRequest(
                    collectionID: collection,
                    limit: ModuleStateScanRequest.maximumLimit,
                    cursor: cursor
                )
            )
            count += page.records.filter(predicate).count
            cursor = page.nextCursor
        } while cursor != nil
        return count
    }

    func activeProjectionShardExists(
        category: ProgressionDiagnosticRecordCategory
    ) async throws -> Bool {
        let metadata = try await activeMetadata()
        return try await store.fetch(
            namespace: namespace,
            key: ModuleStateRecordKey(
                collectionID: ProgressionRepositoryIDs.projectionCollection,
                recordID: ProgressionRepositoryIDs.shardRecordID(
                    generation: metadata.activeGeneration,
                    category: category,
                    shardIndex: 0
                )
            )
        ) != nil
    }

    func corruptAndDiscoverAppliedOrder(revision: UInt64) async throws {
        let metadata = try await activeMetadata()
        try await corruptAndDiscover(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.eventOrderCollection(
                metadata.activeGeneration
            ),
            recordID: ProgressionRepositoryIDs.eventOrderRecordID(revision)
        ))
    }

    func rewriteAppliedOrder(
        revision: UInt64,
        envelope: DomainEventEnvelope
    ) async throws {
        let metadata = try await activeMetadata()
        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.eventOrderCollection(
                metadata.activeGeneration
            ),
            recordID: ProgressionRepositoryIDs.eventOrderRecordID(revision)
        )
        let physical = try #require(try await store.fetch(namespace: namespace, key: key))
        let envelopeDigest = try ProgressionDeterminism.encodedDigest(envelope)
        let cumulativeDigest = ProgressionDeterminism.digest128(
            "genesis|\(revision)|\(envelope.eventID.rawValue.uuidString.lowercased())|\(envelopeDigest)"
        )
        let replacement = try ProgressionAppliedEventOrderRecord(
            appliedRevision: revision,
            envelope: envelope,
            cumulativeDigest: cumulativeDigest
        )
        try await rewrite(
            physical,
            payload: try ProgressionDeterminism.encoder().encode(replacement),
            transactionMaterial: "rewrite-applied-order-\(revision)"
        )
    }

    func rewriteAppliedProcessedEvent(
        _ eventID: EventID,
        envelope: DomainEventEnvelope
    ) async throws {
        let metadata = try await activeMetadata()
        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.eventCollection(
                metadata.activeGeneration
            ),
            recordID: ProgressionRepositoryIDs.eventRecordID(eventID)
        )
        let physical = try #require(try await store.fetch(namespace: namespace, key: key))
        let record = try ProgressionDeterminism.decoder().decode(
            ProcessedEventRecord.self,
            from: physical.payload
        )
        let replacement = ProcessedEventRecord(
            envelope: envelope,
            envelopeDigest: try ProgressionDeterminism.encodedDigest(envelope),
            semanticDigest: record.semanticDigest,
            outcome: .applied,
            transactionID: record.transactionID,
            appliedRevision: record.appliedRevision
        )
        try replacement.validate()
        try await rewrite(
            physical,
            payload: try ProgressionDeterminism.encoder().encode(replacement),
            transactionMaterial: "rewrite-applied-processed-\(eventID.rawValue.uuidString.lowercased())"
        )
    }

    func corruptAndDiscoverSemantic(_ digest: String) async throws {
        let metadata = try await activeMetadata()
        try await corruptAndDiscover(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.semanticCollection(
                metadata.activeGeneration
            ),
            recordID: ProgressionRepositoryIDs.semanticRecordID(digest)
        ))
    }

    func corruptAndDiscoverFirstRecoveryCandidate(
        generation: String
    ) async throws {
        let collection = ProgressionRepositoryIDs.recoveryEventCollection(generation)
        let page = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit
            )
        )
        let physical = try #require(page.records.first)
        try await corruptAndDiscover(physical.key)
    }

    func corruptAndDiscoverProcessedEvent(_ eventID: EventID) async throws {
        let metadata = try await activeMetadata()
        try await corruptAndDiscover(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.eventCollection(metadata.activeGeneration),
            recordID: ProgressionRepositoryIDs.eventRecordID(eventID)
        ))
    }

    func rewriteRebuildReceiptCleanupToActiveGeneration() async throws {
        let metadata = try await activeMetadata()
        let collection = ProgressionRepositoryIDs.commandCollection(metadata.activeGeneration)
        let page = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit
            )
        )
        let physical = try #require(page.records.first { physical in
            guard let receipt = try? ProgressionDeterminism.decoder().decode(
                ProgressionCommandReceiptRecord.self,
                from: physical.payload
            ) else { return false }
            return receipt.operationIdentifier == "progression.recovery.rebuild"
        })
        let receipt = try ProgressionDeterminism.decoder().decode(
            ProgressionCommandReceiptRecord.self,
            from: physical.payload
        )
        let mutated = ProgressionCommandReceiptRecord(
            operationID: receipt.operationID,
            correlationID: receipt.correlationID,
            operationIdentifier: receipt.operationIdentifier,
            commandDigest: receipt.commandDigest,
            completedAt: receipt.completedAt,
            resultRevision: receipt.resultRevision,
            cleanupGeneration: metadata.activeGeneration
        )
        try await rewrite(
            physical,
            payload: try ProgressionDeterminism.encoder().encode(mutated),
            transactionMaterial: "mutate-rebuild-receipt"
        )
    }

    func rewriteNonHeadRevealWithUnknownPrimary() async throws {
        let metadata = try await activeMetadata()
        let pendingShardKey = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.projectionCollection,
            recordID: ProgressionRepositoryIDs.shardRecordID(
                generation: metadata.activeGeneration,
                category: .pendingReveal,
                shardIndex: 0
            )
        )
        let shardPhysical = try #require(try await store.fetch(
            namespace: namespace,
            key: pendingShardKey
        ))
        let shard = try ProgressionDeterminism.decoder().decode(
            ProgressionProjectionShard.self,
            from: shardPhysical.payload
        )
        let queueState = try #require(shard.records.compactMap {
            logical -> ProgressionRevealQueueStateRecord? in
            guard case let .revealQueueState(record) = logical else { return nil }
            return record
        }.first)
        let page = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: ProgressionRepositoryIDs.revealQueueCollection,
                limit: ModuleStateScanRequest.maximumLimit
            )
        )
        let located = try #require(page.records.compactMap { physical -> (
            ModuleStateRecord,
            PendingRevealRecord
        )? in
            guard let record = try? ProgressionDeterminism.decoder().decode(
                PendingRevealRecord.self,
                from: physical.payload
            ), record.generation == metadata.activeGeneration,
               record.revealID != queueState.headRevealID
            else { return nil }
            return (physical, record)
        }.first)
        let unknown = ProgressionContentID(rawValue: "title.synthetic.unknown")!
        let record = located.1
        let mutated = PendingRevealRecord(
            generation: record.generation,
            revealID: record.revealID,
            transactionID: record.transactionID,
            createdRevision: record.createdRevision,
            createdAt: record.createdAt,
            state: record.state,
            acknowledgedAt: record.acknowledgedAt,
            tier: record.tier,
            primaryContentID: unknown,
            secondaryContentIDs: record.secondaryContentIDs.filter { $0 != unknown },
            sourceAchievementIDs: record.sourceAchievementIDs,
            sourceRuleIDs: record.sourceRuleIDs,
            nextRevealID: record.nextRevealID
        )
        try await rewrite(
            located.0,
            payload: try ProgressionDeterminism.encoder().encode(mutated),
            transactionMaterial: "mutate-non-head-reveal"
        )
    }

    func rewriteAcknowledgementWithUnknownPrimary() async throws {
        let metadata = try await activeMetadata()
        let collection = ProgressionRepositoryIDs.revealAcknowledgementCollection(
            metadata.activeGeneration
        )
        let page = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: collection,
                limit: ModuleStateScanRequest.maximumLimit
            )
        )
        let physical = try #require(page.records.first)
        let record = try ProgressionDeterminism.decoder().decode(
            PendingRevealRecord.self,
            from: physical.payload
        )
        let unknown = ProgressionContentID(rawValue: "title.synthetic.unknown-ack")!
        let mutated = PendingRevealRecord(
            generation: record.generation,
            revealID: record.revealID,
            transactionID: record.transactionID,
            createdRevision: record.createdRevision,
            createdAt: record.createdAt,
            state: record.state,
            acknowledgedAt: record.acknowledgedAt,
            tier: record.tier,
            primaryContentID: unknown,
            secondaryContentIDs: record.secondaryContentIDs.filter { $0 != unknown },
            sourceAchievementIDs: record.sourceAchievementIDs,
            sourceRuleIDs: record.sourceRuleIDs,
            nextRevealID: record.nextRevealID
        )
        try await rewrite(
            physical,
            payload: try ProgressionDeterminism.encoder().encode(mutated),
            transactionMaterial: "mutate-acknowledgement-reference"
        )
    }

    func removeOneEarnedGrantWithoutUpdatingOwnership() async throws {
        let metadata = try await activeMetadata()
        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.projectionCollection,
            recordID: ProgressionRepositoryIDs.shardRecordID(
                generation: metadata.activeGeneration,
                category: .grant,
                shardIndex: 0
            )
        )
        let physical = try #require(try await store.fetch(namespace: namespace, key: key))
        let shard = try ProgressionDeterminism.decoder().decode(
            ProgressionProjectionShard.self,
            from: physical.payload
        )
        let removedIdentity = try #require(shard.records.first { logical in
            guard case let .grant(record) = logical else { return false }
            if case .migration = record.source { return false }
            return true
        }).identity
        let mutated = ProgressionProjectionShard(
            generation: shard.generation,
            category: shard.category,
            shardIndex: shard.shardIndex,
            records: shard.records.filter { $0.identity != removedIdentity }
        )
        try mutated.validate()
        try await rewrite(
            physical,
            payload: try ProgressionDeterminism.encoder().encode(mutated),
            transactionMaterial: "remove-earned-grant"
        )
    }

    func corruptProjectionShard(
        category: ProgressionDiagnosticRecordCategory,
        shardIndex: UInt16
    ) async throws {
        let metadataKey = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        )
        let physical = try #require(try await store.fetch(
            namespace: namespace,
            key: metadataKey
        ))
        let metadata = try ProgressionDeterminism.decoder().decode(
            ProgressionMetadataRecord.self,
            from: physical.payload
        )
        let key = ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.projectionCollection,
            recordID: ProgressionRepositoryIDs.shardRecordID(
                generation: metadata.activeGeneration,
                category: category,
                shardIndex: shardIndex
            )
        )
        await store.corruptIntegrityDigest(namespace: namespace, key: key)
    }

    func recordedTransactions() -> [ModuleStateTransaction] {
        transactions
    }

    func clearRecordedTransactions() {
        transactions.removeAll()
    }

    private func corruptAndDiscover(_ key: ModuleStateRecordKey) async throws {
        await store.corruptIntegrityDigest(namespace: namespace, key: key)
        do {
            _ = try await store.fetch(namespace: namespace, key: key)
            throw ProgressionDomainError.invalidRecord("test-corruption-not-detected")
        } catch ModuleStateStoreError.integrityMismatch {
            return
        }
    }

    private func rewrite(
        _ physical: ModuleStateRecord,
        payload: Data,
        transactionMaterial: String
    ) async throws {
        _ = try await store.transact(
            namespace: namespace,
            transaction: try ModuleStateTransaction(
                transactionID: ProgressionDeterminism.transactionUUID(transactionMaterial),
                mutations: [.upsert(ModuleStateUpsert(
                    key: physical.key,
                    schemaVersion: physical.schemaVersion,
                    payload: payload,
                    expectedRevision: .exact(physical.revision)
                ))]
            )
        )
    }
}
