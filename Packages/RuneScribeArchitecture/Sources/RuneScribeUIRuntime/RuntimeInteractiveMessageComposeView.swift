#if os(iOS)
import Foundation
import MessageUI
import Messages
import RuneScribeContracts
import RuneScribeMessagesShared
import SwiftUI
import UIKit

public enum RuneScribeInteractiveMessageError: Error, Equatable, Sendable {
    case unavailable
    case invalidInvitation
    case invalidArtwork
}

@_spi(RuntimeTesting)
public struct RuneScribePreparedInteractiveMessage {
    public let message: MSMessage
    public let body: String
}

@_spi(RuntimeTesting)
@MainActor
public enum RuneScribeInteractiveMessageFactory {
    public static func make(
        invitationURL: URL,
        cipherLabel: String,
        previewImageData: Data
    ) throws -> RuneScribePreparedInteractiveMessage {
        let invitation: MessagesValidatedInvitation
        do {
            invitation = try MessagesInvitationValidator.validate(invitationURL)
        } catch {
            throw RuneScribeInteractiveMessageError.invalidInvitation
        }
        guard let artwork = RuneScribeMessagesBubbleArtworkAdapter.image(
            from: previewImageData
        ) else {
            throw RuneScribeInteractiveMessageError.invalidArtwork
        }

        let layout = MSMessageTemplateLayout()
        layout.image = artwork
        layout.caption = "Rune Scribe cipher: \(cipherLabel)"
        layout.subcaption = "Tap the artwork to continue in Rune Scribe."

        let message = MSMessage()
        message.url = invitation.URL
        message.layout = layout
        message.summaryText = "Rune Scribe cipher invitation"
        message.accessibilityLabel = "Rune Scribe cipher invitation. Tap to continue."

        return RuneScribePreparedInteractiveMessage(
            message: message,
            body: "Rune Scribe invitation fallback:\n\(invitation.URL.absoluteString)"
        )
    }
}

@_spi(RuntimeTesting)
@MainActor
public enum RuneScribeMessagesBubbleArtworkAdapter {
    public static let logicalSize = CGSize(width: 300, height: 225)
    public static let safeInsets = UIEdgeInsets(
        top: 9,
        left: 12,
        bottom: 9,
        right: 12
    )

    public static func image(from PNGData: Data) -> UIImage? {
        guard PNGData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
              let source = UIImage(data: PNGData),
              source.size.width > 0,
              source.size.height > 0
        else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = min(max(UIScreen.main.scale, 2), 3)
        return UIGraphicsImageRenderer(size: logicalSize, format: format).image { context in
            let canvas = CGRect(origin: .zero, size: logicalSize)
            sampledPaletteColor(from: source).setFill()
            context.fill(canvas)

            let safeRect = canvas.inset(by: safeInsets)
            let scale = min(
                safeRect.width / source.size.width,
                safeRect.height / source.size.height
            )
            let fittedSize = CGSize(
                width: source.size.width * scale,
                height: source.size.height * scale
            )
            let fittedRect = CGRect(
                x: safeRect.midX - fittedSize.width / 2,
                y: safeRect.midY - fittedSize.height / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
            source.draw(in: fittedRect)
        }
    }

    private static func sampledPaletteColor(from image: UIImage) -> UIColor {
        guard let CGImage = image.cgImage else { return .secondarySystemBackground }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return .secondarySystemBackground }
        context.interpolationQuality = .medium
        context.draw(CGImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}

public struct RuneScribePreparedInteractiveMessageLauncher: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let cipherLabel: String
    private let previewImageData: Data?
    private let launchID: UUID
    private let onPresented: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationReportDTO) -> Void

    @State private var presentation: InteractiveMessagePresentation?

    public init(
        transfer: OpaqueShareTransfer,
        cipherLabel: String,
        previewImageData: Data?,
        launchID: UUID,
        onPresented: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationReportDTO) -> Void
    ) {
        self.transfer = transfer
        self.cipherLabel = cipherLabel
        self.previewImageData = previewImageData
        self.launchID = launchID
        self.onPresented = onPresented
        self.onFinish = onFinish
    }

    public var body: some View {
        Color.clear
            .task(id: launchID) { preparePresentation() }
            .sheet(item: $presentation) { presentation in
                InteractiveMessageComposeView(
                    presentation: presentation,
                    onPresented: {
                        transfer.beginReportingPresented(on: .messages)
                        onPresented()
                    },
                    onFinish: { report in
                        onFinish(report)
                        self.presentation = nil
                    }
                )
            }
    }

    private func preparePresentation() {
        guard presentation == nil,
              MFMessageComposeViewController.canSendText(),
              let invitationURL = transfer.presentationURL,
              let previewImageData
        else {
            failBeforePresentation()
            return
        }
        do {
            presentation = InteractiveMessagePresentation(
                prepared: try RuneScribeInteractiveMessageFactory.make(
                    invitationURL: invitationURL,
                    cipherLabel: cipherLabel,
                    previewImageData: previewImageData
                )
            )
        } catch {
            failBeforePresentation()
        }
    }

    private func failBeforePresentation() {
        onFinish(try! SharePresentationReportDTO(
            routeClass: .messages,
            result: .failed
        ))
    }
}

public struct RuneScribeInteractiveMessageButton<Label: View>: View {
    @ObservedObject private var transfer: OpaqueShareTransfer
    private let cipherLabel: String
    private let previewImageData: Data
    private let onShareTriggered: @MainActor () -> Void
    private let onPresented: @MainActor () -> Void
    private let onFinish: @MainActor (SharePresentationReportDTO) -> Void
    private let label: () -> Label

    @State private var presentation: InteractiveMessagePresentation?

    public init(
        transfer: OpaqueShareTransfer,
        cipherLabel: String,
        previewImageData: Data,
        onShareTriggered: @escaping @MainActor () -> Void = {},
        onPresented: @escaping @MainActor () -> Void = {},
        onFinish: @escaping @MainActor (SharePresentationReportDTO) -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.transfer = transfer
        self.cipherLabel = cipherLabel
        self.previewImageData = previewImageData
        self.onShareTriggered = onShareTriggered
        self.onPresented = onPresented
        self.onFinish = onFinish
        self.label = label
    }

    public var body: some View {
        Button(action: preparePresentation, label: label)
            .sheet(item: $presentation) { presentation in
                InteractiveMessageComposeView(
                    presentation: presentation,
                    onPresented: onPresented,
                    onFinish: { report in
                        onFinish(report)
                        self.presentation = nil
                    }
                )
            }
    }

    private func preparePresentation() {
        guard presentation == nil,
              MFMessageComposeViewController.canSendText(),
              let invitationURL = transfer.presentationURL
        else {
            reportFailure()
            return
        }
        onShareTriggered()
        do {
            presentation = InteractiveMessagePresentation(
                prepared: try RuneScribeInteractiveMessageFactory.make(
                    invitationURL: invitationURL,
                    cipherLabel: cipherLabel,
                    previewImageData: previewImageData
                )
            )
        } catch {
            reportFailure()
        }
    }

    private func reportFailure() {
        onFinish(try! SharePresentationReportDTO(
            routeClass: .messages,
            result: .failed
        ))
    }
}

@MainActor
private final class InteractiveMessagePresentation: Identifiable {
    let id = UUID()
    let prepared: RuneScribePreparedInteractiveMessage

    init(prepared: RuneScribePreparedInteractiveMessage) {
        self.prepared = prepared
    }
}

@MainActor
private struct InteractiveMessageComposeView: UIViewControllerRepresentable {
    let presentation: InteractiveMessagePresentation
    let onPresented: @MainActor () -> Void
    let onFinish: @MainActor (SharePresentationReportDTO) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let composer = MFMessageComposeViewController()
        composer.messageComposeDelegate = context.coordinator
        composer.message = presentation.prepared.message
        composer.body = presentation.prepared.body
        onPresented()
        return composer
    }

    func updateUIViewController(
        _ controller: MFMessageComposeViewController,
        context: Context
    ) {}

    @MainActor
    final class Coordinator: NSObject,
        @preconcurrency MFMessageComposeViewControllerDelegate
    {
        private let onFinish: @MainActor (SharePresentationReportDTO) -> Void
        private var hasFinished = false

        init(onFinish: @escaping @MainActor (SharePresentationReportDTO) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            guard !hasFinished else { return }
            hasFinished = true
            let routeResult: ShareRouteResultDTO = switch result {
            case .sent: .sentConfirmed
            case .cancelled: .cancelled
            case .failed: .failed
            @unknown default: .failed
            }
            onFinish(try! SharePresentationReportDTO(
                routeClass: .messages,
                result: routeResult
            ))
        }
    }
}
#endif
