#if os(iOS)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
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

	private var eventContinuations: [UUID: AsyncStream<MultiCamClient.Event>.Continuation] = [:]
	private var pixelBufferContinuations: [MultiCamClient.CameraID: [UUID: AsyncStream<PhotoCaptureClient.PixelBufferWrapper>.Continuation]] = [:]

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

		let validSets = discovery.supportedMultiCamDeviceSets

		// Keep full sets as-is (may be 2, 3, or more cameras).
		// Also extract all 2-camera pairs from larger sets.
		var seen = Set<String>()
		var cameraSets: [[MultiCamClient.CameraID]] = []

		for deviceSet in validSets {
			let ids = deviceSet.compactMap { mapDeviceToCameraID($0) }
			guard !ids.isEmpty else { continue }

			let sorted = ids.sorted { $0.rawValue < $1.rawValue }

			// Add the full set (3+ cameras if supported)
			let fullKey = sorted.map(\.rawValue).joined(separator: ",")
			if !seen.contains(fullKey) {
				seen.insert(fullKey)
				cameraSets.append(sorted)
			}

			// Also add 2-camera subsets for more options
			if sorted.count > 2 {
				for i in 0..<sorted.count {
					for j in (i + 1)..<sorted.count {
						let pair = [sorted[i], sorted[j]]
						let pairKey = pair.map(\.rawValue).joined(separator: ",")
						if !seen.contains(pairKey) {
							seen.insert(pairKey)
							cameraSets.append(pair)
						}
					}
				}
			}
		}

		// Sort: larger sets first, then alphabetically
		cameraSets.sort { a, b in
			if a.count != b.count { return a.count > b.count }
			return a.map(\.rawValue).joined() < b.map(\.rawValue).joined()
		}

		return MultiCamClient.DeviceCapability(
			isMultiCamSupported: true,
			availableCameraSets: cameraSets,
			maxSimultaneousCameras: cameraSets.map(\.count).max() ?? 2
		)
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
		logger("Active cameras: \(activeCameras.map(\.rawValue)), hardware cost: \(String(format: "%.2f", delegate.lastHardwareCost))")

		// FIX: Compositor uses actual active cameras (not requested), in case some were dropped
		let actualCameras = activeCameras
		let layout = currentLayout
		let comp = await MainActor.run {
			let c = MultiCamCompositor.create()
			c?.setCameras(actualCameras)
			c?.setLayout(layout)
			return c
		}
		self.compositor = comp

		// Wire delegate → compositor + recording pipeline + pixel buffer streams
		// Recording pipeline is called SYNCHRONOUSLY here to ensure CMSampleBuffer
		// is still valid (AVFoundation recycles buffers after the delegate returns).
		let pipeline = recordingPipeline
		delegate.onVideoFrame = { [weak self, weak comp] cameraID, sampleBuffer in
			guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
			comp?.enqueueFrame(pixelBuffer, for: cameraID)

			// Feed recording pipeline synchronously (before buffer is recycled)
			pipeline.appendVideoSample(sampleBuffer, for: cameraID)

			// Feed pixel buffer streams asynchronously (wrapper retains the buffer)
			let wrapped = SendableSampleBuffer(sampleBuffer)
			Task { [weak self] in
				await self?.deliverPixelBuffer(cameraID: cameraID, sampleBuffer: wrapped)
			}
		}

		delegate.onAudioSample = { sampleBuffer in
			pipeline.appendAudioSample(sampleBuffer)
		}

		// Invalidate cached preview
		cachedPreviewView = nil

		logger("Starting multi-cam session")
		delegate.startRunning()

		for camera in config.cameras {
			yieldEvent(.cameraConnected(camera))
		}
	}

	func stopSession() async {
		guard delegate.isRunning else {
			logger("Session not running")
			return
		}

		logger("Stopping multi-cam session")

		if isRecording {
			_ = try? await recordingPipeline.stopRecording()
			isRecording = false
		}

		delegate.onVideoFrame = nil
		delegate.onAudioSample = nil
		compositor = nil
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

	func getLayout() -> MultiCamClient.Layout {
		currentLayout
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

		let outputSize = CGSize(width: 1080, height: 1920) // Portrait 1080p
		try recordingPipeline.startRecording(
			config: config,
			cameras: activeCameras,
			outputSize: outputSize
		)
		isRecording = true
		yieldEvent(.recordingStarted)
		logger("Recording started")
	}

	func stopRecording() async throws -> MultiCamClient.RecordingResult {
		guard isRecording else {
			throw MultiCamClient.Error.recordingNotInProgress
		}

		let result = try await recordingPipeline.stopRecording()
		isRecording = false
		yieldEvent(.recordingStopped(result))
		logger("Recording stopped: duration=\(result.duration)s")
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
		guard video == .authorized && audio == .authorized else {
			if video == .notDetermined || audio == .notDetermined { return .notDetermined }
			if video == .restricted || audio == .restricted { return .restricted }
			return .denied
		}
		return .authorized
	}

	// MARK: - Preview

	func getPreviewView() -> MultiCamClient.PreviewView {
		if let cached = cachedPreviewView {
			return cached
		}
		let preview: MultiCamClient.PreviewView
		if let comp = compositor {
			preview = MultiCamClient.PreviewView(view: comp, layout: currentLayout)
			comp.previewViewRef = preview
		} else {
			preview = MultiCamClient.PreviewView(view: UIView(), layout: currentLayout)
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

	func observePixelBuffers(for camera: MultiCamClient.CameraID) -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper> {
		let id = UUID()
		return AsyncStream { continuation in
			if pixelBufferContinuations[camera] == nil {
				pixelBufferContinuations[camera] = [:]
			}
			pixelBufferContinuations[camera]?[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.removePixelBufferContinuation(camera: camera, id: id) }
			}
		}
	}

	private func removePixelBufferContinuation(camera: MultiCamClient.CameraID, id: UUID) {
		pixelBufferContinuations[camera]?.removeValue(forKey: id)
	}

	// MARK: - Internal Frame Delivery

	private func deliverPixelBuffer(cameraID: MultiCamClient.CameraID, sampleBuffer: SendableSampleBuffer) {
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
