import CoreImage
import CoreImage.CIFilterBuiltins
import CoreTransferable
import Foundation
import RuneScribeContracts
@_spi(RuntimeResourceHost) import RuneScribeRuntimeCore
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum OpaqueSharePresentationError: Error, Equatable, Sendable {
    case unavailable
    case revoked
}

/// Runtime-owned lease for one artifact presentation. The platform URL remains
/// private to RuneScribeUIRuntime and is invalidated with the originating
/// runtime/module generation.
@MainActor
public final class OpaqueShareTransfer: ObservableObject {
    public let artifactID: ShareArtifactID

    @Published public private(set) var isAvailable = true
    @Published public private(set) var outcome: ShareArtifactOutcomeDTO?

    private let lease: RuntimeSharePresentationLease
    private var eventTask: Task<Void, Never>?
    private var isClosed = false

    private init(
        artifactID: ShareArtifactID,
        lease: RuntimeSharePresentationLease
    ) {
        self.artifactID = artifactID
        self.lease = lease
        eventTask = Task { @MainActor [weak self] in
            let events = await lease.events()
            for await event in events {
                switch event {
                case .revoked:
                    self?.markRevoked()
                case .completed(let outcome):
                    self?.markCompleted(outcome)
                }
            }
        }
    }

    public static func open(
        artifactID: ShareArtifactID,
        session: RuntimeSharePresentationSession
    ) async throws -> OpaqueShareTransfer {
        let lease = try await session.acquire()
        try Task.checkCancellation()
        return OpaqueShareTransfer(artifactID: artifactID, lease: lease)
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        isAvailable = false
        eventTask?.cancel()
        eventTask = nil
        await lease.close()
    }

    public func finish(_ outcome: ShareArtifactOutcomeDTO) async throws {
        guard !isClosed else {
            throw OpaqueSharePresentationError.revoked
        }
        try await lease.finish(outcome)
    }

    deinit {
        eventTask?.cancel()
    }

    @MainActor
    public func qrCodeImage(scale: CGFloat = 12) -> Image? {
        guard let presentationURL else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(presentationURL.absoluteString.utf8)
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

    var presentationURL: URL? {
        guard isAvailable,
              case .artifact(let url) = lease.content
        else { return nil }
        return url
    }

    var presentationText: String? {
        guard isAvailable,
              case .text(let text) = lease.content
        else { return nil }
        return text
    }

    private func markRevoked() {
        guard !isClosed else { return }
        isClosed = true
        isAvailable = false
        eventTask?.cancel()
        eventTask = nil
    }

    private func markCompleted(_ outcome: ShareArtifactOutcomeDTO) {
        guard !isClosed else { return }
        isClosed = true
        isAvailable = false
        self.outcome = outcome
        eventTask?.cancel()
        eventTask = nil
    }
}

private extension UTType {
    static let runtimeRuneScribe = UTType(
        exportedAs: RuneScribeWireFormat.contentType
    )
}

private struct RuntimeShareExportArtifact: Transferable {
    let url: URL
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .runtimeRuneScribe) { artifact in
            SentTransferredFile(artifact.url)
        }
        .suggestedFileName { artifact in
            artifact.filename + "." + RuneScribeWireFormat.fileExtension
        }
    }
}

private struct RuntimeShareArtifactExporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var transfer: OpaqueShareTransfer
    let defaultFilename: String
    let onFinish: @MainActor (ShareArtifactOutcomeDTO) -> Void

    private var item: RuntimeShareExportArtifact? {
        guard let url = transfer.presentationURL else { return nil }
        return RuntimeShareExportArtifact(url: url, filename: defaultFilename)
    }

    func body(content: Content) -> some View {
        content.fileExporter(
            isPresented: $isPresented,
            item: item,
            contentTypes: [.runtimeRuneScribe],
            defaultFilename: defaultFilename
        ) { result in
            switch result {
            case .success:
                onFinish(.handedOff)
            case .failure:
                onFinish(.failed)
            }
        } onCancellation: {
            onFinish(.cancelled)
        }
    }
}

public extension View {
    func runtimeShareArtifactExporter(
        isPresented: Binding<Bool>,
        transfer: OpaqueShareTransfer?,
        defaultFilename: String,
        onFinish: @escaping @MainActor (ShareArtifactOutcomeDTO) -> Void
    ) -> some View {
        Group {
            if let transfer {
                modifier(
                    RuntimeShareArtifactExporterModifier(
                        isPresented: isPresented,
                        transfer: transfer,
                        defaultFilename: defaultFilename,
                        onFinish: onFinish
                    )
                )
            } else {
                self
            }
        }
    }
}
