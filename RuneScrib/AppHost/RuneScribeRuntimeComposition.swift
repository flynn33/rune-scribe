import Foundation
@_spi(ThemeFidelityQualification) import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribeThemeGloamthornModule
import RuneScribeThemeMoonleafModule
import RuneScribeNorseThemeModule
@_spi(ThemeFidelityQualification) import RuneScribePlatform
import RuneScribeProgressionModule
@_spi(RuntimeOperationAuthority) import RuneScribeRuntimeCore
import RuneScribeThemeSunspireModule
import RuneScribeThemeCoordinatorModule
import RuneScribeThemeWildwoodModule
@_spi(ThemeFidelityQualification) import RuneScribeUIModule
import RuneScribeUIRuntime
private enum RuntimeCompositionQualificationError: Error { case invalidLaunch }

@MainActor final class RuneScribeRuntimeComposition {
    private let runtime: RuneScribeRuntime
    private let coreFactory: AnyModuleFactory
    private let platformEnvironment: ApplePlatformServiceEnvironment
    private let qualificationResolution: ThemeFidelityQualificationLaunch.Resolution
    private let resources: any ApplicationResourceLocator
    private let rootPresentationAdapter: RuntimeRootPresentationHostAdapter
    private var isConfigured = false, startIsInFlight = false
    private var activationState: RuntimeActivationState = .idle
    private var activationGeneration: UInt64 = 0
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopOperation: Task<Void, Never>?
    let rootPresentationStore: RootViewPresentationStore
    private(set) var startupFailed = false
    var inputDeliveryFailed: Bool { runtime.hostIngressSnapshot.hasDeliveryFailures }
    var lastInputFailure: RuntimeHostIngressFailure? { runtime.hostIngressSnapshot.lastFailure }
    var runtimeSnapshot: RuntimeSnapshot { get async { await runtime.snapshot() } }
    init(
        bundle: Bundle = .main,
        injectedCoreFactory: AnyModuleFactory? = nil,
        qualificationResolution: ThemeFidelityQualificationLaunch.Resolution =
            ThemeFidelityQualificationLaunch.resolve(),
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        moduleStateStore: @autoclosure () -> (any ModuleStateStore)? = try? AppleSQLiteModuleStateStore(),
        inboundFiles: @autoclosure () -> any InboundFileReader = AppleInboundFileReader(),
        cloudSync: (any CloudSyncTransport)? = nil
    ) {
        self.qualificationResolution = qualificationResolution
        switch qualificationResolution {
        case .invalid, .validated:
            platformEnvironment = .isolatedQualification()
        case .notRequested:
            platformEnvironment = .normalRoute(processEnvironment: processEnvironment,
                moduleStateStore: moduleStateStore(), inboundFiles: inboundFiles(),
                cloudSync: cloudSync)
        }
        let moduleBundles = RuneScribeProgressionModuleBootstrap.ownerScopedResourceBundles
            .merging(RuneScribeNorseThemeModuleBootstrap.ownerScopedResourceBundles) { _, replacement in replacement }
            .merging(RuneScribeThemeMoonleafModuleBootstrap.ownerScopedResourceBundles) { _, replacement in replacement }
            .merging(RuneScribeThemeSunspireModuleBootstrap.ownerScopedResourceBundles) { _, replacement in replacement }
            .merging(RuneScribeThemeWildwoodModuleBootstrap.ownerScopedResourceBundles) { _, replacement in replacement }
            .merging(RuneScribeThemeGloamthornModuleBootstrap.ownerScopedResourceBundles) { _, replacement in replacement }
        resources = RuneScribeNorseThemeQualification.applicationResourceLocator(
            base: BundleApplicationResourceLocator(
                bundle: bundle,
                moduleBundles: moduleBundles
            )
        )
        coreFactory = injectedCoreFactory ?? RuneScribeCoreModuleBootstrap.factory()
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let rootPresentationStore = RootViewPresentationStore()
        self.rootPresentationStore = rootPresentationStore
        rootPresentationAdapter = rootPresentationStore.runtimeHostAdapter(
            productMetadata: RuneScribeUIProductMetadata(version: version ?? "—", buildNumber: buildNumber ?? "—")
        )
        let runtime = RuneScribeRuntime(runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)), platform: Self.platform)
        self.runtime = runtime
        runtime.observeHostIngressFailures { [weak self] failure in
            Task { @MainActor [weak self] in
                self?.presentHostIngressFailure(failure)
            }
        }
    }
    func presentHostIngressFailure(_ failure: RuntimeHostIngressFailure) {
        switch failure {
        case .admissionRejected, .destinationRejected:
            rootPresentationStore.presentNotice(.inputRejected)
        case .destinationUnavailable, .deliveryFailed:
            rootPresentationStore.presentNotice(.inputUnavailable)
        }
    }
    func start() async {
        if let stopOperation { await stopOperation.value }
        guard activationState == .idle else { return }
        activationState = .starting
        activationGeneration &+= 1
        let generation = activationGeneration
        startIsInFlight = true
        defer {
            let waiters = startCompletionWaiters
            startIsInFlight = false
            startCompletionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        do {
            guard qualificationResolution != .invalid else { throw RuntimeCompositionQualificationError.invalidLaunch }
            if !isConfigured {
                try await configure()
                isConfigured = true
            }
            guard generation == activationGeneration, activationState == .starting else { return }
            switch qualificationResolution {
            case .notRequested:
                try await RuneScribeRuntimeSimulatorQualification.applyIfRequested(
                    to: runtime,
                    optionalProviderUnlockIDs: [
                        "moonleaf": RuneScribeThemeMoonleafModuleBootstrap.unlockID,
                    ]
                )
            case .invalid:
                throw RuntimeCompositionQualificationError.invalidLaunch
            case .validated:
                try await runtime.reconcileEntitlements(
                    try ProgressionEntitlementSnapshotDTO(
                        revision: 4_200,
                        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        includedUnlockIDs: [RuneScribeUnlockIDs.norseCodex],
                        earnedUnlockIDs: [
                            RuneScribeThemeMoonleafModuleBootstrap.unlockID,
                            RuneScribeThemeSunspireModuleBootstrap.unlockID,
                            RuneScribeThemeWildwoodModuleBootstrap.unlockID,
                            RuneScribeThemeGloamthornModuleBootstrap.unlockID,
                        ]
                    )
                )
            }
            try await runtime.start()
            guard generation == activationGeneration, activationState == .starting else { return }
            activationState = .running
            startupFailed = false
        } catch {
            guard generation == activationGeneration, activationState == .starting else { return }
            await runtime.stop()
            guard generation == activationGeneration, activationState == .starting else { return }
            activationState = .idle
            startupFailed = true
            rootPresentationStore.recover(message: "Please quit and reopen Rune Scribe.")
        }
    }
    func stop() async {
        if let stopOperation { await stopOperation.value; return }
        activationState = .stopping
        activationGeneration &+= 1
        let task = Task { @MainActor in
            await self.runtime.stop()
            await self.awaitStartCompletion()
            self.activationState = .idle
            self.stopOperation = nil
        }
        stopOperation = task
        await task.value
    }
    private func awaitStartCompletion() async {
        guard startIsInFlight else { return }
        await withCheckedContinuation { startCompletionWaiters.append($0) }
    }
    @discardableResult
    func receive(
        urls: [URL],
        source: InboundDeliverySourceDTO
    ) -> [InboundInputDispositionDTO] {
        runtime.submit(
            contentsOf: urls.map { url in
                url.isFileURL
                    ? .file(url, source: source)
                    : .url(url, source: source)
            }
        )
    }
    @discardableResult
    func receive(lifecycle event: ApplicationLifecycleInputDTO) -> InboundInputDispositionDTO {
        let disposition = runtime.submit(.lifecycle(event))
        if event == .didBecomeActive || event == .willEnterForeground {
            Task { await runtime.wakeExternalServices(.applicationBecameActive) }
        }
        return disposition
    }
    @discardableResult
    func receive(menu command: ApplicationMenuCommandDTO) -> InboundInputDispositionDTO {
        runtime.submit(.menu(command))
    }
    private func configure() async throws {
        try await runtime.installPlatformAdapter(resources, for: RuneScribeServiceKeys.applicationResourceLocator)
        if let moduleStateStore = platformEnvironment.moduleStateStore { try await runtime.installPlatformAdapter(moduleStateStore, for: RuneScribeServiceKeys.moduleStateStore) }
        try await runtime.register(manifest: RuneScribeCoreModuleBootstrap.manifest(), factory: coreFactory)
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeMoonleafModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeSunspireModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeWildwoodModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeGloamthornModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await RuneScribeProgressionModuleBootstrap.register(with: runtime)
        try await runtime.register(manifest: RuneScribeUIModuleBootstrap.manifest(), factory: RuneScribeUIModuleBootstrap.factory(qualificationResolution: qualificationResolution))
        try await runtime.installStandardPort(rootPresentationAdapter, for: .standard)
        try await runtime.installPlatformAdapter(platformEnvironment.secureValues, for: RuneScribeServiceKeys.secureValueStore)
        try await runtime.installPlatformAdapter(platformEnvironment.protectedFiles, for: RuneScribeServiceKeys.protectedFileStore)
        try await runtime.installPlatformAdapter(platformEnvironment.inboundFiles, for: RuneScribeServiceKeys.inboundFileReader)
        try await runtime.installPlatformAdapter(platformEnvironment.shareArtifacts, for: RuneScribeServiceKeys.shareArtifactStore)
        try await runtime.installPlatformAdapter(platformEnvironment.shareArtifacts, for: RuneScribeServiceKeys.sharePresentation)
        try await runtime.installPlatformAdapter(platformEnvironment.fonts, for: RuneScribeServiceKeys.systemFontRegistrar)
        try await runtime.installPlatformAdapter(platformEnvironment.contacts, for: RuneScribeServiceKeys.contactAccess)
        try await runtime.installPlatformAdapter(platformEnvironment.cloudSync, for: RuneScribeServiceKeys.cloudSyncTransport)
        try await runtime.installPlatformAdapter(platformEnvironment.gameCenterReporting, for: RuneScribeServiceKeys.gameCenterReporting)
        try await runtime.installPlatformAdapter(platformEnvironment.clipboard, for: RuneScribeServiceKeys.clipboardRead)
        try await runtime.installPlatformAdapter(platformEnvironment.clipboard, for: RuneScribeServiceKeys.clipboardWrite)
        try await runtime.installPlatformAdapter(platformEnvironment.clock, for: RuneScribeServiceKeys.clock)
        try await runtime.installPlatformAdapter(platformEnvironment.uuid, for: RuneScribeServiceKeys.uuid)
        try await runtime.installPlatformAdapter(AppleUnlockFeedbackService(), for: RuneScribeUnlockFeedback.serviceKey)
    }
    private static var platform: SupportedPlatform {
        #if os(macOS)
        .macOS
        #elseif os(iOS)
        .iOS
        #endif
    }

}
private enum RuntimeActivationState { case idle, starting, running, stopping }
