import XCTest
import CryptoKit
@testable import RuneScrib

final class MessageSendTests: XCTestCase {

    // includeKey iff the cipher is contact-linked AND not yet delivered.
    func testShouldIncludeKeyTruthTable() throws {
        let contactID = UUID()

        var linkedUndelivered = Cipher.generated(label: "A")
        linkedUndelivered.contactID = contactID
        XCTAssertTrue(MessageSend.shouldIncludeKey(linkedUndelivered))

        var linkedDelivered = Cipher.generated(label: "B")
        linkedDelivered.contactID = contactID
        linkedDelivered.delivered = true
        XCTAssertFalse(MessageSend.shouldIncludeKey(linkedDelivered))

        let unlinked = Cipher.generated(label: "C")  // contactID nil, delivered false
        XCTAssertFalse(MessageSend.shouldIncludeKey(unlinked))
    }
}

extension MessageSendTests {

    // The envelope inside the payload must decrypt back to the original plaintext
    // under the same cipher (MessageSend.payload is exactly the inverse of compose).
    func testPayloadEnvelopeRoundTripsPlaintext() throws {
        let cipher = Cipher.generated(label: "RT")
        let plaintext = "meet at the standing stones ᛥ"
        let runes = try MessageService().compose(plaintext, with: cipher)

        let payload = try MessageSend.payload(runes: runes,
                                              senderName: "Freya",
                                              cipher: cipher,
                                              includeKey: false)

        let (decoded, used) = try MessageService().read(envelope: payload.envelope,
                                                        tryingCiphers: [cipher])
        XCTAssertEqual(decoded, plaintext)
        XCTAssertEqual(used.id, cipher.id)
    }

    // embeddedCipher present iff includeKey, and it carries this cipher's key material.
    func testPayloadEmbedsCipherOnlyWhenIncludeKey() throws {
        let cipher = Cipher.generated(label: "Embed")
        let runes = try MessageService().compose("hi", with: cipher)

        let without = try MessageSend.payload(runes: runes, senderName: "S",
                                              cipher: cipher, includeKey: false)
        XCTAssertNil(without.embeddedCipher)

        let with = try MessageSend.payload(runes: runes, senderName: "S",
                                           cipher: cipher, includeKey: true)
        XCTAssertNotNil(with.embeddedCipher)
        XCTAssertEqual(with.embeddedCipher?.keyMaterial, cipher.keyMaterial)
        XCTAssertEqual(with.embeddedCipher?.publicID, cipher.publicID)
    }

    // fileData is the file form of payload(...). A bundled-font cipher never appends font
    // bytes, so the file form equals the bare encoded payload and decodes back cleanly.
    func testFileDataMatchesEncodedPayloadForBundledFont() throws {
        let cipher = Cipher.generated(label: "File")   // fontRef == .bundled
        XCTAssertEqual(cipher.fontRef, .bundled)
        let runes = try MessageService().compose("hi there", with: cipher)

        let file = try MessageSend.fileData(runes: runes, senderName: "Freya",
                                            cipher: cipher, includeKey: true)
        let expected = try MessageSend.payload(runes: runes, senderName: "Freya",
                                               cipher: cipher, includeKey: true).encoded()
        XCTAssertEqual(file, expected, "bundled font must not be appended")

        let (back, fontBytes) = try MessageSharePayload.decodeFile(file)
        XCTAssertEqual(back.senderName, "Freya")
        XCTAssertNil(fontBytes)
        XCTAssertEqual(back.embeddedCipher?.keyMaterial, cipher.keyMaterial)
    }
}

extension MessageSendTests {
    // A cipher whose font is NOT the bundled one rides its font bytes along ONLY on the first
    // (key-bearing) message; a keyless follow-up file carries no font. Pins the
    // `(includeKey && cipher.fontRef != .bundled)` branch of MessageSend.fileData, which the
    // bundled-font test cannot reach.
    func testFileDataAppendsCustomFontBytesOnlyWithKey() throws {
        // Register a non-bundled font: reuse the real bundled font bytes under a custom ref so
        // FontStore validates and stores them (valid font + matching hash).
        let fontData = FontRef.bundledFontData()
        XCTAssertFalse(fontData.isEmpty, "bundled font bytes must be available for this test")
        let customRef = FontRef(id: "custom-test", version: 1,
                                sha256: Data(SHA256.hash(data: fontData)))
        XCTAssertNotEqual(customRef, .bundled)
        try FontStore.shared.importFont(fontData, expecting: customRef)

        // A cipher that references the custom (non-bundled) font.
        let g = Cipher.generated(label: "Custom")
        let cipher = Cipher(label: "Custom", origin: .generated, publicID: g.publicID,
                            keyMaterial: g.keyMaterial, decorativeMapping: g.decorativeMapping,
                            fontRef: customRef)
        XCTAssertNotEqual(cipher.fontRef, .bundled)
        let runes = try MessageService().compose("meet at dawn", with: cipher)

        // First message (key included) → the custom font's bytes are appended.
        let withKey = try MessageSend.fileData(runes: runes, senderName: "S",
                                               cipher: cipher, includeKey: true)
        let (p1, fontBytes) = try MessageSharePayload.decodeFile(withKey)
        XCTAssertEqual(fontBytes, fontData, "the non-bundled font rides the first key-bearing message")
        XCTAssertEqual(p1.embeddedCipher?.keyMaterial, cipher.keyMaterial)

        // Follow-up (no key) → no font bytes appended.
        let noKey = try MessageSend.fileData(runes: runes, senderName: "S",
                                             cipher: cipher, includeKey: false)
        let (p2, none) = try MessageSharePayload.decodeFile(noKey)
        XCTAssertNil(none, "a keyless follow-up file carries no font bytes")
        XCTAssertNil(p2.embeddedCipher)
    }
}
