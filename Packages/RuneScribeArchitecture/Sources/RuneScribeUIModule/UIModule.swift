import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeUIRuntime
import SwiftUI

public enum UIModuleResourceError: Error, Equatable, Sendable {
    case manifestMissing
}

public enum RuneScribeUIModuleBootstrap {
    public static let moduleID: ModuleIdentifier = "com.runescribe.module.ui"

    public static let descriptor = ModuleDescriptor(
        moduleID: "com.runescribe.module.ui",
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(33)),
        kind: .ui,
        entryPoint: "RuneScribeUIModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.subscribeEvents,
            RuneScribeCapabilities.rootUI,
        ],
        requiredModuleRoles: [RuneScribeRoles.core]
    )

    public static func manifestData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "module-manifest",
            withExtension: "json"
        ) else {
            throw UIModuleResourceError.manifestMissing
        }
        return try Data(contentsOf: url)
    }

    public static func manifest() throws -> ModuleManifest {
        try ModuleManifestDecoder.decode(manifestData())
    }

    public static func factory() -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            RuneScribeUIModule()
        }
    }
}

public struct RuneScribeUIModule: RuneScribeUIContributingModule {
    public let descriptor = RuneScribeUIModuleBootstrap.descriptor

    public init() {}

    public func start(context: ModuleContext) async throws {}

    public func stop() async {}

    @MainActor
    public func makeRootView() -> AnyView {
        AnyView(EmptyView())
    }

    public func rootContribution() -> RootViewContribution {
        RootViewContribution(moduleID: descriptor.moduleID) {
            AnyView(EmptyView())
        }
    }
}
