import Foundation

public enum ThemeIdentifierDomain: Sendable {}
public enum ThemeModuleIdentifierDomain: Sendable {}
public enum ThemeModuleRoleIdentifierDomain: Sendable {}
public enum ThemePolicyClassIdentifierDomain: Sendable {}
public enum ThemeResourceIdentifierDomain: Sendable {}
public enum ThemeResourceRoleIdentifierDomain: Sendable {}
public enum ThemeGlyphIdentifierDomain: Sendable {}
public enum ThemeFontReferenceIdentifierDomain: Sendable {}
public enum ThemeLayoutPresetIdentifierDomain: Sendable {}
public enum ThemeBackgroundIdentifierDomain: Sendable {}
public enum ThemeVaultIdentifierDomain: Sendable {}
public enum ThemeProvenanceIdentifierDomain: Sendable {}
public enum ThemeLocalizationKeyDomain: Sendable {}

public typealias ThemeID = RoadmapStringIdentifier<ThemeIdentifierDomain>
public typealias ThemeModuleID = RoadmapStringIdentifier<ThemeModuleIdentifierDomain>
public typealias ThemeModuleRoleID = RoadmapStringIdentifier<ThemeModuleRoleIdentifierDomain>
public typealias ThemePolicyClassID = RoadmapStringIdentifier<ThemePolicyClassIdentifierDomain>
public typealias ThemeResourceID = RoadmapStringIdentifier<ThemeResourceIdentifierDomain>
public typealias ThemeResourceRoleID = RoadmapStringIdentifier<ThemeResourceRoleIdentifierDomain>
public typealias ThemeGlyphID = RoadmapStringIdentifier<ThemeGlyphIdentifierDomain>
public typealias ThemeFontReferenceID =
    RoadmapStringIdentifier<ThemeFontReferenceIdentifierDomain>
public typealias ThemeLayoutPresetID = RoadmapStringIdentifier<ThemeLayoutPresetIdentifierDomain>
public typealias ThemeBackgroundID = RoadmapStringIdentifier<ThemeBackgroundIdentifierDomain>
public typealias ThemeVaultID = RoadmapStringIdentifier<ThemeVaultIdentifierDomain>
public typealias ThemeProvenanceID = RoadmapStringIdentifier<ThemeProvenanceIdentifierDomain>
public typealias ThemeLocalizationKey = RoadmapStringIdentifier<ThemeLocalizationKeyDomain>

public enum ThemeDescriptorValidationError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion
    case invalidValue(String)
    case duplicateIdentifier(String)
    case invalidScriptSymbolCount(String)
    case invalidScriptMapping(String)
    case missingDefaultRelic
    case missingFallback(String)
    case missingAccessibility(String)
    case unknownResource(String)
    case unknownReference(String)
    case resourceRequirementMismatch(String)
    case resourceSemanticMismatch(String)
}

public enum ThemeCanonicalSymbolSet {
    public static let symbolCount = 32
    public static let transportTokens: [String] = (0 ..< symbolCount).map {
        String(UnicodeScalar(0x16A0 + $0)!)
    }
}

public struct ThemeFontPostScriptName: RawRepresentable, Codable, Hashable, Sendable {
    public static let maximumUTF8Count = 127

    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty,
              bytes.count <= Self.maximumUTF8Count,
              bytes.allSatisfy({
                  (0x30 ... 0x39).contains($0)
                      || (0x41 ... 0x5A).contains($0)
                      || (0x61 ... 0x7A).contains($0)
                      || $0 == 0x2D
              })
        else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let name = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid font name.")
            )
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct ThemeContractVersion: Codable, Hashable, Sendable, Comparable {
    public let major: UInt16
    public let minor: UInt16

    public static let current = ThemeContractVersion(uncheckedMajor: 1, minor: 0)

    public init(major: UInt16, minor: UInt16) throws {
        guard major > 0 else {
            throw ThemeDescriptorValidationError.invalidValue("contract-version")
        }
        self.major = major
        self.minor = minor
    }

    private init(uncheckedMajor major: UInt16, minor: UInt16) {
        self.major = major
        self.minor = minor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                major: container.decode(UInt16.self, forKey: .major),
                minor: container.decode(UInt16.self, forKey: .minor)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid contract version.")
            )
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public enum ThemePlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case iOS
    case macOS
}

public struct ThemePlatformCompatibility: Codable, Hashable, Sendable {
    public let platform: ThemePlatform
    public let minimumMajorVersion: UInt16
    public let minimumMinorVersion: UInt16
    public let minimumPatchVersion: UInt16

    public init(
        platform: ThemePlatform,
        minimumMajorVersion: UInt16,
        minimumMinorVersion: UInt16 = 0,
        minimumPatchVersion: UInt16 = 0
    ) throws {
        guard minimumMajorVersion > 0 else {
            throw ThemeDescriptorValidationError.invalidValue("minimum-platform-version")
        }
        self.platform = platform
        self.minimumMajorVersion = minimumMajorVersion
        self.minimumMinorVersion = minimumMinorVersion
        self.minimumPatchVersion = minimumPatchVersion
    }

    fileprivate func validate() throws {
        guard minimumMajorVersion > 0 else {
            throw ThemeDescriptorValidationError.invalidValue("minimum-platform-version")
        }
    }
}

public enum ThemeCriticality: String, Codable, Hashable, Sendable {
    case requiredBase
    case optional
}

public enum ThemeRarityToken: String, Codable, CaseIterable, Hashable, Sendable {
    case forged
    case inscribed
    case rare
    case mythic
}

public enum ThemeContentStateToken: String, Codable, CaseIterable, Hashable, Sendable {
    case locked
    case encountered
    case unavailable
    case owned
    case selected
}

public enum ThemeArtifactAvailability: String, Codable, Hashable, Sendable {
    case included
    case earned
    case encountered
    case mastery
}

public struct ThemeSemanticColor: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 7 || bytes.count == 9,
              bytes.first == 0x23,
              bytes.dropFirst().allSatisfy(Self.isASCIIHexDigit)
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let color = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid semantic color.")
            )
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x46).contains(byte)
            || (0x61 ... 0x66).contains(byte)
    }
}

public struct ThemeRarityAccent: Codable, Hashable, Sendable {
    public let rarity: ThemeRarityToken
    public let color: ThemeSemanticColor

    public init(rarity: ThemeRarityToken, color: ThemeSemanticColor) {
        self.rarity = rarity
        self.color = color
    }
}

public struct ThemeSemanticPalette: Codable, Hashable, Sendable {
    public let backgroundPrimary: ThemeSemanticColor
    public let backgroundSecondary: ThemeSemanticColor
    public let surfacePrimary: ThemeSemanticColor
    public let surfaceElevated: ThemeSemanticColor
    public let textPrimary: ThemeSemanticColor
    public let textSecondary: ThemeSemanticColor
    public let textInverse: ThemeSemanticColor
    public let accentPrimary: ThemeSemanticColor
    public let accentSecondary: ThemeSemanticColor
    public let success: ThemeSemanticColor
    public let warning: ThemeSemanticColor
    public let danger: ThemeSemanticColor
    public let information: ThemeSemanticColor
    public let locked: ThemeSemanticColor
    public let encountered: ThemeSemanticColor
    public let unavailable: ThemeSemanticColor
    public let selected: ThemeSemanticColor
    public let focus: ThemeSemanticColor
    public let keyboardFocus: ThemeSemanticColor
    public let rarityAccents: [ThemeRarityAccent]

    public init(
        backgroundPrimary: ThemeSemanticColor,
        backgroundSecondary: ThemeSemanticColor,
        surfacePrimary: ThemeSemanticColor,
        surfaceElevated: ThemeSemanticColor,
        textPrimary: ThemeSemanticColor,
        textSecondary: ThemeSemanticColor,
        textInverse: ThemeSemanticColor,
        accentPrimary: ThemeSemanticColor,
        accentSecondary: ThemeSemanticColor,
        success: ThemeSemanticColor,
        warning: ThemeSemanticColor,
        danger: ThemeSemanticColor,
        information: ThemeSemanticColor,
        locked: ThemeSemanticColor,
        encountered: ThemeSemanticColor,
        unavailable: ThemeSemanticColor,
        selected: ThemeSemanticColor,
        focus: ThemeSemanticColor,
        keyboardFocus: ThemeSemanticColor,
        rarityAccents: [ThemeRarityAccent]
    ) throws {
        self.backgroundPrimary = backgroundPrimary
        self.backgroundSecondary = backgroundSecondary
        self.surfacePrimary = surfacePrimary
        self.surfaceElevated = surfaceElevated
        self.textPrimary = textPrimary
        self.textSecondary = textSecondary
        self.textInverse = textInverse
        self.accentPrimary = accentPrimary
        self.accentSecondary = accentSecondary
        self.success = success
        self.warning = warning
        self.danger = danger
        self.information = information
        self.locked = locked
        self.encountered = encountered
        self.unavailable = unavailable
        self.selected = selected
        self.focus = focus
        self.keyboardFocus = keyboardFocus
        self.rarityAccents = rarityAccents
        try validate()
    }

    fileprivate func validate() throws {
        let rarities = rarityAccents.map(\.rarity)
        let textSurfaces = [
            backgroundPrimary,
            backgroundSecondary,
            surfacePrimary,
            surfaceElevated,
        ]
        guard Set(rarities).count == rarities.count,
              Set(rarities) == Set(ThemeRarityToken.allCases),
              textSurfaces.allSatisfy({ contrastRatio(textPrimary, $0) >= 4.5 }),
              textSurfaces.allSatisfy({ contrastRatio(textSecondary, $0) >= 4.5 }),
              contrastRatio(textInverse, accentPrimary) >= 4.5,
              contrastRatio(selected, backgroundPrimary) >= 3,
              contrastRatio(focus, backgroundPrimary) >= 3,
              contrastRatio(keyboardFocus, backgroundPrimary) >= 3
        else {
            throw ThemeDescriptorValidationError.invalidValue("semantic-palette")
        }
    }
}

private func contrastRatio(
    _ first: ThemeSemanticColor,
    _ second: ThemeSemanticColor
) -> Double {
    guard let firstLuminance = relativeLuminance(first),
          let secondLuminance = relativeLuminance(second)
    else { return 0 }
    let lighter = max(firstLuminance, secondLuminance)
    let darker = min(firstLuminance, secondLuminance)
    return (lighter + 0.05) / (darker + 0.05)
}

private func relativeLuminance(_ color: ThemeSemanticColor) -> Double? {
    let digits = String(color.rawValue.dropFirst())
    guard digits.count == 6 || digits.uppercased().hasSuffix("FF") else { return nil }
    let rgb = String(digits.prefix(6))
    var components: [Double] = []
    var index = rgb.startIndex
    for _ in 0 ..< 3 {
        let next = rgb.index(index, offsetBy: 2)
        guard let byte = UInt8(rgb[index ..< next], radix: 16) else { return nil }
        let value = Double(byte) / 255
        components.append(
            value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4)
        )
        index = next
    }
    return 0.2126 * components[0]
        + 0.7152 * components[1]
        + 0.0722 * components[2]
}

public struct ThemeLocalizedText: Codable, Hashable, Sendable {
    public let key: ThemeLocalizationKey
    public let fallbackValue: String

    public init(key: ThemeLocalizationKey, fallbackValue: String) throws {
        let fallbackValue = fallbackValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackValue.isEmpty, fallbackValue.utf8.count <= 512 else {
            throw ThemeDescriptorValidationError.invalidValue("localized-fallback")
        }
        self.key = key
        self.fallbackValue = fallbackValue
    }

    fileprivate func validate() throws {
        guard !fallbackValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              fallbackValue.utf8.count <= 512
        else {
            throw ThemeDescriptorValidationError.invalidValue("localized-fallback")
        }
    }
}

public struct ThemeAccessibilityMetadata: Codable, Hashable, Sendable {
    public let label: ThemeLocalizedText
    public let hint: ThemeLocalizedText?
    public let hidesRedundantGlyphs: Bool
    public let noColorOnlyState: Bool
    public let dynamicTypeSafe: Bool

    public init(
        label: ThemeLocalizedText,
        hint: ThemeLocalizedText? = nil,
        hidesRedundantGlyphs: Bool = false,
        noColorOnlyState: Bool = true,
        dynamicTypeSafe: Bool = true
    ) throws {
        self.label = label
        self.hint = hint
        self.hidesRedundantGlyphs = hidesRedundantGlyphs
        self.noColorOnlyState = noColorOnlyState
        self.dynamicTypeSafe = dynamicTypeSafe
        try validate()
    }

    fileprivate func validate() throws {
        do {
            try label.validate()
            try hint?.validate()
        } catch {
            throw ThemeDescriptorValidationError.missingAccessibility(label.key.rawValue)
        }
        guard noColorOnlyState, dynamicTypeSafe else {
            throw ThemeDescriptorValidationError.missingAccessibility(label.key.rawValue)
        }
    }
}

public enum ThemeRightsOrigin: String, Codable, Hashable, Sendable {
    case original
    case derived
}

public struct ThemeRightsMetadata: Codable, Hashable, Sendable {
    public let id: ThemeProvenanceID
    public let creatorTool: String
    public let creationDate: String
    public let origin: ThemeRightsOrigin
    public let rightsOwner: String
    public let sourceReference: String
    public let exportSettings: String
    public let licenseNotice: String

    public init(
        id: ThemeProvenanceID,
        creatorTool: String,
        creationDate: String,
        origin: ThemeRightsOrigin,
        rightsOwner: String,
        sourceReference: String,
        exportSettings: String,
        licenseNotice: String
    ) throws {
        let fields = [
            creatorTool,
            creationDate,
            rightsOwner,
            sourceReference,
            exportSettings,
            licenseNotice,
        ]
        guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              creationDate.utf8.count == 10
        else {
            throw ThemeDescriptorValidationError.invalidValue("rights-metadata")
        }
        self.id = id
        self.creatorTool = creatorTool
        self.creationDate = creationDate
        self.origin = origin
        self.rightsOwner = rightsOwner
        self.sourceReference = sourceReference
        self.exportSettings = exportSettings
        self.licenseNotice = licenseNotice
    }

    fileprivate func validate() throws {
        _ = try Self(
            id: id,
            creatorTool: creatorTool,
            creationDate: creationDate,
            origin: origin,
            rightsOwner: rightsOwner,
            sourceReference: sourceReference,
            exportSettings: exportSettings,
            licenseNotice: licenseNotice
        )
    }
}

public struct ThemeSHA256Digest: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        let bytes = Array(rawValue.utf8)
        guard bytes.count == 64,
              bytes.allSatisfy({ (0x30 ... 0x39).contains($0) || (0x61 ... 0x66).contains($0) })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard let digest = Self(rawValue: value) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid SHA-256 digest.")
            )
        }
        self = digest
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ThemeResourceMediaType: String, Codable, Hashable, Sendable {
    case json = "application/json"
    case png = "image/png"
    case heif = "image/heif"
    case pdf = "application/pdf"
    case ttf = "font/ttf"
    case otf = "font/otf"
    case mp4 = "video/mp4"
    case quickTime = "video/quicktime"
    case m4a = "audio/mp4"
    case caf = "audio/x-caf"
    case wav = "audio/wav"
}

public enum ThemeResourceRoles {
    public static let scriptFont = make("script.font")
    public static let scriptStaticFallback = make("script.static-fallback")
    public static let scriptGlyphVector = make("script.glyph-vector")
    public static let relicMaster = make("relic.master")
    public static let relicThumbnail = make("relic.thumbnail")
    public static let relicStaticShareFallback = make("relic.static-share-fallback")
    public static let relicHighContrast = make("relic.high-contrast")
    public static let sealVectorMaster = make("seal.vector-master")
    public static let sealMonochromeFallback = make("seal.monochrome-fallback")
    public static let sealThumbnail = make("seal.thumbnail")
    public static let frameVectorMaster = make("frame.vector-master")
    public static let frameStaticFallback = make("frame.static-fallback")
    public static let crestVectorMaster = make("crest.vector-master")
    public static let crestStaticFallback = make("crest.static-fallback")
    public static let backgroundStaticBase = make("background.static-base")
    public static let backgroundReduceMotion = make("background.reduce-motion")
    public static let backgroundHighContrast = make("background.high-contrast")
    public static let backgroundMotion = make("background.motion")
    public static let backgroundRendererParameters = make("background.parameters")
    public static let vaultCard = make("vault.card")
    public static let vaultLockedSilhouette = make("vault.locked-silhouette")
    public static let vaultEncountered = make("vault.encountered")
    public static let vaultSelected = make("vault.selected")
    public static let localizationStrings = make("localization.strings")

    private static func make(_ rawValue: String) -> ThemeResourceRoleID {
        ThemeResourceRoleID(rawValue: rawValue)!
    }
}

public enum ThemeResourceRequirement: String, Codable, Hashable, Sendable {
    case required
    case optional
}

public struct ThemePixelSize: Codable, Hashable, Sendable {
    public let width: UInt32
    public let height: UInt32

    public init(width: UInt32, height: UInt32) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096 else {
            throw ThemeDescriptorValidationError.invalidValue("pixel-size")
        }
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            width: container.decode(UInt32.self, forKey: .width),
            height: container.decode(UInt32.self, forKey: .height)
        )
    }
}

public struct ThemeResourceIntegrity: Codable, Hashable, Sendable {
    public let sha256: ThemeSHA256Digest
    public let byteLength: UInt64
    public let pixelSize: ThemePixelSize?

    public init(
        sha256: ThemeSHA256Digest,
        byteLength: UInt64,
        pixelSize: ThemePixelSize? = nil
    ) throws {
        guard byteLength > 0, byteLength <= 67_108_864 else {
            throw ThemeDescriptorValidationError.invalidValue("resource-byte-length")
        }
        self.sha256 = sha256
        self.byteLength = byteLength
        self.pixelSize = pixelSize
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sha256: container.decode(ThemeSHA256Digest.self, forKey: .sha256),
            byteLength: container.decode(UInt64.self, forKey: .byteLength),
            pixelSize: container.decodeIfPresent(
                ThemePixelSize.self,
                forKey: .pixelSize
            )
        )
    }

    fileprivate func validate() throws {
        guard byteLength > 0, byteLength <= 67_108_864 else {
            throw ThemeDescriptorValidationError.invalidValue("resource-byte-length")
        }
        if let pixelSize {
            _ = try ThemePixelSize(width: pixelSize.width, height: pixelSize.height)
        }
    }
}

public struct ThemeResourceReference: Codable, Hashable, Sendable {
    public let id: ThemeResourceID
    public let role: ThemeResourceRoleID
    public let mediaType: ThemeResourceMediaType
    public let requirement: ThemeResourceRequirement
    public let integrity: ThemeResourceIntegrity
    public let rightsID: ThemeProvenanceID

    public init(
        id: ThemeResourceID,
        role: ThemeResourceRoleID,
        mediaType: ThemeResourceMediaType,
        requirement: ThemeResourceRequirement,
        integrity: ThemeResourceIntegrity,
        rightsID: ThemeProvenanceID
    ) throws {
        self.id = id
        self.role = role
        self.mediaType = mediaType
        self.requirement = requirement
        self.integrity = integrity
        self.rightsID = rightsID
        try integrity.validate()
    }

    fileprivate func validate() throws {
        try integrity.validate()
    }
}

public enum ThemeScriptPortability: String, Codable, Hashable, Sendable {
    case unicodePortable
    case fontDependent
    case vectorRendered
}

public struct ThemeScalarRange: Codable, Hashable, Sendable {
    public let minimum: Double
    public let maximum: Double

    public init(minimum: Double, maximum: Double) throws {
        guard minimum.isFinite,
              maximum.isFinite,
              minimum > 0,
              maximum >= minimum
        else {
            throw ThemeDescriptorValidationError.invalidValue("scalar-range")
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    fileprivate func validate() throws {
        _ = try Self(minimum: minimum, maximum: maximum)
    }
}

public struct ThemeScriptGlyph: Codable, Hashable, Sendable {
    public let canonicalValue: UInt8
    public let glyphID: ThemeGlyphID
    public let textToken: String
    public let vectorResourceID: ThemeResourceID?

    public init(
        canonicalValue: UInt8,
        glyphID: ThemeGlyphID,
        textToken: String,
        vectorResourceID: ThemeResourceID? = nil
    ) throws {
        guard canonicalValue < 32,
              !textToken.isEmpty,
              textToken.utf8.count <= 16
        else {
            throw ThemeDescriptorValidationError.invalidScriptMapping(glyphID.rawValue)
        }
        self.canonicalValue = canonicalValue
        self.glyphID = glyphID
        self.textToken = textToken
        self.vectorResourceID = vectorResourceID
    }

    fileprivate func validate() throws {
        _ = try Self(
            canonicalValue: canonicalValue,
            glyphID: glyphID,
            textToken: textToken,
            vectorResourceID: vectorResourceID
        )
    }
}

public struct ThemeScriptDescriptor: Codable, Hashable, Sendable {
    public let id: ScriptID
    public let displayName: ThemeLocalizedText
    public let portability: ThemeScriptPortability
    public let glyphs: [ThemeScriptGlyph]
    public let fontResourceID: ThemeResourceID?
    public let fontReferenceID: ThemeFontReferenceID?
    public let fontVersion: UInt32?
    public let fontPostScriptName: ThemeFontPostScriptName?
    public let staticFallbackResourceID: ThemeResourceID
    public let fallbackScriptID: ScriptID
    public let recommendedPointSizes: ThemeScalarRange
    public let accessibility: ThemeAccessibilityMetadata
    public let rightsID: ThemeProvenanceID

    public init(
        id: ScriptID,
        displayName: ThemeLocalizedText,
        portability: ThemeScriptPortability,
        glyphs: [ThemeScriptGlyph],
        fontResourceID: ThemeResourceID?,
        fontReferenceID: ThemeFontReferenceID?,
        fontVersion: UInt32?,
        fontPostScriptName: ThemeFontPostScriptName?,
        staticFallbackResourceID: ThemeResourceID,
        fallbackScriptID: ScriptID,
        recommendedPointSizes: ThemeScalarRange,
        accessibility: ThemeAccessibilityMetadata,
        rightsID: ThemeProvenanceID
    ) throws {
        self.id = id
        self.displayName = displayName
        self.portability = portability
        self.glyphs = glyphs
        self.fontResourceID = fontResourceID
        self.fontReferenceID = fontReferenceID
        self.fontVersion = fontVersion
        self.fontPostScriptName = fontPostScriptName
        self.staticFallbackResourceID = staticFallbackResourceID
        self.fallbackScriptID = fallbackScriptID
        self.recommendedPointSizes = recommendedPointSizes
        self.accessibility = accessibility
        self.rightsID = rightsID
        try validate()
    }

    fileprivate func validate() throws {
        guard glyphs.count == 32 else {
            throw ThemeDescriptorValidationError.invalidScriptSymbolCount(id.rawValue)
        }
        try displayName.validate()
        try accessibility.validate()
        try recommendedPointSizes.validate()
        try glyphs.forEach { try $0.validate() }
        let values = glyphs.map(\.canonicalValue)
        let glyphIDs = glyphs.map(\.glyphID)
        let textTokens = glyphs.map(\.textToken)
        guard values == (0 ..< 32).map(UInt8.init),
              Set(glyphIDs).count == glyphIDs.count,
              textTokens == ThemeCanonicalSymbolSet.transportTokens
        else {
            throw ThemeDescriptorValidationError.invalidScriptMapping(id.rawValue)
        }
        let fontIdentityIsComplete = fontResourceID != nil
            && fontReferenceID != nil
            && fontVersion != nil
            && fontVersion != 0
            && fontPostScriptName != nil
            && (fontReferenceID?.rawValue.utf8.count ?? 0) <= 16
        let fontIdentityIsAbsent = fontResourceID == nil
            && fontReferenceID == nil
            && fontVersion == nil
            && fontPostScriptName == nil
        guard fontIdentityIsComplete || fontIdentityIsAbsent else {
            throw ThemeDescriptorValidationError.invalidValue("font-identity:\(id.rawValue)")
        }
        if portability == .fontDependent, !fontIdentityIsComplete {
            throw ThemeDescriptorValidationError.missingFallback("font:\(id.rawValue)")
        }
        if portability == .vectorRendered, glyphs.contains(where: { $0.vectorResourceID == nil }) {
            throw ThemeDescriptorValidationError.missingFallback("vector-glyph:\(id.rawValue)")
        }
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        var result = Set([staticFallbackResourceID])
        if let fontResourceID { result.insert(fontResourceID) }
        result.formUnion(glyphs.compactMap(\.vectorResourceID))
        return result
    }
}

public struct ThemeNormalizedRegion: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              x >= 0,
              y >= 0,
              width > 0,
              height > 0,
              x + width <= 1,
              y + height <= 1
        else {
            throw ThemeDescriptorValidationError.invalidValue("normalized-region")
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ other: Self) -> Bool {
        other.x >= x
            && other.y >= y
            && other.x + other.width <= x + width
            && other.y + other.height <= y + height
    }

    public func contains(_ point: ThemeNormalizedPoint) -> Bool {
        point.x >= x
            && point.y >= y
            && point.x <= x + width
            && point.y <= y + height
    }

    fileprivate func validate() throws {
        _ = try Self(x: x, y: y, width: width, height: height)
    }
}

public struct ThemeNormalizedPoint: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite, (0 ... 1).contains(x), (0 ... 1).contains(y) else {
            throw ThemeDescriptorValidationError.invalidValue("normalized-point")
        }
        self.x = x
        self.y = y
    }

    fileprivate func validate() throws {
        _ = try Self(x: x, y: y)
    }
}

public enum ThemeSealAnchorCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case lowerLeft
    case lowerRight
    case bottomCenter
    case topCenter
}

public struct ThemeSealAnchor: Codable, Hashable, Sendable {
    public let category: ThemeSealAnchorCategory
    public let point: ThemeNormalizedPoint

    public init(category: ThemeSealAnchorCategory, point: ThemeNormalizedPoint) {
        self.category = category
        self.point = point
    }
}

public struct ThemeAspectRatio: Codable, Hashable, Sendable {
    public let width: UInt16
    public let height: UInt16

    public init(width: UInt16, height: UInt16) throws {
        guard width > 0, height > 0 else {
            throw ThemeDescriptorValidationError.invalidValue("aspect-ratio")
        }
        self.width = width
        self.height = height
    }

    fileprivate func validate() throws {
        _ = try Self(width: width, height: height)
    }
}

public enum ThemeLayoutOverflowBehavior: String, Codable, Hashable, Sendable {
    case paginate
    case standardAlternate
}

public struct ThemeShareLayoutPreset: Codable, Hashable, Sendable {
    public let id: ThemeLayoutPresetID
    public let aspectRatio: ThemeAspectRatio
    public let relicBounds: ThemeNormalizedRegion
    public let contentSafeRegion: ThemeNormalizedRegion
    public let glyphSafeRegion: ThemeNormalizedRegion
    public let sealAnchors: [ThemeSealAnchor]
    public let maximumGlyphLines: UInt8
    public let minimumGlyphScale: Double
    public let overflowBehavior: ThemeLayoutOverflowBehavior
    public let attributionRegion: ThemeNormalizedRegion
    public let provenanceRegion: ThemeNormalizedRegion?
    public let serialNumberRegion: ThemeNormalizedRegion?
    public let qrSafeRegion: ThemeNormalizedRegion?
    public let thumbnailCrop: ThemeNormalizedRegion

    public init(
        id: ThemeLayoutPresetID,
        aspectRatio: ThemeAspectRatio,
        relicBounds: ThemeNormalizedRegion,
        contentSafeRegion: ThemeNormalizedRegion,
        glyphSafeRegion: ThemeNormalizedRegion,
        sealAnchors: [ThemeSealAnchor],
        maximumGlyphLines: UInt8,
        minimumGlyphScale: Double,
        overflowBehavior: ThemeLayoutOverflowBehavior,
        attributionRegion: ThemeNormalizedRegion,
        provenanceRegion: ThemeNormalizedRegion? = nil,
        serialNumberRegion: ThemeNormalizedRegion? = nil,
        qrSafeRegion: ThemeNormalizedRegion? = nil,
        thumbnailCrop: ThemeNormalizedRegion
    ) throws {
        self.id = id
        self.aspectRatio = aspectRatio
        self.relicBounds = relicBounds
        self.contentSafeRegion = contentSafeRegion
        self.glyphSafeRegion = glyphSafeRegion
        self.sealAnchors = sealAnchors
        self.maximumGlyphLines = maximumGlyphLines
        self.minimumGlyphScale = minimumGlyphScale
        self.overflowBehavior = overflowBehavior
        self.attributionRegion = attributionRegion
        self.provenanceRegion = provenanceRegion
        self.serialNumberRegion = serialNumberRegion
        self.qrSafeRegion = qrSafeRegion
        self.thumbnailCrop = thumbnailCrop
        try validate()
    }

    fileprivate func validate() throws {
        try aspectRatio.validate()
        try relicBounds.validate()
        try contentSafeRegion.validate()
        try glyphSafeRegion.validate()
        try attributionRegion.validate()
        try provenanceRegion?.validate()
        try serialNumberRegion?.validate()
        try qrSafeRegion?.validate()
        try thumbnailCrop.validate()
        try sealAnchors.forEach { try $0.point.validate() }
        let categories = sealAnchors.map(\.category)
        guard maximumGlyphLines > 0,
              maximumGlyphLines <= 32,
              minimumGlyphScale.isFinite,
              minimumGlyphScale > 0,
              minimumGlyphScale <= 1,
              relicBounds.contains(contentSafeRegion),
              contentSafeRegion.contains(glyphSafeRegion),
              sealAnchors.allSatisfy({ relicBounds.contains($0.point) }),
              !sealAnchors.contains(where: { glyphSafeRegion.contains($0.point) }),
              Set(categories).count == categories.count
        else {
            throw ThemeDescriptorValidationError.invalidValue("share-layout:\(id.rawValue)")
        }
    }
}

public struct ThemeArtifactMetadata: Codable, Hashable, Sendable {
    public let id: ArtifactID
    public let codexID: CodexID
    public let displayName: ThemeLocalizedText
    public let description: ThemeLocalizedText
    public let rarity: ThemeRarityToken
    public let availability: ThemeArtifactAvailability
    public let accessibility: ThemeAccessibilityMetadata
    public let rightsID: ThemeProvenanceID

    public init(
        id: ArtifactID,
        codexID: CodexID,
        displayName: ThemeLocalizedText,
        description: ThemeLocalizedText,
        rarity: ThemeRarityToken,
        availability: ThemeArtifactAvailability,
        accessibility: ThemeAccessibilityMetadata,
        rightsID: ThemeProvenanceID
    ) throws {
        self.id = id
        self.codexID = codexID
        self.displayName = displayName
        self.description = description
        self.rarity = rarity
        self.availability = availability
        self.accessibility = accessibility
        self.rightsID = rightsID
        try validate()
    }

    fileprivate func validate() throws {
        try displayName.validate()
        try description.validate()
        try accessibility.validate()
    }
}

public struct ThemeRelicDescriptor: Codable, Hashable, Sendable {
    public let metadata: ThemeArtifactMetadata
    public let isDefault: Bool
    public let primaryResourceID: ThemeResourceID
    public let thumbnailResourceID: ThemeResourceID
    public let staticFallbackResourceID: ThemeResourceID
    public let highContrastResourceID: ThemeResourceID
    public let defaultLayoutID: ThemeLayoutPresetID
    public let layouts: [ThemeShareLayoutPreset]

    public init(
        metadata: ThemeArtifactMetadata,
        isDefault: Bool,
        primaryResourceID: ThemeResourceID,
        thumbnailResourceID: ThemeResourceID,
        staticFallbackResourceID: ThemeResourceID,
        highContrastResourceID: ThemeResourceID,
        defaultLayoutID: ThemeLayoutPresetID,
        layouts: [ThemeShareLayoutPreset]
    ) throws {
        self.metadata = metadata
        self.isDefault = isDefault
        self.primaryResourceID = primaryResourceID
        self.thumbnailResourceID = thumbnailResourceID
        self.staticFallbackResourceID = staticFallbackResourceID
        self.highContrastResourceID = highContrastResourceID
        self.defaultLayoutID = defaultLayoutID
        self.layouts = layouts
        try validate()
    }

    fileprivate func validate() throws {
        try metadata.validate()
        guard !layouts.isEmpty,
              unique(layouts.map(\.id)),
              layouts.contains(where: { $0.id == defaultLayoutID })
        else {
            throw ThemeDescriptorValidationError.invalidValue("relic-layouts:\(metadata.id.rawValue)")
        }
        try layouts.forEach { try $0.validate() }
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        [primaryResourceID, thumbnailResourceID, staticFallbackResourceID, highContrastResourceID]
    }
}

public enum ThemeSealScaleReference: String, Codable, Hashable, Sendable {
    case relicShortEdge
    case relicLongEdge
    case relicWidth
    case relicHeight
}

public struct ThemeSealDescriptor: Codable, Hashable, Sendable {
    public let metadata: ThemeArtifactMetadata
    public let vectorResourceID: ThemeResourceID
    public let monochromeFallbackResourceID: ThemeResourceID
    public let thumbnailResourceID: ThemeResourceID
    public let allowedScale: ThemeScalarRange
    public let scaleReference: ThemeSealScaleReference
    public let allowedAnchors: [ThemeSealAnchorCategory]

    public init(
        metadata: ThemeArtifactMetadata,
        vectorResourceID: ThemeResourceID,
        monochromeFallbackResourceID: ThemeResourceID,
        thumbnailResourceID: ThemeResourceID,
        allowedScale: ThemeScalarRange,
        scaleReference: ThemeSealScaleReference,
        allowedAnchors: [ThemeSealAnchorCategory]
    ) throws {
        self.metadata = metadata
        self.vectorResourceID = vectorResourceID
        self.monochromeFallbackResourceID = monochromeFallbackResourceID
        self.thumbnailResourceID = thumbnailResourceID
        self.allowedScale = allowedScale
        self.scaleReference = scaleReference
        self.allowedAnchors = allowedAnchors
        try validate()
    }

    fileprivate func validate() throws {
        try metadata.validate()
        try allowedScale.validate()
        guard !allowedAnchors.isEmpty, unique(allowedAnchors), allowedScale.maximum <= 1 else {
            throw ThemeDescriptorValidationError.invalidValue("seal-placement:\(metadata.id.rawValue)")
        }
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        [vectorResourceID, monochromeFallbackResourceID, thumbnailResourceID]
    }
}

public struct ThemeFrameDescriptor: Codable, Hashable, Sendable {
    public let metadata: ThemeArtifactMetadata
    public let vectorResourceID: ThemeResourceID
    public let staticFallbackResourceID: ThemeResourceID
    public let compatibleRelicIDs: [ArtifactID]
    public let allowsStaticShare: Bool

    public init(
        metadata: ThemeArtifactMetadata,
        vectorResourceID: ThemeResourceID,
        staticFallbackResourceID: ThemeResourceID,
        compatibleRelicIDs: [ArtifactID],
        allowsStaticShare: Bool
    ) throws {
        guard !compatibleRelicIDs.isEmpty, unique(compatibleRelicIDs) else {
            throw ThemeDescriptorValidationError.invalidValue("frame-relic-compatibility")
        }
        self.metadata = metadata
        self.vectorResourceID = vectorResourceID
        self.staticFallbackResourceID = staticFallbackResourceID
        self.compatibleRelicIDs = compatibleRelicIDs
        self.allowsStaticShare = allowsStaticShare
        try validate()
    }

    fileprivate func validate() throws {
        try metadata.validate()
        guard !compatibleRelicIDs.isEmpty, unique(compatibleRelicIDs) else {
            throw ThemeDescriptorValidationError.invalidValue("frame-relic-compatibility")
        }
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        [vectorResourceID, staticFallbackResourceID]
    }
}

public struct ThemeCrestDescriptor: Codable, Hashable, Sendable {
    public let metadata: ThemeArtifactMetadata
    public let vectorResourceID: ThemeResourceID
    public let staticFallbackResourceID: ThemeResourceID

    public init(
        metadata: ThemeArtifactMetadata,
        vectorResourceID: ThemeResourceID,
        staticFallbackResourceID: ThemeResourceID
    ) throws {
        self.metadata = metadata
        self.vectorResourceID = vectorResourceID
        self.staticFallbackResourceID = staticFallbackResourceID
        try validate()
    }

    fileprivate func validate() throws {
        try metadata.validate()
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        [vectorResourceID, staticFallbackResourceID]
    }
}

public enum ThemeMotionIntensity: String, Codable, Hashable, Sendable {
    case none
    case subtle
    case moderate
}

public enum ThemePerformanceClass: String, Codable, Hashable, Sendable {
    case low
    case standard
    case elevated
}

public struct ThemeBackgroundDescriptor: Codable, Hashable, Sendable {
    public let id: ThemeBackgroundID
    public let displayName: ThemeLocalizedText
    public let staticBaseResourceID: ThemeResourceID
    public let reduceMotionResourceID: ThemeResourceID
    public let highContrastResourceID: ThemeResourceID
    public let optionalMotionResourceID: ThemeResourceID?
    public let rendererParametersResourceID: ThemeResourceID?
    public let motionIntensity: ThemeMotionIntensity
    public let performanceClass: ThemePerformanceClass
    public let parallaxAllowed: Bool
    public let accessibility: ThemeAccessibilityMetadata
    public let rightsID: ThemeProvenanceID

    public init(
        id: ThemeBackgroundID,
        displayName: ThemeLocalizedText,
        staticBaseResourceID: ThemeResourceID,
        reduceMotionResourceID: ThemeResourceID,
        highContrastResourceID: ThemeResourceID,
        optionalMotionResourceID: ThemeResourceID? = nil,
        rendererParametersResourceID: ThemeResourceID? = nil,
        motionIntensity: ThemeMotionIntensity,
        performanceClass: ThemePerformanceClass,
        parallaxAllowed: Bool,
        accessibility: ThemeAccessibilityMetadata,
        rightsID: ThemeProvenanceID
    ) throws {
        self.id = id
        self.displayName = displayName
        self.staticBaseResourceID = staticBaseResourceID
        self.reduceMotionResourceID = reduceMotionResourceID
        self.highContrastResourceID = highContrastResourceID
        self.optionalMotionResourceID = optionalMotionResourceID
        self.rendererParametersResourceID = rendererParametersResourceID
        self.motionIntensity = motionIntensity
        self.performanceClass = performanceClass
        self.parallaxAllowed = parallaxAllowed
        self.accessibility = accessibility
        self.rightsID = rightsID
        try validate()
    }

    fileprivate func validate() throws {
        try displayName.validate()
        try accessibility.validate()
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        var result = Set([
            staticBaseResourceID,
            reduceMotionResourceID,
            highContrastResourceID,
        ])
        if let rendererParametersResourceID {
            result.insert(rendererParametersResourceID)
        }
        return result
    }

    fileprivate var optionalResourceIDs: Set<ThemeResourceID> {
        Set(optionalMotionResourceID.map { [$0] } ?? [])
    }
}

public struct ThemeVaultDescriptor: Codable, Hashable, Sendable {
    public let id: ThemeVaultID
    public let grouping: ThemeLocalizedText
    public let cardResourceID: ThemeResourceID
    public let lockedSilhouetteResourceID: ThemeResourceID
    public let encounteredResourceID: ThemeResourceID
    public let selectedResourceID: ThemeResourceID
    public let accessibility: ThemeAccessibilityMetadata
    public let rightsID: ThemeProvenanceID

    public init(
        id: ThemeVaultID,
        grouping: ThemeLocalizedText,
        cardResourceID: ThemeResourceID,
        lockedSilhouetteResourceID: ThemeResourceID,
        encounteredResourceID: ThemeResourceID,
        selectedResourceID: ThemeResourceID,
        accessibility: ThemeAccessibilityMetadata,
        rightsID: ThemeProvenanceID
    ) throws {
        self.id = id
        self.grouping = grouping
        self.cardResourceID = cardResourceID
        self.lockedSilhouetteResourceID = lockedSilhouetteResourceID
        self.encounteredResourceID = encounteredResourceID
        self.selectedResourceID = selectedResourceID
        self.accessibility = accessibility
        self.rightsID = rightsID
        try validate()
    }

    fileprivate func validate() throws {
        try grouping.validate()
        try accessibility.validate()
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        [cardResourceID, lockedSilhouetteResourceID, encounteredResourceID, selectedResourceID]
    }
}

public struct ThemeLocalizationDescriptor: Codable, Hashable, Sendable {
    public let localeIdentifier: String
    public let stringsResourceID: ThemeResourceID

    public init(localeIdentifier: String, stringsResourceID: ThemeResourceID) throws {
        let bytes = Array(localeIdentifier.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 35,
              bytes.allSatisfy({
                  (0x41 ... 0x5A).contains($0)
                      || (0x61 ... 0x7A).contains($0)
                      || (0x30 ... 0x39).contains($0)
                      || $0 == 0x2D
              })
        else {
            throw ThemeDescriptorValidationError.invalidValue("locale-identifier")
        }
        self.localeIdentifier = localeIdentifier
        self.stringsResourceID = stringsResourceID
    }

    fileprivate func validate() throws {
        _ = try Self(localeIdentifier: localeIdentifier, stringsResourceID: stringsResourceID)
    }
}

public struct ThemeCodexDescriptor: Codable, Hashable, Sendable {
    public let id: CodexID
    public let entitlementID: UnlockID
    public let displayName: ThemeLocalizedText
    public let shortDescription: ThemeLocalizedText
    public let longDescription: ThemeLocalizedText
    public let accessibility: ThemeAccessibilityMetadata
    public let palette: ThemeSemanticPalette
    public let primaryScriptID: ScriptID
    public let fallbackScriptID: ScriptID
    public let defaultRelicID: ArtifactID
    public let scripts: [ThemeScriptDescriptor]
    public let relics: [ThemeRelicDescriptor]
    public let seals: [ThemeSealDescriptor]
    public let frames: [ThemeFrameDescriptor]
    public let crests: [ThemeCrestDescriptor]
    public let background: ThemeBackgroundDescriptor
    public let vault: ThemeVaultDescriptor
    public let rightsID: ThemeProvenanceID

    public init(
        id: CodexID,
        entitlementID: UnlockID,
        displayName: ThemeLocalizedText,
        shortDescription: ThemeLocalizedText,
        longDescription: ThemeLocalizedText,
        accessibility: ThemeAccessibilityMetadata,
        palette: ThemeSemanticPalette,
        primaryScriptID: ScriptID,
        fallbackScriptID: ScriptID,
        defaultRelicID: ArtifactID,
        scripts: [ThemeScriptDescriptor],
        relics: [ThemeRelicDescriptor],
        seals: [ThemeSealDescriptor],
        frames: [ThemeFrameDescriptor],
        crests: [ThemeCrestDescriptor],
        background: ThemeBackgroundDescriptor,
        vault: ThemeVaultDescriptor,
        rightsID: ThemeProvenanceID
    ) throws {
        self.id = id
        self.entitlementID = entitlementID
        self.displayName = displayName
        self.shortDescription = shortDescription
        self.longDescription = longDescription
        self.accessibility = accessibility
        self.palette = palette
        self.primaryScriptID = primaryScriptID
        self.fallbackScriptID = fallbackScriptID
        self.defaultRelicID = defaultRelicID
        self.scripts = scripts
        self.relics = relics
        self.seals = seals
        self.frames = frames
        self.crests = crests
        self.background = background
        self.vault = vault
        self.rightsID = rightsID
        try validate()
    }

    fileprivate func validate() throws {
        try displayName.validate()
        try shortDescription.validate()
        try longDescription.validate()
        try accessibility.validate()
        try palette.validate()
        guard !scripts.isEmpty, unique(scripts.map(\.id)) else {
            throw ThemeDescriptorValidationError.invalidValue("script-catalog")
        }
        try scripts.forEach { try $0.validate() }
        guard let primaryScript = scripts.first(where: { $0.id == primaryScriptID }) else {
            throw ThemeDescriptorValidationError.unknownReference(primaryScriptID.rawValue)
        }
        guard primaryScript.fallbackScriptID == fallbackScriptID else {
            throw ThemeDescriptorValidationError.missingFallback(primaryScriptID.rawValue)
        }
        guard !relics.isEmpty else {
            throw ThemeDescriptorValidationError.missingDefaultRelic
        }
        try relics.forEach { try $0.validate() }
        try seals.forEach { try $0.validate() }
        try frames.forEach { try $0.validate() }
        try crests.forEach { try $0.validate() }
        try background.validate()
        try vault.validate()

        let allArtifacts = relics.map(\.metadata) + seals.map(\.metadata)
            + frames.map(\.metadata) + crests.map(\.metadata)
        guard unique(allArtifacts.map(\.id)) else {
            throw ThemeDescriptorValidationError.duplicateIdentifier("artifact")
        }
        guard allArtifacts.allSatisfy({ $0.codexID == id }) else {
            throw ThemeDescriptorValidationError.unknownReference("artifact-codex")
        }
        let defaults = relics.filter(\.isDefault)
        guard defaults.count == 1,
              defaults[0].metadata.id == defaultRelicID
        else {
            throw ThemeDescriptorValidationError.missingDefaultRelic
        }
        let relicIDs = Set(relics.map(\.metadata.id))
        for frame in frames where !Set(frame.compatibleRelicIDs).isSubset(of: relicIDs) {
            throw ThemeDescriptorValidationError.unknownReference(frame.metadata.id.rawValue)
        }
    }

    fileprivate var requiredResourceIDs: Set<ThemeResourceID> {
        var result = Set<ThemeResourceID>()
        scripts.forEach { result.formUnion($0.requiredResourceIDs) }
        relics.forEach { result.formUnion($0.requiredResourceIDs) }
        seals.forEach { result.formUnion($0.requiredResourceIDs) }
        frames.forEach { result.formUnion($0.requiredResourceIDs) }
        crests.forEach { result.formUnion($0.requiredResourceIDs) }
        result.formUnion(background.requiredResourceIDs)
        result.formUnion(vault.requiredResourceIDs)
        return result
    }

    fileprivate var optionalResourceIDs: Set<ThemeResourceID> {
        background.optionalResourceIDs
    }

    fileprivate var referencedRightsIDs: Set<ThemeProvenanceID> {
        var result = Set([rightsID, background.rightsID, vault.rightsID])
        scripts.forEach { result.insert($0.rightsID) }
        relics.forEach { result.insert($0.metadata.rightsID) }
        seals.forEach { result.insert($0.metadata.rightsID) }
        frames.forEach { result.insert($0.metadata.rightsID) }
        crests.forEach { result.insert($0.metadata.rightsID) }
        return result
    }

    fileprivate var declaredStableIDs: [String] {
        var result = [id.rawValue, background.id.rawValue, vault.id.rawValue]
        result.append(contentsOf: scripts.map(\.id.rawValue))
        result.append(contentsOf: scripts.flatMap { $0.glyphs.map(\.glyphID.rawValue) })
        result.append(contentsOf: relics.map(\.metadata.id.rawValue))
        result.append(contentsOf: relics.flatMap { $0.layouts.map(\.id.rawValue) })
        result.append(contentsOf: seals.map(\.metadata.id.rawValue))
        result.append(contentsOf: frames.map(\.metadata.id.rawValue))
        result.append(contentsOf: crests.map(\.metadata.id.rawValue))
        return result
    }
}

public struct ThemeDescriptor: Codable, Hashable, Sendable {
    public static let supportedSchemaVersion = ThemeContractVersion.current
    public static let supportedUIContractVersion = ThemeContractVersion.current
    public static let providerPolicyClass = ThemePolicyClassID(rawValue: "policy.theme-provider")!

    public let id: ThemeID
    public let moduleID: ThemeModuleID
    public let moduleRole: ThemeModuleRoleID
    public let policyClass: ThemePolicyClassID
    public let criticality: ThemeCriticality
    public let schemaVersion: ThemeContractVersion
    public let contentVersion: UInt64
    public let minimumUIContractVersion: ThemeContractVersion
    public let platformCompatibility: [ThemePlatformCompatibility]
    public let fallbackCodexID: CodexID
    public let codex: ThemeCodexDescriptor
    public let resources: [ThemeResourceReference]
    public let localizations: [ThemeLocalizationDescriptor]
    public let defaultLocaleIdentifier: String
    public let rights: [ThemeRightsMetadata]

    public var globallyUniqueStableIDs: Set<String> {
        Set(
            [id.rawValue, moduleID.rawValue, moduleRole.rawValue]
                + codex.declaredStableIDs
                + [codex.entitlementID.rawValue]
                + resources.map(\.id.rawValue)
                + rights.map(\.id.rawValue)
        )
    }

    public init(
        id: ThemeID,
        moduleID: ThemeModuleID,
        moduleRole: ThemeModuleRoleID,
        policyClass: ThemePolicyClassID = ThemeDescriptor.providerPolicyClass,
        criticality: ThemeCriticality,
        schemaVersion: ThemeContractVersion,
        contentVersion: UInt64,
        minimumUIContractVersion: ThemeContractVersion,
        platformCompatibility: [ThemePlatformCompatibility],
        fallbackCodexID: CodexID,
        codex: ThemeCodexDescriptor,
        resources: [ThemeResourceReference],
        localizations: [ThemeLocalizationDescriptor],
        defaultLocaleIdentifier: String,
        rights: [ThemeRightsMetadata]
    ) throws {
        self.id = id
        self.moduleID = moduleID
        self.moduleRole = moduleRole
        self.policyClass = policyClass
        self.criticality = criticality
        self.schemaVersion = schemaVersion
        self.contentVersion = contentVersion
        self.minimumUIContractVersion = minimumUIContractVersion
        self.platformCompatibility = platformCompatibility
        self.fallbackCodexID = fallbackCodexID
        self.codex = codex
        self.resources = resources
        self.localizations = localizations
        self.defaultLocaleIdentifier = defaultLocaleIdentifier
        self.rights = rights
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: ThemeDescriptorAnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = rawContainer.allKeys.first(where: { !allowed.contains($0.stringValue) }) {
            throw DecodingError.dataCorruptedError(
                forKey: unknown,
                in: rawContainer,
                debugDescription: "Unknown Theme descriptor field."
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(ThemeID.self, forKey: .id),
                moduleID: container.decode(ThemeModuleID.self, forKey: .moduleID),
                moduleRole: container.decode(ThemeModuleRoleID.self, forKey: .moduleRole),
                policyClass: container.decode(ThemePolicyClassID.self, forKey: .policyClass),
                criticality: container.decode(ThemeCriticality.self, forKey: .criticality),
                schemaVersion: container.decode(ThemeContractVersion.self, forKey: .schemaVersion),
                contentVersion: container.decode(UInt64.self, forKey: .contentVersion),
                minimumUIContractVersion: container.decode(
                    ThemeContractVersion.self,
                    forKey: .minimumUIContractVersion
                ),
                platformCompatibility: container.decode(
                    [ThemePlatformCompatibility].self,
                    forKey: .platformCompatibility
                ),
                fallbackCodexID: container.decode(CodexID.self, forKey: .fallbackCodexID),
                codex: container.decode(ThemeCodexDescriptor.self, forKey: .codex),
                resources: container.decode([ThemeResourceReference].self, forKey: .resources),
                localizations: container.decode(
                    [ThemeLocalizationDescriptor].self,
                    forKey: .localizations
                ),
                defaultLocaleIdentifier: container.decode(
                    String.self,
                    forKey: .defaultLocaleIdentifier
                ),
                rights: container.decode([ThemeRightsMetadata].self, forKey: .rights)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Theme descriptor: \(error)"
                )
            )
        }
    }

    fileprivate func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw ThemeDescriptorValidationError.unsupportedSchemaVersion
        }
        guard contentVersion > 0,
              policyClass == Self.providerPolicyClass,
              minimumUIContractVersion <= Self.supportedUIContractVersion,
              !platformCompatibility.isEmpty,
              unique(platformCompatibility.map(\.platform))
        else {
            throw ThemeDescriptorValidationError.invalidValue("theme-compatibility")
        }
        guard fallbackCodexID == RuneScribeCodexIDs.norse else {
            throw ThemeDescriptorValidationError.missingFallback(codex.id.rawValue)
        }
        switch criticality {
        case .requiredBase:
            guard moduleID.rawValue == RuneScribeModuleIDs.norseTheme.rawValue,
                  moduleRole.rawValue == RuneScribeRoles.norseTheme.rawValue,
                  codex.id == RuneScribeCodexIDs.norse,
                  codex.entitlementID == RuneScribeUnlockIDs.norseCodex
            else {
                throw ThemeDescriptorValidationError.invalidValue("norse-base-identity")
            }
        case .optional:
            guard codex.id != RuneScribeCodexIDs.norse else {
                throw ThemeDescriptorValidationError.invalidValue("optional-base-identity")
            }
        }

        try codex.validate()
        try platformCompatibility.forEach { try $0.validate() }
        try resources.forEach { try $0.validate() }
        try localizations.forEach { try $0.validate() }
        try rights.forEach { try $0.validate() }
        guard !resources.isEmpty, unique(resources.map(\.id)) else {
            throw ThemeDescriptorValidationError.duplicateIdentifier("resource")
        }
        guard !localizations.isEmpty,
              unique(localizations.map(\.localeIdentifier)),
              localizations.contains(where: { $0.localeIdentifier == defaultLocaleIdentifier })
        else {
            throw ThemeDescriptorValidationError.invalidValue("localization-catalog")
        }
        guard !rights.isEmpty, unique(rights.map(\.id)) else {
            throw ThemeDescriptorValidationError.duplicateIdentifier("rights")
        }

        let declaredResources = Dictionary(uniqueKeysWithValues: resources.map { ($0.id, $0) })
        let requiredReferences = codex.requiredResourceIDs
            .union(localizations.map(\.stringsResourceID))
        let optionalReferences = codex.optionalResourceIDs
        for resourceID in requiredReferences.union(optionalReferences)
            where declaredResources[resourceID] == nil
        {
            throw ThemeDescriptorValidationError.unknownResource(resourceID.rawValue)
        }
        for resourceID in requiredReferences
            where declaredResources[resourceID]?.requirement != .required
        {
            throw ThemeDescriptorValidationError.resourceRequirementMismatch(resourceID.rawValue)
        }
        try validateSemanticResourceBindings(declaredResources)

        let declaredRights = Set(rights.map(\.id))
        let referencedRights = codex.referencedRightsIDs.union(resources.map(\.rightsID))
        for rightsID in referencedRights where !declaredRights.contains(rightsID) {
            throw ThemeDescriptorValidationError.unknownReference(rightsID.rawValue)
        }

        let declarations = [id.rawValue, moduleID.rawValue, moduleRole.rawValue]
            + codex.declaredStableIDs
            + resources.map(\.id.rawValue)
            + rights.map(\.id.rawValue)
        guard unique(declarations) else {
            throw ThemeDescriptorValidationError.duplicateIdentifier("theme-catalog")
        }
    }

    private func validateSemanticResourceBindings(
        _ resourcesByID: [ThemeResourceID: ThemeResourceReference]
    ) throws {
        let stillMedia: Set<ThemeResourceMediaType> = [.png, .heif, .pdf]
        let thumbnailMedia: Set<ThemeResourceMediaType> = [.png, .heif]
        let vectorMedia: Set<ThemeResourceMediaType> = [.pdf]
        let fontMedia: Set<ThemeResourceMediaType> = [.ttf, .otf]
        let motionMedia: Set<ThemeResourceMediaType> = [.mp4, .quickTime]

        func require(
            _ resourceID: ThemeResourceID,
            role: ThemeResourceRoleID,
            media: Set<ThemeResourceMediaType>
        ) throws {
            guard let reference = resourcesByID[resourceID],
                  reference.role == role,
                  media.contains(reference.mediaType)
            else {
                throw ThemeDescriptorValidationError.resourceSemanticMismatch(
                    resourceID.rawValue
                )
            }
        }

        for script in codex.scripts {
            if let fontResourceID = script.fontResourceID {
                try require(fontResourceID, role: ThemeResourceRoles.scriptFont, media: fontMedia)
            }
            try require(
                script.staticFallbackResourceID,
                role: ThemeResourceRoles.scriptStaticFallback,
                media: stillMedia
            )
            for glyph in script.glyphs {
                if let vectorResourceID = glyph.vectorResourceID {
                    try require(
                        vectorResourceID,
                        role: ThemeResourceRoles.scriptGlyphVector,
                        media: vectorMedia
                    )
                }
            }
        }
        for relic in codex.relics {
            try require(relic.primaryResourceID, role: ThemeResourceRoles.relicMaster, media: stillMedia)
            try require(
                relic.thumbnailResourceID,
                role: ThemeResourceRoles.relicThumbnail,
                media: thumbnailMedia
            )
            try require(
                relic.staticFallbackResourceID,
                role: ThemeResourceRoles.relicStaticShareFallback,
                media: stillMedia
            )
            try require(
                relic.highContrastResourceID,
                role: ThemeResourceRoles.relicHighContrast,
                media: stillMedia
            )
        }
        for seal in codex.seals {
            try require(
                seal.vectorResourceID,
                role: ThemeResourceRoles.sealVectorMaster,
                media: vectorMedia
            )
            try require(
                seal.monochromeFallbackResourceID,
                role: ThemeResourceRoles.sealMonochromeFallback,
                media: stillMedia
            )
            try require(
                seal.thumbnailResourceID,
                role: ThemeResourceRoles.sealThumbnail,
                media: thumbnailMedia
            )
        }
        for frame in codex.frames {
            try require(
                frame.vectorResourceID,
                role: ThemeResourceRoles.frameVectorMaster,
                media: vectorMedia
            )
            try require(
                frame.staticFallbackResourceID,
                role: ThemeResourceRoles.frameStaticFallback,
                media: stillMedia
            )
        }
        for crest in codex.crests {
            try require(
                crest.vectorResourceID,
                role: ThemeResourceRoles.crestVectorMaster,
                media: vectorMedia
            )
            try require(
                crest.staticFallbackResourceID,
                role: ThemeResourceRoles.crestStaticFallback,
                media: stillMedia
            )
        }
        try require(
            codex.background.staticBaseResourceID,
            role: ThemeResourceRoles.backgroundStaticBase,
            media: stillMedia
        )
        try require(
            codex.background.reduceMotionResourceID,
            role: ThemeResourceRoles.backgroundReduceMotion,
            media: stillMedia
        )
        try require(
            codex.background.highContrastResourceID,
            role: ThemeResourceRoles.backgroundHighContrast,
            media: stillMedia
        )
        if let motion = codex.background.optionalMotionResourceID {
            try require(motion, role: ThemeResourceRoles.backgroundMotion, media: motionMedia)
        }
        if let parameters = codex.background.rendererParametersResourceID {
            try require(
                parameters,
                role: ThemeResourceRoles.backgroundRendererParameters,
                media: [.json]
            )
        }
        try require(codex.vault.cardResourceID, role: ThemeResourceRoles.vaultCard, media: stillMedia)
        try require(
            codex.vault.lockedSilhouetteResourceID,
            role: ThemeResourceRoles.vaultLockedSilhouette,
            media: stillMedia
        )
        try require(
            codex.vault.encounteredResourceID,
            role: ThemeResourceRoles.vaultEncountered,
            media: stillMedia
        )
        try require(
            codex.vault.selectedResourceID,
            role: ThemeResourceRoles.vaultSelected,
            media: stillMedia
        )
        for localization in localizations {
            try require(
                localization.stringsResourceID,
                role: ThemeResourceRoles.localizationStrings,
                media: [.json]
            )
        }
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case moduleID
        case moduleRole
        case policyClass
        case criticality
        case schemaVersion
        case contentVersion
        case minimumUIContractVersion
        case platformCompatibility
        case fallbackCodexID
        case codex
        case resources
        case localizations
        case defaultLocaleIdentifier
        case rights
    }
}

private struct ThemeDescriptorAnyCodingKey: CodingKey {
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

private func unique<Value: Hashable>(_ values: [Value]) -> Bool {
    Set(values).count == values.count
}
