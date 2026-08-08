import Foundation

public enum RuneScribeServiceIDs {
    public static let application: ServiceIdentifier = "RuneScribeApplicationService"
    public static let inboundInput: ServiceIdentifier = "RuneScribeInboundInputService"
    public static let secureValueStore: ServiceIdentifier = "SecureValueStore"
    public static let protectedFileStore: ServiceIdentifier = "ProtectedFileStore"
    public static let inboundFileReader: ServiceIdentifier = "InboundFileReader"
    public static let shareArtifactStore: ServiceIdentifier = "ShareArtifactStore"
    public static let applicationResourceLocator: ServiceIdentifier = "ApplicationResourceLocator"
    public static let systemFontRegistrar: ServiceIdentifier = "SystemFontRegistrar"
    public static let contactAccess: ServiceIdentifier = "ContactAccessService"
    public static let clipboardRead: ServiceIdentifier = "ClipboardService"
    public static let clipboardWrite: ServiceIdentifier = "ClipboardWriteService"
    public static let clock: ServiceIdentifier = "ClockService"
    public static let uuid: ServiceIdentifier = "UUIDService"

    public static let all: Set<ServiceIdentifier> = [
        application,
        inboundInput,
        secureValueStore,
        protectedFileStore,
        inboundFileReader,
        shareArtifactStore,
        applicationResourceLocator,
        systemFontRegistrar,
        contactAccess,
        clipboardRead,
        clipboardWrite,
        clock,
        uuid,
    ]
}

public enum RuneScribeKeychain {
    public static let service = "com.runescribe.keystore"
    public static let symmetricKeyAccount = "symmetricKey"
    public static let cipherLibraryAccount = "cipherLibrary"
    public static let appPINAccount = "appPin"
    public static let pinThrottleAccount = "pinThrottle"

    public static let accounts: Set<String> = [
        symmetricKeyAccount,
        cipherLibraryAccount,
        appPINAccount,
        pinThrottleAccount,
    ]
}

public protocol SecureValueStore: Sendable {
    func data(service: String, account: String) async throws -> Data?
    func set(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
}

public enum ProtectedPathError: Error, Equatable, Sendable {
    case invalidRelativePath
    case invalidComponent
}

public struct ProtectedPath: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    public init(validating rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw ProtectedPathError.invalidRelativePath
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public func appending(_ component: String) throws -> ProtectedPath {
        guard Self.isValidComponent(component) else {
            throw ProtectedPathError.invalidComponent
        }
        return try ProtectedPath(validating: rawValue + "/" + component)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public static let contacts = ProtectedPath(rawValue: "RuneScribContacts/contacts.enc")!
    public static let fontsDirectory = ProtectedPath(rawValue: "RuneScribFonts")!

    private static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.hasPrefix("/"),
              !value.hasPrefix("~"),
              !value.contains("\\"),
              !value.contains("\0")
        else { return false }

        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
    }
}

public protocol ProtectedFileStore: Sendable {
    func read(relativePath: ProtectedPath) async throws -> Data?
    func write(_ data: Data, relativePath: ProtectedPath) async throws
    func remove(relativePath: ProtectedPath) async throws
    func exists(relativePath: ProtectedPath) async throws -> Bool
    func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath]
}

public enum InboundFileReaderError: Error, Equatable, Sendable {
    case notFileURL
    case invalidPath
    case securityScopeDenied
    case unsupportedFileType
    case contentTooLarge
    case unavailable
}

/// Opens one external inbound file without following symbolic links, verifies
/// the opened descriptor, and returns no more than the caller's explicit bound.
public protocol InboundFileReader: Sendable {
    func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data
}

/// An opaque, adapter-owned file made available to a system share surface.
/// The URL is intentionally scoped to one generated artifact; callers never
/// receive the adapter's root directory or arbitrary file-system access.
public struct ScopedShareFile: Equatable, Sendable {
    public let artifactID: ShareArtifactID
    public let fileURL: URL

    public init(artifactID: ShareArtifactID, fileURL: URL) {
        self.artifactID = artifactID
        self.fileURL = fileURL
    }
}

/// Creates and removes short-lived share files through a narrow Platform seam.
/// Core owns payload construction and lifetime policy; the adapter owns safe
/// temporary-path construction, atomic writes, and physical cleanup.
public protocol ShareArtifactStore: Sendable {
    func create(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws -> ScopedShareFile

    /// Stores a key-bearing cipher link behind an opaque lease. The URL never
    /// enters an application DTO, event, snapshot, log, or Codable value.
    func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws
    func removeLink(artifactID: ShareArtifactID) async throws
    func remove(_ file: ScopedShareFile) async throws
    func removeAll() async throws
}

public enum ContactAuthorizationDTO: String, Codable, Hashable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case limited
}

public struct SystemContactDTO: Codable, Equatable, Hashable, Sendable {
    public let systemIdentifier: String
    public let displayName: String
    public let phoneNumbers: [String]
    public let emailAddresses: [String]

    public init(
        systemIdentifier: String,
        displayName: String,
        phoneNumbers: [String] = [],
        emailAddresses: [String] = []
    ) {
        self.systemIdentifier = systemIdentifier
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
    }
}

public protocol ContactAccessService: Sendable {
    func authorizationStatus() async -> ContactAuthorizationDTO
    func requestAccess() async throws -> Bool
    func fetchContacts() async throws -> [SystemContactDTO]
}

public protocol ClipboardReading: Sendable {
    func changeCount() async -> Int
    func string() async -> String?
}

public protocol ClipboardWriting: Sendable {
    func setString(_ value: String) async throws
}

public struct RegisteredFontDTO: Codable, Equatable, Hashable, Sendable {
    public let postScriptName: String

    public init(postScriptName: String) {
        self.postScriptName = postScriptName
    }
}

public protocol SystemFontRegistrar: Sendable {
    func postScriptName(forFontData data: Data) async throws -> String
    func registerFont(_ data: Data) async throws -> RegisteredFontDTO
}

public struct ApplicationResource: Codable, Equatable, Hashable, Sendable {
    public let name: String
    public let fileExtension: String
    public let subdirectory: String?

    public init(name: String, fileExtension: String, subdirectory: String? = nil) {
        self.name = name
        self.fileExtension = fileExtension
        self.subdirectory = subdirectory
    }

    public static let bundledRuneFont = ApplicationResource(
        name: "NotoSansRunic-Regular",
        fileExtension: "ttf",
        subdirectory: nil
    )

    public static let splashVideo = ApplicationResource(
        name: "raven-forge-spp-splash",
        fileExtension: "mp4",
        subdirectory: nil
    )

    public static let defaultMetalLibrary = ApplicationResource(
        name: "default",
        fileExtension: "metallib",
        subdirectory: nil
    )
}

public protocol ApplicationResourceLocator: Sendable {
    func data(for resource: ApplicationResource) async throws -> Data
    func url(for resource: ApplicationResource) async throws -> URL
}

public enum RuneScribeServiceKeys {
    public static let application = ServiceKey<any RuneScribeApplicationService>(
        RuneScribeServiceIDs.application
    )
    public static let inboundInput = ServiceKey<any RuneScribeInboundInputService>(
        RuneScribeServiceIDs.inboundInput
    )
    public static let secureValueStore = ServiceKey<any SecureValueStore>(
        RuneScribeServiceIDs.secureValueStore
    )
    public static let protectedFileStore = ServiceKey<any ProtectedFileStore>(
        RuneScribeServiceIDs.protectedFileStore
    )
    public static let inboundFileReader = ServiceKey<any InboundFileReader>(
        RuneScribeServiceIDs.inboundFileReader
    )
    public static let shareArtifactStore = ServiceKey<any ShareArtifactStore>(
        RuneScribeServiceIDs.shareArtifactStore
    )
    public static let applicationResourceLocator = ServiceKey<any ApplicationResourceLocator>(
        RuneScribeServiceIDs.applicationResourceLocator
    )
    public static let systemFontRegistrar = ServiceKey<any SystemFontRegistrar>(
        RuneScribeServiceIDs.systemFontRegistrar
    )
    public static let contactAccess = ServiceKey<any ContactAccessService>(
        RuneScribeServiceIDs.contactAccess
    )
    public static let clipboardRead = ServiceKey<any ClipboardReading>(
        RuneScribeServiceIDs.clipboardRead
    )
    public static let clipboardWrite = ServiceKey<any ClipboardWriting>(
        RuneScribeServiceIDs.clipboardWrite
    )
    public static let clock = ServiceKey<any ClockProviding>(RuneScribeServiceIDs.clock)
    public static let uuid = ServiceKey<any UUIDProviding>(RuneScribeServiceIDs.uuid)
}
