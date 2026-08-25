import Foundation
import RuneScribeContracts

public enum NorseBaseThemeDescriptorFactory {
    public static let discoveryDescriptor: ThemeDescriptor = {
        do { return try make() }
        catch { preconditionFailure("Invalid frozen Norse Base Theme descriptor: \(error)") }
    }()

    public static func make() throws -> ThemeDescriptor {
        let codexID = RuneScribeCodexIDs.norse
        let presentationRightsID = provenanceID("rights.norse.base")
        let fontRightsID = provenanceID("rights.norse.font.noto")
        let scriptID = ScriptID(rawValue: "script.base-runes")!
        let relics = try makeRelics(codexID: codexID, rightsID: presentationRightsID)

        let script = try ThemeScriptDescriptor(
            id: scriptID,
            displayName: localized("script.base-runes.name", "Base Rune Script"),
            portability: .unicodePortable,
            glyphs: try ThemeCanonicalSymbolSet.transportTokens.enumerated().map { index, token in
                try ThemeScriptGlyph(
                    canonicalValue: UInt8(index),
                    glyphID: glyphID(String(format: "glyph.base-runes.%02d", index)),
                    textToken: token
                )
            },
            fontResourceID: NorseBaseThemeResourceIDs.font,
            fontReferenceID: ThemeFontReferenceID(rawValue: "noto-sans-runic")!,
            fontVersion: 1,
            fontPostScriptName: ThemeFontPostScriptName(rawValue: "NotoSansRunic-Regular"),
            staticFallbackResourceID: NorseBaseThemeResourceIDs.scriptFallback,
            fallbackScriptID: scriptID,
            recommendedPointSizes: ThemeScalarRange(minimum: 12, maximum: 64),
            accessibility: accessibility(
                "script.base-runes",
                label: "Base Rune Script",
                hint: "Presents the canonical 32-value Rune Scribe mapping.",
                hidesRedundantGlyphs: true
            ),
            rightsID: fontRightsID,
            standardSpecimenResourceID: NorseBaseThemeResourceIDs.scriptSpecimenStandard,
            highContrastSpecimenResourceID: NorseBaseThemeResourceIDs.scriptSpecimenHighContrast
        )

        let background = try ThemeBackgroundDescriptor(
            id: ThemeBackgroundID(rawValue: "background.norse.cold-sea-hall")!,
            displayName: localized("background.norse.name", "Cold Sea and Ancient Hall"),
            staticBaseResourceID: NorseBaseThemeResourceIDs.backgroundStatic,
            reduceMotionResourceID: NorseBaseThemeResourceIDs.backgroundReduceMotion,
            highContrastResourceID: NorseBaseThemeResourceIDs.backgroundHighContrast,
            macOSWideResourceID: NorseBaseThemeResourceIDs.backgroundMacOSWide,
            motionIntensity: .subtle,
            performanceClass: .standard,
            parallaxAllowed: false,
            accessibility: accessibility(
                "background.norse",
                label: "Cold northern sea and ancient hall",
                hint: "Uses deep navy atmosphere, cold sea light, and an ancient timber hall behind the workspace."
            ),
            rightsID: presentationRightsID
        )

        let vault = try ThemeVaultDescriptor(
            id: ThemeVaultID(rawValue: "vault.norse")!,
            grouping: localized("vault.norse.grouping", "Norse Collection"),
            cardResourceID: NorseBaseThemeResourceIDs.vaultCard,
            lockedSilhouetteResourceID: NorseBaseThemeResourceIDs.vaultLocked,
            encounteredResourceID: NorseBaseThemeResourceIDs.vaultEncountered,
            selectedResourceID: NorseBaseThemeResourceIDs.vaultSelected,
            unavailableResourceID: NorseBaseThemeResourceIDs.vaultUnavailable,
            accessibility: accessibility(
                "vault.norse",
                label: "Norse Founding Codex collection",
                hint: "Shows ownership, availability, and selection with text and shape as well as color."
            ),
            rightsID: presentationRightsID
        )

        let codex = try ThemeCodexDescriptor(
            id: codexID,
            entitlementID: RuneScribeUnlockIDs.norseCodex,
            displayName: localized("codex.norse.name", "Norse Codex"),
            shortDescription: localized("codex.norse.tagline", "The Founding Codex."),
            longDescription: localized(
                "codex.norse.description",
                "The permanent Rune Scribe Base Codex, shaped from weathered stone, carved dark wood, forged iron, and restrained knotwork."
            ),
            accessibility: accessibility(
                "codex.norse",
                label: "Norse Founding Codex",
                hint: "Rune Scribe's permanent, always-owned Base Codex."
            ),
            palette: try palette(),
            primaryScriptID: scriptID,
            fallbackScriptID: scriptID,
            defaultRelicID: artifactID("relic.norse.runestone-tablet"),
            scripts: [script],
            relics: relics,
            seals: try makeSeals(codexID: codexID, rightsID: presentationRightsID),
            frames: try makeFrames(relics: relics, codexID: codexID, rightsID: presentationRightsID),
            crests: try makeCrests(codexID: codexID, rightsID: presentationRightsID),
            background: background,
            vault: vault,
            rightsID: presentationRightsID
        )

        return try ThemeDescriptor(
            id: ThemeID(rawValue: "theme.norse.base")!,
            moduleID: ThemeModuleID(rawValue: RuneScribeModuleIDs.norseTheme.rawValue)!,
            moduleRole: ThemeModuleRoleID(rawValue: RuneScribeRoles.norseTheme.rawValue)!,
            policyClass: ThemeDescriptor.providerPolicyClass,
            criticality: .requiredBase,
            schemaVersion: ThemeContractVersion.current,
            contentVersion: 2,
            minimumUIContractVersion: ThemeContractVersion.current,
            platformCompatibility: [
                try ThemePlatformCompatibility(platform: .iOS, minimumMajorVersion: 17),
                try ThemePlatformCompatibility(platform: .macOS, minimumMajorVersion: 15),
            ],
            fallbackCodexID: codexID,
            codex: codex,
            resources: try NorseBaseThemeResourceCatalog.references(
                fontRightsID: fontRightsID,
                presentationRightsID: presentationRightsID
            ),
            localizations: [
                try ThemeLocalizationDescriptor(
                    localeIdentifier: "en-US",
                    stringsResourceID: NorseBaseThemeResourceIDs.localization
                ),
            ],
            defaultLocaleIdentifier: "en-US",
            rights: [
                try ThemeRightsMetadata(
                    id: presentationRightsID,
                    creatorTool: "Raven Forge Studios approved Norse production package",
                    creationDate: "2026-08-21",
                    origin: .original,
                    rightsOwner: "Raven Forge Studios",
                    sourceReference: "Rune Scribe Norse Theme Module package version 1.0",
                    exportSettings: "Approved production PNG, PDF, JSON, and WAV resources",
                    licenseNotice: "All rights reserved."
                ),
                try ThemeRightsMetadata(
                    id: fontRightsID,
                    creatorTool: "Noto Sans Runic source distribution",
                    creationDate: "2026-06-19",
                    origin: .derived,
                    rightsOwner: "The Noto Project Authors",
                    sourceReference: "NotoSansRunic-Regular.ttf",
                    exportSettings: "Exact byte-preserving resource migration",
                    licenseNotice: "SIL Open Font License 1.1; see Third-Party-Notices."
                ),
            ]
        )
    }

    private static func makeRelics(
        codexID: CodexID,
        rightsID: ThemeProvenanceID
    ) throws -> [ThemeRelicDescriptor] {
        let definitions: [RelicDefinition] = [
            RelicDefinition(id: "relic.norse.runestone-tablet", name: "Runestone Tablet", description: "A broad weathered stone tablet with a dimensional iron-and-knotwork border and paired raven crest.", rarity: .forged, availability: .included, isDefault: true, width: 4, height: 3, safeArea: (0.23, 0.30, 0.54, 0.45), anchors: [(0.23, 0.78, .lowerLeft), (0.77, 0.78, .lowerRight)], maximumLines: 7),
            RelicDefinition(id: "relic.norse.dragonwood-plaque", name: "Dragonwood Plaque", description: "A tall plaque of dark carved wood enclosed by forged iron and crowned by a sculpted dragon.", rarity: .inscribed, availability: .earned, width: 3, height: 4, safeArea: (0.27, 0.31, 0.46, 0.42), anchors: [(0.30, 0.78, .lowerLeft), (0.70, 0.78, .lowerRight)], maximumLines: 6),
            RelicDefinition(id: "relic.norse.stormforged-stele", name: "Stormforged Stele", description: "A tall war-stele of weathered stone and blackened iron beneath a carved hammer crest.", rarity: .rare, availability: .earned, width: 3, height: 4, safeArea: (0.27, 0.36, 0.46, 0.40), anchors: [(0.30, 0.81, .lowerLeft), (0.70, 0.81, .lowerRight)], maximumLines: 6),
        ]

        return try definitions.map { definition in
            let id = artifactID(definition.id)
            let resources = NorseBaseThemeResourceIDs.relicResourceIDs[id]!
            let layout = try makeLayout(definition)
            return try ThemeRelicDescriptor(
                metadata: artifact(
                    id: id,
                    codexID: codexID,
                    name: definition.name,
                    description: definition.description,
                    rarity: definition.rarity,
                    availability: definition.availability,
                    accessibilityHint: "Uses a bounded inscription area and approved seal anchors.",
                    rightsID: rightsID
                ),
                isDefault: definition.isDefault,
                primaryResourceID: resources.primary,
                thumbnailResourceID: resources.thumbnail,
                staticFallbackResourceID: resources.staticFallback,
                highContrastResourceID: resources.highContrast,
                defaultLayoutID: layout.id,
                layouts: [layout]
            )
        }
    }

    private static func makeSeals(codexID: CodexID, rightsID: ThemeProvenanceID) throws -> [ThemeSealDescriptor] {
        let definitions: [(String, String, String, ThemeRarityToken, ThemeArtifactAvailability)] = [
            ("seal.norse.valknut", "Valknut Seal", "An aged bronze medallion bearing a sculpted interlocked Valknut.", .forged, .included),
            ("seal.norse.ravenshield", "Ravenshield Seal", "A forged shield medallion bearing a sculpted raven.", .forged, .included),
            ("seal.norse.mjolnir", "Mjolnir Seal", "A relief medallion bearing the hammer Mjolnir.", .inscribed, .earned),
            ("seal.norse.wolkin", "Wolkin Seal", "An aged medallion bearing a longship beneath the northern sky.", .inscribed, .earned),
            ("seal.norse.yggdrasil", "Yggdrasil Seal", "A sculpted medallion bearing the world tree Yggdrasil.", .inscribed, .earned),
            ("seal.norse.berserk", "Berserk Seal", "A dark forged medallion bearing a battle-worn warrior mark.", .rare, .earned),
        ]
        return try definitions.map { rawID, name, description, rarity, availability in
            let id = artifactID(rawID)
            let resources = NorseBaseThemeResourceIDs.sealResourceIDs[id]!
            return try ThemeSealDescriptor(
                metadata: artifact(id: id, codexID: codexID, name: name, description: description, rarity: rarity, availability: availability, accessibilityHint: "Places the \(name) at an approved anchor without covering the inscription.", rightsID: rightsID),
                vectorResourceID: resources.vector,
                monochromeFallbackResourceID: resources.monochrome,
                thumbnailResourceID: resources.thumbnail,
                allowedScale: ThemeScalarRange(minimum: 0.12, maximum: 0.24),
                scaleReference: .relicShortEdge,
                allowedAnchors: [.lowerLeft, .lowerRight]
            )
        }
    }

    private static func makeFrames(relics: [ThemeRelicDescriptor], codexID: CodexID, rightsID: ThemeProvenanceID) throws -> [ThemeFrameDescriptor] {
        [try ThemeFrameDescriptor(
            metadata: artifact(id: artifactID("frame.norse.carved-knotwork"), codexID: codexID, name: "Norse Mastery Frame", description: "A carved silver-and-gold knotwork mastery border with sculpted corner ornaments.", rarity: .inscribed, availability: .earned, accessibilityHint: "Adds a mastery border without changing or obscuring the message.", rightsID: rightsID),
            vectorResourceID: NorseBaseThemeResourceIDs.frameVector,
            staticFallbackResourceID: NorseBaseThemeResourceIDs.frameStatic,
            compatibleRelicIDs: relics.map(\.metadata.id),
            allowsStaticShare: true
        )]
    }

    private static func makeCrests(codexID: CodexID, rightsID: ThemeProvenanceID) throws -> [ThemeCrestDescriptor] {
        [try ThemeCrestDescriptor(
            metadata: artifact(id: artifactID("crest.norse.raven-mastery"), codexID: codexID, name: "Raven Mastery Crest", description: "A weathered shield crest bearing a sculpted silver raven and restrained blue enamel.", rarity: .rare, availability: .mastery, accessibilityHint: "Marks Norse mastery without replacing the message label.", rightsID: rightsID),
            vectorResourceID: NorseBaseThemeResourceIDs.crestVector,
            staticFallbackResourceID: NorseBaseThemeResourceIDs.crestStatic,
            thumbnailResourceID: NorseBaseThemeResourceIDs.crestThumbnail
        )]
    }

    private static func makeLayout(_ definition: RelicDefinition) throws -> ThemeShareLayoutPreset {
        let safe = definition.safeArea
        return try ThemeShareLayoutPreset(
            id: ThemeLayoutPresetID(rawValue: "layout.\(definition.id)")!,
            aspectRatio: ThemeAspectRatio(width: definition.width, height: definition.height),
            relicBounds: ThemeNormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            contentSafeRegion: ThemeNormalizedRegion(x: 0.08, y: 0.08, width: 0.84, height: 0.82),
            glyphSafeRegion: ThemeNormalizedRegion(x: safe.0, y: safe.1, width: safe.2, height: safe.3),
            sealAnchors: try definition.anchors.map { x, y, category in
                ThemeSealAnchor(category: category, point: try ThemeNormalizedPoint(x: x, y: y))
            },
            maximumGlyphLines: definition.maximumLines,
            minimumGlyphScale: 0.5,
            overflowBehavior: .standardAlternate,
            attributionRegion: ThemeNormalizedRegion(x: 0.08, y: 0.93, width: 0.84, height: 0.04),
            provenanceRegion: ThemeNormalizedRegion(x: 0.08, y: 0.88, width: 0.38, height: 0.04),
            serialNumberRegion: ThemeNormalizedRegion(x: 0.54, y: 0.88, width: 0.38, height: 0.04),
            qrSafeRegion: ThemeNormalizedRegion(x: 0.74, y: 0.69, width: 0.14, height: 0.14),
            thumbnailCrop: ThemeNormalizedRegion(x: 0, y: 0, width: 1, height: 1)
        )
    }

    private static func artifact(id: ArtifactID, codexID: CodexID, name: String, description: String, rarity: ThemeRarityToken, availability: ThemeArtifactAvailability, accessibilityHint: String, rightsID: ThemeProvenanceID) throws -> ThemeArtifactMetadata {
        try ThemeArtifactMetadata(
            id: id,
            codexID: codexID,
            displayName: localized("\(id.rawValue).name", name),
            description: localized("\(id.rawValue).description", description),
            rarity: rarity,
            availability: availability,
            accessibility: accessibility(id.rawValue, label: name, hint: accessibilityHint),
            rightsID: rightsID
        )
    }

    private static func accessibility(_ keyPrefix: String, label: String, hint: String, hidesRedundantGlyphs: Bool = false) throws -> ThemeAccessibilityMetadata {
        try ThemeAccessibilityMetadata(
            label: localized("\(keyPrefix).accessibility-label", label),
            hint: localized("\(keyPrefix).accessibility-hint", hint),
            hidesRedundantGlyphs: hidesRedundantGlyphs,
            noColorOnlyState: true,
            dynamicTypeSafe: true
        )
    }

    private static func localized(_ key: String, _ fallbackValue: String) throws -> ThemeLocalizedText {
        try ThemeLocalizedText(key: ThemeLocalizationKey(rawValue: key)!, fallbackValue: fallbackValue)
    }

    private static func palette() throws -> ThemeSemanticPalette {
        let color: (String) -> ThemeSemanticColor = { ThemeSemanticColor(rawValue: $0)! }
        return try ThemeSemanticPalette(
            backgroundPrimary: color("#080A1E"), backgroundSecondary: color("#14082E"),
            surfacePrimary: color("#1A1E30"), surfaceElevated: color("#252A3C"),
            textPrimary: color("#F4EFE5"), textSecondary: color("#A0A8B8"),
            textInverse: color("#080A1E"), accentPrimary: color("#D4971A"),
            accentSecondary: color("#3A7FD5"), success: color("#34C759"),
            warning: color("#D4971A"), danger: color("#FF3B30"),
            information: color("#3A7FD5"), locked: color("#A0A8B8"),
            encountered: color("#3A7FD5"), unavailable: color("#8E8E93"),
            selected: color("#D4971A"), focus: color("#EEBE45"),
            keyboardFocus: color("#3A7FD5"),
            rarityAccents: [
                ThemeRarityAccent(rarity: .forged, color: color("#A0A8B8")),
                ThemeRarityAccent(rarity: .inscribed, color: color("#3A7FD5")),
                ThemeRarityAccent(rarity: .rare, color: color("#D4971A")),
                ThemeRarityAccent(rarity: .mythic, color: color("#EEBE45")),
            ]
        )
    }

    private static func provenanceID(_ value: String) -> ThemeProvenanceID { ThemeProvenanceID(rawValue: value)! }
    private static func glyphID(_ value: String) -> ThemeGlyphID { ThemeGlyphID(rawValue: value)! }
    private static func artifactID(_ value: String) -> ArtifactID { ArtifactID(rawValue: value)! }
}

private struct RelicDefinition {
    let id: String
    let name: String
    let description: String
    let rarity: ThemeRarityToken
    let availability: ThemeArtifactAvailability
    let isDefault: Bool
    let width: UInt16
    let height: UInt16
    let safeArea: (Double, Double, Double, Double)
    let anchors: [(Double, Double, ThemeSealAnchorCategory)]
    let maximumLines: UInt8

    init(id: String, name: String, description: String, rarity: ThemeRarityToken, availability: ThemeArtifactAvailability, isDefault: Bool = false, width: UInt16, height: UInt16, safeArea: (Double, Double, Double, Double), anchors: [(Double, Double, ThemeSealAnchorCategory)], maximumLines: UInt8) {
        self.id = id
        self.name = name
        self.description = description
        self.rarity = rarity
        self.availability = availability
        self.isDefault = isDefault
        self.width = width
        self.height = height
        self.safeArea = safeArea
        self.anchors = anchors
        self.maximumLines = maximumLines
    }
}
