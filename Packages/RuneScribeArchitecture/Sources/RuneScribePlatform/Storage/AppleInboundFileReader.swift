import Darwin
import Foundation
import RuneScribeContracts

/// Reads one externally supplied file through descriptor-relative, no-follow
/// opens. Every ancestor and the leaf are pinned before bytes are read, closing
/// the check/open race that pathname-based Foundation reads cannot avoid.
public struct AppleInboundFileReader: InboundFileReader {
    public static let hardMaximumByteCount = 16 * 1_024 * 1_024

    private let beginAccess: @Sendable (URL) -> Bool
    private let endAccess: @Sendable (URL) -> Void

    public init() {
        beginAccess = { $0.startAccessingSecurityScopedResource() }
        endAccess = { $0.stopAccessingSecurityScopedResource() }
    }

    init(
        beginAccess: @escaping @Sendable (URL) -> Bool,
        endAccess: @escaping @Sendable (URL) -> Void
    ) {
        self.beginAccess = beginAccess
        self.endAccess = endAccess
    }

    public func read(
        _ fileURL: URL,
        requiresSecurityScope: Bool,
        maximumByteCount: Int
    ) async throws -> Data {
        guard fileURL.isFileURL else { throw InboundFileReaderError.notFileURL }
        guard maximumByteCount > 0,
              maximumByteCount <= Self.hardMaximumByteCount
        else { throw InboundFileReaderError.contentTooLarge }

        let openedScope = requiresSecurityScope ? beginAccess(fileURL) : false
        guard !requiresSecurityScope || openedScope else {
            throw InboundFileReaderError.securityScopeDenied
        }
        defer {
            if openedScope { endAccess(fileURL) }
        }

        return try Self.readDescriptor(
            at: fileURL,
            maximumByteCount: maximumByteCount
        )
    }

    private static func readDescriptor(
        at fileURL: URL,
        maximumByteCount: Int
    ) throws -> Data {
        let originalPath = fileURL.path
        guard originalPath.hasPrefix("/"),
              !originalPath.utf8.contains(0),
              fileURL.standardizedFileURL.path == originalPath
        else { throw InboundFileReaderError.invalidPath }

        let platformPath = canonicalizingSystemAlias(in: originalPath)
        let components = URL(fileURLWithPath: platformPath).pathComponents.filter { $0 != "/" }
        guard let leaf = components.last,
              !leaf.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw InboundFileReaderError.invalidPath }

        var directoryDescriptor = Darwin.open(
            "/",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw InboundFileReaderError.unavailable
        }
        defer { Darwin.close(directoryDescriptor) }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString { pointer in
                Darwin.openat(
                    directoryDescriptor,
                    pointer,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard nextDescriptor >= 0 else { throw mappedOpenError() }
            Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let fileDescriptor = leaf.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard fileDescriptor >= 0 else { throw mappedOpenError() }
        defer { Darwin.close(fileDescriptor) }

        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0 else {
            throw InboundFileReaderError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw InboundFileReaderError.unsupportedFileType
        }
        guard metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumByteCount)
        else { throw InboundFileReaderError.contentTooLarge }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remainingWithSentinel = maximumByteCount - result.count + 1
            guard remainingWithSentinel > 0 else {
                throw InboundFileReaderError.contentTooLarge
            }
            let requested = min(buffer.count, remainingWithSentinel)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fileDescriptor, bytes.baseAddress, requested)
            }
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw InboundFileReaderError.unavailable
            }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumByteCount else {
                throw InboundFileReaderError.contentTooLarge
            }
        }
    }

    private static func mappedOpenError() -> InboundFileReaderError {
        switch errno {
        case ELOOP, ENOTDIR:
            .unsupportedFileType
        default:
            .unavailable
        }
    }

    /// Apple exposes a few stable root aliases (notably `/var` on sandbox
    /// container URLs). Canonicalizing only those aliases keeps ordinary file
    /// imports usable without permitting caller-controlled symlink ancestors.
    private static func canonicalizingSystemAlias(in path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"]
        where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }
}
