import RuneScribeContracts
import RuneScribeRuntimeCore
@testable import RuneScribeThemeCoordinatorModule
import XCTest

final class ThemeCoordinatorModuleTests: XCTestCase {
    func testBootstrapUsesFrozenRuntimeIdentityAndEndpoints() {
        let descriptor = RuneScribeThemeCoordinatorModuleBootstrap.descriptor
        XCTAssertEqual(descriptor.moduleID, RuneScribeModuleIDs.themeCoordinator)
        XCTAssertEqual(descriptor.role, RuneScribeRoles.themeCoordinator)
        XCTAssertEqual(descriptor.policyClass, RuneScribePolicyClasses.themeCoordinator)
        XCTAssertEqual(
            descriptor.publishedEndpoints,
            RuntimeThemeEndpointCatalog.publishedEndpointIDs
        )
    }
}
