import Foundation
import ObjectDetectionClient
import PhotoCaptureClient
import YOLO
import os
#if canImport(UIKit)
import UIKit
#endif

/// Actor that manages YOLO model lifecycle and runs inference on camera frames.
/// The model is loaded from the .mlpackage bundled in this SPM target's resources.
actor ObjectDetectionClientActor {
	private var model: YOLO?
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
				"Bundled model '\(configuration.modelName).mlpackage' not found in resources"
			)
		}

		// YOLO init requires file path ending in .mlpackage and a task parameter.
		// Loading is asynchronous — the completion callback signals success/failure.
		let yolo = await withCheckedContinuation { (continuation: CheckedContinuation<YOLO?, Never>) in
			let instance = YOLO(modelURL.path, task: .detect) { result in
				switch result {
				case .success(let model):
					continuation.resume(returning: model)
				case .failure:
					continuation.resume(returning: nil)
				}
			}
			// Keep reference alive until completion fires.
			_ = instance
		}

		guard let yolo else {
			throw ObjectDetectionClient.Error.modelLoadFailed("YOLO model initialization failed")
		}

		self.model = yolo
		logger("YOLO model loaded from bundle: \(modelURL.path)")

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
		model = nil
		configuration = nil

		for continuation in resultContinuations.values {
			continuation.finish()
		}
		resultContinuations.removeAll()
	}

	// MARK: - Frame Processing

	private func processFrame(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async {
		guard let model else { return }
		guard let configuration else { return }

		let result: ObjectDetectionClient.DetectionResult? = await withCheckedContinuation { continuation in
			inferenceQueue.async {
				let start = CFAbsoluteTimeGetCurrent()

				#if canImport(UIKit)
				// CIImage from retained CVPixelBuffer — zero copy
				let ciImage = CIImage(cvPixelBuffer: wrapper.pixelBuffer)

				// YOLO callAsFunction is NON-THROWING, returns empty result on failure
				let yoloResult = model(ciImage)
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
		let yolo: YOLO
		if let existingModel = model {
			yolo = existingModel
		} else {
			let modelName = configuration?.modelName ?? "yolo11n"
			guard let modelURL = bundledModelURL(name: modelName) else {
				throw ObjectDetectionClient.Error.modelLoadFailed(
					"Bundled model '\(modelName).mlpackage' not found in resources"
				)
			}

			// Load model via completion for single-image detection
			let loaded = await withCheckedContinuation { (continuation: CheckedContinuation<YOLO?, Never>) in
				let instance = YOLO(modelURL.path, task: .detect) { result in
					switch result {
					case .success(let model):
						continuation.resume(returning: model)
					case .failure:
						continuation.resume(returning: nil)
					}
				}
				_ = instance
			}

			guard let loaded else {
				throw ObjectDetectionClient.Error.modelLoadFailed("YOLO model initialization failed for single-image detection")
			}
			yolo = loaded
		}

		guard let uiImage = UIImage(data: imageData) else {
			throw ObjectDetectionClient.Error.inferenceFailed("Invalid image data")
		}

		let start = CFAbsoluteTimeGetCurrent()
		let yoloResult = yolo(uiImage)
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
