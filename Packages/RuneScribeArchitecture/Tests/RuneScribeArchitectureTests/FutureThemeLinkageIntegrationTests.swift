import Foundation
import RuneScribeContracts
import RuneScribePlatform
import RuneScribeProgressionModule
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

final class FutureThemeLinkageIntegrationTests: XCTestCase {
    func testFifthDistinctDeliveryAtomicallyUnlocksAndActivatesMoonleaf() async throws {
        let harness = try await FutureThemeHarness.make(themeOutcome: .succeed)
        do {
            try await harness.start()
            let before = try await harness.migrateAndSeedFourDeliveries()

            let runtimeBefore = await harness.runtime.snapshot()
            XCTAssertEqual(runtimeBefore.status, .running)
            XCTAssertEqual(runtimeBefore.moduleStates[FutureThemeIDs.themeModule], .validated)
            let startCountBefore = await harness.themeProbe.startCount()
            XCTAssertEqual(startCountBefore, 0)
            assertFourOfFiveMoonleafState(before)

            let context = try await harness.coreCapture.backgroundContext()
            let batch = try ProgressionEventFactBatch(
                batchIndex: 0,
                totalBatchCount: 1,
                totalFactCount: 1,
                facts: [
                    try SlottedProgressionEventFact(
                        slot: ProgressionFactSlot(rawValue: 0),
                        fact: firstDeliveryFact(index: 5)
                    ),
                ]
            )
            let firstReceipt = try await harness.coreCapture.submit(
                batch: batch,
                context: context
            )

            let themeStarted = await eventually {
                await harness.themeProbe.startCount() == 1
            }
            guard themeStarted else {
                throw FutureThemeTestError.timedOut(
                    await harness.diagnostic(stage: "theme activation")
                )
            }
            let unavailableOwned = await eventually {
                guard let snapshot = await harness.uiCapture.latestProgressionSnapshot(),
                      snapshot.revision == before.revision + 1,
                      let moonleaf = ownership(.codex(FutureThemeIDs.moonleafCodex), in: snapshot)
                else { return false }
                return moonleaf.state == .owned
                    && moonleaf.providerAvailability == .unavailable
                    && moonleaf.renderState == .genericFallback
            }
            XCTAssertTrue(unavailableOwned)
            let committedValue = await harness.uiCapture.latestProgressionSnapshot()
            let committed = try XCTUnwrap(committedValue)
            assertAtomicMoonleafUnlock(before: before, after: committed)

            await harness.themeProbe.releaseActivation()
            let activated = await eventually {
                let runtime = await harness.runtime.snapshot()
                guard runtime.moduleStates[FutureThemeIDs.themeModule] == .active,
                      let snapshot = await harness.uiCapture.latestProgressionSnapshot(),
                      let moonleaf = ownership(.codex(FutureThemeIDs.moonleafCodex), in: snapshot)
                else { return false }
                return snapshot.revision == committed.revision
                    && snapshot.entitlementIDs == committed.entitlementIDs
                    && moonleaf.state == .owned
                    && moonleaf.providerAvailability == .active
                    && moonleaf.renderState == .providerAvailable
            }
            XCTAssertTrue(activated)

            let availableValue = await harness.uiCapture.latestProgressionSnapshot()
            let available = try XCTUnwrap(availableValue)
            XCTAssertEqual(available.revision, committed.revision)
            XCTAssertEqual(available.entitlementIDs, committed.entitlementIDs)
            XCTAssertEqual(available.nextReveal?.revealID, committed.nextReveal?.revealID)

            let retryReceipt = try await harness.coreCapture.submit(
                batch: batch,
                context: context
            )
            XCTAssertEqual(retryReceipt, firstReceipt)
            let unchanged = await remainsTrue {
                guard let snapshot = await harness.uiCapture.latestProgressionSnapshot()
                else { return false }
                return snapshot.revision == available.revision
                    && snapshot.pendingRevealCount == available.pendingRevealCount
                    && snapshot.nextReveal?.revealID == available.nextReveal?.revealID
                    && snapshot.entitlementIDs == available.entitlementIDs
            }
            XCTAssertTrue(unchanged)
            let startCountAfter = await harness.themeProbe.startCount()
            XCTAssertEqual(startCountAfter, 1)

            let runtimeAfter = await harness.runtime.snapshot()
            XCTAssertEqual(runtimeAfter.status, .running)
            XCTAssertEqual(runtimeAfter.moduleStates[RuneScribeModuleIDs.core], .active)
            XCTAssertEqual(runtimeAfter.moduleStates[RuneScribeModuleIDs.progression], .active)
            XCTAssertEqual(runtimeAfter.moduleStates[RuneScribeModuleIDs.primaryUI], .active)
            XCTAssertEqual(runtimeAfter.moduleStates[FutureThemeIDs.themeModule], .active)
            XCTAssertEqual(
                runtimeAfter.entitlementSnapshot.includedUnlockIDs,
                [RuneScribeUnlockIDs.norseCodex]
            )
            XCTAssertEqual(
                runtimeAfter.entitlementSnapshot.earnedUnlockIDs,
                [FutureThemeIDs.moonleafUnlock]
            )

            let progressionHistory = await harness.uiCapture.progressionSnapshots()
            let sameRevisionAvailability = progressionHistory.compactMap { snapshot ->
                ProgressionProviderAvailability? in
                guard snapshot.revision == committed.revision else { return nil }
                return ownership(.codex(FutureThemeIDs.moonleafCodex), in: snapshot)?
                    .providerAvailability
            }
            XCTAssertTrue(sameRevisionAvailability.contains(.unavailable))
            XCTAssertTrue(sameRevisionAvailability.contains(.active))

            assertNoDirectThemeProgressionCalls(
                await harness.runtime.callLedgerSnapshot()
            )
        } catch {
            await harness.stop()
            throw error
        }
        await harness.stop()
        let stopCount = await harness.themeProbe.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    func testMoonleafActivationFailurePreservesOwnershipAndRequiredModules() async throws {
        let harness = try await FutureThemeHarness.make(themeOutcome: .fail)
        do {
            try await harness.start()
            let before = try await harness.migrateAndSeedFourDeliveries()
            let context = try await harness.coreCapture.backgroundContext()
            let batch = try ProgressionEventFactBatch(
                batchIndex: 0,
                totalBatchCount: 1,
                totalFactCount: 1,
                facts: [
                    try SlottedProgressionEventFact(
                        slot: ProgressionFactSlot(rawValue: 0),
                        fact: firstDeliveryFact(index: 5)
                    ),
                ]
            )
            _ = try await harness.coreCapture.submit(batch: batch, context: context)

            let themeStarted = await eventually {
                await harness.themeProbe.startCount() == 1
            }
            guard themeStarted else {
                throw FutureThemeTestError.timedOut(
                    await harness.diagnostic(stage: "theme failure activation")
                )
            }
            let ownedBeforeFailure = await eventually {
                guard let snapshot = await harness.uiCapture.latestProgressionSnapshot(),
                      snapshot.revision == before.revision + 1,
                      let moonleaf = ownership(.codex(FutureThemeIDs.moonleafCodex), in: snapshot)
                else { return false }
                return moonleaf.state == .owned
                    && moonleaf.providerAvailability == .unavailable
            }
            XCTAssertTrue(ownedBeforeFailure)
            let durableValue = await harness.uiCapture.latestProgressionSnapshot()
            let durable = try XCTUnwrap(durableValue)
            assertAtomicMoonleafUnlock(before: before, after: durable)

            await harness.themeProbe.releaseActivation()
            let failedProjection = await eventually {
                let runtime = await harness.runtime.snapshot()
                guard runtime.moduleStates[FutureThemeIDs.themeModule] == .failed,
                      let snapshot = await harness.uiCapture.latestProgressionSnapshot(),
                      let moonleaf = ownership(.codex(FutureThemeIDs.moonleafCodex), in: snapshot)
                else { return false }
                return snapshot.revision == durable.revision
                    && snapshot.entitlementIDs == durable.entitlementIDs
                    && moonleaf.state == .owned
                    && moonleaf.providerAvailability == .failed
                    && moonleaf.renderState == .providerFailed
            }
            XCTAssertTrue(failedProjection)

            let runtimeAfter = await harness.runtime.snapshot()
            XCTAssertEqual(runtimeAfter.status, .running)
            XCTAssertEqual(runtimeAfter.moduleStates[RuneScribeModuleIDs.core], .active)
            XCTAssertEqual(runtimeAfter.moduleStates[RuneScribeModuleIDs.progression], .active)
            XCTAssertEqual(runtimeAfter.moduleStates[RuneScribeModuleIDs.primaryUI], .active)
            XCTAssertEqual(runtimeAfter.moduleStates[FutureThemeIDs.themeModule], .failed)
            XCTAssertEqual(
                runtimeAfter.entitlementSnapshot.includedUnlockIDs,
                [RuneScribeUnlockIDs.norseCodex]
            )
            XCTAssertEqual(
                runtimeAfter.entitlementSnapshot.earnedUnlockIDs,
                [FutureThemeIDs.moonleafUnlock]
            )
            let projectedValue = await harness.uiCapture.latestProgressionSnapshot()
            let projected = try XCTUnwrap(projectedValue)
            XCTAssertEqual(projected.revision, durable.revision)
            XCTAssertEqual(projected.entitlementIDs, durable.entitlementIDs)
            XCTAssertEqual(projected.nextReveal?.revealID, durable.nextReveal?.revealID)
            XCTAssertEqual(
                ownership(.codex(FutureThemeIDs.norseCodex), in: projected)?.state,
                .owned
            )
            assertNoDirectThemeProgressionCalls(
                await harness.runtime.callLedgerSnapshot()
            )
        } catch {
            await harness.stop()
            throw error
        }
        await harness.stop()
        let stopCount = await harness.themeProbe.stopCount()
        XCTAssertEqual(stopCount, 1)
    }

    private func assertFourOfFiveMoonleafState(
        _ snapshot: ProgressionSnapshotDTO,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let achievement = snapshot.achievements.first {
            $0.achievementID == FutureThemeIDs.fiveCirclesAchievement
        }
        XCTAssertEqual(achievement?.progress.current, 4, file: file, line: line)
        XCTAssertEqual(achievement?.progress.target, 5, file: file, line: line)
        XCTAssertFalse(achievement?.progress.isComplete ?? true, file: file, line: line)

        let gate = snapshot.codexGates.first {
            $0.codexID == FutureThemeIDs.moonleafCodex
        }
        XCTAssertEqual(gate?.progress.current, 0, file: file, line: line)
        XCTAssertEqual(gate?.progress.target, 1, file: file, line: line)
        XCTAssertNil(gate?.unlockedAt, file: file, line: line)
        XCTAssertEqual(gate?.components.count, 1, file: file, line: line)
        XCTAssertEqual(gate?.components.first?.current, 0, file: file, line: line)
        XCTAssertEqual(gate?.components.first?.target, 1, file: file, line: line)
        XCTAssertFalse(gate?.components.first?.isComplete ?? true, file: file, line: line)

        let moonleaf = ownership(.codex(FutureThemeIDs.moonleafCodex), in: snapshot)
        XCTAssertEqual(moonleaf?.state, .locked, file: file, line: line)
        XCTAssertEqual(moonleaf?.providerAvailability, .unavailable, file: file, line: line)
        XCTAssertEqual(moonleaf?.renderState, .locked, file: file, line: line)
        XCTAssertFalse(
            snapshot.entitlementIDs.contains(FutureThemeIDs.moonleafUnlock),
            file: file,
            line: line
        )
    }

    private func assertAtomicMoonleafUnlock(
        before: ProgressionSnapshotDTO,
        after: ProgressionSnapshotDTO,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(after.revision, before.revision + 1, file: file, line: line)

        let completedBefore = completedAchievementIDs(before)
        let completedAfter = completedAchievementIDs(after)
        XCTAssertEqual(
            completedAfter.subtracting(completedBefore),
            [FutureThemeIDs.fiveCirclesAchievement],
            file: file,
            line: line
        )
        let achievement = after.achievements.first {
            $0.achievementID == FutureThemeIDs.fiveCirclesAchievement
        }
        XCTAssertEqual(achievement?.progress.current, 5, file: file, line: line)
        XCTAssertEqual(achievement?.progress.target, 5, file: file, line: line)
        XCTAssertTrue(achievement?.progress.isComplete ?? false, file: file, line: line)

        let gate = after.codexGates.first {
            $0.codexID == FutureThemeIDs.moonleafCodex
        }
        XCTAssertEqual(gate?.progress.current, 1, file: file, line: line)
        XCTAssertEqual(gate?.progress.target, 1, file: file, line: line)
        XCTAssertNotNil(gate?.unlockedAt, file: file, line: line)
        XCTAssertEqual(gate?.components.count, 1, file: file, line: line)
        XCTAssertEqual(gate?.components.first?.current, 1, file: file, line: line)
        XCTAssertEqual(gate?.components.first?.target, 1, file: file, line: line)
        XCTAssertTrue(gate?.components.first?.isComplete ?? false, file: file, line: line)

        XCTAssertEqual(
            ownedReferenceKeys(after).subtracting(ownedReferenceKeys(before)),
            FutureThemeIDs.moonleafOwnershipBundle,
            file: file,
            line: line
        )
        XCTAssertEqual(
            Set(after.entitlementIDs).subtracting(before.entitlementIDs),
            [FutureThemeIDs.moonleafUnlock],
            file: file,
            line: line
        )
        XCTAssertEqual(after.pendingRevealCount, before.pendingRevealCount + 1, file: file, line: line)
        let reveal = after.nextReveal
        XCTAssertEqual(reveal?.state, .pending, file: file, line: line)
        XCTAssertEqual(reveal?.tier, .codex, file: file, line: line)
        XCTAssertEqual(
            reveal.map { referenceKey($0.primaryRewardID) },
            "codex:codex.moonleaf",
            file: file,
            line: line
        )
        XCTAssertEqual(
            reveal?.secondaryRewardIDs.map(referenceKey),
            [
                "artifact:relic.moonleaf.tablet",
                "artifact:script.moonleaf",
                "artifact:seal.moonleaf.crescentleaf",
                "artifact:seal.moonleaf.woodland-stag",
                "entitlement:unlock.codex.moonleaf",
            ],
            file: file,
            line: line
        )
        XCTAssertEqual(
            reveal?.sourceAchievementIDs,
            [FutureThemeIDs.fiveCirclesAchievement],
            file: file,
            line: line
        )
        XCTAssertEqual(
            reveal?.sourceRuleIDs,
            [FutureThemeIDs.moonleafGateRule],
            file: file,
            line: line
        )
    }

    private func assertNoDirectThemeProgressionCalls(
        _ ledger: [RuntimeCallLedgerRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            ledger.contains { record in
                let source = record.metadata.sourceModuleID
                let destination = record.metadata.destinationModuleID
                return (source == FutureThemeIDs.themeModule
                    && destination == RuneScribeModuleIDs.progression)
                    || (source == RuneScribeModuleIDs.progression
                        && destination == FutureThemeIDs.themeModule)
            },
            file: file,
            line: line
        )
        let applyEventID = RuntimeProgressionEndpointCatalog.applyEvent
            .descriptor.endpointID.rawValue
        XCTAssertEqual(
            ledger.filter {
                $0.metadata.operationIdentifier.rawValue == applyEventID
                    && $0.outcome == .succeeded
            }.count,
            5,
            file: file,
            line: line
        )
    }
}

private enum FutureThemeIDs {
    static let themeModule: ModuleIdentifier = "com.runescribe.module.theme.moonleaf"
    static let themeRole: ModuleRole = "runescribe.theme.moonleaf"
    static let runtimeHostModule: ModuleIdentifier = "application.host.runtime-source"
    static let progressionOutboxNamespace = ModuleStateNamespace(
        moduleID: "com.runescribe.runtime.progression-outbox"
    )
    static let progressionOutboxCollection = ModuleStateCollectionID(
        rawValue: "progression.outbox"
    )!
    static let moonleafUnlock = UnlockID(rawValue: "unlock.codex.moonleaf")!
    static let norseCodex = CodexID(rawValue: "codex.norse")!
    static let moonleafCodex = CodexID(rawValue: "codex.moonleaf")!
    static let fiveCirclesAchievement = AchievementID(
        rawValue: "achievement.five-circles"
    )!
    static let moonleafGateRule = RuleID(
        rawValue: "rule.codex.moonleaf.known-in-five-circles"
    )!
    static let moonleafOwnershipBundle: Set<String> = [
        "artifact:relic.moonleaf.tablet",
        "artifact:script.moonleaf",
        "artifact:seal.moonleaf.crescentleaf",
        "artifact:seal.moonleaf.woodland-stag",
        "codex:codex.moonleaf",
        "entitlement:unlock.codex.moonleaf",
    ]
}

private struct FutureThemeHarness {
    let runtime: RuneScribeRuntime
    let coreCapture: FutureThemeCoreCapture
    let uiCapture: FutureThemeUICapture
    let themeProbe: FutureThemeActivationProbe
    let stateStore: InMemoryModuleStateStore

    static func make(themeOutcome: FutureThemeActivationOutcome) async throws -> Self {
        let version = try SemanticVersion(major: 1, minor: 0, patch: 0)
        let clock = FutureThemeAdvancingClock(
            start: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let runtime = RuneScribeRuntime(
            runtimeVersion: version,
            platform: .macOS,
            environment: RuntimeEnvironment(now: { clock.now() }, nextUUID: { UUID() })
        )
        let coreCapture = FutureThemeCoreCapture()
        let uiCapture = FutureThemeUICapture()
        let themeProbe = FutureThemeActivationProbe(outcome: themeOutcome)
        let stateStore = InMemoryModuleStateStore(now: { clock.now() })

        let resources = BundleApplicationResourceLocator(
            bundle: RuneScribeProgressionModuleBootstrap.resourceBundle,
            moduleBundles: RuneScribeProgressionModuleBootstrap.ownerScopedResourceBundles
        )
        try await runtime.installPlatformAdapter(
            resources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            stateStore,
            for: RuneScribeServiceKeys.moduleStateStore
        )

        let core = coreDescriptor(version: version)
        try await runtime.register(
            manifest: manifest(for: core, runtimeVersion: version),
            factory: AnyModuleFactory(descriptor: core) {
                FutureThemeTestModule(
                    descriptor: core,
                    start: { context in
                        let outbox = try await context.progressionOutboxClient()
                        let migration = try await context.existingUserMigrationClient()
                        await coreCapture.install(outbox: outbox, migration: migration)
                    }
                )
            }
        )

        try await RuneScribeProgressionModuleBootstrap.register(with: runtime)

        let theme = themeDescriptor(version: version)
        try await runtime.register(
            manifest: manifest(
                for: theme,
                runtimeVersion: version,
                entitlement: EntitlementRequirement(
                    kind: .earned,
                    identifier: FutureThemeIDs.moonleafUnlock
                )
            ),
            factory: AnyModuleFactory(descriptor: theme) {
                FutureThemeTestModule(
                    descriptor: theme,
                    start: { _ in try await themeProbe.start() },
                    stop: { await themeProbe.stop() }
                )
            }
        )

        let ui = uiDescriptor(version: version)
        try await runtime.register(
            manifest: manifest(for: ui, runtimeVersion: version),
            factory: AnyModuleFactory(descriptor: ui) {
                FutureThemeTestModule(
                    descriptor: ui,
                    start: { context in
                        try await uiCapture.connect(
                            progression: context.progressionClient(),
                            availability: context.runtimeAvailabilityClient()
                        )
                    },
                    stop: { await uiCapture.stop() }
                )
            }
        )

        return Self(
            runtime: runtime,
            coreCapture: coreCapture,
            uiCapture: uiCapture,
            themeProbe: themeProbe,
            stateStore: stateStore
        )
    }

    func start() async throws {
        try await runtime.start()
        let snapshot = await runtime.snapshot()
        guard snapshot.status == .running,
              snapshot.moduleStates[RuneScribeModuleIDs.core] == .active,
              snapshot.moduleStates[RuneScribeModuleIDs.progression] == .active,
              snapshot.moduleStates[RuneScribeModuleIDs.primaryUI] == .active
        else { throw FutureThemeTestError.requiredModuleDidNotStart }
        let entitlementObservationReady = await eventually {
            let endpointID = RuntimeProgressionEndpointCatalog.entitlements
                .endpointID.rawValue
            return await runtime.callLedgerSnapshot().contains {
                $0.metadata.sourceModuleID == FutureThemeIDs.runtimeHostModule
                    && $0.metadata.operationIdentifier.rawValue == endpointID
                    && $0.outcome == .inFlight
            }
        }
        guard entitlementObservationReady else {
            throw FutureThemeTestError.timedOut(
                await diagnostic(stage: "runtime entitlement observation")
            )
        }
    }

    func stop() async {
        await themeProbe.releaseActivation()
        await runtime.stop()
        await uiCapture.stop()
    }

    func migrateAndSeedFourDeliveries() async throws -> ProgressionSnapshotDTO {
        let migrationReceipt = try await coreCapture.submitMigration(ciphers: [])
        var migrationApplied = false
        for _ in 0 ..< 10 where !migrationApplied {
            migrationApplied = await eventually(attempts: 50) {
                guard let snapshot = await uiCapture.latestProgressionSnapshot()
                else { return false }
                return snapshot.revision == 1
                    && snapshot.entitlementIDs.contains(RuneScribeUnlockIDs.norseCodex)
            }
            if !migrationApplied {
                let retry = try await coreCapture.submitMigration(ciphers: [])
                guard retry == migrationReceipt else {
                    throw FutureThemeTestError.migrationReceiptChanged
                }
            }
        }
        guard migrationApplied else {
            let revision = await uiCapture.latestProgressionSnapshot()?.revision
            let ledger = await runtime.callLedgerSnapshot().map {
                "\($0.metadata.sourceModuleID.rawValue):\($0.metadata.operationIdentifier.rawValue):\(String(describing: $0.outcome))"
            }
            throw FutureThemeTestError.timedOut(
                "migration revision=\(String(describing: revision)) ledger=\(ledger)"
            )
        }
        let migrationEndpointID = RuntimeProgressionEndpointCatalog
            .applyExistingUserMigration.descriptor.endpointID.rawValue
        let migrationHandlerFailures = await runtime.callLedgerSnapshot().compactMap {
            record -> String? in
            guard record.metadata.operationIdentifier.rawValue == migrationEndpointID,
                  record.outcome == .failed(.handlerFailure)
            else { return nil }
            return record.metadata.operationID.rawValue
        }
        guard migrationHandlerFailures.isEmpty else {
            throw FutureThemeTestError.migrationHandlerFailure(
                operationIDs: migrationHandlerFailures
            )
        }

        let context = try await coreCapture.backgroundContext()
        let facts = try (1 ... 4).map { index in
            try SlottedProgressionEventFact(
                slot: ProgressionFactSlot(rawValue: UInt32(index - 1)),
                fact: firstDeliveryFact(index: index)
            )
        }
        let batch = try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: 1,
            totalFactCount: 4,
            facts: facts
        )
        _ = try await coreCapture.submit(batch: batch, context: context)
        let applied = await eventually {
            guard let snapshot = await uiCapture.latestProgressionSnapshot(),
                  snapshot.revision == 5,
                  let achievement = snapshot.achievements.first(where: {
                      $0.achievementID == FutureThemeIDs.fiveCirclesAchievement
                  })
            else { return false }
            return achievement.progress.current == 4
                && achievement.progress.target == 5
                && !achievement.progress.isComplete
        }
        guard applied else {
            let latest = await uiCapture.latestProgressionSnapshot()
            let progress = latest?.achievements.first {
                $0.achievementID == FutureThemeIDs.fiveCirclesAchievement
            }?.progress.current
            let ledger = await runtime.callLedgerSnapshot().map {
                "\($0.metadata.sourceModuleID.rawValue):\($0.metadata.operationIdentifier.rawValue):\(String(describing: $0.outcome))"
            }
            throw FutureThemeTestError.timedOut(
                "seed revision=\(String(describing: latest?.revision)) progress=\(String(describing: progress)) ledger=\(ledger)"
            )
        }
        let outboxDrained = await eventually {
            await progressionOutboxIsDrained()
        }
        guard outboxDrained else {
            throw FutureThemeTestError.timedOut("seed outbox did not drain")
        }
        guard let seeded = await uiCapture.latestProgressionSnapshot()
        else { throw FutureThemeTestError.timedOut("seed snapshot absent") }
        return seeded
    }

    private func progressionOutboxIsDrained() async -> Bool {
        guard let request = try? ModuleStateScanRequest(
            collectionID: FutureThemeIDs.progressionOutboxCollection,
            limit: ModuleStateScanRequest.maximumLimit
        ), let page = try? await stateStore.scan(
            namespace: FutureThemeIDs.progressionOutboxNamespace,
            request: request
        ) else { return false }
        return page.records.isEmpty
    }

    func diagnostic(stage: String) async -> String {
        let runtimeSnapshot = await runtime.snapshot()
        let progressionSnapshot = await uiCapture.latestProgressionSnapshot()
        let entitlementSnapshot = await uiCapture.latestEntitlementSnapshot()
        let replayResult: String
        if let entitlementSnapshot {
            do {
                try await runtime.reconcileEntitlements(entitlementSnapshot)
                replayResult = "accepted"
            } catch {
                replayResult = String(describing: error)
            }
        } else {
            replayResult = "missing"
        }
        let entitlementEndpointID = RuntimeProgressionEndpointCatalog.entitlements
            .endpointID.rawValue
        let ledger = await runtime.callLedgerSnapshot().compactMap { record -> String? in
            guard record.metadata.operationIdentifier.rawValue == entitlementEndpointID
            else { return nil }
            return "\(record.metadata.sourceModuleID.rawValue):\(record.metadata.operationID.rawValue):\(String(describing: record.outcome))"
        }
        return "\(stage) runtime=\(runtimeSnapshot.entitlementSnapshot) progressionRevision=\(String(describing: progressionSnapshot?.revision)) progressionEntitlements=\(String(describing: progressionSnapshot?.entitlementIDs)) stream=\(String(describing: entitlementSnapshot)) replay=\(replayResult) ledger=\(ledger)"
    }

}

private enum FutureThemeActivationOutcome: Sendable {
    case succeed
    case fail
}

private final class FutureThemeAdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(start: Date) {
        value = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let current = value
        value = value.addingTimeInterval(1)
        return current
    }
}

private enum FutureThemeTestError: Error {
    case activationFailed
    case migrationHandlerFailure(operationIDs: [String])
    case migrationReceiptChanged
    case requiredModuleDidNotStart
    case timedOut(String)
}

private actor FutureThemeActivationProbe {
    private let outcome: FutureThemeActivationOutcome
    private var starts = 0
    private var stops = 0
    private var released = false
    private var activationWaiter: CheckedContinuation<Void, Never>?

    init(outcome: FutureThemeActivationOutcome) {
        self.outcome = outcome
    }

    func start() async throws {
        starts += 1
        if !released {
            await withCheckedContinuation { continuation in
                activationWaiter = continuation
            }
        }
        if outcome == .fail {
            throw FutureThemeTestError.activationFailed
        }
    }

    func releaseActivation() {
        released = true
        activationWaiter?.resume()
        activationWaiter = nil
    }

    func stop() {
        stops += 1
        releaseActivation()
    }

    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private actor FutureThemeCoreCapture {
    private var outbox: RuntimeProgressionOutboxClient?
    private var migration: RuntimeExistingUserMigrationClient?

    func install(
        outbox: RuntimeProgressionOutboxClient,
        migration: RuntimeExistingUserMigrationClient
    ) {
        self.outbox = outbox
        self.migration = migration
    }

    func submitMigration(
        ciphers: [ExistingUserMigrationCipherDTO]
    ) async throws -> ExistingUserMigrationPagedHandoffReceipt {
        guard let migration else { throw FutureThemeTestError.requiredModuleDidNotStart }
        return try await migration.submit(ciphers: ciphers)
    }

    func backgroundContext() async throws -> RuntimePersistableOperationContext {
        guard let outbox else { throw FutureThemeTestError.requiredModuleDidNotStart }
        return try await outbox.issueBackgroundContext(for: .coreReconciliation)
    }

    func submit(
        batch: ProgressionEventFactBatch,
        context: RuntimePersistableOperationContext
    ) async throws -> ProgressionOutboxBatchReceipt {
        guard let outbox else { throw FutureThemeTestError.requiredModuleDidNotStart }
        return try await outbox.submitBatch(batch, context: context)
    }
}

private actor FutureThemeUICapture {
    private var stateTask: Task<Void, Never>?
    private var entitlementTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private var states: [ProgressionSnapshotDTO] = []
    private var entitlements: [ProgressionEntitlementSnapshotDTO] = []
    private var availability: [RuntimeAvailabilitySnapshot] = []

    func connect(
        progression: RuntimeProgressionClient,
        availability: RuntimeAvailabilityClient
    ) async throws {
        let availabilityStream = try await availability.snapshots()
        stateTask = Task { [weak self] in
            for await envelope in progression.progressionStateEnvelopes {
                guard !Task.isCancelled else { return }
                await self?.record(envelope.payload)
            }
        }
        entitlementTask = Task { [weak self] in
            for await envelope in progression.entitlementEnvelopes {
                guard !Task.isCancelled else { return }
                await self?.record(envelope.payload)
            }
        }
        availabilityTask = Task { [weak self] in
            for await snapshot in availabilityStream {
                guard !Task.isCancelled else { return }
                await self?.record(snapshot)
            }
        }
    }

    func stop() {
        stateTask?.cancel()
        entitlementTask?.cancel()
        availabilityTask?.cancel()
        stateTask = nil
        entitlementTask = nil
        availabilityTask = nil
    }

    func latestProgressionSnapshot() -> ProgressionSnapshotDTO? { states.last }
    func progressionSnapshots() -> [ProgressionSnapshotDTO] { states }
    func latestEntitlementSnapshot() -> ProgressionEntitlementSnapshotDTO? {
        entitlements.last
    }

    private func record(_ snapshot: ProgressionSnapshotDTO) {
        states.append(snapshot)
    }

    private func record(_ snapshot: ProgressionEntitlementSnapshotDTO) {
        entitlements.append(snapshot)
    }

    private func record(_ snapshot: RuntimeAvailabilitySnapshot) {
        availability.append(snapshot)
    }
}

private struct FutureThemeTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    private let startOperation: @Sendable (ModuleContext) async throws -> Void
    private let stopOperation: @Sendable () async -> Void

    init(
        descriptor: ModuleDescriptor,
        start: @escaping @Sendable (ModuleContext) async throws -> Void,
        stop: @escaping @Sendable () async -> Void = {}
    ) {
        self.descriptor = descriptor
        startOperation = start
        stopOperation = stop
    }

    func start(context: ModuleContext) async throws {
        try await startOperation(context)
    }

    func stop() async {
        await stopOperation()
    }
}

private func coreDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.core,
        moduleVersion: version,
        kind: .service,
        entryPoint: "FutureThemeCore",
        role: RuneScribeRoles.core,
        requestedCapabilities: [
            RuneScribeCapabilities.progressionEventSubmit,
            RuneScribeCapabilities.progressionMigrationSubmit,
        ]
    )
}

private func uiDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.primaryUI,
        moduleVersion: version,
        kind: .ui,
        entryPoint: "FutureThemeUI",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.runtimeAvailabilityRead,
            RuneScribeCapabilities.progressionStateRead,
        ],
        requiredModuleRoles: [RuneScribeRoles.core],
        consumedEndpoints: [
            RuntimeProgressionEndpointCatalog.progressionState.endpointID,
            RuntimeProgressionEndpointCatalog.entitlements.endpointID,
        ]
    )
}

private func themeDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: FutureThemeIDs.themeModule,
        moduleVersion: version,
        kind: .service,
        criticality: .optional,
        entryPoint: "FutureMoonleafTheme",
        role: FutureThemeIDs.themeRole,
        requestedCapabilities: [],
        requiredModuleRoles: [RuneScribeRoles.core]
    )
}

private func manifest(
    for descriptor: ModuleDescriptor,
    runtimeVersion: SemanticVersion,
    entitlement: EntitlementRequirement? = nil
) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: runtimeVersion,
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredResources: descriptor.requiredResources.sorted { $0.name < $1.name },
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted(),
        entitlementRequirement: entitlement
    )
}

private func firstDeliveryFact(index: Int) throws -> ProgressionEventFact {
    let suffix = String(format: "%08x", index)
    let cipher = try XCTUnwrap(
        CipherToken(rawValue: String(repeating: "c", count: 24) + suffix)
    )
    let relationship = try XCTUnwrap(
        RelationshipToken(rawValue: String(repeating: "r", count: 24) + suffix)
    )
    return try ProgressionEventFact(
        eventType: "runescribe.cipher.first-delivery-completed",
        eligibility: DomainEventEligibilityMetadata(
            state: .eligible,
            reason: EligibilityReasonID(rawValue: "eligibility.eligible.domain-commit")!
        ),
        payload: DomainEventPayload(
            cipherToken: cipher,
            relationshipToken: relationship,
            keyIncluded: true,
            linkedRelationship: true
        )
    )
}

private func ownership(
    _ reference: ProgressionContentReference,
    in snapshot: ProgressionSnapshotDTO
) -> ProgressionOwnershipDTO? {
    snapshot.ownership.first { $0.reference == reference }
}

private func completedAchievementIDs(
    _ snapshot: ProgressionSnapshotDTO
) -> Set<AchievementID> {
    Set(snapshot.achievements.compactMap {
        $0.progress.isComplete ? $0.achievementID : nil
    })
}

private func ownedReferenceKeys(_ snapshot: ProgressionSnapshotDTO) -> Set<String> {
    Set(snapshot.ownership.compactMap {
        $0.state == .owned ? referenceKey($0.reference) : nil
    })
}

private func referenceKey(_ reference: ProgressionContentReference) -> String {
    switch reference {
    case let .codex(id): "codex:\(id.rawValue)"
    case let .artifact(id): "artifact:\(id.rawValue)"
    case let .title(id): "title:\(id.rawValue)"
    case let .entitlement(id): "entitlement:\(id.rawValue)"
    case let .crest(id): "crest:\(id.rawValue)"
    case .unknown: "unknown"
    }
}

private func eventually(
    attempts: Int = 400,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< attempts {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

private func remainsTrue(
    attempts: Int = 30,
    condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< attempts {
        guard await condition() else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
