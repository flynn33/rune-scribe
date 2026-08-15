import RuneScribeCoreModule
import RuneScribeContracts
import RuneScribeRuntimeCore
import XCTest

final class CoreModuleTests: XCTestCase {
    func testBundledManifestMatchesFactoryDescriptor() throws {
        let manifest = try RuneScribeCoreModuleBootstrap.manifest()
        let descriptor = RuneScribeCoreModuleBootstrap.descriptor

        XCTAssertEqual(manifest.moduleID.rawValue, "com.runescribe.module.core")
        XCTAssertEqual(manifest.moduleType, .service)
        XCTAssertEqual(manifest.moduleID, descriptor.moduleID)
        XCTAssertEqual(manifest.moduleVersion, descriptor.moduleVersion)
        XCTAssertEqual(manifest.entryPoint, descriptor.entryPoint)
        XCTAssertEqual(Set(manifest.capabilitiesRequested), descriptor.requestedCapabilities)
        XCTAssertEqual(
            Set(manifest.runtimeRequirements.requiredServices),
            descriptor.requiredServices
        )
        XCTAssertTrue(descriptor.publishedServices.isEmpty)
        XCTAssertFalse(
            descriptor.requestedCapabilities.contains(RuneScribeCapabilities.publishService)
        )
        XCTAssertTrue(
            descriptor.requestedCapabilities.contains(
                RuneScribeCapabilities.progressionEventSubmit
            )
        )
        XCTAssertTrue(
            descriptor.requestedCapabilities.contains(
                RuneScribeCapabilities.progressionMigrationSubmit
            )
        )
        XCTAssertEqual(
            descriptor.publishedEndpoints,
            RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
                RuntimeApplicationEndpointCatalog.ingressEndpointIDs
            )
        )
    }
}
