import XCTest
@testable import RuneScrib

@MainActor
final class KeyManagerLinkTests: XCTestCase {

    private var keyManager: KeyManager { KeyManager.shared }

    override func setUp() async throws {
        // Ensure the singleton's async load completes before any test assertion
        // so that `activeCipher` reflects persisted state (not an empty library).
        await keyManager.load()
    }

    func testEnsureLinkedCipherGeneratesOneLinkedNonActiveCipher() {
        let contact = Contact(displayName: "Brynjar", appleContactID: "abc", source: .imported)
        let priorActive = keyManager.activeCipher?.id

        let created = keyManager.ensureLinkedCipher(forImportedContact: contact)

        let cipher = try! XCTUnwrap(created, "a contact with no ciphers must get one")
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

        let first = keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNotNil(first, "first ensure creates the cipher")

        let second = keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNil(second, "a contact that already has a cipher gets no second one")

        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).count, 1,
                       "still exactly one cipher linked after re-ensuring")
    }
}
