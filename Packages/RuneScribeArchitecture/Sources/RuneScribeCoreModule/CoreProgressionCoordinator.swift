import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

enum CoreProgressionCoordinatorError: Error, Equatable, Sendable {
    case operationTooLarge
    case duplicateFact
    case evidenceMigrationFailed
}

enum CoreProgressionDrainResult: Equatable, Sendable {
    case durable
    case retainedForRetry
    case unavailable
}

protocol CoreProgressionOutboxTransport: Sendable {
    func submitBatch(
        _ batch: ProgressionEventFactBatch,
        context: RuntimePersistableOperationContext
    ) async throws -> ProgressionOutboxBatchReceipt

    func issueBackgroundContext(
        for purpose: RuntimeBackgroundOperationPurpose
    ) async throws -> RuntimePersistableOperationContext

    func acknowledgeBatch(
        _ receipt: ProgressionOutboxBatchReceipt,
        context: RuntimePersistableOperationContext
    ) async throws
}

extension RuntimeProgressionOutboxClient: CoreProgressionOutboxTransport {}

protocol CoreProgressionTokenDeriving: Sendable {
    func makeCipherSeed() async throws -> Data
    func cipherToken(for seed: Data) async throws -> CipherToken
    func makeMessageToken() async throws -> MessageToken
    func packageToken(for admittedPackageBytes: Data) async throws -> PackageToken
    func makeRelationshipSeed() async throws -> Data
    func relationshipToken(for seed: Data) async throws -> RelationshipToken
}

extension ProgressionTokenService: CoreProgressionTokenDeriving {}

/// Coordinates the optional progression rail without making utility behavior
/// depend on the Progression Module. Core persists the complete fact evidence
/// first; this actor only delivers and acknowledges evidence already committed
/// inside the encrypted cipher library.
actor CoreProgressionCoordinator {
    private let repository: CipherRepository
    private let tokens: any CoreProgressionTokenDeriving
    private let outbox: (any CoreProgressionOutboxTransport)?

    init(
        repository: CipherRepository,
        tokens: any CoreProgressionTokenDeriving,
        outbox: (any CoreProgressionOutboxTransport)?
    ) {
        self.repository = repository
        self.tokens = tokens
        self.outbox = outbox
    }

    init(
        repository: CipherRepository,
        runtimeIO: RuntimeIOClient,
        outbox: RuntimeProgressionOutboxClient?
    ) {
        self.init(
            repository: repository,
            tokens: ProgressionTokenService(runtimeIO: runtimeIO),
            outbox: outbox
        )
    }

    static func commandDigest<Value: Encodable>(
        _ value: Value
    ) throws -> CoreProgressionDigest {
        try CoreProgressionDigest.canonical(value)
    }

    static func pendingBatches(
        context: RuntimePersistableOperationContext,
        commandDigest: CoreProgressionDigest,
        facts: [ProgressionEventFact]
    ) throws -> [CorePendingProgressionBatch] {
        guard facts.count <= ProgressionEventFactBatch.maximumFactsPerOperation else {
            throw CoreProgressionCoordinatorError.operationTooLarge
        }
        guard !facts.isEmpty else { return [] }

        var factDigests = Set<CoreProgressionDigest>()
        for fact in facts {
            let digest = try CoreProgressionDigest.canonical(fact)
            guard factDigests.insert(digest).inserted else {
                throw CoreProgressionCoordinatorError.duplicateFact
            }
        }

        let maximum = ProgressionEventFactBatch.maximumFactsPerBatch
        let totalFactCount = UInt32(facts.count)
        let totalBatchCount = UInt32((facts.count + maximum - 1) / maximum)
        var batches: [CorePendingProgressionBatch] = []
        batches.reserveCapacity(Int(totalBatchCount))

        for batchIndex in 0 ..< Int(totalBatchCount) {
            let start = batchIndex * maximum
            let end = min(start + maximum, facts.count)
            let slotted = try facts[start ..< end].enumerated().map { offset, fact in
                try SlottedProgressionEventFact(
                    slot: ProgressionFactSlot(rawValue: UInt32(start + offset)),
                    fact: fact
                )
            }
            let batch = try ProgressionEventFactBatch(
                batchIndex: UInt32(batchIndex),
                totalBatchCount: totalBatchCount,
                totalFactCount: totalFactCount,
                facts: slotted
            )
            batches.append(try CorePendingProgressionBatch(
                context: context,
                commandDigest: commandDigest,
                batch: batch
            ))
        }
        return batches
    }

    func issueContext(
        for purpose: RuntimeBackgroundOperationPurpose
    ) async throws -> RuntimePersistableOperationContext {
        guard let outbox else {
            throw CoreProgressionCoordinatorError.evidenceMigrationFailed
        }
        return try await outbox.issueBackgroundContext(for: purpose)
    }

    /// Upgrades the encrypted library in place without emitting historical
    /// domain events. PRG-5 consumes the separately derived migration snapshot.
    @discardableResult
    func migrateEvidenceIfNeeded() async throws -> CipherLibrary {
        let library = try await repository.snapshot()
        guard library.version == CipherLibrary.legacyVersion else {
            return library
        }

        var cipherSeeds: [UUID: Data] = [:]
        cipherSeeds.reserveCapacity(library.ciphers.count)
        var relationshipSeeds: [CoreProgressionRelationshipIdentity: Data] = [:]

        for cipher in library.ciphers {
            cipherSeeds[cipher.id] = try await tokens.makeCipherSeed()
            if let contactID = cipher.contactID {
                let identity = CoreProgressionRelationshipIdentity(
                    cipherID: cipher.id,
                    contactID: contactID
                )
                relationshipSeeds[identity] = try await tokens.makeRelationshipSeed()
            }
        }

        let mutation = try await repository.migrateProgressionEvidence(
            using: CoreProgressionMigrationSeedSet(
                cipherSeeds: cipherSeeds,
                relationshipSeeds: relationshipSeeds
            )
        )
        return mutation.library
    }

    func cipherSeed() async throws -> Data {
        try await tokens.makeCipherSeed()
    }

    func cipherToken(for seed: Data) async throws -> CipherToken {
        try await tokens.cipherToken(for: seed)
    }

    func messageToken() async throws -> MessageToken {
        try await tokens.makeMessageToken()
    }

    func packageToken(for admittedPackageBytes: Data) async throws -> PackageToken {
        try await tokens.packageToken(for: admittedPackageBytes)
    }

    func relationshipSeed() async throws -> Data {
        try await tokens.makeRelationshipSeed()
    }

    func relationshipToken(for seed: Data) async throws -> RelationshipToken {
        try await tokens.relationshipToken(for: seed)
    }

    /// Derives the PRG-5 handoff exclusively from encrypted randomized seeds.
    /// The returned snapshot contains no cipher identifiers, delivery state,
    /// relationship state, key material, or contact information.
    func existingUserMigrationSnapshot() async throws
        -> CoreProgressionMigrationSnapshot
    {
        let ledger = try await repository.progressionEvidenceSnapshot()
        var tokensByCipherID: [UUID: CipherToken] = [:]
        tokensByCipherID.reserveCapacity(ledger.cipherSeeds.count)
        for record in ledger.cipherSeeds {
            tokensByCipherID[record.cipherID] = try await tokens.cipherToken(
                for: record.seed
            )
        }
        return try await repository.progressionMigrationSnapshot(
            cipherTokensByID: tokensByCipherID
        )
    }

    /// Drains receipts before pending facts, submits each operation in batch
    /// order, and removes Core evidence only after Runtime acknowledges every
    /// batch. Any failure leaves the exact facts and receipt needed for retry.
    func drain() async -> CoreProgressionDrainResult {
        guard let outbox else { return .unavailable }
        do {
            try await acknowledgeRetainedReceipts(using: outbox)
            try await recontextualizeEphemeralEvidence(using: outbox)

            let pending = try await repository.pendingProgressionBatches()
            for item in pending {
                let receipt = try await outbox.submitBatch(
                    item.batch,
                    context: item.context
                )
                _ = try await repository.recordProgressionBatchReceipt(
                    context: item.context,
                    receipt: receipt
                )
            }

            try await acknowledgeRetainedReceipts(using: outbox)
            let remainingPending = try await repository.pendingProgressionBatches()
            let remainingAcknowledged = try await repository
                .acknowledgedProgressionBatches()
            return remainingPending.isEmpty && remainingAcknowledged.isEmpty
                ? .durable
                : .retainedForRetry
        } catch {
            return .retainedForRetry
        }
    }

    private func recontextualizeEphemeralEvidence(
        using outbox: any CoreProgressionOutboxTransport
    ) async throws {
        let pending = try await repository.pendingProgressionBatches()
        var ephemeralContextDigests: [CoreProgressionDigest] = []
        for item in pending where item.context.authorityScope == .runtimeGeneration {
            if !ephemeralContextDigests.contains(item.identity.contextDigest) {
                ephemeralContextDigests.append(item.identity.contextDigest)
            }
        }

        for sourceDigest in ephemeralContextDigests {
            let replacement = try await outbox.issueBackgroundContext(
                for: .evidenceRecovery
            )
            guard replacement.authorityScope == .persistent else {
                throw CoreProgressionCoordinatorError.evidenceMigrationFailed
            }
            _ = try await repository.recontextualizePendingProgressionBatches(
                from: sourceDigest,
                to: replacement
            )
        }
    }

    private func acknowledgeRetainedReceipts(
        using outbox: any CoreProgressionOutboxTransport
    ) async throws {
        let retained = try await repository.acknowledgedProgressionBatches()
        var contextDigests: [CoreProgressionDigest] = []
        for item in retained where !contextDigests.contains(item.identity.contextDigest) {
            contextDigests.append(item.identity.contextDigest)
        }
        let pending = try await repository.pendingProgressionBatches()
        for contextDigest in contextDigests {
            guard !pending.contains(where: {
                $0.identity.contextDigest == contextDigest
            }) else {
                continue
            }
            let ordered = retained.filter {
                $0.identity.contextDigest == contextDigest
            }
            for item in ordered {
                try await outbox.acknowledgeBatch(
                    item.receipt,
                    context: item.context
                )
            }
            for item in ordered {
                _ = try await repository.clearAcknowledgedProgressionBatch(
                    context: item.context,
                    receipt: item.receipt
                )
            }
        }
    }
}
