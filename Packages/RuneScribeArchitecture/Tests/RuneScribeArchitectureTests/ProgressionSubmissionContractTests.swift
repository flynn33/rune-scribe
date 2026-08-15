import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
import XCTest

final class ProgressionSubmissionContractTests: XCTestCase {
    func testRuntimeOperationContextRejectsExtremeFiniteDateWithoutIntegerConversionTrap() {
        let extreme = Date(timeIntervalSince1970: Double(Int64.max))
        XCTAssertTrue(extreme.timeIntervalSince1970.isFinite)

        XCTAssertThrowsError(
            try RuntimePersistableOperationContext(
                operationID: "extreme-date-operation",
                correlationID: "10000000-0000-0000-0000-000000000001",
                occurredAtUTC: extreme,
                operationIdentifier: "application.encode",
                runtimeGeneration: 1,
                authorityNonce: UUID(
                    uuidString: "10000000-0000-0000-0000-000000000002"
                )!,
                authorityTag: Data(repeating: 1, count: 32),
                authorityScope: .persistent
            )
        ) { error in
            XCTAssertEqual(error as? RuntimeOperationContextError, .invalidContext)
        }
    }

    func testSharePresentationReportAcceptsExactlyTheRouteResultAndAttachmentMatrix() throws {
        for route in ShareRouteClassDTO.allCases {
            for result in ShareRouteResultDTO.allCases {
                for attachmentAccepted in [Bool?.none, true, false] {
                    let routeResultAccepted = accepts(route: route, result: result)
                    let attachmentAcceptedByContract = attachmentAccepted == nil
                        || (route == .messages && result == .sentConfirmed)
                    let shouldAccept = routeResultAccepted
                        && attachmentAcceptedByContract
                    do {
                        let report = try SharePresentationReportDTO(
                            routeClass: route,
                            result: result,
                            requiredAttachmentAccepted: attachmentAccepted
                        )
                        XCTAssertTrue(
                            shouldAccept,
                            "Unexpected valid combination: \(route.rawValue)/\(result.rawValue)/\(String(describing: attachmentAccepted))"
                        )
                        XCTAssertEqual(report.isTerminal, result != .presented)
                    } catch {
                        XCTAssertFalse(
                            shouldAccept,
                            "Unexpected invalid combination: \(route.rawValue)/\(result.rawValue)/\(String(describing: attachmentAccepted))"
                        )
                        XCTAssertEqual(
                            error as? ShareCompletionContractError,
                            routeResultAccepted
                                ? .invalidAttachmentEvidence
                                : .invalidRouteResult
                        )
                    }
                }
            }
        }
    }

    func testShareEligibilityRequiresConfirmedMessageAttachmentWhenKeyDeliveryIsRequired() throws {
        let accepted = try SharePresentationReportDTO(
            routeClass: .messages,
            result: .sentConfirmed,
            requiredAttachmentAccepted: true
        )
        let declined = try SharePresentationReportDTO(
            routeClass: .messages,
            result: .sentConfirmed,
            requiredAttachmentAccepted: false
        )
        let unknown = try SharePresentationReportDTO(
            routeClass: .messages,
            result: .sentConfirmed
        )

        XCTAssertTrue(accepted.isEligibleTerminal(requiresKeyDelivery: true))
        XCTAssertFalse(declined.isEligibleTerminal(requiresKeyDelivery: true))
        XCTAssertFalse(unknown.isEligibleTerminal(requiresKeyDelivery: true))
        XCTAssertTrue(unknown.isEligibleTerminal(requiresKeyDelivery: false))
    }

    private func accepts(
        route: ShareRouteClassDTO,
        result: ShareRouteResultDTO
    ) -> Bool {
        switch result {
        case .presented, .cancelled, .failed:
            true
        case .sentConfirmed:
            route == .messages
        case .completedBySystem:
            route == .shareSheet || route == .airDrop
        case .completionUnavailable:
            route == .fileExport || route == .clipboard || route == .qrDisplay
        }
    }
}
