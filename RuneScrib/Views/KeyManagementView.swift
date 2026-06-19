// RuneScrib/Views/KeyManagementView.swift

import SwiftUI
import UniformTypeIdentifiers

struct KeyManagementView: View {

    // MARK: - Environment

    @EnvironmentObject private var keyManager: KeyManager

    // MARK: - State

    @State private var showRotateConfirmation = false
    @Environment(\.dismiss) private var dismiss

    @State private var showExporter = false
    @State private var exportDocument = DecoderDocument(data: Data())
    @State private var exportFilename = "RuneScrib-Decoder"
    @State private var exportStatus: Status = .idle

    @State private var showImporter = false
    @State private var importStatus: Status = .idle

    // MARK: - Types

    enum Status: Equatable {
        case idle
        case success(String)
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
                    currentKeyPanel
                    exportPanel
                    importPanel
                    rotatePanel
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        // ── Single-file export (cross-platform) ───────────────────────────────
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url):
                exportStatus = .success("Saved \(url.lastPathComponent)")
            case .failure(let error):
                exportStatus = .failure(error.localizedDescription)
            }
        }
        // ── Decoder import (cross-platform) ───────────────────────────────────
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        // ── Rotate confirmation ───────────────────────────────────────────────
        .alert("Rotate Cipher Key?", isPresented: $showRotateConfirmation) {
            Button("Export Decoder First") { beginExport() }
            Button("Rotate Without Exporting", role: .destructive) {
                Task { try? await keyManager.rotateKey() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently replaces the current cipher mapping. Messages encoded " +
                 "with the old key will no longer be decodable. Export the decoder first " +
                 "if you need a record.")
        }
    }

    // MARK: - Panels

    private var currentKeyPanel: some View {
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
    }

    private var exportPanel: some View {
        RunePanel(title: "Export Decoder", systemImage: "square.and.arrow.up", accent: .runeGold) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Save the decoder as a single .json file. Import it into RuneScrib to " +
                     "decode messages, or share it with an AI model (Claude, ChatGPT, Grok).")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    beginExport()
                } label: {
                    Label("Export Decoder File…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneScribButtonStyle())
                .disabled(keyManager.currentKey == nil || keyManager.isLoading)

                statusLabel(exportStatus)
            }
        }
    }

    private var importPanel: some View {
        RunePanel(title: "Import Decoder", systemImage: "square.and.arrow.down", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Import a decoder file someone shared with you, then paste their runes " +
                     "into the Decode tab to read the message.")
                    .font(.system(size: 12))
                    .foregroundColor(.runeSilver)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let decoder = keyManager.importedDecoder {
                    infoRow("Decoder", String(decoder.keyId.prefix(18)) + "…")
                    infoRow("Created", decoder.createdAt.formatted(
                        .dateTime.day().month(.abbreviated).year().hour().minute()))

                    HStack(spacing: 12) {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Replace…", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())

                        Button(role: .destructive) {
                            keyManager.clearImportedDecoder()
                            importStatus = .idle
                        } label: {
                            Label("Remove", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())
                    }
                } else {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Decoder File…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }

                statusLabel(importStatus)
            }
        }
    }

    private var rotatePanel: some View {
        RunePanel(title: "Rotate Cipher Key", systemImage: "arrow.clockwise", accent: .runeBlue) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generates a new random mapping. Messages encoded with the current key " +
                     "become permanently undecodable — export the decoder first if you need a record.")
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

    // MARK: - Helpers

    @ViewBuilder
    private func statusLabel(_ status: Status) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.red)
        }
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
                .textSelection(.enabled)
            Spacer()
        }
    }

    // MARK: - Actions

    private func beginExport() {
        do {
            exportDocument = DecoderDocument(data: try keyManager.decoderExportData())
            exportFilename = keyManager.decoderExportFilename
            exportStatus = .idle
            showExporter = true
        } catch {
            exportStatus = .failure(error.localizedDescription)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let decoder = try keyManager.importDecoder(data: data)
                importStatus = .success("Imported decoder \(String(decoder.keyId.prefix(8)))…")
            } catch {
                importStatus = .failure(error.localizedDescription)
            }
        case .failure(let error):
            importStatus = .failure(error.localizedDescription)
        }
    }
}
