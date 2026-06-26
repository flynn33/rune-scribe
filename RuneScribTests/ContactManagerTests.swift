import XCTest
import CryptoKit
@testable import RuneScrib

@MainActor
final class ContactManagerTests: XCTestCase {

    override func setUp() async throws {
        // Ensure the singleton's async load completes so activeID is set before tests run.
        await KeyManager.shared.load()
    }

    private func makeManager() -> (ContactManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: dir)
        return (ContactManager(store: store, keyManager: .shared), dir)
    }

    func testAddImportedAutoLinksExactlyOneCipher() {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = Contact(displayName: "Sten", appleContactID: "imp-1", source: .imported)
        manager.addImported([snapshot])

        let stored = try! XCTUnwrap(manager.contacts.first { $0.appleContactID == "imp-1" })
        let linked = KeyManager.shared.ciphers(forContact: stored.id)
        XCTAssertEqual(linked.count, 1, "an imported contact gets exactly one auto-assigned cipher")
        XCTAssertEqual(linked.first?.label, "Sten", "the auto-assigned cipher is named for the contact")
        XCTAssertEqual(linked.first?.contactID, stored.id, "and is linked to it")
        XCTAssertNotEqual(KeyManager.shared.activeCipher?.id, linked.first?.id,
                          "import must not change the active cipher")
    }

    func testReimportingSameAppleIDDoesNotAddSecondCipher() {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let snapshot = Contact(displayName: "Vala", appleContactID: "imp-2", source: .imported)
        manager.addImported([snapshot])
        let stored = try! XCTUnwrap(manager.contacts.first { $0.appleContactID == "imp-2" })

        manager.addImported([snapshot]) // dedup by appleContactID — no new contact, no new cipher

        XCTAssertEqual(manager.contacts.filter { $0.appleContactID == "imp-2" }.count, 1,
                       "the duplicate import is deduped by appleContactID")
        XCTAssertEqual(KeyManager.shared.ciphers(forContact: stored.id).count, 1,
                       "and no second cipher is auto-assigned")
    }

    func testManualAddDoesNotAutoGenerateCipher() {
        let (manager, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let manual = Contact(displayName: "Orm", source: .manual)
        manager.add(manual)

        let stored = try! XCTUnwrap(manager.contacts.first { $0.id == manual.id })
        XCTAssertTrue(KeyManager.shared.ciphers(forContact: stored.id).isEmpty,
                      "manual add is import-only-exempt: no cipher is auto-generated")
    }
}
