// RuneScrib/Views/Components/RuneInscriptionText.swift

import SwiftUI
import Foundation

/// The in-place transformation animation: the output is inscribed one glyph at a
/// time, left to right. Each landing glyph flares bright, then dims to its resting
/// colour; positions that haven't been reached yet still show the original source
/// character. Encoding settles into gold runes, decoding into pale plain text.
///
/// When `settled` is true it renders the final, static result as plain selectable
/// text — no Metal effect — so the runes stay sharp and individual glyphs can be
/// selected and copied. The flare is a pure colour flash (also sharp); there is no
/// rasterising glow.
///
/// Rendered as a single `AttributedString` per frame so the text wraps naturally
/// while each character keeps its own font (runic vs. monospaced) and colour.
struct RuneInscriptionText: View {

    enum Direction { case encode, decode }

    // MARK: - Inputs

    private let sourceChars: [Character]
    private let targetChars: [Character]
    let start: Date
    let direction: Direction
    var fontSize: CGFloat = 24
    var settled: Bool = false

    init(source: String,
         target: String,
         start: Date,
         direction: Direction,
         fontSize: CGFloat = 24,
         settled: Bool = false) {
        // The cipher maps one character to one character, so source and target are
        // always the same length. Pad with spaces (a no-op glyph) only as defensive
        // degradation so a hypothetical length mismatch can't corrupt the reveal.
        let s = Array(source)
        let t = Array(target)
        let n = Swift.max(s.count, t.count)
        self.sourceChars = (0..<n).map { $0 < s.count ? s[$0] : " " }
        self.targetChars = (0..<n).map { $0 < t.count ? t[$0] : " " }
        self.start = start
        self.direction = direction
        self.fontSize = fontSize
        self.settled = settled
    }

    // MARK: - Timing (fast)

    private static let startDelay = 0.0
    private static let flareDecay = 0.13
    private static let maxTotal   = 0.5
    private static let perCharCap = 0.028
    private static let settleBuffer = 0.05

    static func perChar(count: Int) -> Double {
        count > 0 ? Swift.min(perCharCap, maxTotal / Double(count)) : perCharCap
    }

    /// Total time from `start` until everything is inscribed and rested: the last
    /// glyph (index count-1) lands at `startDelay + (count-1)*perChar`, its flare
    /// finishes `flareDecay` later, plus a small settle buffer.
    static func totalDuration(count: Int) -> Double {
        startDelay + Double(Swift.max(count - 1, 0)) * perChar(count: count) + flareDecay + settleBuffer
    }

    private func inscribeTime(_ index: Int) -> Double {
        Self.startDelay + Double(index) * Self.perChar(count: targetChars.count)
    }

    // MARK: - Body

    var body: some View {
        if settled {
            glyphText(finalAttributed)
                .textSelection(.enabled)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                glyphText(attributed(at: t))
            }
        }
    }

    private func glyphText(_ string: AttributedString) -> some View {
        // The runic font is applied as a view modifier (not a per-run attribute):
        // runtime-registered fonts resolve reliably this way, so the runes render
        // in bundled Noto Sans Runic. Latin (the unrevealed tail / decoded text)
        // falls back to the system font. Per-run colour still drives the flare.
        Text(string)
            .font(.runic(fontSize))
            .lineSpacing(7)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Attributed Builders

    private func attributed(at t: Double) -> AttributedString {
        var result = AttributedString()
        for index in targetChars.indices {
            let landed = t >= inscribeTime(index)
            let character = landed ? targetChars[index] : sourceChars[index]
            var piece = AttributedString(String(character))
            if landed {
                let age = t - inscribeTime(index)
                let flare = Swift.max(0, 1 - age / Self.flareDecay)
                piece.foregroundColor = settledColor(flare: flare)
            } else {
                piece.foregroundColor = Self.sourceColor
            }
            result += piece
        }
        return result
    }

    private var finalAttributed: AttributedString {
        var result = AttributedString()
        let base: Color = direction == .encode ? Self.gold : Self.settledDecode
        for character in targetChars {
            var piece = AttributedString(String(character))
            piece.foregroundColor = base
            result += piece
        }
        return result
    }

    // MARK: - Glyph Styling

    private func settledColor(flare: Double) -> Color {
        let base = direction == .encode ? Self.goldRGB : Self.settledDecodeRGB
        return Self.lerp(base, Self.flareRGB, flare)
    }

    // MARK: - Colours

    private static let gold = Color(red: 0.831, green: 0.592, blue: 0.102)
    private static let settledDecode = Color(red: 0.86, green: 0.88, blue: 0.93)
    private static let sourceColor = Color(red: 0.55, green: 0.58, blue: 0.66).opacity(0.55)

    private static let goldRGB: (Double, Double, Double)          = (0.831, 0.592, 0.102)
    private static let settledDecodeRGB: (Double, Double, Double)  = (0.86, 0.88, 0.93)
    private static let flareRGB: (Double, Double, Double)          = (1.0, 0.97, 0.84)

    private static func lerp(_ a: (Double, Double, Double),
                             _ b: (Double, Double, Double),
                             _ t: Double) -> Color {
        let u = Swift.min(Swift.max(t, 0), 1)
        return Color(red: a.0 + (b.0 - a.0) * u,
                     green: a.1 + (b.1 - a.1) * u,
                     blue: a.2 + (b.2 - a.2) * u)
    }
}
