#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import PhotoCaptureClient
    import os

    // MARK: - Aspect-Fill Uniforms (matches Metal struct layout)

    /// Must match `AspectFillUniforms` in Shaders.metal exactly.
    private struct AspectFillUniforms {
        var uvScale: SIMD2<Float>
        var uvOffset: SIMD2<Float>
        var zoomFactor: Float
        var _pad: Float
        var zoomAnchor: SIMD2<Float>
    }

    // MARK: - Box Vertex (matches Metal struct layout)

    /// Must match `BoxVertex` in Shaders.metal exactly.
    /// `color` (SIMD4, 16-byte aligned) is first so there is no padding between fields.
    private struct BoxVertex {
        var color: SIMD4<Float>
        var position: SIMD2<Float>
        /// Position within the box in pixels, relative to its center (for the SDF border).
        var localPos: SIMD2<Float>
        /// Box half-extent in pixels.
        var halfSize: SIMD2<Float>
        /// x = corner radius (px), y = border width (px).
        var params: SIMD2<Float>
    }

    /// Wrapper to make CVMetalTexture + MTLTexture pair Sendable for use in OSAllocatedUnfairLock.
    private struct CameraFrame: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let mtlTexture: MTLTexture
    }

    /// Metal-backed camera preview that renders CVPixelBuffers using the display link
    /// and supports bounding box overlay drawing for object detection results.
    final class MetalPreviewRenderer: UIView, @unchecked Sendable {

        // MARK: - Metal State

        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let textureCache: CVMetalTextureCache
        private let mtkView: MTKView

        /// Overlay that draws detection labels (class name + confidence) above the Metal preview.
        private let labelOverlayView = DetectionLabelOverlayView()

        // Render pipelines
        private let cameraPipeline: MTLRenderPipelineState
        private let boxPipeline: MTLRenderPipelineState

        // Reusable vertex buffer for bounding box overlays (avoids per-frame allocation).
        // Each box is one quad (2 triangles = 6 vertices); 800 vertices ≈ 133 boxes.
        private let maxBoxVertices = 800
        private let boxVertexBuffer: MTLBuffer

        /// Bounding-box border thickness in points. The border is drawn as a rounded-rectangle
        /// ring in the fragment shader (Metal `.line` primitives are 1px hairlines with no width).
        private let boxBorderWidth: CGFloat = 3

        /// Bounding-box corner radius in points. 0 = sharp corners.
        private let boxCornerRadius: CGFloat = 8

        // MARK: - Frame State

        /// Latest camera frame — stores both CVMetalTexture (to retain backing IOSurface) and MTLTexture (for rendering).
        /// CVMetalTextureGetTexture returns a texture only valid while the CVMetalTexture is alive,
        /// so we must retain the CVMetalTexture until the next frame replaces it.
        private let _currentFrame = OSAllocatedUnfairLock<CameraFrame?>(initialState: nil)

        /// Texture dimensions for aspect-fill computation.
        private let _textureSize = OSAllocatedUnfairLock<SIMD2<Float>>(initialState: .zero)

        /// Current overlay rectangles — written from any thread, read from main thread.
        private let _overlays = OSAllocatedUnfairLock<[PhotoCaptureClient.OverlayRect]>(initialState: [])

        /// Dirty flag — set by enqueueFrame, cleared by draw. Prevents redundant draws.
        private let _needsDraw = OSAllocatedUnfairLock<Bool>(initialState: false)

        // MARK: - Visual Zoom State

        /// Visual zoom state — set externally by the actor, read during draw. Thread-safe.
        private let _visualZoom = OSAllocatedUnfairLock<(factor: Float, anchorX: Float, anchorY: Float)>(
            initialState: (factor: 1.0, anchorX: 0.5, anchorY: 0.5)
        )

        /// Back-reference to PreviewView for syncing aspect-fill and zoom values to consumers.
        weak var previewViewRef: PhotoCaptureClient.PreviewView?

        /// Aspect-fill uniforms — recomputed when drawable size or texture size changes.
        private var aspectFillUniforms = AspectFillUniforms(
            uvScale: SIMD2<Float>(1, 1),
            uvOffset: SIMD2<Float>(0, 0),
            zoomFactor: 1.0,
            _pad: 0,
            zoomAnchor: SIMD2<Float>(0.5, 0.5)
        )
        private var lastTextureSize: SIMD2<Float> = .zero

        // MARK: - Init

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

            // Camera pipeline
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

            let bufferSize = 800 * MemoryLayout<BoxVertex>.stride
            guard let boxVertexBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
                return nil
            }

            return MetalPreviewRenderer(
                device: device,
                commandQueue: commandQueue,
                textureCache: textureCache,
                cameraPipeline: cameraPipeline,
                boxPipeline: boxPipeline,
                boxVertexBuffer: boxVertexBuffer
            )
        }

        private init(
            device: MTLDevice,
            commandQueue: MTLCommandQueue,
            textureCache: CVMetalTextureCache,
            cameraPipeline: MTLRenderPipelineState,
            boxPipeline: MTLRenderPipelineState,
            boxVertexBuffer: MTLBuffer
        ) {
            self.device = device
            self.commandQueue = commandQueue
            self.textureCache = textureCache
            self.cameraPipeline = cameraPipeline
            self.boxPipeline = boxPipeline
            self.boxVertexBuffer = boxVertexBuffer

            let mtkView = MTKView()
            mtkView.device = device
            mtkView.framebufferOnly = true
            mtkView.colorPixelFormat = .bgra8Unorm
            // On-demand rendering: only draw when a new frame arrives via setNeedsDisplay()
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            self.mtkView = mtkView

            super.init(frame: .zero)

            mtkView.delegate = self
            addSubview(mtkView)
            mtkView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                mtkView.topAnchor.constraint(equalTo: topAnchor),
                mtkView.bottomAnchor.constraint(equalTo: bottomAnchor),
                mtkView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mtkView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            // Label overlay sits above the Metal view, pinned to the same bounds.
            labelOverlayView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(labelOverlayView)
            NSLayoutConstraint.activate([
                labelOverlayView.topAnchor.constraint(equalTo: topAnchor),
                labelOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
                labelOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
                labelOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])

            NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                CVMetalTextureCacheFlush(self.textureCache, 0)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - Visual Zoom API

        /// Set visual zoom from the actor. Triggers a redraw.
        func setVisualZoom(
            factor: Float,
            anchorX: Float,
            anchorY: Float
        ) {
            _visualZoom.withLock { $0 = (factor: factor, anchorX: anchorX, anchorY: anchorY) }
            previewViewRef?.visualZoomFactor = factor
            previewViewRef?.visualZoomAnchorX = anchorX
            previewViewRef?.visualZoomAnchorY = anchorY
            _needsDraw.withLock { $0 = true }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.mtkView.setNeedsDisplay()
                self.labelOverlayView.update(transform: self.currentOverlayTransform())
            }
        }

        /// Reset zoom to default (e.g., on camera switch).
        func resetVisualZoom() {
            setVisualZoom(factor: 1.0, anchorX: 0.5, anchorY: 0.5)
        }

        // MARK: - Public API

        /// Called from the AVCaptureVideoDataOutput delegate queue with each camera frame.
        /// Creates a Metal texture from the pixel buffer (zero-copy via CVMetalTextureCache)
        /// and stores it for the next display-link-driven draw call.
        func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            var cvTexture: CVMetalTexture?
            let status = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                pixelBuffer,
                nil,
                .bgra8Unorm,
                width,
                height,
                0,
                &cvTexture
            )

            guard status == kCVReturnSuccess,
                let cvTex = cvTexture,
                let texture = CVMetalTextureGetTexture(cvTex)
            else {
                return
            }

            // Retain CVMetalTexture alongside MTLTexture to keep backing IOSurface alive until next frame
            let frame = CameraFrame(cvTexture: cvTex, mtlTexture: texture)
            _currentFrame.withLock { $0 = frame }
            _textureSize.withLock { $0 = SIMD2<Float>(Float(width), Float(height)) }
            _needsDraw.withLock { $0 = true }

            // Request a draw on the main thread (MTKView requires main-thread display calls)
            DispatchQueue.main.async { [weak self] in
                self?.mtkView.setNeedsDisplay()
            }
        }

        /// Update the bounding box overlays displayed on the preview.
        func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {
            _overlays.withLock { $0 = overlays }
            // Labels are CoreAnimation layers — reposition on the main thread.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.labelOverlayView.update(overlays: overlays, transform: self.currentOverlayTransform())
            }
        }

        /// Show or hide the detection labels drawn above the preview.
        func setLabelsVisible(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.labelOverlayView.labelsVisible = visible
            }
        }

        /// Current aspect-fill + zoom transform, used to place both boxes and labels.
        /// Read `aspectFillUniforms` on the main thread (where it is mutated).
        private func currentOverlayTransform() -> OverlayTransform {
            let zoom = _visualZoom.withLock { $0 }
            return OverlayTransform(
                uvScale: aspectFillUniforms.uvScale,
                uvOffset: aspectFillUniforms.uvOffset,
                zoomFactor: zoom.factor,
                zoomAnchorX: zoom.anchorX,
                zoomAnchorY: zoom.anchorY
            )
        }

        // MARK: - Aspect-Fill Computation

        /// Recomputes UV scale/offset so the camera texture fills the view
        /// without stretching (aspect-fill with center crop).
        private func recomputeAspectFill(
            drawableSize: CGSize,
            textureSize: SIMD2<Float>
        ) {
            guard textureSize.x > 0 && textureSize.y > 0 else { return }

            let viewAspect = Float(drawableSize.width / drawableSize.height)
            let texAspect = textureSize.x / textureSize.y

            var scaleX: Float = 1.0
            var scaleY: Float = 1.0

            if texAspect > viewAspect {
                // Texture is wider than view — crop sides
                scaleX = viewAspect / texAspect
            } else {
                // Texture is taller than view — crop top/bottom
                scaleY = texAspect / viewAspect
            }

            let scale = SIMD2<Float>(scaleX, scaleY)
            let offset = SIMD2<Float>((1.0 - scaleX) * 0.5, (1.0 - scaleY) * 0.5)
            let zoom = _visualZoom.withLock { $0 }
            aspectFillUniforms = AspectFillUniforms(
                uvScale: scale,
                uvOffset: offset,
                zoomFactor: zoom.factor,
                _pad: 0,
                zoomAnchor: SIMD2<Float>(zoom.anchorX, zoom.anchorY)
            )

            // Sync to PreviewView so consumers (e.g. label overlays) can correct coordinates
            previewViewRef?.uvScale = scale
            previewViewRef?.uvOffset = offset
            // Keep the label overlay aligned with the new aspect-fill transform.
            labelOverlayView.update(transform: currentOverlayTransform())
        }
    }

    // MARK: - MTKViewDelegate

    extension MetalPreviewRenderer: MTKViewDelegate {
        func mtkView(
            _ view: MTKView,
            drawableSizeWillChange size: CGSize
        ) {
            let texSize = _textureSize.withLock { $0 }
            recomputeAspectFill(drawableSize: size, textureSize: texSize)
            lastTextureSize = texSize
        }

        func draw(in view: MTKView) {
            // Skip if no new frame since last draw
            let needsDraw = _needsDraw.withLock { val in
                let current = val
                val = false
                return current
            }
            guard needsDraw else { return }

            guard let frame = _currentFrame.withLock({ $0 }),
                let drawable = view.currentDrawable,
                let passDescriptor = view.currentRenderPassDescriptor
            else {
                return
            }

            // Recompute aspect-fill if texture dimensions changed (e.g., camera switch)
            let texSize = _textureSize.withLock { $0 }
            if texSize != lastTextureSize {
                recomputeAspectFill(drawableSize: view.drawableSize, textureSize: texSize)
                lastTextureSize = texSize
            }

            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            passDescriptor.colorAttachments[0].storeAction = .store

            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else {
                return
            }

            // 1. Draw camera frame (fullscreen textured quad with aspect-fill + zoom)
            encoder.setRenderPipelineState(cameraPipeline)
            var uniforms = aspectFillUniforms
            let zoom = _visualZoom.withLock { $0 }
            uniforms.zoomFactor = zoom.factor
            uniforms.zoomAnchor = SIMD2<Float>(zoom.anchorX, zoom.anchorY)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<AspectFillUniforms>.size, index: 0)
            encoder.setFragmentTexture(frame.mtlTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            // 2. Draw bounding box overlays
            let overlays = _overlays.withLock { $0 }
            if !overlays.isEmpty {
                drawOverlays(overlays, encoder: encoder)
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Overlay Drawing

        /// Writes one quad per box into the vertex buffer; the rounded, anti-aliased border
        /// (thickness + corner radius) is computed per-pixel in the fragment shader.
        private func drawOverlays(
            _ overlays: [PhotoCaptureClient.OverlayRect],
            encoder: MTLRenderCommandEncoder
        ) {
            encoder.setRenderPipelineState(boxPipeline)

            // One quad (2 triangles = 6 vertices) per box.
            let verticesPerBox = 6
            let maxBoxes = maxBoxVertices / verticesPerBox

            let pointer = boxVertexBuffer.contents().bindMemory(to: BoxVertex.self, capacity: maxBoxVertices)

            let transform = currentOverlayTransform()

            let scale = Float(mtkView.contentScaleFactor)
            let drawableWidth = Float(mtkView.drawableSize.width)
            let drawableHeight = Float(mtkView.drawableSize.height)
            guard drawableWidth > 0, drawableHeight > 0 else { return }
            let borderPixels = Float(boxBorderWidth) * scale
            // One pixel of padding so the anti-aliased outer edge isn't clipped by the quad.
            let padPixels: Float = 1

            var idx = 0
            for index in 0..<min(overlays.count, maxBoxes) {
                let overlay = overlays[index]
                // Map texture space → screen-normalized (aspect-fill + zoom). Returns nil when the box
                // is not fully inside the visible preview, so partially-cropped boxes are skipped.
                guard
                    let rect = visibleScreenRect(
                        minX: overlay.x,
                        minY: overlay.y,
                        width: overlay.width,
                        height: overlay.height,
                        transform: transform
                    )
                else {
                    continue
                }

                // Box geometry in pixels.
                let halfWidthPixels = rect.width * drawableWidth * 0.5
                let halfHeightPixels = rect.height * drawableHeight * 0.5
                let radiusPixels = min(Float(boxCornerRadius) * scale, min(halfWidthPixels, halfHeightPixels))

                // Box center in Metal clip space (-1..1, bottom-left origin).
                let centerX = (rect.minX + rect.width * 0.5) * 2.0 - 1.0
                let centerY = 1.0 - (rect.minY + rect.height * 0.5) * 2.0

                // Quad half-extent (box + AA padding) in clip space and matching local pixel coords.
                let halfClipX = (halfWidthPixels + padPixels) / drawableWidth * 2.0
                let halfClipY = (halfHeightPixels + padPixels) / drawableHeight * 2.0
                let localX = halfWidthPixels + padPixels
                let localY = halfHeightPixels + padPixels

                let color = overlay.color
                let halfSize = SIMD2<Float>(halfWidthPixels, halfHeightPixels)
                let params = SIMD2<Float>(radiusPixels, borderPixels)

                func addVertex(
                    _ clipX: Float,
                    _ clipY: Float,
                    _ localPosX: Float,
                    _ localPosY: Float
                ) {
                    pointer[idx] = BoxVertex(
                        color: color,
                        position: SIMD2<Float>(clipX, clipY),
                        localPos: SIMD2<Float>(localPosX, localPosY),
                        halfSize: halfSize,
                        params: params
                    )
                    idx += 1
                }

                // Two triangles covering the padded box quad.
                addVertex(centerX - halfClipX, centerY - halfClipY, -localX, -localY)
                addVertex(centerX + halfClipX, centerY - halfClipY, localX, -localY)
                addVertex(centerX - halfClipX, centerY + halfClipY, -localX, localY)
                addVertex(centerX + halfClipX, centerY - halfClipY, localX, -localY)
                addVertex(centerX + halfClipX, centerY + halfClipY, localX, localY)
                addVertex(centerX - halfClipX, centerY + halfClipY, -localX, localY)
            }

            guard idx > 0 else { return }

            encoder.setVertexBuffer(boxVertexBuffer, offset: 0, index: 0)
            // Draw only the vertices actually written — boxes outside the visible frame are skipped.
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: idx)
        }
    }
#endif
