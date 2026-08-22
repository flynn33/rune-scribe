import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum RuneScribeThemeWildwoodModuleBootstrap {
    public static let moduleID: ModuleIdentifier = "com.runescribe.module.theme.wildwood"
    public static let role: ModuleRole = "runescribe.theme.wildwood"
    public static let codexID = CodexID(rawValue: "codex.wildwood")!
    public static let unlockID = UnlockID(rawValue: "unlock.codex.wildwood")!
    public static let discoveryDescriptor = WildwoodThemeDescriptorFactory.discoveryDescriptor

    public static var resourceBundle: Bundle { .module }
    public static var ownerScopedResourceBundles: [ModuleIdentifier: Bundle] {
        [moduleID: resourceBundle]
    }

    public static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        kind: .service,
        criticality: .optional,
        entryPoint: "RuneScribeThemeWildwoodModule",
        role: role,
        policyClass: RuneScribePolicyClasses.themeProvider,
        requestedCapabilities: [
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.contributionPublish,
            RuneScribeCapabilities.opaqueResourcePublish,
        ],
        requiredServices: [RuneScribeServiceIDs.applicationResourceLocator],
        requiredResources: WildwoodThemeBundledResourceCatalog.all
    )

    public static let manifestResource = WildwoodThemeBundledResourceCatalog.moduleManifest
    public static let manifestExpectedSHA256Hex = "df2bd0dd5048b726c53406bab6c0c211be453c70e115c6354e62a12af9bd70db"
    public static var manifestExpectedSHA256: Data {
        Data(hexadecimal: manifestExpectedSHA256Hex)
    }

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeThemeWildwoodModule.self)
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
        try await WildwoodThemeResources.loadValidated(using: runtimeIO).resourcePayloads
    }
}

public struct RuneScribeThemeWildwoodModule: RuntimeConstructibleModule {
    public static let moduleDescriptor = RuneScribeThemeWildwoodModuleBootstrap.descriptor
    public let descriptor = Self.moduleDescriptor

    public init() {}

    public func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        let theme = try await WildwoodThemeResources.loadValidated(using: runtimeIO)
        try await context.publishTheme(
            descriptor: theme.descriptor,
            resourcePayloads: theme.resourcePayloads
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
