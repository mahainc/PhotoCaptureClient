#if os(iOS)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MultiCamClient
import PhotoCaptureClient
import os

/// Bridges AVCaptureMultiCamSession to the actor. Owns all AVFoundation objects.
/// Follows the same delegate pattern as PhotoCaptureDelegate in PhotoCaptureClientLive.
final class MultiCamSessionDelegate: NSObject, @unchecked Sendable {

	// MARK: - Callbacks

	var onVideoFrame: ((_ cameraID: MultiCamClient.CameraID, _ sampleBuffer: CMSampleBuffer) -> Void)?
	var onAudioSample: ((_ sampleBuffer: CMSampleBuffer) -> Void)?
	var onEvent: (@Sendable (MultiCamClient.Event) -> Void)?

	// MARK: - AVFoundation State

	private(set) var multiCamSession: AVCaptureMultiCamSession?
	private var cameraInputs: [MultiCamClient.CameraID: AVCaptureDeviceInput] = [:]
	private var videoOutputs: [MultiCamClient.CameraID: AVCaptureVideoDataOutput] = [:]
	private var outputToCameraID: [ObjectIdentifier: MultiCamClient.CameraID] = [:]
	private var audioOutput: AVCaptureAudioDataOutput?

	// Per-camera dispatch queues
	private var videoQueues: [MultiCamClient.CameraID: DispatchQueue] = [:]
	private let audioQueue = DispatchQueue(label: "MultiCamDelegate.audio")
	private let sessionQueue = DispatchQueue(label: "MultiCamDelegate.session")

	var isRunning: Bool {
		multiCamSession?.isRunning ?? false
	}

	// MARK: - Session Configuration

	/// The hardware cost after session configuration (0.0–1.0). Values >= 1.0 may cause issues.
	private(set) var lastHardwareCost: Float = 0

	/// Cameras that were actually added successfully (may be fewer than requested if cost exceeded).
	private(set) var activeCameras: [MultiCamClient.CameraID] = []

	func configureSession(_ config: MultiCamClient.SessionConfiguration) throws {
		guard AVCaptureMultiCamSession.isMultiCamSupported else {
			throw MultiCamClient.Error.multiCamNotSupported
		}

		let session = AVCaptureMultiCamSession()
		session.beginConfiguration()

		var addedCameras: [MultiCamClient.CameraID] = []

		for cameraID in config.cameras {
			let avPosition = cameraID.avPosition
			let deviceType = cameraID.avDeviceType

			guard let device = AVCaptureDevice.default(deviceType, for: .video, position: avPosition) else {
				onEvent?(.sessionError("Camera \(cameraID.rawValue) not found, skipping"))
				continue
			}

			guard let input = try? AVCaptureDeviceInput(device: device),
				  session.canAddInput(input) else {
				onEvent?(.sessionError("Cannot add \(cameraID.rawValue) input, skipping"))
				continue
			}
			session.addInput(input)

			let videoOutput = AVCaptureVideoDataOutput()
			let queue = DispatchQueue(label: "MultiCamDelegate.video.\(cameraID.rawValue)")
			videoQueues[cameraID] = queue
			videoOutput.setSampleBufferDelegate(self, queue: queue)
			videoOutput.alwaysDiscardsLateVideoFrames = true
			videoOutput.videoSettings = [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
			]

			guard session.canAddOutput(videoOutput) else {
				session.removeInput(input)
				videoQueues.removeValue(forKey: cameraID)
				onEvent?(.sessionError("Cannot add \(cameraID.rawValue) output, skipping"))
				continue
			}
			session.addOutput(videoOutput)

			// FIX #5: Configure frame rate BEFORE cost check
			if let _ = try? device.lockForConfiguration() {
				let maxSupported = device.activeFormat.videoSupportedFrameRateRanges
					.map { $0.maxFrameRate }
					.max() ?? 30
				let clampedFPS = min(Double(config.frameRate), maxSupported)
				let timescale = CMTimeScale(clampedFPS)
				device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: timescale)
				device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: timescale)
				device.unlockForConfiguration()
			}

			// Check hardware cost after adding this camera + frame rate
			if session.hardwareCost >= 1.0 {
				var reduced = false

				// Strategy 1: Try a lower-resolution format
				if let _ = try? device.lockForConfiguration() {
					let currentFormat = device.activeFormat
					let formats = device.formats.filter { fmt in
						let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
						let currentDims = CMVideoFormatDescriptionGetDimensions(currentFormat.formatDescription)
						return dims.width < currentDims.width && dims.height < currentDims.height
							&& fmt.isMultiCamSupported
					}.sorted { a, b in
						let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
						let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
						return da.width * da.height > db.width * db.height
					}

					for format in formats {
						device.activeFormat = format
						if session.hardwareCost < 1.0 {
							reduced = true
							break
						}
					}
					device.unlockForConfiguration()
				}

				// FIX #7: Strategy 2: Try reducing frame rate as fallback
				if !reduced, session.hardwareCost >= 1.0 {
					if let _ = try? device.lockForConfiguration() {
						let fallbackFPS: [Double] = [24, 15, 10]
						for fps in fallbackFPS {
							let maxSupported = device.activeFormat.videoSupportedFrameRateRanges
								.map { $0.maxFrameRate }
								.max() ?? 30
							let clamped = min(fps, maxSupported)
							device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
							device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
							if session.hardwareCost < 1.0 {
								reduced = true
								break
							}
						}
						device.unlockForConfiguration()
					}
				}

				// Still over budget — remove this camera
				if !reduced && session.hardwareCost >= 1.0 {
					let cost = session.hardwareCost
					session.removeOutput(videoOutput)
					session.removeInput(input)
					videoQueues.removeValue(forKey: cameraID)
					onEvent?(.sessionError("\(cameraID.rawValue) exceeds hardware budget (cost: \(String(format: "%.2f", cost))), skipped"))
					continue
				}
			}

			cameraInputs[cameraID] = input
			videoOutputs[cameraID] = videoOutput
			outputToCameraID[ObjectIdentifier(videoOutput)] = cameraID
			addedCameras.append(cameraID)

			// Rotate to portrait
			if let connection = videoOutput.connection(with: .video) {
				connection.videoRotationAngle = 90
			}
		}

		// FIX #6: Don't commit an empty session
		guard !addedCameras.isEmpty else {
			throw MultiCamClient.Error.cameraSetNotSupported(config.cameras)
		}

		// Add audio (only if requested)
		if config.includeAudio, let audioDevice = AVCaptureDevice.default(for: .audio) {
			if let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
			   session.canAddInput(audioInput) {
				session.addInput(audioInput)
			}
			let audioOut = AVCaptureAudioDataOutput()
			audioOut.setSampleBufferDelegate(self, queue: audioQueue)
			if session.canAddOutput(audioOut) {
				session.addOutput(audioOut)
				self.audioOutput = audioOut
			}
		}

		session.commitConfiguration()

		lastHardwareCost = session.hardwareCost
		activeCameras = addedCameras
		self.multiCamSession = session

		let costStr = String(format: "%.2f", session.hardwareCost)
		print("📹 [MULTI_CAM]: Session configured with \(addedCameras.count)/\(config.cameras.count) cameras, hardware cost: \(costStr)/1.00")
		for cam in addedCameras {
			print("📹 [MULTI_CAM]:   ✓ \(cam.rawValue)")
		}
		let dropped = config.cameras.filter { !addedCameras.contains($0) }
		for cam in dropped {
			print("📹 [MULTI_CAM]:   ✗ \(cam.rawValue) (dropped)")
		}
	}

	// MARK: - Per-Camera Zoom

	func setZoom(for camera: MultiCamClient.CameraID, factor: CGFloat) throws {
		guard let input = cameraInputs[camera] else {
			throw MultiCamClient.Error.cameraSetNotSupported([camera])
		}
		let device = input.device
		let minZoom = device.minAvailableVideoZoomFactor
		let maxZoom = device.maxAvailableVideoZoomFactor
		let clamped = min(max(factor, minZoom), maxZoom)
		try device.lockForConfiguration()
		device.videoZoomFactor = clamped
		device.unlockForConfiguration()
	}

	func zoomRange(for camera: MultiCamClient.CameraID) -> (min: CGFloat, max: CGFloat) {
		guard let input = cameraInputs[camera] else { return (1.0, 1.0) }
		return (input.device.minAvailableVideoZoomFactor, input.device.maxAvailableVideoZoomFactor)
	}

	func startRunning() {
		sessionQueue.async { [weak self] in
			self?.multiCamSession?.startRunning()
		}
	}

	func stopRunning() {
		sessionQueue.async { [weak self] in
			self?.multiCamSession?.stopRunning()
		}
	}

	func teardown() {
		if let session = multiCamSession, session.isRunning {
			sessionQueue.async { session.stopRunning() }
		}
		removeNotificationObservers()
		onVideoFrame = nil
		onAudioSample = nil
		multiCamSession = nil
		cameraInputs.removeAll()
		videoOutputs.removeAll()
		outputToCameraID.removeAll()
		videoQueues.removeAll()
		audioOutput = nil
	}

	// MARK: - Notification Observers

	// MARK: - System Pressure KVO

	private var pressureObservations: [NSKeyValueObservation] = []

	func registerNotificationObservers() {
		let nc = NotificationCenter.default
		nc.addObserver(self, selector: #selector(sessionDidStartRunning),
		               name: .AVCaptureSessionDidStartRunning, object: multiCamSession)
		nc.addObserver(self, selector: #selector(sessionDidStopRunning),
		               name: .AVCaptureSessionDidStopRunning, object: multiCamSession)
		nc.addObserver(self, selector: #selector(sessionRuntimeError),
		               name: .AVCaptureSessionRuntimeError, object: multiCamSession)
		nc.addObserver(self, selector: #selector(sessionWasInterrupted),
		               name: .AVCaptureSessionWasInterrupted, object: multiCamSession)
		nc.addObserver(self, selector: #selector(sessionInterruptionEnded),
		               name: .AVCaptureSessionInterruptionEnded, object: multiCamSession)

		// Observe system pressure on each active camera device
		for (cameraID, input) in cameraInputs {
			let observation = input.device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
				self?.handleSystemPressure(device: device, cameraID: cameraID)
			}
			pressureObservations.append(observation)
		}

		// Periodically report hardware cost
		if let session = multiCamSession {
			let costObservation = session.observe(\.hardwareCost, options: [.new]) { [weak self] session, _ in
				let cost = session.hardwareCost
				self?.lastHardwareCost = cost
				self?.onEvent?(.hardwareCostUpdated(cost))
			}
			pressureObservations.append(costObservation)
		}
	}

	func removeNotificationObservers() {
		NotificationCenter.default.removeObserver(self)
		pressureObservations.removeAll()
	}

	private func handleSystemPressure(device: AVCaptureDevice, cameraID: MultiCamClient.CameraID) {
		let pressureState = device.systemPressureState
		let level = pressureState.level.multiCamLevel

		onEvent?(.systemPressureChanged(level))

		// Auto-throttle on serious/critical pressure
		if pressureState.level == .serious {
			print("📹 [MULTI_CAM]: ⚠️ System pressure SERIOUS on \(cameraID.rawValue) — reducing frame rate")
			throttleDevice(device, targetFPS: 24)
		} else if pressureState.level == .critical {
			print("📹 [MULTI_CAM]: 🔴 System pressure CRITICAL on \(cameraID.rawValue) — reducing to minimum")
			throttleDevice(device, targetFPS: 15)
		} else if pressureState.level == .shutdown {
			print("📹 [MULTI_CAM]: 🛑 System pressure SHUTDOWN on \(cameraID.rawValue)")
			onEvent?(.sessionError("Device overheating — camera \(cameraID.rawValue) may stop"))
		}
	}

	private func throttleDevice(_ device: AVCaptureDevice, targetFPS: Double) {
		guard let _ = try? device.lockForConfiguration() else { return }
		let maxSupported = device.activeFormat.videoSupportedFrameRateRanges
			.map { $0.maxFrameRate }
			.max() ?? 30
		let clamped = min(targetFPS, maxSupported)
		device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
		device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
		device.unlockForConfiguration()
	}

	@objc private func sessionDidStartRunning(_ notification: Notification) {
		onEvent?(.sessionStarted)
	}

	@objc private func sessionDidStopRunning(_ notification: Notification) {
		onEvent?(.sessionStopped)
	}

	@objc private func sessionRuntimeError(_ notification: Notification) {
		let message: String
		if let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError {
			message = error.localizedDescription
		} else {
			message = "Unknown runtime error"
		}
		onEvent?(.sessionError(message))
	}

	@objc private func sessionWasInterrupted(_ notification: Notification) {
		let reason: String
		if let userInfo = notification.userInfo,
		   let rawReason = userInfo[AVCaptureSessionInterruptionReasonKey] as? Int {
			switch AVCaptureSession.InterruptionReason(rawValue: rawReason) {
			case .videoDeviceNotAvailableInBackground: reason = "App moved to background"
			case .audioDeviceInUseByAnotherClient: reason = "Audio device in use by another app"
			case .videoDeviceInUseByAnotherClient: reason = "Camera in use by another app"
			case .videoDeviceNotAvailableWithMultipleForegroundApps: reason = "Camera not available in split view"
			case .videoDeviceNotAvailableDueToSystemPressure: reason = "Camera unavailable due to system pressure"
			default: reason = "Unknown interruption"
			}
		} else {
			reason = "Session interrupted"
		}
		onEvent?(.sessionInterrupted(reason))
	}

	@objc private func sessionInterruptionEnded(_ notification: Notification) {
		onEvent?(.sessionInterruptionEnded)
	}
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension MultiCamSessionDelegate: AVCaptureVideoDataOutputSampleBufferDelegate {
	func captureOutput(
		_ output: AVCaptureOutput,
		didOutput sampleBuffer: CMSampleBuffer,
		from connection: AVCaptureConnection
	) {
		let key = ObjectIdentifier(output)

		// Route video frames by camera ID
		if let cameraID = outputToCameraID[key] {
			onVideoFrame?(cameraID, sampleBuffer)
			return
		}

		// Route audio samples
		if output === audioOutput {
			onAudioSample?(sampleBuffer)
		}
	}
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MultiCamSessionDelegate: AVCaptureAudioDataOutputSampleBufferDelegate {
	// Audio samples are routed through the same captureOutput method above
}

// MARK: - CameraID → AVFoundation Mapping

extension MultiCamClient.CameraID {
	var avPosition: AVCaptureDevice.Position {
		switch self {
		case .frontWide: return .front
		default: return .back
		}
	}

	var avDeviceType: AVCaptureDevice.DeviceType {
		switch self {
		case .frontWide: return .builtInWideAngleCamera
		case .backWide: return .builtInWideAngleCamera
		case .backUltraWide: return .builtInUltraWideCamera
		case .backTelephoto: return .builtInTelephotoCamera
		default: return .builtInWideAngleCamera
		}
	}
}

// MARK: - System Pressure Level Mapping

extension AVCaptureDevice.SystemPressureState.Level {
	var multiCamLevel: MultiCamClient.SystemPressureLevel {
		if self == .nominal { return .nominal }
		if self == .fair { return .fair }
		if self == .serious { return .serious }
		if self == .critical { return .critical }
		if self == .shutdown { return .shutdown }
		return .critical
	}
}
#endif
