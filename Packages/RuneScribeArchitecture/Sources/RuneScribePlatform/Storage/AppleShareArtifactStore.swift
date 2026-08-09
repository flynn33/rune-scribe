import Foundation
import RuneScribeContracts

public enum AppleShareArtifactStoreError: Error, Equatable, Sendable {
    case invalidFilename
    case duplicateIdentifier
    case unknownArtifact
    case pathEscapesRoot
    case symbolicLinkNotAllowed
}

/// Temporary storage for short-lived files handed to system share surfaces.
/// Each instance owns one exact directory, validates every component, and only
/// removes files that it created and still tracks by their opaque artifact ID.
public actor AppleShareArtifactStore: ShareArtifactStore {
    private let rootDirectory: URL
    private var files: [ShareArtifactID: ScopedShareFile] = [:]
    private var links: [ShareArtifactID: URL] = [:]
    private var isPrepared = false

    public init(temporaryDirectory: URL? = nil) {
        let base = (temporaryDirectory ?? FileManager.default.temporaryDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let ownedRoot = base
            .appendingPathComponent("RuneScribeShareArtifacts", isDirectory: true)
            .standardizedFileURL
        rootDirectory = ownedRoot
        if FileManager.default.fileExists(atPath: ownedRoot.path)
            || Self.isSymbolicLinkPath(ownedRoot) {
            try? FileManager.default.removeItem(at: ownedRoot)
        }
    }

    public func create(
        _ data: Data,
        artifactID: ShareArtifactID,
        filename: String,
        fileExtension: String
    ) async throws -> ScopedShareFile {
        guard Self.isValidComponent(filename), Self.isValidComponent(fileExtension) else {
            throw AppleShareArtifactStoreError.invalidFilename
        }
        guard files[artifactID] == nil, links[artifactID] == nil else {
            throw AppleShareArtifactStoreError.duplicateIdentifier
        }

        try prepareRootIfNeeded()
        let artifactDirectory = rootDirectory
            .appendingPathComponent(artifactID.rawValue.uuidString, isDirectory: true)
            .standardizedFileURL
        guard isContainedInRoot(artifactDirectory), !isSymbolicLink(at: artifactDirectory) else {
            throw AppleShareArtifactStoreError.pathEscapesRoot
        }
        try FileManager.default.createDirectory(
            at: artifactDirectory,
            withIntermediateDirectories: false
        )

        let fileURL = artifactDirectory
            .appendingPathComponent("\(filename).\(fileExtension)", isDirectory: false)
            .standardizedFileURL
        guard isContainedInRoot(fileURL), !isSymbolicLink(at: fileURL) else {
            throw AppleShareArtifactStoreError.pathEscapesRoot
        }

        do {
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: fileURL, options: [.atomic])
            #endif
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw error
        }

        let file = ScopedShareFile(artifactID: artifactID, fileURL: fileURL)
        files[artifactID] = file
        return file
    }

    public func remove(_ file: ScopedShareFile) async throws {
        guard files[file.artifactID] == file else {
            throw AppleShareArtifactStoreError.unknownArtifact
        }
        let artifactDirectory = file.fileURL.deletingLastPathComponent().standardizedFileURL
        guard isContainedInRoot(artifactDirectory), !isSymbolicLink(at: artifactDirectory) else {
            throw AppleShareArtifactStoreError.symbolicLinkNotAllowed
        }
        if FileManager.default.fileExists(atPath: artifactDirectory.path) {
            try FileManager.default.removeItem(at: artifactDirectory)
        }
        files.removeValue(forKey: file.artifactID)
    }

    public func storeLink(_ url: URL, artifactID: ShareArtifactID) async throws {
        guard files[artifactID] == nil, links[artifactID] == nil else {
            throw AppleShareArtifactStoreError.duplicateIdentifier
        }
        links[artifactID] = url
    }

    public func removeLink(artifactID: ShareArtifactID) async throws {
        guard links.removeValue(forKey: artifactID) != nil else {
            throw AppleShareArtifactStoreError.unknownArtifact
        }
    }

    /// Presentation infrastructure can export a user-requested link without
    /// placing its key-bearing URL in Contracts, snapshots, or persisted state.
    public func link(for artifactID: ShareArtifactID) throws -> URL {
        guard let url = links[artifactID] else {
            throw AppleShareArtifactStoreError.unknownArtifact
        }
        return url
    }

    public func removeAll() async throws {
        defer { links.removeAll() }
        guard !isSymbolicLink(at: rootDirectory) else {
            throw AppleShareArtifactStoreError.symbolicLinkNotAllowed
        }
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
        files.removeAll()
        isPrepared = false
    }

    private func prepareRootIfNeeded() throws {
        guard !isSymbolicLink(at: rootDirectory) else {
            throw AppleShareArtifactStoreError.symbolicLinkNotAllowed
        }
        if isPrepared {
            let canonicalRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalRoot == rootDirectory else {
                throw AppleShareArtifactStoreError.pathEscapesRoot
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: rootDirectory.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                files.removeAll()
                isPrepared = false
                return try prepareRootIfNeeded()
            }
            return
        }
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            let canonicalRoot = rootDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard canonicalRoot == rootDirectory else {
                throw AppleShareArtifactStoreError.pathEscapesRoot
            }
            try FileManager.default.removeItem(at: rootDirectory)
        }
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        isPrepared = true
    }

    private func isContainedInRoot(_ url: URL) -> Bool {
        if url == rootDirectory { return true }
        let prefix = rootDirectory.path.hasSuffix("/")
            ? rootDirectory.path
            : rootDirectory.path + "/"
        return url.path.hasPrefix(prefix)
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        Self.isSymbolicLinkPath(url)
    }

    private static func isSymbolicLinkPath(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
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
