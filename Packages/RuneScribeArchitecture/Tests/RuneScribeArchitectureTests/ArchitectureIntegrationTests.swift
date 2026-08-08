import Foundation
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
        try await registerHostPlatformServices(on: runtime)

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

    private func registerHostPlatformServices(
        on runtime: RuneScribeRuntime
    ) async throws {
        let secureValues: any SecureValueStore = InMemorySecureValueStore()
        let protectedFiles: any ProtectedFileStore = InMemoryProtectedFileStore()
        let resources: any ApplicationResourceLocator = MappedApplicationResourceLocator(
            locations: [:]
        )
        let fonts: any SystemFontRegistrar = InMemoryFontRegistrar(namesByData: [:])
        let contacts: any ContactAccessService = InMemoryContactAccessService()
        let clipboard = InMemoryClipboardService()
        let clipboardReader: any ClipboardReading = clipboard
        let clipboardWriter: any ClipboardWriting = clipboard
        let clock: any ClockProviding = FixedClock(.distantPast)
        let uuid: any UUIDProviding = FixedUUIDProvider(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )

        try await runtime.registerHostService(
            secureValues,
            for: RuneScribeServiceKeys.secureValueStore
        )
        try await runtime.registerHostService(
            protectedFiles,
            for: RuneScribeServiceKeys.protectedFileStore
        )
        try await runtime.registerHostService(
            resources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.registerHostService(
            fonts,
            for: RuneScribeServiceKeys.systemFontRegistrar
        )
        try await runtime.registerHostService(
            contacts,
            for: RuneScribeServiceKeys.contactAccess
        )
        try await runtime.registerHostService(
            clipboardReader,
            for: RuneScribeServiceKeys.clipboardRead
        )
        try await runtime.registerHostService(
            clipboardWriter,
            for: RuneScribeServiceKeys.clipboardWrite
        )
        try await runtime.registerHostService(clock, for: RuneScribeServiceKeys.clock)
        try await runtime.registerHostService(uuid, for: RuneScribeServiceKeys.uuid)
    }
}
