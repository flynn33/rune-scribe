import RuneScribeContracts
import RuneScribeRuntimeCore
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
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
    }

    func testModuleProvidesExactlyOneRuntimePresentedRootContribution() throws {
        let module = RuneScribeUIModule(dependencies: dependencies())
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

        let contribution = RuneScribeUIModule(dependencies: dependencies()).rootContribution()
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

    private func dependencies() -> RuneScribeUIDependencies {
        RuneScribeUIDependencies(
            rootPresentationStore: RootViewPresentationStore()
        )
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
