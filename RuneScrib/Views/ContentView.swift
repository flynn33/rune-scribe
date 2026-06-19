// RuneScrib/Views/ContentView.swift

import SwiftUI

struct ContentView: View {

    // MARK: - Environment

    @EnvironmentObject private var keyManager: KeyManager

    // MARK: - State

    @State private var inputText: String = ""
    // The result sheet is driven by an Identifiable item rather than a Bool +
    // separate `encodedText` String. Setting both in one event triggers SwiftUI's
    // `.sheet(isPresented:)` stale-capture bug (the sheet reads the pre-mutation,
    // empty value). `.sheet(item:)` presents with the freshly-computed payload.
    @State private var encodedResult: EncodedResult?
    @State private var showKeyManagement: Bool = false

    /// Identifiable payload that carries a completed encoding into the result sheet.
    private struct EncodedResult: Identifiable {
        let id = UUID()
        let encoded: String
        let original: String
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
                        help: "Manage, rotate, and export the cipher key"
                    ) { showKeyManagement = true }
                )

                VStack(alignment: .leading, spacing: RuneMetrics.sectionGap) {

                    // ── Input ─────────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        RuneEyebrow(title: "Plain Text", systemImage: "text.alignleft", accent: .runeSilver)

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                                .fill(Color.runeParchment)

                            TextEditor(text: $inputText)
                                .font(.system(size: 15, design: .monospaced))
                                .foregroundColor(.white)
                                .scrollContentBackground(.hidden)
                                .padding(10)

                            if inputText.isEmpty {
                                Text("Type or paste your message here…")
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

                        CharacterCountView(text: inputText)
                    }
                    .frame(maxHeight: .infinity)

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
                                performEncoding()
                            } label: {
                                Label("RUNE SCRIB", systemImage: "bolt.fill")
                            }
                            .buttonStyle(RuneScribButtonStyle())
                            .keyboardShortcut(.return, modifiers: [.command])
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || keyManager.currentKey == nil)
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
        .sheet(item: $encodedResult) { result in
            ResultPopupView(encodedText: result.encoded, originalText: result.original)
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

    private func performEncoding() {
        guard let key = keyManager.currentKey else { return }
        let engine = CipherEngine(key: key)
        encodedResult = EncodedResult(encoded: engine.encode(inputText),
                                      original: inputText)
    }
}
