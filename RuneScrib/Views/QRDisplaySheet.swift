// RuneScrib/Views/QRDisplaySheet.swift

import SwiftUI

/// Shows a cipher as a scannable QR code — the only way a cipher is shared. Point the
/// iPhone Camera (or Rune Scribe's in-app scanner) at it to import; the QR carries the whole
/// cipher as an offline `runescribe://import` payload, so nothing leaves the device and no
/// server is involved. There is deliberately no shareable link.
struct QRDisplaySheet: View {

    @Environment(\.dismiss) private var dismiss

    let url: URL
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛊᚺᚨᚱᛖ",
                subtitle: "Share via QR",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(spacing: RuneMetrics.sectionGap) {
                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
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
    }

    @ViewBuilder
    private var qrImage: some View {
        if let image = QRCodeGenerator.image(for: url) {
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
}
