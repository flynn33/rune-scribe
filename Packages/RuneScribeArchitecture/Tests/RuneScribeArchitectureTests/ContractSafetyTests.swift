import Foundation
import RuneScribeContracts
import XCTest

final class ContractSafetyTests: XCTestCase {
    func testStableServiceStorageAndWireIdentifiers() {
        XCTAssertEqual(RuneScribeServiceIDs.secureValueStore.rawValue, "SecureValueStore")
        XCTAssertEqual(RuneScribeServiceIDs.protectedFileStore.rawValue, "ProtectedFileStore")
        XCTAssertEqual(RuneScribeServiceIDs.inboundFileReader.rawValue, "InboundFileReader")
        XCTAssertEqual(RuneScribeServiceIDs.shareArtifactStore.rawValue, "ShareArtifactStore")
        XCTAssertEqual(
            RuneScribeServiceIDs.sharePresentation.rawValue,
            "SharePresentationService"
        )
        XCTAssertEqual(RuneScribeServiceIDs.applicationResourceLocator.rawValue, "ApplicationResourceLocator")
        XCTAssertEqual(RuneScribeServiceIDs.systemFontRegistrar.rawValue, "SystemFontRegistrar")
        XCTAssertEqual(RuneScribeServiceIDs.contactAccess.rawValue, "ContactAccessService")
        XCTAssertEqual(RuneScribeServiceIDs.clipboardRead.rawValue, "ClipboardService")
        XCTAssertEqual(
            RuneScribeServiceIDs.clipboardWrite.rawValue,
            "ClipboardWriteService"
        )
        XCTAssertEqual(RuneScribeServiceIDs.clock.rawValue, "ClockService")
        XCTAssertEqual(RuneScribeServiceIDs.uuid.rawValue, "UUIDService")
        XCTAssertEqual(RuneScribeServiceIDs.all.count, 12)
        XCTAssertEqual(
            RuneScribeServiceKeys.secureValueStore.identifier,
            RuneScribeServiceIDs.secureValueStore
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.protectedFileStore.identifier,
            RuneScribeServiceIDs.protectedFileStore
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.inboundFileReader.identifier,
            RuneScribeServiceIDs.inboundFileReader
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.shareArtifactStore.identifier,
            RuneScribeServiceIDs.shareArtifactStore
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.sharePresentation.identifier,
            RuneScribeServiceIDs.sharePresentation
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.applicationResourceLocator.identifier,
            RuneScribeServiceIDs.applicationResourceLocator
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.systemFontRegistrar.identifier,
            RuneScribeServiceIDs.systemFontRegistrar
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.contactAccess.identifier,
            RuneScribeServiceIDs.contactAccess
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.clipboardRead.identifier,
            RuneScribeServiceIDs.clipboardRead
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.clipboardWrite.identifier,
            RuneScribeServiceIDs.clipboardWrite
        )
        XCTAssertEqual(RuneScribeServiceKeys.clock.identifier, RuneScribeServiceIDs.clock)
        XCTAssertEqual(RuneScribeServiceKeys.uuid.identifier, RuneScribeServiceIDs.uuid)

        XCTAssertEqual(RuneScribeKeychain.service, "com.runescribe.keystore")
        XCTAssertEqual(
            RuneScribeKeychain.accounts,
            ["symmetricKey", "cipherLibrary", "appPin", "pinThrottle"]
        )
        XCTAssertEqual(ProtectedPath.contacts.rawValue, "RuneScribContacts/contacts.enc")
        XCTAssertEqual(ProtectedPath.fontsDirectory.rawValue, "RuneScribFonts")

        XCTAssertEqual(RuneScribeWireFormat.URLScheme, "runescribe")
        XCTAssertEqual(RuneScribeWireFormat.contentType, "com.runescribe.runescribe")
        XCTAssertEqual(RuneScribeWireFormat.fileExtension, "runescribe")
        XCTAssertEqual(RuneScribeWireFormat.cipherVersion, 3)
        XCTAssertEqual(RuneScribeWireFormat.messageVersion, 1)
        XCTAssertTrue(RuneScribeCapabilities.all.contains(RuneScribeCapabilities.clockRead))
        XCTAssertTrue(RuneScribeCapabilities.all.contains(RuneScribeCapabilities.uuidGenerate))
        XCTAssertTrue(
            RuneScribeCapabilities.all.contains(RuneScribeCapabilities.shareArtifactStorage)
        )
        XCTAssertTrue(
            RuneScribeCapabilities.all.contains(RuneScribeCapabilities.inboundFileRead)
        )
        XCTAssertTrue(
            RuneScribeCapabilities.all.contains(RuneScribeCapabilities.fileImportUI)
        )
    }

    func testUIModuleInboundFilePresentationDoesNotOwnNativeURLs() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceRoot = packageRoot.appendingPathComponent("Sources", isDirectory: true)
        let uiModuleRoot = sourceRoot.appendingPathComponent(
            "RuneScribeUIModule",
            isDirectory: true
        )
        let uiRuntimeImporter = sourceRoot
            .appendingPathComponent("RuneScribeUIRuntime", isDirectory: true)
            .appendingPathComponent("RuntimeInboundFileImporter.swift")
        let uiModuleSources = try FileManager.default.subpathsOfDirectory(
            atPath: uiModuleRoot.path
        )
        .filter { $0.hasSuffix(".swift") }
        .map { relativePath in
            try String(
                contentsOf: uiModuleRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }
        .joined(separator: "\n")

        XCTAssertFalse(uiModuleSources.contains(".fileImporter"))
        XCTAssertFalse(uiModuleSources.contains("InboundFileDTO("))
        XCTAssertFalse(uiModuleSources.contains("fileURL"))
        XCTAssertFalse(uiModuleSources.contains("Result<[URL]"))

        let runtimeSource = try String(
            contentsOf: uiRuntimeImporter,
            encoding: .utf8
        )
        XCTAssertTrue(runtimeSource.contains(".fileImporter"))
        XCTAssertTrue(runtimeSource.contains("@_spi(RuntimeFileImportHost)"))
    }

    func testResourceHandlesMatchShippingRootBundleLookups() {
        XCTAssertEqual(ApplicationResource.bundledRuneFont.name, "NotoSansRunic-Regular")
        XCTAssertEqual(ApplicationResource.bundledRuneFont.fileExtension, "ttf")
        XCTAssertNil(ApplicationResource.bundledRuneFont.subdirectory)
        XCTAssertEqual(ApplicationResource.splashVideo.name, "raven-forge-spp-splash")
        XCTAssertEqual(ApplicationResource.splashVideo.fileExtension, "mp4")
        XCTAssertNil(ApplicationResource.splashVideo.subdirectory)
        XCTAssertEqual(ApplicationResource.defaultMetalLibrary.name, "default")
        XCTAssertEqual(ApplicationResource.defaultMetalLibrary.fileExtension, "metallib")
        XCTAssertNil(ApplicationResource.defaultMetalLibrary.subdirectory)
    }

    func testProtectedPathRejectsTraversalAndBuildsValidatedFontPaths() throws {
        XCTAssertNil(ProtectedPath(rawValue: ""))
        XCTAssertNil(ProtectedPath(rawValue: "/RuneScribFonts/font.ttf"))
        XCTAssertNil(ProtectedPath(rawValue: "../contacts.enc"))
        XCTAssertNil(ProtectedPath(rawValue: "RuneScribFonts/../contacts.enc"))
        XCTAssertNil(ProtectedPath(rawValue: "RuneScribFonts\\font.ttf"))
        XCTAssertNil(ProtectedPath(rawValue: "RuneScribFonts//font.ttf"))

        let fontPath = try ProtectedPath.fontsDirectory.appending("0123456789abcdef.ttf")
        XCTAssertEqual(fontPath.rawValue, "RuneScribFonts/0123456789abcdef.ttf")
        XCTAssertThrowsError(try ProtectedPath.fontsDirectory.appending("../font.ttf"))

        let encoded = try JSONEncoder().encode(fontPath)
        XCTAssertEqual(try JSONDecoder().decode(ProtectedPath.self, from: encoded), fontPath)
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ProtectedPath.self,
                from: Data("\"../../escape\"".utf8)
            )
        )
    }

    func testApplicationAndInboundValuesAreSendable() {
        assertSendable(CipherID.self)
        assertSendable(ContactID.self)
        assertSendable(FontID.self)
        assertSendable(CodexID.self)
        assertSendable(ScriptID.self)
        assertSendable(ArtifactID.self)
        assertSendable(RelicID.self)
        assertSendable(SealID.self)
        assertSendable(FrameID.self)
        assertSendable(EffectID.self)
        assertSendable(AchievementID.self)
        assertSendable(RuleID.self)
        assertSendable(UnlockID.self)
        assertSendable(EventID.self)
        assertSendable(CorrelationID.self)
        assertSendable(CipherToken.self)
        assertSendable(MessageToken.self)
        assertSendable(PackageToken.self)
        assertSendable(RelationshipToken.self)
        assertSendable(PackageKindID.self)
        assertSendable(PackageVersionID.self)
        assertSendable(PackageTypeDescriptor.self)
        assertSendable(DomainEventEligibilityMetadata.self)
        assertSendable(DomainEventPayload.self)
        assertSendable(DomainEventEnvelope.self)
        assertSendable(EntitlementSourceDescriptor.self)
        assertSendable(EntitlementRequirementDescriptor.self)
        assertSendable(CipherSummary.self)
        assertSendable(ContactSummary.self)
        assertSendable(FontSummary.self)
        assertSendable(RuneScribeApplicationSnapshot.self)
        assertSendable(EncodeMessageCommand.self)
        assertSendable(DecodedMessageResult.self)
        assertSendable(ShareArtifactDTO.self)
        assertSendable(ShareArtifactID.self)
        assertSendable(CompleteShareArtifactCommand.self)
        assertSendable(RuneScribeInboundInput.self)
        assertSendable(ApplicationSnapshotChangedEvent.self)
        assertSendable(MessageStateChangedEvent.self)
    }

    func testClipboardReadAndWriteUseDistinctContractTypesAndServiceKeys() async throws {
        let reader: any ClipboardReading = ReadOnlyClipboardStub()
        let writer = WriteOnlyClipboardStub()
        let writerContract: any ClipboardWriting = writer

        let changeCount = await reader.changeCount()
        let readValue = await reader.string()
        XCTAssertEqual(changeCount, 7)
        XCTAssertEqual(readValue, "read-only")
        try await writerContract.setString("write-only")
        let writtenValue = await writer.value()
        XCTAssertEqual(writtenValue, "write-only")
        XCTAssertNotEqual(
            RuneScribeServiceKeys.clipboardRead.identifier,
            RuneScribeServiceKeys.clipboardWrite.identifier
        )
    }

    func testPendingImportAndSafeEventSerializationExcludeInboundContent() throws {
        let pending = PendingImportSummary(
            id: ImportID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            suggestedName: "Synthetic Cipher",
            source: .file,
            includesFont: true
        )
        let pendingJSON = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertFalse(pendingJSON.contains("fileURL"))
        XCTAssertFalse(pendingJSON.contains("payload"))

        let event = MessageStateChangedEvent(
            phase: .received,
            hasPendingMessage: true,
            failureCode: nil
        )
        let eventJSON = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        XCTAssertFalse(eventJSON.contains("plaintext"))
        XCTAssertFalse(eventJSON.contains("senderName"))
        XCTAssertFalse(eventJSON.contains("runes"))
    }

    func testSensitiveApplicationValuesCannotBeAccidentallySerialized() {
        XCTAssertFalse(isEncodable(InboundURLDTO.self))
        XCTAssertFalse(isDecodable(InboundURLDTO.self))
        XCTAssertFalse(isEncodable(InboundFileDTO.self))
        XCTAssertFalse(isDecodable(InboundFileDTO.self))
        XCTAssertFalse(isEncodable(RuneScribeInboundInput.self))
        XCTAssertFalse(isDecodable(RuneScribeInboundInput.self))
        XCTAssertFalse(isEncodable(SystemContactDTO.self))
        XCTAssertFalse(isDecodable(SystemContactDTO.self))
        XCTAssertFalse(isEncodable(ContactSummary.self))
        XCTAssertFalse(isDecodable(ContactSummary.self))
        XCTAssertFalse(isEncodable(ContactLibraryStateDTO.self))
        XCTAssertFalse(isDecodable(ContactLibraryStateDTO.self))
        XCTAssertFalse(isEncodable(CreateContactCommand.self))
        XCTAssertFalse(isDecodable(CreateContactCommand.self))
        XCTAssertFalse(isEncodable(UpdateContactCommand.self))
        XCTAssertFalse(isDecodable(UpdateContactCommand.self))
        XCTAssertFalse(isEncodable(ImportContactsCommand.self))
        XCTAssertFalse(isDecodable(ImportContactsCommand.self))
        XCTAssertFalse(isEncodable(ReceivedMessageDTO.self))
        XCTAssertFalse(isDecodable(ReceivedMessageDTO.self))
        XCTAssertFalse(isEncodable(EncodeMessageCommand.self))
        XCTAssertFalse(isDecodable(EncodeMessageCommand.self))
        XCTAssertFalse(isEncodable(DecodeMessageCommand.self))
        XCTAssertFalse(isDecodable(DecodeMessageCommand.self))
        XCTAssertFalse(isEncodable(DecodedMessageResult.self))
        XCTAssertFalse(isDecodable(DecodedMessageResult.self))
        XCTAssertFalse(isEncodable(PINInput.self))
        XCTAssertFalse(isDecodable(PINInput.self))
    }

    func testShareCompletionCarriesAttachmentAcknowledgementWithoutArtifactBytes() throws {
        let artifactID = ShareArtifactID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let command = CompleteShareArtifactCommand(
            artifactID: artifactID,
            outcome: .messageSent(requiredAttachmentAccepted: true)
        )
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(CompleteShareArtifactCommand.self, from: encoded)
        XCTAssertEqual(decoded, command)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("artifactData"))
    }

    func testRoadmapStringIdentifiersValidateSyntaxAndRoundTrip() throws {
        let codex = try XCTUnwrap(CodexID(rawValue: "codex.base"))
        let script = try XCTUnwrap(ScriptID(rawValue: "script.base-runes"))
        let artifact = try XCTUnwrap(ArtifactID(rawValue: "artifact.first-mark"))
        let relic = try XCTUnwrap(RelicID(rawValue: "relic.base-01"))
        let seal = try XCTUnwrap(SealID(rawValue: "seal.base-01"))
        let frame = try XCTUnwrap(FrameID(rawValue: "frame.base-01"))
        let effect = try XCTUnwrap(EffectID(rawValue: "effect.base-01"))
        let achievement = try XCTUnwrap(AchievementID(rawValue: "achievement.first-mark"))
        let rule = try XCTUnwrap(RuleID(rawValue: "rule.first-mark"))
        let unlock = try XCTUnwrap(UnlockID(rawValue: "unlock.codex-02"))
        let packageKind = try XCTUnwrap(PackageKindID(rawValue: "encrypted-message"))
        let packageVersion = try XCTUnwrap(PackageVersionID(rawValue: "1.0"))

        try assertCodableRoundTrip(codex)
        try assertCodableRoundTrip(script)
        try assertCodableRoundTrip(artifact)
        try assertCodableRoundTrip(relic)
        try assertCodableRoundTrip(seal)
        try assertCodableRoundTrip(frame)
        try assertCodableRoundTrip(effect)
        try assertCodableRoundTrip(achievement)
        try assertCodableRoundTrip(rule)
        try assertCodableRoundTrip(unlock)
        try assertCodableRoundTrip(packageKind)
        try assertCodableRoundTrip(packageVersion)
        try assertCodableRoundTrip(
            PackageTypeDescriptor(kind: packageKind, version: packageVersion)
        )

        XCTAssertNil(CodexID(rawValue: ""))
        XCTAssertNil(CodexID(rawValue: "Codex.Base"))
        XCTAssertNil(CodexID(rawValue: "codex_base"))
        XCTAssertNil(CodexID(rawValue: ".codex"))
        XCTAssertNil(CodexID(rawValue: "codex-"))
        XCTAssertNil(CodexID(rawValue: "codex..base"))
        XCTAssertNil(CodexID(rawValue: "codex.-base"))
        XCTAssertNil(CodexID(rawValue: "codex/base"))
        XCTAssertNil(CodexID(rawValue: String(repeating: "a", count: 97)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(CodexID.self, from: Data("\"Codex.Base\"".utf8))
        )
    }

    func testRoadmapEventAndCorrelationIdentifiersAreUUIDBackedAndCodable() throws {
        let eventID = EventID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        )
        let correlationID = CorrelationID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        )

        try assertCodableRoundTrip(eventID)
        try assertCodableRoundTrip(correlationID)
    }

    func testPrivacySafeTokensAreOpaqueBoundedAndCodable() throws {
        let cipher = try XCTUnwrap(
            CipherToken(rawValue: String(repeating: "a", count: 64))
        )
        let message = try XCTUnwrap(
            MessageToken(rawValue: String(repeating: "b", count: 64))
        )
        let package = try XCTUnwrap(
            PackageToken(rawValue: String(repeating: "d", count: 64))
        )
        let relationship = try XCTUnwrap(
            RelationshipToken(rawValue: "01234567-89abcdef-01234567-89abcdef")
        )

        try assertCodableRoundTrip(cipher)
        try assertCodableRoundTrip(message)
        try assertCodableRoundTrip(package)
        try assertCodableRoundTrip(relationship)

        XCTAssertNil(RelationshipToken(rawValue: "alice"))
        XCTAssertNil(RelationshipToken(rawValue: "alice@example.com"))
        XCTAssertNil(RelationshipToken(rawValue: "0123456789ABCDEF"))
        XCTAssertNil(RelationshipToken(rawValue: "01234567--89abcdef"))
        XCTAssertNil(RelationshipToken(rawValue: String(repeating: "a", count: 129)))
    }

    func testDomainEventEnvelopeIsVersionedBoundedAndPrivacySafe() throws {
        let cipherToken = try XCTUnwrap(
            CipherToken(rawValue: String(repeating: "c", count: 64))
        )
        let eligibility = DomainEventEligibilityMetadata(
            state: .eligible,
            reason: try XCTUnwrap(EligibilityReasonID(rawValue: "operation.committed"))
        )
        let codexID = try XCTUnwrap(CodexID(rawValue: "codex.base"))
        let artifactID = try XCTUnwrap(ArtifactID(rawValue: "artifact.base.first-mark"))
        let payload = try DomainEventPayload(
            cipherToken: cipherToken,
            origin: .generated,
            routeClass: .shareSheet,
            codexIDs: [codexID],
            artifactIDs: [artifactID],
            keyIncluded: true,
            linkedRelationship: false
        )
        let envelope = try makeDomainEventEnvelope(
            eligibility: eligibility,
            payload: payload
        )

        try assertCodableRoundTrip(envelope)
        let encoded = try JSONEncoder().encode(envelope)
        let encodedText = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(encodedText.contains("plaintext"))
        XCTAssertFalse(encodedText.contains("keyMaterial"))
        XCTAssertFalse(encodedText.contains("senderName"))
        XCTAssertFalse(encodedText.contains("contactName"))
        XCTAssertFalse(encodedText.contains("packageBytes"))

        XCTAssertThrowsError(try makeDomainEventEnvelope(schemaVersion: 0))
        XCTAssertThrowsError(
            try makeDomainEventEnvelope(eventType: EventIdentifier(rawValue: "Cipher.Created"))
        )
        XCTAssertThrowsError(
            try makeDomainEventEnvelope(
                sourceModuleID: ModuleIdentifier(rawValue: "com.runescribe.module.Core")
            )
        )
        XCTAssertThrowsError(
            try makeDomainEventEnvelope(
                occurredAt: Date(timeIntervalSinceReferenceDate: .infinity)
            )
        )
        XCTAssertThrowsError(
            try DomainEventPayload(
                codexIDs: Array(
                    repeating: codexID,
                    count: DomainEventPayload.maximumCodexIDs + 1
                )
            )
        )
        XCTAssertThrowsError(try DomainEventPayload(codexIDs: [codexID, codexID]))

        var invalidObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        invalidObject["schemaVersion"] = 0
        let invalidEncoded = try JSONSerialization.data(withJSONObject: invalidObject)
        XCTAssertThrowsError(try JSONDecoder().decode(DomainEventEnvelope.self, from: invalidEncoded))

        invalidObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        invalidObject.removeValue(forKey: "eligibility")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DomainEventEnvelope.self,
                from: JSONSerialization.data(withJSONObject: invalidObject)
            )
        )

        invalidObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var forgedPayload = try XCTUnwrap(invalidObject["payload"] as? [String: Any])
        forgedPayload["cipherToken"] = "5551234567"
        invalidObject["payload"] = forgedPayload
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DomainEventEnvelope.self,
                from: JSONSerialization.data(withJSONObject: invalidObject)
            )
        )
    }

    func testEntitlementDescriptorsModelNeutralSourcesAndValidateComposition() throws {
        let earnedReference = try XCTUnwrap(
            EntitlementSourceReferenceID(rawValue: "progression.codex-02")
        )
        let debugReference = try XCTUnwrap(
            EntitlementSourceReferenceID(rawValue: "debug.codex-02")
        )
        let purchaseReference = try XCTUnwrap(
            EntitlementSourceReferenceID(rawValue: "purchase.codex-02")
        )
        let sources: [EntitlementSourceDescriptor] = [
            .included,
            .earned(earnedReference),
            .debug(debugReference),
            .futurePurchase(purchaseReference),
        ]
        let requirement = try EntitlementRequirementDescriptor(
            requirementID: XCTUnwrap(UnlockID(rawValue: "unlock.codex-02")),
            match: .any,
            sources: sources
        )

        try assertCodableRoundTrip(requirement)
        XCTAssertEqual(requirement.sources.map(\.kind), EntitlementSourceKind.allCases)
        XCTAssertNil(EntitlementSourceDescriptor.included.referenceID)

        XCTAssertThrowsError(
            try EntitlementSourceDescriptor(
                kind: .included,
                referenceID: earnedReference
            )
        )
        XCTAssertThrowsError(try EntitlementSourceDescriptor(kind: .earned))
        XCTAssertThrowsError(
            try EntitlementRequirementDescriptor(
                requirementID: XCTUnwrap(UnlockID(rawValue: "unlock.empty")),
                sources: []
            )
        )
        XCTAssertThrowsError(
            try EntitlementRequirementDescriptor(
                requirementID: XCTUnwrap(UnlockID(rawValue: "unlock.duplicate")),
                sources: [.included, .included]
            )
        )
        XCTAssertThrowsError(
            try EntitlementRequirementDescriptor(
                requirementID: XCTUnwrap(UnlockID(rawValue: "unlock.too-many")),
                sources: (0 ... EntitlementRequirementDescriptor.maximumSourceCount).map {
                    .earned(
                        EntitlementSourceReferenceID(rawValue: "progression.source-\($0)")!
                    )
                }
            )
        )

        let invalidSource = Data("{\"kind\":\"included\",\"referenceID\":\"debug.invalid\"}".utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(EntitlementSourceDescriptor.self, from: invalidSource)
        )
    }

    func testRoadmapContractsDoNotReferenceSensitiveApplicationDTOs() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot
            .appendingPathComponent("Sources/RuneScribeContracts/RoadmapContracts.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertFalse(source.contains("CipherSummary"))
        XCTAssertFalse(source.contains("ContactSummary"))
        XCTAssertFalse(source.contains("ReceivedMessageDTO"))
        XCTAssertFalse(source.contains("PINInput"))
        XCTAssertFalse(source.contains("MessageEnvelope"))
        XCTAssertFalse(source.contains("SymmetricKey"))
        XCTAssertFalse(source.contains("payload: Data"))
        XCTAssertFalse(source.contains("[String: Any]"))
    }

    func testContractsSourceUsesOnlyFoundationAndApplicationSurfaceNamesNoKeyType() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contractsDirectory = packageRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("RuneScribeContracts", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: contractsDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let imports = source.split(separator: "\n").compactMap { line -> String? in
                let words = line.split(whereSeparator: \Character.isWhitespace)
                guard words.first == "import", words.count == 2 else { return nil }
                return String(words[1])
            }
            XCTAssertEqual(Set(imports).subtracting(["Foundation"]), [])
        }

        let applicationSource = try String(
            contentsOf: contractsDirectory.appendingPathComponent("ApplicationContracts.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(applicationSource.contains("SymmetricKey"))
        XCTAssertFalse(applicationSource.contains("keyMaterial"))
        XCTAssertFalse(applicationSource.contains("PINInput: Codable"))
        XCTAssertFalse(applicationSource.contains("ReceivedMessageDTO: Codable"))
        XCTAssertFalse(applicationSource.contains("EncodeMessageCommand: Codable"))
        XCTAssertFalse(applicationSource.contains("DecodeMessageCommand: Codable"))
        XCTAssertFalse(applicationSource.contains("DecodedMessageResult: Codable"))
        XCTAssertFalse(applicationSource.contains("ContactSummary: Codable"))
        XCTAssertFalse(applicationSource.contains("ContactLibraryStateDTO: Codable"))
        XCTAssertFalse(applicationSource.contains("CreateContactCommand: Codable"))
        XCTAssertFalse(applicationSource.contains("UpdateContactCommand: Codable"))
        XCTAssertFalse(applicationSource.contains("ImportContactsCommand: Codable"))

        let inboundSource = try String(
            contentsOf: contractsDirectory.appendingPathComponent("InboundInputs.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(inboundSource.contains("InboundURLDTO: Codable"))
        XCTAssertFalse(inboundSource.contains("InboundFileDTO: Codable"))
        XCTAssertFalse(inboundSource.contains("RuneScribeInboundInput: Codable"))

        let platformSource = try String(
            contentsOf: contractsDirectory.appendingPathComponent("PlatformContracts.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(platformSource.contains("SystemContactDTO: Codable"))
    }

    private func assertSendable<Value: Sendable>(_: Value.Type) {}

    private func assertCodableRoundTrip<Value: Codable & Equatable>(
        _ value: Value,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(Value.self, from: encoded)
        XCTAssertEqual(decoded, value, file: file, line: line)
    }

    private func makeDomainEventEnvelope(
        schemaVersion: UInt16 = 1,
        eventType: EventIdentifier = EventIdentifier(rawValue: "cipher.created"),
        sourceModuleID: ModuleIdentifier = ModuleIdentifier(
            rawValue: "com.runescribe.module.core"
        ),
        occurredAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        eligibility: DomainEventEligibilityMetadata? = nil,
        payload: DomainEventPayload? = nil
    ) throws -> DomainEventEnvelope {
        let resolvedEligibility = eligibility ?? DomainEventEligibilityMetadata(
            state: .informational,
            reason: EligibilityReasonID(rawValue: "operation.not-evaluated")!
        )
        return try DomainEventEnvelope(
            schemaVersion: schemaVersion,
            eventID: EventID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
            ),
            correlationID: CorrelationID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
            ),
            eventType: eventType,
            sourceModuleID: sourceModuleID,
            occurredAt: occurredAt,
            eligibility: resolvedEligibility,
            payload: try payload ?? DomainEventPayload()
        )
    }

    private func isEncodable(_ type: Any.Type) -> Bool {
        type is any Encodable.Type
    }

    private func isDecodable(_ type: Any.Type) -> Bool {
        type is any Decodable.Type
    }
}

private struct ReadOnlyClipboardStub: ClipboardReading {
    func changeCount() async -> Int { 7 }

    func string() async -> String? { "read-only" }
}

private actor WriteOnlyClipboardStub: ClipboardWriting {
    private var storedValue: String?

    func setString(_ value: String) async throws {
        storedValue = value
    }

    func value() -> String? {
        storedValue
    }
}
