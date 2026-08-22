import Foundation
import RuneScribeContracts
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
    case appLocked = "app-locked"
    case pinSet = "pin-set"
    case pinChange = "pin-change"
    case pinDisable = "pin-disable"
    case vault
}

@MainActor
enum RuneThemeHeadingInterpreter {
    private(set) static var current: [ThemeHeadingSlot: String] = [:]

    static func install(_ data: Data?) {
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
        current[slot] ?? fallback
    }

    static func reset() { current = [:] }
}

struct ThemeScriptPresentation: Equatable, Sendable {
    static let baseFallback = ThemeScriptPresentation(
        scriptID: ScriptID(rawValue: "script.base-runes")!,
        fontPostScriptName: "NotoSansRunic-Regular",
        vectorDataByToken: [:]
    )

    let scriptID: ScriptID
    let fontPostScriptName: String
    let vectorDataByToken: [String: Data]
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
