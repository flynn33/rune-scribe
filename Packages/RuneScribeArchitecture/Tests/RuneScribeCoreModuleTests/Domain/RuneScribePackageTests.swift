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

    func testFrozenBoundsRejectBeforeVariablePayloadAllocation() throws {
        var oversized = Data(
            repeating: 0,
            count: RuneScribePackage.maximumTotalLength + 1
        )
        oversized.replaceSubrange(0..<RuneScribePackage.magic.count, with: RuneScribePackage.magic)
        var oversizedEvents: [RuneScribePackageDecodeAllocation] = []
        XCTAssertThrowsError(try RuneScribePackage(
            decoding: oversized,
            allocationObserver: { oversizedEvents.append($0) }
        )) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .packageTooLarge)
        }
        XCTAssertTrue(oversizedEvents.isEmpty)

        let cipher = Cipher.generated(label: "Bounded")
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
        var forgedSectionLength = try package.encoded()
        forgedSectionLength.replaceUInt32(
            at: RuneScribePackage.fixedHeaderLength + 12,
            with: UInt32(RuneScribePackage.maximumTotalLength)
        )
        forgedSectionLength.refreshPackageChecksum()
        var sectionEvents: [RuneScribePackageDecodeAllocation] = []
        XCTAssertThrowsError(try RuneScribePackage(
            decoding: forgedSectionLength,
            allocationObserver: { sectionEvents.append($0) }
        )) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .nonContiguousSections)
        }
        XCTAssertFalse(sectionEvents.contains { event in
            if case .sectionPayload = event { return true }
            return false
        })

        let resource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.font",
            version: 1,
            mediaType: "font/otf",
            data: Data("font".utf8)
        )
        var forgedResourceLength = try RuneScribePackageResourceTable(
            resources: [resource]
        ).encoded()
        forgedResourceLength.replaceUInt32(
            at: 16,
            with: UInt32(RuneScribePackageResource.maximumDataLength + 1)
        )
        var resourceEvents: [RuneScribePackageDecodeAllocation] = []
        XCTAssertThrowsError(try RuneScribePackageResourceTable(
            decoding: forgedResourceLength,
            allocationObserver: { resourceEvents.append($0) }
        )) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .invalidResourceTable)
        }
        XCTAssertFalse(resourceEvents.contains { event in
            switch event {
            case .resourceMetadata, .resourcePayload: true
            default: false
            }
        })
    }

    func testLateInvalidDirectoryRecordsEmitNoAllocationEvents() throws {
        let cipher = Cipher.generated(label: "Late directory")
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
                    type: RuneScribePackageSectionType.safePreview.rawValue,
                    data: Data(repeating: 0xA5, count: 65 * 1024)
                ),
            ]
        )
        let valid = try package.encoded()
        let lateRecord = RuneScribePackage.fixedHeaderLength
            + RuneScribePackage.directoryRecordLength

        var invalidReserved = valid
        invalidReserved.replaceUInt16(at: lateRecord + 6, with: 1)
        invalidReserved.refreshPackageChecksum()
        assertPackagePreflightRejects(invalidReserved, as: .invalidDirectory)

        var nonCanonical = valid
        nonCanonical.replaceUInt16(at: lateRecord, with: 0)
        nonCanonical.refreshPackageChecksum()
        assertPackagePreflightRejects(nonCanonical, as: .nonCanonicalSectionOrder)

        var oversizedForMutatedType = valid
        oversizedForMutatedType.replaceUInt16(
            at: lateRecord,
            with: RuneScribePackageSectionType.presentationMetadata.rawValue
        )
        oversizedForMutatedType.refreshPackageChecksum()
        assertPackagePreflightRejects(
            oversizedForMutatedType,
            as: .sectionTooLarge(RuneScribePackageSectionType.presentationMetadata.rawValue)
        )

        var nonContiguous = valid
        let originalOffset = nonContiguous.readUInt32(at: lateRecord + 8)
        nonContiguous.replaceUInt32(at: lateRecord + 8, with: originalOffset + 1)
        nonContiguous.refreshPackageChecksum()
        assertPackagePreflightRejects(nonContiguous, as: .nonContiguousSections)
    }

    func testLateInvalidResourceRecordsEmitNoAllocationEvents() throws {
        let first = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.a",
            version: 1,
            mediaType: "font/otf",
            data: Data("first-font".utf8)
        )
        let second = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.b",
            version: 1,
            mediaType: "font/otf",
            data: Data("second-font".utf8)
        )
        let valid = try RuneScribePackageResourceTable(resources: [first, second]).encoded()
        let lateRecord = 4 + 48
            + first.id.utf8.count
            + first.mediaType.utf8.count
            + first.data.count

        var invalidFlags = valid
        invalidFlags.replaceUInt16(at: lateRecord + 2, with: 1)
        assertResourcePreflightRejects(invalidFlags, as: .invalidResourceTable)

        var oversized = valid
        oversized.replaceUInt32(
            at: lateRecord + 12,
            with: UInt32(RuneScribePackageResource.maximumDataLength + 1)
        )
        assertResourcePreflightRejects(oversized, as: .invalidResourceTable)

        var duplicate = valid
        let lateIDStart = lateRecord + 48
        duplicate.replaceSubrange(
            lateIDStart..<(lateIDStart + second.id.utf8.count),
            with: first.id.utf8
        )
        assertResourcePreflightRejects(duplicate, as: .duplicateResource)

        let cipher = Cipher.generated(label: "Nested late resource")
        let container = try RuneScribePackage(
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
                    data: valid
                ),
            ]
        )
        var malformedNested = try container.encoded()
        let resourceDirectoryRecord = RuneScribePackage.fixedHeaderLength
            + RuneScribePackage.directoryRecordLength
        let resourceOffset = Int(malformedNested.readUInt32(at: resourceDirectoryRecord + 8))
        malformedNested.replaceUInt16(at: resourceOffset + lateRecord + 2, with: 1)
        malformedNested.refreshPackageChecksum()
        assertPackagePreflightRejects(malformedNested, as: .invalidResourceTable)
    }

    func testLegacyFontMediaTypeAllowlistRejectsImageBeforeAllocation() throws {
        XCTAssertThrowsError(
            try RuneScribePackageResource(
                kind: .legacyFont,
                id: "legacy.image",
                version: 1,
                mediaType: "image/png",
                data: Data("not-a-font".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .invalidResourceMediaType)
        }

        let first = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.a",
            version: 1,
            mediaType: "font/ttf",
            data: Data("first-font".utf8)
        )
        let second = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.b",
            version: 1,
            mediaType: "font/otf",
            data: Data("second-font".utf8)
        )
        var masquerading = try RuneScribePackageResourceTable(
            resources: [first, second]
        ).encoded()
        let lateRecord = 4 + 48
            + first.id.utf8.count
            + first.mediaType.utf8.count
            + first.data.count
        let mediaLengthOffset = lateRecord + 10
        let mediaStart = lateRecord + 48 + second.id.utf8.count
        masquerading.replaceSubrange(
            mediaStart..<(mediaStart + second.mediaType.utf8.count),
            with: "image/png".utf8
        )
        masquerading.replaceUInt16(
            at: mediaLengthOffset,
            with: UInt16("image/png".utf8.count)
        )
        assertResourcePreflightRejects(masquerading, as: .invalidResourceMediaType)
    }

    func testResourceTableRejectsIdentifierPathAndMediaTypeAbuse() throws {
        let resource = try RuneScribePackageResource(
            kind: .legacyFont,
            id: "legacy.font",
            version: 1,
            mediaType: "font/otf",
            data: Data("font".utf8)
        )
        let valid = try RuneScribePackageResourceTable(resources: [resource]).encoded()

        var traversal = valid
        traversal.replaceSubrange(52..<63, with: Data("../bad.font".utf8))
        XCTAssertThrowsError(try RuneScribePackageResourceTable(decoding: traversal)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .invalidResourceIdentifier)
        }

        var malformedMediaType = valid
        malformedMediaType.replaceSubrange(63..<71, with: Data("font//tf".utf8))
        XCTAssertThrowsError(
            try RuneScribePackageResourceTable(decoding: malformedMediaType)
        ) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .invalidResourceMediaType)
        }

        var zeroVersion = valid
        zeroVersion.replaceUInt32(at: 8, with: 0)
        XCTAssertThrowsError(try RuneScribePackageResourceTable(decoding: zeroVersion)) { error in
            XCTAssertEqual(error as? RuneScribePackageError, .invalidResourceVersion)
        }
    }

    func testDeterministicMalformedCorpusStaysBoundedAndFailsClosed() throws {
        let cipher = Cipher.generated(label: "Mutation corpus")
        let base = try RuneScribePackage(
            kind: .cipherInvitation,
            payloadVersion: UInt16(CipherSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: try CipherSharePayload(cipher: cipher).encoded()
                ),
                RuneScribePackageSection(type: 0x7000, data: Data("optional".utf8)),
            ]
        ).encoded()

        var generator = DeterministicMutationGenerator(state: 0x5253_4352_504B_4731)
        var distinctErrors: Set<String> = []
        for sample in 0..<512 {
            var candidate = base
            let mutationCount = 1 + Int(generator.next() % 4)
            for _ in 0..<mutationCount {
                let position = Int(generator.next() % UInt64(candidate.count))
                let mask = UInt8(truncatingIfNeeded: generator.next()) | 1
                candidate[position] ^= mask
            }
            if sample.isMultiple(of: 2), candidate.count >= RuneScribePackage.checksumLength {
                candidate.refreshPackageChecksum()
            }

            var events: [RuneScribePackageDecodeAllocation] = []
            do {
                let decoded = try RuneScribePackage(
                    decoding: candidate,
                    allocationObserver: { events.append($0) }
                )
                XCTAssertLessThanOrEqual(try decoded.encoded().count, RuneScribePackage.maximumTotalLength)
            } catch let error as RuneScribePackageError {
                distinctErrors.insert(String(describing: error))
            } catch {
                XCTFail("Unexpected error type at deterministic sample \(sample): \(error)")
            }

            for event in events {
                switch event {
                case .sectionArrayCapacity(let count):
                    XCTAssertLessThanOrEqual(count, RuneScribePackage.maximumSectionCount)
                case .sectionPayload(let bytes):
                    XCTAssertLessThanOrEqual(bytes, RuneScribePackage.maximumResourceTableLength)
                case .resourceArrayCapacity(let count):
                    XCTAssertLessThanOrEqual(count, RuneScribePackageResourceTable.maximumResourceCount)
                case .resourceMetadata(let bytes):
                    XCTAssertLessThanOrEqual(
                        bytes,
                        SHA256.Digest.byteCount
                            + RuneScribePackageResource.maximumIdentifierUTF8Count
                            + RuneScribePackageResource.maximumMediaTypeUTF8Count
                    )
                case .resourcePayload(let bytes):
                    XCTAssertLessThanOrEqual(bytes, RuneScribePackageResource.maximumDataLength)
                }
            }
        }
        XCTAssertGreaterThanOrEqual(distinctErrors.count, 6)
    }

    private func assertPackagePreflightRejects(
        _ data: Data,
        as expected: RuneScribePackageError
    ) {
        var events: [RuneScribePackageDecodeAllocation] = []
        XCTAssertThrowsError(try RuneScribePackage(
            decoding: data,
            allocationObserver: { events.append($0) }
        )) { error in
            XCTAssertEqual(error as? RuneScribePackageError, expected)
        }
        XCTAssertTrue(events.isEmpty)
    }

    private func assertResourcePreflightRejects(
        _ data: Data,
        as expected: RuneScribePackageError
    ) {
        var events: [RuneScribePackageDecodeAllocation] = []
        XCTAssertThrowsError(try RuneScribePackageResourceTable(
            decoding: data,
            allocationObserver: { events.append($0) }
        )) { error in
            XCTAssertEqual(error as? RuneScribePackageError, expected)
        }
        XCTAssertTrue(events.isEmpty)
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

    mutating func replaceUInt32(at offset: Int, with value: UInt32) {
        replaceSubrange(offset..<(offset + 4), with: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    mutating func replaceUInt16(at offset: Int, with value: UInt16) {
        replaceSubrange(offset..<(offset + 2), with: [
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
}

private struct DeterministicMutationGenerator {
    private var state: UInt64

    init(state: UInt64) {
        self.state = state
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
