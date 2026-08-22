import CoreGraphics
import CoreImage
import RuneScribeContracts
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
@testable import RuneScribeUIModule
@testable import RuneScribeUIRuntime
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
                RuneScribeServiceIDs.systemFontRegistrar,
            ]
        )
        XCTAssertEqual(
            descriptor.consumedEndpoints,
            RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
                RuntimeProgressionEndpointCatalog.UIEndpointIDs
            ).union(
                RuntimeThemeEndpointCatalog.UIEndpointIDs
            )
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

    func testQRCodeRoundTripsAcrossScaleCropNoiseAndContrastFixtures() throws {
        let payload = "runescribe://import?v=3&p="
            + "dGVzdC1jaXBoZXItcGF5bG9hZC13aXRoLWJvdW5kZWQtbm9pc2U"
        let detector = try XCTUnwrap(CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(options: [.useSoftwareRenderer: true]),
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        ))

        for scale: CGFloat in [4, 8, 12] {
            let image = try XCTUnwrap(RuntimeQRCodeRenderer.image(
                message: payload,
                scale: scale
            ))
            XCTAssertEqual(decodedMessage(in: image, detector: detector), payload)
        }

        let source = try XCTUnwrap(RuntimeQRCodeRenderer.image(
            message: payload,
            scale: 12
        ))
        let crop = CGRect(
            x: 2,
            y: 2,
            width: source.width - 4,
            height: source.height - 4
        )
        let cropped = try XCTUnwrap(source.cropping(to: crop))
        XCTAssertEqual(decodedMessage(in: cropped, detector: detector), payload)

        for noisePointCount in [8, 32] {
            let noisy = try deterministicNoise(
                on: source,
                pointCount: noisePointCount
            )
            XCTAssertEqual(decodedMessage(in: noisy, detector: detector), payload)
        }

        let highContrast = CIImage(cgImage: source).applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputContrastKey: 2.0,
                kCIInputSaturationKey: 0.0,
            ]
        )
        let highContrastImage = try XCTUnwrap(
            CIContext(options: [.useSoftwareRenderer: true]).createCGImage(
                highContrast,
                from: highContrast.extent
            )
        )
        XCTAssertEqual(decodedMessage(in: highContrastImage, detector: detector), payload)
    }

    private func decodedMessage(in image: CGImage, detector: CIDetector) -> String? {
        detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }

    private func deterministicNoise(
        on image: CGImage,
        pointCount: Int
    ) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        var state: UInt64 = 0x5255_4E45_5343_5249
        for index in 0 ..< pointCount {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let x = Int(state % UInt64(image.width))
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let y = Int(state % UInt64(image.height))
            context.setFillColor(CGColor(
                gray: index.isMultiple(of: 2) ? 0 : 1,
                alpha: 1
            ))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
        return try XCTUnwrap(context.makeImage())
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
        criticality: descriptor.criticality,
        supportedPlatforms: [.iOS, .macOS],
        capabilitiesRequested: [
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: [RuneScribeServiceIDs.sharePresentation]
        ),
        defaultRole: RuneScribeRoles.primaryUI,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted()
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
