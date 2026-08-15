import Foundation
import RuneScribeContracts

public enum NorseBaseThemeDescriptorFactory {
    public static let discoveryDescriptor: ThemeDescriptor = {
        do {
            return try make()
        } catch {
            preconditionFailure("Invalid frozen Norse Base Theme descriptor: \(error)")
        }
    }()

    public static func make() throws -> ThemeDescriptor {
        let codexID = RuneScribeCodexIDs.norse
        let presentationRightsID = provenanceID("rights.norse.base")
        let fontRightsID = provenanceID("rights.norse.font.noto")
        let scriptID = ScriptID(rawValue: "script.base-runes")!

        let script = try ThemeScriptDescriptor(
            id: scriptID,
            displayName: localized("script.base-runes.name", "Base Rune Script"),
            portability: .unicodePortable,
            glyphs: try ThemeCanonicalSymbolSet.transportTokens.enumerated().map {
                index, token in
                try ThemeScriptGlyph(
                    canonicalValue: UInt8(index),
                    glyphID: glyphID(String(format: "glyph.base-runes.%02d", index)),
                    textToken: token
                )
            },
            fontResourceID: NorseBaseThemeResourceIDs.font,
            fontReferenceID: ThemeFontReferenceID(rawValue: "noto-sans-runic")!,
            fontVersion: 1,
            fontPostScriptName: ThemeFontPostScriptName(
                rawValue: "NotoSansRunic-Regular"
            ),
            staticFallbackResourceID: NorseBaseThemeResourceIDs.scriptFallback,
            fallbackScriptID: scriptID,
            recommendedPointSizes: ThemeScalarRange(minimum: 12, maximum: 64),
            accessibility: accessibility(
                "script.base-runes",
                label: "Base Rune Script",
                hint: "Presents the canonical 32-value Rune Scribe mapping.",
                hidesRedundantGlyphs: true
            ),
            rightsID: fontRightsID
        )

        let relics = try makeRelics(codexID: codexID, rightsID: presentationRightsID)
        let seals = try makeSeals(codexID: codexID, rightsID: presentationRightsID)
        let background = try ThemeBackgroundDescriptor(
            id: ThemeBackgroundID(rawValue: "background.norse.rune-metal")!,
            displayName: localized("background.norse.name", "Rune Background"),
            staticBaseResourceID: NorseBaseThemeResourceIDs.backgroundStatic,
            reduceMotionResourceID: NorseBaseThemeResourceIDs.backgroundReduceMotion,
            highContrastResourceID: NorseBaseThemeResourceIDs.backgroundHighContrast,
            optionalMotionResourceID: nil,
            rendererParametersResourceID: NorseBaseThemeResourceIDs.backgroundParameters,
            motionIntensity: .subtle,
            performanceClass: .standard,
            parallaxAllowed: false,
            accessibility: accessibility(
                "background.norse",
                label: "Norse rune background",
                hint: "Provides the current Rune Scribe background treatment."
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
            accessibility: accessibility(
                "vault.norse",
                label: "Norse Codex collection",
                hint: "Shows Base Codex ownership and selection states without relying on color alone."
            ),
            rightsID: presentationRightsID
        )

        let codex = try ThemeCodexDescriptor(
            id: codexID,
            entitlementID: RuneScribeUnlockIDs.norseCodex,
            displayName: localized("codex.norse.name", "Norse Codex"),
            shortDescription: localized(
                "codex.norse.description.short",
                "Rune Scribe's permanent Base Codex."
            ),
            longDescription: localized(
                "codex.norse.description.long",
                "The permanent Base Codex extracted from Rune Scribe's current presentation."
            ),
            accessibility: accessibility(
                "codex.norse",
                label: "Norse Base Codex",
                hint: "Uses the permanent Base Codex presentation."
            ),
            palette: try palette(),
            primaryScriptID: scriptID,
            fallbackScriptID: scriptID,
            defaultRelicID: ArtifactID(rawValue: "relic.norse.runestone.weathered")!,
            scripts: [script],
            relics: relics,
            seals: seals,
            frames: [],
            crests: [],
            background: background,
            vault: vault,
            rightsID: presentationRightsID
        )

        let resources = try NorseBaseThemeResourceCatalog.references(
            fontRightsID: fontRightsID,
            presentationRightsID: presentationRightsID
        )

        return try ThemeDescriptor(
            id: ThemeID(rawValue: "theme.norse.base")!,
            moduleID: ThemeModuleID(rawValue: RuneScribeModuleIDs.norseTheme.rawValue)!,
            moduleRole: ThemeModuleRoleID(rawValue: RuneScribeRoles.norseTheme.rawValue)!,
            policyClass: ThemeDescriptor.providerPolicyClass,
            criticality: .requiredBase,
            schemaVersion: ThemeContractVersion.current,
            contentVersion: 1,
            minimumUIContractVersion: ThemeContractVersion.current,
            platformCompatibility: [
                try ThemePlatformCompatibility(platform: .iOS, minimumMajorVersion: 17),
                try ThemePlatformCompatibility(platform: .macOS, minimumMajorVersion: 15),
            ],
            fallbackCodexID: codexID,
            codex: codex,
            resources: resources,
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
                    creatorTool: "Rune Scribe repository extraction",
                    creationDate: "2026-08-15",
                    origin: .derived,
                    rightsOwner: "Raven Forge Studios",
                    sourceReference: "RuneTheme.swift; RuneScribButtonStyle.swift; Shaders.metal; progression catalog",
                    exportSettings: "deterministic semantic JSON version 1.0",
                    licenseNotice: "All rights reserved."
                ),
                try ThemeRightsMetadata(
                    id: fontRightsID,
                    creatorTool: "Noto Sans Runic source distribution",
                    creationDate: "2026-06-19",
                    origin: .derived,
                    rightsOwner: "The Noto Project Authors",
                    sourceReference: "RuneScrib/Resources/Fonts/NotoSansRunic-Regular.ttf",
                    exportSettings: "exact byte-preserving copy",
                    licenseNotice: "SIL Open Font License 1.1; see RuneScrib/Resources/Fonts/OFL.txt"
                ),
            ]
        )
    }

    private static func makeRelics(
        codexID: CodexID,
        rightsID: ThemeProvenanceID
    ) throws -> [ThemeRelicDescriptor] {
        let definitions: [(String, String, String, ThemeRarityToken, ThemeArtifactAvailability, Bool, UInt16, UInt16)] = [
            (
                "relic.norse.runestone.weathered",
                "Weathered Rune Stone",
                "The default Base Codex Rune Stone presentation.",
                .forged,
                .included,
                true,
                4,
                5
            ),
            (
                "relic.norse.raven-medallion",
                "Raven Medallion",
                "A round medallion Relic presentation.",
                .inscribed,
                .earned,
                false,
                1,
                1
            ),
            (
                "relic.norse.sealed-parchment",
                "Sealed Parchment",
                "A sealed parchment Relic presentation.",
                .inscribed,
                .earned,
                false,
                4,
                3
            ),
        ]
        return try definitions.map {
            rawID, name, description, rarity, availability, isDefault, width, height in
            let artifactID = ArtifactID(rawValue: rawID)!
            let resources = NorseBaseThemeResourceIDs.relicResourceIDs[artifactID]!
            let key = rawID
            let layout = try layout(
                id: ThemeLayoutPresetID(rawValue: "layout.\(rawID)")!,
                width: width,
                height: height
            )
            return try ThemeRelicDescriptor(
                metadata: artifact(
                    id: artifactID,
                    codexID: codexID,
                    key: key,
                    name: name,
                    description: description,
                    rarity: rarity,
                    availability: availability,
                    accessibilityHint: isDefault
                        ? "Uses the default upright stone conformance silhouette."
                        : "Uses a distinct Base Codex conformance silhouette.",
                    rightsID: rightsID
                ),
                isDefault: isDefault,
                primaryResourceID: resources.primary,
                thumbnailResourceID: resources.thumbnail,
                staticFallbackResourceID: resources.staticFallback,
                highContrastResourceID: resources.highContrast,
                defaultLayoutID: layout.id,
                layouts: [layout]
            )
        }
    }

    private static func makeSeals(
        codexID: CodexID,
        rightsID: ThemeProvenanceID
    ) throws -> [ThemeSealDescriptor] {
        let definitions: [(String, String, ThemeRarityToken, ThemeArtifactAvailability)] = [
            ("seal.norse.knotwork", "Knotwork Mark", .forged, .included),
            ("seal.norse.forge-flame", "Forge Flame", .forged, .included),
            ("seal.norse.raven", "Raven Seal", .inscribed, .earned),
            ("seal.norse.longship", "Longship Seal", .inscribed, .earned),
            ("seal.norse.forge-hammer", "Forge Hammer Seal", .inscribed, .earned),
            ("seal.norse.echo-rune", "Echo Rune Seal", .rare, .earned),
        ]
        return try definitions.map { rawID, name, rarity, availability in
            let artifactID = ArtifactID(rawValue: rawID)!
            let resources = NorseBaseThemeResourceIDs.sealResourceIDs[artifactID]!
            return try ThemeSealDescriptor(
                metadata: artifact(
                    id: artifactID,
                    codexID: codexID,
                    key: rawID,
                    name: name,
                    description: "The \(name).",
                    rarity: rarity,
                    availability: availability,
                    accessibilityHint: "Places the \(name) mark at an approved anchor.",
                    rightsID: rightsID
                ),
                vectorResourceID: resources.vector,
                monochromeFallbackResourceID: resources.monochrome,
                thumbnailResourceID: resources.thumbnail,
                allowedScale: ThemeScalarRange(minimum: 0.1, maximum: 0.3),
                scaleReference: .relicShortEdge,
                allowedAnchors: [.lowerLeft, .lowerRight, .bottomCenter, .topCenter]
            )
        }
    }

    private static func layout(
        id: ThemeLayoutPresetID,
        width: UInt16,
        height: UInt16
    ) throws -> ThemeShareLayoutPreset {
        try ThemeShareLayoutPreset(
            id: id,
            aspectRatio: ThemeAspectRatio(width: width, height: height),
            relicBounds: ThemeNormalizedRegion(x: 0, y: 0, width: 1, height: 1),
            contentSafeRegion: ThemeNormalizedRegion(
                x: 0.05,
                y: 0.05,
                width: 0.9,
                height: 0.85
            ),
            glyphSafeRegion: ThemeNormalizedRegion(
                x: 0.12,
                y: 0.12,
                width: 0.76,
                height: 0.5
            ),
            sealAnchors: [
                ThemeSealAnchor(
                    category: .lowerLeft,
                    point: try ThemeNormalizedPoint(x: 0.15, y: 0.82)
                ),
                ThemeSealAnchor(
                    category: .lowerRight,
                    point: try ThemeNormalizedPoint(x: 0.85, y: 0.82)
                ),
                ThemeSealAnchor(
                    category: .bottomCenter,
                    point: try ThemeNormalizedPoint(x: 0.5, y: 0.82)
                ),
                ThemeSealAnchor(
                    category: .topCenter,
                    point: try ThemeNormalizedPoint(x: 0.5, y: 0.08)
                ),
            ],
            maximumGlyphLines: 8,
            minimumGlyphScale: 0.5,
            overflowBehavior: .standardAlternate,
            attributionRegion: ThemeNormalizedRegion(
                x: 0.05,
                y: 0.93,
                width: 0.9,
                height: 0.05
            ),
            provenanceRegion: ThemeNormalizedRegion(
                x: 0.05,
                y: 0.87,
                width: 0.4,
                height: 0.04
            ),
            serialNumberRegion: ThemeNormalizedRegion(
                x: 0.55,
                y: 0.87,
                width: 0.4,
                height: 0.04
            ),
            qrSafeRegion: ThemeNormalizedRegion(
                x: 0.72,
                y: 0.64,
                width: 0.16,
                height: 0.16
            ),
            thumbnailCrop: ThemeNormalizedRegion(x: 0, y: 0, width: 1, height: 1)
        )
    }

    private static func artifact(
        id: ArtifactID,
        codexID: CodexID,
        key: String,
        name: String,
        description: String,
        rarity: ThemeRarityToken,
        availability: ThemeArtifactAvailability,
        accessibilityHint: String,
        rightsID: ThemeProvenanceID
    ) throws -> ThemeArtifactMetadata {
        try ThemeArtifactMetadata(
            id: id,
            codexID: codexID,
            displayName: localized("\(key).name", name),
            description: localized("\(key).description", description),
            rarity: rarity,
            availability: availability,
            accessibility: accessibility(
                key,
                label: name,
                hint: accessibilityHint
            ),
            rightsID: rightsID
        )
    }

    private static func accessibility(
        _ keyPrefix: String,
        label: String,
        hint: String,
        hidesRedundantGlyphs: Bool = false
    ) throws -> ThemeAccessibilityMetadata {
        try ThemeAccessibilityMetadata(
            label: localized("\(keyPrefix).accessibility-label", label),
            hint: localized("\(keyPrefix).accessibility-hint", hint),
            hidesRedundantGlyphs: hidesRedundantGlyphs,
            noColorOnlyState: true,
            dynamicTypeSafe: true
        )
    }

    private static func localized(
        _ key: String,
        _ fallbackValue: String
    ) throws -> ThemeLocalizedText {
        try ThemeLocalizedText(
            key: ThemeLocalizationKey(rawValue: key)!,
            fallbackValue: fallbackValue
        )
    }

    private static func palette() throws -> ThemeSemanticPalette {
        let colors: [String: ThemeSemanticColor] = Dictionary(uniqueKeysWithValues: [
            "backgroundPrimary": "#080A1E",
            "backgroundSecondary": "#14082E",
            "surfacePrimary": "#1A1E30",
            "surfaceElevated": "#1A1E30",
            "textPrimary": "#FFFFFF",
            "textSecondary": "#A0A8B8",
            "textInverse": "#080A1E",
            "accentPrimary": "#D4971A",
            "accentSecondary": "#3A7FD5",
            "success": "#34C759",
            "warning": "#D4971A",
            "danger": "#FF3B30",
            "information": "#3A7FD5",
            "locked": "#A0A8B8",
            "encountered": "#3A7FD5",
            "unavailable": "#8E8E93",
            "selected": "#D4971A",
            "focus": "#EEBE45",
            "keyboardFocus": "#3A7FD5",
        ].map { ($0.key, ThemeSemanticColor(rawValue: $0.value)!) })
        return try ThemeSemanticPalette(
            backgroundPrimary: colors["backgroundPrimary"]!,
            backgroundSecondary: colors["backgroundSecondary"]!,
            surfacePrimary: colors["surfacePrimary"]!,
            surfaceElevated: colors["surfaceElevated"]!,
            textPrimary: colors["textPrimary"]!,
            textSecondary: colors["textSecondary"]!,
            textInverse: colors["textInverse"]!,
            accentPrimary: colors["accentPrimary"]!,
            accentSecondary: colors["accentSecondary"]!,
            success: colors["success"]!,
            warning: colors["warning"]!,
            danger: colors["danger"]!,
            information: colors["information"]!,
            locked: colors["locked"]!,
            encountered: colors["encountered"]!,
            unavailable: colors["unavailable"]!,
            selected: colors["selected"]!,
            focus: colors["focus"]!,
            keyboardFocus: colors["keyboardFocus"]!,
            rarityAccents: [
                ThemeRarityAccent(rarity: .forged, color: colors["textSecondary"]!),
                ThemeRarityAccent(rarity: .inscribed, color: colors["accentSecondary"]!),
                ThemeRarityAccent(rarity: .rare, color: colors["accentPrimary"]!),
                ThemeRarityAccent(rarity: .mythic, color: colors["focus"]!),
            ]
        )
    }

    private static func provenanceID(_ value: String) -> ThemeProvenanceID {
        ThemeProvenanceID(rawValue: value)!
    }

    private static func glyphID(_ value: String) -> ThemeGlyphID {
        ThemeGlyphID(rawValue: value)!
    }
}
