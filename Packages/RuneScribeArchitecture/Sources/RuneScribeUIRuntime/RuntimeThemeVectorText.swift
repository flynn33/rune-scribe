import Foundation
import SwiftUI

public enum RuntimeThemeGlyphToken: Equatable, Sendable {
    case glyph(textToken: String, data: Data)
    case text(String)
    case space(String)
    case lineBreak
}

public struct RuntimeThemeGlyphRun: Equatable, Sendable {
    public let tokens: [RuntimeThemeGlyphToken]

    public init(text: String, glyphDataByTextToken: [String: Data]) {
        tokens = text.map { character in
            let token = String(character)
            if character == "\n" {
                return .lineBreak
            }
            if character.isWhitespace {
                return .space(token)
            }
            if let data = glyphDataByTextToken[token] {
                return .glyph(textToken: token, data: data)
            }
            return .text(token)
        }
    }
}

public struct RuntimeThemeVectorText: View {
    @Environment(\.runtimeApplicationResourcePresentation)
    private var applicationResourcePresentation

    private let text: String
    private let run: RuntimeThemeGlyphRun
    private let pointSize: CGFloat
    private let color: Color
    private let lineSpacing: CGFloat

    public init(
        text: String,
        glyphDataByTextToken: [String: Data],
        pointSize: CGFloat,
        color: Color,
        lineSpacing: CGFloat = 7
    ) {
        self.text = text
        run = RuntimeThemeGlyphRun(
            text: text,
            glyphDataByTextToken: glyphDataByTextToken
        )
        self.pointSize = pointSize
        self.color = color
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        Group {
            if let applicationResourcePresentation {
                RuntimeThemeGlyphContent(
                    run: run,
                    pointSize: pointSize,
                    color: color,
                    lineSpacing: lineSpacing,
                    cache: applicationResourcePresentation
                        .themeDecodedResourceCache
                )
            } else {
                RuntimeThemeGlyphFallbackContent(
                    run: run,
                    pointSize: pointSize,
                    color: color,
                    lineSpacing: lineSpacing
                )
            }
        }
        .overlay(alignment: .topLeading) {
            Text(text)
                .font(.system(size: pointSize, design: .monospaced))
                .lineSpacing(lineSpacing)
                .foregroundStyle(.clear)
                .textSelection(.enabled)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(text))
    }
}

private struct RuntimeThemeGlyphFallbackContent: View {
    let run: RuntimeThemeGlyphRun
    let pointSize: CGFloat
    let color: Color
    let lineSpacing: CGFloat

    @StateObject private var cache = RuntimeThemeDecodedResourceCache()

    var body: some View {
        RuntimeThemeGlyphContent(
            run: run,
            pointSize: pointSize,
            color: color,
            lineSpacing: lineSpacing,
            cache: cache
        )
    }
}

private struct RuntimeThemeGlyphContent: View {
    let run: RuntimeThemeGlyphRun
    let pointSize: CGFloat
    let color: Color
    let lineSpacing: CGFloat
    let cache: RuntimeThemeDecodedResourceCache

    var body: some View {
        RuntimeThemeGlyphFlowLayout(
            itemSpacing: max(1, pointSize * 0.08),
            lineSpacing: lineSpacing
        ) {
            ForEach(Array(run.tokens.enumerated()), id: \.offset) { _, token in
                tokenView(token)
            }
        }
    }

    @ViewBuilder
    private func tokenView(_ token: RuntimeThemeGlyphToken) -> some View {
        switch token {
        case .glyph(let textToken, let data):
            RuntimeThemeGlyphImage(
                data: data,
                fallback: textToken,
                cache: cache
            )
                .id(
                    RuntimeThemeGlyphImageIdentity(
                        data: data,
                        cacheIdentifier: ObjectIdentifier(cache)
                    )
                )
                .foregroundStyle(color)
                .frame(width: pointSize, height: pointSize * 1.2)
                .accessibilityHidden(true)
        case .text(let value):
            Text(value)
                .font(.system(size: pointSize, design: .monospaced))
                .foregroundStyle(color)
                .fixedSize()
                .accessibilityHidden(true)
        case .space(let value):
            Color.clear
                .frame(
                    width: max(pointSize * 0.42 * CGFloat(value.count), 1),
                    height: pointSize * 1.2
                )
                .accessibilityHidden(true)
        case .lineBreak:
            Color.clear
                .frame(width: 0, height: pointSize * 1.2)
                .layoutValue(key: RuntimeThemeLineBreakKey.self, value: true)
                .accessibilityHidden(true)
        }
    }
}

private struct RuntimeThemeGlyphImage: View {
    @StateObject private var resource: RuntimeThemeDecodedResourceReference
    let fallback: String

    init(
        data: Data,
        fallback: String,
        cache: RuntimeThemeDecodedResourceCache
    ) {
        _resource = StateObject(
            wrappedValue: RuntimeThemeDecodedResourceReference(
                data: data,
                cache: cache
            )
        )
        self.fallback = fallback
    }

    var body: some View {
        if let image = resource.image {
            image
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
        } else {
            Text(fallback)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .minimumScaleFactor(0.5)
        }
    }
}

private struct RuntimeThemeGlyphImageIdentity: Hashable {
    let data: Data
    let cacheIdentifier: ObjectIdentifier
}

private struct RuntimeThemeLineBreakKey: LayoutValueKey {
    static let defaultValue = false
}

private struct RuntimeThemeGlyphFlowLayout: Layout {
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        for placement in result.placements {
            placement.subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (size: CGSize, placements: [Placement]) {
        let proposedWidth = proposal.width ?? .greatestFiniteMagnitude
        let availableWidth = max(proposedWidth, 1)
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if subview[RuntimeThemeLineBreakKey.self] {
                y += max(lineHeight, size.height) + lineSpacing
                x = 0
                lineHeight = 0
                continue
            }
            if x > 0, x + size.width > availableWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            placements.append(Placement(subview: subview, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + itemSpacing
            lineHeight = max(lineHeight, size.height)
            measuredWidth = max(measuredWidth, max(0, x - itemSpacing))
        }

        let measuredHeight = subviews.isEmpty ? 0 : y + lineHeight
        return (
            CGSize(
                width: proposal.width.map { min($0, measuredWidth) } ?? measuredWidth,
                height: measuredHeight
            ),
            placements
        )
    }

    private struct Placement {
        let subview: LayoutSubview
        let origin: CGPoint
        let size: CGSize
    }
}
