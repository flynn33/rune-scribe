import Foundation
import RuneScribeContracts

/// Deterministic contract adapters for package and hosted test targets only.

public struct SecureValueLocation: Hashable, Sendable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public actor InMemorySecureValueStore: SecureValueStore {
    private var values: [SecureValueLocation: Data]

    public init(values: [SecureValueLocation: Data] = [:]) {
        self.values = values
    }

    public func data(service: String, account: String) async throws -> Data? {
        values[SecureValueLocation(service: service, account: account)]
    }

    public func set(_ data: Data, service: String, account: String) async throws {
        values[SecureValueLocation(service: service, account: account)] = data
    }

    public func delete(service: String, account: String) async throws {
        values.removeValue(forKey: SecureValueLocation(service: service, account: account))
    }
}

public actor InMemoryProtectedFileStore: ProtectedFileStore {
    private var files: [ProtectedPath: Data]

    public init(files: [ProtectedPath: Data] = [:]) {
        self.files = files
    }

    public func read(
        relativePath: ProtectedPath,
        maximumByteCount: Int
    ) async throws -> Data? {
        guard maximumByteCount > 0 else {
            throw ProtectedFileStoreReadError.invalidMaximumByteCount
        }
        guard let data = files[relativePath] else { return nil }
        guard data.count <= maximumByteCount else {
            throw ProtectedFileStoreReadError.contentTooLarge
        }
        return data
    }

    public func write(_ data: Data, relativePath: ProtectedPath) async throws {
        files[relativePath] = data
    }

    public func remove(relativePath: ProtectedPath) async throws {
        files.removeValue(forKey: relativePath)
        let prefix = relativePath.rawValue + "/"
        files = files.filter { !$0.key.rawValue.hasPrefix(prefix) }
    }

    public func exists(relativePath: ProtectedPath) async throws -> Bool {
        if files[relativePath] != nil { return true }
        let prefix = relativePath.rawValue + "/"
        return files.keys.contains { $0.rawValue.hasPrefix(prefix) }
    }

    public func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        let prefix = directory.rawValue + "/"
        let components = Set(files.keys.compactMap { path -> String? in
            guard path.rawValue.hasPrefix(prefix) else { return nil }
            let suffix = path.rawValue.dropFirst(prefix.count)
            return suffix.split(separator: "/", maxSplits: 1).first.map(String.init)
        })
        return try components
            .filter { component in
                fileExtension == nil
                    || URL(fileURLWithPath: component).pathExtension == fileExtension
            }
            .map { try directory.appending($0) }
            .sorted()
    }
}

public actor InMemoryInboundFileReader: InboundFileReader {
    private var files: [URL: Data]
    private var permitsSecurityScope: Bool

    public init(
        files: [URL: Data] = [:],
        permitsSecurityScope: Bool = true
    ) {
        self.files = files
        self.permitsSecurityScope = permitsSecurityScope
    }

    public func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        guard fileURL.isFileURL else { throw InboundFileReaderError.notFileURL }
        guard !requiresSecurityScope || permitsSecurityScope else {
            throw InboundFileReaderError.securityScopeDenied
        }
        guard let data = files[fileURL] else {
            throw InboundFileReaderError.unavailable
        }
        guard data.count <= maximumByteCount else {
            throw InboundFileReaderError.contentTooLarge
        }
        return data
    }

    public func set(_ data: Data, for fileURL: URL) {
        files[fileURL] = data
    }

    public func setSecurityScopePermitted(_ permitted: Bool) {
        permitsSecurityScope = permitted
    }
}

public enum InMemoryShareArtifactStoreError: Error, Equatable, Sendable {
    case duplicateIdentifier
    case unknownArtifact
}

public actor InMemoryShareArtifactStore: ShareArtifactStore, SharePresentationProviding {
    private struct Entry: Sendable {
        let fileURL: URL
        let data: Data
    }

    private var entries: [ShareArtifactID: Entry] = [:]
    private var links: [ShareArtifactID: URL] = [:]

    public init() {}

    public func create(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws {
        guard entries[artifactID] == nil, links[artifactID] == nil else {
            throw InMemoryShareArtifactStoreError.duplicateIdentifier
        }
        let fileURL = URL(
            fileURLWithPath: "/in-memory-share/\(artifactID.rawValue.uuidString)/\(filename).\(fileExtension)"
        )
        entries[artifactID] = Entry(fileURL: fileURL, data: data)
    }

    public func remove(artifactID: ShareArtifactID) async throws {
        guard entries[artifactID] != nil else {
            throw InMemoryShareArtifactStoreError.unknownArtifact
        }
        entries.removeValue(forKey: artifactID)
    }

    public func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws {
        guard entries[artifactID] == nil, links[artifactID] == nil else {
            throw InMemoryShareArtifactStoreError.duplicateIdentifier
        }
        links[artifactID] = url
    }

    public func removeLink(artifactID: ShareArtifactID) async throws {
        guard links.removeValue(forKey: artifactID) != nil else {
            throw InMemoryShareArtifactStoreError.unknownArtifact
        }
    }

    public func removeAll() async throws {
        entries.removeAll()
        links.removeAll()
    }

    public func data(for artifactID: ShareArtifactID) -> Data? {
        entries[artifactID]?.data
    }

    public func contains(_ artifactID: ShareArtifactID) -> Bool {
        entries[artifactID] != nil || links[artifactID] != nil
    }

    public func link(for artifactID: ShareArtifactID) -> URL? {
        links[artifactID]
    }

    public func presentationURL(for artifactID: ShareArtifactID) async throws -> URL {
        if let fileURL = entries[artifactID]?.fileURL {
            return fileURL
        }
        if let linkURL = links[artifactID] {
            return linkURL
        }
        throw InMemoryShareArtifactStoreError.unknownArtifact
    }
}

public actor InMemoryContactAccessService: ContactAccessService {
    private var status: ContactAuthorizationDTO
    private let requestResult: Bool
    private let contacts: [SystemContactDTO]

    public init(
        authorizationStatus: ContactAuthorizationDTO = .notDetermined,
        requestResult: Bool = true,
        contacts: [SystemContactDTO] = []
    ) {
        status = authorizationStatus
        self.requestResult = requestResult
        self.contacts = contacts
    }

    public func authorizationStatus() async -> ContactAuthorizationDTO {
        status
    }

    public func requestAccess() async throws -> Bool {
        status = requestResult ? .authorized : .denied
        return requestResult
    }

    public func fetchContacts() async throws -> [SystemContactDTO] {
        contacts
    }
}

public actor InMemoryClipboardService: ClipboardReading, ClipboardWriting {
    private var value: String?
    private var counter: Int

    public init(string: String? = nil, changeCount: Int = 0) {
        value = string
        counter = changeCount
    }

    public func changeCount() async -> Int {
        counter
    }

    public func string() async -> String? {
        value
    }

    public func setString(_ value: String) async throws {
        self.value = value
        counter += 1
    }
}

public enum InMemoryFontRegistrarError: Error, Equatable, Sendable {
    case unknownFont
}

public actor InMemoryFontRegistrar: SystemFontRegistrar {
    private let namesByData: [Data: String]
    private var registeredData: Set<Data> = []

    public init(namesByData: [Data: String]) {
        self.namesByData = namesByData
    }

    public func postScriptName(forFontData data: Data) async throws -> String {
        guard let name = namesByData[data] else {
            throw InMemoryFontRegistrarError.unknownFont
        }
        return name
    }

    public func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        let name = try await postScriptName(forFontData: data)
        registeredData.insert(data)
        return RegisteredFontDTO(postScriptName: name)
    }

    public func isRegistered(_ data: Data) -> Bool {
        registeredData.contains(data)
    }
}

public enum MappedApplicationResourceLocatorError: Error, Equatable, Sendable {
    case resourceNotFound(ApplicationResource)
}

public struct MappedApplicationResourceLocator: ApplicationResourceLocator, Sendable {
    private let locations: [ApplicationResource: URL]

    public init(locations: [ApplicationResource: URL]) {
        self.locations = locations
    }

    public func data(for resource: ApplicationResource) async throws -> Data {
        try Data(contentsOf: try location(for: resource))
    }

    public func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        guard let url = locations[resource] else {
            throw MappedApplicationResourceLocatorError.resourceNotFound(resource)
        }
        return url
    }
}

public struct FixedClock: ClockProviding {
    private let date: Date

    public init(_ date: Date) {
        self.date = date
    }

    public func now() -> Date {
        date
    }
}

public struct FixedUUIDProvider: UUIDProviding {
    private let uuid: UUID

    public init(_ uuid: UUID) {
        self.uuid = uuid
    }

    public func nextUUID() -> UUID {
        uuid
    }
}
