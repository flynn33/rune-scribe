import Foundation

public enum SharePresentationContractError: Error, Equatable, Sendable {
    case unsupportedSchema(UInt16)
    case invalidPresentationVersion
    case invalidArtifactIdentifier
    case invalidCompatibilityFlags
    case invalidSafePreview
    case invalidResource
    case tooManyResources(maximum: Int)
    case duplicateResource
    case invalidProviderInventory
    case invalidProvenance
    case invalidObservation
}

private struct SharePresentationAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func sharePresentationRejectUnknownKeys<Key>(
    from decoder: Decoder,
    allowedBy _: Key.Type
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: SharePresentationAnyCodingKey.self)
    let allowed = Set(Key.allCases.map(\.stringValue))
    guard let unknown = container.allKeys.first(where: {
        !allowed.contains($0.stringValue)
    }) else { return }
    throw DecodingError.dataCorrupted(
        .init(
            codingPath: decoder.codingPath + [unknown],
            debugDescription: "Unknown share-presentation field."
        )
    )
}

public enum ShareProvenanceSignerIdentifierDomain: Sendable {}
public typealias ShareProvenanceSignerID =
    RoadmapStringIdentifier<ShareProvenanceSignerIdentifierDomain>

/// Nonsecret appearance choices frozen for one outbound operation. These values
/// are deliberately independent of Cipher identity and key storage.
public struct SharePresentationSelection: Codable, Equatable, Hashable, Sendable {
    public static let supportedPresentationVersion: UInt16 = 1

    public let codexID: CodexID
    public let scriptID: ScriptID
    public let relicID: ArtifactID
    public let sealID: ArtifactID?
    public let frameID: ArtifactID?
    public let presentationVersion: UInt16

    public init(
        codexID: CodexID,
        scriptID: ScriptID,
        relicID: ArtifactID,
        sealID: ArtifactID? = nil,
        frameID: ArtifactID? = nil,
        presentationVersion: UInt16 = 1
    ) throws {
        guard presentationVersion > 0 else {
            throw SharePresentationContractError.invalidPresentationVersion
        }
        guard codexID.rawValue.hasPrefix("codex."),
              scriptID.rawValue.hasPrefix("script."),
              relicID.rawValue.hasPrefix("relic."),
              sealID?.rawValue.hasPrefix("seal.") ?? true,
              frameID?.rawValue.hasPrefix("frame.") ?? true
        else {
            throw SharePresentationContractError.invalidArtifactIdentifier
        }
        self.codexID = codexID
        self.scriptID = scriptID
        self.relicID = relicID
        self.sealID = sealID
        self.frameID = frameID
        self.presentationVersion = presentationVersion
    }

    public var artifactIDs: [ArtifactID] {
        [relicID] + [sealID, frameID].compactMap { $0 }
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codexID: container.decode(CodexID.self, forKey: .codexID),
            scriptID: container.decode(ScriptID.self, forKey: .scriptID),
            relicID: container.decode(ArtifactID.self, forKey: .relicID),
            sealID: container.decodeIfPresent(ArtifactID.self, forKey: .sealID),
            frameID: container.decodeIfPresent(ArtifactID.self, forKey: .frameID),
            presentationVersion: container.decode(UInt16.self, forKey: .presentationVersion)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codexID
        case scriptID
        case relicID
        case sealID
        case frameID
        case presentationVersion
    }
}

public enum ShareSafePreviewMediaType: String, Codable, CaseIterable, Sendable {
    case png = "image/png"
    case heif = "image/heif"
}

/// The preview itself remains in the bounded safe-preview package section. This
/// descriptor binds those bytes to a fixed 4:3 image before UI code sees them.
public struct ShareSafePreviewMetadata: Codable, Equatable, Hashable, Sendable {
    public static let maximumByteLength: UInt32 = 4 * 1024 * 1024

    public let mediaType: ShareSafePreviewMediaType
    public let byteLength: UInt32
    public let pixelSize: ThemePixelSize
    public let sha256: ThemeSHA256Digest

    public init(
        mediaType: ShareSafePreviewMediaType,
        byteLength: UInt32,
        pixelSize: ThemePixelSize,
        sha256: ThemeSHA256Digest
    ) throws {
        guard byteLength > 0,
              byteLength <= Self.maximumByteLength,
              UInt64(pixelSize.width) * 3 == UInt64(pixelSize.height) * 4
        else {
            throw SharePresentationContractError.invalidSafePreview
        }
        self.mediaType = mediaType
        self.byteLength = byteLength
        self.pixelSize = pixelSize
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            mediaType: container.decode(ShareSafePreviewMediaType.self, forKey: .mediaType),
            byteLength: container.decode(UInt32.self, forKey: .byteLength),
            pixelSize: container.decode(ThemePixelSize.self, forKey: .pixelSize),
            sha256: container.decode(ThemeSHA256Digest.self, forKey: .sha256)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case mediaType
        case byteLength
        case pixelSize
        case sha256
    }
}

/// Hash-only resource facts used to prove which validated Theme inputs produced
/// a static Artifact. Resource bytes are never carried by this record.
public struct SharePresentationResourceMetadata: Codable, Equatable, Hashable, Sendable {
    public static let maximumDeclaredByteLength: UInt64 = 64 * 1024 * 1024

    public let resourceID: ThemeResourceID
    public let role: ThemeResourceRoleID
    public let mediaType: ThemeResourceMediaType
    public let byteLength: UInt64
    public let pixelSize: ThemePixelSize?
    public let sha256: ThemeSHA256Digest

    public init(
        resourceID: ThemeResourceID,
        role: ThemeResourceRoleID,
        mediaType: ThemeResourceMediaType,
        byteLength: UInt64,
        pixelSize: ThemePixelSize? = nil,
        sha256: ThemeSHA256Digest
    ) throws {
        let isRasterImage = mediaType == .png || mediaType == .heif
        guard byteLength > 0,
              byteLength <= Self.maximumDeclaredByteLength,
              isRasterImage == (pixelSize != nil)
        else {
            throw SharePresentationContractError.invalidResource
        }
        self.resourceID = resourceID
        self.role = role
        self.mediaType = mediaType
        self.byteLength = byteLength
        self.pixelSize = pixelSize
        self.sha256 = sha256
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            resourceID: container.decode(ThemeResourceID.self, forKey: .resourceID),
            role: container.decode(ThemeResourceRoleID.self, forKey: .role),
            mediaType: container.decode(ThemeResourceMediaType.self, forKey: .mediaType),
            byteLength: container.decode(UInt64.self, forKey: .byteLength),
            pixelSize: container.decodeIfPresent(ThemePixelSize.self, forKey: .pixelSize),
            sha256: container.decode(ThemeSHA256Digest.self, forKey: .sha256)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case resourceID
        case role
        case mediaType
        case byteLength
        case pixelSize
        case sha256
    }
}

public enum ShareProvenanceVerificationStatus: String, Codable, CaseIterable, Sendable {
    case verified
    case unverified
    case unavailable
    case invalid

    public var domainEventStatus: DomainEventProvenanceStatus {
        switch self {
        case .verified: .verified
        case .unverified: .unverified
        case .unavailable: .absent
        case .invalid: .invalid
        }
    }
}

public struct ShareProvenanceReference: Codable, Equatable, Hashable, Sendable {
    public let referenceID: ThemeProvenanceID
    public let statementSHA256: ThemeSHA256Digest
    public let signerKeyID: ShareProvenanceSignerID?
    public let status: ShareProvenanceVerificationStatus

    public init(
        referenceID: ThemeProvenanceID,
        statementSHA256: ThemeSHA256Digest,
        signerKeyID: ShareProvenanceSignerID? = nil,
        status: ShareProvenanceVerificationStatus
    ) throws {
        if status == .verified, signerKeyID == nil {
            throw SharePresentationContractError.invalidProvenance
        }
        self.referenceID = referenceID
        self.statementSHA256 = statementSHA256
        self.signerKeyID = signerKeyID
        self.status = status
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            referenceID: container.decode(ThemeProvenanceID.self, forKey: .referenceID),
            statementSHA256: container.decode(ThemeSHA256Digest.self, forKey: .statementSHA256),
            signerKeyID: container.decodeIfPresent(
                ShareProvenanceSignerID.self,
                forKey: .signerKeyID
            ),
            status: container.decode(ShareProvenanceVerificationStatus.self, forKey: .status)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case referenceID
        case statementSHA256
        case signerKeyID
        case status
    }
}

public struct SharePresentationCompatibilityFlags: Codable, Equatable,
    Hashable, Sendable
{
    public static let safePreviewPresent = try! Self(rawValue: 1 << 0)
    public static let norseInteractiveFallback = try! Self(rawValue: 1 << 1)
    public static let highContrastPreviewAvailable = try! Self(rawValue: 1 << 2)
    public static let monochromePreviewAvailable = try! Self(rawValue: 1 << 3)
    public static let supportedMask: UInt16 = 0x000f

    public let rawValue: UInt16

    public init(rawValue: UInt16) throws {
        guard rawValue & ~Self.supportedMask == 0 else {
            throw SharePresentationContractError.invalidCompatibilityFlags
        }
        self.rawValue = rawValue
    }

    public func contains(_ flag: Self) -> Bool {
        rawValue & flag.rawValue == flag.rawValue
    }

    public func union(_ other: Self) -> Self {
        try! Self(rawValue: rawValue | other.rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(UInt16.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SharePresentationMetadata: Codable, Equatable, Hashable, Sendable {
    public static let schemaVersion: UInt16 = 1
    public static let maximumResourceCount = 32
    public static let maximumDeclaredResourceBytes: UInt64 = 64 * 1024 * 1024

    public let version: UInt16
    public let selection: SharePresentationSelection
    public let safePreview: ShareSafePreviewMetadata?
    public let resources: [SharePresentationResourceMetadata]
    public let provenance: ShareProvenanceReference?
    public let compatibility: SharePresentationCompatibilityFlags

    public init(
        version: UInt16 = Self.schemaVersion,
        selection: SharePresentationSelection,
        safePreview: ShareSafePreviewMetadata? = nil,
        resources: [SharePresentationResourceMetadata] = [],
        provenance: ShareProvenanceReference? = nil,
        compatibility: SharePresentationCompatibilityFlags
    ) throws {
        guard version == Self.schemaVersion else {
            throw SharePresentationContractError.unsupportedSchema(version)
        }
        guard resources.count <= Self.maximumResourceCount else {
            throw SharePresentationContractError.tooManyResources(
                maximum: Self.maximumResourceCount
            )
        }
        guard Set(resources.map(\.resourceID)).count == resources.count else {
            throw SharePresentationContractError.duplicateResource
        }
        var declaredResourceBytes: UInt64 = 0
        for resource in resources {
            guard resource.byteLength <= Self.maximumDeclaredResourceBytes
                    - declaredResourceBytes
            else {
                throw SharePresentationContractError.invalidResource
            }
            declaredResourceBytes += resource.byteLength
        }
        guard compatibility.contains(.safePreviewPresent) == (safePreview != nil),
              compatibility.contains(.norseInteractiveFallback)
        else {
            throw SharePresentationContractError.invalidCompatibilityFlags
        }
        self.version = version
        self.selection = selection
        self.safePreview = safePreview
        self.resources = resources.sorted { lhs, rhs in
            if lhs.resourceID != rhs.resourceID {
                return lhs.resourceID < rhs.resourceID
            }
            return lhs.role < rhs.role
        }
        self.provenance = provenance
        self.compatibility = compatibility
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(UInt16.self, forKey: .version),
            selection: container.decode(SharePresentationSelection.self, forKey: .selection),
            safePreview: container.decodeIfPresent(
                ShareSafePreviewMetadata.self,
                forKey: .safePreview
            ),
            resources: container.decode(
                [SharePresentationResourceMetadata].self,
                forKey: .resources
            ),
            provenance: container.decodeIfPresent(
                ShareProvenanceReference.self,
                forKey: .provenance
            ),
            compatibility: container.decode(
                SharePresentationCompatibilityFlags.self,
                forKey: .compatibility
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case selection
        case safePreview
        case resources
        case provenance
        case compatibility
    }
}

/// A bounded, nonsecret view of one installed Theme provider's presentation
/// surface. It lets receivers validate sender-selected stable IDs and resource
/// integrity without exposing provider objects or importing provider modules.
public struct SharePresentationProviderResourceInventory: Codable, Equatable, Hashable,
    Sendable
{
    public let resourceID: ThemeResourceID
    public let role: ThemeResourceRoleID
    public let mediaType: ThemeResourceMediaType
    public let byteLength: UInt64
    public let pixelSize: ThemePixelSize?
    public let sha256: ThemeSHA256Digest

    public init(
        resourceID: ThemeResourceID,
        role: ThemeResourceRoleID,
        mediaType: ThemeResourceMediaType,
        byteLength: UInt64,
        pixelSize: ThemePixelSize?,
        sha256: ThemeSHA256Digest
    ) throws {
        guard byteLength > 0,
              byteLength <= SharePresentationResourceMetadata.maximumDeclaredByteLength
        else { throw SharePresentationContractError.invalidProviderInventory }
        self.resourceID = resourceID
        self.role = role
        self.mediaType = mediaType
        self.byteLength = byteLength
        self.pixelSize = pixelSize
        self.sha256 = sha256
    }

    public init(reference: ThemeResourceReference) throws {
        try self.init(
            resourceID: reference.id,
            role: reference.role,
            mediaType: reference.mediaType,
            byteLength: reference.integrity.byteLength,
            pixelSize: reference.integrity.pixelSize,
            sha256: reference.integrity.sha256
        )
    }

    public init(metadata: SharePresentationResourceMetadata) throws {
        try self.init(
            resourceID: metadata.resourceID,
            role: metadata.role,
            mediaType: metadata.mediaType,
            byteLength: metadata.byteLength,
            pixelSize: metadata.pixelSize,
            sha256: metadata.sha256
        )
    }

    public func matches(_ metadata: SharePresentationResourceMetadata) -> Bool {
        resourceID == metadata.resourceID
            && role == metadata.role
            && mediaType == metadata.mediaType
            && byteLength == metadata.byteLength
            && pixelSize == metadata.pixelSize
            && sha256 == metadata.sha256
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            resourceID: container.decode(ThemeResourceID.self, forKey: .resourceID),
            role: container.decode(ThemeResourceRoleID.self, forKey: .role),
            mediaType: container.decode(ThemeResourceMediaType.self, forKey: .mediaType),
            byteLength: container.decode(UInt64.self, forKey: .byteLength),
            pixelSize: container.decodeIfPresent(ThemePixelSize.self, forKey: .pixelSize),
            sha256: container.decode(ThemeSHA256Digest.self, forKey: .sha256)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case resourceID
        case role
        case mediaType
        case byteLength
        case pixelSize
        case sha256
    }
}

public struct SharePresentationProviderInventory: Codable, Equatable, Hashable, Sendable {
    public static let maximumScriptCount = 16
    public static let maximumArtifactCount = 128
    public static let maximumResourceCount = 256

    public let codexID: CodexID
    public let scriptIDs: [ScriptID]
    public let relicIDs: [ArtifactID]
    public let sealIDs: [ArtifactID]
    public let frameIDs: [ArtifactID]
    public let resources: [SharePresentationProviderResourceInventory]

    public init(
        codexID: CodexID,
        scriptIDs: [ScriptID],
        relicIDs: [ArtifactID],
        sealIDs: [ArtifactID],
        frameIDs: [ArtifactID],
        resources: [SharePresentationProviderResourceInventory]
    ) throws {
        let artifactIDs = relicIDs + sealIDs + frameIDs
        guard !scriptIDs.isEmpty,
              scriptIDs.count <= Self.maximumScriptCount,
              !relicIDs.isEmpty,
              artifactIDs.count <= Self.maximumArtifactCount,
              resources.count <= Self.maximumResourceCount,
              Set(scriptIDs).count == scriptIDs.count,
              Set(artifactIDs).count == artifactIDs.count,
              Set(resources.map(\.resourceID)).count == resources.count
        else {
            throw SharePresentationContractError.invalidProviderInventory
        }
        var declaredBytes: UInt64 = 0
        for resource in resources {
            guard resource.byteLength
                    <= SharePresentationMetadata.maximumDeclaredResourceBytes - declaredBytes
            else {
                throw SharePresentationContractError.invalidProviderInventory
            }
            declaredBytes += resource.byteLength
        }
        self.codexID = codexID
        self.scriptIDs = scriptIDs.sorted()
        self.relicIDs = relicIDs.sorted()
        self.sealIDs = sealIDs.sorted()
        self.frameIDs = frameIDs.sorted()
        self.resources = resources.sorted { $0.resourceID < $1.resourceID }
    }

    public init(descriptor: ThemeDescriptor) throws {
        try self.init(
            codexID: descriptor.codex.id,
            scriptIDs: descriptor.codex.scripts.map(\.id),
            relicIDs: descriptor.codex.relics.map(\.metadata.id),
            sealIDs: descriptor.codex.seals.map(\.metadata.id),
            frameIDs: descriptor.codex.frames.map(\.metadata.id),
            resources: try descriptor.resources.map(
                SharePresentationProviderResourceInventory.init(reference:)
            )
        )
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            codexID: container.decode(CodexID.self, forKey: .codexID),
            scriptIDs: container.decode([ScriptID].self, forKey: .scriptIDs),
            relicIDs: container.decode([ArtifactID].self, forKey: .relicIDs),
            sealIDs: container.decode([ArtifactID].self, forKey: .sealIDs),
            frameIDs: container.decode([ArtifactID].self, forKey: .frameIDs),
            resources: container.decode(
                [SharePresentationProviderResourceInventory].self,
                forKey: .resources
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case codexID
        case scriptIDs
        case relicIDs
        case sealIDs
        case frameIDs
        case resources
    }
}

/// Shared fail-closed compatibility policy used before Core records an inbound
/// observation and again when UI binds that observation to the live provider
/// inventory.
public enum SharePresentationProviderCompatibilityResolver {
    public static let maximumProviderCount = 64

    public static func resolve(
        metadata: SharePresentationMetadata,
        providerAvailability: ShareProviderAvailability,
        inventories: [SharePresentationProviderInventory]
    ) -> ShareProviderAvailability {
        resolve(
            selection: metadata.selection,
            resources: metadata.resources,
            providerAvailability: providerAvailability,
            inventories: inventories
        )
    }

    public static func resolve(
        selection: SharePresentationSelection,
        resources: [SharePresentationResourceMetadata],
        providerAvailability: ShareProviderAvailability,
        inventories: [SharePresentationProviderInventory]
    ) -> ShareProviderAvailability {
        guard selection.presentationVersion
                == SharePresentationSelection.supportedPresentationVersion
        else { return .incompatible }
        guard providerAvailability == .available else { return providerAvailability }
        guard inventories.count <= maximumProviderCount,
              Set(inventories.map(\.codexID)).count == inventories.count
        else { return .corrupt }
        guard let inventory = inventories.first(where: {
            $0.codexID == selection.codexID
        }) else { return .unknown }
        guard inventory.scriptIDs.contains(selection.scriptID),
              inventory.relicIDs.contains(selection.relicID),
              selection.sealID.map(inventory.sealIDs.contains) ?? true,
              selection.frameID.map(inventory.frameIDs.contains) ?? true
        else { return .incompatible }

        let installedResources = Dictionary(
            uniqueKeysWithValues: inventory.resources.map { ($0.resourceID, $0) }
        )
        for resource in resources {
            guard let installed = installedResources[resource.resourceID] else {
                return .incompatible
            }
            guard installed.matches(resource) else { return .corrupt }
        }
        return .available
    }
}

/// Signed statement bytes are carried separately from display metadata so a
/// missing or invalid verifier can never make message decryption unavailable.
public struct ShareSignedProvenance: Codable, Equatable, Hashable, Sendable {
    public static let schemaVersion: UInt16 = 1
    public static let signatureByteCount = 64

    public let version: UInt16
    public let referenceID: ThemeProvenanceID
    public let signerKeyID: ShareProvenanceSignerID
    public let statementSHA256: ThemeSHA256Digest
    public let presentationSHA256: ThemeSHA256Digest
    public let previewSHA256: ThemeSHA256Digest?
    public let signature: Data

    public init(
        version: UInt16 = Self.schemaVersion,
        referenceID: ThemeProvenanceID,
        signerKeyID: ShareProvenanceSignerID,
        statementSHA256: ThemeSHA256Digest,
        presentationSHA256: ThemeSHA256Digest,
        previewSHA256: ThemeSHA256Digest?,
        signature: Data
    ) throws {
        guard version == Self.schemaVersion else {
            throw SharePresentationContractError.unsupportedSchema(version)
        }
        guard signature.count == Self.signatureByteCount else {
            throw SharePresentationContractError.invalidProvenance
        }
        self.version = version
        self.referenceID = referenceID
        self.signerKeyID = signerKeyID
        self.statementSHA256 = statementSHA256
        self.presentationSHA256 = presentationSHA256
        self.previewSHA256 = previewSHA256
        self.signature = signature
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            version: container.decode(UInt16.self, forKey: .version),
            referenceID: container.decode(ThemeProvenanceID.self, forKey: .referenceID),
            signerKeyID: container.decode(ShareProvenanceSignerID.self, forKey: .signerKeyID),
            statementSHA256: container.decode(ThemeSHA256Digest.self, forKey: .statementSHA256),
            presentationSHA256: container.decode(
                ThemeSHA256Digest.self,
                forKey: .presentationSHA256
            ),
            previewSHA256: container.decodeIfPresent(
                ThemeSHA256Digest.self,
                forKey: .previewSHA256
            ),
            signature: container.decode(Data.self, forKey: .signature)
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case referenceID
        case signerKeyID
        case statementSHA256
        case presentationSHA256
        case previewSHA256
        case signature
    }
}

/// Presentation bytes frozen for one outbound share operation. Core performs
/// the canonical hash and image checks again before writing a package; this
/// boundary rejects incoherent section presence and unbounded preview data.
public struct OutboundSharePresentationDTO: Codable, Equatable, Sendable {
    public let metadata: SharePresentationMetadata
    public let safePreviewData: Data?
    public let signedProvenance: ShareSignedProvenance?

    public init(
        metadata: SharePresentationMetadata,
        safePreviewData: Data? = nil,
        signedProvenance: ShareSignedProvenance? = nil
    ) throws {
        guard metadata.safePreview.map({ descriptor in
            guard let safePreviewData else { return false }
            return safePreviewData.count == Int(descriptor.byteLength)
                && safePreviewData.count <= Int(
                    ShareSafePreviewMetadata.maximumByteLength
                )
        }) ?? (safePreviewData == nil)
        else {
            throw SharePresentationContractError.invalidSafePreview
        }
        if let signedProvenance {
            guard let reference = metadata.provenance,
                  signedProvenance.referenceID == reference.referenceID,
                  signedProvenance.signerKeyID == reference.signerKeyID,
                  signedProvenance.statementSHA256 == reference.statementSHA256,
                  signedProvenance.previewSHA256 == metadata.safePreview?.sha256
            else {
                throw SharePresentationContractError.invalidProvenance
            }
        }
        self.metadata = metadata
        self.safePreviewData = safePreviewData
        self.signedProvenance = signedProvenance
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(SharePresentationMetadata.self, forKey: .metadata),
            safePreviewData: container.decodeIfPresent(Data.self, forKey: .safePreviewData),
            signedProvenance: container.decodeIfPresent(
                ShareSignedProvenance.self,
                forKey: .signedProvenance
            )
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata
        case safePreviewData
        case signedProvenance
    }
}

public enum ShareProviderAvailability: String, Codable, CaseIterable, Sendable {
    case available
    case locked
    case unknown
    case unavailable
    case incompatible
    case corrupt
    case notInstalled = "not-installed"
}

public enum ShareSafePreviewStatus: String, Codable, CaseIterable, Sendable {
    case absent
    case valid
    case invalid
}

public enum ReceivedShareRenderMode: String, Codable, CaseIterable, Sendable {
    case requestedCodex = "requested-codex"
    case norseInteractiveFallback = "norse-interactive-fallback"
}

public enum ShareEncounterRecordingStatus: String, Codable, CaseIterable, Sendable {
    case recorded
    case unavailable
}

public struct ReceivedSharePresentation: Codable, Equatable, Hashable, Sendable {
    public let requestedSelection: SharePresentationSelection
    public let effectiveCodexID: CodexID
    public let providerAvailability: ShareProviderAvailability
    public let renderMode: ReceivedShareRenderMode
    public let safePreviewStatus: ShareSafePreviewStatus
    public let provenanceStatus: ShareProvenanceVerificationStatus
    public let encounterRecordingStatus: ShareEncounterRecordingStatus
    public let resourceMetadata: [SharePresentationResourceMetadata]

    public init(
        requestedSelection: SharePresentationSelection,
        effectiveCodexID: CodexID,
        providerAvailability: ShareProviderAvailability,
        renderMode: ReceivedShareRenderMode,
        safePreviewStatus: ShareSafePreviewStatus,
        provenanceStatus: ShareProvenanceVerificationStatus,
        encounterRecordingStatus: ShareEncounterRecordingStatus = .unavailable,
        resourceMetadata: [SharePresentationResourceMetadata] = []
    ) throws {
        guard resourceMetadata.count <= SharePresentationMetadata.maximumResourceCount,
              Set(resourceMetadata.map(\.resourceID)).count == resourceMetadata.count
        else { throw SharePresentationContractError.invalidObservation }
        switch renderMode {
        case .requestedCodex:
            guard providerAvailability == .available,
                  effectiveCodexID == requestedSelection.codexID
            else { throw SharePresentationContractError.invalidObservation }
        case .norseInteractiveFallback:
            guard providerAvailability != .available,
                  effectiveCodexID == RuneScribeCodexIDs.norse
            else { throw SharePresentationContractError.invalidObservation }
        }
        self.requestedSelection = requestedSelection
        self.effectiveCodexID = effectiveCodexID
        self.providerAvailability = providerAvailability
        self.renderMode = renderMode
        self.safePreviewStatus = safePreviewStatus
        self.provenanceStatus = provenanceStatus
        self.encounterRecordingStatus = encounterRecordingStatus
        self.resourceMetadata = resourceMetadata.sorted { $0.resourceID < $1.resourceID }
    }

    public init(from decoder: Decoder) throws {
        try sharePresentationRejectUnknownKeys(from: decoder, allowedBy: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            requestedSelection: container.decode(
                SharePresentationSelection.self,
                forKey: .requestedSelection
            ),
            effectiveCodexID: container.decode(CodexID.self, forKey: .effectiveCodexID),
            providerAvailability: container.decode(
                ShareProviderAvailability.self,
                forKey: .providerAvailability
            ),
            renderMode: container.decode(ReceivedShareRenderMode.self, forKey: .renderMode),
            safePreviewStatus: container.decode(
                ShareSafePreviewStatus.self,
                forKey: .safePreviewStatus
            ),
            provenanceStatus: container.decode(
                ShareProvenanceVerificationStatus.self,
                forKey: .provenanceStatus
            ),
            encounterRecordingStatus: container.decodeIfPresent(
                ShareEncounterRecordingStatus.self,
                forKey: .encounterRecordingStatus
            ) ?? .unavailable,
            resourceMetadata: container.decodeIfPresent(
                [SharePresentationResourceMetadata].self,
                forKey: .resourceMetadata
            ) ?? []
        )
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case requestedSelection
        case effectiveCodexID
        case providerAvailability
        case renderMode
        case safePreviewStatus
        case provenanceStatus
        case encounterRecordingStatus
        case resourceMetadata
    }
}
