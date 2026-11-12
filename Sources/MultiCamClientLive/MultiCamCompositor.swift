#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    /// Wrapper to make CVMetalTexture + MTLTexture pair Sendable.
    struct CameraFrame: @unchecked Sendable {
        let cvTexture: CVMetalTexture
        let mtlTexture: MTLTexture
        let width: Int
        let height: Int
    }

    /// PiP border appearance (normalized width + RGBA color) applied to non-fullscreen
    /// viewports during encoding.
    struct BorderStyle {
        let width: Float
        let color: SIMD4<Float>
    }

    /// The encoder + drawable dimensions + border a viewport is encoded into. Groups what
    /// would otherwise be three loose parameters shared by every render pass (preview,
    /// offscreen recording, one-shot composite).
    struct RenderTarget {
        let encoder: MTLRenderCommandEncoder
        let drawableSize: CGSize
        let border: BorderStyle
    }

    /// An immutable snapshot of the camera frames + viewports available to render,
    /// read once from `_renderState` per draw/capture.
    struct Scene {
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
        static let fullscreenThreshold: CGFloat = 0.99

        /// JPEG quality used when encoding a one-shot composite photo.
        static let jpegCompressionQuality: CGFloat = 0.92

        // MARK: - Metal State

        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        private let textureCache: CVMetalTextureCache
        private let mtkView: MTKView
        let cameraPipeline: MTLRenderPipelineState

        /// Live RGB + luminance histogram of the primary camera (GPU compute + draw, no
        /// readback). `nil` if its pipelines could not be built. Drawn on the preview only —
        /// never the offscreen recording pass, so recorded video stays clean.
        private let histogramOverlay: Histogram.Overlay?

        /// Histogram appearance (channels, on-screen frame, opacity). Touched only on the main
        /// thread (set via `setHistogramConfig`, read in `draw(in:)`).
        var histogramConfig = Histogram.Config.default

        /// Minimum spacing between histogram recomputes; the draw reads the last bins every frame.
        let histogramComputeInterval: CFTimeInterval = 1.0 / 12.0

        /// Whether the histogram is drawn, and when it last recomputed. Touched only on the main
        /// thread (set via `setHistogramVisible`, read in `draw(in:)`).
        private var histogramVisible = false
        var lastHistogramComputeTime: CFTimeInterval = 0

        // MARK: - Frame State (combined under single lock to prevent torn renders)

        struct RenderState: @unchecked Sendable {
            var cameraFrames: [MultiCamClient.CameraID: CameraFrame] = [:]
            var viewports: [LayoutEngine.CameraViewport] = []
        }
        let _renderState = OSAllocatedUnfairLock(initialState: RenderState())

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
        var recordingPixelBufferPool: CVPixelBufferPool?
        private var recordingOutputSize: CGSize = .zero
        var recordingTextureCache: CVMetalTextureCache?
        var _isRecording = OSAllocatedUnfairLock(initialState: false)

        var isRecording: Bool {
            get { _isRecording.withLock { $0 } }
            set { _isRecording.withLock { $0 = newValue } }
        }

        /// Border settings for PiP overlays (set from app layer)
        var borderWidth: Float = 0  // in normalized viewport space
        var borderColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)  // RGBA

        // MARK: - PiP Gesture State

        /// Callback bundle for PiP drag/pinch. Defaults to `.none` (no-op).
        var callbacks: MultiCamClient.PiPGestureCallbacks = .none
        /// Per-recognizer state holders (one per gesture). Keep state off the compositor
        /// itself so simultaneous gestures on different PiPs don't cross-talk.
        private let dragCoordinator = PiPDragCoordinator()
        private let pinchCoordinator = PiPPinchCoordinator()

        // MARK: - Init

        /// Groups the Metal/CoreVideo/overlay dependencies the factory resolves, so `init`
        /// takes one value instead of five loose parameters.
        struct Resources {
            let device: MTLDevice
            let commandQueue: MTLCommandQueue
            let textureCache: CVMetalTextureCache
            let cameraPipeline: MTLRenderPipelineState
            let histogramOverlay: Histogram.Overlay?
        }

        init(resources: Resources) {
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
        func setHistogramConfig(_ config: Histogram.Config) {
            histogramConfig = config
            _needsDraw.withLock { $0 = true }
            mtkView.setNeedsDisplay()
        }

        /// Read a snapshot of the current viewport for `camera`, or nil if not present.
        func currentViewport(for camera: MultiCamClient.CameraID) -> LayoutEngine.CameraViewport? {
            _renderState.withLock { state in
                state.viewports.first(where: { $0.cameraID == camera })
            }
        }

        /// Hit-test a touch point (in compositor view coords) against current viewports,
        /// returning the top-most camera (highest zOrder) whose normalized rect contains it.
        func cameraAtTouch(_ point: CGPoint) -> MultiCamClient.CameraID? {
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
        var gestureCallbacks: MultiCamClient.PiPGestureCallbacks { callbacks }

        func configureRecordingOutput(size: CGSize) {
            recordingOutputSize = size
            let attrs = Self.pixelBufferAttributes(width: Int(size.width), height: Int(size.height))
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            recordingPixelBufferPool = pool

            // Create a separate texture cache for recording pixel buffers
            recordingTextureCache = Self.makeTextureCache(device: device)
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
    }
#endif
