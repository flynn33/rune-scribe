// RuneScrib/Views/ContentView.swift

import SwiftUI

struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var keyManager: KeyManager

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

    /// One glyph size shared by the editor and the inscription so the text never
    /// changes size when it transforms — only the glyphs change.
    private let glyphSize: CGFloat = 20

    private var isEditing: Bool { boxPhase == .editing }

    private var actionDisabled: Bool {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        return keyManager.activeCipher == nil
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.runeNavy.ignoresSafeArea()

            VStack(spacing: 0) {

                RuneHeader(
                    runic: "ᚱᚢᚾᛖ ᛋᚲᚱᛁᛒ",
                    subtitle: "Rune · Scribe",
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

                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    textFrame
                        .frame(maxHeight: .infinity)

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
            CipherLibraryView().environmentObject(keyManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLibraryRequested)) { _ in
            showLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            showSettings = true
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
            Color.clear

        case .result:
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

    // MARK: - Actions

    private func performAction() {
        guard boxPhase == .editing, let cipher = keyManager.activeCipher else { return }
        let source = inputText
        let engine = CipherEngine(key: cipher.key)
        let target: String
        switch mode {
        case .encode:
            target = engine.encode(source)
            transformDirection = .encode
        case .decode:
            target = engine.decode(source)
            transformDirection = .decode
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
}
