import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeUIModule
import RuneScribeUIRuntime
import XCTest

final class ArchitectureIntegrationTests: XCTestCase {
    func testBundledSkeletonBootsNonUIBeforeExactlyOneUI() async throws {
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            platform: .macOS
        )

        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory()
        )
        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory()
        )

        try await runtime.start()
        let running = await runtime.snapshot()
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(
            running.activationOrder,
            [RuneScribeModuleIDs.core, RuneScribeModuleIDs.primaryUI]
        )
        XCTAssertEqual(running.activeUIModuleID, RuneScribeModuleIDs.primaryUI)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.core], .active)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.primaryUI], .active)

        await runtime.stop()
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.moduleStates[RuneScribeModuleIDs.core], .stopped)
        XCTAssertEqual(stopped.moduleStates[RuneScribeModuleIDs.primaryUI], .stopped)
    }

    func testProductDependencySurfacesRemainIndependentlyImportable() {
        XCTAssertEqual(RuneScribePlatformBoundary.contractVersion, 1)
        XCTAssertEqual(BootPresentationState.booting, .booting)
        XCTAssertEqual(RuneScribeCoreModuleBootstrap.moduleID, RuneScribeModuleIDs.core)
        XCTAssertEqual(RuneScribeUIModuleBootstrap.moduleID, RuneScribeModuleIDs.primaryUI)
    }
}
