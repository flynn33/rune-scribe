import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum CoreModuleResourceError: Error, Equatable, Sendable {
    case manifestMissing
}

public enum RuneScribeCoreModuleBootstrap {
    public static let moduleID: ModuleIdentifier = "com.runescribe.module.core"

    public static let descriptor = ModuleDescriptor(
        moduleID: "com.runescribe.module.core",
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(42)),
        kind: .service,
        entryPoint: "RuneScribeCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [
            RuneScribeCapabilities.publishEvents,
            RuneScribeCapabilities.keychainStorage,
            RuneScribeCapabilities.protectedFileStorage,
            RuneScribeCapabilities.shareArtifactStorage,
            RuneScribeCapabilities.fontRegistration,
            RuneScribeCapabilities.contactRead,
            RuneScribeCapabilities.clipboardRead,
            RuneScribeCapabilities.clockRead,
            RuneScribeCapabilities.uuidGenerate,
            RuneScribeCapabilities.inboundInput,
            RuneScribeCapabilities.progressionEventSubmit,
            RuneScribeCapabilities.progressionMigrationSubmit,
        ],
        requiredServices: [
            RuneScribeServiceIDs.secureValueStore,
            RuneScribeServiceIDs.protectedFileStore,
            RuneScribeServiceIDs.shareArtifactStore,
            RuneScribeServiceIDs.systemFontRegistrar,
            RuneScribeServiceIDs.contactAccess,
            RuneScribeServiceIDs.clipboardRead,
            RuneScribeServiceIDs.clock,
            RuneScribeServiceIDs.uuid,
        ],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
            RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
    )

    public static func manifestData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "module-manifest",
            withExtension: "json"
        ) else {
            throw CoreModuleResourceError.manifestMissing
        }
        return try Data(contentsOf: url)
    }

    public static func manifest() throws -> ModuleManifest {
        try ModuleManifestDecoder.decode(manifestData())
    }

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeCoreModule.self)
    }
}

public struct RuneScribeCoreModule: RuntimeConstructibleModule {
    public static let moduleDescriptor = RuneScribeCoreModuleBootstrap.descriptor
    public let descriptor = Self.moduleDescriptor
    private let lifecycle = RuneScribeCoreModuleLifecycle()

    public init() {}

    public func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        // Progression is deliberately optional. Core retains its utility surface
        // when the runtime cannot vend the outbox, while operation-aware calls
        // still journal recoverable evidence in Core whenever possible.
        let progressionOutbox = try? await context.progressionOutboxClient()
        let existingUserMigration = try? await context.existingUserMigrationClient()
        let service = RuneScribeCoreApplicationService(
            runtimeIO: runtimeIO,
            progressionOutbox: progressionOutbox,
            existingUserMigration: existingUserMigration
        )
        try await context.registerApplicationEndpoints(service)
        try await context.registerInboundInputEndpoint(service)
        await lifecycle.store(service)
        await service.startInboundProcessing()
    }

    public func stop() async {
        await lifecycle.stop()
    }
}

private actor RuneScribeCoreModuleLifecycle {
    private var service: RuneScribeCoreApplicationService?

    func store(_ service: RuneScribeCoreApplicationService) {
        self.service = service
    }

    func stop() async {
        guard let service else { return }
        self.service = nil
        await service.stopInboundProcessing()
    }
}
