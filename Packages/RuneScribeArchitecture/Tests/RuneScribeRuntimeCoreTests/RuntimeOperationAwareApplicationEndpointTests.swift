import Foundation
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@_spi(RuntimeTesting) @testable import RuneScribeRuntimeCore
import XCTest

@MainActor
final class RuntimeOperationAwareApplicationEndpointTests: XCTestCase {
    func testNilStoreUtilityEndpointsExecuteWithRuntimeGenerationContexts() async throws {
        let now = Date(timeIntervalSince1970: 12_345.678_901)
        let service = OperationAwareApplicationProbe()
        let clientCapture = OperationAwareCommandClientCapture()
        let coreDescriptor = Self.coreDescriptor
        let clientDescriptor = Self.clientDescriptor
        let runtime = RuneScribeRuntime(
            runtimeVersion: Self.version,
            platform: .macOS,
            environment: RuntimeEnvironment(now: { now }, nextUUID: { UUID() })
        )
        try await runtime.register(
            manifest: manifest(for: coreDescriptor),
            factory: AnyModuleFactory(descriptor: coreDescriptor) {
                OperationAwareApplicationPublishingModule(
                    descriptor: coreDescriptor,
                    service: service
                )
            }
        )
        try await runtime.register(
            manifest: manifest(for: clientDescriptor),
            factory: AnyModuleFactory(descriptor: clientDescriptor) {
                OperationAwareApplicationClientModule(
                    descriptor: clientDescriptor,
                    capture: clientCapture
                )
            }
        )

        try await runtime.start()
        let capturedClient = await clientCapture.client()
        let client = try XCTUnwrap(capturedClient)
        let encoded = try await client.send(
            EncodeMessageCommand(plaintext: "utility encode"),
            to: RuntimeApplicationEndpointCatalog.encode
        )
        let decoded = try await client.send(
            DecodeMessageCommand(runes: encoded.runes),
            to: RuntimeApplicationEndpointCatalog.decode
        )
        let created = try await client.send(
            CreateCipherCommand(name: "Utility Cipher"),
            to: RuntimeApplicationEndpointCatalog.createCipher
        )

        let expectedEncoded = await service.expectedEncodedResult()
        let expectedDecoded = await service.expectedDecodedResult()
        let expectedCipher = await service.expectedCipher()
        XCTAssertEqual(encoded, expectedEncoded)
        XCTAssertEqual(decoded, expectedDecoded)
        XCTAssertEqual(created, expectedCipher)
        let contexts = await service.contexts()
        let expectedOperationIdentifiers: Set<RuntimeOperationIdentifier> = [
            RuntimeOperationIdentifier(
                RuntimeApplicationEndpointCatalog.encode.descriptor.endpointID.rawValue
            ),
            RuntimeOperationIdentifier(
                RuntimeApplicationEndpointCatalog.decode.descriptor.endpointID.rawValue
            ),
            RuntimeOperationIdentifier(
                RuntimeApplicationEndpointCatalog.createCipher.descriptor.endpointID.rawValue
            ),
        ]
        XCTAssertEqual(
            Set<RuntimeOperationIdentifier>(contexts.keys),
            expectedOperationIdentifiers
        )
        XCTAssertEqual(Set(contexts.values.map(\.runtimeOperationID)).count, 3)
        XCTAssertEqual(Set(contexts.values.map(\.runtimeCorrelationID)).count, 3)
        for context in contexts.values {
            XCTAssertEqual(context.authorityScope, .runtimeGeneration)
            XCTAssertEqual(context.issuingRuntimeGeneration, 1)
            XCTAssertEqual(
                context.runtimeOccurredAtUTC.timeIntervalSince1970,
                12_345.679,
                accuracy: 0.000_001
            )
        }
        await runtime.stop()
    }

    private static let version = SemanticVersion(
        major: UInt(1),
        minor: UInt(0),
        patch: UInt(0)
    )

    private static let coreDescriptor = ModuleDescriptor(
        moduleID: "com.runescribe.test.operation-aware-core",
        moduleVersion: version,
        kind: .service,
        entryPoint: "OperationAwareApplicationPublishingModule",
        role: RuneScribeRoles.core,
        requestedCapabilities: [],
        publishedEndpoints: RuntimeApplicationEndpointCatalog.applicationEndpointIDs
    )

    private static let clientDescriptor = ModuleDescriptor(
        moduleID: "com.runescribe.test.operation-aware-client",
        moduleVersion: version,
        kind: .ui,
        entryPoint: "OperationAwareApplicationClientModule",
        role: RuneScribeRoles.primaryUI,
        requestedCapabilities: [
            RuneScribeCapabilities.applicationCommands,
            RuneScribeCapabilities.rootUI,
        ],
        requiredModuleRoles: [RuneScribeRoles.core],
        consumedEndpoints: [
            RuntimeApplicationEndpointCatalog.encode.descriptor.endpointID,
            RuntimeApplicationEndpointCatalog.decode.descriptor.endpointID,
            RuntimeApplicationEndpointCatalog.createCipher.descriptor.endpointID,
        ]
    )

    private func manifest(for descriptor: ModuleDescriptor) -> ModuleManifest {
        ModuleManifest(
            runtimeVersion: Self.version,
            moduleID: descriptor.moduleID,
            displayName: descriptor.entryPoint,
            moduleVersion: descriptor.moduleVersion,
            moduleType: descriptor.kind,
            criticality: descriptor.criticality,
            supportedPlatforms: [.macOS],
            minimumOS: MinimumOSVersions(macOS: "15.0"),
            capabilitiesRequested: descriptor.requestedCapabilities.sorted(),
            entryPoint: descriptor.entryPoint,
            runtimeRequirements: ModuleRuntimeRequirements(
                requiredServices: descriptor.requiredServices.sorted(),
                requiredModuleRoles: descriptor.requiredModuleRoles.sorted()
            ),
            defaultRole: descriptor.role,
            consumedEndpoints: descriptor.consumedEndpoints.sorted(),
            publishedEndpoints: descriptor.publishedEndpoints.sorted()
        )
    }
}

private struct OperationAwareApplicationPublishingModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let service: OperationAwareApplicationProbe

    func start(context: ModuleContext) async throws {
        try await context.registerApplicationEndpoints(service)
    }

    func stop() async {}
}

private struct OperationAwareApplicationClientModule: RuneScribeModule {
    let descriptor: ModuleDescriptor
    let capture: OperationAwareCommandClientCapture

    func start(context: ModuleContext) async throws {
        let client = try await context.commandClient(
            to: .role(RuneScribeRoles.core)
        )
        await capture.setClient(client)
    }

    func stop() async {}
}

private actor OperationAwareCommandClientCapture {
    private var storedClient: RuntimeCommandClient?

    func setClient(_ client: RuntimeCommandClient) {
        storedClient = client
    }

    func client() -> RuntimeCommandClient? { storedClient }
}

private actor OperationAwareApplicationProbe: RuneScribeOperationAwareApplicationService {
    private let cipherID = CipherID(
        rawValue: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    )
    private var observedContexts: [
        RuntimeOperationIdentifier: RuntimePersistableOperationContext
    ] = [:]

    nonisolated func stateStream() -> AsyncStream<RuneScribeApplicationSnapshot> {
        AsyncStream { continuation in continuation.finish() }
    }

    func expectedEncodedResult() -> EncodedMessageResult {
        EncodedMessageResult(runes: "utility-runes", cipherID: cipherID)
    }

    func expectedDecodedResult() -> DecodedMessageResult {
        DecodedMessageResult(
            plaintext: "utility decode",
            cipherID: cipherID,
            cipherName: "Utility Cipher"
        )
    }

    func expectedCipher() -> CipherSummary {
        CipherSummary(
            id: cipherID,
            name: "Utility Cipher",
            origin: .generated,
            createdAt: Date(timeIntervalSince1970: 1),
            isActive: true,
            assignedContactID: nil,
            hasBeenDelivered: false,
            publicIdentifier: "utility-public-id",
            fontID: .bundledRuneFont
        )
    }

    func contexts() -> [
        RuntimeOperationIdentifier: RuntimePersistableOperationContext
    ] {
        observedContexts
    }

    func encode(
        _ command: EncodeMessageCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> EncodedMessageResult {
        observedContexts[context.runtimeOperationIdentifier] = context
        return expectedEncodedResult()
    }

    func decode(
        _ command: DecodeMessageCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> DecodedMessageResult {
        observedContexts[context.runtimeOperationIdentifier] = context
        return expectedDecodedResult()
    }

    func createCipher(
        _ command: CreateCipherCommand,
        context: RuntimePersistableOperationContext
    ) async throws -> CipherSummary {
        observedContexts[context.runtimeOperationIdentifier] = context
        return expectedCipher()
    }

    func encode(_ command: EncodeMessageCommand) async throws -> EncodedMessageResult {
        throw OperationAwareProbeError.legacyPath
    }

    func decode(_ command: DecodeMessageCommand) async throws -> DecodedMessageResult {
        throw OperationAwareProbeError.legacyPath
    }

    func createCipher(_ command: CreateCipherCommand) async throws -> CipherSummary {
        throw OperationAwareProbeError.legacyPath
    }

    func renameCipher(_ command: RenameCipherCommand) async throws -> CipherSummary {
        throw OperationAwareProbeError.unexpectedCommand
    }

    func deleteCipher(id: CipherID) async throws { throw OperationAwareProbeError.unexpectedCommand }
    func setActiveCipher(_ command: SetActiveCipherCommand) async throws { throw OperationAwareProbeError.unexpectedCommand }
    func assignContact(_ command: AssignContactCommand) async throws { throw OperationAwareProbeError.unexpectedCommand }
    func createContact(_ command: CreateContactCommand) async throws -> ContactSummary { throw OperationAwareProbeError.unexpectedCommand }
    func updateContact(_ command: UpdateContactCommand) async throws -> ContactSummary { throw OperationAwareProbeError.unexpectedCommand }
    func deleteContacts(ids: Set<ContactID>) async throws { throw OperationAwareProbeError.unexpectedCommand }
    func deleteAllImportedContacts() async throws { throw OperationAwareProbeError.unexpectedCommand }
    func importContacts(_ command: ImportContactsCommand) async throws -> [ContactSummary] { throw OperationAwareProbeError.unexpectedCommand }
    func requestSystemContacts() async throws -> [SystemContactDTO] { throw OperationAwareProbeError.unexpectedCommand }
    func prepareCipherShare(_ command: PrepareCipherShareCommand) async throws -> ShareArtifactDTO { throw OperationAwareProbeError.unexpectedCommand }
    func prepareMessageShare(_ command: PrepareMessageShareCommand) async throws -> ShareArtifactDTO { throw OperationAwareProbeError.unexpectedCommand }
    func completeShareArtifact(_ command: CompleteShareArtifactCommand) async throws -> ShareArtifactCompletionResultDTO { throw OperationAwareProbeError.unexpectedCommand }
    func releaseShareArtifact(id: ShareArtifactID) async {}
    func importFile(_ input: InboundFileDTO) async throws -> ImportResultDTO { throw OperationAwareProbeError.unexpectedCommand }
    func importURL(_ input: InboundURLDTO) async throws -> ImportResultDTO { throw OperationAwareProbeError.unexpectedCommand }
    func confirmImport(_ command: ConfirmImportCommand) async throws -> CipherSummary { throw OperationAwareProbeError.unexpectedCommand }
    func cancelImport(id: ImportID) async {}
    func dismissReceivedMessage(id: MessageID) async {}
    func lock() async {}
    func verifyPIN(_ input: PINInput) async throws -> Bool { throw OperationAwareProbeError.unexpectedCommand }
    func unlock(_ command: UnlockCommand) async throws -> UnlockResultDTO { throw OperationAwareProbeError.unexpectedCommand }
    func setPIN(_ command: SetPINCommand) async throws { throw OperationAwareProbeError.unexpectedCommand }
    func changePIN(_ command: ChangePINCommand) async throws { throw OperationAwareProbeError.unexpectedCommand }
    func disablePIN(_ command: DisablePINCommand) async throws { throw OperationAwareProbeError.unexpectedCommand }
}

private enum OperationAwareProbeError: Error {
    case legacyPath
    case unexpectedCommand
}
