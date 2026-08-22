import CryptoKit
import Foundation
import RuneScribeContracts
@testable import RuneScribeCoreModule
import XCTest

final class DestinationCompatibilityMatrixTests: XCTestCase {
    func testExecutableOldNewAndUpdateRequiredMatrixAcrossDestinations() throws {
        let fixtures = try makeFixtures()
        let expectedRowIDs: Set<String> = [
            "container-cipher-themed-v1",
            "container-cipher-v1",
            "container-message-themed-v1",
            "container-message-v1",
            "imported-font-available",
            "imported-font-incompatible",
            "imported-font-mismatch",
            "imported-font-missing",
            "known-payload-unavailable-presentation",
            "legacy-cipher-v3",
            "legacy-message-v1",
            "newer-container",
            "newer-payload",
            "newer-required-section",
            "unknown-optional-section",
            "unknown-required",
        ]
        XCTAssertEqual(fixtures.count, 16)
        XCTAssertEqual(Set(fixtures.map(\.id)), expectedRowIDs)
        var executedRows: [String] = []

        for fixture in fixtures {
            let rowID = fixture.id
            executedRows.append(rowID)
            XCTAssertEqual(
                priorReaderOutcome(for: fixture.data),
                fixture.expectedPriorReader,
                "prior-reader.\(rowID)"
            )
            do {
                let routed = try FileRouter.decode(fixture.data)
                switch (fixture.expected, routed) {
                case let (
                    .cipher(expectedPayload, expectedFont),
                    .cipher(payload, fontBytes)
                ):
                    XCTAssertEqual(payload, expectedPayload, rowID)
                    XCTAssertEqual(fontBytes, expectedFont, rowID)
                case let (
                    .message(expectedPayload, expectedFont),
                    .message(payload, fontBytes)
                ):
                    XCTAssertEqual(payload, expectedPayload, rowID)
                    XCTAssertEqual(fontBytes, expectedFont, rowID)
                case let (
                    .themedCipher(
                        expectedPayload,
                        expectedFont,
                        expectedSelection,
                        expectedCompatibility
                    ),
                    .themedCipher(payload, fontBytes, presentation)
                ):
                    XCTAssertEqual(payload, expectedPayload, rowID)
                    XCTAssertEqual(fontBytes, expectedFont, rowID)
                    XCTAssertEqual(
                        presentation.metadata?.selection,
                        expectedSelection,
                        rowID
                    )
                    XCTAssertEqual(
                        presentation.metadata?.compatibility,
                        expectedCompatibility,
                        rowID
                    )
                case let (
                    .themedMessage(
                        expectedPayload,
                        expectedFont,
                        expectedSelection,
                        expectedCompatibility
                    ),
                    .themedMessage(payload, fontBytes, presentation)
                ):
                    XCTAssertEqual(payload, expectedPayload, rowID)
                    XCTAssertEqual(fontBytes, expectedFont, rowID)
                    XCTAssertEqual(
                        presentation.metadata?.selection,
                        expectedSelection,
                        rowID
                    )
                    XCTAssertEqual(
                        presentation.metadata?.compatibility,
                        expectedCompatibility,
                        rowID
                    )
                default:
                    XCTFail("Unexpected successful route for \(rowID)")
                }
            } catch let error as FileRouterError {
                guard case .failure(let expected) = fixture.expected else {
                    return XCTFail("Unexpected failure for \(rowID): \(error)")
                }
                XCTAssertEqual(error, expected, rowID)
            }
        }

        XCTAssertEqual(executedRows.count, fixtures.count)
        XCTAssertEqual(Set(executedRows).count, executedRows.count)
    }

    private func priorReaderOutcome(for data: Data) -> PriorReaderOutcome {
        guard let version = data.first else { return .rejected }
        switch version {
        case UInt8(RuneScribeWireFormat.cipherVersion):
            return (try? CipherSharePayload.decodeFile(data)) == nil
                ? .rejected
                : .legacyCipher
        case UInt8(RuneScribeWireFormat.messageVersion):
            return (try? MessageSharePayload.decodeFile(data)) == nil
                ? .rejected
                : .legacyMessage
        default:
            return RuneScribePackage.hasMagic(data) ? .updateRequired : .rejected
        }
    }

    private func makeFixtures() throws -> [Fixture] {
        let cipher = Cipher.generated(label: "Compatibility")
        let cipherSharePayload = CipherSharePayload(cipher: cipher)
        let cipherPayload = try cipherSharePayload.encoded()
        let messageSharePayload = MessageSharePayload(
            senderName: "Compatibility",
            envelope: Data([1, 2, 3]),
            embeddedCipher: nil
        )
        let messagePayload = try messageSharePayload.encoded()

        let currentCipher = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: cipherPayload
                )
            ]
        ).encoded()
        let currentMessage = try RuneScribePackage(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: messagePayload
                )
            ]
        ).encoded()
        let themedSelection = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.moonleaf")!,
            scriptID: ScriptID(rawValue: "script.moonleaf")!,
            relicID: ArtifactID(rawValue: "relic.moonleaf.tablet")!
        )
        let themedMessage = try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: messagePayload,
            presentation: SharePresentationSectionBundle(
                metadata: SharePresentationMetadata(
                    selection: themedSelection,
                    compatibility: .norseInteractiveFallback
                ),
                safePreviewData: nil,
                signedProvenance: nil
            )
        ).encoded()
        let themedCipher = try RuneScribePackage.themed(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            corePayload: cipherPayload,
            presentation: SharePresentationSectionBundle(
                metadata: SharePresentationMetadata(
                    selection: themedSelection,
                    compatibility: .norseInteractiveFallback
                ),
                safePreviewData: nil,
                signedProvenance: nil
            )
        ).encoded()
        let unavailableSelection = try SharePresentationSelection(
            codexID: CodexID(rawValue: "codex.future")!,
            scriptID: ScriptID(rawValue: "script.future")!,
            relicID: ArtifactID(rawValue: "relic.future.tablet")!
        )
        let unavailablePresentation = try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: messagePayload,
            presentation: SharePresentationSectionBundle(
                metadata: SharePresentationMetadata(
                    selection: unavailableSelection,
                    compatibility: .norseInteractiveFallback
                ),
                safePreviewData: nil,
                signedProvenance: nil
            )
        ).encoded()
        let unknownOptional = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: cipherPayload
                ),
                RuneScribePackageSection(type: 0x7000, data: Data("ignored".utf8)),
            ]
        ).encoded()

        let importedBytes = Data("validated-imported-font".utf8)
        let importedReference = FontRef(
            id: "legacy.compat",
            version: 1,
            sha256: Data(SHA256.hash(data: importedBytes))
        )
        let importedCipher = Cipher(
            label: "Imported font",
            origin: .imported,
            publicID: Data(1...8),
            keyMaterial: Data(repeating: 9, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: importedReference
        )
        let importedSharePayload = CipherSharePayload(cipher: importedCipher)
        let importedCore = try importedSharePayload.encoded()
        let importedResource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: importedReference.id,
            version: UInt32(importedReference.version),
            mediaType: "font/otf",
            data: importedBytes
        )
        let importedTable = try RuneScribePackageResourceTable(
            resources: [importedResource]
        ).encoded()
        let importedAvailable = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: importedCore
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: importedTable
                ),
            ]
        ).encoded()
        let importedMissing = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: importedCore
                )
            ]
        ).encoded()
        let wrongResource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: importedReference.id,
            version: UInt32(importedReference.version),
            mediaType: "font/otf",
            data: Data("wrong-font".utf8)
        )
        let wrongTable = try RuneScribePackageResourceTable(resources: [wrongResource]).encoded()
        let importedCorrupt = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: importedCore
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: wrongTable
                ),
            ]
        ).encoded()
        let incompatibleBytes = Data("structurally-valid-but-unregisterable-font".utf8)
        let incompatibleReference = FontRef(
            id: "legacy.badfont",
            version: 1,
            sha256: Data(SHA256.hash(data: incompatibleBytes))
        )
        let incompatibleCipher = Cipher(
            label: "Incompatible font",
            origin: .imported,
            publicID: Data(9...16),
            keyMaterial: Data(repeating: 7, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: incompatibleReference
        )
        let incompatibleSharePayload = CipherSharePayload(cipher: incompatibleCipher)
        let incompatibleCore = try incompatibleSharePayload.encoded()
        let incompatibleResource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: incompatibleReference.id,
            version: UInt32(incompatibleReference.version),
            mediaType: "font/ttf",
            data: incompatibleBytes
        )
        let incompatibleTable = try RuneScribePackageResourceTable(
            resources: [incompatibleResource]
        ).encoded()
        let importedIncompatible = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: incompatibleCore
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: incompatibleTable
                ),
            ]
        ).encoded()

        var newerContainer = currentCipher
        newerContainer.replaceSubrange(8..<10, with: Data([0, 2]))
        newerContainer.refreshMatrixChecksum()
        var newerPayload = currentCipher
        newerPayload.replaceSubrange(18..<20, with: Data([0, 4]))
        newerPayload.refreshMatrixChecksum()
        var unknownRequired = currentCipher
        unknownRequired.replaceSubrange(32..<34, with: Data([0x70, 0x01]))
        unknownRequired.refreshMatrixChecksum()
        var newerRequiredSection = currentCipher
        newerRequiredSection.replaceSubrange(34..<36, with: Data([0, 2]))
        newerRequiredSection.refreshMatrixChecksum()

        return [
            Fixture(id: "legacy-cipher-v3", data: cipherPayload, expected: .cipher(cipherSharePayload, nil), expectedPriorReader: .legacyCipher),
            Fixture(id: "legacy-message-v1", data: messagePayload, expected: .message(messageSharePayload, nil), expectedPriorReader: .legacyMessage),
            Fixture(id: "container-cipher-v1", data: currentCipher, expected: .cipher(cipherSharePayload, nil), expectedPriorReader: .updateRequired),
            Fixture(id: "container-message-v1", data: currentMessage, expected: .message(messageSharePayload, nil), expectedPriorReader: .updateRequired),
            Fixture(
                id: "container-cipher-themed-v1",
                data: themedCipher,
                expected: .themedCipher(
                    cipherSharePayload,
                    nil,
                    themedSelection,
                    .norseInteractiveFallback
                ),
                expectedPriorReader: .updateRequired
            ),
            Fixture(
                id: "container-message-themed-v1",
                data: themedMessage,
                expected: .themedMessage(
                    messageSharePayload,
                    nil,
                    themedSelection,
                    .norseInteractiveFallback
                ),
                expectedPriorReader: .updateRequired
            ),
            Fixture(
                id: "known-payload-unavailable-presentation",
                data: unavailablePresentation,
                expected: .themedMessage(
                    messageSharePayload,
                    nil,
                    unavailableSelection,
                    .norseInteractiveFallback
                ),
                expectedPriorReader: .updateRequired
            ),
            Fixture(id: "unknown-optional-section", data: unknownOptional, expected: .cipher(cipherSharePayload, nil), expectedPriorReader: .updateRequired),
            Fixture(id: "imported-font-available", data: importedAvailable, expected: .cipher(importedSharePayload, importedBytes), expectedPriorReader: .updateRequired),
            Fixture(id: "imported-font-missing", data: importedMissing, expected: .failure(.malformedContainer), expectedPriorReader: .updateRequired),
            Fixture(id: "imported-font-mismatch", data: importedCorrupt, expected: .failure(.malformedContainer), expectedPriorReader: .updateRequired),
            Fixture(id: "imported-font-incompatible", data: importedIncompatible, expected: .cipher(incompatibleSharePayload, incompatibleBytes), expectedPriorReader: .updateRequired),
            Fixture(id: "newer-container", data: newerContainer, expected: .failure(.unsupportedContainerVersion(2)), expectedPriorReader: .updateRequired),
            Fixture(
                id: "newer-payload",
                data: newerPayload,
                expected: .failure(.unsupportedPayloadVersion(
                    kind: RuneScribePackageKind.cipherInvitation.rawValue,
                    version: 4
                )),
                expectedPriorReader: .updateRequired
            ),
            Fixture(id: "unknown-required", data: unknownRequired, expected: .failure(.unknownRequiredSection(0x7001)), expectedPriorReader: .updateRequired),
            Fixture(
                id: "newer-required-section",
                data: newerRequiredSection,
                expected: .failure(.unsupportedRequiredSectionVersion(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    version: 2
                )),
                expectedPriorReader: .updateRequired
            ),
        ]
    }
}

private extension DestinationCompatibilityMatrixTests {
    enum PriorReaderOutcome: Equatable {
        case legacyCipher
        case legacyMessage
        case updateRequired
        case rejected
    }

    enum Expected {
        case cipher(CipherSharePayload, Data?)
        case message(MessageSharePayload, Data?)
        case themedCipher(
            CipherSharePayload,
            Data?,
            SharePresentationSelection,
            SharePresentationCompatibilityFlags
        )
        case themedMessage(
            MessageSharePayload,
            Data?,
            SharePresentationSelection,
            SharePresentationCompatibilityFlags
        )
        case failure(FileRouterError)
    }

    struct Fixture {
        let id: String
        let data: Data
        let expected: Expected
        let expectedPriorReader: PriorReaderOutcome
    }
}

private extension Data {
    mutating func refreshMatrixChecksum() {
        let checksumStart = count - RuneScribePackage.checksumLength
        replaceSubrange(
            checksumStart..<count,
            with: Data(SHA256.hash(data: prefix(checksumStart)))
        )
    }
}
