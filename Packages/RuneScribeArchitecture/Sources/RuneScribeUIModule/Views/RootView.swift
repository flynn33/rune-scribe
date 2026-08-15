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

/// Hosts the main interface and overlays the lock screen whenever the app is
/// locked. The Core lifecycle path re-locks on background, while this view plays
/// the launch splash on a cold start when the 30-day intro schedule allows.
struct RootView: View {
    @ObservedObject private var session: RuneScribeUISession

    /// Created once with the process-owned session, so a background/foreground
    /// transition never re-evaluates the cold-launch splash schedule.
    @State private var showSplash: Bool

    init(session: RuneScribeUISession) {
        self.session = session
        _showSplash = State(
            initialValue: RuntimeSplashSchedule.shouldShow(
                resourceAvailable: session.resourcePresentation.hasSplashVideo
            )
        )
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
        )
    }

    var body: some View {
        ZStack {
            ContentView()

            if let reveal = session.activeReveal,
               !revealIsBlockedAtRoot {
                UnlockRevealView(reveal: reveal)
                    .zIndex(0.5)
            }

            if session.isLocked {
                LockView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showSplash {
                session.resourcePresentation.makeSplashView {
                    RuntimeSplashSchedule.markShown()
                    withAnimation(.easeInOut(duration: 0.45)) { showSplash = false }
                }
                .transition(.opacity)
                .zIndex(2)
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isLocked)
        .onChange(of: revealIsBlockedAtRoot, initial: true) { _, isBlocked in
            session.setRevealBlocker(.rootPresentation, active: isBlocked)
        }
        .sheet(item: Binding(
            get: { (showSplash || session.isLocked) ? nil : session.pendingImport },
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
        .sheet(item: Binding(
            get: { (showSplash || session.isLocked) ? nil : session.pendingMessage },
            set: {
                if $0 == nil && !session.isLocked && !showSplash {
                    dismissPendingMessage()
                }
            }
        )) { pending in
            ReceivedMessageView(pending: pending) { message in
                session.requestRoute(.replyToMessage(cipherID: message.cipherID))
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
        .environmentObject(session)
        .environment(
            \.runtimeApplicationResourcePresentation,
            session.resourcePresentation
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
}
