import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import XCTest
@testable import RuneScrib

final class FileRouterTests: XCTestCase {
    func testClassifiesMessageVersionAsMessage() {
        XCTAssertEqual(
            FileRouter.classify(Data([UInt8(RuneScribeWireFormat.messageVersion), 0, 0])),
            .message
        )
    }

    func testClassifiesCipherVersionAsCipher() {
        XCTAssertEqual(
            FileRouter.classify(Data([UInt8(RuneScribeWireFormat.cipherVersion), 0, 0])),
            .cipher
        )
    }

    func testClassifiesEmptyAndUnknownVersionsAsUnknown() {
        XCTAssertEqual(FileRouter.classify(Data()), .unknown)
        XCTAssertEqual(FileRouter.classify(Data([0x7F, 0x01, 0x02])), .unknown)
    }

    func testMessageAndCipherVersionsAreDistinct() {
        XCTAssertNotEqual(
            RuneScribeWireFormat.messageVersion,
            RuneScribeWireFormat.cipherVersion
        )
    }

    @MainActor
    func testRouteUnknownFileReturnsUnknownAndSetsVisibleError() throws {
        let coordinator = makeCoordinator()
        let url = try temporaryFile(bytes: [0x7F, 0x01, 0x02])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(FileRouter.route(fileURL: url, coordinator: coordinator), .unknown)
        XCTAssertNotNil(coordinator.errorMessage)
        XCTAssertNil(coordinator.pending)
    }

    @MainActor
    func testRouteUnreadableFileReturnsUnreadableAndSetsVisibleError() {
        let coordinator = makeCoordinator()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(RuneScribeShare.fileExtension)

        XCTAssertEqual(
            FileRouter.route(fileURL: missing, coordinator: coordinator),
            .unreadable
        )
        XCTAssertNotNil(coordinator.errorMessage)
    }

    @MainActor
    func testRecognizedCipherAndMessageFilesReturnObservableRoutes() throws {
        let coordinator = makeCoordinator()
        let cipherURL = try temporaryFile(
            bytes: [UInt8(RuneScribeWireFormat.cipherVersion), 0, 0]
        )
        let messageURL = try temporaryFile(
            bytes: [UInt8(RuneScribeWireFormat.messageVersion), 0, 0]
        )
        defer {
            try? FileManager.default.removeItem(at: cipherURL)
            try? FileManager.default.removeItem(at: messageURL)
        }

        XCTAssertEqual(
            FileRouter.route(fileURL: cipherURL, coordinator: coordinator),
            .routedCipher
        )
        XCTAssertEqual(
            FileRouter.route(fileURL: messageURL, coordinator: coordinator),
            .routedMessage
        )
    }

    @MainActor
    private func makeCoordinator() -> ImportCoordinator {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
        return ImportCoordinator(keyManager: KeyManager(service: service))
    }

    private func temporaryFile(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(RuneScribeShare.fileExtension)
        try Data(bytes).write(to: url)
        return url
    }
}

final class InboundOpenRouterTests: XCTestCase {
    func testFileURLTargetsFileRoute() {
        let url = URL(fileURLWithPath: "/tmp/example.\(RuneScribeShare.fileExtension)")
        XCTAssertEqual(InboundOpenRouter.target(for: url), .file(url))
    }

    func testCustomAndLegacyURLsTargetLinkRoute() throws {
        let custom = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=AAAA"))
        let legacy = try XCTUnwrap(
            URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAAA")
        )
        XCTAssertEqual(InboundOpenRouter.target(for: custom), .link(custom))
        XCTAssertEqual(InboundOpenRouter.target(for: legacy), .link(legacy))
    }

    func testTargetsPreserveInputOrder() throws {
        let file = URL(fileURLWithPath: "/tmp/a.\(RuneScribeShare.fileExtension)")
        let link = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=AAAA"))
        XCTAssertEqual(
            InboundOpenRouter.targets(for: [file, link]),
            [.file(file), .link(link)]
        )
        XCTAssertEqual(InboundOpenRouter.targets(for: []), [])
    }

    func testBrowsingActivityRequiresWebURL() throws {
        let browsing = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        let url = try XCTUnwrap(
            URL(string: "https://ravenforgesoftware.com/rune-scribe/import?v=3&p=AAAA")
        )
        browsing.webpageURL = url
        XCTAssertEqual(InboundOpenRouter.target(for: browsing), .link(url))

        let missingURL = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        XCTAssertNil(InboundOpenRouter.target(for: missingURL))

        let unrelated = NSUserActivity(activityType: "com.runescribe.other")
        unrelated.webpageURL = url
        XCTAssertNil(InboundOpenRouter.target(for: unrelated))
    }
}
