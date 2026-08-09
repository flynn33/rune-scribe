import Foundation

public enum RuneScribeWireFormat {
    public static let URLScheme = "runescribe"
    public static let importHost = "import"
    public static let legacyWebHost = "ravenforgesoftware.com"
    public static let legacyImportPath = "/rune-scribe/import"
    public static let contentType = "com.runescribe.runescribe"
    public static let fileExtension = "runescribe"
    public static let cipherVersion = 3
    public static let messageVersion = 1
    public static let containerMagic = Data([
        0x52, 0x53, 0x43, 0x52, 0x50, 0x4B, 0x47, 0x0A,
    ])
    public static let containerVersion = 1
}

public enum InboundDeliverySourceDTO: String, Codable, Hashable, Sendable {
    case applicationOpen
    case sceneOpen
    case webBrowsingActivity
    case clipboard
    case qrScanner
    case fileImporter
}

public struct InboundInputMetadataDTO: Codable, Equatable, Hashable, Sendable {
    public let id: InboundInputID
    public let receivedAt: Date
    public let source: InboundDeliverySourceDTO
    public let isColdStart: Bool

    public init(
        id: InboundInputID,
        receivedAt: Date,
        source: InboundDeliverySourceDTO,
        isColdStart: Bool
    ) {
        self.id = id
        self.receivedAt = receivedAt
        self.source = source
        self.isColdStart = isColdStart
    }
}

public struct InboundFileDTO: Equatable, Hashable, Sendable {
    public let metadata: InboundInputMetadataDTO
    public let fileURL: URL
    public let declaredContentType: String?
    public let requiresSecurityScopedAccess: Bool

    public init(
        metadata: InboundInputMetadataDTO,
        fileURL: URL,
        declaredContentType: String? = nil,
        requiresSecurityScopedAccess: Bool = true
    ) {
        self.metadata = metadata
        self.fileURL = fileURL
        self.declaredContentType = declaredContentType
        self.requiresSecurityScopedAccess = requiresSecurityScopedAccess
    }
}

public struct InboundURLDTO: Equatable, Hashable, Sendable {
    public let metadata: InboundInputMetadataDTO
    public let url: URL

    public init(metadata: InboundInputMetadataDTO, url: URL) {
        self.metadata = metadata
        self.url = url
    }
}

public enum ApplicationLifecycleInputDTO: String, Codable, Hashable, Sendable {
    case didBecomeActive
    case willResignActive
    case didEnterBackground
    case willEnterForeground
    case willTerminate
}

public struct InboundLifecycleDTO: Codable, Equatable, Hashable, Sendable {
    public let metadata: InboundInputMetadataDTO
    public let event: ApplicationLifecycleInputDTO

    public init(metadata: InboundInputMetadataDTO, event: ApplicationLifecycleInputDTO) {
        self.metadata = metadata
        self.event = event
    }
}

public enum ApplicationMenuCommandDTO: String, Codable, Hashable, Sendable {
    case openCipherLibrary
    case openSettings
}

public struct InboundMenuCommandDTO: Codable, Equatable, Hashable, Sendable {
    public let metadata: InboundInputMetadataDTO
    public let command: ApplicationMenuCommandDTO

    public init(metadata: InboundInputMetadataDTO, command: ApplicationMenuCommandDTO) {
        self.metadata = metadata
        self.command = command
    }
}

public enum RuneScribeInboundInput: Equatable, Hashable, Sendable {
    case file(InboundFileDTO)
    case url(InboundURLDTO)
    case lifecycle(InboundLifecycleDTO)
    case menu(InboundMenuCommandDTO)

    public var metadata: InboundInputMetadataDTO {
        switch self {
        case .file(let value):
            value.metadata
        case .url(let value):
            value.metadata
        case .lifecycle(let value):
            value.metadata
        case .menu(let value):
            value.metadata
        }
    }
}

public enum InboundInputDispositionDTO: String, Codable, Hashable, Sendable {
    case accepted
    case duplicate
    case ignored
    case rejected
}

public protocol RuneScribeInboundInputService: Sendable {
    func receive(_ input: RuneScribeInboundInput) async throws -> InboundInputDispositionDTO
}
