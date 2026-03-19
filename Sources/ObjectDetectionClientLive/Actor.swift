import Foundation
import ObjectDetectionClient
import PhotoCaptureClient
import YOLO
import os
#if canImport(UIKit)
import UIKit
#endif

/// Actor that manages YOLO model lifecycle and runs inference on camera frames.
/// Uses BasePredictor directly (instead of YOLO.init) to support .mlmodelc bundles
/// that Xcode compiles from .mlpackage during the build.
actor ObjectDetectionClientActor {
	private var predictor: BasePredictor?
	private var configuration: ObjectDetectionClient.Configuration?
	private var resultContinuations: [UUID: AsyncStream<ObjectDetectionClient.DetectionResult>.Continuation] = [:]
	private var frameProcessingTask: Task<Void, Never>?

	/// Thread-safe mode accessible from any isolation domain.
	private let modeStorage = OSAllocatedUnfairLock(initialState: ObjectDetectionClient.DetectionMode.manual)

	/// Dedicated queue for YOLO inference — keeps the actor unblocked.
	private let inferenceQueue = DispatchQueue(label: "ObjectDetectionClientActor.inference", qos: .userInitiated)

	/// Cached CIContext for pixel buffer → CGImage conversion. Reused across frames.
	#if canImport(UIKit)
	private let ciContext = CIContext()
	#endif

	private let logger: @Sendable (String) -> Void

	init(
		logger: @escaping @Sendable (String) -> Void = { message in
			#if DEBUG
			print("[OBJECT_DETECTION]: \(message)")
			#endif
		}
	) {
		self.logger = logger
	}

	// MARK: - Mode

	nonisolated func currentMode() -> ObjectDetectionClient.DetectionMode {
		modeStorage.withLock { $0 }
	}

	// MARK: - Model Loading

	private func bundledModelURL(name: String) -> URL? {
		// Xcode compiles .mlpackage → .mlmodelc during build, so check both
		Bundle.module.url(forResource: name, withExtension: "mlmodelc")
		?? Bundle.module.url(forResource: name, withExtension: "mlpackage")
	}

	/// Load a BasePredictor from a model URL. Handles both .mlmodelc and .mlpackage.
	/// Uses BasePredictor.create directly instead of YOLO.init, which only accepts
	/// .mlmodel/.mlpackage paths and fails on .mlmodelc.
	private func loadPredictor(from modelURL: URL) async throws -> BasePredictor {
		try await withCheckedThrowingContinuation { continuation in
			ObjectDetector.create(unwrappedModelURL: modelURL) { result in
				switch result {
				case .success(let predictor):
					continuation.resume(returning: predictor)
				case .failure(let error):
					continuation.resume(throwing: error)
				}
			}
		}
	}

	// MARK: - Start / Stop

	func startDetection(
		configuration: ObjectDetectionClient.Configuration,
		pixelBufferStream: @escaping @Sendable () async -> AsyncStream<PhotoCaptureClient.PixelBufferWrapper>
	) async throws {
		guard currentMode() == .manual else {
			logger("Detection already running")
			return
		}

		logger("Loading YOLO model: \(configuration.modelName)")
		self.configuration = configuration

		guard let modelURL = bundledModelURL(name: configuration.modelName) else {
			throw ObjectDetectionClient.Error.modelLoadFailed(
				"Bundled model '\(configuration.modelName)' not found in resources (tried .mlmodelc and .mlpackage)"
			)
		}

		logger("Found model at: \(modelURL.path) (extension: \(modelURL.pathExtension))")

		do {
			let loadedPredictor = try await loadPredictor(from: modelURL)
			self.predictor = loadedPredictor
			logger("YOLO model loaded successfully from: \(modelURL.lastPathComponent)")
		} catch {
			throw ObjectDetectionClient.Error.modelLoadFailed(
				"BasePredictor.create failed: \(error.localizedDescription)"
			)
		}

		modeStorage.withLock { $0 = .auto }

		frameProcessingTask = Task { [weak self] in
			let stream = await pixelBufferStream()
			for await wrapper in stream {
				guard !Task.isCancelled else { break }
				guard let self else { break }
				await self.processFrame(wrapper)
			}
		}
	}

	func stopDetection() {
		logger("Stopping detection")
		frameProcessingTask?.cancel()
		frameProcessingTask = nil
		modeStorage.withLock { $0 = .manual }
		predictor = nil
		configuration = nil

		for continuation in resultContinuations.values {
			continuation.finish()
		}
		resultContinuations.removeAll()
	}

	// MARK: - Frame Processing

	private func processFrame(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async {
		guard let predictor else { return }
		guard let configuration else { return }

		let result: ObjectDetectionClient.DetectionResult? = await withCheckedContinuation { continuation in
			inferenceQueue.async {
				let start = CFAbsoluteTimeGetCurrent()

				#if canImport(UIKit)
				// CIImage from retained CVPixelBuffer — zero copy
				let ciImage = CIImage(cvPixelBuffer: wrapper.pixelBuffer)

				// BasePredictor.predictOnImage is NON-THROWING, returns empty result on failure
				let yoloResult = predictor.predictOnImage(image: ciImage)
				let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000

				var detectedObjects: [ObjectDetectionClient.DetectedObject] = []

				for box in yoloResult.boxes.prefix(configuration.maxDetections) {
					// NOTE: .conf (NOT .confidence)
					guard box.conf >= configuration.confidenceThreshold else { continue }

					let boundingBox = ObjectDetectionClient.BoundingBox(
						x: Float(box.xywhn.origin.x),
						y: Float(box.xywhn.origin.y),
						width: Float(box.xywhn.size.width),
						height: Float(box.xywhn.size.height)
					)

					detectedObjects.append(ObjectDetectionClient.DetectedObject(
						label: box.cls,
						confidence: box.conf,
						boundingBox: boundingBox
					))
				}

				let result = ObjectDetectionClient.DetectionResult(
					objects: detectedObjects,
					inferenceTimeMs: inferenceTime,
					timestamp: wrapper.timestamp
				)
				continuation.resume(returning: result)
				#else
				continuation.resume(returning: nil)
				#endif
			}
		}

		if let result {
			yieldResult(result)
		}
	}

	// MARK: - Single Image Detection

	func detectInImage(_ imageData: Data) async throws -> ObjectDetectionClient.DetectionResult {
		#if canImport(UIKit)
		let activePredictor: BasePredictor
		if let existing = predictor {
			activePredictor = existing
		} else {
			let modelName = configuration?.modelName ?? "yolo11n"
			guard let modelURL = bundledModelURL(name: modelName) else {
				throw ObjectDetectionClient.Error.modelLoadFailed(
					"Bundled model '\(modelName)' not found in resources"
				)
			}
			activePredictor = try await loadPredictor(from: modelURL)
		}

		guard let uiImage = UIImage(data: imageData) else {
			throw ObjectDetectionClient.Error.inferenceFailed("Invalid image data")
		}

		guard let ciImage = CIImage(image: uiImage) else {
			throw ObjectDetectionClient.Error.inferenceFailed("Failed to create CIImage from UIImage")
		}

		let start = CFAbsoluteTimeGetCurrent()
		let yoloResult = activePredictor.predictOnImage(image: ciImage)
		let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
		let config = configuration ?? .default

		var detectedObjects: [ObjectDetectionClient.DetectedObject] = []

		for box in yoloResult.boxes.prefix(config.maxDetections) {
			guard box.conf >= config.confidenceThreshold else { continue }

			let boundingBox = ObjectDetectionClient.BoundingBox(
				x: Float(box.xywhn.origin.x),
				y: Float(box.xywhn.origin.y),
				width: Float(box.xywhn.size.width),
				height: Float(box.xywhn.size.height)
			)

			detectedObjects.append(ObjectDetectionClient.DetectedObject(
				label: box.cls,
				confidence: box.conf,
				boundingBox: boundingBox
			))
		}

		return ObjectDetectionClient.DetectionResult(
			objects: detectedObjects,
			inferenceTimeMs: inferenceTime,
			timestamp: .now
		)
		#else
		throw ObjectDetectionClient.Error.inferenceFailed("Object detection requires iOS")
		#endif
	}

	// MARK: - Streams

	func observeResults() -> AsyncStream<ObjectDetectionClient.DetectionResult> {
		let id = UUID()
		return AsyncStream { continuation in
			resultContinuations[id] = continuation
			continuation.onTermination = { [weak self] _ in
				Task { await self?.removeContinuation(id: id) }
			}
		}
	}

	private func removeContinuation(id: UUID) {
		resultContinuations.removeValue(forKey: id)
	}

	private func yieldResult(_ result: ObjectDetectionClient.DetectionResult) {
		for continuation in resultContinuations.values {
			continuation.yield(result)
		}
	}
}
