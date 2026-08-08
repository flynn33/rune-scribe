import CryptoKit
import Foundation
import RuneScribeContracts
import XCTest
@testable import RuneScrib

@MainActor
final class FontStoreTests: XCTestCase {
    func testLaunchBridgeTriggersCoreRegistrationWithoutCreatingImportedDirectory() async throws {
        let context = try TestApplicationFactory.makeIntegratedContext()
        let store = FontStore(applicationService: context.service)

        store.registerBundledAndImportedFonts()
        await waitUntil {
            await context.fontRegistrar.isRegistered(context.bundledFontData)
        }

        let directoryExists = try await context.protectedFiles.exists(
            relativePath: .fontsDirectory
        )
        XCTAssertFalse(directoryExists)
    }

    func testLaunchBridgeRegistersButDoesNotMutatePersistedCustomFontBytes() async throws {
        let bytes = Data("persisted-font-fixture".utf8)
        let digest = Data(SHA256.hash(data: bytes))
        let name = digest.map { String(format: "%02x", $0) }.joined() + ".ttf"
        let path = try ProtectedPath.fontsDirectory.appending(name)
        let context = try TestApplicationFactory.makeIntegratedContext(
            protectedFiles: [path: bytes],
            additionalFontNames: [bytes: "PersistedFixture"]
        )
        let store = FontStore(applicationService: context.service)

        store.registerBundledAndImportedFonts()
        await waitUntil {
            await context.fontRegistrar.isRegistered(bytes)
        }

        let persisted = try await context.protectedFiles.read(relativePath: path)
        XCTAssertEqual(persisted, bytes)
    }

    private func waitUntil(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<500 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for font registration", file: file, line: line)
    }
}
