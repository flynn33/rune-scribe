// RuneScrib/Views/LicenseView.swift

import SwiftUI

/// Displays the Apache License 2.0 notice (Settings → View License).
struct LicenseView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .license,
                subtitle: "License",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                Text(AppLicense.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
    }
}
