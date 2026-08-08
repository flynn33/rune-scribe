import XCTest
@testable import RuneScrib

@MainActor
final class RuntimeCompositionTests: XCTestCase {
    func testProductionCompositionStartsWithEveryRequiredHostService() async {
        let composition = RuneScribeRuntimeComposition(bundle: .main)

        await composition.start()

        XCTAssertFalse(composition.startupFailed)
        await composition.stop()
    }
}
