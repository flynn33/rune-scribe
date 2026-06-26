// RuneScrib/Views/ContentView.swift

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

    /// One glyph size shared by the editor and the inscription so the text never
    /// changes size when it transforms — only the glyphs change.
    private let glyphSize: CGFloat = 20

    private var isEditing: Bool { boxPhase == .editing }

    private var actionDisabled: Bool {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return keyManager.activeCipher == nil
    }

    /// The cipher used to produce the current result snapshot (encode only).
    private var resultCipher: Cipher? {
        transformDirection == .encode ? keyManager.activeCipher : nil
    }

    /// Builds the share payload URL for the current runes; nil when not on an encode result.
    private func messageShareURL() -> URL? {
        guard transformDirection == .encode, let cipher = resultCipher else { return nil }
        let include = MessageSend.shouldIncludeKey(cipher)
        guard let payload = try? MessageSend.payload(runes: targetSnapshot,
                                                     senderName: cipher.label,
                                                     cipher: cipher,
                                                     includeKey: include),
              let url = try? payload.url() else { return nil }
        return url
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

                    if let contact = contactManager.contact(id: keyManager.activeCipher?.contactID) {
                        composeRecipient(contact)
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
            MessageComposeView(messageText: messageBody(),
                               recipients: messageRecipients(),
                               onFinish: handleMessageSent)
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
            keyManager.setActive(id: cipherID)
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
                        performAction()
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
                        Label(copyConfirmed ? "Copied!" : (transformDirection == .encode ? "Copy Runes" : "Copy Text"),
                              systemImage: copyConfirmed ? "checkmark.circle.fill" : "doc.on.clipboard")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RuneScribButtonStyle())
                }

                if transformDirection == .encode, let url = messageShareURL() {
                    HStack(spacing: 14) {
                        ShareLink(item: url,
                                  subject: Text("Rune Scribe message"),
                                  message: Text("A message in runes — open in Rune Scribe to read.")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RuneSecondaryButtonStyle())

                        #if os(iOS)
                        if MessageComposeView.canSend {
                            Button {
                                showMessageCompose = true
                            } label: {
                                Label("Send via iMessage", systemImage: "message.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(RuneScribButtonStyle())
                        }
                        #endif
                    }

                    keyIndicator(for: resultCipher)
                }
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
                    Button { keyManager.setActive(id: cipher.id) } label: {
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

    // MARK: - Actions

    private func performAction() {
        guard boxPhase == .editing, let activeCipher = keyManager.activeCipher else { return }
        let source = inputText
        let service = MessageService()
        let target: String
        do {
            switch mode {
            case .encode:
                target = try service.compose(source, with: activeCipher)
                transformDirection = .encode
            case .decode:
                target = try service.read(source, tryingCiphers: keyManager.ciphers).plaintext
                transformDirection = .decode
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
        copyConfirmed = false
        boxPhase = .editing
    }

    private func confirmCopy() {
        Clipboard.copy(targetSnapshot)
        withAnimation { copyConfirmed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            withAnimation { copyConfirmed = false }
        }
    }

    /// A light line telling the sender whether this message carries the cipher key.
    @ViewBuilder
    private func keyIndicator(for cipher: Cipher?) -> some View {
        if let cipher {
            let included = MessageSend.shouldIncludeKey(cipher)
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
    /// Body for the system Messages sheet: the runes, a blank line, then the link.
    private func messageBody() -> String {
        guard let url = messageShareURL() else { return targetSnapshot }
        return "\(targetSnapshot)\n\n\(url.absoluteString)"
    }

    /// Phone numbers + emails of the active cipher's linked contact, if any.
    private func messageRecipients() -> [String]? {
        guard let contact = contactManager.contact(id: resultCipher?.contactID) else { return nil }
        let all = contact.phones + contact.emails
        return all.isEmpty ? nil : all
    }

    /// Called when Apple's compose sheet reports an actual send: mark the key delivered —
    /// but only when this message actually embedded the key (a contact-linked, not-yet-
    /// delivered cipher). `delivered` means "key handed to the contact", not "ever sent",
    /// so an unlinked send must not flip it and skip a later first-delivery bootstrap.
    private func handleMessageSent() {
        if let cipher = resultCipher, MessageSend.shouldIncludeKey(cipher) {
            keyManager.markDelivered(cipherID: cipher.id)
        }
    }
    #endif
}
