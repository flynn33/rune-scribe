import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import RuneScribePlatform
@testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
import XCTest

final class KeychainMigrationTests: XCTestCase {
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

    func testSimulatorLoadsFrozenLegacyLibraryThroughAppleKeychainStore() async throws {
        let key = try XCTUnwrap(Data(base64Encoded: Self.legacyKeyBase64))
        let encrypted = try XCTUnwrap(
            Data(base64Encoded: Self.legacyEncryptedLibraryBase64)
        )
        let namespacedService = [
            RuneScribeKeychain.service,
            "simulator-compatibility-tests",
            UUID().uuidString,
        ].joined(separator: ".")
        let appleStore = AppleKeychainStore()
        let store = CanonicalServiceMappingSecureValueStore(
            store: appleStore,
            namespacedService: namespacedService
        )
        addTeardownBlock {
            try await Self.deleteKeychainEntries(
                from: appleStore,
                service: namespacedService
            )
        }

        try await appleStore.set(
            key,
            service: namespacedService,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        try await appleStore.set(
            encrypted,
            service: namespacedService,
            account: RuneScribeKeychain.cipherLibraryAccount
        )

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
        do {
            var iterator = service.stateStream().makeAsyncIterator()
            let snapshotValue = await iterator.next()
            let snapshot = try XCTUnwrap(snapshotValue)
            let expectedCipherID = try XCTUnwrap(
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")
            )
            let summary = try XCTUnwrap(snapshot.cipherLibrary.ciphers.first)
            XCTAssertEqual(snapshot.cipherLibrary.ciphers.count, 1)
            XCTAssertEqual(snapshot.cipherLibrary.activeCipherID?.rawValue, expectedCipherID)
            XCTAssertEqual(summary.id.rawValue, expectedCipherID)
            XCTAssertEqual(summary.name, "Legacy Cipher")
            XCTAssertEqual(summary.assignedContactID?.rawValue, expectedContactID)
            XCTAssertTrue(summary.hasBeenDelivered)

            let encoded = try await service.encode(
                EncodeMessageCommand(
                    plaintext: "isolated Apple Keychain migration smoke",
                    cipherID: summary.id
                )
            )
            let decoded = try await service.decode(
                DecodeMessageCommand(runes: encoded.runes)
            )
            XCTAssertEqual(decoded.plaintext, "isolated Apple Keychain migration smoke")
            XCTAssertEqual(decoded.cipherID, summary.id)
            let storedKey = try await appleStore.data(
                service: namespacedService,
                account: RuneScribeKeychain.symmetricKeyAccount
            )
            let storedLibrary = try await appleStore.data(
                service: namespacedService,
                account: RuneScribeKeychain.cipherLibraryAccount
            )
            XCTAssertEqual(storedKey, key)
            XCTAssertEqual(storedLibrary, encrypted)

            await service.stopInboundProcessing()
            try await Self.deleteKeychainEntries(
                from: appleStore,
                service: namespacedService
            )
            for account in RuneScribeKeychain.accounts {
                let deletedValue = try await appleStore.data(
                    service: namespacedService,
                    account: account
                )
                XCTAssertNil(deletedValue)
            }
        } catch {
            await service.stopInboundProcessing()
            try? await Self.deleteKeychainEntries(
                from: appleStore,
                service: namespacedService
            )
            throw error
        }
    }

    private static func deleteKeychainEntries(
        from store: AppleKeychainStore,
        service: String
    ) async throws {
        var firstError: Error?
        for account in RuneScribeKeychain.accounts {
            do {
                try await store.delete(service: service, account: account)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError {
            throw firstError
        }
    }
}

private enum CanonicalServiceMappingSecureValueStoreError: Error {
    case unexpectedService
}

private struct CanonicalServiceMappingSecureValueStore: SecureValueStore {
    let store: AppleKeychainStore
    let namespacedService: String

    func data(service: String, account: String) async throws -> Data? {
        try await store.data(service: try mappedService(service), account: account)
    }

    func set(_ data: Data, service: String, account: String) async throws {
        try await store.set(data, service: try mappedService(service), account: account)
    }

    func delete(service: String, account: String) async throws {
        try await store.delete(service: try mappedService(service), account: account)
    }

    private func mappedService(_ service: String) throws -> String {
        guard service == RuneScribeKeychain.service else {
            throw CanonicalServiceMappingSecureValueStoreError.unexpectedService
        }
        return namespacedService
    }
}
