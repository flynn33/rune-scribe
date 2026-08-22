import Darwin
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

    public func read(
        relativePath: ProtectedPath,
        maximumByteCount: Int
    ) async throws -> Data? {
        guard maximumByteCount > 0 else {
            throw ProtectedFileStoreReadError.invalidMaximumByteCount
        }
        let url = try resolvedURL(for: relativePath)
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP || errno == ENOTDIR {
                throw AppleProtectedFileStoreError.symbolicLinkNotAllowed
            }
            throw ProtectedFileStoreReadError.unavailable
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ProtectedFileStoreReadError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw ProtectedFileStoreReadError.unsupportedFileType
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumByteCount)
        else {
            throw ProtectedFileStoreReadError.contentTooLarge
        }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remaining = maximumByteCount - result.count
            let requested = remaining < buffer.count
                ? remaining + 1
                : buffer.count
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requested)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProtectedFileStoreReadError.unavailable
            }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumByteCount else {
                throw ProtectedFileStoreReadError.contentTooLarge
            }
        }
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
