import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import RuneScribeNorseThemeModule
import RuneScribePlatform
@_spi(RuntimeTesting) import RuneScribeRuntimeCore
import RuneScribeTestSupport
import RuneScribeThemeCoordinatorModule
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import XCTest

final class ArchitectureIntegrationTests: XCTestCase {
    func testDamagedNorseResourceKeepsCoreEncodeDecodeAvailable() async throws {
        let runtime = RuneScribeRuntime(
            runtimeVersion: try SemanticVersion(major: 1, minor: 0, patch: 0),
            platform: .macOS
        )
        let capture = EmergencyFallbackUICapture()
        let shareArtifacts = try await registerHostPlatformServices(
            on: runtime,
            unavailableNorseResource: NorseBaseBundledResourceCatalog.notoSansRunic
        )
        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory()
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: AnyModuleFactory(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                IntegrationTestModule(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                    context in
                    await capture.store(
                        application: try await context.applicationClient(),
                        theme: try await context.themeCoordinatorClient(),
                        runtimeIO: try await context.runtimeIOClient()
                    )
                }
            }
        )

        try await runtime.start()
        defer { Task { await runtime.stop() } }
        let capturedApplication = await capture.applicationClient()
        let capturedTheme = await capture.themeClient()
        let capturedRuntimeIO = await capture.runtimeIOClient()
        let application = try XCTUnwrap(capturedApplication)
        let theme = try XCTUnwrap(capturedTheme)
        let runtimeIO = try XCTUnwrap(capturedRuntimeIO)
        let themeSnapshot = try await theme.snapshot()
        XCTAssertTrue(themeSnapshot.isEmergencyPresentation)
        XCTAssertEqual(themeSnapshot.fallbackReason, .invalidResources)

        let uiSession = await MainActor.run {
            RuneScribeUISession(
                applicationClient: application,
                runtimeIO: runtimeIO,
                themeCoordinatorClient: theme,
                resourcePresentation: RuntimeApplicationResourcePresentation(
                    splashVideo: nil,
                    metalLibrary: nil
                ),
                productMetadata: .unavailable
            )
        }
        try await uiSession.prepareInitialTheme()
        try await MainActor.run { try uiSession.start() }
        defer { Task { @MainActor in await uiSession.stop() } }
        let emergencyUIState = await MainActor.run {
            (
                uiSession.themeSnapshot?.isEmergencyPresentation,
                uiSession.themeScriptPresentation
            )
        }
        XCTAssertEqual(emergencyUIState.0, true)
        XCTAssertEqual(emergencyUIState.1, .baseFallback)

        let cipher = try await application.createCipher(
            CreateCipherCommand(name: "Emergency Presentation Decode")
        )
        let encoded = try await application.encode(
            EncodeMessageCommand(
                plaintext: "Readable despite damaged presentation bytes",
                cipherID: cipher.id
            )
        )
        let decoded = try await application.decode(
            DecodeMessageCommand(runes: encoded.runes)
        )
        XCTAssertEqual(decoded.plaintext, "Readable despite damaged presentation bytes")
        XCTAssertEqual(decoded.cipherID, cipher.id)

        let typedPresentation = try OutboundSharePresentationDTO(
            metadata: SharePresentationMetadata(
                selection: SharePresentationSelection(
                    codexID: RuneScribeCodexIDs.norse,
                    scriptID: ScriptID(rawValue: "script.base-runes")!,
                    relicID: ArtifactID(
                        rawValue: "relic.norse.runestone.weathered"
                    )!,
                    sealID: ArtifactID(rawValue: "seal.norse.knotwork")!
                ),
                compatibility: .norseInteractiveFallback
            )
        )
        let typedArtifact = try await application.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Typed Emergency Sender",
                cipherID: cipher.id,
                presentation: typedPresentation
            )
        )
        let storedTypedBytes = await shareArtifacts.data(for: typedArtifact.id)
        let typedBytes = try XCTUnwrap(storedTypedBytes)
        XCTAssertTrue(RuneScribePackage.hasMagic(typedBytes))
        let typedImport = try await application.importFile(
            inboundMessageFile(typedBytes, idSuffix: 1)
        )
        XCTAssertEqual(typedImport.disposition, .receivedMessage)
        let typedMessageID = try XCTUnwrap(typedImport.receivedMessageID)
        let typedMessage = try await waitForPendingMessage(
            id: typedMessageID,
            in: uiSession
        )
        XCTAssertEqual(
            typedMessage.plaintext,
            "Readable despite damaged presentation bytes"
        )
        XCTAssertEqual(typedMessage.presentation?.renderMode, .norseInteractiveFallback)
        XCTAssertFalse(
            RootEmergencyThemeWarningPolicy.shouldShow(
                isEmergencyPresentation: true,
                isDismissed: false,
                showSplash: false,
                isLocked: false,
                hasPendingImport: false,
                hasPendingMessage: true,
                hasActiveReveal: false
            ),
            "The emergency warning must not cover the readable received-message UI."
        )
        try await application.dismissReceivedMessage(id: typedMessageID)
        try await application.releaseShareArtifact(id: typedArtifact.id)

        let legacyArtifact = try await application.prepareMessageShare(
            PrepareMessageShareCommand(
                runes: encoded.runes,
                senderName: "Legacy Emergency Sender",
                cipherID: cipher.id
            )
        )
        let storedLegacyBytes = await shareArtifacts.data(for: legacyArtifact.id)
        let legacyBytes = try XCTUnwrap(storedLegacyBytes)
        XCTAssertFalse(RuneScribePackage.hasMagic(legacyBytes))
        let legacyImport = try await application.importFile(
            inboundMessageFile(legacyBytes, idSuffix: 2)
        )
        XCTAssertEqual(legacyImport.disposition, .receivedMessage)
        let legacyMessageID = try XCTUnwrap(legacyImport.receivedMessageID)
        let legacyMessage = try await waitForPendingMessage(
            id: legacyMessageID,
            in: uiSession
        )
        XCTAssertEqual(
            legacyMessage.plaintext,
            "Readable despite damaged presentation bytes"
        )
        XCTAssertNil(legacyMessage.presentation)
        try await application.dismissReceivedMessage(id: legacyMessageID)
        try await application.releaseShareArtifact(id: legacyArtifact.id)

        let running = await runtime.snapshot()
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.core], .active)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.norseTheme], .active)
        XCTAssertEqual(
            running.moduleStates[RuneScribeModuleIDs.themeCoordinator],
            .active
        )
    }

    private func inboundMessageFile(
        _ data: Data,
        idSuffix: UInt8
    ) -> InboundFileDTO {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = idSuffix
        let identifier = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return InboundFileDTO(
            metadata: InboundInputMetadataDTO(
                id: InboundInputID(rawValue: identifier),
                receivedAt: Date(timeIntervalSince1970: TimeInterval(idSuffix)),
                source: .fileImporter,
                isColdStart: false
            ),
            data: data,
            declaredContentType: RuneScribeWireFormat.contentType
        )
    }

    private func waitForPendingMessage(
        id: MessageID,
        in session: RuneScribeUISession
    ) async throws -> PendingMessageViewState {
        for _ in 0 ..< 200 {
            if let message = await MainActor.run(body: { session.pendingMessage }),
               message.id == id {
                return message
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw EmergencyFallbackTestError.pendingMessageTimeout
    }

    func testBundledSkeletonBootsNonUIBeforeExactlyOneUI() async throws {
        let rootStore = await MainActor.run { RootViewPresentationStore() }
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            platform: .macOS
        )
        try await registerHostPlatformServices(on: runtime)

        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory()
        )
        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory()
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        let rootPresentationAdapter = await MainActor.run {
            rootStore.runtimeHostAdapter(productMetadata: .unavailable)
        }
        try await runtime.installStandardPort(
            rootPresentationAdapter,
            for: .standard
        )

        try await runtime.start()
        let running = await runtime.snapshot()
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(
            running.activationOrder,
            [
                RuneScribeModuleIDs.core,
                RuneScribeModuleIDs.norseTheme,
                RuneScribeModuleIDs.themeCoordinator,
                RuneScribeModuleIDs.primaryUI,
            ]
        )
        XCTAssertEqual(running.activeUIModuleID, RuneScribeModuleIDs.primaryUI)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.core], .active)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.norseTheme], .active)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.themeCoordinator], .active)
        XCTAssertEqual(running.moduleStates[RuneScribeModuleIDs.primaryUI], .active)
        let runningRootState = await MainActor.run { rootStore.state }
        XCTAssertEqual(
            runningRootState,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )

        await runtime.stop()
        let stopped = await runtime.snapshot()
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(stopped.moduleStates[RuneScribeModuleIDs.core], .stopped)
        XCTAssertEqual(stopped.moduleStates[RuneScribeModuleIDs.norseTheme], .stopped)
        XCTAssertEqual(stopped.moduleStates[RuneScribeModuleIDs.themeCoordinator], .stopped)
        XCTAssertEqual(stopped.moduleStates[RuneScribeModuleIDs.primaryUI], .stopped)
        let stoppedRootState = await MainActor.run { rootStore.state }
        XCTAssertEqual(stoppedRootState, .booting)
    }

    func testRealUIBootsThroughRequiredBaseResourceFailure() async throws {
        let rootStore = await MainActor.run { RootViewPresentationStore() }
        let runtime = RuneScribeRuntime(
            runtimeVersion: SemanticVersion(
                major: UInt(1),
                minor: UInt(0),
                patch: UInt(0)
            ),
            platform: .macOS
        )
        try await registerHostPlatformServices(
            on: runtime,
            unavailableNorseResource: NorseBaseBundledResourceCatalog.notoSansRunic
        )
        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory()
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: RuneScribeUIModuleBootstrap.factory()
        )
        let rootPresentationAdapter = await MainActor.run {
            rootStore.runtimeHostAdapter(productMetadata: .unavailable)
        }
        try await runtime.installStandardPort(
            rootPresentationAdapter,
            for: .standard
        )

        try await runtime.start()
        let running = await runtime.snapshot()
        let runningRootState = await MainActor.run { rootStore.state }
        XCTAssertEqual(running.status, .running)
        XCTAssertEqual(
            running.moduleStates[RuneScribeModuleIDs.primaryUI],
            .active
        )
        XCTAssertEqual(
            runningRootState,
            .ready(moduleID: RuneScribeModuleIDs.primaryUI)
        )

        await runtime.stop()
    }

    func testProgressionStoreFailurePreservesCoreUtilitiesAndNeutralAvailability() async throws {
        let runtimeVersion = SemanticVersion(major: UInt(1), minor: UInt(0), patch: UInt(0))
        let runtime = RuneScribeRuntime(runtimeVersion: runtimeVersion, platform: .macOS)
        let uiCapture = OptionalFailureUICapture()
        let themeProbe = OptionalThemeActivationProbe()
        let moonleaf = try XCTUnwrap(UnlockID(rawValue: "unlock.codex.moonleaf"))
        let progression = optionalProgressionDescriptor(version: runtimeVersion)
        let theme = optionalThemeDescriptor(version: runtimeVersion)
        let underlyingStore = InMemoryModuleStateStore()
        let failingStore = ProgressionNamespaceFailingStore(base: underlyingStore)
        let shareArtifacts = try await registerHostPlatformServices(
            on: runtime,
            moduleStateStore: failingStore
        )

        try await runtime.register(
            manifest: RuneScribeCoreModuleBootstrap.manifest(),
            factory: RuneScribeCoreModuleBootstrap.factory()
        )
        try await RuneScribeNorseThemeModuleBootstrap.register(with: runtime)
        try await RuneScribeThemeCoordinatorModuleBootstrap.register(with: runtime)
        try await runtime.register(
            manifest: integrationManifest(for: progression, runtimeVersion: runtimeVersion),
            factory: AnyModuleFactory(descriptor: progression) {
                IntegrationTestModule(descriptor: progression) { context in
                    let client = try await context.moduleStateClient()
                    _ = try await client.prepare(schemaVersion: 1)
                }
            }
        )
        try await runtime.register(
            manifest: integrationManifest(
                for: theme,
                runtimeVersion: runtimeVersion,
                entitlement: EntitlementRequirement(kind: .earned, identifier: moonleaf)
            ),
            factory: AnyModuleFactory(descriptor: theme) {
                IntegrationTestModule(descriptor: theme) { _ in
                    await themeProbe.recordStart()
                }
            }
        )
        try await runtime.register(
            manifest: RuneScribeUIModuleBootstrap.manifest(),
            factory: AnyModuleFactory(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                IntegrationTestModule(descriptor: RuneScribeUIModuleBootstrap.descriptor) {
                    context in
                    let application = try await context.applicationClient()
                    let availability = try await context.runtimeAvailabilityClient()
                    await uiCapture.store(application: application, availability: availability)
                }
            }
        )

        do {
            try await runtime.start()
            let snapshot = await runtime.snapshot()
            XCTAssertEqual(snapshot.status, .running)
            XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.core], .active)
            XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.primaryUI], .active)
            XCTAssertEqual(snapshot.moduleStates[RuneScribeModuleIDs.progression], .failed)
            XCTAssertEqual(snapshot.moduleStates[theme.moduleID], .validated)
            XCTAssertEqual(snapshot.entitlementSnapshot.includedUnlockIDs, [RuneScribeUnlockIDs.norseCodex])
            XCTAssertEqual(snapshot.entitlementSnapshot.earnedUnlockIDs, [])
            let failedPrepareCount = await failingStore.progressionPrepareCount()
            XCTAssertEqual(failedPrepareCount, 1)
            let themeStartCount = await themeProbe.startCount()
            XCTAssertEqual(themeStartCount, 0)

            let capturedApplication = await uiCapture.applicationClient()
            let capturedAvailability = await uiCapture.availabilityClient()
            let application = try XCTUnwrap(capturedApplication)
            let availability = try XCTUnwrap(capturedAvailability)
            let availabilitySnapshot = try await availability.snapshot()
            XCTAssertEqual(
                availabilitySnapshot[role: RuneScribeRoles.progression]?.lifecycleState,
                .failed
            )
            XCTAssertEqual(availabilitySnapshot[role: theme.role]?.lifecycleState, .validated)
            XCTAssertEqual(
                availabilitySnapshot.entitlementSnapshot.includedUnlockIDs,
                [RuneScribeUnlockIDs.norseCodex]
            )
            XCTAssertEqual(availabilitySnapshot.entitlementSnapshot.earnedUnlockIDs, [])
            let availabilityStream = try await availability.snapshots()
            var availabilityIterator = availabilityStream.makeAsyncIterator()
            let streamedAvailability = await availabilityIterator.next()
            XCTAssertEqual(streamedAvailability, availabilitySnapshot)

            let cipher = try await application.createCipher(
                CreateCipherCommand(name: "Optional Failure Utility")
            )
            let encoded = try await application.encode(
                EncodeMessageCommand(plaintext: "Core remains available", cipherID: cipher.id)
            )
            let decoded = try await application.decode(
                DecodeMessageCommand(runes: encoded.runes)
            )
            XCTAssertEqual(decoded.plaintext, "Core remains available")
            XCTAssertEqual(decoded.cipherID, cipher.id)

            let messageArtifact = try await application.prepareMessageShare(
                PrepareMessageShareCommand(
                    runes: encoded.runes,
                    senderName: "Rune Scribe",
                    cipherID: cipher.id
                )
            )
            XCTAssertEqual(messageArtifact.reference, .file(messageArtifact.id))
            XCTAssertEqual(messageArtifact.contentType, RuneScribeWireFormat.contentType)
            XCTAssertEqual(messageArtifact.fileExtension, RuneScribeWireFormat.fileExtension)
            XCTAssertFalse(messageArtifact.requiresKeyDelivery)
            let messageData = await shareArtifacts.data(for: messageArtifact.id)
            XCTAssertFalse(try XCTUnwrap(messageData).isEmpty)
            try await application.releaseShareArtifact(id: messageArtifact.id)
            let messageArtifactRetained = await shareArtifacts.contains(messageArtifact.id)
            XCTAssertFalse(messageArtifactRetained)

            let cipherArtifact = try await application.prepareCipherShare(
                PrepareCipherShareCommand(cipherID: cipher.id, representation: .file)
            )
            let cipherShareData = await shareArtifacts.data(for: cipherArtifact.id)
            let importData = try XCTUnwrap(cipherShareData)
            try await application.releaseShareArtifact(id: cipherArtifact.id)
            let cipherArtifactRetained = await shareArtifacts.contains(cipherArtifact.id)
            XCTAssertFalse(cipherArtifactRetained)
            try await application.deleteCipher(id: cipher.id)

            let imported = try await application.importFile(
                InboundFileDTO(
                    metadata: InboundInputMetadataDTO(
                        id: InboundInputID(rawValue: UUID()),
                        receivedAt: Date(),
                        source: .fileImporter,
                        isColdStart: false
                    ),
                    data: importData,
                    declaredContentType: RuneScribeWireFormat.contentType
                )
            )
            XCTAssertEqual(imported.disposition, .awaitingConfirmation)
            let pendingImport = try XCTUnwrap(imported.pendingImport)
            let confirmed = try await application.confirmImport(
                ConfirmImportCommand(
                    importID: pendingImport.id,
                    name: "Recovered Utility Cipher"
                )
            )
            XCTAssertEqual(confirmed.name, "Recovered Utility Cipher")
            XCTAssertEqual(confirmed.origin, .imported)

            let requiredUtilityOperations: Set<RuntimeOperationIdentifier> = [
                RuntimeOperationIdentifier(
                    RuntimeApplicationEndpointCatalog.encode.descriptor.endpointID.rawValue
                ),
                RuntimeOperationIdentifier(
                    RuntimeApplicationEndpointCatalog.decode.descriptor.endpointID.rawValue
                ),
                RuntimeOperationIdentifier(
                    RuntimeApplicationEndpointCatalog.prepareMessageShare.descriptor.endpointID.rawValue
                ),
                RuntimeOperationIdentifier(
                    RuntimeApplicationEndpointCatalog.prepareCipherShare.descriptor.endpointID.rawValue
                ),
                RuntimeOperationIdentifier(
                    RuntimeApplicationEndpointCatalog.importFile.descriptor.endpointID.rawValue
                ),
                RuntimeOperationIdentifier(
                    RuntimeApplicationEndpointCatalog.confirmImport.descriptor.endpointID.rawValue
                ),
            ]
            let ledger = await runtime.callLedgerSnapshot()
            let succeededOperations = Set(
                ledger.filter { $0.outcome == .succeeded }.map(\.metadata.operationIdentifier)
            )
            XCTAssertTrue(requiredUtilityOperations.isSubset(of: succeededOperations))
            let progressionOperationIDs = Set(
                RuntimeProgressionEndpointCatalog.publishedEndpointIDs.map(\.rawValue)
            )
            XCTAssertFalse(
                ledger.contains {
                    progressionOperationIDs.contains($0.metadata.operationIdentifier.rawValue)
                }
            )
        } catch {
            await runtime.stop()
            throw error
        }
        await runtime.stop()
    }

    @discardableResult
    private func registerHostPlatformServices(
        on runtime: RuneScribeRuntime,
        moduleStateStore: any ModuleStateStore = InMemoryModuleStateStore(),
        unavailableNorseResource: ApplicationResource? = nil
    ) async throws -> InMemoryShareArtifactStore {
        let secureValues: any SecureValueStore = InMemorySecureValueStore()
        let protectedFiles: any ProtectedFileStore = InMemoryProtectedFileStore()
        let inboundFiles: any InboundFileReader = InMemoryInboundFileReader()
        let shareArtifacts = InMemoryShareArtifactStore()
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let bundledFontURL = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/NotoSansRunic-Regular.ttf"
        )
        let bundledFontData = try Data(contentsOf: bundledFontURL)
        let resources: any ApplicationResourceLocator = IntegrationApplicationResources(
            standardLocations: [
                .bundledRuneFont: bundledFontURL,
                .splashVideo: URL(fileURLWithPath: "/fixture/splash.mp4"),
                .defaultMetalLibrary: URL(fileURLWithPath: "/fixture/default.metallib"),
            ],
            norseBundle: RuneScribeNorseThemeModuleBootstrap.resourceBundle,
            unavailableNorseResource: unavailableNorseResource
        )
        let fonts: any SystemFontRegistrar = InMemoryFontRegistrar(
            namesByData: [bundledFontData: "NotoSansRunic-Regular"]
        )
        let contacts: any ContactAccessService = InMemoryContactAccessService()
        let clipboard = InMemoryClipboardService()
        let clipboardReader: any ClipboardReading = clipboard
        let clipboardWriter: any ClipboardWriting = clipboard
        let clock: any ClockProviding = SystemClock()
        let uuid: any UUIDProviding = SystemUUIDProvider()

        try await runtime.installPlatformAdapter(
            secureValues,
            for: RuneScribeServiceKeys.secureValueStore
        )
        try await runtime.installPlatformAdapter(
            protectedFiles,
            for: RuneScribeServiceKeys.protectedFileStore
        )
        try await runtime.installPlatformAdapter(
            inboundFiles,
            for: RuneScribeServiceKeys.inboundFileReader
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.shareArtifactStore
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.installPlatformAdapter(
            resources,
            for: RuneScribeServiceKeys.applicationResourceLocator
        )
        try await runtime.installPlatformAdapter(
            fonts,
            for: RuneScribeServiceKeys.systemFontRegistrar
        )
        try await runtime.installPlatformAdapter(
            contacts,
            for: RuneScribeServiceKeys.contactAccess
        )
        try await runtime.installPlatformAdapter(
            clipboardReader,
            for: RuneScribeServiceKeys.clipboardRead
        )
        try await runtime.installPlatformAdapter(
            clipboardWriter,
            for: RuneScribeServiceKeys.clipboardWrite
        )
        try await runtime.installPlatformAdapter(clock, for: RuneScribeServiceKeys.clock)
        try await runtime.installPlatformAdapter(uuid, for: RuneScribeServiceKeys.uuid)
        try await runtime.installPlatformAdapter(
            moduleStateStore,
            for: RuneScribeServiceKeys.moduleStateStore
        )
        return shareArtifacts
    }
}

private struct IntegrationApplicationResources: ApplicationResourceLocator {
    let standardLocations: [ApplicationResource: URL]
    let norseBundle: Bundle
    let unavailableNorseResource: ApplicationResource?

    func data(for resource: ApplicationResource) async throws -> Data {
        try Data(contentsOf: try location(for: resource))
    }

    func url(for resource: ApplicationResource) async throws -> URL {
        try location(for: resource)
    }

    private func location(for resource: ApplicationResource) throws -> URL {
        guard resource != unavailableNorseResource else {
            throw MappedApplicationResourceLocatorError.resourceNotFound(resource)
        }
        if resource.ownerModuleID == RuneScribeModuleIDs.norseTheme,
           let location = norseBundle.url(
               forResource: resource.name,
               withExtension: resource.fileExtension,
               subdirectory: resource.subdirectory
           )
        {
            return location
        }
        guard let location = standardLocations[resource] else {
            throw MappedApplicationResourceLocatorError.resourceNotFound(resource)
        }
        return location
    }
}

private actor EmergencyFallbackUICapture {
    private var application: RuntimeApplicationClient?
    private var theme: RuntimeThemeCoordinatorClient?
    private var runtimeIO: RuntimeIOClient?

    func store(
        application: RuntimeApplicationClient,
        theme: RuntimeThemeCoordinatorClient,
        runtimeIO: RuntimeIOClient
    ) {
        self.application = application
        self.theme = theme
        self.runtimeIO = runtimeIO
    }

    func applicationClient() -> RuntimeApplicationClient? { application }
    func themeClient() -> RuntimeThemeCoordinatorClient? { theme }
    func runtimeIOClient() -> RuntimeIOClient? { runtimeIO }
}

private enum EmergencyFallbackTestError: Error {
    case pendingMessageTimeout
}

private struct IntegrationTestModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let startOperation: @Sendable (ModuleContext) async throws -> Void

    init(
        descriptor: ModuleDescriptor,
        start: @escaping @Sendable (ModuleContext) async throws -> Void
    ) {
        self.descriptor = descriptor
        startOperation = start
    }

    func start(context: ModuleContext) async throws {
        try await startOperation(context)
    }

    func stop() async {}
}

private actor OptionalFailureUICapture {
    private var application: RuntimeApplicationClient?
    private var availability: RuntimeAvailabilityClient?

    func store(
        application: RuntimeApplicationClient,
        availability: RuntimeAvailabilityClient
    ) {
        self.application = application
        self.availability = availability
    }

    func applicationClient() -> RuntimeApplicationClient? { application }
    func availabilityClient() -> RuntimeAvailabilityClient? { availability }
}

private actor OptionalThemeActivationProbe {
    private var starts = 0

    func recordStart() { starts += 1 }
    func startCount() -> Int { starts }
}

private actor ProgressionNamespaceFailingStore: ModuleStateStore {
    private let base: InMemoryModuleStateStore
    private var prepareCount = 0

    init(base: InMemoryModuleStateStore) {
        self.base = base
    }

    func prepareNamespace(
        _ namespace: ModuleStateNamespace,
        schemaVersion: UInt32
    ) async throws -> ModuleStateHealthSnapshot {
        if namespace.moduleID == RuneScribeModuleIDs.progression {
            prepareCount += 1
            throw ModuleStateStoreError.unavailable
        }
        return try await base.prepareNamespace(namespace, schemaVersion: schemaVersion)
    }

    func fetch(
        namespace: ModuleStateNamespace,
        key: ModuleStateRecordKey
    ) async throws -> ModuleStateRecord? {
        try await base.fetch(namespace: namespace, key: key)
    }

    func scan(
        namespace: ModuleStateNamespace,
        request: ModuleStateScanRequest
    ) async throws -> ModuleStateScanPage {
        try await base.scan(namespace: namespace, request: request)
    }

    func transact(
        namespace: ModuleStateNamespace,
        transaction: ModuleStateTransaction
    ) async throws -> ModuleStateTransactionResult {
        try await base.transact(namespace: namespace, transaction: transaction)
    }

    func quarantine(
        namespace: ModuleStateNamespace,
        diagnosticCode: String
    ) async throws -> ModuleStateHealthSnapshot {
        try await base.quarantine(namespace: namespace, diagnosticCode: diagnosticCode)
    }

    func health(namespace: ModuleStateNamespace) async -> ModuleStateHealthSnapshot {
        await base.health(namespace: namespace)
    }

    func progressionPrepareCount() -> Int { prepareCount }
}

private func optionalProgressionDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: RuneScribeModuleIDs.progression,
        moduleVersion: version,
        kind: .service,
        criticality: .optional,
        entryPoint: "StoreFailingProgressionModule",
        role: RuneScribeRoles.progression,
        requestedCapabilities: [RuneScribeCapabilities.moduleStateAccess],
        requiredServices: [RuneScribeServiceIDs.moduleStateStore]
    )
}

private func optionalThemeDescriptor(version: SemanticVersion) -> ModuleDescriptor {
    ModuleDescriptor(
        moduleID: "com.runescribe.module.theme.moonleaf.integration",
        moduleVersion: version,
        kind: .service,
        criticality: .optional,
        entryPoint: "MoonleafIntegrationThemeModule",
        role: "runescribe.theme.moonleaf.integration",
        requestedCapabilities: [],
        requiredModuleRoles: [RuneScribeRoles.core]
    )
}

private func integrationManifest(
    for descriptor: ModuleDescriptor,
    runtimeVersion: SemanticVersion,
    entitlement: EntitlementRequirement? = nil
) -> ModuleManifest {
    ModuleManifest(
        runtimeVersion: runtimeVersion,
        moduleID: descriptor.moduleID,
        displayName: descriptor.entryPoint,
        moduleVersion: descriptor.moduleVersion,
        moduleType: descriptor.kind,
        criticality: descriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
        entryPoint: descriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: descriptor.requiredServices.sorted(),
            requiredResources: descriptor.requiredResources.sorted { $0.name < $1.name },
            requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
        ),
        defaultRole: descriptor.role,
        consumedEndpoints: descriptor.consumedEndpoints.sorted(),
        publishedEndpoints: descriptor.publishedEndpoints.sorted(),
        entitlementRequirement: entitlement
    )
}
