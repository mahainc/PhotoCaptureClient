#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    // MARK: - Uniforms (must match Shaders.metal)

    /// Must match Metal struct `MultiCamUniforms` exactly (96 bytes).
    private struct MultiCamUniforms {
        var viewportRect: SIMD4<Float>  // 16 bytes
        var uvScale: SIMD2<Float>  // 8 bytes
        var uvOffset: SIMD2<Float>  // 8 bytes
        var cornerRadius: Float  // 4 bytes
        var borderWidth: Float  // 4 bytes
        var borderColor: SIMD4<Float>  // 16 bytes
        var pixelAspectRatio: Float  // 4 bytes
        var _pad: SIMD3<Float>  // 12 bytes pad to 80
    }

    /// Wrapper to make CVMetalTexture + MTLTexture pair Sendable.
    private struct CameraFrame: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let mtlTexture: MTLTexture
        let width: Int
        let height: Int
    }

    /// PiP border appearance (normalized width + RGBA color) applied to non-fullscreen
    /// viewports during encoding.
    private struct BorderStyle {
        let width: Float
        let color: SIMD4<Float>
    }

    /// The encoder + drawable dimensions + border a viewport is encoded into. Groups what
    /// would otherwise be three loose parameters shared by every render pass (preview,
    /// offscreen recording, one-shot composite).
    private struct RenderTarget {
        let encoder: MTLRenderCommandEncoder
        let drawableSize: CGSize
        let border: BorderStyle
    }

    /// An immutable snapshot of the camera frames + viewports available to render,
    /// read once from `_renderState` per draw/capture.
    private struct Scene {
        let frames: [MultiCamClient.CameraID: CameraFrame]
        let viewports: [LayoutEngine.CameraViewport]
    }

    /// Metal-backed multi-camera compositor that renders N camera textures
    /// into a single view according to the current layout.
    final class MultiCamCompositor: UIView, @unchecked Sendable {

        // MARK: - Tuning Constants

        /// Matches the display's native refresh rate (120 Hz on ProMotion devices). The
        /// default is 60 fps even on 120 Hz displays. Requires the host app to set
        /// `CADisableMinimumFrameDurationOnPhone = true` in Info.plist to actually unlock 120 Hz.
        private static let preferredFramesPerSecond: Int = 120

        /// A viewport at or above this normalized width/height fraction is treated as
        /// fullscreen (no PiP border drawn).
        private static let fullscreenThreshold: CGFloat = 0.99

        /// JPEG quality used when encoding a one-shot composite photo.
        private static let jpegCompressionQuality: CGFloat = 0.92

        // MARK: - Metal State

        private let device: MTLDevice
        private let commandQueue: MTLCommandQueue
        private let textureCache: CVMetalTextureCache
        private let mtkView: MTKView
        private let cameraPipeline: MTLRenderPipelineState

        /// Live RGB + luminance histogram of the primary camera (GPU compute + draw, no
        /// readback). `nil` if its pipelines could not be built. Drawn on the preview only —
        /// never the offscreen recording pass, so recorded video stays clean.
        private let histogramOverlay: HistogramOverlay?

        /// Histogram appearance (channels, on-screen frame, opacity). Touched only on the main
        /// thread (set via `setHistogramConfig`, read in `draw(in:)`).
        private var histogramConfig = HistogramConfig.default

        /// Minimum spacing between histogram recomputes; the draw reads the last bins every frame.
        private let histogramComputeInterval: CFTimeInterval = 1.0 / 12.0

        /// Whether the histogram is drawn, and when it last recomputed. Touched only on the main
        /// thread (set via `setHistogramVisible`, read in `draw(in:)`).
        private var histogramVisible = false
        private var lastHistogramComputeTime: CFTimeInterval = 0

        // MARK: - Frame State (combined under single lock to prevent torn renders)

        private struct RenderState: @unchecked Sendable {
            var cameraFrames: [MultiCamClient.CameraID: CameraFrame] = [:]
            var viewports: [LayoutEngine.CameraViewport] = []
        }
        private let _renderState = OSAllocatedUnfairLock(initialState: RenderState())

        /// Dirty flag.
        private let _needsDraw = OSAllocatedUnfairLock<Bool>(initialState: false)

        private let layoutEngine = LayoutEngine()

        /// Active cameras in order.
        private let _cameras = OSAllocatedUnfairLock<[MultiCamClient.CameraID]>(initialState: [])

        /// Current layout.
        private let _layout = OSAllocatedUnfairLock<MultiCamClient.Layout>(initialState: .grid(.init()))

        /// Back-reference to preview view.
        weak var previewViewRef: MultiCamClient.PreviewView?

        // MARK: - Recording Offscreen

        /// Callback for recording pipeline — receives composited frame synchronously.
        var onRecordingFrame: ((_ pixelBuffer: CVPixelBuffer, _ time: CMTime) -> Void)?
        private var recordingPixelBufferPool: CVPixelBufferPool?
        private var recordingOutputSize: CGSize = .zero
        private var recordingTextureCache: CVMetalTextureCache?
        private var _isRecording = OSAllocatedUnfairLock(initialState: false)

        var isRecording: Bool {
            get { _isRecording.withLock { $0 } }
            set { _isRecording.withLock { $0 = newValue } }
        }

        /// Border settings for PiP overlays (set from app layer)
        var borderWidth: Float = 0  // in normalized viewport space
        var borderColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)  // RGBA

        // MARK: - PiP Gesture State

        /// Callback bundle for PiP drag/pinch. Defaults to `.none` (no-op).
        private var callbacks: MultiCamClient.PiPGestureCallbacks = .none
        /// Per-recognizer state holders (one per gesture). Keep state off the compositor
        /// itself so simultaneous gestures on different PiPs don't cross-talk.
        private let dragCoordinator = PiPDragCoordinator()
        private let pinchCoordinator = PiPPinchCoordinator()

        // MARK: - Init

        /// Groups the Metal/CoreVideo/overlay dependencies the factory resolves, so `init`
        /// takes one value instead of five loose parameters.
        private struct Resources {
            let device: MTLDevice
            let commandQueue: MTLCommandQueue
            let textureCache: CVMetalTextureCache
            let cameraPipeline: MTLRenderPipelineState
            let histogramOverlay: HistogramOverlay?
        }

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
            let histogramOverlay = HistogramOverlay.create(device: device)

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

        private init(resources: Resources) {
            self.device = resources.device
            self.commandQueue = resources.commandQueue
            self.textureCache = resources.textureCache
            self.cameraPipeline = resources.cameraPipeline
            self.histogramOverlay = resources.histogramOverlay

            let mtkView = MTKView()
            mtkView.device = resources.device
            mtkView.framebufferOnly = true
            mtkView.colorPixelFormat = .bgra8Unorm
            mtkView.isPaused = true
            mtkView.enableSetNeedsDisplay = true
            mtkView.isUserInteractionEnabled = false  // Touches must reach the compositor (parent), not the MTKView.
            mtkView.preferredFramesPerSecond = Self.preferredFramesPerSecond
            self.mtkView = mtkView

            super.init(frame: .zero)

            configureMTKView()
            configureGestureRecognizers()
            configureMemoryWarningObserver()
        }

        /// Wires the MTKView as a delegate + full-bleed subview (AutoLayout).
        private func configureMTKView() {
            mtkView.delegate = self
            addSubview(mtkView)
            mtkView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                mtkView.topAnchor.constraint(equalTo: topAnchor),
                mtkView.bottomAnchor.constraint(equalTo: bottomAnchor),
                mtkView.leadingAnchor.constraint(equalTo: leadingAnchor),
                mtkView.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        /// Enables hit-testing and attaches the PiP drag/pinch gesture recognizers.
        private func configureGestureRecognizers() {
            isUserInteractionEnabled = true
            dragCoordinator.compositor = self
            pinchCoordinator.compositor = self
            let pan = UIPanGestureRecognizer(target: dragCoordinator, action: #selector(PiPDragCoordinator.handle(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            addGestureRecognizer(pan)
            let pinch = UIPinchGestureRecognizer(
                target: pinchCoordinator,
                action: #selector(PiPPinchCoordinator.handle(_:))
            )
            pinch.delegate = self
            addGestureRecognizer(pinch)
        }

        /// Flushes the texture cache under memory pressure.
        private func configureMemoryWarningObserver() {
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

        // MARK: - Public API

        func enqueueFrame(
            _ pixelBuffer: CVPixelBuffer,
            for camera: MultiCamClient.CameraID
        ) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)

            // The camera pixel buffer is not retained by the caller, so the CameraFrame keeps
            // the CVMetalTexture alive to hold the backing IOSurface until the next frame.
            guard let made = makeTexture(from: pixelBuffer, cache: textureCache) else { return }
            let frame = CameraFrame(
                cvTexture: made.cvTexture,
                mtlTexture: made.texture,
                width: width,
                height: height
            )
            let shouldDispatch = _needsDraw.withLock { needsDraw -> Bool in
                let wasClean = !needsDraw
                needsDraw = true
                return wasClean  // Only dispatch if transitioning from clean → dirty
            }
            _renderState.withLock { $0.cameraFrames[camera] = frame }

            if shouldDispatch {
                DispatchQueue.main.async { [weak self] in
                    self?.mtkView.setNeedsDisplay()
                }
            }
        }

        func setLayout(_ layout: MultiCamClient.Layout) {
            _layout.withLock { $0 = layout }

            let cameras = _cameras.withLock { $0 }
            let viewports = layoutEngine.computeViewports(layout: layout, cameras: cameras)
            _renderState.withLock { $0.viewports = viewports }
            _needsDraw.withLock { $0 = true }
            DispatchQueue.main.async { [weak self] in
                self?.mtkView.setNeedsDisplay()
            }
        }

        func setCameras(_ cameras: [MultiCamClient.CameraID]) {
            _cameras.withLock { $0 = cameras }
            let layout = _layout.withLock { $0 }
            let viewports = layoutEngine.computeViewports(layout: layout, cameras: cameras)
            _renderState.withLock { $0.viewports = viewports }
        }

        /// Fast-path: replace only the affected viewport's origin and request a redraw.
        /// Used by `MultiCamClient.setPiPOverlayPosition` for live drag updates without
        /// running the full layout pipeline. Must be called on the main thread.
        @MainActor
        func updateOverlayOrigin(
            camera: MultiCamClient.CameraID,
            origin: CGPoint
        ) {
            guard let current = currentViewport(for: camera) else { return }
            applyViewportRect(camera: camera, rect: CGRect(origin: origin, size: current.rect.size))
        }

        /// Generalized fast-path: replace one viewport's full rect (origin + size). Used by
        /// the gesture pipeline (drag + pinch) to push a clamped frame without rebuilding
        /// the whole layout. Must be called on the main thread.
        @MainActor
        func applyViewportRect(
            camera: MultiCamClient.CameraID,
            rect: CGRect
        ) {
            _renderState.withLock { state in
                guard let idx = state.viewports.firstIndex(where: { $0.cameraID == camera }) else { return }
                let old = state.viewports[idx]
                state.viewports[idx] = LayoutEngine.CameraViewport(
                    cameraID: old.cameraID,
                    rect: rect,
                    zOrder: old.zOrder,
                    cornerRadius: old.cornerRadius
                )
            }
            _needsDraw.withLock { $0 = true }
            mtkView.setNeedsDisplay()
        }

        /// Replace (or clear, with `.none`) the gesture-callback bundle the compositor
        /// uses to coordinate PiP drag/pinch with the host app.
        @MainActor
        func setGestureCallbacks(_ callbacks: MultiCamClient.PiPGestureCallbacks) {
            self.callbacks = callbacks
        }

        /// Show or hide the live histogram drawn over the composited preview.
        @MainActor
        func setHistogramVisible(_ visible: Bool) {
            histogramVisible = visible
            _needsDraw.withLock { $0 = true }
            mtkView.setNeedsDisplay()
        }

        /// Update the live histogram's channels, frame, and opacity.
        @MainActor
        func setHistogramConfig(_ config: HistogramConfig) {
            histogramConfig = config
            _needsDraw.withLock { $0 = true }
            mtkView.setNeedsDisplay()
        }

        /// Read a snapshot of the current viewport for `camera`, or nil if not present.
        fileprivate func currentViewport(for camera: MultiCamClient.CameraID) -> LayoutEngine.CameraViewport? {
            _renderState.withLock { state in
                state.viewports.first(where: { $0.cameraID == camera })
            }
        }

        /// Hit-test a touch point (in compositor view coords) against current viewports,
        /// returning the top-most camera (highest zOrder) whose normalized rect contains it.
        fileprivate func cameraAtTouch(_ point: CGPoint) -> MultiCamClient.CameraID? {
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            let normalized = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
            let viewports = _renderState.withLock { $0.viewports }
            // Top-most first.
            for vp in viewports.sorted(by: { $0.zOrder > $1.zOrder }) {
                if vp.rect.contains(normalized) { return vp.cameraID }
            }
            return nil
        }

        /// Look up the active callback bundle from the compositor (for coordinator use).
        fileprivate var gestureCallbacks: MultiCamClient.PiPGestureCallbacks { callbacks }

        func configureRecordingOutput(size: CGSize) {
            recordingOutputSize = size
            let attrs = Self.pixelBufferAttributes(width: Int(size.width), height: Int(size.height))
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            recordingPixelBufferPool = pool

            // Create a separate texture cache for recording pixel buffers
            recordingTextureCache = Self.makeTextureCache(device: device)
        }

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
        private func currentScene() -> Scene {
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
        private func makeRenderTarget(
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
        private func encodeScene(
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

        /// Creates + unwraps a `CVMetalTextureCache` for `device`, or nil on failure. Shared
        /// by `create()`, `configureRecordingOutput`, and `allocateOffscreenTexture`.
        private static func makeTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
            var cache: CVMetalTextureCache?
            let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
            guard status == kCVReturnSuccess else { return nil }
            return cache
        }

        /// Zero-copy BGRA Metal texture over `pixelBuffer`. Returns the `CVMetalTexture` too: the
        /// `MTLTexture` is only valid while it (or the pixel buffer's IOSurface) stays alive, so
        /// the caller keeps whichever outlives the other.
        private func makeTexture(
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
        private static func pixelBufferAttributes(
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
    }

    // MARK: - MTKViewDelegate

    extension MultiCamCompositor: MTKViewDelegate {
        func mtkView(
            _ view: MTKView,
            drawableSizeWillChange size: CGSize
        ) {
            // Viewports are normalized, so no recomputation needed for size changes
        }

        func draw(in view: MTKView) {
            let needsDraw = _needsDraw.withLock { val in
                let current = val
                val = false
                return current
            }
            guard needsDraw else { return }

            guard let drawable = view.currentDrawable,
                let passDescriptor = view.currentRenderPassDescriptor
            else { return }

            let scene = currentScene()

            passDescriptor.colorAttachments[0].loadAction = .clear
            passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            passDescriptor.colorAttachments[0].storeAction = .store

            // Draw each camera by zOrder
            let sortedViewports = scene.viewports.sorted { $0.zOrder < $1.zOrder }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            // Histogram compute (of the primary camera) before the render pass so the draw reads
            // fresh bins. Encoded on the same command buffer.
            if histogramVisible,
                let histogramOverlay,
                let primaryTexture = primaryCameraTexture(frames: scene.frames, sortedViewports: sortedViewports)
            {
                maybeComputeHistogram(histogramOverlay, from: primaryTexture, in: commandBuffer)
            }

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

            let target = makeRenderTarget(encoder: encoder, drawableSize: view.drawableSize)
            encodeScene(scene, into: target)

            // Draw the live histogram over the composited preview (read-only exposure aid; the
            // offscreen recording pass below is deliberately left clean).
            if histogramVisible, let histogramOverlay {
                histogramOverlay.encodeDraw(in: encoder, config: histogramConfig)
            }

            encoder.endEncoding()

            // Offscreen recording: encode into the SAME command buffer (no second GPU pass)
            encodeOffscreenRecordingIfNeeded(commandBuffer: commandBuffer, scene: scene)

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        /// Encodes the offscreen (recording) composite pass into `commandBuffer` when a
        /// recording session is active, and hands the finished pixel buffer to
        /// `onRecordingFrame` on command-buffer completion. No-op otherwise.
        private func encodeOffscreenRecordingIfNeeded(
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
        private func primaryCameraTexture(
            frames: [MultiCamClient.CameraID: CameraFrame],
            sortedViewports: [LayoutEngine.CameraViewport]
        ) -> MTLTexture? {
            let fullscreen = sortedViewports.first { isFullscreenViewport($0.rect) }
            guard let cameraID = (fullscreen ?? sortedViewports.first)?.cameraID else { return nil }
            return frames[cameraID]?.mtlTexture
        }

        /// Recomputes the histogram at most every `histogramComputeInterval`, onto `commandBuffer`
        /// before the render pass. Runs on the main thread inside `draw(in:)`.
        private func maybeComputeHistogram(
            _ overlay: HistogramOverlay,
            from texture: MTLTexture,
            in commandBuffer: MTLCommandBuffer
        ) {
            let now = CACurrentMediaTime()
            guard now - lastHistogramComputeTime >= histogramComputeInterval else { return }
            lastHistogramComputeTime = now
            overlay.encodeCompute(texture: texture, in: commandBuffer, config: histogramConfig)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    extension MultiCamCompositor: UIGestureRecognizerDelegate {

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            let point = touch.location(in: self)
            guard let cam = cameraAtTouch(point) else { return false }
            return callbacks.isCameraInteractive(cam)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Allow our own pan + pinch to fire together on the same PiP overlay; reject
            // simultaneity with foreign recognizers (e.g., the parent container's lens-zoom
            // pinch). The parent restricts itself to the primary fullscreen viewport, so
            // in PiP mode the two never compete on the same touch anyway.
            return gestureRecognizer.view == self && other.view == self
        }
    }

    // MARK: - Gesture Coordinators

    /// Shared per-recognizer gesture state. Held by the compositor; isolated from the
    /// compositor's shared state so simultaneous gestures on different PiPs don't
    /// cross-talk. Subclassed by `PiPDragCoordinator` and `PiPPinchCoordinator`.
    @MainActor
    private class PiPGestureCoordinator: NSObject {
        weak var compositor: MultiCamCompositor?
        var camera: MultiCamClient.CameraID?
        var startRect: CGRect = .zero
    }

    /// Per-recognizer drag state. Held by the compositor; isolated from compositor's
    /// shared state so simultaneous gestures on different PiPs don't cross-talk.
    @MainActor
    private final class PiPDragCoordinator: PiPGestureCoordinator {
        @objc func handle(_ gr: UIPanGestureRecognizer) {
            guard let comp = compositor else { return }
            switch gr.state {
                case .began:
                    guard let cam = comp.cameraAtTouch(gr.location(in: comp)),
                        let vp = comp.currentViewport(for: cam)
                    else {
                        gr.state = .failed
                        return
                    }
                    camera = cam
                    startRect = vp.rect
                case .changed:
                    guard let cam = camera else { return }
                    guard comp.currentViewport(for: cam) != nil else {
                        // Camera disappeared mid-gesture (disconnect / mode switch). Cancel.
                        gr.state = .cancelled
                        return
                    }
                    let bounds = comp.bounds
                    guard bounds.width > 0, bounds.height > 0 else { return }
                    let t = gr.translation(in: comp)
                    let proposedOrigin = CGPoint(
                        x: startRect.origin.x + t.x / bounds.width,
                        y: startRect.origin.y + t.y / bounds.height
                    )
                    let proposed = CGRect(origin: proposedOrigin, size: startRect.size)
                    let clamped = comp.gestureCallbacks.clampFrame(cam, proposed)
                    comp.applyViewportRect(camera: cam, rect: clamped)
                    comp.gestureCallbacks.onLiveUpdate(cam, clamped, .drag)
                case .ended:
                    guard let cam = camera else { return }
                    let final = comp.currentViewport(for: cam)?.rect ?? startRect
                    comp.gestureCallbacks.onCommit(cam, final, .drag)
                    camera = nil
                case .cancelled, .failed:
                    camera = nil
                default:
                    break
            }
        }
    }

    /// Per-recognizer pinch state. Independent from drag coordinator; both can fire
    /// concurrently on the same PiP (combined drag + resize gesture).
    @MainActor
    private final class PiPPinchCoordinator: PiPGestureCoordinator {
        /// Floor on the gesture's live scale factor, so a pinch-closed gesture can't
        /// collapse the PiP to a zero/negative-sized rect.
        private static let minimumPinchScale: CGFloat = 0.01

        @objc func handle(_ gr: UIPinchGestureRecognizer) {
            guard let comp = compositor else { return }
            switch gr.state {
                case .began:
                    guard let cam = comp.cameraAtTouch(gr.location(in: comp)),
                        let vp = comp.currentViewport(for: cam)
                    else {
                        gr.state = .failed
                        return
                    }
                    camera = cam
                    startRect = vp.rect
                case .changed:
                    guard let cam = camera else { return }
                    guard comp.currentViewport(for: cam) != nil else {
                        gr.state = .cancelled
                        return
                    }
                    let scale = max(Self.minimumPinchScale, gr.scale)
                    let newW = startRect.width * scale
                    let newH = startRect.height * scale
                    let cx = startRect.midX
                    let cy = startRect.midY
                    let proposed = CGRect(
                        x: cx - newW / 2,
                        y: cy - newH / 2,
                        width: newW,
                        height: newH
                    )
                    let clamped = comp.gestureCallbacks.clampFrame(cam, proposed)
                    comp.applyViewportRect(camera: cam, rect: clamped)
                    comp.gestureCallbacks.onLiveUpdate(cam, clamped, .pinch)
                case .ended:
                    guard let cam = camera else { return }
                    let final = comp.currentViewport(for: cam)?.rect ?? startRect
                    comp.gestureCallbacks.onCommit(cam, final, .pinch)
                    camera = nil
                case .cancelled, .failed:
                    camera = nil
                default:
                    break
            }
        }
    }
#endif
