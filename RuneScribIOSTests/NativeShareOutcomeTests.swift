import CryptoKit
import Messages
import RuneScribeContracts
@_spi(RuntimeTesting) import RuneScribeUIRuntime
import UIKit
import XCTest

final class NativeShareOutcomeTests: XCTestCase {
    @MainActor
    func testInteractiveCipherMessageUsesArtworkURLAndVisibleFallbackBody() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 900)).image {
            UIColor.systemPurple.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 1_200, height: 900))
        }
        let PNG = try XCTUnwrap(image.pngData())
        let validURL = try messagesFixtureURL()

        let prepared = try RuneScribeInteractiveMessageFactory.make(
            invitationURL: validURL,
            cipherLabel: "Freyja",
            previewImageData: PNG
        )

        XCTAssertEqual(prepared.message.url, validURL)
        XCTAssertEqual(
            prepared.body,
            "Rune Scribe invitation fallback:\n\(validURL.absoluteString)"
        )
        let layout = try XCTUnwrap(
            prepared.message.layout as? MSMessageTemplateLayout
        )
        XCTAssertEqual(layout.image?.size, CGSize(width: 300, height: 225))
        XCTAssertEqual(layout.caption, "Rune Scribe cipher: Freyja")
        XCTAssertEqual(
            layout.subcaption,
            "Tap the artwork to continue in Rune Scribe."
        )
    }

    @MainActor
    func testInteractiveCipherMessageRejectsInvalidURLAndNonPNGArtwork() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image {
            UIColor.systemPurple.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let PNG = try XCTUnwrap(image.pngData())
        let invalidURL = try XCTUnwrap(URL(
            string: "https://example.com/?runescribe=import&v=3&p=fixture"
        ))
        XCTAssertThrowsError(
            try RuneScribeInteractiveMessageFactory.make(
                invitationURL: invalidURL,
                cipherLabel: "Freyja",
                previewImageData: PNG
            )
        )
        XCTAssertThrowsError(
            try RuneScribeInteractiveMessageFactory.make(
                invitationURL: messagesFixtureURL(),
                cipherLabel: "Freyja",
                previewImageData: Data([0x00, 0x01])
            )
        )
    }

    @MainActor
    func testCipherLinkShareSendsRenderedPNGAndTappableImportURLAsDistinctItems() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image {
            UIColor.systemPurple.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let png = try XCTUnwrap(image.pngData())
        let importURL = try XCTUnwrap(URL(
            string: "https://ravenforgesoftware.com/rune-scribe/"
                + "?runescribe=import&v=3&p=fixture"
        ))

        let items = RuneScribeIOSLinkActivityItemFactory.makeItems(
            url: importURL,
            previewTitle: "Rune Scribe cipher: Freya",
            previewSystemImage: "link",
            previewImageData: png,
            subject: "Rune Scribe cipher: Freya",
            message: "Tap to import this cipher."
        )

        let sharedImage = try XCTUnwrap(items.compactMap { $0 as? UIImage }.first)
        XCTAssertEqual(sharedImage.cgImage?.width, image.cgImage?.width)
        XCTAssertEqual(sharedImage.cgImage?.height, image.cgImage?.height)
        XCTAssertEqual(items.compactMap { $0 as? NSString }.map(String.init), [
            "Tap to import this cipher.",
        ])
        let linkSource = try XCTUnwrap(items.compactMap {
            $0 as? any UIActivityItemSource
        }.first)
        XCTAssertEqual(
            linkSource.activityViewController(
                UIActivityViewController(activityItems: [], applicationActivities: nil),
                itemForActivityType: .message
            ) as? URL,
            importURL
        )
    }

    @MainActor
    func testCipherLinkShareNeverSubstitutesInvalidImageBytesForImportURL() throws {
        let importURL = try XCTUnwrap(URL(
            string: "https://ravenforgesoftware.com/rune-scribe/"
                + "?runescribe=import&v=3&p=fixture"
        ))

        let items = RuneScribeIOSLinkActivityItemFactory.makeItems(
            url: importURL,
            previewTitle: "Rune Scribe cipher: Freya",
            previewSystemImage: "link",
            previewImageData: Data([0x00, 0x01]),
            subject: "Rune Scribe cipher: Freya",
            message: "Tap to import this cipher."
        )

        XCTAssertTrue(items.compactMap { $0 as? UIImage }.isEmpty)
        let linkSource = try XCTUnwrap(items.compactMap {
            $0 as? any UIActivityItemSource
        }.first)
        XCTAssertEqual(
            linkSource.activityViewController(
                UIActivityViewController(activityItems: [], applicationActivities: nil),
                itemForActivityType: .message
            ) as? URL,
            importURL
        )
    }

    func testMessageComposeAcceptsOnlyDecodablePNGPreviewAttachments() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3)).image {
            UIColor.systemIndigo.setFill()
            $0.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
        let png = try XCTUnwrap(image.pngData())

        XCTAssertEqual(
            RuneScribeMessagePreviewAttachment.validatedPNG(png),
            png
        )
        XCTAssertNil(
            RuneScribeMessagePreviewAttachment.validatedPNG(Data([0x00, 0x01]))
        )
    }

    func testActivityReportMapsTypedRouteAndCompletionStates() {
        let airDrop = RuneScribeActivityReportMapper.report(
            activityType: .airDrop,
            completed: true,
            error: nil
        )
        XCTAssertEqual(airDrop.routeClass, .airDrop)
        XCTAssertEqual(airDrop.result, .completedBySystem)

        let shareSheet = RuneScribeActivityReportMapper.report(
            activityType: .mail,
            completed: true,
            error: nil
        )
        XCTAssertEqual(shareSheet.routeClass, .shareSheet)
        XCTAssertEqual(shareSheet.result, .completedBySystem)

        let cancelled = RuneScribeActivityReportMapper.report(
            activityType: nil,
            completed: false,
            error: nil
        )
        XCTAssertEqual(cancelled.routeClass, .shareSheet)
        XCTAssertEqual(cancelled.result, .cancelled)

        let failed = RuneScribeActivityReportMapper.report(
            activityType: .airDrop,
            completed: true,
            error: FixtureError.failed
        )
        XCTAssertEqual(failed.routeClass, .airDrop)
        XCTAssertEqual(failed.result, .failed)
    }

    func testActivityCompletionGateSuppressesDisappearFallbackAfterCompletion() {
        var gate = RuneScribeActivityCompletionGate()

        let accepted = gate.accept(
            activityType: .airDrop,
            completed: true,
            error: nil
        )
        XCTAssertEqual(accepted?.routeClass, .airDrop)
        XCTAssertEqual(accepted?.result, .completedBySystem)
        XCTAssertNil(gate.accept(activityType: nil, completed: false, error: nil))
        XCTAssertTrue(gate.hasCompleted)
    }

    func testActivityCompletionGateAcceptsDisappearFallbackOnlyOnce() {
        var gate = RuneScribeActivityCompletionGate()

        let accepted = gate.accept(
            activityType: nil,
            completed: false,
            error: nil
        )
        XCTAssertEqual(accepted?.routeClass, .shareSheet)
        XCTAssertEqual(accepted?.result, .cancelled)
        XCTAssertNil(gate.accept(activityType: .airDrop, completed: true, error: nil))
        XCTAssertNil(
            gate.accept(
                activityType: .mail,
                completed: false,
                error: FixtureError.failed
            )
        )
        XCTAssertTrue(gate.hasCompleted)
    }
}

func messagesFixtureURL() throws -> URL {
    var payload = Data([3])
    payload.append(Data(repeating: 0x11, count: 8))
    payload.append(Data(repeating: 0x22, count: 32))
    payload.append(Data(0..<32))
    payload.append(Data("noto-sans-runic\0".utf8))
    payload.append(contentsOf: [0, 0, 0, 1])
    payload.append(Data(repeating: 0x33, count: 32))
    payload.append(Data(SHA256.hash(data: payload).prefix(4)))
    let encoded = payload.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return try XCTUnwrap(URL(
        string: "https://ravenforgesoftware.com/rune-scribe/"
            + "?runescribe=import&v=3&p=\(encoded)"
    ))
}

private enum FixtureError: Error {
    case failed
}
