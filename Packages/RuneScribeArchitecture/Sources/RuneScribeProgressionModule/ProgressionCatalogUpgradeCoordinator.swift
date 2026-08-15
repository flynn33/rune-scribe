import Foundation
import RuneScribeContracts

enum ProgressionCatalogUpgradeCoordinator {
    static func upgrade(
        bundle: ValidatedProgressionCatalogBundle,
        repository: ProgressionRepository,
        storedState: ProgressionRepositoryState
    ) async throws -> ProgressionRepositoryState {
        let oldMetadata = storedState.projection.metadata
        let catalog = bundle.catalog
        guard oldMetadata.catalogID == catalog.catalogID,
              oldMetadata.catalogVersion < catalog.catalogVersion,
              let physicalMetadata = storedState.projection.physicalMetadata
        else { throw ProgressionDomainError.catalogMismatch }
        let upgradeTimestamp = physicalMetadata.updatedAt

        let migrations = storedState.projection.logicalRecords().compactMap {
            logical -> CatalogMigrationRecord? in
            guard case let .catalogMigration(value) = logical else { return nil }
            return value
        }
        guard migrations.count == 1,
              migrations[0].catalogVersion == oldMetadata.catalogVersion
        else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-migration") }
        let currentFingerprints = try ProgressionCatalogCompatibility.fingerprints(for: bundle)
        try ProgressionCatalogCompatibility.validateAddOnlyUpgrade(
            from: migrations[0].compatibilityFingerprints,
            to: currentFingerprints
        )
        let existingUserMigrations = storedState.projection.logicalRecords().compactMap {
            logical -> ExistingUserMigrationRecord? in
            guard case let .existingUserMigration(record) = logical else { return nil }
            return record
        }
        guard existingUserMigrations.count <= 1 else {
            throw ProgressionDomainError.invalidRecord(
                "catalog-upgrade-existing-user-migration"
            )
        }
        let existingUserMigration = existingUserMigrations.first
        let existingUserMigrationSeeds: [ExistingUserMigrationSeedRecord]
        if let existingUserMigration {
            existingUserMigrationSeeds = try await repository.existingUserMigrationSeeds(
                generation: oldMetadata.activeGeneration
            )
            try await repository.validateExistingUserMigrationSeedSnapshot(
                generation: oldMetadata.activeGeneration,
                expectedCount: existingUserMigration.cipherCount,
                expectedDigest: existingUserMigration.snapshotDigest,
                handoffSchemaVersion: existingUserMigration.handoffSchemaVersion,
                pageCount: existingUserMigration.pageCount
            )
        } else {
            existingUserMigrationSeeds = []
        }

        var validatedStoredState = storedState
        let priorQueuedRevealRecords = try await repository
            .structurallyValidatedRevealQueueRecords(
            in: storedState.projection,
            bundle: bundle
        )
        validatedStoredState.nextPendingReveal = priorQueuedRevealRecords.first
        let operationID = upgradeOperationID(
            catalogID: catalog.catalogID,
            from: oldMetadata.catalogVersion,
            to: catalog.catalogVersion
        )
        let operationIdentifier = "progression.catalog.upgrade"
        let transactionID = ProgressionDeterminism.transactionUUID(
            "runtime-operation|\(operationIdentifier)|\(operationID)"
        )
        let newGeneration = ProgressionDeterminism.digest128(
            "catalog-upgrade-generation|\(catalog.catalogID.rawValue)|\(oldMetadata.catalogVersion.rawValue)|\(catalog.catalogVersion.rawValue)"
        )
        var projection = try ProgressionReducer.initialProjection(
            bundle: bundle,
            generation: newGeneration
        )
        projection.metadata.initializedAt = oldMetadata.initializedAt
        projection.metadata.knownInactiveQuarantineCount =
            oldMetadata.knownInactiveQuarantineCount
        if let existingUserMigration {
            let migrationOutput = try ProgressionExistingUserMigrationReducer.replay(
                record: existingUserMigration,
                seedRecords: existingUserMigrationSeeds,
                to: projection,
                bundle: bundle
            )
            projection = migrationOutput.projection
            try await repository.stageExistingUserMigrationSeedRecords(
                migrationOutput.seedRecords,
                generation: newGeneration,
                operationID: operationID
            )
            try await repository.stageDistinctTokens(
                migrationOutput.distinctTokens,
                generation: newGeneration,
                operationID: operationID,
                appliedRevision: projection.metadata.revision
            )
        }
        var queuedReveals: [RevealID: PendingRevealRecord] = [:]
        for located in priorQueuedRevealRecords {
            let record = located.value
            let rebased = PendingRevealRecord(
                generation: newGeneration,
                revealID: record.revealID,
                transactionID: record.transactionID,
                createdRevision: record.createdRevision,
                createdAt: record.createdAt,
                state: record.state,
                presentedAt: record.presentedAt,
                acknowledgedAt: record.acknowledgedAt,
                tier: record.tier,
                primaryContentID: record.primaryContentID,
                secondaryContentIDs: record.secondaryContentIDs,
                sourceAchievementIDs: record.sourceAchievementIDs,
                sourceRuleIDs: record.sourceRuleIDs,
                nextRevealID: record.nextRevealID
            )
            try rebased.validate()
            queuedReveals[rebased.revealID] = rebased
        }
        guard case let .revealQueueState(priorQueueState)? = storedState.projection.records[
            "reveal-queue-state"
        ] else { throw ProgressionDomainError.invalidRecord("reveal-queue-state-missing") }
        try priorQueueState.validate()
        try projection.upsert(.revealQueueState(ProgressionRevealQueueStateRecord(
            generation: newGeneration,
            pendingCount: priorQueueState.pendingCount,
            headRevealID: priorQueueState.headRevealID,
            tailRevealID: priorQueueState.tailRevealID
        )))
        var replayState = ProgressionRepositoryState(
            projection: projection,
            nextPendingReveal: nil,
            inactiveShards: [:],
            health: storedState.health
        )
        var queueTail = priorQueueState.tailRevealID.flatMap { queuedReveals[$0] }
        var cursor: ModuleStateScanCursor?
        var priorAppliedRevision: UInt64?
        var priorAppliedAt: Date? = existingUserMigration?.completedAt
        let previouslyOwnedContentIDs = Set(
            validatedStoredState.projection.logicalRecords().compactMap {
                logical -> ProgressionContentID? in
                guard case let .ownership(record) = logical else { return nil }
                return record.contentID
            }
        )

        try await repository.captureRecoveryEventCandidates(
            from: oldMetadata.activeGeneration,
            to: newGeneration,
            operationID: operationID
        )
        repeat {
            let page = try await repository.recoveryEventCandidatePage(
                generation: newGeneration,
                cursor: cursor
            )
            for order in page.records {
                guard priorAppliedRevision.map({ $0 < order.appliedRevision }) ?? true else {
                    throw ProgressionDomainError.invalidRecord("catalog-upgrade-event-order")
                }
                let storedProcessed: ProcessedEventRecord?
                do {
                    storedProcessed = try await repository.processedEvent(
                          order.eventID,
                          generation: oldMetadata.activeGeneration
                      )
                } catch ProgressionDomainError.invalidRecord {
                    storedProcessed = nil
                } catch let error as ModuleStateStoreError {
                    switch error {
                    case .quarantined, .integrityMismatch, .unreadable, .corrupt:
                        storedProcessed = nil
                    default:
                        throw error
                    }
                }
                guard case let .accepted(event) = ProgressionEventValidator.validate(
                    storedProcessed?.envelope ?? order.envelope,
                    bundle: bundle
                ) else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-event") }
                let processed = ProcessedEventRecord(
                    envelope: event.envelope,
                    envelopeDigest: try ProgressionDeterminism.encodedDigest(event.envelope),
                    semanticDigest: event.semanticDigest,
                    outcome: .applied,
                    transactionID: GrantTransactionID(
                        rawValue: "transaction.\(order.eventID.rawValue.uuidString.lowercased())"
                    ),
                    appliedRevision: order.appliedRevision
                )
                if let storedProcessed, storedProcessed != processed {
                    guard order.sourceCumulativeDigest != nil else {
                        throw ProgressionDomainError.invalidRecord("catalog-upgrade-event")
                    }
                    try await repository.quarantineProcessedEvent(
                        eventID: order.eventID,
                        generation: oldMetadata.activeGeneration
                    )
                }

                projection = replayState.projection
                let priorRevision = order.appliedRevision.subtractingReportingOverflow(1)
                guard !priorRevision.overflow else {
                    throw ProgressionDomainError.invalidRecord("catalog-upgrade-revision")
                }
                projection.metadata.revision = priorRevision.partialValue
                projection.metadata.lastMutationAt = priorRevision.partialValue == 0
                    ? nil : priorAppliedAt
                replayState.projection = projection

                let candidates = try ProgressionReducer.lifetimeDistinctCandidates(
                    for: event,
                    projection: projection,
                    bundle: bundle
                )
                var existing: [DistinctTokenRecord] = []
                for candidate in candidates {
                    if let record = try await repository.distinctToken(candidate) {
                        guard sameToken(record, candidate) else {
                            throw ProgressionDomainError.recordIdentityCollision(
                                candidate.tokenDigest
                            )
                        }
                        if record.firstAppliedRevision < order.appliedRevision {
                            existing.append(record)
                        }
                    }
                }
                let reduced = try ProgressionReducer.apply(
                    event,
                    to: replayState,
                    existingLifetimeTokens: existing,
                    queueTail: queueTail,
                    suppressReveal: true,
                    bundle: bundle
                )
                if let sourceDigest = order.sourceCumulativeDigest {
                    if sourceDigest != reduced.projection.metadata.appliedEventDigest {
                        guard order.hasProcessedSource else {
                            throw ProgressionDomainError.invalidRecord(
                                "catalog-upgrade-ledger-digest"
                            )
                        }
                        try await repository.quarantineAppliedEventOrder(
                            revision: order.appliedRevision,
                            generation: oldMetadata.activeGeneration
                        )
                    }
                }
                let rebuiltOrder = try ProgressionAppliedEventOrderRecord(
                    appliedRevision: order.appliedRevision,
                    envelope: order.envelope,
                    cumulativeDigest: reduced.projection.metadata.appliedEventDigest!
                )
                try await repository.stageAppliedLedger(
                    processed: processed,
                    order: rebuiltOrder,
                    semantic: ProgressionSemanticDedupeRecord(
                        canonicalMaterial: event.semanticMaterial,
                        firstEventID: event.envelope.eventID
                    ),
                    generation: newGeneration,
                    operationID: operationID
                )
                try await repository.stageDistinctTokens(
                    reduced.newDistinctTokens,
                    generation: newGeneration,
                    operationID: operationID,
                    appliedRevision: order.appliedRevision
                )
                for reveal in reduced.queuedRevealUpserts {
                    queuedReveals[reveal.revealID] = reveal
                }
                if case let .revealQueueState(queue)? = reduced.projection.records[
                    "reveal-queue-state"
                ], let tailID = queue.tailRevealID {
                    queueTail = queuedReveals[tailID]
                } else {
                    queueTail = nil
                }
                replayState.projection = reduced.projection
                priorAppliedRevision = order.appliedRevision
                priorAppliedAt = event.envelope.occurredAt
            }
            if let next = page.next {
                let health = try await repository.client.health()
                cursor = ModuleStateScanCursor(
                    collectionID: next.collectionID,
                    afterRecordID: next.afterRecordID,
                    observedStoreRevision: health.storeRevision
                )
            } else {
                cursor = nil
            }
        } while cursor != nil

        projection = replayState.projection
        try await repository.preflightDerivedIndexesForCleanup(
            generation: oldMetadata.activeGeneration,
            replacementGeneration: newGeneration,
            expectedQueuedRevealIDs: Set(queuedReveals.keys)
        )
        let preCopyHealth = try await repository.client.health()
        let copySummary = try await repository.copyGenerationScopedRecords(
            from: oldMetadata.activeGeneration,
            to: newGeneration,
            appliedEventCount: projection.metadata.appliedEventCount,
            sourceRevision: oldMetadata.revision,
            sourceProjection: storedState.projection,
            bundle: bundle,
            validateAcknowledgementReferences: false,
            operationID: operationID
        )
        projection.metadata.processedEventCount = copySummary.processedEventCount
        projection.metadata.terminalProcessedEventDigest =
            copySummary.terminalProcessedEventDigest
        projection.metadata.acknowledgedRevealCount = copySummary.acknowledgedRevealCount
        projection.metadata.acknowledgedRevealDigest = copySummary.acknowledgedRevealDigest
        projection.metadata.commandReceiptCount = copySummary.commandReceiptCount
        projection.metadata.commandReceiptDigest = copySummary.commandReceiptDigest
        try await repository.validateActiveAppliedLedger(projection, bundle: bundle)
        projection.metadata.knownInactiveQuarantineCount =
            preCopyHealth.quarantinedRecordCount
        try preserveTitle(from: validatedStoredState.projection, in: &projection)
        try preserveBootstrapTimes(
            from: validatedStoredState.projection.metadata.initializedAt,
            in: &projection
        )
        try preserveExistingMigrationGrants(
            from: validatedStoredState.projection,
            in: &projection
        )
        try await repository.validateHistoricalReplayExactness(
            from: validatedStoredState.projection,
            to: projection,
            bundle: bundle
        )
        try validateMonotonicState(from: validatedStoredState.projection, to: projection)
        let (revision, overflow) = oldMetadata.revision.addingReportingOverflow(1)
        let (commandReceiptCount, commandOverflow) = projection.metadata.commandReceiptCount
            .addingReportingOverflow(1)
        guard !overflow, !commandOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = upgradeTimestamp
        projection.metadata.commandReceiptCount = commandReceiptCount
        let upgradeReveal = try appendUpgradeReveal(
            catalog: catalog,
            fromVersion: oldMetadata.catalogVersion,
            transactionID: transactionID,
            createdAt: upgradeTimestamp,
            previouslyOwnedContentIDs: previouslyOwnedContentIDs,
            projection: &projection,
            queuedReveals: &queuedReveals,
            queueTail: &queueTail
        )
        try projection.upsert(.catalogMigration(CatalogMigrationRecord(
            generation: newGeneration,
            migrationVersion: catalog.migration.migrationVersion,
            catalogVersion: catalog.catalogVersion,
            transactionID: transactionID,
            completedAt: upgradeTimestamp,
            compatibilityFingerprints: currentFingerprints,
            upgradeRevealBundle: upgradeReveal.map {
                CatalogMigrationRecord.UpgradeRevealBundle(reveal: $0)
            },
            priorCatalogVersion: oldMetadata.catalogVersion,
            priorGeneration: oldMetadata.activeGeneration
        )))

        try await repository.validatePreservedRevealReferences(
            priorQueuedRevealRecords,
            against: projection,
            bundle: bundle
        )
        try await repository.validateAcknowledgementReferences(
            generation: oldMetadata.activeGeneration,
            against: projection,
            bundle: bundle
        )
        guard projection.metadata.processedEventCount == oldMetadata.processedEventCount,
              projection.metadata.terminalProcessedEventDigest ==
                oldMetadata.terminalProcessedEventDigest,
              projection.metadata.acknowledgedRevealCount ==
                oldMetadata.acknowledgedRevealCount,
              projection.metadata.acknowledgedRevealDigest ==
                oldMetadata.acknowledgedRevealDigest,
              projection.metadata.commandReceiptCount == commandReceiptCount,
              projection.metadata.commandReceiptDigest == oldMetadata.commandReceiptDigest
        else {
            throw ProgressionDomainError.invalidRecord("catalog-upgrade-index-count")
        }

        let reveals = queuedReveals.values.sorted { $0.revealID < $1.revealID }
        guard try await repository.client.health().quarantinedRecordCount ==
                preCopyHealth.quarantinedRecordCount
        else {
            throw ProgressionDomainError.invalidRecord("catalog-upgrade-direct-integrity")
        }
        try await repository.stage(
            projection,
            distinctTokens: [],
            pendingReveals: reveals,
            operationID: operationID,
            existing: storedState
        )
        let receipt = ProgressionCommandReceiptRecord(
            operationID: operationID,
            correlationID: operationID,
            operationIdentifier: operationIdentifier,
            commandDigest: ProgressionDeterminism.digest128(
                "catalog-upgrade|\(oldMetadata.catalogVersion.rawValue)|\(catalog.catalogVersion.rawValue)"
            ),
            completedAt: upgradeTimestamp,
            resultRevision: revision,
            cleanupGeneration: oldMetadata.activeGeneration
        )
        _ = try await repository.promoteStagedGeneration(
            before: storedState,
            stagedProjection: projection,
            stagedReveals: reveals,
            receipt: receipt,
            transactionID: transactionID,
            allowsCatalogUpgrade: true
        )
        try await repository.cleanupRecoveryEventCandidates(
            generation: newGeneration,
            operationID: operationID
        )
        try await repository.cleanupInactiveGeneration(
            oldMetadata.activeGeneration,
            activeGeneration: newGeneration,
            operationID: operationID
        )
        var promoted = try await repository.loadExisting(bundle: bundle)
        promoted = try await repository.completeCatalogUpgradeCleanup(
            promoted,
            completedAt: upgradeTimestamp,
            operationID: operationID,
            bundle: bundle
        )
        return promoted
    }

    private static func validateMonotonicState(
        from old: ProgressionProjection,
        to new: ProgressionProjection
    ) throws {
        for logical in old.logicalRecords() {
            switch logical {
            case let .statisticCounter(record):
                guard case let .statisticCounter(current)? = new.records[logical.identity],
                      current.value >= record.value
                else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-revocation") }
            case let .statisticContentUse(record):
                guard case let .statisticContentUse(current)? = new.records[logical.identity],
                      Set(record.contentIDs).isSubset(of: Set(current.contentIDs))
                else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-revocation") }
            case let .achievementProgress(record):
                guard case let .achievementProgress(current)? = new.records[logical.identity],
                      current.current >= record.current
                else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-revocation") }
            case .achievementCompletion, .milestoneCompletion, .grant, .entitlement:
                guard new.records[logical.identity] != nil else {
                    throw ProgressionDomainError.invalidRecord("catalog-upgrade-revocation")
                }
            case let .ownership(record):
                guard case let .ownership(current)? = new.records[logical.identity],
                      Set(record.sourceGrantKeys).isSubset(of: Set(current.sourceGrantKeys))
                else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-revocation") }
            case let .encounter(record):
                guard case let .encounter(current)? = new.records[logical.identity],
                      sameEncounter(record, current)
                else { throw ProgressionDomainError.invalidRecord("catalog-upgrade-revocation") }
            case .titleSelection, .revealQueueState, .catalogMigration,
                 .existingUserMigration:
                break
            }
        }
    }

    private static func preserveTitle(
        from old: ProgressionProjection,
        in new: inout ProgressionProjection
    ) throws {
        guard case let .titleSelection(selection)? = old.records["title-selection"] else {
            throw ProgressionDomainError.invalidRecord("title-selection-missing")
        }
        if let titleID = selection.selectedTitleID {
            guard let contentID = ProgressionContentID(rawValue: titleID.rawValue),
                  new.records["ownership|\(contentID.rawValue)"] != nil
            else { throw ProgressionDomainError.unownedTitle(titleID) }
        }
        try new.upsert(.titleSelection(TitleSelectionRecord(
            generation: new.metadata.activeGeneration,
            selectedTitleID: selection.selectedTitleID,
            selectedAt: selection.selectedAt
        )))
    }

    private static func preserveBootstrapTimes(
        from timestamp: Date?,
        in projection: inout ProgressionProjection
    ) throws {
        guard let timestamp else { return }
        for logical in projection.logicalRecords() {
            switch logical {
            case let .grant(record):
                guard case .migration = record.source, record.grantedAt == nil else { continue }
                try projection.upsert(.grant(GrantRecord(
                    generation: record.generation,
                    grantGroupID: record.grantGroupID,
                    contentID: record.contentID,
                    source: record.source,
                    transactionID: record.transactionID,
                    grantedAt: timestamp
                )))
            case let .ownership(record):
                guard record.grantedAt == nil else { continue }
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: record.generation,
                    contentID: record.contentID,
                    sourceGrantKeys: record.sourceGrantKeys,
                    grantedAt: timestamp
                )))
            case let .entitlement(record):
                guard record.source == .included, record.grantedAt == nil else { continue }
                try projection.upsert(.entitlement(ProgressionEntitlementRecord(
                    generation: record.generation,
                    entitlementID: record.entitlementID,
                    contentID: record.contentID,
                    source: record.source,
                    grantedAt: timestamp
                )))
            default:
                continue
            }
        }
    }

    private static func preserveExistingMigrationGrants(
        from old: ProgressionProjection,
        in new: inout ProgressionProjection
    ) throws {
        for logical in old.logicalRecords() {
            guard case let .grant(record) = logical,
                  case .migration = record.source,
                  new.records[logical.identity] != nil
            else { continue }
            try new.upsert(.grant(GrantRecord(
                generation: new.metadata.activeGeneration,
                grantGroupID: record.grantGroupID,
                contentID: record.contentID,
                source: record.source,
                transactionID: record.transactionID,
                grantedAt: record.grantedAt
            )))
        }
    }

    private struct UpgradeRevealCandidate {
        let contentID: ProgressionContentID
        let grantGroupID: GrantGroupID
        let tier: ProgressionDurableRevealTier
        let isPrimary: Bool
        var sources: Set<ProgressionGrantSource>
    }

    static func canonicallyPriorOwnedContentIDs(
        in projection: ProgressionProjection,
        priorFingerprints: [CatalogMigrationRecord.CompatibilityFingerprint]
    ) -> Set<ProgressionContentID> {
        let keys = Set(priorFingerprints.map { $0.stableKey })
        let priorContentIDs = Set(keys.compactMap { key -> ProgressionContentID? in
            guard key.hasPrefix("content:") else { return nil }
            return ProgressionContentID(rawValue: String(key.dropFirst("content:".count)))
        })
        let priorAchievementIDs = Set(keys.compactMap { key -> AchievementID? in
            guard key.hasPrefix("achievement:") else { return nil }
            return AchievementID(rawValue: String(key.dropFirst("achievement:".count)))
        })
        let priorRuleIDs = Set(keys.compactMap { key -> RuleID? in
            guard key.hasPrefix("milestone:") else { return nil }
            return RuleID(rawValue: String(key.dropFirst("milestone:".count)))
        })
        let priorGrantItems = Set(keys.filter { $0.hasPrefix("grant-item:") })
        return Set(projection.logicalRecords().compactMap {
            logical -> ProgressionContentID? in
            guard case let .ownership(ownership) = logical,
                  priorContentIDs.contains(ownership.contentID)
            else { return nil }
            let hasPriorGrant = ownership.sourceGrantKeys.contains { sourceKey in
                guard case let .grant(grant)? = projection.records[sourceKey] else {
                    return false
                }
                let itemKey = "grant-item:\(grant.grantGroupID.rawValue):\(grant.contentID.rawValue)"
                guard priorGrantItems.contains(itemKey) else { return false }
                return switch grant.source {
                case .migration: true
                case let .achievement(id): priorAchievementIDs.contains(id)
                case let .milestone(id): priorRuleIDs.contains(id)
                }
            }
            return hasPriorGrant ? ownership.contentID : nil
        })
    }

    static func appendUpgradeReveal(
        catalog: ProgressionCatalog,
        fromVersion: ProgressionCatalogVersion,
        transactionID: UUID,
        createdAt: Date,
        previouslyOwnedContentIDs: Set<ProgressionContentID>,
        projection: inout ProgressionProjection,
        queuedReveals: inout [RevealID: PendingRevealRecord],
        queueTail: inout PendingRevealRecord?
    ) throws -> PendingRevealRecord? {
        let newlyOwnedContentIDs = Set(projection.logicalRecords().compactMap {
            logical -> ProgressionContentID? in
            guard case let .ownership(record) = logical,
                  !previouslyOwnedContentIDs.contains(record.contentID),
                  catalog.content(id: record.contentID)?.availability != .included
            else { return nil }
            return record.contentID
        })
        guard !newlyOwnedContentIDs.isEmpty else { return nil }

        var candidates: [ProgressionContentID: UpgradeRevealCandidate] = [:]
        for logical in projection.logicalRecords() {
            guard case let .grant(record) = logical,
                  newlyOwnedContentIDs.contains(record.contentID),
                  let group = catalog.grantGroup(id: record.grantGroupID)
            else { continue }
            let tier = durableTier(group.revealTier)
            guard tier != .none else { continue }
            switch record.source {
            case .migration:
                continue
            case .achievement, .milestone:
                break
            }
            let candidate = UpgradeRevealCandidate(
                contentID: record.contentID,
                grantGroupID: record.grantGroupID,
                tier: tier,
                isPrimary: record.contentID == group.primaryContentID,
                sources: [record.source]
            )
            if var existing = candidates[record.contentID] {
                existing.sources.insert(record.source)
                if upgradeRevealCandidateSortsBefore(candidate, existing) {
                    candidates[record.contentID] = UpgradeRevealCandidate(
                        contentID: candidate.contentID,
                        grantGroupID: candidate.grantGroupID,
                        tier: candidate.tier,
                        isPrimary: candidate.isPrimary,
                        sources: existing.sources
                    )
                } else {
                    candidates[record.contentID] = existing
                }
            } else {
                candidates[record.contentID] = candidate
            }
        }
        let sorted = candidates.values.sorted(by: upgradeRevealCandidateSortsBefore)
        guard let primary = sorted.first else { return nil }
        let sources = sorted.reduce(into: Set<ProgressionGrantSource>()) {
            $0.formUnion($1.sources)
        }
        let achievementIDs = sources.compactMap { source -> AchievementID? in
            guard case let .achievement(value) = source else { return nil }
            return value
        }
        let ruleIDs = sources.compactMap { source -> RuleID? in
            guard case let .milestone(value) = source else { return nil }
            return value
        }
        let revealID = RevealID(
            rawValue: "reveal.upgrade.\(fromVersion.rawValue).\(catalog.catalogVersion.rawValue)"
        )!
        let reveal = PendingRevealRecord(
            generation: projection.metadata.activeGeneration,
            revealID: revealID,
            transactionID: GrantTransactionID(
                rawValue: "transaction.\(transactionID.uuidString.lowercased())"
            )!,
            createdRevision: projection.metadata.revision,
            createdAt: createdAt,
            state: .queued,
            acknowledgedAt: nil,
            tier: primary.tier,
            primaryContentID: primary.contentID,
            secondaryContentIDs: sorted.dropFirst().map(\.contentID),
            sourceAchievementIDs: achievementIDs,
            sourceRuleIDs: ruleIDs,
            nextRevealID: nil
        )
        try reveal.validate()

        guard case let .revealQueueState(queue)? = projection.records[
            "reveal-queue-state"
        ] else { throw ProgressionDomainError.invalidRecord("reveal-queue-state-missing") }
        let (pendingCount, overflow) = queue.pendingCount.addingReportingOverflow(1)
        guard !overflow else { throw ProgressionDomainError.invalidRecord("reveal-queue-count") }
        if var tail = queueTail {
            tail.nextRevealID = revealID
            try tail.validate()
            queuedReveals[tail.revealID] = tail
            queueTail = tail
        }
        try projection.upsert(.revealQueueState(ProgressionRevealQueueStateRecord(
            generation: projection.metadata.activeGeneration,
            pendingCount: pendingCount,
            headRevealID: queue.headRevealID ?? revealID,
            tailRevealID: revealID
        )))
        queuedReveals[revealID] = reveal
        queueTail = reveal
        return reveal
    }

    private static func upgradeRevealCandidateSortsBefore(
        _ lhs: UpgradeRevealCandidate,
        _ rhs: UpgradeRevealCandidate
    ) -> Bool {
        let left = (
            revealTierRank(lhs.tier),
            lhs.isPrimary ? 1 : 0,
            lhs.grantGroupID.rawValue,
            lhs.contentID.rawValue
        )
        let right = (
            revealTierRank(rhs.tier),
            rhs.isPrimary ? 1 : 0,
            rhs.grantGroupID.rawValue,
            rhs.contentID.rawValue
        )
        return left > right
    }

    private static func durableTier(
        _ tier: ProgressionCatalogRevealTier
    ) -> ProgressionDurableRevealTier {
        switch tier {
        case .none: .none
        case .micro: .micro
        case .artifact: .artifact
        case .codex: .codex
        case .mastery: .mastery
        }
    }

    private static func revealTierRank(_ tier: ProgressionDurableRevealTier) -> Int {
        switch tier {
        case .none: 0
        case .micro: 1
        case .artifact: 2
        case .codex: 3
        case .mastery: 4
        }
    }

    private static func sameToken(_ lhs: DistinctTokenRecord, _ rhs: DistinctTokenRecord) -> Bool {
        lhs.generation == rhs.generation &&
            lhs.statisticID == rhs.statisticID &&
            lhs.bucketID == rhs.bucketID &&
            lhs.tokenDigest == rhs.tokenDigest &&
            lhs.canonicalToken == rhs.canonicalToken
    }

    private static func sameEncounter(_ lhs: EncounterRecord, _ rhs: EncounterRecord) -> Bool {
        lhs.codexID == rhs.codexID &&
            lhs.artifactObservations == rhs.artifactObservations &&
            lhs.firstEncounteredAt == rhs.firstEncounteredAt &&
            lhs.lastEncounteredAt == rhs.lastEncounteredAt &&
            lhs.encounterCount == rhs.encounterCount &&
            lhs.provenanceStatus == rhs.provenanceStatus
    }

    private static func upgradeOperationID(
        catalogID: ProgressionCatalogID,
        from oldVersion: ProgressionCatalogVersion,
        to newVersion: ProgressionCatalogVersion
    ) -> String {
        "catalog-upgrade.\(ProgressionDeterminism.digest128("\(catalogID.rawValue)|\(oldVersion.rawValue)|\(newVersion.rawValue)"))"
    }
}
