import CryptoKit
import Foundation
import RuneScribeContracts
import Synchronization
@testable import RuneScribeCoreModule
import XCTest

final class ContactRepositoryTests: XCTestCase {
    private static let encryptedContactBookBase64 = "oKGio6SlpqeoqaqrnToKSDe4a9AMR73iK1ijsR7YOHPmxGBWx3UE7xuJTyPiRnfPnxJjDXKsNPg5V7PJdytreFLgKlNxbjtulEC1gISMtV4SicaEnZGPdO63gtugbome54P4CYsZV/TUuGG2/+xExWbdraHF+S1hsL3YGRZjVZvoArlhA+27ydU8nj7nK+tdsSPzclswkO5SL+m35anBDpCzleHfkJHX3KhBWaV9PYuUByF492tHAEPw1ZMSR4n9ZifaHLiyC2Qhu77yzdD6MSN+2D5mOc60vQ=="

    func testContactCodableRoundTripPreservesEveryField() throws {
        let contact = Contact(
            id: try XCTUnwrap(
                UUID(uuidString: "71000000-0000-0000-0000-000000000001")
            ),
            displayName: "Codable Contact",
            phones: ["+15550100710", "+15550100711"],
            emails: ["codable@example.invalid"],
            appleContactID: "synthetic-contact-710",
            source: .imported,
            createdAt: Date(timeIntervalSinceReferenceDate: 710)
        )

        let encoded = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(Contact.self, from: encoded)

        XCTAssertEqual(decoded, contact)
    }

    func testContactBookCodableRoundTripPreservesVersionAndContacts() throws {
        let contacts = try [
            Contact(
                id: XCTUnwrap(
                    UUID(uuidString: "54000000-0000-0000-0000-000000000001")
                ),
                displayName: "Manual Contact",
                phones: ["+15550100540"],
                source: .manual,
                createdAt: Date(timeIntervalSinceReferenceDate: 540)
            ),
            Contact(
                id: XCTUnwrap(
                    UUID(uuidString: "54000000-0000-0000-0000-000000000002")
                ),
                displayName: "Imported Contact",
                emails: ["imported@example.invalid"],
                appleContactID: "synthetic-contact-541",
                source: .imported,
                createdAt: Date(timeIntervalSinceReferenceDate: 541)
            ),
        ]
        let book = ContactBook(version: ContactBook.currentVersion, contacts: contacts)

        let encoded = try JSONEncoder().encode(book)
        let decoded = try JSONDecoder().decode(ContactBook.self, from: encoded)

        XCTAssertEqual(decoded, book)
        XCTAssertEqual(decoded.version, ContactBook.currentVersion)
        XCTAssertEqual(decoded.contacts, contacts)
    }

    func testLoadsFrozenVersion1AESGCMFixtureFromShippingPathAndAccount() async throws {
        let fixture = try XCTUnwrap(Data(base64Encoded: Self.encryptedContactBookBase64))
        let key = Data((0...31).map(UInt8.init))
        let secureStore = ContactSecureStore(values: [Self.symmetricKeyLocation: key])
        let fileStore = ContactFileStore(files: [.contacts: fixture])
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )

        let book = try await repository.snapshot()

        XCTAssertEqual(book.version, 1)
        let contact = try XCTUnwrap(book.contacts.first)
        XCTAssertEqual(
            contact.id,
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        XCTAssertEqual(contact.displayName, "Baseline")
        XCTAssertEqual(contact.phones, ["+15551234567"])
        XCTAssertEqual(contact.emails, ["baseline@example.com"])
        XCTAssertNil(contact.appleContactID)
        XCTAssertEqual(contact.source, .manual)
        XCTAssertEqual(contact.createdAt, Date(timeIntervalSinceReferenceDate: 0))
        let readPaths = await fileStore.readPaths()
        let readLocations = await secureStore.readLocations()
        XCTAssertEqual(readPaths, [.contacts])
        XCTAssertEqual(readLocations, [Self.symmetricKeyLocation])
    }

    func testMissingFileIsEmptyWithoutReadingOrCreatingAKey() async throws {
        let secureStore = ContactSecureStore()
        let fileStore = ContactFileStore()
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )

        let book = try await repository.snapshot()
        let reads = await secureStore.readLocations()
        let writes = await secureStore.writeLocations()
        XCTAssertEqual(book, .empty)
        XCTAssertEqual(reads, [])
        XCTAssertEqual(writes, [])
    }

    func testExistingFileWithWrongKeyFailsWithoutRewriting() async throws {
        let fixture = try XCTUnwrap(Data(base64Encoded: Self.encryptedContactBookBase64))
        let wrongKey = Data(repeating: 0xA5, count: 32)
        let secureStore = ContactSecureStore(values: [Self.symmetricKeyLocation: wrongKey])
        let fileStore = ContactFileStore(files: [.contacts: fixture])
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )

        await XCTAssertThrowsErrorAsync(try await repository.snapshot()) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .corruptedStore)
        }
        let persisted = await fileStore.data(at: .contacts)
        let writes = await fileStore.writePaths()
        XCTAssertEqual(persisted, fixture)
        XCTAssertEqual(writes, [])
    }

    func testUnsupportedEncryptedSchemaVersionIsTypedAndNotRewritten() async throws {
        let keyData = Data((0...31).map(UInt8.init))
        let sealed = try AES.GCM.seal(
            Data(#"{"version":2,"contacts":[]}"#.utf8),
            using: SymmetricKey(data: keyData)
        )
        let fixture = try XCTUnwrap(sealed.combined)
        let secureStore = ContactSecureStore(values: [Self.symmetricKeyLocation: keyData])
        let fileStore = ContactFileStore(files: [.contacts: fixture])
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )

        await XCTAssertThrowsErrorAsync(try await repository.snapshot()) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .unsupportedStoreVersion(2))
        }
        let persisted = await fileStore.data(at: .contacts)
        let writes = await fileStore.writePaths()
        XCTAssertEqual(persisted, fixture)
        XCTAssertEqual(writes, [])
    }

    func testSaveRequiresExistingSharedKeyAndDoesNotCreateOne() async throws {
        let secureStore = ContactSecureStore()
        let fileStore = ContactFileStore()
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )
        _ = try await repository.snapshot()
        let contact = Contact(
            id: UUID(),
            displayName: "No Key",
            source: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        await XCTAssertThrowsErrorAsync(
            try await repository.replace(ContactBook(contacts: [contact]))
        ) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .missingSymmetricKey)
        }
        let secureWrites = await secureStore.writeLocations()
        let persisted = await fileStore.data(at: .contacts)
        XCTAssertEqual(secureWrites, [])
        XCTAssertNil(persisted)
    }

    func testFailedProtectedWriteDoesNotPublishCandidate() async throws {
        let secureStore = ContactSecureStore(
            values: [Self.symmetricKeyLocation: Data((0...31).map(UInt8.init))]
        )
        let fileStore = ContactFileStore()
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )
        _ = try await repository.snapshot()
        await fileStore.setWriteFailure(true)
        let contact = Contact(
            id: UUID(),
            displayName: "Must Not Commit",
            source: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        await XCTAssertThrowsErrorAsync(
            try await repository.replace(ContactBook(contacts: [contact]))
        ) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .protectedStorageUnavailable)
        }
        let book = try await repository.snapshot()
        XCTAssertEqual(book, .empty)
    }

    func testAmbiguousProtectedWriteInvalidatesCacheAndReloadsAuthoritativeFile() async throws {
        let secureStore = ContactSecureStore(
            values: [Self.symmetricKeyLocation: Data((0...31).map(UInt8.init))]
        )
        let fileStore = ContactFileStore()
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )
        _ = try await repository.snapshot()
        let contact = Contact(
            id: UUID(),
            displayName: "Committed Before Error",
            source: .imported,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        await fileStore.setCommitThenFail(true)

        await XCTAssertThrowsErrorAsync(
            try await repository.replace(ContactBook(contacts: [contact]))
        ) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .protectedStorageUnavailable)
        }
        await fileStore.setCommitThenFail(false)

        let reloaded = try await repository.snapshot()
        XCTAssertEqual(reloaded.contacts, [contact])
    }

    func testAssociationIntentIsEncryptedVerifiedAndClearedAfterAmbiguousRemoval() async throws {
        let secureStore = ContactSecureStore(
            values: [Self.symmetricKeyLocation: Data((0...31).map(UInt8.init))]
        )
        let fileStore = ContactFileStore()
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: fileStore
        )
        let intent = MessageContactAssociationIntent(
            cipherID: try XCTUnwrap(
                UUID(uuidString: "60000000-0000-0000-0000-000000000001")
            ),
            preparedContactID: try XCTUnwrap(
                UUID(uuidString: "60000000-0000-0000-0000-000000000002")
            ),
            previousContactID: try XCTUnwrap(
                UUID(uuidString: "60000000-0000-0000-0000-000000000003")
            ),
            requiresContactCommit: true
        )
        let path = try XCTUnwrap(
            ProtectedPath(rawValue: "RuneScribContacts/message-contact-association.enc")
        )
        await fileStore.setCommitThenFail(true)

        try await repository.storeMessageAssociationIntent(intent)

        await fileStore.setCommitThenFail(false)
        let storedIntent = await fileStore.data(at: path)
        let encrypted = try XCTUnwrap(storedIntent)
        XCTAssertNil(encrypted.range(of: Data(intent.cipherID.uuidString.utf8)))
        let loaded = try await repository.messageAssociationIntent()
        XCTAssertEqual(loaded, intent)

        await fileStore.setRemoveThenFail(true)
        try await repository.removeMessageAssociationIntent()
        let removedData = await fileStore.data(at: path)
        let removedIntent = try await repository.messageAssociationIntent()
        XCTAssertNil(removedData)
        XCTAssertNil(removedIntent)
    }

    func testCorruptedAssociationIntentFailsClosedWithoutOverwrite() async throws {
        let keyData = Data((0...31).map(UInt8.init))
        let path = try XCTUnwrap(
            ProtectedPath(rawValue: "RuneScribContacts/message-contact-association.enc")
        )
        let corrupt = Data(repeating: 0xA5, count: 48)
        let fileStore = ContactFileStore(files: [path: corrupt])
        let repository = EncryptedContactRepository(
            secureValueStore: ContactSecureStore(
                values: [Self.symmetricKeyLocation: keyData]
            ),
            protectedFileStore: fileStore
        )

        await XCTAssertThrowsErrorAsync(
            try await repository.messageAssociationIntent()
        ) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .corruptedStore)
        }
        let persisted = await fileStore.data(at: path)
        let writes = await fileStore.writePaths()
        XCTAssertEqual(persisted, corrupt)
        XCTAssertEqual(writes, [])
    }

    func testUnsupportedAssociationIntentVersionIsRejected() async throws {
        let keyData = Data((0...31).map(UInt8.init))
        let path = try XCTUnwrap(
            ProtectedPath(rawValue: "RuneScribContacts/message-contact-association.enc")
        )
        let plaintext = Data(
            #"{"version":2,"cipherID":"61000000-0000-0000-0000-000000000001","preparedContactID":"61000000-0000-0000-0000-000000000002","previousContactID":null,"requiresContactCommit":true}"#.utf8
        )
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: keyData))
        let encrypted = try XCTUnwrap(box.combined)
        let repository = EncryptedContactRepository(
            secureValueStore: ContactSecureStore(
                values: [Self.symmetricKeyLocation: keyData]
            ),
            protectedFileStore: ContactFileStore(files: [path: encrypted])
        )

        await XCTAssertThrowsErrorAsync(
            try await repository.messageAssociationIntent()
        ) { error in
            XCTAssertEqual(error as? ContactRepositoryError, .unsupportedStoreVersion(2))
        }
    }

    private static let symmetricKeyLocation = ContactSecureStore.Location(
        service: RuneScribeKeychain.service,
        account: RuneScribeKeychain.symmetricKeyAccount
    )
}

final class ContactManagerCoreTests: XCTestCase {
    func testRemovingEmptySetIsNoOp() throws {
        let contact = Contact(
            id: try XCTUnwrap(
                UUID(uuidString: "09000000-0000-0000-0000-000000000001")
            ),
            displayName: "Manual",
            source: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
        let book = ContactBook(contacts: [contact])

        XCTAssertEqual(book.removing(ids: []), book)
    }

    func testManualCreateAndUpdatePreserveIdentitySourceAndCreationDate() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
        let date = Date(timeIntervalSinceReferenceDate: 42)
        let fixture = try makeManager(ids: [id], date: date)

        let created = try await fixture.manager.create(
            CreateContactCommand(
                displayName: "Saga",
                phoneNumbers: ["+15550000001"],
                emailAddresses: ["saga@example.com"]
            )
        )
        let updated = try await fixture.manager.update(
            UpdateContactCommand(
                contactID: ContactID(rawValue: id),
                displayName: "Saga Updated",
                phoneNumbers: [],
                emailAddresses: ["updated@example.com"]
            )
        )

        XCTAssertEqual(created.value.id, id)
        XCTAssertEqual(created.value.source, .manual)
        XCTAssertEqual(updated.value.id, id)
        XCTAssertEqual(updated.value.source, .manual)
        XCTAssertEqual(updated.value.createdAt, date)
        XCTAssertEqual(updated.value.displayName, "Saga Updated")
        let finalBook = try await fixture.manager.snapshot()
        XCTAssertEqual(finalBook.contacts, [updated.value])
    }

    func testDeletingEmptySetReturnsUnchangedBookWithoutWriting() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "11000000-0000-0000-0000-000000000001"))
        let fixture = try makeManager(
            ids: [id],
            date: Date(timeIntervalSinceReferenceDate: 43)
        )
        _ = try await fixture.manager.create(
            CreateContactCommand(displayName: "Manual")
        )
        let before = try await fixture.manager.snapshot()
        let writesBefore = await fixture.files.writePaths()

        let removal = try await fixture.manager.delete(ids: [])

        let after = try await fixture.manager.snapshot()
        let writesAfter = await fixture.files.writePaths()
        XCTAssertEqual(removal.removed, [])
        XCTAssertEqual(removal.book, before)
        XCTAssertEqual(after, before)
        XCTAssertEqual(writesAfter, writesBefore)
    }

    func testImportDeduplicatesExistingAndBatchWhilePreservingFirstSeenOrder() async throws {
        let ids = try [
            XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000001")),
            XCTUnwrap(UUID(uuidString: "20000000-0000-0000-0000-000000000002")),
        ]
        let fixture = try makeManager(ids: ids, date: Date(timeIntervalSinceReferenceDate: 7))
        let first = SystemContactDTO(systemIdentifier: "system-1", displayName: "First")
        let duplicate = SystemContactDTO(systemIdentifier: "system-1", displayName: "Duplicate")
        let second = SystemContactDTO(systemIdentifier: "system-2", displayName: "Second")

        let initial = try await fixture.manager.importContacts(
            ImportContactsCommand(contacts: [first, duplicate, second])
        )
        let repeated = try await fixture.manager.importContacts(
            ImportContactsCommand(contacts: [second, first])
        )

        XCTAssertEqual(initial.added.map(\.displayName), ["First", "Second"])
        XCTAssertEqual(initial.added.map(\.id), ids)
        XCTAssertEqual(initial.linkCandidates.map(\.id), ids)
        XCTAssertEqual(repeated.added, [])
        XCTAssertEqual(repeated.linkCandidates.map(\.id), ids)
        XCTAssertEqual(repeated.book.contacts.map(\.appleContactID), ["system-1", "system-2"])
    }

    func testDeleteAllImportedPreservesManualAndReportsRemovedIDs() async throws {
        let ids = try [
            XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000001")),
            XCTUnwrap(UUID(uuidString: "30000000-0000-0000-0000-000000000002")),
        ]
        let fixture = try makeManager(ids: ids, date: Date(timeIntervalSinceReferenceDate: 9))
        let manual = try await fixture.manager.create(CreateContactCommand(displayName: "Manual"))
        let imported = try await fixture.manager.importContacts(
            ImportContactsCommand(
                contacts: [SystemContactDTO(systemIdentifier: "system", displayName: "Imported")]
            )
        )

        let removal = try await fixture.manager.deleteAllImported()

        XCTAssertEqual(removal.removed.map(\.id), imported.added.map(\.id))
        XCTAssertEqual(removal.book.contacts, [manual.value])
    }

    func testPreparedMessageContactUsesExactNameAndCommitsOnlyWhenRequested() async throws {
        let id = try XCTUnwrap(UUID(uuidString: "40000000-0000-0000-0000-000000000001"))
        let fixture = try makeManager(ids: [id], date: Date(timeIntervalSinceReferenceDate: 11))

        let prepared = try await fixture.manager.prepareImportedContact(named: "Sender")
        let beforeCommit = try await fixture.manager.snapshot()
        let committed = try await fixture.manager.commitPreparedImportedContact(prepared)
        let existing = try await fixture.manager.prepareImportedContact(named: "Sender")

        XCTAssertTrue(prepared.requiresCommit)
        XCTAssertEqual(prepared.contact.id, id)
        XCTAssertEqual(beforeCommit, .empty)
        XCTAssertEqual(committed.book.contacts, [prepared.contact])
        XCTAssertFalse(existing.requiresCommit)
        XCTAssertEqual(existing.contact, prepared.contact)
        XCTAssertEqual(existing.contact.source, .imported)
        XCTAssertNil(existing.contact.appleContactID)
    }

    func testCommittingPreparedMessageContactRebasesOntoCurrentBook() async throws {
        let ids = try [
            XCTUnwrap(UUID(uuidString: "41000000-0000-0000-0000-000000000001")),
            XCTUnwrap(UUID(uuidString: "41000000-0000-0000-0000-000000000002")),
        ]
        let fixture = try makeManager(ids: ids, date: Date(timeIntervalSinceReferenceDate: 11))

        let prepared = try await fixture.manager.prepareImportedContact(named: "Sender")
        let manual = try await fixture.manager.create(CreateContactCommand(displayName: "Manual"))
        let committed = try await fixture.manager.commitPreparedImportedContact(prepared)

        XCTAssertEqual(committed.book.contacts.map(\.id), [manual.value.id, prepared.contact.id])
    }

    func testPendingMessageAssociationRecoveryRemovesOnlyPreparedContactAndRetainsIntent() async throws {
        let ids = try [
            XCTUnwrap(UUID(uuidString: "42000000-0000-0000-0000-000000000001")),
            XCTUnwrap(UUID(uuidString: "42000000-0000-0000-0000-000000000002")),
        ]
        let fixture = try makeManager(ids: ids, date: Date(timeIntervalSinceReferenceDate: 11))
        let prior = try await fixture.manager.create(CreateContactCommand(displayName: "Prior"))
        let prepared = try await fixture.manager.prepareImportedContact(named: "Prospective")
        let cipherID = try XCTUnwrap(
            UUID(uuidString: "42000000-0000-0000-0000-000000000003")
        )
        let intent = try await fixture.manager.stageMessageAssociation(
            prepared,
            cipherID: cipherID,
            previousContactID: prior.value.id
        )
        _ = try await fixture.manager.commitPreparedImportedContact(prepared)

        let preparedRecovery = try await fixture.manager.prepareMessageAssociationRecovery()
        let recovery = try XCTUnwrap(preparedRecovery)

        XCTAssertEqual(recovery.intent, intent)
        XCTAssertEqual(recovery.book.contacts, [prior.value])
        let retainedIntent = try await fixture.repository.messageAssociationIntent()
        XCTAssertEqual(retainedIntent, intent)

        try await fixture.manager.completeMessageAssociationRecovery(intent)
        let clearedIntent = try await fixture.repository.messageAssociationIntent()
        XCTAssertNil(clearedIntent)
    }

    func testPreparedCommitRejectsNewExactNameInsteadOfCreatingDuplicate() async throws {
        let ids = try [
            XCTUnwrap(UUID(uuidString: "43000000-0000-0000-0000-000000000001")),
            XCTUnwrap(UUID(uuidString: "43000000-0000-0000-0000-000000000002")),
        ]
        let fixture = try makeManager(ids: ids, date: Date(timeIntervalSinceReferenceDate: 11))
        let prepared = try await fixture.manager.prepareImportedContact(named: "Same")
        _ = try await fixture.manager.create(CreateContactCommand(displayName: "Same"))

        await XCTAssertThrowsErrorAsync(
            try await fixture.manager.commitPreparedImportedContact(prepared)
        ) { error in
            XCTAssertEqual(error as? ContactManagerError, .preparedContactConflict)
        }
        let book = try await fixture.manager.snapshot()
        XCTAssertEqual(book.contacts.map(\.displayName), ["Same"])
    }

    func testConcurrentCreatesPreserveBothCommittedContacts() async throws {
        let ids = try [
            XCTUnwrap(UUID(uuidString: "45000000-0000-0000-0000-000000000001")),
            XCTUnwrap(UUID(uuidString: "45000000-0000-0000-0000-000000000002")),
        ]
        let fixture = try makeManager(ids: ids, date: Date(timeIntervalSinceReferenceDate: 12))

        async let first = fixture.manager.create(CreateContactCommand(displayName: "First"))
        async let second = fixture.manager.create(CreateContactCommand(displayName: "Second"))
        _ = try await (first, second)

        let book = try await fixture.manager.snapshot()
        XCTAssertEqual(Set(book.contacts.map(\.id)), Set(ids))
        XCTAssertEqual(Set(book.contacts.map(\.displayName)), ["First", "Second"])
    }

    func testSummaryProjectionCarriesNoSystemIdentifierAndCountsLinks() throws {
        let id = try XCTUnwrap(UUID(uuidString: "50000000-0000-0000-0000-000000000001"))
        let contact = Contact(
            id: id,
            displayName: "Projected",
            appleContactID: "private-system-id",
            source: .imported,
            createdAt: Date(timeIntervalSinceReferenceDate: 13)
        )

        let summaries = ContactManager.summaries(
            for: ContactBook(contacts: [contact]),
            linkedCipherCounts: [id: 2]
        )

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries.first?.id, ContactID(rawValue: id))
        XCTAssertEqual(summaries.first?.source, .imported)
        XCTAssertEqual(summaries.first?.linkedCipherCount, 2)
    }

    private func makeManager(
        ids: [UUID],
        date: Date
    ) throws -> (
        manager: ContactManager,
        repository: EncryptedContactRepository,
        files: ContactFileStore
    ) {
        let secureStore = ContactSecureStore(
            values: [
                .init(
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.symmetricKeyAccount
                ): Data((0...31).map(UInt8.init)),
            ]
        )
        let files = ContactFileStore()
        let repository = EncryptedContactRepository(
            secureValueStore: secureStore,
            protectedFileStore: files
        )
        return (
            ContactManager(
                repository: repository,
                contactAccess: ContactAccessFake(status: .authorized),
                clock: ContactFixedClock(date),
                uuid: ContactSequenceUUIDProvider(ids)
            ),
            repository,
            files
        )
    }
}

private struct ContactFixedClock: ClockProviding {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date { date }
}

private final class ContactSequenceUUIDProvider: UUIDProviding, Sendable {
    private let values: Mutex<[UUID]>

    init(_ values: [UUID]) {
        self.values = Mutex(values)
    }

    func nextUUID() -> UUID {
        values.withLock { values in
            guard !values.isEmpty else {
                return UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            }
            return values.removeFirst()
        }
    }
}

private actor ContactAccessFake: ContactAccessService {
    private var status: ContactAuthorizationDTO

    init(status: ContactAuthorizationDTO) {
        self.status = status
    }

    func authorizationStatus() async -> ContactAuthorizationDTO { status }

    func requestAccess() async throws -> Bool {
        status = .authorized
        return true
    }

    func fetchContacts() async throws -> [SystemContactDTO] { [] }
}

private actor ContactSecureStore: SecureValueStore {
    struct Location: Hashable, Sendable {
        let service: String
        let account: String
    }

    private var values: [Location: Data]
    private var reads: [Location] = []
    private var writes: [Location] = []

    init(values: [Location: Data] = [:]) {
        self.values = values
    }

    func data(service: String, account: String) async throws -> Data? {
        let location = Location(service: service, account: account)
        reads.append(location)
        return values[location]
    }

    func set(_ data: Data, service: String, account: String) async throws {
        let location = Location(service: service, account: account)
        writes.append(location)
        values[location] = data
    }

    func delete(service: String, account: String) async throws {
        values.removeValue(forKey: Location(service: service, account: account))
    }

    func readLocations() -> [Location] { reads }
    func writeLocations() -> [Location] { writes }
}

private actor ContactFileStore: ProtectedFileStore {
    private var files: [ProtectedPath: Data]
    private var reads: [ProtectedPath] = []
    private var writes: [ProtectedPath] = []
    private var failWrites = false
    private var commitThenFail = false
    private var removeThenFail = false

    init(files: [ProtectedPath: Data] = [:]) {
        self.files = files
    }

    func read(relativePath: ProtectedPath) async throws -> Data? {
        reads.append(relativePath)
        return files[relativePath]
    }

    func write(_ data: Data, relativePath: ProtectedPath) async throws {
        guard !failWrites else { throw ContactFileFailure.failed }
        writes.append(relativePath)
        files[relativePath] = data
        if commitThenFail { throw ContactFileFailure.failed }
    }

    func remove(relativePath: ProtectedPath) async throws {
        files.removeValue(forKey: relativePath)
        if removeThenFail { throw ContactFileFailure.failed }
    }

    func exists(relativePath: ProtectedPath) async throws -> Bool {
        files[relativePath] != nil
    }

    func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        let prefix = directory.rawValue + "/"
        return files.keys.filter { path in
            path.rawValue.hasPrefix(prefix)
                && (fileExtension == nil
                    || URL(fileURLWithPath: path.rawValue).pathExtension == fileExtension)
        }.sorted()
    }

    func setWriteFailure(_ value: Bool) { failWrites = value }
    func setCommitThenFail(_ value: Bool) { commitThenFail = value }
    func setRemoveThenFail(_ value: Bool) { removeThenFail = value }
    func data(at path: ProtectedPath) -> Data? { files[path] }
    func readPaths() -> [ProtectedPath] { reads }
    func writePaths() -> [ProtectedPath] { writes }
}

private enum ContactFileFailure: Error {
    case failed
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
