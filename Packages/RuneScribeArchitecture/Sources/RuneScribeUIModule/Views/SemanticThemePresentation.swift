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
    }
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
        cipherFontSource: FontSourceDTO?
    ) -> String {
        if cipherFontSource == .imported, let cipherFontName {
            return cipherFontName
        }
        return themePostScriptName
    }

    static func usesThemeVectors(cipherFontSource: FontSourceDTO?) -> Bool {
        cipherFontSource != .imported
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
