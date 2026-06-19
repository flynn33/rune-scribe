// RuneScrib/Views/Components/RuneTheme.swift
//
// Shared design system for RuneScrib: consistent metrics, a reusable Metal
// header, an "eyebrow" section label, and a card container. Every view is
// composed from these so the windows share one width, one header treatment,
// one type scale, and one set of paddings — symmetrical and cohesive across
// both macOS and iOS.

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

// MARK: - Runic Font

extension Font {
    /// Bundled Noto Sans Runic — covers the entire Unicode Runic block, so no rune
    /// renders as a missing-glyph box (default system fonts lack U+16F1–U+16F8).
    /// Registered at launch via `FontRegistration`; falls back to the system font.
    static func runic(_ size: CGFloat) -> Font { .custom("Noto Sans Runic", size: size) }
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
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(2.5)
        }
        .foregroundColor(accent)
    }
}

// MARK: - Header

/// A circular header action (close on sheets, key on the main view). Placed at the
/// header's top-right on every platform — clear of the macOS window controls.
struct RuneHeaderButton {
    let systemImage: String
    let help: String
    let action: () -> Void
}

/// The animated Metal header shared by every view: a centered runic wordmark over
/// a legibility scrim, an optional top-right action, and a hairline gold rule along
/// the bottom. Fixed height keeps all views vertically aligned.
struct RuneHeader: View {
    let runic: String
    let subtitle: String
    var height: CGFloat = RuneMetrics.headerHeight
    var trailingButton: RuneHeaderButton? = nil

    var body: some View {
        ZStack {
            RuneMetalView()

            // Scrim: darkens the animated background so the wordmark stays legible.
            LinearGradient(
                colors: [Color.runeNavy.opacity(0.10), Color.runeNavy.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 6) {
                Text(runic)
                    .font(.system(size: 27, weight: .bold))
                    .foregroundColor(.runeGold)
                    .shadow(color: Color.runeGold.opacity(0.35), radius: 9, y: 1)
                Text(subtitle.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(5)
                    .foregroundColor(.runeSilver)
            }

            if let trailingButton {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: trailingButton.action) {
                            Image(systemName: trailingButton.systemImage)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.runeSilver)
                                .frame(width: 28, height: 28)
                                .background(Circle().fill(Color.runeNavy.opacity(0.55)))
                                .overlay(Circle().strokeBorder(Color.runeSilver.opacity(0.30), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(trailingButton.help)
                    }
                    Spacer()
                }
                .padding(14)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.runeGold.opacity(0.35))
                .frame(height: 1)
        }
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
        .padding(16)
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
