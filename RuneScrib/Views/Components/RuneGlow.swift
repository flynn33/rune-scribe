// RuneScrib/Views/Components/RuneGlow.swift

import SwiftUI
import Foundation

extension View {
    /// Wraps rune glyphs in a faint, gently-pulsing gold halo rendered by the
    /// `runeGlow` Metal layer-effect shader. The glyphs themselves are untouched;
    /// only the surrounding transparent area receives the bloom.
    ///
    /// - Parameters:
    ///   - color: halo tint (defaults to the bright gold accent).
    ///   - radius: glow reach in points.
    ///   - intensity: overall halo strength.
    ///   - animated: when true, the intensity breathes slowly via `TimelineView`.
    func runeGlow(color: Color = .runeGoldBright,
                  radius: CGFloat = 5,
                  intensity: CGFloat = 1.7,
                  animated: Bool = true) -> some View {
        modifier(RuneGlowModifier(color: color,
                                  radius: radius,
                                  intensity: intensity,
                                  animated: animated))
    }
}

private struct RuneGlowModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    let color: Color
    let radius: CGFloat
    let intensity: CGFloat
    let animated: Bool

    func body(content: Content) -> some View {
        // Only drive the continuous TimelineView while the scene is active, so the
        // pulse doesn't keep the GPU busy when the app is inactive/backgrounded.
        if animated && scenePhase == .active {
            TimelineView(.animation) { timeline in
                content.modifier(GlowLayer(color: color,
                                           radius: radius,
                                           intensity: pulse(at: timeline.date)))
            }
        } else {
            content.modifier(GlowLayer(color: color, radius: radius, intensity: intensity))
        }
    }

    /// Slow breathing pulse (~3s period) around the base intensity.
    private func pulse(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        return intensity * (0.82 + 0.18 * CGFloat(sin(t * 2.1)))
    }
}

/// The actual Metal layer effect. Split out so the animated wrapper can re-create
/// it each frame with a fresh intensity.
private struct GlowLayer: ViewModifier {
    let color: Color
    let radius: CGFloat
    let intensity: CGFloat

    func body(content: Content) -> some View {
        content.layerEffect(
            ShaderLibrary.runeGlow(
                .color(color),
                .float(Float(radius)),
                .float(Float(intensity))
            ),
            maxSampleOffset: CGSize(width: radius, height: radius)
        )
    }
}
