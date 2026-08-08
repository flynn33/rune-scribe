import SwiftUI

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
            initialValue: SplashAsset.shouldShow(videoURL: session.splashVideoURL)
        )
    }

    var body: some View {
        ZStack {
            ContentView()

            if session.isLocked {
                LockView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showSplash, let splashVideoURL = session.splashVideoURL {
                VideoSplashView(videoURL: splashVideoURL) {
                    SplashAsset.markShown()
                    withAnimation(.easeInOut(duration: 0.45)) { showSplash = false }
                }
                .transition(.opacity)
                .zIndex(2)
                .ignoresSafeArea()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.isLocked)
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
                    session.importErrorMessage = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
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
            get: { session.importErrorMessage != nil && !session.isLocked && !showSplash },
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
        .environmentObject(session)
        .environment(\.runeScribeMetalLibraryURL, session.metalLibraryURL)
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
