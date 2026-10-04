import AVFoundation
import RuneScribeContracts
import RuneScribeUIRuntime
@testable import RuneScribeUIModule
import XCTest

final class PlatformPresentationTests: XCTestCase {
    func testQRPermissionMappingCoversReadyRequestAndDeniedStates() {
        XCTAssertEqual(QRScannerPermissionAction.resolve(.authorized), .ready)
        XCTAssertEqual(QRScannerPermissionAction.resolve(.notDetermined), .requestAccess)
        XCTAssertEqual(QRScannerPermissionAction.resolve(.denied), .denied)
        XCTAssertEqual(QRScannerPermissionAction.resolve(.restricted), .denied)
    }

    func testQRCancelCompletesOnceAndRejectsLaterScanHandoff() {
        var gate = QRScannerCompletionGate()

        XCTAssertEqual(gate.accept(.cancelled), .cancelled)
        XCTAssertNil(gate.accept(.scanned("runescribe://import?p=late")))
        XCTAssertTrue(gate.hasCompleted)
    }

    func testQRScanHandsOffFirstPayloadAndRejectsDuplicatesOrCancellation() {
        var gate = QRScannerCompletionGate()
        let first = "runescribe://import?p=first"

        XCTAssertEqual(gate.accept(.scanned(first)), .scanned(first))
        XCTAssertNil(gate.accept(.scanned("runescribe://import?p=duplicate")))
        XCTAssertNil(gate.accept(.cancelled))
        XCTAssertTrue(gate.hasCompleted)
    }

    func testMessageComposeMapsSentCancelledAndFailedResults() throws {
        XCTAssertEqual(
            MessageComposeReportMapper.report(
                for: .sent,
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: false
            ),
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: false
            )
        )
        XCTAssertEqual(
            MessageComposeReportMapper.report(
                for: .cancelled,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .cancelled
            )
        )
        XCTAssertEqual(
            MessageComposeReportMapper.report(
                for: .failed,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .failed
            )
        )
    }

    func testMessageComposeReportsRequiredAttachmentOnlyWhenComposerAcceptedIt() throws {
        XCTAssertEqual(
            MessageComposeReportMapper.report(
                for: .sent,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            )
        )
        XCTAssertEqual(
            MessageComposeReportMapper.report(
                for: .sent,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: false
            ),
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: false
            )
        )
        XCTAssertEqual(
            MessageComposeReportMapper.report(
                for: .sent,
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: true
            ),
            try SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: false
            )
        )
    }

    func testMessageComposeAttachmentSetupAllowsAcceptedRequiredAttachment() {
        XCTAssertEqual(
            MessageComposeAttachmentSetupPolicy.decide(
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            .presentComposer(requiredAttachmentAccepted: true)
        )
    }

    func testMessageComposeAttachmentSetupFailsRejectedRequiredAttachment() {
        XCTAssertEqual(
            MessageComposeAttachmentSetupPolicy.decide(
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: false
            ),
            .fail
        )
    }

    func testMessageComposeAttachmentSetupRejectsMissingArtwork() {
        XCTAssertEqual(
            MessageComposeAttachmentSetupPolicy.decide(
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: false
            ),
            .fail
        )
    }

    func testMessageComposeCompletionGateEmitsOnlyFirstTerminalOutcome() {
        var gate = MessageComposeCompletionGate()

        let failed = MessageComposeReportMapper.report(
            for: .failed,
            requiredAttachmentWasPresent: true,
            requiredAttachmentAccepted: true
        )
        let sent = MessageComposeReportMapper.report(
            for: .sent,
            requiredAttachmentWasPresent: true,
            requiredAttachmentAccepted: true
        )
        let cancelled = MessageComposeReportMapper.report(
            for: .cancelled,
            requiredAttachmentWasPresent: true,
            requiredAttachmentAccepted: true
        )

        XCTAssertEqual(gate.accept(failed), failed)
        XCTAssertNil(gate.accept(sent))
        XCTAssertNil(gate.accept(cancelled))
        XCTAssertTrue(gate.hasCompleted)
    }
}
