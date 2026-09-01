import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum RuneScribeThemeMoonleafModuleBootstrap {
    public static let moduleID: ModuleIdentifier = "com.runescribe.module.theme.moonleaf"
    public static let role: ModuleRole = "runescribe.theme.moonleaf"
    public static let codexID = CodexID(rawValue: "codex.moonleaf")!
    public static let unlockID = UnlockID(rawValue: "unlock.codex.moonleaf")!
    public static let discoveryDescriptor = MoonleafThemeDescriptorFactory.discoveryDescriptor

    public static var resourceBundle: Bundle { .module }
    public static var ownerScopedResourceBundles: [ModuleIdentifier: Bundle] {
        [moduleID: resourceBundle]
    }

    public static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        kind: .service,
        criticality: .optional,
        entryPoint: "RuneScribeThemeMoonleafModule",
        role: role,
        policyClass: RuneScribePolicyClasses.themeProvider,
        requestedCapabilities: [
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.contributionPublish,
            RuneScribeCapabilities.opaqueResourcePublish,
        ],
        requiredServices: [RuneScribeServiceIDs.applicationResourceLocator],
        requiredResources: MoonleafThemeBundledResourceCatalog.all
    )

    public static let manifestResource = MoonleafThemeBundledResourceCatalog.moduleManifest
    public static let manifestExpectedSHA256Hex = MoonleafV43ResourcePins.moduleManifestSHA256Hex
    public static var manifestExpectedSHA256: Data {
        Data(hexadecimal: manifestExpectedSHA256Hex)
    }

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeThemeMoonleafModule.self)
    }

    public static func register(with runtime: RuneScribeRuntime) async throws {
        try await runtime.register(
            manifestResource: manifestResource,
            expectedSHA256: manifestExpectedSHA256,
            maximumByteCount: 32 * 1_024,
            factory: factory(),
            themeDiscovery: discoveryDescriptor
        )
    }

    public static func discoveryResourcePayloads(
        using runtimeIO: RuntimeIOClient
    ) async throws -> [ThemeResourceID: Data] {
        try await MoonleafThemeResources.loadValidated(using: runtimeIO).resourcePayloads
    }
}

public struct RuneScribeThemeMoonleafModule: RuntimeConstructibleModule {
    public static let moduleDescriptor = RuneScribeThemeMoonleafModuleBootstrap.descriptor
    public let descriptor = Self.moduleDescriptor

    public init() {}

    public func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        let descriptor = try await MoonleafThemeResources.loadDescriptorValidated(
            using: runtimeIO
        )
        try await context.publishTheme(
            descriptor: descriptor,
            resourceLoader: { resourceID in
                try await MoonleafThemeResources.loadValidatedResource(
                    id: resourceID,
                    using: runtimeIO
                )
            }
        )
    }

    public func stop() async {}
}

private extension Data {
    init(hexadecimal value: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index ..< next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
