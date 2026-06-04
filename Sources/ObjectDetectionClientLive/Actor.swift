import CoreML
import CoreVideo
import Foundation
import ObjectDetectionClient
import PhotoCaptureClient
import Vision
import os

#if canImport(UIKit)
    import UIKit
#endif

/// Actor that manages YOLO model lifecycle and runs inference on camera frames.
/// Uses Vision framework directly (instead of YOLO library's model loading) to control
/// MLModelConfiguration.computeUnits and avoid Neural Engine MLIR crashes.
actor ObjectDetectionClientActor {
    private var vnModel: VNCoreMLModel?
    private var labels: [String] = []
    private var configuration: ObjectDetectionClient.Configuration?
    private var resultContinuations: [UUID: AsyncStream<ObjectDetectionClient.DetectionResult>.Continuation] = [:]
    private var frameProcessingTask: Task<Void, Never>?

    /// Thread-safe mode accessible from any isolation domain.
    private let modeStorage = OSAllocatedUnfairLock(initialState: ObjectDetectionClient.DetectionMode.manual)

    /// Dedicated queue for YOLO inference — keeps the actor unblocked.
    private let inferenceQueue = DispatchQueue(label: "ObjectDetectionClientActor.inference", qos: .userInitiated)

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

    /// Load model using CoreML/Vision directly. Uses .cpuAndNeuralEngine to leverage
    /// the Apple Neural Engine for fastest inference while avoiding GPU MLIR crashes.
    private func loadModel(from modelURL: URL) throws -> (VNCoreMLModel, [String]) {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let mlModel: MLModel
        if modelURL.pathExtension == "mlmodelc" {
            mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        } else {
            let compiledURL = try MLModel.compileModel(at: modelURL)
            mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
        }

        // Extract class labels from model metadata
        var extractedLabels: [String] = []
        if let userDefined = mlModel.modelDescription
            .metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String]
        {
            if let labelsData = userDefined["classes"] {
                extractedLabels = labelsData.components(separatedBy: ",")
            } else if let labelsData = userDefined["names"] {
                // Parse dictionary format: {0: 'person', 1: 'bicycle', ...}
                let cleaned =
                    labelsData
                    .replacingOccurrences(of: "{", with: "")
                    .replacingOccurrences(of: "}", with: "")
                let pairs = cleaned.components(separatedBy: ",")
                for pair in pairs {
                    let parts = pair.components(separatedBy: ":")
                    if parts.count == 2 {
                        let label = parts[1]
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "'", with: "")
                        extractedLabels.append(label)
                    }
                }
            }
        }

        let vnModel = try VNCoreMLModel(for: mlModel)

        // Set thresholds via feature provider
        let iouThreshold = Double(configuration?.iouThreshold ?? 0.45)
        let confidenceThreshold = Double(configuration?.confidenceThreshold ?? 0.4)
        vnModel.featureProvider = ThresholdProvider(
            iouThreshold: iouThreshold,
            confidenceThreshold: confidenceThreshold
        )

        return (vnModel, extractedLabels)
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
            let (loadedModel, loadedLabels) = try loadModel(from: modelURL)
            self.vnModel = loadedModel
            self.labels = loadedLabels
            logger("YOLO model loaded successfully (\(loadedLabels.count) classes, using cpuAndNeuralEngine)")
        } catch {
            throw ObjectDetectionClient.Error.modelLoadFailed(
                "Model loading failed: \(error.localizedDescription)"
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
        vnModel = nil
        labels = []
        configuration = nil

        for continuation in resultContinuations.values {
            continuation.finish()
        }
        resultContinuations.removeAll()
    }

    // MARK: - Frame Processing

    private func processFrame(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async {
        guard let vnModel else { return }
        guard let configuration else { return }

        let result: ObjectDetectionClient.DetectionResult? = await withCheckedContinuation { continuation in
            inferenceQueue.async { [labels] in
                let start = CFAbsoluteTimeGetCurrent()

                #if canImport(UIKit)
                    let request = VNCoreMLRequest(model: vnModel)

                    request.imageCropAndScaleOption = .scaleFill

                    // Use CVPixelBuffer directly — avoids CIImage allocation per frame
                    let handler = VNImageRequestHandler(cvPixelBuffer: wrapper.pixelBuffer, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        continuation.resume(returning: nil)
                        return
                    }

                    let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
                    var detectedObjects: [ObjectDetectionClient.DetectedObject] = []

                    if let results = request.results as? [VNRecognizedObjectObservation] {
                        for prediction in results.prefix(configuration.maxDetections) {
                            let conf = prediction.labels[0].confidence
                            guard conf >= configuration.confidenceThreshold else { continue }

                            let visionBox = prediction.boundingBox
                            // Vision uses bottom-left origin → convert to top-left
                            let boundingBox = ObjectDetectionClient.BoundingBox(
                                x: Float(visionBox.minX),
                                y: Float(1 - visionBox.maxY),
                                width: Float(visionBox.width),
                                height: Float(visionBox.height)
                            )

                            // Sample true Z depth at the box centre (nil on non-depth devices/simulator).
                            let depth = Self.sampleDepth(
                                in: wrapper.depthBuffer,
                                centerX: boundingBox.x + boundingBox.width * 0.5,
                                centerY: boundingBox.y + boundingBox.height * 0.5,
                                boxWidth: boundingBox.width,
                                boxHeight: boundingBox.height
                            )

                            let label = prediction.labels[0].identifier
                            detectedObjects.append(
                                ObjectDetectionClient.DetectedObject(
                                    label: label,
                                    confidence: conf,
                                    boundingBox: boundingBox,
                                    depth: depth
                                )
                            )
                        }
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

    // MARK: - Depth Sampling

    /// Sample metric depth (metres) at a detection's centre from the depth map attached to the frame.
    /// Returns the ~20th percentile of valid samples over the inner ~60% of the box (robust to
    /// see-through background / partial occlusion), or `nil` when no depth is available.
    private static func sampleDepth(
        in depthBuffer: CVPixelBuffer?,
        centerX: Float,
        centerY: Float,
        boxWidth: Float,
        boxHeight: Float
    ) -> Float? {
        guard let depthBuffer else { return nil }
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)

        // Sample a 5x5 grid over the inner ~60% of the box (scales with box size), dropping holes.
        let innerWidth = boxWidth * 0.6
        let innerHeight = boxHeight * 0.6
        let steps = 5
        var samples: [Float] = []
        samples.reserveCapacity(steps * steps)

        for row in 0..<steps {
            for column in 0..<steps {
                let offsetX = (Float(column) / Float(steps - 1) - 0.5) * innerWidth
                let offsetY = (Float(row) / Float(steps - 1) - 0.5) * innerHeight
                let normalizedX = min(max(centerX + offsetX, 0), 1)
                let normalizedY = min(max(centerY + offsetY, 0), 1)
                let pixelX = min(Int(normalizedX * Float(width)), width - 1)
                let pixelY = min(Int(normalizedY * Float(height)), height - 1)
                let rowPointer = base.advanced(by: pixelY * bytesPerRow)
                let value = rowPointer.assumingMemoryBound(to: Float32.self)[pixelX]
                if value.isFinite, value > 0 {
                    samples.append(value)
                }
            }
        }

        guard samples.count >= 3 else { return nil }
        samples.sort()
        // Low (~20th) percentile = the near surface within the box, robust to background bleed.
        let index = Int(Float(samples.count - 1) * 0.20)
        return samples[index]
    }

    // MARK: - Single Image Detection

    func detectInImage(_ imageData: Data) async throws -> ObjectDetectionClient.DetectionResult {
        #if canImport(UIKit)
            let activeModel: VNCoreMLModel
            let activeLabels: [String]

            if let existing = vnModel {
                activeModel = existing
                activeLabels = labels
            } else {
                let modelName = configuration?.modelName ?? "yolo11n"
                guard let modelURL = bundledModelURL(name: modelName) else {
                    throw ObjectDetectionClient.Error.modelLoadFailed(
                        "Bundled model '\(modelName)' not found in resources"
                    )
                }
                let (loaded, loadedLabels) = try loadModel(from: modelURL)
                activeModel = loaded
                activeLabels = loadedLabels
            }

            guard let uiImage = UIImage(data: imageData) else {
                throw ObjectDetectionClient.Error.inferenceFailed("Invalid image data")
            }

            // Bake orientation into pixel data so Vision sees the same
            // orientation that cropImage will use later
            let renderer = UIGraphicsImageRenderer(size: uiImage.size)
            let orientedImage = renderer.image { _ in
                uiImage.draw(in: CGRect(origin: .zero, size: uiImage.size))
            }
            guard let cgImage = orientedImage.cgImage else {
                throw ObjectDetectionClient.Error.inferenceFailed("Failed to render oriented image")
            }

            let request = VNCoreMLRequest(model: activeModel)
            request.imageCropAndScaleOption = .scaleFill

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let config = configuration ?? .default

            var detectedObjects: [ObjectDetectionClient.DetectedObject] = []

            if let results = request.results as? [VNRecognizedObjectObservation] {
                for prediction in results.prefix(config.maxDetections) {
                    let conf = prediction.labels[0].confidence
                    guard conf >= config.confidenceThreshold else { continue }

                    let visionBox = prediction.boundingBox
                    // Vision uses bottom-left origin → convert to top-left
                    let boundingBox = ObjectDetectionClient.BoundingBox(
                        x: Float(visionBox.minX),
                        y: Float(1 - visionBox.maxY),
                        width: Float(visionBox.width),
                        height: Float(visionBox.height)
                    )

                    let label = prediction.labels[0].identifier
                    detectedObjects.append(
                        ObjectDetectionClient.DetectedObject(
                            label: label,
                            confidence: conf,
                            boundingBox: boundingBox
                        )
                    )
                }
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

// MARK: - ThresholdProvider

/// Provides confidence and IoU thresholds to VNCoreMLModel.
private class ThresholdProvider: MLFeatureProvider {
    let values: [String: MLFeatureValue]

    var featureNames: Set<String> {
        Set(values.keys)
    }

    init(
        iouThreshold: Double,
        confidenceThreshold: Double
    ) {
        values = [
            "iouThreshold": MLFeatureValue(double: iouThreshold),
            "confidenceThreshold": MLFeatureValue(double: confidenceThreshold),
        ]
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        values[featureName]
    }
}
