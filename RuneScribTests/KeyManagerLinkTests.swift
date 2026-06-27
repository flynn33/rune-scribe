import XCTest
@testable import RuneScrib

@MainActor
final class KeyManagerLinkTests: XCTestCase {

    private var keyManager: KeyManager { KeyManager.shared }

    /// Contacts whose auto-assigned ciphers this test inserted into the shared singleton;
    /// torn down after each test so Keychain state does not accumulate across runs.
    private var createdContactIDs: [UUID] = []

    override func setUp() async throws {
        // Ensure the singleton's async load completes before any test assertion
        // so that `activeCipher` reflects persisted state (not an empty library).
        await keyManager.load()
    }

    override func tearDown() async throws {
        // Remove the ciphers this test inserted so later tests against the shared
        // singleton are not affected by leftover Keychain state. Robust to already-gone.
        for contactID in createdContactIDs {
            for cipher in keyManager.ciphers(forContact: contactID) {
                keyManager.deleteCipher(id: cipher.id)
            }
        }
        createdContactIDs.removeAll()
    }

    func testEnsureLinkedCipherGeneratesOneLinkedNonActiveCipher() throws {
        let contact = Contact(displayName: "Brynjar", appleContactID: "abc", source: .imported)
        createdContactIDs.append(contact.id)
        let priorActive = keyManager.activeCipher?.id

        let created = keyManager.ensureLinkedCipher(forImportedContact: contact)

        let cipher = try XCTUnwrap(created, "a contact with no ciphers must get one")
        XCTAssertEqual(cipher.label, "Brynjar", "the cipher is labelled with the contact's name")
        XCTAssertEqual(cipher.contactID, contact.id, "the cipher is linked to the contact")
        XCTAssertEqual(cipher.origin, .generated, "auto-assigned ciphers are generated, not imported")
        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).map(\.id), [cipher.id],
                       "exactly one cipher is linked to this contact")
        XCTAssertNotEqual(keyManager.activeCipher?.id, cipher.id,
                          "auto-assign must NOT steal the active selection")
        XCTAssertEqual(keyManager.activeCipher?.id, priorActive,
                       "the active cipher is unchanged by auto-assign")
    }
}

extension KeyManagerLinkTests {
    func testEnsureLinkedCipherIsIdempotentPerContact() {
        let contact = Contact(displayName: "Hilde", appleContactID: "dup-1", source: .imported)
        createdContactIDs.append(contact.id)

        let first = keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNotNil(first, "first ensure creates the cipher")

        let second = keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNil(second, "a contact that already has a cipher gets no second one")

        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).count, 1,
                       "still exactly one cipher linked after re-ensuring")
    }

    func testUnlinkContactsClearsAllLinksAndKeepsAllCiphers() throws {
        let one = Contact(displayName: "Ingrid", appleContactID: "ul-1", source: .imported)
        let two = Contact(displayName: "Soren", appleContactID: "ul-2", source: .imported)
        createdContactIDs.append(contentsOf: [one.id, two.id])
        let c1 = try XCTUnwrap(keyManager.ensureLinkedCipher(forImportedContact: one))
        let c2 = try XCTUnwrap(keyManager.ensureLinkedCipher(forImportedContact: two))

        keyManager.unlinkContacts([one.id, two.id])

        XCTAssertTrue(keyManager.ciphers(forContact: one.id).isEmpty, "no cipher remains linked to the first contact")
        XCTAssertTrue(keyManager.ciphers(forContact: two.id).isEmpty, "nor the second")
        XCTAssertNotNil(keyManager.ciphers.first { $0.id == c1.id }, "but both ciphers are kept")
        XCTAssertNotNil(keyManager.ciphers.first { $0.id == c2.id })
    }
}
