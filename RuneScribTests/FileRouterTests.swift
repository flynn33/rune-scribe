import XCTest
import CryptoKit
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

// MARK: - Route results are observable and failures are no longer silent (F-002 / AC-007, AC-008, AC-009, AC-010)

extension FileRouterTests {

    /// Clears both singleton coordinators so a test starts from a known state and the
    /// content-hash dedupe (which only skips when a matching item is still `pending`) never
    /// interferes.
    @MainActor
    private func resetCoordinators() {
        ImportCoordinator.shared.pending = nil
        ImportCoordinator.shared.errorMessage = nil
        MessageCoordinator.shared.pending = nil
        MessageCoordinator.shared.errorMessage = nil
    }

    /// Unknown leading bytes used to be a silent no-op; now they return `.unknown` and set a
    /// user-visible error rather than leaving the app looking like nothing happened.
    @MainActor
    func testRouteUnknownBytesReturnsUnknownAndSetsError() {
        resetCoordinators()
        let result = FileRouter.route(Data([0x7F, 0x01, 0x02]))
        XCTAssertEqual(result, .unknown)
        XCTAssertNotNil(ImportCoordinator.shared.errorMessage,
                        "an unrecognised file must surface a visible error")
        XCTAssertNil(ImportCoordinator.shared.pending)
    }

    /// Empty bytes classify as unknown and must also surface an error, not vanish.
    @MainActor
    func testRouteEmptyDataReturnsUnknownAndSetsError() {
        resetCoordinators()
        let result = FileRouter.route(Data())
        XCTAssertEqual(result, .unknown)
        XCTAssertNotNil(ImportCoordinator.shared.errorMessage)
    }

    /// A file URL whose bytes can't be read returns `.unreadable` and surfaces an error,
    /// instead of the previous silent early-return.
    @MainActor
    func testRouteUnreadableFileURLReturnsUnreadableAndSetsError() {
        resetCoordinators()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(RuneScribeShare.fileExtension)
        let result = FileRouter.route(fileURL: missing)
        XCTAssertEqual(result, .unreadable)
        XCTAssertNotNil(ImportCoordinator.shared.errorMessage,
                        "an unreadable file must surface a visible error")
    }

    /// A valid cipher file returns `.routedCipher`, reaches the cipher `ImportCoordinator`
    /// (pending set for confirmation), and never touches `MessageCoordinator`.
    @MainActor
    func testRouteCipherFileReturnsRoutedCipherAndSurfacesPending() {
        resetCoordinators()
        let bytes = CipherSharePayload(cipher: .generated(label: "RouteTest")).encoded()
        XCTAssertEqual(bytes.first, CipherSharePayload.version, "a cipher file leads with the cipher version byte")

        let result = FileRouter.route(bytes)

        XCTAssertEqual(result, .routedCipher)
        XCTAssertNotNil(ImportCoordinator.shared.pending, "a cipher file surfaces a pending import")
        XCTAssertNil(ImportCoordinator.shared.errorMessage)
        XCTAssertNil(MessageCoordinator.shared.pending, "a cipher file must not reach the message coordinator")
    }

    /// A valid message file returns `.routedMessage` — routing happened even when the
    /// message can't be decrypted (that's the coordinator's concern) — and never sets a
    /// pending cipher import.
    @MainActor
    func testRouteMessageFileReturnsRoutedMessage() throws {
        resetCoordinators()
        let stranger = Cipher.generated(label: "Stranger")
        let env = MessageEnvelope.wrap(try MessageCryptor().seal("unreadable", with: stranger))
        let bytes = MessageSharePayload(senderName: "Tester", envelope: env, embeddedCipher: nil).encoded()

        let result = FileRouter.route(bytes)

        XCTAssertEqual(result, .routedMessage)
        XCTAssertNil(ImportCoordinator.shared.pending, "a message file must not reach the cipher import coordinator")
    }
}

// MARK: - Canonical inbound-open router (F-001 / AC-002, AC-006)

final class InboundOpenRouterTests: XCTestCase {

    func testFileURLTargetsFileRoute() throws {
        let url = URL(fileURLWithPath: "/tmp/example.\(RuneScribeShare.fileExtension)")
        XCTAssertEqual(InboundOpenRouter.target(for: url), .file(url))
    }

    func testCustomSchemeURLTargetsLinkRoute() throws {
        let url = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=AAAA"))
        XCTAssertEqual(InboundOpenRouter.target(for: url), .link(url))
    }

    /// A legacy https import link is a non-file URL, so it targets the link route (where
    /// LinkRouter then recognises it as a cipher import).
    func testLegacyHTTPSURLTargetsLinkRoute() throws {
        let url = try XCTUnwrap(URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAAA"))
        XCTAssertEqual(InboundOpenRouter.target(for: url), .link(url))
    }

    /// A batch of URLs is classified in a stable, input order — the scene delegate hands
    /// several URL contexts through in one call.
    func testTargetsPreserveOrder() throws {
        let file = URL(fileURLWithPath: "/tmp/a.\(RuneScribeShare.fileExtension)")
        let link = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=AAAA"))
        XCTAssertEqual(InboundOpenRouter.targets(for: [file, link]),
                       [.file(file), .link(link)])
        XCTAssertEqual(InboundOpenRouter.targets(for: []), [], "an empty batch is a safe no-op")
    }

    func testBrowsingUserActivityWithURLTargetsLink() throws {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        let url = try XCTUnwrap(URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAAA"))
        activity.webpageURL = url
        XCTAssertEqual(InboundOpenRouter.target(for: activity), .link(url))
    }

    func testNonBrowsingUserActivityHasNoTarget() {
        let activity = NSUserActivity(activityType: "com.runescribe.other")
        activity.webpageURL = URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAAA")
        XCTAssertNil(InboundOpenRouter.target(for: activity))
    }

    func testBrowsingUserActivityWithoutURLHasNoTarget() {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        XCTAssertNil(InboundOpenRouter.target(for: activity))
    }
}
