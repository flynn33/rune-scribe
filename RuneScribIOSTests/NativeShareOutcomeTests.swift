import RuneScribeContracts
import RuneScribeUIRuntime
import XCTest

final class NativeShareOutcomeTests: XCTestCase {
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

private enum FixtureError: Error {
    case failed
}
