import CryptoKit
import Foundation
import ImageIO
import RuneScribeContracts

enum SharePresentationSectionError: Error, Equatable, Sendable {
    case metadataTooLarge
    case provenanceTooLarge
    case noncanonicalMetadata
    case noncanonicalProvenance
    case missingSafePreview
    case unexpectedSafePreview
    case invalidSafePreview
    case presentationDigestMismatch
    case provenanceBindingMismatch
}

struct SharePresentationSectionBundle: Equatable, Sendable {
    let metadata: SharePresentationMetadata
    let safePreviewData: Data?
    let signedProvenance: ShareSignedProvenance?
}

struct SharePresentationIntake: Equatable, Sendable {
    let metadata: SharePresentationMetadata?
    let safePreviewData: Data?
    let safePreviewStatus: ShareSafePreviewStatus
    let provenanceStatus: ShareProvenanceVerificationStatus

    static let absent = SharePresentationIntake(
        metadata: nil,
        safePreviewData: nil,
        safePreviewStatus: .absent,
        provenanceStatus: .unavailable
    )
}

struct ShareProvenanceTrustStore: Equatable, Sendable {
    /// No production provenance signing authority has been approved in source.
    /// Signed records therefore remain explicitly unavailable until an approved
    /// public key is added here by a release-authority decision.
    static let production = ShareProvenanceTrustStore(rawPublicKeys: [:])

    private let rawPublicKeys: [ShareProvenanceSignerID: Data]

    init(rawPublicKeys: [ShareProvenanceSignerID: Data] = [:]) {
        self.rawPublicKeys = rawPublicKeys.filter { _, data in
            data.count == 32
                && (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil
        }
    }

    func rawPublicKey(for signerKeyID: ShareProvenanceSignerID) -> Data? {
        rawPublicKeys[signerKeyID]
    }
}

enum SharePresentationSectionCodec {
    static let maximumMetadataLength = 64 * 1024
    static let maximumProvenanceLength = 64 * 1024

    static func encode(_ bundle: SharePresentationSectionBundle) throws -> (
        metadata: Data,
        safePreview: Data?,
        signedProvenance: Data?
    ) {
        let metadataData = try encodeMetadata(bundle.metadata)
        let validatedPreview = try validateSafePreview(
            bundle.safePreviewData,
            metadata: bundle.metadata.safePreview
        )

        let provenanceData: Data?
        if let signedProvenance = bundle.signedProvenance {
            guard digest(of: metadataData) == signedProvenance.presentationSHA256,
                  signedProvenance.previewSHA256 == bundle.metadata.safePreview?.sha256,
                  signedProvenance.referenceID == bundle.metadata.provenance?.referenceID,
                  signedProvenance.signerKeyID == bundle.metadata.provenance?.signerKeyID,
                  signedProvenance.statementSHA256
                    == bundle.metadata.provenance?.statementSHA256
            else {
                throw SharePresentationSectionError.provenanceBindingMismatch
            }
            provenanceData = try encodeProvenance(signedProvenance)
        } else {
            provenanceData = nil
        }
        return (metadataData, validatedPreview, provenanceData)
    }

    static func decodeMetadata(_ data: Data) throws -> SharePresentationMetadata {
        guard !data.isEmpty, data.count <= maximumMetadataLength else {
            throw SharePresentationSectionError.metadataTooLarge
        }
        let value = try JSONDecoder().decode(SharePresentationMetadata.self, from: data)
        guard try encodeMetadata(value) == data else {
            throw SharePresentationSectionError.noncanonicalMetadata
        }
        return value
    }

    static func encodeMetadata(_ metadata: SharePresentationMetadata) throws -> Data {
        let data = try canonicalEncoder().encode(metadata)
        guard data.count <= maximumMetadataLength else {
            throw SharePresentationSectionError.metadataTooLarge
        }
        return data
    }

    static func decodeProvenance(_ data: Data) throws -> ShareSignedProvenance {
        guard !data.isEmpty, data.count <= maximumProvenanceLength else {
            throw SharePresentationSectionError.provenanceTooLarge
        }
        let value = try JSONDecoder().decode(ShareSignedProvenance.self, from: data)
        guard try encodeProvenance(value) == data else {
            throw SharePresentationSectionError.noncanonicalProvenance
        }
        return value
    }

    static func encodeProvenance(_ provenance: ShareSignedProvenance) throws -> Data {
        let data = try canonicalEncoder().encode(provenance)
        guard data.count <= maximumProvenanceLength else {
            throw SharePresentationSectionError.provenanceTooLarge
        }
        return data
    }

    static func validateSafePreview(
        _ data: Data?,
        metadata: ShareSafePreviewMetadata?
    ) throws -> Data? {
        switch (data, metadata) {
        case (nil, nil):
            return nil
        case (nil, .some):
            throw SharePresentationSectionError.missingSafePreview
        case (.some, nil):
            throw SharePresentationSectionError.unexpectedSafePreview
        case let (.some(data), .some(metadata)):
            guard data.count == Int(metadata.byteLength),
                  data.count <= Int(ShareSafePreviewMetadata.maximumByteLength),
                  digest(of: data) == metadata.sha256,
                  mediaType(of: data) == metadata.mediaType,
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(imageSource) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    0,
                    nil
                  ) as? [CFString: Any],
                  let declaredWidth = (properties[kCGImagePropertyPixelWidth]
                    as? NSNumber)?.intValue,
                  let declaredHeight = (properties[kCGImagePropertyPixelHeight]
                    as? NSNumber)?.intValue,
                  declaredWidth == Int(metadata.pixelSize.width),
                  declaredHeight == Int(metadata.pixelSize.height),
                  let image = CGImageSourceCreateImageAtIndex(
                    imageSource,
                    0,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  ),
                  image.width == Int(metadata.pixelSize.width),
                  image.height == Int(metadata.pixelSize.height)
            else {
                throw SharePresentationSectionError.invalidSafePreview
            }
            return data
        }
    }

    static func digest(of data: Data) -> ThemeSHA256Digest {
        let value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ThemeSHA256Digest(rawValue: value)!
    }

    static func provenanceSigningMessage(
        _ provenance: ShareSignedProvenance
    ) -> Data {
        var output = Data("RuneScribe.ShareProvenance.v1\0".utf8)
        appendLengthPrefixed(provenance.referenceID.rawValue, to: &output)
        appendLengthPrefixed(provenance.signerKeyID.rawValue, to: &output)
        appendDigest(provenance.statementSHA256, to: &output)
        appendDigest(provenance.presentationSHA256, to: &output)
        if let previewSHA256 = provenance.previewSHA256 {
            output.append(1)
            appendDigest(previewSHA256, to: &output)
        } else {
            output.append(0)
        }
        return output
    }

    private static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func mediaType(of data: Data) -> ShareSafePreviewMediaType? {
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        if data.count >= pngMagic.count, Array(data.prefix(pngMagic.count)) == pngMagic {
            return .png
        }
        guard data.count >= 12,
              String(decoding: data[4..<8], as: UTF8.self) == "ftyp"
        else { return nil }
        let brand = String(decoding: data[8..<12], as: UTF8.self)
        return ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]
            .contains(brand) ? .heif : nil
    }

    private static func appendLengthPrefixed(_ value: String, to output: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt16(bytes.count).bigEndian
        output.append(Data(bytes: &length, count: MemoryLayout<UInt16>.size))
        output.append(bytes)
    }

    private static func appendDigest(
        _ digest: ThemeSHA256Digest,
        to output: inout Data
    ) {
        let characters = Array(digest.rawValue.utf8)
        for index in stride(from: 0, to: characters.count, by: 2) {
            output.append(hexNibble(characters[index]) << 4 | hexNibble(characters[index + 1]))
        }
    }

    private static func hexNibble(_ character: UInt8) -> UInt8 {
        if (0x30...0x39).contains(character) { return character - 0x30 }
        return character - 0x61 + 10
    }
}

enum ShareProvenanceVerifier {
    static func verify(
        _ signed: ShareSignedProvenance?,
        metadata: SharePresentationMetadata,
        canonicalMetadata: Data,
        safePreviewData: Data?,
        trustStore: ShareProvenanceTrustStore
    ) -> ShareProvenanceVerificationStatus {
        guard let reference = metadata.provenance else {
            return signed == nil ? .unavailable : .invalid
        }
        guard let signed else {
            switch reference.status {
            case .invalid:
                return .invalid
            case .unavailable:
                return .unavailable
            case .verified, .unverified:
                return .unverified
            }
        }
        guard signed.referenceID == reference.referenceID,
              signed.signerKeyID == reference.signerKeyID,
              signed.statementSHA256 == reference.statementSHA256,
              signed.presentationSHA256
                == SharePresentationSectionCodec.digest(of: canonicalMetadata),
              signed.previewSHA256 == metadata.safePreview?.sha256,
              signed.previewSHA256
                == safePreviewData.map(SharePresentationSectionCodec.digest(of:))
        else { return .invalid }
        guard let rawKey = trustStore.rawPublicKey(for: signed.signerKeyID),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
        else { return .unavailable }
        return key.isValidSignature(
            signed.signature,
            for: SharePresentationSectionCodec.provenanceSigningMessage(signed)
        ) ? .verified : .invalid
    }
}

extension RuneScribePackage {
    static func themed(
        kind: RuneScribePackageKind,
        payloadVersion: UInt16,
        corePayload: Data,
        presentation: SharePresentationSectionBundle,
        legacyFontReference: FontRef? = nil,
        legacyFontData: Data? = nil
    ) throws -> RuneScribePackage {
        let encoded = try SharePresentationSectionCodec.encode(presentation)
        var sections = [
            RuneScribePackageSection(
                type: RuneScribePackageSectionType.corePayload.rawValue,
                version: 1,
                required: true,
                data: corePayload
            ),
            RuneScribePackageSection(
                type: RuneScribePackageSectionType.presentationMetadata.rawValue,
                version: SharePresentationMetadata.schemaVersion,
                required: false,
                data: encoded.metadata
            ),
        ]
        if let safePreview = encoded.safePreview {
            sections.append(RuneScribePackageSection(
                type: RuneScribePackageSectionType.safePreview.rawValue,
                version: 1,
                required: false,
                data: safePreview
            ))
        }
        if let signedProvenance = encoded.signedProvenance {
            sections.append(RuneScribePackageSection(
                type: RuneScribePackageSectionType.signedProvenance.rawValue,
                version: ShareSignedProvenance.schemaVersion,
                required: false,
                data: signedProvenance
            ))
        }
        if let reference = legacyFontReference, reference != .bundled {
            guard let data = legacyFontData else {
                throw RuneScribePackageError.missingLegacyFontResource
            }
            guard let version = UInt32(exactly: reference.version) else {
                throw RuneScribePackageError.invalidResourceVersion
            }
            let resource = try RuneScribePackageResource(
                kind: .legacyFont,
                id: reference.id,
                version: version,
                mediaType: "font/ttf",
                data: data
            )
            guard resource.sha256 == reference.sha256 else {
                throw RuneScribePackageError.legacyFontResourceReferenceMismatch
            }
            sections.append(RuneScribePackageSection(
                type: RuneScribePackageSectionType.resourceTable.rawValue,
                version: RuneScribePackageResourceTable.version,
                required: true,
                data: try RuneScribePackageResourceTable(
                    resources: [resource]
                ).encoded()
            ))
        } else if legacyFontData != nil {
            throw RuneScribePackageError.legacyFontResourceReferenceMismatch
        }
        return try RuneScribePackage(
            kind: kind,
            payloadVersion: payloadVersion,
            sections: sections
        )
    }

    /// Presentation is deliberately fail-soft: Core payload admission/decryption
    /// remains authoritative even when optional appearance data is malformed.
    func sharePresentation(
        trustStore: ShareProvenanceTrustStore = .init()
    ) -> SharePresentationIntake {
        guard let metadataSection = sections.first(where: {
            $0.type == RuneScribePackageSectionType.presentationMetadata.rawValue
        }), metadataSection.version == SharePresentationMetadata.schemaVersion,
        let metadata = try? SharePresentationSectionCodec.decodeMetadata(
            metadataSection.data
        ) else {
            return .absent
        }
        let previewSection = sections.first(where: {
            $0.type == RuneScribePackageSectionType.safePreview.rawValue
        })
        let preview: Data?
        let previewStatus: ShareSafePreviewStatus
        do {
            if let previewSection, previewSection.version != 1 {
                throw SharePresentationSectionError.invalidSafePreview
            }
            preview = try SharePresentationSectionCodec.validateSafePreview(
                previewSection?.data,
                metadata: metadata.safePreview
            )
            previewStatus = preview == nil ? .absent : .valid
        } catch {
            preview = nil
            previewStatus = .invalid
        }

        let provenanceSection = sections.first(where: {
            $0.type == RuneScribePackageSectionType.signedProvenance.rawValue
        })
        let signed: ShareSignedProvenance? = provenanceSection.flatMap { section in
            guard section.version == ShareSignedProvenance.schemaVersion else { return nil }
            return try? SharePresentationSectionCodec.decodeProvenance(section.data)
        }
        let provenanceStatus = ShareProvenanceVerifier.verify(
            signed,
            metadata: metadata,
            canonicalMetadata: metadataSection.data,
            safePreviewData: preview,
            trustStore: trustStore
        )
        return SharePresentationIntake(
            metadata: metadata,
            safePreviewData: preview,
            safePreviewStatus: previewStatus,
            provenanceStatus: provenanceSection != nil && signed == nil
                ? .invalid
                : provenanceStatus
        )
    }
}
