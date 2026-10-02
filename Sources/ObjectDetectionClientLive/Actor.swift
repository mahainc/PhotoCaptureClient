import CoreImage
import CoreML
import CoreVideo
import Foundation
import ObjectDetectionClient
import ObjectTracking
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
    /// Tracks already cropped, so each object is cut out once however long it stays.
    ///
    /// Pruned against the live track ids every frame rather than grown forever: a long
    /// session over a busy scene mints tracks continuously, and this would otherwise
    /// retain a UUID for every object the camera ever saw.
    private var croppedTrackIDs: Set<UUID> = []
    private var frameProcessingTask: Task<Void, Never>?

    /// Track-by-detection layer: turns identity-less per-frame detections into stable, coasted tracks.
    /// Created in `startDetection`, reset in `stopDetection`.
    private var tracker: MultiObjectTracker?
    /// Timestamp of the previous processed frame, for the tracker's inter-frame `dt`.
    private var lastFrameTimestamp: Date?
    /// Estimates global camera motion between frames for BoT-SORT CMC. Created in `startDetection`.
    private var motionEstimator: CameraMotionEstimator?
    /// Previous processed frame, registered against the current one to estimate camera motion.
    private var previousFrameWrapper: PhotoCaptureClient.PixelBufferWrapper?

    /// Monocular depth fallback for devices with no hardware depth sensor. The estimate refreshes
    /// in the background every `Self.monocularDepthInterval` frames and is cached here between
    /// refreshes; nil until the first estimate lands (ranking falls back to centre-proximity until
    /// then). Never touched on a device that delivers hardware depth — the model stays unloaded.
    private let depthEstimator = DepthEstimator()
    private var monocularDepth: CVPixelBuffer?
    private var monocularDepthFrameCounter = 0
    /// Refresh the monocular estimate every Nth processed frame — a second full-frame inference, too
    /// costly to run every frame, and depth ranking tolerates a few frames of staleness.
    private static let monocularDepthInterval = 3

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

        let extractedLabels = ModelLabels.parse(mlModel)

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

        let trackerConfig = TrackerConfiguration(
            highConfidence: configuration.highConfidenceThreshold,
            lowConfidence: configuration.confidenceThreshold
        )
        tracker = MultiObjectTracker(config: trackerConfig)
        motionEstimator = CameraMotionEstimator(mode: trackerConfig.cameraMotion)
        lastFrameTimestamp = nil
        previousFrameWrapper = nil

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
        tracker = nil
        motionEstimator = nil
        lastFrameTimestamp = nil
        previousFrameWrapper = nil
        monocularDepth = nil
        monocularDepthFrameCounter = 0
        croppedTrackIDs.removeAll()

        for continuation in resultContinuations.values {
            continuation.finish()
        }
        resultContinuations.removeAll()
    }

    // MARK: - Frame Processing

    private func processFrame(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async {
        guard let vnModel else { return }
        guard let configuration else { return }
        guard let motionEstimator else { return }

        refreshMonocularDepthIfNeeded(for: wrapper)
        let effectiveDepth = (wrapper.depthBuffer ?? monocularDepth).map(DepthMap.init)

        let raw = await runInference(
            wrapper: wrapper,
            previousWrapper: previousFrameWrapper,
            vnModel: vnModel,
            configuration: configuration,
            motionEstimator: motionEstimator,
            depthBuffer: effectiveDepth
        )
        guard let raw else { return }

        // Tracker step runs in the actor's (single-threaded) isolation: assign stable IDs and coast
        // confirmed tracks through brief detection dropouts so the dot stops flickering/teleporting.
        let previousTimestamp = lastFrameTimestamp
        let dt = previousTimestamp.map { Float(wrapper.timestamp.timeIntervalSince($0)) } ?? 0.333
        // Never regress the stored timestamp if a frame arrives out of order, so the next dt can't
        // become a large "catch-up" value (the tracker also clamps dt to [minDt, maxDt]).
        lastFrameTimestamp = previousTimestamp.map { max($0, wrapper.timestamp) } ?? wrapper.timestamp
        previousFrameWrapper = wrapper
        let tracks = tracker?.update(detections: raw.detections, dt: dt, cameraMotion: raw.cameraMotion) ?? []
        let objects = tracks.map { track in
            ObjectDetectionClient.DetectedObject(
                id: track.id,
                label: track.label,
                confidence: track.confidence,
                boundingBox: ObjectDetectionClient.BoundingBox(
                    x: track.box.x,
                    y: track.box.y,
                    width: track.box.width,
                    height: track.box.height
                ),
                depth: track.depth,
                trackedSeconds: TimeInterval(track.trackedSeconds)
            )
        }

        // Forget tracks the tracker has retired, so the set stays the size of the scene
        // rather than the size of the session.
        croppedTrackIDs.formIntersection(tracks.map(\.id))
        let matured = await cropMaturedObjects(
            tracks: tracks,
            wrapper: wrapper,
            dwellSeconds: configuration.dwellSeconds
        )

        #if DEBUG
        // Per-frame depth diagnostic: builds a summary string and writes to the on-device log, so it
        // stays out of release builds — the string formatting and file I/O are hot-path work at the
        // detection cadence, not something a shipped app should pay for.
        if !objects.isEmpty {
            let source =
                wrapper.depthBuffer != nil
                ? "hardware" : (monocularDepth != nil ? "monocular" : "none")
            let summary = objects.map { object in
                let box = object.boundingBox
                let geometry = String(
                    format: "c=%.2f,%.2f wh=%.2fx%.2f",
                    box.x + box.width * 0.5, box.y + box.height * 0.5, box.width, box.height)
                let depthText = object.depth.map { String(format: "%.3f", $0) } ?? "nil"
                return "\(object.label)[conf=\(String(format: "%.2f", object.confidence)) \(geometry) d=\(depthText)]"
            }
            .joined(separator: " ")
            let nearest =
                objects
                .compactMap { object in object.depth.map { (object.label, $0) } }
                .min { $0.1 < $1.1 }?.0 ?? "—"
            DiagnosticLog.shared.log("DEPTH src=\(source) \(summary) → nearest=\(nearest)")
        }
        #endif

        yieldResult(
            ObjectDetectionClient.DetectionResult(
                objects: objects,
                maturedObjects: matured,
                inferenceTimeMs: raw.inferenceMs,
                timestamp: wrapper.timestamp
            )
        )
    }

    /// Cut out every track that has just crossed the dwell threshold.
    ///
    /// Runs off the actor, on the inference queue: a JPEG encode is long enough that doing
    /// it under actor isolation would hold up the next frame's detection.
    private func cropMaturedObjects(
        tracks: [Track],
        wrapper: PhotoCaptureClient.PixelBufferWrapper,
        dwellSeconds: TimeInterval?
    ) async -> [ObjectDetectionClient.MaturedObject] {
        guard let dwellSeconds else { return [] }

        let ripe = tracks.filter { track in
            TimeInterval(track.trackedSeconds) >= dwellSeconds
                && !croppedTrackIDs.contains(track.id)
        }
        guard !ripe.isEmpty else { return [] }

        // Marked before the crop, not after: the crop is awaited, and a second frame
        // arriving in between would otherwise see the same track as uncropped and cut it
        // twice.
        for track in ripe {
            croppedTrackIDs.insert(track.id)
        }

        let requests = ripe.map { (id: $0.id, label: $0.label, box: $0.box) }
        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let context = CIContext(options: [.useSoftwareRenderer: false])
                let image = CIImage(cvPixelBuffer: wrapper.pixelBuffer)
                let cropped = requests.compactMap { request in
                    Self.crop(image, to: request.box, in: context).map { data in
                        ObjectDetectionClient.MaturedObject(
                            id: request.id,
                            label: request.label,
                            croppedData: data
                        )
                    }
                }
                continuation.resume(returning: cropped)
            }
        }
    }

    /// One object's crop as JPEG bytes, padded and capped for a thumbnail.
    ///
    /// The box is normalised with a top-left origin; Core Image measures y upward from the
    /// bottom, so the rect is flipped before it cuts.
    private static func crop(
        _ image: CIImage,
        to box: TrackBox,
        in context: CIContext
    ) -> Data? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let width = CGFloat(box.width) * extent.width
        let height = CGFloat(box.height) * extent.height
        let padding = max(width, height) * Self.cropPaddingRatio
        let originX = max(0, CGFloat(box.x) * extent.width - padding)
        let topOriginY = max(0, CGFloat(box.y) * extent.height - padding)
        let paddedWidth = min(extent.width - originX, width + padding * 2)
        let paddedHeight = min(extent.height - topOriginY, height + padding * 2)
        guard paddedWidth > 0, paddedHeight > 0 else { return nil }

        let rect = CGRect(
            x: extent.minX + originX,
            y: extent.minY + extent.height - topOriginY - paddedHeight,
            width: paddedWidth,
            height: paddedHeight
        )

        var cut = image.cropped(to: rect)
        let longestEdge = max(cut.extent.width, cut.extent.height)
        if longestEdge > Self.cropMaxDimension {
            let scale = Self.cropMaxDimension / longestEdge
            cut = cut.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        return context.jpegRepresentation(
            of: cut,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [:]
        )
    }

    /// Context kept around the detector's box, as a fraction of its longer side. The model
    /// brackets an object tightly and a crop with no margin reads as a mistake.
    private static let cropPaddingRatio: CGFloat = 0.1
    /// Longest edge of a crop. These are thumbnails held in memory by the consumer, not
    /// the full-resolution image a scan would want.
    private static let cropMaxDimension: CGFloat = 360

    /// Starts a background monocular-depth refresh when the device delivers no hardware depth and the
    /// cadence is due. Non-blocking: the current frame samples whatever estimate is already cached
    /// (centre-proximity until the first lands), and the result updates `monocularDepth` for later
    /// frames. On a device with hardware depth this returns at once and never loads the depth model.
    private func refreshMonocularDepthIfNeeded(for wrapper: PhotoCaptureClient.PixelBufferWrapper) {
        guard wrapper.depthBuffer == nil else { return }
        monocularDepthFrameCounter += 1
        let due = monocularDepth == nil || monocularDepthFrameCounter % Self.monocularDepthInterval == 0
        guard due else { return }
        Task {
            let estimate = await depthEstimator.estimate(wrapper)
            monocularDepth = estimate?.buffer ?? monocularDepth
        }
    }

    /// Run YOLO inference for one frame off the actor (on `inferenceQueue`), sampling per-box depth and
    /// estimating camera motion versus the previous frame. Returns `nil` on non-iOS or a Vision failure.
    private func runInference(
        wrapper: PhotoCaptureClient.PixelBufferWrapper,
        previousWrapper: PhotoCaptureClient.PixelBufferWrapper?,
        vnModel: VNCoreMLModel,
        configuration: ObjectDetectionClient.Configuration,
        motionEstimator: CameraMotionEstimator,
        depthBuffer: DepthMap?
    ) async -> (detections: [Detection], inferenceMs: Double, cameraMotion: CameraMotion)? {
        await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let start = CFAbsoluteTimeGetCurrent()

                #if canImport(UIKit)
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .scaleFill

                // Use CVPixelBuffer directly — avoids CIImage allocation per frame.
                let handler = VNImageRequestHandler(cvPixelBuffer: wrapper.pixelBuffer, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }

                let inferenceTime = (CFAbsoluteTimeGetCurrent() - start) * 1000
                var detections: [Detection] = []

                if let results = request.results as? [VNRecognizedObjectObservation] {
                    for prediction in results.prefix(configuration.maxDetections) {
                        let conf = prediction.labels[0].confidence
                        guard conf >= configuration.confidenceThreshold else { continue }

                        let visionBox = prediction.boundingBox
                        // Vision uses bottom-left origin → convert to top-left.
                        let box = TrackBox(
                            x: Float(visionBox.minX),
                            y: Float(1 - visionBox.maxY),
                            width: Float(visionBox.width),
                            height: Float(visionBox.height)
                        )

                        // Sample Z depth at the box centre from hardware depth, or the monocular
                        // fallback on devices without a depth sensor (nil until the first estimate).
                        let depth = DepthSampler.sample(
                            in: depthBuffer?.buffer,
                            centerX: box.x + box.width * 0.5,
                            centerY: box.y + box.height * 0.5,
                            boxWidth: box.width,
                            boxHeight: box.height
                        )

                        detections.append(
                            Detection(
                                box: box,
                                confidence: conf,
                                label: prediction.labels[0].identifier,
                                depth: depth
                            )
                        )
                    }
                }

                // Estimate global camera motion (previous → current) for CMC — identity on the
                // first frame or when registration fails.
                let cameraMotion =
                    previousWrapper.map {
                        motionEstimator.estimate(
                            previous: $0.pixelBuffer,
                            current: wrapper.pixelBuffer
                        )
                    } ?? .identity

                continuation.resume(returning: (detections, inferenceTime, cameraMotion))
                #else
                continuation.resume(returning: nil)
                #endif
            }
        }
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
            let modelName = configuration?.modelName ?? "yolo26n"
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
                // Single still has no tracker — filter by the high threshold so the picker only
                // shows confident objects (the live floor is intentionally low for ByteTrack).
                guard conf >= config.highConfidenceThreshold else { continue }

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

// MARK: - DepthSampler

/// Samples metric depth (metres) at a detection's centre from the depth map attached to the frame.
private enum DepthSampler {
    /// Returns the ~20th percentile of valid samples over the inner ~60% of the box (robust to
    /// see-through background / partial occlusion), or `nil` when no depth is available.
    static func sample(
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
