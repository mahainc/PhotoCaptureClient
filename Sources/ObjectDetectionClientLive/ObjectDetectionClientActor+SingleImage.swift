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

// MARK: - Single Image Detection

extension ObjectDetectionClientActor {
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
}
