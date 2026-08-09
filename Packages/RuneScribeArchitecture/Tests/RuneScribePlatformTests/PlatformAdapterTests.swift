import Foundation
import os
import RuneScribeContracts
import Security
@testable import RuneScribePlatform
import RuneScribeTestSupport
import XCTest

final class PlatformAdapterTests: XCTestCase {
    func testKeychainConstantsAndDeleteThenAddCompatibility() async throws {
        XCTAssertEqual(RuneScribeKeychain.service, "com.runescribe.keystore")
        XCTAssertEqual(
            RuneScribeKeychain.accounts,
            ["symmetricKey", "cipherLibrary", "appPin", "pinThrottle"]
        )

        let operations = RecordingKeychainOperations()
        let store = AppleKeychainStore(operations: operations)
        let payload = Data([0x01, 0x02, 0x03])

        try await store.set(
            payload,
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )

        XCTAssertEqual(
            operations.calls,
            [
                .delete(
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.symmetricKeyAccount
                ),
                .add(
                    data: payload,
                    service: RuneScribeKeychain.service,
                    account: RuneScribeKeychain.symmetricKeyAccount,
                    accessibility: .whenUnlockedThisDeviceOnly
                ),
            ]
        )
        let storedPayload = try await store.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        XCTAssertEqual(storedPayload, payload)

        try await store.delete(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        let deletedPayload = try await store.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.symmetricKeyAccount
        )
        XCTAssertNil(deletedPayload)
    }

    func testKeychainErrorsAreTypedAndContainNoValues() async throws {
        let deleteFailure = OSStatus(-34018)
        let operations = RecordingKeychainOperations(forcedDeleteStatus: deleteFailure)
        let store = AppleKeychainStore(operations: operations)

        do {
            try await store.set(
                Data("secret marker".utf8),
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.appPINAccount
            )
            XCTFail("Expected the injected delete failure")
        } catch {
            XCTAssertEqual(error as? AppleKeychainStoreError, .deleteFailed(deleteFailure))
            XCTAssertFalse(error.localizedDescription.contains("secret marker"))
        }

        let malformed = AppleKeychainStore(
            operations: RecordingKeychainOperations(
                forcedReadStatus: errSecSuccess,
                forcedReadData: nil
            )
        )
        do {
            _ = try await malformed.data(
                service: RuneScribeKeychain.service,
                account: RuneScribeKeychain.cipherLibraryAccount
            )
            XCTFail("Expected malformed Keychain data to be rejected")
        } catch {
            XCTAssertEqual(error as? AppleKeychainStoreError, .unexpectedDataFormat)
        }
    }

    func testProtectedFileStorePreservesPathsAndListsImportedFonts() async throws {
        let root = temporaryDirectory(named: "ProtectedFiles")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppleProtectedFileStore(applicationSupportDirectory: root)

        let missingContacts = try await store.read(relativePath: .contacts)
        XCTAssertNil(missingContacts)
        let contacts = Data([0x43, 0x54])
        try await store.write(contacts, relativePath: .contacts)
        let persistedContacts = try await store.read(relativePath: .contacts)
        XCTAssertEqual(persistedContacts, contacts)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("RuneScribContacts/contacts.enc")),
            contacts
        )

        let firstFont = try ProtectedPath.fontsDirectory.appending("a.ttf")
        let secondFont = try ProtectedPath.fontsDirectory.appending("b.ttf")
        let ignored = try ProtectedPath.fontsDirectory.appending("notes.txt")
        try await store.write(Data([1]), relativePath: secondFont)
        try await store.write(Data([2]), relativePath: ignored)
        try await store.write(Data([3]), relativePath: firstFont)

        let fontContents = try await store.contents(
            of: .fontsDirectory,
            matchingExtension: "ttf"
        )
        XCTAssertEqual(fontContents, [firstFont, secondFont])
        let fontsDirectoryExists = try await store.exists(relativePath: .fontsDirectory)
        XCTAssertTrue(fontsDirectoryExists)
        try await store.remove(relativePath: firstFont)
        let firstFontExists = try await store.exists(relativePath: firstFont)
        let removedFont = try await store.read(relativePath: firstFont)
        XCTAssertFalse(firstFontExists)
        XCTAssertNil(removedFont)
    }

    func testProtectedFileStoreRejectsSymlinkedDirectoryForEveryOperation() async throws {
        let root = temporaryDirectory(named: "SymlinkRoot")
        let outside = temporaryDirectory(named: "SymlinkOutside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let outsideFile = outside.appendingPathComponent("contacts.enc")
        let outsideData = Data([0xAA, 0xBB])
        try outsideData.write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("RuneScribContacts"),
            withDestinationURL: outside
        )

        let store = AppleProtectedFileStore(applicationSupportDirectory: root)
        await assertAsyncThrows {
            try await store.read(relativePath: .contacts)
        }
        XCTAssertEqual(try Data(contentsOf: outsideFile), outsideData)
        try FileManager.default.removeItem(at: outsideFile)
        await assertAsyncThrows {
            try await store.write(Data([0x01]), relativePath: .contacts)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideFile.path))
        await assertAsyncThrows {
            try await store.exists(relativePath: .contacts)
        }
        await assertAsyncThrows {
            try await store.remove(relativePath: .contacts)
        }
        let contactDirectory = try ProtectedPath(validating: "RuneScribContacts")
        await assertAsyncThrows {
            try await store.contents(of: contactDirectory, matchingExtension: nil)
        }
    }

    func testProtectedFileStoreSkipsSymlinkEntriesAndAllowsSafeMissingLeaf() async throws {
        let root = temporaryDirectory(named: "SymlinkListingRoot")
        let outside = temporaryDirectory(named: "SymlinkListingOutside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let fontDirectory = root.appendingPathComponent("RuneScribFonts", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fontDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let outsideFont = outside.appendingPathComponent("outside.ttf")
        let outsideData = Data([0x10, 0x20])
        try outsideData.write(to: outsideFont)

        let linkedFontURL = fontDirectory.appendingPathComponent("linked.ttf")
        try FileManager.default.createSymbolicLink(
            at: linkedFontURL,
            withDestinationURL: outsideFont
        )
        try FileManager.default.createSymbolicLink(
            at: fontDirectory.appendingPathComponent("broken.ttf"),
            withDestinationURL: outside.appendingPathComponent("missing.ttf")
        )

        let store = AppleProtectedFileStore(applicationSupportDirectory: root)
        let safePath = try ProtectedPath.fontsDirectory.appending("safe.ttf")
        try await store.write(Data([0x30]), relativePath: safePath)
        let contents = try await store.contents(
            of: .fontsDirectory,
            matchingExtension: "ttf"
        )
        XCTAssertEqual(contents, [safePath])

        let linkedPath = try ProtectedPath.fontsDirectory.appending("linked.ttf")
        await assertAsyncThrows {
            try await store.read(relativePath: linkedPath)
        }
        await assertAsyncThrows {
            try await store.remove(relativePath: linkedPath)
        }
        XCTAssertEqual(try Data(contentsOf: outsideFont), outsideData)
    }

    func testInMemoryStorageAdaptersObeyContracts() async throws {
        let secure = InMemorySecureValueStore()
        try await secure.set(
            Data([7]),
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.pinThrottleAccount
        )
        let throttle = try await secure.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.pinThrottleAccount
        )
        XCTAssertEqual(throttle, Data([7]))
        try await secure.delete(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.pinThrottleAccount
        )
        let deletedThrottle = try await secure.data(
            service: RuneScribeKeychain.service,
            account: RuneScribeKeychain.pinThrottleAccount
        )
        XCTAssertNil(deletedThrottle)

        let font = try ProtectedPath.fontsDirectory.appending("fixture.ttf")
        let files = InMemoryProtectedFileStore()
        try await files.write(Data([9]), relativePath: font)
        let memoryDirectoryExists = try await files.exists(relativePath: .fontsDirectory)
        let memoryContents = try await files.contents(
            of: .fontsDirectory,
            matchingExtension: "ttf"
        )
        XCTAssertTrue(memoryDirectoryExists)
        XCTAssertEqual(memoryContents, [font])
        try await files.remove(relativePath: .fontsDirectory)
        let memoryFontExists = try await files.exists(relativePath: font)
        XCTAssertFalse(memoryFontExists)
    }

    func testInboundFileReaderUsesBalancedScopeAndEnforcesByteBound() async throws {
        let root = temporaryDirectory(named: "InboundReader")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("message.runescribe")
        let fixture = Data([0x01, 0x02, 0x03, 0x04])
        try fixture.write(to: file)
        let access = OSAllocatedUnfairLock(
            initialState: (begins: 0, ends: 0, permits: true)
        )
        let reader = AppleInboundFileReader(
            beginAccess: { _ in
                access.withLock { state in
                    state.begins += 1
                    return state.permits
                }
            },
            endAccess: { _ in access.withLock { $0.ends += 1 } }
        )

        let data = try await reader.read(
            file,
            requiresSecurityScope: true,
            maximumByteCount: fixture.count
        )
        XCTAssertEqual(data, fixture)
        XCTAssertEqual(access.withLock { $0.begins }, 1)
        XCTAssertEqual(access.withLock { $0.ends }, 1)

        do {
            _ = try await reader.read(
                file,
                requiresSecurityScope: true,
                maximumByteCount: fixture.count - 1
            )
            XCTFail("Oversized inbound files must be rejected")
        } catch {
            XCTAssertEqual(error as? InboundFileReaderError, .contentTooLarge)
        }
        XCTAssertEqual(access.withLock { $0.begins }, 2)
        XCTAssertEqual(access.withLock { $0.ends }, 2)

        access.withLock { $0.permits = false }
        do {
            _ = try await reader.read(
                file,
                requiresSecurityScope: true,
                maximumByteCount: fixture.count
            )
            XCTFail("Denied security scope must fail closed")
        } catch {
            XCTAssertEqual(error as? InboundFileReaderError, .securityScopeDenied)
        }
        XCTAssertEqual(access.withLock { $0.begins }, 3)
        XCTAssertEqual(access.withLock { $0.ends }, 2)
    }

    func testInboundFileReaderRejectsDotSegmentsAndSymlinkComponents() async throws {
        let root = temporaryDirectory(named: "InboundReaderLinks")
        let outside = temporaryDirectory(named: "InboundReaderOutside")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("outside.runescribe")
        try Data([0x44]).write(to: outsideFile)
        let leafLink = root.appendingPathComponent("leaf.runescribe")
        let ancestorLink = root.appendingPathComponent("linked-directory")
        try FileManager.default.createSymbolicLink(at: leafLink, withDestinationURL: outsideFile)
        try FileManager.default.createSymbolicLink(at: ancestorLink, withDestinationURL: outside)
        let reader = AppleInboundFileReader()

        for url in [leafLink, ancestorLink.appendingPathComponent("outside.runescribe")] {
            do {
                _ = try await reader.read(
                    url,
                    requiresSecurityScope: false,
                    maximumByteCount: 16
                )
                XCTFail("No inbound path component may be a symbolic link")
            } catch {
                XCTAssertEqual(error as? InboundFileReaderError, .unsupportedFileType)
            }
        }

        let dotSegmentURL = try XCTUnwrap(
            URL(string: root.appendingPathComponent("missing/../leaf.runescribe").absoluteString)
        )
        do {
            _ = try await reader.read(
                dotSegmentURL,
                requiresSecurityScope: false,
                maximumByteCount: 16
            )
            XCTFail("Non-canonical dot-segment paths must be rejected")
        } catch {
            XCTAssertEqual(error as? InboundFileReaderError, .invalidPath)
        }
    }

    func testContactAdapterMapsMinimalValuesAndExcludesUnnamedContacts() async throws {
        let service = SystemContactAccessService(
            operations: ContactOperations(
                authorizationStatus: { .limited },
                requestAccess: { false },
                fetchContacts: {
                    [
                        ContactRecord(
                            systemIdentifier: "kept",
                            displayName: "  Baseline Contact  ",
                            phoneNumbers: ["+15551234567"],
                            emailAddresses: ["baseline@example.com"]
                        ),
                        ContactRecord(
                            systemIdentifier: "dropped",
                            displayName: " \n ",
                            phoneNumbers: ["unused"],
                            emailAddresses: []
                        ),
                        ContactRecord(
                            systemIdentifier: "legacy-sentinel",
                            displayName: "Unnamed",
                            phoneNumbers: [],
                            emailAddresses: []
                        ),
                    ]
                }
            )
        )

        let authorizationStatus = await service.authorizationStatus()
        let accessGranted = try await service.requestAccess()
        let contacts = try await service.fetchContacts()
        XCTAssertEqual(authorizationStatus, .limited)
        XCTAssertFalse(accessGranted)
        XCTAssertEqual(
            contacts,
            [
                SystemContactDTO(
                    systemIdentifier: "kept",
                    displayName: "Baseline Contact",
                    phoneNumbers: ["+15551234567"],
                    emailAddresses: ["baseline@example.com"]
                )
            ]
        )
    }

    @MainActor
    func testClipboardAdapterUsesAsyncContract() async throws {
        let fixture = ClipboardFixture(value: "original", changeCount: 4)
        let service = SystemClipboardService(
            operations: ClipboardOperations(
                changeCount: { fixture.changeCount },
                string: { fixture.value },
                setString: { value in
                    fixture.value = value
                    fixture.changeCount += 1
                    return true
                }
            )
        )

        let originalChangeCount = await service.changeCount()
        XCTAssertEqual(originalChangeCount, 4)
        let original = await service.string()
        XCTAssertEqual(original, "original")
        try await service.setString("runescribe://cipher/value")
        let updatedChangeCount = await service.changeCount()
        let updatedString = await service.string()
        XCTAssertEqual(updatedChangeCount, 5)
        XCTAssertEqual(updatedString, "runescribe://cipher/value")
    }

    func testFontAdapterUsesValueBoundaryAndTreatsRepeatRegistrationAsSuccess() async throws {
        let fontData = Data([1, 2, 3])
        let registered = CoreTextFontRegistrar(
            operations: FontOperations(
                postScriptName: { $0 == fontData ? "FixtureFont-Regular" : nil },
                register: { _ in .alreadyRegistered }
            )
        )

        let registration = try await registered.registerFont(fontData)
        XCTAssertEqual(
            registration,
            RegisteredFontDTO(postScriptName: "FixtureFont-Regular")
        )
        do {
            _ = try await registered.postScriptName(forFontData: Data())
            XCTFail("Expected invalid font data to fail")
        } catch {
            XCTAssertEqual(error as? CoreTextFontRegistrarError, .invalidFontData)
        }

        let bundledFontURL = repositoryRoot()
            .appendingPathComponent("RuneScrib/Resources/Fonts/NotoSansRunic-Regular.ttf")
        let bundledFontData = try Data(contentsOf: bundledFontURL)
        let postScriptName = try await CoreTextFontRegistrar()
            .postScriptName(forFontData: bundledFontData)
        XCTAssertEqual(postScriptName, "NotoSansRunic-Regular")
    }

    func testResourceAndDeterministicAdapters() async throws {
        let root = temporaryDirectory(named: "Resources")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resource = ApplicationResource(name: "fixture", fileExtension: "bin")
        let resourceURL = root.appendingPathComponent("fixture.bin")
        let bytes = Data([0x52, 0x46])
        try bytes.write(to: resourceURL, options: .atomic)
        let locator = MappedApplicationResourceLocator(locations: [resource: resourceURL])

        let locatedURL = try await locator.url(for: resource)
        let locatedData = try await locator.data(for: resource)
        XCTAssertEqual(locatedURL, resourceURL)
        XCTAssertEqual(locatedData, bytes)
        XCTAssertNil(ApplicationResource.bundledRuneFont.subdirectory)
        XCTAssertEqual(ApplicationResource.splashVideo.name, "raven-forge-spp-splash")

        let date = Date(timeIntervalSinceReferenceDate: 42)
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        XCTAssertEqual(FixedClock(date).now(), date)
        XCTAssertEqual(FixedUUIDProvider(uuid).nextUUID(), uuid)
    }

    func testBundleResourceLocatorUsesTheExplicitHostBundle() async throws {
        let root = temporaryDirectory(named: "HostBundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Fixture.bundle", isDirectory: true)
        #if os(macOS)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let infoURL = contentsURL.appendingPathComponent("Info.plist")
        #else
        let resourcesURL = bundleURL
        let infoURL = bundleURL.appendingPathComponent("Info.plist")
        #endif
        try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.runescribe.platform-tests.fixture",
            "CFBundleName": "Fixture",
            "CFBundlePackageType": "BNDL",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: infoURL, options: .atomic)
        let expectedData = Data([0x01, 0x05, 0x09])
        let expectedURL = resourcesURL.appendingPathComponent("host-owned.dat")
        try expectedData.write(to: expectedURL, options: .atomic)

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let locator = BundleApplicationResourceLocator(bundle: bundle)
        let resource = ApplicationResource(name: "host-owned", fileExtension: "dat")
        let locatedURL = try await locator.url(for: resource)
        let locatedData = try await locator.data(for: resource)
        XCTAssertEqual(locatedURL, expectedURL)
        XCTAssertEqual(locatedData, expectedData)
    }

    func testShareArtifactStoreScopesWritesAndCleanup() async throws {
        let root = temporaryDirectory(named: "ShareArtifacts")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppleShareArtifactStore(temporaryDirectory: root)
        let artifactID = ShareArtifactID(rawValue: UUID())
        let payload = Data([0x52, 0x53])

        let file = try await store.create(
            payload,
            artifactID: artifactID,
            filename: "RuneScrib-Message",
            fileExtension: "runescribe"
        )

        XCTAssertEqual(file.artifactID, artifactID)
        XCTAssertEqual(file.fileURL.lastPathComponent, "RuneScrib-Message.runescribe")
        XCTAssertEqual(try Data(contentsOf: file.fileURL), payload)
        do {
            _ = try await store.create(
                payload,
                artifactID: artifactID,
                filename: "duplicate",
                fileExtension: "runescribe"
            )
            XCTFail("Duplicate artifact identifiers must be rejected")
        } catch {
            XCTAssertEqual(error as? AppleShareArtifactStoreError, .duplicateIdentifier)
        }
        do {
            _ = try await store.create(
                payload,
                artifactID: ShareArtifactID(rawValue: UUID()),
                filename: "../escape",
                fileExtension: "runescribe"
            )
            XCTFail("Path-bearing filenames must be rejected")
        } catch {
            XCTAssertEqual(error as? AppleShareArtifactStoreError, .invalidFilename)
        }

        try await store.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path))
        do {
            try await store.remove(file)
            XCTFail("An already removed artifact must be rejected")
        } catch {
            XCTAssertEqual(error as? AppleShareArtifactStoreError, .unknownArtifact)
        }

        let second = try await store.create(
            payload,
            artifactID: ShareArtifactID(rawValue: UUID()),
            filename: "RuneScrib-Message",
            fileExtension: "runescribe"
        )
        try await store.removeAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.fileURL.path))
    }

    func testShareArtifactStorePurgesStaleSymlinkedRootWithoutFollowingIt() async throws {
        let base = temporaryDirectory(named: "ShareArtifactSymlinkRoot")
        let outside = temporaryDirectory(named: "ShareArtifactSymlinkOutside")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data([0x7A]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("RuneScribeShareArtifacts"),
            withDestinationURL: outside
        )
        let store = AppleShareArtifactStore(temporaryDirectory: base)
        let file = try await store.create(
            Data([0x01]),
            artifactID: ShareArtifactID(rawValue: UUID()),
            filename: "RuneScrib-Message",
            fileExtension: "runescribe"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.fileURL.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data([0x7A]))
    }

    func testShareArtifactStorePurgesStaleKeyBearingFilesOnConstruction() throws {
        let base = temporaryDirectory(named: "ShareArtifactStaleRoot")
        defer { try? FileManager.default.removeItem(at: base) }
        let ownedRoot = base.appendingPathComponent("RuneScribeShareArtifacts")
        let staleDirectory = ownedRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: staleDirectory,
            withIntermediateDirectories: true
        )
        let staleFile = staleDirectory.appendingPathComponent("stale.runescribe")
        try Data([0x52, 0x53]).write(to: staleFile)

        _ = AppleShareArtifactStore(temporaryDirectory: base)

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRoot.path))
    }

    func testShareArtifactStoreRejectsRootReplacedAfterPreparation() async throws {
        let base = temporaryDirectory(named: "ShareArtifactRootReplacement")
        let outside = temporaryDirectory(named: "ShareArtifactReplacementOutside")
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = AppleShareArtifactStore(temporaryDirectory: base)
        _ = try await store.create(
            Data([0x01]),
            artifactID: ShareArtifactID(rawValue: UUID()),
            filename: "first",
            fileExtension: "runescribe"
        )

        let ownedRoot = base.appendingPathComponent("RuneScribeShareArtifacts")
        try FileManager.default.removeItem(at: ownedRoot)
        try FileManager.default.createSymbolicLink(at: ownedRoot, withDestinationURL: outside)

        do {
            _ = try await store.create(
                Data([0x02]),
                artifactID: ShareArtifactID(rawValue: UUID()),
                filename: "second",
                fileExtension: "runescribe"
            )
            XCTFail("A replaced temporary root must be rejected")
        } catch {
            XCTAssertEqual(
                error as? AppleShareArtifactStoreError,
                .symbolicLinkNotAllowed
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testShareArtifactStoreKeepsOpaqueLinksInMemoryUntilRevoked() async throws {
        let root = temporaryDirectory(named: "ShareArtifactLinks")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppleShareArtifactStore(temporaryDirectory: root)
        let artifactID = ShareArtifactID(rawValue: UUID())
        let link = try XCTUnwrap(URL(string: "runescribe://import?v=3&p=synthetic"))

        try await store.storeLink(link, artifactID: artifactID)
        let stored = try await store.link(for: artifactID)
        XCTAssertEqual(stored, link)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path + "/RuneScribeShareArtifacts"))

        do {
            try await store.storeLink(link, artifactID: artifactID)
            XCTFail("Duplicate opaque link identifiers must be rejected")
        } catch {
            XCTAssertEqual(error as? AppleShareArtifactStoreError, .duplicateIdentifier)
        }

        try await store.removeLink(artifactID: artifactID)
        do {
            _ = try await store.link(for: artifactID)
            XCTFail("Revoked opaque links must be unavailable")
        } catch {
            XCTAssertEqual(error as? AppleShareArtifactStoreError, .unknownArtifact)
        }
    }

    private func temporaryDirectory(named name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneScribePlatformTests-\(name)-\(UUID().uuidString)")
    }

    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
}

private func assertAsyncThrows<Value>(
    _ operation: () async throws -> Value,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await operation()
        XCTFail("Expected operation to throw", file: file, line: line)
    } catch {}
}

private enum KeychainCall: Equatable {
    case add(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    )
    case read(service: String, account: String)
    case delete(service: String, account: String)
}

private final class RecordingKeychainOperations: KeychainOperations {
    private struct State {
        var calls: [KeychainCall] = []
        var values: [SecureValueLocation: Data] = [:]
        let forcedDeleteStatus: OSStatus?
        let forcedReadStatus: OSStatus?
        let forcedReadData: Data?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        forcedDeleteStatus: OSStatus? = nil,
        forcedReadStatus: OSStatus? = nil,
        forcedReadData: Data? = nil
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                forcedDeleteStatus: forcedDeleteStatus,
                forcedReadStatus: forcedReadStatus,
                forcedReadData: forcedReadData
            )
        )
    }

    var calls: [KeychainCall] {
        state.withLock { $0.calls }
    }

    func add(
        data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) -> OSStatus {
        state.withLock { state in
            state.calls.append(
                .add(
                    data: data,
                    service: service,
                    account: account,
                    accessibility: accessibility
                )
            )
            state.values[SecureValueLocation(service: service, account: account)] = data
            return errSecSuccess
        }
    }

    func read(service: String, account: String) -> (status: OSStatus, data: Data?) {
        state.withLock { state in
            state.calls.append(.read(service: service, account: account))
            if let status = state.forcedReadStatus {
                return (status, state.forcedReadData)
            }
            let data = state.values[SecureValueLocation(service: service, account: account)]
            return data == nil ? (errSecItemNotFound, nil) : (errSecSuccess, data)
        }
    }

    func delete(service: String, account: String) -> OSStatus {
        state.withLock { state in
            state.calls.append(.delete(service: service, account: account))
            if let status = state.forcedDeleteStatus { return status }
            let key = SecureValueLocation(service: service, account: account)
            return state.values.removeValue(forKey: key) == nil
                ? errSecItemNotFound
                : errSecSuccess
        }
    }
}

@MainActor
private final class ClipboardFixture {
    var value: String?
    var changeCount: Int

    init(value: String?, changeCount: Int) {
        self.value = value
        self.changeCount = changeCount
    }
}
