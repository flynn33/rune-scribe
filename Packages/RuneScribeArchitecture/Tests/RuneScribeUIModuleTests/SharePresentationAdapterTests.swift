import RuneScribeContracts
import RuneScribeUIRuntime
import XCTest

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

final class SharePresentationAdapterTests: XCTestCase {
    func testUtilityRouteMatrixNeverProducesEligibleCompletion() {
        let fileCases: [(FileExportTerminalResult, ShareRouteResultDTO)] = [
            (.saved, .completionUnavailable),
            (.cancelled, .cancelled),
            (.failed, .failed),
        ]

        for (input, expectedResult) in fileCases {
            let report = RuneScribeUtilityShareReportMapper.fileExport(input)
            XCTAssertEqual(report.routeClass, .fileExport)
            XCTAssertEqual(report.result, expectedResult)
            XCTAssertFalse(report.isEligibleTerminal(requiresKeyDelivery: false))
            XCTAssertFalse(report.isEligibleTerminal(requiresKeyDelivery: true))
        }

        let clipboard = RuneScribeUtilityShareReportMapper.clipboardCompletion
        XCTAssertEqual(clipboard.routeClass, .clipboard)
        XCTAssertEqual(clipboard.result, .completionUnavailable)
        XCTAssertFalse(clipboard.isEligibleTerminal(requiresKeyDelivery: false))

        let qr = RuneScribeUtilityShareReportMapper.qrDisplayCompletion
        XCTAssertEqual(qr.routeClass, .qrDisplay)
        XCTAssertEqual(qr.result, .completionUnavailable)
        XCTAssertFalse(qr.isEligibleTerminal(requiresKeyDelivery: false))
    }

    #if os(macOS)
    func testMacSystemShareMatrixClassifiesOnlyAuthoritativeAirDrop() throws {
        let airDrop = try XCTUnwrap(NSSharingService(named: .sendViaAirDrop))
        let messages = try XCTUnwrap(NSSharingService(named: .composeMessage))
        let titledImpostor = NSSharingService(
            title: "AirDrop",
            image: NSImage(size: NSSize(width: 1, height: 1)),
            alternateImage: nil
        ) {}

        XCTAssertEqual(
            RuneScribeMacSharingServiceReportMapper.routeClass(for: airDrop),
            .airDrop
        )
        XCTAssertEqual(
            RuneScribeMacSharingServiceReportMapper.routeClass(for: messages),
            .shareSheet
        )
        XCTAssertEqual(
            RuneScribeMacSharingServiceReportMapper.routeClass(for: titledImpostor),
            .shareSheet
        )
        XCTAssertEqual(
            RuneScribeMacSharingServiceReportMapper.routeClass(for: nil),
            .shareSheet
        )

        for (service, routeClass) in [
            (airDrop, ShareRouteClassDTO.airDrop),
            (messages, ShareRouteClassDTO.shareSheet),
        ] {
            for result in [
                ShareRouteResultDTO.completedBySystem,
                .cancelled,
                .failed,
            ] {
                let report = RuneScribeMacSharingServiceReportMapper.report(
                    for: service,
                    result: result
                )
                XCTAssertEqual(report.routeClass, routeClass)
                XCTAssertEqual(report.result, result)
                XCTAssertEqual(
                    report.isEligibleTerminal(requiresKeyDelivery: false),
                    result == .completedBySystem
                )
            }
        }
    }
    #endif

    #if os(iOS)
    func testIOSSystemShareMatrixRetainsAirDropRouteForEveryTerminal() {
        for (activityType, routeClass) in [
            (UIActivity.ActivityType.airDrop, ShareRouteClassDTO.airDrop),
            (UIActivity.ActivityType.mail, ShareRouteClassDTO.shareSheet),
        ] {
            let completed = RuneScribeActivityReportMapper.report(
                activityType: activityType,
                completed: true,
                error: nil
            )
            XCTAssertEqual(completed.routeClass, routeClass)
            XCTAssertEqual(completed.result, .completedBySystem)

            let cancelled = RuneScribeActivityReportMapper.report(
                activityType: activityType,
                completed: false,
                error: nil
            )
            XCTAssertEqual(cancelled.routeClass, routeClass)
            XCTAssertEqual(cancelled.result, .cancelled)

            let failed = RuneScribeActivityReportMapper.report(
                activityType: activityType,
                completed: false,
                error: AdapterFailure()
            )
            XCTAssertEqual(failed.routeClass, routeClass)
            XCTAssertEqual(failed.result, .failed)
        }
    }

    func testMessagesRouteMatrixPreservesAttachmentConfirmation() {
        let sentWithAttachment = MessageComposeReportMapper.report(
            for: .sent,
            requiredAttachmentWasPresent: true,
            requiredAttachmentAccepted: true
        )
        XCTAssertEqual(sentWithAttachment.routeClass, .messages)
        XCTAssertEqual(sentWithAttachment.result, .sentConfirmed)
        XCTAssertEqual(sentWithAttachment.requiredAttachmentAccepted, true)
        XCTAssertTrue(sentWithAttachment.isEligibleTerminal(requiresKeyDelivery: true))

        let sentWithoutAttachment = MessageComposeReportMapper.report(
            for: .sent,
            requiredAttachmentWasPresent: true,
            requiredAttachmentAccepted: false
        )
        XCTAssertEqual(sentWithoutAttachment.requiredAttachmentAccepted, false)
        XCTAssertFalse(sentWithoutAttachment.isEligibleTerminal(requiresKeyDelivery: true))

        for terminal in [
            MessageComposeTerminalResult.cancelled,
            .failed,
        ] {
            let report = MessageComposeReportMapper.report(
                for: terminal,
                requiredAttachmentWasPresent: true,
                requiredAttachmentAccepted: true
            )
            XCTAssertEqual(report.routeClass, .messages)
            XCTAssertFalse(report.isEligibleTerminal(requiresKeyDelivery: false))
        }
    }

    private struct AdapterFailure: Error {}
    #endif
}
