// RuneScrib/Views/QRDisplaySheet.swift

import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

/// Shows a cipher as a scannable QR code — the only way a cipher is shared. Point the
/// iPhone Camera (or Rune Scribe's in-app scanner) at it to import; the QR carries the whole
/// cipher as an offline `runescribe://import` payload, so nothing leaves the device and no
/// server is involved. There is deliberately no shareable link.
struct QRDisplaySheet: View {

    @Environment(\.dismiss) private var dismiss

    let transfer: OpaqueShareTransfer
    let label: String
    let onFinish: @MainActor (SharePresentationCompletion) -> Void

    @State private var hasBegunFinish = false

    init(
        transfer: OpaqueShareTransfer,
        label: String,
        onFinish: @escaping @MainActor (SharePresentationCompletion) -> Void = { _ in }
    ) {
        self.transfer = transfer
        self.label = label
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛊᚺᚨᚱᛖ",
                subtitle: "Share via QR",
                trailingButtons: [RuneHeaderButton(
                    systemImage: "xmark",
                    help: "Close"
                ) {
                    finish(dismissWhenFinished: true)
                }]
            )

            ScrollView {
                VStack(spacing: RuneMetrics.sectionGap) {
                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.runeTextPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    qrImage

                    Text("Point another iPhone's Camera at this code — or use Scan in Rune "
                         + "Scribe — to import the cipher. It never leaves your devices.")
                        .font(.system(size: 12))
                        .foregroundColor(.runeSilver)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .onAppear {
            Task { @MainActor in
                try? await transfer.reportPresented(on: .qrDisplay)
            }
        }
        .onDisappear {
            finish(dismissWhenFinished: false)
        }
    }

    @ViewBuilder
    private var qrImage: some View {
        if let image = transfer.qrCodeImage() {
            image
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 240, height: 240)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous).fill(.white))
                .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                    .strokeBorder(Color.runeGold.opacity(0.35), lineWidth: 1))
        } else {
            Text("Couldn't generate a QR code for this cipher.")
                .font(.system(size: 12))
                .foregroundColor(.runeSilver)
                .frame(height: 240)
        }
    }

    private func finish(dismissWhenFinished: Bool) {
        guard !hasBegunFinish else { return }
        hasBegunFinish = true
        Task { @MainActor in
            do {
                onFinish(.success(try await transfer.finishQRDisplay()))
            } catch {
                onFinish(.failure(error))
            }
            if dismissWhenFinished {
                dismiss()
            }
        }
    }
}
