@preconcurrency import AVFoundation
import CoreMedia
import PhotoCaptureClient
import Foundation

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

	// Direct continuation for frame delivery — avoids actor hop per frame
	var pixelBufferContinuation: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation?

	// Throttling: only deliver a frame every 200ms (~5fps)
	private let frameIntervalSeconds: CFTimeInterval = 0.2
	private var lastFrameTime: CFTimeInterval = 0

	// Framework objects — owned by the delegate, never by the actor
	private(set) var captureSession: AVCaptureSession?
	private(set) var photoOutput: AVCapturePhotoOutput?
	private(set) var currentDevice: AVCaptureDevice?
	private(set) var currentInput: AVCaptureDeviceInput?
	private(set) var videoPreviewLayer: AVCaptureVideoPreviewLayer?
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
		if session.canAddOutput(videoOutput) {
			session.addOutput(videoOutput)
			self.videoDataOutput = videoOutput
		}

		session.commitConfiguration()

		// Create preview layer
		let preview = AVCaptureVideoPreviewLayer(session: session)
		preview.videoGravity = .resizeAspectFill

		self.captureSession = session
		self.photoOutput = output
		self.currentDevice = device
		self.currentInput = input
		self.videoPreviewLayer = preview
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
		captureSession = nil
		photoOutput = nil
		currentDevice = nil
		currentInput = nil
		videoPreviewLayer = nil
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
		// Throttle: skip frames if we're delivering too fast
		let now = CACurrentMediaTime()
		guard now - lastFrameTime >= frameIntervalSeconds else { return }
		lastFrameTime = now

		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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

		// Yield directly into the continuation — no actor hop needed
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

	func getPreviewLayer() -> PhotoCaptureClient.PreviewLayer {
		if let layer = delegate.videoPreviewLayer {
			return PhotoCaptureClient.PreviewLayer(layer: layer)
		}
		return PhotoCaptureClient.PreviewLayer(layer: CALayer())
	}

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
