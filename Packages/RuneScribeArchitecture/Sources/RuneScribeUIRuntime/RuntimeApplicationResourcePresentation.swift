import AVFoundation
import Foundation
import Metal
import MetalKit
@_spi(RuntimeResourceHost) import RuneScribeRuntimeCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private final class RuntimeNotificationObserver: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func cancel() {
        NotificationCenter.default.removeObserver(token)
    }

    deinit {
        cancel()
    }
}

@MainActor
public final class RuntimeApplicationResourcePresentation: ObservableObject {
    private let splashVideoSession: RuntimeApplicationResourceSession?
    private let metalLibrarySession: RuntimeApplicationResourceSession?

    @Published internal private(set) var splashPlayer: AVPlayer?
    @Published internal private(set) var metalResource: RuntimeMetalResource?

    private var splashLease: RuntimeApplicationResourceLease?
    private var metalLease: RuntimeApplicationResourceLease?
    private var splashEventTask: Task<Void, Never>?
    private var metalEventTask: Task<Void, Never>?
    private var splashFallbackTask: Task<Void, Never>?
    private var splashEndObserver: RuntimeNotificationObserver?
    private var splashFinishCallback: (@MainActor () -> Void)?
    private var splashIsStarting = false
    private var metalIsStarting = false
    private var splashDidFinish = false
    private var isClosed = false

    public init(
        splashVideo: RuntimeApplicationResourceSession?,
        metalLibrary: RuntimeApplicationResourceSession?
    ) {
        splashVideoSession = splashVideo
        metalLibrarySession = metalLibrary
    }

    public var hasSplashVideo: Bool {
        splashVideoSession != nil && !isClosed
    }

    public func makeSplashView(
        onFinish: @escaping @MainActor () -> Void
    ) -> AnyView {
        AnyView(
            RuntimeSplashPresentationView(
                presentation: self,
                onFinish: onFinish
            )
        )
    }

    public func makeMetalView() -> AnyView {
        AnyView(RuntimeMetalPresentationView(presentation: self))
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        let splashLease = clearSplashPresentation()
        let metalLease = clearMetalPresentation()
        await splashLease?.close()
        await metalLease?.close()
    }

    deinit {
        splashEventTask?.cancel()
        metalEventTask?.cancel()
        splashFallbackTask?.cancel()
    }

    func startSplash(
        onFinish: @escaping @MainActor () -> Void
    ) async {
        guard !isClosed, let splashVideoSession else {
            onFinish()
            return
        }
        guard splashPlayer == nil, !splashIsStarting, !splashDidFinish else {
            return
        }
        splashIsStarting = true
        splashFinishCallback = onFinish

        do {
            let lease = try await splashVideoSession.acquire()
            try Task.checkCancellation()
            guard !isClosed else {
                await lease.close()
                return
            }

            let player = AVPlayer(url: lease.url)
            player.actionAtItemEnd = .pause
            splashLease = lease
            splashPlayer = player
            let events = await lease.events()
            splashEventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard event == .revoked else { continue }
                    self?.finishSplash()
                }
            }
            configureAudioSession()
            let splashEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishSplash()
                }
            }
            self.splashEndObserver = RuntimeNotificationObserver(
                token: splashEndObserver
            )
            player.play()
            splashFallbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.finishSplash()
            }
        } catch is CancellationError {
            splashFinishCallback = nil
        } catch {
            finishSplash()
        }
        splashIsStarting = false
    }

    var splashIsActive: Bool {
        splashPlayer != nil && !splashDidFinish
    }

    func finishSplash() {
        guard !splashDidFinish else { return }
        splashDidFinish = true
        let callback = splashFinishCallback
        let lease = clearSplashPresentation()
        if let lease {
            Task {
                await lease.close()
            }
        }
        callback?()
    }

    func startMetal() async {
        guard !isClosed,
              metalResource == nil,
              !metalIsStarting,
              let metalLibrarySession
        else { return }
        metalIsStarting = true
        defer { metalIsStarting = false }

        do {
            let lease = try await metalLibrarySession.acquire()
            try Task.checkCancellation()
            guard !isClosed,
                  let device = MTLCreateSystemDefaultDevice(),
                  let library = try? device.makeLibrary(URL: lease.url)
            else {
                await lease.close()
                return
            }

            metalLease = lease
            metalResource = RuntimeMetalResource(device: device, library: library)
            let events = await lease.events()
            metalEventTask = Task { @MainActor [weak self] in
                for await event in events {
                    guard event == .revoked else { continue }
                    self?.stopMetal()
                }
            }
        } catch {
            // Missing or revoked optional presentation resources degrade to a static header.
        }
    }

    private func clearSplashPresentation() -> RuntimeApplicationResourceLease? {
        splashEventTask?.cancel()
        splashEventTask = nil
        splashFallbackTask?.cancel()
        splashFallbackTask = nil
        splashEndObserver?.cancel()
        splashEndObserver = nil
        splashPlayer?.pause()
        splashPlayer?.replaceCurrentItem(with: nil)
        splashPlayer = nil
        splashFinishCallback = nil
        let lease = splashLease
        splashLease = nil
        return lease
    }

    private func clearMetalPresentation() -> RuntimeApplicationResourceLease? {
        metalEventTask?.cancel()
        metalEventTask = nil
        metalResource = nil
        let lease = metalLease
        metalLease = nil
        return lease
    }

    private func stopMetal() {
        let lease = clearMetalPresentation()
        if let lease {
            Task {
                await lease.close()
            }
        }
    }

    private func configureAudioSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(
            .ambient,
            options: [.mixWithOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
    }
}

private struct RuntimeApplicationResourcePresentationKey: EnvironmentKey {
    static let defaultValue: RuntimeApplicationResourcePresentation? = nil
}

public extension EnvironmentValues {
    var runtimeApplicationResourcePresentation: RuntimeApplicationResourcePresentation? {
        get { self[RuntimeApplicationResourcePresentationKey.self] }
        set { self[RuntimeApplicationResourcePresentationKey.self] = newValue }
    }
}

public struct RuntimeMetalBackground: View {
    @Environment(\.runtimeApplicationResourcePresentation)
    private var presentation

    public init() {}

    public var body: some View {
        Group {
            if let presentation {
                presentation.makeMetalView()
            } else {
                Color(red: 0.031, green: 0.039, blue: 0.118)
            }
        }
    }
}

private struct RuntimeSplashPresentationView: View {
    @ObservedObject var presentation: RuntimeApplicationResourcePresentation
    let onFinish: @MainActor () -> Void
    @State private var showSkip = false

    var body: some View {
        ZStack {
            Color(red: 0.031, green: 0.039, blue: 0.118)
                .ignoresSafeArea()

            if let player = presentation.splashPlayer {
                RuntimeSplashVideoSurface(player: player)
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()
                if showSkip, presentation.splashIsActive {
                    Button {
                        presentation.finishSplash()
                    } label: {
                        Text("Skip")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .tracking(1.5)
                            .foregroundStyle(Color(red: 0.031, green: 0.039, blue: 0.118))
                            .padding(.horizontal, 22)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(
                                    Color(red: 0.831, green: 0.592, blue: 0.102)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 44)
                    .transition(.opacity)
                    .accessibilityLabel("Skip intro")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            presentation.finishSplash()
        }
        .task {
            await presentation.startSplash(onFinish: onFinish)
            guard presentation.splashIsActive else { return }
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, presentation.splashIsActive else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showSkip = true
            }
        }
    }
}

private struct RuntimeSplashVideoSurface {
    let player: AVPlayer
}

#if os(iOS)
extension RuntimeSplashVideoSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> RuntimeSplashHostView {
        RuntimeSplashHostView(player: player)
    }

    func updateUIView(_ uiView: RuntimeSplashHostView, context: Context) {}

    static func dismantleUIView(_ uiView: RuntimeSplashHostView, coordinator: ()) {
        uiView.detachPlayer()
    }
}

private final class RuntimeSplashHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .clear
        playerLayer?.player = player
        playerLayer?.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func detachPlayer() {
        playerLayer?.player = nil
    }
}
#elseif os(macOS)
extension RuntimeSplashVideoSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> RuntimeSplashHostView {
        RuntimeSplashHostView(player: player)
    }

    func updateNSView(_ nsView: RuntimeSplashHostView, context: Context) {}

    static func dismantleNSView(_ nsView: RuntimeSplashHostView, coordinator: ()) {
        nsView.detachPlayer()
    }
}

private final class RuntimeSplashHostView: NSView {
    private let playerLayer = AVPlayerLayer()

    init(player: AVPlayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(playerLayer)
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    func detachPlayer() {
        playerLayer.player = nil
    }
}
#endif

private struct RuntimeMetalPresentationView: View {
    @ObservedObject var presentation: RuntimeApplicationResourcePresentation

    var body: some View {
        Group {
            if let resource = presentation.metalResource {
                RuntimeMetalSurface(resource: resource)
                    .id(ObjectIdentifier(resource))
            } else {
                Color(red: 0.031, green: 0.039, blue: 0.118)
            }
        }
        .task {
            await presentation.startMetal()
        }
    }
}

@MainActor
final class RuntimeMetalResource {
    let device: MTLDevice
    let library: MTLLibrary

    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }
}

private struct RuntimeFragmentUniforms {
    var time: Float
    var resolutionX: Float
    var resolutionY: Float
    var padding: Float = 0
}

@MainActor
private final class RuntimeMetalRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var uniformsBuffer: MTLBuffer?
    private let startDate = Date()

    init?(resource: RuntimeMetalResource) {
        guard let commandQueue = resource.device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = commandQueue
        super.init()

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "RuneBackground"
        descriptor.vertexFunction = resource.library.makeFunction(name: "vertex_fullscreen")
        descriptor.fragmentFunction = resource.library.makeFunction(name: "fragment_rune_background")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? resource.device.makeRenderPipelineState(descriptor: descriptor)
        uniformsBuffer = resource.device.makeBuffer(
            length: MemoryLayout<RuntimeFragmentUniforms>.stride,
            options: .storageModeShared
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipelineState,
              let uniformsBuffer,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let encoder = commandBuffer.makeRenderCommandEncoder(
                  descriptor: renderPassDescriptor
              ),
              let drawable = view.currentDrawable
        else { return }

        var uniforms = RuntimeFragmentUniforms(
            time: Float(Date().timeIntervalSince(startDate)),
            resolutionX: Float(view.drawableSize.width),
            resolutionY: Float(view.drawableSize.height)
        )
        memcpy(
            uniformsBuffer.contents(),
            &uniforms,
            MemoryLayout<RuntimeFragmentUniforms>.stride
        )
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip,
            vertexStart: 0,
            vertexCount: 4
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private struct RuntimeMetalSurface {
    let resource: RuntimeMetalResource

    @MainActor
    func makeCoordinator() -> RuntimeMetalRenderer? {
        RuntimeMetalRenderer(resource: resource)
    }

    @MainActor
    fileprivate func makeMetalView(
        _ coordinator: RuntimeMetalRenderer?
    ) -> MTKView {
        let view = MTKView(frame: .zero, device: resource.device)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(
            red: 0.03,
            green: 0.04,
            blue: 0.12,
            alpha: 1
        )
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = coordinator
        return view
    }

    @MainActor
    fileprivate static func dismantle(_ view: MTKView) {
        view.isPaused = true
        view.delegate = nil
        view.device = nil
    }
}

#if os(macOS)
extension RuntimeMetalSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        makeMetalView(context.coordinator)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    static func dismantleNSView(_ nsView: MTKView, coordinator: RuntimeMetalRenderer?) {
        dismantle(nsView)
    }
}
#elseif os(iOS)
extension RuntimeMetalSurface: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        makeMetalView(context.coordinator)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: RuntimeMetalRenderer?) {
        dismantle(uiView)
    }
}
#endif
