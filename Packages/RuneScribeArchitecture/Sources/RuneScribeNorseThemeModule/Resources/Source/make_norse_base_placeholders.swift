import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private struct AssetRecord {
    let id: String
    let mediaType: String
    let width: Int?
    let height: Int?
    let data: Data
}

private let resourcesURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let outputURL = resourcesURL.appendingPathComponent(
    "NorseBasePlaceholderAssets-v1.0.json"
)
private let fontURL = resourcesURL.appendingPathComponent(
    "NotoSansRunic-Regular.ttf"
)

if !CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil) {
    // Registration returns false when the same process already owns the font.
    let font = CTFontCreateWithName("NotoSansRunic-Regular" as CFString, 16, nil)
    guard CTFontGetGlyphCount(font) > 0 else {
        fatalError("Noto Sans Runic could not be registered.")
    }
}

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha
    )
}

private func makePNG(
    width: Int,
    height: Int,
    draw: (CGContext, CGRect) -> Void
) -> Data {
    let bytesPerRow = width * 4
    var pixels = Data(count: bytesPerRow * height)
    let image: CGImage = pixels.withUnsafeMutableBytes { bytes in
        guard let baseAddress = bytes.baseAddress,
              let context = CGContext(
                  data: baseAddress,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { fatalError("Could not create image context.") }
        context.setShouldAntialias(true)
        draw(context, CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            fatalError("Could not make image.")
        }
        return image
    }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { fatalError("Could not create PNG destination.") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("Could not encode PNG.")
    }
    return output as Data
}

private func makeSealPDF(kind: Int) -> Data {
    let pointCount = 3 + kind
    var commands = [
        "q",
        "0.831 0.592 0.102 RG",
        "10 w",
        "1 J",
        "1 j",
        "42 128 m",
        "42 175.497 80.503 214 128 214 c",
        "175.497 214 214 175.497 214 128 c",
        "214 80.503 175.497 42 128 42 c",
        "80.503 42 42 80.503 42 128 c",
        "S",
    ]
    let locale = Locale(identifier: "en_US_POSIX")
    for index in 0 ..< pointCount {
        let angle = Double(index) / Double(pointCount) * Double.pi * 2
        let innerX = 128 + cos(angle) * 22
        let innerY = 128 + sin(angle) * 22
        let outerX = 128 + cos(angle) * 78
        let outerY = 128 + sin(angle) * 78
        commands.append(String(
            format: "%.3f %.3f m %.3f %.3f l S",
            locale: locale,
            innerX,
            innerY,
            outerX,
            outerY
        ))
    }
    commands.append(contentsOf: [
        "0.831 0.592 0.102 rg",
        "110 110 36 36 re f",
        "Q",
    ])
    let stream = commands.joined(separator: "\n") + "\n"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 256 256] /Resources << >> /Contents 4 0 R >>",
        "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)endstream",
    ]
    var document = "%PDF-1.4\n%RuneScribe\n"
    var offsets = [0]
    for (index, object) in objects.enumerated() {
        offsets.append(document.utf8.count)
        document += "\(index + 1) 0 obj\n\(object)\nendobj\n"
    }
    let xrefOffset = document.utf8.count
    document += "xref\n0 \(objects.count + 1)\n"
    document += "0000000000 65535 f \n"
    for offset in offsets.dropFirst() {
        document += String(format: "%010d 00000 n \n", offset)
    }
    document += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
    document += "startxref\n\(xrefOffset)\n%%EOF\n"
    return Data(document.utf8)
}

private func fill(_ context: CGContext, _ rect: CGRect, _ value: CGColor) {
    context.setFillColor(value)
    context.fill(rect)
}

private func stroke(
    _ context: CGContext,
    _ path: CGPath,
    color: CGColor,
    width: CGFloat
) {
    context.addPath(path)
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
}

private func drawBackground(
    _ context: CGContext,
    _ rect: CGRect,
    variant: Int
) {
    fill(context, rect, variant == 2 ? color(0x000000) : color(0x080A1E))
    guard variant != 2 else {
        context.setStrokeColor(color(0xFFFFFF))
        context.setLineWidth(max(3, rect.width / 180))
        context.stroke(rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04))
        return
    }
    let bandColor = variant == 1 ? color(0x3A7FD5, alpha: 0.18) : color(0x3A7FD5, alpha: 0.28)
    context.setStrokeColor(bandColor)
    context.setLineWidth(max(2, rect.width / 256))
    let spacing = rect.width / 9
    var x = -rect.height
    while x < rect.width {
        context.move(to: CGPoint(x: x, y: 0))
        context.addLine(to: CGPoint(x: x + rect.height, y: rect.height))
        x += spacing
    }
    context.strokePath()
    context.setStrokeColor(color(0xD4971A, alpha: variant == 1 ? 0.25 : 0.48))
    context.setLineWidth(max(2, rect.width / 220))
    for index in 1 ... 5 {
        let inset = CGFloat(index) * rect.width * 0.065
        context.strokeEllipse(in: rect.insetBy(dx: inset, dy: inset))
    }
}

private func drawVault(
    _ context: CGContext,
    _ rect: CGRect,
    state: Int
) {
    fill(context, rect, color(0x080A1E))
    let card = CGPath(
        roundedRect: rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.1),
        cornerWidth: rect.height * 0.08,
        cornerHeight: rect.height * 0.08,
        transform: nil
    )
    context.addPath(card)
    context.setFillColor(color(0x1A1E30))
    context.fillPath()
    let accents: [UInt32] = [0xD4971A, 0xA0A8B8, 0x3A7FD5, 0xEEBE45]
    stroke(context, card, color: color(accents[state]), width: rect.height * 0.025)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    context.setStrokeColor(color(accents[state]))
    context.setLineWidth(rect.height * 0.035)
    if state == 0 {
        context.strokeEllipse(in: CGRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))
    } else if state == 1 {
        context.stroke(CGRect(x: center.x - 34, y: center.y - 25, width: 68, height: 58))
        context.strokeEllipse(in: CGRect(x: center.x - 24, y: center.y + 10, width: 48, height: 48))
    } else if state == 2 {
        context.move(to: CGPoint(x: center.x - 58, y: center.y))
        context.addCurve(
            to: CGPoint(x: center.x + 58, y: center.y),
            control1: CGPoint(x: center.x - 20, y: center.y + 52),
            control2: CGPoint(x: center.x + 20, y: center.y + 52)
        )
        context.addCurve(
            to: CGPoint(x: center.x - 58, y: center.y),
            control1: CGPoint(x: center.x + 20, y: center.y - 52),
            control2: CGPoint(x: center.x - 20, y: center.y - 52)
        )
        context.strokePath()
        context.strokeEllipse(in: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))
    } else {
        context.move(to: CGPoint(x: center.x - 48, y: center.y))
        context.addLine(to: CGPoint(x: center.x - 10, y: center.y - 38))
        context.addLine(to: CGPoint(x: center.x + 55, y: center.y + 42))
        context.strokePath()
    }
}

private func relicPath(in rect: CGRect, kind: Int) -> CGPath {
    let inset = rect.width * 0.14
    let bounds = rect.insetBy(dx: inset, dy: inset)
    if kind == 1 {
        return CGPath(ellipseIn: bounds, transform: nil)
    }
    if kind == 2 {
        return CGPath(
            roundedRect: CGRect(
                x: bounds.minX,
                y: bounds.minY + bounds.height * 0.12,
                width: bounds.width,
                height: bounds.height * 0.76
            ),
            cornerWidth: bounds.width * 0.08,
            cornerHeight: bounds.width * 0.08,
            transform: nil
        )
    }
    let path = CGMutablePath()
    path.move(to: CGPoint(x: bounds.midX, y: bounds.maxY))
    path.addLine(to: CGPoint(x: bounds.maxX * 0.93, y: bounds.maxY * 0.82))
    path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY * 1.25))
    path.addLine(to: CGPoint(x: bounds.midX, y: bounds.minY))
    path.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY * 1.25))
    path.addLine(to: CGPoint(x: bounds.minX * 1.07, y: bounds.maxY * 0.82))
    path.closeSubpath()
    return path
}

private func drawRelic(
    _ context: CGContext,
    _ rect: CGRect,
    kind: Int,
    highContrast: Bool
) {
    fill(context, rect, highContrast ? color(0x000000) : color(0x080A1E))
    let path = relicPath(in: rect, kind: kind)
    context.addPath(path)
    context.setFillColor(highContrast ? color(0xFFFFFF) : color(kind == 2 ? 0x6C4D2E : 0x303542))
    context.fillPath()
    stroke(
        context,
        path,
        color: highContrast ? color(0x000000) : color(0xD4971A),
        width: max(4, rect.width * 0.018)
    )
    context.setStrokeColor(highContrast ? color(0x000000) : color(0xA0A8B8))
    context.setLineWidth(max(3, rect.width * 0.012))
    for index in 0 ..< 5 {
        let y = rect.minY + rect.height * (0.35 + CGFloat(index) * 0.08)
        context.move(to: CGPoint(x: rect.minX + rect.width * 0.31, y: y))
        context.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.31, y: y))
    }
    context.strokePath()
}

private func drawSeal(
    _ context: CGContext,
    _ rect: CGRect,
    kind: Int,
    monochrome: Bool
) {
    if monochrome { fill(context, rect, color(0xFFFFFF)) }
    let ink = monochrome ? color(0x000000) : color(0xD4971A)
    let bounds = rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.16)
    context.setStrokeColor(ink)
    context.setLineWidth(max(5, rect.width * 0.045))
    context.strokeEllipse(in: bounds)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let points = 3 + kind
    for index in 0 ..< points {
        let angle = CGFloat(index) / CGFloat(points) * .pi * 2
        let inner = CGPoint(
            x: center.x + cos(angle) * bounds.width * 0.12,
            y: center.y + sin(angle) * bounds.height * 0.12
        )
        let outer = CGPoint(
            x: center.x + cos(angle) * bounds.width * 0.46,
            y: center.y + sin(angle) * bounds.height * 0.46
        )
        context.move(to: inner)
        context.addLine(to: outer)
    }
    context.strokePath()
    context.setFillColor(ink)
    context.fillEllipse(in: CGRect(
        x: center.x - rect.width * 0.07,
        y: center.y - rect.height * 0.07,
        width: rect.width * 0.14,
        height: rect.height * 0.14
    ))
}

private func drawScriptFallback(_ context: CGContext, _ rect: CGRect) {
    fill(context, rect, color(0x080A1E))
    let font = CTFontCreateWithName(
        "NotoSansRunic-Regular" as CFString,
        rect.height * 0.2,
        nil
    )
    let values = (0 ..< 32).map { UniChar(0x16A0 + $0) }
    var glyphs = [CGGlyph](repeating: 0, count: values.count)
    guard CTFontGetGlyphsForCharacters(font, values, &glyphs, values.count) else {
        fatalError("Base rune glyph coverage is incomplete.")
    }
    var positions = glyphs.indices.map { index in
        CGPoint(
            x: rect.width * (0.035 + CGFloat(index % 16) / 16),
            y: rect.height * (index < 16 ? 0.61 : 0.22)
        )
    }
    context.setFillColor(color(0xD4971A))
    CTFontDrawGlyphs(font, &glyphs, &positions, glyphs.count, context)
}

private var records = [AssetRecord]()
private func appendPNG(
    _ id: String,
    width: Int,
    height: Int,
    draw: (CGContext, CGRect) -> Void
) {
    records.append(AssetRecord(
        id: id,
        mediaType: "image/png",
        width: width,
        height: height,
        data: makePNG(width: width, height: height, draw: draw)
    ))
}

appendPNG("script-fallback", width: 1024, height: 256, draw: drawScriptFallback)
for variant in 0 ..< 3 {
    appendPNG("background-\(variant)", width: 1024, height: 1024) {
        drawBackground($0, $1, variant: variant)
    }
}
for state in 0 ..< 4 {
    appendPNG("vault-\(state)", width: 512, height: 320) {
        drawVault($0, $1, state: state)
    }
}
let relicNames = ["weathered", "raven-medallion", "sealed-parchment"]
for (kind, name) in relicNames.enumerated() {
    appendPNG("relic-\(name)-master", width: 1024, height: 1024) {
        drawRelic($0, $1, kind: kind, highContrast: false)
    }
    appendPNG("relic-\(name)-thumbnail", width: 256, height: 256) {
        drawRelic($0, $1, kind: kind, highContrast: false)
    }
    appendPNG("relic-\(name)-high-contrast", width: 1024, height: 1024) {
        drawRelic($0, $1, kind: kind, highContrast: true)
    }
}
let sealNames = [
    "knotwork", "forge-flame", "raven", "longship", "forge-hammer", "echo-rune",
]
for (kind, name) in sealNames.enumerated() {
    records.append(AssetRecord(
        id: "seal-\(name)-vector",
        mediaType: "application/pdf",
        width: nil,
        height: nil,
        data: makeSealPDF(kind: kind)
    ))
    appendPNG("seal-\(name)-raster", width: 256, height: 256) {
        drawSeal($0, $1, kind: kind, monochrome: true)
    }
}

let assets: [[String: Any]] = records.sorted { $0.id < $1.id }.map { record in
    var value: [String: Any] = [
        "id": record.id,
        "mediaType": record.mediaType,
        "byteLength": record.data.count,
        "sha256": SHA256.hash(data: record.data).map {
            String(format: "%02x", $0)
        }.joined(),
        "data": record.data.base64EncodedString(),
    ]
    if let width = record.width, let height = record.height {
        value["pixelSize"] = ["width": width, "height": height]
    }
    return value
}
let root: [String: Any] = [
    "schemaVersion": "1.0",
    "generator": "make_norse_base_placeholders.swift",
    "assets": assets,
]
let encoded = try JSONSerialization.data(
    withJSONObject: root,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
)
try encoded.write(to: outputURL, options: .atomic)
