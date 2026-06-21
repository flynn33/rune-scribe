// RuneScrib/Views/Components/VideoSplashView.swift

import SwiftUI
import AVFoundation

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The bundled splash video, or nil if the asset is missing (in which case the
/// app skips the splash entirely).
enum SplashAsset {
    static let url = Bundle.main.url(forResource: "raven-forge-spp-splash", withExtension: "mp4")
}

// MARK: - Playback model

/// Owns the splash `AVPlayer` and reports exactly once when playback should end —
/// whether it finished, was skipped, or hit the safety timeout. Main-actor
/// isolated so all state and the SwiftUI callback are touched safely under Swift 6.
@MainActor
final class SplashModel: ObservableObject {

    let player: AVPlayer

    private var onFinish: (() -> Void)?
    private var endObserver: NSObjectProtocol?
    private var fallback: Task<Void, Never>?
    private var finished = false

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
    }

    /// Begins playback and arranges to call `onFinish` once. Safe to call repeatedly.
    func start(onFinish: @escaping () -> Void) {
        guard !finished, self.onFinish == nil else { return }
        self.onFinish = onFinish

        configureAudioSession()

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }

        player.play()

        // Safety net: never trap the user behind the splash if the item never
        // reports completion (e.g. a decode/playback failure).
        fallback = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            self?.finish()
        }
    }

    /// Ends the splash. Idempotent — the first call wins; later ones are ignored.
    func finish() {
        guard !finished else { return }
        finished = true
        player.pause()
        fallback?.cancel()
        fallback = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        let callback = onFinish
        onFinish = nil
        callback?()
    }

    private func configureAudioSession() {
        #if os(iOS)
        // Ambient mixes with other audio and honours the silent switch, so the
        // splash soundtrack never hijacks the user's music or rings out on silent.
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

// MARK: - Video surface (controls-free, aspect-fit)

/// A bare `AVPlayerLayer` surface — no transport controls — that fits the (square)
/// video inside its bounds. Cross-platform via UIView/NSView.
struct SplashVideoSurface {
    let player: AVPlayer
}

#if os(iOS)
extension SplashVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> SplashHostView { SplashHostView(player: player) }
    func updateUIView(_ uiView: SplashHostView, context: Context) {}
}

final class SplashHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .clear
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#elseif os(macOS)
extension SplashVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> SplashHostView { SplashHostView(player: player) }
    func updateNSView(_ nsView: SplashHostView, context: Context) {}
}

final class SplashHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif

// MARK: - Splash view

/// Full-screen launch splash that plays the bundled video once over the app's
/// navy, then calls `onFinish`. Tapping anywhere — or the Skip button that fades
/// in shortly after — dismisses it early.
struct VideoSplashView: View {

    @StateObject private var model: SplashModel
    private let onFinish: () -> Void
    @State private var showSkip = false

    init(videoURL: URL, onFinish: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SplashModel(url: videoURL))
        self.onFinish = onFinish
    }

    var body: some View {
        ZStack {
            Color.runeNavy.ignoresSafeArea()

            SplashVideoSurface(player: model.player)
                .ignoresSafeArea()

            VStack {
                Spacer()
                if showSkip {
                    Button { model.finish() } label: {
                        Text("Skip")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundColor(.runeNavy)
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.runeGold))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                    .accessibilityLabel("Skip intro")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.finish() }
        .task {
            model.start(onFinish: onFinish)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { showSkip = true }
        }
    }
}
