#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    extension MultiCamCompositor {

        // MARK: - One-Shot Composite Photo Capture

        /// Renders all current camera frames into a single composited image matching the preview layout.
        /// Must be called on the main thread (UIView subclass).
        func captureCompositePhoto(outputSize: CGSize) -> PhotoCaptureClient.Photo? {
            let width = Int(outputSize.width)
            let height = Int(outputSize.height)
            guard isValidDimensions(width: width, height: height) else { return nil }

            let scene = currentScene()
            guard !scene.frames.isEmpty, !scene.viewports.isEmpty else { return nil }

            guard let allocation = allocateOffscreenTexture(width: width, height: height) else { return nil }

            guard
                renderComposite(
                    scene,
                    into: allocation.texture,
                    drawableSize: CGSize(width: width, height: height)
                )
            else { return nil }

            return makeJPEGPhoto(from: allocation.pixelBuffer, outputSize: outputSize)
        }

        /// Allocates a one-shot BGRA pixel buffer + matching Metal texture of `width` x `height`.
        private func allocateOffscreenTexture(
            width: Int,
            height: Int
        ) -> (pixelBuffer: CVPixelBuffer, texture: MTLTexture)? {
            let attrs = Self.pixelBufferAttributes(width: width, height: height)
            var pixelBuffer: CVPixelBuffer?
            let pbStatus = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                attrs as CFDictionary,
                &pixelBuffer
            )
            guard pbStatus == kCVReturnSuccess, let pixelBuffer else { return nil }

            guard let cache = Self.makeTextureCache(device: device),
                let made = makeTexture(from: pixelBuffer, cache: cache)
            else { return nil }

            // The returned pixel buffer retains the backing IOSurface, so the CVMetalTexture
            // need not outlive this call.
            return (pixelBuffer, made.texture)
        }

        /// Encodes + synchronously runs the GPU composite pass for a one-shot capture.
        private func renderComposite(
            _ scene: Scene,
            into texture: MTLTexture,
            drawableSize: CGSize
        ) -> Bool {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            descriptor.colorAttachments[0].storeAction = .store

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return false }

            let target = makeRenderTarget(encoder: encoder, drawableSize: drawableSize)
            encodeScene(scene, into: target)

            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            return true
        }

        /// Reads `_renderState` once and returns an immutable snapshot of the frames +
        /// viewports available to render. Shared by the live-draw and composite-photo paths.
        func currentScene() -> Scene {
            _renderState.withLock { Scene(frames: $0.cameraFrames, viewports: $0.viewports) }
        }

        /// Converts a rendered BGRA pixel buffer into a JPEG-backed `Photo`.
        private func makeJPEGPhoto(
            from pixelBuffer: CVPixelBuffer,
            outputSize: CGSize
        ) -> PhotoCaptureClient.Photo? {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
            let uiImage = UIImage(cgImage: cgImage)
            guard let jpegData = uiImage.jpegData(compressionQuality: Self.jpegCompressionQuality) else { return nil }

            return PhotoCaptureClient.Photo(
                fileDataRepresentation: jpegData,
                photoDimensions: outputSize,
                timestamp: .now,
                isRawPhoto: false
            )
        }

        // MARK: - Shared Viewport Encoding

        /// Builds a `RenderTarget` for `encoder`/`drawableSize`, filling its border from the
        /// compositor's current `borderWidth`/`borderColor`. Shared by the one-shot photo
        /// capture, the live preview pass, and the offscreen recording pass.
        func makeRenderTarget(
            encoder: MTLRenderCommandEncoder,
            drawableSize: CGSize
        ) -> RenderTarget {
            RenderTarget(
                encoder: encoder,
                drawableSize: drawableSize,
                border: BorderStyle(width: borderWidth, color: borderColor)
            )
        }

        /// Builds the uniforms for one viewport and encodes its draw call. Shared by the
        /// one-shot photo capture, the live preview pass, and the offscreen recording pass
        /// so the three stay byte-identical by construction.
        private func encodeViewport(
            _ viewport: LayoutEngine.CameraViewport,
            frame: CameraFrame,
            into target: RenderTarget
        ) {
            let (uvScale, uvOffset) = computeAspectFill(
                viewportRect: viewport.rect,
                drawableSize: target.drawableSize,
                textureSize: CGSize(width: frame.width, height: frame.height)
            )

            // Apply border only to non-fullscreen viewports (PiP overlays)
            let isFullscreen = isFullscreenViewport(viewport.rect)
            let effectiveBorderWidth: Float = isFullscreen ? 0 : target.border.width
            let effectiveBorderColor: SIMD4<Float> = isFullscreen ? .zero : target.border.color

            // Pixel aspect ratio: viewport pixel width / viewport pixel height
            let viewportPixelWidth = Float(viewport.rect.width) * Float(target.drawableSize.width)
            let viewportPixelHeight = Float(viewport.rect.height) * Float(target.drawableSize.height)
            let pixelAspectRatio = viewportPixelHeight > 0 ? viewportPixelWidth / viewportPixelHeight : Float(1)

            var uniforms = MultiCamUniforms(
                viewportRect: SIMD4<Float>(
                    Float(viewport.rect.origin.x),
                    Float(viewport.rect.origin.y),
                    Float(viewport.rect.size.width),
                    Float(viewport.rect.size.height)
                ),
                uvScale: uvScale,
                uvOffset: uvOffset,
                cornerRadius: Float(viewport.cornerRadius),
                borderWidth: effectiveBorderWidth,
                borderColor: effectiveBorderColor,
                pixelAspectRatio: pixelAspectRatio,
                _pad: .zero
            )

            let encoder = target.encoder
            encoder.setRenderPipelineState(cameraPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
            encoder.setFragmentTexture(frame.mtlTexture, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        /// Encodes every viewport in `scene`, sorted by zOrder, into `target`. The single
        /// shared loop body for the live preview pass, the offscreen recording pass, and
        /// the one-shot composite capture.
        func encodeScene(
            _ scene: Scene,
            into target: RenderTarget
        ) {
            for viewport in scene.viewports.sorted(by: { $0.zOrder < $1.zOrder }) {
                guard let frame = scene.frames[viewport.cameraID] else { continue }
                encodeViewport(viewport, frame: frame, into: target)
            }
        }

        /// A viewport whose normalized width AND height are both at/above `fullscreenThreshold`.
        private func isFullscreenViewport(_ rect: CGRect) -> Bool {
            rect.width >= Self.fullscreenThreshold && rect.height >= Self.fullscreenThreshold
        }

        /// Both dimensions must be strictly positive to be a valid pixel/texture size.
        private func isValidDimensions(
            width: Int,
            height: Int
        ) -> Bool {
            width > 0 && height > 0
        }

        // MARK: - Aspect-Fill for a Viewport

        private func computeAspectFill(
            viewportRect: CGRect,
            drawableSize: CGSize,
            textureSize: CGSize
        ) -> (uvScale: SIMD2<Float>, uvOffset: SIMD2<Float>) {
            guard isValidDimensions(width: Int(textureSize.width), height: Int(textureSize.height)) else {
                return (SIMD2<Float>(1, 1), SIMD2<Float>(0, 0))
            }

            let vpAspect =
                Float(viewportRect.width * drawableSize.width) / Float(viewportRect.height * drawableSize.height)
            let texAspect = Float(textureSize.width) / Float(textureSize.height)

            var scaleX: Float = 1.0
            var scaleY: Float = 1.0

            if texAspect > vpAspect {
                scaleX = vpAspect / texAspect
            } else {
                scaleY = texAspect / vpAspect
            }

            let offsetX = (1.0 - scaleX) * 0.5
            let offsetY = (1.0 - scaleY) * 0.5

            return (SIMD2<Float>(scaleX, scaleY), SIMD2<Float>(offsetX, offsetY))
        }

        // MARK: - Offscreen Recording Encode

        /// Encodes the offscreen (recording) composite pass into `commandBuffer` when a
        /// recording session is active, and hands the finished pixel buffer to
        /// `onRecordingFrame` on command-buffer completion. No-op otherwise.
        func encodeOffscreenRecordingIfNeeded(
            commandBuffer: MTLCommandBuffer,
            scene: Scene
        ) {
            guard _isRecording.withLock({ $0 }),
                let pool = recordingPixelBufferPool,
                let recordingTextureCache,
                let callback = onRecordingFrame
            else { return }

            var pixelBuffer: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
            guard status == kCVReturnSuccess, let recordedPixelBuffer = pixelBuffer else { return }

            let width = CVPixelBufferGetWidth(recordedPixelBuffer)
            let height = CVPixelBufferGetHeight(recordedPixelBuffer)

            // `recordedPixelBuffer` is retained by the completion handler below, so it holds the
            // backing IOSurface; the CVMetalTexture need not outlive this call.
            guard let made = makeTexture(from: recordedPixelBuffer, cache: recordingTextureCache)
            else { return }

            let offscreenDescriptor = MTLRenderPassDescriptor()
            offscreenDescriptor.colorAttachments[0].texture = made.texture
            offscreenDescriptor.colorAttachments[0].loadAction = .clear
            offscreenDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            offscreenDescriptor.colorAttachments[0].storeAction = .store

            // Encode offscreen pass into the SAME command buffer
            if let offscreenEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenDescriptor) {
                let offscreenSize = CGSize(width: width, height: height)
                let target = makeRenderTarget(encoder: offscreenEncoder, drawableSize: offscreenSize)
                encodeScene(scene, into: target)
                offscreenEncoder.endEncoding()
            }

            commandBuffer.addCompletedHandler { _ in
                callback(
                    recordedPixelBuffer,
                    CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000)
                )
            }
        }

        // MARK: - Histogram

        /// The texture the histogram measures — the fullscreen (primary) camera when present,
        /// otherwise the first viewport. Nil until a camera has delivered a frame.
        func primaryCameraTexture(
            frames: [MultiCamClient.CameraID: CameraFrame],
            sortedViewports: [LayoutEngine.CameraViewport]
        ) -> MTLTexture? {
            let fullscreen = sortedViewports.first { isFullscreenViewport($0.rect) }
            guard let cameraID = (fullscreen ?? sortedViewports.first)?.cameraID else { return nil }
            return frames[cameraID]?.mtlTexture
        }

        /// Recomputes the histogram at most every `histogramComputeInterval`, onto `commandBuffer`
        /// before the render pass. Runs on the main thread inside `draw(in:)`.
        func maybeComputeHistogram(
            _ overlay: Histogram.Overlay,
            from texture: MTLTexture,
            in commandBuffer: MTLCommandBuffer
        ) {
            let now = CACurrentMediaTime()
            guard now - lastHistogramComputeTime >= histogramComputeInterval else { return }
            lastHistogramComputeTime = now
            overlay.encodeCompute(texture: texture, in: commandBuffer, config: histogramConfig)
        }
    }
#endif
