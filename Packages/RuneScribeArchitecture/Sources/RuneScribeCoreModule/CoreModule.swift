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
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(33)),
        kind: .service,
        entryPoint: "RuneScribeCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [
            RuneScribeCapabilities.publishService,
            RuneScribeCapabilities.publishEvents,
            RuneScribeCapabilities.keychainStorage,
            RuneScribeCapabilities.protectedFileStorage,
            RuneScribeCapabilities.inboundFileRead,
            RuneScribeCapabilities.shareArtifactStorage,
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.fontRegistration,
            RuneScribeCapabilities.contactRead,
            RuneScribeCapabilities.clipboardRead,
            RuneScribeCapabilities.clockRead,
            RuneScribeCapabilities.uuidGenerate,
            RuneScribeCapabilities.inboundInput,
        ],
        requiredServices: [
            RuneScribeServiceIDs.secureValueStore,
            RuneScribeServiceIDs.protectedFileStore,
            RuneScribeServiceIDs.inboundFileReader,
            RuneScribeServiceIDs.shareArtifactStore,
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.systemFontRegistrar,
            RuneScribeServiceIDs.contactAccess,
            RuneScribeServiceIDs.clipboardRead,
            RuneScribeServiceIDs.clock,
            RuneScribeServiceIDs.uuid,
        ],
        publishedServices: [
            RuneScribeServiceIDs.application,
            RuneScribeServiceIDs.inboundInput,
        ]
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
        AnyModuleFactory(descriptor: descriptor) {
            RuneScribeCoreModule()
        }
    }
}

public struct RuneScribeCoreModule: RuneScribeModule {
    public let descriptor = RuneScribeCoreModuleBootstrap.descriptor
    private let lifecycle = RuneScribeCoreModuleLifecycle()

    public init() {}

    public func start(context: ModuleContext) async throws {
        let secureValueStore: any SecureValueStore = try await context.resolveService(
            RuneScribeServiceKeys.secureValueStore
        )
        let protectedFileStore: any ProtectedFileStore = try await context.resolveService(
            RuneScribeServiceKeys.protectedFileStore
        )
        let inboundFileReader: any InboundFileReader = try await context.resolveService(
            RuneScribeServiceKeys.inboundFileReader
        )
        let shareArtifactStore: any ShareArtifactStore = try await context.resolveService(
            RuneScribeServiceKeys.shareArtifactStore
        )
        let applicationResourceLocator: any ApplicationResourceLocator = try await context.resolveService(
            RuneScribeServiceKeys.applicationResourceLocator
        )
        let systemFontRegistrar: any SystemFontRegistrar = try await context.resolveService(
            RuneScribeServiceKeys.systemFontRegistrar
        )
        let contactAccess: any ContactAccessService = try await context.resolveService(
            RuneScribeServiceKeys.contactAccess
        )
        let clipboardReading: any ClipboardReading = try await context.resolveService(
            RuneScribeServiceKeys.clipboardRead
        )
        let clock: any ClockProviding = try await context.resolveService(
            RuneScribeServiceKeys.clock
        )
        let uuid: any UUIDProviding = try await context.resolveService(
            RuneScribeServiceKeys.uuid
        )
        let service = RuneScribeCoreApplicationService(
            secureValueStore: secureValueStore,
            protectedFileStore: protectedFileStore,
            inboundFileReader: inboundFileReader,
            shareArtifactStore: shareArtifactStore,
            applicationResourceLocator: applicationResourceLocator,
            systemFontRegistrar: systemFontRegistrar,
            contactAccess: contactAccess,
            clipboardReading: clipboardReading,
            clock: clock,
            uuid: uuid
        )
        try await context.publishService(
            service as any RuneScribeApplicationService,
            for: RuneScribeServiceKeys.application
        )
        try await context.publishService(
            service as any RuneScribeInboundInputService,
            for: RuneScribeServiceKeys.inboundInput
        )
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
