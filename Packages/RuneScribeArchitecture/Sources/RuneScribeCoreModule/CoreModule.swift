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
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.fontRegistration,
            RuneScribeCapabilities.contactRead,
            RuneScribeCapabilities.clipboardRead,
            RuneScribeCapabilities.clockRead,
            RuneScribeCapabilities.uuidGenerate,
        ],
        requiredServices: [
            RuneScribeServiceIDs.secureValueStore,
            RuneScribeServiceIDs.protectedFileStore,
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.systemFontRegistrar,
            RuneScribeServiceIDs.contactAccess,
            RuneScribeServiceIDs.clipboardRead,
            RuneScribeServiceIDs.clock,
            RuneScribeServiceIDs.uuid,
        ],
        publishedServices: [RuneScribeServiceIDs.application]
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

    public static func factory(
        applicationService: (any RuneScribeApplicationService)? = nil
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            RuneScribeCoreModule(applicationService: applicationService)
        }
    }
}

public struct RuneScribeCoreModule: RuneScribeModule {
    public let descriptor = RuneScribeCoreModuleBootstrap.descriptor
    private let applicationService: (any RuneScribeApplicationService)?

    public init(applicationService: (any RuneScribeApplicationService)? = nil) {
        self.applicationService = applicationService
    }

    public func start(context: ModuleContext) async throws {
        let secureValueStore: any SecureValueStore = try await context.resolveService(
            RuneScribeServiceKeys.secureValueStore
        )
        let _: any ProtectedFileStore = try await context.resolveService(
            RuneScribeServiceKeys.protectedFileStore
        )
        let _: any ApplicationResourceLocator = try await context.resolveService(
            RuneScribeServiceKeys.applicationResourceLocator
        )
        let _: any SystemFontRegistrar = try await context.resolveService(
            RuneScribeServiceKeys.systemFontRegistrar
        )
        let _: any ContactAccessService = try await context.resolveService(
            RuneScribeServiceKeys.contactAccess
        )
        let _: any ClipboardReading = try await context.resolveService(
            RuneScribeServiceKeys.clipboardRead
        )
        let clock: any ClockProviding = try await context.resolveService(
            RuneScribeServiceKeys.clock
        )
        let uuid: any UUIDProviding = try await context.resolveService(
            RuneScribeServiceKeys.uuid
        )
        let service = applicationService ?? RuneScribeCoreApplicationService(
            secureValueStore: secureValueStore,
            clock: clock,
            uuid: uuid
        )
        try await context.publishService(service, for: RuneScribeServiceKeys.application)
    }

    public func stop() async {}
}
