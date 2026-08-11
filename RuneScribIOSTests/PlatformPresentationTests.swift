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

    func testMessageComposeMapsSentCancelledAndFailedResults() {
        XCTAssertEqual(
            MessageComposeOutcomeMapper.outcome(
                for: .sent,
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: false
            ),
            .messageSent(requiredAttachmentAccepted: false)
        )
        XCTAssertEqual(
            MessageComposeOutcomeMapper.outcome(
                for: .cancelled,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            .cancelled
        )
        XCTAssertEqual(
            MessageComposeOutcomeMapper.outcome(
                for: .failed,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            .failed
        )
    }

    func testMessageComposeReportsRequiredAttachmentOnlyWhenComposerAcceptedIt() {
        XCTAssertEqual(
            MessageComposeOutcomeMapper.outcome(
                for: .sent,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            ),
            .messageSent(requiredAttachmentAccepted: true)
        )
        XCTAssertEqual(
            MessageComposeOutcomeMapper.outcome(
                for: .sent,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: false
            ),
            .messageSent(requiredAttachmentAccepted: false)
        )
        XCTAssertEqual(
            MessageComposeOutcomeMapper.outcome(
                for: .sent,
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: true
            ),
            .messageSent(requiredAttachmentAccepted: false)
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

    func testMessageComposeAttachmentSetupAllowsComposerWithoutRequiredAttachment() {
        XCTAssertEqual(
            MessageComposeAttachmentSetupPolicy.decide(
                requiredAttachmentWasPresent: false,
                requiredAttachmentAccepted: false
            ),
            .presentComposer(requiredAttachmentAccepted: false)
        )
    }

    func testMessageComposeCompletionGateEmitsOnlyFirstTerminalOutcome() {
        var gate = MessageComposeCompletionGate()

        XCTAssertEqual(gate.accept(.failed), .failed)
        XCTAssertNil(gate.accept(.messageSent(requiredAttachmentAccepted: true)))
        XCTAssertNil(gate.accept(.cancelled))
        XCTAssertTrue(gate.hasCompleted)
    }
}
