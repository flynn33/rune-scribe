import XCTest
import CryptoKit
@testable import RuneScrib

@MainActor
final class MessageCoordinatorTests: XCTestCase {

    /// Ciphers already in the shared library before a test runs; everything added
    /// during the test is removed in tearDown so other test classes see a clean library.
    private var preexistingCipherIDs: Set<UUID> = []

    override func setUp() async throws {
        try await super.setUp()
        await KeyManager.shared.load()
        preexistingCipherIDs = Set(KeyManager.shared.ciphers.map(\.id))
    }

    // `autoAssociate` is always exercised through an injected `freshContactManager()`
    // (never `ContactManager.shared`), so contacts stay isolated per test and tearDown
    // only needs to restore the shared `KeyManager`, not contact state.
    override func tearDown() async throws {
        for cipher in KeyManager.shared.ciphers where !preexistingCipherIDs.contains(cipher.id) {
            KeyManager.shared.deleteCipher(id: cipher.id)
        }
        try await super.tearDown()
    }

    // A fresh ContactManager backed by an isolated, key-injected store — never
    // touches the Keychain or app-support, and starts with zero contacts.
    private func freshContactManager() -> ContactManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MsgCoordTests-\(UUID().uuidString)", isDirectory: true)
        let store = ContactStore(key: SymmetricKey(size: .bits256), directory: dir)
        return ContactManager(store: store, keyManager: .shared)
    }

    // Builds the wire envelope for `plaintext` under `cipher`, exactly as the app does.
    private func envelope(_ plaintext: String, with cipher: Cipher) throws -> Data {
        let sealed = try MessageCryptor().seal(plaintext, with: cipher)
        return MessageEnvelope.wrap(sealed)
    }

    func testIngestEmbeddedCipherImportsDecryptsAndLinksNewContact() throws {
        let km = KeyManager.shared
        let cm = freshContactManager()
        let coordinator = MessageCoordinator(keyManager: km, contactManager: cm)

        let senderCipher = Cipher.generated(label: "Sender")
        let env = try envelope("rendezvous at dusk", with: senderCipher)
        let payload = MessageSharePayload(
            senderName: "Astrid",
            envelope: env,
            embeddedCipher: CipherSharePayload(cipher: senderCipher))
        let url = try payload.url()

        coordinator.ingest(url: url)

        XCTAssertNil(coordinator.errorMessage)
        let pending = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(pending.plaintext, "rendezvous at dusk")
        XCTAssertEqual(pending.senderName, "Astrid")

        let imported = try XCTUnwrap(km.ciphers.first { $0.keyMaterial == senderCipher.keyMaterial })
        XCTAssertEqual(imported.origin, .imported)
        XCTAssertEqual(pending.cipher.id, imported.id)

        let contact = try XCTUnwrap(cm.contacts.first { $0.displayName == "Astrid" })
        XCTAssertEqual(contact.source, .imported)
        XCTAssertEqual(km.ciphers(forContact: contact.id).map(\.id), [imported.id])
    }

    func testIngestNoEmbedDecryptsViaAlreadyStoredCipher() throws {
        let km = KeyManager.shared
        let cm = freshContactManager()
        let coordinator = MessageCoordinator(keyManager: km, contactManager: cm)

        let shared = try km.importCipher(CipherSharePayload(cipher: Cipher.generated(label: "Pre")),
                                         label: "Pre-shared")
        let env = try envelope("the eagle has landed", with: shared)
        let payload = MessageSharePayload(senderName: "Bjorn", envelope: env, embeddedCipher: nil)

        coordinator.ingest(url: try payload.url())

        XCTAssertNil(coordinator.errorMessage)
        let pending = try XCTUnwrap(coordinator.pending)
        XCTAssertEqual(pending.plaintext, "the eagle has landed")
        XCTAssertEqual(pending.cipher.id, shared.id)
        XCTAssertTrue(cm.contacts.contains { $0.displayName == "Bjorn" })
    }

    func testIngestJunkSetsErrorAndLeavesPendingNil() {
        let coordinator = MessageCoordinator(keyManager: .shared, contactManager: freshContactManager())
        coordinator.ingest(url: URL(string: "https://ravenforgesoftware.com/rune-scribe/m?v=1&p=not-base64!!")!)
        XCTAssertNil(coordinator.pending)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testIngestUndecryptableMessageSetsErrorAndLeavesPendingNil() throws {
        let coordinator = MessageCoordinator(keyManager: .shared, contactManager: freshContactManager())
        let stranger = Cipher.generated(label: "Stranger")
        let env = try envelope("you cannot read this", with: stranger)
        let payload = MessageSharePayload(senderName: "Ghost", envelope: env, embeddedCipher: nil)
        coordinator.ingest(url: try payload.url())
        XCTAssertNil(coordinator.pending)
        XCTAssertNotNil(coordinator.errorMessage)
    }

    func testSameURLIngestedTwiceIsDeduped() throws {
        let cm = freshContactManager()
        let coordinator = MessageCoordinator(keyManager: .shared, contactManager: cm)
        let cipher = Cipher.generated(label: "Dup")
        let env = try envelope("once only", with: cipher)
        let url = try MessageSharePayload(
            senderName: "Eira", envelope: env,
            embeddedCipher: CipherSharePayload(cipher: cipher)).url()

        coordinator.ingest(url: url)
        let firstPendingID = try XCTUnwrap(coordinator.pending).id
        let contactsAfterFirst = cm.contacts.count

        coordinator.ingest(url: url)   // duplicate delivery

        XCTAssertEqual(coordinator.pending?.id, firstPendingID)
        XCTAssertEqual(cm.contacts.count, contactsAfterFirst)
    }

    // MARK: - a key re-sent across distinct messages dedups by publicID and never hijacks active

    func testReingestingSameEmbeddedKeyDeduplicatesAndKeepsActiveCipher() throws {
        let km = KeyManager.shared
        let coordinator = MessageCoordinator(keyManager: km, contactManager: freshContactManager())

        // Establish a known active cipher the user is "composing with".
        let mine = try km.importCipher(CipherSharePayload(cipher: Cipher.generated(label: "Mine")), label: "Mine")
        XCTAssertEqual(km.activeCipher?.id, mine.id)

        // The same sender cipher embedded in two DISTINCT messages (different plaintext →
        // different URLs, so URL-level dedup doesn't apply; the publicID dedup is what's tested).
        let senderCipher = Cipher.generated(label: "Sender")
        let embed = CipherSharePayload(cipher: senderCipher)
        let url1 = try MessageSharePayload(senderName: "Astrid",
                                           envelope: try envelope("first", with: senderCipher),
                                           embeddedCipher: embed).url()
        let url2 = try MessageSharePayload(senderName: "Astrid",
                                           envelope: try envelope("second", with: senderCipher),
                                           embeddedCipher: embed).url()

        coordinator.ingest(url: url1)
        coordinator.ingest(url: url2)

        // Imported exactly once — a re-sent key must not pile up duplicates.
        XCTAssertEqual(km.ciphers.filter { $0.publicID == senderCipher.publicID }.count, 1)
        // Receiving messages must not change the cipher the user is composing with.
        XCTAssertEqual(km.activeCipher?.id, mine.id)
    }
}
