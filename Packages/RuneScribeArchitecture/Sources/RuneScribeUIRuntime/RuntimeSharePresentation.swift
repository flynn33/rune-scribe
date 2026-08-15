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

public typealias SharePresentationCompletion = Result<
    ShareArtifactCompletionEvidenceDTO,
    any Error
>

public enum FileExportTerminalResult: Equatable, Sendable {
    case saved
    case cancelled
    case failed
}

public enum RuneScribeUtilityShareReportMapper {
    public static func fileExport(
        _ result: FileExportTerminalResult
    ) -> SharePresentationReportDTO {
        let routeResult: ShareRouteResultDTO = switch result {
        case .saved: .completionUnavailable
        case .cancelled: .cancelled
        case .failed: .failed
        }
        return try! SharePresentationReportDTO(
            routeClass: .fileExport,
            result: routeResult
        )
    }

    public static var clipboardCompletion: SharePresentationReportDTO {
        try! SharePresentationReportDTO(
            routeClass: .clipboard,
            result: .completionUnavailable
        )
    }

    public static var qrDisplayCompletion: SharePresentationReportDTO {
        try! SharePresentationReportDTO(
            routeClass: .qrDisplay,
            result: .completionUnavailable
        )
    }
}

/// Runtime-owned lease for one artifact presentation. The platform URL remains
/// private to RuneScribeUIRuntime and is invalidated with the originating
/// runtime/module generation.
@MainActor
public final class OpaqueShareTransfer: ObservableObject {
    public let artifactID: ShareArtifactID

    @Published public private(set) var isAvailable = true
    @Published public private(set) var presentationReport: SharePresentationReportDTO?
    @Published public private(set) var completionEvidence: ShareArtifactCompletionEvidenceDTO?

    private let lease: RuntimeSharePresentationLease
    private var eventTask: Task<Void, Never>?
    private var isClosed = false
    private var hasBegunTerminalFinish = false

    private init(
        artifactID: ShareArtifactID,
        lease: RuntimeSharePresentationLease,
        presentationEvents: AsyncStream<RuntimeSharePresentationEvent>
    ) {
        self.artifactID = artifactID
        self.lease = lease
        eventTask = Task { @MainActor [weak self] in
            for await event in presentationEvents {
                switch event {
                case .presented(let report):
                    self?.presentationReport = report
                case .completed(let evidence):
                    self?.markCompleted(evidence)
                case .revoked:
                    self?.markRevoked()
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
        let presentationEvents = await lease.presentationEvents()
        try Task.checkCancellation()
        return OpaqueShareTransfer(
            artifactID: artifactID,
            lease: lease,
            presentationEvents: presentationEvents
        )
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        isAvailable = false
        eventTask?.cancel()
        eventTask = nil
        await lease.close()
    }

    public func reportPresented(on routeClass: ShareRouteClassDTO) async throws {
        guard !isClosed, !hasBegunTerminalFinish else {
            throw OpaqueSharePresentationError.revoked
        }
        try await lease.reportPresented(on: routeClass)
    }

    public func finish(
        _ report: SharePresentationReportDTO
    ) async throws -> ShareArtifactCompletionEvidenceDTO {
        guard report.isTerminal,
              !isClosed,
              !hasBegunTerminalFinish
        else {
            throw OpaqueSharePresentationError.revoked
        }
        hasBegunTerminalFinish = true
        do {
            let evidence = try await lease.finish(report)
            markCompleted(evidence)
            return evidence
        } catch {
            hasBegunTerminalFinish = false
            throw error
        }
    }

    public func finishClipboardCopy() async throws -> ShareArtifactCompletionEvidenceDTO {
        try await finish(RuneScribeUtilityShareReportMapper.clipboardCompletion)
    }

    public func finishQRDisplay() async throws -> ShareArtifactCompletionEvidenceDTO {
        try await finish(RuneScribeUtilityShareReportMapper.qrDisplayCompletion)
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
        hasBegunTerminalFinish = true
        isAvailable = false
        eventTask?.cancel()
        eventTask = nil
    }

    private func markCompleted(_ evidence: ShareArtifactCompletionEvidenceDTO) {
        guard !isClosed else { return }
        isClosed = true
        hasBegunTerminalFinish = true
        isAvailable = false
        completionEvidence = evidence
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
    let onFinish: @MainActor (SharePresentationCompletion) -> Void

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
                finish(with: .saved)
            case .failure:
                finish(with: .failed)
            }
        } onCancellation: {
            finish(with: .cancelled)
        }
        .onChange(of: isPresented, initial: true) { _, presented in
            guard presented else { return }
            Task { @MainActor in
                try? await transfer.reportPresented(on: .fileExport)
            }
        }
    }

    private func finish(with result: FileExportTerminalResult) {
        Task { @MainActor in
            do {
                let report = RuneScribeUtilityShareReportMapper.fileExport(result)
                onFinish(.success(try await transfer.finish(report)))
            } catch {
                onFinish(.failure(error))
            }
        }
    }
}

public extension View {
    func runtimeShareArtifactExporter(
        isPresented: Binding<Bool>,
        transfer: OpaqueShareTransfer?,
        defaultFilename: String,
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void
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
