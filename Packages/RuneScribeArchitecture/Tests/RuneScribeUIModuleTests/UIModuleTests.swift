import RuneScribeContracts
import RuneScribeRuntimeCore
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import SwiftUI
import XCTest

@MainActor
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
        XCTAssertEqual(
            Set(manifest.runtimeRequirements.requiredServices),
            descriptor.requiredServices
        )
        XCTAssertEqual(
            descriptor.requiredServices,
            [
                RuneScribeServiceIDs.applicationResourceLocator,
                RuneScribeServiceIDs.clipboardWrite,
            ]
        )
        XCTAssertEqual(
            descriptor.consumedEndpoints,
            RuntimeApplicationEndpointCatalog.applicationEndpointIDs
        )
    }

    func testFactoryCreatesFreshModulesOnDemandWithoutPresentingRoot() throws {
        let rootStore = RootViewPresentationStore()
        let factory = RuneScribeUIModuleBootstrap.factory(
            dependencies: RuneScribeUIDependencies(
                rootPresentationStore: rootStore
            )
        )

        XCTAssertEqual(rootStore.state, .booting)
        let first = try XCTUnwrap(factory.makeModule() as? RuneScribeUIModule)
        XCTAssertEqual(rootStore.state, .booting)
        let second = try XCTUnwrap(factory.makeModule() as? RuneScribeUIModule)

        XCTAssertFalse(first === second)
        XCTAssertEqual(rootStore.state, .booting)
    }

    func testRootContributionSelectorRejectsZeroAndMultiple() {
        XCTAssertThrowsError(try RootContributionSelector.select(from: [])) { error in
            XCTAssertEqual(error as? RootContributionError, RootContributionError.none)
        }

        let firstID: ModuleIdentifier = "com.runescribe.module.synthetic.first"
        let secondID: ModuleIdentifier = "com.runescribe.module.synthetic.second"
        let first = RootViewContribution(moduleID: firstID) { AnyView(EmptyView()) }
        let second = RootViewContribution(moduleID: secondID) { AnyView(EmptyView()) }
        XCTAssertThrowsError(
            try RootContributionSelector.select(from: [second, first])
        ) { error in
            XCTAssertEqual(
                error as? RootContributionError,
                .multiple([firstID, secondID])
            )
        }
    }

    func testOpaqueSharePresentationResolvesOnlyWhileLeased() async throws {
        let artifactID = ShareArtifactID(rawValue: UUID())
        let link = try XCTUnwrap(
            URL(string: "runescribe://import?v=3&p=synthetic")
        )
        let vault = TestOpaqueLinkVault(link: link)
        let provider = OpaqueSharePresentationProvider { requestedID in
            try await vault.load(requestedID)
        }

        let transfer = try await provider.transfer(for: artifactID)
        XCTAssertEqual(transfer.artifactID, artifactID)
        XCTAssertNotNil(transfer.qrCodeImage())

        await vault.revoke()
        do {
            _ = try await provider.transfer(for: artifactID)
            XCTFail("A revoked opaque link must not resolve again")
        } catch {
            XCTAssertEqual(error as? TestOpaqueLinkVault.Error, .unavailable)
        }
    }
}

private actor TestOpaqueLinkVault {
    enum Error: Swift.Error, Equatable { case unavailable }
    private var link: URL?

    init(link: URL) {
        self.link = link
    }

    func load(_ artifactID: ShareArtifactID) throws -> URL {
        guard let link else { throw Error.unavailable }
        return link
    }

    func revoke() {
        link = nil
    }
}
