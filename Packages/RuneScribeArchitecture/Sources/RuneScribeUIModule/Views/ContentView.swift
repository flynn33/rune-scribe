// RuneScrib/Views/ContentView.swift

import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

struct MessageArtifactCompletionGate: Equatable, Sendable {
    private(set) var inFlightArtifactID: ShareArtifactID?

    mutating func begin(for artifactID: ShareArtifactID) -> Bool {
        guard inFlightArtifactID == nil else { return false }
        inFlightArtifactID = artifactID
        return true
    }

    mutating func finish(for artifactID: ShareArtifactID) {
        guard inFlightArtifactID == artifactID else { return }
        inFlightArtifactID = nil
    }

    func isCompleting(_ artifactID: ShareArtifactID) -> Bool {
        inFlightArtifactID == artifactID
    }
}

private struct MessageSharePreparation: Equatable, Sendable {
    let runes: String
    let senderName: String
    let cipherID: UUID
    let shareHandle: EncodedMessageHandle
}

struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var session: RuneScribeUISession

    // MARK: - Types

    enum Mode: String, CaseIterable, Identifiable {
        case encode = "Encode"
        case decode = "Decode"
        var id: String { rawValue }
    }

    /// Drives the in-place transformation: the text box edits, then plays the
    /// inscription animation, then rests on the result — all in the same frame,
    /// which never changes size.
    private enum BoxPhase { case editing, transforming, result }

    // MARK: - State

    @State private var mode: Mode = .encode
    @State private var inputText: String = ""
    @State private var boxPhase: BoxPhase = .editing
    @State private var sourceSnapshot: String = ""
    @State private var targetSnapshot: String = ""
    @State private var transformStart: Date = .distantPast
    @State private var transformDirection: RuneInscriptionText.Direction = .encode
    @State private var actionTask: Task<Void, Never>?
    @State private var actionGeneration: UInt64 = 0
    @State private var settleTask: Task<Void, Never>?
    @State private var copyConfirmed = false
    @State private var showLibrary: Bool = false
    @State private var showSettings: Bool = false
    @State private var showVaultProgress: Bool = false
    @State private var decodeError: String?
    @State private var showMessageCompose = false
    /// Scoped Core artifact for a first-delivery attachment. UI receives only the
    /// temporary file reference and completion handle, never payload or key bytes.
    @State private var pendingMessageArtifact: ShareArtifactDTO?
    @State private var pendingMessageTransfer: OpaqueShareTransfer?
    @State private var messageSharePreparation: MessageSharePreparation?
    @State private var isPreparingMessageReplacement = false
    @State private var messageArtifactCompletionGate = MessageArtifactCompletionGate()

    // Linking the active cipher to a recipient so its first message carries the key.
    @State private var showNewContact = false
    @State private var newContactName = ""
    @State private var newContactPhone = ""
    @State private var newContactEmail = ""

    /// One glyph size shared by the editor and the inscription so the text never
    /// changes size when it transforms — only the glyphs change.
    private let glyphSize: CGFloat = 20

    private var isEditing: Bool { boxPhase == .editing }

    private var actionDisabled: Bool {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return session.activeCipher == nil
    }

    private var isWorkspaceRevealBlocked: Bool {
        showLibrary
            || showSettings
            || showVaultProgress
            || showMessageCompose
            || showNewContact
            || decodeError != nil
    }

    /// The cipher used to produce the current result snapshot (encode only).
    private var resultCipher: CipherViewState? {
        transformDirection == .encode ? session.activeCipher : nil
    }

    /// The text Rune Scribe sends for a message: always the runes. The plain "get the app"
    /// product link is appended ONLY when this message also carries the cipher file (the first
    /// message to a contact), so a recipient who lacks the app can find it. Follow-up messages —
    /// which go to someone who already has the app and the cipher — send the runes alone, with
    /// no link. The key itself never travels in this text; it rides only the first message's file.
    private func outgoingMessageText(includeProductLink: Bool) -> String {
        includeProductLink
            ? "\(targetSnapshot)\n\n\(RuneScribeShare.productLink)"
            : targetSnapshot
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.runeNavy.ignoresSafeArea()

            VStack(spacing: 0) {

                RuneHeader(
                    runic: "ᚱᚢᚾᛖ ᛋᚲᚱᛁᛒᛖ",
                    subtitle: "Rune Scribe",
                    trailingButtons: [
                        RuneHeaderButton(systemImage: "archivebox.fill",
                                         help: "Vault and Progress") { showVaultProgress = true },
                        RuneHeaderButton(systemImage: "gearshape.fill",
                                         help: "Settings") { showSettings = true },
                        RuneHeaderButton(systemImage: "key.fill",
                                         help: "Manage your cipher library") { showLibrary = true }
                    ]
                )

                // Fixed layout — only the content inside `textFrame` changes when
                // converting. Nothing here appears, disappears, or resizes.
                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {

                    activeCipherBar

                    if let active = session.activeCipher {
                        if let contact = session.contact(id: active.contactID) {
                            composeRecipient(contact)
                        } else {
                            recipientPicker(for: active)
                        }
                    }

                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    textFrame
                        .frame(maxHeight: .infinity)

                    // At least the 46pt button-row height. The transforming-phase
                    // placeholder is pinned to exactly 46pt so the parchment text frame
                    // keeps its size through the inscription animation; only the taller
                    // .result row (Share/iMessage + key indicator) is allowed to grow.
                    actionArea
                        .frame(minHeight: 46)
                }
                .padding(RuneMetrics.pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .runeRootFrame()
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showLibrary) {
            CipherLibraryView()
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showVaultProgress) {
            VaultProgressView()
        }
        #if os(iOS)
        .sheet(isPresented: $showMessageCompose) {
            MessageComposeView(messageText: outgoingMessageText(
                                   includeProductLink: pendingMessageArtifact?.requiresKeyDelivery == true
                               ),
                               recipients: messageRecipients(),
                               attachment: pendingMessageTransfer,
                               onFinish: handleMessageFinished)
        }
        #endif
        .alert("Couldn't Complete", isPresented: Binding(
            get: { decodeError != nil },
            set: { if !$0 { decodeError = nil } }
        )) {
            Button("OK") { decodeError = nil }
        } message: {
            Text(decodeError ?? "")
        }
        .alert("New Contact", isPresented: $showNewContact) {
            TextField("Name", text: $newContactName)
            TextField("Phone (optional)", text: $newContactPhone)
            TextField("Email (optional)", text: $newContactEmail)
            Button("Add") { addAndAssignContact() }
            Button("Cancel", role: .cancel) { resetNewContact() }
        } message: {
            Text("Link this cipher to a person so your first message shares the key with them.")
        }
        .onChange(of: session.route, initial: true) { _, request in
            handleRoute(request)
        }
        .onChange(of: session.isLocked) { _, isLocked in
            if isLocked { dismissPresentedContentForLock() }
        }
        .onChange(of: isWorkspaceRevealBlocked, initial: true) { _, isBlocked in
            session.setRevealBlocker(.workspaceModal, active: isBlocked)
        }
        // Changing the mode or the active cipher invalidates a shown result, so
        // drop back to editing rather than leaving stale output on screen.
        .onChange(of: mode) { _, _ in handleEditingContextChange() }
        .onChange(of: session.activeCipher?.id) { _, _ in handleEditingContextChange() }
    }

    // MARK: - Text Frame (fixed size; only the inner content changes)

    private var textFrame: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)

            switch boxPhase {
            case .editing:
                TextEditor(text: $inputText)
                    .font(.system(size: glyphSize, design: .monospaced))
                    .foregroundColor(.white)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .accessibilityLabel(
                        mode == .encode ? "Message to encode" : "Runes to decode"
                    )

                if inputText.isEmpty {
                    Text(mode == .encode ? "Type or paste your message here…"
                                         : "Paste runes to decode…")
                        .font(.system(size: glyphSize, design: .monospaced))
                        .foregroundColor(.runeSilver.opacity(0.45))
                        .padding(.horizontal, 15)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }

            case .transforming, .result:
                ScrollView {
                    RuneInscriptionText(source: sourceSnapshot,
                                        target: targetSnapshot,
                                        start: transformStart,
                                        direction: transformDirection,
                                        fontSize: glyphSize,
                                        fontName: RuneFont.name(for: session.activeCipher),
                                        settled: boxPhase == .result)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder(Color.runeBlue.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Action Area

    @ViewBuilder
    private var actionArea: some View {
        switch boxPhase {
        case .editing:
            HStack {
                if !inputText.isEmpty && !session.isLoading {
                    Button {
                        reset()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                }
                Spacer()
                if session.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading cipher…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.runeSilver)
                    }
                } else {
                    Button {
                        beginAction()
                    } label: {
                        Label(mode == .encode ? "RUNE SCRIBE" : "DECODE",
                              systemImage: mode == .encode ? "bolt.fill" : "wand.and.rays")
                    }
                    .buttonStyle(RuneScribButtonStyle())
                    .keyboardShortcut(
                        RuneScribeCommandCatalog.primaryAction.key.keyEquivalent,
                        modifiers: RuneScribeCommandCatalog.primaryAction.modifiers.eventModifiers
                    )
                    .disabled(actionDisabled || actionTask != nil)
                }
                Spacer()
            }

        case .transforming:
            // No spinner or indicator — the inscription in the frame is the feedback.
            // Pinned to the button-row height so the text frame doesn't resize mid-animation.
            Color.clear.frame(height: 46)

        case .result:
            VStack(spacing: 8) {
                resultEditCopyActions

                if transformDirection == .encode, let cipher = resultCipher {
                    #if os(iOS)
                    resultShareActions
                    #else
                    shareButton()
                    #endif

                    keyIndicator(for: cipher)
                }

                Button {
                    reset()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
            }
        }
    }

    private var resultEditCopyActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                resultEditButton(resistsCompression: true)
                resultCopyButton(resistsCompression: true)
            }

            VStack(spacing: 8) {
                resultEditButton(resistsCompression: false)
                resultCopyButton(resistsCompression: false)
            }
        }
    }

    private func resultEditButton(resistsCompression: Bool) -> some View {
        Button {
            returnToEditing()
        } label: {
            Label("Edit", systemImage: "pencil")
                .lineLimit(1)
                .fixedSize(horizontal: resistsCompression, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneSecondaryButtonStyle())
    }

    private func resultCopyButton(resistsCompression: Bool) -> some View {
        Button {
            confirmCopy()
        } label: {
            Label(
                copyButtonTitle,
                systemImage: copyConfirmed
                    ? "checkmark.circle.fill"
                    : "doc.on.clipboard"
            )
            .lineLimit(1)
            .fixedSize(horizontal: resistsCompression, vertical: false)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneScribButtonStyle())
    }

    #if os(iOS)
    private var resultShareActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                resultShareButton(resistsCompression: true)
                resultMessageButton(resistsCompression: true)
            }

            VStack(spacing: 8) {
                resultShareButton(resistsCompression: false)
                resultMessageButton(resistsCompression: false)
            }
        }
    }

    private func resultShareButton(resistsCompression: Bool) -> some View {
        shareButton()
            .lineLimit(1)
            .fixedSize(horizontal: resistsCompression, vertical: false)
            .frame(maxWidth: .infinity)
    }

    /// Always present so it is never "missing"; disabled (not hidden) when the
    /// device cannot send (Simulator / no iMessage account).
    private func resultMessageButton(resistsCompression: Bool) -> some View {
        Button {
            guard let artifact = pendingMessageArtifact,
                  pendingMessageTransfer?.isAvailable == true else {
                decodeError = "Rune Scribe is still preparing this message for sharing."
                return
            }
            // A first message must actually be able to attach the key file. If
            // this device/account cannot attach it, do not quietly send a keyless
            // message that would strand the recipient — tell them to use Share.
            if artifact.requiresKeyDelivery,
               !MessageComposeView.canSend(requiredAttachment: true) {
                decodeError = "This device can’t attach Rune Scribe files to Messages. Use Share to send the key instead."
                return
            }
            showMessageCompose = true
        } label: {
            Label("Send via iMessage", systemImage: "message.fill")
                .lineLimit(1)
                .fixedSize(horizontal: resistsCompression, vertical: false)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(RuneScribButtonStyle())
        .disabled(
            !MessageComposeView.canSend(requiredAttachment: false)
                || pendingMessageArtifact == nil
                || pendingMessageTransfer?.isAvailable != true
        )
    }
    #endif

    // MARK: - Active Cipher Bar

    private var activeCipherBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundColor(.runeGold)

            Menu {
                ForEach(session.ciphers) { cipher in
                    Button { selectActiveCipher(cipher.id) } label: {
                        if cipher.id == session.activeCipher?.id {
                            Label(cipher.label, systemImage: "checkmark")
                        } else {
                            Text(cipher.label)
                        }
                    }
                }
                Divider()
                Button { showLibrary = true } label: {
                    Label("Manage Ciphers…", systemImage: "books.vertical")
                }
            } label: {
                HStack(spacing: 6) {
                    Text(session.activeCipher?.label ?? "No Cipher")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.runeSilver)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Active cipher: \(session.activeCipher?.label ?? "No Cipher")")
            }
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())

            Text("\(session.ciphers.count) cipher\(session.ciphers.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.runeSilver)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 0)
        .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous).fill(Color.runeParchment))
        .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
            .strokeBorder(Color.runeGold.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Compose Recipient

    /// Shows who the active cipher is organized under, so the user knows the recipient.
    private func composeRecipient(_ contact: ContactViewState) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.runeBlue)
            Text("To: \(contact.displayName)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.runeSilver)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    /// Shown when the active cipher isn't linked to anyone yet: pick (or add) the
    /// recipient so the first message to them carries the cipher key.
    private func recipientPicker(for cipher: CipherViewState) -> some View {
        Menu {
            ForEach(session.contacts) { contact in
                Button(contact.displayName) {
                    linkCipher(cipher.id, to: contact.id)
                }
            }
            if !session.contacts.isEmpty { Divider() }
            Button {
                resetNewContact(); showNewContact = true
            } label: {
                Label("New Contact…", systemImage: "person.badge.plus")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 11))
                    .foregroundColor(.runeBlue)
                Text("Set recipient to include the key")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.runeBlue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.runeBlue)
                Spacer()
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Set recipient to include the key")
        }
    }

    // MARK: - Actions

    private func beginAction() {
        guard actionTask == nil else { return }
        let generation = actionGeneration
        actionTask = Task { @MainActor in
            await performAction(generation: generation)
            actionTask = nil
        }
    }

    private func performAction(generation: UInt64) async {
        guard boxPhase == .editing, let activeCipher = session.activeCipher else { return }
        let source = inputText
        let target: String
        let direction: RuneInscriptionText.Direction
        var preparedArtifact: ShareArtifactDTO?
        var preparedTransfer: OpaqueShareTransfer?
        var preparedShare: MessageSharePreparation?
        do {
            switch mode {
            case .encode:
                let result = try await session.encode(source, cipherID: activeCipher.id)
                guard let shareHandle = result.shareHandle else {
                    throw OpaqueSharePresentationError.unavailable
                }
                target = result.runes
                direction = .encode
                let share = MessageSharePreparation(
                    runes: result.runes,
                    senderName: activeCipher.label,
                    cipherID: result.cipherID.rawValue,
                    shareHandle: shareHandle
                )
                preparedArtifact = try await session.prepareMessageShare(
                    runes: share.runes,
                    senderName: share.senderName,
                    cipherID: share.cipherID,
                    shareHandle: share.shareHandle
                )
                if let preparedArtifact {
                    switch preparedArtifact.reference {
                    case .file:
                        preparedTransfer = try await session.shareTransfer(
                            for: preparedArtifact.id
                        )
                    case .opaque:
                        preparedTransfer = try await session.textShareTransfer(
                            target,
                            artifactID: preparedArtifact.id
                        )
                    }
                }
                preparedShare = share
            case .decode:
                target = try await session.decode(source).plaintext
                direction = .decode
            }
        } catch {
            await preparedTransfer?.close()
            if let preparedArtifact {
                await session.releaseShareArtifact(id: preparedArtifact.id)
            }
            guard actionGeneration == generation,
                  !Task.isCancelled,
                  !session.isLocked else { return }
            presentFailure(error)
            return
        }

        guard actionGeneration == generation, !Task.isCancelled else {
            await preparedTransfer?.close()
            if let preparedArtifact {
                await session.releaseShareArtifact(id: preparedArtifact.id)
            }
            return
        }
        guard !session.isLocked else {
            await preparedTransfer?.close()
            if let preparedArtifact {
                await session.releaseShareArtifact(id: preparedArtifact.id)
            }
            dismissPresentedContentForLock()
            return
        }

        if let preparedArtifact {
            pendingMessageArtifact = preparedArtifact
            pendingMessageTransfer = preparedTransfer
            messageSharePreparation = preparedShare
        } else {
            releaseMessageArtifact()
        }
        sourceSnapshot = source
        targetSnapshot = target
        transformDirection = direction
        transformStart = Date()
        copyConfirmed = false
        boxPhase = .transforming

        settleTask?.cancel()
        let duration = RuneInscriptionText.totalDuration(count: Array(target).count)
        settleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            boxPhase = .result
        }
    }

    private func returnToEditing() {
        settleTask?.cancel()
        releaseMessageArtifact()
        copyConfirmed = false
        boxPhase = .editing
    }

    private func handleEditingContextChange() {
        if actionTask != nil {
            actionGeneration &+= 1
            actionTask?.cancel()
        }
        if !isEditing { returnToEditing() }
    }

    /// Wipes the composer back to a pristine, empty editing state (the user changed their
    /// mind). Cancels any in-flight inscription and clears the text and result snapshots.
    private func reset() {
        settleTask?.cancel()
        inputText = ""
        sourceSnapshot = ""
        targetSnapshot = ""
        releaseMessageArtifact()
        copyConfirmed = false
        decodeError = nil
        boxPhase = .editing
    }

    private var copyButtonTitle: String {
        if copyConfirmed { return "Copied!" }
        return transformDirection == .encode ? "Copy Runes" : "Copy Text"
    }

    private func confirmCopy() {
        // Copy is plain runes only. A first-message cipher rides in the `.runescribe` file
        // (Share / Send via iMessage), never as a link inside copied text.
        Task {
            guard await session.copyToClipboard(targetSnapshot) else { return }
            if transformDirection == .encode,
               let artifact = pendingMessageArtifact,
               let transfer = pendingMessageTransfer,
               messageArtifactCompletionGate.begin(for: artifact.id) {
                do {
                    let evidence = try await transfer.finishClipboardCopy()
                    await completePreparedArtifact(
                        artifact: artifact,
                        evidence: evidence
                    )
                } catch {
                    messageArtifactCompletionGate.finish(for: artifact.id)
                    recoverMessageArtifactAfterTerminalFailure(
                        artifact: artifact,
                        error: error
                    )
                }
            }
            withAnimation { copyConfirmed = true }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { copyConfirmed = false }
        }
    }

    /// Adds a manual contact from the New Contact fields and links the active cipher to
    /// it, so the next message bootstraps the key to that person.
    private func addAndAssignContact() {
        defer { resetNewContact() }
        guard let active = session.activeCipher else { return }
        let name = newContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let phones = [newContactPhone.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let emails = [newContactEmail.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let contact = ContactViewState(
            displayName: name,
            phones: phones,
            emails: emails,
            source: .manual
        )
        Task {
            do {
                let persisted = try await session.createContact(contact)
                try await session.setContact(cipherID: active.id, contactID: persisted.id)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func resetNewContact() {
        newContactName = ""; newContactPhone = ""; newContactEmail = ""
    }

    private func handleRoute(_ request: RuneScribeUIRouteRequest?) {
        guard let request else { return }
        defer { session.consumeRoute(id: request.id) }
        guard !session.isLocked else { return }

        switch request.route {
        case .openCipherLibrary:
            showLibrary = true
        case .openSettings:
            showSettings = true
        case .replyToMessage(let cipherID):
            guard session.ciphers.contains(where: { $0.id == cipherID }) else { return }
            Task {
                do {
                    try await session.setActive(id: cipherID)
                    mode = .encode
                    if !isEditing { returnToEditing() }
                } catch {
                    presentFailure(error)
                }
            }
        }
    }

    private func dismissPresentedContentForLock() {
        actionGeneration &+= 1
        actionTask?.cancel()
        settleTask?.cancel()
        settleTask = nil
        inputText = ""
        sourceSnapshot = ""
        targetSnapshot = ""
        decodeError = nil
        copyConfirmed = false
        boxPhase = .editing
        showLibrary = false
        showSettings = false
        showVaultProgress = false
        showMessageCompose = false
        showNewContact = false
        resetNewContact()
        session.setRevealBlocker(.systemShare, active: false)
        releaseMessageArtifact()
    }

    /// The Share button. On the first message to a contact it shares the self-contained
    /// `.runescribe` file (envelope + key) and marks the cipher delivered; on every later
    /// message there is no file, so it shares the runes alone (no product link — the link rides
    /// only with the cipher file) — which a recipient who already holds the cipher decodes in
    /// the Decode tab.
    @ViewBuilder
    private func shareButton() -> some View {
        if let artifact = pendingMessageArtifact,
           case .file = artifact.reference {
            if let transfer = pendingMessageTransfer {
                RuneScribeFileShareLink(
                    transfer: transfer,
                    onShareTriggered: {
                        session.setRevealBlocker(.systemShare, active: true)
                    },
                    onFinish: { completion in
                        handleNativeShareFinished(completion)
                    }
                )
                .buttonStyle(RuneSecondaryButtonStyle())
            } else {
                Button { } label: {
                    Label("Preparing…", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
                .disabled(true)
            }
        } else if pendingMessageArtifact == nil,
                  let preparation = messageSharePreparation {
            Button {
                Task {
                    await prepareReplacementMessageArtifact(using: preparation)
                }
            } label: {
                Label(
                    isPreparingMessageReplacement ? "Preparing…" : "Retry Share",
                    systemImage: isPreparingMessageReplacement
                        ? "clock"
                        : "arrow.clockwise"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .disabled(isPreparingMessageReplacement)
        } else if pendingMessageArtifact == nil {
            Button { } label: {
                Label("Preparing…", systemImage: "clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .disabled(true)
        } else {
            if let transfer = pendingMessageTransfer {
                RuneScribeTextShareLink(
                    transfer: transfer,
                    onShareTriggered: {
                        session.setRevealBlocker(.systemShare, active: true)
                    },
                    onFinish: { completion in
                        handleNativeShareFinished(completion)
                    }
                )
                .buttonStyle(RuneSecondaryButtonStyle())
            } else {
                Button { } label: {
                    Label("Preparing…", systemImage: "clock")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
                .disabled(true)
            }
        }
    }

    /// A light line telling the sender whether this message carries the cipher key.
    @ViewBuilder
    private func keyIndicator(for cipher: CipherViewState?) -> some View {
        if cipher != nil {
            let included = pendingMessageArtifact?.requiresKeyDelivery == true
            HStack(spacing: 6) {
                Image(systemName: included ? "key.fill" : "lock.fill")
                    .font(.system(size: 10))
                    .foregroundColor(included ? .runeGold : .runeBlue)
                Text(included ? "Key included" : "Uses your shared key")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.runeSilver)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    #if os(iOS)
    /// Phone numbers + emails of the active cipher's linked contact, if any.
    private func messageRecipients() -> [String]? {
        guard let contact = session.contact(id: resultCipher?.contactID) else { return nil }
        let all = contact.phones + contact.emails
        return all.isEmpty ? nil : all
    }

    private func handleMessageFinished(_ completion: SharePresentationCompletion) {
        showMessageCompose = false
        handleShareCompletion(completion)
    }
    #endif

    private func handleShareCompletion(_ completion: SharePresentationCompletion) {
        switch completion {
        case .success(let evidence):
            beginMessageArtifactCompletion(evidence: evidence)
        case .failure(let error):
            guard let artifact = pendingMessageArtifact else {
                presentFailure(error)
                return
            }
            recoverMessageArtifactAfterTerminalFailure(
                artifact: artifact,
                error: error
            )
        }
    }

    private func handleNativeShareFinished(_ completion: SharePresentationCompletion) {
        session.setRevealBlocker(.systemShare, active: false)
        handleShareCompletion(completion)
    }

    private func recoverMessageArtifactAfterTerminalFailure(
        artifact: ShareArtifactDTO,
        error: any Error
    ) {
        guard pendingMessageArtifact?.id == artifact.id else { return }
        presentFailure(error)
        let preparation = messageSharePreparation
        pendingMessageArtifact = nil
        let transfer = pendingMessageTransfer
        pendingMessageTransfer = nil
        Task {
            await transfer?.close()
            await session.releaseShareArtifact(id: artifact.id)
            if let preparation {
                await prepareReplacementMessageArtifact(using: preparation)
            }
        }
    }

    private func beginMessageArtifactCompletion(
        evidence: ShareArtifactCompletionEvidenceDTO
    ) {
        guard let artifact = pendingMessageArtifact,
              artifact.id == evidence.artifactID,
              messageArtifactCompletionGate.begin(for: evidence.artifactID)
        else { return }
        Task {
            await completePreparedArtifact(artifact: artifact, evidence: evidence)
        }
    }

    private func completePreparedArtifact(
        artifact: ShareArtifactDTO,
        evidence: ShareArtifactCompletionEvidenceDTO
    ) async {
        defer { messageArtifactCompletionGate.finish(for: artifact.id) }
        let preparation = messageSharePreparation
        do {
            _ = try await session.completeShareArtifact(evidence: evidence)
        } catch {
            await session.releaseShareArtifact(id: artifact.id)
            if pendingMessageArtifact?.id == artifact.id {
                presentFailure(error)
            }
        }

        guard pendingMessageArtifact?.id == artifact.id else { return }
        pendingMessageArtifact = nil
        let transfer = pendingMessageTransfer
        pendingMessageTransfer = nil
        await transfer?.close()

        guard let preparation else { return }
        await prepareReplacementMessageArtifact(using: preparation)
    }

    private func prepareReplacementMessageArtifact(
        using preparation: MessageSharePreparation
    ) async {
        guard messageSharePreparation == preparation,
              pendingMessageArtifact == nil,
              transformDirection == .encode,
              boxPhase != .editing,
              !session.isLocked,
              !isPreparingMessageReplacement
        else { return }
        isPreparingMessageReplacement = true
        defer { isPreparingMessageReplacement = false }

        var artifact: ShareArtifactDTO?
        var transfer: OpaqueShareTransfer?
        do {
            let preparedArtifact = try await session.prepareMessageShare(
                runes: preparation.runes,
                senderName: preparation.senderName,
                cipherID: preparation.cipherID,
                shareHandle: preparation.shareHandle
            )
            artifact = preparedArtifact
            switch preparedArtifact.reference {
            case .file:
                transfer = try await session.shareTransfer(for: preparedArtifact.id)
            case .opaque:
                transfer = try await session.textShareTransfer(
                    preparation.runes,
                    artifactID: preparedArtifact.id
                )
            }
        } catch {
            if let artifact {
                await session.releaseShareArtifact(id: artifact.id)
            }
            guard messageSharePreparation == preparation,
                  !session.isLocked else { return }
            presentFailure(error)
            return
        }

        guard let artifact,
              let transfer,
              messageSharePreparation == preparation,
              pendingMessageArtifact == nil,
              transformDirection == .encode,
              boxPhase != .editing,
              !session.isLocked
        else {
            await transfer?.close()
            if let artifact {
                await session.releaseShareArtifact(id: artifact.id)
            }
            return
        }
        pendingMessageArtifact = artifact
        pendingMessageTransfer = transfer
    }

    private func selectActiveCipher(_ id: UUID) {
        Task {
            do {
                try await session.setActive(id: id)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func linkCipher(_ cipherID: UUID, to contactID: UUID) {
        Task {
            do {
                try await session.setContact(cipherID: cipherID, contactID: contactID)
            } catch {
                presentFailure(error)
            }
        }
    }

    private func presentFailure(_ error: Error) {
        decodeError = RuneScribeUISession.message(for: error)
    }

    private func releaseMessageArtifact() {
        messageSharePreparation = nil
        guard let artifact = pendingMessageArtifact else { return }
        guard !messageArtifactCompletionGate.isCompleting(artifact.id) else { return }
        pendingMessageArtifact = nil
        let transfer = pendingMessageTransfer
        pendingMessageTransfer = nil
        Task {
            await transfer?.close()
            await session.releaseShareArtifact(id: artifact.id)
        }
    }
}
