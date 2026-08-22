// RuneScribTests/CipherLibraryTests.swift

import XCTest
import CryptoKit
@testable import RuneScribeCoreModule

/// Tests for the multi-cipher library model and the share/import round-trip.
final class CipherLibraryTests: XCTestCase {

    // MARK: - Cipher

    func testGeneratedCipherIsValid() {
        let c = Cipher.generated(label: "Test")
        XCTAssertEqual(c.label, "Test")
        XCTAssertEqual(c.origin, .generated)
        XCTAssertEqual(c.keyMaterial.count, 32)
        XCTAssertEqual(c.publicID.count, 8)
        XCTAssertEqual(Set(c.decorativeMapping), Set(0..<32))
    }

    func testTwoGeneratedCiphersHaveDistinctIds() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.publicID, b.publicID)
    }

    // MARK: - CipherLibrary

    func testLibraryCodableRoundTrip() throws {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: b.id)

        let data = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(CipherLibrary.self, from: data)

        XCTAssertEqual(restored, library)
        XCTAssertEqual(restored.activeCipher?.id, b.id)
    }

    func testStoredShapeRejectsCipherCountBeyondDecodeCapacity() {
        let cipher = Cipher.generated(label: "Capacity")
        let library = CipherLibrary(
            ciphers: Array(
                repeating: cipher,
                count: CipherLibrary.maximumCipherCount + 1
            ),
            activeID: cipher.id
        )

        XCTAssertThrowsError(try library.validateStoredShape()) { error in
            XCTAssertEqual(error as? CipherLibraryValidationError, .tooManyCiphers)
        }
    }

    func testActiveCipherFallsBackToFirst() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        XCTAssertEqual(CipherLibrary(ciphers: [a, b], activeID: UUID()).activeCipher?.id, a.id)
        XCTAssertEqual(CipherLibrary(ciphers: [a, b], activeID: nil).activeCipher?.id, a.id)
        XCTAssertNil(CipherLibrary.empty.activeCipher)
    }

    // MARK: - Pure mutations

    func testAddingActivates() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a], activeID: a.id).adding(b)
        XCTAssertEqual(library.ciphers.count, 2)
        XCTAssertEqual(library.activeID, b.id)
    }

    func testRemovingLastCipherRegenerates() {
        let only = Cipher.generated(label: "Only")
        let library = CipherLibrary(ciphers: [only], activeID: only.id).removingCipher(id: only.id)
        XCTAssertEqual(library.ciphers.count, 1, "library must never be empty")
        XCTAssertNotEqual(library.ciphers[0].id, only.id, "a fresh cipher is generated")
        XCTAssertEqual(library.activeID, library.ciphers[0].id)
    }

    func testRemovingActiveReassignsActive() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: a.id).removingCipher(id: a.id)
        XCTAssertEqual(library.ciphers.map(\.id), [b.id])
        XCTAssertEqual(library.activeID, b.id)
    }

    func testRemovingNonActiveKeepsActive() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: a.id).removingCipher(id: b.id)
        XCTAssertEqual(library.activeID, a.id)
        XCTAssertEqual(library.ciphers.count, 1)
    }

    func testSettingActiveIgnoresUnknownId() {
        let a = Cipher.generated(label: "A")
        let library = CipherLibrary(ciphers: [a], activeID: a.id)
        XCTAssertEqual(library.settingActive(id: UUID()).activeID, a.id, "unknown id is a no-op")
    }

    func testRenamingCipher() {
        let a = Cipher.generated(label: "Old")
        let library = CipherLibrary(ciphers: [a], activeID: a.id).renamingCipher(id: a.id, to: "New")
        XCTAssertEqual(library.ciphers[0].label, "New")
    }

    // MARK: - Share / import round-trip

    func testShareImportRoundTripProducesAWorkingCipher() throws {
        let original = Cipher.generated(label: "Friend")
        let rebuilt = try CipherSharePayload(
            decoding: CipherSharePayload(cipher: original).encoded()
        )
            .cipher(label: "Imported")
        XCTAssertEqual(rebuilt.keyMaterial, original.keyMaterial)
        XCTAssertEqual(rebuilt.origin, .imported)

        // Encrypt on the sender's cipher, decrypt with the imported one.
        let runes = try MessageService().compose("yo", with: original)
        XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "yo")
    }
}

extension CipherLibraryTests {
    func testImportFromFileFormReturnsInjectedFontBytesAndRebuildsCipher() throws {
        let fontBytes = Data("synthetic-font-fixture".utf8)
        let fontRef = FontRef(
            id: "fixture-font",
            version: 7,
            sha256: Data(SHA256.hash(data: fontBytes))
        )
        let generated = Cipher.generated(label: "Friend")
        let original = Cipher(
            id: generated.id,
            label: generated.label,
            origin: generated.origin,
            createdAt: generated.createdAt,
            publicID: generated.publicID,
            keyMaterial: generated.keyMaterial,
            decorativeMapping: generated.decorativeMapping,
            fontRef: fontRef
        )
        let file = try CipherSharePayload(cipher: original).encodedFile(fontBytes: fontBytes)
        let (payload, decodedFontBytes) = try CipherSharePayload.decodeFile(file)
        XCTAssertEqual(decodedFontBytes, fontBytes)
        let rebuilt = payload.cipher(label: "Imported")
        XCTAssertEqual(rebuilt.fontRef, original.fontRef)
        let runes = try MessageService().compose("hi", with: original)
        XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "hi")
    }
}

extension CipherLibraryTests {

    func testCompletingKeyDeliveryChangesOnlyTheTarget() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: a.id)
            .settingContact(cipherID: b.id, contactID: UUID())

        let after = library.completingKeyDelivery(cipherID: b.id)

        XCTAssertFalse(after.ciphers.first { $0.id == a.id }!.hasCompletedKeyDelivery)
        XCTAssertTrue(after.ciphers.first { $0.id == b.id }!.hasCompletedKeyDelivery)
        XCTAssertEqual(after.ciphers.first { $0.id == b.id }!.keyDeliveryState, .completed)
        XCTAssertEqual(after.activeID, a.id, "key delivery must not change the active cipher")
    }

    func testCompletingKeyDeliveryForUnknownIDIsNoOp() {
        let a = Cipher.generated(label: "A")
        let library = CipherLibrary(ciphers: [a], activeID: a.id)
        XCTAssertEqual(library.completingKeyDelivery(cipherID: UUID()), library)
    }

    func testAddingWithoutActivatingAppendsAndKeepsActive() {
        let a = Cipher.generated(label: "A")
        let b = Cipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a], activeID: a.id)

        let after = library.addingWithoutActivating(b)

        XCTAssertEqual(after.ciphers.map(\.id), [a.id, b.id])
        XCTAssertEqual(after.activeID, a.id, "must not steal the active selection")
    }

    func testAddingWithoutActivatingSeedsActiveWhenNil() {
        let a = Cipher.generated(label: "A")
        let library = CipherLibrary(ciphers: [], activeID: nil)
        let after = library.addingWithoutActivating(a)
        XCTAssertEqual(after.activeID, a.id, "first cipher into an empty library becomes active")
    }
}

extension CipherLibraryTests {
    func testSettingAndClearingContactKeepsTheCipher() {
        let cid = UUID()
        let c = Cipher.generated(label: "A")
        var lib = CipherLibrary(ciphers: [c], activeID: c.id).settingContact(cipherID: c.id, contactID: cid)
        XCTAssertEqual(lib.ciphers[0].contactID, cid)
        XCTAssertEqual(lib.ciphers[0].keyMaterial, c.keyMaterial, "linking never changes the key")
        lib = lib.settingContact(cipherID: c.id, contactID: nil)
        XCTAssertNil(lib.ciphers[0].contactID)
        XCTAssertEqual(lib.ciphers.count, 1, "unlink keeps the cipher")
    }
    func testUnlinkingAContactClearsOnlyItsCiphersAndKeepsThem() {
        let cid = UUID(), otherCID = UUID()
        let a = Cipher.generated(label: "A"), b = Cipher.generated(label: "B")
        var lib = CipherLibrary(ciphers: [a, b], activeID: a.id)
            .settingContact(cipherID: a.id, contactID: cid)
            .settingContact(cipherID: b.id, contactID: otherCID)
        lib = lib.unlinkingContact(contactID: cid)
        XCTAssertNil(lib.ciphers.first { $0.id == a.id }?.contactID)
        XCTAssertEqual(lib.ciphers.first { $0.id == b.id }?.contactID, otherCID, "unlinking one contact must not affect ciphers linked to a different contact")
        XCTAssertEqual(lib.ciphers.count, 2, "deleting a contact never deletes ciphers")
    }
}
