// RuneScrib/Views/CipherLibraryView.swift

import SwiftUI
import UniformTypeIdentifiers

/// The cipher library: create, import, label, select, export, and delete the
/// user's cipher/decipher pairs. The active cipher (used for both encoding and
/// decoding on the main screen) is highlighted and switchable here.
struct CipherLibraryView: View {

    @EnvironmentObject private var keyManager: KeyManager
    @EnvironmentObject private var contactManager: ContactManager
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
    @State private var renameTarget: Cipher?
    @State private var renameLabel = ""
    @State private var showRename = false

    // Delete
    @State private var deleteTarget: Cipher?
    @State private var showDelete = false

    // Share via QR
    @State private var qrCipher: Cipher?

    // In-app QR scanner (iOS) → confirm
    @State private var showScanner = false
    @State private var pendingScan: ImportCoordinator.PendingImport?

    @State private var status: Status = .idle

    // Contact linking
    @State private var pendingReassign: (cipherID: UUID, contactID: UUID?)?
    @State private var showReassignConfirm = false

    // One-time contacts import prompt (first time the library opens)
    @AppStorage("rf.contacts.importPrompted") private var contactsPrompted = false
    @State private var showContactsPrompt = false
    @State private var showContactsManager = false

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
                      contentType: .runeScribe,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url): status = .success("Saved \(url.lastPathComponent)")
            case .failure(let error): status = .failure(error.localizedDescription)
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.runeScribe],
                      allowsMultipleSelection: false) { result in
            handleImportSelection(result)
        }
        .sheet(item: $qrCipher) { cipher in
            if let url = try? keyManager.shareURL(for: cipher.id, name: cipher.label) {
                QRDisplaySheet(url: url, label: cipher.label)
            }
        }
        .sheet(isPresented: $showScanner) { scannerSheet }
        .sheet(item: $pendingScan) { pending in
            ImportConfirmView(pending: pending) { result in
                switch result {
                case .success(let cipher):
                    status = .success("Imported \u{201C}\(cipher.label)\u{201D} and made it active.")
                case .failure(let error):
                    status = .failure(error.localizedDescription)
                }
            }
            .environmentObject(keyManager)
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
        .alert(deleteTarget.map { "Delete \u{201C}\($0.label)\u{201D}?" } ?? "Delete Cipher?",
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
        // Reassign confirmation — changing an already-linked cipher to a different contact.
        .alert("Reassign Cipher?", isPresented: $showReassignConfirm) {
            Button("Reassign", role: .destructive) {
                if let pending = pendingReassign {
                    keyManager.setContact(cipherID: pending.cipherID, contactID: pending.contactID)
                }
                pendingReassign = nil
            }
            Button("Cancel", role: .cancel) { pendingReassign = nil }
        } message: {
            Text(reassignMessage())
        }
        // One-time prompt offering contacts import the first time the library opens.
        .onAppear {
            if !contactsPrompted {
                contactsPrompted = true
                showContactsPrompt = true
            }
        }
        .confirmationDialog("Organize ciphers by contact?", isPresented: $showContactsPrompt, titleVisibility: .visible) {
            Button("Import from Contacts") { showContactsManager = true }
            Button("Add Manually") { showContactsManager = true }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("Link ciphers to people to keep them organized. You can also do this anytime in Settings → Contacts.")
        }
        .sheet(isPresented: $showContactsManager) {
            ContactsView()
                .environmentObject(contactManager)
                .environmentObject(keyManager)
        }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        VStack(spacing: 12) {
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

            #if os(iOS)
            Button { showScanner = true } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            #endif
        }
        .padding(.horizontal, RuneMetrics.pad)
        .padding(.top, RuneMetrics.pad)
    }

    // MARK: - Cipher Card

    private func cipherCard(_ cipher: Cipher) -> some View {
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
                metaLabel("ID", cipher.shortPublicID)
                metaLabel("CREATED", cipher.createdAt.formatted(.dateTime.day().month(.abbreviated).year()))
            }

            contactControl(cipher)

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

                // A canonical cipher (runes within the shareable pool) can be expressed
                // as a link/QR; reuse that as the shareability check, but share the
                // self-contained `.runescribe` file (key + font), not the URL.
                if (try? keyManager.shareURL(for: cipher.id, name: cipher.label)) != nil,
                   let file = try? RuneScribeShareFile(data: keyManager.exportData(for: cipher.id),
                                                       filename: keyManager.exportFilename(for: cipher.id)) {
                    ShareLink(item: file,
                              preview: SharePreview(cipher.label)) {
                        cardIconChrome("square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("Share via Messages, Mail…")

                    cardIconButton("qrcode", help: "Show QR code") { qrCipher = cipher }
                } else {
                    // Exotic imported ciphers (runes outside the canonical pool) can't
                    // be expressed as a link/QR. Show the affordances disabled with an
                    // explanation rather than silently dropping them.
                    cardIconChrome("square.and.arrow.up", tint: .runeSilver.opacity(0.3))
                        .help("Hand-crafted ciphers can't be shared as a link or QR code.")
                    cardIconChrome("qrcode", tint: .runeSilver.opacity(0.3))
                        .help("Hand-crafted ciphers can't be shared as a link or QR code.")
                }

                cardIconButton("arrow.down.doc", help: "Export decoder file") { beginExport(cipher) }
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

    // MARK: - Contact Control

    /// The per-card control to link / change / remove the cipher's contact. Reassigning an
    /// already-linked cipher to a DIFFERENT contact asks for confirmation first; removing the
    /// link (No contact) or making a first link does not.
    private func contactControl(_ cipher: Cipher) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 12))
                .foregroundColor(.runeBlue)
            Menu {
                Button { requestSetContact(cipher, to: nil) } label: {
                    if cipher.contactID == nil { Label("No contact", systemImage: "checkmark") }
                    else { Text("No contact") }
                }
                if !contactManager.contacts.isEmpty { Divider() }
                ForEach(contactManager.contacts) { contact in
                    Button { requestSetContact(cipher, to: contact.id) } label: {
                        if contact.id == cipher.contactID { Label(contact.displayName, systemImage: "checkmark") }
                        else { Text(contact.displayName) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(contactManager.contact(id: cipher.contactID)?.displayName ?? "No contact")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(cipher.contactID == nil ? .runeSilver : .white)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.runeSilver)
                }
            }
            .menuIndicator(.hidden)
            Spacer()
        }
    }

    private func requestSetContact(_ cipher: Cipher, to contactID: UUID?) {
        if let current = cipher.contactID, contactID != nil, current != contactID {
            pendingReassign = (cipher.id, contactID)
            showReassignConfirm = true
        } else {
            keyManager.setContact(cipherID: cipher.id, contactID: contactID)
        }
    }

    private func reassignMessage() -> String {
        guard let pending = pendingReassign,
              let cipher = keyManager.ciphers.first(where: { $0.id == pending.cipherID }) else { return "" }
        let from = contactManager.contact(id: cipher.contactID)?.displayName ?? "a contact"
        let to = contactManager.contact(id: pending.contactID)?.displayName ?? "another contact"
        return "This cipher is linked to \(from). Reassign it to \(to)?"
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

    /// The square-icon chrome shared by the card's icon buttons and the ShareLink
    /// (which isn't a plain Button, so it can't use `cardIconButton`).
    private func cardIconChrome(_ systemImage: String, tint: Color = .runeSilver) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.runeNavy.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }

    private func cardIconButton(_ systemImage: String,
                                help: String,
                                tint: Color = .runeSilver,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) { cardIconChrome(systemImage, tint: tint) }
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

    private func beginExport(_ cipher: Cipher) {
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
            let cipher = try keyManager.importCipher(fileData: data, label: importLabel)
            status = .success("Imported \u{201C}\(cipher.label)\u{201D} and made it active.")
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    // MARK: - QR Scanning (iOS)

    @ViewBuilder
    private var scannerSheet: some View {
        #if os(iOS)
        QRScannerView { scanned in
            showScanner = false
            handleScanned(scanned)
        }
        #else
        EmptyView()
        #endif
    }

    /// Decodes a scanned QR string and routes it into the confirm sheet, or reports
    /// why it couldn't be read.
    private func handleScanned(_ string: String) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            status = .failure("That QR code isn't a Rune Scribe cipher.")
            return
        }
        do {
            let payload = try CipherSharePayload(url: url)
            pendingScan = ImportCoordinator.PendingImport(payload: payload,
                                                          suggestedName: payload.parsedName ?? "Imported Cipher",
                                                          fontBytes: nil)
        } catch {
            status = .failure((error as? LocalizedError)?.errorDescription
                              ?? "That QR code isn't a Rune Scribe cipher.")
        }
    }
}
