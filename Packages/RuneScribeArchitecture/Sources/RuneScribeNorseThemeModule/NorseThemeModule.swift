import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore

public enum RuneScribeNorseThemeModuleBootstrap {
    public static let moduleID = RuneScribeModuleIDs.norseTheme
    public static let discoveryDescriptor = NorseBaseThemeDescriptorFactory.discoveryDescriptor

    /// Exposed only so the application host can map this owner-scoped bundle.
    /// Module code reads production bytes through RuntimeIOClient.
    public static var resourceBundle: Bundle { .module }
    public static var ownerScopedResourceBundles: [ModuleIdentifier: Bundle] {
        [moduleID: resourceBundle]
    }

    public static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
        kind: .service,
        criticality: .required,
        entryPoint: "RuneScribeNorseThemeModule",
        role: RuneScribeRoles.norseTheme,
        policyClass: RuneScribePolicyClasses.themeProvider,
        requestedCapabilities: [
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.contributionPublish,
            RuneScribeCapabilities.opaqueResourcePublish,
        ],
        requiredServices: [
            RuneScribeServiceIDs.applicationResourceLocator,
        ],
        requiredResources: NorseBaseBundledResourceCatalog.all
    )

    public static let manifestResource = NorseBaseBundledResourceCatalog.moduleManifest

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(moduleType: RuneScribeNorseThemeModule.self)
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

    /// Test and host support that retains runtime-mediated access to every
    /// byte published by the provider.
    public static func discoveryResourcePayloads(
        using runtimeIO: RuntimeIOClient
    ) async throws -> [ThemeResourceID: Data] {
        try await NorseBaseThemeResources.loadValidated(using: runtimeIO).resourcePayloads
    }

    public static var manifestExpectedSHA256: Data {
        data(fromHex: manifestExpectedSHA256Hex)
    }

    public static let manifestExpectedSHA256Hex =
        "9cc17fb4504eb975972b521237c4c80566a0b1a13fd71b8dd885e69ff3a86a5d"

    private static func data(fromHex value: String) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            bytes.append(UInt8(value[index ..< next], radix: 16)!)
            index = next
        }
        return Data(bytes)
    }
}

public struct RuneScribeNorseThemeModule: RuntimeConstructibleModule {
    public static let moduleDescriptor = RuneScribeNorseThemeModuleBootstrap.descriptor
    public let descriptor = Self.moduleDescriptor

    public init() {}

    public func start(context: ModuleContext) async throws {
        let runtimeIO = try await context.runtimeIOClient()
        do {
            let theme = try await NorseBaseThemeResources.loadValidated(using: runtimeIO)
            try await context.publishTheme(
                descriptor: theme.descriptor,
                resourcePayloads: theme.resourcePayloads
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as RequiredThemeResourceFailureDTO {
            try await publishEmergencyPresentation(
                after: failure,
                context: context
            )
        } catch {
            try await publishEmergencyPresentation(
                after: RequiredThemeResourceFailureDTO(
                    moduleID: RuneScribeModuleIDs.norseTheme,
                    codexID: RuneScribeCodexIDs.norse,
                    stage: .contributionPublication,
                    errorCode: .contributionRejected
                ),
                context: context
            )
        }
    }

    public func stop() async {}

    private func publishEmergencyPresentation(
        after failure: RequiredThemeResourceFailureDTO,
        context: ModuleContext
    ) async throws {
        // Publish bounded provenance before the descriptor-only contribution.
        // The coordinator can then retain an inspectable emergency diagnostic
        // without blocking Core encode/decode availability.
        try await context.publishRequiredBaseResourceFailure(failure)
        try await context.publishThemeDescriptor(
            RuneScribeNorseThemeModuleBootstrap.discoveryDescriptor
        )
    }
}
