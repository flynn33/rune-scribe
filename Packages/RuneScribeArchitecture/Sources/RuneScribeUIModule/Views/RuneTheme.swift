// RuneScrib/Views/Components/RuneTheme.swift
//
// Shared design system for RuneScrib: consistent metrics, a reusable Metal
// header, an "eyebrow" section label, and a card container. Every view is
// composed from these so the windows share one width, one header treatment,
// one type scale, and one set of paddings — symmetrical and cohesive across
// both macOS and iOS.

import RuneScribeUIRuntime
import SwiftUI

// MARK: - Metrics

/// Single source of truth for sizing and spacing across all RuneScrib views.
enum RuneMetrics {
    /// macOS content width — the main window and both sheets line up to this.
    static let contentWidth: CGFloat = 600
    /// macOS sheet height so the two modal sheets share a footprint.
    static let sheetHeight: CGFloat = 660
    /// Height of the animated runic header used by every view.
    static let headerHeight: CGFloat = 108
    /// Outer padding around a view's body content.
    static let pad: CGFloat = 24
    /// Vertical gap between stacked sections / cards.
    static let sectionGap: CGFloat = 18
    /// Corner radius shared by cards, inputs, and buttons.
    static let corner: CGFloat = 12
}

// MARK: - Platform Frames

extension View {
    /// Root frame: macOS pins a minimum window content size; iOS fills the screen.
    @ViewBuilder
    func runeRootFrame() -> some View {
        #if os(macOS)
        frame(minWidth: RuneMetrics.contentWidth, minHeight: 560)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }

    /// Sheet frame: macOS uses a fixed size so both sheets match; iOS fills the
    /// system-presented sheet.
    @ViewBuilder
    func runeSheetFrame() -> some View {
        #if os(macOS)
        frame(width: RuneMetrics.contentWidth, height: RuneMetrics.sheetHeight)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
    }
}

// MARK: - Presentation Surfaces

/// Controls how strongly a provider-neutral presentation surface obscures the
/// application content beneath it. Privacy-sensitive overlays use a stronger
/// material and tint while preserving the active Theme's semantic palette.
enum RuneSemanticPresentationSurfaceRole {
    case standard
    case privacy
}

private struct RuneSemanticPresentationSurfaceModifier: ViewModifier {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    let role: RuneSemanticPresentationSurfaceRole

    private var material: Material {
        role == .privacy ? .thickMaterial : .thinMaterial
    }

    private var tintOpacity: Double {
        let increasedContrast = colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast
        return switch (role, increasedContrast) {
        case (.standard, false): 0.58
        case (.standard, true): 0.78
        case (.privacy, false): 0.88
        case (.privacy, true): 0.96
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Rectangle().fill(material)
                    Color.runeBackgroundSecondary.opacity(tintOpacity)
                }
                .ignoresSafeArea()
            }
            // A sheet's system container must not replace the semantic surface
            // with an unrelated opaque platform background.
            .presentationBackground(.clear)
    }
}

extension View {
    /// Applies the shared semantic surface used above the single root Theme
    /// background renderer. The default remains translucent so provider
    /// presentation continuity survives sheets without mounting a renderer.
    func runeSemanticPresentationSurface(
        _ role: RuneSemanticPresentationSurfaceRole = .standard
    ) -> some View {
        modifier(RuneSemanticPresentationSurfaceModifier(role: role))
    }
}

// MARK: - Runic Font

extension Font {
    /// A rune font at `size`. Defaults to the bundled Noto Sans Runic — which covers the
    /// entire Unicode Runic block, so no rune renders as a missing-glyph box (default system
    /// fonts lack U+16F1–U+16F8) — but accepts a cipher's resolved font name. Registered by
    /// the runtime-mediated presentation rail; falls back to the system font.
    @MainActor
    static func runic(_ size: CGFloat, fontName: String? = nil) -> Font {
        .custom(
            fontName ?? RuneThemePaletteInterpreter.fontPostScriptName,
            size: size
        )
    }
}

// MARK: - Eyebrow Label

/// A small uppercased, letter-spaced label with a leading glyph. Used as the
/// title of every section and card so headings read consistently.
struct RuneEyebrow: View {
    let title: String
    let systemImage: String
    var accent: Color = .runeGold

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.5)
        }
        .foregroundColor(accent)
    }
}

// MARK: - Header

/// A circular header action (close on sheets, settings/library on the main view).
/// Placed at the header's top-right on every platform — clear of the macOS window
/// controls (which sit top-left).
struct RuneHeaderButton: Identifiable {
    let systemImage: String
    let help: String
    let action: @MainActor () -> Void

    var id: String { "\(systemImage).\(help)" }
}

private struct RuneHeaderActionView: View {
    let button: RuneHeaderButton

    var body: some View {
        Button(action: button.action) {
            Image(systemName: button.systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.runeSilver)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.runeNavy.opacity(0.55)))
                .overlay(
                    Circle().strokeBorder(
                        Color.runeSilver.opacity(0.30),
                        lineWidth: 1
                    )
                )
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(button.help)
        .help(button.help)
    }
}

/// The application header shared by every view: a centered runic wordmark over
/// a provider-neutral legibility scrim, an optional top-right action, and a
/// hairline semantic-accent rule along the bottom. The application shell owns
/// the runtime Theme background; the header never mounts a second renderer.
struct RuneHeader: View {
    let slot: ThemeHeadingSlot
    let subtitle: String
    var height: CGFloat = RuneMetrics.headerHeight
    var trailingButtons: [RuneHeaderButton] = []

    private var decorativeHeading: String {
        RuneThemeHeadingInterpreter.value(for: slot, fallback: subtitle)
    }

    var body: some View {
        ZStack {
            Color.runeNavy.opacity(0.24)

            // Scrim: preserves wordmark legibility over the root Theme background.
            LinearGradient(
                colors: [Color.runeNavy.opacity(0.10), Color.runeNavy.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            if trailingButtons.isEmpty {
                wordmark
            } else {
                ViewThatFits(in: .horizontal) {
                    centeredHeaderContent
                    compactHeaderContent
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            ZStack {
                Rectangle()
                    .fill(Color.runeGold.opacity(0.35))
                    .frame(height: 1)
                ThemeChromeImage(slot: .divider)
                    .frame(maxWidth: .infinity)
                    .frame(height: 18)
                    .opacity(0.88)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            ThemeChromeImage(slot: .cornerOrnament)
                .frame(width: 52, height: 52)
                .opacity(0.72)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            ThemeChromeImage(slot: .cornerOrnament)
                .scaleEffect(x: -1, y: 1)
                .frame(width: 52, height: 52)
                .opacity(0.72)
                .allowsHitTesting(false)
        }
    }

    private var actionRowWidth: CGFloat {
        let buttonCount = CGFloat(trailingButtons.count)
        return buttonCount * 44 + max(0, buttonCount - 1) * 10
    }

    private var wordmark: some View {
        VStack(spacing: 6) {
            Canvas { context, size in
                var glyphContext = context
                glyphContext.addFilter(
                    .shadow(color: Color.runeGold.opacity(0.35), radius: 9, y: 1)
                )

                let resolved = glyphContext.resolve(
                    Text(decorativeHeading)
                        .font(.runic(27))
                        .foregroundColor(.runeGold)
                )
                let measured = resolved.measure(
                    in: CGSize(width: 10_000, height: size.height)
                )
                let horizontalScale = measured.width > 0 ? size.width / measured.width : 1
                let verticalScale = measured.height > 0 ? size.height / measured.height : 1
                let scale = min(1, horizontalScale, verticalScale)

                glyphContext.translateBy(x: size.width / 2, y: size.height / 2)
                glyphContext.scaleBy(x: scale, y: scale)
                glyphContext.draw(resolved, at: .zero, anchor: .center)
            }
            .frame(
                minWidth: 80,
                idealWidth: min(280, max(140, CGFloat(decorativeHeading.count) * 19)),
                maxWidth: .infinity,
                minHeight: 34,
                maxHeight: 34
            )
            .accessibilityHidden(true)
            Text(subtitle.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(5)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundColor(.runeSilver)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtitle)
        .accessibilityAddTraits(.isHeader)
    }

    private var centeredHeaderContent: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: actionRowWidth, height: 44)
                .accessibilityHidden(true)
            wordmark
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxHeight: .infinity)
            actionRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var compactHeaderContent: some View {
        HStack(spacing: 8) {
            wordmark
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
            actionRow
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            ForEach(trailingButtons, content: RuneHeaderActionView.init)
        }
        .frame(height: max(44, height - 28), alignment: .top)
    }
}

// MARK: - Card

/// A titled card with the parchment fill and a faint accent border. All grouped
/// content (key info, export, rotate, encoded output) sits in one of these so
/// the views share a single panel language.
struct RunePanel<Content: View>: View {
    let title: String
    let systemImage: String
    var accent: Color = .runeGold
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RuneEyebrow(title: title, systemImage: systemImage, accent: accent)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder(accent.opacity(0.18), lineWidth: 1)
        )
    }
}
