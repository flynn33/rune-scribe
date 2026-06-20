// RuneScrib/Services/QRCodeGenerator.swift

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Generates a crisp QR code image from a `runescribe://import` URL using CoreImage
/// (no third-party dependency). The default generator output is one module per
/// pixel, so it's scaled up with a nearest-neighbour transform and rendered with
/// `.interpolation(.none)` by callers to stay sharp.
enum QRCodeGenerator {

    /// A SwiftUI `Image` of the QR code for `url`, or nil if generation fails.
    static func image(for url: URL, scale: CGFloat = 12) -> Image? {
        guard let cgImage = cgImage(for: url.absoluteString, scale: scale) else { return nil }
        #if os(macOS)
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        return Image(nsImage: NSImage(cgImage: cgImage, size: size))
        #else
        return Image(uiImage: UIImage(cgImage: cgImage))
        #endif
    }

    /// The raw QR `CGImage` for an arbitrary string.
    static func cgImage(for string: String, scale: CGFloat = 12) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"   // 15% recovery — sharp and reliable at this payload size

        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // A local context avoids a non-Sendable shared static under Swift 6 strict
        // concurrency; QR generation is infrequent (presenting a sheet), so the cost
        // is negligible.
        let context = CIContext()
        return context.createCGImage(scaled, from: scaled.extent)
    }
}
