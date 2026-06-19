// RuneScrib/Metal/RuneMetalView.swift

import SwiftUI
import MetalKit

/// SwiftUI wrapper for the Metal animated Norse background.
/// Hosts an `MTKView` via `NSViewRepresentable` (macOS) or `UIViewRepresentable` (iOS).
struct RuneMetalView {

    func makeCoordinator() -> MetalRenderer {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MetalRenderer(device: device) else {
            fatalError("RuneScrib: Could not create MetalRenderer.")
        }
        return renderer
    }

    /// Builds and configures the MTKView. Shared by both platform representations.
    fileprivate func makeMetalView(_ coordinator: MetalRenderer) -> MTKView {
        let view = MTKView()

        guard let device = MTLCreateSystemDefaultDevice() else {
            // Metal unavailable — return a blank, statically-cleared view.
            view.clearColor = MTLClearColor(red: 0.03, green: 0.04, blue: 0.12, alpha: 1)
            return view
        }

        view.device = device
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.clearColor = MTLClearColor(red: 0.03, green: 0.04, blue: 0.12, alpha: 1)
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = coordinator
        return view
    }
}

#if os(macOS)
extension RuneMetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView { makeMetalView(context.coordinator) }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}
#elseif os(iOS)
extension RuneMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView { makeMetalView(context.coordinator) }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif
