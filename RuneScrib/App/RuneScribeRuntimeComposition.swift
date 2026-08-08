import Foundation
import RuneScribeContracts
import RuneScribeCoreModule
import RuneScribePlatform
import RuneScribeRuntimeCore
import RuneScribeUIModule

/// Production composition root for the app-owned runtime.
///
/// P3 boots the no-op module shells alongside the legacy application path so every
/// privileged adapter is registered and capability-checked on both shipping hosts.
/// Later migration phases make this runtime the sole activation path and surface its
/// neutral recovery state in the root shell.
@MainActor
final class RuneScribeRuntimeComposition {
    private let runtime: RuneScribeRuntime
    private let hostBundle: Bundle
    private var isConfigured = false

    private(set) var startupFailed = false

    init(bundle: Bundle = .main) {
        hostBundle = bundle
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
            factory: RuneScribeCoreModuleBootstrap.factory()
        )
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory()
        )

        let secureValues: any SecureValueStore = AppleKeychainStore()
        let protectedFiles: any ProtectedFileStore = AppleProtectedFileStore()
        let resources: any ApplicationResourceLocator = BundleApplicationResourceLocator(
            bundle: hostBundle
        )
        let fonts: any SystemFontRegistrar = CoreTextFontRegistrar()
        let contacts: any ContactAccessService = SystemContactAccessService()
        let systemClipboard = SystemClipboardService()
        let clipboardRead: any ClipboardReading = systemClipboard
        let clipboardWrite: any ClipboardWriting = systemClipboard
        let clock: any ClockProviding = SystemClock()
        let uuid: any UUIDProviding = SystemUUIDProvider()

        try await runtime.registerHostService(
            secureValues,
            for: RuneScribeServiceKeys.secureValueStore
        )
        try await runtime.registerHostService(
            protectedFiles,
            for: RuneScribeServiceKeys.protectedFileStore
        )
        try await runtime.registerHostService(
            resources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.registerHostService(
            fonts,
            for: RuneScribeServiceKeys.systemFontRegistrar
        )
        try await runtime.registerHostService(
            contacts,
            for: RuneScribeServiceKeys.contactAccess
        )
        try await runtime.registerHostService(
            clipboardRead,
            for: RuneScribeServiceKeys.clipboardRead
        )
        try await runtime.registerHostService(
            clipboardWrite,
            for: RuneScribeServiceKeys.clipboardWrite
        )
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
