import RuneScribeContracts
import RuneScribeUIRuntime
import XCTest

final class NativeShareOutcomeTests: XCTestCase {
    func testActivityOutcomeMapsPublicCompletionStates() {
        XCTAssertEqual(
            RuneScribeActivityOutcomeMapper.outcome(completed: true, error: nil),
            .handedOff
        )
        XCTAssertEqual(
            RuneScribeActivityOutcomeMapper.outcome(completed: false, error: nil),
            .cancelled
        )
        XCTAssertEqual(
            RuneScribeActivityOutcomeMapper.outcome(
                completed: true,
                error: FixtureError.failed
            ),
            .failed
        )
        XCTAssertEqual(
            RuneScribeActivityOutcomeMapper.outcome(
                completed: false,
                error: FixtureError.failed
            ),
            .failed
        )
    }

    func testActivityCompletionGateSuppressesDisappearFallbackAfterCompletion() {
        var gate = RuneScribeActivityCompletionGate()

        XCTAssertEqual(gate.accept(completed: true, error: nil), .handedOff)
        XCTAssertNil(gate.accept(completed: false, error: nil))
        XCTAssertTrue(gate.hasCompleted)
    }

    func testActivityCompletionGateAcceptsDisappearFallbackOnlyOnce() {
        var gate = RuneScribeActivityCompletionGate()

        XCTAssertEqual(gate.accept(completed: false, error: nil), .cancelled)
        XCTAssertNil(gate.accept(completed: true, error: nil))
        XCTAssertNil(gate.accept(completed: false, error: FixtureError.failed))
        XCTAssertTrue(gate.hasCompleted)
    }
}

private enum FixtureError: Error {
    case failed
}
