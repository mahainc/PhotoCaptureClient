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

// MARK: - Start / Stop

extension ObjectDetectionClientActor {
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
}
