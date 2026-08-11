import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
@testable import RuneScribeRuntimeCore
import XCTest

final class FontCatalogTests: XCTestCase {
    func testRegistersFixedBundledIdentityThroughInjectedResourceAndRegistrar() async throws {
        let bytes = try bundledFontData()
        XCTAssertEqual(Data(SHA256.hash(data: bytes)), FontRef.bundled.sha256)
        let registrar = FontRegistrarFake(names: [bytes: "Noto Sans Runic"])
        let catalog = FontCatalog(
            protectedFileStore: FontFileStore(),
            registrar: registrar,
            resources: FontResourceLocatorFake(values: [.bundledRuneFont: bytes])
        )

        try await catalog.registerAvailableFonts()

        let isRegistered = await catalog.isRegistered(.bundled)
        let name = await catalog.registeredPostScriptName(for: .bundled)
        let summary = await catalog.summary(for: .bundled)
        let registered = await registrar.registeredBytes()
        XCTAssertTrue(isRegistered)
        XCTAssertEqual(name, "Noto Sans Runic")
        XCTAssertEqual(summary.id, .bundledRuneFont)
        XCTAssertEqual(summary.contentHash, Self.hex(FontRef.bundled.sha256))
        XCTAssertTrue(summary.isRegistered)
        XCTAssertEqual(registered, [bytes])
    }

    func testEnsuringRegisteredBundledFontDoesNotRegisterItAgain() async throws {
        let bytes = try bundledFontData()
        let registrar = FontRegistrarFake(names: [bytes: "Noto Sans Runic"])
        let catalog = FontCatalog(
            protectedFileStore: FontFileStore(),
            registrar: registrar,
            resources: FontResourceLocatorFake(values: [.bundledRuneFont: bytes])
        )

        try await catalog.registerAvailableFonts()
        try await catalog.ensureAvailable(reference: .bundled, suppliedBytes: nil)

        let lookups = await registrar.nameLookupBytes()
        let registrations = await registrar.registeredBytes()
        XCTAssertEqual(lookups, [bytes])
        XCTAssertEqual(registrations, [bytes])
    }

    func testCorruptCustomEntryIsQuarantinedWithoutBlockingValidFontRegistration() async throws {
        let bundled = try bundledFontData()
        let valid = Data("valid-persisted-font".utf8)
        let validDigest = Self.digest(valid)
        let validPath = try Self.path(
            for: FontRef(id: "valid-font", version: 1, sha256: validDigest)
        )
        let corruptPath = try ProtectedPath.fontsDirectory.appending(
            "\(String(repeating: "0", count: 64)).ttf"
        )
        let files = FontFileStore(files: [
            corruptPath: Data("corrupt".utf8),
            validPath: valid,
        ])
        let registrar = FontRegistrarFake(names: [
            bundled: "Noto Sans Runic",
            valid: "ValidPersistedFont",
        ])
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake(values: [.bundledRuneFont: bundled])
        )

        let report = try await catalog.registerAvailableFonts()

        let registered = await registrar.registeredBytes()
        let storedReport = await catalog.registrationReport()
        XCTAssertEqual(report.registeredCustomCount, 1)
        XCTAssertEqual(report.skipped, [.invalidContentAddress])
        XCTAssertTrue(registered.contains(bundled))
        XCTAssertTrue(registered.contains(valid))
        XCTAssertFalse(registered.contains(Data("corrupt".utf8)))
        XCTAssertEqual(storedReport, report)
    }

    func testCustomImportUsesContentDigestPathAndRoundTrips() async throws {
        let bytes = Data("custom-font-fixture".utf8)
        let reference = FontRef(id: "custom-runes", version: 2, sha256: Self.digest(bytes))
        let files = FontFileStore()
        let registrar = FontRegistrarFake(names: [bytes: "CustomRunes"])
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        try await catalog.importFont(bytes, expecting: reference)

        let path = try Self.path(for: reference)
        let persisted = await files.data(at: path)
        let resolved = try await catalog.resolve(reference)
        let loaded = try await catalog.data(for: reference)
        XCTAssertEqual(persisted, bytes)
        XCTAssertEqual(resolved, "CustomRunes")
        XCTAssertEqual(loaded, bytes)
        XCTAssertEqual(path.rawValue, "RuneScribFonts/\(Self.hex(reference.sha256)).ttf")
    }

    func testHashMismatchDoesNotWriteOrRegister() async throws {
        let bytes = Data("untrusted-font".utf8)
        let reference = FontRef(
            id: "custom-runes",
            version: 1,
            sha256: Data(repeating: 0x44, count: 32)
        )
        let files = FontFileStore()
        let registrar = FontRegistrarFake(names: [bytes: "CustomRunes"])
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .hashMismatch)
        }

        let writes = await files.writePaths()
        let registered = await registrar.registeredBytes()
        XCTAssertEqual(writes, [])
        XCTAssertEqual(registered, [])
    }

    func testProtectedWriteFailureOccursBeforeRegistration() async throws {
        let bytes = Data("write-failure-font".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let files = FontFileStore()
        await files.setWriteFailure(true)
        let registrar = FontRegistrarFake(names: [bytes: "CustomRunes"])
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .protectedStorageUnavailable)
        }

        let registered = await registrar.registeredBytes()
        XCTAssertEqual(registered, [])
    }

    func testInitialWriteCommitThenErrorContinuesRegistration() async throws {
        let bytes = Data("ambiguous-write-font".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let path = try Self.path(for: reference)
        let files = FontFileStore()
        await files.setWriteThenFail(number: 1)
        let registrar = FontRegistrarFake(names: [bytes: "AmbiguousWriteFont"])
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        try await catalog.importFont(bytes, expecting: reference)

        let persisted = await files.data(at: path)
        let registered = await registrar.registeredBytes()
        XCTAssertEqual(persisted, bytes)
        XCTAssertEqual(registered, [bytes])
    }

    func testRegistrationFailureRemovesNewlyPersistedBytes() async throws {
        let bytes = Data("registration-failure-font".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let path = try Self.path(for: reference)
        let files = FontFileStore()
        let registrar = FontRegistrarFake(
            names: [bytes: "CustomRunes"],
            rejectedRegistrations: [bytes]
        )
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .cannotRegister)
        }

        let persisted = await files.data(at: path)
        let removals = await files.removePaths()
        XCTAssertNil(persisted)
        XCTAssertEqual(removals, [path])
    }

    func testRegistrationFailureRestoresPriorPersistedBytes() async throws {
        let bytes = Data("replacement-font".utf8)
        let prior = Data("prior-corrupt-content".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let path = try Self.path(for: reference)
        let files = FontFileStore(files: [path: prior])
        let registrar = FontRegistrarFake(
            names: [bytes: "CustomRunes"],
            rejectedRegistrations: [bytes]
        )
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .cannotRegister)
        }

        let persisted = await files.data(at: path)
        XCTAssertEqual(persisted, prior)
    }

    func testRollbackWriteCommitThenErrorRestoresPriorAndSurfacesRegistrationError() async throws {
        let bytes = Data("rollback-write-ambiguous-font".utf8)
        let prior = Data("prior-content".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let path = try Self.path(for: reference)
        let files = FontFileStore(files: [path: prior])
        await files.setWriteThenFail(number: 2)
        let registrar = FontRegistrarFake(
            names: [bytes: "RollbackWriteFont"],
            rejectedRegistrations: [bytes]
        )
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .cannotRegister)
        }

        let persisted = await files.data(at: path)
        XCTAssertEqual(persisted, prior)
    }

    func testRollbackRemoveCommitThenErrorSurfacesRegistrationError() async throws {
        let bytes = Data("rollback-remove-ambiguous-font".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let path = try Self.path(for: reference)
        let files = FontFileStore()
        await files.setRemoveThenFail(true)
        let registrar = FontRegistrarFake(
            names: [bytes: "RollbackRemoveFont"],
            rejectedRegistrations: [bytes]
        )
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .cannotRegister)
        }

        let persisted = await files.data(at: path)
        XCTAssertNil(persisted)
    }

    func testRegistrationRollbackFailureIsTypedAndLeavesFailureVisible() async throws {
        let bytes = Data("rollback-failure-font".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(bytes))
        let path = try Self.path(for: reference)
        let files = FontFileStore()
        await files.setRemoveFailure(true)
        let registrar = FontRegistrarFake(
            names: [bytes: "CustomRunes"],
            rejectedRegistrations: [bytes]
        )
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.importFont(bytes, expecting: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .rollbackFailed)
        }

        let persisted = await files.data(at: path)
        XCTAssertEqual(persisted, bytes)
    }

    func testCorruptPersistedBytesAreRejectedBeforeFontParsing() async throws {
        let valid = Data("expected-font".utf8)
        let corrupt = Data("different-font".utf8)
        let reference = FontRef(id: "custom-runes", version: 1, sha256: Self.digest(valid))
        let path = try Self.path(for: reference)
        let files = FontFileStore(files: [path: corrupt])
        let registrar = FontRegistrarFake(names: [corrupt: "WrongFont"])
        let catalog = FontCatalog(
            protectedFileStore: files,
            registrar: registrar,
            resources: FontResourceLocatorFake()
        )

        await XCTAssertFontThrows(try await catalog.data(for: reference)) {
            XCTAssertEqual($0 as? FontCatalogError, .corruptedStoredFont)
        }

        let nameLookups = await registrar.nameLookupBytes()
        XCTAssertEqual(nameLookups, [])
    }

    private func bundledFontData() throws -> Data {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            repository.deleteLastPathComponent()
        }
        let font = repository
            .appendingPathComponent("RuneScrib")
            .appendingPathComponent("Resources")
            .appendingPathComponent("Fonts")
            .appendingPathComponent("NotoSansRunic-Regular.ttf")
        return try Data(contentsOf: font)
    }

    private static func digest(_ bytes: Data) -> Data {
        Data(SHA256.hash(data: bytes))
    }

    private static func hex(_ digest: Data) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func path(for reference: FontRef) throws -> ProtectedPath {
        try .fontsDirectory.appending("\(hex(reference.sha256)).ttf")
    }
}

private extension FontCatalog {
    init(
        protectedFileStore: any ProtectedFileStore,
        registrar: any SystemFontRegistrar,
        resources: any ApplicationResourceLocator
    ) {
        self.init(
            runtimeIO: RuntimeIOClient(
                readProtectedFile: {
                    try await protectedFileStore.read(relativePath: $0)
                },
                writeProtectedFile: {
                    try await protectedFileStore.write($0, relativePath: $1)
                },
                removeProtectedFile: {
                    try await protectedFileStore.remove(relativePath: $0)
                },
                protectedFileExists: {
                    try await protectedFileStore.exists(relativePath: $0)
                },
                protectedFileContents: {
                    try await protectedFileStore.contents(
                        of: $0,
                        matchingExtension: $1
                    )
                },
                registerBundledSystemFont: {
                    let data = try await resources.data(for: $0)
                    guard Data(SHA256.hash(data: data)) == $1 else {
                        throw RuntimeBundledFontFailure.integrityMismatch
                    }
                    let postScriptName = try await registrar.postScriptName(
                        forFontData: data
                    )
                    guard !postScriptName.isEmpty else {
                        throw RuntimeBundledFontFailure.unreadableFont
                    }
                    return try await registrar.registerFont(data)
                },
                systemFontPostScriptName: {
                    try await registrar.postScriptName(forFontData: $0)
                },
                registerSystemFont: {
                    try await registrar.registerFont($0)
                }
            )
        )
    }
}

private actor FontFileStore: ProtectedFileStore {
    private var files: [ProtectedPath: Data]
    private var writes: [ProtectedPath] = []
    private var removals: [ProtectedPath] = []
    private var failWrites = false
    private var failRemovals = false
    private var writeThenFailNumber: Int?
    private var removeThenFail = false

    init(files: [ProtectedPath: Data] = [:]) {
        self.files = files
    }

    func read(relativePath: ProtectedPath) async throws -> Data? {
        files[relativePath]
    }

    func write(_ data: Data, relativePath: ProtectedPath) async throws {
        guard !failWrites else { throw FontFakeFailure.failed }
        writes.append(relativePath)
        files[relativePath] = data
        if writes.count == writeThenFailNumber { throw FontFakeFailure.failed }
    }

    func remove(relativePath: ProtectedPath) async throws {
        guard !failRemovals else { throw FontFakeFailure.failed }
        removals.append(relativePath)
        files.removeValue(forKey: relativePath)
        if removeThenFail { throw FontFakeFailure.failed }
    }

    func exists(relativePath: ProtectedPath) async throws -> Bool {
        files[relativePath] != nil
    }

    func contents(
        of directory: ProtectedPath,
        matchingExtension fileExtension: String?
    ) async throws -> [ProtectedPath] {
        let prefix = directory.rawValue + "/"
        return files.keys.filter { path in
            path.rawValue.hasPrefix(prefix)
                && (fileExtension == nil
                    || URL(fileURLWithPath: path.rawValue).pathExtension == fileExtension)
        }.sorted()
    }

    func setWriteFailure(_ value: Bool) { failWrites = value }
    func setRemoveFailure(_ value: Bool) { failRemovals = value }
    func setWriteThenFail(number: Int?) { writeThenFailNumber = number }
    func setRemoveThenFail(_ value: Bool) { removeThenFail = value }
    func data(at path: ProtectedPath) -> Data? { files[path] }
    func writePaths() -> [ProtectedPath] { writes }
    func removePaths() -> [ProtectedPath] { removals }
}

private actor FontRegistrarFake: SystemFontRegistrar {
    private let names: [Data: String]
    private let rejectedRegistrations: Set<Data>
    private var lookups: [Data] = []
    private var registrations: [Data] = []

    init(names: [Data: String], rejectedRegistrations: Set<Data> = []) {
        self.names = names
        self.rejectedRegistrations = rejectedRegistrations
    }

    func postScriptName(forFontData data: Data) async throws -> String {
        lookups.append(data)
        guard let name = names[data] else { throw FontFakeFailure.failed }
        return name
    }

    func registerFont(_ data: Data) async throws -> RegisteredFontDTO {
        guard !rejectedRegistrations.contains(data), let name = names[data] else {
            throw FontFakeFailure.failed
        }
        registrations.append(data)
        return RegisteredFontDTO(postScriptName: name)
    }

    func nameLookupBytes() -> [Data] { lookups }
    func registeredBytes() -> [Data] { registrations }
}

private struct FontResourceLocatorFake: ApplicationResourceLocator {
    let values: [ApplicationResource: Data]

    init(values: [ApplicationResource: Data] = [:]) {
        self.values = values
    }

    func data(for resource: ApplicationResource) async throws -> Data {
        guard let data = values[resource] else { throw FontFakeFailure.failed }
        return data
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        _ = resource
        throw FontFakeFailure.failed
    }
}

private enum FontFakeFailure: Error {
    case failed
}

private func XCTAssertFontThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
