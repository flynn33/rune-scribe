import Foundation
@_spi(RuntimeExistingUserMigrationAuthority) import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeTestSupport
import Testing
@testable import RuneScribeProgressionModule

@Test
func existingUserMigrationMatchesEveryArchivistBoundaryWithoutInventingEvents() async throws {
    for count in [0, 4, 5, 19, 20] {
        let fixture = try ProgressionDurableFixture()
        let service = try await migrationService(fixture)
        let timestamp = Date(timeIntervalSince1970: 2_000_010_000 + Double(count))
        let transactionID = migrationTransactionID(count)
        let delivery = try migrationDelivery(
            count: count,
            transactionID: transactionID,
            mixedOrigins: true,
            reverseInput: count.isMultiple(of: 2)
        )

        let deferred = try await service.applyEvent(
            fixture.cipherEvent(index: UInt32(80_000 + count)),
            metadata: fixture.metadata(
                operation: "progression.event.apply",
                suffix: "migration-gate-\(count)"
            )
        )
        #expect(deferred == .deferredStoreUnavailable)

        let result = try await service.applyExistingUserMigration(
            delivery,
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.apply",
                suffix: "existing-user-\(count)",
                timestamp: timestamp
            )
        )
        guard case let .applied(grantTransactionID, revision, _) = result else {
            Issue.record("Migration count \(count) did not apply: \(result)")
            await service.shutdown()
            continue
        }
        #expect(grantTransactionID == existingUserMigrationGrantTransactionID(transactionID))
        #expect(revision == 1)

        let snapshot = try await fixture.snapshot(
            from: service,
            suffix: "existing-user-snapshot-\(count)"
        )
        let cipherStatistic = try #require(snapshot.statistics.first {
            $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
                $0.codexID == nil
        })
        #expect(cipherStatistic.value == UInt64(count))
        #expect(snapshot.statistics.filter {
            ![
                "stat.cipher.created-or-imported.unique",
                "stat.ownership.artifact-count",
                "stat.achievement.completed-count",
            ].contains($0.statisticID.rawValue)
        }.allSatisfy { $0.value == 0 })
        #expect(snapshot.encounters.isEmpty)
        #expect(snapshot.archive.isEmpty)
        let completedArchivists = Set(snapshot.achievements.compactMap {
            achievement -> String? in
            guard achievement.completedAt != nil,
                  achievement.achievementID.rawValue.hasPrefix("achievement.archivist-")
            else { return nil }
            #expect(achievement.completedAt == timestamp)
            return achievement.achievementID.rawValue
        })
        let expectedArchivists: Set<String> = if count >= 20 {
            ["achievement.archivist-1", "achievement.archivist-2"]
        } else if count >= 5 {
            ["achievement.archivist-1"]
        } else {
            []
        }
        #expect(completedArchivists == expectedArchivists)
        #expect(snapshot.pendingRevealCount == (count >= 5 ? 1 : 0))
        if count < 5 {
            #expect(snapshot.nextReveal == nil)
        } else if count < 20 {
            let reveal = try #require(snapshot.nextReveal)
            #expect(reveal.primaryRewardID == .artifact(
                ArtifactID(rawValue: "frame.norse.carved-knotwork")!
            ))
            #expect(reveal.secondaryRewardIDs.isEmpty)
            #expect(reveal.sourceAchievementIDs.map(\.rawValue) == [
                "achievement.archivist-1",
            ])
        } else {
            let reveal = try #require(snapshot.nextReveal)
            #expect(reveal.primaryRewardID == .title(
                TitleID(rawValue: "title.archivist")!
            ))
            #expect(reveal.secondaryRewardIDs == [
                .artifact(ArtifactID(rawValue: "frame.norse.carved-knotwork")!),
                .artifact(ArtifactID(rawValue: "seal.norse.berserk")!),
            ])
            #expect(reveal.sourceAchievementIDs.map(\.rawValue) == [
                "achievement.archivist-1",
                "achievement.archivist-2",
            ])
        }

        let repository = ProgressionRepository(client: fixture.client)
        let loaded = try await repository.loadExisting(bundle: fixture.bundle)
        let migration = try #require(loaded.projection.records(matching: {
            logical -> ExistingUserMigrationRecord? in
            guard case let .existingUserMigration(record) = logical else { return nil }
            return record
        }).first)
        #expect(migration.transactionID == transactionID)
        #expect(migration.cipherCount == UInt32(count))
        #expect(migration.completedAt == timestamp)
        #expect(loaded.projection.metadata.appliedEventCount == 0)
        #expect(loaded.projection.metadata.processedEventCount == 0)
        #expect(loaded.projection.metadata.distinctTokenCount == UInt64(count))
        #expect(try await repository.existingUserMigrationSeeds(
            generation: loaded.projection.metadata.activeGeneration
        ).count == count)

        if count == 0 {
            #expect(Set(snapshot.ownership.filter {
                $0.state == .owned
            }.map(migrationReferenceRawValue)) == [
                "codex:codex.norse",
                "artifact:relic.norse.runestone-tablet",
                "artifact:script.base-runes",
                "artifact:seal.norse.ravenshield",
                "artifact:seal.norse.valknut",
                "entitlement:unlock.codex.norse",
            ])
        }
        await service.shutdown()
    }
}

@Test
func existingUserMigrationIsTransactionIdempotentAndFutureFactsDoNotReopenIt() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await migrationService(fixture)
    let transactionID = migrationTransactionID(50)
    let delivery = try migrationDelivery(
        count: 5,
        transactionID: transactionID,
        mixedOrigins: true
    )
    let operation = try fixture.metadata(
        operation: "progression.migration.existing-user.apply",
        suffix: "migration-idempotent"
    )
    guard case .applied = try await service.applyExistingUserMigration(
        delivery,
        metadata: operation
    ) else {
        Issue.record("The idempotency fixture did not apply.")
        return
    }
    #expect(try await service.applyExistingUserMigration(
        delivery,
        metadata: operation
    ) == .duplicate)

    let changed = try migrationDelivery(
        count: 4,
        transactionID: transactionID,
        mixedOrigins: true
    )
    guard case .rejectedPermanent = try await service.applyExistingUserMigration(
        changed,
        metadata: operation
    ) else {
        Issue.record("Changed migration payload did not collide.")
        return
    }
    let replacementTransaction = try migrationDelivery(
        count: 5,
        transactionID: migrationTransactionID(51),
        mixedOrigins: true
    )
    guard case .rejectedPermanent = try await service.applyExistingUserMigration(
        replacementTransaction,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-replacement"
        )
    ) else {
        Issue.record("A second migration transaction was accepted.")
        return
    }

    guard case .applied = try await service.applyEvent(
        fixture.cipherEvent(index: 90_000),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "migration-future-fact"
        )
    ) else {
        Issue.record("A future cipher fact did not apply after terminal migration.")
        return
    }
    let snapshot = try await fixture.snapshot(from: service, suffix: "migration-future")
    #expect(snapshot.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 6)
    #expect(snapshot.achievements.filter {
        $0.achievementID.rawValue == "achievement.archivist-1" &&
            $0.completedAt != nil
    }.count == 1)
    #expect(snapshot.pendingRevealCount == 1)
    await service.shutdown()
}

@Test
func existingUserMigrationRetryRepublishesCommittedStateInTheSameProcess() async throws {
    let fixture = try ProgressionDurableFixture()
    let faultingClient = MigrationPostPromotionReadFaultClient(
        base: fixture.client,
        faultCount: 2
    )
    let service = try await migrationService(
        fixture,
        stateClient: faultingClient
    )
    let probe = ExistingUserMigrationStreamProbe()
    let stateMetadata = try fixture.metadata(
        operation: "progression.state.stream",
        suffix: "migration-post-commit-state"
    )
    let entitlementMetadata = try fixture.metadata(
        operation: "progression.entitlements.stream",
        suffix: "migration-post-commit-entitlements"
    )
    let stateTask = Task {
        for await snapshot in service.stateStream(metadata: stateMetadata) {
            await probe.record(snapshot)
        }
    }
    let entitlementTask = Task {
        for await snapshot in service.entitlementStream(metadata: entitlementMetadata) {
            await probe.record(snapshot)
        }
    }
    #expect(await waitForMigrationStreamProbe {
        await probe.hasInitialSnapshots
    })

    let delivery = try migrationDelivery(
        count: 20,
        transactionID: migrationTransactionID(4_140),
        mixedOrigins: true
    )
    let operation = try fixture.metadata(
        operation: "progression.migration.existing-user.apply",
        suffix: "migration-post-commit-apply"
    )
    var observedRetryableFailure = false
    do {
        let result = try await service.applyExistingUserMigration(
            delivery,
            metadata: operation
        )
        Issue.record("Post-commit publication fault returned terminal result: \(result)")
    } catch let error as ModuleStateStoreError {
        if case .injectedFailure("migration-post-promotion-read") = error {
            observedRetryableFailure = true
        } else {
            Issue.record("Unexpected post-commit migration error: \(error)")
        }
    }
    #expect(observedRetryableFailure)
    #expect(await faultingClient.injectedFaultCount == 2)
    #expect(try await service.applyExistingUserMigration(
        delivery,
        metadata: operation
    ) == .duplicate)
    #expect(await waitForMigrationStreamProbe {
        await probe.hasPublished(cipherCount: 20)
    })
    let publishedState = try #require(await probe.latestState)
    let publishedEntitlements = try #require(await probe.latestEntitlements)
    #expect(publishedState.revision == 1)
    #expect(publishedEntitlements.revision == 1)
    #expect(publishedEntitlements.includedUnlockIDs.contains(
        UnlockID(rawValue: "unlock.codex.norse")!
    ))
    await service.shutdown()
    await stateTask.value
    await entitlementTask.value

    let relaunched = try await migrationService(fixture)
    let relaunchedState = try await fixture.snapshot(
        from: relaunched,
        suffix: "migration-post-commit-relaunch"
    )
    #expect(relaunchedState.revision == 1)
    #expect(relaunchedState.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 20)
    await relaunched.shutdown()
}

@Test
func pagedExistingUserMigrationRetryRepublishesCommittedStateInTheSameProcess() async throws {
    let fixture = try ProgressionDurableFixture()
    let faultingClient = MigrationPostPromotionReadFaultClient(
        base: fixture.client,
        faultCount: 2
    )
    let service = try await migrationService(
        fixture,
        stateClient: faultingClient
    )
    let probe = ExistingUserMigrationStreamProbe()
    let stateMetadata = try fixture.metadata(
        operation: "progression.state.stream",
        suffix: "migration-page-post-commit-state"
    )
    let entitlementMetadata = try fixture.metadata(
        operation: "progression.entitlements.stream",
        suffix: "migration-page-post-commit-entitlements"
    )
    let stateTask = Task {
        for await snapshot in service.stateStream(metadata: stateMetadata) {
            await probe.record(snapshot)
        }
    }
    let entitlementTask = Task {
        for await snapshot in service.entitlementStream(metadata: entitlementMetadata) {
            await probe.record(snapshot)
        }
    }
    #expect(await waitForMigrationStreamProbe {
        await probe.hasInitialSnapshots
    })

    let deliveries = try pagedMigrationDeliveries(
        count: 4_097,
        transactionID: migrationTransactionID(4_141)
    )
    #expect(try await service.applyExistingUserMigrationPage(
        deliveries[0],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-post-commit-stage"
        )
    ) == .accepted(pageIndex: 0))
    let finalOperation = try fixture.metadata(
        operation: "progression.migration.existing-user.page.apply",
        suffix: "migration-page-post-commit-apply"
    )
    var observedRetryableFailure = false
    do {
        let result = try await service.applyExistingUserMigrationPage(
            deliveries[1],
            metadata: finalOperation
        )
        Issue.record("Paged post-commit publication fault returned terminal result: \(result)")
    } catch let error as ModuleStateStoreError {
        if case .injectedFailure("migration-post-promotion-read") = error {
            observedRetryableFailure = true
        } else {
            Issue.record("Unexpected paged post-commit migration error: \(error)")
        }
    }
    #expect(observedRetryableFailure)
    #expect(await faultingClient.injectedFaultCount == 2)
    #expect(try await service.applyExistingUserMigrationPage(
        deliveries[1],
        metadata: finalOperation
    ) == .outcome(.duplicate))
    #expect(await waitForMigrationStreamProbe {
        await probe.hasPublished(cipherCount: 4_097)
    })
    let publishedState = try #require(await probe.latestState)
    let publishedEntitlements = try #require(await probe.latestEntitlements)
    #expect(publishedState.revision == 1)
    #expect(publishedEntitlements.revision == 1)
    #expect(publishedEntitlements.includedUnlockIDs.contains(
        UnlockID(rawValue: "unlock.codex.norse")!
    ))
    await service.shutdown()
    await stateTask.value
    await entitlementTask.value

    let relaunched = try await migrationService(fixture)
    let relaunchedState = try await fixture.snapshot(
        from: relaunched,
        suffix: "migration-page-post-commit-relaunch"
    )
    #expect(relaunchedState.revision == 1)
    #expect(relaunchedState.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 4_097)
    await relaunched.shutdown()
}

@Test
func maximumExistingUserMigrationStagesWithinRepositoryLimitsAndRelaunches() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await migrationService(fixture)
    let delivery = try migrationDelivery(
        count: ExistingUserMigrationSnapshotDTO.maximumCipherCount,
        transactionID: migrationTransactionID(4_096),
        mixedOrigins: true,
        reverseInput: true
    )
    await fixture.client.clearRecordedTransactions()
    guard case .applied = try await service.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-maximum"
        )
    ) else {
        Issue.record("The maximum migration did not apply.")
        return
    }
    let transactions = await fixture.client.recordedTransactions()
    #expect(transactions.count > 2)
    for transaction in transactions {
        #expect(transaction.mutations.count <= ModuleStateTransaction.maximumMutations)
        var payloadBytes = 0
        for mutation in transaction.mutations {
            if case let .upsert(upsert) = mutation {
                #expect(upsert.payload.count <= 1_048_576)
                payloadBytes += upsert.payload.count
            }
        }
        #expect(payloadBytes <= 8_388_608)
    }
    let active = try await fixture.client.activeMetadata()
    #expect(active.distinctTokenCount == 4_096)
    let repository = ProgressionRepository(client: fixture.client)
    #expect(try await repository.existingUserMigrationSeeds(
        generation: active.activeGeneration
    ).count == 4_096)
    await service.shutdown()

    let relaunched = try await migrationService(fixture)
    let snapshot = try await fixture.snapshot(
        from: relaunched,
        suffix: "migration-maximum-relaunch"
    )
    #expect(snapshot.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 4_096)
    await relaunched.shutdown()
}

@Test
func pagedExistingUserMigrationApplies4097OnlyAfterValidatedFinalPage() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await migrationService(fixture)
    let transactionID = migrationTransactionID(4_097)
    let deliveries = try pagedMigrationDeliveries(
        count: 4_097,
        transactionID: transactionID
    )
    #expect(deliveries.count == 2)

    #expect(try await service.applyExistingUserMigrationPage(
        deliveries[0],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-0"
        )
    ) == .accepted(pageIndex: 0))
    #expect(try await service.applyExistingUserMigrationPage(
        deliveries[0],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-0-retry"
        )
    ) == .accepted(pageIndex: 0))

    let partial = try await fixture.snapshot(
        from: service,
        suffix: "migration-page-partial"
    )
    #expect(partial.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 0)
    #expect(partial.pendingRevealCount == 0)
    #expect(try await service.applyEvent(
        fixture.cipherEvent(index: 99_000),
        metadata: fixture.metadata(
            operation: "progression.event.apply",
            suffix: "migration-page-event-blocked"
        )
    ) == .deferredStoreUnavailable)
    let partialRepository = ProgressionRepository(client: fixture.client)
    let partialState = try await partialRepository.loadExisting(bundle: fixture.bundle)
    #expect(partialState.projection.records(matching: {
        logical -> ExistingUserMigrationRecord? in
        guard case let .existingUserMigration(value) = logical else { return nil }
        return value
    }).isEmpty)

    let finalResult = try await service.applyExistingUserMigrationPage(
        deliveries[1],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-1"
        )
    )
    guard case let .outcome(.applied(grantTransactionID, revision, _)) = finalResult else {
        Issue.record("The final migration page did not apply: \(finalResult)")
        return
    }
    #expect(grantTransactionID == existingUserMigrationGrantTransactionID(transactionID))
    #expect(revision == 1)

    let snapshot = try await fixture.snapshot(
        from: service,
        suffix: "migration-page-applied"
    )
    #expect(snapshot.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 4_097)
    #expect(snapshot.pendingRevealCount == 1)
    let loaded = try await partialRepository.loadExisting(bundle: fixture.bundle)
    let migration = try #require(loaded.projection.records(matching: {
        logical -> ExistingUserMigrationRecord? in
        guard case let .existingUserMigration(value) = logical else { return nil }
        return value
    }).first)
    #expect(migration.cipherCount == 4_097)
    #expect(migration.handoffSchemaVersion == 2)
    #expect(migration.pageCount == 2)
    #expect(loaded.projection.metadata.distinctTokenCount == 4_097)
    #expect(try await partialRepository.existingUserMigrationSeeds(
        generation: loaded.projection.metadata.activeGeneration
    ).count == 4_097)
    #expect(try await service.applyExistingUserMigrationPage(
        deliveries[1],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-duplicate"
        )
    ) == .outcome(.duplicate))
    assertMigrationTransactionBounds(await fixture.client.recordedTransactions())
    await service.shutdown()

    let relaunched = try await migrationService(fixture)
    let relaunchedSnapshot = try await fixture.snapshot(
        from: relaunched,
        suffix: "migration-page-relaunch"
    )
    #expect(relaunchedSnapshot.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 4_097)
    _ = try await relaunched.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(
                uuidString: "88000000-0000-0000-0000-000000004097"
            )!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "migration-page-rebuild"
        )
    )
    let rebuilt = try await fixture.snapshot(
        from: relaunched,
        suffix: "migration-page-rebuilt"
    )
    #expect(rebuilt.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 4_097)
    await relaunched.shutdown()
}

@Test
func pagedExistingUserMigrationRejectsDuplicateTokenAcrossPages() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await migrationService(fixture)
    let transactionID = migrationTransactionID(4_098)
    var ciphers = try migrationCiphers(count: 4_097)
    ciphers[4_096] = ciphers[4_095]
    let deliveries = try pagedMigrationDeliveries(
        ciphers: ciphers,
        transactionID: transactionID
    )
    #expect(try await service.applyExistingUserMigrationPage(
        deliveries[0],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-duplicate-0"
        )
    ) == .accepted(pageIndex: 0))
    guard case .outcome(.rejectedPermanent) = try await service
        .applyExistingUserMigrationPage(
            deliveries[1],
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-duplicate-1"
            )
        )
    else {
        Issue.record("A cross-page duplicate token was not rejected.")
        return
    }
    let snapshot = try await fixture.snapshot(
        from: service,
        suffix: "migration-page-duplicate-snapshot"
    )
    #expect(snapshot.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 0)
    #expect(snapshot.pendingRevealCount == 0)
    await service.shutdown()
}

@Test
func pagedExistingUserMigrationRejectsFinalAggregateMismatch() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await migrationService(fixture)
    let transactionID = migrationTransactionID(4_099)
    let deliveries = try pagedMigrationDeliveries(
        count: 4_097,
        transactionID: transactionID
    )
    _ = try await service.applyExistingUserMigrationPage(
        deliveries[0],
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-digest-0"
        )
    )
    let changedSnapshot = try ExistingUserMigrationSnapshotDTO(ciphers: [
        ExistingUserMigrationCipherDTO(
            cipherToken: CipherToken(rawValue: migrationToken(90_000))!,
            origin: .generated
        ),
    ])
    let changedFinal = ExistingUserMigrationPageDeliveryDTO(
        transactionID: ExistingUserMigrationTransactionID(rawValue: transactionID),
        page: try ExistingUserMigrationPageDTO(
            pageIndex: 1,
            pageCount: 2,
            totalCipherCount: 4_097,
            aggregateDigest: deliveries[1].page.aggregateDigest,
            snapshot: changedSnapshot
        )
    )
    guard case .outcome(.rejectedPermanent) = try await service
        .applyExistingUserMigrationPage(
            changedFinal,
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-digest-1"
            )
        )
    else {
        Issue.record("A final-page aggregate mismatch was not rejected.")
        return
    }
    let snapshot = try await fixture.snapshot(
        from: service,
        suffix: "migration-page-digest-snapshot"
    )
    #expect(snapshot.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 0)
    #expect(snapshot.pendingRevealCount == 0)
    await service.shutdown()
}

@Test
func pagedExistingUserMigrationResumesPageStageBeforeAndAfterCommitFaults() async throws {
    for (faultIndex, faultPoint) in [
        InMemoryModuleStateFaultPoint.beforeTransactionCommit,
        .afterTransactionCommit,
    ].enumerated() {
        let fixture = try ProgressionDurableFixture()
        let first = try await migrationService(fixture)
        let deliveries = try pagedMigrationDeliveries(
            count: 4_097,
            transactionID: migrationTransactionID(4_110 + faultIndex)
        )
        await fixture.store.injectFault(
            at: faultPoint,
            afterSuccessfulCalls: 1
        )
        #expect(try await first.applyExistingUserMigrationPage(
            deliveries[0],
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-stage-\(faultPoint.rawValue)"
            )
        ) == .outcome(.deferredStoreUnavailable))
        let partial = try await fixture.snapshot(
            from: first,
            suffix: "migration-page-stage-partial-\(faultPoint.rawValue)"
        )
        #expect(partial.statistics.first {
            $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
                $0.codexID == nil
        }?.value == 0)
        await first.shutdown()

        let relaunched = try await migrationService(fixture)
        #expect(try await relaunched.applyExistingUserMigrationPage(
            deliveries[0],
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-stage-retry-\(faultPoint.rawValue)"
            )
        ) == .accepted(pageIndex: 0))
        guard case .outcome(.applied) = try await relaunched
            .applyExistingUserMigrationPage(
                deliveries[1],
                metadata: fixture.metadata(
                    operation: "progression.migration.existing-user.page.apply",
                    suffix: "migration-page-stage-final-\(faultPoint.rawValue)"
                )
            )
        else {
            Issue.record("Paged migration did not recover page-stage fault.")
            return
        }
        await relaunched.shutdown()
    }
}

@Test
func pagedExistingUserMigrationResumesFinalPromotionBeforeAndAfterCommitFaults() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await migrationService(baseline)
    let baselineDeliveries = try pagedMigrationDeliveries(
        count: 4_097,
        transactionID: migrationTransactionID(4_120)
    )
    _ = try await baselineService.applyExistingUserMigrationPage(
        baselineDeliveries[0],
        metadata: baseline.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-promotion-baseline-0"
        )
    )
    await baseline.client.clearRecordedTransactions()
    _ = try await baselineService.applyExistingUserMigrationPage(
        baselineDeliveries[1],
        metadata: baseline.metadata(
            operation: "progression.migration.existing-user.page.apply",
            suffix: "migration-page-promotion-baseline-1"
        )
    )
    let baselineTransactions = await baseline.client.recordedTransactions()
    let promotionIndex = try #require(baselineTransactions.firstIndex {
        transaction in
        let keys = Set(transaction.mutations.map(\.key))
        return keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        )) && keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
        ))
    })
    assertMigrationTransactionBounds(baselineTransactions)
    await baselineService.shutdown()

    for (faultIndex, faultPoint) in [
        InMemoryModuleStateFaultPoint.beforeTransactionCommit,
        .afterTransactionCommit,
    ].enumerated() {
        let fixture = try ProgressionDurableFixture()
        let first = try await migrationService(fixture)
        let deliveries = try pagedMigrationDeliveries(
            count: 4_097,
            transactionID: migrationTransactionID(4_130 + faultIndex)
        )
        _ = try await first.applyExistingUserMigrationPage(
            deliveries[0],
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-promotion-0-\(faultPoint.rawValue)"
            )
        )
        await fixture.client.clearRecordedTransactions()
        await fixture.store.injectFault(
            at: faultPoint,
            afterSuccessfulCalls: promotionIndex
        )
        let interrupted = try await first.applyExistingUserMigrationPage(
            deliveries[1],
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-promotion-1-\(faultPoint.rawValue)"
            )
        )
        switch interrupted {
        case .outcome(.applied), .outcome(.deferredStoreUnavailable):
            break
        default:
            Issue.record("Unexpected promotion interruption: \(interrupted)")
        }
        await first.shutdown()

        let relaunched = try await migrationService(fixture)
        let replay = try await relaunched.applyExistingUserMigrationPage(
            deliveries[1],
            metadata: fixture.metadata(
                operation: "progression.migration.existing-user.page.apply",
                suffix: "migration-page-promotion-replay-\(faultPoint.rawValue)"
            )
        )
        switch replay {
        case .outcome(.applied), .outcome(.duplicate):
            break
        default:
            Issue.record("Paged promotion did not recover: \(replay)")
        }
        let snapshot = try await fixture.snapshot(
            from: relaunched,
            suffix: "migration-page-promotion-snapshot-\(faultPoint.rawValue)"
        )
        #expect(snapshot.statistics.first {
            $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
                $0.codexID == nil
        }?.value == 4_097)
        assertMigrationTransactionBounds(await fixture.client.recordedTransactions())
        await relaunched.shutdown()
    }
}

@Test
func existingUserMigrationFaultMatrixResumesEveryStagingAndPromotionBoundary() async throws {
    let baseline = try ProgressionDurableFixture()
    let baselineService = try await migrationService(baseline)
    let transactionID = migrationTransactionID(130)
    let delivery = try migrationDelivery(
        count: 130,
        transactionID: transactionID,
        mixedOrigins: true
    )
    let operation = try baseline.metadata(
        operation: "progression.migration.existing-user.apply",
        suffix: "migration-fault-matrix",
        timestamp: Date(timeIntervalSince1970: 2_000_011_000)
    )
    await baseline.client.clearRecordedTransactions()
    guard case .applied = try await baselineService.applyExistingUserMigration(
        delivery,
        metadata: operation
    ) else {
        Issue.record("The migration fault baseline did not apply.")
        return
    }
    let baselineTransactions = await baseline.client.recordedTransactions()
    let promotionIndex = try #require(baselineTransactions.firstIndex { transaction in
        let keys = Set(transaction.mutations.map(\.key))
        return keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        )) && keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
        ))
    })
    #expect(promotionIndex > 2)
    assertMigrationTransactionBounds(baselineTransactions)
    await baselineService.shutdown()

    for faultPoint in [
        InMemoryModuleStateFaultPoint.beforeTransactionCommit,
        .afterTransactionCommit,
    ] {
        for transactionIndex in 0 ... promotionIndex {
            let fixture = try ProgressionDurableFixture()
            let first = try await migrationService(fixture)
            let candidate = try migrationDelivery(
                count: 130,
                transactionID: transactionID,
                mixedOrigins: true
            )
            let candidateOperation = try fixture.metadata(
                operation: "progression.migration.existing-user.apply",
                suffix: "migration-fault-matrix",
                timestamp: Date(timeIntervalSince1970: 2_000_011_000)
            )
            await fixture.client.clearRecordedTransactions()
            await fixture.store.injectFault(
                at: faultPoint,
                afterSuccessfulCalls: transactionIndex
            )
            let interrupted = try await first.applyExistingUserMigration(
                candidate,
                metadata: candidateOperation
            )
            #expect(
                interrupted == .deferredStoreUnavailable ||
                    migrationAppliedOrDuplicate(interrupted)
            )
            await first.shutdown()

            let relaunched = try await migrationService(fixture)
            let replay = try await relaunched.applyExistingUserMigration(
                candidate,
                metadata: candidateOperation
            )
            #expect(migrationAppliedOrDuplicate(replay))
            let snapshot = try await fixture.snapshot(
                from: relaunched,
                suffix: "migration-fault-\(faultPoint.rawValue)-\(transactionIndex)"
            )
            #expect(snapshot.statistics.first {
                $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
                    $0.codexID == nil
            }?.value == 130)
            #expect(snapshot.pendingRevealCount == 1)
            #expect(snapshot.achievements.filter {
                ["achievement.archivist-1", "achievement.archivist-2"]
                    .contains($0.achievementID.rawValue) && $0.completedAt != nil
            }.count == 2)
            #expect(try await fixture.client.fetch(
                collectionID: ProgressionRepositoryIDs.metadataCollection,
                recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
            ) == nil)
            let active = try await fixture.client.activeMetadata()
            let repository = ProgressionRepository(client: fixture.client)
            #expect(try await repository.existingUserMigrationSeeds(
                generation: active.activeGeneration
            ).count == 130)
            assertMigrationTransactionBounds(await fixture.client.recordedTransactions())
            await relaunched.shutdown()
        }
    }
}

@Test
func freshMigrationTransactionSweepsAnInterruptedStagingGeneration() async throws {
    let fixture = try ProgressionDurableFixture()
    let first = try await migrationService(fixture)
    let firstDelivery = try migrationDelivery(
        count: 130,
        transactionID: migrationTransactionID(240),
        mixedOrigins: true
    )
    await fixture.store.injectFault(
        at: .beforeTransactionCommit,
        afterSuccessfulCalls: 2
    )
    #expect(try await first.applyExistingUserMigration(
        firstDelivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-stale-first"
        )
    ) == .deferredStoreUnavailable)
    let abandonedGeneration = try #require(
        try await migrationStageDestination(fixture.client)
    )
    #expect(try await fixture.client.generationRecordCount(abandonedGeneration) > 0)
    await first.shutdown()

    let relaunched = try await migrationService(fixture)
    let replacement = try migrationDelivery(
        count: 130,
        transactionID: migrationTransactionID(241),
        mixedOrigins: true
    )
    guard case .applied = try await relaunched.applyExistingUserMigration(
        replacement,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-stale-replacement"
        )
    ) else {
        Issue.record("A fresh migration transaction did not replace stale staging.")
        return
    }
    #expect(try await migrationStageDestination(fixture.client) == nil)
    #expect(try await fixture.client.generationRecordCount(abandonedGeneration) == 0)
    await relaunched.shutdown()
}

@Test
func rebuildPreservesPendingAndAcknowledgedMigrationRevealExactlyOnce() async throws {
    let fixture = try ProgressionDurableFixture()
    let first = try await migrationService(fixture)
    let delivery = try migrationDelivery(
        count: 20,
        transactionID: migrationTransactionID(200),
        mixedOrigins: true
    )
    guard case .applied = try await first.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-rebuild-source"
        )
    ) else {
        Issue.record("The rebuild fixture migration did not apply.")
        return
    }
    let initial = try await fixture.snapshot(from: first, suffix: "migration-rebuild-initial")
    let revealID = try #require(initial.nextReveal?.revealID)
    _ = try await first.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "88000000-0000-0000-0000-000000000001")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "migration-rebuild-pending"
        )
    )
    let rebuiltPending = try await fixture.snapshot(
        from: first,
        suffix: "migration-rebuild-pending-snapshot"
    )
    #expect(rebuiltPending.pendingRevealCount == 1)
    #expect(rebuiltPending.nextReveal?.revealID == revealID)
    await first.shutdown()

    let relaunched = try await migrationService(fixture)
    #expect(try await fixture.snapshot(
        from: relaunched,
        suffix: "migration-rebuild-relaunch"
    ).nextReveal?.revealID == revealID)
    try await fixture.markPresented(
        revealID,
        using: relaunched,
        suffix: "migration-reveal-ack",
        timestamp: Date(timeIntervalSince1970: 2_000_000_000)
    )
    try await relaunched.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "migration-reveal-ack"
        )
    )
    _ = try await relaunched.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "88000000-0000-0000-0000-000000000002")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "migration-rebuild-acked"
        )
    )
    let final = try await fixture.snapshot(from: relaunched, suffix: "migration-rebuild-final")
    #expect(final.pendingRevealCount == 0)
    #expect(final.nextReveal == nil)
    await relaunched.shutdown()
}

@Test
func catalogUpgradePreservesMigrationSeedsWithoutReapplyingInitialMigration() async throws {
    let fixture = try ProgressionDurableFixture()
    let versionTwo = try await migrationService(fixture)
    let delivery = try migrationDelivery(
        count: 20,
        transactionID: migrationTransactionID(220),
        mixedOrigins: true
    )
    guard case .applied = try await versionTwo.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-upgrade-source"
        )
    ) else {
        Issue.record("The upgrade fixture migration did not apply.")
        return
    }
    let pending = try await fixture.snapshot(from: versionTwo, suffix: "migration-upgrade-v2")
    let revealID = try #require(pending.nextReveal?.revealID)
    try await fixture.markPresented(
        revealID,
        using: versionTwo,
        suffix: "migration-upgrade-ack",
        timestamp: Date(timeIntervalSince1970: 2_000_000_000)
    )
    try await versionTwo.acknowledgeReveal(
        AcknowledgeProgressionRevealCommand(revealID: revealID),
        metadata: fixture.metadata(
            operation: "progression.reveal.acknowledge",
            suffix: "migration-upgrade-ack"
        )
    )
    await versionTwo.shutdown()

    let versionThreeBundle = fixture.additiveVersionThreeBundle()
    let versionThree = try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: versionThreeBundle,
        stateClient: fixture.client,
        requiresExistingUserMigration: true
    )
    let upgraded = try await fixture.snapshot(from: versionThree, suffix: "migration-upgrade-v3")
    #expect(upgraded.catalogVersion?.rawValue == 3)
    #expect(upgraded.pendingRevealCount == 0)
    #expect(upgraded.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 20)
    #expect(Set(upgraded.achievements.compactMap {
        $0.completedAt == nil ? nil : $0.achievementID.rawValue
    }).isSuperset(of: [
        "achievement.archivist-1",
        "achievement.archivist-2",
    ]))
    let metadata = try await fixture.client.activeMetadata()
    let repository = ProgressionRepository(client: fixture.client)
    #expect(try await repository.existingUserMigrationSeeds(
        generation: metadata.activeGeneration
    ).count == 20)
    #expect(try await versionThree.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-upgrade-retry"
        )
    ) == .duplicate)
    await versionThree.shutdown()
}

@Test
func recoveryReplaysMigrationSeedBeforeEventsAndPreservesItsPendingReveal() async throws {
    let fixture = try ProgressionDurableFixture()
    let first = try await migrationService(fixture)
    let delivery = try migrationDelivery(
        count: 20,
        transactionID: migrationTransactionID(230),
        mixedOrigins: true
    )
    guard case .applied = try await first.applyExistingUserMigration(
        delivery,
        metadata: fixture.metadata(
            operation: "progression.migration.existing-user.apply",
            suffix: "migration-recovery-source"
        )
    ) else {
        Issue.record("The recovery fixture migration did not apply.")
        return
    }
    let before = try await fixture.snapshot(from: first, suffix: "migration-recovery-before")
    let revealID = try #require(before.nextReveal?.revealID)
    await first.shutdown()
    try await fixture.client.corruptProjectionShard(
        category: .statisticCounter,
        shardIndex: 0
    )

    let degraded = try await migrationService(fixture)
    #expect(try await degraded.diagnosticsSummary(
        metadata: fixture.metadata(
            operation: "progression.diagnostics.summary",
            suffix: "migration-recovery-degraded"
        )
    ).availability == .degraded)
    _ = try await degraded.rebuild(
        ProgressionRecoveryRequest(
            confirmationToken: UUID(uuidString: "88000000-0000-0000-0000-000000000003")!
        ),
        metadata: fixture.metadata(
            operation: "progression.recovery.rebuild",
            suffix: "migration-recovery-rebuild"
        )
    )
    let after = try await fixture.snapshot(from: degraded, suffix: "migration-recovery-after")
    #expect(after.statistics.first {
        $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
            $0.codexID == nil
    }?.value == 20)
    #expect(after.pendingRevealCount == 1)
    #expect(after.nextReveal?.revealID == revealID)
    await degraded.shutdown()
}

@Test
func codexGateComponentsPreserveCatalogAuthoredOrder() async throws {
    let fixture = try ProgressionDurableFixture()
    let service = try await fixture.bootstrap()
    let snapshot = try await fixture.snapshot(from: service, suffix: "gate-components")
    let sunspire = try #require(snapshot.codexGates.first {
        $0.codexID.rawValue == "codex.sunspire"
    })
    #expect(sunspire.components.map(\.componentID) == [
        "rule.codex.sunspire.reciprocal-light.component.1",
        "rule.codex.sunspire.reciprocal-light.component.2",
        "rule.codex.sunspire.reciprocal-light.component.3",
    ])
    #expect(sunspire.components.map(\.label) == [
        "Moonleaf Codex",
        "Bidirectional correspondents",
        "Incoming messages decoded",
    ])
    await service.shutdown()
}

private func migrationService(
    _ fixture: ProgressionDurableFixture
) async throws -> RuneScribeProgressionServiceActor {
    try await migrationService(fixture, stateClient: fixture.client)
}

private func migrationService(
    _ fixture: ProgressionDurableFixture,
    stateClient: any ProgressionStateClient
) async throws -> RuneScribeProgressionServiceActor {
    try await RuneScribeProgressionServiceActor.bootstrapForTesting(
        catalogBundle: fixture.bundle,
        stateClient: stateClient,
        requiresExistingUserMigration: true
    )
}

private func migrationDelivery(
    count: Int,
    transactionID: UUID,
    mixedOrigins: Bool,
    reverseInput: Bool = false
) throws -> ExistingUserMigrationDeliveryDTO {
    var ciphers = try (0 ..< count).map { index in
        try ExistingUserMigrationCipherDTO(
            cipherToken: CipherToken(rawValue: migrationToken(index))!,
            origin: mixedOrigins && !index.isMultiple(of: 2) ? .imported : .generated
        )
    }
    if reverseInput { ciphers.reverse() }
    return ExistingUserMigrationDeliveryDTO(
        transactionID: ExistingUserMigrationTransactionID(rawValue: transactionID),
        snapshot: try ExistingUserMigrationSnapshotDTO(ciphers: ciphers)
    )
}

private func migrationCiphers(
    count: Int,
    mixedOrigins: Bool = true
) throws -> [ExistingUserMigrationCipherDTO] {
    try (0 ..< count).map { index in
        try ExistingUserMigrationCipherDTO(
            cipherToken: CipherToken(rawValue: migrationToken(index))!,
            origin: mixedOrigins && !index.isMultiple(of: 2)
                ? .imported
                : .generated
        )
    }
}

private func pagedMigrationDeliveries(
    count: Int,
    transactionID: UUID
) throws -> [ExistingUserMigrationPageDeliveryDTO] {
    try pagedMigrationDeliveries(
        ciphers: migrationCiphers(count: count),
        transactionID: transactionID
    )
}

private func pagedMigrationDeliveries(
    ciphers: [ExistingUserMigrationCipherDTO],
    transactionID: UUID
) throws -> [ExistingUserMigrationPageDeliveryDTO] {
    let maximum = ExistingUserMigrationSnapshotDTO.maximumCipherCount
    let pageCount = UInt32(((ciphers.count - 1) / maximum) + 1)
    let digest = try ProgressionExistingUserMigrationReducer.aggregateDigest(
        ciphers: ciphers,
        pageCount: pageCount
    )
    return try stride(from: 0, to: ciphers.count, by: maximum)
        .enumerated()
        .map { index, start in
            let snapshot = try ExistingUserMigrationSnapshotDTO(
                ciphers: Array(ciphers[start ..< min(start + maximum, ciphers.count)])
            )
            return ExistingUserMigrationPageDeliveryDTO(
                transactionID: ExistingUserMigrationTransactionID(
                    rawValue: transactionID
                ),
                page: try ExistingUserMigrationPageDTO(
                    pageIndex: UInt32(index),
                    pageCount: pageCount,
                    totalCipherCount: UInt32(ciphers.count),
                    aggregateDigest: digest,
                    snapshot: snapshot
                )
            )
        }
}

private func migrationToken(_ index: Int) -> String {
    String(repeating: "c", count: 24) + String(format: "%08x", index)
}

private func migrationTransactionID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "87000000-0000-0000-0000-%012x", index))!
}

private func migrationReferenceRawValue(
    _ ownership: ProgressionOwnershipDTO
) -> String {
    switch ownership.reference {
    case let .codex(id): "codex:\(id.rawValue)"
    case let .artifact(id): "artifact:\(id.rawValue)"
    case let .title(id): "title:\(id.rawValue)"
    case let .entitlement(id): "entitlement:\(id.rawValue)"
    case let .crest(id): "crest:\(id.rawValue)"
    case .unknown: "unknown"
    }
}

private func assertMigrationTransactionBounds(
    _ transactions: [ModuleStateTransaction]
) {
    for transaction in transactions {
        #expect(transaction.mutations.count <= ModuleStateTransaction.maximumMutations)
        var payloadBytes = 0
        for mutation in transaction.mutations {
            if case let .upsert(upsert) = mutation {
                #expect(upsert.payload.count <= 1_048_576)
                payloadBytes += upsert.payload.count
            }
        }
        #expect(payloadBytes <= 8_388_608)
    }
}

private func migrationAppliedOrDuplicate(
    _ result: ExistingUserMigrationApplyResult
) -> Bool {
    switch result {
    case .applied, .duplicate: true
    case .rejectedPermanent, .deferredUnsupportedSchema, .deferredStoreUnavailable: false
    }
}

private func migrationStageDestination(
    _ client: ProgressionTestStateClient
) async throws -> String? {
    guard let physical = try await client.fetch(
        collectionID: ProgressionRepositoryIDs.metadataCollection,
        recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
    ) else { return nil }
    let marker = try ProgressionDeterminism.decoder().decode(
        ExistingUserMigrationStageMarkerRecord.self,
        from: physical.payload
    )
    try marker.validate()
    return marker.destinationGeneration
}

private actor ExistingUserMigrationStreamProbe {
    private var states: [ProgressionSnapshotDTO] = []
    private var entitlements: [ProgressionEntitlementSnapshotDTO] = []

    var hasInitialSnapshots: Bool {
        states.first?.revision == 0 && entitlements.first?.revision == 0
    }

    var latestState: ProgressionSnapshotDTO? { states.last }
    var latestEntitlements: ProgressionEntitlementSnapshotDTO? { entitlements.last }

    func record(_ snapshot: ProgressionSnapshotDTO) {
        states.append(snapshot)
    }

    func record(_ snapshot: ProgressionEntitlementSnapshotDTO) {
        entitlements.append(snapshot)
    }

    func hasPublished(cipherCount: UInt64) -> Bool {
        states.contains { snapshot in
            snapshot.revision == 1 && snapshot.statistics.first {
                $0.statisticID.rawValue == "stat.cipher.created-or-imported.unique" &&
                    $0.codexID == nil
            }?.value == cipherCount
        } && entitlements.contains { $0.revision == 1 }
    }
}

private func waitForMigrationStreamProbe(
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    for _ in 0 ..< 1_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return false
}

private actor MigrationPostPromotionReadFaultClient: ProgressionStateClient {
    private let base: ProgressionTestStateClient
    private var remainingFaultCount: Int
    private var promotionObserved = false
    private var postPromotionMutationObserved = false
    private(set) var injectedFaultCount = 0

    init(base: ProgressionTestStateClient, faultCount: Int) {
        self.base = base
        remainingFaultCount = faultCount
    }

    func prepare(schemaVersion: UInt32) async throws -> ModuleStateHealthSnapshot {
        try await base.prepare(schemaVersion: schemaVersion)
    }

    func fetch(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID
    ) async throws -> ModuleStateRecord? {
        try injectReadFaultIfNeeded()
        return try await base.fetch(collectionID: collectionID, recordID: recordID)
    }

    func scan(_ request: ModuleStateScanRequest) async throws -> ModuleStateScanPage {
        try injectReadFaultIfNeeded()
        return try await base.scan(request)
    }

    func transact(
        _ transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        let result = try await base.transact(transaction)
        if Self.isExistingUserMigrationPromotion(transaction) {
            promotionObserved = true
        } else if promotionObserved {
            postPromotionMutationObserved = true
        }
        return result
    }

    func quarantine(diagnosticCode: String) async throws -> ModuleStateHealthSnapshot {
        try await base.quarantine(diagnosticCode: diagnosticCode)
    }

    func quarantineRecord(
        collectionID: ModuleStateCollectionID,
        recordID: ModuleStateRecordID,
        expectedRevision: UInt64,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try await base.quarantineRecord(
            collectionID: collectionID,
            recordID: recordID,
            expectedRevision: expectedRevision,
            diagnosticCode: diagnosticCode
        )
    }

    func health() async throws -> ModuleStateHealthSnapshot {
        try await base.health()
    }

    private func injectReadFaultIfNeeded() throws {
        guard postPromotionMutationObserved, remainingFaultCount > 0 else { return }
        remainingFaultCount -= 1
        injectedFaultCount += 1
        throw ModuleStateStoreError.injectedFailure(
            "migration-post-promotion-read"
        )
    }

    private static func isExistingUserMigrationPromotion(
        _ transaction: ModuleStateTransaction
    ) -> Bool {
        let keys = Set(transaction.mutations.map(\.key))
        return keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.activeMetadataRecord
        )) && keys.contains(ModuleStateRecordKey(
            collectionID: ProgressionRepositoryIDs.metadataCollection,
            recordID: ProgressionRepositoryIDs.existingUserMigrationStageMarkerRecord
        ))
    }
}
