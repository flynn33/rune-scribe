import XCTest
import CryptoKit
@testable import RuneScrib

final class CompatibilityBaselineTests: XCTestCase {
    private static let encryptedContactBookBase64 = "oKGio6SlpqeoqaqrnToKSDe4a9AMR73iK1ijsR7YOHPmxGBWx3UE7xuJTyPiRnfPnxJjDXKsNPg5V7PJdytreFLgKlNxbjtulEC1gISMtV4SicaEnZGPdO63gtugbome54P4CYsZV/TUuGG2/+xExWbdraHF+S1hsL3YGRZjVZvoArlhA+27ydU8nj7nK+tdsSPzclswkO5SL+m35anBDpCzleHfkJHX3KhBWaV9PYuUByF492tHAEPw1ZMSR4n9ZifaHLiyC2Qhu77yzdD6MSN+2D5mOc60vQ=="

    private static let bundledFontSHA256 = Data([
        0x61, 0x5b, 0x6c, 0x11, 0x66, 0xa8, 0xc5, 0x18,
        0x16, 0xdc, 0x15, 0x36, 0x78, 0x4a, 0xcb, 0xf4,
        0x86, 0x54, 0x7e, 0x3b, 0xed, 0x03, 0xdb, 0xfd,
        0xd7, 0x09, 0x10, 0xe1, 0x00, 0x66, 0x79, 0x3b,
    ])

    func testEncryptedContactStoreGoldenFixtureLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribeCompatibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try XCTUnwrap(Data(base64Encoded: Self.encryptedContactBookBase64))
        try fixture.write(to: directory.appendingPathComponent("contacts.enc"), options: .atomic)

        let keyBytes = Data((0...31).map { UInt8($0) })
        let book = ContactStore(key: SymmetricKey(data: keyBytes), directory: directory).load()
        let expectedContact = Contact(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            displayName: "Baseline",
            phones: ["+15551234567"],
            emails: ["baseline@example.com"],
            source: .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: 0)
        )

        XCTAssertEqual(book.version, 1)
        XCTAssertEqual(book.contacts, [expectedContact])
    }

    func testBundledFontMatchesFixedSHA256() throws {
        let fontURL = try XCTUnwrap(
            Bundle(for: CompatibilityBaselineTests.self)
                .url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
                ?? Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
        )
        let digest = Data(SHA256.hash(data: try Data(contentsOf: fontURL)))

        XCTAssertEqual(digest, Self.bundledFontSHA256)
    }

    func testPINGoldenVector() {
        let salt = Data((0...15).map { UInt8($0) })
        let expected = Data([
            0x50, 0x70, 0x32, 0x1c, 0xa3, 0x4d, 0xbd, 0xaf,
            0xe9, 0xb2, 0x53, 0x71, 0xd1, 0xc0, 0xf8, 0x3b,
            0xca, 0xfe, 0x07, 0x3f, 0xba, 0xe1, 0xf2, 0x27,
            0x4f, 0x00, 0xa6, 0xd6, 0xc6, 0x8e, 0x98, 0x99,
        ])

        XCTAssertEqual(
            AppLock.deriveHash(pin: "1234", salt: salt, iterations: 120_000),
            expected
        )
    }
}
