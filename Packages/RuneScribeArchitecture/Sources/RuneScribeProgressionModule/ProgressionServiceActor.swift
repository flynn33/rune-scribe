import Foundation
import RuneScribeContracts
import RuneScribeProgressionSyncDomain
import RuneScribeRuntimeCore

struct ProgressionExternalSyncState: Equatable, Sendable {
    let snapshot: ProgressionSnapshotDTO
    let projection: RuntimeProgressionExternalProjection
}

enum ProgressionProviderAvailabilityProjection {
    static func availability(
        for lifecycleState: ModuleLifecycleState
    ) -> ProgressionProviderAvailability {
        switch lifecycleState {
        case .registered, .validated, .stopping, .stopped:
            .unavailable
        case .eligible, .activating:
            .eligible
        case .active:
            .active
        case .failed:
            .failed
        }
    }

    static func availabilityByCodexID(
        snapshot: RuntimeAvailabilitySnapshot,
        bindings: ProgressionFutureThemeBindingContract
    ) -> [CodexID: ProgressionProviderAvailability] {
        let lifecycleByModuleID = Dictionary(
            uniqueKeysWithValues: snapshot.optionalModules.map {
                ($0.moduleID, $0.lifecycleState)
            }
        )
        return Dictionary(uniqueKeysWithValues: bindings.bindings.map { binding in
            let availability = lifecycleByModuleID[binding.moduleID].map {
                Self.availability(for: $0)
            } ?? .unavailable
            return (binding.codexID, availability)
        })
    }
}

public actor RuneScribeProgressionServiceActor: RuneScribeProgressionService,
    RuneScribeExistingUserMigrationApplying
{
    private let bundle: ValidatedProgressionCatalogBundle
    private let repository: ProgressionRepository
    private var state: ProgressionRepositoryState
    private var recoveryOnly: Bool
    private var recoveredTitleSelection: TitleSelectionRecord?
    private var recoverableProjectionQuarantineCount: UInt64?
    private var recoveryRebuildPermitted: Bool
    private let requiresExistingUserMigration: Bool
    private var providerAvailabilityByCodexID: [
        CodexID: ProgressionProviderAvailability
    ] = [:]
    private var runtimeAvailabilityRevision: UInt64?
    private var runtimeAvailabilityTask: Task<Void, Never>?
    private var stateStreamTerminalReason: ProgressionExternalSyncTerminalReason?
    private var stateContinuations: [String: AsyncStream<ProgressionSnapshotDTO>.Continuation] = [:]
    private var entitlementContinuations:
        [String: AsyncStream<ProgressionEntitlementSnapshotDTO>.Continuation] = [:]

    public static func bootstrap(
        catalogBundle: ValidatedProgressionCatalogBundle,
        stateClient: RuntimeModuleStateClient,
        availabilityClient: RuntimeAvailabilityClient
    ) async throws -> RuneScribeProgressionServiceActor {
        let availabilitySnapshots = try await availabilityClient.snapshots()
        return try await bootstrapForTesting(
            catalogBundle: catalogBundle,
            stateClient: stateClient,
            requiresExistingUserMigration: true,
            availabilitySnapshots: availabilitySnapshots
        )
    }

    static func bootstrapForTesting(
        catalogBundle: ValidatedProgressionCatalogBundle,
        stateClient: any ProgressionStateClient,
        requiresExistingUserMigration: Bool = false,
        availabilitySnapshots: AsyncStream<RuntimeAvailabilitySnapshot>? = nil
    ) async throws -> RuneScribeProgressionServiceActor {
        let repository = ProgressionRepository(client: stateClient)
        let initial = try ProgressionReducer.initialProjection(bundle: catalogBundle)
        do {
            let state = try await repository.loadOrInitialize(
                bundle: catalogBundle,
                initialProjection: initial
            )
            _ = try ProgressionSnapshotBuilder.snapshot(
                state: state,
                bundle: catalogBundle,
                capturedAt: state.health.capturedAt
            )
            let service = RuneScribeProgressionServiceActor(
                bundle: catalogBundle,
                repository: repository,
                state: state,
                recoveryOnly: false,
                recoveredTitleSelection: nil,
                recoverableProjectionQuarantineCount: nil,
                recoveryRebuildPermitted: true,
                requiresExistingUserMigration: requiresExistingUserMigration
            )
            await service.startAvailabilityObservation(availabilitySnapshots)
            return service
        } catch {
            if case .injectedFailure = error as? ModuleStateStoreError {
                throw error
            }
            let anchor = try await repository.recoveryAnchor(bundle: catalogBundle)
            guard anchor.metadata.catalogVersion <= catalogBundle.catalog.catalogVersion,
                  anchor.metadata.catalogVersion == catalogBundle.catalog.catalogVersion ||
                    anchor.recoveredCatalogMigration != nil,
                  anchor.metadata.initializedAt != nil
            else { throw error }
            let state = try recoveryState(bundle: catalogBundle, anchor: anchor)
            let recoveredTitleSelection = try await repository.recoverableTitleSelection(
                metadata: anchor.metadata
            )
            let expectedQuarantineCount = try expectedRecoveryQuarantineCount(anchor)
            let service = RuneScribeProgressionServiceActor(
                bundle: catalogBundle,
                repository: repository,
                state: state,
                recoveryOnly: true,
                recoveredTitleSelection: recoveredTitleSelection,
                recoverableProjectionQuarantineCount: expectedQuarantineCount,
                recoveryRebuildPermitted: anchor.directRecoveryPermitted,
                requiresExistingUserMigration: requiresExistingUserMigration
            )
            await service.startAvailabilityObservation(availabilitySnapshots)
            return service
        }
    }

    private init(
        bundle: ValidatedProgressionCatalogBundle,
        repository: ProgressionRepository,
        state: ProgressionRepositoryState,
        recoveryOnly: Bool,
        recoveredTitleSelection: TitleSelectionRecord?,
        recoverableProjectionQuarantineCount: UInt64?,
        recoveryRebuildPermitted: Bool,
        requiresExistingUserMigration: Bool
    ) {
        self.bundle = bundle
        self.repository = repository
        self.state = state
        self.recoveryOnly = recoveryOnly
        self.recoveredTitleSelection = recoveredTitleSelection
        self.recoverableProjectionQuarantineCount = recoverableProjectionQuarantineCount
        self.recoveryRebuildPermitted = recoveryRebuildPermitted
        self.requiresExistingUserMigration = requiresExistingUserMigration
        providerAvailabilityByCodexID = Dictionary(
            uniqueKeysWithValues: bundle.futureThemeBindings.bindings.map {
                ($0.codexID, .unavailable)
            }
        )
    }

    public func applyExistingUserMigration(
        _ delivery: ExistingUserMigrationDeliveryDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationApplyResult {
        guard delivery.snapshot.schemaVersion ==
                ExistingUserMigrationSnapshotDTO.currentSchemaVersion
        else { return .deferredUnsupportedSchema }
        guard metadata.operationIdentifier.rawValue ==
                "progression.migration.existing-user.apply"
        else {
            return .rejectedPermanent(reason: migrationRejection(
                "progression.migration.operation-invalid"
            ))
        }
        let snapshotDigest = try ProgressionDeterminism.encodedIntegrityDigest(
            delivery.snapshot
        )
        if let existing = existingUserMigrationRecord() {
            guard existing.transactionID == delivery.transactionID.rawValue,
                  existing.snapshotDigest == snapshotDigest,
                  existing.cipherCount == UInt32(delivery.snapshot.ciphers.count),
                  existing.snapshotSchemaVersion == delivery.snapshot.schemaVersion
            else {
                return .rejectedPermanent(reason: migrationRejection(
                    "progression.migration.snapshot-collision"
                ))
            }
            guard try await reloadAndPublishExistingUserMigration(
                transactionID: delivery.transactionID.rawValue,
                snapshotDigest: snapshotDigest,
                cipherCount: UInt32(delivery.snapshot.ciphers.count),
                snapshotSchemaVersion: delivery.snapshot.schemaVersion,
                capturedAt: metadata.timestampUTC
            ) != nil else { return .deferredStoreUnavailable }
            return .duplicate
        }
        guard !recoveryOnly else { return .deferredStoreUnavailable }
        guard state.projection.metadata.appliedEventCount == 0,
              state.projection.metadata.processedEventCount == 0,
              state.projection.metadata.distinctTokenCount == 0,
              state.projection.metadata.revision == 0
        else {
            return .rejectedPermanent(reason: migrationRejection(
                "progression.migration.state-not-empty"
            ))
        }

        let priorState = state
        let oldGeneration = priorState.projection.metadata.activeGeneration
        let grantTransactionID = existingUserMigrationGrantTransactionID(
            delivery.transactionID.rawValue
        )
        do {
            let marker = try await repository.prepareExistingUserMigrationStage(
                source: priorState,
                delivery: delivery,
                snapshotDigest: snapshotDigest,
                metadata: metadata
            )
            var projection = try ProgressionReducer.initialProjection(
                bundle: bundle,
                generation: marker.value.destinationGeneration
            )
            projection.metadata.initializedAt = priorState.projection.metadata.initializedAt
            projection.metadata.knownInactiveQuarantineCount =
                priorState.projection.metadata.knownInactiveQuarantineCount
            guard let initializedAt = projection.metadata.initializedAt else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-initialized-at"
                )
            }
            try Self.stampIncludedBaseline(initializedAt, in: &projection)
            let reduced = try ProgressionExistingUserMigrationReducer.apply(
                snapshot: delivery.snapshot,
                transactionID: delivery.transactionID.rawValue,
                snapshotDigest: snapshotDigest,
                completedAt: metadata.timestampUTC,
                to: projection,
                bundle: bundle
            )
            try await repository.stageExistingUserMigration(
                projection: reduced.projection,
                seedRecords: reduced.seedRecords,
                distinctTokens: reduced.distinctTokens,
                pendingReveal: reduced.pendingReveal,
                marker: marker,
                existing: priorState
            )
            do {
                _ = try await repository.promoteExistingUserMigration(
                    before: priorState,
                    stagedProjection: reduced.projection,
                    pendingReveal: reduced.pendingReveal,
                    marker: marker
                )
            } catch {
                guard try await reloadAndPublishExistingUserMigration(
                    transactionID: delivery.transactionID.rawValue,
                    snapshotDigest: snapshotDigest,
                    cipherCount: UInt32(delivery.snapshot.ciphers.count),
                    snapshotSchemaVersion: delivery.snapshot.schemaVersion,
                    capturedAt: metadata.timestampUTC
                ) != nil else { throw error }
            }
            if state.projection.metadata.activeGeneration !=
                marker.value.destinationGeneration
            {
                state = try await repository.loadExisting(bundle: bundle)
            }
            try await repository.cleanupInactiveGeneration(
                oldGeneration,
                activeGeneration: state.projection.metadata.activeGeneration,
                operationID: "existing-user-migration.\(delivery.transactionID.rawValue.uuidString.lowercased())"
            )
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return .applied(
                grantTransactionID: grantTransactionID,
                revision: reduced.projection.metadata.revision,
                delta: reduced.delta
            )
        } catch ProgressionDomainError.transactionIdentityCollision {
            return .rejectedPermanent(reason: migrationRejection(
                "progression.migration.transaction-collision"
            ))
        } catch let error as ModuleStateStoreError {
            switch error {
            case .unavailable, .quarantined, .unreadable, .corrupt, .integrityMismatch,
                 .injectedFailure, .revisionConflict:
                if let terminal = try await reloadAndPublishExistingUserMigration(
                    transactionID: delivery.transactionID.rawValue,
                    snapshotDigest: snapshotDigest,
                    cipherCount: UInt32(delivery.snapshot.ciphers.count),
                    snapshotSchemaVersion: delivery.snapshot.schemaVersion,
                    capturedAt: metadata.timestampUTC
                ) {
                    return .applied(
                        grantTransactionID: terminal.grantTransactionID,
                        revision: state.projection.metadata.revision,
                        delta: migrationDelta(in: state.projection)
                    )
                }
                return .deferredStoreUnavailable
            default:
                throw error
            }
        }
    }

    public func applyExistingUserMigrationPage(
        _ delivery: ExistingUserMigrationPageDeliveryDTO,
        metadata: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationPageApplyResult {
        let page = delivery.page
        guard page.handoffSchemaVersion ==
                ExistingUserMigrationPageDTO.currentHandoffSchemaVersion,
              page.snapshot.schemaVersion ==
                ExistingUserMigrationSnapshotDTO.currentSchemaVersion
        else { return .outcome(.deferredUnsupportedSchema) }
        guard metadata.operationIdentifier.rawValue ==
                "progression.migration.existing-user.page.apply"
        else {
            return .outcome(.rejectedPermanent(reason: migrationRejection(
                "progression.migration.operation-invalid"
            )))
        }
        if let existing = existingUserMigrationRecord() {
            guard existing.transactionID == delivery.transactionID.rawValue,
                  existing.snapshotDigest == page.aggregateDigest,
                  existing.cipherCount == page.totalCipherCount,
                  existing.snapshotSchemaVersion == page.snapshot.schemaVersion,
                  existing.handoffSchemaVersion == page.handoffSchemaVersion,
                  existing.pageCount == page.pageCount
            else {
                return .outcome(.rejectedPermanent(reason: migrationRejection(
                    "progression.migration.snapshot-collision"
                )))
            }
            guard try await reloadAndPublishExistingUserMigration(
                transactionID: delivery.transactionID.rawValue,
                snapshotDigest: page.aggregateDigest,
                cipherCount: page.totalCipherCount,
                snapshotSchemaVersion: page.snapshot.schemaVersion,
                handoffSchemaVersion: page.handoffSchemaVersion,
                pageCount: page.pageCount,
                capturedAt: metadata.timestampUTC
            ) != nil else {
                return .outcome(.deferredStoreUnavailable)
            }
            return .outcome(.duplicate)
        }
        guard !recoveryOnly else {
            return .outcome(.deferredStoreUnavailable)
        }
        guard state.projection.metadata.appliedEventCount == 0,
              state.projection.metadata.processedEventCount == 0,
              state.projection.metadata.distinctTokenCount == 0,
              state.projection.metadata.revision == 0
        else {
            return .outcome(.rejectedPermanent(reason: migrationRejection(
                "progression.migration.state-not-empty"
            )))
        }

        let priorState = state
        let oldGeneration = priorState.projection.metadata.activeGeneration
        let transactionID = delivery.transactionID.rawValue
        let grantTransactionID = existingUserMigrationGrantTransactionID(
            transactionID
        )
        do {
            let marker = try await repository.prepareExistingUserMigrationPageStage(
                source: priorState,
                delivery: delivery,
                metadata: metadata
            )
            let pageSeeds = page.snapshot.ciphers.map {
                ExistingUserMigrationSeedRecord(
                    generation: marker.value.destinationGeneration,
                    cipherToken: $0.cipherToken,
                    origin: $0.origin,
                    sourcePageIndex: page.pageIndex
                )
            }
            try await repository.stageExistingUserMigrationSeedRecords(
                pageSeeds,
                generation: marker.value.destinationGeneration,
                operationID:
                    "\(transactionID.uuidString.lowercased()).page.\(page.pageIndex)"
            )
            let stagedSeeds = try await repository.existingUserMigrationSeeds(
                generation: marker.value.destinationGeneration
            )
            guard stagedSeeds.count <= Int(page.totalCipherCount) else {
                throw ProgressionDomainError.transactionIdentityCollision
            }
            guard stagedSeeds.count == Int(page.totalCipherCount) else {
                return .accepted(pageIndex: page.pageIndex)
            }
            try await repository.validateExistingUserMigrationSeedSnapshot(
                generation: marker.value.destinationGeneration,
                expectedCount: page.totalCipherCount,
                expectedDigest: page.aggregateDigest,
                handoffSchemaVersion: page.handoffSchemaVersion,
                pageCount: page.pageCount
            )

            var projection = try ProgressionReducer.initialProjection(
                bundle: bundle,
                generation: marker.value.destinationGeneration
            )
            projection.metadata.initializedAt = priorState.projection.metadata.initializedAt
            projection.metadata.knownInactiveQuarantineCount =
                priorState.projection.metadata.knownInactiveQuarantineCount
            guard let initializedAt = projection.metadata.initializedAt else {
                throw ProgressionDomainError.invalidRecord(
                    "existing-user-migration-initialized-at"
                )
            }
            try Self.stampIncludedBaseline(initializedAt, in: &projection)
            let ciphers = try stagedSeeds.map {
                try ExistingUserMigrationCipherDTO(
                    cipherToken: $0.cipherToken,
                    origin: $0.origin
                )
            }
            let reduced = try ProgressionExistingUserMigrationReducer.applyPaged(
                ciphers: ciphers,
                pageCount: page.pageCount,
                transactionID: transactionID,
                aggregateDigest: page.aggregateDigest,
                completedAt: marker.value.operationTimestamp,
                to: projection,
                bundle: bundle
            )
            try await repository.stageExistingUserMigration(
                projection: reduced.projection,
                seedRecords: reduced.seedRecords,
                distinctTokens: reduced.distinctTokens,
                pendingReveal: reduced.pendingReveal,
                marker: marker,
                existing: priorState
            )
            do {
                _ = try await repository.promoteExistingUserMigration(
                    before: priorState,
                    stagedProjection: reduced.projection,
                    pendingReveal: reduced.pendingReveal,
                    marker: marker
                )
            } catch {
                guard try await reloadAndPublishExistingUserMigration(
                    transactionID: transactionID,
                    snapshotDigest: page.aggregateDigest,
                    cipherCount: page.totalCipherCount,
                    snapshotSchemaVersion: page.snapshot.schemaVersion,
                    handoffSchemaVersion: page.handoffSchemaVersion,
                    pageCount: page.pageCount,
                    capturedAt: marker.value.operationTimestamp
                ) != nil else { throw error }
            }
            if state.projection.metadata.activeGeneration !=
                marker.value.destinationGeneration
            {
                state = try await repository.loadExisting(bundle: bundle)
            }
            try await repository.cleanupInactiveGeneration(
                oldGeneration,
                activeGeneration: state.projection.metadata.activeGeneration,
                operationID:
                    "existing-user-migration.\(transactionID.uuidString.lowercased())"
            )
            try await refreshAndPublish(capturedAt: marker.value.operationTimestamp)
            return .outcome(.applied(
                grantTransactionID: grantTransactionID,
                revision: reduced.projection.metadata.revision,
                delta: reduced.delta
            ))
        } catch let error as ProgressionDomainError {
            switch error {
            case .transactionIdentityCollision:
                return .outcome(.rejectedPermanent(reason: migrationRejection(
                    "progression.migration.transaction-collision"
                )))
            case .recordIdentityCollision, .invalidRecord:
                return .outcome(.rejectedPermanent(reason: migrationRejection(
                    "progression.migration.snapshot-collision"
                )))
            default:
                throw error
            }
        } catch let error as ModuleStateStoreError {
            switch error {
            case .unavailable, .quarantined, .unreadable, .corrupt,
                 .integrityMismatch, .injectedFailure, .revisionConflict:
                if let terminal = try await reloadAndPublishExistingUserMigration(
                    transactionID: transactionID,
                    snapshotDigest: page.aggregateDigest,
                    cipherCount: page.totalCipherCount,
                    snapshotSchemaVersion: page.snapshot.schemaVersion,
                    handoffSchemaVersion: page.handoffSchemaVersion,
                    pageCount: page.pageCount,
                    capturedAt: metadata.timestampUTC
                ) {
                    return .outcome(.applied(
                        grantTransactionID: terminal.grantTransactionID,
                        revision: state.projection.metadata.revision,
                        delta: migrationDelta(in: state.projection)
                    ))
                }
                return .outcome(.deferredStoreUnavailable)
            default:
                throw error
            }
        }
    }

    public func applyEvent(
        _ envelope: DomainEventEnvelope,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionEventApplyResult {
        guard !recoveryOnly,
              !requiresExistingUserMigration || existingUserMigrationRecord() != nil
        else { return .deferredStoreUnavailable }
        do {
            let envelopeDigest = try ProgressionDeterminism.encodedDigest(envelope)
            if let existing = try await repository.processedEvent(
                envelope.eventID,
                generation: state.projection.metadata.activeGeneration
            ) {
                guard existing.envelopeDigest == envelopeDigest,
                      existing.envelope == envelope
                else {
                    return .rejectedPermanent(reason: ProgressionEventValidator.eventIDCollision)
                }
                try await refreshAndPublish(capturedAt: envelope.occurredAt)
                return .duplicate
            }

            switch ProgressionEventValidator.validate(envelope, bundle: bundle) {
            case .unsupportedSchema:
                return .deferredUnsupportedSchema
            case .ignored:
                return try await commitTerminalEvent(
                    envelope,
                    envelopeDigest: envelopeDigest,
                    semanticDigest: nil,
                    outcome: .ignoredIneligible,
                    rejectionCode: nil,
                    result: .ignoredIneligible
                )
            case let .rejected(code):
                return try await commitTerminalEvent(
                    envelope,
                    envelopeDigest: envelopeDigest,
                    semanticDigest: nil,
                    outcome: .rejectedPermanent,
                    rejectionCode: code,
                    result: .rejectedPermanent(reason: code)
                )
            case let .accepted(event):
                if let semantic = try await repository.semanticRecord(
                    event.semanticDigest,
                    generation: state.projection.metadata.activeGeneration
                ) {
                    guard semantic.canonicalMaterial == event.semanticMaterial else {
                        return try await commitTerminalEvent(
                            envelope,
                            envelopeDigest: envelopeDigest,
                            semanticDigest: event.semanticDigest,
                            outcome: .rejectedPermanent,
                            rejectionCode: ProgressionEventValidator.semanticCollision,
                            result: .rejectedPermanent(
                                reason: ProgressionEventValidator.semanticCollision
                            )
                        )
                    }
                    return try await commitTerminalEvent(
                        envelope,
                        envelopeDigest: envelopeDigest,
                        semanticDigest: event.semanticDigest,
                        outcome: .duplicate,
                        rejectionCode: nil,
                        result: .duplicate
                    )
                }

                let candidates = try ProgressionReducer.lifetimeDistinctCandidates(
                    for: event,
                    projection: state.projection,
                    bundle: bundle
                )
                var existingTokens: [DistinctTokenRecord] = []
                for candidate in candidates {
                    if let existing = try await repository.distinctToken(candidate) {
                        guard sameDistinctTokenIdentity(existing, candidate),
                              existing.firstAppliedRevision < candidate.firstAppliedRevision
                        else {
                            throw ProgressionDomainError.recordIdentityCollision(
                                candidate.tokenDigest
                            )
                        }
                        existingTokens.append(existing)
                    }
                }
                let queueTail = try await repository.queueTail(in: state)
                let reduced = try ProgressionReducer.apply(
                    event,
                    to: state,
                    existingLifetimeTokens: existingTokens,
                    queueTail: queueTail,
                    bundle: bundle
                )
                let semantic = ProgressionSemanticDedupeRecord(
                    canonicalMaterial: event.semanticMaterial,
                    firstEventID: envelope.eventID
                )
                let transactionID = eventTransactionID(envelope.eventID)
                let processed = ProcessedEventRecord(
                    envelope: envelope,
                    envelopeDigest: envelopeDigest,
                    semanticDigest: event.semanticDigest,
                    outcome: .applied,
                    transactionID: transactionID,
                    appliedRevision: reduced.projection.metadata.revision
                )
                _ = try await repository.commit(
                    before: state,
                    after: reduced.projection,
                    additions: ProgressionCommitAdditions(
                        processedEvent: processed,
                        appliedEventOrder: try ProgressionAppliedEventOrderRecord(
                            appliedRevision: reduced.projection.metadata.revision,
                            envelope: envelope,
                            cumulativeDigest: reduced.projection.metadata.appliedEventDigest!
                        ),
                        semanticRecord: semantic,
                        distinctTokenUpserts: reduced.newDistinctTokens,
                        pendingRevealUpserts: reduced.queuedRevealUpserts
                    ),
                    transactionID: envelope.eventID.rawValue
                )
                try await refreshAndPublish(capturedAt: envelope.occurredAt)
                return .applied(
                    transactionID: transactionID,
                    revision: reduced.projection.metadata.revision,
                    delta: reduced.delta
                )
            }
        } catch let error as ModuleStateStoreError {
            switch error {
            case .unavailable, .quarantined, .unreadable, .corrupt, .integrityMismatch,
                 .injectedFailure:
                try? await refreshAndPublish(capturedAt: envelope.occurredAt)
                return .deferredStoreUnavailable
            default:
                throw error
            }
        }
    }

    public nonisolated func stateStream(
        metadata: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionSnapshotDTO> {
        let key = streamKey("state", metadata: metadata)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(key) }
            }
            Task { await self.addStateContinuation(key, continuation: continuation, metadata: metadata) }
        }
    }

    func externalSyncState(capturedAt: Date) async throws -> ProgressionExternalSyncState {
        ProgressionExternalSyncState(
            snapshot: try ProgressionSnapshotBuilder.snapshot(
                state: state,
                bundle: bundle,
                capturedAt: capturedAt,
                providerAvailabilityByCodexID: providerAvailabilityByCodexID
            ),
            projection: try await externalProjection()
        )
    }

    func applyExternalMerge(
        _ delivery: RuntimeProgressionExternalMergeDelivery
    ) async throws -> ProgressionExternalSyncState {
        let metadata = delivery.operationMetadata
        guard metadata.operationIdentifier.rawValue == "progression.external-merge.apply",
              metadata.destinationModuleID == RuneScribeModuleIDs.progression,
              !recoveryOnly
        else { throw ProgressionDomainError.invalidRecord("external-merge-authority") }
        let digest = try commandDigest("external-merge", delivery.projection)
        if try await repository.commandReceipt(
            metadata: metadata,
            commandDigest: digest,
            generation: state.projection.metadata.activeGeneration
        ) != nil {
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return try await externalSyncState(capturedAt: metadata.timestampUTC)
        }

        let existingDistinctTokens = try await repository.distinctTokens(
            generation: state.projection.metadata.activeGeneration,
            maximumRevision: state.projection.metadata.revision
        )
        let reduced = try ProgressionReducer.applyExternalMerge(
            delivery.projection,
            to: state.projection,
            transactionID: commandTransactionID(metadata),
            appliedAt: metadata.timestampUTC,
            existingDistinctTokens: existingDistinctTokens,
            bundle: bundle
        )
        var projection = reduced.projection
        let (revision, overflow) = projection.metadata.revision.addingReportingOverflow(1)
        let (commandReceiptCount, commandOverflow) = projection.metadata.commandReceiptCount
            .addingReportingOverflow(1)
        let (distinctTokenCount, distinctOverflow) = projection.metadata.distinctTokenCount
            .addingReportingOverflow(UInt64(reduced.newDistinctTokens.count))
        guard !overflow, !commandOverflow, !distinctOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = metadata.timestampUTC
        projection.metadata.commandReceiptCount = commandReceiptCount
        projection.metadata.distinctTokenCount = distinctTokenCount
        let receipt = commandReceipt(
            metadata: metadata,
            digest: digest,
            resultRevision: revision
        )
        _ = try await repository.commit(
            before: state,
            after: projection,
            additions: ProgressionCommitAdditions(
                distinctTokenUpserts: reduced.newDistinctTokens,
                commandReceipt: receipt
            ),
            transactionID: commandTransactionID(metadata)
        )
        try await refreshAndPublish(capturedAt: metadata.timestampUTC)
        return try await externalSyncState(capturedAt: metadata.timestampUTC)
    }

    private func externalProjection() async throws -> RuntimeProgressionExternalProjection {
        guard let initializedAt = state.projection.metadata.initializedAt else {
            throw ProgressionDomainError.invalidRecord("external-sync-initialized-at")
        }
        let completions = Dictionary(uniqueKeysWithValues: state.projection.records(
            matching: { logical -> (AchievementID, Date)? in
                guard case let .achievementCompletion(record) = logical else { return nil }
                return (record.achievementID, record.completedAt)
            }
        ))
        let milestoneCompletionDates = Dictionary(uniqueKeysWithValues: state.projection.records(
            matching: { logical -> (RuleID, Date)? in
                guard case let .milestoneCompletion(record) = logical else { return nil }
                return (record.ruleID, record.completedAt)
            }
        ))
        let counters = state.projection.records { logical -> RuntimeProgressionCounterFact? in
            guard case let .statisticCounter(record) = logical else { return nil }
            return RuntimeProgressionCounterFact(
                statisticID: record.statisticID,
                codexID: record.bucketID,
                value: record.value
            )
        }
        let distinctRecords = try await repository.distinctTokens(
            generation: state.projection.metadata.activeGeneration,
            maximumRevision: state.projection.metadata.revision
        )
        guard UInt64(distinctRecords.count) == state.projection.metadata.distinctTokenCount else {
            throw ProgressionDomainError.invalidRecord("external-sync-distinct-count")
        }
        var distinctTokens: [RuntimeProgressionDistinctTokenFact] = []
        distinctTokens.reserveCapacity(distinctRecords.count)
        for record in distinctRecords {
            let firstObservedAt: Date
            if let stored = record.firstObservedAt {
                firstObservedAt = stored
            } else if let order = try await repository.appliedEventOrderRecord(
                record.firstAppliedRevision,
                generation: state.projection.metadata.activeGeneration
            ) {
                firstObservedAt = order.envelope.occurredAt
            } else {
                firstObservedAt = initializedAt
            }
            distinctTokens.append(try RuntimeProgressionDistinctTokenFact(
                statisticID: record.statisticID,
                codexID: record.bucketID,
                opaqueTokenDigest: record.cloudOpaqueTokenDigest,
                firstObservedAt: firstObservedAt
            ))
        }
        let achievements = state.projection.records {
            logical -> RuntimeProgressionAchievementFact? in
            guard case let .achievementProgress(record) = logical else { return nil }
            return RuntimeProgressionAchievementFact(
                achievementID: record.achievementID,
                current: record.current,
                target: record.target,
                completedAt: completions[record.achievementID]
            )
        }
        let milestones = state.projection.records {
            logical -> RuntimeProgressionMilestoneFact? in
            guard case let .milestoneCompletion(record) = logical else { return nil }
            return RuntimeProgressionMilestoneFact(
                ruleID: record.ruleID,
                completedAt: record.completedAt
            )
        }
        let grants = state.projection.records { logical -> RuntimeProgressionGrantFact? in
            guard case let .grant(record) = logical else { return nil }
            let firstGrantedAt: Date = switch record.source {
            case let .achievement(achievementID):
                completions[achievementID] ?? record.grantedAt ?? initializedAt
            case let .milestone(ruleID):
                milestoneCompletionDates[ruleID] ?? record.grantedAt ?? initializedAt
            case .migration:
                record.grantedAt ?? initializedAt
            }
            return RuntimeProgressionGrantFact(
                grantID: record.transactionID,
                contentID: record.contentID.rawValue,
                firstGrantedAt: firstGrantedAt,
                provenanceMaterial: record.source.key
            )
        }
        let owned = state.projection.records { logical -> String? in
            guard case let .ownership(record) = logical else { return nil }
            return record.contentID.rawValue
        }
        let unlocks = state.projection.records { logical -> UnlockID? in
            guard case let .entitlement(record) = logical else { return nil }
            return record.entitlementID
        }
        let titles = state.projection.records { logical -> TitleID? in
            guard case let .ownership(record) = logical,
                  bundle.catalog.content(id: record.contentID)?.kind == .title
            else { return nil }
            return TitleID(rawValue: record.contentID.rawValue)
        }
        let encounters = state.projection.records {
            logical -> RuntimeProgressionEncounterFact? in
            guard case let .encounter(record) = logical else { return nil }
            return RuntimeProgressionEncounterFact(
                codexID: record.codexID,
                artifactIDs: record.artifactIDs,
                firstEncounteredAt: record.firstEncounteredAt,
                lastEncounteredAt: record.lastEncounteredAt,
                encounterCount: record.encounterCount
            )
        }
        let selectedTitleRecord: TitleSelectionRecord? = if case let .titleSelection(record)? =
            state.projection.records["title-selection"]
        {
            record
        } else {
            nil
        }
        return RuntimeProgressionExternalProjection(
            catalogVersion: state.projection.metadata.catalogVersion.rawValue,
            localRevision: state.projection.metadata.revision,
            initializedAt: initializedAt,
            counters: counters,
            distinctTokens: distinctTokens,
            achievements: achievements,
            milestones: milestones,
            grants: grants,
            ownedContentIDs: owned,
            unlockIDs: unlocks,
            titleIDs: titles,
            encounters: encounters,
            selectedTitleID: selectedTitleRecord?.selectedTitleID,
            selectedTitleUpdatedAt: selectedTitleRecord?.selectedAt,
            knownStatisticIDs: bundle.catalog.statistics.map(\.statisticID),
            knownAchievementIDs: bundle.catalog.achievements.map(\.achievementID),
            knownMilestoneRuleIDs: bundle.catalog.milestones.map(\.ruleID),
            knownContentIDs: bundle.catalog.content.map(\.contentID.rawValue),
            knownArtifactIDs: bundle.catalog.content.compactMap { definition in
                guard definition.countsAsArtifact else { return nil }
                return ArtifactID(rawValue: definition.contentID.rawValue)
            },
            knownUnlockIDs: bundle.catalog.content.compactMap { definition in
                guard definition.kind == .entitlement else { return nil }
                return UnlockID(rawValue: definition.contentID.rawValue)
            },
            knownTitleIDs: bundle.catalog.content.compactMap { definition in
                guard definition.kind == .title else { return nil }
                return TitleID(rawValue: definition.contentID.rawValue)
            },
            statisticSchemas: bundle.catalog.statistics.map { definition in
                let transport: RuntimeProgressionStatisticTransport
                switch definition.storage {
                case .distinctSet, .bucketedDistinctSet:
                    transport = .distinctToken
                case .derived:
                    transport = .derivedOmitted
                }
                return RuntimeProgressionStatisticSchema(
                    statisticID: definition.statisticID,
                    transport: transport,
                    requiresCodexBucket: definition.bucket == .codexID
                )
            },
            knownCodexIDs: bundle.catalog.content.compactMap { definition in
                guard definition.kind == .codex else { return nil }
                return CodexID(rawValue: definition.contentID.rawValue)
            }
        )
    }

    public nonisolated func entitlementStream(
        metadata: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionEntitlementSnapshotDTO> {
        let key = streamKey("entitlement", metadata: metadata)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEntitlementContinuation(key) }
            }
            Task {
                await self.addEntitlementContinuation(
                    key,
                    continuation: continuation,
                    metadata: metadata
                )
            }
        }
    }

    public func markRevealPresented(
        _ command: MarkProgressionRevealPresentedCommand,
        metadata: RuntimeOperationMetadata
    ) async throws {
        guard !recoveryOnly else { throw ModuleStateStoreError.quarantined }
        let digest = try commandDigest("mark-reveal-presented", command)
        if try await repository.commandReceipt(
            metadata: metadata,
            commandDigest: digest,
            generation: state.projection.metadata.activeGeneration
        ) != nil {
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return
        }
        guard let head = try await repository.validatedRevealQueueHead(
            in: state.projection,
            bundle: bundle
        ), head.value.revealID == command.revealID
        else { throw ProgressionDomainError.unknownReveal(command.revealID) }

        var presentedReveal: PendingRevealRecord?
        switch head.value.state {
        case .queued:
            var presented = head.value
            presented.state = .presented
            presented.presentedAt = metadata.timestampUTC
            try presented.validate()
            presentedReveal = presented
        case .presented:
            presentedReveal = nil
        case .acknowledged:
            throw ProgressionDomainError.invalidRecord("queued-reveal-state")
        }

        var projection = state.projection
        let (revision, revisionOverflow) = projection.metadata.revision
            .addingReportingOverflow(1)
        let (commandReceiptCount, commandOverflow) = projection.metadata
            .commandReceiptCount.addingReportingOverflow(1)
        guard !revisionOverflow, !commandOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = metadata.timestampUTC
        projection.metadata.commandReceiptCount = commandReceiptCount
        let receipt = commandReceipt(
            metadata: metadata,
            digest: digest,
            resultRevision: revision
        )
        _ = try await repository.commit(
            before: state,
            after: projection,
            additions: ProgressionCommitAdditions(
                pendingRevealUpserts: presentedReveal.map { [$0] } ?? [],
                commandReceipt: receipt
            ),
            transactionID: commandTransactionID(metadata)
        )
        try await refreshAndPublish(capturedAt: metadata.timestampUTC)
    }

    public func acknowledgeReveal(
        _ command: AcknowledgeProgressionRevealCommand,
        metadata: RuntimeOperationMetadata
    ) async throws {
        guard !recoveryOnly else { throw ModuleStateStoreError.quarantined }
        let digest = try commandDigest("acknowledge-reveal", command)
        if try await repository.commandReceipt(
            metadata: metadata,
            commandDigest: digest,
            generation: state.projection.metadata.activeGeneration
        ) != nil {
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return
        }
        if try await repository.validatedAcknowledgedReveal(
            command.revealID,
            generation: state.projection.metadata.activeGeneration,
            projection: state.projection,
            bundle: bundle
        ) != nil {
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return
        }
        guard let queued = try await repository.validatedRevealQueueHead(
            in: state.projection,
            bundle: bundle
        ),
              queued.value.revealID == command.revealID,
              queued.value.state == .presented
        else { throw ProgressionDomainError.unknownReveal(command.revealID) }
        guard case let .revealQueueState(queue)? = state.projection.records[
            "reveal-queue-state"
        ], queue.pendingCount > 0 else {
            throw ProgressionDomainError.invalidRecord("reveal-queue-state")
        }

        var projection = state.projection
        let (pendingCount, overflow) = queue.pendingCount.subtractingReportingOverflow(1)
        guard !overflow else { throw ProgressionDomainError.invalidRecord("reveal-queue-count") }
        try projection.upsert(.revealQueueState(ProgressionRevealQueueStateRecord(
            generation: projection.metadata.activeGeneration,
            pendingCount: pendingCount,
            headRevealID: queued.value.nextRevealID,
            tailRevealID: pendingCount == 0 ? nil : queue.tailRevealID
        )))
        let (revision, revisionOverflow) = projection.metadata.revision.addingReportingOverflow(1)
        let (acknowledgedRevealCount, acknowledgementOverflow) = projection.metadata
            .acknowledgedRevealCount.addingReportingOverflow(1)
        let (commandReceiptCount, commandOverflow) = projection.metadata.commandReceiptCount
            .addingReportingOverflow(1)
        guard !revisionOverflow, !acknowledgementOverflow, !commandOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = metadata.timestampUTC
        projection.metadata.acknowledgedRevealCount = acknowledgedRevealCount
        projection.metadata.commandReceiptCount = commandReceiptCount
        var acknowledged = queued.value
        acknowledged.state = .acknowledged
        acknowledged.acknowledgedAt = metadata.timestampUTC
        try acknowledged.validate()
        let receipt = commandReceipt(
            metadata: metadata,
            digest: digest,
            resultRevision: revision
        )
        _ = try await repository.commit(
            before: state,
            after: projection,
            additions: ProgressionCommitAdditions(
                acknowledgedRevealUpsert: acknowledged,
                queuedRevealDeletes: [queued],
                commandReceipt: receipt
            ),
            transactionID: commandTransactionID(metadata)
        )
        try await refreshAndPublish(capturedAt: metadata.timestampUTC)
    }

    public func selectTitle(
        _ command: SelectProgressionTitleCommand,
        metadata: RuntimeOperationMetadata
    ) async throws {
        guard !recoveryOnly else { throw ModuleStateStoreError.quarantined }
        let digest = try commandDigest("select-title", command)
        if try await repository.commandReceipt(
            metadata: metadata,
            commandDigest: digest,
            generation: state.projection.metadata.activeGeneration
        ) != nil {
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return
        }
        if let titleID = command.titleID {
            guard let contentID = ProgressionContentID(rawValue: titleID.rawValue),
                  bundle.catalog.content(id: contentID)?.kind == .title
            else { throw ProgressionDomainError.unknownTitle(titleID) }
            guard state.projection.records["ownership|\(contentID.rawValue)"] != nil else {
                throw ProgressionDomainError.unownedTitle(titleID)
            }
        }
        var projection = state.projection
        try projection.upsert(.titleSelection(TitleSelectionRecord(
            generation: projection.metadata.activeGeneration,
            selectedTitleID: command.titleID,
            selectedAt: metadata.timestampUTC
        )))
        let (revision, overflow) = projection.metadata.revision.addingReportingOverflow(1)
        let (commandReceiptCount, commandOverflow) = projection.metadata.commandReceiptCount
            .addingReportingOverflow(1)
        guard !overflow, !commandOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = metadata.timestampUTC
        projection.metadata.commandReceiptCount = commandReceiptCount
        let receipt = commandReceipt(
            metadata: metadata,
            digest: digest,
            resultRevision: revision
        )
        _ = try await repository.commit(
            before: state,
            after: projection,
            additions: ProgressionCommitAdditions(commandReceipt: receipt),
            transactionID: commandTransactionID(metadata)
        )
        try await refreshAndPublish(capturedAt: metadata.timestampUTC)
    }

    public func diagnosticsSummary(
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionDiagnosticsSummaryDTO {
        state.health = try await repository.client.health()
        let quarantineDiagnostics = try await repository.quarantineDiagnostics(
            health: state.health
        )
        return try ProgressionSnapshotBuilder.diagnostics(
            state: state,
            bundle: bundle,
            quarantineDiagnostics: quarantineDiagnostics,
            capturedAt: metadata.timestampUTC
        )
    }

    public func rebuild(
        _ request: ProgressionRecoveryRequest,
        metadata: RuntimeOperationMetadata
    ) async throws -> ProgressionRecoveryResult {
        guard request.confirmationToken.uuidString !=
            "00000000-0000-0000-0000-000000000000"
        else { throw ProgressionDomainError.rebuildConfirmationMismatch }
        try await synchronizeForRebuild()
        let rebuildingFromRecovery = recoveryOnly
        if rebuildingFromRecovery {
            guard recoveryRebuildPermitted,
                  recoverableProjectionQuarantineCount ==
                    state.health.quarantinedRecordCount
            else {
                throw ProgressionDomainError.invalidRecord(
                    "recovery-direct-integrity-uncertain"
                )
            }
        }
        let initialQuarantinedRecordCount = state.health.quarantinedRecordCount
        var repairedAppliedRecordCount: UInt64 = 0
        let digest = try commandDigest("rebuild", request)
        if let receipt = try await repository.commandReceipt(
            metadata: metadata,
            commandDigest: digest,
            generation: state.projection.metadata.activeGeneration,
            requiresCleanupGeneration: true
        ) {
            guard let cleanupGeneration = receipt.cleanupGeneration else {
                throw ProgressionDomainError.invalidRecord("rebuild-receipt-cleanup")
            }
            try await repository.cleanupInactiveGeneration(
                cleanupGeneration,
                activeGeneration: state.projection.metadata.activeGeneration,
                operationID: metadata.operationID.rawValue
            )
            try await repository.cleanupRecoveryEventCandidates(
                generation: state.projection.metadata.activeGeneration,
                operationID: metadata.operationID.rawValue
            )
            try await refreshAndPublish(capturedAt: metadata.timestampUTC)
            return try ProgressionRecoveryResult(
                rebuiltAt: receipt.completedAt,
                revision: receipt.resultRevision
            )
        }

        let priorState = state
        let oldGeneration = priorState.projection.metadata.activeGeneration
        let upgradingCatalog = priorState.projection.metadata.catalogVersion <
            bundle.catalog.catalogVersion
        let priorMigration: CatalogMigrationRecord?
        if upgradingCatalog {
            let migrations = priorState.projection.records(
                matching: { logical -> CatalogMigrationRecord? in
                    guard case let .catalogMigration(record) = logical else { return nil }
                    return record
                }
            )
            guard migrations.count == 1,
                  migrations[0].catalogVersion ==
                    priorState.projection.metadata.catalogVersion
            else { throw ProgressionDomainError.invalidRecord("recovery-catalog-upgrade") }
            try ProgressionCatalogCompatibility.validateAddOnlyUpgrade(
                from: migrations[0].compatibilityFingerprints,
                to: ProgressionCatalogCompatibility.fingerprints(for: bundle)
            )
            priorMigration = migrations[0]
        } else {
            priorMigration = nil
        }
        let priorExistingUserMigrations = priorState.projection.records(
            matching: { logical -> ExistingUserMigrationRecord? in
                guard case let .existingUserMigration(record) = logical else { return nil }
                return record
            }
        )
        guard priorExistingUserMigrations.count <= 1 else {
            throw ProgressionDomainError.invalidRecord(
                "rebuild-existing-user-migration"
            )
        }
        let priorExistingUserMigration = priorExistingUserMigrations.first
        let priorExistingUserMigrationSeeds: [ExistingUserMigrationSeedRecord]
        if let priorExistingUserMigration {
            priorExistingUserMigrationSeeds = try await repository
                .existingUserMigrationSeeds(generation: oldGeneration)
            try await repository.validateExistingUserMigrationSeedSnapshot(
                generation: oldGeneration,
                expectedCount: priorExistingUserMigration.cipherCount,
                expectedDigest: priorExistingUserMigration.snapshotDigest,
                handoffSchemaVersion:
                    priorExistingUserMigration.handoffSchemaVersion,
                pageCount: priorExistingUserMigration.pageCount
            )
        } else {
            priorExistingUserMigrationSeeds = []
        }
        let stageMarker = try await repository.prepareRebuildStage(
            source: priorState,
            metadata: metadata
        )
        let newGeneration = stageMarker.value.destinationGeneration
        let priorQueuedRevealRecords = if rebuildingFromRecovery {
            try await repository.structurallyValidatedRevealQueueRecords(
                in: priorState.projection,
                bundle: bundle
            )
        } else {
            try await repository.validatedRevealQueueRecords(
                in: priorState.projection,
                bundle: bundle
            )
        }
        var projection = try ProgressionReducer.initialProjection(
            bundle: bundle,
            generation: newGeneration
        )
        projection.metadata.initializedAt = priorState.projection.metadata.initializedAt
        if let priorExistingUserMigration {
            let migrationOutput = try ProgressionExistingUserMigrationReducer.replay(
                record: priorExistingUserMigration,
                seedRecords: priorExistingUserMigrationSeeds,
                to: projection,
                bundle: bundle
            )
            projection = migrationOutput.projection
            try await repository.stageExistingUserMigrationSeedRecords(
                migrationOutput.seedRecords,
                generation: newGeneration,
                operationID: metadata.operationID.rawValue
            )
            try await repository.stageDistinctTokens(
                migrationOutput.distinctTokens,
                generation: newGeneration,
                operationID: metadata.operationID.rawValue,
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
        guard case let .revealQueueState(priorQueueState)? = priorState.projection.records[
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
            health: priorState.health
        )
        var queueTail = priorQueueState.tailRevealID.flatMap { queuedReveals[$0] }
        var cursor: ModuleStateScanCursor?
        var priorAppliedRevision: UInt64?
        var priorAppliedAt: Date? = priorExistingUserMigration?.completedAt

        try await repository.captureRecoveryEventCandidates(
            from: oldGeneration,
            to: newGeneration,
            operationID: metadata.operationID.rawValue
        )
        repeat {
            let page = try await repository.recoveryEventCandidatePage(
                generation: newGeneration,
                cursor: cursor
            )
            for order in page.records {
                guard priorAppliedRevision.map({ $0 < order.appliedRevision }) ?? true else {
                    throw ProgressionDomainError.invalidRecord("rebuild-event-order")
                }
                let storedProcessed: ProcessedEventRecord?
                do {
                    storedProcessed = try await repository.processedEvent(
                        order.eventID,
                        generation: oldGeneration
                    )
                } catch ProgressionDomainError.invalidRecord {
                    storedProcessed = nil
                } catch let error as ModuleStateStoreError {
                    switch error {
                    case .quarantined:
                        storedProcessed = nil
                    case .integrityMismatch, .unreadable, .corrupt:
                        let (next, overflow) = repairedAppliedRecordCount
                            .addingReportingOverflow(1)
                        guard !overflow else {
                            throw ProgressionDomainError.invalidRecord(
                                "rebuild-repair-count"
                            )
                        }
                        repairedAppliedRecordCount = next
                        storedProcessed = nil
                    default:
                        throw error
                    }
                }
                guard case let .accepted(event) = ProgressionEventValidator.validate(
                    storedProcessed?.envelope ?? order.envelope,
                    bundle: bundle
                ) else { throw ProgressionDomainError.invalidRecord("rebuild-event-invalid") }
                let processed = ProcessedEventRecord(
                    envelope: event.envelope,
                    envelopeDigest: try ProgressionDeterminism.encodedDigest(event.envelope),
                    semanticDigest: event.semanticDigest,
                    outcome: .applied,
                    transactionID: eventTransactionID(order.eventID),
                    appliedRevision: order.appliedRevision
                )
                if let storedProcessed, storedProcessed != processed {
                    guard order.sourceCumulativeDigest != nil else {
                        throw ProgressionDomainError.invalidRecord(
                            "rebuild-processed-event-mismatch"
                        )
                    }
                    try await repository.quarantineProcessedEvent(
                        eventID: order.eventID,
                        generation: oldGeneration
                    )
                }

                projection = replayState.projection
                let priorRevision = order.appliedRevision.subtractingReportingOverflow(1)
                guard !priorRevision.overflow else {
                    throw ProgressionDomainError.invalidRecord("rebuild-event-revision")
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
                        guard sameDistinctTokenIdentity(record, candidate) else {
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
                    // The validated active queue is authoritative presentation state.
                    // Rebuild reconstructs domain state but never recreates historical reveals.
                    suppressReveal: true,
                    bundle: bundle
                )
                if let sourceDigest = order.sourceCumulativeDigest {
                    if sourceDigest != reduced.projection.metadata.appliedEventDigest {
                        guard order.hasProcessedSource else {
                            throw ProgressionDomainError.invalidRecord("rebuild-ledger-digest")
                        }
                        try await repository.quarantineAppliedEventOrder(
                            revision: order.appliedRevision,
                            generation: oldGeneration
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
                    operationID: metadata.operationID.rawValue
                )
                try await repository.stageDistinctTokens(
                    reduced.newDistinctTokens,
                    generation: newGeneration,
                    operationID: metadata.operationID.rawValue,
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
            generation: oldGeneration,
            replacementGeneration: newGeneration,
            expectedQueuedRevealIDs: Set(queuedReveals.keys)
        )
        let preCopyHealth = try await repository.client.health()
        let (minimumRecoverableQuarantineCount, quarantineOverflow) =
            initialQuarantinedRecordCount.addingReportingOverflow(
                repairedAppliedRecordCount
            )
        guard !quarantineOverflow,
              preCopyHealth.quarantinedRecordCount >= minimumRecoverableQuarantineCount
        else {
            throw ProgressionDomainError.invalidRecord(
                "recovery-direct-integrity-uncertain"
            )
        }
        let copySummary = try await repository.copyGenerationScopedRecords(
            from: oldGeneration,
            to: newGeneration,
            appliedEventCount: projection.metadata.appliedEventCount,
            sourceRevision: priorState.projection.metadata.revision,
            sourceProjection: priorState.projection,
            bundle: bundle,
            validateAcknowledgementReferences: !rebuildingFromRecovery,
            operationID: metadata.operationID.rawValue
        )
        projection.metadata.processedEventCount = copySummary.processedEventCount
        projection.metadata.terminalProcessedEventDigest =
            copySummary.terminalProcessedEventDigest
        projection.metadata.acknowledgedRevealCount = copySummary.acknowledgedRevealCount
        projection.metadata.acknowledgedRevealDigest = copySummary.acknowledgedRevealDigest
        projection.metadata.commandReceiptCount = copySummary.commandReceiptCount
        projection.metadata.commandReceiptDigest = copySummary.commandReceiptDigest
        try await repository.validateActiveAppliedLedger(projection, bundle: bundle)
        try preserveCommandState(
            from: priorState.projection,
            recoveredSelection: rebuildingFromRecovery ? recoveredTitleSelection : nil,
            mayDropInvalidSelection: rebuildingFromRecovery,
            in: &projection
        )
        try preserveBootstrapTimes(
            from: priorState.projection.metadata.initializedAt,
            in: &projection
        )
        let previouslyOwnedContentIDs = priorMigration.map {
            ProgressionCatalogUpgradeCoordinator.canonicallyPriorOwnedContentIDs(
                in: projection,
                priorFingerprints: $0.compatibilityFingerprints
            )
        }
        let domainStateMatches: Bool
        if rebuildingFromRecovery {
            domainStateMatches = true
        } else {
            domainStateMatches = try ProgressionProjectionComparison.hasEquivalentDomainState(
                priorState.projection,
                projection
            )
        }
        guard projection.metadata.appliedEventCount ==
                priorState.projection.metadata.appliedEventCount,
              projection.metadata.lastAppliedRevision ==
                priorState.projection.metadata.lastAppliedRevision,
              projection.metadata.appliedEventDigest ==
                priorState.projection.metadata.appliedEventDigest,
              projection.metadata.processedEventCount ==
                priorState.projection.metadata.processedEventCount,
              projection.metadata.terminalProcessedEventDigest ==
                priorState.projection.metadata.terminalProcessedEventDigest,
              projection.metadata.distinctTokenCount ==
                priorState.projection.metadata.distinctTokenCount,
              projection.metadata.acknowledgedRevealCount ==
                priorState.projection.metadata.acknowledgedRevealCount,
              projection.metadata.acknowledgedRevealDigest ==
                priorState.projection.metadata.acknowledgedRevealDigest,
              projection.metadata.commandReceiptCount ==
                priorState.projection.metadata.commandReceiptCount,
              projection.metadata.commandReceiptDigest ==
                priorState.projection.metadata.commandReceiptDigest,
              domainStateMatches
        else {
            throw ProgressionDomainError.invalidRecord("rebuild-state-mismatch")
        }
        let (revision, overflow) = priorState.projection.metadata.revision
            .addingReportingOverflow(1)
        let (commandReceiptCount, commandOverflow) = projection.metadata.commandReceiptCount
            .addingReportingOverflow(1)
        guard !overflow, !commandOverflow else {
            throw ProgressionDomainError.invalidRecord("revision-overflow")
        }
        projection.metadata.revision = revision
        projection.metadata.lastMutationAt = metadata.timestampUTC
        projection.metadata.commandReceiptCount = commandReceiptCount
        if let priorMigration, let previouslyOwnedContentIDs {
            let upgradeReveal = try ProgressionCatalogUpgradeCoordinator.appendUpgradeReveal(
                catalog: bundle.catalog,
                fromVersion: priorMigration.catalogVersion,
                transactionID: commandTransactionID(metadata),
                createdAt: metadata.timestampUTC,
                previouslyOwnedContentIDs: previouslyOwnedContentIDs,
                projection: &projection,
                queuedReveals: &queuedReveals,
                queueTail: &queueTail
            )
            try projection.upsert(.catalogMigration(CatalogMigrationRecord(
                generation: newGeneration,
                migrationVersion: bundle.catalog.migration.migrationVersion,
                catalogVersion: bundle.catalog.catalogVersion,
                transactionID: commandTransactionID(metadata),
                completedAt: metadata.timestampUTC,
                compatibilityFingerprints: try ProgressionCatalogCompatibility.fingerprints(
                    for: bundle
                ),
                upgradeRevealBundle: upgradeReveal.map {
                    CatalogMigrationRecord.UpgradeRevealBundle(reveal: $0)
                },
                priorCatalogVersion: priorMigration.catalogVersion,
                priorGeneration: oldGeneration
            )))
        }

        try await repository.validatePreservedRevealReferences(
            priorQueuedRevealRecords,
            against: projection,
            bundle: bundle
        )
        try await repository.validateAcknowledgementReferences(
            generation: oldGeneration,
            against: projection,
            bundle: bundle
        )
        let postCopyHealth = try await repository.client.health()
        guard postCopyHealth.quarantinedRecordCount ==
                preCopyHealth.quarantinedRecordCount
        else {
            throw ProgressionDomainError.invalidRecord(
                "recovery-direct-integrity-uncertain"
            )
        }
        projection.metadata.knownInactiveQuarantineCount =
            postCopyHealth.quarantinedRecordCount

        try await repository.stage(
            projection,
            distinctTokens: [],
            pendingReveals: queuedReveals.values.sorted { $0.revealID < $1.revealID },
            operationID: metadata.operationID.rawValue,
            existing: priorState
        )
        let receipt = commandReceipt(
            metadata: metadata,
            digest: digest,
            resultRevision: revision,
            cleanupGeneration: oldGeneration
        )
        _ = try await repository.promoteStagedGeneration(
            before: priorState,
            stagedProjection: projection,
            stagedReveals: queuedReveals.values.sorted { $0.revealID < $1.revealID },
            receipt: receipt,
            transactionID: commandTransactionID(metadata),
            rebuildStageMarker: stageMarker,
            allowsCatalogUpgrade: upgradingCatalog
        )
        try await repository.cleanupRecoveryEventCandidates(
            generation: newGeneration,
            operationID: metadata.operationID.rawValue
        )
        state = try await repository.loadExisting(bundle: bundle)
        recoveryOnly = false
        recoveredTitleSelection = nil
        recoverableProjectionQuarantineCount = nil
        recoveryRebuildPermitted = true
        try await repository.cleanupInactiveGeneration(
            oldGeneration,
            activeGeneration: state.projection.metadata.activeGeneration,
            operationID: metadata.operationID.rawValue
        )
        if upgradingCatalog {
            state = try await repository.completeCatalogUpgradeCleanup(
                state,
                completedAt: metadata.timestampUTC,
                operationID: metadata.operationID.rawValue,
                bundle: bundle
            )
        }
        try await refreshAndPublish(capturedAt: metadata.timestampUTC)
        return try ProgressionRecoveryResult(rebuiltAt: metadata.timestampUTC, revision: revision)
    }

    private func startAvailabilityObservation(
        _ snapshots: AsyncStream<RuntimeAvailabilitySnapshot>?
    ) {
        guard let snapshots else { return }
        runtimeAvailabilityTask?.cancel()
        runtimeAvailabilityTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                await self?.adoptRuntimeAvailability(snapshot)
            }
        }
    }

    private func adoptRuntimeAvailability(_ snapshot: RuntimeAvailabilitySnapshot) {
        if let runtimeAvailabilityRevision,
           snapshot.revision < runtimeAvailabilityRevision
        {
            return
        }
        runtimeAvailabilityRevision = snapshot.revision
        let projected = ProgressionProviderAvailabilityProjection.availabilityByCodexID(
            snapshot: snapshot,
            bindings: bundle.futureThemeBindings
        )
        guard projected != providerAvailabilityByCodexID else { return }
        providerAvailabilityByCodexID = projected
        let stateSnapshot: ProgressionSnapshotDTO
        do {
            stateSnapshot = try ProgressionSnapshotBuilder.snapshot(
                state: state,
                bundle: bundle,
                capturedAt: snapshot.capturedAt,
                providerAvailabilityByCodexID: providerAvailabilityByCodexID
            )
        } catch {
            terminateStateStreams(reason: .snapshotProjectionFailed)
            return
        }
        for continuation in stateContinuations.values {
            continuation.yield(stateSnapshot)
        }
    }

    public func shutdown() {
        runtimeAvailabilityTask?.cancel()
        runtimeAvailabilityTask = nil
        for continuation in stateContinuations.values { continuation.finish() }
        for continuation in entitlementContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
        entitlementContinuations.removeAll()
    }

    private func commitTerminalEvent(
        _ envelope: DomainEventEnvelope,
        envelopeDigest: String,
        semanticDigest: String?,
        outcome: ProgressionProcessedEventOutcome,
        rejectionCode: ProgressionRejectionCode?,
        result: ProgressionEventApplyResult
    ) async throws -> ProgressionEventApplyResult {
        let record = ProcessedEventRecord(
            envelope: envelope,
            envelopeDigest: envelopeDigest,
            semanticDigest: semanticDigest,
            outcome: outcome,
            rejectionCode: rejectionCode
        )
        var projection = state.projection
        let (processedEventCount, overflow) = projection.metadata.processedEventCount
            .addingReportingOverflow(1)
        guard !overflow else {
            throw ProgressionDomainError.invalidRecord("processed-event-count-overflow")
        }
        projection.metadata.processedEventCount = processedEventCount
        _ = try await repository.commit(
            before: state,
            after: projection,
            additions: ProgressionCommitAdditions(processedEvent: record),
            transactionID: envelope.eventID.rawValue
        )
        state = try await repository.loadExisting(bundle: bundle)
        return result
    }

    private func refreshAndPublish(capturedAt: Date) async throws {
        let refreshed = try await repository.loadExisting(bundle: bundle)
        try publish(refreshed, capturedAt: capturedAt)
    }

    private func publish(
        _ refreshed: ProgressionRepositoryState,
        capturedAt: Date
    ) throws {
        state = refreshed
        recoveryOnly = false
        recoveredTitleSelection = nil
        recoverableProjectionQuarantineCount = nil
        recoveryRebuildPermitted = true
        let snapshot = try ProgressionSnapshotBuilder.snapshot(
            state: state,
            bundle: bundle,
            capturedAt: capturedAt,
            providerAvailabilityByCodexID: providerAvailabilityByCodexID
        )
        let entitlements = try ProgressionSnapshotBuilder.entitlements(
            state: state,
            capturedAt: capturedAt
        )
        for continuation in stateContinuations.values { continuation.yield(snapshot) }
        for continuation in entitlementContinuations.values {
            continuation.yield(entitlements)
        }
    }

    private func addStateContinuation(
        _ key: String,
        continuation: AsyncStream<ProgressionSnapshotDTO>.Continuation,
        metadata: RuntimeOperationMetadata
    ) {
        stateContinuations.removeValue(forKey: key)?.finish()
        guard stateStreamTerminalReason == nil else {
            continuation.finish()
            return
        }
        stateContinuations[key] = continuation
        do {
            let snapshot = try ProgressionSnapshotBuilder.snapshot(
                state: state,
                bundle: bundle,
                capturedAt: metadata.timestampUTC,
                providerAvailabilityByCodexID: providerAvailabilityByCodexID
            )
            continuation.yield(snapshot)
        } catch {
            terminateStateStreams(reason: .snapshotProjectionFailed)
        }
    }

    func stateStreamTerminationReason() -> ProgressionExternalSyncTerminalReason? {
        stateStreamTerminalReason
    }

    private func terminateStateStreams(reason: ProgressionExternalSyncTerminalReason) {
        stateStreamTerminalReason = reason
        for continuation in stateContinuations.values { continuation.finish() }
        stateContinuations.removeAll()
    }

    private func addEntitlementContinuation(
        _ key: String,
        continuation: AsyncStream<ProgressionEntitlementSnapshotDTO>.Continuation,
        metadata: RuntimeOperationMetadata
    ) {
        entitlementContinuations.removeValue(forKey: key)?.finish()
        entitlementContinuations[key] = continuation
        if let snapshot = try? ProgressionSnapshotBuilder.entitlements(
            state: state,
            capturedAt: metadata.timestampUTC
        ) {
            continuation.yield(snapshot)
        } else {
            continuation.finish()
            entitlementContinuations.removeValue(forKey: key)
        }
    }

    private func removeStateContinuation(_ key: String) {
        stateContinuations.removeValue(forKey: key)
    }

    private func removeEntitlementContinuation(_ key: String) {
        entitlementContinuations.removeValue(forKey: key)
    }

    private func synchronizeForRebuild() async throws {
        do {
            state = try await repository.loadExisting(bundle: bundle)
            recoveryOnly = false
            recoveredTitleSelection = nil
            recoverableProjectionQuarantineCount = nil
            recoveryRebuildPermitted = true
        } catch {
            let anchor = try await repository.recoveryAnchor(bundle: bundle)
            guard anchor.metadata.catalogVersion <= bundle.catalog.catalogVersion,
                  anchor.metadata.catalogVersion == bundle.catalog.catalogVersion ||
                    anchor.recoveredCatalogMigration != nil,
                  anchor.metadata.initializedAt != nil
            else { throw error }
            state = try Self.recoveryState(bundle: bundle, anchor: anchor)
            recoveryOnly = true
            recoveredTitleSelection = try await repository.recoverableTitleSelection(
                metadata: anchor.metadata
            )
            recoverableProjectionQuarantineCount = try Self
                .expectedRecoveryQuarantineCount(anchor)
            recoveryRebuildPermitted = anchor.directRecoveryPermitted
        }
    }

    private static func recoveryState(
        bundle: ValidatedProgressionCatalogBundle,
        anchor: ProgressionRecoveryAnchor
    ) throws -> ProgressionRepositoryState {
        var projection = try ProgressionReducer.initialProjection(
            bundle: bundle,
            generation: anchor.metadata.activeGeneration
        )
        projection.metadata = anchor.metadata
        projection.physicalMetadata = anchor.physicalMetadata
        projection.bootstrapRuntimeTimestamp = anchor.metadata.initializedAt
        if let initializedAt = anchor.metadata.initializedAt {
            try stampIncludedBaseline(initializedAt, in: &projection)
        }
        if let revealQueueState = anchor.recoveredRevealQueueState {
            try projection.upsert(.revealQueueState(revealQueueState))
        }
        for record in anchor.recoveredRevealValidationRecords {
            try projection.upsert(record)
        }
        if let migration = anchor.recoveredCatalogMigration {
            try projection.upsert(.catalogMigration(migration))
        }
        if let migration = anchor.recoveredExistingUserMigration {
            try projection.upsert(.existingUserMigration(migration))
        }
        let health = ModuleStateHealthSnapshot(
            namespace: anchor.health.namespace,
            loadState: .corrupt,
            storeRevision: anchor.health.storeRevision,
            namespaceSchemaVersion: anchor.health.namespaceSchemaVersion,
            recordCount: anchor.health.recordCount,
            quarantinedRecordCount: anchor.health.quarantinedRecordCount,
            accessDisposition: .readWrite,
            capturedAt: anchor.health.capturedAt,
            diagnosticCode: "progression.recovery-required"
        )
        return ProgressionRepositoryState(
            projection: projection,
            nextPendingReveal: nil,
            inactiveShards: [:],
            health: health
        )
    }

    private static func expectedRecoveryQuarantineCount(
        _ anchor: ProgressionRecoveryAnchor
    ) throws -> UInt64 {
        let (projectionCount, projectionOverflow) = anchor.metadata.knownInactiveQuarantineCount
            .addingReportingOverflow(anchor.quarantinedProjectionRecordCount)
        let (count, directOverflow) = projectionCount.addingReportingOverflow(
            anchor.recoverableDirectQuarantineCount
        )
        guard !projectionOverflow, !directOverflow else {
            throw ProgressionDomainError.invalidRecord("recovery-quarantine-count")
        }
        return count
    }

    private static func stampIncludedBaseline(
        _ timestamp: Date,
        in projection: inout ProgressionProjection
    ) throws {
        for logical in projection.logicalRecords() {
            switch logical {
            case let .grant(record):
                guard case .migration = record.source else { continue }
                try projection.upsert(.grant(GrantRecord(
                    generation: record.generation,
                    grantGroupID: record.grantGroupID,
                    contentID: record.contentID,
                    source: record.source,
                    transactionID: record.transactionID,
                    grantedAt: timestamp
                )))
            case let .ownership(record):
                try projection.upsert(.ownership(OwnershipRecord(
                    generation: record.generation,
                    contentID: record.contentID,
                    sourceGrantKeys: record.sourceGrantKeys,
                    grantedAt: timestamp
                )))
            case let .entitlement(record):
                guard record.source == .included else { continue }
                try projection.upsert(.entitlement(ProgressionEntitlementRecord(
                    generation: record.generation,
                    entitlementID: record.entitlementID,
                    contentID: record.contentID,
                    source: record.source,
                    grantedAt: timestamp
                )))
            case let .catalogMigration(record):
                try projection.upsert(.catalogMigration(CatalogMigrationRecord(
                    generation: record.generation,
                    migrationVersion: record.migrationVersion,
                    catalogVersion: record.catalogVersion,
                    transactionID: record.transactionID,
                    completedAt: timestamp,
                    compatibilityFingerprints: record.compatibilityFingerprints,
                    upgradeRevealBundle: record.upgradeRevealBundle,
                    priorCatalogVersion: record.priorCatalogVersion,
                    priorGeneration: record.priorGeneration,
                    cleanupCompletedAt: record.cleanupCompletedAt
                )))
            default:
                continue
            }
        }
    }

    private func preserveCommandState(
        from active: ProgressionProjection,
        recoveredSelection: TitleSelectionRecord?,
        mayDropInvalidSelection: Bool,
        in rebuilt: inout ProgressionProjection
    ) throws {
        guard case let .titleSelection(activeSelection)? = active.records["title-selection"] else {
            throw ProgressionDomainError.invalidRecord("title-selection-missing")
        }
        var selection = recoveredSelection ?? activeSelection
        if let titleID = selection.selectedTitleID,
           let contentID = ProgressionContentID(rawValue: titleID.rawValue),
           bundle.catalog.content(id: contentID)?.kind == .title,
           rebuilt.records["ownership|\(contentID.rawValue)"] != nil
        {
            // The rebuilt ownership projection validates the salvaged selection.
        } else if let titleID = selection.selectedTitleID {
            guard mayDropInvalidSelection else {
                throw ProgressionDomainError.unownedTitle(titleID)
            }
            selection = TitleSelectionRecord(
                generation: selection.generation,
                selectedTitleID: nil,
                selectedAt: nil
            )
        }
        try rebuilt.upsert(.titleSelection(TitleSelectionRecord(
            generation: rebuilt.metadata.activeGeneration,
            selectedTitleID: selection.selectedTitleID,
            selectedAt: selection.selectedAt
        )))
        let migrations = active.records(matching: { logical -> CatalogMigrationRecord? in
            if case let .catalogMigration(record) = logical { return record }
            return nil
        })
        guard migrations.count == 1 else {
            throw ProgressionDomainError.invalidRecord("catalog-migration-missing")
        }
        let migration = migrations[0]
        try rebuilt.upsert(.catalogMigration(CatalogMigrationRecord(
            generation: rebuilt.metadata.activeGeneration,
            migrationVersion: migration.migrationVersion,
            catalogVersion: migration.catalogVersion,
            transactionID: migration.transactionID,
            completedAt: migration.completedAt,
            compatibilityFingerprints: migration.compatibilityFingerprints,
            upgradeRevealBundle: migration.upgradeRevealBundle,
            priorCatalogVersion: migration.priorCatalogVersion,
            priorGeneration: migration.priorGeneration,
            cleanupCompletedAt: migration.cleanupCompletedAt
        )))
        for logical in active.logicalRecords() {
            guard case let .grant(record) = logical,
                  case .migration = record.source,
                  rebuilt.records[logical.identity] != nil
            else { continue }
            try rebuilt.upsert(.grant(GrantRecord(
                generation: rebuilt.metadata.activeGeneration,
                grantGroupID: record.grantGroupID,
                contentID: record.contentID,
                source: record.source,
                transactionID: record.transactionID,
                grantedAt: record.grantedAt
            )))
        }
    }

    private func preserveBootstrapTimes(
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

    private func existingUserMigrationRecord() -> ExistingUserMigrationRecord? {
        Self.existingUserMigrationRecord(in: state.projection)
    }

    private static func existingUserMigrationRecord(
        in projection: ProgressionProjection
    ) -> ExistingUserMigrationRecord? {
        let records = projection.records(matching: {
            logical -> ExistingUserMigrationRecord? in
            guard case let .existingUserMigration(record) = logical else { return nil }
            return record
        })
        return records.count == 1 ? records[0] : nil
    }

    private func reloadAndPublishExistingUserMigration(
        transactionID: UUID,
        snapshotDigest: String,
        cipherCount: UInt32,
        snapshotSchemaVersion: UInt16,
        handoffSchemaVersion: UInt16? = nil,
        pageCount: UInt32? = nil,
        capturedAt: Date
    ) async throws -> ExistingUserMigrationRecord? {
        let committed = try await repository.loadExisting(bundle: bundle)
        guard let terminal = Self.existingUserMigrationRecord(
            in: committed.projection
        ), terminal.transactionID == transactionID,
           terminal.snapshotDigest == snapshotDigest,
           terminal.cipherCount == cipherCount,
           terminal.snapshotSchemaVersion == snapshotSchemaVersion
        else { return nil }
        if let handoffSchemaVersion {
            guard terminal.handoffSchemaVersion == handoffSchemaVersion,
                  terminal.pageCount == pageCount
            else { return nil }
        }
        try publish(committed, capturedAt: capturedAt)
        return terminal
    }

    private func migrationDelta(
        in projection: ProgressionProjection
    ) -> ProgressionStateDeltaSummary {
        let migration = Self.existingUserMigrationRecord(in: projection)
        let completed = projection.records(matching: { logical -> AchievementID? in
            guard case let .achievementCompletion(record) = logical,
                  record.sourceExistingUserMigrationTransactionID != nil
            else { return nil }
            return record.achievementID
        })
        let migrationGrantContent = Set(projection.records(matching: {
            logical -> ProgressionContentID? in
            guard case let .grant(record) = logical,
                  case let .achievement(id) = record.source,
                  completed.contains(id)
            else { return nil }
            return record.contentID
        }))
        return ProgressionStateDeltaSummary(
            changedStatisticCount: migration?.cipherCount == 0 ? 0 : 1,
            completedAchievementCount: UInt16(clamping: completed.count),
            completedMilestoneCount: 0,
            grantedContentCount: UInt16(clamping: migrationGrantContent.count),
            grantedEntitlementCount: 0,
            queuedRevealCount: migration?.revealBundle == nil ? 0 : 1
        )
    }

    private func migrationRejection(_ rawValue: String) -> ProgressionRejectionCode {
        ProgressionRejectionCode(rawValue: rawValue)!
    }

    private func commandReceipt(
        metadata: RuntimeOperationMetadata,
        digest: String,
        resultRevision: UInt64,
        cleanupGeneration: String? = nil
    ) -> ProgressionCommandReceiptRecord {
        ProgressionCommandReceiptRecord(
            operationID: metadata.operationID.rawValue,
            correlationID: metadata.correlationID.rawValue,
            operationIdentifier: metadata.operationIdentifier.rawValue,
            commandDigest: digest,
            completedAt: metadata.timestampUTC,
            resultRevision: resultRevision,
            cleanupGeneration: cleanupGeneration
        )
    }

    private func commandDigest<T: Encodable>(_ kind: String, _ command: T) throws -> String {
        ProgressionDeterminism.digest128(
            "\(kind)|\(try ProgressionDeterminism.encodedDigest(command))"
        )
    }

    private func commandTransactionID(_ metadata: RuntimeOperationMetadata) -> UUID {
        ProgressionDeterminism.transactionUUID(
            "runtime-operation|\(metadata.operationIdentifier.rawValue)|\(metadata.operationID.rawValue)"
        )
    }

    private func eventTransactionID(_ eventID: EventID) -> GrantTransactionID {
        GrantTransactionID(
            rawValue: "transaction.\(eventID.rawValue.uuidString.lowercased())"
        )!
    }

    private func revealID(for eventID: EventID) -> RevealID {
        RevealID(rawValue: "reveal.\(eventID.rawValue.uuidString.lowercased())")!
    }
}

private func streamKey(_ kind: String, metadata: RuntimeOperationMetadata) -> String {
    "\(kind)|\(metadata.operationIdentifier.rawValue)|\(metadata.operationID.rawValue)"
}

private func sameDistinctTokenIdentity(
    _ lhs: DistinctTokenRecord,
    _ rhs: DistinctTokenRecord
) -> Bool {
    lhs.generation == rhs.generation &&
        lhs.statisticID == rhs.statisticID &&
        lhs.bucketID == rhs.bucketID &&
        lhs.tokenDigest == rhs.tokenDigest &&
        lhs.canonicalToken == rhs.canonicalToken &&
        lhs.externalOpaqueTokenDigest == rhs.externalOpaqueTokenDigest
}
