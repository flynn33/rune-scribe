// RuneScrib/Views/Components/QRScannerView.swift

#if os(iOS)
import RuneScribeUIRuntime
import SwiftUI

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
@MainActor
struct QRScannerView: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onScan: (String) -> Void
    let onCancel: () -> Void

    @State private var scannerController = RuntimeQRScannerController()
    @State private var completionGate = QRScannerCompletionGate()

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
                slot: .qrScan,
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
        .task { await scannerController.resolvePermission() }
        // Re-check after the user returns from Settings having changed the grant.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await scannerController.resolvePermission() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            Color.black
            switch scannerController.status {
            case .checking:
                ProgressView().tint(.runeGold)
            case .ready:
                RuntimeQRScannerPreview(onScan: handleScan)
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
                .foregroundColor(.runeTextPrimary)
            Text("Allow camera access for Rune Scribe in Settings to scan a cipher QR code.")
                .font(.system(size: 12))
                .foregroundColor(.runeSilver)
                .multilineTextAlignment(.center)
                .padding(.horizontal, RuneMetrics.pad)
            Button { scannerController.openSettings() } label: {
                Label("Open Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .padding(.horizontal, RuneMetrics.pad)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if scannerController.status == .ready {
            Text("Point the camera at a Rune Scribe QR code.")
                .font(.system(size: 12))
                .foregroundColor(.runeSilver)
                .padding(.vertical, 14)
        }
    }

    private func handleScan(_ code: String) {
        complete(.scanned(code))
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
}
#endif
