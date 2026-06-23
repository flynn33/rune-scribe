// RuneScribTests/CipherLibraryTests.swift

import XCTest
@testable import RuneScrib

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
        let rebuilt = try CipherSharePayload(decoding: CipherSharePayload(cipher: original).encoded())
            .cipher(label: "Imported")
        XCTAssertEqual(rebuilt.keyMaterial, original.keyMaterial)
        XCTAssertEqual(rebuilt.origin, .imported)

        // Encrypt on the sender's cipher, decrypt with the imported one.
        let runes = try MessageService().compose("yo", with: original)
        XCTAssertEqual(try MessageService().read(runes, tryingCiphers: [rebuilt]).plaintext, "yo")
    }
}
