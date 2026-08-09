// RuneScrib/Views/Components/QRScannerView.swift

#if os(iOS)
import SwiftUI
import AVFoundation

enum QRScannerPermissionAction: Equatable, Sendable {
    case ready
    case requestAccess
    case denied

    static func resolve(_ authorization: AVAuthorizationStatus) -> Self {
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

enum QRScannerCompletion: Equatable, Sendable {
    case scanned(String)
    case cancelled
}

struct QRScannerCompletionGate: Equatable, Sendable {
    private(set) var hasCompleted = false

    mutating func accept(_ completion: QRScannerCompletion) -> QRScannerCompletion? {
        guard !hasCompleted else { return nil }
        hasCompleted = true
        return completion
    }
}

/// Full-screen QR scanner sheet (iOS). Requests camera access, shows a live
/// preview, and reports the first scanned string via `onScan`; the caller decodes
/// and routes it. macOS has no scanner — the whole file is iOS-only.
struct QRScannerView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onScan: (String) -> Void
    let onCancel: () -> Void

    @State private var status: Status = .checking
    @State private var completionGate = QRScannerCompletionGate()
    private enum Status { case checking, ready, denied }

    init(
        onScan: @escaping (String) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.onScan = onScan
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛊᚲᚨᚾ",
                subtitle: "Scan QR",
                trailingButtons: [
                    RuneHeaderButton(systemImage: "xmark", help: "Close") {
                        complete(.cancelled)
                    },
                ]
            )
            content
            footer
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .task { await resolvePermission() }
        // Re-check after the user returns from Settings having changed the grant.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await resolvePermission() } }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Color.black
            switch status {
            case .checking:
                ProgressView().tint(.runeGold)
            case .ready:
                CameraPreview(onScan: handleScan)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.runeGold.opacity(0.9), lineWidth: 3)
                    .frame(width: 220, height: 220)
            case .denied:
                deniedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 34))
                .foregroundColor(.runeSilver)
            Text("Camera access is off")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
            Text("Allow camera access for Rune Scribe in Settings to scan a cipher QR code.")
                .font(.system(size: 12))
                .foregroundColor(.runeSilver)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RuneMetrics.pad)
            Button { openSettings() } label: {
                Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .padding(.horizontal, RuneMetrics.pad)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if status == .ready {
            Text("Point the camera at a Rune Scribe QR code.")
                .font(.system(size: 12))
                .foregroundColor(.runeSilver)
                .padding(.vertical, 14)
        }
    }

    private func handleScan(_ code: String) {
        complete(.scanned(code))
    }

    private func resolvePermission() async {
        switch QRScannerPermissionAction.resolve(
            AVCaptureDevice.authorizationStatus(for: .video)
        ) {
        case .ready:
            status = .ready
        case .requestAccess:
            status = await AVCaptureDevice.requestAccess(for: .video) ? .ready : .denied
        case .denied:
            status = .denied
        }
    }

    private func complete(_ proposed: QRScannerCompletion) {
        guard let completion = completionGate.accept(proposed) else { return }
        switch completion {
        case .scanned(let code):
            onScan(code)
        case .cancelled:
            onCancel()
        }
        dismiss()
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Camera preview bridge

private struct CameraPreview: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

/// Owns the `AVCaptureSession`. The session is created and started on the main
/// actor (this controller is `@MainActor` by virtue of `UIViewController`), which
/// keeps it free of non-`Sendable` captures across queues under Swift 6. Metadata
/// is delivered on a background queue and the result is hopped back to the main
/// actor before touching any state.
final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {

    var onScan: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let metadataQueue = DispatchQueue(label: "com.runescribe.qr.metadata")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var completionGate = QRScannerCompletionGate()

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
        // Starting on the main actor avoids a non-Sendable session crossing a queue
        // boundary; the brief hitch is acceptable for a transient scanner sheet.
        if !session.isRunning { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  case .scanned(let code)? = self.completionGate.accept(.scanned(value))
            else { return }
            self.session.stopRunning()
            self.onScan?(code)
        }
    }
}
#endif
