import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
@_spi(RuntimeOperationAuthority) import RuneScribeContracts
@testable import RuneScribeCoreModule
import XCTest

final class SharePresentationSectionTests: XCTestCase {
    func testCanonicalMetadataRoundTripRejectsNoncanonicalAndUnknownFields() throws {
        let fixture = try makeFixture()
        let encoded = try SharePresentationSectionCodec.encodeMetadata(fixture.metadata)

        XCTAssertEqual(
            try SharePresentationSectionCodec.decodeMetadata(encoded),
            fixture.metadata
        )
        XCTAssertThrowsError(
            try SharePresentationSectionCodec.decodeMetadata(encoded + Data("\n".utf8))
        ) { error in
            XCTAssertEqual(
                error as? SharePresentationSectionError,
                .noncanonicalMetadata
            )
        }

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["unexpected"] = true
        let unknown = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertThrowsError(try SharePresentationSectionCodec.decodeMetadata(unknown))

        XCTAssertThrowsError(try ShareSafePreviewMetadata(
            mediaType: .png,
            byteLength: 100,
            pixelSize: ThemePixelSize(width: 401, height: 300),
            sha256: fixture.metadata.safePreview!.sha256
        ))
    }

    func testThemedPackageRoundTripPreservesCoreAndValidatedPreview() throws {
        let fixture = try makeFixture()
        let core = try messageCorePayload()
        let package = try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: core,
            presentation: SharePresentationSectionBundle(
                metadata: fixture.metadata,
                safePreviewData: fixture.preview,
                signedProvenance: nil
            )
        )

        let decoded = try RuneScribePackage(decoding: package.encoded())
        let intake = decoded.sharePresentation()

        XCTAssertEqual(decoded.corePayload, core)
        XCTAssertEqual(intake.metadata, fixture.metadata)
        XCTAssertEqual(intake.safePreviewData, fixture.preview)
        XCTAssertEqual(intake.safePreviewStatus, .valid)
        XCTAssertEqual(intake.provenanceStatus, .unavailable)
    }

    func testOutboundDTOAndRouterRetainBoundedPresentationAndLegacyFont() throws {
        let fixture = try makeFixture()
        let outbound = try OutboundSharePresentationDTO(
            metadata: fixture.metadata,
            safePreviewData: fixture.preview
        )
        let fontData = Data("phase-f-custom-font".utf8)
        let fontRef = FontRef(
            id: "phase-f-font",
            version: 2,
            sha256: Data(SHA256.hash(data: fontData))
        )
        let generated = Cipher.generated(label: "Phase F")
        let cipher = Cipher(
            id: generated.id,
            label: generated.label,
            origin: generated.origin,
            createdAt: generated.createdAt,
            formatVersion: generated.formatVersion,
            publicID: generated.publicID,
            keyMaterial: generated.keyMaterial,
            decorativeMapping: generated.decorativeMapping,
            fontRef: fontRef
        )
        let payload = MessageSharePayload(
            senderName: "Sender",
            envelope: Data([0x01, 0x02, 0x03]),
            embeddedCipher: CipherSharePayload(cipher: cipher)
        )
        let package = try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: payload.encoded(),
            presentation: SharePresentationSectionBundle(
                metadata: outbound.metadata,
                safePreviewData: outbound.safePreviewData,
                signedProvenance: outbound.signedProvenance
            ),
            legacyFontReference: fontRef,
            legacyFontData: fontData
        )

        guard case let .themedMessage(routed, routedFont, intake) = try FileRouter.decode(
            package.encoded()
        ) else {
            return XCTFail("Expected a themed message route.")
        }
        XCTAssertEqual(routed.senderName, payload.senderName)
        XCTAssertEqual(routedFont, fontData)
        XCTAssertEqual(intake.metadata, fixture.metadata)
        XCTAssertEqual(intake.safePreviewData, fixture.preview)
    }

    func testOutboundDTORejectsMismatchedPreviewAndReceivedDTORejectsOversize() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try OutboundSharePresentationDTO(
            metadata: fixture.metadata,
            safePreviewData: Data([0x00])
        )) { error in
            XCTAssertEqual(
                error as? SharePresentationContractError,
                .invalidSafePreview
            )
        }

        let presentation = try SharePresentationResolver.resolve(
            metadata: fixture.metadata,
            providerAvailability: .unknown,
            safePreviewStatus: .valid,
            provenanceStatus: .unavailable
        )
        XCTAssertThrowsError(try ReceivedMessageDTO(
            id: MessageID(rawValue: UUID()),
            plaintext: "Readable",
            senderName: "Sender",
            cipherID: CipherID(rawValue: UUID()),
            cipherName: "Cipher",
            presentation: presentation,
            safePreviewData: Data(
                repeating: 0,
                count: Int(ShareSafePreviewMetadata.maximumByteLength) + 1
            )
        ))
    }

    func testDurableShareJournalFreezesPresentationSelection() throws {
        let fixture = try makeFixture()
        let id = ShareArtifactID(rawValue: UUID())
        let artifact = CoreShareArtifact(
            dto: ShareArtifactDTO(
                id: id,
                reference: .opaque(id),
                displayName: "Rune Scribe Message",
                contentType: "text/plain",
                fileExtension: nil,
                lifetime: .singleUse,
                requiresKeyDelivery: false
            ),
            hasStoredFile: false,
            hasStoredLink: false,
            messageCipherID: UUID(),
            encodedMessageHandle: nil,
            presentationSelection: fixture.metadata.selection,
            persistsMetadata: true
        )
        let record = try CoreDurableShareArtifactRecord(sequence: 1, artifact: artifact)
        let restored = try JSONDecoder().decode(
            CoreDurableShareArtifactRecord.self,
            from: JSONEncoder().encode(record)
        )

        XCTAssertEqual(restored.presentationSelection, fixture.metadata.selection)

        let encoded = try JSONEncoder().encode(record)
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "presentationSelection")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertNil(try JSONDecoder().decode(
            CoreDurableShareArtifactRecord.self,
            from: legacyData
        ).presentationSelection)
    }

    func testCorruptPreviewFailsSoftWithoutChangingCoreAdmission() throws {
        let fixture = try makeFixture()
        let core = try messageCorePayload()
        var corruptPreview = fixture.preview
        corruptPreview[corruptPreview.startIndex] ^= 0xff
        let package = try RuneScribePackage(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            sections: [
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.corePayload.rawValue,
                    required: true,
                    data: core
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.presentationMetadata.rawValue,
                    data: try SharePresentationSectionCodec.encodeMetadata(fixture.metadata)
                ),
                RuneScribePackageSection(
                    type: RuneScribePackageSectionType.safePreview.rawValue,
                    data: corruptPreview
                ),
            ]
        )

        let decoded = try RuneScribePackage(decoding: package.encoded())
        let intake = decoded.sharePresentation()

        XCTAssertEqual(decoded.corePayload, core)
        XCTAssertEqual(intake.metadata, fixture.metadata)
        XCTAssertNil(intake.safePreviewData)
        XCTAssertEqual(intake.safePreviewStatus, .invalid)
    }

    func testEveryUnavailableProviderStateUsesNorseAndPreservesValidPreview() throws {
        let fixture = try makeFixture()
        let unavailable: [ShareProviderAvailability] = [
            .locked,
            .unknown,
            .unavailable,
            .incompatible,
            .corrupt,
            .notInstalled,
        ]

        for state in unavailable {
            let resolution = try SharePresentationResolver.resolve(
                metadata: fixture.metadata,
                providerAvailability: state,
                safePreviewStatus: .valid,
                provenanceStatus: .unverified
            )
            XCTAssertEqual(resolution.effectiveCodexID, RuneScribeCodexIDs.norse)
            XCTAssertEqual(resolution.renderMode, .norseInteractiveFallback)
            XCTAssertEqual(resolution.safePreviewStatus, .valid)
        }

        let selection = fixture.metadata.selection
        let futureMetadata = try SharePresentationMetadata(
            selection: SharePresentationSelection(
                codexID: selection.codexID,
                scriptID: selection.scriptID,
                relicID: selection.relicID,
                sealID: selection.sealID,
                frameID: selection.frameID,
                presentationVersion:
                    SharePresentationSelection.supportedPresentationVersion + 1
            ),
            safePreview: fixture.metadata.safePreview,
            resources: fixture.metadata.resources,
            provenance: fixture.metadata.provenance,
            compatibility: fixture.metadata.compatibility
        )
        let futureResolution = try SharePresentationResolver.resolve(
            metadata: futureMetadata,
            providerAvailability: .available,
            safePreviewStatus: .valid,
            provenanceStatus: .unverified
        )
        XCTAssertEqual(futureResolution.providerAvailability, .incompatible)
        XCTAssertEqual(futureResolution.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(futureResolution.safePreviewStatus, .valid)
    }

    func testProviderInventoryRejectsUnknownSelectionIDsAndResourceHashDrift() throws {
        let fixture = try makeFixture()
        let selection = fixture.metadata.selection
        let inventory = try providerInventory(for: fixture.metadata)
        let valid = try SharePresentationResolver.resolve(
            metadata: fixture.metadata,
            providerAvailability: .available,
            safePreviewStatus: .valid,
            provenanceStatus: .unverified,
            providerInventories: [inventory]
        )
        XCTAssertEqual(valid.providerAvailability, .available)
        XCTAssertEqual(valid.renderMode, .requestedCodex)

        let incompatibleSelections = [
            try SharePresentationSelection(
                codexID: selection.codexID,
                scriptID: ScriptID(rawValue: "script.sunspire")!,
                relicID: selection.relicID,
                sealID: selection.sealID,
                frameID: selection.frameID
            ),
            try SharePresentationSelection(
                codexID: selection.codexID,
                scriptID: selection.scriptID,
                relicID: ArtifactID(rawValue: "relic.sunspire.cross-codex")!,
                sealID: selection.sealID,
                frameID: selection.frameID
            ),
            try SharePresentationSelection(
                codexID: selection.codexID,
                scriptID: selection.scriptID,
                relicID: selection.relicID,
                sealID: ArtifactID(rawValue: "seal.sunspire.cross-codex")!,
                frameID: selection.frameID
            ),
            try SharePresentationSelection(
                codexID: selection.codexID,
                scriptID: selection.scriptID,
                relicID: selection.relicID,
                sealID: selection.sealID,
                frameID: ArtifactID(rawValue: "frame.sunspire.cross-codex")!
            ),
        ]
        for incompatibleSelection in incompatibleSelections {
            let metadata = try presentationMetadata(
                selection: incompatibleSelection,
                basedOn: fixture.metadata
            )
            let resolution = try SharePresentationResolver.resolve(
                metadata: metadata,
                providerAvailability: .available,
                safePreviewStatus: .valid,
                provenanceStatus: .unverified,
                providerInventories: [inventory]
            )
            XCTAssertEqual(resolution.providerAvailability, .incompatible)
            XCTAssertEqual(resolution.effectiveCodexID, RuneScribeCodexIDs.norse)
            XCTAssertEqual(resolution.renderMode, .norseInteractiveFallback)
        }

        let expectedResource = try presentationResource(digestCharacter: "a")
        let hashBoundMetadata = try presentationMetadata(
            selection: selection,
            basedOn: fixture.metadata,
            resources: [try presentationResource(digestCharacter: "b")]
        )
        let resourceInventory = try providerInventory(
            for: fixture.metadata,
            resources: [expectedResource]
        )
        let corrupt = try SharePresentationResolver.resolve(
            metadata: hashBoundMetadata,
            providerAvailability: .available,
            safePreviewStatus: .valid,
            provenanceStatus: .unverified,
            providerInventories: [resourceInventory]
        )
        XCTAssertEqual(corrupt.providerAvailability, .corrupt)
        XCTAssertEqual(corrupt.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(corrupt.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(corrupt.resourceMetadata, hashBoundMetadata.resources)
    }

    func testSignedProvenanceVerifiesAndInvalidSignatureDoesNotBlockPayload() throws {
        let preview = try makePNG(width: 4, height: 3)
        let previewMetadata = try previewMetadata(preview)
        let privateKey = Curve25519.Signing.PrivateKey()
        let signerID = ShareProvenanceSignerID(rawValue: "signer.runescribe.release")!
        let referenceID = ThemeProvenanceID(rawValue: "rights.moonleaf.release")!
        let statementDigest = SharePresentationSectionCodec.digest(
            of: Data("approved-release-statement".utf8)
        )
        let reference = try ShareProvenanceReference(
            referenceID: referenceID,
            statementSHA256: statementDigest,
            signerKeyID: signerID,
            status: .unverified
        )
        let metadata = try makeMetadata(
            previewMetadata: previewMetadata,
            provenance: reference
        )
        let metadataData = try SharePresentationSectionCodec.encodeMetadata(metadata)
        let placeholder = try ShareSignedProvenance(
            referenceID: referenceID,
            signerKeyID: signerID,
            statementSHA256: statementDigest,
            presentationSHA256: SharePresentationSectionCodec.digest(of: metadataData),
            previewSHA256: previewMetadata.sha256,
            signature: Data(repeating: 0, count: ShareSignedProvenance.signatureByteCount)
        )
        let signature = try privateKey.signature(
            for: SharePresentationSectionCodec.provenanceSigningMessage(placeholder)
        )
        let signed = try ShareSignedProvenance(
            referenceID: referenceID,
            signerKeyID: signerID,
            statementSHA256: statementDigest,
            presentationSHA256: placeholder.presentationSHA256,
            previewSHA256: previewMetadata.sha256,
            signature: signature
        )
        let trustStore = ShareProvenanceTrustStore(rawPublicKeys: [
            signerID: privateKey.publicKey.rawRepresentation,
        ])
        let validPackage = try themedPackage(
            metadata: metadata,
            preview: preview,
            signed: signed
        )

        XCTAssertEqual(
            try RuneScribePackage(decoding: validPackage.encoded())
                .sharePresentation(trustStore: trustStore).provenanceStatus,
            .verified
        )
        XCTAssertEqual(ShareProvenanceTrustStore.production, .init())
        guard case let .themedMessage(routedPayload, _, routedIntake) =
            try FileRouter.decode(validPackage.encoded())
        else {
            return XCTFail("Expected production FileRouter to preserve the themed payload")
        }
        XCTAssertEqual(routedPayload.senderName, "Sender")
        XCTAssertEqual(
            routedIntake.provenanceStatus,
            .unavailable,
            "A valid signature from an unapproved signer must remain explicitly untrusted"
        )
        XCTAssertFalse(routedPayload.envelope.isEmpty)

        var invalidBytes = signature
        invalidBytes[invalidBytes.startIndex] ^= 0x01
        let invalidSigned = try ShareSignedProvenance(
            referenceID: referenceID,
            signerKeyID: signerID,
            statementSHA256: statementDigest,
            presentationSHA256: placeholder.presentationSHA256,
            previewSHA256: previewMetadata.sha256,
            signature: invalidBytes
        )
        let invalidPackage = try themedPackage(
            metadata: metadata,
            preview: preview,
            signed: invalidSigned
        )
        let decoded = try RuneScribePackage(decoding: invalidPackage.encoded())
        XCTAssertFalse(decoded.corePayload.isEmpty)
        XCTAssertEqual(
            decoded.sharePresentation(trustStore: trustStore).provenanceStatus,
            .invalid
        )
    }

    func testTerminalShareProgressionProjectsSelectionAndCancelNeverGrants() throws {
        let fixture = try makeFixture()
        let messageToken = token(MessageToken.self, "aa")
        let cipherToken = token(CipherToken.self, "bb")
        let relationshipToken = token(RelationshipToken.self, "cc")
        let share = try XCTUnwrap(CoreProgressionFactFactory.shareCompleted(
            report: SharePresentationReportDTO(
                routeClass: .messages,
                result: .sentConfirmed,
                requiredAttachmentAccepted: true
            ),
            messageToken: messageToken,
            codexIDs: [fixture.metadata.selection.codexID],
            artifactIDs: fixture.metadata.selection.artifactIDs,
            keyIncluded: true,
            relationshipToken: relationshipToken,
            linkedRelationship: true
        ))
        let firstDelivery = try CoreProgressionFactFactory.firstDeliveryCompleted(
            cipherToken: cipherToken,
            relationshipToken: relationshipToken
        )
        XCTAssertEqual(share.eventType.rawValue, "runescribe.share.completed")
        XCTAssertEqual(share.payload.codexIDs, [fixture.metadata.selection.codexID])
        XCTAssertEqual(share.payload.artifactIDs, fixture.metadata.selection.artifactIDs)
        XCTAssertEqual(
            firstDelivery.eventType.rawValue,
            "runescribe.cipher.first-delivery-completed"
        )
        XCTAssertNil(try CoreProgressionFactFactory.shareCompleted(
            report: SharePresentationReportDTO(
                routeClass: .shareSheet,
                result: .cancelled
            ),
            messageToken: messageToken,
            keyIncluded: false,
            relationshipToken: nil,
            linkedRelationship: false
        ))
    }

    func testReceivedPresentationProjectionCreatesSelectedEncounterFact() throws {
        let fixture = try makeFixture()
        let intake = SharePresentationIntake(
            metadata: fixture.metadata,
            safePreviewData: fixture.preview,
            safePreviewStatus: .valid,
            provenanceStatus: .unverified
        )
        let packageToken = token(PackageToken.self, "dd")
        let projection = SharePresentationProgressionProjection.inbound(intake)
        let presentation = try SharePresentationResolver.resolve(
            metadata: fixture.metadata,
            providerAvailability: .locked,
            safePreviewStatus: intake.safePreviewStatus,
            provenanceStatus: intake.provenanceStatus
        )
        let fact = try CoreProgressionFactFactory.presentationObserved(
            packageToken: packageToken,
            codexIDs: projection.codexIDs,
            artifactIDs: projection.artifactIDs,
            provenanceStatus: projection.provenanceStatus
        )
        XCTAssertEqual(presentation.effectiveCodexID, RuneScribeCodexIDs.norse)
        XCTAssertEqual(presentation.renderMode, .norseInteractiveFallback)
        XCTAssertEqual(fact.eventType.rawValue, "runescribe.presentation.observed")
        XCTAssertEqual(fact.payload.codexIDs, [fixture.metadata.selection.codexID])
        XCTAssertEqual(fact.payload.artifactIDs, fixture.metadata.selection.artifactIDs)
        XCTAssertEqual(fact.payload.provenanceStatus, .unverified)
    }

    private func makeFixture() throws -> (
        metadata: SharePresentationMetadata,
        preview: Data
    ) {
        let preview = try makePNG(width: 4, height: 3)
        return (
            try makeMetadata(previewMetadata: previewMetadata(preview)),
            preview
        )
    }

    private func makeMetadata(
        previewMetadata: ShareSafePreviewMetadata,
        provenance: ShareProvenanceReference? = nil
    ) throws -> SharePresentationMetadata {
        try SharePresentationMetadata(
            selection: SharePresentationSelection(
                codexID: CodexID(rawValue: "codex.moonleaf")!,
                scriptID: ScriptID(rawValue: "script.moonleaf")!,
                relicID: ArtifactID(rawValue: "relic.moonleaf.moonstone-tablet")!,
                sealID: ArtifactID(rawValue: "seal.moonleaf.echo-firefly")!,
                frameID: ArtifactID(rawValue: "frame.moonleaf.silvervine")!
            ),
            safePreview: previewMetadata,
            resources: [],
            provenance: provenance,
            compatibility: SharePresentationCompatibilityFlags.safePreviewPresent
                .union(.norseInteractiveFallback)
        )
    }

    private func presentationMetadata(
        selection: SharePresentationSelection,
        basedOn metadata: SharePresentationMetadata,
        resources: [SharePresentationResourceMetadata]? = nil
    ) throws -> SharePresentationMetadata {
        try SharePresentationMetadata(
            selection: selection,
            safePreview: metadata.safePreview,
            resources: resources ?? metadata.resources,
            provenance: metadata.provenance,
            compatibility: metadata.compatibility
        )
    }

    private func providerInventory(
        for metadata: SharePresentationMetadata,
        resources: [SharePresentationResourceMetadata]? = nil
    ) throws -> SharePresentationProviderInventory {
        let selection = metadata.selection
        return try SharePresentationProviderInventory(
            codexID: selection.codexID,
            scriptIDs: [selection.scriptID],
            relicIDs: [selection.relicID],
            sealIDs: [selection.sealID].compactMap { $0 },
            frameIDs: [selection.frameID].compactMap { $0 },
            resources: try (resources ?? metadata.resources).map(
                SharePresentationProviderResourceInventory.init(metadata:)
            )
        )
    }

    private func presentationResource(
        digestCharacter: Character
    ) throws -> SharePresentationResourceMetadata {
        try SharePresentationResourceMetadata(
            resourceID: ThemeResourceID(rawValue: "resource.moonleaf.share-background")!,
            role: ThemeResourceRoles.backgroundStaticBase,
            mediaType: .pdf,
            byteLength: 512,
            sha256: ThemeSHA256Digest(
                rawValue: String(repeating: digestCharacter, count: 64)
            )!
        )
    }

    private func previewMetadata(_ data: Data) throws -> ShareSafePreviewMetadata {
        try ShareSafePreviewMetadata(
            mediaType: .png,
            byteLength: UInt32(data.count),
            pixelSize: ThemePixelSize(width: 4, height: 3),
            sha256: SharePresentationSectionCodec.digest(of: data)
        )
    }

    private func themedPackage(
        metadata: SharePresentationMetadata,
        preview: Data,
        signed: ShareSignedProvenance
    ) throws -> RuneScribePackage {
        try RuneScribePackage.themed(
            kind: .encryptedMessage,
            payloadVersion: UInt16(MessageSharePayload.version),
            corePayload: messageCorePayload(),
            presentation: SharePresentationSectionBundle(
                metadata: metadata,
                safePreviewData: preview,
                signedProvenance: signed
            )
        )
    }

    private func messageCorePayload() throws -> Data {
        try MessageSharePayload(
            senderName: "Sender",
            envelope: Data([0x01, 0x02, 0x03]),
            embeddedCipher: nil
        ).encoded()
    }

    private func token<Domain>(
        _ type: PrivacySafeToken<Domain>.Type,
        _ pair: String
    ) -> PrivacySafeToken<Domain> {
        PrivacySafeToken(rawValue: String(repeating: pair, count: 16))!
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
