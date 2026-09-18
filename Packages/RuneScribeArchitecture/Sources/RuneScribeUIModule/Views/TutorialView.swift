import SwiftUI

enum RuneScribeTutorialCatalog {
    static let currentVersion = 1

    static let pages: [RuneScribeTutorialPage] = [
        RuneScribeTutorialPage(
            title: "Write or Reveal",
            systemImage: "character.cursor.ibeam",
            summary: "Choose a cipher, select Rune Scribe or Decode, then enter the message.",
            details: [
                "Rune Scribe turns ordinary text into the selected runic cipher.",
                "Decode reveals a received inscription when its cipher is in your library.",
            ]
        ),
        RuneScribeTutorialPage(
            title: "Share a Cipher",
            systemImage: "rectangle.portrait.on.rectangle.portrait",
            summary: "The recipient receives a tappable runic tablet preview.",
            details: [
                "With Rune Scribe installed, tapping opens an import confirmation in the app.",
                "Without the app, the Rune Scribe page explains what is needed and links to the App Store.",
            ]
        ),
        RuneScribeTutorialPage(
            title: "Relic, Seal, and Frame",
            systemImage: "seal.fill",
            summary: "These choices change the shared tablet's appearance, not its cipher or security.",
            details: [
                "Relic chooses the tablet material or foundation.",
                "Seal adds the theme's emblem or maker's mark.",
                "Frame chooses the border around the inscription.",
            ]
        ),
        RuneScribeTutorialPage(
            title: "Customize the Share",
            systemImage: "paintbrush.pointed.fill",
            summary: "Write first, then use Customize Share when you want a different presentation.",
            details: [
                "The writing and decoding workspaces stay focused on the message.",
                "Preview the finished tablet before sending it through Messages, Mail, AirDrop, or another system share destination.",
            ]
        ),
        RuneScribeTutorialPage(
            title: "Keep the Cipher",
            systemImage: "lock.shield.fill",
            summary: "A recipient must import the right cipher before the message can be revealed.",
            details: [
                "Review every import confirmation before accepting it.",
                "The first delivery can include the cipher needed for the conversation; later messages reuse the imported cipher.",
            ]
        ),
    ]
}

struct RuneScribeTutorialPage: Identifiable, Equatable {
    let title: String
    let systemImage: String
    let summary: String
    let details: [String]

    var id: String { title }
}

struct TutorialView: View {
    enum Mode {
        case firstRun
        case reference
    }

    let mode: Mode
    let onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage = 0

    init(mode: Mode, onComplete: @escaping () -> Void = {}) {
        self.mode = mode
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            RuneHeader(
                slot: .settings,
                subtitle: "How Rune Scribe Works",
                trailingButtons: mode == .reference
                    ? [RuneHeaderButton(systemImage: "xmark", help: "Close") { dismiss() }]
                    : []
            )

            ScrollView {
                tutorialPage(RuneScribeTutorialCatalog.pages[selectedPage])
                    .id(selectedPage)
                    .transition(.opacity)
                    .padding(RuneMetrics.pad)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            navigation
                .padding(.horizontal, RuneMetrics.pad)
                .padding(.bottom, RuneMetrics.pad)
        }
        .runeSheetFrame()
        .runeSemanticPresentationSurface()
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(mode == .firstRun)
        .animation(.easeInOut(duration: 0.2), value: selectedPage)
    }

    private func tutorialPage(_ page: RuneScribeTutorialPage) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: page.systemImage)
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(Color.runeBlue)
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text(page.title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.runeTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(page.summary)
                    .font(.body)
                    .foregroundStyle(Color.runeSilver)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.details, id: \.self) { detail in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.runeBlue)
                            .accessibilityHidden(true)
                        Text(detail)
                            .font(.body)
                            .foregroundStyle(Color.runeTextPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var navigation: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(RuneScribeTutorialCatalog.pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.runeBlue : Color.runeSilver.opacity(0.35))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(
                "Step \(selectedPage + 1) of \(RuneScribeTutorialCatalog.pages.count)"
            )

            HStack(spacing: 12) {
                if selectedPage > 0 {
                    Button("Back") { selectedPage -= 1 }
                        .buttonStyle(RuneScribButtonStyle())
                } else if mode == .firstRun {
                    Button("Skip") { complete() }
                        .buttonStyle(RuneScribButtonStyle())
                }

                Button(selectedPage == RuneScribeTutorialCatalog.pages.count - 1
                    ? (mode == .firstRun ? "Start Scribing" : "Done")
                    : "Next"
                ) {
                    if selectedPage == RuneScribeTutorialCatalog.pages.count - 1 {
                        complete()
                    } else {
                        selectedPage += 1
                    }
                }
                .buttonStyle(RuneScribButtonStyle())
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func complete() {
        onComplete()
        if mode == .reference { dismiss() }
    }
}
