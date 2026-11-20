#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import PhotoCaptureClient
    import os

    /// The Metal objects the renderer owns, grouped so the factory hands them to `init` as one value.
    struct Resources {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let textureCache: CVMetalTextureCache
        let cameraPipeline: MTLRenderPipelineState
        let boxPipeline: MTLRenderPipelineState
        let boxVertexBuffer: MTLBuffer
        let histogramOverlay: Histogram.Overlay?
        let channelGainPipeline: MTLComputePipelineState?
        let textPipeline: MTLRenderPipelineState?
    }

    // MARK: - Metal Setup

    extension MetalPreviewRenderer {

        /// Factory method — returns nil if Metal is unavailable.
        static func create() -> MetalPreviewRenderer? {
            guard let device = MTLCreateSystemDefaultDevice(),
                let commandQueue = device.makeCommandQueue()
            else {
                return nil
            }

            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &cache
            )
            guard status == kCVReturnSuccess, let textureCache = cache else {
                return nil
            }

            guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
                return nil
            }

            let cameraDescriptor = MTLRenderPipelineDescriptor()
            cameraDescriptor.vertexFunction = library.makeFunction(name: "cameraVertex")
            cameraDescriptor.fragmentFunction = library.makeFunction(name: "cameraFragment")
            cameraDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let cameraPipeline = try? device.makeRenderPipelineState(descriptor: cameraDescriptor) else {
                return nil
            }

            // Box pipeline with alpha blending
            let boxDescriptor = MTLRenderPipelineDescriptor()
            boxDescriptor.vertexFunction = library.makeFunction(name: "boxVertex")
            boxDescriptor.fragmentFunction = library.makeFunction(name: "boxFragment")
            boxDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            boxDescriptor.colorAttachments[0].isBlendingEnabled = true
            boxDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            boxDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            boxDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            boxDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            guard let boxPipeline = try? device.makeRenderPipelineState(descriptor: boxDescriptor) else {
                return nil
            }

            let bufferSize = maxBoxVertices * MemoryLayout<BoxVertex>.stride
            guard let boxVertexBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
                return nil
            }

            // Optional: the preview still runs if the histogram pipelines fail to build.
            let histogramOverlay = Histogram.Overlay.create(device: device)

            // Optional: the preview still runs (unfiltered) if the gain pipeline fails to build.
            let channelGainPipeline = library.makeFunction(name: "applyChannelGain")
                .flatMap { try? device.makeComputePipelineState(function: $0) }

            // Optional: the preview still runs, without text overlays, if the text pipeline fails to build.
            let textPipeline = makeTextPipeline(device: device, library: library)

            return MetalPreviewRenderer(
                resources: Resources(
                    device: device,
                    commandQueue: commandQueue,
                    textureCache: textureCache,
                    cameraPipeline: cameraPipeline,
                    boxPipeline: boxPipeline,
                    boxVertexBuffer: boxVertexBuffer,
                    histogramOverlay: histogramOverlay,
                    channelGainPipeline: channelGainPipeline,
                    textPipeline: textPipeline
                )
            )
        }

        /// Premultiplied blending: the text fragment already scales color by coverage and opacity.
        private static func makeTextPipeline(
            device: MTLDevice,
            library: MTLLibrary
        ) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "textVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "textFragment")
            let attachment = descriptor.colorAttachments[0]
            attachment?.pixelFormat = .bgra8Unorm
            attachment?.isBlendingEnabled = true
            attachment?.sourceRGBBlendFactor = .one
            attachment?.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment?.sourceAlphaBlendFactor = .one
            attachment?.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }
#endif
