import Foundation
import RuneScribeContracts
import XCTest

final class ContractSafetyTests: XCTestCase {
    func testStableServiceStorageAndWireIdentifiers() {
        XCTAssertEqual(RuneScribeServiceIDs.application.rawValue, "RuneScribeApplicationService")
        XCTAssertEqual(RuneScribeServiceIDs.inboundInput.rawValue, "RuneScribeInboundInputService")
        XCTAssertEqual(RuneScribeServiceIDs.secureValueStore.rawValue, "SecureValueStore")
        XCTAssertEqual(RuneScribeServiceIDs.protectedFileStore.rawValue, "ProtectedFileStore")
        XCTAssertEqual(RuneScribeServiceIDs.inboundFileReader.rawValue, "InboundFileReader")
        XCTAssertEqual(RuneScribeServiceIDs.shareArtifactStore.rawValue, "ShareArtifactStore")
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
        XCTAssertEqual(RuneScribeServiceIDs.all.count, 13)
        XCTAssertEqual(
            RuneScribeServiceKeys.application.identifier,
            RuneScribeServiceIDs.application
        )
        XCTAssertEqual(
            RuneScribeServiceKeys.inboundInput.identifier,
            RuneScribeServiceIDs.inboundInput
        )
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
        assertSendable(CipherSummary.self)
        assertSendable(ContactSummary.self)
        assertSendable(FontSummary.self)
        assertSendable(RuneScribeApplicationSnapshot.self)
        assertSendable(EncodeMessageCommand.self)
        assertSendable(DecodedMessageResult.self)
        assertSendable(ShareArtifactDTO.self)
        assertSendable(ScopedShareFile.self)
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
