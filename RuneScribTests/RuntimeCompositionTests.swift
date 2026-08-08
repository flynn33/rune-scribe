import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeUIRuntime
import XCTest
@testable import RuneScrib

@MainActor
final class RuntimeCompositionTests: XCTestCase {
    func testProductionCompositionStartsWithEveryRequiredHostService() async {
        let service = RuneScribeCoreApplicationService(
            secureValueStore: InMemorySecureValueStore(),
            shareArtifactStore: InMemoryShareArtifactStore(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider()
        )
        let composition = RuneScribeRuntimeComposition(
            bundle: .main,
            injectedApplicationService: service
        )

        await composition.start()

        XCTAssertFalse(composition.startupFailed)
        XCTAssertEqual(
            composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )
        await composition.stop()
        XCTAssertEqual(composition.rootPresentationStore.state, .booting)

        await composition.start()
        XCTAssertFalse(composition.startupFailed)
        XCTAssertEqual(
            composition.rootPresentationStore.state,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )
        await composition.stop()
    }
}
