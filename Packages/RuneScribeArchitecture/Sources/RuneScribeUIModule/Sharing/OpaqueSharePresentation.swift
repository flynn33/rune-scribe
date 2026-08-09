import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import Foundation
import RuneScribeContracts
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum OpaqueSharePresentationError: Error, Equatable, Sendable {
    case unavailable
}

struct OpaqueShareTransfer: Transferable, Sendable {
    let artifactID: ShareArtifactID
    private let url: URL

    init(artifactID: ShareArtifactID, url: URL) {
        self.artifactID = artifactID
        self.url = url
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { item in
            item.url
        })
    }

    #if os(macOS)
    /// Internal-only handoff to the AppKit picker. The URL remains outside all
    /// public contracts and serialization surfaces.
    var macOSSharingURL: URL { url }
    #elseif os(iOS)
    /// Internal-only handoff to the UIKit activity presenter. The URL remains
    /// outside all public contracts and serialization surfaces.
    var iOSSharingURL: URL { url }
    #endif

    @MainActor
    func qrCodeImage(scale: CGFloat = 12) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale)
        )
        let context = CIContext()
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        #if os(macOS)
        let size = NSSize(width: image.width, height: image.height)
        return Image(nsImage: NSImage(cgImage: image, size: size))
        #elseif os(iOS)
        return Image(uiImage: UIImage(cgImage: image))
        #endif
    }
}

public struct OpaqueSharePresentationProvider: Sendable {
    private let loadURL: @Sendable (ShareArtifactID) async throws -> URL

    public init(
        loadURL: @escaping @Sendable (ShareArtifactID) async throws -> URL
    ) {
        self.loadURL = loadURL
    }

    func transfer(for artifactID: ShareArtifactID) async throws -> OpaqueShareTransfer {
        OpaqueShareTransfer(
            artifactID: artifactID,
            url: try await loadURL(artifactID)
        )
    }

    public static let unavailable = OpaqueSharePresentationProvider { _ in
        throw OpaqueSharePresentationError.unavailable
    }
}
