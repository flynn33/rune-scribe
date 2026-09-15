import Foundation
import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

struct ThemePresentationResourcePlan: Equatable, Sendable {
    let codexID: CodexID
    let scriptID: ScriptID
    let fontResourceID: ThemeResourceID?
    let expectedFontPostScriptName: String?
    let vectorResourceIDByToken: [String: ThemeResourceID]
    let backgroundStaticResourceID: ThemeResourceID
    let backgroundReduceMotionResourceID: ThemeResourceID
    let backgroundHighContrastResourceID: ThemeResourceID
    let backgroundMacOSWideResourceID: ThemeResourceID?
    let backgroundRendererParametersResourceID: ThemeResourceID?
    let decorativeHeadingResourceID: ThemeResourceID?
    let unlockAnimationResourceIDByTier: [String: ThemeResourceID]

    init(descriptor: ThemeDescriptor) throws {
        guard let script = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        }) else {
            throw ThemeDescriptorValidationError.unknownReference(
                descriptor.codex.primaryScriptID.rawValue
            )
        }
        codexID = descriptor.codex.id
        scriptID = script.id
        fontResourceID = script.fontResourceID
        expectedFontPostScriptName = script.fontPostScriptName?.rawValue
        vectorResourceIDByToken = Dictionary(
            uniqueKeysWithValues: script.glyphs.compactMap { glyph in
                glyph.vectorResourceID.map { (glyph.textToken, $0) }
            }
        )
        backgroundStaticResourceID = descriptor.codex.background.staticBaseResourceID
        backgroundReduceMotionResourceID = descriptor.codex.background.reduceMotionResourceID
        backgroundHighContrastResourceID = descriptor.codex.background.highContrastResourceID
        backgroundMacOSWideResourceID = descriptor.codex.background.macOSWideResourceID
        backgroundRendererParametersResourceID =
            descriptor.codex.background.rendererParametersResourceID
        decorativeHeadingResourceID = descriptor.resources.first(where: {
            $0.role.rawValue == "decorative-heading-catalog"
        })?.id
        unlockAnimationResourceIDByTier = ThemeUnlockCueSelector.resourceIDsByTier(
            role: "unlock-animation-cue",
            descriptor: descriptor
        )
    }
}

/// A presentation-only description of an image admitted by the Theme runtime.
///
/// The plan intentionally contains identity and integrity metadata rather than
/// bytes or a platform image. `RuneScribeUIRuntime` is responsible for matching
/// a resolved resource against this plan before it publishes an opaque image
/// reference to the UI.
struct ThemeVisualImagePlan: Identifiable, Equatable, Hashable, Sendable {
    let id: ThemeResourceID
    let codexID: CodexID
    let role: ThemeResourceRoleID
    let mediaType: ThemeResourceMediaType
    let byteLength: UInt64
    let pixelSize: ThemePixelSize?
    let sha256: ThemeSHA256Digest

    init(codexID: CodexID, reference: ThemeResourceReference) {
        id = reference.id
        self.codexID = codexID
        role = reference.role
        mediaType = reference.mediaType
        byteLength = reference.integrity.byteLength
        pixelSize = reference.integrity.pixelSize
        sha256 = reference.integrity.sha256
    }
}

enum ThemeVisualArtifactKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case relic = "Relic"
    case seal = "Seal"
    case frame = "Frame"
    case crest = "Crest"

    var systemImage: String {
        switch self {
        case .relic: "rectangle.portrait"
        case .seal: "seal"
        case .frame: "photo.artframe"
        case .crest: "shield"
        }
    }
}

struct ThemeCodexVisualPlan: Equatable, Sendable {
    let codexID: CodexID
    let displayName: String
    let description: String
    let accessibilityLabel: String
    let accessibilityHint: String?
    let card: ThemeVisualImagePlan
    let locked: ThemeVisualImagePlan
    let encountered: ThemeVisualImagePlan
    let selected: ThemeVisualImagePlan
    let unavailable: ThemeVisualImagePlan
}

struct ThemeScriptVisualPlan: Equatable, Sendable {
    let scriptID: ScriptID
    let staticFallback: ThemeVisualImagePlan
    let standardSpecimen: ThemeVisualImagePlan?
    let highContrastSpecimen: ThemeVisualImagePlan?

    var images: [ThemeVisualImagePlan] {
        [staticFallback, standardSpecimen, highContrastSpecimen]
            .compactMap { $0 }
    }
}

enum ThemeChromeVisualSlot: CaseIterable, Equatable, Hashable, Sendable {
    case panelBorder
    case cornerOrnament
    case divider
    case primaryButton
    case tabSelector
}

struct ThemeChromeVisualPlan: Equatable, Sendable {
    let panelBorder: ThemeVisualImagePlan?
    let cornerOrnament: ThemeVisualImagePlan?
    let divider: ThemeVisualImagePlan?
    let primaryButton: ThemeVisualImagePlan?
    let tabSelector: ThemeVisualImagePlan?

    var images: [ThemeVisualImagePlan] {
        [panelBorder, cornerOrnament, divider, primaryButton, tabSelector]
            .compactMap { $0 }
    }

    func image(for slot: ThemeChromeVisualSlot) -> ThemeVisualImagePlan? {
        switch slot {
        case .panelBorder: panelBorder
        case .cornerOrnament: cornerOrnament
        case .divider: divider
        case .primaryButton: primaryButton
        case .tabSelector: tabSelector
        }
    }
}

struct ThemeArtifactVisualPlan: Identifiable, Equatable, Sendable {
    let id: ArtifactID
    let codexID: CodexID
    let kind: ThemeVisualArtifactKind
    let displayName: String
    let description: String
    let facets: [String]
    let rarity: ThemeRarityToken
    let availability: ThemeArtifactAvailability
    let accessibilityLabel: String
    let accessibilityHint: String?
    let rightsID: ThemeProvenanceID
    let primary: ThemeVisualImagePlan
    let thumbnail: ThemeVisualImagePlan
    let standard: ThemeVisualImagePlan
    let highContrast: ThemeVisualImagePlan
    let defaultLayoutID: ThemeLayoutPresetID?
    let layouts: [ThemeShareLayoutPreset]
    let sealAllowedScale: ThemeScalarRange?
    let sealScaleReference: ThemeSealScaleReference?
    let sealAllowedAnchors: [ThemeSealAnchorCategory]
    let compatibleRelicIDs: Set<ArtifactID>
    let allowsStaticShare: Bool

}

/// The complete descriptor-derived image inventory needed by the active UI.
/// Selection and revision are part of the plan so a view never combines image
/// references from one Theme revision with selection metadata from another.
struct ActiveThemeVisualResourcePlan: Equatable, Sendable {
    let revision: UInt64
    let themeID: ThemeID
    let codexID: CodexID
    let codex: ThemeCodexVisualPlan
    let script: ThemeScriptVisualPlan
    let backgroundStatic: ThemeVisualImagePlan
    let backgroundReduceMotion: ThemeVisualImagePlan
    let backgroundHighContrast: ThemeVisualImagePlan
    let chrome: ThemeChromeVisualPlan
    let relics: [ThemeArtifactVisualPlan]
    let seals: [ThemeArtifactVisualPlan]
    let frames: [ThemeArtifactVisualPlan]
    let crests: [ThemeArtifactVisualPlan]
    let selectedRelicID: ArtifactID
    let selectedSealID: ArtifactID?
    let selectedFrameID: ArtifactID?

    var scriptID: ScriptID { script.scriptID }

    var catalog: [ThemeArtifactVisualPlan] {
        relics + seals + frames + crests
    }

    var selectedRelic: ThemeArtifactVisualPlan? {
        relics.first(where: { $0.id == selectedRelicID })
    }

    var selectedSeal: ThemeArtifactVisualPlan? {
        selectedSealID.flatMap { selectedID in
            seals.first(where: { $0.id == selectedID })
        }
    }

    var selectedFrame: ThemeArtifactVisualPlan? {
        selectedFrameID.flatMap { selectedID in
            frames.first(where: { $0.id == selectedID })
        }
    }

    init(
        descriptor: ThemeDescriptor,
        revision: UInt64,
        selection: SharePresentationSelection
    ) throws {
        guard selection.codexID == descriptor.codex.id,
              selection.scriptID == descriptor.codex.primaryScriptID
        else { throw ThemePresentationResourceError.identityMismatch }

        self.revision = revision
        themeID = descriptor.id
        codexID = descriptor.codex.id

        let references = Dictionary(uniqueKeysWithValues: descriptor.resources.map {
            ($0.id, $0)
        })
        func image(_ id: ThemeResourceID) throws -> ThemeVisualImagePlan {
            guard let reference = references[id] else {
                throw ThemePresentationResourceError.missing(id)
            }
            return ThemeVisualImagePlan(codexID: descriptor.codex.id, reference: reference)
        }
        func uniqueImage(role: ThemeResourceRoleID) throws -> ThemeVisualImagePlan? {
            let matches = descriptor.resources.filter { $0.role == role }
            guard matches.count <= 1 else {
                throw ThemePresentationResourceError.identityMismatch
            }
            return matches.first.map {
                ThemeVisualImagePlan(codexID: descriptor.codex.id, reference: $0)
            }
        }
        func artifact(
            _ metadata: ThemeArtifactMetadata,
            kind: ThemeVisualArtifactKind,
            primaryID: ThemeResourceID,
            thumbnailID: ThemeResourceID,
            standardID: ThemeResourceID,
            highContrastID: ThemeResourceID,
            defaultLayoutID: ThemeLayoutPresetID? = nil,
            layouts: [ThemeShareLayoutPreset] = [],
            sealAllowedScale: ThemeScalarRange? = nil,
            sealScaleReference: ThemeSealScaleReference? = nil,
            sealAllowedAnchors: [ThemeSealAnchorCategory] = [],
            compatibleRelicIDs: Set<ArtifactID> = [],
            allowsStaticShare: Bool = true
        ) throws -> ThemeArtifactVisualPlan {
            ThemeArtifactVisualPlan(
                id: metadata.id,
                codexID: metadata.codexID,
                kind: kind,
                displayName: metadata.displayName.fallbackValue,
                description: metadata.description.fallbackValue,
                facets: metadata.facets?.map(\.fallbackValue) ?? [],
                rarity: metadata.rarity,
                availability: metadata.availability,
                accessibilityLabel: metadata.accessibility.label.fallbackValue,
                accessibilityHint: metadata.accessibility.hint?.fallbackValue,
                rightsID: metadata.rightsID,
                primary: try image(primaryID),
                thumbnail: try image(thumbnailID),
                standard: try image(standardID),
                highContrast: try image(highContrastID),
                defaultLayoutID: defaultLayoutID,
                layouts: layouts,
                sealAllowedScale: sealAllowedScale,
                sealScaleReference: sealScaleReference,
                sealAllowedAnchors: sealAllowedAnchors,
                compatibleRelicIDs: compatibleRelicIDs,
                allowsStaticShare: allowsStaticShare
            )
        }

        let vault = descriptor.codex.vault
        codex = ThemeCodexVisualPlan(
            codexID: descriptor.codex.id,
            displayName: descriptor.codex.displayName.fallbackValue,
            description: descriptor.codex.shortDescription.fallbackValue,
            accessibilityLabel: vault.accessibility.label.fallbackValue,
            accessibilityHint: vault.accessibility.hint?.fallbackValue,
            card: try image(vault.cardResourceID),
            locked: try image(vault.lockedSilhouetteResourceID),
            encountered: try image(vault.encounteredResourceID),
            selected: try image(vault.selectedResourceID),
            unavailable: try image(vault.unavailableResourceID ?? vault.cardResourceID)
        )
        guard let primaryScript = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        }) else {
            throw ThemePresentationResourceError.identityMismatch
        }
        script = ThemeScriptVisualPlan(
            scriptID: primaryScript.id,
            staticFallback: try image(primaryScript.staticFallbackResourceID),
            standardSpecimen: try primaryScript.standardSpecimenResourceID.map {
                try image($0)
            },
            highContrastSpecimen: try primaryScript.highContrastSpecimenResourceID.map {
                try image($0)
            }
        )
        backgroundStatic = try image(descriptor.codex.background.staticBaseResourceID)
        backgroundReduceMotion = try image(descriptor.codex.background.reduceMotionResourceID)
        backgroundHighContrast = try image(descriptor.codex.background.highContrastResourceID)
        chrome = ThemeChromeVisualPlan(
            panelBorder: try uniqueImage(role: ThemeResourceRoles.panelCardBorder),
            cornerOrnament: try uniqueImage(role: ThemeResourceRoles.panelCornerOrnament),
            divider: try uniqueImage(role: ThemeResourceRoles.panelDivider),
            primaryButton: try uniqueImage(role: ThemeResourceRoles.panelPrimaryButton),
            tabSelector: try uniqueImage(role: ThemeResourceRoles.panelTabSelector)
        )
        relics = try descriptor.codex.relics.compactMap { relic in
            guard relic.metadata.availability != .reservedInactive else { return nil }
            return try artifact(
                relic.metadata,
                kind: .relic,
                primaryID: relic.primaryResourceID,
                thumbnailID: relic.thumbnailResourceID,
                standardID: relic.staticFallbackResourceID,
                highContrastID: relic.highContrastResourceID,
                defaultLayoutID: relic.defaultLayoutID,
                layouts: relic.layouts
            )
        }
        seals = try descriptor.codex.seals.compactMap { seal in
            guard seal.metadata.availability != .reservedInactive else { return nil }
            return try artifact(
                seal.metadata,
                kind: .seal,
                primaryID: seal.standardResourceID,
                thumbnailID: seal.thumbnailResourceID,
                standardID: seal.standardResourceID,
                highContrastID: seal.standardResourceID,
                sealAllowedScale: seal.allowedScale,
                sealScaleReference: seal.scaleReference,
                sealAllowedAnchors: seal.allowedAnchors
            )
        }
        frames = try descriptor.codex.frames.compactMap { frame in
            guard frame.metadata.availability != .reservedInactive else { return nil }
            return try artifact(
                frame.metadata,
                kind: .frame,
                primaryID: frame.vectorResourceID,
                thumbnailID: frame.thumbnailResourceID ?? frame.staticFallbackResourceID,
                standardID: frame.staticFallbackResourceID,
                highContrastID: frame.staticFallbackResourceID,
                compatibleRelicIDs: Set(frame.compatibleRelicIDs),
                allowsStaticShare: frame.allowsStaticShare
            )
        }
        crests = try descriptor.codex.crests.compactMap { crest in
            guard crest.metadata.availability != .reservedInactive else { return nil }
            return try artifact(
                crest.metadata,
                kind: .crest,
                primaryID: crest.vectorResourceID,
                thumbnailID: crest.thumbnailResourceID ?? crest.staticFallbackResourceID,
                standardID: crest.staticFallbackResourceID,
                highContrastID: crest.staticFallbackResourceID
            )
        }
        selectedRelicID = selection.relicID
        selectedSealID = selection.sealID
        selectedFrameID = selection.frameID

        guard relics.contains(where: { $0.id == selectedRelicID }),
              selectedSealID.map({ id in seals.contains(where: { $0.id == id }) }) ?? true,
              selectedFrameID.map({ id in
                  frames.contains(where: {
                      $0.id == id
                          && $0.allowsStaticShare
                          && $0.compatibleRelicIDs.contains(selectedRelicID)
                  })
              }) ?? true
        else { throw ThemePresentationResourceError.identityMismatch }
    }
}

/// Atomically published UI state. Every reference is revision-bound and was
/// admitted by the runtime against the corresponding pure image plan.
@MainActor
struct ActiveThemeVisualPresentation {
    let revision: UInt64
    let plan: ActiveThemeVisualResourcePlan
    let imageReferences: [ThemeResourceID: RuntimeThemeImageReference]

    init(
        revision: UInt64,
        plan: ActiveThemeVisualResourcePlan,
        imageReferences: [ThemeResourceID: RuntimeThemeImageReference]
    ) {
        precondition(revision == plan.revision)
        self.revision = revision
        self.plan = plan
        self.imageReferences = imageReferences.filter { resourceID, reference in
            resourceID == reference.resourceID
                && reference.codexID == plan.codex.codexID
                && reference.contentRevision == revision
        }
    }

    func imageReference(for imagePlan: ThemeVisualImagePlan) -> RuntimeThemeImageReference? {
        guard imagePlan.codexID == plan.codex.codexID,
              let reference = imageReferences[imagePlan.id],
              reference.codexID == imagePlan.codexID,
              reference.role == imagePlan.role,
              reference.mediaType == imagePlan.mediaType,
              reference.integrity.byteLength == imagePlan.byteLength,
              reference.integrity.pixelSize == imagePlan.pixelSize,
              reference.integrity.sha256 == imagePlan.sha256,
              reference.contentRevision == revision
        else { return nil }
        return reference
    }

    func image(for resourceID: ThemeResourceID) -> Image? {
        imageReferences[resourceID]?.image
    }

    func chromeImageReference(
        for slot: ThemeChromeVisualSlot
    ) -> RuntimeThemeImageReference? {
        guard let imagePlan = plan.chrome.image(for: slot) else { return nil }
        return imageReference(for: imagePlan)
    }
}

enum ThemeUnlockCueSelector {
    static func resourceIDsByTier(
        role: String,
        descriptor: ThemeDescriptor
    ) -> [String: ThemeResourceID] {
        ProgressionRevealTier.allCases.reduce(into: [:]) { result, tier in
            let suffix = resourceSuffix(for: tier)
            let matches = descriptor.resources.filter {
                $0.role.rawValue == role && $0.id.rawValue.hasSuffix(suffix)
            }
            if matches.count == 1 {
                result[tier.rawValue] = matches[0].id
            }
        }
    }

    static func animationDuration(_ data: Data?) -> Double? {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let duration = root["durationSeconds"] as? Double,
              duration.isFinite,
              (0.3 ... 3.0).contains(duration)
        else { return nil }
        return duration
    }

    private static func resourceSuffix(for tier: ProgressionRevealTier) -> String {
        switch tier {
        case .micro: "reveal-minor"
        case .artifact: "reveal-relic"
        case .codex: "reveal-codex"
        case .mastery: "reveal-mastery"
        }
    }
}

enum ThemeHeadingSlot: String, CaseIterable, Sendable {
    case workspace = "workspace.main"
    case settings
    case receivedMessage = "received-message"
    case contacts
    case qrScan = "qr-scan"
    case share
    case license
    case `import`
    case cipherLibrary = "cipher-library"
    case frameBrowser = "frame-browser"
    case appLocked = "app-locked"
    case pinSet = "pin-set"
    case pinChange = "pin-change"
    case pinDisable = "pin-disable"
    case vault
}

@MainActor
enum RuneThemeHeadingInterpreter {
    private(set) static var current: [ThemeHeadingSlot: String] = [:]
    private static var providerFallbacks: [ThemeHeadingSlot: String] = [:]
    private static let fallbackWords: [ThemeHeadingSlot: String] = [
        .workspace: "RUNE SCRIBE",
        .settings: "SETTINGS",
        .receivedMessage: "MESSAGE",
        .contacts: "CONTACTS",
        .qrScan: "SCAN",
        .share: "SHARE",
        .license: "LICENSE",
        .import: "IMPORT",
        .cipherLibrary: "CIPHERS",
        .frameBrowser: "FRAME",
        .appLocked: "RUNE LOCK",
        .pinSet: "SET PIN",
        .pinChange: "CHANGE",
        .pinDisable: "DISABLE",
        .vault: "VAULT",
    ]

    static func install(_ data: Data?, descriptor: ThemeDescriptor? = nil) {
        providerFallbacks = descriptor.map(makeProviderFallbacks) ?? [:]
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let rawSlots = root["decorativeHeadingSlots"] as? [String: String]
        else {
            current = [:]
            return
        }
        current = Dictionary(uniqueKeysWithValues: rawSlots.compactMap { raw, value in
            guard let slot = ThemeHeadingSlot(rawValue: raw),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (slot, value)
        })
    }

    static func value(for slot: ThemeHeadingSlot, fallback: String) -> String {
        current[slot] ?? providerFallbacks[slot] ?? fallback
    }

    static func reset() {
        current = [:]
        providerFallbacks = [:]
    }

    private static func makeProviderFallbacks(
        descriptor: ThemeDescriptor
    ) -> [ThemeHeadingSlot: String] {
        guard let script = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        }) else { return [:] }
        let glyphs = Dictionary(
            uniqueKeysWithValues: script.glyphs.map { ($0.canonicalValue, $0.textToken) }
        )
        return Dictionary(uniqueKeysWithValues: fallbackWords.compactMap { slot, word in
            makeProviderHeading(word, glyphs: glyphs).map { (slot, $0) }
        })
    }

    private static func makeProviderHeading(
        _ word: String,
        glyphs: [UInt8: String]
    ) -> String? {
        var heading = ""
        for scalar in word.unicodeScalars {
            if scalar == " " {
                heading.append(" ")
                continue
            }
            guard scalar.value >= 65,
                  scalar.value <= 90,
                  let token = glyphs[UInt8(scalar.value - 65)]
            else { return nil }
            heading.append(token)
        }
        return heading
    }
}

@MainActor
enum RuntimeThemeSemanticResourceUseObservation {
    private static var observer: ((ThemeResourceID) -> Void)?

    static func begin(_ observer: @escaping (ThemeResourceID) -> Void) {
        self.observer = observer
    }

    static func end() {
        observer = nil
    }

    @discardableResult
    static func report(_ resourceID: ThemeResourceID) -> Bool {
        guard let observer else { return false }
        observer(resourceID)
        return true
    }
}

struct ThemeScriptPresentation: Equatable, Sendable {
    static let baseFallback = ThemeScriptPresentation(
        scriptID: ScriptID(rawValue: "script.base-runes")!,
        fontPostScriptName: "NotoSansRunic-Regular",
        fontResourceID: nil,
        vectorDataByToken: [:],
        vectorResourceIDByToken: [:]
    )

    let scriptID: ScriptID
    let fontPostScriptName: String
    let fontResourceID: ThemeResourceID?
    let vectorDataByToken: [String: Data]
    let vectorResourceIDByToken: [String: ThemeResourceID]
}

enum ThemePresentationResourceError: Error, Equatable, Sendable {
    case missing(ThemeResourceID)
    case identityMismatch
    case fontIdentityMismatch
    case stateUnavailable
}

enum ThemeScriptFontSelector {
    static func postScriptName(
        themePostScriptName: String,
        cipherFontName: String?,
        cipherFontSource: FontSourceDTO?,
        cipherFontIsRegistered: Bool = true
    ) -> String {
        if cipherFontSource == .imported,
           cipherFontIsRegistered,
           let cipherFontName {
            return cipherFontName
        }
        return themePostScriptName
    }

    static func usesThemeVectors(
        cipherFontSource: FontSourceDTO?,
        cipherFontIsRegistered: Bool = true
    ) -> Bool {
        cipherFontSource != .imported || !cipherFontIsRegistered
    }
}

/// Interprets runtime-owned semantic Theme tokens for the shared UI scaffold.
/// The fallback preserves the current Base appearance while previews and tests
/// are not attached to a running Theme Coordinator.
@MainActor
enum RuneThemePaletteInterpreter {
    private(set) static var current = fallback
    private(set) static var fontPostScriptName = "NotoSansRunic-Regular"

    static func install(_ descriptor: ThemeDescriptor) {
        current = descriptor.codex.palette
        fontPostScriptName = descriptor.codex.scripts.first(where: {
            $0.id == descriptor.codex.primaryScriptID
        })?.fontPostScriptName?.rawValue ?? "NotoSansRunic-Regular"
    }

    static func reset() {
        current = fallback
        fontPostScriptName = "NotoSansRunic-Regular"
    }

    static func rgba(
        _ color: ThemeSemanticColor
    ) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let digits = String(color.rawValue.dropFirst())
        let value = UInt64(digits, radix: 16)!
        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64
        if digits.count == 8 {
            red = (value >> 24) & 0xff
            green = (value >> 16) & 0xff
            blue = (value >> 8) & 0xff
            alpha = value & 0xff
        } else {
            red = (value >> 16) & 0xff
            green = (value >> 8) & 0xff
            blue = value & 0xff
            alpha = 0xff
        }
        return (
            Double(red) / 255,
            Double(green) / 255,
            Double(blue) / 255,
            Double(alpha) / 255
        )
    }

    private static let fallback: ThemeSemanticPalette = {
        let color: (String) -> ThemeSemanticColor = {
            ThemeSemanticColor(rawValue: $0)!
        }
        return try! ThemeSemanticPalette(
            backgroundPrimary: color("#080A1E"),
            backgroundSecondary: color("#14082E"),
            surfacePrimary: color("#1A1E30"),
            surfaceElevated: color("#1A1E30"),
            textPrimary: color("#FFFFFF"),
            textSecondary: color("#A0A8B8"),
            textInverse: color("#080A1E"),
            accentPrimary: color("#D4971A"),
            accentSecondary: color("#3A7FD5"),
            success: color("#34C759"),
            warning: color("#D4971A"),
            danger: color("#FF3B30"),
            information: color("#3A7FD5"),
            locked: color("#A0A8B8"),
            encountered: color("#3A7FD5"),
            unavailable: color("#8E8E93"),
            selected: color("#D4971A"),
            focus: color("#EEBE45"),
            keyboardFocus: color("#3A7FD5"),
            rarityAccents: [
                ThemeRarityAccent(rarity: .forged, color: color("#A0A8B8")),
                ThemeRarityAccent(rarity: .inscribed, color: color("#3A7FD5")),
                ThemeRarityAccent(rarity: .rare, color: color("#D4971A")),
                ThemeRarityAccent(rarity: .mythic, color: color("#EEBE45")),
            ]
        )
    }()
}

@MainActor
extension Color {
    static var runeNavy: Color {
        Color(theme: RuneThemePaletteInterpreter.current.backgroundPrimary)
    }

    static var runeBackgroundSecondary: Color {
        Color(theme: RuneThemePaletteInterpreter.current.backgroundSecondary)
    }

    static var runeGold: Color {
        Color(theme: RuneThemePaletteInterpreter.current.accentPrimary)
    }

    static var runeGoldBright: Color {
        Color(theme: RuneThemePaletteInterpreter.current.focus)
    }

    static var runeBlue: Color {
        Color(theme: RuneThemePaletteInterpreter.current.information)
    }

    static var runeAccentSecondary: Color {
        Color(theme: RuneThemePaletteInterpreter.current.accentSecondary)
    }

    static var runeSilver: Color {
        Color(theme: RuneThemePaletteInterpreter.current.textSecondary)
    }

    static var runeParchment: Color {
        Color(theme: RuneThemePaletteInterpreter.current.surfacePrimary)
    }

    static var runeSurfaceElevated: Color {
        Color(theme: RuneThemePaletteInterpreter.current.surfaceElevated)
    }

    static var runeTextPrimary: Color {
        Color(theme: RuneThemePaletteInterpreter.current.textPrimary)
    }

    static var runeTextInverse: Color {
        Color(theme: RuneThemePaletteInterpreter.current.textInverse)
    }

    static var runeSuccess: Color {
        Color(theme: RuneThemePaletteInterpreter.current.success)
    }

    static var runeWarning: Color {
        Color(theme: RuneThemePaletteInterpreter.current.warning)
    }

    static var runeDanger: Color {
        Color(theme: RuneThemePaletteInterpreter.current.danger)
    }

    static var runeUnavailable: Color {
        Color(theme: RuneThemePaletteInterpreter.current.unavailable)
    }

    static var runeLocked: Color {
        Color(theme: RuneThemePaletteInterpreter.current.locked)
    }

    static var runeEncountered: Color {
        Color(theme: RuneThemePaletteInterpreter.current.encountered)
    }

    static var runeSelected: Color {
        Color(theme: RuneThemePaletteInterpreter.current.selected)
    }

    static var runeFocus: Color {
        Color(theme: RuneThemePaletteInterpreter.current.focus)
    }

    static var runeKeyboardFocus: Color {
        Color(theme: RuneThemePaletteInterpreter.current.keyboardFocus)
    }

    static func runeRarity(_ rarity: ThemeRarityToken) -> Color {
        let semantic = RuneThemePaletteInterpreter.current.rarityAccents.first {
            $0.rarity == rarity
        }?.color ?? RuneThemePaletteInterpreter.current.textSecondary
        return Color(theme: semantic)
    }

    private init(theme: ThemeSemanticColor) {
        let components = RuneThemePaletteInterpreter.rgba(theme)
        self.init(
            .sRGB,
            red: components.red,
            green: components.green,
            blue: components.blue,
            opacity: components.alpha
        )
    }
}
