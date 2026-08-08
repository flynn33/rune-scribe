import RuneScribeContracts
import XCTest
@testable import RuneScrib

@MainActor
final class KeyManagerLinkTests: XCTestCase {
    private var keyManager: KeyManager!

    override func setUp() async throws {
        keyManager = TestApplicationFactory.makeKeyManager()
        try await waitForApplicationSnapshot(from: keyManager) {
            !$0.cipherLibrary.isLoading
        }
    }

    func testEnsureLinkedCipherGeneratesOneLinkedNonActiveCipher() async throws {
        let contact = Contact(displayName: "Brynjar", appleContactID: "abc", source: .imported)
        let priorActiveID = keyManager.activeCipher?.id

        let created = try await keyManager.ensureLinkedCipher(forImportedContact: contact)
        try await waitForLinkedCipher(contactID: contact.id, count: 1) { snapshot in
            snapshot.cipherLibrary.activeCipherID?.rawValue == priorActiveID
        }

        let createdID = try XCTUnwrap(created?.id, "a contact with no ciphers must get one")
        let cipher = try XCTUnwrap(keyManager.ciphers.first { $0.id == createdID })
        XCTAssertEqual(cipher.label, "Brynjar", "the cipher is labelled with the contact's name")
        XCTAssertEqual(cipher.contactID, contact.id, "the cipher is linked to the contact")
        XCTAssertEqual(cipher.origin, .generated, "auto-assigned ciphers are generated, not imported")
        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).map(\.id), [cipher.id],
                       "exactly one cipher is linked to this contact")
        XCTAssertNotEqual(keyManager.activeCipher?.id, cipher.id,
                          "auto-assign must NOT steal the active selection")
        XCTAssertEqual(keyManager.activeCipher?.id, priorActiveID,
                       "the active cipher is unchanged by auto-assign")
    }

    func testEnsureLinkedCipherIsIdempotentPerContact() async throws {
        let contact = Contact(displayName: "Hilde", appleContactID: "dup-1", source: .imported)

        let first = try await keyManager.ensureLinkedCipher(forImportedContact: contact)
        XCTAssertNotNil(first, "first ensure creates the cipher")
        try await waitForLinkedCipher(contactID: contact.id, count: 1)

        let second = try await keyManager.ensureLinkedCipher(forImportedContact: contact)

        XCTAssertNil(second, "a contact that already has a cipher gets no second one")
        XCTAssertEqual(keyManager.ciphers(forContact: contact.id).count, 1,
                       "still exactly one cipher linked after re-ensuring")
    }

    func testUnlinkContactsClearsAllLinksAndKeepsAllCiphers() async throws {
        let one = Contact(displayName: "Ingrid", appleContactID: "ul-1", source: .imported)
        let two = Contact(displayName: "Soren", appleContactID: "ul-2", source: .imported)
        let firstResult = try await keyManager.ensureLinkedCipher(forImportedContact: one)
        let c1 = try XCTUnwrap(firstResult)
        try await waitForLinkedCipher(contactID: one.id, count: 1)
        let secondResult = try await keyManager.ensureLinkedCipher(forImportedContact: two)
        let c2 = try XCTUnwrap(secondResult)
        try await waitForLinkedCipher(contactID: two.id, count: 1)

        try await keyManager.unlinkContacts([one.id, two.id])
        try await waitForApplicationSnapshot(from: keyManager) { snapshot in
            snapshot.cipherLibrary.ciphers.allSatisfy { summary in
                guard let contactID = summary.assignedContactID?.rawValue else { return true }
                return contactID != one.id && contactID != two.id
            }
        }

        XCTAssertTrue(keyManager.ciphers(forContact: one.id).isEmpty,
                      "no cipher remains linked to the first contact")
        XCTAssertTrue(keyManager.ciphers(forContact: two.id).isEmpty, "nor the second")
        XCTAssertNotNil(keyManager.ciphers.first { $0.id == c1.id }, "but both ciphers are kept")
        XCTAssertNotNil(keyManager.ciphers.first { $0.id == c2.id })
    }

    private func waitForLinkedCipher(
        contactID: UUID,
        count: Int,
        additionally predicate: @escaping (RuneScribeApplicationSnapshot) -> Bool = { _ in true }
    ) async throws {
        try await waitForApplicationSnapshot(from: keyManager) { snapshot in
            snapshot.cipherLibrary.ciphers.filter {
                $0.assignedContactID?.rawValue == contactID
            }.count == count && predicate(snapshot)
        }
    }
}
