import RuneScribeContracts
import RuneScribePlatform
import XCTest
@testable import RuneScrib

final class FontStoreTests: XCTestCase {
    func testLaunchRegistrationToleratesMissingImportedFontDirectory() {
        let root = temporaryDirectory(named: "MissingImportedFonts")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FontStore(
            files: AppleProtectedFileStore(applicationSupportDirectory: root)
        )

        store.registerBundledAndImportedFonts()

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("RuneScribFonts").path
            )
        )
    }

    func testLaunchRegistrationDoesNotMutatePersistedFontBytes() throws {
        let root = temporaryDirectory(named: "PersistedImportedFont")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = AppleProtectedFileStore(applicationSupportDirectory: root)
        let path = try ProtectedPath.fontsDirectory.appending("fixture.ttf")
        let bytes = Data([0x00, 0x01, 0x00, 0x00, 0x52, 0x46])
        try files.writeSynchronously(bytes, relativePath: path)

        FontStore(files: files).registerBundledAndImportedFonts()

        XCTAssertEqual(try files.readSynchronously(relativePath: path), bytes)
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("FontStoreTests-\(name)-\(UUID().uuidString)")
    }
}
