// RuneScrib/Views/KeyManagementView.swift

import SwiftUI

#if os(macOS)
import AppKit
#endif

struct KeyManagementView: View {

    // MARK: - Environment

    @EnvironmentObject private var keyManager: KeyManager

    // MARK: - State

    @State private var showRotateConfirmation: Bool = false
    @State private var exportStatus: ExportStatus = .idle
    @Environment(\.dismiss) private var dismiss

    #if os(iOS)
    @State private var shareItems: ShareItems?
    #endif

    // MARK: - Types

    enum ExportStatus {
        case idle
        case success([URL])
        case failure(String)
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {

            RuneHeader(
                runic: "ᚱᚢᚾᛖ ᚲᛖᚤ",
                subtitle: "Key Management",
                trailingButton: RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {

                    // ── Current Key Info ──────────────────────────────────────
                    RunePanel(title: "Current Cipher Key", systemImage: "lock.shield.fill", accent: .runeSilver) {
                        VStack(alignment: .leading, spacing: 9) {
                            infoRow("Status",
                                    keyManager.currentKey != nil ? "Active" : "Not Loaded",
                                    color: keyManager.currentKey != nil ? .green : .orange)

                            if let key = keyManager.currentKey {
                                infoRow("Key ID", String(key.keyId.prefix(18)) + "…")
                                infoRow("Version", "\(key.version)")
                                infoRow("Created", key.createdAt.formatted(
                                    .dateTime.day().month(.abbreviated).year().hour().minute()))
                                infoRow("Characters", "\(key.mapping.count) of 89")
                            }

                            if keyManager.isLoading {
                                HStack(spacing: 8) {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Working…")
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.runeSilver)
                                }
                            }
                        }
                    }

                    // ── Export Section ────────────────────────────────────────
                    RunePanel(title: "Export Key for AI Models", systemImage: "square.and.arrow.up", accent: .runeGold) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Share the cipher with an AI model (Claude, ChatGPT, Grok). Writes the key as .json + .md, and bundles the Noto Sans Runic font so every rune displays wherever the decipher is opened.")
                                .font(.system(size: 12))
                                .foregroundColor(.runeSilver)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Button {
                                exportKey()
                            } label: {
                                Label("Export Key  ·  JSON + Markdown", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RuneScribButtonStyle())
                            .disabled(keyManager.currentKey == nil || keyManager.isLoading)

                            exportStatusView
                        }
                    }

                    // ── Rotate Section ────────────────────────────────────────
                    RunePanel(title: "Rotate Cipher Key", systemImage: "arrow.clockwise", accent: .runeBlue) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Generates a new random mapping. Messages encoded with the current key become permanently undecodable — export first if you need a record.")
                                .font(.system(size: 12))
                                .foregroundColor(.orange.opacity(0.85))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(role: .destructive) {
                                showRotateConfirmation = true
                            } label: {
                                Label("Rotate Key…", systemImage: "arrow.clockwise.circle.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RuneSecondaryButtonStyle())
                            .disabled(keyManager.isLoading)
                        }
                    }
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)

        // ── Rotate Confirmation Alert ─────────────────────────────────────────
        .alert("Rotate Cipher Key?", isPresented: $showRotateConfirmation) {
            Button("Export Key First") {
                exportKey()
            }
            Button("Rotate Without Exporting", role: .destructive) {
                Task { try? await keyManager.rotateKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently replace the current cipher mapping. " +
                 "Encoded messages using the old key will no longer be decodable. " +
                 "Do you want to export the current key before rotating?")
        }
        #if os(iOS)
        // On iOS the exported files are handed to the system share sheet.
        .sheet(item: $shareItems) { items in
            ActivityView(activityItems: items.urls)
        }
        #endif
    }

    // MARK: - Subviews

    @ViewBuilder
    private var exportStatusView: some View {
        switch exportStatus {
        case .idle:
            EmptyView()
        case .success(let urls):
            VStack(alignment: .leading, spacing: 4) {
                Label("Export successful", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.green)
                ForEach(urls, id: \.self) { url in
                    Text("→ \(url.lastPathComponent)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.runeSilver)
                }
            }
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
    }

    // MARK: - Helpers

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
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Actions

    private func exportKey() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a folder to save the RuneScrib cipher key files."
        panel.prompt = "Export Here"

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        do {
            let urls = try keyManager.exportKey(to: directory)
            exportStatus = .success(urls)
        } catch {
            exportStatus = .failure(error.localizedDescription)
        }
        #elseif os(iOS)
        // No folder picker on iOS: write to a temp folder, then share the files so
        // the user can Save to Files, AirDrop, Mail, etc.
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("RuneScribExport-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let urls = try keyManager.exportKey(to: dir)
            exportStatus = .success(urls)
            shareItems = ShareItems(urls: urls)
        } catch {
            exportStatus = .failure(error.localizedDescription)
        }
        #endif
    }
}
