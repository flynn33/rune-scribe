// RuneScrib/Views/CipherLibraryView.swift

import SwiftUI
import UniformTypeIdentifiers

/// The cipher library: create, import, label, select, export, and delete the
/// user's cipher/decipher pairs. The active cipher (used for both encoding and
/// decoding on the main screen) is highlighted and switchable here.
struct CipherLibraryView: View {

    @EnvironmentObject private var keyManager: KeyManager
    @Environment(\.dismiss) private var dismiss

    // Export
    @State private var showExporter = false
    @State private var exportDocument = DecoderDocument(data: Data())
    @State private var exportFilename = "RuneScrib-Decoder"

    // Import
    @State private var showImporter = false
    @State private var pendingImportData: Data?
    @State private var importLabel = ""
    @State private var showImportLabel = false

    // Create
    @State private var showNewCipher = false
    @State private var newLabel = ""

    // Rename
    @State private var renameTarget: NamedCipher?
    @State private var renameLabel = ""
    @State private var showRename = false

    // Delete
    @State private var deleteTarget: NamedCipher?
    @State private var showDelete = false

    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case success(String)
        case failure(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                runic: "ᚲᛁᛈᚺᛖᚱᛋ",
                subtitle: "Cipher Library",
                trailingButtons: [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
            )

            actionsBar

            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(keyManager.ciphers) { cipher in
                        cipherCard(cipher)
                    }
                }
                .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusFooter
        }
        .runeSheetFrame()
        .background(Color.runeNavy)
        .preferredColorScheme(.dark)
        .fileExporter(isPresented: $showExporter,
                      document: exportDocument,
                      contentType: .json,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url): status = .success("Saved \(url.lastPathComponent)")
            case .failure(let error): status = .failure(error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            handleImportSelection(result)
        }
        // New cipher
        .alert("New Cipher", isPresented: $showNewCipher) {
            TextField("Label", text: $newLabel)
            Button("Create") { createCipher() }
            Button("Cancel", role: .cancel) { newLabel = "" }
        } message: {
            Text("Generates a new random cipher/decipher pair and makes it active.")
        }
        // Import label
        .alert("Name This Cipher", isPresented: $showImportLabel) {
            TextField("Label", text: $importLabel)
            Button("Import") { commitImport() }
            Button("Cancel", role: .cancel) { pendingImportData = nil; importLabel = "" }
        } message: {
            Text("Give the imported decoder a label so you can find it later.")
        }
        // Rename
        .alert("Rename Cipher", isPresented: $showRename) {
            TextField("Label", text: $renameLabel)
            Button("Save") {
                if let target = renameTarget { keyManager.renameCipher(id: target.id, to: renameLabel) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        // Delete
        .alert(deleteTarget.map { "Delete “\($0.label)”?" } ?? "Delete Cipher?",
               isPresented: $showDelete) {
            Button("Export First…") {
                if let target = deleteTarget { beginExport(target) }
                deleteTarget = nil
            }
            Button("Delete", role: .destructive) {
                if let target = deleteTarget { keyManager.deleteCipher(id: target.id) }
                deleteTarget = nil
                status = .idle
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Messages encoded with this cipher can no longer be decoded once it is "
                 + "deleted. Export its decoder first if you need a record.")
        }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        HStack(spacing: 12) {
            Button { newLabel = ""; showNewCipher = true } label: {
                Label("New Cipher", systemImage: "plus.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneScribButtonStyle())

            Button { showImporter = true } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
        }
        .padding(.horizontal, RuneMetrics.pad)
        .padding(.top, RuneMetrics.pad)
    }

    // MARK: - Cipher Card

    private func cipherCard(_ cipher: NamedCipher) -> some View {
        let isActive = cipher.id == keyManager.activeCipher?.id

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cipher.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
                if isActive { badge("ACTIVE", color: .runeGold) }
                badge(cipher.origin == .imported ? "IMPORTED" : "GENERATED",
                      color: cipher.origin == .imported ? .runeBlue : .runeSilver)
            }

            HStack(spacing: 14) {
                metaLabel("ID", cipher.shortKeyId)
                metaLabel("CREATED", cipher.createdAt.formatted(.dateTime.day().month(.abbreviated).year()))
            }

            Divider().overlay(Color.runeSilver.opacity(0.15))

            HStack(spacing: 10) {
                Button { keyManager.setActive(id: cipher.id) } label: {
                    Label(isActive ? "Active" : "Use", systemImage: isActive ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(isActive ? .runeGold : .runeSilver)
                .disabled(isActive)

                Spacer()

                cardIconButton("square.and.arrow.up", help: "Export decoder") { beginExport(cipher) }
                cardIconButton("pencil", help: "Rename") {
                    renameTarget = cipher; renameLabel = cipher.label; showRename = true
                }
                cardIconButton("trash", help: "Delete", tint: .red.opacity(0.85)) {
                    deleteTarget = cipher; showDelete = true
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder((isActive ? Color.runeGold : Color.runeSilver).opacity(isActive ? 0.45 : 0.15),
                              lineWidth: 1)
        )
    }

    // MARK: - Small Components

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1)
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.4), lineWidth: 1))
    }

    private func metaLabel(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundColor(.runeSilver)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.85))
        }
    }

    private func cardIconButton(_ systemImage: String,
                                help: String,
                                tint: Color = .runeSilver,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.runeNavy.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch status {
        case .idle:
            EmptyView()
        case .success(let message):
            footer(message, systemImage: "checkmark.circle.fill", color: .green)
        case .failure(let message):
            footer(message, systemImage: "xmark.circle.fill", color: .red)
        }
    }

    private func footer(_ message: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Label(message, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(color)
            Spacer()
        }
        .padding(.horizontal, RuneMetrics.pad)
        .padding(.vertical, 12)
        .background(Color.runeParchment.opacity(0.6))
    }

    // MARK: - Operations

    private func createCipher() {
        keyManager.addCipher(label: newLabel)
        newLabel = ""
        status = keyManager.lastError.map { .failure($0) } ?? .success("Created and activated.")
    }

    private func beginExport(_ cipher: NamedCipher) {
        do {
            exportDocument = DecoderDocument(data: try keyManager.exportData(for: cipher.id))
            exportFilename = keyManager.exportFilename(for: cipher.id)
            status = .idle
            showExporter = true
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                pendingImportData = try Data(contentsOf: url)
                importLabel = url.deletingPathExtension().lastPathComponent
                showImportLabel = true
            } catch {
                status = .failure(error.localizedDescription)
            }
        case .failure(let error):
            status = .failure(error.localizedDescription)
        }
    }

    private func commitImport() {
        guard let data = pendingImportData else { return }
        defer { pendingImportData = nil; importLabel = "" }
        do {
            let cipher = try keyManager.importCipher(data: data, label: importLabel)
            status = .success("Imported “\(cipher.label)” and made it active.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }
}
