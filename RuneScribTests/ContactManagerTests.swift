import CryptoKit
import RuneScribeContracts
import XCTest
@testable import RuneScrib

@MainActor
final class ContactManagerTests: XCTestCase {
    private var keyManager: KeyManager!

    override func setUp() async throws {
        keyManager = TestApplicationFactory.makeKeyManager()
        try await waitForApplicationSnapshot(from: keyManager) {
            !$0.cipherLibrary.isLoading
        }
    }

    private func makeManager() -> (ContactManager, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContactManagerTests-\(UUID().uuidString)")
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: directory)
        return (ContactManager(store: store, keyManager: keyManager), directory)
    }

    func testAddImportedAutoLinksExactlyOneCipher() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let priorActiveID = keyManager.activeCipher?.id

        manager.addImported([
            Contact(displayName: "Sten", appleContactID: "imp-1", source: .imported)
        ])
        let stored = try XCTUnwrap(
            manager.contacts.first { $0.appleContactID == "imp-1" }
        )
        try await waitForApplicationSnapshot(from: keyManager) { snapshot in
            snapshot.cipherLibrary.ciphers.filter {
                $0.assignedContactID?.rawValue == stored.id
            }.count == 1
                && snapshot.cipherLibrary.activeCipherID?.rawValue == priorActiveID
        }

        let linked = keyManager.ciphers(forContact: stored.id)
        XCTAssertEqual(linked.count, 1, "an imported contact gets exactly one auto-assigned cipher")
        XCTAssertEqual(linked.first?.label, "Sten", "the auto-assigned cipher is named for the contact")
        XCTAssertEqual(linked.first?.contactID, stored.id, "and is linked to it")
        XCTAssertNotEqual(keyManager.activeCipher?.id, linked.first?.id,
                          "import must not change the active cipher")
        XCTAssertEqual(keyManager.activeCipher?.id, priorActiveID)
    }

    func testReimportingSameAppleIDDoesNotAddSecondCipher() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = Contact(displayName: "Vala", appleContactID: "imp-2", source: .imported)

        manager.addImported([snapshot])
        let stored = try XCTUnwrap(
            manager.contacts.first { $0.appleContactID == "imp-2" }
        )
        try await waitForLinkedCipher(contactID: stored.id, count: 1)

        manager.addImported([snapshot])

        XCTAssertEqual(manager.contacts.filter { $0.appleContactID == "imp-2" }.count, 1,
                       "the duplicate import is deduped by appleContactID")
        XCTAssertEqual(keyManager.ciphers(forContact: stored.id).count, 1,
                       "and no second cipher is auto-assigned")
    }

    func testManualAddDoesNotAutoGenerateCipher() throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manual = Contact(displayName: "Orm", source: .manual)

        manager.add(manual)

        let stored = try XCTUnwrap(manager.contacts.first { $0.id == manual.id })
        XCTAssertTrue(keyManager.ciphers(forContact: stored.id).isEmpty,
                      "manual add is import-only-exempt: no cipher is auto-generated")
    }

    func testBulkDeleteUnlinksCiphersButKeepsThem() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }

        manager.addImported([
            Contact(displayName: "Sten", appleContactID: "bulk-1", source: .imported),
            Contact(displayName: "Vala", appleContactID: "bulk-2", source: .imported),
        ])
        let one = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "bulk-1" })
        let two = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "bulk-2" })
        try await waitForApplicationSnapshot(from: keyManager) { snapshot in
            let assigned = snapshot.cipherLibrary.ciphers.filter { summary in
                summary.assignedContactID?.rawValue == one.id
                    || summary.assignedContactID?.rawValue == two.id
            }
            return assigned.count == 2
        }
        let cipherIDs = (keyManager.ciphers(forContact: one.id)
            + keyManager.ciphers(forContact: two.id)).map(\.id)
        XCTAssertEqual(cipherIDs.count, 2, "each imported contact starts with one linked cipher")

        manager.delete(ids: [one.id, two.id])
        try await waitForApplicationSnapshot(from: keyManager) { snapshot in
            snapshot.cipherLibrary.ciphers.allSatisfy { summary in
                guard let contactID = summary.assignedContactID?.rawValue else { return true }
                return contactID != one.id && contactID != two.id
            }
        }

        XCTAssertNil(manager.contacts.first { $0.id == one.id }, "the contacts are removed")
        XCTAssertNil(manager.contacts.first { $0.id == two.id })
        for id in cipherIDs {
            let cipher = try XCTUnwrap(keyManager.ciphers.first { $0.id == id },
                                       "the cipher is kept, never deleted")
            XCTAssertNil(cipher.contactID, "but its contact link is cleared")
        }
    }

    func testDeleteAllImportedSparesManual() async throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manual = Contact(displayName: "Orm", source: .manual)

        manager.add(manual)
        manager.addImported([
            Contact(displayName: "Sten", appleContactID: "all-1", source: .imported)
        ])
        let imported = try XCTUnwrap(
            manager.contacts.first { $0.appleContactID == "all-1" }
        )
        try await waitForLinkedCipher(contactID: imported.id, count: 1)
        let cipherID = try XCTUnwrap(keyManager.ciphers(forContact: imported.id).first?.id)

        manager.deleteAllImported()
        try await waitForLinkedCipher(contactID: imported.id, count: 0)

        XCTAssertEqual(manager.contacts.map(\.id), [manual.id],
                       "manual contacts survive; imported are removed")
        let cipher = try XCTUnwrap(keyManager.ciphers.first { $0.id == cipherID },
                                   "the cipher is kept")
        XCTAssertNil(cipher.contactID, "and unlinked")
    }

    func testBulkDeleteEmptySetIsNoOp() throws {
        let (manager, directory) = makeManager()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manual = Contact(displayName: "Orm", source: .manual)

        manager.add(manual)
        manager.delete(ids: [])

        XCTAssertEqual(manager.contacts.map(\.id), [manual.id],
                       "deleting an empty set removes nothing")
    }

    private func waitForLinkedCipher(contactID: UUID, count: Int) async throws {
        try await waitForApplicationSnapshot(from: keyManager) { snapshot in
            snapshot.cipherLibrary.ciphers.filter {
                $0.assignedContactID?.rawValue == contactID
            }.count == count
        }
    }
}
