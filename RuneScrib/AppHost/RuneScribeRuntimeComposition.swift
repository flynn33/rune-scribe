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
    private let rootPresentationAdapter: RuntimeRootPresentationHostAdapter
    private var isConfigured = false
    private var activationState: RuntimeActivationState = .idle
    private var activationGeneration: UInt64 = 0
    private var startIsInFlight = false
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopOperation: Task<Void, Never>?
    let rootPresentationStore: RootViewPresentationStore
    private(set) var startupFailed = false
    var inputDeliveryFailed: Bool { runtime.hostIngressSnapshot.hasDeliveryFailures }
    var lastInputFailure: RuntimeHostIngressFailure? {
        runtime.hostIngressSnapshot.lastFailure
    }
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
        self.rootPresentationStore = rootPresentationStore
        rootPresentationAdapter = rootPresentationStore.runtimeHostAdapter(
            productMetadata: RuneScribeUIProductMetadata(
                version: version ?? "—",
                buildNumber: buildNumber ?? "—"
            )
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
            if !isConfigured {
                try await configure()
                isConfigured = true
            }
            guard generation == activationGeneration, activationState == .starting else { return }
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
        runtime.submit(.lifecycle(event))
    }
    @discardableResult
    func receive(menu command: ApplicationMenuCommandDTO) -> InboundInputDispositionDTO {
        runtime.submit(.menu(command))
    }
    private func configure() async throws {
        try await runtime.register(manifest: RuneScribeCoreModuleBootstrap.manifest(), factory: coreFactory)
        try await runtime.register(manifest: RuneScribeUIModuleBootstrap.manifest(), factory: RuneScribeUIModuleBootstrap.factory())
        try await runtime.installStandardPort(
            rootPresentationAdapter,
            for: .standard
        )
        try await runtime.installPlatformAdapter(secureValues, for: RuneScribeServiceKeys.secureValueStore)
        try await runtime.installPlatformAdapter(protectedFiles, for: RuneScribeServiceKeys.protectedFileStore)
        try await runtime.installPlatformAdapter(inboundFiles, for: RuneScribeServiceKeys.inboundFileReader)
        try await runtime.installPlatformAdapter(shareArtifacts, for: RuneScribeServiceKeys.shareArtifactStore)
        try await runtime.installPlatformAdapter(shareArtifacts, for: RuneScribeServiceKeys.sharePresentation)
        try await runtime.installPlatformAdapter(resources, for: RuneScribeServiceKeys.applicationResourceLocator)
        try await runtime.installPlatformAdapter(fonts, for: RuneScribeServiceKeys.systemFontRegistrar)
        try await runtime.installPlatformAdapter(contacts, for: RuneScribeServiceKeys.contactAccess)
        try await runtime.installPlatformAdapter(clipboardRead, for: RuneScribeServiceKeys.clipboardRead)
        try await runtime.installPlatformAdapter(clipboardWrite, for: RuneScribeServiceKeys.clipboardWrite)
        try await runtime.installPlatformAdapter(clock, for: RuneScribeServiceKeys.clock)
        try await runtime.installPlatformAdapter(uuid, for: RuneScribeServiceKeys.uuid)
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
