import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import XCTest

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
        XCTAssertTrue(cipher.delivered)

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
        XCTAssertEqual(ciphers.first?["formatVersion"] as? Int, 1)

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
        let duplicate = await repository.ingestMessageCipher(
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
        let imported = await repository.ingestMessageCipher(
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

    func testSharedFailedInitializationCanRetryWithoutPoisoningNewLoad() async throws {
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
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Expected the shared initialization to fail")
            } catch let error as CipherRepositoryError {
                XCTAssertEqual(error, .secureStorageUnavailable)
            }
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

    func testMissingFileImportEmitsProtectedFileFailureBeforeReturning() async throws {
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
            fileURL: URL(fileURLWithPath: "/tmp/fixture.runescribe"),
            requiresSecurityScopedAccess: false
        )
        do {
            _ = try await service.importFile(input)
            XCTFail("Expected the missing file to fail")
        } catch let error as RuneScribeProductError {
            XCTAssertEqual(
                error,
                .failure(RuneScribeFailureDTO(code: .protectedFileUnavailable))
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
        XCTAssertEqual(failed.importState.lastFailure?.code, .protectedFileUnavailable)
        XCTAssertEqual(failed.lastFailure?.code, .protectedFileUnavailable)
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
    }

    func delete(service: String, account: String) async throws {
        let address = Address(service: service, account: account)
        operations.append(.delete(address))
        values.removeValue(forKey: address)
    }
}
