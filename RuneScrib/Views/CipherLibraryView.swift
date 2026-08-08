// RuneScrib/Views/CipherLibraryView.swift

import RuneScribeContracts
import SwiftUI
import UniformTypeIdentifiers

/// The cipher library: create, import, label, select, export, and delete the
/// user's cipher/decipher pairs. The active cipher (used for both encoding and
/// decoding on the main screen) is highlighted and switchable here.
struct CipherLibraryView: View {

    private struct CipherQRShare: Identifiable {
        let artifact: ShareArtifactDTO
        let url: URL
        let label: String

        var id: ShareArtifactID { artifact.id }
    }

    @EnvironmentObject private var keyManager: KeyManager
    @EnvironmentObject private var contactManager: ContactManager
    @Environment(\.dismiss) private var dismiss

    // Export
    @State private var showExporter = false
    @State private var exportArtifact: ShareArtifactDTO?
    @State private var exportItem: RuneScribeExportArtifact?
    @State private var exportFilename = "RuneScrib-Decoder"

    // Import
    @State private var showImporter = false

    // Create
    @State private var showNewCipher = false
    @State private var newLabel = ""

    // Rename
    @State private var renameTarget: CipherViewState?
    @State private var renameLabel = ""
    @State private var showRename = false

    // Delete
    @State private var deleteTarget: CipherViewState?
    @State private var showDelete = false

    // Share via QR
    @State private var qrShare: CipherQRShare?
    @State private var linkArtifacts: [UUID: ShareArtifactDTO] = [:]

    // In-app QR scanner (iOS) → confirm
    @State private var showScanner = false
    @State private var pendingScan: PendingImportSummary?

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
                      item: exportItem,
                      contentTypes: [.runeScribe],
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url):
                status = .success("Saved \(url.lastPathComponent)")
                finishExport(outcome: .handedOff)
            case .failure(let error):
                status = .failure(error.localizedDescription)
                finishExport(outcome: .failed)
            }
        } onCancellation: {
            finishExport(outcome: .cancelled)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.runeScribe],
                      allowsMultipleSelection: false) { result in
            handleImportSelection(result)
        }
        .sheet(item: $qrShare, onDismiss: releaseQRShare) { share in
            QRDisplaySheet(url: share.url, label: share.label)
        }
        .sheet(isPresented: $showScanner) { scannerSheet }
        .sheet(item: $pendingScan) { pending in
            ImportConfirmView(
                pending: pending,
                confirmImport: {
                    try await keyManager.confirmImport(id: pending.id, name: $0)
                },
                cancelImport: {
                    Task { await keyManager.cancelImport(id: pending.id) }
                }
            ) { result in
                switch result {
                case .success(let cipher):
                    status = .success("Imported \u{201C}\(cipher.label)\u{201D} and made it active.")
                case .failure(let error):
                    status = .failure(error.localizedDescription)
                }
            }
        }
        // New cipher
        .alert("New Cipher", isPresented: $showNewCipher) {
            TextField("Label", text: $newLabel)
            Button("Create") { createCipher() }
            Button("Cancel", role: .cancel) { newLabel = "" }
        } message: {
            Text("Generates a new random cipher/decipher pair and makes it active.")
        }
        // Rename
        .alert("Rename Cipher", isPresented: $showRename) {
            TextField("Label", text: $renameLabel)
            Button("Save") {
                if let target = renameTarget {
                    Task { try? await keyManager.renameCipher(id: target.id, to: renameLabel) }
                }
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
                if let target = deleteTarget {
                    Task { try? await keyManager.deleteCipher(id: target.id) }
                }
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
                    Task {
                        try? await keyManager.setContact(
                            cipherID: pending.cipherID,
                            contactID: pending.contactID
                        )
                    }
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
        .task(id: keyManager.ciphers.map(\.id)) {
            await prepareLinkArtifacts()
        }
        .onDisappear { releaseLinkArtifacts() }
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

    private func cipherCard(_ cipher: CipherViewState) -> some View {
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
                Button {
                    Task { try? await keyManager.setActive(id: cipher.id) }
                } label: {
                    Label(isActive ? "Active" : "Use", systemImage: isActive ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(isActive ? .runeGold : .runeSilver)
                .disabled(isActive)

                Spacer()

                // Share the offline `runescribe://import?…` deep link — the same payload
                // as the QR. Recipients tapping the link in Messages / Mail / Notes open
                // the app and land on the import sheet via LinkRouter. (A `.runescribe`
                // *file* is still available from Export; files do not single-tap-launch
                // third-party apps from Messages, so sharing a file here broke auto-import.)
                if let artifact = linkArtifacts[cipher.id],
                   case .link(let shareURL) = artifact.reference {
                    ShareLink(
                        item: shareURL,
                        subject: Text("Rune Scribe cipher: \(cipher.label)"),
                        message: Text("Tap to open in Rune Scribe and import this cipher so you can decode my messages.")
                    ) {
                        cardIconChrome("square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .help("Share via Messages, Mail…")
                    .simultaneousGesture(TapGesture().onEnded {
                        completeLinkShare(cipherID: cipher.id, artifact: artifact)
                    })

                    cardIconButton("qrcode", help: "Show QR code") {
                        linkArtifacts.removeValue(forKey: cipher.id)
                        qrShare = CipherQRShare(
                            artifact: artifact,
                            url: shareURL,
                            label: cipher.label
                        )
                    }
                } else {
                    cardIconChrome("square.and.arrow.up", tint: .runeSilver.opacity(0.3))
                        .help("Preparing the cipher link…")
                    cardIconChrome("qrcode", tint: .runeSilver.opacity(0.3))
                        .help("Preparing the cipher link…")
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
    private func contactControl(_ cipher: CipherViewState) -> some View {
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

    private func requestSetContact(_ cipher: CipherViewState, to contactID: UUID?) {
        if let current = cipher.contactID, contactID != nil, current != contactID {
            pendingReassign = (cipher.id, contactID)
            showReassignConfirm = true
        } else {
            Task {
                try? await keyManager.setContact(cipherID: cipher.id, contactID: contactID)
            }
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
        let label = newLabel
        newLabel = ""
        Task {
            do {
                _ = try await keyManager.addCipher(label: label)
                status = .success("Created and activated.")
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func beginExport(_ cipher: CipherViewState) {
        Task {
            do {
                let artifact = try await keyManager.prepareCipherShare(
                    cipherID: cipher.id,
                    displayName: cipher.label,
                    representation: .file
                )
                guard case .file(let url) = artifact.reference else {
                    await keyManager.releaseShareArtifact(id: artifact.id)
                    status = .failure("The decoder file could not be prepared.")
                    return
                }
                exportArtifact = artifact
                exportFilename = artifact.displayName
                exportItem = RuneScribeExportArtifact(
                    url: url,
                    filename: artifact.displayName
                )
                status = .idle
                showExporter = true
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }

    private func finishExport(outcome: ShareArtifactOutcomeDTO) {
        guard let artifact = exportArtifact else { return }
        exportArtifact = nil
        exportItem = nil
        Task {
            _ = try? await keyManager.completeShareArtifact(id: artifact.id, outcome: outcome)
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                do {
                    let result = try await keyManager.importFile(url, source: .fileImporter)
                    pendingScan = result.pendingImport
                    if result.pendingImport == nil, result.disposition == .duplicate {
                        status = .success("That cipher is already in your library.")
                    }
                } catch {
                    status = .failure(error.localizedDescription)
                }
            }
        case .failure(let error):
            status = .failure(error.localizedDescription)
        }
    }

    private func prepareLinkArtifacts() async {
        let liveIDs = Set(keyManager.ciphers.map(\.id))
        let stale = linkArtifacts.filter { !liveIDs.contains($0.key) }
        for artifact in stale.values {
            await keyManager.releaseShareArtifact(id: artifact.id)
        }
        linkArtifacts = linkArtifacts.filter { liveIDs.contains($0.key) }

        for cipher in keyManager.ciphers where linkArtifacts[cipher.id] == nil {
            do {
                let artifact = try await keyManager.prepareCipherShare(
                    cipherID: cipher.id,
                    displayName: cipher.label,
                    representation: .link
                )
                guard case .link = artifact.reference else {
                    await keyManager.releaseShareArtifact(id: artifact.id)
                    continue
                }
                linkArtifacts[cipher.id] = artifact
            } catch {
                // Unsupported hand-crafted ciphers retain the disabled affordance.
            }
        }
    }

    private func completeLinkShare(cipherID: UUID, artifact: ShareArtifactDTO) {
        linkArtifacts.removeValue(forKey: cipherID)
        Task {
            _ = try? await keyManager.completeShareArtifact(id: artifact.id, outcome: .handedOff)
            await prepareLinkArtifacts()
        }
    }

    private func releaseQRShare() {
        guard let share = qrShare else { return }
        qrShare = nil
        Task {
            await keyManager.releaseShareArtifact(id: share.artifact.id)
            await prepareLinkArtifacts()
        }
    }

    private func releaseLinkArtifacts() {
        let artifacts = Array(linkArtifacts.values)
        linkArtifacts.removeAll()
        Task {
            for artifact in artifacts {
                await keyManager.releaseShareArtifact(id: artifact.id)
            }
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
        guard LinkRouter.isCipherImportURL(url) else {
            status = .failure("That QR code isn't a Rune Scribe cipher.")
            return
        }
        Task {
            do {
                let result = try await keyManager.importURL(url, source: .qrScanner)
                pendingScan = result.pendingImport
            } catch {
                status = .failure(error.localizedDescription)
            }
        }
    }
}
