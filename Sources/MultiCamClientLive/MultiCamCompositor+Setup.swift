#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    // MARK: - Metal / CoreVideo Setup

    extension MultiCamCompositor {

        static func create() -> MultiCamCompositor? {
            guard let device = MTLCreateSystemDefaultDevice(),
                let commandQueue = device.makeCommandQueue()
            else {
                return nil
            }

            guard let textureCache = Self.makeTextureCache(device: device) else {
                return nil
            }

            guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
                return nil
            }

            let cameraDescriptor = MTLRenderPipelineDescriptor()
            cameraDescriptor.vertexFunction = library.makeFunction(name: "multiCamVertex")
            cameraDescriptor.fragmentFunction = library.makeFunction(name: "multiCamFragment")
            cameraDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            guard let cameraPipeline = try? device.makeRenderPipelineState(descriptor: cameraDescriptor) else {
                return nil
            }

            // Optional: the compositor still runs if the histogram pipelines fail to build.
            let histogramOverlay = Histogram.Overlay.create(device: device)

            return MultiCamCompositor(
                resources: Resources(
                    device: device,
                    commandQueue: commandQueue,
                    textureCache: textureCache,
                    cameraPipeline: cameraPipeline,
                    histogramOverlay: histogramOverlay
                )
            )
        }

        /// Creates + unwraps a `CVMetalTextureCache` for `device`, or nil on failure. Shared
        /// by `create()`, `configureRecordingOutput`, and `allocateOffscreenTexture`.
        static func makeTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard status == kCVReturnSuccess else { return nil }
            return cache
        }

        /// Zero-copy BGRA Metal texture over `pixelBuffer`. Returns the `CVMetalTexture` too: the
        /// `MTLTexture` is only valid while it (or the pixel buffer's IOSurface) stays alive, so
        /// the caller keeps whichever outlives the other.
        func makeTexture(
            from pixelBuffer: CVPixelBuffer,
            cache: CVMetalTextureCache
        ) -> (cvTexture: CVMetalTexture, texture: MTLTexture)? {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                cache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )
            guard status == kCVReturnSuccess, let cvTex = cvTexture,
                let texture = CVMetalTextureGetTexture(cvTex)
            else { return nil }
            return (cvTex, texture)
        }

        /// The CVPixelBuffer attributes dictionary shared by the recording pool and the
        /// one-shot photo-capture buffer.
        static func pixelBufferAttributes(
            width: Int,
            height: Int
        ) -> [String: Any] {
            [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
        }
    }
#endif
