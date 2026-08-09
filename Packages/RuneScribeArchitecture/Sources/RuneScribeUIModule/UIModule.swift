import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
import RuneScribeUIRuntime
import SwiftUI

enum UIModuleResourceError: Error, Equatable, Sendable {
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
            RuneScribeCapabilities.resolveService,
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.resourceRead,
            RuneScribeCapabilities.clipboardWrite,
            RuneScribeCapabilities.shareUI,
            RuneScribeCapabilities.messagesUI,
        ],
        requiredServices: [
            RuneScribeServiceIDs.application,
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.clipboardWrite,
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

    public static func factory(
        dependencies: RuneScribeUIDependencies
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            RuneScribeUIModule(dependencies: dependencies)
        }
    }
}

@MainActor
public final class RuneScribeUIModule: RuneScribeModule {
    public nonisolated let descriptor = RuneScribeUIModuleBootstrap.descriptor

    private nonisolated let dependencies: RuneScribeUIDependencies
    private var session: RuneScribeUISession?

    public nonisolated init(dependencies: RuneScribeUIDependencies) {
        self.dependencies = dependencies
    }

    public func start(context: ModuleContext) async throws {
        let applicationService: any RuneScribeApplicationService = try await context.resolveService(
            RuneScribeServiceKeys.application
        )
        let resources: any ApplicationResourceLocator = try await context.resolveService(
            RuneScribeServiceKeys.applicationResourceLocator
        )
        let clipboardWriting: any ClipboardWriting = try await context.resolveService(
            RuneScribeServiceKeys.clipboardWrite
        )

        async let splashVideoURL: URL? = try? await resources.url(for: .splashVideo)
        async let metalLibraryURL: URL? = try? await resources.url(for: .defaultMetalLibrary)
        let resolvedResources = await (splashVideoURL, metalLibraryURL)

        let session = RuneScribeUISession(
            applicationService: applicationService,
            clipboardWriting: clipboardWriting,
            sharePresentation: dependencies.sharePresentation,
            splashVideoURL: resolvedResources.0,
            metalLibraryURL: resolvedResources.1,
            productMetadata: dependencies.productMetadata
        )

        do {
            try session.start()
            let contribution = RootViewContribution(moduleID: descriptor.moduleID) {
                AnyView(RootView(session: session))
            }
            try dependencies.rootPresentationStore.present(contribution)
            self.session = session
        } catch {
            await session.stop()
            throw error
        }
    }

    public func stop() async {
        let session = self.session
        self.session = nil
        await session?.stop()
        dependencies.rootPresentationStore.dismiss(moduleID: descriptor.moduleID)
    }

}
