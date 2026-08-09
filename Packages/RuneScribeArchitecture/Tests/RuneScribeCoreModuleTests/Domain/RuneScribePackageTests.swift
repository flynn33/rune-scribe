import CryptoKit
import Foundation
@testable import RuneScribeCoreModule
import XCTest

final class RuneScribePackageTests: XCTestCase {
    func testCipherPackageRoundTripHasFrozenHeaderAndIndependentVersions() throws {
        let cipher = Cipher.generated(label: "Container")
        let legacy = try CipherSharePayload(cipher: cipher).encoded()
        let package = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: legacy
                ),
                RuneScribePackageSection(type: 0x7000, data: Data("optional".utf8)),
            ]
        )

        let encoded = try package.encoded()
        XCTAssertEqual(encoded.prefix(8), RuneScribePackage.magic)
        XCTAssertEqual(encoded.readUInt16(at: 8), 1)
        XCTAssertEqual(encoded.readUInt16(at: 10), 64)
        XCTAssertEqual(encoded.readUInt16(at: 16), RuneScribePackageKind.cipherInvitation.rawValue)
        XCTAssertEqual(encoded.readUInt16(at: 18), UInt16(CipherSharePayload.version))
        XCTAssertEqual(encoded.readUInt16(at: 20), 2)
        XCTAssertEqual(encoded.readUInt32(at: 24), 32)
        XCTAssertEqual(
            Data(SHA256.hash(data: encoded.dropLast(32))),
            encoded.suffix(32)
        )

        let decoded = try RuneScribePackage(decoding: encoded)
        XCTAssertEqual(decoded, package)
        XCTAssertEqual(decoded.sections.last?.type, 0x7000, "unknown optional sections are retained")

        guard case .cipher(let routed, let font) = try FileRouter.decode(encoded) else {
            return XCTFail("Expected a routed cipher package")
        }
        XCTAssertNil(font)
        XCTAssertEqual(routed.keyMaterial, cipher.keyMaterial)
        XCTAssertEqual(routed.decorativeMapping, cipher.symbolPermutation)
    }

    func testMessagePackageRoutesWithoutChangingLegacyPayloadBytes() throws {
        let cipher = Cipher.generated(label: "Message")
        let envelope = try MessageCryptor().seal("hello", with: cipher)
        let legacy = try MessageSharePayload(
            senderName: "Sender",
            envelope: MessageEnvelope.wrap(envelope),
            embeddedCipher: nil
        ).encoded()
        let package = try RuneScribePackage(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: legacy
                )
            ]
        )

        guard case .message(let routed, let font) = try FileRouter.decode(package.encoded()) else {
            return XCTFail("Expected a routed message package")
        }
        XCTAssertNil(font)
        XCTAssertEqual(try routed.encoded(), legacy)
    }

    func testUnknownRequiredAndOversizedSectionsFailBeforeRouting() throws {
        XCTAssertThrowsError(
            try RuneScribePackage(
                kind: .cipherInvitation,
                payloadVersion: 3,
                sections: [
                    RuneScribePackageSection(
                        type: RuneScribePackageSectionType.corePayload.rawValue,
                        required: true,
                        data: Data([3])
                    ),
                    RuneScribePackageSection(type: 0x7000, required: true, data: Data())
                ]
            )
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .unknownRequiredSection(0x7000))
        }

        XCTAssertThrowsError(
            try RuneScribePackage(
                kind: .cipherInvitation,
                payloadVersion: 3,
                sections: [
                    RuneScribePackageSection(
                        type: RuneScribePackageSectionType.corePayload.rawValue,
                        required: true,
                        data: Data(repeating: 0, count: 1 * 1024 * 1024 + 1)
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? RuneScribePackageError,
                .sectionTooLarge(RuneScribePackageSectionType.corePayload.rawValue)
            )
        }
    }

    func testMalformedLengthsChecksumAndPartialMagicFailClosed() throws {
        let cipher = Cipher.generated(label: "Malformed")
        let package = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: 3,
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: try CipherSharePayload(cipher: cipher).encoded()
                )
            ]
        )
        let valid = try package.encoded()

        for count in 1..<RuneScribePackage.magic.count {
            let partial = RuneScribePackage.magic.prefix(count)
            XCTAssertThrowsError(try FileRouter.decode(Data(partial))) { error in
                XCTAssertEqual(error as? FileRouterError, .malformedContainer)
            }
        }

        var forgedLength = valid
        forgedLength.replaceSubrange(12..<16, with: Data([0, 0, 0, 1]))
        XCTAssertThrowsError(try RuneScribePackage(decoding: forgedLength)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .lengthMismatch)
        }

        var forgedBody = valid
        forgedBody[forgedBody.startIndex + 64] ^= 1
        XCTAssertThrowsError(try RuneScribePackage(decoding: forgedBody)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .badChecksum)
        }
    }

    func testBuilderRejectsWrongPayloadVersionAndMissingCore() {
        XCTAssertThrowsError(
            try RuneScribePackage(kind: .cipherInvitation, payloadVersion: 1, sections: [])
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .missingCorePayload)
        }

        XCTAssertThrowsError(
            try RuneScribePackage(
                kind: .encryptedMessage,
                payloadVersion: 3,
                sections: [
                    RuneScribePackageSection(
                        type: RuneScribePackageSectionType.corePayload.rawValue,
                        required: true,
                        data: Data([1])
                    )
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? RuneScribePackageError,
                .unsupportedPayloadVersion(
                    kind: RuneScribePackageKind.encryptedMessage.rawValue,
                    version: 3
                )
            )
        }
    }

    func testResourceTableRoundTripsWithExactHashAndValidatesInsidePackage() throws {
        let bytes = Data("font-resource".utf8)
        let resource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.runes",
            version: 7,
            mediaType: "font/otf",
            data: bytes
        )
        XCTAssertEqual(resource.sha256, Data(SHA256.hash(data: bytes)))

        let table = try RuneScribePackageResourceTable(resources: [resource])
        let encodedTable = try table.encoded()
        XCTAssertEqual(try RuneScribePackageResourceTable(decoding: encodedTable), table)

        let cipher = Cipher.generated(label: "Resources")
        let package = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: try CipherSharePayload(cipher: cipher).encoded()
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: encodedTable
                ),
            ]
        )
        XCTAssertEqual(try RuneScribePackage(decoding: package.encoded()), package)
    }

    func testResourceTableRejectsDuplicateOversizeAndCorruptHash() throws {
        let resource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.runes",
            version: 1,
            mediaType: "font/otf",
            data: Data("font".utf8)
        )
        XCTAssertThrowsError(
            try RuneScribePackageResourceTable(resources: [resource, resource])
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .duplicateResource)
        }
        XCTAssertThrowsError(
            try RuneScribePackageResource(
                kind: .legacyFont,
                id: "legacy.large",
                version: 1,
                mediaType: "font/otf",
                data: Data(repeating: 0, count: RuneScribePackageResource.maximumDataLength + 1)
            )
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .resourceTooLarge)
        }

        var corrupt = try RuneScribePackageResourceTable(resources: [resource]).encoded()
        corrupt[20] ^= 1 // first entry's SHA-256 starts after the table and entry prefixes
        XCTAssertThrowsError(try RuneScribePackageResourceTable(decoding: corrupt)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .resourceHashMismatch)
        }

        let cipher = Cipher.generated(label: "Corrupt resource")
        XCTAssertThrowsError(
            try RuneScribePackage(
                kind: .cipherInvitation,
                payloadVersion: UInt16(CipherSharePayload.version),
                sections: [
                    RuneScribePackageSection(
                        type: RuneScribePackageSectionType.corePayload.rawValue,
                        required: true,
                        data: try CipherSharePayload(cipher: cipher).encoded()
                    ),
                    RuneScribePackageSection(
                        type: RuneScribePackageSectionType.resourceTable.rawValue,
                        data: corrupt
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .resourceHashMismatch)
        }
    }

    func testResourceTableRejectsUnknownKindAndMoreThanEightEntries() throws {
        let resource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.0",
            version: 1,
            mediaType: "font/otf",
            data: Data([0])
        )
        var unknownKind = try RuneScribePackageResourceTable(resources: [resource]).encoded()
        unknownKind.replaceSubrange(4..<6, with: Data([0, 2]))
        XCTAssertThrowsError(try RuneScribePackageResourceTable(decoding: unknownKind)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .invalidResourceKind)
        }

        let resources = try (0...RuneScribePackageResourceTable.maximumResourceCount).map { index in
            try RuneScribePackageResource(
                kind: .legacyFont,
                id: "legacy.\(index)",
                version: 1,
                mediaType: "font/otf",
                data: Data([UInt8(index)])
            )
        }
        XCTAssertThrowsError(try RuneScribePackageResourceTable(resources: resources)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .tooManyResources)
        }
    }

    func testUpdateRequiredContainerErrorsSurviveMagicFirstRouting() throws {
        let cipher = Cipher.generated(label: "Update")
        let package = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: try CipherSharePayload(cipher: cipher).encoded()
                )
            ]
        )
        let valid = try package.encoded()

        var newerContainer = valid
        newerContainer.replaceSubrange(8..<10, with: Data([0, 2]))
        newerContainer.refreshPackageChecksum()
        XCTAssertThrowsError(try FileRouter.decode(newerContainer)) { error in
            XCTAssertEqual(error as? FileRouterError, .unsupportedContainerVersion(2))
        }

        var unknownKind = valid
        unknownKind.replaceSubrange(16..<18, with: Data([0x70, 0x00]))
        unknownKind.refreshPackageChecksum()
        XCTAssertThrowsError(try FileRouter.decode(unknownKind)) { error in
            XCTAssertEqual(error as? FileRouterError, .unsupportedPayloadKind(0x7000))
        }

        var newerPayload = valid
        newerPayload.replaceSubrange(18..<20, with: Data([0, 4]))
        newerPayload.refreshPackageChecksum()
        XCTAssertThrowsError(try FileRouter.decode(newerPayload)) { error in
            XCTAssertEqual(
                error as? FileRouterError,
                .unsupportedPayloadVersion(
                    kind: RuneScribePackageKind.cipherInvitation.rawValue,
                    version: 4
                )
            )
        }

        var unknownRequiredSection = valid
        unknownRequiredSection.replaceSubrange(32..<34, with: Data([0x70, 0x01]))
        unknownRequiredSection.refreshPackageChecksum()
        XCTAssertThrowsError(try FileRouter.decode(unknownRequiredSection)) { error in
            XCTAssertEqual(error as? FileRouterError, .unknownRequiredSection(0x7001))
        }

        var newerRequiredSection = valid
        newerRequiredSection.replaceSubrange(34..<36, with: Data([0, 2]))
        newerRequiredSection.refreshPackageChecksum()
        XCTAssertThrowsError(try FileRouter.decode(newerRequiredSection)) { error in
            XCTAssertEqual(
                error as? FileRouterError,
                .unsupportedRequiredSectionVersion(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    version: 2
                )
            )
        }
    }

    func testMatchingLegacyFontResourceRoutesForCipherAndMessagePackages() throws {
        let fontBytes = Data("font-resource".utf8)
        let fontRef = FontRef(
            id: "legacy.runes",
            version: 7,
            sha256: Data(SHA256.hash(data: fontBytes))
        )
        let cipher = Cipher(
            label: "Custom Font",
            origin: .generated,
            publicID: Data(1...8),
            keyMaterial: Data(repeating: 9, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: fontRef
        )
        let resource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: fontRef.id,
            version: UInt32(fontRef.version),
            mediaType: "font/otf",
            data: fontBytes
        )
        let resourceTable = try RuneScribePackageResourceTable(resources: [resource]).encoded()
        let cipherCore = try CipherSharePayload(cipher: cipher).encoded()
        let cipherPackage = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: cipherCore
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: resourceTable
                ),
            ]
        )

        guard case .cipher(let routedCipher, let routedCipherFont) = try FileRouter.decode(
            cipherPackage.encoded()
        ) else {
            return XCTFail("Expected a routed cipher package")
        }
        XCTAssertEqual(routedCipher.fontRef, fontRef)
        XCTAssertEqual(routedCipherFont, fontBytes)

        let messageCore = try MessageSharePayload(
            senderName: "Sender",
            envelope: Data([1]),
            embeddedCipher: CipherSharePayload(cipher: cipher)
        ).encoded()
        let messagePackage = try RuneScribePackage(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: messageCore
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: resourceTable
                ),
            ]
        )

        guard case .message(let routedMessage, let routedMessageFont) = try FileRouter.decode(
            messagePackage.encoded()
        ) else {
            return XCTFail("Expected a routed message package")
        }
        XCTAssertEqual(routedMessage.embeddedCipher?.fontRef, fontRef)
        XCTAssertEqual(routedMessageFont, fontBytes)
    }

    func testMissingOrMismatchedLegacyFontResourceFailsClosed() throws {
        let expectedBytes = Data("expected-font".utf8)
        let fontRef = FontRef(
            id: "legacy.runes",
            version: 1,
            sha256: Data(SHA256.hash(data: expectedBytes))
        )
        let cipher = Cipher(
            label: "Custom Font",
            origin: .generated,
            publicID: Data(1...8),
            keyMaterial: Data(repeating: 7, count: 32),
            decorativeMapping: Array(0..<32),
            fontRef: fontRef
        )
        let core = try CipherSharePayload(cipher: cipher).encoded()
        let missing = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: core
                )
            ]
        )

        XCTAssertThrowsError(try missing.legacyFontBytes(matching: fontRef)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .missingLegacyFontResource)
        }
        XCTAssertThrowsError(try FileRouter.decode(missing.encoded())) { error in
            XCTAssertEqual(error as? FileRouterError, .malformedContainer)
        }

        let unrelatedBytes = Data("different-font".utf8)
        let mismatchedResource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: fontRef.id,
            version: UInt32(fontRef.version),
            mediaType: "font/otf",
            data: unrelatedBytes
        )
        let mismatchedTable = try RuneScribePackageResourceTable(
            resources: [mismatchedResource]
        ).encoded()
        let mismatched = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: core
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.resourceTable.rawValue,
                    data: mismatchedTable
                ),
            ]
        )

        XCTAssertThrowsError(try mismatched.legacyFontBytes(matching: fontRef)) { error in
            XCTAssertEqual(
                error as? RuneScribePackageError,
                .legacyFontResourceReferenceMismatch
            )
        }
        XCTAssertThrowsError(try FileRouter.decode(mismatched.encoded())) { error in
            XCTAssertEqual(error as? FileRouterError, .malformedContainer)
        }
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        self[offset..<(offset + 2)].reduce(0) { ($0 << 8) | UInt16($1) }
    }

    func readUInt32(at offset: Int) -> UInt32 {
        self[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    mutating func refreshPackageChecksum() {
        let checksumStart = count - RuneScribePackage.checksumLength
        replaceSubrange(
            checksumStart..<count,
            with: Data(SHA256.hash(data: prefix(checksumStart)))
        )
    }
}
