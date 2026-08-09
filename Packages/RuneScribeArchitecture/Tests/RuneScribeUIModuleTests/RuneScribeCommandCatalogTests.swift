import RuneScribeContracts
@testable import RuneScribeUIModule
import XCTest

final class RuneScribeCommandCatalogTests: XCTestCase {
    func testMacCommandSurfaceAndPrimaryShortcutRemainExact() {
        XCTAssertTrue(RuneScribeCommandCatalog.removesSystemNewItem)
        XCTAssertEqual(
            RuneScribeCommandCatalog.settings,
            RuneScribeCommandDescriptor(
                title: "Settings…",
                command: .openSettings,
                key: .character(","),
                modifiers: [.command]
            )
        )
        XCTAssertEqual(
            RuneScribeCommandCatalog.cipherLibrary,
            RuneScribeCommandDescriptor(
                title: "Cipher Library…",
                command: .openCipherLibrary,
                key: .character("l"),
                modifiers: [.command, .shift]
            )
        )
        XCTAssertEqual(
            RuneScribeCommandCatalog.primaryAction,
            RuneScribeCommandDescriptor(
                title: "Rune Scribe",
                command: nil,
                key: .returnKey,
                modifiers: [.command]
            )
        )
    }
}
