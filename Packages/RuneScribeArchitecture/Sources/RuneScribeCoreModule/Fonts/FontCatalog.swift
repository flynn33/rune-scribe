import CryptoKit
import Foundation
import RuneScribeContracts

enum FontCatalogError: Error, Equatable, Sendable {
    case invalidReference
    case unavailableFont
    case hashMismatch
    case unreadableFont
    case cannotRegister
    case protectedStorageUnavailable
    case resourceUnavailable
    case corruptedStoredFont
    case rollbackFailed
}

enum StoredFontRegistrationIssue: Error, Equatable, Sendable {
    case unreadableEntry
    case invalidContentAddress
    case invalidFont
    case registrationFailed
}

struct FontCatalogRegistrationReport: Equatable, Sendable {
    let registeredCustomCount: Int
    let skipped: [StoredFontRegistrationIssue]

    static let empty = FontCatalogRegistrationReport(
        registeredCustomCount: 0,
        skipped: []
    )
}

/// Core-owned font validation and catalog policy. Platform seams retain all
/// bundle, protected-file, and CoreText implementation details.
actor FontCatalog: CoreFontIntegrating {
    static let bundledDisplayName = "Noto Sans Runic"

    private let protectedFileStore: any ProtectedFileStore
    private let registrar: any SystemFontRegistrar
    private let resources: any ApplicationResourceLocator

    private var registeredNamesByDigest: [String: String] = [:]
    private var lastRegistrationReport: FontCatalogRegistrationReport = .empty
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        protectedFileStore: any ProtectedFileStore,
        registrar: any SystemFontRegistrar,
        resources: any ApplicationResourceLocator
    ) {
        self.protectedFileStore = protectedFileStore
        self.registrar = registrar
        self.resources = resources
    }

    /// Registers the fixed shipping font and all content-addressed imported
    /// fonts. The bundled font and directory listing remain boot-critical.
    /// Individual custom entries are quarantined in a key-free report so one
    /// damaged imported file cannot prevent the application from starting.
    @discardableResult
    func registerAvailableFonts() async throws -> FontCatalogRegistrationReport {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        let bundled = try await bundledData()
        try await registerValidated(bundled, digest: Self.digestHex(FontRef.bundled.sha256))

        let paths: [ProtectedPath]
        do {
            paths = try await protectedFileStore.contents(
                of: .fontsDirectory,
                matchingExtension: "ttf"
            )
        } catch {
            throw FontCatalogError.protectedStorageUnavailable
        }

        var registeredCustomCount = 0
        var skipped: [StoredFontRegistrationIssue] = []
        for path in paths {
            do {
                try await registerStoredFont(at: path)
                registeredCustomCount += 1
            } catch {
                skipped.append(Self.registrationIssue(for: error))
            }
        }
        let report = FontCatalogRegistrationReport(
            registeredCustomCount: registeredCustomCount,
            skipped: skipped
        )
        lastRegistrationReport = report
        return report
    }

    /// Returns a usable PostScript name when the referenced bytes are present
    /// and valid. The bundled display identity is frozen for wire compatibility.
    func resolve(_ reference: FontRef) async throws -> String? {
        guard reference.hasValidWireShape else {
            throw FontCatalogError.invalidReference
        }
        if reference == .bundled {
            return Self.bundledDisplayName
        }
        guard let bytes = try await data(for: reference) else {
            return nil
        }
        return try await postScriptName(for: bytes)
    }

    /// Reads and verifies font bytes. A missing custom font is represented by
    /// nil; invalid or inaccessible stored content is an explicit failure.
    func data(for reference: FontRef) async throws -> Data? {
        guard reference.hasValidWireShape else {
            throw FontCatalogError.invalidReference
        }
        if reference == .bundled {
            return try await bundledData()
        }

        let path = try Self.importedPath(for: reference)
        let stored: Data?
        do {
            stored = try await protectedFileStore.read(relativePath: path)
        } catch {
            throw FontCatalogError.protectedStorageUnavailable
        }
        guard let stored else {
            return nil
        }
        guard Self.digest(of: stored) == reference.sha256 else {
            throw FontCatalogError.corruptedStoredFont
        }
        return stored
    }

    /// Validates bytes, commits custom persistence, and then registers the
    /// process font. A registration failure restores the prior persisted state;
    /// a protected-file write failure occurs before any process-wide mutation.
    func importFont(_ bytes: Data, expecting reference: FontRef) async throws {
        await acquireMutationPermit()
        defer { releaseMutationPermit() }

        try validate(bytes, expecting: reference)
        _ = try await postScriptName(for: bytes)

        if reference == .bundled {
            try await registerValidated(
                bytes,
                digest: Self.digestHex(reference.sha256),
                validateName: false
            )
            return
        }

        let path = try Self.importedPath(for: reference)
        let previous: Data?
        do {
            previous = try await protectedFileStore.read(relativePath: path)
        } catch {
            throw FontCatalogError.protectedStorageUnavailable
        }

        let changedPersistence = previous != bytes
        if changedPersistence {
            do {
                try await protectedFileStore.write(bytes, relativePath: path)
            } catch {
                // Atomic replacement can reach disk before an adapter reports
                // failure. Continue only when an authoritative re-read proves
                // the intended content-addressed bytes were committed.
                let authoritative: Data?
                do {
                    authoritative = try await protectedFileStore.read(relativePath: path)
                } catch {
                    throw FontCatalogError.protectedStorageUnavailable
                }
                guard authoritative == bytes else {
                    throw FontCatalogError.protectedStorageUnavailable
                }
            }
        }

        do {
            try await registerValidated(
                bytes,
                digest: Self.digestHex(reference.sha256),
                validateName: false
            )
        } catch {
            guard changedPersistence else {
                throw error
            }
            do {
                try await restorePersistedFont(previous, at: path)
            } catch {
                throw FontCatalogError.rollbackFailed
            }
            throw error
        }
    }

    func ensureAvailable(reference: FontRef, suppliedBytes: Data?) async throws {
        if let suppliedBytes {
            try await importFont(suppliedBytes, expecting: reference)
            return
        }

        guard let bytes = try await data(for: reference) else {
            throw FontCatalogError.unavailableFont
        }
        await acquireMutationPermit()
        defer { releaseMutationPermit() }
        try await registerValidated(bytes, digest: Self.digestHex(reference.sha256))
    }

    func isRegistered(_ reference: FontRef) -> Bool {
        registeredNamesByDigest[Self.digestHex(reference.sha256)] != nil
    }

    func registeredPostScriptName(for reference: FontRef) -> String? {
        registeredNamesByDigest[Self.digestHex(reference.sha256)]
    }

    func registrationReport() -> FontCatalogRegistrationReport {
        lastRegistrationReport
    }

    func summary(for reference: FontRef) -> FontSummary {
        let digest = Self.digestHex(reference.sha256)
        let registeredName = registeredNamesByDigest[digest]
        let isBundled = reference == .bundled
        return FontSummary(
            id: FontID(rawValue: reference.id),
            displayName: isBundled
                ? Self.bundledDisplayName
                : (registeredName ?? reference.id),
            version: reference.version,
            contentHash: digest,
            source: isBundled ? .bundled : .imported,
            isRegistered: registeredName != nil
        )
    }

    private func bundledData() async throws -> Data {
        let bytes: Data
        do {
            bytes = try await resources.data(for: .bundledRuneFont)
        } catch {
            throw FontCatalogError.resourceUnavailable
        }
        guard Self.digest(of: bytes) == FontRef.bundled.sha256 else {
            throw FontCatalogError.hashMismatch
        }
        return bytes
    }

    private func validate(_ bytes: Data, expecting reference: FontRef) throws {
        guard reference.hasValidWireShape else {
            throw FontCatalogError.invalidReference
        }
        guard Self.digest(of: bytes) == reference.sha256 else {
            throw FontCatalogError.hashMismatch
        }
    }

    private func postScriptName(for bytes: Data) async throws -> String {
        do {
            let name = try await registrar.postScriptName(forFontData: bytes)
            guard !name.isEmpty else {
                throw FontCatalogError.unreadableFont
            }
            return name
        } catch let error as FontCatalogError {
            throw error
        } catch {
            throw FontCatalogError.unreadableFont
        }
    }

    private func registerValidated(
        _ bytes: Data,
        digest: String,
        validateName: Bool = true
    ) async throws {
        if validateName {
            _ = try await postScriptName(for: bytes)
        }
        do {
            let registered = try await registrar.registerFont(bytes)
            guard !registered.postScriptName.isEmpty else {
                throw FontCatalogError.cannotRegister
            }
            registeredNamesByDigest[digest] = registered.postScriptName
        } catch let error as FontCatalogError {
            throw error
        } catch {
            throw FontCatalogError.cannotRegister
        }
    }

    private func registerStoredFont(at path: ProtectedPath) async throws {
        let bytes: Data
        do {
            guard let stored = try await protectedFileStore.read(relativePath: path) else {
                throw FontCatalogError.corruptedStoredFont
            }
            bytes = stored
        } catch let error as FontCatalogError {
            throw error
        } catch {
            throw FontCatalogError.protectedStorageUnavailable
        }

        let expectedDigest = URL(fileURLWithPath: path.rawValue)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        let actualDigest = Self.digestHex(Self.digest(of: bytes))
        guard expectedDigest.count == 64,
              expectedDigest.allSatisfy(\.isHexDigit),
              expectedDigest == actualDigest
        else {
            throw FontCatalogError.corruptedStoredFont
        }
        try await registerValidated(bytes, digest: actualDigest)
    }

    /// Resolves an ambiguous rollback by re-reading the content-addressed path.
    /// A rollback adapter error is harmless when the prior bytes (or absence)
    /// are already authoritative; only an unresolved state becomes rollbackFailed.
    private func restorePersistedFont(
        _ previous: Data?,
        at path: ProtectedPath
    ) async throws {
        do {
            if let previous {
                try await protectedFileStore.write(previous, relativePath: path)
            } else {
                try await protectedFileStore.remove(relativePath: path)
            }
            return
        } catch {
            let authoritative: Data?
            do {
                authoritative = try await protectedFileStore.read(relativePath: path)
            } catch {
                throw FontCatalogError.rollbackFailed
            }
            guard authoritative == previous else {
                throw FontCatalogError.rollbackFailed
            }
        }
    }

    private static func registrationIssue(for error: Error) -> StoredFontRegistrationIssue {
        guard let error = error as? FontCatalogError else {
            return .unreadableEntry
        }
        switch error {
        case .protectedStorageUnavailable:
            return .unreadableEntry
        case .corruptedStoredFont, .hashMismatch, .invalidReference:
            return .invalidContentAddress
        case .unreadableFont:
            return .invalidFont
        case .cannotRegister:
            return .registrationFailed
        case .unavailableFont, .resourceUnavailable, .rollbackFailed:
            return .unreadableEntry
        }
    }

    private static func importedPath(for reference: FontRef) throws -> ProtectedPath {
        do {
            return try .fontsDirectory.appending("\(digestHex(reference.sha256)).ttf")
        } catch {
            throw FontCatalogError.invalidReference
        }
    }

    private static func digest(of bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    private static func digestHex(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func acquireMutationPermit() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutationPermit() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }
}
