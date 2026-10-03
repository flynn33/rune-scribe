import Foundation
@_spi(ThemeFidelityQualification) import RuneScribeContracts
import RuneScribeMessagesShared
@_spi(ThemeFidelityQualification) import RuneScribeRuntimeCore
import RuneScribeUIPresentationContracts
import RuneScribeUIRuntime
import SwiftUI

enum UIModuleResourceError: Error, Equatable, Sendable {
    case manifestMissing
    case invalidQualificationLaunch
}

public enum RuneScribeUIModuleBootstrap {
    public static let moduleID: ModuleIdentifier = "com.runescribe.module.ui"

    public static let descriptor = ModuleDescriptor(
        moduleID: "com.runescribe.module.ui",
        moduleVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(44)),
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
            RuneScribeCapabilities.fileImportUI,
            RuneScribeCapabilities.shareUI,
            RuneScribeCapabilities.messagesUI,
            RuneScribeCapabilities.runtimeAvailabilityRead,
            RuneScribeCapabilities.runtimeSettingsRead,
            RuneScribeCapabilities.runtimeSettingsWrite,
            RuneScribeCapabilities.cloudGameCenterStatusRead,
            RuneScribeCapabilities.gameCenterOptIn,
            RuneScribeCapabilities.cloudAccountRebind,
            RuneScribeCapabilities.progressionStateRead,
            RuneScribeCapabilities.progressionCommands,
            RuneScribeCapabilities.themeStateRead,
            RuneScribeCapabilities.themeSelection,
            RuneScribeCapabilities.themeResourceRead,
            RuneScribeCapabilities.fontRegistration,
        ],
        requiredServices: [
            RuneScribeServiceIDs.applicationResourceLocator,
            RuneScribeServiceIDs.clipboardWrite,
            RuneScribeServiceIDs.sharePresentation,
            RuneScribeServiceIDs.systemFontRegistrar,
        ],
        requiredResources: [
            .splashVideo,
            .defaultMetalLibrary,
        ],
        requiredModuleRoles: [
            RuneScribeRoles.core,
            RuneScribeRoles.themeCoordinator,
        ],
        consumedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
            RuntimeProgressionEndpointCatalog.UIEndpointIDs
        ).union(
            RuntimeThemeEndpointCatalog.UIEndpointIDs
        )
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
        AnyModuleFactory(moduleType: RuneScribeUIModule.self)
    }

    @_spi(ThemeFidelityQualification)
    public static func factory(
        qualificationResolution: ThemeFidelityQualificationLaunch.Resolution,
        messagesImportStateHandler: @escaping MessagesImportStateHandler =
            MessagesImportStateHandlers.unavailable
    ) -> AnyModuleFactory {
        AnyModuleFactory(qualificationDescriptor: descriptor) {
            RuneScribeUIModule(
                qualificationResolution: qualificationResolution,
                messagesImportStateHandler: messagesImportStateHandler
            )
        }
    }
}

@MainActor
public final class RuneScribeUIModule: RuntimeConstructibleModule {
    public nonisolated static let moduleDescriptor = RuneScribeUIModuleBootstrap.descriptor
    public nonisolated let descriptor = RuneScribeUIModuleBootstrap.descriptor

    private var session: RuneScribeUISession?
    private var rootPresentationClient: RuntimeRootPresentationClient?
    private nonisolated let qualificationResolution: ThemeFidelityQualificationLaunch.Resolution
    private nonisolated let messagesImportStateHandler: MessagesImportStateHandler

    public nonisolated init() {
        qualificationResolution = ThemeFidelityQualificationLaunch.resolve()
        messagesImportStateHandler = MessagesImportStateHandlers.unavailable
    }

    @_spi(ThemeFidelityQualification)
    public nonisolated init(
        qualificationResolution: ThemeFidelityQualificationLaunch.Resolution,
        messagesImportStateHandler: @escaping MessagesImportStateHandler =
            MessagesImportStateHandlers.unavailable
    ) {
        self.qualificationResolution = qualificationResolution
        self.messagesImportStateHandler = messagesImportStateHandler
    }

    public func start(context: ModuleContext) async throws {
        let qualificationLaunch: ThemeFidelityQualificationLaunch?
        switch qualificationResolution {
        case .notRequested:
            qualificationLaunch = nil
        case .invalid:
            throw UIModuleResourceError.invalidQualificationLaunch
        case .validated(let launch):
            qualificationLaunch = launch
        }

        let applicationClient = try await context.applicationClient()
        let runtimeIO = try await context.runtimeIOClient()
        let availabilityClient = try await context.runtimeAvailabilityClient()
        let progressionClient = qualificationLaunch == nil
            ? try? await context.progressionClient()
            : nil
        let themeCoordinatorClient = try await context.themeCoordinatorClient()
        let runtimeSettingsClient = qualificationLaunch == nil
            ? try? await context.runtimeSettingsClient()
            : nil
        let cloudGameCenterStatusClient = qualificationLaunch == nil
            ? try? await context.cloudGameCenterStatusClient()
            : nil
        let unlockFeedbackClient = qualificationLaunch == nil
            ? try? await context.unlockFeedbackClient()
            : nil
        let rootPresentationClient = try await context.rootPresentationClient()
        let productMetadata = try await rootPresentationClient.productMetadata()
        let inboundFileImportSession = try await runtimeIO.inboundFileImportSession {
            [applicationClient] input in
            try await applicationClient.importFile(input)
        }

        async let splashVideoSession: RuntimeApplicationResourceSession? = try? await runtimeIO.applicationResourceSession(
            .splashVideo
        )
        async let metalLibrarySession: RuntimeApplicationResourceSession? = try? await runtimeIO.applicationResourceSession(
            .defaultMetalLibrary
        )
        let resourceSessions = await (splashVideoSession, metalLibrarySession)
        let resourcePresentation = RuntimeApplicationResourcePresentation(
            splashVideo: resourceSessions.0,
            metalLibrary: resourceSessions.1
        )

        let session = RuneScribeUISession(
            applicationClient: applicationClient,
            runtimeIO: runtimeIO,
            availabilityClient: availabilityClient,
            progressionClient: progressionClient,
            themeCoordinatorClient: themeCoordinatorClient,
            runtimeSettingsClient: runtimeSettingsClient,
            cloudGameCenterStatusClient: cloudGameCenterStatusClient,
            unlockFeedbackClient: unlockFeedbackClient,
            inboundFileImportSession: inboundFileImportSession,
            resourcePresentation: resourcePresentation,
            productMetadata: productMetadata,
            messagesImportStateHandler: messagesImportStateHandler
        )

        do {
            try await session.prepareInitialTheme()
            try session.start()
            let rootView: AnyView
            if let qualificationLaunch {
                rootView = AnyView(ThemeFidelityQualificationHostView(
                    launch: qualificationLaunch,
                    session: session
                ))
            } else {
                rootView = AnyView(RootView(session: session))
            }
            let contribution = RootViewContribution(moduleID: descriptor.moduleID) {
                rootView
            }
            try await rootPresentationClient.present(contribution)
            self.session = session
            self.rootPresentationClient = rootPresentationClient
        } catch {
            await session.stop()
            throw error
        }
    }

    public func stop() async {
        let session = self.session
        let rootPresentationClient = self.rootPresentationClient
        self.session = nil
        self.rootPresentationClient = nil
        await session?.stop()
        try? await rootPresentationClient?.dismiss()
    }

}
