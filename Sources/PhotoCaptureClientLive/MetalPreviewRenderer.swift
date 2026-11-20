#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import PhotoCaptureClient
    import os

    /// Wrapper to make CVMetalTexture + MTLTexture pair Sendable for use in OSAllocatedUnfairLock.
    private struct CameraFrame: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let mtlTexture: MTLTexture
    }

    /// Metal-backed camera preview that renders CVPixelBuffers using the display link
    /// and supports bounding box overlay drawing for object detection results.
    final class MetalPreviewRenderer: UIView, @unchecked Sendable {

        // MARK: - Metal State

        let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let textureCache: CVMetalTextureCache
        let mtkView: MTKView

        /// Overlay that draws detection labels (class name + confidence) above the Metal preview.
        private let labelOverlayView = DetectionLabelOverlayView()

        /// Overlay that draws a single animated dot (the `.centerDot` style) above the preview.
        private let dotOverlayView = DetectionDotOverlayView()

        // Render pipelines
        private let cameraPipeline: MTLRenderPipelineState
        let boxPipeline: MTLRenderPipelineState

        /// Draws the live RGB + luminance histogram (GPU compute + draw, no readback). `nil`
        /// if its Metal pipelines could not be built; the preview then runs without it.
        private let histogramOverlay: Histogram.Overlay?

        /// The channel-gain filter: a compute pass that writes `camera × gain` into `gainTexture`,
        /// which the preview and the histogram then both read. `nil` if the pipeline could not be
        /// built — the preview then shows the unfiltered feed. The filter transforms pixels; the
        /// histogram only measures them.
        let channelGainPipeline: MTLComputePipelineState?

        /// Live-translated text, drawn in the camera pass. `nil` if its pipeline could not be built.
        private let textOverlayLayer: TextOverlayLayer?
        private let textBackdrop: TextBackdrop?

        /// A captured photo shown in place of the camera, text overlays included. Main thread only.
        private var stillTexture: MTLTexture?
        /// The still just released, fading out over the camera. Main thread only.
        private var fadingStill: (texture: MTLTexture, releasedAt: CFTimeInterval)?
        private let fadingStillPipeline: MTLRenderPipelineState?
        private static let stillFadeSeconds: CFTimeInterval = 0.25
        /// Set while a still is up, so camera frames neither replace it nor change its size.
        private let _showsStill = OSAllocatedUnfairLock<Bool>(initialState: false)

        /// Destination for the channel-gain filter, reused across frames and resized to match the
        /// camera texture. Touched only on the main thread inside `draw(in:)`.
        var gainTexture: MTLTexture?

        /// Histogram appearance (channels, on-screen frame, opacity). Updated via
        /// `setHistogramConfig` from any thread, read in `draw`.
        private let _histogramConfig = OSAllocatedUnfairLock<Histogram.Config>(initialState: .default)

        /// Minimum spacing between histogram recomputes — the draw still reads the last bins
        /// every frame, so the overlay stays on screen at full rate while compute runs ~12fps.
        private let histogramComputeInterval: CFTimeInterval = 1.0 / 12.0

        /// Timestamp of the last histogram compute. Read and written only on the main thread
        /// inside `draw(in:)`.
        private var lastHistogramComputeTime: CFTimeInterval = 0

        // Reusable vertex buffer for bounding box overlays (avoids per-frame allocation).
        // Each box is one quad (2 triangles = 6 vertices); 800 vertices ≈ 133 boxes.
        // `static` so `create()` sizes the buffer from the same source the draw path fills to.
        static let maxBoxVertices = 800
        let boxVertexBuffer: MTLBuffer

        /// Bounding-box border thickness in points. The border is drawn as a rounded-rectangle
        /// ring in the fragment shader (Metal `.line` primitives are 1px hairlines with no width).
        let boxBorderWidth: CGFloat = 3

        /// Bounding-box corner radius in points. 0 = sharp corners.
        let boxCornerRadius: CGFloat = 8

        // MARK: - Frame State

        /// Latest camera frame — stores both CVMetalTexture (to retain backing IOSurface) and MTLTexture (for rendering).
        /// CVMetalTextureGetTexture returns a texture only valid while the CVMetalTexture is alive,
        /// so we must retain the CVMetalTexture until the next frame replaces it.
        private let _currentFrame = OSAllocatedUnfairLock<CameraFrame?>(initialState: nil)

        /// Texture dimensions for aspect-fill computation.
        private let _textureSize = OSAllocatedUnfairLock<SIMD2<Float>>(initialState: .zero)

        /// Current overlay rectangles — written from any thread, read from main thread.
        private let _overlays = OSAllocatedUnfairLock<[PhotoCaptureClient.OverlayRect]>(initialState: [])

        /// How overlays are drawn (boxes vs. center dot). The Metal box pass runs only for `.boxes`.
        private let _overlayStyle = OSAllocatedUnfairLock<PhotoCaptureClient.OverlayStyle>(
            initialState: .boxes
        )

        /// Whether the live histogram overlay is drawn. Written from any thread, read in `draw`.
        private let _histogramVisible = OSAllocatedUnfairLock<Bool>(initialState: false)

        /// Per-channel RGBA gain applied to the live preview — and to the histogram sampling the same
        /// pixels. `(1,1,1,1)` leaves the feed untouched. Written from any thread, read in `draw`.
        let _channelGains = OSAllocatedUnfairLock<SIMD4<Float>>(initialState: .one)

        /// Dirty flag — set by enqueueFrame, cleared by draw. Prevents redundant draws.
        private let _needsDraw = OSAllocatedUnfairLock<Bool>(initialState: false)

        // MARK: - Visual Zoom State

        /// Visual zoom state — set externally by the actor, read during draw. Thread-safe.
        private let _visualZoom = OSAllocatedUnfairLock<(factor: Float, anchorX: Float, anchorY: Float)>(
            initialState: (factor: 1.0, anchorX: 0.5, anchorY: 0.5)
        )

        // MARK: - Gesture State

        /// Emitted on tap — an AVFoundation focus point of interest (landscape-left, 0..1) the actor
        /// forwards to the capture device. Set on the main thread.
        var onTapToFocus: ((CGPoint) -> Void)?

        /// Emitted on a tap that lands on a text overlay, with its id; such a tap does not focus.
        var onTextOverlayTap: ((UUID) -> Void)?

        /// Emitted while pinching — a zoom factor already clamped to `zoomLimits`. Set on the main thread.
        var onZoomChange: ((CGFloat) -> Void)?

        /// The active device's available zoom range, supplied by the actor; pinch factors clamp to it.
        /// Touched only on the main thread, like the two tracking fields below.
        var zoomLimits: (min: CGFloat, max: CGFloat) = (1, 1)

        /// The live zoom factor the next pinch resumes from, and the anchor captured when a pinch begins.
        private var currentZoomFactor: CGFloat = 1
        private var baseZoomFactor: CGFloat = 1

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

        init(resources: Resources) {
            self.device = resources.device
            self.commandQueue = resources.commandQueue
            self.textureCache = resources.textureCache
            self.cameraPipeline = resources.cameraPipeline
            self.fadingStillPipeline = resources.fadingStillPipeline
            self.boxPipeline = resources.boxPipeline
            self.boxVertexBuffer = resources.boxVertexBuffer
            self.histogramOverlay = resources.histogramOverlay
            self.channelGainPipeline = resources.channelGainPipeline
            self.textOverlayLayer = resources.textPipeline.map {
                TextOverlayLayer(device: resources.device, pipeline: $0)
            }
            self.textBackdrop = TextBackdrop(device: resources.device)

            let mtkView = MTKView()
            mtkView.device = resources.device
            mtkView.framebufferOnly = true
            mtkView.colorPixelFormat = .bgra8Unorm
            // On-demand rendering: only draw when a new frame arrives via setNeedsDisplay()
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            self.mtkView = mtkView

            super.init(frame: .zero)

            mtkView.delegate = self
            pinToBounds(mtkView)
            pinToBounds(labelOverlayView)
            pinToBounds(dotOverlayView)

            // Touches must reach this view's gesture recognizers, not the MTKView layered over it.
            mtkView.isUserInteractionEnabled = false
            setupGestures()
            observeMemoryWarnings()
        }

        /// Add `subview` and pin its four edges to this view's bounds.
        private func pinToBounds(_ subview: UIView) {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
            NSLayoutConstraint.activate([
                subview.topAnchor.constraint(equalTo: topAnchor),
                subview.bottomAnchor.constraint(equalTo: bottomAnchor),
                subview.leadingAnchor.constraint(equalTo: leadingAnchor),
                subview.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        /// Flush the Metal texture cache on a memory warning to release backing IOSurfaces.
        private func observeMemoryWarnings() {
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
                self.dotOverlayView.update(transform: self.currentOverlayTransform())
            }
        }

        /// Reset zoom to default (e.g., on camera switch).
        func resetVisualZoom() {
            setVisualZoom(factor: 1.0, anchorX: 0.5, anchorY: 0.5)
        }

        // MARK: - Gestures

        /// Install the default pinch-to-zoom and tap-to-focus recognizers on the preview.
        private func setupGestures() {
            addGestureRecognizer(
                UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            )
            addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            )
        }

        /// Reset pinch tracking to 1× — called on camera switch, after the new device input has
        /// already reset its own `videoZoomFactor`.
        func resetZoomTracking() {
            currentZoomFactor = 1
            baseZoomFactor = 1
        }

        /// Keep pinch tracking in step with a programmatic zoom so the next pinch resumes from the
        /// live factor instead of jumping.
        func syncZoomTracking(to factor: CGFloat) {
            currentZoomFactor = min(max(factor, zoomLimits.min), zoomLimits.max)
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
                case .began:
                    baseZoomFactor = currentZoomFactor
                case .changed, .ended:
                    // `scale` is cumulative since `.began`, so the base is the anchor, not the previous factor.
                    let proposed = baseZoomFactor * gesture.scale
                    let clamped = min(max(proposed, zoomLimits.min), zoomLimits.max)
                    currentZoomFactor = clamped
                    onZoomChange?(clamped)
                default:
                    break
            }
        }

        @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let texturePoint = texturePoint(forViewPoint: gesture.location(in: self)) else { return }
            if let id = textOverlayLayer?.overlayID(at: texturePoint) {
                onTextOverlayTap?(id)
                return
            }
            // The video connection rotates portrait → landscape-left (`videoRotationAngle = 90`).
            onTapToFocus?(CGPoint(x: CGFloat(clampUnit(texturePoint.y)), y: CGFloat(clampUnit(1 - texturePoint.x))))
        }

        /// Map a point in view coordinates to the camera texture (normalized, top-left origin) with the
        /// same zoom-about-anchor then aspect-fill the camera shader uses. `nil` before the view has a size.
        private func texturePoint(forViewPoint point: CGPoint) -> SIMD2<Float>? {
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return nil }

            let zoom = _visualZoom.withLock { $0 }
            let viewU = Float(point.x / size.width)
            let viewV = Float(point.y / size.height)
            let zoomedU = (viewU - zoom.anchorX) / zoom.factor + zoom.anchorX
            let zoomedV = (viewV - zoom.anchorY) / zoom.factor + zoom.anchorY
            return SIMD2(
                zoomedU * aspectFillUniforms.uvScale.x + aspectFillUniforms.uvOffset.x,
                zoomedV * aspectFillUniforms.uvScale.y + aspectFillUniforms.uvOffset.y
            )
        }

        private func clampUnit(_ value: Float) -> Float {
            min(max(value, 0), 1)
        }

        // MARK: - Public API

        /// Called from the AVCaptureVideoDataOutput delegate queue with each camera frame.
        /// Creates a Metal texture from the pixel buffer (zero-copy via CVMetalTextureCache)
        /// and stores it for the next display-link-driven draw call.
        func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
            guard !_showsStill.withLock({ $0 }) else { return }
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
            // Labels and the dot are CoreAnimation views — reposition on the main thread.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let transform = self.currentOverlayTransform()
                self.labelOverlayView.update(overlays: overlays, transform: transform)
                self.dotOverlayView.update(overlays: overlays, transform: transform)
            }
        }

        /// Replace the text drawn over the preview; it eases toward new positions frame by frame.
        func updateTextOverlays(_ overlays: [PhotoCaptureClient.TextOverlay]) {
            DispatchQueue.main.async { [weak self] in
                self?.textOverlayLayer?.update(overlays)
            }
            markNeedsRedraw()
        }

        /// Show `photoData` in place of the camera until called with `nil`.
        func showStill(_ photoData: Data?) {
            _showsStill.withLock { $0 = photoData != nil }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if photoData == nil, let released = stillTexture {
                    fadingStill = (released, CACurrentMediaTime())
                }
                stillTexture = photoData.flatMap { StillTexture.make(from: $0, device: self.device) }
                if let stillTexture {
                    let size = SIMD2(Float(stillTexture.width), Float(stillTexture.height))
                    _textureSize.withLock { $0 = size }
                }
                markNeedsRedraw()
            }
        }

        /// Show or hide the detection labels drawn above the preview.
        func setLabelsVisible(_ visible: Bool) {
            DispatchQueue.main.async { [weak self] in
                self?.labelOverlayView.labelsVisible = visible
            }
        }

        /// Select how overlays are drawn: rounded boxes or a single animated center dot.
        func setOverlayStyle(_ style: PhotoCaptureClient.OverlayStyle) {
            _overlayStyle.withLock { $0 = style }
            _needsDraw.withLock { $0 = true }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dotOverlayView.setActive(style == .centerDot)
                self.mtkView.setNeedsDisplay()
            }
        }

        /// Show or hide the live histogram drawn over the preview.
        func setHistogramVisible(_ visible: Bool) {
            _histogramVisible.withLock { $0 = visible }
            markNeedsRedraw()
        }

        /// Update the live histogram's channels, frame, and opacity.
        func setHistogramConfig(_ config: Histogram.Config) {
            _histogramConfig.withLock { $0 = config }
            markNeedsRedraw()
        }

        /// Set the per-channel RGBA gain applied to the live preview (and the histogram). `(1,1,1,1)`
        /// restores the untouched feed.
        func setChannelGains(_ gains: SIMD4<Float>) {
            _channelGains.withLock { $0 = gains }
            markNeedsRedraw()
        }

        /// Flag a redraw and request one on the main thread (MTKView requires main-thread display).
        private func markNeedsRedraw() {
            _needsDraw.withLock { $0 = true }
            DispatchQueue.main.async { [weak self] in
                self?.mtkView.setNeedsDisplay()
            }
        }

        /// Current aspect-fill + zoom transform, used to place both boxes and labels.
        /// Read `aspectFillUniforms` on the main thread (where it is mutated).
        func currentOverlayTransform() -> OverlayTransform {
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

            // `frame` keeps the camera texture's IOSurface alive until the draw is encoded.
            let frame = _currentFrame.withLock { $0 }
            guard let shownTexture = stillTexture ?? frame?.mtlTexture,
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

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let histogramVisible = _histogramVisible.withLock { $0 }
            let histogramConfig = _histogramConfig.withLock { $0 }
            let channelGains = _channelGains.withLock { $0 }

            // Apply the channel-gain filter once; the preview and the histogram both read its result,
            // so the filter transforms pixels in one place and the histogram just measures them.
            let sourceTexture = filteredTexture(from: shownTexture, gains: channelGains, in: commandBuffer)

            // Histogram compute runs before the render pass so the draw reads fresh bins.
            // Encoded on the same command buffer; the draw step adds it over the frame below.
            if histogramVisible {
                maybeComputeHistogram(from: sourceTexture, config: histogramConfig, in: commandBuffer)
            }

            // The blur is a compute pass too, so it is encoded before the render pass samples it.
            let backdrop =
                textOverlayLayer?.hasContent == true
                ? textBackdrop?.encodeBlur(of: sourceTexture, in: commandBuffer) : nil

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
                return
            }

            // 1. Draw camera frame (fullscreen textured quad with aspect-fill + zoom)
            encoder.setRenderPipelineState(cameraPipeline)
            var uniforms = aspectFillUniforms
            let zoom = _visualZoom.withLock { $0 }
            uniforms.zoomFactor = zoom.factor
            uniforms.zoomAnchor = SIMD2<Float>(zoom.anchorX, zoom.anchorY)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<AspectFillUniforms>.size, index: 0)
            encoder.setFragmentTexture(sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            drawFadingStill(in: encoder, uniforms: uniforms)

            // 2. Draw bounding box overlays (skipped in `.centerDot` style — the dot is a
            //    CoreAnimation overlay drawn by `dotOverlayView`, not a Metal primitive).
            let overlays = _overlays.withLock { $0 }
            if _overlayStyle.withLock({ $0 }) == .boxes, !overlays.isEmpty {
                drawOverlays(overlays, encoder: encoder)
            }

            // 3. Text overlays, mapped by the same uniforms as the camera quad.
            if let backdrop {
                textOverlayLayer?.encode(
                    in: encoder,
                    geometry: textOverlayGeometry(view: view, uniforms: uniforms),
                    backdrop: backdrop
                )
            }

            // 4. Draw the live histogram over everything (read-only exposure aid).
            if histogramVisible, let histogramOverlay {
                histogramOverlay.encodeDraw(in: encoder, config: histogramConfig)
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Draws the released still over the camera at its remaining opacity, asking for the next
        /// frame until it is gone so the fade runs even if the camera is slow to deliver.
        private func drawFadingStill(
            in encoder: MTLRenderCommandEncoder,
            uniforms: AspectFillUniforms
        ) {
            guard let fading = fadingStill, let fadingStillPipeline else { return }
            var uniforms = uniforms
            var opacity = Float(1 - (CACurrentMediaTime() - fading.releasedAt) / Self.stillFadeSeconds)
            guard opacity > 0 else {
                fadingStill = nil
                return
            }
            encoder.setRenderPipelineState(fadingStillPipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<AspectFillUniforms>.size, index: 0)
            encoder.setFragmentTexture(fading.texture, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            markNeedsRedraw()
        }

        private func textOverlayGeometry(
            view: MTKView,
            uniforms: AspectFillUniforms
        ) -> TextOverlayGeometry {
            let textureSize = _textureSize.withLock { $0 }
            let visibleTexels = textureSize.y * uniforms.uvScale.y
            return TextOverlayGeometry(
                textureSize: textureSize,
                pixelsPerTexel: visibleTexels > 0
                    ? Float(view.drawableSize.height) / visibleTexels * uniforms.zoomFactor : 0,
                contentScale: Float(view.contentScaleFactor),
                uniforms: uniforms
            )
        }

        // MARK: - Histogram

        /// Recomputes the histogram at most every `histogramComputeInterval`, encoding the
        /// compute passes onto `commandBuffer` before the render pass. Runs on the main thread
        /// inside `draw(in:)`, so `lastHistogramComputeTime` needs no lock.
        private func maybeComputeHistogram(
            from texture: MTLTexture,
            config: Histogram.Config,
            in commandBuffer: MTLCommandBuffer
        ) {
            guard let histogramOverlay else { return }
            let now = CACurrentMediaTime()
            guard now - lastHistogramComputeTime >= histogramComputeInterval else { return }
            lastHistogramComputeTime = now
            histogramOverlay.encodeCompute(texture: texture, in: commandBuffer, config: config)
        }

    }
#endif
