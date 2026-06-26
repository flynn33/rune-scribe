import XCTest
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
}
