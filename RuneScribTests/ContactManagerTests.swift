import XCTest
import CryptoKit
@testable import RuneScrib

@MainActor
final class ContactManagerTests: XCTestCase {

    /// Contacts whose auto-assigned ciphers landed in the shared `KeyManager`; torn down
    /// after each test so leftover Keychain state cannot make later tests flaky.
    private var createdContactIDs: [UUID] = []

    override func setUp() async throws {
        // Ensure the singleton's async load completes so activeID is set before tests run.
        await KeyManager.shared.load()
    }

    override func tearDown() async throws {
        // Remove ciphers this test auto-assigned in the shared singleton. Robust to already-gone.
        for contactID in createdContactIDs {
            for cipher in KeyManager.shared.ciphers(forContact: contactID) {
                KeyManager.shared.deleteCipher(id: cipher.id)
            }
        }
        createdContactIDs.removeAll()
    }

    private func makeManager() -> (ContactManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: dir)
        return (ContactManager(store: store, keyManager: .shared), dir)
    }

    func testAddImportedAutoLinksExactlyOneCipher() throws {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = Contact(displayName: "Sten", appleContactID: "imp-1", source: .imported)
        manager.addImported([snapshot])

        let stored = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "imp-1" })
        createdContactIDs.append(stored.id)
        let linked = KeyManager.shared.ciphers(forContact: stored.id)
        XCTAssertEqual(linked.count, 1, "an imported contact gets exactly one auto-assigned cipher")
        XCTAssertEqual(linked.first?.label, "Sten", "the auto-assigned cipher is named for the contact")
        XCTAssertEqual(linked.first?.contactID, stored.id, "and is linked to it")
        XCTAssertNotEqual(KeyManager.shared.activeCipher?.id, linked.first?.id,
                          "import must not change the active cipher")
    }

    func testReimportingSameAppleIDDoesNotAddSecondCipher() throws {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = Contact(displayName: "Vala", appleContactID: "imp-2", source: .imported)
        manager.addImported([snapshot])
        let stored = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "imp-2" })
        createdContactIDs.append(stored.id)

        manager.addImported([snapshot]) // dedup by appleContactID — no new contact, no new cipher

        XCTAssertEqual(manager.contacts.filter { $0.appleContactID == "imp-2" }.count, 1,
                       "the duplicate import is deduped by appleContactID")
        XCTAssertEqual(KeyManager.shared.ciphers(forContact: stored.id).count, 1,
                       "and no second cipher is auto-assigned")
    }

    func testManualAddDoesNotAutoGenerateCipher() throws {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = Contact(displayName: "Orm", source: .manual)
        manager.add(manual)

        let stored = try XCTUnwrap(manager.contacts.first { $0.id == manual.id })
        XCTAssertTrue(KeyManager.shared.ciphers(forContact: stored.id).isEmpty,
                      "manual add is import-only-exempt: no cipher is auto-generated")
    }

    func testBulkDeleteUnlinksCiphersButKeepsThem() throws {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        manager.addImported([
            Contact(displayName: "Sten", appleContactID: "bulk-1", source: .imported),
            Contact(displayName: "Vala", appleContactID: "bulk-2", source: .imported)
        ])
        let one = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "bulk-1" })
        let two = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "bulk-2" })
        createdContactIDs.append(contentsOf: [one.id, two.id])
        let cipherIDs = (KeyManager.shared.ciphers(forContact: one.id)
            + KeyManager.shared.ciphers(forContact: two.id)).map(\.id)
        XCTAssertEqual(cipherIDs.count, 2, "each imported contact starts with one linked cipher")

        manager.delete(ids: [one.id, two.id])

        XCTAssertNil(manager.contacts.first { $0.id == one.id }, "the contacts are removed")
        XCTAssertNil(manager.contacts.first { $0.id == two.id })
        for id in cipherIDs {
            let cipher = try XCTUnwrap(KeyManager.shared.ciphers.first { $0.id == id },
                                       "the cipher is kept, never deleted")
            XCTAssertNil(cipher.contactID, "but its contact link is cleared")
        }
    }

    func testDeleteAllImportedSparesManual() throws {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = Contact(displayName: "Orm", source: .manual)
        manager.add(manual)
        manager.addImported([Contact(displayName: "Sten", appleContactID: "all-1", source: .imported)])
        let imported = try XCTUnwrap(manager.contacts.first { $0.appleContactID == "all-1" })
        createdContactIDs.append(imported.id)
        let cipherID = try XCTUnwrap(KeyManager.shared.ciphers(forContact: imported.id).first?.id)

        manager.deleteAllImported()

        XCTAssertEqual(manager.contacts.map(\.id), [manual.id], "manual contacts survive; imported are removed")
        let cipher = try XCTUnwrap(KeyManager.shared.ciphers.first { $0.id == cipherID }, "the cipher is kept")
        XCTAssertNil(cipher.contactID, "and unlinked")
    }

    func testBulkDeleteEmptySetIsNoOp() throws {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = Contact(displayName: "Orm", source: .manual)
        manager.add(manual)

        manager.delete(ids: [])

        XCTAssertEqual(manager.contacts.map(\.id), [manual.id], "deleting an empty set removes nothing")
    }
}
