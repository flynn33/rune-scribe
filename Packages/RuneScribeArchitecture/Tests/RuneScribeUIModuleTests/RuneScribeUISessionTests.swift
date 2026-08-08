import Foundation
import RuneScribeContracts
import RuneScribeRuntimeCore
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import XCTest

@MainActor
final class RuneScribeUISessionTests: XCTestCase {
    func testSnapshotAndPendingMessageProjectWithoutOwningDomainState() async throws {
        let service = ControllableApplicationService()
        let session = makeSession(applicationService: service)
        try session.start()

        service.yieldState(Self.fixtureSnapshot(revision: 7, plaintext: "Meet at the oak."))
        let projected = await eventually { session.snapshot?.revision == 7 }

        XCTAssertTrue(projected)
        XCTAssertEqual(session.ciphers.count, 1)
        XCTAssertEqual(session.activeCipher?.label, "Freya")
        XCTAssertEqual(session.activeCipher?.fontName, "Elder Runes")
        XCTAssertEqual(session.activeCipher?.shortPublicID, "ABCDEF12")
        XCTAssertEqual(session.contacts.map(\.displayName), ["Freya Day"])
        XCTAssertEqual(session.importedContactCount, 1)
        XCTAssertEqual(session.pendingMessage?.plaintext, "Meet at the oak.")
        XCTAssertEqual(session.pendingMessage?.senderName, "Freya")
        XCTAssertEqual(session.pendingMessage?.cipherName, "Freya")
        XCTAssertEqual(session.lastError, "A required app resource is unavailable.")
        XCTAssertEqual(session.importErrorMessage, "This isn't a valid Rune Scribe import.")
        XCTAssertEqual(
            session.messageErrorMessage,
            "This message couldn't be read with your ciphers."
        )

        await session.stop()
    }

    func testRepeatingSameMessageSnapshotKeepsOneIdenticalProjection() async throws {
        let service = ControllableApplicationService()
        let session = makeSession(applicationService: service)
        try session.start()
        let state = Self.fixtureSnapshot(
            revision: 8,
            plaintext: "once only",
            includeFailures: false
        )

        service.yieldState(state)
        let firstProjectionArrived = await eventually {
            session.pendingMessage?.plaintext == "once only"
        }
        XCTAssertTrue(firstProjectionArrived)
        let firstProjection = try XCTUnwrap(session.pendingMessage)

        service.yieldState(state)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(session.pendingMessage, firstProjection)
        await session.stop()
    }

    func testSnapshotWithoutPendingMessageClearsPresentation() async throws {
        let service = ControllableApplicationService()
        let session = makeSession(applicationService: service)
        try session.start()

        service.yieldState(
            Self.fixtureSnapshot(
                revision: 9,
                plaintext: "hello",
                includeFailures: false
            )
        )
        let pendingProjectionArrived = await eventually {
            session.pendingMessage != nil
        }
        XCTAssertTrue(pendingProjectionArrived)

        service.yieldState(
            Self.fixtureSnapshot(
                revision: 10,
                plaintext: nil,
                includeFailures: false
            )
        )
        let pendingProjectionCleared = await eventually {
            session.snapshot?.revision == 10 && session.pendingMessage == nil
        }
        XCTAssertTrue(pendingProjectionCleared)

        await session.stop()
    }

    func testMenuStreamAndReplyUseTypedConsumableRoutes() async throws {
        let service = ControllableApplicationService()
        let session = makeSession(applicationService: service)
        try session.start()

        service.yieldMenu(.openSettings)
        let settingsProjected = await eventually {
            session.route?.route == .openSettings
        }
        XCTAssertTrue(settingsProjected)
        let settingsRequest = try XCTUnwrap(session.route)

        session.consumeRoute(id: UUID())
        XCTAssertEqual(session.route, settingsRequest)
        session.consumeRoute(id: settingsRequest.id)
        XCTAssertNil(session.route)

        service.yieldMenu(.openCipherLibrary)
        let libraryProjected = await eventually {
            session.route?.route == .openCipherLibrary
        }
        XCTAssertTrue(libraryProjected)

        let cipherID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        session.requestRoute(.replyToMessage(cipherID: cipherID))
        XCTAssertEqual(session.route?.route, .replyToMessage(cipherID: cipherID))

        await session.stop()
    }

    func testStopClearsPresentationStateAndIgnoresLateStreamValues() async throws {
        let service = ControllableApplicationService()
        let session = makeSession(applicationService: service)
        try session.start()

        service.yieldState(Self.fixtureSnapshot(revision: 1, plaintext: "Secret plaintext"))
        service.yieldMenu(.openSettings)
        let initialProjectionArrived = await eventually {
            session.snapshot?.revision == 1 && session.route?.route == .openSettings
        }
        XCTAssertTrue(initialProjectionArrived)

        session.requestRoute(
            .replyToMessage(
                cipherID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
            )
        )
        await session.stop()

        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.pendingMessage)
        XCTAssertNil(session.route)
        XCTAssertNil(session.lastError)
        XCTAssertNil(session.importErrorMessage)
        XCTAssertNil(session.messageErrorMessage)

        service.yieldState(Self.fixtureSnapshot(revision: 2, plaintext: "Late plaintext"))
        service.yieldMenu(.openCipherLibrary)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertNil(session.snapshot)
        XCTAssertNil(session.pendingMessage)
        XCTAssertNil(session.route)
        await session.stop()
    }

    func testStopReleasesApplicationClipboardAndShareProviderOwners() async throws {
        var service: ControllableApplicationService? = ControllableApplicationService()
        var clipboard: LifetimeClipboard? = LifetimeClipboard()
        var shareOwner: LifetimeProbe? = LifetimeProbe()
        let weakService = WeakReference(service)
        let weakClipboard = WeakReference(clipboard)
        let weakShareOwner = WeakReference(shareOwner)

        let session = RuneScribeUISession(
            applicationService: try XCTUnwrap(service),
            clipboardWriting: try XCTUnwrap(clipboard),
            sharePresentation: OpaqueSharePresentationProvider {
                [owner = try XCTUnwrap(shareOwner)] _ in
                _ = owner
                return URL(fileURLWithPath: "/fixture/share.runescribe")
            },
            splashVideoURL: URL(fileURLWithPath: "/fixture/splash.mp4"),
            metalLibraryURL: URL(fileURLWithPath: "/fixture/default.metallib"),
            productMetadata: .init(version: "1.0", buildNumber: "1")
        )
        try session.start()

        service = nil
        clipboard = nil
        shareOwner = nil
        XCTAssertNotNil(weakService.value)
        XCTAssertNotNil(weakClipboard.value)
        XCTAssertNotNil(weakShareOwner.value)

        await session.stop()
        let ownersReleased = await eventually {
            weakService.value == nil
                && weakClipboard.value == nil
                && weakShareOwner.value == nil
        }
        XCTAssertTrue(ownersReleased)
    }

    func testModuleActivationToleratesMissingOptionalVisualResources() async throws {
        let rootStore = RootViewPresentationStore()
        let applicationService = ControllableApplicationService()
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0)),
            platform: .macOS
        )

        try await runtime.register(
            manifest: TestCoreModule.manifest,
            factory: TestCoreModule.factory(applicationService: applicationService)
        )
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory(
                dependencies: RuneScribeUIDependencies(rootPresentationStore: rootStore)
            )
        )
        try await runtime.registerHostService(
            MissingApplicationResources(),
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.registerHostService(
            LifetimeClipboard(),
            for: RuneScribeServiceKeys.clipboardWrite
        )

        try await runtime.start()
        XCTAssertEqual(
            rootStore.state,
            .ready(moduleID: RuneScribeUIModuleBootstrap.moduleID)
        )

        let nilResourceSession = RuneScribeUISession(
            applicationService: applicationService,
            clipboardWriting: LifetimeClipboard(),
            sharePresentation: .unavailable,
            splashVideoURL: nil,
            metalLibraryURL: nil,
            productMetadata: .unavailable
        )
        XCTAssertNil(nilResourceSession.splashVideoURL)
        XCTAssertNil(nilResourceSession.metalLibraryURL)
        await nilResourceSession.stop()

        await runtime.stop()
        XCTAssertEqual(rootStore.state, .booting)
    }

    private func makeSession(
        applicationService: any RuneScribeApplicationService,
        clipboard: any ClipboardWriting = LifetimeClipboard()
    ) -> RuneScribeUISession {
        RuneScribeUISession(
            applicationService: applicationService,
            clipboardWriting: clipboard,
            sharePresentation: .unavailable,
            splashVideoURL: URL(fileURLWithPath: "/fixture/splash.mp4"),
            metalLibraryURL: URL(fileURLWithPath: "/fixture/default.metallib"),
            productMetadata: .init(version: "1.0", buildNumber: "1")
        )
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() {
                return true
            }
            await Task.yield()
        }
        return predicate()
    }

    private static func fixtureSnapshot(
        revision: UInt64,
        plaintext: String?,
        includeFailures: Bool = true
    ) -> RuneScribeApplicationSnapshot {
        let cipherID = CipherID(
            rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let contactID = ContactID(
            rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )
        let fontID = FontID(rawValue: "elder-runes")
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let cipher = CipherSummary(
            id: cipherID,
            name: "Freya",
            origin: .generated,
            createdAt: createdAt,
            isActive: true,
            assignedContactID: contactID,
            hasBeenDelivered: true,
            publicIdentifier: "ABCDEF1234567890",
            fontID: fontID
        )
        let contact = ContactSummary(
            id: contactID,
            displayName: "Freya Day",
            phoneNumbers: ["+15550001"],
            emailAddresses: ["freya@example.com"],
            source: .imported,
            createdAt: createdAt,
            linkedCipherCount: 1
        )
        let message = plaintext.map {
            ReceivedMessageDTO(
                id: MessageID(
                    rawValue: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
                ),
                plaintext: $0,
                senderName: "Freya",
                cipherID: cipherID,
                cipherName: "Freya"
            )
        }
        return RuneScribeApplicationSnapshot(
            revision: revision,
            capturedAt: createdAt,
            cipherLibrary: CipherLibraryStateDTO(
                ciphers: [cipher],
                activeCipherID: cipherID
            ),
            contactLibrary: ContactLibraryStateDTO(
                contacts: [contact],
                importedCount: 1,
                authorization: .authorized
            ),
            fonts: [
                FontSummary(
                    id: fontID,
                    displayName: "Elder Runes",
                    version: 1,
                    contentHash: "fixture-hash",
                    source: .bundled,
                    isRegistered: true
                ),
            ],
            importState: ImportStateDTO(
                phase: includeFailures ? .failed : .idle,
                lastFailure: includeFailures
                    ? RuneScribeFailureDTO(code: .invalidInput)
                    : nil
            ),
            messageState: MessageStateDTO(
                phase: message == nil ? .idle : (includeFailures ? .failed : .received),
                pendingMessage: message,
                lastFailure: includeFailures
                    ? RuneScribeFailureDTO(code: .noMatchingCipher)
                    : nil
            ),
            lockState: ApplicationLockStateDTO(isPINSet: true, isLocked: false),
            lastFailure: includeFailures
                ? RuneScribeFailureDTO(code: .resourceUnavailable)
                : nil
        )
    }
}

private enum StubError: Error {
    case unexpectedCommand
}

private actor LifetimeProbe {}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private actor LifetimeClipboard: ClipboardWriting {
    func setString(_ value: String) async throws {}
}

private actor ControllableApplicationService: RuneScribeApplicationService {
    nonisolated let states: AsyncStream<RuneScribeApplicationSnapshot>
    nonisolated let stateContinuation: AsyncStream<RuneScribeApplicationSnapshot>.Continuation
    nonisolated let menuCommands: AsyncStream<ApplicationMenuCommandDTO>
    nonisolated let menuContinuation: AsyncStream<ApplicationMenuCommandDTO>.Continuation

    init() {
        let stateChannel = AsyncStream.makeStream(
            of: RuneScribeApplicationSnapshot.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        states = stateChannel.stream
        stateContinuation = stateChannel.continuation

        let menuChannel = AsyncStream.makeStream(
            of: ApplicationMenuCommandDTO.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        menuCommands = menuChannel.stream
        menuContinuation = menuChannel.continuation
    }

    nonisolated func yieldState(_ snapshot: RuneScribeApplicationSnapshot) {
        stateContinuation.yield(snapshot)
    }

    nonisolated func yieldMenu(_ command: ApplicationMenuCommandDTO) {
        menuContinuation.yield(command)
    }

    nonisolated func stateStream() -> AsyncStream<RuneScribeApplicationSnapshot> {
        states
    }

    nonisolated func menuCommandStream() -> AsyncStream<ApplicationMenuCommandDTO> {
        menuCommands
    }

    func encode(_ command: EncodeMessageCommand) async throws -> EncodedMessageResult {
        throw StubError.unexpectedCommand
    }

    func decode(_ command: DecodeMessageCommand) async throws -> DecodedMessageResult {
        throw StubError.unexpectedCommand
    }

    func createCipher(_ command: CreateCipherCommand) async throws -> CipherSummary {
        throw StubError.unexpectedCommand
    }

    func renameCipher(_ command: RenameCipherCommand) async throws -> CipherSummary {
        throw StubError.unexpectedCommand
    }

    func deleteCipher(id: CipherID) async throws {
        throw StubError.unexpectedCommand
    }

    func setActiveCipher(_ command: SetActiveCipherCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func assignContact(_ command: AssignContactCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func createContact(_ command: CreateContactCommand) async throws -> ContactSummary {
        throw StubError.unexpectedCommand
    }

    func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary {
        throw StubError.unexpectedCommand
    }

    func deleteContacts(ids: Set<ContactID>) async throws {
        throw StubError.unexpectedCommand
    }

    func deleteAllImportedContacts() async throws {
        throw StubError.unexpectedCommand
    }

    func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary] {
        throw StubError.unexpectedCommand
    }

    func requestSystemContacts() async throws -> [SystemContactDTO] {
        throw StubError.unexpectedCommand
    }

    func prepareCipherShare(
        _ command: PrepareCipherShareCommand
    ) async throws -> ShareArtifactDTO {
        throw StubError.unexpectedCommand
    }

    func prepareMessageShare(
        _ command: PrepareMessageShareCommand
    ) async throws -> ShareArtifactDTO {
        throw StubError.unexpectedCommand
    }

    func completeShareArtifact(
        _ command: CompleteShareArtifactCommand
    ) async throws -> ShareArtifactCompletionResultDTO {
        throw StubError.unexpectedCommand
    }

    func releaseShareArtifact(id: ShareArtifactID) async {}

    func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO {
        throw StubError.unexpectedCommand
    }

    func importURL(_ input: InboundURLDTO) async throws -> ImportResultDTO {
        throw StubError.unexpectedCommand
    }

    func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary {
        throw StubError.unexpectedCommand
    }

    func cancelImport(id: ImportID) async {}

    func dismissReceivedMessage(id: MessageID) async {}

    func lock() async {}

    func verifyPIN(_ input: PINInput) async throws -> Bool {
        throw StubError.unexpectedCommand
    }

    func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO {
        throw StubError.unexpectedCommand
    }

    func setPIN(_ command: SetPINCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func changePIN(_ command: ChangePINCommand) async throws {
        throw StubError.unexpectedCommand
    }

    func disablePIN(_ command: DisablePINCommand) async throws {
        throw StubError.unexpectedCommand
    }
}

private enum MissingResourceError: Error {
    case unavailable
}

private struct MissingApplicationResources: ApplicationResourceLocator {
    func data(for resource: ApplicationResource) async throws -> Data {
        throw MissingResourceError.unavailable
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        throw MissingResourceError.unavailable
    }
}

private enum TestCoreModule {
    static let moduleID: ModuleIdentifier = "com.runescribe.test.core"
    static let moduleVersion = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    static let descriptor = ModuleDescriptor(
        moduleID: moduleID,
        moduleVersion: moduleVersion,
        kind: .service,
        entryPoint: "RuneScribeTestCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.publishService],
        publishedServices: [RuneScribeServiceIDs.application]
    )
    static let manifest = ModuleManifest(
        runtimeVersion: moduleVersion,
        moduleID: moduleID,
        displayName: "Rune Scribe Test Core",
        moduleVersion: moduleVersion,
        moduleType: .service,
        supportedPlatforms: [.iOS, .macOS],
        capabilitiesRequested: [RuneScribeCapabilities.publishService],
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(),
        defaultRole: RuneScribeRoles.core
    )

    static func factory(
        applicationService: any RuneScribeApplicationService
    ) -> AnyModuleFactory {
        AnyModuleFactory(descriptor: descriptor) {
            ApplicationPublishingModule(applicationService: applicationService)
        }
    }
}

private struct ApplicationPublishingModule: RuneScribeModule {
    let descriptor = TestCoreModule.descriptor
    let applicationService: any RuneScribeApplicationService

    func start(context: ModuleContext) async throws {
        try await context.publishService(
            applicationService,
            for: RuneScribeServiceKeys.application
        )
    }

    func stop() async {}
}
