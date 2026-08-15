import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeTestSupport
import Testing
@testable import RuneScribeProgressionModule

@Test
func faultMatrixCoversEmptyNamespaceWriteAndInitializationSeal() async throws {
    let baseline = try ProgressionDurableFixture()
    await baseline.client.clearRecordedTransactions()
    let baselineService = try await baseline.bootstrap()
    let baselineTransactions = await baseline.client.recordedTransactions()
    let baselineRecordCount = await baseline.client.recordCount()
    let baselineMetadata = try await baseline.client.activeMetadata()
    await baselineService.shutdown()

    #expect(baselineTransactions.count == 2)
    #expect(baselineMetadata.initializedAt != nil)
    #expect(baselineRecordCount > 0)
    assertTransactionBounds(baselineTransactions)
    assertInitializationTransactions(baselineTransactions)

    for faultPoint in transactionFaultPoints {
        for transactionIndex in baselineTransactions.indices {
            let fixture = try ProgressionDurableFixture()
            await fixture.client.clearRecordedTransactions()
            await fixture.store.injectFault(
                at: faultPoint,
                afterSuccessfulCalls: transactionIndex
            )

            let interrupted = try? await fixture.bootstrap()
            await interrupted?.shutdown()

            let interruptedRecordCount = await fixture.client.recordCount()
            if faultPoint == .beforeTransactionCommit, transactionIndex == 0 {
                #expect(interruptedRecordCount == 0)
            } else {
                #expect(interruptedRecordCount > 0)
            }

            let recovered: RuneScribeProgressionServiceActor
            do {
                recovered = try await fixture.bootstrap()
            } catch {
                Issue.record(
                    "Initialization recovery failed at \(faultPoint.rawValue) transaction \(transactionIndex): \(error)"
                )
                continue
            }
            let recoveredMetadata = try await fixture.client.activeMetadata()
            let recoveredSnapshot = try await fixture.snapshot(
                from: recovered,
                suffix: "fault-init-\(faultPoint.rawValue)-\(transactionIndex)"
            )
            #expect(recoveredMetadata.initializedAt == baselineMetadata.initializedAt)
            #expect(recoveredSnapshot.revision == 0)
            #expect(await fixture.client.recordCount() == baselineRecordCount)
            assertTransactionBounds(await fixture.client.recordedTransactions())
            await recovered.shutdown()
        }
    }
}

@Test
func faultMatrixKeepsCascadeCompletionAndRewardsAtomic() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await baseline.bootstrap()
    try await seedFirstDeliveryProgress(baseline, service: baselineService)
    let baselineBefore = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-event-baseline-before"
    )
    let event = try baseline.firstDeliveryEvent(
        index: 5,
        occurredAt: Date(timeIntervalSince1970: 2_000_005_000)
    )
    await baseline.client.clearRecordedTransactions()
    let baselineOutcome = try await baselineService.applyEvent(
        event,
        metadata: baseline.metadata(
            operation: "progression.event.apply",
            suffix: "fault-event-cascade"
        )
    )
    guard case let .applied(_, _, delta) = baselineOutcome else {
        Issue.record("The cascade baseline event did not apply.")
        return
    }
    let baselineAfter = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-event-baseline-after"
    )
    let baselineTransactions = await baseline.client.recordedTransactions()
    await baselineService.shutdown()

    #expect(baselineTransactions.count == 1)
    #expect(delta.completedAchievementCount > 0)
    #expect(delta.completedMilestoneCount > 0)
    #expect(delta.grantedContentCount > 0)
    #expect(delta.queuedRevealCount == 1)
    #expect(
        baselineAfter.achievements.filter(\.progress.isComplete).count >
            baselineBefore.achievements.filter(\.progress.isComplete).count
    )
    #expect(
        baselineAfter.ownership.filter { $0.state == .owned }.count >
            baselineBefore.ownership.filter { $0.state == .owned }.count
    )
    #expect(baselineAfter.entitlementIDs.count > baselineBefore.entitlementIDs.count)
    #expect(baselineAfter.pendingRevealCount == baselineBefore.pendingRevealCount + 1)
    let newlyCompletedAchievements = Set(baselineAfter.achievements.compactMap {
        $0.progress.isComplete ? $0.achievementID.rawValue : nil
    }).subtracting(baselineBefore.achievements.compactMap {
        $0.progress.isComplete ? $0.achievementID.rawValue : nil
    })
    #expect(newlyCompletedAchievements == ["achievement.five-circles"])
    let newlyOwned = Set(baselineAfter.ownership.filter {
        $0.state == .owned
    }.map { faultReferenceRawValue($0.reference) }).subtracting(
        baselineBefore.ownership.filter { $0.state == .owned }.map {
            faultReferenceRawValue($0.reference)
        }
    )
    #expect(newlyOwned == [
        "artifact:relic.moonleaf.tablet",
        "artifact:script.moonleaf",
        "artifact:seal.moonleaf.crescentleaf",
        "artifact:seal.moonleaf.woodland-stag",
        "codex:codex.moonleaf",
        "entitlement:unlock.codex.moonleaf",
    ])
    let reveal = try #require(baselineAfter.nextReveal)
    #expect(reveal.tier == .codex)
    #expect(faultReferenceRawValue(reveal.primaryRewardID) == "codex:codex.moonleaf")
    #expect(reveal.secondaryRewardIDs.map(faultReferenceRawValue) == [
        "artifact:relic.moonleaf.tablet",
        "artifact:script.moonleaf",
        "artifact:seal.moonleaf.crescentleaf",
        "artifact:seal.moonleaf.woodland-stag",
        "entitlement:unlock.codex.moonleaf",
    ])
    #expect(reveal.sourceAchievementIDs.map(\.rawValue) == [
        "achievement.five-circles",
    ])
    #expect(reveal.sourceRuleIDs.map(\.rawValue) == [
        "rule.codex.moonleaf.known-in-five-circles",
    ])
    assertAtomicCascadeTransaction(baselineTransactions[0])
    assertTransactionBounds(baselineTransactions)

    let beforeFingerprint = FaultDomainFingerprint(baselineBefore)
    let afterFingerprint = FaultDomainFingerprint(baselineAfter)
    for faultPoint in transactionFaultPoints {
        let fixture = try ProgressionDurableFixture()
        let service = try await fixture.bootstrap()
        try await seedFirstDeliveryProgress(fixture, service: service)
        let before = try await fixture.snapshot(
            from: service,
            suffix: "fault-event-before-\(faultPoint.rawValue)"
        )
        #expect(FaultDomainFingerprint(before) == beforeFingerprint)
        let candidate = try fixture.firstDeliveryEvent(
            index: 5,
            occurredAt: Date(timeIntervalSince1970: 2_000_005_000)
        )
        let operation = try fixture.metadata(
            operation: "progression.event.apply",
            suffix: "fault-event-cascade"
        )
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(at: faultPoint)

        #expect(
            try await service.applyEvent(candidate, metadata: operation)
                == .deferredStoreUnavailable
        )
        await service.shutdown()

        let relaunched = try await fixture.bootstrap()
        let interruptedSnapshot = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-event-interrupted-\(faultPoint.rawValue)"
        )
        #expect(
            FaultDomainFingerprint(interruptedSnapshot) ==
                (faultPoint == .beforeTransactionCommit
                    ? beforeFingerprint : afterFingerprint)
        )
        let replay = try await relaunched.applyEvent(candidate, metadata: operation)
        if faultPoint == .beforeTransactionCommit {
            guard case .applied = replay else {
                Issue.record("A before-commit cascade did not apply on retry.")
                return
            }
        } else {
            #expect(replay == .duplicate)
        }
        let final = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-event-final-\(faultPoint.rawValue)"
        )
        #expect(FaultDomainFingerprint(final) == afterFingerprint)
        assertTransactionBounds(await fixture.client.recordedTransactions())
        await relaunched.shutdown()
    }
}

private func faultReferenceRawValue(
    _ reference: ProgressionContentReference
) -> String {
    switch reference {
    case .codex(let value): "codex:\(value.rawValue)"
    case .artifact(let value): "artifact:\(value.rawValue)"
    case .title(let value): "title:\(value.rawValue)"
    case .entitlement(let value): "entitlement:\(value.rawValue)"
    case .crest(let value): "crest:\(value.rawValue)"
    case .unknown: "unknown"
    }
}

@Test
func faultMatrixReconcilesRevealAcknowledgementBeforeAndAfterCommit() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await baseline.bootstrap()
    _ = try await baselineService.applyEvent(
        baseline.messageEncodedEvent(
            index: 171,
            occurredAt: Date(timeIntervalSince1970: 2_000_005_100)
        ),
        metadata: baseline.metadata(
            operation: "progression.event.apply",
            suffix: "fault-ack-source"
        )
    )
    let baselineBefore = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-ack-baseline-before"
    )
    let revealID = try #require(baselineBefore.nextReveal?.revealID)
    try await baselineService.markRevealPresented(
        MarkProgressionRevealPresentedCommand(revealID: revealID),
        metadata: baseline.metadata(
            operation: "progression.reveal.mark-presented",
            suffix: "fault-ack-present",
            timestamp: Date(timeIntervalSince1970: 2_000_005_150)
        )
    )
    let presentedBaselineBefore = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-ack-presented-baseline-before"
    )
    let command = AcknowledgeProgressionRevealCommand(revealID: revealID)
    let operation = try baseline.metadata(
        operation: "progression.reveal.acknowledge",
        suffix: "fault-ack-command",
        timestamp: Date(timeIntervalSince1970: 2_000_005_200)
    )
    await baseline.client.clearRecordedTransactions()
    try await baselineService.acknowledgeReveal(command, metadata: operation)
    let baselineAfter = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-ack-baseline-after"
    )
    let baselineTransactions = await baseline.client.recordedTransactions()
    await baselineService.shutdown()

    #expect(baselineTransactions.count == 1)
    #expect(presentedBaselineBefore.pendingRevealCount == 1)
    #expect(presentedBaselineBefore.nextReveal?.state == .presented)
    #expect(baselineAfter.pendingRevealCount == 0)
    #expect(baselineAfter.nextReveal == nil)
    assertTransactionBounds(baselineTransactions)

    for faultPoint in transactionFaultPoints {
        let fixture = try ProgressionDurableFixture()
        let service = try await fixture.bootstrap()
        _ = try await service.applyEvent(
            fixture.messageEncodedEvent(
                index: 171,
                occurredAt: Date(timeIntervalSince1970: 2_000_005_100)
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "fault-ack-source"
            )
        )
        let before = try await fixture.snapshot(
            from: service,
            suffix: "fault-ack-before-\(faultPoint.rawValue)"
        )
        let candidate = AcknowledgeProgressionRevealCommand(
            revealID: try #require(before.nextReveal?.revealID)
        )
        try await service.markRevealPresented(
            MarkProgressionRevealPresentedCommand(revealID: candidate.revealID),
            metadata: fixture.metadata(
                operation: "progression.reveal.mark-presented",
                suffix: "fault-ack-present",
                timestamp: Date(timeIntervalSince1970: 2_000_005_150)
            )
        )
        let candidateOperation = try fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "fault-ack-command",
            timestamp: Date(timeIntervalSince1970: 2_000_005_200)
        )
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(at: faultPoint)
        do {
            try await service.acknowledgeReveal(candidate, metadata: candidateOperation)
            Issue.record("The acknowledgement fault did not interrupt the command.")
        } catch {
            // The same command is resumed after actor relaunch below.
        }
        await service.shutdown()

        let relaunched = try await fixture.bootstrap()
        let interrupted = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-ack-interrupted-\(faultPoint.rawValue)"
        )
        #expect(
            FaultDomainFingerprint(interrupted) ==
                (faultPoint == .beforeTransactionCommit
                    ? FaultDomainFingerprint(presentedBaselineBefore)
                    : FaultDomainFingerprint(baselineAfter))
        )
        try await relaunched.acknowledgeReveal(candidate, metadata: candidateOperation)
        let final = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-ack-final-\(faultPoint.rawValue)"
        )
        #expect(FaultDomainFingerprint(final) == FaultDomainFingerprint(baselineAfter))
        assertTransactionBounds(await fixture.client.recordedTransactions())
        await relaunched.shutdown()
    }
}

@Test
func faultMatrixReconcilesRevealPresentationBeforeAndAfterCommit() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await baseline.bootstrap()
    _ = try await baselineService.applyEvent(
        baseline.messageEncodedEvent(
            index: 172,
            occurredAt: Date(timeIntervalSince1970: 2_000_005_300)
        ),
        metadata: baseline.metadata(
            operation: "progression.event.apply",
            suffix: "fault-present-source"
        )
    )
    let baselineBefore = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-present-baseline-before"
    )
    let command = MarkProgressionRevealPresentedCommand(
        revealID: try #require(baselineBefore.nextReveal?.revealID)
    )
    let operation = try baseline.metadata(
        operation: "progression.reveal.mark-presented",
        suffix: "fault-present-command",
        timestamp: Date(timeIntervalSince1970: 2_000_005_400)
    )
    await baseline.client.clearRecordedTransactions()
    try await baselineService.markRevealPresented(command, metadata: operation)
    let baselineAfter = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-present-baseline-after"
    )
    let baselineTransactions = await baseline.client.recordedTransactions()
    await baselineService.shutdown()

    #expect(baselineTransactions.count == 1)
    #expect(baselineBefore.nextReveal?.state == .pending)
    #expect(baselineAfter.nextReveal?.state == .presented)
    #expect(baselineAfter.pendingRevealCount == 1)
    assertTransactionBounds(baselineTransactions)

    for faultPoint in transactionFaultPoints {
        let fixture = try ProgressionDurableFixture()
        let service = try await fixture.bootstrap()
        _ = try await service.applyEvent(
            fixture.messageEncodedEvent(
                index: 172,
                occurredAt: Date(timeIntervalSince1970: 2_000_005_300)
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "fault-present-source"
            )
        )
        let before = try await fixture.snapshot(
            from: service,
            suffix: "fault-present-before-\(faultPoint.rawValue)"
        )
        let candidate = MarkProgressionRevealPresentedCommand(
            revealID: try #require(before.nextReveal?.revealID)
        )
        let candidateOperation = try fixture.metadata(
            operation: "progression.reveal.mark-presented",
            suffix: "fault-present-command",
            timestamp: Date(timeIntervalSince1970: 2_000_005_400)
        )
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(at: faultPoint)
        do {
            try await service.markRevealPresented(
                candidate,
                metadata: candidateOperation
            )
            Issue.record("The reveal-presentation fault did not interrupt the command.")
        } catch {
            // The same command is resumed after actor relaunch below.
        }
        await service.shutdown()

        let relaunched = try await fixture.bootstrap()
        let interrupted = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-present-interrupted-\(faultPoint.rawValue)"
        )
        #expect(
            FaultDomainFingerprint(interrupted) ==
                (faultPoint == .beforeTransactionCommit
                    ? FaultDomainFingerprint(baselineBefore)
                    : FaultDomainFingerprint(baselineAfter))
        )
        try await relaunched.markRevealPresented(
            candidate,
            metadata: candidateOperation
        )
        let final = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-present-final-\(faultPoint.rawValue)"
        )
        #expect(FaultDomainFingerprint(final) == FaultDomainFingerprint(baselineAfter))
        assertTransactionBounds(await fixture.client.recordedTransactions())
        await relaunched.shutdown()
    }
}

@Test
func faultMatrixReconcilesTitleSelectionBeforeAndAfterCommit() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await baseline.bootstrap()
    _ = try await baselineService.applyEvent(
        baseline.messageDecodedEvent(
            index: 176,
            occurredAt: Date(timeIntervalSince1970: 2_000_005_300)
        ),
        metadata: baseline.metadata(
            operation: "progression.event.apply",
            suffix: "fault-title-source"
        )
    )
    let baselineBefore = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-title-baseline-before"
    )
    let titleID = try #require(baselineBefore.titles.first(where: \.isOwned)?.titleID)
    let command = SelectProgressionTitleCommand(titleID: titleID)
    let operation = try baseline.metadata(
        operation: "progression.title.select",
        suffix: "fault-title-command",
        timestamp: Date(timeIntervalSince1970: 2_000_005_400)
    )
    await baseline.client.clearRecordedTransactions()
    try await baselineService.selectTitle(command, metadata: operation)
    let baselineAfter = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-title-baseline-after"
    )
    let baselineTransactions = await baseline.client.recordedTransactions()
    await baselineService.shutdown()

    #expect(baselineTransactions.count == 1)
    #expect(baselineBefore.selectedTitleID == nil)
    #expect(baselineAfter.selectedTitleID == titleID)
    assertTransactionBounds(baselineTransactions)

    for faultPoint in transactionFaultPoints {
        let fixture = try ProgressionDurableFixture()
        let service = try await fixture.bootstrap()
        _ = try await service.applyEvent(
            fixture.messageDecodedEvent(
                index: 176,
                occurredAt: Date(timeIntervalSince1970: 2_000_005_300)
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "fault-title-source"
            )
        )
        let before = try await fixture.snapshot(
            from: service,
            suffix: "fault-title-before-\(faultPoint.rawValue)"
        )
        let candidateTitle = try #require(before.titles.first(where: \.isOwned)?.titleID)
        let candidate = SelectProgressionTitleCommand(titleID: candidateTitle)
        let candidateOperation = try fixture.metadata(
            operation: "progression.title.select",
            suffix: "fault-title-command",
            timestamp: Date(timeIntervalSince1970: 2_000_005_400)
        )
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(at: faultPoint)
        do {
            try await service.selectTitle(candidate, metadata: candidateOperation)
            Issue.record("The title-selection fault did not interrupt the command.")
        } catch {
            // The same command is resumed after actor relaunch below.
        }
        await service.shutdown()

        let relaunched = try await fixture.bootstrap()
        let interrupted = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-title-interrupted-\(faultPoint.rawValue)"
        )
        #expect(
            FaultDomainFingerprint(interrupted) ==
                (faultPoint == .beforeTransactionCommit
                    ? FaultDomainFingerprint(baselineBefore)
                    : FaultDomainFingerprint(baselineAfter))
        )
        try await relaunched.selectTitle(candidate, metadata: candidateOperation)
        let final = try await fixture.snapshot(
            from: relaunched,
            suffix: "fault-title-final-\(faultPoint.rawValue)"
        )
        #expect(FaultDomainFingerprint(final) == FaultDomainFingerprint(baselineAfter))
        assertTransactionBounds(await fixture.client.recordedTransactions())
        await relaunched.shutdown()
    }
}

@Test
func faultMatrixCoversEveryRebuildTransactionAcrossRelaunch() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await seededFaultService(baseline, index: 172)
    let baselineBefore = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-rebuild-baseline-before"
    )
    let oldGeneration = try await baseline.client.activeMetadata().activeGeneration
    let request = ProgressionRecoveryRequest(
        confirmationToken: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
    )
    let operation = try baseline.metadata(
        operation: "progression.recovery.rebuild",
        suffix: "fault-rebuild"
    )
    await baseline.client.clearRecordedTransactions()
    _ = try await baselineService.rebuild(request, metadata: operation)
    let baselineAfter = try await baseline.snapshot(
        from: baselineService,
        suffix: "fault-rebuild-baseline-after"
    )
    let newGeneration = try await baseline.client.activeMetadata().activeGeneration
    let baselineTransactions = await baseline.client.recordedTransactions()
    await baselineService.shutdown()

    #expect(!baselineTransactions.isEmpty)
    #expect(oldGeneration != newGeneration)
    assertRebuildPhaseCoverage(
        baselineTransactions,
        oldGeneration: oldGeneration,
        newGeneration: newGeneration
    )
    assertTransactionBounds(baselineTransactions)
    let beforeFingerprint = FaultDomainFingerprint(baselineBefore)
    let afterFingerprint = FaultDomainFingerprint(baselineAfter)

    for faultPoint in transactionFaultPoints {
        for transactionIndex in baselineTransactions.indices {
            let fixture = try ProgressionDurableFixture()
            let service = try await seededFaultService(fixture, index: 172)
            let scenarioOldGeneration = try await fixture.client.activeMetadata().activeGeneration
            let candidateRequest = ProgressionRecoveryRequest(
                confirmationToken: UUID(
                    uuidString: "81000000-0000-0000-0000-000000000001"
                )!
            )
            let candidateOperation = try fixture.metadata(
                operation: "progression.recovery.rebuild",
                suffix: "fault-rebuild"
            )
            await fixture.client.clearRecordedTransactions()
            await fixture.store.injectFault(
                at: faultPoint,
                afterSuccessfulCalls: transactionIndex
            )
            do {
                _ = try await service.rebuild(
                    candidateRequest,
                    metadata: candidateOperation
                )
                Issue.record(
                    "Rebuild transaction \(transactionIndex) did not observe \(faultPoint.rawValue)."
                )
            } catch {
                // Relaunch and deterministic command replay complete the operation below.
            }
            await service.shutdown()

            let relaunched = try await fixture.bootstrap()
            let interrupted = try await fixture.snapshot(
                from: relaunched,
                suffix: "fault-rebuild-interrupted-\(faultPoint.rawValue)-\(transactionIndex)"
            )
            let interruptedFingerprint = FaultDomainFingerprint(interrupted)
            #expect(
                interruptedFingerprint == beforeFingerprint ||
                    interruptedFingerprint == afterFingerprint
            )
            _ = try await relaunched.rebuild(
                candidateRequest,
                metadata: candidateOperation
            )
            let final = try await fixture.snapshot(
                from: relaunched,
                suffix: "fault-rebuild-final-\(faultPoint.rawValue)-\(transactionIndex)"
            )
            #expect(FaultDomainFingerprint(final) == afterFingerprint)
            #expect(try await fixture.client.rebuildStageDestination() == nil)
            #expect(
                try await fixture.client.generationRecordCount(scenarioOldGeneration) == 0
            )
            assertTransactionBounds(await fixture.client.recordedTransactions())
            await relaunched.shutdown()
        }
    }
}

@Test
func faultMatrixCoversEveryCatalogUpgradeTransactionAcrossRelaunch() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineV1 = try await seededFaultService(baseline, index: 173)
    let baselineBefore = try await baseline.snapshot(
        from: baselineV1,
        suffix: "fault-upgrade-baseline-before"
    )
    let oldGeneration = try await baseline.client.activeMetadata().activeGeneration
    await baselineV1.shutdown()
    await baseline.client.clearRecordedTransactions()
    let baselineV2 = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: baseline.additiveVersionTwoBundle(),
        stateClient: baseline.client
    )
    let baselineAfter = try await baseline.snapshot(
        from: baselineV2,
        suffix: "fault-upgrade-baseline-after"
    )
    let newGeneration = try await baseline.client.activeMetadata().activeGeneration
    let baselineTransactions = await baseline.client.recordedTransactions()
    await baselineV2.shutdown()

    #expect(!baselineTransactions.isEmpty)
    #expect(oldGeneration != newGeneration)
    #expect(baselineAfter.catalogVersion == ProgressionCatalogVersion(rawValue: 2))
    assertUpgradePhaseCoverage(
        baselineTransactions,
        oldGeneration: oldGeneration,
        newGeneration: newGeneration
    )
    assertTransactionBounds(baselineTransactions)
    let beforeFingerprint = FaultDomainFingerprint(baselineBefore)
    let afterFingerprint = FaultDomainFingerprint(baselineAfter)

    for faultPoint in transactionFaultPoints {
        for transactionIndex in baselineTransactions.indices {
            let fixture = try ProgressionDurableFixture()
            let versionOne = try await seededFaultService(fixture, index: 173)
            let scenarioOldGeneration = try await fixture.client.activeMetadata().activeGeneration
            await versionOne.shutdown()
            await fixture.client.clearRecordedTransactions()
            await fixture.store.injectFault(
                at: faultPoint,
                afterSuccessfulCalls: transactionIndex
            )

            let interrupted = try? await RuneScribeProgressionServiceActor.bootstrapForTesting(
                catalogBundle: fixture.additiveVersionTwoBundle(),
                stateClient: fixture.client
            )
            await interrupted?.shutdown()
            let interruptedMetadata = try await fixture.client.activeMetadata()
            #expect(
                interruptedMetadata.catalogVersion == ProgressionCatalogVersion(rawValue: 1) ||
                    interruptedMetadata.catalogVersion == ProgressionCatalogVersion(rawValue: 2)
            )
            if interruptedMetadata.catalogVersion == ProgressionCatalogVersion(rawValue: 1) {
                #expect(interruptedMetadata.activeGeneration == scenarioOldGeneration)
                #expect(interruptedMetadata.revision == baselineBefore.revision)
            } else {
                #expect(interruptedMetadata.activeGeneration != scenarioOldGeneration)
            }

            let recovered = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
                catalogBundle: fixture.additiveVersionTwoBundle(),
                stateClient: fixture.client
            )
            let final = try await fixture.snapshot(
                from: recovered,
                suffix: "fault-upgrade-final-\(faultPoint.rawValue)-\(transactionIndex)"
            )
            #expect(FaultDomainFingerprint(final) == afterFingerprint)
            #expect(
                try await fixture.client.generationRecordCount(scenarioOldGeneration) == 0
            )
            assertTransactionBounds(await fixture.client.recordedTransactions())
            await recovered.shutdown()
        }
    }

    #expect(beforeFingerprint.catalogVersion == ProgressionCatalogVersion(rawValue: 1))
}

@Test
func faultMatrixPersistsQuarantineEvidenceAcrossBothInterruptionBoundaries() async throws {
    for faultPoint in transactionFaultPoints {
        let fixture = try await corruptAppliedOrderFixture(index: 174)
        let metadata = try await fixture.client.activeMetadata()
        let repository = ProgressionRepository(client: fixture.client)
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(at: faultPoint)

        await expectAppliedOrderReadToFail(
            repository,
            generation: metadata.activeGeneration
        )
        let interruptedHealth = try await fixture.client.health()
        let interruptedEvidence = try await quarantineEvidence(fixture.client)
        #expect(interruptedHealth.quarantinedRecordCount == 0)
        #expect(
            interruptedEvidence.count ==
                (faultPoint == .afterTransactionCommit ? 1 : 0)
        )

        let relaunchedRepository = ProgressionRepository(client: fixture.client)
        await expectAppliedOrderReadToFail(
            relaunchedRepository,
            generation: metadata.activeGeneration
        )
        try await assertCompletedQuarantine(
            fixture,
            sourceGeneration: metadata.activeGeneration
        )
        assertTransactionBounds(await fixture.client.recordedTransactions())
    }

    for faultPoint in [
        InMemoryModuleStateFaultPoint.quarantineRecord,
        .afterQuarantineRecord,
    ] {
        let fixture = try await corruptAppliedOrderFixture(index: 175)
        let metadata = try await fixture.client.activeMetadata()
        let repository = ProgressionRepository(client: fixture.client)
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(at: faultPoint)

        await expectAppliedOrderReadToFail(
            repository,
            generation: metadata.activeGeneration
        )
        let interruptedHealth = try await fixture.client.health()
        #expect(
            interruptedHealth.quarantinedRecordCount ==
                (faultPoint == .afterQuarantineRecord ? 1 : 0)
        )
        #expect(try await quarantineEvidence(fixture.client).count == 1)

        let relaunchedRepository = ProgressionRepository(client: fixture.client)
        await expectAppliedOrderReadToFail(
            relaunchedRepository,
            generation: metadata.activeGeneration
        )
        try await assertCompletedQuarantine(
            fixture,
            sourceGeneration: metadata.activeGeneration
        )
        assertTransactionBounds(await fixture.client.recordedTransactions())
    }
}

private let transactionFaultPoints: [InMemoryModuleStateFaultPoint] = [
    .beforeTransactionCommit,
    .afterTransactionCommit,
]

private struct FaultDomainFingerprint: Equatable {
    let revision: UInt64
    let catalogVersion: ProgressionCatalogVersion?
    let codexGates: [ProgressionCodexGateDTO]
    let achievements: [ProgressionAchievementDTO]
    let statistics: [ProgressionStatisticDTO]
    let ownership: [ProgressionOwnershipDTO]
    let encounters: [ProgressionEncounterDTO]
    let archive: [ProgressionArchiveEntryDTO]
    let titles: [ProgressionTitleDTO]
    let selectedTitleID: TitleID?
    let pendingRevealCount: UInt16
    let nextReveal: ProgressionRevealSummaryDTO?
    let entitlementIDs: [UnlockID]

    init(_ snapshot: ProgressionSnapshotDTO) {
        revision = snapshot.revision
        catalogVersion = snapshot.catalogVersion
        codexGates = snapshot.codexGates
        achievements = snapshot.achievements
        statistics = snapshot.statistics
        ownership = snapshot.ownership
        encounters = snapshot.encounters
        archive = snapshot.archive
        titles = snapshot.titles
        selectedTitleID = snapshot.selectedTitleID
        pendingRevealCount = snapshot.pendingRevealCount
        nextReveal = snapshot.nextReveal
        entitlementIDs = snapshot.entitlementIDs
    }
}

private func seededFaultService(
    _ fixture: ProgressionDurableFixture,
    index: UInt32
) async throws -> RuneScribeProgressionServiceActor {
    let service = try await fixture.bootstrap()
    guard case .applied = try await service.applyEvent(
        fixture.cipherEvent(index: index),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "fault-seed-\(index)"
        )
    ) else {
        throw ProgressionDomainError.invalidRecord("fault-seed")
    }
    return service
}

private func seedFirstDeliveryProgress(
    _ fixture: ProgressionDurableFixture,
    service: RuneScribeProgressionServiceActor
) async throws {
    for index in UInt32(1) ... UInt32(4) {
        guard case .applied = try await service.applyEvent(
            fixture.firstDeliveryEvent(
                index: index,
                occurredAt: Date(timeIntervalSince1970: 2_000_004_900 + Double(index))
            ),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "fault-cascade-seed-\(index)"
            )
        ) else {
            throw ProgressionDomainError.invalidRecord("fault-cascade-seed")
        }
    }
}

private func assertInitializationTransactions(
    _ transactions: [ModuleStateTransaction]
) {
    guard transactions.count == 2 else { return }
    let firstMetadata = transactions[0].mutations.compactMap { mutation -> ModuleStateUpsert? in
        guard case let .upsert(upsert) = mutation,
              upsert.key.collectionID == ProgressionRepositoryIDs.metadataCollection,
              upsert.key.recordID == ProgressionRepositoryIDs.activeMetadataRecord
        else { return nil }
        return upsert
    }.first
    let secondMetadata = transactions[1].mutations.compactMap {
        mutation -> ModuleStateUpsert? in
        guard case let .upsert(upsert) = mutation,
              upsert.key.collectionID == ProgressionRepositoryIDs.metadataCollection,
              upsert.key.recordID == ProgressionRepositoryIDs.activeMetadataRecord
        else { return nil }
        return upsert
    }.first
    #expect(firstMetadata?.expectedRevision == .absent)
    if case .exact = secondMetadata?.expectedRevision {
        // The initialization seal is revision-guarded.
    } else {
        Issue.record("The initialization seal did not guard the initialized namespace revision.")
    }
}

private func assertAtomicCascadeTransaction(_ transaction: ModuleStateTransaction) {
    var categories: Set<String> = []
    var queuedRevealMutationCount = 0
    var processedEventMutationCount = 0
    var distinctTokenMutationCount = 0
    for mutation in transaction.mutations {
        guard case let .upsert(upsert) = mutation else { continue }
        if upsert.key.collectionID == ProgressionRepositoryIDs.projectionCollection,
           let shard = try? ProgressionDeterminism.decoder().decode(
               ProgressionProjectionShard.self,
               from: upsert.payload
           )
        {
            categories.insert(shard.category.rawValue)
        }
        if upsert.key.collectionID == ProgressionRepositoryIDs.revealQueueCollection {
            queuedRevealMutationCount += 1
        }
        if upsert.key.collectionID.rawValue.hasPrefix("progression-events.") {
            processedEventMutationCount += 1
        }
        if upsert.key.collectionID == ProgressionRepositoryIDs.distinctCollection {
            distinctTokenMutationCount += 1
        }
    }
    for required in [
        ProgressionDiagnosticRecordCategory.statisticCounter,
        .achievementCompletion,
        .milestoneCompletion,
        .grant,
        .ownership,
        .entitlement,
        .pendingReveal,
    ] {
        #expect(categories.contains(required.rawValue))
    }
    #expect(queuedRevealMutationCount == 1)
    #expect(processedEventMutationCount == 1)
    #expect(distinctTokenMutationCount == 1)
}

private func assertRebuildPhaseCoverage(
    _ transactions: [ModuleStateTransaction],
    oldGeneration: String,
    newGeneration: String
) {
    #expect(transactions.contains { transaction in
        transaction.mutations.contains {
            $0.key.collectionID == ProgressionRepositoryIDs.metadataCollection &&
                $0.key.recordID == ProgressionRepositoryIDs.rebuildStageMarkerRecord
        }
    })
    assertGenerationTransitionPhaseCoverage(
        transactions,
        oldGeneration: oldGeneration,
        newGeneration: newGeneration,
        requireCleanupSeal: false
    )
}

private func assertUpgradePhaseCoverage(
    _ transactions: [ModuleStateTransaction],
    oldGeneration: String,
    newGeneration: String
) {
    assertGenerationTransitionPhaseCoverage(
        transactions,
        oldGeneration: oldGeneration,
        newGeneration: newGeneration,
        requireCleanupSeal: true
    )
}

private func assertGenerationTransitionPhaseCoverage(
    _ transactions: [ModuleStateTransaction],
    oldGeneration: String,
    newGeneration: String,
    requireCleanupSeal: Bool
) {
    let captureCollection = ProgressionRepositoryIDs.recoveryEventCollection(newGeneration)
    let commandCollection = ProgressionRepositoryIDs.commandCollection(newGeneration)
    #expect(transactions.contains { transaction in
        transaction.mutations.contains {
            if case .upsert = $0 {
                return $0.key.collectionID == captureCollection
            }
            return false
        }
    })
    #expect(transactions.contains { transaction in
        transaction.mutations.contains { mutation in
            guard case .upsert = mutation else { return false }
            return mutation.key.collectionID == ProgressionRepositoryIDs.projectionCollection &&
                mutation.key.recordID.rawValue.hasPrefix("shard.\(newGeneration).")
        }
    })
    #expect(transactions.contains { transaction in
        let keys = Set(transaction.mutations.map(\.key))
        return keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        )) && keys.contains(where: { $0.collectionID == commandCollection })
    })
    #expect(transactions.contains { transaction in
        transaction.mutations.contains { mutation in
            guard case .delete = mutation else { return false }
            return key(mutation.key, referencesGeneration: oldGeneration)
        }
    })
    #expect(transactions.contains { transaction in
        transaction.mutations.contains { mutation in
            guard case .delete = mutation else { return false }
            return mutation.key.collectionID == captureCollection
        }
    })
    if requireCleanupSeal {
        #expect(transactions.contains { transaction in
            let hasMetadata = transaction.mutations.contains {
                $0.key.collectionID == ProgressionRepositoryIDs.metadataCollection &&
                    $0.key.recordID == ProgressionRepositoryIDs.activeMetadataRecord
            }
            let hasMigrationShard = transaction.mutations.contains {
                $0.key.collectionID == ProgressionRepositoryIDs.projectionCollection &&
                    $0.key.recordID.rawValue ==
                        "shard.\(newGeneration).catalog-migration.0"
            }
            let hasCommand = transaction.mutations.contains {
                $0.key.collectionID == commandCollection
            }
            return hasMetadata && hasMigrationShard && !hasCommand
        })
    }
}

private func key(_ key: ModuleStateRecordKey, referencesGeneration generation: String) -> Bool {
    key.collectionID.rawValue.contains(generation) ||
        key.recordID.rawValue.contains(generation)
}

private func assertTransactionBounds(_ transactions: [ModuleStateTransaction]) {
    for transaction in transactions {
        #expect(transaction.mutations.count <= ModuleStateTransaction.maximumMutations)
        var aggregatePayloadBytes = 0
        for mutation in transaction.mutations {
            guard case let .upsert(upsert) = mutation else { continue }
            #expect(upsert.payload.count <= 1_048_576)
            aggregatePayloadBytes += upsert.payload.count
        }
        #expect(aggregatePayloadBytes <= 8_388_608)
    }
}

private func corruptAppliedOrderFixture(
    index: UInt32
) async throws -> ProgressionDurableFixture {
    let fixture = try ProgressionDurableFixture()
    let service = try await seededFaultService(fixture, index: index)
    await service.shutdown()
    let metadata = try await fixture.client.activeMetadata()
    let key = ModuleStateRecordKey(
        collectionID: ProgressionRepositoryIDs.eventOrderCollection(metadata.activeGeneration),
        recordID: ProgressionRepositoryIDs.eventOrderRecordID(1)
    )
    let physical = try #require(try await fixture.client.fetch(
        collectionID: key.collectionID,
        recordID: key.recordID
    ))
    _ = try await fixture.client.transact(try ModuleStateTransaction(
        transactionID: ProgressionDeterminism.transactionUUID(
            "fault-corrupt-order-\(index)"
        ),
        mutations: [.upsert(ModuleStateUpsert(
            key: key,
            schemaVersion: physical.schemaVersion,
            payload: Data("{}".utf8),
            expectedRevision: .exact(physical.revision)
        ))]
    ))
    return fixture
}

private func expectAppliedOrderReadToFail(
    _ repository: ProgressionRepository,
    generation: String
) async {
    do {
        _ = try await repository.appliedEventOrderRecord(1, generation: generation)
        Issue.record("A storage-valid malformed applied-order record was accepted.")
    } catch {
        // Decode failure, injected interruption, or already-quarantined access is expected.
    }
}

private func quarantineEvidence(
    _ client: ProgressionTestStateClient
) async throws -> [QuarantineRecord] {
    var result: [QuarantineRecord] = []
    var cursor: ModuleStateScanCursor?
    repeat {
        let page = try await client.scan(try ModuleStateScanRequest(
            collectionID: ProgressionRepositoryIDs.quarantineCollection,
            limit: ModuleStateScanRequest.maximumLimit,
            cursor: cursor
        ))
        for physical in page.records {
            let record = try ProgressionDeterminism.decoder().decode(
                QuarantineRecord.self,
                from: physical.payload
            )
            try record.validate()
            result.append(record)
        }
        cursor = page.nextCursor
    } while cursor != nil
    return result
}

private func assertCompletedQuarantine(
    _ fixture: ProgressionDurableFixture,
    sourceGeneration: String
) async throws {
    let health = try await fixture.client.health()
    let evidence = try await quarantineEvidence(fixture.client)
    #expect(health.quarantinedRecordCount == 1)
    #expect(evidence.count == 1)
    let record = try #require(evidence.first)
    #expect(record.category == .processedEvent)
    #expect(
        record.sourceCollectionID ==
            ProgressionRepositoryIDs.eventOrderCollection(sourceGeneration)
    )
    #expect(record.sourceRevision == 2)
    #expect(record.diagnosticCode == ProgressionRepositoryIDs.recordDecodeCode)
}
