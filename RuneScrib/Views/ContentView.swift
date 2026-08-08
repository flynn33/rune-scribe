// RuneScrib/Views/ContentView.swift

import RuneScribeContracts
import SwiftUI

struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var keyManager: KeyManager
    @EnvironmentObject private var contactManager: ContactManager

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
    @State private var settleTask: Task<Void, Never>?
    @State private var copyConfirmed = false
    @State private var showLibrary: Bool = false
    @State private var showSettings: Bool = false
    @State private var decodeError: String?
    @State private var showMessageCompose = false
    /// Scoped Core artifact for a first-delivery attachment. UI receives only the
    /// temporary file reference and completion handle, never payload or key bytes.
    @State private var pendingMessageArtifact: ShareArtifactDTO?

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
        return keyManager.activeCipher == nil
    }

    /// The cipher used to produce the current result snapshot (encode only).
    private var resultCipher: CipherViewState? {
        transformDirection == .encode ? keyManager.activeCipher : nil
    }

    private var pendingAttachmentURL: URL? {
        guard let artifact = pendingMessageArtifact,
              case .file(let url) = artifact.reference else { return nil }
        return url
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

                    if let active = keyManager.activeCipher {
                        if let contact = contactManager.contact(id: active.contactID) {
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
            CipherLibraryView().environmentObject(keyManager).environmentObject(contactManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        #if os(iOS)
        .sheet(isPresented: $showMessageCompose) {
            MessageComposeView(messageText: outgoingMessageText(
                                   includeProductLink: pendingMessageArtifact?.requiresKeyDelivery == true
                               ),
                               recipients: messageRecipients(),
                               attachmentURL: pendingAttachmentURL,
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
        .onReceive(NotificationCenter.default.publisher(for: .openLibraryRequested)) { _ in
            showLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .replyToMessageRequested)) { note in
            // Only switch if the message's cipher is actually in the library; otherwise
            // setActive would be a silent no-op and the reply would use the wrong key.
            guard let cipherID = note.object as? UUID,
                  keyManager.ciphers.contains(where: { $0.id == cipherID }) else { return }
            Task { try? await keyManager.setActive(id: cipherID) }
            mode = .encode
            if !isEditing { returnToEditing() }
        }
        // Changing the mode or the active cipher invalidates a shown result, so
        // drop back to editing rather than leaving stale output on screen.
        .onChange(of: mode) { _, _ in if !isEditing { returnToEditing() } }
        .onChange(of: keyManager.activeCipher?.id) { _, _ in if !isEditing { returnToEditing() } }
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
                                        fontName: RuneFont.name(for: keyManager.activeCipher),
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
                if !inputText.isEmpty && !keyManager.isLoading {
                    Button {
                        reset()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())
                }
                Spacer()
                if keyManager.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8)
                        Text("Loading cipher…")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.runeSilver)
                    }
                } else {
                    Button {
                        Task { await performAction() }
                    } label: {
                        Label(mode == .encode ? "RUNE SCRIBE" : "DECODE",
                              systemImage: mode == .encode ? "bolt.fill" : "wand.and.rays")
                    }
                    .buttonStyle(RuneScribButtonStyle())
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(actionDisabled)
                }
                Spacer()
            }

        case .transforming:
            // No spinner or indicator — the inscription in the frame is the feedback.
            // Pinned to the button-row height so the text frame doesn't resize mid-animation.
            Color.clear.frame(height: 46)

        case .result:
            VStack(spacing: 8) {
                HStack(spacing: 14) {
                    Button {
                        returnToEditing()
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneSecondaryButtonStyle())

                    Button {
                        confirmCopy()
                    } label: {
                        Label(copyButtonTitle,
                              systemImage: copyConfirmed ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }

                if transformDirection == .encode, let cipher = resultCipher {
                    HStack(spacing: 14) {
                        shareButton()

                        #if os(iOS)
                        // Always present so it's never "missing"; disabled (not hidden) when
                        // the device can't send (Simulator / no iMessage account). macOS sends
                        // through the native Share sheet above (Messages/Mail/AirDrop) — no
                        // separate button, so we don't reinvent what the share sheet provides.
                        Button {
                            // A first message must actually be able to attach the key file. If
                            // this device/account can't attach it, don't quietly send a keyless
                            // message that would strand the recipient — tell them to use Share.
                            if pendingMessageArtifact?.requiresKeyDelivery == true,
                               !MessageComposeView.canSend(requiredAttachment: true) {
                                decodeError = "This device can’t attach Rune Scribe files to Messages. Use Share to send the key instead."
                                return
                            }
                            guard pendingMessageArtifact?.requiresKeyDelivery != true
                                    || pendingAttachmentURL != nil else {
                                decodeError = "Rune Scribe is still preparing the key attachment."
                                return
                            }
                            showMessageCompose = true
                        } label: {
                            Label("Send via iMessage", systemImage: "message.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneScribButtonStyle())
                        .disabled(!MessageComposeView.canSend(requiredAttachment: false))
                        #endif
                    }

                    keyIndicator(for: cipher)
                }

                Button {
                    reset()
                } label: {
                    Label("Clear", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RuneSecondaryButtonStyle())
            }
        }
    }

    // MARK: - Active Cipher Bar

    private var activeCipherBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12))
                .foregroundColor(.runeGold)

            Menu {
                ForEach(keyManager.ciphers) { cipher in
                    Button { Task { try? await keyManager.setActive(id: cipher.id) } } label: {
                        if cipher.id == keyManager.activeCipher?.id {
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
                    Text(keyManager.activeCipher?.label ?? "No Cipher")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.runeSilver)
                }
            }
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Text("\(keyManager.ciphers.count) cipher\(keyManager.ciphers.count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.runeSilver)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous).fill(Color.runeParchment))
        .overlay(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
            .strokeBorder(Color.runeGold.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Compose Recipient

    /// Shows who the active cipher is organized under, so the user knows the recipient.
    private func composeRecipient(_ contact: Contact) -> some View {
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
            ForEach(contactManager.contacts) { contact in
                Button(contact.displayName) {
                    Task { try? await keyManager.setContact(cipherID: cipher.id, contactID: contact.id) }
                }
            }
            if !contactManager.contacts.isEmpty { Divider() }
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
        }
    }

    // MARK: - Actions

    private func performAction() async {
        guard boxPhase == .editing, let activeCipher = keyManager.activeCipher else { return }
        let source = inputText
        let target: String
        do {
            switch mode {
            case .encode:
                let result = try await keyManager.encode(source, cipherID: activeCipher.id)
                target = result.runes
                transformDirection = .encode
                pendingMessageArtifact = try await keyManager.prepareMessageShare(
                    runes: result.runes,
                    senderName: activeCipher.label,
                    cipherID: activeCipher.id
                )
            case .decode:
                target = try await keyManager.decode(source).plaintext
                transformDirection = .decode
                releaseMessageArtifact()
            }
        } catch {
            decodeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }

        sourceSnapshot = source
        targetSnapshot = target
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
        Clipboard.copy(targetSnapshot)
        withAnimation { copyConfirmed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { copyConfirmed = false }
        }
    }

    /// Adds a manual contact from the New Contact fields and links the active cipher to
    /// it, so the next message bootstraps the key to that person.
    private func addAndAssignContact() {
        defer { resetNewContact() }
        guard let active = keyManager.activeCipher else { return }
        let name = newContactName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let phones = [newContactPhone.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let emails = [newContactEmail.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }
        let contact = Contact(displayName: name, phones: phones, emails: emails, source: .manual)
        Task {
            guard let persisted = try? await contactManager.create(contact) else { return }
            try? await keyManager.setContact(cipherID: active.id, contactID: persisted.id)
        }
    }

    private func resetNewContact() {
        newContactName = ""; newContactPhone = ""; newContactEmail = ""
    }

    /// The Share button. On the first message to a contact it shares the self-contained
    /// `.runescribe` file (envelope + key) and marks the cipher delivered; on every later
    /// message there is no file, so it shares the runes alone (no product link — the link rides
    /// only with the cipher file) — which a recipient who already holds the cipher decodes in
    /// the Decode tab.
    @ViewBuilder
    private func shareButton() -> some View {
        if let artifact = pendingMessageArtifact,
           case .file(let fileURL) = artifact.reference {
            ShareLink(item: fileURL,
                      preview: SharePreview("Rune Scribe message",
                                            image: Image(systemName: "doc.fill"))) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .simultaneousGesture(TapGesture().onEnded {
                Task { await completePreparedArtifact(outcome: .handedOff) }
            })
        } else if pendingMessageArtifact == nil {
            Button { } label: {
                Label("Preparing…", systemImage: "clock")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
            .disabled(true)
        } else {
            // No cipher file on this message → share the runes alone. The product link rides
            // only with the cipher file (the first message to a contact), never on follow-ups.
            ShareLink(item: outgoingMessageText(includeProductLink: false)) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RuneSecondaryButtonStyle())
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
        guard let contact = contactManager.contact(id: resultCipher?.contactID) else { return nil }
        let all = contact.phones + contact.emails
        return all.isEmpty ? nil : all
    }

    private func handleMessageFinished(_ outcome: ShareArtifactOutcomeDTO) {
        Task { await completePreparedArtifact(outcome: outcome) }
    }
    #endif

    private func completePreparedArtifact(outcome: ShareArtifactOutcomeDTO) async {
        guard let artifact = pendingMessageArtifact else { return }
        do {
            let result = try await keyManager.completeShareArtifact(id: artifact.id, outcome: outcome)
            if result != .retainedForRetry {
                pendingMessageArtifact = nil
            }
        } catch {
            decodeError = keyManager.lastError ?? error.localizedDescription
        }
    }

    private func releaseMessageArtifact() {
        guard let artifact = pendingMessageArtifact else { return }
        pendingMessageArtifact = nil
        Task { await keyManager.releaseShareArtifact(id: artifact.id) }
    }
}
