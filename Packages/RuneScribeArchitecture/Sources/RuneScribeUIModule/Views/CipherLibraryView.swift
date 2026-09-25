// RuneScrib/Views/CipherLibraryView.swift

import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

struct CipherLibraryShareOperationGate: Equatable, Sendable {
    struct Lease: Equatable, Sendable {
        let cipherID: UUID
        let operationID: UUID
    }

    struct Cancellation: Equatable, Sendable {
        let export: Lease?
        let preparation: Lease?
    }

    private(set) var export: Lease?
    private(set) var preparation: Lease?

    var exportCipherID: UUID? { export?.cipherID }
    var preparingCipherID: UUID? { preparation?.cipherID }

    mutating func beginExport(cipherID: UUID, operationID: UUID) -> Bool {
        guard export == nil else { return false }
        export = Lease(cipherID: cipherID, operationID: operationID)
        return true
    }

    mutating func beginPreparation(cipherID: UUID, operationID: UUID) -> Bool {
        guard preparation == nil else { return false }
        preparation = Lease(cipherID: cipherID, operationID: operationID)
        return true
    }

    func ownsExport(operationID: UUID) -> Bool {
        export?.operationID == operationID
    }

    func ownsPreparation(operationID: UUID) -> Bool {
        preparation?.operationID == operationID
    }

    @discardableResult
    mutating func finishExport(operationID: UUID) -> Bool {
        guard export?.operationID == operationID else { return false }
        export = nil
        return true
    }

    @discardableResult
    mutating func finishPreparation(operationID: UUID) -> Bool {
        guard preparation?.operationID == operationID else { return false }
        preparation = nil
        return true
    }

    mutating func cancelOperations(for cipherID: UUID? = nil) -> Cancellation {
        let cancelledExport = export.flatMap { lease in
            cipherID == nil || lease.cipherID == cipherID ? lease : nil
        }
        let cancelledPreparation = preparation.flatMap { lease in
            cipherID == nil || lease.cipherID == cipherID ? lease : nil
        }
        if cancelledExport != nil { export = nil }
        if cancelledPreparation != nil { preparation = nil }
        return Cancellation(
            export: cancelledExport,
            preparation: cancelledPreparation
        )
    }
}

/// The cipher library: create, import, label, select, export, and delete the
/// user's cipher/decipher pairs. The active cipher (used for both encoding and
/// decoding on the main screen) is highlighted and switchable here.
struct CipherLibraryView: View {

    private struct CipherQRShare: Identifiable {
        let cipherID: UUID
        let artifact: ShareArtifactDTO
        let transfer: OpaqueShareTransfer
        let label: String

        var id: ShareArtifactID { artifact.id }
    }

    private struct CipherLinkShare {
        let cipherID: UUID
        let artifact: ShareArtifactDTO
        let transfer: OpaqueShareTransfer
        let label: String
        let previewImageData: Data
    }

    @EnvironmentObject private var session: RuneScribeUISession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    // Export
    @State private var showExporter = false
    @State private var exportArtifact: ShareArtifactDTO?
    @State private var exportTransfer: OpaqueShareTransfer?
    @State private var exportFilename = "RuneScrib-Decoder"
    @State private var exportPreparationTask: Task<Void, Never>?

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
    @State private var fallbackLinkShare: CipherLinkShare?
    @State private var fallbackLinkLaunchID: UUID?
    @State private var primaryShare: PreparedShareBuilderArtifact?
    @State private var primaryShareLaunchID: UUID?
    @State private var primaryShareCipherID: UUID?
    @State private var shareBuilderSource: ShareBuilderSource?
    @State private var sharePreparationTask: Task<Void, Never>?
    @State private var shareOperations = CipherLibraryShareOperationGate()
    @State private var isViewActive = false

    // In-app QR scanner (iOS) → confirm
    @State private var showScanner = false
    @State private var pendingScan: PendingImportSummary?

    @State private var status: Status = .idle

    // Contact linking
    @State private var pendingReassign: (cipherID: UUID, contactID: UUID?)?
    @State private var showReassignConfirm = false

    // One-time contacts import prompt (first time the library opens)
    @State private var didEvaluateContactsPrompt = false
    @State private var showContactsPrompt = false
    @State private var showContactsManager = false

    enum Status: Equatable {
        case idle
        case success(String)
        case failure(String)
    }

    private enum FallbackSharePurpose {
        case link
        case qr
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .cipherLibrary,
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
        .runeSemanticPresentationSurface()
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
        .sheet(item: $shareBuilderSource) { source in
            ShareBuilderView(source: source)
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
                        await releasePreparedShares(for: target.id)
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
            isViewActive = true
            evaluateContactsPromptIfReady()
        }
        .onChange(of: session.runtimePresentationSettingsReady) { _, _ in
            evaluateContactsPromptIfReady()
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
        .background { automaticShareLaunchers }
        .onDisappear {
            isViewActive = false
            releasePreparedShares()
        }
    }

    private func evaluateContactsPromptIfReady() {
        guard session.runtimePresentationSettingsReady,
              !didEvaluateContactsPrompt
        else { return }
        didEvaluateContactsPrompt = true
        guard !session.contactsImportPrompted else { return }
        showContactsPrompt = true
        Task { await session.markContactsImportPrompted() }
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
        let shareFallbackNotice = OutboundShareFontPolicy.projection(
            for: cipher.id,
            in: session.ciphers
        ).shareFallbackNotice

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(cipher.label)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.runeTextPrimary)
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

            if let shareFallbackNotice {
                Label(shareFallbackNotice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.runeGold)
                    .accessibilityIdentifier("cipher.share-fallback")
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
                        .foregroundColor(cipher.contactID == nil ? .runeSilver : .runeTextPrimary)
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
            Button {
                beginPrimaryShare(cipher)
            } label: {
                Label(
                    shareOperations.preparingCipherID == cipher.id ? "Preparing…" : "Share",
                    systemImage: shareOperations.preparingCipherID == cipher.id
                        ? "clock"
                        : "square.and.arrow.up"
                )
                .lineLimit(1)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.runeBlue)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Share \(cipher.label)")
            .disabled(shareOperations.preparingCipherID != nil || primaryShare != nil)
            .accessibilityIdentifier("cipher.primary-share")

            Button {
                shareBuilderSource = .cipherInvitation(
                    cipherID: cipher.id,
                    displayName: cipher.label
                )
            } label: {
                Label("Customize", systemImage: "slider.horizontal.3")
                    .lineLimit(1)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundColor(.runeSilver)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .disabled(shareOperations.preparingCipherID != nil)
            .accessibilityLabel("Customize Share for \(cipher.label)")
            .accessibilityIdentifier("cipher.customize-share")

            Menu {
                Button("Export File") { beginExport(cipher) }
                    .disabled(shareOperations.exportCipherID != nil)
                Button("Show QR") { beginFallbackShare(cipher, purpose: .qr) }
                Button("Share Link") { beginFallbackShare(cipher, purpose: .link) }
                Divider()
                Button("Rename") {
                    renameTarget = cipher
                    renameLabel = cipher.label
                    showRename = true
                }
                Button("Delete", role: .destructive) {
                    deleteTarget = cipher
                    showDelete = true
                }
            } label: {
                cardIconChrome("ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More actions for \(cipher.label)")
            .accessibilityLabel("More actions for \(cipher.label)")
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
                .foregroundColor(.runeTextPrimary.opacity(0.85))
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
            footer(message, systemImage: "checkmark.circle.fill", color: .runeSuccess)
        case .failure(let message):
            footer(message, systemImage: "xmark.circle.fill", color: .runeDanger)
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
        let operationID = UUID()
        guard shareOperations.beginExport(
            cipherID: cipher.id,
            operationID: operationID
        ) else { return }
        exportPreparationTask = Task { @MainActor in
            var artifact: ShareArtifactDTO?
            var transfer: OpaqueShareTransfer?
            do {
                let preparedArtifact = try await session.prepareCipherShare(
                    cipherID: cipher.id,
                    displayName: cipher.label,
                    representation: .file,
                    colorMode: shareColorMode,
                    systemReduceMotion: effectiveReduceMotion
                )
                artifact = preparedArtifact
                try Task.checkCancellation()
                guard case .file = preparedArtifact.reference else {
                    throw OpaqueSharePresentationError.unavailable
                }
                guard isViewActive,
                      shareOperations.ownsExport(operationID: operationID),
                      session.ciphers.contains(where: { $0.id == cipher.id })
                else {
                    throw CancellationError()
                }
                let preparedTransfer = try await session.shareTransfer(
                    for: preparedArtifact.id
                )
                transfer = preparedTransfer
                try Task.checkCancellation()
                guard isViewActive,
                      shareOperations.ownsExport(operationID: operationID),
                      session.ciphers.contains(where: { $0.id == cipher.id })
                else {
                    throw CancellationError()
                }
                exportArtifact = preparedArtifact
                exportFilename = preparedArtifact.displayName
                exportTransfer = preparedTransfer
                status = .idle
                showExporter = true
                exportPreparationTask = nil
            } catch {
                await transfer?.close()
                if let artifact {
                    await session.releaseShareArtifact(id: artifact.id)
                }
                let wasCurrent = shareOperations.finishExport(
                    operationID: operationID
                )
                if wasCurrent {
                    exportPreparationTask = nil
                }
                if wasCurrent, !Task.isCancelled {
                    presentFailure(error)
                }
            }
        }
    }

    private func finishExport(_ completion: SharePresentationCompletion) {
        guard let artifact = exportArtifact,
              let exportLease = shareOperations.export
        else { return }
        guard shareOperations.finishExport(
            operationID: exportLease.operationID
        ) else { return }
        showExporter = false
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
                    await session.releaseShareArtifact(id: artifact.id)
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

    private func beginPrimaryShare(_ cipher: CipherViewState) {
        let operationID = UUID()
        guard primaryShare == nil,
              shareOperations.beginPreparation(
                  cipherID: cipher.id,
                  operationID: operationID
              )
        else { return }
        sharePreparationTask = Task { @MainActor in
            do {
                let catalog = try session.makeShareBuilderCatalog()
                let source = ShareBuilderSource.cipherInvitation(
                    cipherID: cipher.id,
                    displayName: cipher.label
                )
                let renderedPreview = try await session.renderShareBuilderPreview(
                    source: source,
                    catalog: catalog,
                    colorMode: shareColorMode,
                    systemReduceMotion: effectiveReduceMotion
                )
                let prepared = try await session.prepareShareBuilderArtifact(
                    source: source,
                    catalog: catalog,
                    renderedPreview: renderedPreview,
                    colorMode: shareColorMode,
                    systemReduceMotion: effectiveReduceMotion
                )
                try Task.checkCancellation()
                guard isViewActive,
                      shareOperations.ownsPreparation(operationID: operationID),
                      session.ciphers.contains(where: { $0.id == cipher.id })
                else {
                    await prepared.transfer.close()
                    await session.releaseShareArtifact(id: prepared.artifact.id)
                    throw CancellationError()
                }
                guard shareOperations.finishPreparation(
                    operationID: operationID
                ) else {
                    await prepared.transfer.close()
                    await session.releaseShareArtifact(id: prepared.artifact.id)
                    return
                }
                sharePreparationTask = nil
                primaryShare = prepared
                primaryShareCipherID = cipher.id
                primaryShareLaunchID = UUID()
                status = .idle
            } catch {
                let wasCurrent = shareOperations.finishPreparation(
                    operationID: operationID
                )
                if wasCurrent {
                    sharePreparationTask = nil
                }
                if wasCurrent, !Task.isCancelled {
                    presentFailure(error)
                }
            }
        }
    }

    private func beginFallbackShare(
        _ cipher: CipherViewState,
        purpose: FallbackSharePurpose
    ) {
        let operationID = UUID()
        guard fallbackLinkShare == nil,
              qrShare == nil,
              shareOperations.beginPreparation(
                  cipherID: cipher.id,
                  operationID: operationID
              )
        else { return }
        sharePreparationTask = Task { @MainActor in
            var artifact: ShareArtifactDTO?
            var transfer: OpaqueShareTransfer?
            do {
                let preparedArtifact: ShareArtifactDTO
                let preparedTransfer: OpaqueShareTransfer
                let previewImageData: Data?
                switch purpose {
                case .link:
                    let catalog = try session.makeShareBuilderCatalog()
                    let source = ShareBuilderSource.cipherInvitation(
                        cipherID: cipher.id,
                        displayName: cipher.label
                    )
                    let renderedPreview = try await session.renderShareBuilderPreview(
                        source: source,
                        catalog: catalog,
                        colorMode: shareColorMode,
                        systemReduceMotion: effectiveReduceMotion
                    )
                    let prepared = try await session.prepareShareBuilderArtifact(
                        source: source,
                        catalog: catalog,
                        renderedPreview: renderedPreview,
                        colorMode: shareColorMode,
                        systemReduceMotion: effectiveReduceMotion
                    )
                    preparedArtifact = prepared.artifact
                    preparedTransfer = prepared.transfer
                    previewImageData = prepared.previewImageData
                case .qr:
                    preparedArtifact = try await session.prepareCipherShare(
                        cipherID: cipher.id,
                        displayName: cipher.label,
                        representation: .link,
                        colorMode: shareColorMode,
                        systemReduceMotion: effectiveReduceMotion
                    )
                    preparedTransfer = try await session.shareTransfer(
                        for: preparedArtifact.id
                    )
                    previewImageData = nil
                }
                artifact = preparedArtifact
                transfer = preparedTransfer
                if case .link = purpose, previewImageData == nil {
                    throw OpaqueSharePresentationError.unavailable
                }
                try Task.checkCancellation()
                guard case .opaque = preparedArtifact.reference else {
                    throw OpaqueSharePresentationError.unavailable
                }
                guard isViewActive,
                      shareOperations.ownsPreparation(operationID: operationID),
                      session.ciphers.contains(where: { $0.id == cipher.id })
                else {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                guard isViewActive,
                      shareOperations.ownsPreparation(operationID: operationID),
                      session.ciphers.contains(where: { $0.id == cipher.id })
                else {
                    throw CancellationError()
                }
                guard shareOperations.finishPreparation(
                    operationID: operationID
                ) else {
                    await preparedTransfer.close()
                    await session.releaseShareArtifact(id: preparedArtifact.id)
                    return
                }
                sharePreparationTask = nil
                switch purpose {
                case .link:
                    fallbackLinkShare = CipherLinkShare(
                        cipherID: cipher.id,
                        artifact: preparedArtifact,
                        transfer: preparedTransfer,
                        label: cipher.label,
                        previewImageData: previewImageData!
                    )
                    fallbackLinkLaunchID = UUID()
                case .qr:
                    qrShare = CipherQRShare(
                        cipherID: cipher.id,
                        artifact: preparedArtifact,
                        transfer: preparedTransfer,
                        label: cipher.label
                    )
                }
                status = .idle
            } catch {
                await transfer?.close()
                if let artifact {
                    await session.releaseShareArtifact(id: artifact.id)
                }
                let wasCurrent = shareOperations.finishPreparation(
                    operationID: operationID
                )
                if wasCurrent {
                    sharePreparationTask = nil
                }
                if wasCurrent, !Task.isCancelled {
                    presentFailure(error)
                }
            }
        }
    }

    private func finishQRShare(
        _ share: CipherQRShare,
        completion: SharePresentationCompletion
    ) {
        guard qrShare?.id == share.id else { return }
        qrShare = nil
        Task {
            await share.transfer.close()
            switch completion {
            case .success(let evidence) where evidence.artifactID == share.artifact.id:
                do {
                    _ = try await session.completeShareArtifact(evidence: evidence)
                } catch {
                    await session.releaseShareArtifact(id: share.artifact.id)
                    presentFailure(error)
                }
            case .success:
                await session.releaseShareArtifact(id: share.artifact.id)
                status = .failure("The QR share could not be finalized.")
            case .failure(let error):
                await session.releaseShareArtifact(id: share.artifact.id)
                presentFailure(error)
            }
        }
    }

    private func releasePreparedShares() {
        session.setRevealBlocker(.systemShare, active: false)
        _ = shareOperations.cancelOperations()
        let exportTask = exportPreparationTask
        exportPreparationTask = nil
        exportTask?.cancel()
        let preparationTask = sharePreparationTask
        sharePreparationTask = nil
        preparationTask?.cancel()

        showExporter = false
        let exportArtifact = exportArtifact
        self.exportArtifact = nil
        let exportTransfer = exportTransfer
        self.exportTransfer = nil

        let primary = primaryShare
        primaryShare = nil
        primaryShareLaunchID = nil
        primaryShareCipherID = nil
        let fallback = fallbackLinkShare
        fallbackLinkShare = nil
        fallbackLinkLaunchID = nil
        let qr = qrShare
        qrShare = nil
        Task {
            await exportTask?.value
            await preparationTask?.value
            await exportTransfer?.close()
            if let exportArtifact {
                await session.releaseShareArtifact(id: exportArtifact.id)
            }
            if let primary {
                await primary.transfer.close()
                await session.releaseShareArtifact(id: primary.artifact.id)
            }
            if let fallback {
                await fallback.transfer.close()
                await session.releaseShareArtifact(id: fallback.artifact.id)
            }
            if let qr {
                await qr.transfer.close()
                await session.releaseShareArtifact(id: qr.artifact.id)
            }
        }
    }

    private func releasePreparedShares(for cipherID: UUID) async {
        session.setRevealBlocker(.systemShare, active: false)
        let cancellation = shareOperations.cancelOperations(for: cipherID)
        let exportTask = cancellation.export == nil ? nil : exportPreparationTask
        if cancellation.export != nil {
            exportPreparationTask = nil
            exportTask?.cancel()
        }
        let preparationTask = cancellation.preparation == nil
            ? nil
            : sharePreparationTask
        if cancellation.preparation != nil {
            sharePreparationTask = nil
            preparationTask?.cancel()
        }

        let cancelledExportArtifact = cancellation.export == nil ? nil : exportArtifact
        let cancelledExportTransfer = cancellation.export == nil ? nil : exportTransfer
        if cancellation.export != nil {
            showExporter = false
            exportArtifact = nil
            exportTransfer = nil
        }

        await exportTask?.value
        await preparationTask?.value
        await cancelledExportTransfer?.close()
        if let cancelledExportArtifact {
            await session.releaseShareArtifact(id: cancelledExportArtifact.id)
        }
        if primaryShareCipherID == cipherID, let primaryShare {
            self.primaryShare = nil
            primaryShareLaunchID = nil
            primaryShareCipherID = nil
            await primaryShare.transfer.close()
            await session.releaseShareArtifact(id: primaryShare.artifact.id)
        }
        if fallbackLinkShare?.cipherID == cipherID, let fallbackLinkShare {
            self.fallbackLinkShare = nil
            fallbackLinkLaunchID = nil
            await fallbackLinkShare.transfer.close()
            await session.releaseShareArtifact(id: fallbackLinkShare.artifact.id)
        }
        if qrShare?.cipherID == cipherID, let qrShare {
            self.qrShare = nil
            await qrShare.transfer.close()
            await session.releaseShareArtifact(id: qrShare.artifact.id)
        }
    }

    @ViewBuilder
    private var automaticShareLaunchers: some View {
        if let primaryShare, let primaryShareLaunchID {
            RuneScribePreparedCipherLinkLauncher(
                transfer: primaryShare.transfer,
                cipherLabel: primaryShare.artifact.displayName,
                previewImageData: primaryShare.previewImageData,
                launchID: primaryShareLaunchID,
                onPresented: {
                    session.setRevealBlocker(.systemShare, active: true)
                },
                onFinish: { completion in
                    finishPrimaryShare(primaryShare, completion: completion)
                }
            )
        }
        if let fallbackLinkShare, let fallbackLinkLaunchID {
            RuneScribePreparedCipherLinkLauncher(
                transfer: fallbackLinkShare.transfer,
                cipherLabel: fallbackLinkShare.label,
                previewImageData: fallbackLinkShare.previewImageData,
                launchID: fallbackLinkLaunchID,
                onPresented: {
                    session.setRevealBlocker(.systemShare, active: true)
                },
                onFinish: { completion in
                    finishFallbackLinkShare(
                        fallbackLinkShare,
                        completion: completion
                    )
                }
            )
        }
    }

    private func finishPrimaryShare(
        _ prepared: PreparedShareBuilderArtifact,
        completion: SharePresentationCompletion
    ) {
        guard primaryShare?.artifact.id == prepared.artifact.id else { return }
        primaryShare = nil
        primaryShareLaunchID = nil
        primaryShareCipherID = nil
        session.setRevealBlocker(.systemShare, active: false)
        Task {
            do {
                let routeResult = try await session.finishShareBuilderArtifact(
                    prepared,
                    completion: completion
                )
                switch ShareBuilderTerminalDisposition(routeResult: routeResult) {
                case .completed:
                    status = .success("Shared the themed cipher invitation.")
                case .cancelled:
                    status = .idle
                case .failed:
                    status = .failure("The cipher invitation was not shared.")
                }
            } catch {
                status = .failure("The cipher invitation was not shared.")
            }
        }
    }

    private func finishFallbackLinkShare(
        _ share: CipherLinkShare,
        completion: SharePresentationCompletion
    ) {
        guard fallbackLinkShare?.artifact.id == share.artifact.id else { return }
        fallbackLinkShare = nil
        fallbackLinkLaunchID = nil
        session.setRevealBlocker(.systemShare, active: false)
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
                status = .failure("The fallback link could not be finalized.")
            case .failure(let error):
                presentFailure(error)
            }
            await session.releaseShareArtifact(id: share.artifact.id)
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

    private var shareColorMode: ShareArtifactColorMode {
        usesIncreasedContrast ? .highContrast : .standard
    }

    private var effectiveReduceMotion: Bool {
        accessibilityReduceMotion || accessibilityPreferences.forcesReduceMotion
    }

    private var usesIncreasedContrast: Bool {
        colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast
    }

    private func presentFailure(_ error: Error) {
        status = .failure(RuneScribeUISession.message(for: error))
    }
}
