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
    @State private var showKeyManagement: Bool = false

    // MARK: - Derived

    private var recognizedSet: Set<String> {
        switch mode {
        case .encode: return RuneCharacterSet.inputCharacterSet
        case .decode: return keyManager.importedDecoder.map { Set($0.reverseMapping.keys) } ?? []
        }
    }

    private var actionDisabled: Bool {
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        switch mode {
        case .encode: return keyManager.currentKey == nil
        case .decode: return keyManager.importedDecoder == nil
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            Color.runeNavy.ignoresSafeArea()

            VStack(spacing: 0) {

                RuneHeader(
                    runic: "ᚱᚢᚾᛖ ᛋᚲᚱᛁᛒ",
                    subtitle: "Rune · Scrib",
                    trailingButton: RuneHeaderButton(
                        systemImage: "key.fill",
                        help: "Manage, rotate, export, and import keys"
                    ) { showKeyManagement = true }
                )

                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {

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

                    // ── Decode hint when no decoder is imported ───────────────
                    if mode == .decode && keyManager.importedDecoder == nil {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle").foregroundColor(.runeBlue)
                            Text("Import a decoder to read runes.")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.runeSilver)
                            Spacer()
                            Button("Import…") { showKeyManagement = true }
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundColor(.runeGold)
                                .buttonStyle(.plain)
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
                                Text("Loading key…")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.runeSilver)
                            }
                        } else {
                            Button {
                                performAction()
                            } label: {
                                Label(mode == .encode ? "RUNE SCRIB" : "DECODE",
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
        .sheet(isPresented: $showKeyManagement) {
            KeyManagementView()
                .environmentObject(keyManager)
        }
        // ── Menu-command notification listeners ───────────────────────────────
        .onReceive(NotificationCenter.default.publisher(for: .exportKeyRequested)) { _ in
            showKeyManagement = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .rotateKeyRequested)) { _ in
            showKeyManagement = true
        }
    }

    // MARK: - Actions

    private func performAction() {
        switch mode {
        case .encode:
            guard let key = keyManager.currentKey else { return }
            let encoded = CipherEngine(key: key).encode(inputText)
            result = ResultPayload(runes: encoded, plain: inputText, direction: .encode)
        case .decode:
            guard let decoder = keyManager.importedDecoder else { return }
            let decoded = CipherEngine(decoder: decoder).decode(inputText)
            result = ResultPayload(runes: inputText, plain: decoded, direction: .decode)
        }
    }
}
