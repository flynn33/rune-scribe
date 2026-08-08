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
    private var isConfigured = false
    let applicationService: RuneScribeCoreApplicationService
    let sharePresentation: OpaqueSharePresentationProvider
    private(set) var startupFailed = false
    var inputDeliveryFailed: Bool { inputForwarder.hasDeliveryFailures }
    init(bundle: Bundle = .main, injectedApplicationService: RuneScribeCoreApplicationService? = nil) {
        let secureValues: any SecureValueStore = AppleKeychainStore()
        let protectedFiles: any ProtectedFileStore = AppleProtectedFileStore()
        let shareArtifacts = AppleShareArtifactStore()
        let resources: any ApplicationResourceLocator = BundleApplicationResourceLocator(bundle: bundle)
        let fonts: any SystemFontRegistrar = CoreTextFontRegistrar()
        let contacts: any ContactAccessService = SystemContactAccessService()
        let systemClipboard = SystemClipboardService()
        let clipboardRead: any ClipboardReading = systemClipboard
        let clipboardWrite: any ClipboardWriting = systemClipboard
        let clock: any ClockProviding = SystemClock()
        let uuid: any UUIDProviding = SystemUUIDProvider()
        self.secureValues = secureValues
        self.protectedFiles = protectedFiles
        self.shareArtifacts = shareArtifacts
        self.resources = resources
        self.fonts = fonts
        self.contacts = contacts
        self.clipboardRead = clipboardRead
        self.clipboardWrite = clipboardWrite
        self.clock = clock
        self.uuid = uuid
        let applicationService = injectedApplicationService ?? RuneScribeCoreApplicationService(
            secureValueStore: secureValues,
            protectedFileStore: protectedFiles,
            inboundFileReader: inboundFiles,
            shareArtifactStore: shareArtifacts,
            applicationResourceLocator: resources,
            systemFontRegistrar: fonts,
            contactAccess: contacts,
            clipboardReading: clipboardRead,
            clock: clock,
            uuid: uuid
        )
        self.applicationService = applicationService
        inputForwarder = SerialInboundInputForwarder(service: applicationService)
        sharePresentation = OpaqueSharePresentationProvider { artifactID in
            try await shareArtifacts.link(for: artifactID)
        }
        runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: Self.platform
        )
    }
    func start() async {
        do {
            if !isConfigured {
                try await configure()
                isConfigured = true
            }
            try await runtime.start()
            startupFailed = false
        } catch {
            startupFailed = true
        }
    }
    func stop() async {
        await inputForwarder.flush()
        await runtime.stop()
    }
    func receive(urls: [URL], source: InboundDeliverySourceDTO, isColdStart: Bool = false) {
        let inputs = urls.map { input(for: $0, source: source, isColdStart: isColdStart) }
        inputForwarder.submit(contentsOf: inputs)
    }
    func receive(lifecycle event: ApplicationLifecycleInputDTO) {
        let input = RuneScribeInboundInput.lifecycle(
            InboundLifecycleDTO(metadata: metadata(source: .applicationOpen), event: event)
        )
        inputForwarder.submit(input)
    }
    func receive(menu command: ApplicationMenuCommandDTO) {
        let input = RuneScribeInboundInput.menu(
            InboundMenuCommandDTO(metadata: metadata(source: .applicationOpen), command: command)
        )
        inputForwarder.submit(input)
    }
    private func configure() async throws {
        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory(applicationService: applicationService)
        )
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory()
        )
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
    private func input(for url: URL, source: InboundDeliverySourceDTO, isColdStart: Bool) -> RuneScribeInboundInput {
        let metadata = metadata(source: source, isColdStart: isColdStart)
        if url.isFileURL {
            return .file(InboundFileDTO(metadata: metadata, fileURL: url))
        }
        return .url(InboundURLDTO(metadata: metadata, url: url))
    }
    private func metadata(source: InboundDeliverySourceDTO, isColdStart: Bool = false) -> InboundInputMetadataDTO {
        InboundInputMetadataDTO(
            id: InboundInputID(rawValue: uuid.nextUUID()),
            receivedAt: clock.now(),
            source: source,
            isColdStart: isColdStart
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
