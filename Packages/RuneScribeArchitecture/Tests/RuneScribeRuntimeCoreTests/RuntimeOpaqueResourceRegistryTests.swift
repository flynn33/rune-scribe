import CryptoKit
import CoreGraphics
import Foundation
import RuneScribeContracts
@testable import RuneScribeRuntimeCore
import XCTest

final class RuntimeOpaqueResourceRegistryTests: XCTestCase {
    private let publishCapability: CapabilityIdentifier = "runtime.resource.publish"
    private let resolveCapability: CapabilityIdentifier = "runtime.resource.resolve"
    private let providerRole: ModuleRole = "test.resource.provider"
    private let readerRole: ModuleRole = "test.resource.reader"

    func testOpaqueResourceMetadataCodablePreservesRegistrationAndDefaultsLegacyPayload()
        throws
    {
        let metadata = OpaqueResourceMetadata(
            handle: .init(
                namespace: "namespace.metadata-codec",
                resourceID: "resource.metadata-codec"
            ),
            ownerModuleID: "com.runescribe.test.metadata-codec",
            registrationID: 73,
            semanticRole: "codex.card",
            mediaType: .png,
            category: .image,
            byteCount: 256,
            sha256: String(repeating: "a", count: 64),
            pixelSize: .init(width: 16, height: 9)
        )

        let encoded = try JSONEncoder().encode(metadata)
        XCTAssertEqual(try JSONDecoder().decode(OpaqueResourceMetadata.self, from: encoded), metadata)

        var legacyDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            (legacyDocument["registrationID"] as? NSNumber)?.uint64Value,
            metadata.registrationID
        )
        legacyDocument.removeValue(forKey: "registrationID")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyDocument)
        let legacyMetadata = try JSONDecoder().decode(
            OpaqueResourceMetadata.self,
            from: legacyData
        )

        XCTAssertEqual(legacyMetadata.registrationID, 0)
        XCTAssertEqual(
            legacyMetadata,
            OpaqueResourceMetadata(
                handle: metadata.handle,
                ownerModuleID: metadata.ownerModuleID,
                semanticRole: metadata.semanticRole,
                mediaType: metadata.mediaType,
                category: metadata.category,
                byteCount: metadata.byteCount,
                sha256: metadata.sha256,
                pixelSize: metadata.pixelSize
            )
        )
    }

    func testProviderRegistersValidatedNamespaceAndResolverReceivesOpaqueData() async throws {
        let fixture = try await makeFixture()
        let data = try XCTUnwrap(Data(base64Encoded: Self.onePixelPNGBase64))
        let declaration = makeDeclaration(
            id: "image.card",
            role: "codex.card",
            mediaType: .png,
            data: data,
            pixelSize: .init(width: 1, height: 1)
        )

        try await fixture.provider.register(
            OpaqueResourceNamespaceRegistration(
                namespace: "namespace.provider",
                declarations: [declaration],
                payloads: [.init(resourceID: declaration.resourceID, data: data)]
            )
        )

        let handle = OpaqueResourceHandle(
            namespace: "namespace.provider",
            resourceID: "image.card"
        )
        let resolved = try await fixture.resolver.resolve(handle)
        XCTAssertEqual(resolved.data, data)
        XCTAssertEqual(resolved.metadata.handle, handle)
        XCTAssertEqual(resolved.metadata.ownerModuleID, fixture.providerDescriptor.moduleID)
        XCTAssertEqual(resolved.metadata.category, .image)
        XCTAssertEqual(resolved.metadata.pixelSize, .init(width: 1, height: 1))

        let snapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(snapshot.resources.map(\.handle), [handle])
        XCTAssertGreaterThan(snapshot.revision, 0)
    }

    func testDeferredResourcesLoadOnDemandWithoutRegistryRetention() async throws {
        let fixture = try await makeFixture()
        let data = Data("{\"theme\":\"deferred\"}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.deferred",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        let probe = DeferredResourceLoaderProbe(data: data)
        try await fixture.provider.register(
            .init(
                namespace: "namespace.deferred",
                declarations: [declaration],
                resourceLoader: { resourceID in
                    await probe.load(resourceID)
                }
            )
        )

        let callCountBeforeResolution = await probe.callCount()
        XCTAssertEqual(callCountBeforeResolution, 0)
        let handle = OpaqueResourceHandle(
            namespace: "namespace.deferred",
            resourceID: declaration.resourceID
        )
        let firstResolution = try await fixture.resolver.resolve(handle)
        let secondResolution = try await fixture.resolver.resolve(handle)
        XCTAssertEqual(firstResolution.data, data)
        XCTAssertEqual(secondResolution.data, data)
        let loadedResourceIDs = await probe.loadedResourceIDs()
        XCTAssertEqual(
            loadedResourceIDs,
            [declaration.resourceID, declaration.resourceID],
            "Each resolution must reload verified bytes instead of retaining the full catalog."
        )
    }

    func testDeferredRequiredResourceFailsClosedWhenLoaderReturnsNoBytes() async throws {
        let fixture = try await makeFixture()
        let expected = Data("{}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.deferred-missing",
            role: "descriptor",
            mediaType: .json,
            data: expected
        )
        try await fixture.provider.register(
            .init(
                namespace: "namespace.deferred-missing",
                declarations: [declaration],
                resourceLoader: { _ in nil }
            )
        )

        do {
            _ = try await fixture.resolver.resolve(
                .init(
                    namespace: "namespace.deferred-missing",
                    resourceID: declaration.resourceID
                )
            )
            XCTFail("A missing deferred required resource must fail resolution")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .missingRequiredResource(declaration.resourceID)
            )
        }
    }

    func testSuspendedDeferredResolutionCannotCrossNamespaceReregistration()
        async throws
    {
        let fixture = try await makeFixture()
        let data = Data("{\"theme\":\"registration\"}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.registration-race",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        let namespace: OpaqueResourceNamespaceID = "namespace.registration-race"
        let handle = OpaqueResourceHandle(
            namespace: namespace,
            resourceID: declaration.resourceID
        )
        let gate = SuspendedDeferredResourceLoader(data: data)
        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                resourceLoader: { resourceID in
                    await gate.load(resourceID)
                }
            )
        )
        let oldSnapshot = try await fixture.resolver.snapshot()
        let oldMetadata = try XCTUnwrap(oldSnapshot.resources.first)

        let oldResolution = Task {
            try await fixture.resolver.resolve(handle)
        }
        await gate.waitUntilEntered()
        try await fixture.provider.unregister(namespace)
        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                resourceLoader: { _ in data }
            )
        )
        let currentSnapshot = try await fixture.resolver.snapshot()
        let currentMetadata = try XCTUnwrap(currentSnapshot.resources.first)
        XCTAssertGreaterThan(currentMetadata.registrationID, oldMetadata.registrationID)

        await gate.release()
        do {
            _ = try await oldResolution.value
            XCTFail("An old suspended loader must not cross namespace reregistration.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .resourceUnavailable(handle)
            )
        }
        let currentResolution = try await fixture.resolver.resolve(handle)
        XCTAssertEqual(currentResolution.data, data)
        let finalSnapshot = try await fixture.resolver.snapshot()
        XCTAssertTrue(finalSnapshot.validationFaults.isEmpty)
    }

    func testCorruptRequiredUnlockSoundRecordsOneFaultAndReregistrationClearsIt()
        async throws
    {
        let fixture = try await makeFixture()
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let soundURL = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Audio/sound.norse.unlock-relic.wav"
        )
        let sound = try Data(contentsOf: soundURL)
        let corruptSound = Data(sound.dropLast())
        let declaration = makeDeclaration(
            id: "resource.sound.norse.unlock-relic",
            role: ThemeResourceRoles.unlockSound.rawValue,
            mediaType: .wav,
            data: sound
        )
        let namespace = RuntimeThemeContributionCatalog.resourceNamespace(
            for: RuneScribeCodexIDs.norse
        )
        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                resourceLoader: { _ in corruptSound }
            )
        )
        let registeredSnapshot = try await fixture.resolver.snapshot()
        let registrationID = try XCTUnwrap(
            registeredSnapshot.resources.first?.registrationID
        )

        let firstUnlockSound = await fixture.registry.unlockFeedbackSoundData(
            codexID: RuneScribeCodexIDs.norse,
            semanticID: .artifact
        )
        XCTAssertNil(firstUnlockSound)
        let faultedSnapshot = try await fixture.resolver.snapshot()
        XCTAssertGreaterThan(faultedSnapshot.revision, registeredSnapshot.revision)
        let fault = try XCTUnwrap(faultedSnapshot.validationFaults.first)
        XCTAssertEqual(fault.handle.resourceID, declaration.resourceID)
        XCTAssertEqual(fault.registrationID, registrationID)
        XCTAssertEqual(fault.code, .resourceMismatch)
        XCTAssertNil(fault.requiredBaseFailure)

        let repeatedUnlockSound = await fixture.registry.unlockFeedbackSoundData(
            codexID: RuneScribeCodexIDs.norse,
            semanticID: .artifact
        )
        XCTAssertNil(repeatedUnlockSound)
        let repeatedSnapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(repeatedSnapshot.revision, faultedSnapshot.revision)
        XCTAssertEqual(repeatedSnapshot.validationFaults, faultedSnapshot.validationFaults)

        try await fixture.provider.unregister(namespace)
        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                resourceLoader: { _ in sound }
            )
        )
        let freshSnapshot = try await fixture.resolver.snapshot()
        XCTAssertTrue(freshSnapshot.validationFaults.isEmpty)
        XCTAssertGreaterThan(
            try XCTUnwrap(freshSnapshot.resources.first?.registrationID),
            registrationID
        )
    }

    func testThemeProviderPolicyRejectsPayloadBackedNamespaceRegistration()
        async throws
    {
        let fixture = try await makeFixture(
            providerPolicyClass: RuneScribePolicyClasses.themeProvider
        )
        let data = Data("{}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.theme-provider-eager",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        let namespace: OpaqueResourceNamespaceID = "namespace.theme-provider-eager"
        do {
            try await fixture.provider.register(
                .init(
                    namespace: namespace,
                    declarations: [declaration],
                    payloads: [.init(resourceID: declaration.resourceID, data: data)]
                )
            )
            XCTFail("Theme-provider policy must reject payload-backed registration.")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .payloadBackedThemeProviderRegistrationDenied(namespace)
            )
        }

        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                resourceLoader: { _ in data }
            )
        )
        let snapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(snapshot.resources.count, 1)
    }

    func testRegistrationRejectsMissingRequiredAndUndeclaredPayloadsAtomically() async throws {
        let fixture = try await makeFixture()
        let requiredData = Data("required".utf8)
        let required = makeDeclaration(
            id: "descriptor.required",
            role: "descriptor",
            mediaType: .json,
            data: requiredData
        )

        do {
            try await fixture.provider.register(
                .init(
                    namespace: "namespace.missing",
                    declarations: [required],
                    payloads: []
                )
            )
            XCTFail("A required resource without bytes must be rejected")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .missingRequiredResource(required.resourceID)
            )
        }

        do {
            try await fixture.provider.register(
                .init(
                    namespace: "namespace.undeclared",
                    declarations: [required],
                    payloads: [
                        .init(resourceID: required.resourceID, data: requiredData),
                        .init(resourceID: "extra", data: Data()),
                    ]
                )
            )
            XCTFail("Payload bytes absent from the declaration must be rejected")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .undeclaredResource("extra")
            )
        }

        let snapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(snapshot.resources, [])
    }

    func testRegistrationRejectsDuplicateIDsAndNamespaceOwnership() async throws {
        let fixture = try await makeFixture()
        let data = Data("{}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.theme",
            role: "descriptor",
            mediaType: .json,
            data: data
        )

        do {
            try await fixture.provider.register(
                .init(
                    namespace: "namespace.duplicates",
                    declarations: [declaration, declaration],
                    payloads: [.init(resourceID: declaration.resourceID, data: data)]
                )
            )
            XCTFail("Duplicate resource identifiers must fail")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .duplicateResourceID(declaration.resourceID)
            )
        }

        let registration = OpaqueResourceNamespaceRegistration(
            namespace: "namespace.unique",
            declarations: [declaration],
            payloads: [.init(resourceID: declaration.resourceID, data: data)]
        )
        try await fixture.provider.register(registration)
        do {
            try await fixture.provider.register(registration)
            XCTFail("A namespace must have exactly one owner registration")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .duplicateNamespace(registration.namespace)
            )
        }
    }

    func testHashMediaTypePixelAndByteValidationFailClosed() async throws {
        let fixture = try await makeFixture()
        let data = Data("not-an-image".utf8)

        let badHash = OpaqueResourceDeclaration(
            resourceID: "descriptor.hash",
            semanticRole: "descriptor",
            mediaType: .json,
            byteCount: data.count,
            sha256: String(repeating: "0", count: 64)
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.hash",
            declaration: badHash,
            data: data,
            equals: .hashMismatch(badHash.resourceID)
        )

        let unsupported = makeDeclaration(
            id: "archive.bad",
            role: "archive",
            mediaType: "application/zip",
            data: data
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.media",
            declaration: unsupported,
            data: data,
            equals: .unsupportedMediaType(unsupported.mediaType)
        )

        let mismatchedBytes = OpaqueResourceDeclaration(
            resourceID: "descriptor.bytes",
            semanticRole: "descriptor",
            mediaType: .json,
            byteCount: data.count + 1,
            sha256: Self.digest(data)
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.bytes",
            declaration: mismatchedBytes,
            data: data,
            equals: .byteCountMismatch(mismatchedBytes.resourceID)
        )

        let invalidImage = makeDeclaration(
            id: "image.invalid",
            role: "card",
            mediaType: .png,
            data: data,
            pixelSize: .init(width: 1, height: 1)
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.image",
            declaration: invalidImage,
            data: data,
            equals: .mediaTypeMismatch(invalidImage.resourceID)
        )

        let invalidJSON = makeDeclaration(
            id: "descriptor.invalid-json",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.json",
            declaration: invalidJSON,
            data: data,
            equals: .mediaTypeMismatch(invalidJSON.resourceID)
        )
    }

    func testPerResourceCatalogAndModuleBudgetsAreEnforcedPerOwner() async throws {
        let tightBudget = OpaqueResourceBudget(
            maximumDescriptorBytes: 4,
            maximumImageBytes: 8,
            maximumImageDimension: 4_096,
            maximumImageCatalogBytes: 8,
            maximumFontBytes: 8,
            maximumFontCatalogBytes: 8,
            maximumAnimationCatalogBytes: 8,
            maximumSoundBytes: 4,
            maximumSoundCatalogBytes: 4,
            maximumModuleBytes: 8
        )
        let fixture = try await makeFixture(budget: tightBudget)
        let tooLarge = Data("[123]".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.large",
            role: "descriptor",
            mediaType: .json,
            data: tooLarge
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.large",
            declaration: declaration,
            data: tooLarge,
            equals: .resourceBudgetExceeded(declaration.resourceID)
        )

        let firstData = Data("{}  ".utf8)
        let first = makeDeclaration(
            id: "descriptor.first",
            role: "descriptor",
            mediaType: .json,
            data: firstData
        )
        try await fixture.provider.register(
            .init(
                namespace: "namespace.first",
                declarations: [first],
                payloads: [.init(resourceID: first.resourceID, data: firstData)]
            )
        )

        let secondData = Data("[]  ".utf8)
        let second = makeDeclaration(
            id: "descriptor.second",
            role: "descriptor",
            mediaType: .json,
            data: secondData
        )
        try await fixture.provider.register(
            .init(
                namespace: "namespace.second",
                declarations: [second],
                payloads: [.init(resourceID: second.resourceID, data: secondData)]
            )
        )

        let thirdData = Data("{}".utf8)
        let third = makeDeclaration(
            id: "descriptor.third",
            role: "descriptor",
            mediaType: .json,
            data: thirdData
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.third",
            declaration: third,
            data: thirdData,
            equals: .moduleBudgetExceeded
        )
    }

    func testHEIFValidationMatchesDeclaredPrimaryDimensionsAfterAuxiliaryImage() async throws {
        let fixture = try await makeFixture()
        let data = Self.heifContainer(dimensions: [(512, 512), (1_600, 1_200)])
        let declaration = makeDeclaration(
            id: "image.heif-primary",
            role: "relic.static-share-fallback",
            mediaType: .heif,
            data: data,
            pixelSize: .init(width: 1_600, height: 1_200)
        )

        try await fixture.provider.register(
            .init(
                namespace: "namespace.heif-primary",
                declarations: [declaration],
                payloads: [.init(resourceID: declaration.resourceID, data: data)]
            )
        )

        let resolved = try await fixture.resolver.resolve(
            .init(namespace: "namespace.heif-primary", resourceID: declaration.resourceID)
        )
        XCTAssertEqual(resolved.metadata.pixelSize, .init(width: 1_600, height: 1_200))

        let mismatch = makeDeclaration(
            id: "image.heif-mismatch",
            role: "relic.static-share-fallback",
            mediaType: .heif,
            data: data,
            pixelSize: .init(width: 1_024, height: 768)
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.heif-mismatch",
            declaration: mismatch,
            data: data,
            equals: .pixelSizeMismatch(mismatch.resourceID)
        )
    }

    func testInvalidationRemovesOwnedResourcesAndRevokesProviderClient() async throws {
        let fixture = try await makeFixture()
        let data = Data("{}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.theme",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        let namespace: OpaqueResourceNamespaceID = "namespace.revoked"
        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                payloads: [.init(resourceID: declaration.resourceID, data: data)]
            )
        )

        await fixture.registry.invalidateModule(
            fixture.providerDescriptor.moduleID,
            generation: 1
        )
        let snapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(snapshot.resources, [])

        let handle = OpaqueResourceHandle(
            namespace: namespace,
            resourceID: declaration.resourceID
        )
        do {
            _ = try await fixture.resolver.resolve(handle)
            XCTFail("A stopped provider's namespace must be unavailable")
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                .namespaceUnavailable(namespace)
            )
        }

        do {
            try await fixture.provider.register(
                .init(namespace: "namespace.stale", declarations: [], payloads: [])
            )
            XCTFail("A provider client from an invalidated generation must be stale")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .staleClient(fixture.providerDescriptor.moduleID)
            )
        }
    }

    func testRuntimeReplacementRevokesAllOldClients() async throws {
        let fixture = try await makeFixture()
        await fixture.registry.deactivateRuntime()
        _ = await fixture.registry.activateRuntime()

        do {
            _ = try await fixture.resolver.snapshot()
            XCTFail("A client from an earlier runtime generation must not revive")
        } catch {
            XCTAssertEqual(error as? RuneScribeRuntimeError, .runtimeNotRunning)
        }
    }

    func testChangeStreamEmitsInitialRegistrationRemovalAndFinishesOnRevocation()
        async throws
    {
        let fixture = try await makeFixture()
        let stream = try await fixture.resolver.changes()
        var iterator = stream.makeAsyncIterator()
        let initialRevisionValue = await iterator.next()
        let initialRevision = try XCTUnwrap(initialRevisionValue)

        let data = Data("{}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.stream",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        let namespace: OpaqueResourceNamespaceID = "namespace.stream"
        try await fixture.provider.register(
            .init(
                namespace: namespace,
                declarations: [declaration],
                payloads: [.init(resourceID: declaration.resourceID, data: data)]
            )
        )
        let registrationRevisionValue = await iterator.next()
        let registrationRevision = try XCTUnwrap(registrationRevisionValue)
        XCTAssertGreaterThan(registrationRevision, initialRevision)

        try await fixture.provider.unregister(namespace)
        let removalRevisionValue = await iterator.next()
        let removalRevision = try XCTUnwrap(removalRevisionValue)
        XCTAssertGreaterThan(removalRevision, registrationRevision)

        await fixture.registry.invalidateModule(
            fixture.readerDescriptor.moduleID,
            generation: 1
        )
        let terminalRevision = await iterator.next()
        XCTAssertNil(terminalRevision)
    }

    func testCompleteThemeBudgetIsIndependentForDifferentOwners() async throws {
        let tightBudget = OpaqueResourceBudget(
            maximumDescriptorBytes: 8,
            maximumImageBytes: 8,
            maximumImageDimension: 4_096,
            maximumImageCatalogBytes: 16,
            maximumFontBytes: 8,
            maximumFontCatalogBytes: 16,
            maximumAnimationCatalogBytes: 16,
            maximumSoundBytes: 8,
            maximumSoundCatalogBytes: 16,
            maximumModuleBytes: 16
        )
        let fixture = try await makeFixture(budget: tightBudget)
        let firstData = Data("{}  ".utf8)
        let first = makeDeclaration(
            id: "descriptor.owner-one",
            role: "descriptor",
            mediaType: .json,
            data: firstData
        )
        try await fixture.provider.register(
            .init(
                namespace: "namespace.owner-one",
                declarations: [first],
                payloads: [.init(resourceID: first.resourceID, data: firstData)]
            )
        )

        let secondDescriptor = makeDescriptor(
            id: "com.runescribe.test.resource-provider-two",
            role: providerRole,
            capabilities: [publishCapability]
        )
        try await fixture.registry.activateModule(
            descriptor: secondDescriptor,
            generation: 1
        )
        let runtimeGeneration = await fixture.registry.currentGeneration()
        let secondProvider = try await fixture.registry.makeProviderClient(
            sourceModuleID: secondDescriptor.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration,
            policy: makePolicy(),
            requiredCapability: publishCapability
        )
        let secondData = Data("[]  ".utf8)
        let second = makeDeclaration(
            id: "descriptor.owner-two",
            role: "descriptor",
            mediaType: .json,
            data: secondData
        )
        try await secondProvider.register(
            .init(
                namespace: "namespace.owner-two",
                declarations: [second],
                payloads: [.init(resourceID: second.resourceID, data: secondData)]
            )
        )

        let snapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(
            snapshot.resources.map(\.handle.namespace),
            ["namespace.owner-one", "namespace.owner-two"]
        )
    }

    func testTruncatedFontsMalformedPDFsAndMismatchedISOContainersFailClosed()
        async throws
    {
        let fixture = try await makeFixture()
        let truncatedTrueType = Data([0x00, 0x01, 0x00, 0x00, 0x00, 0x01])
        let trueType = makeDeclaration(
            id: "font.truncated-ttf",
            role: "script.font",
            mediaType: .trueTypeFont,
            data: truncatedTrueType
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.truncated-ttf",
            declaration: trueType,
            data: truncatedTrueType,
            equals: .mediaTypeMismatch(trueType.resourceID)
        )

        let truncatedOpenType = Data("OTTOjunk".utf8)
        let openType = makeDeclaration(
            id: "font.truncated-otf",
            role: "script.font",
            mediaType: .openTypeFont,
            data: truncatedOpenType
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.truncated-otf",
            declaration: openType,
            data: truncatedOpenType,
            equals: .mediaTypeMismatch(openType.resourceID)
        )

        for (namespace, bytes) in [
            ("namespace.pdf-junk-prefix", Data("junk%PDF-1.4\n%%EOF".utf8)),
            ("namespace.pdf-malformed", Data("%PDF-1.4\n%%EOF".utf8)),
        ] {
            let declaration = makeDeclaration(
                id: OpaqueResourceID(rawValue: namespace),
                role: "vector.master",
                mediaType: .pdf,
                data: bytes
            )
            await assertRegistration(
                fixture.provider,
                namespace: OpaqueResourceNamespaceID(rawValue: namespace),
                declaration: declaration,
                data: bytes,
                equals: .mediaTypeMismatch(declaration.resourceID)
            )
        }

        let quickTimeBrandedAsMP4 = Self.isoContainer(
            majorBrand: "qt  ",
            mediaBox: "mdat"
        )
        let mp4 = makeDeclaration(
            id: "animation.brand-mismatch",
            role: "background.motion",
            mediaType: .mp4,
            data: quickTimeBrandedAsMP4
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.brand-mismatch",
            declaration: mp4,
            data: quickTimeBrandedAsMP4,
            equals: .mediaTypeMismatch(mp4.resourceID)
        )
    }

    func testCompressedObjectStreamPDFIsAcceptedAndMultipagePDFFailsClosed()
        async throws
    {
        let fixture = try await makeFixture()
        let approvedURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "single-page-object-stream.pdf",
                withExtension: "base64"
            )
        )
        let approved = try XCTUnwrap(
            Data(
                base64Encoded: try Data(contentsOf: approvedURL),
                options: .ignoreUnknownCharacters
            )
        )
        XCTAssertNotNil(approved.range(of: Data("/ObjStm".utf8)))
        let approvedDeclaration = makeDeclaration(
            id: "vector.compressed-object-stream",
            role: "seal.vector-master",
            mediaType: .pdf,
            data: approved
        )
        try await fixture.provider.register(
            .init(
                namespace: "namespace.compressed-object-stream",
                declarations: [approvedDeclaration],
                payloads: [
                    .init(resourceID: approvedDeclaration.resourceID, data: approved),
                ]
            )
        )
        let resolved = try await fixture.resolver.resolve(
            OpaqueResourceHandle(
                namespace: "namespace.compressed-object-stream",
                resourceID: approvedDeclaration.resourceID
            )
        )
        XCTAssertEqual(resolved.data, approved)

        let multipageStorage = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: multipageStorage))
        var mediaBox = CGRect(x: 0, y: 0, width: 128, height: 128)
        let context = try XCTUnwrap(
            CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        )
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let multipage = multipageStorage as Data
        let multipageDeclaration = makeDeclaration(
            id: "vector.multipage",
            role: "seal.vector-master",
            mediaType: .pdf,
            data: multipage
        )
        await assertRegistration(
            fixture.provider,
            namespace: "namespace.multipage",
            declaration: multipageDeclaration,
            data: multipage,
            equals: .mediaTypeMismatch(multipageDeclaration.resourceID)
        )
    }

    func testUnlockFeedbackSoundResolutionUsesVerifiedSelectedCodexResource()
        async throws
    {
        let fixture = try await makeFixture()
        var repositoryRoot = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repositoryRoot.deleteLastPathComponent() }
        let soundURL = repositoryRoot.appendingPathComponent(
            "Packages/RuneScribeArchitecture/Sources/RuneScribeNorseThemeModule/Resources/Production/Audio/sound.norse.unlock-relic.wav"
        )
        let sound = try Data(contentsOf: soundURL)
        let declaration = makeDeclaration(
            id: "resource.sound.norse.unlock-relic",
            role: ThemeResourceRoles.unlockSound.rawValue,
            mediaType: .wav,
            data: sound
        )
        try await fixture.provider.register(
            .init(
                namespace: OpaqueResourceNamespaceID(
                    rawValue: RuneScribeCodexIDs.norse.rawValue
                ),
                declarations: [declaration],
                payloads: [.init(resourceID: declaration.resourceID, data: sound)]
            )
        )

        let resolved = await fixture.registry.unlockFeedbackSoundData(
            codexID: RuneScribeCodexIDs.norse,
            semanticID: .artifact
        )
        XCTAssertEqual(resolved, sound)
        let unavailable = await fixture.registry.unlockFeedbackSoundData(
            codexID: RuneScribeCodexIDs.norse,
            semanticID: .mastery
        )
        XCTAssertNil(unavailable)
    }

    func testModuleGenerationReplacementRemovesResourcesWithoutExplicitInvalidation() async throws {
        let fixture = try await makeFixture()
        let data = Data("{}".utf8)
        let declaration = makeDeclaration(
            id: "descriptor.replaced",
            role: "descriptor",
            mediaType: .json,
            data: data
        )
        try await fixture.provider.register(
            .init(
                namespace: "namespace.replaced",
                declarations: [declaration],
                payloads: [.init(resourceID: declaration.resourceID, data: data)]
            )
        )

        try await fixture.registry.activateModule(
            descriptor: fixture.providerDescriptor,
            generation: 2
        )
        let snapshot = try await fixture.resolver.snapshot()
        XCTAssertEqual(snapshot.resources, [])

        do {
            try await fixture.provider.register(
                .init(namespace: "namespace.old-client", declarations: [], payloads: [])
            )
            XCTFail("The replaced provider generation must be stale")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .staleClient(fixture.providerDescriptor.moduleID)
            )
        }
    }

    func testClientCreationIsCapabilityGated() async throws {
        let registry = RuntimeOpaqueResourceRegistry()
        let generation = await registry.activateRuntime()
        let descriptor = makeDescriptor(
            id: "com.runescribe.test.unauthorized-resource",
            role: providerRole,
            capabilities: []
        )
        try await registry.activateModule(descriptor: descriptor, generation: 1)

        do {
            _ = try await registry.makeProviderClient(
                sourceModuleID: descriptor.moduleID,
                sourceModuleGeneration: 1,
                runtimeGeneration: generation,
                policy: makePolicy(),
                requiredCapability: publishCapability
            )
            XCTFail("A module without the publish capability must not receive a client")
        } catch {
            XCTAssertEqual(
                error as? RuneScribeRuntimeError,
                .capabilityDenied(
                    moduleID: descriptor.moduleID,
                    capability: publishCapability
                )
            )
        }
    }

    private struct Fixture {
        let registry: RuntimeOpaqueResourceRegistry
        let provider: RuntimeOpaqueResourceProviderClient
        let resolver: RuntimeOpaqueResourceResolverClient
        let providerDescriptor: ModuleDescriptor
        let readerDescriptor: ModuleDescriptor
    }

    private func makeFixture(
        budget: OpaqueResourceBudget = .themeScaffold,
        providerPolicyClass: ModulePolicyClass? = nil
    ) async throws -> Fixture {
        let registry = RuntimeOpaqueResourceRegistry(budget: budget)
        let runtimeGeneration = await registry.activateRuntime()
        let providerDescriptor = makeDescriptor(
            id: "com.runescribe.test.resource-provider",
            role: providerRole,
            capabilities: [publishCapability],
            policyClass: providerPolicyClass
        )
        let readerDescriptor = makeDescriptor(
            id: "com.runescribe.test.resource-reader",
            role: readerRole,
            capabilities: [resolveCapability]
        )
        try await registry.activateModule(descriptor: providerDescriptor, generation: 1)
        try await registry.activateModule(descriptor: readerDescriptor, generation: 1)
        let provider = try await registry.makeProviderClient(
            sourceModuleID: providerDescriptor.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration,
            policy: makePolicy(),
            requiredCapability: publishCapability
        )
        let resolver = try await registry.makeResolverClient(
            sourceModuleID: readerDescriptor.moduleID,
            sourceModuleGeneration: 1,
            runtimeGeneration: runtimeGeneration,
            policy: makePolicy(),
            requiredCapability: resolveCapability
        )
        return Fixture(
            registry: registry,
            provider: provider,
            resolver: resolver,
            providerDescriptor: providerDescriptor,
            readerDescriptor: readerDescriptor
        )
    }

    private func makeDescriptor(
        id: ModuleIdentifier,
        role: ModuleRole,
        capabilities: Set<CapabilityIdentifier>,
        policyClass: ModulePolicyClass? = nil
    ) -> ModuleDescriptor {
        ModuleDescriptor(
            moduleID: id,
            moduleVersion: try! SemanticVersion(major: 1, minor: 0, patch: 0),
            kind: .service,
            entryPoint: id.rawValue.replacingOccurrences(of: ".", with: "_"),
            role: role,
            policyClass: policyClass,
            requestedCapabilities: capabilities
        )
    }

    private func makePolicy() -> RuntimePolicy {
        RuntimePolicy(
            vocabulary: CapabilityVocabulary(
                knownCapabilities: [publishCapability, resolveCapability]
            ),
            capabilities: CapabilityPolicy(allowedRolesByCapability: [
                publishCapability: [providerRole],
                resolveCapability: [readerRole],
            ], additionalPolicyClassesByCapability: [
                publishCapability: [RuneScribePolicyClasses.themeProvider],
            ]),
            services: ServiceAccessPolicy(rules: [])
        )
    }

    private func makeDeclaration(
        id: OpaqueResourceID,
        role: String,
        mediaType: OpaqueResourceMediaType,
        data: Data,
        pixelSize: OpaqueResourcePixelSize? = nil
    ) -> OpaqueResourceDeclaration {
        OpaqueResourceDeclaration(
            resourceID: id,
            semanticRole: role,
            mediaType: mediaType,
            byteCount: data.count,
            sha256: Self.digest(data),
            pixelSize: pixelSize
        )
    }

    private func assertRegistration(
        _ client: RuntimeOpaqueResourceProviderClient,
        namespace: OpaqueResourceNamespaceID,
        declaration: OpaqueResourceDeclaration,
        data: Data,
        equals expected: RuntimeOpaqueResourceError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await client.register(
                .init(
                    namespace: namespace,
                    declarations: [declaration],
                    payloads: [.init(resourceID: declaration.resourceID, data: data)]
                )
            )
            XCTFail("Invalid resource registration unexpectedly succeeded", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? RuntimeOpaqueResourceError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isoContainer(majorBrand: String, mediaBox: String) -> Data {
        precondition(majorBrand.utf8.count == 4)
        precondition(mediaBox.utf8.count == 4)
        var data = Data([0, 0, 0, 16])
        data.append(Data("ftyp".utf8))
        data.append(Data(majorBrand.utf8))
        data.append(Data([0, 0, 0, 0]))
        data.append(Data([0, 0, 0, 8]))
        data.append(Data(mediaBox.utf8))
        return data
    }

    private static func heifContainer(dimensions: [(Int, Int)]) -> Data {
        var data = Data([0, 0, 0, 16])
        data.append(Data("ftyp".utf8))
        data.append(Data("heic".utf8))
        data.append(Data([0, 0, 0, 0]))
        for (width, height) in dimensions {
            data.append(Data([0, 0, 0, 20]))
            data.append(Data("ispe".utf8))
            data.append(Data([0, 0, 0, 0]))
            data.append(contentsOf: Self.bigEndianUInt32(width))
            data.append(contentsOf: Self.bigEndianUInt32(height))
        }
        return data
    }

    private static func bigEndianUInt32(_ value: Int) -> [UInt8] {
        let value = UInt32(value)
        return [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }

    private static let onePixelPNGBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

private actor DeferredResourceLoaderProbe {
    private let data: Data?
    private var resourceIDs: [OpaqueResourceID] = []

    init(data: Data?) {
        self.data = data
    }

    func load(_ resourceID: OpaqueResourceID) -> Data? {
        resourceIDs.append(resourceID)
        return data
    }

    func callCount() -> Int { resourceIDs.count }
    func loadedResourceIDs() -> [OpaqueResourceID] { resourceIDs }
}

private actor SuspendedDeferredResourceLoader {
    private let data: Data
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(data: Data) {
        self.data = data
    }

    func load(_ resourceID: OpaqueResourceID) async -> Data? {
        _ = resourceID
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return data
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
