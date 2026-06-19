// RuneScrib/Views/SettingsView.swift

import SwiftUI

/// App settings: the 4-digit app-lock PIN, an About section attributing the app
/// to Raven Forge Software, and access to the End-User License Agreement.
struct SettingsView: View {

    @EnvironmentObject private var appLock: AppLock
    @Environment(\.dismiss) private var dismiss

    @State private var pinFlow: PINFlowView.Mode?
    @State private var showLicense = false

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᛋᛖᛏᛏᛁᛜᛋ",
                subtitle: "Settings",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    appLockPanel
                    aboutPanel
                    licensePanel
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .sheet(item: $pinFlow) { mode in
            PINFlowView(mode: mode).environmentObject(appLock)
        }
        .sheet(isPresented: $showLicense) {
            LicenseView()
        }
    }

    // MARK: - App Lock

    private var appLockPanel: some View {
        RunePanel(title: "App Lock", systemImage: "lock.fill", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text(appLock.isPINSet
                     ? "A 4-digit PIN is required each time Rune-Scribe launches or returns from the background."
                     : "Protect Rune-Scribe with a 4-digit PIN, required on launch and when returning from the background.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                infoRow("Status",
                        appLock.isPINSet ? "PIN set" : "No PIN",
                        color: appLock.isPINSet ? .green : .runeSilver)

                if appLock.isPINSet {
                    HStack(spacing: 12) {
                        Button { pinFlow = .change } label: {
                            Label("Change PIN", systemImage: "lock.rotation")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())

                        Button(role: .destructive) { pinFlow = .disable } label: {
                            Label("Disable", systemImage: "lock.open")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())
                    }
                } else {
                    Button { pinFlow = .set } label: {
                        Label("Set a PIN…", systemImage: "lock.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }
            }
        }
    }

    // MARK: - About

    private var aboutPanel: some View {
        RunePanel(title: "About", systemImage: "info.circle", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rune-Scribe")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Spacer()
                    Text("v\(appVersion) (\(buildNumber))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.runeSilver)
                }

                Text("A \(AppLicense.company) product.")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.runeGold)

                Text("Rune-Scribe turns your messages into Norse runes with a private substitution cipher that stays encrypted on your device.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = URL(string: "https://ravenforgesoftware.com") {
                    Link(destination: url) {
                        Label("ravenforgesoftware.com", systemImage: "globe")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.runeBlue)
                    }
                }
            }
        }
    }

    // MARK: - License

    private var licensePanel: some View {
        RunePanel(title: "License", systemImage: "doc.text", accent: .runeSilver) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rune-Scribe is licensed, not sold. Your use is governed by the End-User License Agreement.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button { showLicense = true } label: {
                    Label("View License", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
            }
        }
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String, color: Color = .white) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundColor(.runeSilver)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundColor(color)
            Spacer()
        }
    }
}
