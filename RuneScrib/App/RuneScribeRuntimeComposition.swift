import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeUIModule

@MainActor
final class RuneScribeRuntimeComposition {
    private let runtime: RuneScribeRuntime
    private let secureValues: any SecureValueStore
    private let protectedFiles: any ProtectedFileStore
    private let resources: any ApplicationResourceLocator
    private let fonts: any SystemFontRegistrar
    private let contacts: any ContactAccessService
    private let clipboardRead: any ClipboardReading
    private let clipboardWrite: any ClipboardWriting
    private let clock: any ClockProviding
    private let uuid: any UUIDProviding
    private var isConfigured = false

    let applicationService: any RuneScribeApplicationService
    private(set) var startupFailed = false

    init(bundle: Bundle = .main) {
        let secureValues: any SecureValueStore = AppleKeychainStore()
        let protectedFiles: any ProtectedFileStore = AppleProtectedFileStore()
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
        self.resources = resources
        self.fonts = fonts
        self.contacts = contacts
        self.clipboardRead = clipboardRead
        self.clipboardWrite = clipboardWrite
        self.clock = clock
        self.uuid = uuid
        applicationService = RuneScribeCoreApplicationService(
            secureValueStore: secureValues, clock: clock, uuid: uuid
        )
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
        await runtime.stop()
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
        try await runtime.registerHostService(resources, for: RuneScribeServiceKeys.applicationResourceLocator)
        try await runtime.registerHostService(fonts, for: RuneScribeServiceKeys.systemFontRegistrar)
        try await runtime.registerHostService(contacts, for: RuneScribeServiceKeys.contactAccess)
        try await runtime.registerHostService(clipboardRead, for: RuneScribeServiceKeys.clipboardRead)
        try await runtime.registerHostService(clipboardWrite, for: RuneScribeServiceKeys.clipboardWrite)
        try await runtime.registerHostService(clock, for: RuneScribeServiceKeys.clock)
        try await runtime.registerHostService(uuid, for: RuneScribeServiceKeys.uuid)
    }

    private static var platform: SupportedPlatform {
        #if os(macOS)
        .macOS
        #elseif os(iOS)
        .iOS
        #endif
    }
}
