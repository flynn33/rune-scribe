// RuneScrib/Views/CipherLibraryView.swift

import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

/// The cipher library: create, import, label, select, export, and delete the
/// user's cipher/decipher pairs. The active cipher (used for both encoding and
/// decoding on the main screen) is highlighted and switchable here.
struct CipherLibraryView: View {

    private struct CipherQRShare: Identifiable {
        let artifact: ShareArtifactDTO
        let transfer: OpaqueShareTransfer
        let label: String

        var id: ShareArtifactID { artifact.id }
    }

    private struct CipherLinkShare {
        let artifact: ShareArtifactDTO
        let transfer: OpaqueShareTransfer
    }

    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss

    // Export
    @State private var showExporter = false
    @State private var exportArtifact: ShareArtifactDTO?
    @State private var exportTransfer: OpaqueShareTransfer?
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
    @State private var linkArtifacts: [UUID: CipherLinkShare] = [:]

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
                    ForEach(session.ciphers) { cipher in
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
        .runtimeShareArtifactExporter(
            isPresented: $showExporter,
            transfer: exportTransfer,
            defaultFilename: exportFilename
        ) { completion in
            if case .success(let evidence) = completion,
               evidence.report.result == .completionUnavailable {
                status = .success("Saved \(exportFilename).\(RuneScribeWireFormat.fileExtension)")
            }
            finishExport(completion)
        }
        .runtimeInboundFileImporter(
            isPresented: $showImporter,
            session: session.inboundFileImportSession
        ) { result in
            handleImportCompletion(result)
        }
        .sheet(item: $qrShare) { share in
            QRDisplaySheet(
                transfer: share.transfer,
                label: share.label
            ) { completion in
                finishQRShare(share, completion: completion)
            }
        }
        .sheet(isPresented: $showScanner) { scannerSheet }
        .sheet(item: $pendingScan) { pending in
            ImportConfirmView(
                pending: pending,
                confirmImport: {
                    try await session.confirmImport(id: pending.id, name: $0)
                },
                cancelImport: {
                    Task { await session.cancelImport(id: pending.id) }
                }
            ) { result in
                switch result {
                case .success(let cipher):
                    status = .success("Imported \u{201C}\(cipher.label)\u{201D} and made it active.")
                case .failure(let error):
                    presentFailure(error)
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
                guard let target = renameTarget else { return }
                let label = renameLabel
                renameTarget = nil
                Task {
                    do {
                        _ = try await session.renameCipher(id: target.id, to: label)
                        status = .success("Renamed cipher.")
                    } catch {
                        presentFailure(error)
                    }
                }
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
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task {
                    do {
                        try await session.deleteCipher(id: target.id)
                        status = .success("Deleted cipher.")
                    } catch {
                        presentFailure(error)
                    }
                }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Messages encoded with this cipher can no longer be decoded once it is "
                 + "deleted. Export its decoder first if you need a record.")
        }
        // Reassign confirmation — changing an already-linked cipher to a different contact.
        .alert("Reassign Cipher?", isPresented: $showReassignConfirm) {
            Button("Reassign", role: .destructive) {
                guard let pending = pendingReassign else { return }
                pendingReassign = nil
                Task {
                    do {
                        try await session.setContact(
                            cipherID: pending.cipherID,
                            contactID: pending.contactID
                        )
                        status = .success("Reassigned cipher.")
                    } catch {
                        presentFailure(error)
                    }
                }
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
        }
        .task(id: session.ciphers.map(\.id)) {
            await prepareLinkArtifacts()
        }
        .onDisappear { releaseLinkArtifacts() }
    }

    // MARK: - Actions Bar

    private var actionsBar: some View {
        VStack(spacing: 12) {
            creationActions

            #if os(iOS)
            Button { showScanner = true } label: {
                Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            #endif
        }
        .padding(.horizontal, RuneMetrics.pad)
        .padding(.top, RuneMetrics.pad)
    }

    private var creationActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                newCipherButton(resistsCompression: true)
                importCipherButton(resistsCompression: true)
            }

            VStack(spacing: 8) {
                newCipherButton(resistsCompression: false)
                importCipherButton(resistsCompression: false)
            }
        }
    }

    private func newCipherButton(resistsCompression: Bool) -> some View {
        Button {
            newLabel = ""
            showNewCipher = true
        } label: {
            Label("New Cipher", systemImage: "plus.circle.fill")
                .lineLimit(1)
                .fixedSize(horizontal: resistsCompression, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneScribButtonStyle())
    }

    private func importCipherButton(resistsCompression: Bool) -> some View {
        Button {
            showImporter = true
        } label: {
            Label("Import…", systemImage: "square.and.arrow.down")
                .lineLimit(1)
                .fixedSize(horizontal: resistsCompression, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
    }

    // MARK: - Cipher Card

    private func cipherCard(_ cipher: CipherViewState) -> some View {
        let isActive = cipher.id == session.activeCipher?.id

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

            cipherCardActions(cipher, isActive: isActive)
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
                .accessibilityHidden(true)
            Menu {
                Button { requestSetContact(cipher, to: nil) } label: {
                    if cipher.contactID == nil { Label("No contact", systemImage: "checkmark") }
                    else { Text("No contact") }
                }
                if !session.contacts.isEmpty { Divider() }
                ForEach(session.contacts) { contact in
                    Button { requestSetContact(cipher, to: contact.id) } label: {
                        if contact.id == cipher.contactID { Label(contact.displayName, systemImage: "checkmark") }
                        else { Text(contact.displayName) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(session.contact(id: cipher.contactID)?.displayName ?? "No contact")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(cipher.contactID == nil ? .runeSilver : .white)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(.runeSilver)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuIndicator(.hidden)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityLabel(
                "Contact for \(cipher.label): \(session.contact(id: cipher.contactID)?.displayName ?? "No contact")"
            )
            Spacer()
        }
    }

    private func requestSetContact(_ cipher: CipherViewState, to contactID: UUID?) {
        if let current = cipher.contactID, contactID != nil, current != contactID {
            pendingReassign = (cipher.id, contactID)
            showReassignConfirm = true
        } else {
            setContact(cipherID: cipher.id, contactID: contactID)
        }
    }

    private func reassignMessage() -> String {
        guard let pending = pendingReassign,
              let cipher = session.ciphers.first(where: { $0.id == pending.cipherID }) else { return "" }
        let from = session.contact(id: cipher.contactID)?.displayName ?? "a contact"
        let to = session.contact(id: pending.contactID)?.displayName ?? "another contact"
        return "This cipher is linked to \(from). Reassign it to \(to)?"
    }

    // MARK: - Cipher Card Actions

    private func cipherCardActions(_ cipher: CipherViewState, isActive: Bool) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cipherActivationButton(cipher, isActive: isActive)
                Spacer(minLength: 0)
                cipherUtilityActions(cipher, spacing: 10)
            }

            VStack(alignment: .leading, spacing: 4) {
                cipherActivationButton(cipher, isActive: isActive)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    cipherUtilityActions(cipher, spacing: 4)
                }
            }
        }
    }

    private func cipherActivationButton(
        _ cipher: CipherViewState,
        isActive: Bool
    ) -> some View {
        Button {
            setActiveCipher(cipher.id)
        } label: {
            Label(
                isActive ? "Active" : "Use",
                systemImage: isActive ? "checkmark.circle.fill" : "circle"
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel("\(isActive ? "Active" : "Use") \(cipher.label)")
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundColor(isActive ? .runeGold : .runeSilver)
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .disabled(isActive)
    }

    private func cipherUtilityActions(
        _ cipher: CipherViewState,
        spacing: CGFloat
    ) -> some View {
        HStack(spacing: spacing) {
            // Share the offline `runescribe://import?…` deep link — the same payload
            // as the QR. Recipients tapping the link in Messages / Mail / Notes open
            // the app and land on the import sheet through the Core input service. (A `.runescribe`
            // *file* is still available from Export; files do not single-tap-launch
            // third-party apps from Messages, so sharing a file here broke auto-import.)
            if let share = linkArtifacts[cipher.id],
               case .opaque = share.artifact.reference {
                RuneScribeCipherLinkShareLink(
                    transfer: share.transfer,
                    cipherLabel: cipher.label,
                    onFinish: { completion in
                        completeLinkShare(
                            cipherID: cipher.id,
                            artifact: share.artifact,
                            completion: completion
                        )
                    }
                ) {
                    cardIconChrome("square.and.arrow.up")
                }

                cardIconButton("qrcode", help: "Show QR code for \(cipher.label)") {
                    linkArtifacts.removeValue(forKey: cipher.id)
                    qrShare = CipherQRShare(
                        artifact: share.artifact,
                        transfer: share.transfer,
                        label: cipher.label
                    )
                }
            } else {
                cardIconChrome("square.and.arrow.up", tint: .runeSilver.opacity(0.3))
                    .help("Preparing the cipher link…")
                cardIconChrome("qrcode", tint: .runeSilver.opacity(0.3))
                    .help("Preparing the cipher link…")
            }

            cardIconButton("arrow.down.doc", help: "Export \(cipher.label)") { beginExport(cipher) }
            cardIconButton("pencil", help: "Rename \(cipher.label)") {
                renameTarget = cipher; renameLabel = cipher.label; showRename = true
            }
            cardIconButton("trash", help: "Delete \(cipher.label)", tint: .red.opacity(0.85)) {
                deleteTarget = cipher; showDelete = true
            }
        }
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
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func cardIconButton(_ systemImage: String,
                                help: String,
                                tint: Color = .runeSilver,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) { cardIconChrome(systemImage, tint: tint) }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(help)
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
                _ = try await session.addCipher(label: label)
                status = .success("Created and activated.")
            } catch {
                presentFailure(error)
            }
        }
    }

    private func beginExport(_ cipher: CipherViewState) {
        Task {
            do {
                let artifact = try await session.prepareCipherShare(
                    cipherID: cipher.id,
                    displayName: cipher.label,
                    representation: .file
                )
                guard case .file = artifact.reference else {
                    await session.releaseShareArtifact(id: artifact.id)
                    status = .failure("The decoder file could not be prepared.")
                    return
                }
                let transfer = try await session.shareTransfer(for: artifact.id)
                exportArtifact = artifact
                exportFilename = artifact.displayName
                exportTransfer = transfer
                status = .idle
                showExporter = true
            } catch {
                presentFailure(error)
            }
        }
    }

    private func finishExport(_ completion: SharePresentationCompletion) {
        guard let artifact = exportArtifact else { return }
        exportArtifact = nil
        let transfer = exportTransfer
        exportTransfer = nil
        Task {
            await transfer?.close()
            switch completion {
            case .success(let evidence) where evidence.artifactID == artifact.id:
                do {
                    _ = try await session.completeShareArtifact(evidence: evidence)
                } catch {
                    presentFailure(error)
                }
            case .success:
                await session.releaseShareArtifact(id: artifact.id)
                status = .failure("The decoder export could not be finalized.")
            case .failure(let error):
                await session.releaseShareArtifact(id: artifact.id)
                presentFailure(error)
            }
        }
    }

    private func handleImportCompletion(
        _ result: Result<ImportResultDTO, Error>
    ) {
        switch result {
        case .success(let importResult):
            pendingScan = importResult.pendingImport
            if importResult.pendingImport == nil,
               importResult.disposition == .duplicate {
                status = .success("That cipher is already in your library.")
            }
        case .failure(let error):
            presentFailure(error)
        }
    }

    private func prepareLinkArtifacts() async {
        let liveIDs = Set(session.ciphers.map(\.id))
        let stale = linkArtifacts.filter { !liveIDs.contains($0.key) }
        for share in stale.values {
            await share.transfer.close()
            await session.releaseShareArtifact(id: share.artifact.id)
        }
        linkArtifacts = linkArtifacts.filter { liveIDs.contains($0.key) }

        for cipher in session.ciphers where linkArtifacts[cipher.id] == nil {
            do {
                let artifact = try await session.prepareCipherShare(
                    cipherID: cipher.id,
                    displayName: cipher.label,
                    representation: .link
                )
                guard case .opaque = artifact.reference else {
                    await session.releaseShareArtifact(id: artifact.id)
                    continue
                }
                let transfer = try await session.shareTransfer(for: artifact.id)
                linkArtifacts[cipher.id] = CipherLinkShare(
                    artifact: artifact,
                    transfer: transfer
                )
            } catch {
                // Unsupported hand-crafted ciphers retain the disabled affordance.
            }
        }
    }

    private func completeLinkShare(
        cipherID: UUID,
        artifact: ShareArtifactDTO,
        completion: SharePresentationCompletion
    ) {
        let transfer = linkArtifacts.removeValue(forKey: cipherID)?.transfer
        Task {
            await transfer?.close()
            switch completion {
            case .success(let evidence) where evidence.artifactID == artifact.id:
                do {
                    _ = try await session.completeShareArtifact(evidence: evidence)
                } catch {
                    presentFailure(error)
                }
            case .success:
                await session.releaseShareArtifact(id: artifact.id)
                status = .failure("The cipher share could not be finalized.")
            case .failure(let error):
                await session.releaseShareArtifact(id: artifact.id)
                presentFailure(error)
            }
            await prepareLinkArtifacts()
        }
    }

    private func finishQRShare(
        _ share: CipherQRShare,
        completion: SharePresentationCompletion
    ) {
        if qrShare?.id == share.id {
            qrShare = nil
        }
        Task {
            await share.transfer.close()
            switch completion {
            case .success(let evidence) where evidence.artifactID == share.artifact.id:
                do {
                    _ = try await session.completeShareArtifact(evidence: evidence)
                } catch {
                    presentFailure(error)
                }
            case .success:
                await session.releaseShareArtifact(id: share.artifact.id)
                status = .failure("The QR share could not be finalized.")
            case .failure(let error):
                await session.releaseShareArtifact(id: share.artifact.id)
                presentFailure(error)
            }
            await prepareLinkArtifacts()
        }
    }

    private func releaseLinkArtifacts() {
        let shares = Array(linkArtifacts.values)
        linkArtifacts.removeAll()
        Task {
            for share in shares {
                await share.transfer.close()
                await session.releaseShareArtifact(id: share.artifact.id)
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
        Task {
            do {
                let result = try await session.importURL(url, source: .qrScanner)
                pendingScan = result.pendingImport
            } catch {
                presentFailure(error)
            }
        }
    }

    private func setActiveCipher(_ id: UUID) {
        Task {
            do {
                try await session.setActive(id: id)
                status = .success("Selected cipher.")
            } catch {
                presentFailure(error)
            }
        }
    }

    private func setContact(cipherID: UUID, contactID: UUID?) {
        Task {
            do {
                try await session.setContact(cipherID: cipherID, contactID: contactID)
                status = .success("Updated cipher contact.")
            } catch {
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        status = .failure(RuneScribeUISession.message(for: error))
    }
}
