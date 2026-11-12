#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Foundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    /// Sendable wrapper for CMSampleBuffer to cross isolation boundaries.
    private final class SendableSampleBuffer: @unchecked Sendable {
        let buffer: CMSampleBuffer
        init(_ buffer: CMSampleBuffer) { self.buffer = buffer }
    }

    /// Coordinating actor for multi-camera sessions, preview, and recording.
    /// Follows the same pattern as PhotoCaptureClientActor.
    actor MultiCamClientActor {
        private let delegate = MultiCamSessionDelegate()
        let recordingPipeline = RecordingPipeline()
        private let logger: @Sendable (String) -> Void

        private var compositor: MultiCamCompositor?
        private var cachedPreviewView: MultiCamClient.PreviewView?
        private var currentLayout: MultiCamClient.Layout = .grid(.init())
        private var activeCameras: [MultiCamClient.CameraID] = []
        private var isRecording = false
        private var pipGestureCallbacks: MultiCamClient.PiPGestureCallbacks = .none
        private var histogramVisible = false
        private var histogramConfig = HistogramConfig.default

        private var eventContinuations: [UUID: AsyncStream<MultiCamClient.Event>.Continuation] = [:]
        private var pixelBufferContinuations:
            [MultiCamClient.CameraID: [UUID: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation]] = [:]
        /// Atomic flag: true if any pixel buffer observers exist. Checked from capture queues without actor hop.
        private let _hasPixelBufferObservers = OSAllocatedUnfairLock(initialState: false)

        // MARK: - Init

        init(
            logger: @escaping @Sendable (String) -> Void = { message in
                #if DEBUG
                    print("📹 [MULTI_CAM]: \(message)")
                #endif
            }
        ) {
            self.logger = logger

            delegate.onEvent = { [weak self] event in
                Task { await self?.yieldEvent(event) }
            }
        }

        // MARK: - Capability

        nonisolated func queryCapability() -> MultiCamClient.DeviceCapability {
            guard AVCaptureMultiCamSession.isMultiCamSupported else {
                return MultiCamClient.DeviceCapability(
                    isMultiCamSupported: false,
                    availableCameraSets: [],
                    maxSimultaneousCameras: 0
                )
            }

            // Use Apple's discovery API to get real valid multi-cam combinations
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [
                    .builtInWideAngleCamera,
                    .builtInUltraWideCamera,
                    .builtInTelephotoCamera,
                ],
                mediaType: .video,
                position: .unspecified
            )

            let cameraSets = sortedByPreference(
                collectCameraSets(from: discovery.supportedMultiCamDeviceSets)
            )

            return MultiCamClient.DeviceCapability(
                isMultiCamSupported: true,
                availableCameraSets: cameraSets,
                maxSimultaneousCameras: cameraSets.map(\.count).max() ?? 2
            )
        }

        /// Every unique camera set the device supports: each discovered full set plus every
        /// 2-camera subset of it, de-duplicated by their sorted-id key.
        private nonisolated func collectCameraSets(
            from deviceSets: [Set<AVCaptureDevice>]
        ) -> [[MultiCamClient.CameraID]] {
            var seen = Set<String>()
            return
                deviceSets
                .compactMap { deviceSet -> [MultiCamClient.CameraID]? in
                    let ids = deviceSet.compactMap { mapDeviceToCameraID($0) }
                    guard !ids.isEmpty else { return nil }
                    return ids.sorted { $0.rawValue < $1.rawValue }
                }
                .flatMap { sorted in [sorted] + cameraPairs(from: sorted) }
                .filter { seen.insert($0.map(\.rawValue).joined(separator: ",")).inserted }
        }

        /// Orders camera sets with the larger sets first, then alphabetically by id.
        private nonisolated func sortedByPreference(
            _ cameraSets: [[MultiCamClient.CameraID]]
        ) -> [[MultiCamClient.CameraID]] {
            cameraSets.sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.map(\.rawValue).joined() < b.map(\.rawValue).joined()
            }
        }

        /// All unique 2-camera pairs within a 3+ camera set, for `queryCapability`'s subset expansion.
        private nonisolated func cameraPairs(
            from sorted: [MultiCamClient.CameraID]
        ) -> [[MultiCamClient.CameraID]] {
            guard sorted.count > 2 else { return [] }
            var pairs: [[MultiCamClient.CameraID]] = []
            for i in 0..<sorted.count {
                for j in (i + 1)..<sorted.count {
                    pairs.append([sorted[i], sorted[j]])
                }
            }
            return pairs
        }

        private nonisolated func mapDeviceToCameraID(_ device: AVCaptureDevice) -> MultiCamClient.CameraID? {
            switch (device.deviceType, device.position) {
                case (.builtInWideAngleCamera, .front): return .frontWide
                case (.builtInWideAngleCamera, .back): return .backWide
                case (.builtInUltraWideCamera, .back): return .backUltraWide
                case (.builtInTelephotoCamera, .back): return .backTelephoto
                default: return nil
            }
        }

        // MARK: - Session Lifecycle

        func startSession(_ config: MultiCamClient.SessionConfiguration) async throws {
            guard !delegate.isRunning else {
                throw MultiCamClient.Error.sessionAlreadyRunning
            }

            logger("Configuring multi-cam session with \(config.cameras.map(\.rawValue))")
            try delegate.configureSession(config)
            delegate.registerNotificationObservers()

            // Use actual cameras that were successfully added (may be fewer if hardware cost exceeded)
            activeCameras = delegate.activeCameras
            logger(
                "Active cameras: \(activeCameras.map(\.rawValue)), hardware cost: \(String(format: "%.2f", delegate.lastHardwareCost))"
            )

            // FIX: Compositor uses actual active cameras (not requested), in case some were dropped
            let actualCameras = activeCameras
            let comp = await createCompositor(for: actualCameras)
            self.compositor = comp
            if comp == nil {
                yieldEvent(.sessionError("Metal compositor unavailable — preview disabled"))
            }

            wireCompositorCallbacks(compositor: comp)

            // Invalidate cached preview
            cachedPreviewView = nil

            logger("Starting multi-cam session")
            delegate.startRunning()

            emitConnectionEvents(activeCameras: activeCameras, requestedCameras: config.cameras)
        }

        /// Creates and configures a fresh compositor for the given active cameras, restoring the
        /// persisted layout/callbacks/histogram state so a session restart is seamless.
        private func createCompositor(
            for cameras: [MultiCamClient.CameraID]
        ) async -> MultiCamCompositor? {
            let layout = currentLayout
            let savedCallbacks = pipGestureCallbacks
            let savedHistogramVisible = histogramVisible
            let savedHistogramConfig = histogramConfig
            return await MainActor.run {
                let comp = MultiCamCompositor.create()
                // setLayout first (may override _cameras for stale custom layouts),
                // then setCameras to restore the correct camera list and recompute viewports.
                comp?.setLayout(layout)
                comp?.setCameras(cameras)
                // Re-apply persisted gesture callbacks so the consumer doesn't have to
                // re-install them on every session restart.
                comp?.setGestureCallbacks(savedCallbacks)
                comp?.setHistogramConfig(savedHistogramConfig)
                comp?.setHistogramVisible(savedHistogramVisible)
                return comp
            }
        }

        /// Wires delegate → compositor + recording pipeline + pixel buffer streams.
        /// Recording pipeline is called SYNCHRONOUSLY here to ensure CMSampleBuffer
        /// is still valid (AVFoundation recycles buffers after the delegate returns).
        private func wireCompositorCallbacks(compositor comp: MultiCamCompositor?) {
            let pipeline = recordingPipeline
            let del = delegate
            delegate.onVideoFrame = { [weak self, weak comp, weak del] cameraID, sampleBuffer in
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                comp?.enqueueFrame(pixelBuffer, for: cameraID)

                // Store latest frame for photo capture (lightweight lock)
                del?.storeLatestPixelBuffer(pixelBuffer, for: cameraID)

                // Feed recording pipeline synchronously (before buffer is recycled)
                pipeline.appendVideoSample(sampleBuffer, for: cameraID)

                // Feed pixel buffer streams only if observers exist (avoid per-frame Task allocation)
                if self?._hasPixelBufferObservers.withLock({ $0 }) == true {
                    let wrapped = SendableSampleBuffer(sampleBuffer)
                    Task { [weak self] in
                        await self?.deliverPixelBuffer(cameraID: cameraID, sampleBuffer: wrapped)
                    }
                }
            }

            delegate.onAudioSample = { sampleBuffer in
                pipeline.appendAudioSample(sampleBuffer)
            }
        }

        /// Emits `cameraConnected` for cameras that passed the hardware cost check, and
        /// `cameraDisconnected` for any requested camera that was dropped.
        private func emitConnectionEvents(
            activeCameras: [MultiCamClient.CameraID],
            requestedCameras: [MultiCamClient.CameraID]
        ) {
            for camera in activeCameras {
                yieldEvent(.cameraConnected(camera))
            }
            let dropped = requestedCameras.filter { !activeCameras.contains($0) }
            for camera in dropped {
                yieldEvent(.cameraDisconnected(camera))
            }
        }

        func stopSession() async {
            logger("Stopping multi-cam session (isRunning=\(delegate.isRunning))")

            if isRecording {
                if let result = try? await recordingPipeline.stopRecording() {
                    yieldEvent(.recordingStopped(result))
                }
                isRecording = false
            }

            delegate.onVideoFrame = nil
            delegate.onAudioSample = nil
            compositor = nil
            cachedPreviewView = nil
            delegate.teardown()

            for (_, continuations) in pixelBufferContinuations {
                for continuation in continuations.values {
                    continuation.finish()
                }
            }
            pixelBufferContinuations.removeAll()

            for continuation in eventContinuations.values {
                continuation.finish()
            }
            eventContinuations.removeAll()

            activeCameras = []
        }

        // MARK: - Layout

        func setLayout(_ layout: MultiCamClient.Layout) async {
            currentLayout = layout
            let comp = compositor
            await MainActor.run { comp?.setLayout(layout) }
            yieldEvent(.layoutChanged(layout))
        }

        func setCameraOrder(_ cameras: [MultiCamClient.CameraID]) async {
            activeCameras = cameras
            let comp = compositor
            let layout = currentLayout
            await MainActor.run {
                comp?.setCameras(cameras)
                comp?.setLayout(layout)
            }
        }

        func getLayout() -> MultiCamClient.Layout {
            currentLayout
        }

        // MARK: - Zoom

        func setPiPBorder(
            width: Float,
            color: SIMD4<Float>
        ) async {
            let comp = compositor
            await MainActor.run {
                comp?.borderWidth = width
                comp?.borderColor = color
            }
        }

        /// Fast-path live origin update for a PiP overlay during drag.
        /// Skips event broadcast and full layout recompute; canonical state is the caller's responsibility.
        func setPiPOverlayPosition(
            camera: MultiCamClient.CameraID,
            position: CGPoint
        ) async {
            let comp = compositor
            await MainActor.run {
                comp?.updateOverlayOrigin(camera: camera, origin: position)
            }
        }

        /// Install (or replace) the gesture-callback bundle the compositor uses for PiP
        /// drag/pinch. Persisted as actor state so it survives session restart — the new
        /// compositor created in `startSession` automatically picks them up.
        func setPiPGestureCallbacks(_ callbacks: MultiCamClient.PiPGestureCallbacks) async {
            pipGestureCallbacks = callbacks
            let comp = compositor
            await MainActor.run { comp?.setGestureCallbacks(callbacks) }
        }

        /// Show or hide the live histogram. Persisted as actor state so a compositor rebuilt in
        /// `startSession` restores it without the consumer re-installing it.
        func setHistogramVisible(_ visible: Bool) async {
            histogramVisible = visible
            let comp = compositor
            await MainActor.run { comp?.setHistogramVisible(visible) }
        }

        /// Update the live histogram's config. Persisted like `setHistogramVisible` so a
        /// compositor rebuilt in `startSession` restores it.
        func setHistogramConfig(_ config: HistogramConfig) async {
            histogramConfig = config
            let comp = compositor
            await MainActor.run { comp?.setHistogramConfig(config) }
        }

        func setTorch(mode: MultiCamClient.TorchMode) {
            delegate.setTorch(mode: mode)
            logger("Torch set to \(mode.rawValue)")
        }

        func setStabilization(
            camera: MultiCamClient.CameraID,
            mode: MultiCamClient.StabilizationMode
        ) {
            delegate.setStabilization(for: camera, mode: mode)
            logger("Stabilization set to \(mode.rawValue) for \(camera.rawValue)")
        }

        func setZoom(
            camera: MultiCamClient.CameraID,
            factor: CGFloat
        ) throws {
            try delegate.setZoom(for: camera, factor: factor)
            yieldEvent(.zoomChanged(camera, factor))
        }

        func zoomRange(camera: MultiCamClient.CameraID) -> (min: CGFloat, max: CGFloat) {
            delegate.zoomRange(for: camera)
        }

        // MARK: - Recording

        func startRecording(_ config: MultiCamClient.RecordingConfiguration) async throws {
            guard delegate.isRunning else {
                throw MultiCamClient.Error.sessionNotRunning
            }
            guard !activeCameras.isEmpty else {
                throw MultiCamClient.Error.cameraSetNotSupported([])
            }
            guard !isRecording else {
                throw MultiCamClient.Error.recordingAlreadyInProgress
            }

            let (cameraSize, compositeSize) = await recordingSizes(forOutputWidth: config.outputWidth)
            try recordingPipeline.startRecording(
                config: config,
                cameras: activeCameras,
                cameraSize: cameraSize,
                compositeSize: compositeSize
            )

            await wireRecordingOutput(size: compositeSize)

            isRecording = true
            yieldEvent(.recordingStarted)
            logger("Recording started (with real-time compositing)")
        }

        /// Computes the per-camera writer size and the screen-aspect-matched composite size
        /// used by `startRecording`.
        private func recordingSizes(
            forOutputWidth outputWidth: Int
        ) async -> (cameraSize: CGSize, compositeSize: CGSize) {
            // Per-camera writers use standard 9:16 portrait (matches camera pixel buffer
            // dimensions) — the transpose of the existing 16:9 `Resolution.hd1080p` dimensions.
            let cameraSize = CGSize(
                width: CGFloat(MultiCamClient.Resolution.hd1080p.height),
                height: CGFloat(MultiCamClient.Resolution.hd1080p.width)
            )

            // Compositor uses screen aspect ratio so viewport rects map correctly
            let screenBounds = await MainActor.run { UIScreen.main.bounds }
            let screenAR = screenBounds.width / screenBounds.height
            let compositeWidth = max(2, outputWidth)
            let rawCompH = Int((CGFloat(compositeWidth) / screenAR).rounded())
            let compositeSize = CGSize(width: compositeWidth, height: rawCompH + (rawCompH % 2))

            return (cameraSize, compositeSize)
        }

        /// Enables compositor offscreen recording and wires its composed-frame callback to the
        /// recording pipeline.
        private func wireRecordingOutput(size compositeSize: CGSize) async {
            let pipeline = recordingPipeline
            let comp = compositor
            await MainActor.run {
                comp?.configureRecordingOutput(size: compositeSize)
                comp?.onRecordingFrame = { pixelBuffer, time in
                    pipeline.appendComposedFrame(pixelBuffer, at: time)
                }
                comp?.isRecording = true
            }
        }

        func pauseRecording() async {
            guard isRecording else { return }
            recordingPipeline.pause()
            let comp = compositor
            await MainActor.run { comp?.isRecording = false }
            yieldEvent(.recordingPaused)
            logger("Recording paused")
        }

        func resumeRecording() async {
            guard isRecording else { return }
            recordingPipeline.resume()
            let comp = compositor
            await MainActor.run { comp?.isRecording = true }
            yieldEvent(.recordingResumed)
            logger("Recording resumed")
        }

        func capturePhoto(camera: MultiCamClient.CameraID) throws -> PhotoCaptureClient.Photo {
            guard delegate.isRunning else {
                throw MultiCamClient.Error.sessionNotRunning
            }
            guard let photo = delegate.capturePhoto(for: camera) else {
                throw MultiCamClient.Error.cameraSetNotSupported([camera])
            }
            yieldEvent(.photoCaptured(camera))
            return photo
        }

        func captureCompositePhoto(outputSize: CGSize) async throws -> MultiCamClient.CompositePhotoCaptureResult {
            guard delegate.isRunning else {
                throw MultiCamClient.Error.sessionNotRunning
            }

            // 1. Composite photo from Metal compositor
            let comp = compositor
            let combinedPhoto: PhotoCaptureClient.Photo? = await MainActor.run {
                comp?.captureCompositePhoto(outputSize: outputSize)
            }

            // 2. Individual per-camera photos
            var individualPhotos: [MultiCamClient.CameraID: PhotoCaptureClient.Photo] = [:]
            for camera in activeCameras {
                if let photo = delegate.capturePhoto(for: camera) {
                    individualPhotos[camera] = photo
                }
            }

            return MultiCamClient.CompositePhotoCaptureResult(
                combinedPhoto: combinedPhoto,
                individualPhotos: individualPhotos
            )
        }

        func stopRecording() async throws -> MultiCamClient.RecordingResult {
            guard isRecording else {
                throw MultiCamClient.Error.recordingNotInProgress
            }

            // Stop compositor recording first
            let comp = compositor
            await MainActor.run {
                comp?.isRecording = false
                comp?.onRecordingFrame = nil
            }

            let result = try await recordingPipeline.stopRecording()
            isRecording = false
            yieldEvent(.recordingStopped(result))
            logger("Recording stopped: duration=\(result.duration)s, combined=\(result.combinedURL != nil)")
            return result
        }

        // MARK: - Authorization

        func requestAuthorization() async -> PhotoCaptureClient.AuthorizationStatus {
            let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
            let audioGranted = await AVCaptureDevice.requestAccess(for: .audio)
            return (videoGranted && audioGranted) ? .authorized : .denied
        }

        nonisolated func authorizationStatus() -> PhotoCaptureClient.AuthorizationStatus {
            let video = AVCaptureDevice.authorizationStatus(for: .video)
            let audio = AVCaptureDevice.authorizationStatus(for: .audio)
            guard bothAuthorized(video: video, audio: audio) else {
                if eitherNotDetermined(video: video, audio: audio) { return .notDetermined }
                if eitherRestricted(video: video, audio: audio) { return .restricted }
                return .denied
            }
            return .authorized
        }

        private nonisolated func bothAuthorized(
            video: AVAuthorizationStatus,
            audio: AVAuthorizationStatus
        ) -> Bool {
            video == .authorized && audio == .authorized
        }

        private nonisolated func eitherNotDetermined(
            video: AVAuthorizationStatus,
            audio: AVAuthorizationStatus
        ) -> Bool {
            video == .notDetermined || audio == .notDetermined
        }

        private nonisolated func eitherRestricted(
            video: AVAuthorizationStatus,
            audio: AVAuthorizationStatus
        ) -> Bool {
            video == .restricted || audio == .restricted
        }

        // MARK: - Preview

        /// Returns the cached preview view, creating, caching and wiring it to the compositor
        /// on first call. The `ensure` prefix admits that side effect; a `get` would not.
        func ensurePreviewView() async -> MultiCamClient.PreviewView {
            if let cached = cachedPreviewView {
                return cached
            }
            let comp = compositor
            let layout = currentLayout
            let preview = await MainActor.run {
                if let comp {
                    let pv = MultiCamClient.PreviewView(view: comp, layout: layout)
                    comp.previewViewRef = pv
                    return pv
                } else {
                    return MultiCamClient.PreviewView(view: UIView(), layout: layout)
                }
            }
            cachedPreviewView = preview
            return preview
        }

        // MARK: - Streams

        func observeEvents() -> AsyncStream<MultiCamClient.Event> {
            let id = UUID()
            return AsyncStream { continuation in
                eventContinuations[id] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removeEventContinuation(id: id) }
                }
            }
        }

        private func removeEventContinuation(id: UUID) {
            eventContinuations.removeValue(forKey: id)
        }

        func observePixelBuffers(for camera: MultiCamClient.CameraID) -> AsyncStream<
            PhotoCaptureClient.PixelBufferWrapper
        > {
            let id = UUID()
            return AsyncStream { continuation in
                if pixelBufferContinuations[camera] == nil {
                    pixelBufferContinuations[camera] = [:]
                }
                pixelBufferContinuations[camera]?[id] = continuation
                _hasPixelBufferObservers.withLock { $0 = true }
                continuation.onTermination = { [weak self] _ in
                    Task { await self?.removePixelBufferContinuation(camera: camera, id: id) }
                }
            }
        }

        private func removePixelBufferContinuation(
            camera: MultiCamClient.CameraID,
            id: UUID
        ) {
            pixelBufferContinuations[camera]?.removeValue(forKey: id)
            // Update atomic flag
            let hasAny = pixelBufferContinuations.values.contains { !$0.isEmpty }
            _hasPixelBufferObservers.withLock { $0 = hasAny }
        }

        // MARK: - Internal Frame Delivery

        private func deliverPixelBuffer(
            cameraID: MultiCamClient.CameraID,
            sampleBuffer: SendableSampleBuffer
        ) {
            // Yield to per-camera pixel buffer streams
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer.buffer) else { return }
            let wrapper = PhotoCaptureClient.PixelBufferWrapper(
                pixelBuffer: pixelBuffer,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                timestamp: .now
            )

            if let continuations = pixelBufferContinuations[cameraID] {
                for continuation in continuations.values {
                    continuation.yield(wrapper)
                }
            }
        }

        // MARK: - Helpers

        private func yieldEvent(_ event: MultiCamClient.Event) {
            for continuation in eventContinuations.values {
                continuation.yield(event)
            }
        }
    }
#endif
