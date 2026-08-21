public enum NorseApplicationResourceCatalog {
    public static let moduleManifest = resource("module-manifest", "json")
    public static let integrityManifest = resource("Norse-Resource-Integrity-Manifest-v1.0", "json")

    public static let accessibilityNorseEn = resource("norse-accessibility.en", "json")
    public static let backgroundForgeStatic = resource("background.norse.forge.static", "png")
    public static let backgroundHighContrast = resource("background.norse.high-contrast", "png")
    public static let backgroundProfile = resource("Norse-Background-Profile-v1.0", "json")
    public static let codexCard = resource("codex-card.norse.v1", "png")
    public static let codexSilhouette = resource("codex-silhouette.norse.v1", "png")
    public static let crestForgeMasterStatic = resource("crest.norse.forge-master", "png")
    public static let crestForgeMasterVector = resource("crest.norse.forge-master", "pdf")
    public static let effectRevealCodex = resource("effect.norse.reveal-codex", "json")
    public static let effectRevealMastery = resource("effect.norse.reveal-mastery", "json")
    public static let effectRevealMinor = resource("effect.norse.reveal-minor", "json")
    public static let effectRevealRelic = resource("effect.norse.reveal-relic", "json")
    public static let notoSansRunic = resource("NotoSansRunic-Regular", "ttf")
    public static let frameCarvedKnotworkStatic = resource("frame.norse.carved-knotwork", "png")
    public static let frameCarvedKnotworkVector = resource("frame.norse.carved-knotwork", "pdf")
    public static let headings = resource("Norse-Decorative-Heading-Slots-v1.0", "json")
    public static let localizationNorseEn = resource("norse-content.en", "json")
    public static let semanticPalette = resource("Norse-Semantic-Palette-v1.0", "json")
    public static let progressionBindings = resource("Norse-Progression-Bindings-v1.0", "json")
    public static let relicIronboundShieldArt = resource("relic.norse.ironbound-shield", "png")
    public static let relicIronboundShieldGeometry = resource("relic.norse.ironbound-shield.geometry", "json")
    public static let relicRavenMedallionArt = resource("relic.norse.raven-medallion", "png")
    public static let relicRavenMedallionGeometry = resource("relic.norse.raven-medallion.geometry", "json")
    public static let relicBlackstoneArt = resource("relic.norse.runestone.blackstone", "png")
    public static let relicBlackstoneGeometry = resource("relic.norse.runestone.blackstone.geometry", "json")
    public static let relicFrozenArt = resource("relic.norse.runestone.frozen", "png")
    public static let relicFrozenGeometry = resource("relic.norse.runestone.frozen.geometry", "json")
    public static let relicWeatheredArt = resource("relic.norse.runestone.weathered", "png")
    public static let relicWeatheredGeometry = resource("relic.norse.runestone.weathered.geometry", "json")
    public static let relicSealedParchmentArt = resource("relic.norse.sealed-parchment", "png")
    public static let relicSealedParchmentGeometry = resource("relic.norse.sealed-parchment.geometry", "json")
    public static let scriptMapping = resource("Norse-Script-Mapping-v1.0", "json")
    public static let scriptSpecimen = resource("script.base-runes.specimen", "png")
    public static let sealEchoRuneThumbnail = resource("seal.norse.echo-rune", "png")
    public static let sealEchoRuneVector = resource("seal.norse.echo-rune", "pdf")
    public static let sealForgeFlameThumbnail = resource("seal.norse.forge-flame", "png")
    public static let sealForgeFlameVector = resource("seal.norse.forge-flame", "pdf")
    public static let sealForgeHammerThumbnail = resource("seal.norse.forge-hammer", "png")
    public static let sealForgeHammerVector = resource("seal.norse.forge-hammer", "pdf")
    public static let sealKnotworkThumbnail = resource("seal.norse.knotwork", "png")
    public static let sealKnotworkVector = resource("seal.norse.knotwork", "pdf")
    public static let sealLongshipThumbnail = resource("seal.norse.longship", "png")
    public static let sealLongshipVector = resource("seal.norse.longship", "pdf")
    public static let sealRavenThumbnail = resource("seal.norse.raven", "png")
    public static let sealRavenVector = resource("seal.norse.raven", "pdf")
    public static let shareFallbackIronboundShield = resource("share-fallback.norse.ironbound-shield", "png")
    public static let shareFallbackRavenMedallion = resource("share-fallback.norse.raven-medallion", "png")
    public static let shareFallbackBlackstone = resource("share-fallback.norse.runestone.blackstone", "png")
    public static let shareFallbackFrozen = resource("share-fallback.norse.runestone.frozen", "png")
    public static let shareFallbackWeathered = resource("share-fallback.norse.runestone.weathered", "png")
    public static let shareFallbackSealedParchment = resource("share-fallback.norse.sealed-parchment", "png")
    public static let soundUnlockCodex = resource("sound.norse.unlock-codex", "wav")
    public static let soundUnlockMastery = resource("sound.norse.unlock-mastery", "wav")
    public static let soundUnlockMinor = resource("sound.norse.unlock-minor", "wav")
    public static let soundUnlockRelic = resource("sound.norse.unlock-relic", "wav")

    public static let resourcesByHandle: [String: ApplicationResource] = [
        "resource.accessibility.norse.en": accessibilityNorseEn,
        "resource.background.norse.forge.static": backgroundForgeStatic,
        "resource.background.norse.high-contrast": backgroundHighContrast,
        "resource.background.norse.profile": backgroundProfile,
        "resource.codex-card.norse": codexCard,
        "resource.codex-silhouette.norse": codexSilhouette,
        "resource.crest.norse.forge-master.static-fallback": crestForgeMasterStatic,
        "resource.crest.norse.forge-master.vector": crestForgeMasterVector,
        "resource.effect.norse.reveal-codex": effectRevealCodex,
        "resource.effect.norse.reveal-mastery": effectRevealMastery,
        "resource.effect.norse.reveal-minor": effectRevealMinor,
        "resource.effect.norse.reveal-relic": effectRevealRelic,
        "resource.font.norse.noto-sans-runic": notoSansRunic,
        "resource.frame.norse.carved-knotwork.static-fallback": frameCarvedKnotworkStatic,
        "resource.frame.norse.carved-knotwork.vector": frameCarvedKnotworkVector,
        "resource.headings.norse": headings,
        "resource.localization.norse.en": localizationNorseEn,
        "resource.palette.norse.semantic": semanticPalette,
        "resource.progression-bindings.norse": progressionBindings,
        "resource.relic.norse.ironbound-shield.art": relicIronboundShieldArt,
        "resource.relic.norse.ironbound-shield.geometry": relicIronboundShieldGeometry,
        "resource.relic.norse.raven-medallion.art": relicRavenMedallionArt,
        "resource.relic.norse.raven-medallion.geometry": relicRavenMedallionGeometry,
        "resource.relic.norse.runestone.blackstone.art": relicBlackstoneArt,
        "resource.relic.norse.runestone.blackstone.geometry": relicBlackstoneGeometry,
        "resource.relic.norse.runestone.frozen.art": relicFrozenArt,
        "resource.relic.norse.runestone.frozen.geometry": relicFrozenGeometry,
        "resource.relic.norse.runestone.weathered.art": relicWeatheredArt,
        "resource.relic.norse.runestone.weathered.geometry": relicWeatheredGeometry,
        "resource.relic.norse.sealed-parchment.art": relicSealedParchmentArt,
        "resource.relic.norse.sealed-parchment.geometry": relicSealedParchmentGeometry,
        "resource.script.norse.mapping": scriptMapping,
        "resource.script.norse.specimen": scriptSpecimen,
        "resource.seal.norse.echo-rune.thumbnail": sealEchoRuneThumbnail,
        "resource.seal.norse.echo-rune.vector": sealEchoRuneVector,
        "resource.seal.norse.forge-flame.thumbnail": sealForgeFlameThumbnail,
        "resource.seal.norse.forge-flame.vector": sealForgeFlameVector,
        "resource.seal.norse.forge-hammer.thumbnail": sealForgeHammerThumbnail,
        "resource.seal.norse.forge-hammer.vector": sealForgeHammerVector,
        "resource.seal.norse.knotwork.thumbnail": sealKnotworkThumbnail,
        "resource.seal.norse.knotwork.vector": sealKnotworkVector,
        "resource.seal.norse.longship.thumbnail": sealLongshipThumbnail,
        "resource.seal.norse.longship.vector": sealLongshipVector,
        "resource.seal.norse.raven.thumbnail": sealRavenThumbnail,
        "resource.seal.norse.raven.vector": sealRavenVector,
        "resource.share-fallback.norse.ironbound-shield": shareFallbackIronboundShield,
        "resource.share-fallback.norse.raven-medallion": shareFallbackRavenMedallion,
        "resource.share-fallback.norse.runestone.blackstone": shareFallbackBlackstone,
        "resource.share-fallback.norse.runestone.frozen": shareFallbackFrozen,
        "resource.share-fallback.norse.runestone.weathered": shareFallbackWeathered,
        "resource.share-fallback.norse.sealed-parchment": shareFallbackSealedParchment,
        "resource.sound.norse.unlock-codex": soundUnlockCodex,
        "resource.sound.norse.unlock-mastery": soundUnlockMastery,
        "resource.sound.norse.unlock-minor": soundUnlockMinor,
        "resource.sound.norse.unlock-relic": soundUnlockRelic,
    ]

    private static func resource(_ name: String, _ fileExtension: String) -> ApplicationResource {
        ApplicationResource(
            name: name,
            fileExtension: fileExtension,
            ownerModuleID: RuneScribeModuleIDs.norseTheme
        )
    }
}
