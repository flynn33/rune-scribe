// RuneScrib/Views/SettingsView.swift

import RuneScribeContracts
import SwiftUI

/// App settings: the 4-digit app-lock PIN, an About section attributing the app
/// to Raven Forge Software, and access to the End-User License Agreement.
struct SettingsView: View {

    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss

    @State private var pinFlow: PINFlowView.Mode?
    @State private var showLicense = false
    @State private var showContacts = false
    @State private var showVaultProgress = false

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .settings,
                subtitle: "Settings",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {
                    appearancePanel
                    progressAndFeedbackPanel
                    appLockPanel
                    contactsPanel
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
            PINFlowView(mode: mode)
        }
        .sheet(isPresented: $showLicense) {
            LicenseView()
        }
        .sheet(isPresented: $showContacts) {
            ContactsView()
        }
        .sheet(isPresented: $showVaultProgress) {
            VaultProgressView()
        }
    }

    // MARK: - Appearance

    private var appearancePanel: some View {
        RunePanel(title: "Appearance", systemImage: "paintpalette", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose one available Codex. This changes presentation only; your ciphers and messages stay the same.")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if let snapshot = session.themeSnapshot {
                    ForEach(snapshot.providers, id: \.codexID) { provider in
                        Button {
                            Task { await session.selectCodex(provider.codexID) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: providerIcon(provider))
                                    .frame(width: 20)
                                    .foregroundColor(
                                        provider.isSelected ? .runeSelected : .runeSilver
                                    )
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.runeTextPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(providerStatus(provider))
                                        .font(.caption)
                                        .foregroundColor(.runeSilver)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .layoutPriority(1)
                                Spacer(minLength: 8)
                                if provider.isSelected {
                                    Text("Selected")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.runeSelected)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                            }
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!provider.isSelectable || provider.isSelected)
                        .accessibilityLabel(provider.displayName)
                        .accessibilityValue(providerAccessibilityStatus(provider))
                        .accessibilityHint(
                            provider.isSelectable && !provider.isSelected
                                ? "Selects this Codex appearance"
                                : ""
                        )
                    }

                    if snapshot.fallbackReason != .none {
                        Label(
                            "Your preferred Codex is unavailable. The Base appearance is active.",
                            systemImage: "arrow.uturn.backward.circle"
                        )
                        .font(.footnote)
                        .foregroundColor(.runeWarning)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Label(
                        "Codex appearances are temporarily unavailable.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                }

                if let error = session.themeSelectionError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundColor(.runeWarning)
                }
            }
        }
    }

    private func providerStatus(_ provider: ThemeProviderSummaryDTO) -> String {
        if provider.isSelected { return "Available" }
        switch provider.state {
        case .available:
            return provider.isOwned ? "Available" : "Not owned"
        case .locked:
            return "Locked"
        case .unavailable:
            return "Temporarily unavailable"
        case .incompatible:
            return "Requires a newer app or system"
        case .invalidResources:
            return "Unavailable because required resources could not be verified"
        }
    }

    private func providerAccessibilityStatus(_ provider: ThemeProviderSummaryDTO) -> String {
        provider.isSelected ? "Available and selected" : providerStatus(provider)
    }

    private func providerIcon(_ provider: ThemeProviderSummaryDTO) -> String {
        if provider.isSelected { return "checkmark.circle.fill" }
        switch provider.state {
        case .available: return "circle"
        case .locked: return "lock.fill"
        case .unavailable, .invalidResources: return "exclamationmark.circle"
        case .incompatible: return "arrow.up.circle"
        }
    }

    // MARK: - Progress and Feedback

    private var progressAndFeedbackPanel: some View {
        RunePanel(title: "Progress & Feedback", systemImage: "medal", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 12) {
                Button { showVaultProgress = true } label: {
                    Label("Open Vault & Progress", systemImage: "archivebox.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())

                Text("Unlock text always remains visible. These switches independently control optional feedback.")
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)

                if session.settingsRailState == .unavailable {
                    Label(
                        "Feedback settings are temporarily unavailable. Current defaults remain in effect.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundColor(.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    feedbackToggle(
                        "Sound",
                        systemImage: "speaker.wave.2",
                        settingID: RuneScribeRuntimeSettings.unlockFeedbackSoundEnabled,
                        value: session.unlockFeedbackPreferences.soundEnabled
                    )
                    feedbackToggle(
                        "Haptic",
                        systemImage: "waveform.path",
                        settingID: RuneScribeRuntimeSettings.unlockFeedbackHapticsEnabled,
                        value: session.unlockFeedbackPreferences.hapticEnabled
                    )
                    feedbackToggle(
                        "Animation",
                        systemImage: "sparkles",
                        settingID: RuneScribeRuntimeSettings.unlockFeedbackAnimationEnabled,
                        value: session.unlockFeedbackPreferences.animationEnabled
                    )

                    if session.settingsRailState == .degraded {
                        Label("A setting could not be saved. Try again.", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.runeGoldBright)
                    }
                }
            }
        }
    }

    private func feedbackToggle(
        _ title: String,
        systemImage: String,
        settingID: RuntimeSettingID,
        value: Bool
    ) -> some View {
        Toggle(isOn: Binding(
            get: { value },
            set: { enabled in
                Task {
                    await session.setUnlockFeedbackSetting(settingID, enabled: enabled)
                }
            }
        )) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .foregroundColor(.runeTextPrimary)
        }
        .toggleStyle(.switch)
        .accessibilityHint("Does not hide unlock text")
    }

    // MARK: - App Lock

    private var appLockPanel: some View {
        RunePanel(title: "App Lock", systemImage: "lock.fill", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.isPINSet
                     ? "A 4-digit PIN is required each time Rune Scribe launches or returns from the background."
                     : "Protect Rune Scribe with a 4-digit PIN, required on launch and when returning from the background.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                infoRow("Status",
                        session.isPINSet ? "PIN set" : "No PIN",
                        color: session.isPINSet ? .runeSuccess : .runeSilver)

                if session.isPINSet {
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

    // MARK: - Contacts

    private var contactsPanel: some View {
        RunePanel(title: "Contacts", systemImage: "person.2.fill", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Organize your ciphers by contact. Import people from Apple Contacts or add them manually. Contacts stay encrypted on this device.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Button { showContacts = true } label: {
                    Label("Manage Contacts", systemImage: "person.2")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
            }
        }
    }

    // MARK: - About

    private var aboutPanel: some View {
        RunePanel(title: "About", systemImage: "info.circle", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Rune Scribe")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.runeTextPrimary)
                    Spacer()
                    Text("v\(appVersion) (\(buildNumber))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.runeSilver)
                }

                Text("A \(AppLicense.company) product.")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.runeGold)

                Text("Rune Scribe turns your messages into private symbolic inscriptions that stay encrypted on your device.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let url = URL(string: RuneScribeShare.productLink) {
                    Link(destination: url) {
                        Label("ravenforgesoftware.com", systemImage: "globe")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.runeBlue)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Raven Forge Software website")
                }
            }
        }
    }

    // MARK: - License

    private var licensePanel: some View {
        RunePanel(title: "License", systemImage: "doc.text", accent: .runeSilver) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Rune Scribe is licensed, not sold. Your use is governed by the End-User License Agreement.")
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
        session.appVersion
    }

    private var buildNumber: String {
        session.buildNumber
    }

    @ViewBuilder
    private func infoRow(
        _ label: String,
        _ value: String,
        color: Color = .runeTextPrimary
    ) -> some View {
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
