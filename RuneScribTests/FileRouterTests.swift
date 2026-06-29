import XCTest
@testable import RuneScrib

final class FileRouterTests: XCTestCase {

    /// A message file's leading version byte routes it to `.message`.
    func testClassifiesMessageVersionAsMessage() {
        let data = Data([MessageSharePayload.version, 0x00, 0x00])
        guard case .message(let d) = FileRouter.classify(data) else {
            return XCTFail("expected .message for leading 0x\(String(MessageSharePayload.version, radix: 16))")
        }
        XCTAssertEqual(d, data)
    }

    /// A cipher file's leading version byte routes it to `.cipher`.
    func testClassifiesCipherVersionAsCipher() {
        let data = Data([CipherSharePayload.version, 0x00, 0x00])
        guard case .cipher(let d) = FileRouter.classify(data) else {
            return XCTFail("expected .cipher for leading 0x\(String(CipherSharePayload.version, radix: 16))")
        }
        XCTAssertEqual(d, data)
    }

    func testClassifiesEmptyAsUnknown() {
        guard case .unknown = FileRouter.classify(Data()) else {
            return XCTFail("expected .unknown for empty data")
        }
    }

    func testClassifiesOtherLeadingByteAsUnknown() {
        guard case .unknown = FileRouter.classify(Data([0x7F, 0x01, 0x02])) else {
            return XCTFail("expected .unknown for an unrecognised leading byte")
        }
    }

    /// The classifier relies on the two version bytes being distinct; pin that invariant.
    func testMessageAndCipherVersionsAreDistinct() {
        XCTAssertNotEqual(MessageSharePayload.version, CipherSharePayload.version)
    }
}

extension FileRouterTests {
    // A tapped `.runescribe` MESSAGE file routed through `FileRouter.route(fileURL:)` — the exact
    // call the SceneDelegate / `.onOpenURL` make for an opened attachment — must reach
    // `MessageCoordinator` (NOT the cipher `ImportCoordinator`). With no matching cipher held,
    // MessageCoordinator surfaces an error rather than a pending import; that the error lands on
    // MessageCoordinator while ImportCoordinator stays untouched proves the message branch routed.
    // Complements `InboundFileRoutingTests`, which covers the tapped CIPHER file.
    @MainActor
    func testTappedMessageFileRoutesToMessageCoordinator() throws {
        MessageCoordinator.shared.pending = nil
        MessageCoordinator.shared.errorMessage = nil
        ImportCoordinator.shared.pending = nil
        ImportCoordinator.shared.errorMessage = nil

        // A well-formed message file (leading 0x01) for a cipher nobody holds, no embedded key.
        let stranger = Cipher.generated(label: "Stranger")
        let env = MessageEnvelope.wrap(try MessageCryptor().seal("you can't read this", with: stranger))
        let bytes = MessageSharePayload(senderName: "Tester", envelope: env, embeddedCipher: nil).encoded()
        XCTAssertEqual(bytes.first, MessageSharePayload.version, "a message file leads with the message version byte")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(RuneScribeShare.fileExtension)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        FileRouter.route(fileURL: url)

        XCTAssertNil(ImportCoordinator.shared.pending,
                     "a message file must NOT be handed to the cipher import coordinator")
        XCTAssertNotNil(MessageCoordinator.shared.errorMessage,
                        "the message routed to MessageCoordinator, which reports no-matching-cipher")
        XCTAssertNil(MessageCoordinator.shared.pending)
    }
}
