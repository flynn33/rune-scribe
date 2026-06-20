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

    /// Identifiable payload carried into the result sheet (avoids SwiftUI's
    /// `.sheet(isPresented:)` stale-capture bug).
    private struct ResultPayload: Identifiable {
        let id = UUID()
        let runes: String
        let plain: String
        let direction: ResultPopupView.Direction
    }

    // MARK: - State

    @State private var mode: Mode = .encode
    @State private var inputText: String = ""
    @State private var result: ResultPayload?
    @State private var showLibrary: Bool = false
    @State private var showSettings: Bool = false

    // MARK: - Derived

    private var recognizedSet: Set<String> {
        switch mode {
        case .encode: return RuneCharacterSet.inputCharacterSet
        case .decode: return keyManager.activeCipher.map { Set($0.key.reverseMapping.keys) } ?? []
        }
    }

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

                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {

                    activeCipherBar

                    // ── Mode toggle ───────────────────────────────────────────
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    // ── Input ─────────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        RuneEyebrow(title: mode == .encode ? "Plain Text" : "Rune Text",
                                    systemImage: mode == .encode ? "text.alignleft" : "wand.and.rays",
                                    accent: .runeSilver)

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .fill(Color.runeParchment)

                            TextEditor(text: $inputText)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .padding(10)

                            if inputText.isEmpty {
                                Text(mode == .encode ? "Type or paste your message here…"
                                                     : "Paste runes to decode…")
                                    .font(.system(size: 15, design: .monospaced))
                                    .foregroundColor(.runeSilver.opacity(0.45))
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 18)
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .strokeBorder(Color.runeBlue.opacity(0.35), lineWidth: 1)
                        )

                        CharacterCountView(text: inputText,
                                           recognized: recognizedSet,
                                           recognizedLabel: mode == .encode ? "encodable" : "decodable",
                                           recognizedAccent: mode == .encode ? .runeBlue : .runeGold)
                    }
                    .frame(maxHeight: .infinity)

                    // ── Decode hint ───────────────────────────────────────────
                    if mode == .decode {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").foregroundColor(.runeBlue)
                            Text("Decoding uses the active cipher. To read someone else's runes, "
                                 + "select their imported decoder above.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.runeSilver)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                    }

                    // ── Error display ─────────────────────────────────────────
                    if let error = keyManager.lastError {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.orange)
                            Spacer()
                        }
                    }

                    // ── Primary action (centered) ─────────────────────────────
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
                }
                .padding(RuneMetrics.pad)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .runeRootFrame()
        .preferredColorScheme(.dark)
        // ── Sheets ────────────────────────────────────────────────────────────
        .sheet(item: $result) { payload in
            ResultPopupView(runes: payload.runes, plain: payload.plain, direction: payload.direction)
        }
        .sheet(isPresented: $showLibrary) {
            CipherLibraryView().environmentObject(keyManager)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        // ── Menu-command notification listeners ───────────────────────────────
        .onReceive(NotificationCenter.default.publisher(for: .openLibraryRequested)) { _ in
            showLibrary = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsRequested)) { _ in
            showSettings = true
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
        guard let cipher = keyManager.activeCipher else { return }
        let engine = CipherEngine(key: cipher.key)
        switch mode {
        case .encode:
            let encoded = engine.encode(inputText)
            result = ResultPayload(runes: encoded, plain: inputText, direction: .encode)
        case .decode:
            let decoded = engine.decode(inputText)
            result = ResultPayload(runes: inputText, plain: decoded, direction: .decode)
        }
    }
}
