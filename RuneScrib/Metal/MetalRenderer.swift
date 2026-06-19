// RuneScrib/Metal/MetalRenderer.swift

import Foundation
import Metal
import MetalKit

// MARK: - FragmentUniforms (must match Shaders.metal)

struct FragmentUniforms {
    var time: Float
    var resolutionX: Float
    var resolutionY: Float
    var padding: Float = 0   // align to 16 bytes
}

// MARK: - MetalRenderer

/// MTKViewDelegate that drives the animated Norse background shader.
final class MetalRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal Objects

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var uniformsBuffer: MTLBuffer?

    // MARK: - Timing

    private let startDate = Date()

    // MARK: - Init

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        super.init()

        buildPipeline()
        uniformsBuffer = device.makeBuffer(
            length: MemoryLayout<FragmentUniforms>.stride,
            options: .storageModeShared
        )
    }

    // MARK: - Pipeline Setup

    private func buildPipeline() {
        guard let library = device.makeDefaultLibrary() else {
            print("RuneScrib: Metal default library not found.")
            return
        }
        guard let vertexFn   = library.makeFunction(name: "vertex_fullscreen"),
              let fragmentFn = library.makeFunction(name: "fragment_rune_background") else {
            print("RuneScrib: Metal shader functions not found.")
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label                              = "RuneBackground"
        descriptor.vertexFunction                     = vertexFn
        descriptor.fragmentFunction                   = fragmentFn
        descriptor.colorAttachments[0].pixelFormat    = .bgra8Unorm

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("RuneScrib: Pipeline state creation failed: \(error)")
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing needed — size is passed via uniforms each frame.
    }

    func draw(in view: MTKView) {
        guard
            let pipelineState,
            let uniformsBuffer,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
            let drawable = view.currentDrawable
        else { return }

        // Update uniforms
        let elapsed = Float(Date().timeIntervalSince(startDate))
        let drawSize = view.drawableSize
        var uniforms = FragmentUniforms(
            time: elapsed,
            resolutionX: Float(drawSize.width),
            resolutionY: Float(drawSize.height)
        )
        memcpy(uniformsBuffer.contents(), &uniforms, MemoryLayout<FragmentUniforms>.stride)

        // Encode draw call: full-screen quad (triangle strip, 4 vertices)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
