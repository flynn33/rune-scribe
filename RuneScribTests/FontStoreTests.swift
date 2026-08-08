import CryptoKit
import RuneScribePlatform
import XCTest
@testable import RuneScrib

final class FontStoreTests: XCTestCase {
    func testResolveBundledRefReturnsRegisteredName() {
        let store = FontStore.shared
        store.registerBundledAndImportedFonts()
        XCTAssertEqual(store.resolve(.bundled), "Noto Sans Runic")
    }

    func testImportBundledBytesValidates() throws {
        let store = FontStore.shared
        XCTAssertNoThrow(try store.importFont(FontRef.bundledFontData(), expecting: .bundled))
    }

    func testImportRejectsCorruptBytes() {
        let store = FontStore.shared
        XCTAssertThrowsError(try store.importFont(Data([0, 1, 2, 3]), expecting: .bundled))
    }

    func testImportRejectsHashMismatch() {
        let store = FontStore.shared
        let wrongRef = FontRef(id: "noto-sans-runic", version: 1, sha256: Data(repeating: 0xAB, count: 32))
        XCTAssertThrowsError(try store.importFont(FontRef.bundledFontData(), expecting: wrongRef))
    }

    func testRegistrationFailureDoesNotPersistCustomFont() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontStoreRegistrationFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = FontRef.bundledFontData()
        let ref = FontRef(
            id: "registration-failure",
            version: 1,
            sha256: Data(SHA256.hash(data: bytes))
        )
        let store = FontStore(
            registrar: RejectingFontRegistrationService(),
            files: AppleProtectedFileStore(applicationSupportDirectory: root)
        )

        XCTAssertThrowsError(try store.importFont(bytes, expecting: ref)) { error in
            XCTAssertEqual(error as? FontStoreError, .cannotRegister)
        }
        XCTAssertNil(store.fontData(for: ref))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("RuneScribFonts").path
            )
        )
    }

    func testRuneFontResolvesToBundledName() {
        FontStore.shared.registerBundledAndImportedFonts()
        XCTAssertEqual(RuneFont.name(for: nil), "Noto Sans Runic")
        XCTAssertEqual(RuneFont.name(for: Cipher.generated(label: "x")), "Noto Sans Runic")
    }
}

private struct RejectingFontRegistrationService: FontRegistrationService {
    private enum Failure: Error {
        case rejected
    }

    func postScriptName(for data: Data) throws -> String {
        "RegistrationFailure-Regular"
    }

    func register(_ data: Data) throws {
        throw Failure.rejected
    }
}
