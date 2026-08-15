import XCTest
import CryptoKit
import Foundation
import Metal
import RuneScribeContracts
@testable import RuneScribeCoreModule
import RuneScribePlatform
@testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
@testable import RuneScrib

final class CompatibilityBaselineTests: XCTestCase {
    private static let bundledFontSHA256 = Data([
        0x61, 0x5b, 0x6c, 0x11, 0x66, 0xa8, 0xc5, 0x18,
        0x16, 0xdc, 0x15, 0x36, 0x78, 0x4a, 0xcb, 0xf4,
        0x86, 0x54, 0x7e, 0x3b, 0xed, 0x03, 0xdb, 0xfd,
        0xd7, 0x09, 0x10, 0xe1, 0x00, 0x66, 0x79, 0x3b,
    ])
    private static let legacyKeyBase64 =
        "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
    private static let legacyEncryptedLibraryBase64 =
        "oKGio6SlpqeoqaqrnToKSDe4a9AMR73iK1ijtwDEPGLhlXg35yxP4l2RVzDjR3bO" +
        "nhNiEG2uNvokSbDKdDZyfFbkN0t0az5rkUWwhYGJsE0ch4iBloeTOrXsgN+qasjd" +
        "5YLwCoYQTLiduCLm5uNCxSGUrfz7tWMi5PyITAZ8Q82sUPpISquf0JZv0H/1I4R" +
        "S43OtJwUNzrgoeqXsuOz3SZLynOOPoNyB+aJGWK93cZOMW2w08n9JTgax/6VVHN/" +
        "ZUy/qfMPXMXsr5SJ1GBQnrBmc2pmWLymuJQYIlxuqoYFmGonUp6g7ihaVtRUkEg" +
        "JU9ReYR43WD28MXxlMRPmpCcYoB747x5VXRx8K9nJcpvWOuMuWA+429RdSArQaK1" +
        "FjipbwGtRVL/bQiKgfrGR0lAwwSOHXWWIewIO0bPQl73k5Vu+SS4xclbm8gi/k6D" +
        "/hy1kEI7/pWCWmNviWSu+3Ibp3G8h0KLj8RA/oeW0gjmL6AARop+0h+hzNZ5yoi" +
        "ixr/h9rpIY+b36yk7zEWarPSdgw420RO4ZECdvNuWyOc/bzAbRXCJ3OqV5URAG9Y" +
        "xkeOsS33UIWW6yoCLsoWImrxAXx7jm5EuPRigZlnCKXh5uXi6G1nvu7GJoNIKbl/" +
        "YosXWDhFFjUoAP9f/mwF7nIFdpEP8LPfj1r+zE6eCiY8vw1tJhOpwJRpb2aVEkE" +
        "cvfgEjB6cdwHgfWK8PkpYJfv7vDLRaByzAvL7OesCEgNmoTp1p5sTK6ycPFy9Kc" +
        "QrsGhSp1NJZMfMHUL9o2COYKCo/IFn7jqMuwqWa6MSHzEdKUtIH7Iow=="

    func testBundledFontMatchesFixedSHA256() throws {
        let fontURL = try XCTUnwrap(
            Bundle(for: CompatibilityBaselineTests.self)
                .url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
                ?? Bundle.main.url(forResource: "NotoSansRunic-Regular", withExtension: "ttf")
        )
        let digest = Data(SHA256.hash(data: try Data(contentsOf: fontURL)))

        XCTAssertEqual(digest, Self.bundledFontSHA256)
    }

    func testSplashAndMetalLibraryRemainHostResources() throws {
        let testBundle = Bundle(for: CompatibilityBaselineTests.self)
        let splashURL = try XCTUnwrap(
            testBundle.url(
                forResource: "raven-forge-spp-splash",
                withExtension: "mp4"
            ) ?? Bundle.main.url(
                forResource: "raven-forge-spp-splash",
                withExtension: "mp4"
            )
        )
        XCTAssertGreaterThan(try Data(contentsOf: splashURL).count, 0)

        let libraryURL = try XCTUnwrap(
            testBundle.url(forResource: "default", withExtension: "metallib")
                ?? Bundle.main.url(forResource: "default", withExtension: "metallib")
        )
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(URL: libraryURL)
        XCTAssertNotNil(library.makeFunction(name: "vertex_fullscreen"))
        XCTAssertNotNil(library.makeFunction(name: "fragment_rune_background"))
    }

    func testSignedHostLoadsFrozenLegacyKeychainLibraryAndActiveSelection() async throws {
        let key = try XCTUnwrap(Data(base64Encoded: Self.legacyKeyBase64))
        let encrypted = try XCTUnwrap(
            Data(base64Encoded: Self.legacyEncryptedLibraryBase64)
        )
        let keyLocation = SecureValueLocation(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        let libraryLocation = SecureValueLocation(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
        let store = InMemorySecureValueStore(values: [
            keyLocation: key,
            libraryLocation: encrypted,
        ])
        let protectedFiles = InMemoryProtectedFileStore()
        let shareArtifacts = InMemoryShareArtifactStore()
        let clock = SystemClock()
        let uuid = SystemUUIDProvider()
        let runtimeIO = RuntimeIOClient(
            secureValueData: {
                try await store.data(service: $0, account: $1)
            },
            setSecureValue: {
                try await store.set($0, service: $1, account: $2)
            },
            deleteSecureValue: {
                try await store.delete(service: $0, account: $1)
            },
            readProtectedFile: {
                try await protectedFiles.read(relativePath: $0)
            },
            writeProtectedFile: {
                try await protectedFiles.write($0, relativePath: $1)
            },
            removeProtectedFile: {
                try await protectedFiles.remove(relativePath: $0)
            },
            protectedFileExists: {
                try await protectedFiles.exists(relativePath: $0)
            },
            protectedFileContents: {
                try await protectedFiles.contents(of: $0, matchingExtension: $1)
            },
            now: { clock.now() },
            nextUUID: { uuid.nextUUID() },
            createShareArtifact: {
                try await shareArtifacts.create(
                    $0,
                    artifactID: $1,
                    filename: $2,
                    fileExtension: $3
                )
            },
            storeShareArtifactLink: {
                try await shareArtifacts.storeLink($0, artifactID: $1)
            },
            removeShareArtifactLink: {
                try await shareArtifacts.removeLink(artifactID: $0)
            },
            removeShareArtifact: { try await shareArtifacts.remove(artifactID: $0) },
            removeAllShareArtifacts: { try await shareArtifacts.removeAll() }
        )
        let expectedContactID = try XCTUnwrap(
            UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
        let contactRepository = EncryptedContactRepository(runtimeIO: runtimeIO)
        _ = try await contactRepository.replace(ContactBook(contacts: [
            Contact(
                id: expectedContactID,
                displayName: "Legacy Contact",
                source: .manual,
                createdAt: Date(timeIntervalSince1970: 1_704_164_645)
            ),
        ]))
        let service = RuneScribeCoreApplicationService(runtimeIO: runtimeIO)

        await service.startInboundProcessing()
        var iterator = service.stateStream().makeAsyncIterator()
        let snapshotValue = await iterator.next()
        let snapshot = try XCTUnwrap(snapshotValue)
        let expectedCipherID = try XCTUnwrap(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let summary = try XCTUnwrap(snapshot.cipherLibrary.ciphers.first)
        XCTAssertEqual(snapshot.cipherLibrary.activeCipherID?.rawValue, expectedCipherID)
        XCTAssertEqual(summary.id.rawValue, expectedCipherID)
        XCTAssertEqual(summary.name, "Legacy Cipher")
        XCTAssertEqual(summary.assignedContactID?.rawValue, expectedContactID)
        XCTAssertTrue(summary.hasBeenDelivered)

        let encoded = try await service.encode(
            EncodeMessageCommand(
                plaintext: "signed migration smoke",
                cipherID: summary.id
            )
        )
        let decoded = try await service.decode(
            DecodeMessageCommand(runes: encoded.runes)
        )
        XCTAssertEqual(decoded.plaintext, "signed migration smoke")
        XCTAssertEqual(decoded.cipherID, summary.id)
        let storedKey = try await store.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        let storedLibrary = try await store.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.cipherLibraryAccount
        )
        XCTAssertEqual(storedKey, key)
        XCTAssertEqual(storedLibrary, encrypted)
        await service.stopInboundProcessing()
    }

}
