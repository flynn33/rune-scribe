// RuneScrib/Views/QRDisplaySheet.swift

import SwiftUI

/// Shows a cipher as a scannable QR code (point the iPhone Camera app at it to
/// import) and offers a Share button that sends the same `runescribe://import`
/// link via Messages, Mail, AirDrop, etc. The QR and the shared link carry the
/// identical payload.
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

                    Text("Point another iPhone's Camera at this code to import the cipher, "
                         + "or use Share to send the link in Messages.")
                        .font(.system(size: 12))
                        .foregroundColor(.runeSilver)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    ShareLink(item: url,
                              subject: Text(label),
                              message: Text("Import my Rune Scribe cipher")) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
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
