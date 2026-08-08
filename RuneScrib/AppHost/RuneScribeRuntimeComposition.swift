import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeUIModule
import RuneScribeUIRuntime

@MainActor
final class RuneScribeRuntimeComposition {
    private let runtime: RuneScribeRuntime
    private let coreFactory: AnyModuleFactory
    private let secureValues: any SecureValueStore
    private let protectedFiles: any ProtectedFileStore
    private let inboundFiles: any InboundFileReader = AppleInboundFileReader()
    private let shareArtifacts: AppleShareArtifactStore
    private let resources: any ApplicationResourceLocator
    private let fonts: any SystemFontRegistrar
    private let contacts: any ContactAccessService
    private let clipboardRead: any ClipboardReading
    private let clipboardWrite: any ClipboardWriting
    private let clock: any ClockProviding
    private let uuid: any UUIDProviding
    private let inputForwarder: SerialInboundInputForwarder
    private let uiDependencies: RuneScribeUIDependencies
    private var isConfigured = false
    private var activationState: RuntimeActivationState = .idle
    private var hasCompletedInitialActivation = false
    private var activationGeneration: UInt64 = 0
    private var startIsInFlight = false
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopOperation: Task<Void, Never>?
    let rootPresentationStore: RootViewPresentationStore
    private(set) var startupFailed = false
    var inputDeliveryFailed: Bool { inputForwarder.hasDeliveryFailures }
    init(bundle: Bundle = .main, injectedCoreFactory: AnyModuleFactory? = nil) {
        let shareArtifacts = AppleShareArtifactStore()
        let systemClipboard = SystemClipboardService()
        secureValues = AppleKeychainStore()
        protectedFiles = AppleProtectedFileStore()
        self.shareArtifacts = shareArtifacts
        resources = BundleApplicationResourceLocator(bundle: bundle)
        fonts = CoreTextFontRegistrar()
        contacts = SystemContactAccessService()
        clipboardRead = systemClipboard
        clipboardWrite = systemClipboard
        clock = SystemClock()
        uuid = SystemUUIDProvider()
        coreFactory = injectedCoreFactory ?? RuneScribeCoreModuleBootstrap.factory()
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let rootPresentationStore = RootViewPresentationStore()
        let sharePresentation = OpaqueSharePresentationProvider { artifactID in
            try await shareArtifacts.link(for: artifactID)
        }
        self.rootPresentationStore = rootPresentationStore
        uiDependencies = RuneScribeUIDependencies(
            rootPresentationStore: rootPresentationStore,
            sharePresentation: sharePresentation,
            productMetadata: RuneScribeUIProductMetadata(version: version ?? "—", buildNumber: buildNumber ?? "—")
        )
        inputForwarder = SerialInboundInputForwarder()
        runtime = RuneScribeRuntime(runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)), platform: Self.platform)
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
            if !isConfigured {
                try await configure()
                isConfigured = true
            }
            guard generation == activationGeneration, activationState == .starting else { return }
            try await runtime.start()
            guard generation == activationGeneration, activationState == .starting else { return }
            let inputService = try await runtime.resolveHostService(RuneScribeServiceKeys.inboundInput) as any RuneScribeInboundInputService
            guard generation == activationGeneration, activationState == .starting else { return }
            guard inputForwarder.attach(service: inputService) == .attached else {
                throw RuntimeCompositionError.inputRailUnavailable
            }
            await inputForwarder.flush()
            guard generation == activationGeneration, activationState == .starting else { return }
            activationState = .running
            hasCompletedInitialActivation = true
            startupFailed = false
        } catch {
            guard generation == activationGeneration, activationState == .starting else { return }
            await inputForwarder.detach()
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
            await self.inputForwarder.flush()
            await self.inputForwarder.detach()
            await self.runtime.stop()
            await self.awaitStartCompletion()
            await self.inputForwarder.detach()
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
    func receive(urls: [URL], source: InboundDeliverySourceDTO, isColdStart: Bool? = nil) -> [InboundInputDispositionDTO] {
        let inputs = urls.map { input(for: $0, source: source, isColdStart: isColdStart) }
        return inputForwarder.submit(contentsOf: inputs)
    }
    @discardableResult
    func receive(lifecycle event: ApplicationLifecycleInputDTO) -> InboundInputDispositionDTO {
        inputForwarder.submit(.lifecycle(InboundLifecycleDTO(metadata: metadata(source: .applicationOpen), event: event)))
    }
    @discardableResult
    func receive(menu command: ApplicationMenuCommandDTO) -> InboundInputDispositionDTO {
        inputForwarder.submit(.menu(InboundMenuCommandDTO(metadata: metadata(source: .applicationOpen), command: command)))
    }
    private func configure() async throws {
        try await runtime.register(manifest: RuneScribeCoreModuleBootstrap.manifest(), factory: coreFactory)
        try await runtime.register(manifest: RuneScribeUIModuleBootstrap.manifest(), factory: RuneScribeUIModuleBootstrap.factory(dependencies: uiDependencies))
        try await runtime.registerHostService(secureValues, for: RuneScribeServiceKeys.secureValueStore)
        try await runtime.registerHostService(protectedFiles, for: RuneScribeServiceKeys.protectedFileStore)
        try await runtime.registerHostService(inboundFiles, for: RuneScribeServiceKeys.inboundFileReader)
        try await runtime.registerHostService(shareArtifacts, for: RuneScribeServiceKeys.shareArtifactStore)
        try await runtime.registerHostService(resources, for: RuneScribeServiceKeys.applicationResourceLocator)
        try await runtime.registerHostService(fonts, for: RuneScribeServiceKeys.systemFontRegistrar)
        try await runtime.registerHostService(contacts, for: RuneScribeServiceKeys.contactAccess)
        try await runtime.registerHostService(clipboardRead, for: RuneScribeServiceKeys.clipboardRead)
        try await runtime.registerHostService(clipboardWrite, for: RuneScribeServiceKeys.clipboardWrite)
        try await runtime.registerHostService(clock, for: RuneScribeServiceKeys.clock)
        try await runtime.registerHostService(uuid, for: RuneScribeServiceKeys.uuid)
    }
    private func input(for url: URL, source: InboundDeliverySourceDTO, isColdStart: Bool?) -> RuneScribeInboundInput {
        let metadata = metadata(source: source, isColdStart: isColdStart)
        return url.isFileURL ? .file(InboundFileDTO(metadata: metadata, fileURL: url)) : .url(InboundURLDTO(metadata: metadata, url: url))
    }
    private func metadata(source: InboundDeliverySourceDTO, isColdStart: Bool? = nil) -> InboundInputMetadataDTO {
        InboundInputMetadataDTO(
            id: InboundInputID(rawValue: uuid.nextUUID()),
            receivedAt: clock.now(),
            source: source,
            isColdStart: isColdStart ?? !hasCompletedInitialActivation
        )
    }
    private static var platform: SupportedPlatform {
        #if os(macOS)
        .macOS
        #elseif os(iOS)
        .iOS
        #endif
    }
}
private enum RuntimeCompositionError: Error { case inputRailUnavailable }
private enum RuntimeActivationState { case idle, starting, running, stopping }
