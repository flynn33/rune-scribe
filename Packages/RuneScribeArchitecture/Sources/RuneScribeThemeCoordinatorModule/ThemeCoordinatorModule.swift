import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum RuneScribeThemeCoordinatorModuleBootstrap {
    public static let moduleID = RuneScribeModuleIDs.themeCoordinator

    public static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(
            major: UInt(1),
            minor: UInt(0),
            patch: UInt(0)
        ),
        kind: .service,
        criticality: .required,
        entryPoint: "RuneScribeThemeCoordinatorModule",
        role: RuneScribeRoles.themeCoordinator,
        policyClass: RuneScribePolicyClasses.themeCoordinator,
        requestedCapabilities: [
            RuneScribeCapabilities.contributionRead,
            RuneScribeCapabilities.opaqueResourceResolve,
            RuneScribeCapabilities.runtimeSettingsRead,
            RuneScribeCapabilities.runtimeSettingsWrite,
            RuneScribeCapabilities.runtimeAvailabilityRead,
            RuneScribeCapabilities.publishEvents,
        ],
        requiredModuleRoles: [RuneScribeRoles.norseTheme],
        publishedEndpoints: RuntimeThemeEndpointCatalog.publishedEndpointIDs
    )

    public static func manifestData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "module-manifest",
            withExtension: "json"
        ) else {
            throw ThemeCoordinatorModuleError.manifestMissing
        }
        return try Data(contentsOf: url)
    }

    public static func manifest() throws -> ModuleManifest {
        try ModuleManifestDecoder.decode(manifestData())
    }

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeThemeCoordinatorModule.self)
    }

    public static func register(with runtime: RuneScribeRuntime) async throws {
        try await runtime.register(manifest: manifest(), factory: factory())
    }
}

public enum ThemeCoordinatorModuleError: Error, Equatable, Sendable {
    case manifestMissing
    case baseProviderUnavailable
    case revisionConflict(expected: UInt64, actual: UInt64)
    case codexNotSelectable(CodexID)
    case resourceUnavailable(ResolveThemeResourceRequestDTO)
}

public final class RuneScribeThemeCoordinatorModule: RuntimeConstructibleModule,
    @unchecked Sendable
{
    public static let moduleDescriptor =
        RuneScribeThemeCoordinatorModuleBootstrap.descriptor
    public let descriptor = RuneScribeThemeCoordinatorModuleBootstrap.descriptor

    private let lifecycle = ThemeCoordinatorModuleLifecycle()

    public init() {}

    public func start(context: ModuleContext) async throws {
        let contributionReader = try await context.contributionReaderClient()
        let resourceResolver = try await context.opaqueResourceResolverClient()
        let settings = try await context.runtimeSettingsClient()
        let availability = try await context.runtimeAvailabilityClient()
        let service = try await ThemeCoordinatorService.bootstrap(
            contributionReader: contributionReader,
            resourceResolver: resourceResolver,
            settings: settings,
            availability: availability,
            platform: context.runtimePlatform,
            operatingSystemVersion: context.runtimeOperatingSystemVersion(),
            now: { context.runtimeTimestamp() },
            publishEvent: { type, payload in
                _ = try await context.publishEvent(type, payload: payload)
            }
        )
        do {
            try await context.registerThemeCoordinatorEndpoints(service)
            await lifecycle.start(service)
        } catch {
            await service.shutdown()
            throw error
        }
    }

    public func stop() async {
        await lifecycle.stop()
    }
}

private actor ThemeCoordinatorModuleLifecycle {
    private var service: ThemeCoordinatorService?

    func start(_ service: ThemeCoordinatorService) {
        self.service = service
    }

    func stop() async {
        let service = self.service
        self.service = nil
        await service?.shutdown()
    }
}
