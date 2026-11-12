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

// MARK: - Model Loading

extension ObjectDetectionClientActor {
    func bundledModelURL(name: String) -> URL? {
        // Xcode compiles .mlpackage → .mlmodelc during build, so check both
        Bundle.module.url(forResource: name, withExtension: "mlmodelc")
            ?? Bundle.module.url(forResource: name, withExtension: "mlpackage")
    }

    /// Load model using CoreML/Vision directly. Uses .cpuAndNeuralEngine to leverage
    /// the Apple Neural Engine for fastest inference while avoiding GPU MLIR crashes.
    func loadModel(from modelURL: URL) throws -> (VNCoreMLModel, [String]) {
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
}
