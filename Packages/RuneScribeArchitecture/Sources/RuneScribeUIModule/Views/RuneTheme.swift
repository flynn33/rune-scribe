// RuneScrib/Views/Components/RuneTheme.swift
//
// Shared design system for RuneScrib: consistent metrics, a reusable Metal
// header, an "eyebrow" section label, and a card container. Every view is
// composed from these so the windows share one width, one header treatment,
// one type scale, and one set of paddings — symmetrical and cohesive across
// both macOS and iOS.

import RuneScribeContracts
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

// MARK: - Visual Depth

/// Shared, provider-neutral depth treatment. Theme artwork supplies identity;
/// these surfaces supply contemporary hierarchy and legibility without baking
/// a particular theme's ornament into application chrome.
struct RuneGlassSurface: View {
    var cornerRadius: CGFloat = RuneMetrics.corner
    var accent: Color = .runeGold
    var tintOpacity: Double = 0.72
    var shadowRadius: CGFloat = 18
    var shadowY: CGFloat = 9

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let increasedContrast = colorSchemeContrast == .increased
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            shape.fill(.thinMaterial)
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.runeSurfaceElevated.opacity(
                            increasedContrast ? min(0.96, tintOpacity + 0.18) : tintOpacity
                        ),
                        Color.runeNavy.opacity(
                            increasedContrast ? 0.94 : max(0.42, tintOpacity - 0.18)
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(increasedContrast ? 0.12 : 0.09),
                        Color.clear,
                        accent.opacity(increasedContrast ? 0.10 : 0.06),
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
            )
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(increasedContrast ? 0.30 : 0.18),
                        accent.opacity(increasedContrast ? 0.58 : 0.34),
                        Color.white.opacity(0.06),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: increasedContrast ? 1.5 : 1
            )
        }
        .shadow(
            color: Color.black.opacity(increasedContrast ? 0.38 : 0.28),
            radius: shadowRadius,
            y: shadowY
        )
    }
}

/// Grades busy scene artwork into a cinematic backdrop while preserving the
/// authored image and palette for every Theme.
struct RuneAtmosphericBackgroundTreatment: View {
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        let increasedContrast = colorSchemeContrast == .increased

        ZStack {
            LinearGradient(
                colors: [
                    Color.runeNavy.opacity(increasedContrast ? 0.62 : 0.42),
                    Color.runeNavy.opacity(increasedContrast ? 0.22 : 0.06),
                    Color.runeBackgroundSecondary.opacity(
                        increasedContrast ? 0.76 : 0.48
                    ),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color.runeGold.opacity(increasedContrast ? 0.15 : 0.22),
                    Color.clear,
                ],
                center: .topLeading,
                startRadius: 10,
                endRadius: 560
            )
            .blendMode(.screen)

            RadialGradient(
                colors: [
                    Color.runeAccentSecondary.opacity(increasedContrast ? 0.12 : 0.18),
                    Color.clear,
                ],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 620
            )
            .blendMode(.screen)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.runeTextPrimary)
                .frame(width: 34, height: 34)
                .background {
                    ZStack {
                        Circle().fill(.ultraThinMaterial)
                        Circle().fill(Color.runeNavy.opacity(0.44))
                    }
                }
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.runeGold.opacity(0.42),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: Color.black.opacity(0.24), radius: 8, y: 4)
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
            Rectangle().fill(.ultraThinMaterial)
            Color.runeNavy.opacity(0.24)

            // Scrim: preserves wordmark legibility over the root Theme background.
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.runeNavy.opacity(0.18),
                    Color.runeBackgroundSecondary.opacity(0.72),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color.runeGold.opacity(0.18), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 320
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
                    .opacity(0.46)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            ZStack {
                ThemeChromeImage(slot: .cornerOrnament)
                    .frame(width: 52, height: 52)
                    .opacity(0.42)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) {
            ZStack {
                ThemeChromeImage(slot: .cornerOrnament)
                    .scaleEffect(x: -1, y: 1)
                    .frame(width: 52, height: 52)
                    .opacity(0.42)
                    .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
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
    @EnvironmentObject private var session: RuneScribeUISession

    var body: some View {
        ThemeChromeProtectedContentLayout(
            panelPixelSize: panelBorderPixelSize,
            minimumInsets: EdgeInsets(
                top: 20,
                leading: 20,
                bottom: 20,
                trailing: 20
            )
        ) {
            VStack(alignment: .leading, spacing: 12) {
                RuneEyebrow(title: title, systemImage: systemImage, accent: accent)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RuneGlassSurface(
                cornerRadius: RuneMetrics.corner,
                accent: accent,
                tintOpacity: 0.76
            )
        }
        .overlay {
            ThemeChromeImage(slot: .panelBorder)
                .opacity(0.40)
                .allowsHitTesting(false)
        }
    }

    private var panelBorderPixelSize: ThemePixelSize? {
        session.activeThemeVisualPresentation?
            .chromeImageReference(for: .panelBorder)?
            .integrity.pixelSize
    }
}
