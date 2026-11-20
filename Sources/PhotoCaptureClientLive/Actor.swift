@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HistogramKit
import ImageIO
import PhotoCaptureClient
import os

#if os(iOS)
    import UIKit
    import MetalKit
#endif

// MARK: - Actor

/// Plain actor that manages AVFoundation photo capture via a delegate.
actor PhotoCaptureClientActor {
    private let delegate = PhotoCaptureDelegate()
    private let logger: @Sendable (String) -> Void

    private var currentPosition: PhotoCaptureClient.CameraPosition = .back
    private var currentFlashMode: PhotoCaptureClient.FlashMode = .auto
    #if os(iOS)
        private var metalRenderer: MetalPreviewRenderer?
        private var cachedPreviewView: PhotoCaptureClient.PreviewView?
        private var currentVisualZoom: (factor: Float, anchorX: Float, anchorY: Float) = (1.0, 0.5, 0.5)
    #endif
    private var eventContinuations: [UUID: AsyncStream<PhotoCaptureClient.Event>.Continuation] = [:]
    private var pixelBufferSubscriberID: UUID?

    // MARK: - Init

    init(
        logger: @escaping @Sendable (String) -> Void = { message in
            #if DEBUG
                print("📷 [PHOTO_CAPTURE]: \(message)")
            #endif
        }
    ) {
        self.logger = logger

        delegate.onEvent = { [weak self] event in
            Task { await self?.yieldEvent(event) }
        }
        delegate.onLog = { [weak self] message in
            Task { await self?.log(message) }
        }
    }

    private func log(_ message: String) {
        logger(message)
    }

    // MARK: - Session Lifecycle

    func startSession() async throws {
        guard !delegate.isRunning else {
            throw PhotoCaptureClient.Error.captureSessionAlreadyRunning
        }
        logger("Configuring capture session")
        try delegate.configureSession(position: currentPosition)
        delegate.registerNotificationObservers()
        #if os(iOS)
            let renderer = await MainActor.run { MetalPreviewRenderer.create() }
            self.metalRenderer = renderer
            delegate.onFrame = { [weak renderer] pixelBuffer in
                renderer?.enqueueFrame(pixelBuffer)
            }
            await wireGestureCallbacks(to: renderer)
            // Link renderer to cached preview view (if getPreviewView was called before startSession)
            if let renderer, let cached = cachedPreviewView {
                renderer.previewViewRef = cached
            }
            // Invalidate cached preview so next getPreviewView returns one with the new renderer
            cachedPreviewView = nil
        #endif
        logger("Starting capture session")
        delegate.startRunning()
    }

    func stopSession() async {
        guard delegate.isRunning else {
            logger("Session not running, nothing to stop")
            return
        }
        logger("Stopping capture session")
        delegate.pixelBufferContinuation?.finish()
        delegate.pixelBufferContinuation = nil
        #if os(iOS)
            delegate.onFrame = nil
            metalRenderer = nil
        #endif
        delegate.teardown()
        for continuation in eventContinuations.values {
            continuation.finish()
        }
        eventContinuations.removeAll()
    }

    // MARK: - Photo Capture

    func capturePhoto(settings: PhotoCaptureClient.PhotoSettings) async throws -> PhotoCaptureClient.Photo {
        guard delegate.isRunning else {
            throw PhotoCaptureClient.Error.captureSessionNotRunning
        }
        logger("Capturing photo with flash: \(settings.flashMode)")

        return try await withCheckedThrowingContinuation { continuation in
            delegate.photoContinuation = continuation
            delegate.capturePhoto(settings: settings)
        }
    }

    // MARK: - Camera Control

    func switchCamera(to position: PhotoCaptureClient.CameraPosition) async throws {
        logger("Switching camera to \(position)")
        try delegate.switchCamera(to: position)
        currentPosition = position
        #if os(iOS)
            currentVisualZoom = (1.0, 0.5, 0.5)
            let renderer = metalRenderer
            let limits = delegate.zoomLimits()
            await MainActor.run {
                renderer?.resetVisualZoom()
                renderer?.zoomLimits = limits
                renderer?.resetZoomTracking()
            }
            yieldEvent(.zoomChanged(1.0))
        #endif
    }

    func setFlashMode(_ mode: PhotoCaptureClient.FlashMode) {
        logger("Setting flash mode to \(mode)")
        currentFlashMode = mode
    }

    func setFrameDeliveryInterval(_ seconds: TimeInterval) {
        logger("Setting frame delivery interval to \(seconds)s")
        delegate.frameIntervalSeconds = max(0, seconds)
    }

    func setPreviewPerformanceMode(_ mode: PhotoCaptureClient.PreviewPerformanceMode) {
        logger("Setting preview performance mode to \(mode)")
        delegate.setPreviewPerformanceMode(mode)
    }

    func focus(at point: CGPoint) async throws {
        logger("Focusing at \(point)")
        try delegate.focus(at: point)
    }

    func setZoomFactor(_ factor: CGFloat) async throws {
        logger("Setting zoom factor to \(factor)")
        try delegate.setZoomFactor(factor)
        #if os(iOS)
            let renderer = metalRenderer
            await MainActor.run { renderer?.syncZoomTracking(to: factor) }
        #endif
    }

    #if os(iOS)
        /// Wire the renderer's default gestures to the capture device: pinch → clamped zoom, tap →
        /// focus + auto-expose. Supplies the device's zoom limits so the pinch clamps on the main thread.
        private func wireGestureCallbacks(to renderer: MetalPreviewRenderer?) async {
            guard let renderer else { return }
            let limits = delegate.zoomLimits()
            await MainActor.run {
                renderer.zoomLimits = limits
                renderer.resetZoomTracking()
                renderer.onZoomChange = { [weak self] factor in
                    Task { await self?.applyGestureZoom(factor) }
                }
                renderer.onTapToFocus = { [weak self] point in
                    Task { await self?.applyTapToFocus(point) }
                }
                renderer.onTextOverlayTap = { [weak self] id in
                    Task { await self?.yieldEvent(.textOverlayTapped(id)) }
                }
            }
        }

        private func applyGestureZoom(_ factor: CGFloat) {
            delegate.setZoomFactorClamped(factor)
        }

        private func applyTapToFocus(_ point: CGPoint) {
            delegate.focusAndExpose(at: point)
        }
    #endif

    func setVisualZoom(
        factor: CGFloat,
        anchorX: CGFloat,
        anchorY: CGFloat
    ) async {
        #if os(iOS)
            let clamped = Float(min(max(factor, 1.0), 5.0))
            let clampedAX = Float(min(max(anchorX, 0.0), 1.0))
            let clampedAY = Float(min(max(anchorY, 0.0), 1.0))
            currentVisualZoom = (clamped, clampedAX, clampedAY)
            let renderer = metalRenderer
            await MainActor.run {
                renderer?.setVisualZoom(factor: clamped, anchorX: clampedAX, anchorY: clampedAY)
            }
            yieldEvent(.zoomChanged(CGFloat(clamped)))
        #endif
    }

    // MARK: - Hardware Exposure / White Balance / Torch

    #if os(iOS)
        func setExposureBias(_ bias: Float) async throws {
            logger("Setting exposure bias to \(bias) EV")
            try delegate.setExposureBias(bias)
        }

        func exposureBiasRange() async -> ClosedRange<Float> {
            delegate.exposureBiasRange()
        }

        func setWhiteBalanceKelvin(_ kelvin: Float) async throws {
            logger("Setting white balance to \(kelvin)K")
            try delegate.setWhiteBalanceKelvin(kelvin)
        }

        func zoomFactorRange() async -> ClosedRange<CGFloat> {
            delegate.zoomFactorRange()
        }

        func setTorchLevel(_ level: Float) async throws {
            logger("Setting torch level to \(level)")
            try delegate.setTorchLevel(level)
        }
    #endif

    // MARK: - Authorization

    func requestAuthorization() async -> PhotoCaptureClient.AuthorizationStatus {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        return granted ? .authorized : .denied
    }

    nonisolated func authorizationStatus() -> PhotoCaptureClient.AuthorizationStatus {
        AVAuthorizationStatus.from(AVCaptureDevice.authorizationStatus(for: .video))
    }

    // MARK: - Streams

    func observeEvents() -> AsyncStream<PhotoCaptureClient.Event> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    private func removeContinuation(id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    // MARK: - Frame Delivery

    func observePixelBuffers() -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper> {
        // bufferingNewest(1): if inference falls behind, keep only the latest frame so detection
        // never chews through a backlog staler than the live preview (and never pins pool buffers).
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // The delegate writes directly into this continuation from the video data queue.
            // Only one subscriber is supported at a time (last subscriber wins).
            let subscriberID = UUID()
            pixelBufferSubscriberID = subscriberID
            delegate.pixelBufferContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearPixelBufferContinuation(subscriberID: subscriberID) }
            }
        }
    }

    // The termination hop is async, so a stale subscriber must not clear its successor's continuation.
    private func clearPixelBufferContinuation(subscriberID: UUID) {
        guard pixelBufferSubscriberID == subscriberID else { return }
        pixelBufferSubscriberID = nil
        delegate.pixelBufferContinuation = nil
    }

    // MARK: - Preview

    #if os(iOS)
        func getPreviewView() -> PhotoCaptureClient.PreviewView {
            if let cached = cachedPreviewView {
                return cached
            }
            let preview: PhotoCaptureClient.PreviewView
            if let renderer = metalRenderer {
                preview = PhotoCaptureClient.PreviewView(view: renderer)
                renderer.previewViewRef = preview
                // Sync current visual zoom state
                preview.visualZoomFactor = currentVisualZoom.factor
                preview.visualZoomAnchorX = currentVisualZoom.anchorX
                preview.visualZoomAnchorY = currentVisualZoom.anchorY
            } else {
                preview = PhotoCaptureClient.PreviewView(view: UIView())
            }
            cachedPreviewView = preview
            return preview
        }

        func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {
            metalRenderer?.updateOverlays(overlays)
        }

        func updateTextOverlays(_ overlays: [PhotoCaptureClient.TextOverlay]) {
            metalRenderer?.updateTextOverlays(overlays)
        }

        func setLabelsVisible(_ visible: Bool) {
            metalRenderer?.setLabelsVisible(visible)
        }

        func setOverlayStyle(_ style: PhotoCaptureClient.OverlayStyle) {
            metalRenderer?.setOverlayStyle(style)
        }

        func setHistogramVisible(_ visible: Bool) {
            metalRenderer?.setHistogramVisible(visible)
        }

        func setHistogramConfig(_ config: Histogram.Config) {
            metalRenderer?.setHistogramConfig(config)
        }

        func setChannelGains(_ gains: SIMD4<Float>) {
            metalRenderer?.setChannelGains(gains)
        }
    #endif

    // MARK: - Helpers

    private func yieldEvent(_ event: PhotoCaptureClient.Event) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }
}
