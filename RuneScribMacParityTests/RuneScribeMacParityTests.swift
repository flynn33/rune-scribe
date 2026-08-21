import AppKit
import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import RuneScribeNorseThemeModule
import RuneScribePlatform
@_spi(RuntimeFileImportHost) @_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import RuneScribeTestSupport
@testable import RuneScribeUIModule
import RuneScribeUIRuntime
import SwiftUI
import XCTest

@MainActor
final class RuneScribeMacParityTests: XCTestCase {
    func testRealViewsRenderWithFocusableWorkspaceAndExactCommandCatalog() async throws {
        try await withHarness { harness in
            let workspace = AnyView(RootView(session: harness.session))
            let settings = AnyView(
                SettingsView()
                    .environmentObject(harness.session)
            )

            let workspacePNG = try renderPNG(
                workspace,
                size: CGSize(width: 600, height: 720)
            )
            let settingsPNG = try renderPNG(
                settings,
                size: CGSize(width: 600, height: 720)
            )
            XCTAssertGreaterThan(workspacePNG.count, 10_000)
            XCTAssertGreaterThan(settingsPNG.count, 10_000)
            attachPNG(workspacePNG, name: "mac-workspace")
            attachPNG(settingsPNG, name: "mac-settings")

            let focus = inspectKeyboardFocus(
                workspace,
                size: CGSize(width: 600, height: 720)
            )
            XCTAssertGreaterThanOrEqual(focus.keyViewCount, 3)
            XCTAssertGreaterThan(focus.focusableViewCount, 0)
            XCTAssertTrue(focus.acceptedFirstResponder)

            XCTAssertTrue(RuneScribeCommandCatalog.removesSystemNewItem)
            XCTAssertEqual(RuneScribeCommandCatalog.settings.title, "Settings…")
            XCTAssertEqual(RuneScribeCommandCatalog.settings.command, .openSettings)
            XCTAssertEqual(RuneScribeCommandCatalog.settings.key, .character(","))
            XCTAssertEqual(RuneScribeCommandCatalog.settings.modifiers, [.command])
            XCTAssertEqual(RuneScribeCommandCatalog.cipherLibrary.title, "Cipher Library…")
            XCTAssertEqual(
                RuneScribeCommandCatalog.cipherLibrary.command,
                .openCipherLibrary
            )
            XCTAssertEqual(
                RuneScribeCommandCatalog.cipherLibrary.key,
                .character("l")
            )
            XCTAssertEqual(
                RuneScribeCommandCatalog.cipherLibrary.modifiers,
                [.command, .shift]
            )
            XCTAssertNil(RuneScribeCommandCatalog.primaryAction.command)
            XCTAssertEqual(RuneScribeCommandCatalog.primaryAction.key, .returnKey)
            XCTAssertEqual(
                RuneScribeCommandCatalog.primaryAction.modifiers,
                [.command]
            )
        }
    }

    func testCustomFontSuccessAndFailureProjectThroughRealSession() async throws {
        try await withHarness { harness in
            let validURL = URL(
                fileURLWithPath: "/in-memory-input/mac-valid-custom-font.runescribe"
            )
            let validFixture = try makeCipherFile(
                publicID: Data([0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7]),
                fontID: "mac-custom",
                expectedFontBytes: Self.validCustomFontBytes,
                suppliedFontBytes: Self.validCustomFontBytes
            )
            await harness.inboundFiles.set(validFixture, for: validURL)

            let validResult = try await harness.importSelectedFile(validURL)
            XCTAssertEqual(validResult.disposition, .awaitingConfirmation)
            let validPending = try XCTUnwrap(validResult.pendingImport)
            XCTAssertTrue(validPending.includesFont)
            let validPendingObserved = await eventually {
                harness.session.pendingImport?.id == validPending.id
            }
            XCTAssertTrue(validPendingObserved)

            let confirmationPNG = try renderPNG(
                AnyView(
                    ImportConfirmView(
                        pending: validPending,
                        confirmImport: { label in
                            try await harness.session.confirmImport(
                                id: validPending.id,
                                name: label
                            )
                        }
                    )
                ),
                size: CGSize(width: 600, height: 720)
            )
            XCTAssertGreaterThan(confirmationPNG.count, 10_000)
            attachPNG(confirmationPNG, name: "mac-import-confirmation")

            let validOutcome = await ImportConfirmationFlow.attempt(
                label: "Mac Custom Font"
            ) { label in
                try await harness.session.confirmImport(
                    id: validPending.id,
                    name: label
                )
            }
            guard case let .imported(imported) = validOutcome else {
                return XCTFail("The valid custom-font fixture was not imported.")
            }
            XCTAssertTrue(validOutcome.shouldDismiss)
            XCTAssertEqual(imported.label, "Mac Custom Font")
            let importedStateObserved = await eventually {
                harness.session.activeCipher?.label == "Mac Custom Font"
                    && harness.session.ciphers.count == 2
            }
            XCTAssertTrue(importedStateObserved)

            let validDigest = Self.digestHex(Self.validCustomFontBytes)
            let validPath = try ProtectedPath.fontsDirectory
                .appending("\(validDigest).ttf")
            let persistedValidFont = try await harness.protectedFiles.read(
                relativePath: validPath
            )
            XCTAssertEqual(
                persistedValidFont,
                Self.validCustomFontBytes
            )
            let customFontRegistered = await harness.fontRegistrar.isRegistered(
                Self.validCustomFontBytes
            )
            XCTAssertTrue(customFontRegistered)
            XCTAssertTrue(harness.session.snapshot?.fonts.contains {
                $0.id == FontID(rawValue: "mac-custom")
                    && $0.source == .imported
                    && $0.isRegistered
            } == true)

            let invalidURL = URL(
                fileURLWithPath: "/in-memory-input/mac-invalid-custom-font.runescribe"
            )
            let expectedInvalidBytes = Data("expected-mac-font".utf8)
            let invalidFixture = try makeCipherFile(
                publicID: Data([0xB0, 0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7]),
                fontID: "mac-rejected",
                expectedFontBytes: expectedInvalidBytes,
                suppliedFontBytes: Data("hash-mismatched-font".utf8)
            )
            await harness.inboundFiles.set(invalidFixture, for: invalidURL)

            let invalidResult = try await harness.importSelectedFile(invalidURL)
            XCTAssertEqual(invalidResult.disposition, .awaitingConfirmation)
            let invalidPending = try XCTUnwrap(invalidResult.pendingImport)
            let invalidPendingObserved = await eventually {
                harness.session.pendingImport?.id == invalidPending.id
            }
            XCTAssertTrue(invalidPendingObserved)

            let invalidOutcome = await ImportConfirmationFlow.attempt(
                label: "Rejected Mac Font"
            ) { label in
                try await harness.session.confirmImport(
                    id: invalidPending.id,
                    name: label
                )
            }
            guard case let .failed(importError) = invalidOutcome else {
                return XCTFail("The hash-mismatched custom font was accepted.")
            }
            XCTAssertFalse(invalidOutcome.shouldDismiss)
            harness.session.importErrorMessage = RuneScribeUISession.message(
                for: importError
            )
            let invalidFailureObserved = await eventually {
                harness.session.pendingImport?.id == invalidPending.id
                    && harness.session.lastError != nil
            }
            XCTAssertTrue(invalidFailureObserved)
            XCTAssertEqual(harness.session.activeCipher?.label, "Mac Custom Font")
            XCTAssertEqual(
                harness.session.ciphers.map(\.label).sorted(),
                ["Mac Custom Font", "My Cipher"]
            )
            XCTAssertFalse(
                RootImportFailurePresentation.shouldShowAlert(
                    message: harness.session.importErrorMessage,
                    hasPendingImport: harness.session.pendingImport != nil,
                    isLocked: harness.session.isLocked,
                    showSplash: false
                )
            )

            let invalidDigest = Self.digestHex(expectedInvalidBytes)
            let invalidPath = try ProtectedPath.fontsDirectory
                .appending("\(invalidDigest).ttf")
            let persistedInvalidFont = try await harness.protectedFiles.read(
                relativePath: invalidPath
            )
            XCTAssertNil(persistedInvalidFont)
            let persistedFontPaths = try await harness.protectedFiles.contents(
                of: .fontsDirectory,
                matchingExtension: "ttf"
            )
            XCTAssertEqual(
                persistedFontPaths,
                [validPath]
            )
        }
    }

    func testProductionShareControlsRenderAndCoreReleasesScopedArtifacts() async throws {
        try await withHarness { harness in
            let activeCipher = try XCTUnwrap(harness.session.activeCipher)
            let linkArtifact = try await harness.session.prepareCipherShare(
                cipherID: activeCipher.id,
                displayName: activeCipher.label,
                representation: .link
            )
            guard case .opaque = linkArtifact.reference else {
                return XCTFail("The cipher share did not produce an opaque link artifact.")
            }
            let transfer = try await harness.session.shareTransfer(
                for: linkArtifact.id
            )

            let fileArtifact = try await harness.session.prepareCipherShare(
                cipherID: activeCipher.id,
                displayName: activeCipher.label,
                representation: .file
            )
            guard case let .file(fileArtifactID) = fileArtifact.reference else {
                return XCTFail("The cipher share did not produce a file artifact.")
            }
            XCTAssertEqual(fileArtifactID, fileArtifact.id)
            let fileTransfer = try await harness.session.shareTransfer(
                for: fileArtifact.id
            )
            let fileURL = try await harness.shareURL(for: fileArtifact.id)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

            let controlsPNG = try renderPNG(
                AnyView(
                    VStack(spacing: 12) {
                        RuneScribeCipherLinkShareLink(
                            transfer: transfer,
                            cipherLabel: activeCipher.label
                        ) {
                            Label("Share link", systemImage: "link")
                        }
                        RuneScribeFileShareLink(transfer: fileTransfer)
                    }
                    .frame(width: 320, height: 160)
                ),
                size: CGSize(width: 320, height: 160)
            )
            XCTAssertGreaterThan(controlsPNG.count, 4_000)
            attachPNG(controlsPNG, name: "mac-share-controls")

            let cancelledReport = try SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .cancelled
            )
            let linkEvidence = try await transfer.finish(cancelledReport)
            let linkCompletion = try await harness.session.completeShareArtifact(
                evidence: linkEvidence
            )
            let fileEvidence = try await fileTransfer.finish(cancelledReport)
            let fileCompletion = try await harness.session.completeShareArtifact(
                evidence: fileEvidence
            )
            XCTAssertEqual(linkCompletion, .released)
            XCTAssertEqual(fileCompletion, .released)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
            do {
                _ = try await harness.session.shareTransfer(for: linkArtifact.id)
                XCTFail("Cancelled share link remained available after Core cleanup.")
            } catch {
                // The opaque link lease was released by Core.
            }
            await transfer.close()
            await fileTransfer.close()
        }
    }

    private func withHarness(
        _ operation: (MacParityHarness) async throws -> Void
    ) async throws {
        let fontURL = try XCTUnwrap(
            RuneScribeNorseThemeModuleBootstrap.resourceBundle.url(
                forResource: "NotoSansRunic-Regular",
                withExtension: "ttf"
            )
        )
        let bundledFontBytes = try Data(contentsOf: fontURL)
        let harness = try await MacParityHarness(
            bundledFontURL: fontURL,
            bundledFontBytes: bundledFontBytes,
            validCustomFontBytes: Self.validCustomFontBytes
        )
        do {
            try await harness.start()
            let initialStateObserved = await eventually {
                harness.session.activeCipher?.label == "My Cipher"
                    && harness.session.isLoading == false
            }
            XCTAssertTrue(initialStateObserved)
            try await operation(harness)
            await harness.stop()
        } catch {
            await harness.stop()
            throw error
        }
    }

    private func makeCipherFile(
        publicID: Data,
        fontID: String,
        expectedFontBytes: Data,
        suppliedFontBytes: Data
    ) throws -> Data {
        let cipher = Cipher(
            label: "Fixture",
            origin: .imported,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            publicID: publicID,
            keyMaterial: Data(0 ..< 32),
            decorativeMapping: Array(0 ..< 32),
            fontRef: FontRef(
                id: fontID,
                version: 1,
                sha256: Data(SHA256.hash(data: expectedFontBytes))
            )
        )
        return try CipherSharePayload(cipher: cipher)
            .encodedFile(fontBytes: suppliedFontBytes)
    }

    private func renderPNG(_ view: AnyView, size: CGSize) throws -> Data {
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        let bitmap = try XCTUnwrap(
            hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds)
        )
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func attachPNG(_ data: Data, name: String) {
        let attachment = XCTAttachment(
            data: data,
            uniformTypeIdentifier: "public.png"
        )
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func inspectKeyboardFocus(
        _ view: AnyView,
        size: CGSize
    ) -> KeyboardFocusReport {
        _ = NSApplication.shared
        let hostingView = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
        )
        let window = makeOffscreenWindow(size: size)
        window.contentView = hostingView
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.recalculateKeyViewLoop()

        var chain: [NSView] = []
        var seen: Set<ObjectIdentifier> = []
        var current = window.initialFirstResponder ?? hostingView.nextKeyView
        while let view = current,
              seen.insert(ObjectIdentifier(view)).inserted,
              chain.count < 128 {
            chain.append(view)
            current = view.nextKeyView
        }

        let focusable = chain.filter(\.acceptsFirstResponder)
        let accepted = focusable.first.map(window.makeFirstResponder) ?? false
        return KeyboardFocusReport(
            keyViewCount: chain.count,
            focusableViewCount: focusable.count,
            acceptedFirstResponder: accepted
        )
    }

    private func makeOffscreenWindow(size: CGSize) -> NSWindow {
        let minimumX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let minimumY = NSScreen.screens.map(\.frame.minY).min() ?? 0
        let window = NSWindow(
            contentRect: NSRect(
                x: minimumX - 10_000,
                y: minimumY - 10_000,
                width: size.width,
                height: size.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        return window
    }

    private func eventually(
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< 2_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    private static func digestHex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static let validCustomFontBytes = Data(
        "deterministic-mac-custom-font".utf8
    )
}

@MainActor
private final class MacParityHarness {
    let session: RuneScribeUISession
    let service: RuneScribeCoreApplicationService
    let inboundFiles: InMemoryInboundFileReader
    let protectedFiles: InMemoryProtectedFileStore
    let fontRegistrar: InMemoryFontRegistrar

    private let shareArtifacts: AppleShareArtifactStore
    private let runtime: RuneScribeRuntime
    private let temporaryRoot: URL

    init(
        bundledFontURL: URL,
        bundledFontBytes: Data,
        validCustomFontBytes: Data
    ) async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RuneScribeMacParityTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false
        )

        let secureValues = InMemorySecureValueStore()
        let protectedFiles = InMemoryProtectedFileStore()
        let inboundFiles = InMemoryInboundFileReader()
        let shareArtifacts = AppleShareArtifactStore(
            temporaryDirectory: temporaryRoot.appendingPathComponent(
                "share",
                isDirectory: true
            )
        )
        let resources = MappedApplicationResourceLocator(
            locations: [.bundledRuneFont: bundledFontURL]
        )
        let fontRegistrar = InMemoryFontRegistrar(
            namesByData: [
                bundledFontBytes: "Noto Sans Runic",
                validCustomFontBytes: "Rune Scribe Custom",
            ]
        )
        let contacts = InMemoryContactAccessService(authorizationStatus: .denied)
        let clipboard = InMemoryClipboardService()
        let clock = SystemClock()
        let uuid = SystemUUIDProvider()
        let runtimeIO = RuntimeIOClient(
            secureValueData: {
                try await secureValues.data(service: $0, account: $1)
            },
            setSecureValue: {
                try await secureValues.set($0, service: $1, account: $2)
            },
            deleteSecureValue: {
                try await secureValues.delete(service: $0, account: $1)
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
            clipboardSnapshot: {
                let initialChangeCount = await clipboard.changeCount()
                let initialString = await clipboard.string()
                let finalChangeCount = await clipboard.changeCount()
                return RuntimeClipboardSnapshot(
                    changeCount: finalChangeCount,
                    string: initialChangeCount == finalChangeCount
                        ? initialString
                        : await clipboard.string()
                )
            },
            contactAuthorizationStatus: {
                await contacts.authorizationStatus()
            },
            requestContactAccess: {
                try await contacts.requestAccess()
            },
            fetchSystemContacts: {
                try await contacts.fetchContacts()
            },
            readInboundFile: {
                try await inboundFiles.read(
                    $0.fileURL,
                    requiresSecurityScope: $0.requiresSecurityScopedAccess,
                    maximumByteCount: $0.maximumByteCount
                )
            },
            registerBundledSystemFont: {
                let data = try await resources.data(for: $0)
                guard Data(SHA256.hash(data: data)) == $1 else {
                    throw RuntimeBundledFontFailure.integrityMismatch
                }
                let postScriptName = try await fontRegistrar.postScriptName(
                    forFontData: data
                )
                guard !postScriptName.isEmpty else {
                    throw RuntimeBundledFontFailure.unreadableFont
                }
                return try await fontRegistrar.registerFont(data)
            },
            systemFontPostScriptName: {
                try await fontRegistrar.postScriptName(forFontData: $0)
            },
            registerSystemFont: {
                try await fontRegistrar.registerFont($0)
            },
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
        let service = RuneScribeCoreApplicationService(runtimeIO: runtimeIO)
        let runtime = RuneScribeRuntime(
            runtimeVersion: MacParityRuntimeModules.version,
            platform: .macOS
        )
        let clientCapture = MacParityApplicationClientCapture()
        try await runtime.register(
            manifest: MacParityRuntimeModules.coreManifest,
            factory: AnyModuleFactory(
                descriptor: MacParityRuntimeModules.coreDescriptor
            ) {
                MacParityApplicationPublishingModule(service: service)
            }
        )
        try await runtime.register(
            manifest: MacParityRuntimeModules.clientManifest,
            factory: AnyModuleFactory(
                descriptor: MacParityRuntimeModules.clientDescriptor
            ) {
                MacParityApplicationClientModule(capture: clientCapture)
            }
        )
        try await runtime.installPlatformAdapter(
            shareArtifacts,
            for: RuneScribeServiceKeys.sharePresentation
        )
        try await runtime.installPlatformAdapter(
            InMemoryModuleStateStore(),
            for: RuneScribeServiceKeys.moduleStateStore
        )
        try await runtime.installPlatformAdapter(
            inboundFiles,
            for: RuneScribeServiceKeys.inboundFileReader
        )
        try await runtime.start()
        let applicationClient = try await clientCapture.requireClient()
        let uiRuntimeIO = try await clientCapture.requireRuntimeIO()
        let inboundFileImportSession = try await uiRuntimeIO.inboundFileImportSession {
            [applicationClient] input in
            try await applicationClient.importFile(input)
        }

        self.service = service
        self.inboundFiles = inboundFiles
        self.protectedFiles = protectedFiles
        self.fontRegistrar = fontRegistrar
        self.shareArtifacts = shareArtifacts
        self.runtime = runtime
        session = RuneScribeUISession(
            applicationClient: applicationClient,
            runtimeIO: uiRuntimeIO,
            inboundFileImportSession: inboundFileImportSession,
            resourcePresentation: RuntimeApplicationResourcePresentation(
                splashVideo: nil,
                metalLibrary: nil
            ),
            productMetadata: RuneScribeUIProductMetadata(
                version: "Parity Test",
                buildNumber: "1"
            )
        )
    }

    func start() async throws {
        try session.start()
        await service.startInboundProcessing()
    }

    func stop() async {
        await service.stopInboundProcessing()
        await session.stop()
        await runtime.stop()
        try? await shareArtifacts.removeAll()
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func shareURL(for artifactID: ShareArtifactID) async throws -> URL {
        try await shareArtifacts.presentationURL(for: artifactID)
    }

    func importSelectedFile(_ fileURL: URL) async throws -> ImportResultDTO {
        try await session.inboundFileImportSession.importSelectedFile(fileURL)
    }
}

private enum MacParityRuntimeModules {
    static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )
    static let coreID: ModuleIdentifier = "com.runescribe.test.mac-parity-core"
    static let clientID: ModuleIdentifier = "com.runescribe.test.mac-parity-ui"

    static let coreDescriptor = ModuleDescriptor(
        moduleID: coreID,
        moduleVersion: version,
        kind: .service,
        entryPoint: "RuneScribeMacParityCoreModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [RuneScribeCapabilities.inboundInput],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs.union(
            RuntimeApplicationEndpointCatalog.ingressEndpointIDs
        )
    )
    static let clientDescriptor = ModuleDescriptor(
        moduleID: clientID,
        moduleVersion: version,
        kind: .ui,
        entryPoint: "RuneScribeMacParityClientModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.fileImportUI,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        requiredServices: [RuneScribeServiceIDs.sharePresentation],
        requiredModuleRoles: [RuneScribeRoles.core],
        consumedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs
    )

    static let coreManifest = ModuleManifest(
        runtimeVersion: version,
        moduleID: coreID,
        displayName: "Rune Scribe Mac Parity Core",
        moduleVersion: version,
        moduleType: .service,
        criticality: coreDescriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: [RuneScribeCapabilities.inboundInput],
        entryPoint: coreDescriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(),
        defaultRole: RuneScribeRoles.core,
        consumedEndpoints: coreDescriptor.consumedEndpoints.sorted(),
        publishedEndpoints: coreDescriptor.publishedEndpoints.sorted()
    )
    static let clientManifest = ModuleManifest(
        runtimeVersion: version,
        moduleID: clientID,
        displayName: "Rune Scribe Mac Parity UI",
        moduleVersion: version,
        moduleType: .ui,
        criticality: clientDescriptor.criticality,
        supportedPlatforms: [.macOS],
        capabilitiesRequested: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.applicationStateRead,
            RuneScribeCapabilities.fileImportUI,
            RuneScribeCapabilities.rootUI,
            RuneScribeCapabilities.shareUI,
        ],
        entryPoint: clientDescriptor.entryPoint,
        runtimeRequirements: ModuleRuntimeRequirements(
            requiredServices: [RuneScribeServiceIDs.sharePresentation],
            requiredModuleRoles: [RuneScribeRoles.core]
        ),
        defaultRole: RuneScribeRoles.primaryUI,
        consumedEndpoints: clientDescriptor.consumedEndpoints.sorted(),
        publishedEndpoints: clientDescriptor.publishedEndpoints.sorted()
    )
}

private struct MacParityApplicationPublishingModule: RuneScribeModule {
    let descriptor = MacParityRuntimeModules.coreDescriptor
    let service: RuneScribeCoreApplicationService

    func start(context: ModuleContext) async throws {
        try await context.registerApplicationEndpoints(service)
        try await context.registerInboundInputEndpoint(service)
    }

    func stop() async {}
}

private actor MacParityApplicationClientCapture {
    private var client: RuntimeApplicationClient?
    private var runtimeIO: RuntimeIOClient?

    func store(_ client: RuntimeApplicationClient, runtimeIO: RuntimeIOClient) {
        self.client = client
        self.runtimeIO = runtimeIO
    }

    func requireClient() throws -> RuntimeApplicationClient {
        guard let client else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return client
    }

    func requireRuntimeIO() throws -> RuntimeIOClient {
        guard let runtimeIO else {
            throw MacParityHarnessError.applicationClientUnavailable
        }
        return runtimeIO
    }
}

private struct MacParityApplicationClientModule: RuneScribeModule {
    let descriptor = MacParityRuntimeModules.clientDescriptor
    let capture: MacParityApplicationClientCapture

    func start(context: ModuleContext) async throws {
        let client = try await context.applicationClient()
        let runtimeIO = try await context.runtimeIOClient()
        await capture.store(client, runtimeIO: runtimeIO)
    }

    func stop() async {}
}

private enum MacParityHarnessError: Error {
    case applicationClientUnavailable
}

private struct KeyboardFocusReport {
    let keyViewCount: Int
    let focusableViewCount: Int
    let acceptedFirstResponder: Bool
}
