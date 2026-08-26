import Foundation
import RuneScribeContracts

/// Provider-neutral platform services installed by the application host.
/// Paired adapters share one underlying instance.
@_spi(ThemeFidelityQualification)
public struct ApplePlatformServiceEnvironment: Sendable {
    public let secureValues: any SecureValueStore
    public let protectedFiles: any ProtectedFileStore
    public let inboundFiles: any InboundFileReader
    public let shareArtifacts: any ShareArtifactStore & SharePresentationProviding
    public let contacts: any ContactAccessService
    public let cloudSync: any CloudSyncTransport
    public let gameCenterReporting: any GameCenterReporting
    public let clipboard: any ClipboardReading & ClipboardWriting
    public let fonts: any SystemFontRegistrar
    public let clock: any ClockProviding
    public let uuid: any UUIDProviding
    public let moduleStateStore: (any ModuleStateStore)?

    @MainActor public init(
        moduleStateStore: (any ModuleStateStore)?,
        inboundFiles: any InboundFileReader,
        cloudSync: (any CloudSyncTransport)?
    ) {
        self.init(
            secureValues: AppleKeychainStore(),
            protectedFiles: AppleProtectedFileStore(),
            inboundFiles: inboundFiles,
            shareArtifacts: AppleShareArtifactStore(),
            contacts: SystemContactAccessService(),
            cloudSync: cloudSync ?? AppleCloudKitProgressionTransport(),
            gameCenterReporting: AppleGameCenterReportingAdapter(),
            clipboard: SystemClipboardService(),
            fonts: CoreTextFontRegistrar(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider(),
            moduleStateStore: moduleStateStore
        )
    }

    @_spi(ThemeFidelityQualification)
    @MainActor public static func isolatedQualification() -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuneScribeThemeFidelity-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        return Self(
            secureValues: IsolatedSecureValueStore(),
            protectedFiles: AppleProtectedFileStore(
                applicationSupportDirectory: root.appendingPathComponent(
                    "ApplicationSupport",
                    isDirectory: true
                )
            ),
            inboundFiles: IsolatedInboundFileReader(),
            shareArtifacts: AppleShareArtifactStore(temporaryDirectory: root),
            contacts: IsolatedContactAccessService(),
            cloudSync: IsolatedCloudSyncTransport(),
            gameCenterReporting: IsolatedGameCenterReporting(),
            clipboard: IsolatedClipboardService(),
            fonts: CoreTextFontRegistrar(),
            clock: SystemClock(),
            uuid: SystemUUIDProvider(),
            moduleStateStore: try? AppleSQLiteModuleStateStore(
                applicationSupportDirectory: root.appendingPathComponent(
                    "ModuleState",
                    isDirectory: true
                )
            )
        )
    }

    private init(
        secureValues: any SecureValueStore,
        protectedFiles: any ProtectedFileStore,
        inboundFiles: any InboundFileReader,
        shareArtifacts: any ShareArtifactStore & SharePresentationProviding,
        contacts: any ContactAccessService,
        cloudSync: any CloudSyncTransport,
        gameCenterReporting: any GameCenterReporting,
        clipboard: any ClipboardReading & ClipboardWriting,
        fonts: any SystemFontRegistrar,
        clock: any ClockProviding,
        uuid: any UUIDProviding,
        moduleStateStore: (any ModuleStateStore)?
    ) {
        self.secureValues = secureValues
        self.protectedFiles = protectedFiles
        self.inboundFiles = inboundFiles
        self.shareArtifacts = shareArtifacts
        self.contacts = contacts
        self.cloudSync = cloudSync
        self.gameCenterReporting = gameCenterReporting
        self.clipboard = clipboard
        self.fonts = fonts
        self.clock = clock
        self.uuid = uuid
        self.moduleStateStore = moduleStateStore
    }
}

private struct IsolatedSecureValueLocation: Hashable, Sendable {
    let service: String
    let account: String
}

private actor IsolatedSecureValueStore: SecureValueStore {
    private var values: [IsolatedSecureValueLocation: Data] = [:]

    func data(service: String, account: String) async throws -> Data? {
        values[IsolatedSecureValueLocation(service: service, account: account)]
    }

    func set(_ data: Data, service: String, account: String) async throws {
        values[IsolatedSecureValueLocation(service: service, account: account)] = data
    }

    func delete(service: String, account: String) async throws {
        values.removeValue(forKey: IsolatedSecureValueLocation(
            service: service,
            account: account
        ))
    }
}

private struct IsolatedInboundFileReader: InboundFileReader {
    func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        throw InboundFileReaderError.unavailable
    }
}

private actor IsolatedContactAccessService: ContactAccessService {
    func authorizationStatus() async -> ContactAuthorizationDTO { .denied }
    func requestAccess() async throws -> Bool { false }
    func fetchContacts() async throws -> [SystemContactDTO] { [] }
}

private actor IsolatedClipboardService: ClipboardReading, ClipboardWriting {
    private var value: String?
    private var counter = 0

    func changeCount() async -> Int { counter }
    func string() async -> String? { value }

    func setString(_ value: String) async throws {
        self.value = value
        counter += 1
    }
}

private actor IsolatedCloudSyncTransport: CloudSyncTransport {
    func accountState() async throws -> CloudAccountStateDTO {
        try CloudAccountStateDTO(state: .noAccount, accountScopeDigest: nil)
    }

    func fetchPrivateProgression() async throws -> CloudSyncFetchResultDTO {
        try CloudSyncFetchResultDTO(payload: nil, changeTag: nil)
    }

    func savePrivateProgression(
        _ request: CloudSyncSaveRequestDTO
    ) async throws -> CloudSyncSaveResultDTO {
        throw CloudSyncTransportError.accountUnavailable
    }
}

private actor IsolatedGameCenterReporting: GameCenterReporting {
    func authenticationState() async -> GameCenterAuthenticationStateDTO { .unavailable }
    func accountScopeDigest() async -> GameCenterAccountScopeDigestDTO? { nil }

    func requestAuthentication() async throws -> GameCenterAuthenticationStateDTO {
        .unavailable
    }

    func report(_ achievements: [GameCenterAchievementReportDTO]) async throws {
        throw GameCenterReportingTransportError.configurationUnavailable
    }
}
