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

    func testRuneFontResolvesToBundledName() {
        FontStore.shared.registerBundledAndImportedFonts()
        XCTAssertEqual(RuneFont.name(for: nil), "Noto Sans Runic")
        XCTAssertEqual(RuneFont.name(for: Cipher.generated(label: "x")), "Noto Sans Runic")
    }
}
