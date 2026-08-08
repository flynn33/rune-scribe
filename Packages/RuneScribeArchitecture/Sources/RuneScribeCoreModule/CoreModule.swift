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

    public init() {}

    public func start(context: ModuleContext) async throws {
        let _: any SecureValueStore = try await context.resolveService(
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
        let _: any ClockProviding = try await context.resolveService(
            RuneScribeServiceKeys.clock
        )
        let _: any UUIDProviding = try await context.resolveService(
            RuneScribeServiceKeys.uuid
        )
    }

    public func stop() async {}
}
