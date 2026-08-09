import Foundation
import RuneScribeContracts

public enum AppleProtectedFileStoreError: Error, Equatable, Sendable {
    case pathEscapesRoot
    case symbolicLinkNotAllowed
}

/// Application Support-backed storage for encrypted contacts and imported fonts.
/// The caller owns encryption and schema validation; this adapter owns only safe
/// relative-path resolution and platform file-protection behavior.
public struct AppleProtectedFileStore: ProtectedFileStore, Sendable {
    private let rootDirectory: URL

    public init(applicationSupportDirectory: URL? = nil) {
        rootDirectory = (
            applicationSupportDirectory
                ?? FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0]
        ).resolvingSymlinksInPath().standardizedFileURL
    }

    public func read(relativePath: ProtectedPath) async throws -> Data? {
        let url = try resolvedURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data, relativePath: ProtectedPath) async throws {
        let url = try resolvedURL(for: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    public func remove(relativePath: ProtectedPath) async throws {
        let url = try resolvedURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func exists(relativePath: ProtectedPath) async throws -> Bool {
        try FileManager.default.fileExists(atPath: resolvedURL(for: relativePath).path)
    }

    public func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        let directoryURL = try resolvedURL(for: directory)
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var contents: [ProtectedPath] = []
        for url in urls where fileExtension == nil || url.pathExtension == fileExtension {
            guard !isSymbolicLink(at: url) else { continue }
            let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL
            guard isContainedInRoot(canonicalURL) else {
                throw AppleProtectedFileStoreError.pathEscapesRoot
            }
            contents.append(try directory.appending(url.lastPathComponent))
        }
        return contents.sorted()
    }

    private func resolvedURL(for relativePath: ProtectedPath) throws -> URL {
        var candidate = rootDirectory
        for component in relativePath.rawValue.split(separator: "/") {
            candidate.appendPathComponent(String(component), isDirectory: false)
            guard !isSymbolicLink(at: candidate) else {
                throw AppleProtectedFileStoreError.symbolicLinkNotAllowed
            }
            candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard isContainedInRoot(candidate) else {
                throw AppleProtectedFileStoreError.pathEscapesRoot
            }
        }
        return candidate
    }

    private func isContainedInRoot(_ url: URL) -> Bool {
        if url == rootDirectory { return true }
        let rootPath = rootDirectory.path.hasSuffix("/")
            ? rootDirectory.path
            : rootDirectory.path + "/"
        return url.path.hasPrefix(rootPath)
    }

    private func isSymbolicLink(at url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }
}
