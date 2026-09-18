import RuneScribeContracts
import RuneScribeUIRuntime
import SwiftUI

@MainActor
enum RootImportFailurePresentation {
    static func shouldShowAlert(
        message: String?,
        hasPendingImport: Bool,
        isLocked: Bool,
        showSplash: Bool
    ) -> Bool {
        message != nil && !hasPendingImport && !isLocked && !showSplash
    }
}

enum RootRevealSafetyPolicy {
    static func shouldBlock(
        showSplash: Bool,
        isLocked: Bool,
        importPhase: ImportPhaseDTO?,
        messagePhase: MessagePhaseDTO?,
        hasPendingImport: Bool,
        hasPendingMessage: Bool,
        hasSecurityOrFailurePresentation: Bool
    ) -> Bool {
        let importIsActive = importPhase == .validating
            || importPhase == .awaitingConfirmation
            || importPhase == .importing
        let receivedMessageIsDecoding = messagePhase == .receiving
            || messagePhase == .received
        return showSplash
            || isLocked
            || importIsActive
            || receivedMessageIsDecoding
            || hasPendingImport
            || hasPendingMessage
            || hasSecurityOrFailurePresentation
    }
}

enum RootPendingPresentation: Equatable {
    case importConfirmation
    case receivedMessage
    case tutorial
}

enum RootPendingPresentationPolicy {
    static func selection(
        showSplash: Bool,
        isLocked: Bool,
        hasPendingImport: Bool,
        hasPendingMessage: Bool,
        needsTutorial: Bool = false
    ) -> RootPendingPresentation? {
        guard !showSplash, !isLocked else { return nil }
        if hasPendingImport { return .importConfirmation }
        if hasPendingMessage { return .receivedMessage }
        if needsTutorial { return .tutorial }
        return nil
    }
}

enum RootReceivedMessageNavigationPolicy {
    static let openCodexRoute: RuneScribeUIRoute = .openSettings
}

enum RootEmergencyThemeWarningPolicy {
    static func shouldShow(
        isEmergencyPresentation: Bool,
        isDismissed: Bool,
        showSplash: Bool,
        isLocked: Bool,
        hasPendingImport: Bool,
        hasPendingMessage: Bool,
        hasActiveReveal: Bool,
        hasTutorial: Bool = false
    ) -> Bool {
        isEmergencyPresentation
            && !isDismissed
            && !showSplash
            && !isLocked
            && !hasPendingImport
            && !hasPendingMessage
            && !hasActiveReveal
            && !hasTutorial
    }
}

/// Hosts the main interface and overlays the lock screen whenever the app is
/// locked. The Core lifecycle path re-locks on background, while this view plays
/// the launch splash on a cold start when the 30-day intro schedule allows.
struct RootView: View {
    @ObservedObject private var session: RuneScribeUISession
    private let allowsColdLaunchSplash: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.runtimeAccessibilityPreferences) private var accessibilityPreferences

    /// Created once with the process-owned session, so a background/foreground
    /// transition never re-evaluates the cold-launch splash schedule.
    @State private var showSplash: Bool
    @State private var didEvaluateColdLaunchSplash = false
    @State private var isEmergencyThemeWarningDismissed = false
    @State private var showsEmergencyThemeWarningDetails = false
    @State private var workspaceDraft = ""
    @State private var tutorialDismissedForSession = false

    init(
        session: RuneScribeUISession,
        allowsColdLaunchSplash: Bool = true
    ) {
        self.session = session
        self.allowsColdLaunchSplash = allowsColdLaunchSplash
        _showSplash = State(initialValue: false)
    }

    private var revealIsBlockedAtRoot: Bool {
        RootRevealSafetyPolicy.shouldBlock(
            showSplash: showSplash,
            isLocked: session.isLocked,
            importPhase: session.snapshot?.importState.phase,
            messagePhase: session.snapshot?.messageState.phase,
            hasPendingImport: session.pendingImport != nil,
            hasPendingMessage: session.pendingMessage != nil,
            hasSecurityOrFailurePresentation: session.importErrorMessage != nil
                || session.messageErrorMessage != nil
                || session.lastError != nil
                || pendingPresentation == .tutorial
        )
    }

    private var pendingPresentation: RootPendingPresentation? {
        RootPendingPresentationPolicy.selection(
            showSplash: showSplash,
            isLocked: session.isLocked,
            hasPendingImport: session.pendingImport != nil,
            hasPendingMessage: session.pendingMessage != nil,
            needsTutorial: tutorialIsNeeded
        )
    }

    private var showsEmergencyThemeWarning: Bool {
        RootEmergencyThemeWarningPolicy.shouldShow(
            isEmergencyPresentation: session.themeSnapshot?.isEmergencyPresentation == true,
            isDismissed: isEmergencyThemeWarningDismissed,
            showSplash: showSplash,
            isLocked: session.isLocked,
            hasPendingImport: session.pendingImport != nil,
            hasPendingMessage: session.pendingMessage != nil,
            hasActiveReveal: session.activeReveal != nil,
            hasTutorial: tutorialIsNeeded
        )
    }

    private var tutorialIsNeeded: Bool {
        session.runtimePresentationSettingsReady
            && !tutorialDismissedForSession
            && session.tutorialCompletedVersion < RuneScribeTutorialCatalog.currentVersion
    }

    var body: some View {
        ZStack {
            // Build the workspace beneath the launch splash so theme fonts and layout
            // settle before reveal. A locked app still removes the workspace entirely,
            // keeping message content out of the protected presentation hierarchy.
            if !session.isLocked {
                ContentView(
                    initialInputText: workspaceDraft,
                    onInputTextChange: { workspaceDraft = $0 }
                )
                .opacity(showSplash ? 0 : 1)
                .allowsHitTesting(!showSplash)
                .accessibilityHidden(showSplash)
            }

            if showsEmergencyThemeWarning {
                VStack(spacing: 0) {
                    RequiredBaseThemeWarning(
                        failures: session.themeSnapshot?.requiredBaseResourceFailures ?? [],
                        showsDetails: $showsEmergencyThemeWarningDetails,
                        dismiss: {
                            isEmergencyThemeWarningDismissed = true
                            showsEmergencyThemeWarningDetails = false
                        }
                    )
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .safeAreaPadding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(0.75)
            }

            if let reveal = session.activeReveal,
               !revealIsBlockedAtRoot {
                UnlockRevealView(reveal: reveal)
                    .zIndex(0.5)
            }

            if session.isLocked {
                LockView()
                    .accessibilityAddTraits(.isModal)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showSplash {
                session.resourcePresentation.makeSplashView {
                    let shownAt = Date()
                    withAnimation(.easeInOut(duration: 0.45)) { showSplash = false }
                    Task { await session.markSplashShown(at: shownAt) }
                }
                .transition(.opacity)
                .zIndex(2)
                .ignoresSafeArea()
            }
        }
        // The application shell is the single owner of the provider-neutral
        // Theme background. A background receives the resolved root bounds
        // without contributing its renderer's ideal size to workspace layout.
        .background {
            ZStack {
                RuntimeMetalBackground()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                RuneAtmosphericBackgroundTreatment()
            }
            .ignoresSafeArea()
            .accessibilityIdentifier(rootBackgroundAccessibilityIdentifier)
            .runtimeViewportFrameProbe(rootBackgroundAccessibilityIdentifier)
            .themeCaptureViewportIdentifier(rootBackgroundCaptureIdentifier)
        }
        .animation(.easeInOut(duration: 0.25), value: session.isLocked)
        .animation(.easeInOut(duration: 0.2), value: showsEmergencyThemeWarning)
        .onChange(of: session.runtimePresentationSettingsReady, initial: true) { _, _ in
            evaluateColdLaunchSplashIfReady()
        }
        .onChange(of: revealIsBlockedAtRoot, initial: true) { _, isBlocked in
            session.setRevealBlocker(.rootPresentation, active: isBlocked)
        }
        .sheet(item: Binding(
            get: {
                pendingPresentation == .importConfirmation
                    ? session.pendingImport
                    : nil
            },
            set: {
                if $0 == nil && !session.isLocked && !showSplash {
                    cancelPendingImport()
                }
            }
        )) { pending in
            ImportConfirmView(
                pending: pending,
                confirmImport: {
                    try await session.confirmImport(id: pending.id, name: $0)
                },
                cancelImport: cancelPendingImport
            ) { result in
                if case .failure(let error) = result {
                    session.importErrorMessage = RuneScribeUISession.message(for: error)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { pendingPresentation == .tutorial },
            set: { _ in }
        )) {
            TutorialView(mode: .firstRun, onComplete: completeTutorial)
        }
        .sheet(item: Binding(
            get: {
                pendingPresentation == .receivedMessage
                    ? session.pendingMessage
                    : nil
            },
            set: {
                if $0 == nil && !session.isLocked && !showSplash {
                    dismissPendingMessage()
                }
            }
        )) { pending in
            ReceivedMessageView(
                pending: pending,
                presentationBinding: session.activeReceivedCipherPresentationBinding(
                    pending: pending,
                    state: .primary,
                    relativeDate: Date(),
                    reduceMotion: accessibilityReduceMotion
                ),
                onOpenCodex: {
                    Task { @MainActor in
                        await Task.yield()
                        session.requestRoute(
                            RootReceivedMessageNavigationPolicy.openCodexRoute
                        )
                    }
                },
                onReply: { message in
                    session.requestRoute(.replyToMessage(cipherID: message.cipherID))
                }
            )
            .task(id: ReceivedCipherPresentationRequest(
                pending: pending,
                themeSnapshotRevision: session.themeSnapshot?.revision,
                state: .primary,
                reduceMotion: accessibilityReduceMotion
            )) {
                try? await session.prepareActiveReceivedCipherPresentation(
                    pending: pending,
                    state: .primary,
                    reduceMotion: accessibilityReduceMotion
                )
            }
        }
        .alert("Import Failed", isPresented: Binding(
            get: {
                RootImportFailurePresentation.shouldShowAlert(
                    message: session.importErrorMessage,
                    hasPendingImport: session.pendingImport != nil,
                    isLocked: session.isLocked,
                    showSplash: showSplash
                )
            },
            set: {
                if !$0 && !session.isLocked && !showSplash {
                    session.importErrorMessage = nil
                }
            }
        )) {
            Button("OK") { session.importErrorMessage = nil }
        } message: {
            Text(session.importErrorMessage ?? "")
        }
        .alert("Couldn't Read Message", isPresented: Binding(
            get: { session.messageErrorMessage != nil && !session.isLocked && !showSplash },
            set: {
                if !$0 && !session.isLocked && !showSplash {
                    session.messageErrorMessage = nil
                }
            }
        )) {
            Button("OK") { session.messageErrorMessage = nil }
        } message: {
            Text(session.messageErrorMessage ?? "")
        }
        .alert("Couldn't Complete", isPresented: Binding(
            get: {
                session.lastError != nil
                    && session.importErrorMessage == nil
                    && session.messageErrorMessage == nil
                    && !session.isLocked
                    && !showSplash
            },
            set: { if !$0 { session.dismissLastError() } }
        )) {
            Button("OK") { session.dismissLastError() }
        } message: {
            Text(session.lastError ?? "")
        }
        .alert("Standard Share Appearance Used", isPresented: Binding(
            get: {
                session.outboundSharePresentationStatus.userVisibleMessage != nil
                    && session.lastError == nil
                    && session.importErrorMessage == nil
                    && session.messageErrorMessage == nil
                    && !session.isLocked
                    && !showSplash
            },
            set: { if !$0 { session.dismissOutboundSharePresentationStatus() } }
        )) {
            Button("OK") { session.dismissOutboundSharePresentationStatus() }
        } message: {
            Text(session.outboundSharePresentationStatus.userVisibleMessage ?? "")
        }
        .environmentObject(session)
        .environment(
            \.runtimeApplicationResourcePresentation,
            session.resourcePresentation
        )
        .runeSimulatorAccessibilityQualification()
    }

    private var rootBackgroundAccessibilityIdentifier: String {
        let themeID = session.themeSnapshot?.effectiveTheme.id.rawValue ?? "unavailable"
        let variant = if session.themeSnapshot?.isEmergencyPresentation == true {
            "emergency"
        } else if colorSchemeContrast == .increased
                    || SimulatorAccessibilityQualification.isRequested {
            "high-contrast"
        } else {
            "standard"
        }
        return "theme.root-background.\(themeID).\(variant)"
    }

    private var rootBackgroundCaptureIdentifier: String? {
        guard session.themeSnapshot?.isEmergencyPresentation != true,
              let themeID = session.themeSnapshot?.effectiveTheme.id
        else { return nil }
        let usesIncreasedContrast = colorSchemeContrast == .increased
            || accessibilityPreferences.forcesIncreasedContrast
            || SimulatorAccessibilityQualification.isRequested
        let variant: ThemeCaptureIdentifier.BackgroundVariant
        if usesIncreasedContrast {
            variant = .highContrast
        } else {
            let effectiveReduceMotion = accessibilityReduceMotion
                || accessibilityPreferences.forcesReduceMotion
                || SimulatorAccessibilityQualification.isRequested
            variant = session.effectiveEffectsPreference(
                systemReduceMotion: effectiveReduceMotion
            ) == .reduced ? .reduceMotion : .standard
        }
        return ThemeCaptureIdentifier.background(themeID: themeID, variant: variant)
    }

    private func evaluateColdLaunchSplashIfReady() {
        guard allowsColdLaunchSplash,
              session.runtimePresentationSettingsReady,
              !didEvaluateColdLaunchSplash
        else { return }
        didEvaluateColdLaunchSplash = true
        showSplash = RuntimeSplashSchedule.shouldShow(
            resourceAvailable: session.resourcePresentation.hasSplashVideo,
            now: Date(),
            lastShownAt: session.splashLastShownAt
        )
    }

    private func cancelPendingImport() {
        guard let id = session.pendingImport?.id else { return }
        Task { await session.cancelImport(id: id) }
    }

    private func dismissPendingMessage() {
        guard let id = session.pendingMessage?.id else { return }
        Task { await session.dismissReceivedMessage(id: id) }
    }

    private func completeTutorial() {
        guard !tutorialDismissedForSession else { return }
        tutorialDismissedForSession = true
        Task {
            await session.markTutorialCompleted(
                version: RuneScribeTutorialCatalog.currentVersion
            )
        }
    }
}

private struct RequiredBaseThemeWarning: View {
    let failures: [RequiredThemeResourceFailureDTO]
    @Binding var showsDetails: Bool
    let dismiss: () -> Void

    private let accessibilityMessage =
        "Appearance resources could not be verified. Rune Scribe is using a standard emergency appearance. Your ciphers and messages remain available."

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.runeWarning)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Appearance resources could not be verified.")
                        .font(.headline)
                        .foregroundStyle(Color.runeTextPrimary)
                    Text(
                        "Rune Scribe is using a standard emergency appearance. "
                            + "Your ciphers and messages remain available."
                    )
                    .font(.subheadline)
                    .foregroundStyle(Color.runeSilver)
                }

                Spacer(minLength: 4)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss appearance warning")
            }

            Button(showsDetails ? "Hide Details" : "Details") {
                showsDetails.toggle()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: 44)
            .accessibilityHint("Shows sanitized appearance diagnostics")

            if showsDetails {
                Divider()
                if failures.isEmpty {
                    Text("No additional resource details are available.")
                        .font(.caption)
                        .foregroundStyle(Color.runeSilver)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                                RequiredBaseThemeFailureDetails(failure: failure)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .fill(Color.runeParchment)
                .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RuneMetrics.corner, style: .continuous)
                .strokeBorder(Color.runeWarning.opacity(0.65), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityMessage)
        .accessibilityIdentifier("required-base-theme-warning")
    }
}

private struct RequiredBaseThemeFailureDetails: View {
    let failure: RequiredThemeResourceFailureDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Stage: \(failure.stage.rawValue)")
            if let resourceID = failure.resourceID {
                Text("Resource: \(resourceID.rawValue)")
            }
            Text("Code: \(failure.errorCode.rawValue)")
            if let expected = failure.expectedByteCount,
               let actual = failure.actualByteCount {
                Text("Bytes: expected \(expected), received \(actual)")
            }
            if let expected = failure.expectedSHA256,
               let actual = failure.actualSHA256 {
                Text("Expected SHA-256: \(expected.rawValue)")
                Text("Received SHA-256: \(actual.rawValue)")
            }
            if let mediaType = failure.mediaType {
                Text("Media: \(mediaType.rawValue)")
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(Color.runeSilver)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}
