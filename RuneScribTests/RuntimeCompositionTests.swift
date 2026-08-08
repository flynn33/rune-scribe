import RuneScribeCoreModule
import RuneScribePlatform
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
        await composition.stop()
    }
}
