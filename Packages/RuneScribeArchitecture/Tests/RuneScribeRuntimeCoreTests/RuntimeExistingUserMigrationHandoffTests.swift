import Foundation
import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

private let migrationHandoffNamespace = ModuleStateNamespace(
    moduleID: "com.runescribe.runtime.existing-user-migration-handoff"
)
private let migrationHandoffCollectionID = ModuleStateCollectionID(
    rawValue: "progression.existing-user-migration"
)!
private let progressionOutboxMigrationTestNamespace = ModuleStateNamespace(
    moduleID: "com.runescribe.runtime.progression-outbox"
)

@MainActor
final class RuntimeExistingUserMigrationHandoffTests: XCTestCase {
    func testSubmitPersistsExactlyOnceAndRejectsChangedSchemaV1Snapshot() async throws {
        let store = InMemoryModuleStateStore()
        let capture = MigrationClientCapture()
        let runtime = try await makeMigrationRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 20_000),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let firstSnapshot = try snapshot(count: 5)

        let first = try await client.submit(firstSnapshot)
        let retry = try await client.submit(firstSnapshot)
        XCTAssertEqual(retry, first)
        XCTAssertEqual(first.snapshotSchemaVersion, 1)
        XCTAssertEqual(first.cipherCount, 5)
        let firstRecordCount = await store.recordCount(
            namespace: migrationHandoffNamespace
        )
        XCTAssertEqual(firstRecordCount, 1)

        do {
            _ = try await client.submit(snapshot(count: 4))
            XCTFail("Expected a changed schema-v1 snapshot to collide")
        } catch {
            XCTAssertEqual(
                error as? RuntimeExistingUserMigrationHandoffError,
                .snapshotCollision
            )
        }
        let collisionRecordCount = await store.recordCount(
            namespace: migrationHandoffNamespace
        )
        XCTAssertEqual(collisionRecordCount, 1)
        await runtime.stop()
    }

    func testMaximumSnapshotRemainsWithinDurableAndEndpointBounds() async throws {
        let store = InMemoryModuleStateStore()
        let capture = MigrationClientCapture()
        let runtime = try await makeMigrationRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 20_100),
            progression: nil
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let maximum = try snapshot(
            count: ExistingUserMigrationSnapshotDTO.maximumCipherCount,
            maximumLengthTokens: true
        )

        let receipt = try await client.submit(maximum)

        XCTAssertEqual(receipt.cipherCount, 4_096)
        let records = try await migrationRecords(in: store)
        XCTAssertEqual(records.count, 1)
        XCTAssertLessThan(records[0].payload.count, 1_048_576)
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.applyExistingUserMigration
                .descriptor.maximumRequestBytes,
            1_048_576
        )
        await runtime.stop()

        let probe = MigrationProgressionProbe(store: store, results: [.duplicate])
        let replay = try await makeMigrationRuntime(
            store: store,
            capture: MigrationClientCapture(),
            now: Date(timeIntervalSince1970: 20_110),
            progression: MigrationProgressionService(probe: probe)
        )
        try await replay.start()
        try await waitUntil { await probe.deliveries().count == 1 }
        let deliveredCount = await probe.deliveries().first?.snapshot.ciphers.count
        XCTAssertEqual(deliveredCount, 4_096)
        await replay.stop()
    }

    func testPagedSnapshotPersistsBoundedPagesAndDeliversAggregateInOrder() async throws {
        let store = InMemoryModuleStateStore()
        let probe = MigrationProgressionProbe(
            store: store,
            results: [],
            pageResults: [
                .accepted(pageIndex: 0),
                .outcome(.duplicate),
            ]
        )
        let capture = MigrationClientCapture()
        let runtime = try await makeMigrationRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 20_150),
            progression: MigrationProgressionService(probe: probe)
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let allCiphers = try ciphers(count: 4_097, maximumLengthTokens: true)

        let receipt = try await client.submit(ciphers: allCiphers.reversed())

        XCTAssertEqual(receipt.handoffSchemaVersion, 2)
        XCTAssertEqual(receipt.snapshotSchemaVersion, 1)
        XCTAssertEqual(receipt.cipherCount, 4_097)
        XCTAssertEqual(receipt.pageCount, 2)
        try await waitUntil { await probe.pageDeliveries().count == 2 }
        let deliveries = await probe.pageDeliveries()
        XCTAssertEqual(deliveries.map(\.page.pageIndex), [0, 1])
        XCTAssertEqual(deliveries.map { $0.page.snapshot.ciphers.count }, [4_096, 1])
        XCTAssertEqual(Set(deliveries.map(\.page.aggregateDigest)).count, 1)
        let schemaV1Deliveries = await probe.deliveries()
        XCTAssertTrue(schemaV1Deliveries.isEmpty)
        for delivery in deliveries {
            XCTAssertLessThan(try JSONEncoder().encode(delivery).count, 1_048_576)
        }
        let records = try await allMigrationRecords(in: store)
        XCTAssertEqual(records.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.payload.count < 1_048_576 })
        XCTAssertEqual(
            RuntimeProgressionEndpointCatalog.applyExistingUserMigrationPage
                .descriptor.maximumRequestBytes,
            1_048_576
        )
        await runtime.stop()
    }

    func testPagedSnapshotRelaunchesAndRejectsChangedAggregate() async throws {
        let store = InMemoryModuleStateStore()
        let firstCapture = MigrationClientCapture()
        let first = try await makeMigrationRuntime(
            store: store,
            capture: firstCapture,
            now: Date(timeIntervalSince1970: 20_160),
            progression: nil
        )
        try await first.start()
        let firstCapturedClient = await firstCapture.client()
        let firstClient = try XCTUnwrap(firstCapturedClient)
        let allCiphers = try ciphers(count: 4_097)
        let receipt = try await firstClient.submit(ciphers: allCiphers)
        var changed = allCiphers
        changed[0] = try ExistingUserMigrationCipherDTO(
            cipherToken: changed[0].cipherToken,
            origin: changed[0].origin == .generated ? .imported : .generated
        )
        do {
            _ = try await firstClient.submit(ciphers: changed)
            XCTFail("Expected changed aggregate collision")
        } catch {
            XCTAssertEqual(
                error as? RuntimeExistingUserMigrationHandoffError,
                .snapshotCollision
            )
        }
        await first.stop()

        let probe = MigrationProgressionProbe(
            store: store,
            results: [],
            pageResults: [.accepted(pageIndex: 0), .outcome(.duplicate)]
        )
        let secondCapture = MigrationClientCapture()
        let second = try await makeMigrationRuntime(
            store: store,
            capture: secondCapture,
            now: Date(timeIntervalSince1970: 20_170),
            progression: MigrationProgressionService(probe: probe)
        )
        try await second.start()
        try await waitUntil { await probe.pageDeliveries().count == 2 }
        let secondCapturedClient = await secondCapture.client()
        let secondClient = try XCTUnwrap(secondCapturedClient)
        let retryReceipt = try await secondClient.submit(ciphers: allCiphers)
        XCTAssertEqual(retryReceipt, receipt)
        await second.stop()
    }

    func testPagedSnapshotPageStageFaultsAreReadbackAndRetrySafe() async throws {
        let ciphers = try ciphers(count: 4_097)

        let beforeStore = InMemoryModuleStateStore()
        let beforeCapture = MigrationClientCapture()
        let before = try await makeMigrationRuntime(
            store: beforeStore,
            capture: beforeCapture,
            now: Date(timeIntervalSince1970: 20_180),
            progression: nil
        )
        try await before.start()
        let beforeCapturedClient = await beforeCapture.client()
        let beforeClient = try XCTUnwrap(beforeCapturedClient)
        await beforeStore.injectFault(
            at: .beforeTransactionCommit,
            afterSuccessfulCalls: 1
        )
        do {
            _ = try await beforeClient.submit(ciphers: ciphers)
            XCTFail("Expected first page before-commit fault")
        } catch ModuleStateStoreError.injectedFailure {}
        let interruptedRecordCount = try await allMigrationRecords(
            in: beforeStore
        ).count
        XCTAssertEqual(interruptedRecordCount, 1)
        let recovered = try await beforeClient.submit(ciphers: ciphers)
        XCTAssertEqual(recovered.cipherCount, 4_097)
        let recoveredRecordCount = try await allMigrationRecords(
            in: beforeStore
        ).count
        XCTAssertEqual(recoveredRecordCount, 3)
        await before.stop()

        let afterStore = InMemoryModuleStateStore()
        let afterCapture = MigrationClientCapture()
        let after = try await makeMigrationRuntime(
            store: afterStore,
            capture: afterCapture,
            now: Date(timeIntervalSince1970: 20_190),
            progression: nil
        )
        try await after.start()
        let afterCapturedClient = await afterCapture.client()
        let afterClient = try XCTUnwrap(afterCapturedClient)
        await afterStore.injectFault(
            at: .afterTransactionCommit,
            afterSuccessfulCalls: 1
        )
        let readback = try await afterClient.submit(ciphers: ciphers)
        XCTAssertEqual(readback.cipherCount, 4_097)
        let readbackRecordCount = try await allMigrationRecords(
            in: afterStore
        ).count
        XCTAssertEqual(readbackRecordCount, 3)
        await after.stop()
    }

    func testPersistBeforeDeliveryAndNeverFabricatesCatalogEvents() async throws {
        let store = InMemoryModuleStateStore()
        let probe = MigrationProgressionProbe(
            store: store,
            results: [.duplicate]
        )
        let capture = MigrationClientCapture()
        let runtime = try await makeMigrationRuntime(
            store: store,
            capture: capture,
            now: Date(timeIntervalSince1970: 20_200),
            progression: MigrationProgressionService(probe: probe)
        )
        try await runtime.start()
        let capturedClient = await capture.client()
        let client = try XCTUnwrap(capturedClient)
        let snapshot = try snapshot(count: 20)

        let receipt = try await client.submit(snapshot)
        try await waitUntil { await probe.deliveries().count == 1 }

        let deliveries = await probe.deliveries()
        XCTAssertEqual(deliveries.first?.transactionID, receipt.transactionID)
        XCTAssertEqual(deliveries.first?.snapshot, snapshot)
        let deliveriesWereDurable = await probe
            .allDeliveriesObservedDurableRecord()
        let eventApplyCount = await probe.eventApplyCount()
        let outboxRecordCount = await store.recordCount(
            namespace: progressionOutboxMigrationTestNamespace
        )
        XCTAssertTrue(deliveriesWereDurable)
        XCTAssertEqual(eventApplyCount, 0)
        XCTAssertEqual(outboxRecordCount, 0)
        try await waitUntil {
            guard let record = try? await self.migrationRecords(in: store).first,
                  let json = String(data: record.payload, encoding: .utf8)
            else { return false }
            return json.contains(#""state":"terminal""#)
                && !json.contains(#""snapshot":{"#)
        }

        let terminalRetry = try await client.submit(snapshot)
        XCTAssertEqual(terminalRetry, receipt)
        try await Task.sleep(for: .milliseconds(20))
        let deliveryCountAfterRetry = await probe.deliveries().count
        XCTAssertEqual(deliveryCountAfterRetry, 1)
        await runtime.stop()
    }

    func testUnavailableAndDeferredProgressionReplayAcrossRelaunch() async throws {
        let store = InMemoryModuleStateStore()
        let firstCapture = MigrationClientCapture()
        let first = try await makeMigrationRuntime(
            store: store,
            capture: firstCapture,
            now: Date(timeIntervalSince1970: 20_300),
            progression: nil
        )
        try await first.start()
        let firstCapturedClient = await firstCapture.client()
        let firstClient = try XCTUnwrap(firstCapturedClient)
        let snapshot = try snapshot(count: 19)
        let receipt = try await firstClient.submit(snapshot)
        let runningSnapshot = await first.snapshot()
        XCTAssertEqual(
            runningSnapshot.status,
            .running,
            "Optional Progression absence must not break Core utility"
        )
        await first.stop()

        let deferredProbe = MigrationProgressionProbe(
            store: store,
            results: [.deferredStoreUnavailable]
        )
        let second = try await makeMigrationRuntime(
            store: store,
            capture: MigrationClientCapture(),
            now: Date(timeIntervalSince1970: 20_310),
            progression: MigrationProgressionService(probe: deferredProbe)
        )
        try await second.start()
        try await waitUntil { await deferredProbe.deliveries().count == 1 }
        await second.stop()

        let terminalProbe = MigrationProgressionProbe(
            store: store,
            results: [.duplicate]
        )
        let thirdCapture = MigrationClientCapture()
        let third = try await makeMigrationRuntime(
            store: store,
            capture: thirdCapture,
            now: Date(timeIntervalSince1970: 20_320),
            progression: MigrationProgressionService(probe: terminalProbe)
        )
        try await third.start()
        try await waitUntil { await terminalProbe.deliveries().count == 1 }
        let thirdCapturedClient = await thirdCapture.client()
        let thirdClient = try XCTUnwrap(thirdCapturedClient)
        let replayReceipt = try await thirdClient.submit(snapshot)
        XCTAssertEqual(replayReceipt, receipt)
        await third.stop()
    }

    func testTransactionPhaseFaultsAreAbsenceSafeAndReadbackSafe() async throws {
        let beforeStore = InMemoryModuleStateStore()
        let beforeCapture = MigrationClientCapture()
        let before = try await makeMigrationRuntime(
            store: beforeStore,
            capture: beforeCapture,
            now: Date(timeIntervalSince1970: 20_400),
            progression: nil
        )
        try await before.start()
        let beforeCapturedClient = await beforeCapture.client()
        let beforeClient = try XCTUnwrap(beforeCapturedClient)
        await beforeStore.injectFault(at: .beforeTransactionCommit)
        do {
            _ = try await beforeClient.submit(snapshot(count: 0))
            XCTFail("Expected the before-commit fault")
        } catch ModuleStateStoreError.injectedFailure {}
        let absentRecordCount = await beforeStore.recordCount(
            namespace: migrationHandoffNamespace
        )
        XCTAssertEqual(absentRecordCount, 0)
        _ = try await beforeClient.submit(snapshot(count: 0))
        let retriedRecordCount = await beforeStore.recordCount(
            namespace: migrationHandoffNamespace
        )
        XCTAssertEqual(retriedRecordCount, 1)
        await before.stop()

        let afterStore = InMemoryModuleStateStore()
        let afterCapture = MigrationClientCapture()
        let after = try await makeMigrationRuntime(
            store: afterStore,
            capture: afterCapture,
            now: Date(timeIntervalSince1970: 20_500),
            progression: nil
        )
        try await after.start()
        let afterCapturedClient = await afterCapture.client()
        let afterClient = try XCTUnwrap(afterCapturedClient)
        await afterStore.injectFault(at: .afterTransactionCommit)
        let recovered = try await afterClient.submit(snapshot(count: 4))
        XCTAssertEqual(recovered.cipherCount, 4)
        let recoveredRecordCount = await afterStore.recordCount(
            namespace: migrationHandoffNamespace
        )
        XCTAssertEqual(recoveredRecordCount, 1)
        let recoveredRetry = try await afterClient.submit(snapshot(count: 4))
        XCTAssertEqual(recoveredRetry, recovered)
        await after.stop()
    }

    func testCapabilityAndEndpointAreCoreOnlyAndNeverUIPublished() async throws {
        let policy = RuntimePolicy.patternBFoundation
        XCTAssertTrue(
            policy.capabilities.allows(
                RuneScribeCapabilities.progressionMigrationSubmit,
                for: RuneScribeRoles.core
            )
        )
        XCTAssertFalse(
            policy.capabilities.allows(
                RuneScribeCapabilities.progressionMigrationSubmit,
                for: RuneScribeRoles.primaryUI
            )
        )
        XCTAssertTrue(
            policy.capabilities.allows(
                RuneScribeCapabilities.progressionMigrationApply,
                for: RuneScribeRoles.applicationHost
            )
        )
        XCTAssertFalse(
            RuntimeProgressionEndpointCatalog.UIEndpointIDs.contains(
                RuntimeProgressionEndpointCatalog.applyExistingUserMigration
                    .descriptor.endpointID
            )
        )
        XCTAssertFalse(
            RuntimeProgressionEndpointCatalog.UIEndpointIDs.contains(
                RuntimeProgressionEndpointCatalog.applyExistingUserMigrationPage
                    .descriptor.endpointID
            )
        )

        let deniedCapture = MigrationDeniedClientCapture()
        let runtime = try await makeMigrationRuntime(
            store: InMemoryModuleStateStore(),
            capture: MigrationClientCapture(),
            now: Date(timeIntervalSince1970: 20_600),
            progression: nil,
            deniedCapture: deniedCapture
        )
        try await runtime.start()
        let denied = await deniedCapture.error()
        XCTAssertEqual(
            denied,
            .capabilityDenied(
                moduleID: RuneScribeModuleIDs.primaryUI,
                capability: RuneScribeCapabilities.progressionMigrationSubmit
            )
        )
        await runtime.stop()
    }

    private func makeMigrationRuntime(
        store: InMemoryModuleStateStore,
        capture: MigrationClientCapture,
        now: Date,
        progression: MigrationProgressionService?,
        deniedCapture: MigrationDeniedClientCapture? = nil
    ) async throws -> RuneScribeRuntime {
        let version = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
        let runtime = RuneScribeRuntime(
            runtimeVersion: version,
            platform: .macOS,
            environment: RuntimeEnvironment(now: { now }, nextUUID: { UUID() })
        )
        let core = migrationCoreDescriptor(version: version)
        try await runtime.register(
            manifest: migrationManifest(for: core, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: core,
                make: {
                    MigrationTestModule(descriptor: core) { context in
                        await capture.setClient(
                            try await context.existingUserMigrationClient()
                        )
                    }
                }
            )
        )
        if let progression {
            let descriptor = migrationProgressionDescriptor(version: version)
            try await runtime.register(
                manifest: migrationManifest(
                    for: descriptor,
                    runtimeVersion: version
                ),
                factory: AnyModuleFactory(
                    descriptor: descriptor,
                    make: {
                        MigrationTestModule(descriptor: descriptor) { context in
                            try await context.registerProgressionEndpoints(progression)
                        }
                    }
                )
            )
        }
        let ui = migrationUIDescriptor(version: version)
        try await runtime.register(
            manifest: migrationManifest(for: ui, runtimeVersion: version),
            factory: AnyModuleFactory(
                descriptor: ui,
                make: {
                    MigrationTestModule(descriptor: ui) { context in
                        guard let deniedCapture else { return }
                        do {
                            _ = try await context.existingUserMigrationClient()
                        } catch let error as RuneScribeRuntimeError {
                            await deniedCapture.setError(error)
                        }
                    }
                }
            )
        )
        try await runtime.installPlatformAdapter(
            store,
            for: RuneScribeServiceKeys.moduleStateStore
        )
        return runtime
    }

    private func snapshot(
        count: Int,
        maximumLengthTokens: Bool = false
    ) throws -> ExistingUserMigrationSnapshotDTO {
        try ExistingUserMigrationSnapshotDTO(
            ciphers: ciphers(count: count, maximumLengthTokens: maximumLengthTokens)
        )
    }

    private func ciphers(
        count: Int,
        maximumLengthTokens: Bool = false
    ) throws -> [ExistingUserMigrationCipherDTO] {
        try (0 ..< count).map { index in
            let suffix = String(format: "%016x", index)
            let paddingCount = maximumLengthTokens ? 112 : 32
            return try ExistingUserMigrationCipherDTO(
                cipherToken: XCTUnwrap(
                    CipherToken(
                        rawValue: String(repeating: "c", count: paddingCount)
                            + suffix
                    )
                ),
                origin: index.isMultiple(of: 2) ? .generated : .imported
            )
        }
    }

    private func migrationRecords(
        in store: InMemoryModuleStateStore
    ) async throws -> [ModuleStateRecord] {
        let request = try ModuleStateScanRequest(
            collectionID: migrationHandoffCollectionID,
            limit: 2
        )
        return try await store.scan(
            namespace: migrationHandoffNamespace,
            request: request
        ).records
    }

    private func allMigrationRecords(
        in store: InMemoryModuleStateStore
    ) async throws -> [ModuleStateRecord] {
        let request = try ModuleStateScanRequest(
            collectionID: migrationHandoffCollectionID,
            limit: ModuleStateScanRequest.maximumLimit
        )
        return try await store.scan(
            namespace: migrationHandoffNamespace,
            request: request
        ).records
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0 ..< 300 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for migration handoff state")
    }
}

private actor MigrationClientCapture {
    private var stored: RuntimeExistingUserMigrationClient?

    func setClient(_ client: RuntimeExistingUserMigrationClient) {
        stored = client
    }

    func client() -> RuntimeExistingUserMigrationClient? { stored }
}

private actor MigrationDeniedClientCapture {
    private var stored: RuneScribeRuntimeError?

    func setError(_ error: RuneScribeRuntimeError) { stored = error }
    func error() -> RuneScribeRuntimeError? { stored }
}

private actor MigrationProgressionProbe {
    private let store: InMemoryModuleStateStore
    private var results: [ExistingUserMigrationApplyResult]
    private var received: [ExistingUserMigrationDeliveryDTO] = []
    private var pageResults: [ExistingUserMigrationPageApplyResult]
    private var receivedPages: [ExistingUserMigrationPageDeliveryDTO] = []
    private var durableAtEveryDelivery = true
    private var receivedEventApplyCount = 0

    init(
        store: InMemoryModuleStateStore,
        results: [ExistingUserMigrationApplyResult],
        pageResults: [ExistingUserMigrationPageApplyResult] = []
    ) {
        self.store = store
        self.results = results
        self.pageResults = pageResults
    }

    func applyMigrationPage(
        _ delivery: ExistingUserMigrationPageDeliveryDTO
    ) async -> ExistingUserMigrationPageApplyResult {
        if await store.recordCount(namespace: migrationHandoffNamespace) == 0 {
            durableAtEveryDelivery = false
        }
        receivedPages.append(delivery)
        return pageResults.isEmpty
            ? .outcome(.duplicate)
            : pageResults.removeFirst()
    }

    func applyMigration(
        _ delivery: ExistingUserMigrationDeliveryDTO
    ) async -> ExistingUserMigrationApplyResult {
        if await store.recordCount(namespace: migrationHandoffNamespace) == 0 {
            durableAtEveryDelivery = false
        }
        received.append(delivery)
        return results.isEmpty ? .duplicate : results.removeFirst()
    }

    func noteEventApply() { receivedEventApplyCount += 1 }
    func deliveries() -> [ExistingUserMigrationDeliveryDTO] { received }
    func pageDeliveries() -> [ExistingUserMigrationPageDeliveryDTO] {
        receivedPages
    }
    func allDeliveriesObservedDurableRecord() -> Bool { durableAtEveryDelivery }
    func eventApplyCount() -> Int { receivedEventApplyCount }
}

private struct MigrationProgressionService: RuneScribeProgressionService,
    RuneScribeExistingUserMigrationApplying
{
    let probe: MigrationProgressionProbe

    func applyExistingUserMigration(
        _ delivery: ExistingUserMigrationDeliveryDTO,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationApplyResult {
        await probe.applyMigration(delivery)
    }

    func applyExistingUserMigrationPage(
        _ delivery: ExistingUserMigrationPageDeliveryDTO,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ExistingUserMigrationPageApplyResult {
        await probe.applyMigrationPage(delivery)
    }

    func applyEvent(
        _: DomainEventEnvelope,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionEventApplyResult {
        await probe.noteEventApply()
        return .duplicate
    }

    func stateStream(
        metadata _: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionSnapshotDTO> {
        AsyncStream { continuation in continuation.finish() }
    }

    func entitlementStream(
        metadata _: RuntimeOperationMetadata
    ) -> AsyncStream<ProgressionEntitlementSnapshotDTO> {
        AsyncStream { continuation in continuation.finish() }
    }

    func acknowledgeReveal(
        _: AcknowledgeProgressionRevealCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {}

    func selectTitle(
        _: SelectProgressionTitleCommand,
        metadata _: RuntimeOperationMetadata
    ) async throws {}

    func diagnosticsSummary(
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionDiagnosticsSummaryDTO {
        try ProgressionDiagnosticsSummaryDTO(
            capturedAt: Date(timeIntervalSince1970: 1),
            availability: .available,
            storeHealth: .loaded,
            catalogID: nil,
            catalogVersion: nil,
            pendingOutboxCount: 0
        )
    }

    func rebuild(
        _: ProgressionRecoveryRequest,
        metadata _: RuntimeOperationMetadata
    ) async throws -> ProgressionRecoveryResult {
        try ProgressionRecoveryResult(
            rebuiltAt: Date(timeIntervalSince1970: 1),
            revision: 1
        )
    }
}

private struct MigrationTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startAction: @Sendable (ModuleContext) async throws -> Void

    func start(context: ModuleContext) async throws {
        try await startAction(context)
    }

    func stop() async {}
}

private func migrationCoreDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.core,
        moduleVersion: version,
        kind: .service,
        entryPoint: "MigrationCore",
        role: RuneScribeRoles.core,
        requestedCapabilities: [
            RuneScribeCapabilities.progressionMigrationSubmit,
        ]
    )
}

private func migrationUIDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.primaryUI,
        moduleVersion: version,
        kind: .ui,
        entryPoint: "MigrationUI",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [RuneScribeCapabilities.rootUI],
        requiredModuleRoles: [RuneScribeRoles.core]
    )
}

private func migrationProgressionDescriptor(
    version: SemanticVersion
) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.progression,
        moduleVersion: version,
        kind: .service,
        criticality: .optional,
        entryPoint: "MigrationProgression",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [],
        publishedEndpoints: RuntimeProgressionEndpointCatalog.publishedEndpointIDs
            .union(RuntimeProgressionEndpointCatalog.existingUserMigrationEndpointIDs)
    )
}

private func migrationManifest(
    for descriptor: ModuleDescriptor,
    runtimeVersion: SemanticVersion
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
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
    )
}
