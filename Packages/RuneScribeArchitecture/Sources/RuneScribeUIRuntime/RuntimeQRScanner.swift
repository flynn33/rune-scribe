#if os(iOS)
import AVFoundation
import Foundation
import Observation
import SwiftUI
import UIKit

public enum QRScannerPermissionAction: Equatable, Sendable {
    case ready
    case requestAccess
    case denied

    public static func resolve(_ authorization: AVAuthorizationStatus) -> Self {
        switch authorization {
        case .authorized:
            .ready
        case .notDetermined:
            .requestAccess
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }
}

@MainActor
@Observable
public final class RuntimeQRScannerController {
    public enum Status: Equatable, Sendable {
        case checking
        case ready
        case denied
    }

    public private(set) var status: Status = .checking

    public init() {}

    public func resolvePermission() async {
        switch QRScannerPermissionAction.resolve(
            AVCaptureDevice.authorizationStatus(for: .video)
        ) {
        case .ready:
            status = .ready
        case .requestAccess:
            status = await AVCaptureDevice.requestAccess(for: .video)
                ? .ready
                : .denied
        case .denied:
            status = .denied
        }
    }

    public func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(url)
    }
}

@MainActor
public struct RuntimeQRScannerPreview: UIViewControllerRepresentable {
    private let onScan: @MainActor (String) -> Void

    public init(onScan: @escaping @MainActor (String) -> Void) {
        self.onScan = onScan
    }

    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = RuntimeQRScannerViewController()
        controller.onScan = onScan
        return controller
    }

    public func updateUIViewController(
        _ viewController: UIViewController,
        context: Context
    ) {
        guard let controller = viewController as? RuntimeQRScannerViewController else {
            return
        }
        controller.onScan = onScan
    }
}

/// Owns the `AVCaptureSession`. The session is created and started on the main
/// actor (this controller is `@MainActor` by virtue of `UIViewController`), which
/// keeps it free of non-`Sendable` captures across queues under Swift 6. Metadata
/// is delivered on a background queue and the result is hopped back to the main
/// actor before touching any state.
private final class RuntimeQRScannerViewController: UIViewController,
    AVCaptureMetadataOutputObjectsDelegate
{
    var onScan: (@MainActor (String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataQueue = DispatchQueue(label: "com.runescribe.qr.metadata")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasCompleted = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: metadataQueue)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.hasCompleted else { return }
            self.hasCompleted = true
            self.session.stopRunning()
            self.onScan?(value)
        }
    }
}
#endif
