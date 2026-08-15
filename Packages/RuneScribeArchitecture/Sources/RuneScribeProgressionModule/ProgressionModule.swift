import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum RuneScribeProgressionModuleBootstrap {
    public static let moduleID = RuneScribeModuleIDs.progression

    /// Exposed for host registration only. Progression never resolves or reads
    /// files from this bundle; all resource bytes cross the runtime I/O rail.
    public static var resourceBundle: Bundle { .module }
    public static var ownerScopedResourceBundles: [ModuleIdentifier: Bundle] {
        [moduleID: resourceBundle]
    }
    public static let manifestResource =
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor.resource
    public static let manifestExpectedSHA256 =
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor.expectedSHA256
    public static let manifestMaximumByteCount =
        ProgressionCatalogResourceCatalog.moduleManifestDescriptor.maximumByteCount

    public static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(37)),
        kind: .service,
        criticality: .optional,
        entryPoint: "RuneScribeProgressionModule",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [
            RuneScribeCapabilities.moduleStateAccess,
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.runtimeAvailabilityRead,
        ],
        requiredServices: [
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.moduleStateStore,
        ],
        requiredResources: ProgressionCatalogResourceCatalog.all,
        publishedEndpoints: RuntimeProgressionEndpointCatalog.publishedEndpointIDs.union(
            RuntimeProgressionEndpointCatalog.existingUserMigrationEndpointIDs
        )
    )

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeProgressionModule.self)
    }

    public static func register(with runtime: RuneScribeRuntime) async throws {
        try await runtime.register(
            manifestResource: manifestResource,
            expectedSHA256: manifestExpectedSHA256,
            maximumByteCount: manifestMaximumByteCount,
            factory: factory()
        )
    }
}

public typealias ProgressionCatalogLoadOperation = @Sendable (
    RuntimeIOClient
) async throws -> ValidatedProgressionCatalogBundle

/// PRG-2 bootstrap lifecycle. Activation validates the controlling resources,
/// opens the runtime-owned state namespace, and registers the durable service.
public struct RuneScribeProgressionModule: RuntimeConstructibleModule {
    public static let moduleDescriptor = RuneScribeProgressionModuleBootstrap.descriptor
    public let descriptor = Self.moduleDescriptor

    private let lifecycle = RuneScribeProgressionModuleLifecycle()
    private let loadCatalog: ProgressionCatalogLoadOperation

    public init() {
        loadCatalog = { runtimeIO in
            try await ProgressionCatalogResources.loadValidatedBundle(using: runtimeIO)
        }
    }

    public init(loadCatalog: @escaping ProgressionCatalogLoadOperation) {
        self.loadCatalog = loadCatalog
    }

    public func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        let resources = try await loadCatalog(runtimeIO)
        let stateClient = try await context.moduleStateClient()
        let availabilityClient = try await context.runtimeAvailabilityClient()
        let service = try await RuneScribeProgressionServiceActor.bootstrap(
            catalogBundle: resources,
            stateClient: stateClient,
            availabilityClient: availabilityClient
        )
        do {
            try await context.registerProgressionEndpoints(service)
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

private actor RuneScribeProgressionModuleLifecycle {
    private var service: RuneScribeProgressionServiceActor?

    func start(_ service: RuneScribeProgressionServiceActor) {
        self.service = service
    }

    func stop() async {
        let service = self.service
        self.service = nil
        await service?.shutdown()
    }
}
