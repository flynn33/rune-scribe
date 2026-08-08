import RuneScribeRuntimeCore
import RuneScribeUIModule
import RuneScribeUIRuntime
import XCTest

final class UIModuleTests: XCTestCase {
    func testBundledManifestMatchesFactoryDescriptor() throws {
        let manifest = try RuneScribeUIModuleBootstrap.manifest()
        let descriptor = RuneScribeUIModuleBootstrap.descriptor

        XCTAssertEqual(manifest.moduleID.rawValue, "com.runescribe.module.ui")
        XCTAssertEqual(manifest.moduleType, .ui)
        XCTAssertEqual(manifest.moduleID, descriptor.moduleID)
        XCTAssertEqual(manifest.moduleVersion, descriptor.moduleVersion)
        XCTAssertEqual(manifest.entryPoint, descriptor.entryPoint)
        XCTAssertEqual(Set(manifest.capabilitiesRequested), descriptor.requestedCapabilities)
        XCTAssertEqual(
            Set(manifest.runtimeRequirements.requiredModuleRoles),
            descriptor.requiredModuleRoles
        )
    }

    @MainActor
    func testSkeletonProvidesExactlyOneEmptyRootContribution() throws {
        let module = RuneScribeUIModule()
        let contribution = module.rootContribution()
        let selected = try RootContributionSelector.select(from: [contribution])

        XCTAssertEqual(selected.moduleID, RuneScribeUIModuleBootstrap.moduleID)
        _ = selected.makeView()
        _ = module.makeRootView()
    }

    func testRootContributionSelectorRejectsZeroAndMultiple() {
        XCTAssertThrowsError(try RootContributionSelector.select(from: [])) { error in
            XCTAssertEqual(error as? RootContributionError, RootContributionError.none)
        }

        let contribution = RuneScribeUIModule().rootContribution()
        XCTAssertThrowsError(
            try RootContributionSelector.select(from: [contribution, contribution])
        ) { error in
            XCTAssertEqual(
                error as? RootContributionError,
                .multiple([
                    RuneScribeUIModuleBootstrap.moduleID,
                    RuneScribeUIModuleBootstrap.moduleID,
                ])
            )
        }
    }
}
