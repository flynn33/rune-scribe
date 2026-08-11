import RuneScribeContracts
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
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
                RuneScribeServiceIDs.sharePresentation,
            ]
        )
        XCTAssertEqual(
            descriptor.consumedEndpoints,
            RuntimeApplicationEndpointCatalog.applicationEndpointIDs
        )
    }

    func testZeroArgumentFactoryCreatesFreshModulesOnDemand() throws {
        let factory = RuneScribeUIModuleBootstrap.factory()

        let first = try XCTUnwrap(factory.makeModule() as? RuneScribeUIModule)
        let second = try XCTUnwrap(factory.makeModule() as? RuneScribeUIModule)

        XCTAssertFalse(first === second)
        XCTAssertEqual(factory.descriptor, RuneScribeUIModuleBootstrap.descriptor)
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
        let vault = TestOpaqueLinkVault(artifactID: artifactID, link: link)
        let capture = TestSharePresentationClientCapture()
        let runtime = RuneScribeRuntime(
            runtimeVersion: TestSharePresentationModule.moduleVersion,
            platform: .macOS
        )
        try await runtime.installPlatformAdapter(
            vault,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.register(
            manifest: TestSharePresentationModule.manifest,
            factory: TestSharePresentationModule.factory(capture: capture)
        )
        try await runtime.start()

        let runtimeIO = try await capture.requireClient()
        let session = try await runtimeIO.sharePresentationSession(
            artifactID: artifactID
        )
        let transfer = try await OpaqueShareTransfer.open(
            artifactID: artifactID,
            session: session
        )
        XCTAssertEqual(transfer.artifactID, artifactID)
        XCTAssertNotNil(transfer.qrCodeImage())

        await vault.revoke()
        do {
            let revokedSession = try await runtimeIO.sharePresentationSession(
                artifactID: artifactID
            )
            _ = try await OpaqueShareTransfer.open(
                artifactID: artifactID,
                session: revokedSession
            )
            XCTFail("A revoked opaque link must not resolve again")
        } catch {
            XCTAssertEqual(error as? TestOpaqueLinkVault.Error, .unavailable)
        }

        await transfer.close()
        XCTAssertFalse(transfer.isAvailable)
        XCTAssertNil(transfer.qrCodeImage())
        await runtime.stop()
    }
}

private actor TestOpaqueLinkVault: SharePresentationProviding {
    enum Error: Swift.Error, Equatable { case unavailable }
    private let artifactID: ShareArtifactID
    private var link: URL?

    init(artifactID: ShareArtifactID, link: URL) {
        self.artifactID = artifactID
        self.link = link
    }

    func presentationURL(
        for requestedArtifactID: ShareArtifactID
    ) async throws -> URL {
        guard requestedArtifactID == artifactID, let link else {
            throw Error.unavailable
        }
        return link
    }

    func revoke() {
        link = nil
    }
}

private actor TestSharePresentationClientCapture {
    private var client: RuntimeIOClient?

    func store(_ client: RuntimeIOClient) {
        self.client = client
    }

    func requireClient() throws -> RuntimeIOClient {
        guard let client else { throw TestSharePresentationCaptureError.missingClient }
        return client
    }
}

private enum TestSharePresentationCaptureError: Error {
    case missingClient
}

private enum TestSharePresentationModule {
    static let moduleID: ModuleIdentifier = "com.runescribe.test.share-presentation"
    static let moduleVersion = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: moduleVersion,
        kind: .ui,
        entryPoint: "RuneScribeTestSharePresentationModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        requiredServices: [RuneScribeServiceIDs.sharePresentation]
    )
    static let manifest = ModuleManifest(
        runtimeVersion: moduleVersion,
        moduleID: moduleID,
        displayName: "Rune Scribe Test Share Presentation",
        moduleVersion: moduleVersion,
        moduleType: .ui,
        supportedPlatforms: [.iOS, .macOS],
        capabilitiesRequested: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: [RuneScribeServiceIDs.sharePresentation]
        ),
        defaultRole: RuneScribeRoles.primaryUI
    )

    static func factory(
        capture: TestSharePresentationClientCapture
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            TestSharePresentationModuleInstance(capture: capture)
        }
    }
}

private struct TestSharePresentationModuleInstance: RuneScribeModule {
    let descriptor = TestSharePresentationModule.descriptor
    let capture: TestSharePresentationClientCapture

    func start(context: ModuleContext) async throws {
        await capture.store(try await context.runtimeIOClient())
    }

    func stop() async {}
}
