import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribePlatform
import XCTest

final class AppleSQLiteModuleStateStoreTests: XCTestCase {
    func testSQLiteStoreReopensWithDurableRecordsAndReceipts() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let key = recordKey(collection: "state", record: "snapshot")
        let transactionID = UUID()

        var firstStore: AppleSQLiteModuleStateStore? = try fixture.makeStore()
        let initialHealth = try await firstStore?.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(initialHealth?.loadState, .absent)
        let result = try await firstStore?.transact(
            namespace: namespace,
            transaction: transaction(
                id: transactionID,
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data("durable".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(result?.storeRevision, 1)
        firstStore = nil

        let reopened = try fixture.makeStore()
        let reopenedHealth = try await reopened.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(reopenedHealth.loadState, .loaded)
        XCTAssertEqual(reopenedHealth.recordCount, 1)
        let record = try await reopened.fetch(namespace: namespace, key: key)
        XCTAssertEqual(record?.payload, Data("durable".utf8))
        XCTAssertEqual(record?.revision, 1)
        XCTAssertEqual(record?.integrityDigest.count, SHA256.Digest.byteCount)

        let replay = try await reopened.transact(
            namespace: namespace,
            transaction: transaction(
                id: transactionID,
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data("durable".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(replay, result)
        let finalHealth = await reopened.health(namespace: namespace)
        XCTAssertEqual(finalHealth.storeRevision, 1)
    }

    func testNamespacesKeepIdenticalLogicalKeysIsolated() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let firstNamespace = ModuleStateNamespace(moduleID: "module.progression")
        let secondNamespace = ModuleStateNamespace(moduleID: "module.theme")
        let key = recordKey(collection: "state", record: "snapshot")
        _ = try await store.prepareNamespace(firstNamespace, schemaVersion: 1)
        _ = try await store.prepareNamespace(secondNamespace, schemaVersion: 3)

        _ = try await store.transact(
            namespace: firstNamespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data("progression".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )

        let firstRecord = try await store.fetch(namespace: firstNamespace, key: key)
        let secondRecord = try await store.fetch(namespace: secondNamespace, key: key)
        let firstHealth = await store.health(namespace: firstNamespace)
        let secondHealth = await store.health(namespace: secondNamespace)
        XCTAssertEqual(firstRecord?.payload, Data("progression".utf8))
        XCTAssertNil(secondRecord)
        XCTAssertEqual(firstHealth.recordCount, 1)
        XCTAssertEqual(secondHealth.recordCount, 0)
        XCTAssertEqual(secondHealth.namespaceSchemaVersion, 3)
    }

    func testScanUsesStableRecordOrderingAndRevisionBoundCursor() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let collection = collectionID("events")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)

        let keys = ["record-c", "record-a", "record-b"].map {
            ModuleStateRecordKey(collectionID: collection, recordID: recordID($0))
        }
        _ = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: keys.map { key in
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data(key.recordID.rawValue.utf8),
                            expectedRevision: .absent
                        )
                    )
                }
            )
        )

        let firstPage = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(collectionID: collection, limit: 2)
        )
        XCTAssertEqual(
            firstPage.records.map(\.key.recordID.rawValue),
            ["record-a", "record-b"]
        )
        let cursor = try XCTUnwrap(firstPage.nextCursor)
        XCTAssertEqual(cursor.afterRecordID.rawValue, "record-b")
        XCTAssertEqual(cursor.observedStoreRevision, 1)

        let secondPage = try await store.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: collection,
                limit: 2,
                cursor: cursor
            )
        )
        XCTAssertEqual(secondPage.records.map(\.key.recordID.rawValue), ["record-c"])
        XCTAssertNil(secondPage.nextCursor)

        _ = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: recordKey(collection: "events", record: "record-d"),
                            schemaVersion: 1,
                            payload: Data("d".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        await assertStoreError(.invalidRequest) {
            _ = try await store.scan(
                namespace: namespace,
                request: try ModuleStateScanRequest(
                    collectionID: collection,
                    limit: 2,
                    cursor: cursor
                )
            )
        }
    }

    func testExpectedRevisionConflictDoesNotMutateRecord() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let key = recordKey(collection: "state", record: "snapshot")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        _ = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data("first".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )

        await assertStoreError(
            .revisionConflict(
                collectionID: key.collectionID,
                recordID: key.recordID,
                expected: 0,
                actual: 1
            )
        ) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: key,
                                schemaVersion: 1,
                                payload: Data("conflicting".utf8),
                                expectedRevision: .exact(0)
                            )
                        ),
                    ]
                )
            )
        }
        let unchangedRecord = try await store.fetch(namespace: namespace, key: key)
        let unchangedHealth = await store.health(namespace: namespace)
        XCTAssertEqual(unchangedRecord?.payload, Data("first".utf8))
        XCTAssertEqual(unchangedHealth.storeRevision, 1)

        let updated = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data("second".utf8),
                            expectedRevision: .exact(1)
                        )
                    ),
                ]
            )
        )
        XCTAssertEqual(updated.mutations.first?.revision, 2)
    }

    func testTransactionIDReplayRequiresTheOriginalMutationRequest() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let key = recordKey(collection: "state", record: "snapshot")
        let transactionID = UUID()
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        let original = transaction(
            id: transactionID,
            mutations: [
                .upsert(
                    ModuleStateUpsert(
                        key: key,
                        schemaVersion: 1,
                        payload: Data("original".utf8),
                        expectedRevision: .absent
                    )
                ),
            ]
        )

        let first = try await store.transact(namespace: namespace, transaction: original)
        let replay = try await store.transact(namespace: namespace, transaction: original)
        XCTAssertEqual(replay, first)

        await assertStoreError(.invalidRequest) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    id: transactionID,
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: key,
                                schemaVersion: 1,
                                payload: Data("different".utf8),
                                expectedRevision: .any
                            )
                        ),
                    ]
                )
            )
        }
        let recordAfterReplay = try await store.fetch(namespace: namespace, key: key)
        let healthAfterReplay = await store.health(namespace: namespace)
        XCTAssertEqual(recordAfterReplay?.revision, 1)
        XCTAssertEqual(healthAfterReplay.storeRevision, 1)
    }

    func testMultiRecordTransactionRollsBackEveryMutationOnConflict() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let untouchedKey = recordKey(collection: "state", record: "existing")
        let newKey = recordKey(collection: "state", record: "new-record")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        _ = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: untouchedKey,
                            schemaVersion: 1,
                            payload: Data("unchanged".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )

        await assertStoreError(
            .revisionConflict(
                collectionID: untouchedKey.collectionID,
                recordID: untouchedKey.recordID,
                expected: 0,
                actual: 1
            )
        ) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: newKey,
                                schemaVersion: 1,
                                payload: Data("must-roll-back".utf8),
                                expectedRevision: .absent
                            )
                        ),
                        .upsert(
                            ModuleStateUpsert(
                                key: untouchedKey,
                                schemaVersion: 1,
                                payload: Data("must-not-commit".utf8),
                                expectedRevision: .exact(0)
                            )
                        ),
                    ]
                )
            )
        }

        let rolledBackRecord = try await store.fetch(namespace: namespace, key: newKey)
        let untouchedRecord = try await store.fetch(namespace: namespace, key: untouchedKey)
        XCTAssertNil(rolledBackRecord)
        XCTAssertEqual(untouchedRecord?.payload, Data("unchanged".utf8))
        let health = await store.health(namespace: namespace)
        XCTAssertEqual(health.storeRevision, 1)
        XCTAssertEqual(health.recordCount, 1)
    }

    func testPayloadAndTransactionByteBoundsFailBeforeMutation() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)

        await assertStoreError(
            .payloadTooLarge(maximumBytes: AppleSQLiteModuleStateStore.maximumPayloadByteCount)
        ) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: recordKey(collection: "state", record: "oversized"),
                                schemaVersion: 1,
                                payload: Data(
                                    repeating: 0xA5,
                                    count: AppleSQLiteModuleStateStore.maximumPayloadByteCount + 1
                                ),
                                expectedRevision: .absent
                            )
                        ),
                    ]
                )
            )
        }

        let oneMiB = Data(
            repeating: 0x5A,
            count: AppleSQLiteModuleStateStore.maximumPayloadByteCount
        )
        await assertStoreError(
            .payloadTooLarge(
                maximumBytes: AppleSQLiteModuleStateStore.maximumTransactionPayloadByteCount
            )
        ) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    mutations: (0 ..< 9).map { index in
                        .upsert(
                            ModuleStateUpsert(
                                key: recordKey(
                                    collection: "state",
                                    record: "payload-\(index)"
                                ),
                                schemaVersion: 1,
                                payload: oneMiB,
                                expectedRevision: .absent
                            )
                        )
                    }
                )
            )
        }
        let health = await store.health(namespace: namespace)
        XCTAssertEqual(health.recordCount, 0)
    }

    func testZeroSchemaVersionsAreRejectedBeforeNamespaceOrRecordMutation() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")

        await assertStoreError(.invalidRequest) {
            _ = try await store.prepareNamespace(namespace, schemaVersion: 0)
        }
        let missingHealth = await store.health(namespace: namespace)
        XCTAssertNil(missingHealth.namespaceSchemaVersion)

        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        await assertStoreError(.invalidRequest) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: recordKey(collection: "state", record: "zero-schema"),
                                schemaVersion: 0,
                                payload: Data("invalid".utf8),
                                expectedRevision: .absent
                            )
                        ),
                    ]
                )
            )
        }
        let health = await store.health(namespace: namespace)
        XCTAssertEqual(health.loadState, .absent)
        XCTAssertEqual(health.storeRevision, 0)
        XCTAssertEqual(health.recordCount, 0)
    }

    func testDiagnosticCodesUseBoundedLowercaseNonSensitiveSyntax() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)

        let invalidCodes = [
            "Uppercase",
            "contains_underscore",
            "double--separator",
            ".leading-dot",
            String(repeating: "a", count: 97),
        ]
        for diagnosticCode in invalidCodes {
            await assertStoreError(.invalidRequest) {
                _ = try await store.quarantine(
                    namespace: namespace,
                    diagnosticCode: diagnosticCode
                )
            }
        }
        let unchanged = await store.health(namespace: namespace)
        XCTAssertEqual(unchanged.loadState, .absent)
        XCTAssertNil(unchanged.diagnosticCode)

        let accepted = try await store.quarantine(
            namespace: namespace,
            diagnosticCode: "record.validation-failed"
        )
        XCTAssertEqual(accepted.loadState, .quarantined)
        XCTAssertEqual(accepted.diagnosticCode, "record.validation-failed")
    }

    func testProductionLocationUsesPrivateFilesAndRejectsIntermediateSymlink() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeModuleStateProduction-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        _ = try AppleSQLiteModuleStateStore(applicationSupportDirectory: base)
        let ownedDirectory = base
            .appendingPathComponent("RuneScribe", isDirectory: true)
            .appendingPathComponent("RuntimeModuleState", isDirectory: true)
        let storeURL = ownedDirectory.appendingPathComponent("module-state.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeURL.path))
        let directoryPermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: ownedDirectory.path)[.posixPermissions]
                as? NSNumber
        )
        let filePermissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: storeURL.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(directoryPermissions.intValue & 0o777, 0o700)
        XCTAssertEqual(filePermissions.intValue & 0o777, 0o600)

        let symlinkBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeModuleStateSymlink-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeModuleStateOutside-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: symlinkBase)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: symlinkBase, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkBase.appendingPathComponent("RuneScribe"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try AppleSQLiteModuleStateStore(applicationSupportDirectory: symlinkBase)
        ) { error in
            XCTAssertEqual(error as? ModuleStateStoreError, .unavailable)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("RuntimeModuleState").path
            )
        )
    }

    func testActiveSQLiteSidecarsUsePrivatePermissionsAndSupportedDataProtection() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let key = recordKey(collection: "state", record: "large-snapshot")

        _ = try await store.prepareNamespace(namespace, schemaVersion: 1)
        _ = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data(repeating: 0xA5, count: 512 * 1_024),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        _ = try await store.fetch(namespace: namespace, key: key)

        let sqliteFiles = [
            fixture.storeURL,
            URL(fileURLWithPath: fixture.storeURL.path + "-wal"),
            URL(fileURLWithPath: fixture.storeURL.path + "-shm"),
        ]
        for fileURL in sqliteFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fileURL.path),
                "Expected active SQLite file \(fileURL.lastPathComponent)"
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
            XCTAssertEqual(
                permissions.intValue & 0o777,
                0o600,
                fileURL.lastPathComponent
            )

            #if os(iOS)
            let protection = try XCTUnwrap(attributes[.protectionKey] as? FileProtectionType)
            XCTAssertEqual(
                protection,
                .completeUntilFirstUserAuthentication,
                fileURL.lastPathComponent
            )
            #endif
        }
    }

    func testNamespaceSchemaStatesIncludeAbsentLoadedMigratedAndUnreadable() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        let namespace = ModuleStateNamespace(moduleID: "module.progression")

        let missingHealth = await store.health(namespace: namespace)
        XCTAssertEqual(missingHealth.loadState, .absent)
        let absent = try await store.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(absent.loadState, .absent)
        XCTAssertEqual(absent.namespaceSchemaVersion, 1)

        let loaded = try await store.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(loaded.loadState, .absent)
        let migrated = try await store.prepareNamespace(namespace, schemaVersion: 2)
        XCTAssertEqual(migrated.loadState, .migrated)
        XCTAssertEqual(migrated.namespaceSchemaVersion, 2)

        _ = try await store.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: recordKey(collection: "migration", record: "version-2"),
                            schemaVersion: 2,
                            payload: Data("complete".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        let postMigration = await store.health(namespace: namespace)
        XCTAssertEqual(postMigration.loadState, .loaded)

        let downgrade = try await store.prepareNamespace(namespace, schemaVersion: 1)
        XCTAssertEqual(downgrade.loadState, .unreadable)
        XCTAssertEqual(downgrade.namespaceSchemaVersion, 2)
        XCTAssertEqual(downgrade.diagnosticCode, "module-state-schema-newer-than-runtime")
        await assertStoreError(.unreadable) {
            _ = try await store.transact(
                namespace: namespace,
                transaction: transaction(
                    mutations: [
                        .upsert(
                            ModuleStateUpsert(
                                key: recordKey(collection: "state", record: "blocked"),
                                schemaVersion: 1,
                                payload: Data(),
                                expectedRevision: .absent
                            )
                        ),
                    ]
                )
            )
        }

        let recovered = try await store.prepareNamespace(namespace, schemaVersion: 2)
        XCTAssertEqual(recovered.loadState, .loaded)
    }

    func testRecordQuarantineIsDurableAndLeavesValidRecordsWritable() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let invalidKey = recordKey(collection: "events", record: "event-a")
        let validKey = recordKey(collection: "events", record: "event-b")
        let rebuiltKey = recordKey(collection: "projection", record: "generation-2")
        var store: AppleSQLiteModuleStateStore? = try fixture.makeStore()
        _ = try await store?.prepareNamespace(namespace, schemaVersion: 1)
        _ = try await store?.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [invalidKey, validKey].map { key in
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data(key.recordID.rawValue.utf8),
                            expectedRevision: .absent
                        )
                    )
                }
            )
        )

        await assertStoreError(
            .revisionConflict(
                collectionID: invalidKey.collectionID,
                recordID: invalidKey.recordID,
                expected: 2,
                actual: 1
            )
        ) {
            _ = try await store?.quarantineRecord(
                namespace: namespace,
                key: invalidKey,
                expectedRevision: 2,
                diagnosticCode: "progression-record-invalid"
            )
        }
        let quarantined = try await store?.quarantineRecord(
            namespace: namespace,
            key: invalidKey,
            expectedRevision: 1,
            diagnosticCode: "progression-record-invalid"
        )
        XCTAssertEqual(quarantined?.loadState, .quarantined)
        XCTAssertEqual(quarantined?.accessDisposition, .readWrite)
        XCTAssertEqual(quarantined?.recordCount, 1)
        XCTAssertEqual(quarantined?.quarantinedRecordCount, 1)
        store = nil

        let reopened = try fixture.makeStore()
        let health = await reopened.health(namespace: namespace)
        XCTAssertEqual(health.loadState, .quarantined)
        XCTAssertEqual(health.accessDisposition, .readWrite)
        XCTAssertEqual(health.recordCount, 1)
        XCTAssertEqual(health.quarantinedRecordCount, 1)
        await assertStoreError(.quarantined) {
            _ = try await reopened.fetch(namespace: namespace, key: invalidKey)
        }
        let valid = try await reopened.scan(
            namespace: namespace,
            request: try ModuleStateScanRequest(
                collectionID: validKey.collectionID,
                limit: 10
            )
        )
        XCTAssertEqual(valid.records.map(\.key), [validKey])
        _ = try await reopened.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: rebuiltKey,
                            schemaVersion: 1,
                            payload: Data("rebuilt".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        let postRebuild = await reopened.health(namespace: namespace)
        XCTAssertEqual(postRebuild.accessDisposition, .readWrite)
        XCTAssertEqual(postRebuild.recordCount, 2)
        XCTAssertEqual(postRebuild.quarantinedRecordCount, 1)
    }

    func testQuarantineIsDurableAndBlocksNamespaceAccessWithoutDeletingRecords() async throws {
        let fixture = try StoreFixture(testName: #function)
        defer { fixture.remove() }
        let namespace = ModuleStateNamespace(moduleID: "module.progression")
        let key = recordKey(collection: "state", record: "snapshot")
        var store: AppleSQLiteModuleStateStore? = try fixture.makeStore()
        _ = try await store?.prepareNamespace(namespace, schemaVersion: 1)
        _ = try await store?.transact(
            namespace: namespace,
            transaction: transaction(
                mutations: [
                    .upsert(
                        ModuleStateUpsert(
                            key: key,
                            schemaVersion: 1,
                            payload: Data("preserve".utf8),
                            expectedRevision: .absent
                        )
                    ),
                ]
            )
        )
        let quarantined = try await store?.quarantine(
            namespace: namespace,
            diagnosticCode: "record-validation-failed"
        )
        XCTAssertEqual(quarantined?.loadState, .quarantined)
        XCTAssertEqual(quarantined?.accessDisposition, .blocked)
        XCTAssertEqual(quarantined?.diagnosticCode, "record-validation-failed")
        XCTAssertEqual(quarantined?.recordCount, 1)
        store = nil

        let reopened = try fixture.makeStore()
        let health = await reopened.health(namespace: namespace)
        XCTAssertEqual(health.loadState, .quarantined)
        XCTAssertEqual(health.accessDisposition, .blocked)
        XCTAssertEqual(health.recordCount, 1)
        await assertStoreError(.quarantined) {
            _ = try await reopened.fetch(namespace: namespace, key: key)
        }
        await assertStoreError(.quarantined) {
            _ = try await reopened.scan(
                namespace: namespace,
                request: try ModuleStateScanRequest(
                    collectionID: key.collectionID,
                    limit: 10
                )
            )
        }
    }
}

private extension AppleSQLiteModuleStateStoreTests {
    struct StoreFixture {
        let directory: URL
        let storeURL: URL

        init(testName: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "RuneScribeModuleStateTests-\(testName)-\(UUID().uuidString)",
                    isDirectory: true
                )
                .standardizedFileURL
            storeURL = directory.appendingPathComponent("module-state.sqlite")
        }

        func makeStore() throws -> AppleSQLiteModuleStateStore {
            try AppleSQLiteModuleStateStore(storeURL: storeURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func collectionID(_ value: String) -> ModuleStateCollectionID {
        ModuleStateCollectionID(rawValue: value)!
    }

    func recordID(_ value: String) -> ModuleStateRecordID {
        ModuleStateRecordID(rawValue: value)!
    }

    func recordKey(collection: String, record: String) -> ModuleStateRecordKey {
        ModuleStateRecordKey(
            collectionID: collectionID(collection),
            recordID: recordID(record)
        )
    }

    func transaction(
        id: UUID = UUID(),
        mutations: [ModuleStateMutation]
    ) -> ModuleStateTransaction {
        try! ModuleStateTransaction(transactionID: id, mutations: mutations)
    }

    func assertStoreError<T: Sendable>(
        _ expected: ModuleStateStoreError,
        operation: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected module-state store error \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ModuleStateStoreError, expected, file: file, line: line)
        }
    }
}
