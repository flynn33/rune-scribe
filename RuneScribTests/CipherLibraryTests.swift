// RuneScribTests/CipherLibraryTests.swift

import XCTest
@testable import RuneScrib

/// Tests for the multi-cipher library model and the import/reconstruct path.
final class CipherLibraryTests: XCTestCase {

    private func makeKey() -> RuneKey {
        RuneKey(mapping: RuneCharacterSet.generateRandomMapping())
    }

    // MARK: - NamedCipher

    func testGeneratedCipherIsValid() {
        let cipher = NamedCipher.generated(label: "Test")
        XCTAssertEqual(cipher.label, "Test")
        XCTAssertEqual(cipher.origin, .generated)
        XCTAssertEqual(cipher.key.mapping.count, 89)
        XCTAssertEqual(cipher.key.reverseMapping.count, 89)
    }

    func testGeneratedCipherEncodeDecodeRoundTrip() {
        let cipher = NamedCipher.generated(label: "Round")
        let engine = CipherEngine(key: cipher.key)
        let original = "The wolf at dawn — 7 ships & 0 fear!"
        XCTAssertEqual(engine.decode(engine.encode(original)), original)
    }

    func testNamedCipherCodableRoundTrip() throws {
        let cipher = NamedCipher.generated(label: "Persist")
        let data = try JSONEncoder().encode(cipher)
        let restored = try JSONDecoder().decode(NamedCipher.self, from: data)
        XCTAssertEqual(restored, cipher)
    }

    func testTwoGeneratedCiphersHaveDistinctIds() {
        let a = NamedCipher.generated(label: "A")
        let b = NamedCipher.generated(label: "B")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(a.key.keyId, b.key.keyId)
    }

    // MARK: - CipherLibrary

    func testLibraryCodableRoundTrip() throws {
        let a = NamedCipher.generated(label: "A")
        let b = NamedCipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: b.id)

        let data = try JSONEncoder().encode(library)
        let restored = try JSONDecoder().decode(CipherLibrary.self, from: data)

        XCTAssertEqual(restored, library)
        XCTAssertEqual(restored.activeCipher?.id, b.id)
    }

    func testActiveCipherFallsBackToFirst() {
        let a = NamedCipher.generated(label: "A")
        let b = NamedCipher.generated(label: "B")

        // activeID points at a missing entry → falls back to the first.
        XCTAssertEqual(CipherLibrary(ciphers: [a, b], activeID: UUID()).activeCipher?.id, a.id)
        // nil activeID → first.
        XCTAssertEqual(CipherLibrary(ciphers: [a, b], activeID: nil).activeCipher?.id, a.id)
        // empty library → nil.
        XCTAssertNil(CipherLibrary.empty.activeCipher)
    }

    // MARK: - Import / Reconstruct Path

    func testRuneKeyPreservesIdentityOnReconstruct() {
        let original = makeKey()
        let rebuilt = RuneKey(keyId: original.keyId,
                              createdAt: original.createdAt,
                              mapping: original.mapping)
        XCTAssertEqual(rebuilt.keyId, original.keyId)
        XCTAssertEqual(rebuilt.createdAt, original.createdAt)
        XCTAssertEqual(rebuilt.reverseMapping, original.reverseMapping)
    }

    // MARK: - Pure Mutations

    func testAddingActivates() {
        let a = NamedCipher.generated(label: "A")
        let b = NamedCipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a], activeID: a.id).adding(b)
        XCTAssertEqual(library.ciphers.count, 2)
        XCTAssertEqual(library.activeID, b.id)
    }

    func testRemovingLastCipherRegenerates() {
        let only = NamedCipher.generated(label: "Only")
        let library = CipherLibrary(ciphers: [only], activeID: only.id).removingCipher(id: only.id)
        XCTAssertEqual(library.ciphers.count, 1, "library must never be empty")
        XCTAssertNotEqual(library.ciphers[0].id, only.id, "a fresh cipher is generated")
        XCTAssertEqual(library.activeID, library.ciphers[0].id, "active id tracks the fresh cipher")
    }

    func testRemovingActiveReassignsActive() {
        let a = NamedCipher.generated(label: "A")
        let b = NamedCipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: a.id).removingCipher(id: a.id)
        XCTAssertEqual(library.ciphers.map(\.id), [b.id])
        XCTAssertEqual(library.activeID, b.id)
    }

    func testRemovingNonActiveKeepsActive() {
        let a = NamedCipher.generated(label: "A")
        let b = NamedCipher.generated(label: "B")
        let library = CipherLibrary(ciphers: [a, b], activeID: a.id).removingCipher(id: b.id)
        XCTAssertEqual(library.activeID, a.id)
        XCTAssertEqual(library.ciphers.count, 1)
    }

    func testSettingActiveIgnoresUnknownId() {
        let a = NamedCipher.generated(label: "A")
        let library = CipherLibrary(ciphers: [a], activeID: a.id)
        XCTAssertEqual(library.settingActive(id: UUID()).activeID, a.id, "unknown id is a no-op")
    }

    func testRenamingCipher() {
        let a = NamedCipher.generated(label: "Old")
        let library = CipherLibrary(ciphers: [a], activeID: a.id).renamingCipher(id: a.id, to: "New")
        XCTAssertEqual(library.ciphers[0].label, "New")
    }

    // MARK: - Legacy Migration

    func testFromLegacyWithBothSources() {
        let key = makeKey()
        let decoderKey = makeKey()
        let export = try! JSONEncoder().encode(RuneKeyExport.from(decoderKey))
        let decoder = try! ImportedDecoder.parse(export)

        let library = CipherLibrary.fromLegacy(key: key, decoder: decoder)

        XCTAssertEqual(library.ciphers.count, 2)
        XCTAssertEqual(library.ciphers[0].origin, .generated)
        XCTAssertEqual(library.ciphers[1].origin, .imported)
        XCTAssertEqual(library.activeID, library.ciphers[0].id, "the generated cipher is active")
        XCTAssertEqual(library.ciphers[1].key.keyId, decoderKey.keyId, "imported keeps its key id")
    }

    func testFromLegacyWithOnlyKey() {
        let library = CipherLibrary.fromLegacy(key: makeKey(), decoder: nil)
        XCTAssertEqual(library.ciphers.count, 1)
        XCTAssertEqual(library.ciphers[0].origin, .generated)
    }

    func testFromLegacyEmptyGeneratesOne() {
        let library = CipherLibrary.fromLegacy(key: nil, decoder: nil)
        XCTAssertEqual(library.ciphers.count, 1, "always seeds at least one cipher")
        XCTAssertEqual(library.ciphers[0].origin, .generated)
        XCTAssertEqual(library.activeID, library.ciphers[0].id)
    }

    func testImportPathRoundTrip() throws {
        // Export → parse → reconstruct: identity preserved and runes still decode.
        let key = makeKey()
        let data = try JSONEncoder().encode(RuneKeyExport.from(key))
        let decoder = try ImportedDecoder.parse(data)
        let imported = RuneKey(keyId: decoder.keyId,
                               createdAt: decoder.createdAt,
                               mapping: decoder.mapping)

        XCTAssertEqual(imported.keyId, key.keyId)

        let message = "Meet at the longhouse."
        let runes = CipherEngine(key: key).encode(message)
        XCTAssertEqual(CipherEngine(key: imported).decode(runes), message)
    }
}
