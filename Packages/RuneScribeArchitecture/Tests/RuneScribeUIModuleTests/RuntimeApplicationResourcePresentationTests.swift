import Foundation
import RuneScribeContracts
@_spi(RuntimeResourceHost) @testable import RuneScribeRuntimeCore
@testable import RuneScribeUIRuntime
import XCTest

@MainActor
final class RuntimeApplicationResourcePresentationTests: XCTestCase {
    func testSplashPresentationAcquiresLazilyAndFinishesExactlyOnce() async throws {
        let fixture = try await makeFixture(resource: .splashVideo)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: fixture.session,
            metalLibrary: nil
        )
        var finishCount = 0

        var state = await fixture.provider.state()
        XCTAssertTrue(state.urlRequests.isEmpty)
        let initialBindingCount = await fixture.gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(initialBindingCount, 0)

        await presentation.startSplash {
            finishCount += 1
        }

        XCTAssertTrue(presentation.splashIsActive)
        XCTAssertNotNil(presentation.splashPlayer)
        state = await fixture.provider.state()
        XCTAssertEqual(state.urlRequests, [.splashVideo])
        let acquiredBindingCount = await fixture.gateway
            .activeApplicationResourceBindingCount()
        XCTAssertEqual(acquiredBindingCount, 1)

        presentation.finishSplash()
        presentation.finishSplash()

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(presentation.splashIsActive)
        XCTAssertNil(presentation.splashPlayer)
        let bindingClosed = await bindingCountEventuallyEquals(
            0,
            on: fixture.gateway
        )
        XCTAssertTrue(bindingClosed)
    }

    func testSourceRevocationStopsSplashAndNotifiesOnce() async throws {
        let fixture = try await makeFixture(resource: .splashVideo)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: fixture.session,
            metalLibrary: nil
        )
        var finishCount = 0
        await presentation.startSplash {
            finishCount += 1
        }

        await fixture.gateway.invalidateModule(
            fixture.descriptor.moduleID,
            generation: fixture.moduleGeneration
        )

        let presentationRevoked = await conditionEventually {
            finishCount == 1 && presentation.splashPlayer == nil
        }
        XCTAssertTrue(presentationRevoked)
        XCTAssertEqual(finishCount, 1)
        let bindingCount = await fixture.gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testCloseReleasesSplashLeaseWithoutReportingCompletion() async throws {
        let fixture = try await makeFixture(resource: .splashVideo)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: fixture.session,
            metalLibrary: nil
        )
        var finishCount = 0
        await presentation.startSplash {
            finishCount += 1
        }

        await presentation.close()

        XCTAssertEqual(finishCount, 0)
        XCTAssertFalse(presentation.hasSplashVideo)
        XCTAssertNil(presentation.splashPlayer)
        let bindingCount = await fixture.gateway.activeApplicationResourceBindingCount()
        XCTAssertEqual(bindingCount, 0)
    }

    func testMissingSplashSessionFinishesWithoutCreatingNativeState() async {
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: nil
        )
        var finishCount = 0

        await presentation.startSplash {
            finishCount += 1
        }

        XCTAssertEqual(finishCount, 1)
        XCTAssertFalse(presentation.hasSplashVideo)
        XCTAssertNil(presentation.splashPlayer)
        XCTAssertNil(presentation.metalResource)
    }

    func testInvalidMetalLibraryClosesLeaseAndDegradesToStaticState() async throws {
        let fixture = try await makeFixture(resource: .defaultMetalLibrary)
        let presentation = RuntimeApplicationResourcePresentation(
            splashVideo: nil,
            metalLibrary: fixture.session
        )

        await presentation.startMetal()

        XCTAssertNil(presentation.metalResource)
        let bindingClosed = await bindingCountEventuallyEquals(
            0,
            on: fixture.gateway
        )
        XCTAssertTrue(bindingClosed)
        let state = await fixture.provider.state()
        XCTAssertEqual(state.urlRequests, [.defaultMetalLibrary])
    }
}

private struct ResourcePresentationFixture {
    let gateway: RuntimeIOGateway
    let provider: ResourcePresentationProbe
    let descriptor: ModuleDescriptor
    let moduleGeneration: UInt64
    let session: RuntimeApplicationResourceSession
}

private struct ResourcePresentationProbeState: Equatable, Sendable {
    let urlRequests: [ApplicationResource]
}

private actor ResourcePresentationProbe: ApplicationResourceLocator {
    private let url: URL
    private var urlRequests: [ApplicationResource] = []

    init(url: URL) {
        self.url = url
    }

    func data(for resource: ApplicationResource) async throws -> Data {
        Data()
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        urlRequests.append(resource)
        return url
    }

    func state() -> ResourcePresentationProbeState {
        ResourcePresentationProbeState(urlRequests: urlRequests)
    }
}

private func makeFixture(
    resource: ApplicationResource
) async throws -> ResourcePresentationFixture {
    let provider = ResourcePresentationProbe(
        url: URL(fileURLWithPath: "/tmp/runescribe-runtime-resource-fixture")
    )
    let gateway = RuntimeIOGateway(policy: .patternBFoundation)
    await gateway.install(provider)
    let runtimeGeneration = await gateway.activateRuntime()
    let descriptor = ModuleDescriptor(
        moduleID: "com.runescribe.test.ui-runtime-resource-presentation",
        moduleVersion: SemanticVersion(
            major: UInt(1),
            minor: UInt(0),
            patch: UInt(34)
        ),
        kind: .ui,
        entryPoint: "RuntimeApplicationResourcePresentationTestModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [RuneScribeCapabilities.resourceRead],
        requiredServices: [RuneScribeServiceIDs.applicationResourceLocator],
        requiredResources: [resource],
        publishedServices: [],
        requiredModuleRoles: [],
        consumedEndpoints: [],
        publishedEndpoints: []
    )
    let moduleGeneration = UInt64(1)
    try await gateway.activateModule(
        descriptor: descriptor,
        generation: moduleGeneration
    )
    let client = try await gateway.makeClient(
        sourceModuleID: descriptor.moduleID,
        sourceModuleGeneration: moduleGeneration,
        runtimeGeneration: runtimeGeneration
    )
    let session = try await client.applicationResourceSession(resource)
    return ResourcePresentationFixture(
        gateway: gateway,
        provider: provider,
        descriptor: descriptor,
        moduleGeneration: moduleGeneration,
        session: session
    )
}

@MainActor
private func conditionEventually(
    _ predicate: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<1_000 {
        if predicate() {
            return true
        }
        await Task.yield()
    }
    return false
}

private func bindingCountEventuallyEquals(
    _ expectedCount: Int,
    on gateway: RuntimeIOGateway
) async -> Bool {
    for _ in 0..<1_000 {
        if await gateway.activeApplicationResourceBindingCount() == expectedCount {
            return true
        }
        await Task.yield()
    }
    return false
}
