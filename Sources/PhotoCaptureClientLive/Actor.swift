@preconcurrency import AVFoundation
import CoreMedia
import PhotoCaptureClient
import Foundation
import os

#if os(iOS)
import UIKit
import MetalKit
#else
import AppKit
#endif

// MARK: - Delegate

/// Private delegate class that bridges AVCapturePhotoCaptureDelegate callbacks
/// and session notifications to the actor. Inherits NSObject for delegate
/// protocol conformance and conforms to `@unchecked Sendable` to safely
/// cross isolation boundaries.
private final class PhotoCaptureDelegate: NSObject, @unchecked Sendable {
	// Callback closures — actor sets these in init
	var onEvent: (@Sendable (PhotoCaptureClient.Event) -> Void)?
	var onLog: (@Sendable (String) -> Void)?

	// Per-capture continuation — set before each capturePhoto call
	var photoContinuation: CheckedContinuation<PhotoCaptureClient.Photo, any Swift.Error>?

	// Frame delivery properties
	private(set) var videoDataOutput: AVCaptureVideoDataOutput?
	private let videoDataQueue = DispatchQueue(label: "PhotoCaptureDelegate.videoDataQueue")

	// Thread-safe continuation for frame delivery.
	// Written from actor context (observePixelBuffers), read from videoDataQueue (captureOutput).
	private let _pixelBufferContinuation = OSAllocatedUnfairLock<AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation?>(initialState: nil)

	var pixelBufferContinuation: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation? {
		get { _pixelBufferContinuation.withLock { $0 } }
		set { _pixelBufferContinuation.withLock { $0 = newValue } }
	}

	// Throttling: only deliver a frame every 333ms (~3fps) for YOLO inference.
	// 3fps is visually smooth for detection boxes while reducing ~40% inference CPU.
	private let frameIntervalSeconds: CFTimeInterval = 0.333
	private var lastFrameTime: CFTimeInterval = 0

	// Metal renderer callback — receives every frame at full camera rate (no throttling)
	var onFrame: ((_ pixelBuffer: CVPixelBuffer) -> Void)?

	// Framework objects — owned by the delegate, never by the actor
	private(set) var captureSession: AVCaptureSession?
	private(set) var photoOutput: AVCapturePhotoOutput?
	private(set) var currentDevice: AVCaptureDevice?
	private(set) var currentInput: AVCaptureDeviceInput?
	private let sessionQueue = DispatchQueue(label: "PhotoCaptureDelegate.sessionQueue")

	var isRunning: Bool {
		captureSession?.isRunning ?? false
	}

	// MARK: - Session Lifecycle

	func configureSession(position: PhotoCaptureClient.CameraPosition) throws {
		let session = AVCaptureSession()
		session.beginConfiguration()
		session.sessionPreset = .photo

		// Find camera device
		let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
		guard let device = AVCaptureDevice.default(
			.builtInWideAngleCamera,
			for: .video,
			position: avPosition
		) else {
			session.commitConfiguration()
			throw PhotoCaptureClient.Error.captureDeviceNotFound(position)
		}

		// Add input
		let input = try AVCaptureDeviceInput(device: device)
		guard session.canAddInput(input) else {
			session.commitConfiguration()
			throw PhotoCaptureClient.Error.cannotAddInput
		}
		session.addInput(input)

		// Add output
		let output = AVCapturePhotoOutput()
		guard session.canAddOutput(output) else {
			session.commitConfiguration()
			throw PhotoCaptureClient.Error.cannotAddOutput
		}
		session.addOutput(output)

		// Add video data output for frame delivery
		let videoOutput = AVCaptureVideoDataOutput()
		videoOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
		videoOutput.alwaysDiscardsLateVideoFrames = true
		videoOutput.videoSettings = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
		]
		if session.canAddOutput(videoOutput) {
			session.addOutput(videoOutput)
			self.videoDataOutput = videoOutput
		}

		// Cap camera frame delivery to 30fps to reduce CPU load.
		// The Metal renderer draws on-demand per frame, so 30fps is sufficient for preview.
		if let _ = try? device.lockForConfiguration() {
			device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
			device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
			device.unlockForConfiguration()
		}

		session.commitConfiguration()

		self.captureSession = session
		self.photoOutput = output
		self.currentDevice = device
		self.currentInput = input

		// Apply rotation/mirroring AFTER commitConfiguration — connections aren't fully
		// wired before commit on iOS 17+, and unsupported angles silently no-op without
		// the explicit support check.
		applyConnectionOrientation(position: position)
	}

	/// Force every active output connection into portrait + mirror the front camera
	/// so the preview, video frames, and captured photo all share orientation.
	/// Called after `configureSession` and after every `switchCamera` so the input
	/// swap doesn't reset rotation back to the sensor default.
	private func applyConnectionOrientation(position: PhotoCaptureClient.CameraPosition) {
		let mirror = position == .front
		let connections: [AVCaptureConnection?] = [
			videoDataOutput?.connection(with: .video),
			photoOutput?.connection(with: .video),
		]
		for case let connection? in connections {
			if connection.isVideoRotationAngleSupported(90) {
				connection.videoRotationAngle = 90
			}
			if connection.isVideoMirroringSupported {
				connection.automaticallyAdjustsVideoMirroring = false
				connection.isVideoMirrored = mirror
			}
		}
	}

	func startRunning() {
		sessionQueue.async { [weak self] in
			self?.captureSession?.startRunning()
		}
	}

	func stopRunning() {
		sessionQueue.async { [weak self] in
			self?.captureSession?.stopRunning()
		}
	}

	func switchCamera(to position: PhotoCaptureClient.CameraPosition) throws {
		guard let session = captureSession else {
			throw PhotoCaptureClient.Error.captureSessionNotRunning
		}

		let avPosition: AVCaptureDevice.Position = position == .front ? .front : .back
		guard let newDevice = AVCaptureDevice.default(
			.builtInWideAngleCamera,
			for: .video,
			position: avPosition
		) else {
			throw PhotoCaptureClient.Error.captureDeviceNotFound(position)
		}

		let newInput = try AVCaptureDeviceInput(device: newDevice)

		session.beginConfiguration()
		if let currentInput {
			session.removeInput(currentInput)
		}
		guard session.canAddInput(newInput) else {
			if let currentInput {
				session.addInput(currentInput)
			}
			session.commitConfiguration()
			throw PhotoCaptureClient.Error.cannotAddInput
		}
		session.addInput(newInput)
		session.commitConfiguration()

		self.currentDevice = newDevice
		self.currentInput = newInput

		applyConnectionOrientation(position: position)
	}

	func capturePhoto(settings: PhotoCaptureClient.PhotoSettings) {
		let avSettings = AVCapturePhotoSettings()
		avSettings.flashMode = settings.flashMode.avFlashMode
		avSettings.photoQualityPrioritization = settings.qualityPrioritization.avQualityPrioritization
		photoOutput?.capturePhoto(with: avSettings, delegate: self)
	}

	func focus(at point: CGPoint) throws {
		guard let device = currentDevice else {
			throw PhotoCaptureClient.Error.captureSessionNotRunning
		}
		guard device.isFocusModeSupported(.autoFocus) else {
			throw PhotoCaptureClient.Error.focusModeNotSupported
		}
		try device.lockForConfiguration()
		device.focusPointOfInterest = point
		device.focusMode = .autoFocus
		device.unlockForConfiguration()
	}

	#if os(iOS)
	func setZoomFactor(_ factor: CGFloat) throws {
		guard let device = currentDevice else {
			throw PhotoCaptureClient.Error.captureSessionNotRunning
		}
		let minZoom = device.minAvailableVideoZoomFactor
		let maxZoom = device.maxAvailableVideoZoomFactor
		guard factor >= minZoom && factor <= maxZoom else {
			throw PhotoCaptureClient.Error.zoomFactorOutOfRange(min: minZoom, max: maxZoom)
		}
		try device.lockForConfiguration()
		device.videoZoomFactor = factor
		device.unlockForConfiguration()
	}
	#else
	func setZoomFactor(_ factor: CGFloat) throws {
		throw PhotoCaptureClient.Error.cameraUnavailable
	}
	#endif

	func teardown() {
		if let session = captureSession, session.isRunning {
			sessionQueue.async {
				session.stopRunning()
			}
		}
		removeNotificationObservers()
		pixelBufferContinuation?.finish()
		pixelBufferContinuation = nil
		videoDataOutput = nil
		onFrame = nil
		captureSession = nil
		photoOutput = nil
		currentDevice = nil
		currentInput = nil
	}

	// MARK: - Notification Observers

	func registerNotificationObservers() {
		let nc = NotificationCenter.default
		nc.addObserver(self, selector: #selector(sessionDidStartRunning),
		               name: .AVCaptureSessionDidStartRunning, object: captureSession)
		nc.addObserver(self, selector: #selector(sessionDidStopRunning),
		               name: .AVCaptureSessionDidStopRunning, object: captureSession)
		nc.addObserver(self, selector: #selector(sessionRuntimeError),
		               name: .AVCaptureSessionRuntimeError, object: captureSession)
		#if os(iOS)
		nc.addObserver(self, selector: #selector(sessionWasInterrupted),
		               name: .AVCaptureSessionWasInterrupted, object: captureSession)
		nc.addObserver(self, selector: #selector(sessionInterruptionEnded),
		               name: .AVCaptureSessionInterruptionEnded, object: captureSession)
		#endif
	}

	func removeNotificationObservers() {
		NotificationCenter.default.removeObserver(self)
	}

	@objc private func sessionDidStartRunning(_ notification: Notification) {
		onEvent?(.sessionStarted)
	}

	@objc private func sessionDidStopRunning(_ notification: Notification) {
		onEvent?(.sessionStopped)
	}

	#if os(iOS)
	@objc private func sessionWasInterrupted(_ notification: Notification) {
		let reason: PhotoCaptureClient.InterruptionReason
		if let userInfo = notification.userInfo,
		   let rawReason = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int,
		   let avReason = AVCaptureSession.InterruptionReason(rawValue: rawReason) {
			reason = avReason.domainReason
		} else {
			reason = .unknown
		}
		onEvent?(.sessionInterrupted(reason))
	}

	@objc private func sessionInterruptionEnded(_ notification: Notification) {
		onEvent?(.sessionInterruptionEnded)
	}
	#endif

	@objc private func sessionRuntimeError(_ notification: Notification) {
		let message: String
		if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
			message = error.localizedDescription
		} else {
			message = "Unknown runtime error"
		}
		onEvent?(.sessionRuntimeError(message))
	}
}

// MARK: - AVCapturePhotoCaptureDelegate

extension PhotoCaptureDelegate: AVCapturePhotoCaptureDelegate {
	func photoOutput(
		_ output: AVCapturePhotoOutput,
		willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings
	) {
		onEvent?(.willBeginCapture)
	}

	func photoOutput(
		_ output: AVCapturePhotoOutput,
		willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
	) {
		onEvent?(.willCapturePhoto)
	}

	func photoOutput(
		_ output: AVCapturePhotoOutput,
		didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings
	) {
		onEvent?(.didCapturePhoto)
	}

	func photoOutput(
		_ output: AVCapturePhotoOutput,
		didFinishProcessingPhoto photo: AVCapturePhoto,
		error: (any Swift.Error)?
	) {
		if let error {
			photoContinuation?.resume(throwing: PhotoCaptureClient.Error.captureFailed(error.localizedDescription))
			photoContinuation = nil
			return
		}

		let dimensions = photo.resolvedSettings.photoDimensions
		#if os(iOS)
		let isRaw = photo.isRawPhoto
		#else
		let isRaw = false
		#endif
		let domainPhoto = PhotoCaptureClient.Photo(
			fileDataRepresentation: photo.fileDataRepresentation(),
			photoDimensions: CGSize(width: Int(dimensions.width), height: Int(dimensions.height)),
			timestamp: .now,
			isRawPhoto: isRaw
		)
		photoContinuation?.resume(returning: domainPhoto)
		photoContinuation = nil
	}

	func photoOutput(
		_ output: AVCapturePhotoOutput,
		didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
		error: (any Swift.Error)?
	) {
		onEvent?(.captureCompleted)

		// If didFinishProcessingPhoto was never called (e.g., error before processing)
		if let error, photoContinuation != nil {
			photoContinuation?.resume(throwing: PhotoCaptureClient.Error.captureFailed(error.localizedDescription))
			photoContinuation = nil
		}
	}
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PhotoCaptureDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
	func captureOutput(
		_ output: AVCaptureOutput,
		didOutput sampleBuffer: CMSampleBuffer,
		from connection: AVCaptureConnection
	) {
		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

		// Deliver every frame to Metal renderer at full camera rate
		onFrame?(pixelBuffer)

		// Throttle: only deliver frames for detection inference at ~5fps
		let now = CACurrentMediaTime()
		guard now - lastFrameTime >= frameIntervalSeconds else { return }
		lastFrameTime = now

		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

		let wrapper = PhotoCaptureClient.PixelBufferWrapper(
			pixelBuffer: pixelBuffer,
			width: width,
			height: height,
			bytesPerRow: bytesPerRow,
			timestamp: .now
		)

		pixelBufferContinuation?.yield(wrapper)
	}
}

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
		await MainActor.run { renderer?.resetVisualZoom() }
		yieldEvent(.zoomChanged(1.0))
		#endif
	}

	func setFlashMode(_ mode: PhotoCaptureClient.FlashMode) {
		logger("Setting flash mode to \(mode)")
		currentFlashMode = mode
	}

	func focus(at point: CGPoint) async throws {
		logger("Focusing at \(point)")
		try delegate.focus(at: point)
	}

	func setZoomFactor(_ factor: CGFloat) async throws {
		logger("Setting zoom factor to \(factor)")
		try delegate.setZoomFactor(factor)
	}

	func setVisualZoom(factor: CGFloat, anchorX: CGFloat, anchorY: CGFloat) async {
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
		return AsyncStream { continuation in
			// The delegate writes directly into this continuation from the video data queue.
			// Only one subscriber is supported at a time (last subscriber wins).
			delegate.pixelBufferContinuation = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.clearPixelBufferContinuation() }
			}
		}
	}

	private func clearPixelBufferContinuation() {
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
	#else
	func getPreviewView() -> PhotoCaptureClient.PreviewView {
		return PhotoCaptureClient.PreviewView(view: NSView())
	}

	func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {}
	#endif

	// MARK: - Helpers

	private func yieldEvent(_ event: PhotoCaptureClient.Event) {
		for continuation in eventContinuations.values {
			continuation.yield(event)
		}
	}
}

// MARK: - AVFoundation → Domain Conversions

extension PhotoCaptureClient.FlashMode {
	var avFlashMode: AVCaptureDevice.FlashMode {
		switch self {
		case .off: .off
		case .on: .on
		case .auto: .auto
		}
	}
}

extension PhotoCaptureClient.QualityPrioritization {
	var avQualityPrioritization: AVCapturePhotoOutput.QualityPrioritization {
		switch self {
		case .speed: .speed
		case .balanced: .balanced
		case .quality: .quality
		}
	}
}

extension AVAuthorizationStatus {
	static func from(_ status: AVAuthorizationStatus) -> PhotoCaptureClient.AuthorizationStatus {
		switch status {
		case .notDetermined: .notDetermined
		case .restricted: .restricted
		case .denied: .denied
		case .authorized: .authorized
		@unknown default: .notDetermined
		}
	}
}

#if os(iOS)
extension AVCaptureSession.InterruptionReason {
	var domainReason: PhotoCaptureClient.InterruptionReason {
		switch self {
		case .videoDeviceNotAvailableInBackground:
			.videoDeviceNotAvailableInBackground
		case .audioDeviceInUseByAnotherClient:
			.audioDeviceInUseByAnotherClient
		case .videoDeviceInUseByAnotherClient:
			.videoDeviceInUseByAnotherClient
		case .videoDeviceNotAvailableWithMultipleForegroundApps:
			.videoDeviceNotAvailableWithMultipleForegroundApps
		case .videoDeviceNotAvailableDueToSystemPressure:
			.videoDeviceNotAvailableDueToSystemPressure
		case .sensitiveContentMitigationActivated:
			.unknown
		@unknown default:
			.unknown
		}
	}
}
#endif
