import CryptoKit
import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@testable import RuneScribeCoreModule
@testable import RuneScribeRuntimeCore
import XCTest

extension CipherRepository {
    init(
        secureValueStore: any SecureValueStore,
        clock: any ClockProviding,
        uuid: any UUIDProviding
    ) {
        self.init(
            runtimeIO: RuntimeIOClient(
                secureValueData: {
                    try await secureValueStore.data(service: $0, account: $1)
                },
                setSecureValue: {
                    try await secureValueStore.set($0, service: $1, account: $2)
                },
                deleteSecureValue: {
                    try await secureValueStore.delete(service: $0, account: $1)
                },
                now: { clock.now() },
                nextUUID: { uuid.nextUUID() }
            )
        )
    }
}

final class CipherPersistenceApplicationTests: XCTestCase {
    private static let legacyCipherID = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )
    private static let legacyContactID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )

    func testLoadsFrozenLegacyEncryptedLibraryWithoutRewriting() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(Self.legacyContactID)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        await store.clearOperations()

        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )

        let library = try await repository.snapshot()

        XCTAssertEqual(library.version, 1)
        XCTAssertEqual(library.activeID, cipherID)
        XCTAssertEqual(library.ciphers.count, 1)
        let cipher = try XCTUnwrap(library.ciphers.first)
        XCTAssertEqual(cipher.id, cipherID)
        XCTAssertEqual(cipher.label, "Legacy Cipher")
        XCTAssertEqual(cipher.origin, .generated)
        XCTAssertEqual(cipher.createdAt, Date(timeIntervalSince1970: 1_704_164_645))
        XCTAssertEqual(cipher.publicID, Data(1...8))
        let expectedCipherKey = try XCTUnwrap(
            Data(base64Encoded: "ICEiYyQlJicoKSorLC0uLzAxMjM0NTY3ODk6Ozw9Pj8=")
        )
        XCTAssertEqual(cipher.keyMaterial, expectedCipherKey)
        XCTAssertEqual(cipher.decorativeMapping, Array((0..<32).reversed()))
        XCTAssertEqual(cipher.fontRef, .bundled)
        XCTAssertEqual(cipher.contactID, contactID)
        XCTAssertTrue(cipher.hasCompletedKeyDelivery)

        let operations = await store.recordedOperations()
        XCTAssertEqual(
            operations,
            [
                .read(.init(
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.symmetricKeyAccount
                )),
                .read(.init(
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.cipherLibraryAccount
                )),
            ]
        )
    }

    func testFirstRunUsesStableAccountsAndWritesAESGCMISO8601Library() async throws {
        let generatedID = try XCTUnwrap(
            UUID(uuidString: "99999999-8888-7777-6666-555555555555")
        )
        let createdAt = Date(timeIntervalSince1970: 1_749_283_750)
        let store = InMemorySecureValueStore()
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(createdAt),
            uuid: FixedUUIDProvider(generatedID)
        )

        let library = try await repository.snapshot()

        XCTAssertEqual(library.ciphers.count, 1)
        XCTAssertEqual(library.activeID, generatedID)
        XCTAssertEqual(library.ciphers.first?.id, generatedID)
        XCTAssertEqual(library.ciphers.first?.createdAt, createdAt)
        XCTAssertEqual(library.ciphers.first?.label, "My Cipher")
        XCTAssertEqual(library.ciphers.first?.keyMaterial.count, 32)
        XCTAssertEqual(library.ciphers.first?.publicID.count, 8)
        XCTAssertEqual(Set(library.ciphers.first?.decorativeMapping ?? []), Set(0..<32))

        let storedKey = await store.value(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        let key = try XCTUnwrap(storedKey)
        let storedLibrary = await store.value(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
        let encrypted = try XCTUnwrap(storedLibrary)
        XCTAssertEqual(key.count, 32)

        let object = try Self.frozenLegacyJSON(encrypted: encrypted, key: key)
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertEqual(object["activeID"] as? String, generatedID.uuidString)
        let ciphers = try XCTUnwrap(object["ciphers"] as? [[String: Any]])
        XCTAssertEqual(ciphers.count, 1)
        XCTAssertEqual(ciphers.first?["id"] as? String, generatedID.uuidString)
        XCTAssertEqual(ciphers.first?["createdAt"] as? String, "2025-06-07T08:09:10Z")
        XCTAssertEqual(ciphers.first?["formatVersion"] as? Int, Cipher.currentVersion)

        let operations = await store.recordedOperations()
        XCTAssertEqual(
            operations.filter(\.isWrite).map(\.address),
            [
                .init(
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.symmetricKeyAccount
                ),
                .init(
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.cipherLibraryAccount
                ),
            ]
        )
        let itemCount = await store.itemCount()
        XCTAssertEqual(itemCount, 2)
    }

    func testUpdateReusesKeyAndPersistsOneLibraryItem() async throws {
        let newID = try XCTUnwrap(
            UUID(uuidString: "22222222-3333-4444-5555-666666666666")
        )
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let storedOriginalKey = await store.value(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        let originalKey = try XCTUnwrap(storedOriginalKey)
        await store.clearOperations()
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(newID)
        )

        let mutation = try await repository.createCipher(
            label: "   12345678901234567890123456789012345678901234567890   "
        )

        XCTAssertEqual(mutation.value.id, newID)
        XCTAssertEqual(mutation.value.label, "1234567890123456789012345678901234567890")
        XCTAssertEqual(mutation.library.activeID, newID)
        XCTAssertEqual(mutation.library.ciphers.count, 2)
        let keyAfterUpdate = await store.value(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        XCTAssertEqual(keyAfterUpdate, originalKey)
        let itemCount = await store.itemCount()
        XCTAssertEqual(itemCount, 2)

        let storedLibrary = await store.value(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
        let encrypted = try XCTUnwrap(storedLibrary)
        let object = try Self.frozenLegacyJSON(encrypted: encrypted, key: originalKey)
        XCTAssertEqual(object["activeID"] as? String, newID.uuidString)
        XCTAssertEqual((object["ciphers"] as? [[String: Any]])?.count, 2)

        let writes = await store.recordedOperations().filter(\.isWrite)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(
            writes.first?.address,
            .init(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.cipherLibraryAccount
            )
        )
    }

    func testDeletingLastCipherRegeneratesAndActivatesMyCipher() async throws {
        let legacyID = try XCTUnwrap(Self.legacyCipherID)
        let replacementID = try XCTUnwrap(
            UUID(uuidString: "77777777-6666-5555-4444-333333333333")
        )
        let replacementDate = Date(timeIntervalSince1970: 1_749_283_750)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(replacementDate),
            uuid: FixedUUIDProvider(replacementID)
        )

        let mutation = try await repository.deleteCipher(id: legacyID)

        XCTAssertTrue(mutation.value)
        XCTAssertEqual(mutation.library.ciphers.count, 1)
        XCTAssertEqual(mutation.library.activeID, replacementID)
        XCTAssertEqual(mutation.library.ciphers.first?.id, replacementID)
        XCTAssertEqual(mutation.library.ciphers.first?.label, "My Cipher")
        XCTAssertEqual(mutation.library.ciphers.first?.createdAt, replacementDate)
    }

    func testEmbeddedMessageImportDeduplicatesAndDoesNotActivate() async throws {
        let legacyID = try XCTUnwrap(Self.legacyCipherID)
        let importedID = try XCTUnwrap(
            UUID(uuidString: "33333333-4444-5555-6666-777777777777")
        )
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(importedID)
        )
        _ = try await repository.snapshot()
        await store.clearOperations()

        let duplicatePayload = Self.payload(publicID: Data(1...8), keyStart: 64)
        let duplicate = try await repository.ingestMessageCipher(
            duplicatePayload,
            label: "Duplicate"
        )
        guard case .existing(let existing, let unchanged) = duplicate else {
            return XCTFail("Expected the existing cipher")
        }
        XCTAssertEqual(existing.id, legacyID)
        XCTAssertEqual(unchanged.ciphers.count, 1)
        let duplicateWrites = await store.recordedOperations().filter(\.isWrite)
        XCTAssertEqual(duplicateWrites.count, 0)

        let newPayload = Self.payload(publicID: Data(9...16), keyStart: 96)
        let imported = try await repository.ingestMessageCipher(
            newPayload,
            label: "Received"
        )
        guard case .persisted(let cipher, let updated) = imported else {
            return XCTFail("Expected a persisted cipher")
        }
        XCTAssertEqual(cipher.id, importedID)
        XCTAssertEqual(cipher.origin, .imported)
        XCTAssertEqual(updated.ciphers.map(\.id), [legacyID, importedID])
        XCTAssertEqual(updated.activeID, legacyID)
    }

    func testCipherInvitationFingerprintPreventsDuplicateAfterRelaunch() async throws {
        let importedID = try XCTUnwrap(
            UUID(uuidString: "22222222-3333-4444-5555-666666666666")
        )
        let unusedReplayID = try XCTUnwrap(
            UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")
        )
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let payload = Self.payload(publicID: Data(9...16), keyStart: 96)
        let firstRepository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(importedID)
        )

        let first = try await firstRepository.importCipher(
            payload,
            label: "First invitation"
        )
        XCTAssertEqual(first.value.id, importedID)
        XCTAssertEqual(first.library.ciphers.count, 2)

        let relaunched = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_751)),
            uuid: FixedUUIDProvider(unusedReplayID)
        )
        _ = try await relaunched.snapshot()
        await store.clearOperations()

        let replay = try await relaunched.importCipher(
            payload,
            label: "Replay invitation"
        )

        XCTAssertEqual(replay.value.id, importedID)
        XCTAssertEqual(replay.value.label, "First invitation")
        XCTAssertEqual(replay.library.ciphers.count, 2)
        XCTAssertFalse(replay.library.ciphers.contains { $0.id == unusedReplayID })
        let writes = await store.recordedOperations().filter(\.isWrite)
        XCTAssertTrue(writes.isEmpty)
    }

    func testFailedWriteDoesNotClaimOrCacheMutation() async throws {
        let newID = try XCTUnwrap(
            UUID(uuidString: "44444444-5555-6666-7777-888888888888")
        )
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(newID)
        )
        _ = try await repository.snapshot()
        await store.failWrites(to: RuneScribeKeychain.cipherLibraryAccount)

        do {
            _ = try await repository.createCipher(label: "Must Not Commit")
            XCTFail("Expected the secure write to fail")
        } catch let error as CipherRepositoryError {
            XCTAssertEqual(error, .secureStorageUnavailable)
        }

        let library = try await repository.snapshot()
        XCTAssertEqual(library.ciphers.count, 1)
        XCTAssertEqual(library.activeID, Self.legacyCipherID)
        XCTAssertNil(library.ciphers.first(where: { $0.id == newID }))
    }

    func testConcurrentMutationsPreserveBothUpdates() async throws {
        let legacyID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(
            UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")
        )
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        _ = try await repository.snapshot()

        async let renamed = repository.renameCipher(id: legacyID, label: "Serialized")
        async let assigned = repository.assignContact(
            cipherID: legacyID,
            contactID: contactID
        )
        _ = try await (renamed, assigned)

        let library = try await repository.snapshot()
        let cipher = try XCTUnwrap(library.ciphers.first(where: { $0.id == legacyID }))
        XCTAssertEqual(cipher.label, "Serialized")
        XCTAssertEqual(cipher.contactID, contactID)
    }

    func testConcurrentFailedInitializationCanRetryWithoutPoisoningNewLoad() async throws {
        let generatedID = try XCTUnwrap(
            UUID(uuidString: "55555555-6666-7777-8888-999999999999")
        )
        let store = InMemorySecureValueStore()
        await store.failNextReads(
            from: RuneScribeKeychain.symmetricKeyAccount,
            count: 1
        )
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(generatedID)
        )

        let first = Task { try await repository.snapshot() }
        let second = Task { try await repository.snapshot() }
        var failures: [CipherRepositoryError] = []
        var successes: [CipherLibrary] = []
        for task in [first, second] {
            do {
                successes.append(try await task.value)
            } catch let error as CipherRepositoryError {
                failures.append(error)
            } catch {
                XCTFail("Expected a typed repository failure, received \(error)")
            }
        }
        XCTAssertFalse(failures.isEmpty)
        XCTAssertTrue(failures.allSatisfy { $0 == .secureStorageUnavailable })
        for success in successes {
            XCTAssertEqual(success.ciphers.map(\.id), [generatedID])
            XCTAssertEqual(success.activeID, generatedID)
        }

        let recovered = try await repository.snapshot()
        XCTAssertEqual(recovered.ciphers.map(\.id), [generatedID])
        XCTAssertEqual(recovered.activeID, generatedID)
    }

    func testApplicationStreamProjectsOnlyKeyFreeCipherState() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(Self.legacyContactID)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let service = RuneScribeCoreApplicationService(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        var iterator = service.stateStream().makeAsyncIterator()

        let loadingValue = await iterator.next()
        let loading = try XCTUnwrap(loadingValue)
        XCTAssertTrue(loading.cipherLibrary.isLoading)
        XCTAssertTrue(loading.cipherLibrary.ciphers.isEmpty)

        let loadedValue = await iterator.next()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertFalse(loaded.cipherLibrary.isLoading)
        XCTAssertNil(loaded.lastFailure)
        XCTAssertEqual(loaded.cipherLibrary.activeCipherID, CipherID(rawValue: cipherID))
        let summary = try XCTUnwrap(loaded.cipherLibrary.ciphers.first)
        XCTAssertEqual(summary.id, CipherID(rawValue: cipherID))
        XCTAssertEqual(summary.name, "Legacy Cipher")
        XCTAssertEqual(summary.assignedContactID, ContactID(rawValue: contactID))
        XCTAssertTrue(summary.hasBeenDelivered)
        XCTAssertEqual(summary.publicIdentifier, "01020304")
        XCTAssertEqual(summary.fontID, .bundledRuneFont)

        let fieldNames = Set(Mirror(reflecting: summary).children.compactMap(\.label))
        XCTAssertFalse(fieldNames.contains("keyMaterial"))
        XCTAssertFalse(fieldNames.contains("symmetricKey"))
        XCTAssertFalse(fieldNames.contains("decorativeMapping"))
        XCTAssertFalse(fieldNames.contains("path"))

        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "migration round trip",
                cipherID: CipherID(rawValue: cipherID)
            )
        )
        let decoded = try await service.decode(DecodeMessageCommand(runes: encoded.runes))
        XCTAssertEqual(decoded.plaintext, "migration round trip")
        XCTAssertEqual(decoded.cipherID, CipherID(rawValue: cipherID))
        XCTAssertEqual(decoded.cipherName, "Legacy Cipher")
    }

    func testApplicationMapsStorageFailureWithoutLeakingDetails() async throws {
        let store = InMemorySecureValueStore()
        await store.failReads(from: RuneScribeKeychain.symmetricKeyAccount)
        let service = RuneScribeCoreApplicationService(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        var iterator = service.stateStream().makeAsyncIterator()
        let loadingValue = await iterator.next()
        _ = try XCTUnwrap(loadingValue)

        let failedValue = await iterator.next()
        let failed = try XCTUnwrap(failedValue)
        XCTAssertEqual(failed.lastFailure?.code, .secureStorageUnavailable)
        XCTAssertNil(failed.lastFailure?.retryAfter)
        XCTAssertFalse(failed.cipherLibrary.isLoading)
        XCTAssertTrue(failed.cipherLibrary.ciphers.isEmpty)

        do {
            _ = try await service.createCipher(CreateCipherCommand(name: "Unavailable"))
            XCTFail("Expected a typed product failure")
        } catch let error as RuneScribeProductError {
            XCTAssertEqual(
                error,
                .failure(RuneScribeFailureDTO(code: .secureStorageUnavailable))
            )
        }
    }

    func testUnavailableCallBeforeSubscriptionDoesNotSuppressInitialization() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let service = RuneScribeCoreApplicationService(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )

        do {
            _ = try await service.createContact(
                CreateContactCommand(displayName: "Not Yet Available")
            )
            XCTFail("Expected P4B contact creation to be unavailable")
        } catch let error as RuneScribeProductError {
            XCTAssertEqual(
                error,
                .failure(RuneScribeFailureDTO(code: .temporarilyUnavailable))
            )
        }

        var iterator = service.stateStream().makeAsyncIterator()
        let loadingValue = await iterator.next()
        let loading = try XCTUnwrap(loadingValue)
        XCTAssertTrue(loading.cipherLibrary.isLoading)

        let loadedValue = await iterator.next()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertFalse(loaded.cipherLibrary.isLoading)
        XCTAssertNil(loaded.lastFailure)
        XCTAssertEqual(loaded.cipherLibrary.ciphers.map(\.id), [CipherID(rawValue: cipherID)])
    }

    func testConcurrentServiceMutationsCannotRegressProjectedState() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(
            UUID(uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-AAAAAAAAAAAA")
        )
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let service = RuneScribeCoreApplicationService(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )

        async let renamed = service.renameCipher(
            RenameCipherCommand(
                cipherID: CipherID(rawValue: cipherID),
                name: "Serialized Service"
            )
        )
        async let assigned: Void = service.assignContact(
            AssignContactCommand(
                cipherID: CipherID(rawValue: cipherID),
                contactID: ContactID(rawValue: contactID)
            )
        )
        _ = try await (renamed, assigned)

        var iterator = service.stateStream().makeAsyncIterator()
        let snapshotValue = await iterator.next()
        let snapshot = try XCTUnwrap(snapshotValue)
        let summary = try XCTUnwrap(snapshot.cipherLibrary.ciphers.first)
        XCTAssertEqual(summary.name, "Serialized Service")
        XCTAssertEqual(summary.assignedContactID, ContactID(rawValue: contactID))
    }

    func testEmptyNormalizedFilePayloadEmitsCorruptionFailureBeforeReturning() async throws {
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let service = RuneScribeCoreApplicationService(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        var iterator = service.stateStream().makeAsyncIterator()
        let loadingValue = await iterator.next()
        _ = try XCTUnwrap(loadingValue)
        let loadedValue = await iterator.next()
        _ = try XCTUnwrap(loadedValue)

        let input = InboundFileDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: UUID()),
                receivedAt: Date(timeIntervalSince1970: 1_749_283_750),
                source: .fileImporter,
                isColdStart: false
            ),
            data: Data()
        )
        do {
            _ = try await service.importFile(input)
            XCTFail("Expected the empty normalized payload to fail")
        } catch let error as RuneScribeProductError {
            XCTAssertEqual(
                error,
                .failure(RuneScribeFailureDTO(code: .corruptedContent))
            )
        }

        var failedSnapshot: RuneScribeApplicationSnapshot?
        for _ in 0..<2 {
            let candidate = await iterator.next()
            if candidate?.importState.phase == .failed {
                failedSnapshot = candidate
                break
            }
        }
        let failed = try XCTUnwrap(failedSnapshot)
        XCTAssertEqual(failed.importState.phase, .failed)
        XCTAssertEqual(failed.importState.lastFailure?.code, .corruptedContent)
        XCTAssertEqual(failed.lastFailure?.code, .corruptedContent)
    }

    func testProgressionMigrationPersistsOnceAndReturnsPrivacySafeSnapshot() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(Self.legacyContactID)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        let relationship = CoreProgressionRelationshipIdentity(
            cipherID: cipherID,
            contactID: contactID
        )
        let seeds = CoreProgressionMigrationSeedSet(
            cipherSeeds: [cipherID: Data(repeating: 0x11, count: 32)],
            relationshipSeeds: [relationship: Data(repeating: 0x22, count: 32)]
        )

        let utilitySnapshot = try await repository.snapshot()
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.migrateProgressionEvidence(using: .init(
                cipherSeeds: [:],
                relationshipSeeds: [:]
            ))
        }
        let utilityAfterFailedMigration = try await repository.snapshot()
        XCTAssertEqual(utilityAfterFailedMigration, utilitySnapshot)

        let firstMigration = try await repository.migrateProgressionEvidence(
            using: seeds
        )
        let repeatedMigration = try await repository.migrateProgressionEvidence(
            using: seeds
        )
        XCTAssertTrue(firstMigration.value)
        XCTAssertFalse(repeatedMigration.value)
        let token = try XCTUnwrap(CipherToken(rawValue: String(repeating: "a", count: 64)))
        let migration = try await repository.progressionMigrationSnapshot(
            cipherTokensByID: [cipherID: token]
        )
        XCTAssertEqual(
            migration.ciphers,
            [CoreProgressionMigrationCipher(cipherToken: token, origin: .generated)]
        )

        let reloaded = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_751)),
            uuid: FixedUUIDProvider(UUID())
        )
        let library = try await reloaded.snapshot()
        XCTAssertEqual(library.version, CipherLibrary.currentVersion)
        let evidence = try XCTUnwrap(library.progressionLedger)
        XCTAssertEqual(evidence.cipherSeeds.first?.seed, Data(repeating: 0x11, count: 32))
        let relation = try XCTUnwrap(evidence.relationships.first)
        XCTAssertEqual(relation.keyDeliveryState, .migratedUnverified)
        XCTAssertFalse(relation.firstDeliveryEventCommitted)
    }

    func testUnlinkRelinkReusesPairSeedWithoutRepeatingFirstDelivery() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let firstContactID = try XCTUnwrap(Self.legacyContactID)
        let secondContactID = UUID(
            uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-000000000001"
        )!
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        let firstIdentity = CoreProgressionRelationshipIdentity(
            cipherID: cipherID,
            contactID: firstContactID
        )
        _ = try await repository.migrateProgressionEvidence(using: .init(
            cipherSeeds: [cipherID: Data(repeating: 1, count: 32)],
            relationshipSeeds: [firstIdentity: Data(repeating: 2, count: 32)]
        ))

        let first = try await repository.recordRelationshipProgressionActivity(
            cipherID: cipherID,
            contactID: firstContactID,
            completesKeyDelivery: true,
            commitsFirstDeliveryEvent: true,
            activity: .init(eligibleOutbound: true),
            pendingBatches: [try Self.firstDeliveryPending(
                context: Self.progressionContext(byte: 30),
                byte: 30
            )]
        )
        XCTAssertTrue(first.value.keyDeliveryTransitioned)
        XCTAssertTrue(first.value.firstDeliveryTransitioned)
        _ = try await repository.unlinkContacts([firstContactID])
        _ = try await repository.assignContact(
            cipherID: cipherID,
            contactID: firstContactID,
            relationshipSeed: nil,
            pendingBatches: []
        )
        let relinked = try await repository.snapshot()
        XCTAssertEqual(relinked.ciphers.first?.keyDeliveryState, .pending)
        let samePair = try await repository.relationshipProgressionEvidence(
            cipherID: cipherID,
            contactID: firstContactID
        )
        XCTAssertEqual(samePair?.seed, Data(repeating: 2, count: 32))
        let repeated = try await repository.recordRelationshipProgressionActivity(
            cipherID: cipherID,
            contactID: firstContactID,
            completesKeyDelivery: true,
            commitsFirstDeliveryEvent: false,
            activity: .init(eligibleOutbound: true),
            pendingBatches: []
        )
        XCTAssertTrue(repeated.value.keyDeliveryTransitioned)
        XCTAssertFalse(repeated.value.firstDeliveryTransitioned)

        _ = try await repository.unlinkContacts([firstContactID])
        _ = try await repository.assignContact(
            cipherID: cipherID,
            contactID: secondContactID,
            relationshipSeed: Data(repeating: 3, count: 32),
            pendingBatches: []
        )
        let different = try await repository.recordRelationshipProgressionActivity(
            cipherID: cipherID,
            contactID: secondContactID,
            completesKeyDelivery: true,
            commitsFirstDeliveryEvent: true,
            activity: .init(eligibleOutbound: true),
            pendingBatches: [try Self.firstDeliveryPending(
                context: Self.progressionContext(byte: 31),
                byte: 31
            )]
        )
        XCTAssertTrue(different.value.keyDeliveryTransitioned)
        XCTAssertTrue(different.value.firstDeliveryTransitioned)
        let differentPair = try await repository.relationshipProgressionEvidence(
            cipherID: cipherID,
            contactID: secondContactID
        )
        XCTAssertEqual(differentPair?.seed, Data(repeating: 3, count: 32))
    }

    func testAmbiguousAfterCommitProgressionWriteUsesAuthenticatedReadBack() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(Self.legacyContactID)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        _ = try await repository.snapshot()
        await store.failNextWritesAfterCommit(
            to: RuneScribeKeychain.cipherLibraryAccount
        )

        let mutation = try await repository.migrateProgressionEvidence(using: .init(
            cipherSeeds: [cipherID: Data(repeating: 7, count: 32)],
            relationshipSeeds: [
                .init(cipherID: cipherID, contactID: contactID):
                    Data(repeating: 8, count: 32),
            ]
        ))
        XCTAssertTrue(mutation.value)

        let reloaded = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_751)),
            uuid: FixedUUIDProvider(UUID())
        )
        let reloadedLibrary = try await reloaded.snapshot()
        XCTAssertEqual(reloadedLibrary, mutation.library)
    }

    func testProgressionAwareCreateCommitsDomainAndFactAtomicallyAndRejectsCollision() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(Self.legacyContactID)
        let newCipherID = UUID(
            uuidString: "CCCCCCCC-DDDD-EEEE-FFFF-000000000001"
        )!
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(newCipherID)
        )
        _ = try await repository.migrateProgressionEvidence(using: .init(
            cipherSeeds: [cipherID: Data(repeating: 1, count: 32)],
            relationshipSeeds: [
                .init(cipherID: cipherID, contactID: contactID):
                    Data(repeating: 2, count: 32),
            ]
        ))
        let context = try Self.progressionContext(byte: 1)
        let pending = try Self.progressionPending(context: context, byte: 1)
        await store.failWrites(to: RuneScribeKeychain.cipherLibraryAccount)

        do {
            _ = try await repository.createCipher(
                label: "Atomic",
                progressionSeed: Data(repeating: 3, count: 32),
                pendingBatches: [pending]
            )
            XCTFail("Expected the before-write fault")
        } catch let error as CipherRepositoryError {
            XCTAssertEqual(error, .secureStorageUnavailable)
        }
        let unchanged = try await repository.snapshot()
        XCTAssertNil(unchanged.ciphers.first(where: { $0.id == newCipherID }))
        XCTAssertTrue(try XCTUnwrap(unchanged.progressionLedger).pendingBatches.isEmpty)

        await store.allowWrites(to: RuneScribeKeychain.cipherLibraryAccount)
        await store.failNextWritesAfterCommit(
            to: RuneScribeKeychain.cipherLibraryAccount
        )
        let committed = try await repository.createCipher(
            label: "Atomic",
            progressionSeed: Data(repeating: 3, count: 32),
            pendingBatches: [pending]
        )
        XCTAssertEqual(committed.value.id, newCipherID)
        XCTAssertEqual(committed.library.progressionLedger?.pendingBatches, [pending])
        XCTAssertEqual(
            committed.library.progressionLedger?.cipherSeeds.first(where: {
                $0.cipherID == newCipherID
            })?.seed,
            Data(repeating: 3, count: 32)
        )

        let conflicting = try CorePendingProgressionBatch(
            context: context,
            commandDigest: CoreProgressionDigest.canonical("conflicting"),
            batch: pending.batch
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.appendPendingProgressionBatches([conflicting])
        }
        let retainedPending = try await repository.pendingProgressionBatches()
        XCTAssertEqual(retainedPending, [pending])
    }

    func testReceiptClearAndTerminalEvidenceSurviveRelaunchUntilExplicitRetirement() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let contactID = try XCTUnwrap(Self.legacyContactID)
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(UUID())
        )
        _ = try await repository.migrateProgressionEvidence(using: .init(
            cipherSeeds: [cipherID: Data(repeating: 1, count: 32)],
            relationshipSeeds: [
                .init(cipherID: cipherID, contactID: contactID):
                    Data(repeating: 2, count: 32),
            ]
        ))
        let context = try Self.progressionContext(byte: 2)
        let pending = try Self.progressionPending(context: context, byte: 2)
        _ = try await repository.appendPendingProgressionBatches([pending])
        let receipt = try Self.progressionReceipt(
            context: context,
            batch: pending.batch,
            byte: 2
        )
        _ = try await repository.recordProgressionBatchReceipt(
            context: context,
            receipt: receipt
        )

        let afterReceipt = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_751)),
            uuid: FixedUUIDProvider(UUID())
        )
        let remainingPending = try await afterReceipt.pendingProgressionBatches()
        XCTAssertTrue(remainingPending.isEmpty)
        let acknowledged = try await afterReceipt.acknowledgedProgressionBatches()
        XCTAssertEqual(acknowledged.first?.batch, pending.batch)
        _ = try await afterReceipt.clearAcknowledgedProgressionBatch(
            context: context,
            receipt: receipt
        )

        let handle = EncodedMessageHandle(rawValue: UUID(
            uuidString: "DDDDDDDD-EEEE-FFFF-0000-000000000001"
        )!)
        let encodedRecord = try CoreEncodedMessageProgressionRecord(
            handle: handle,
            cipherID: cipherID,
            originatingContext: context,
            encodedMessageDigest: CoreProgressionDigest.canonical("encoded"),
            messageToken: MessageToken(rawValue: String(repeating: "b", count: 64))!,
            codexIDs: [CodexID(rawValue: "codex.norse")!],
            artifactIDs: []
        )
        _ = try await afterReceipt.commitEncodedMessageProgressionEvidence(
            encodedRecord,
            pendingBatches: []
        )
        let artifactID = ShareArtifactID(rawValue: UUID(
            uuidString: "EEEEEEEE-FFFF-0000-0000-000000000001"
        )!)
        let terminal = try await afterReceipt.commitShareTerminalProgression(
            artifactID: artifactID,
            context: context,
            commandDigest: CoreProgressionDigest.canonical("terminal-command"),
            resultDigest: CoreProgressionDigest.canonical("terminal-result"),
            encodedMessageHandle: handle,
            cipherID: nil,
            contactID: nil,
            completesKeyDelivery: false,
            commitsFirstDeliveryEvent: false,
            activity: .init(),
            pendingBatches: []
        )
        XCTAssertTrue(terminal.value.inserted)
        let retiredEncoded = try await afterReceipt.encodedMessageProgressionEvidence(
            handle: handle
        )
        XCTAssertNil(retiredEncoded)

        let terminalReload = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_752)),
            uuid: FixedUUIDProvider(UUID())
        )
        let reloadedTerminal = try await terminalReload
            .shareTerminalProgressionEvidence(artifactID: artifactID)
        XCTAssertTrue(try XCTUnwrap(reloadedTerminal).cleanupPending)
        _ = try await terminalReload.markShareTerminalCleanupComplete(
            artifactID: artifactID
        )
        let retirement = try await terminalReload.retireShareTerminalEvidence(
            artifactIDs: [artifactID]
        )
        XCTAssertEqual(retirement.value, 1)
        let removedTerminal = try await terminalReload.shareTerminalProgressionEvidence(
            artifactID: artifactID
        )
        XCTAssertNil(removedTerminal)
    }

    func testProgressionContactReconciliationCommitsRepairSeedsAndFactsOnce() async throws {
        let cipherID = try XCTUnwrap(Self.legacyCipherID)
        let oldContactID = try XCTUnwrap(Self.legacyContactID)
        let newContactID = UUID(
            uuidString: "ABABABAB-CDCD-EFEF-0101-000000000001"
        )!
        let generatedID = UUID(
            uuidString: "ACACACAC-DEDE-F0F0-0202-000000000001"
        )!
        let store = InMemorySecureValueStore()
        try await Self.seedLegacyLibrary(in: store)
        let repository = CipherRepository(
            secureValueStore: store,
            clock: FixedClock(Date(timeIntervalSince1970: 1_749_283_750)),
            uuid: FixedUUIDProvider(generatedID)
        )
        _ = try await repository.migrateProgressionEvidence(using: .init(
            cipherSeeds: [cipherID: Data(repeating: 1, count: 32)],
            relationshipSeeds: [
                .init(cipherID: cipherID, contactID: oldContactID):
                    Data(repeating: 2, count: 32),
            ]
        ))
        let pending = try Self.progressionPending(
            context: Self.progressionContext(byte: 3),
            byte: 3
        )
        await store.clearOperations()

        let mutation = try await repository.reconcileContactAssociations(
            generatedSeeds: [CoreGeneratedContactProgressionSeed(
                contact: ImportedContactCipherSeed(
                    contactID: newContactID,
                    displayName: "New Contact"
                ),
                cipherSeed: Data(repeating: 3, count: 32),
                relationshipSeed: Data(repeating: 4, count: 32)
            )],
            validContactIDs: [newContactID],
            pendingBatches: [pending]
        )
        XCTAssertEqual(mutation.value.changes, 2)
        XCTAssertEqual(mutation.value.addedCiphers.map(\.id), [generatedID])
        XCTAssertEqual(mutation.library.activeID, cipherID)
        XCTAssertNil(mutation.library.ciphers.first(where: {
            $0.id == cipherID
        })?.contactID)
        XCTAssertEqual(mutation.library.ciphers.first(where: {
            $0.id == generatedID
        })?.contactID, newContactID)
        XCTAssertEqual(mutation.library.progressionLedger?.pendingBatches, [pending])
        XCTAssertNotNil(mutation.library.progressionLedger?.relationships.first(where: {
            $0.identity == .init(cipherID: cipherID, contactID: oldContactID)
        }))
        XCTAssertEqual(mutation.library.progressionLedger?.relationships.first(where: {
            $0.identity == .init(cipherID: generatedID, contactID: newContactID)
        })?.seed, Data(repeating: 4, count: 32))
        let writes = await store.recordedOperations().filter(\.isWrite)
        XCTAssertEqual(writes.count, 1)
    }

    // MARK: - Frozen migration fixture

    private static let legacyKeyBase64 =
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="

    /// Frozen output produced by the shipping AES-GCM combined representation
    /// using a fixed synthetic key, nonce, and ISO-8601 legacy JSON document.
    private static let legacyEncryptedLibraryBase64 =
        "oKGio6SlpqeoqaqrnToKSDe4a9AMR73iK1ijtwDEPGLhlXg35yxP4l2RVzDjR3bO" +
        "nhNiEG2uNvokSbDKdDZyfFbkN0t0az5rkUWwhYGJsE0ch4iBloeTOrXsgN+qasjd" +
        "5YLwCoYQTLiduCLm5uNCxSGUrfz7tWMi5PyITAZ8Q82sUPpISquf0JZv0H/1I4R" +
        "S43OtJwUNzrgoeqXsuOz3SZLynOOPoNyB+aJGWK93cZOMW2w08n9JTgax/6VVHN/" +
        "ZUy/qfMPXMXsr5SJ1GBQnrBmc2pmWLymuJQYIlxuqoYFmGonUp6g7ihaVtRUkEg" +
        "JU9ReYR43WD28MXxlMRPmpCcYoB747x5VXRx8K9nJcpvWOuMuWA+429RdSArQaK1" +
        "FjipbwGtRVL/bQiKgfrGR0lAwwSOHXWWIewIO0bPQl73k5Vu+SS4xclbm8gi/k6D" +
        "/hy1kEI7/pWCWmNviWSu+3Ibp3G8h0KLj8RA/oeW0gjmL6AARop+0h+hzNZ5yoi" +
        "ixr/h9rpIY+b36yk7zEWarPSdgw420RO4ZECdvNuWyOc/bzAbRXCJ3OqV5URAG9Y" +
        "xkeOsS33UIWW6yoCLsoWImrxAXx7jm5EuPRigZlnCKXh5uXi6G1nvu7GJoNIKbl/" +
        "YosXWDhFFjUoAP9f/mwF7nIFdpEP8LPfj1r+zE6eCiY8vw1tJhOpwJRpb2aVEkE" +
        "cvfgEjB6cdwHgfWK8PkpYJfv7vDLRaByzAvL7OesCEgNmoTp1p5sTK6ycPFy9Kc" +
        "QrsGhSp1NJZMfMHUL9o2COYKCo/IFn7jqMuwqWa6MSHzEdKUtIH7Iow=="

    private static func seedLegacyLibrary(in store: InMemorySecureValueStore) async throws {
        let key = try XCTUnwrap(Data(base64Encoded: legacyKeyBase64))
        let encrypted = try XCTUnwrap(Data(base64Encoded: legacyEncryptedLibraryBase64))
        await store.seed(
            key,
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        await store.seed(
            encrypted,
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
    }

    /// Independent frozen-format reader used to verify the rebuilt writer.
    private static func frozenLegacyJSON(
        encrypted: Data,
        key: Data
    ) throws -> [String: Any] {
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: plaintext) as? [String: Any]
        )
    }

    private static func payload(publicID: Data, keyStart: Int) -> CipherSharePayload {
        CipherSharePayload(
            publicID: publicID,
            keyMaterial: Data(
                (keyStart..<(keyStart + 32)).map { UInt8($0 & 0xFF) }
            ),
            decorativeMapping: Array(0..<32),
            fontRef: .bundled
        )
    }

    private static func progressionContext(
        byte: UInt8
    ) throws -> RuntimePersistableOperationContext {
        try RuntimePersistableOperationContext(
            operationID: RuntimeOperationID(rawValue: "persistence-\(byte)"),
            correlationID: RuntimeCorrelationID(
                rawValue: "F0000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
            ),
            occurredAtUTC: Date(timeIntervalSince1970: 1_700_000_000.654_321),
            operationIdentifier: RuntimeOperationIdentifier(rawValue: "core.persistence"),
            runtimeGeneration: 1,
            authorityNonce: UUID(
                uuidString: "F1000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
            )!,
            authorityTag: Data(repeating: byte, count: 32),
            authorityScope: .persistent
        )
    }

    private static func progressionPending(
        context: RuntimePersistableOperationContext,
        byte: UInt8
    ) throws -> CorePendingProgressionBatch {
        let token = CipherToken(
            rawValue: String(format: "%064x", Int(byte) + 100)
        )!
        let fact = try CoreProgressionFactFactory.cipherCreated(cipherToken: token)
        let batch = try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: 1,
            totalFactCount: 1,
            facts: [try SlottedProgressionEventFact(
                slot: ProgressionFactSlot(rawValue: 0),
                fact: fact
            )]
        )
        return try CorePendingProgressionBatch(
            context: context,
            commandDigest: CoreProgressionDigest.canonical("persistence-\(byte)"),
            batch: batch
        )
    }

    private static func firstDeliveryPending(
        context: RuntimePersistableOperationContext,
        byte: UInt8
    ) throws -> CorePendingProgressionBatch {
        let cipherToken = CipherToken(
            rawValue: String(format: "%064x", Int(byte) + 200)
        )!
        let relationshipToken = RelationshipToken(
            rawValue: String(format: "%064x", Int(byte) + 300)
        )!
        let fact = try CoreProgressionFactFactory.firstDeliveryCompleted(
            cipherToken: cipherToken,
            relationshipToken: relationshipToken
        )
        let batch = try ProgressionEventFactBatch(
            batchIndex: 0,
            totalBatchCount: 1,
            totalFactCount: 1,
            facts: [try SlottedProgressionEventFact(
                slot: ProgressionFactSlot(rawValue: 0),
                fact: fact
            )]
        )
        return try CorePendingProgressionBatch(
            context: context,
            commandDigest: CoreProgressionDigest.canonical("first-delivery-\(byte)"),
            batch: batch
        )
    }

    private static func progressionReceipt(
        context: RuntimePersistableOperationContext,
        batch: ProgressionEventFactBatch,
        byte: UInt8
    ) throws -> ProgressionOutboxBatchReceipt {
        try ProgressionOutboxBatchReceipt(
            contextID: context.runtimeOperationID,
            batchIndex: batch.batchIndex,
            eventIDsBySlot: [
                ProgressionFactSlot(rawValue: 0): EventID(rawValue: UUID(
                    uuidString: "F2000000-0000-0000-0000-0000000000\(String(format: "%02x", byte))"
                )!),
            ],
            correlationID: CorrelationID(rawValue: UUID(
                uuidString: context.runtimeCorrelationID.rawValue
            )!),
            durableAt: Date(timeIntervalSince1970: 1_700_000_001),
            outboxRevision: 1
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}

private struct FixedClock: ClockProviding {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        date
    }
}

private struct FixedUUIDProvider: UUIDProviding {
    let value: UUID

    init(_ value: UUID) {
        self.value = value
    }

    func nextUUID() -> UUID {
        value
    }
}

private actor InMemorySecureValueStore: SecureValueStore {
    struct Address: Hashable, Sendable {
        let service: String
        let account: String
    }

    enum Operation: Equatable, Sendable {
        case read(Address)
        case write(Address)
        case delete(Address)

        var address: Address {
            switch self {
            case .read(let address), .write(let address), .delete(let address):
                address
            }
        }

        var isWrite: Bool {
            if case .write = self { return true }
            return false
        }
    }

    enum StoreError: Error {
        case unavailable
    }

    private var values: [Address: Data] = [:]
    private var operations: [Operation] = []
    private var failingReadAccounts: Set<String> = []
    private var remainingReadFailures: [String: Int] = [:]
    private var failingWriteAccounts: Set<String> = []
    private var remainingAfterCommitWriteFailures: [String: Int] = [:]

    func seed(_ data: Data, service: String, account: String) {
        values[Address(service: service, account: account)] = data
    }

    func value(service: String, account: String) -> Data? {
        values[Address(service: service, account: account)]
    }

    func itemCount() -> Int {
        values.count
    }

    func recordedOperations() -> [Operation] {
        operations
    }

    func clearOperations() {
        operations.removeAll()
    }

    func failReads(from account: String) {
        failingReadAccounts.insert(account)
    }

    func failNextReads(from account: String, count: Int) {
        remainingReadFailures[account] = count
    }

    func failWrites(to account: String) {
        failingWriteAccounts.insert(account)
    }

    func allowWrites(to account: String) {
        failingWriteAccounts.remove(account)
    }

    func failNextWritesAfterCommit(to account: String, count: Int = 1) {
        remainingAfterCommitWriteFailures[account] = count
    }

    func data(service: String, account: String) async throws -> Data? {
        let address = Address(service: service, account: account)
        operations.append(.read(address))
        await Task.yield()
        guard !failingReadAccounts.contains(account) else {
            throw StoreError.unavailable
        }
        if let remaining = remainingReadFailures[account], remaining > 0 {
            remainingReadFailures[account] = remaining - 1
            throw StoreError.unavailable
        }
        return values[address]
    }

    func set(_ data: Data, service: String, account: String) async throws {
        let address = Address(service: service, account: account)
        operations.append(.write(address))
        guard !failingWriteAccounts.contains(account) else {
            throw StoreError.unavailable
        }
        await Task.yield()
        values[address] = data
        if let remaining = remainingAfterCommitWriteFailures[account], remaining > 0 {
            remainingAfterCommitWriteFailures[account] = remaining - 1
            throw StoreError.unavailable
        }
    }

    func delete(service: String, account: String) async throws {
        let address = Address(service: service, account: account)
        operations.append(.delete(address))
        values.removeValue(forKey: address)
    }
}
