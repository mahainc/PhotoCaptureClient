import CoreML
import CoreVideo
import Foundation
import ObjectDetectionClient
import PhotoCaptureClient
import Vision

/// A depth map that can cross actor boundaries. The `CVPixelBuffer` itself is not `Sendable`, but the
/// estimator hands ownership straight to the detector and never mutates it afterwards.
struct DepthMap: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

/// Monocular depth estimator for devices with no hardware depth sensor.
///
/// Turns a camera frame into a dense relative-depth map whose values follow the hardware
/// convention — smaller is nearer — so it drops straight into the same per-object `DepthSampler`
/// used for LiDAR / dual-camera depth. It is a second full-frame inference, so the caller runs it
/// only when `PixelBufferWrapper.depthBuffer` is nil and at a reduced cadence; the map ranks the
/// nearest object and is not metric.
actor DepthEstimator {
    private let modelName: String
    private var vnModel: VNCoreMLModel?
    private let inferenceQueue = DispatchQueue(label: "DepthEstimator.inference", qos: .userInitiated)

    init(modelName: String = "yolo26n-depth") {
        self.modelName = modelName
    }

    /// A DepthFloat32 depth map the size of the model's output, or nil if the model is missing or
    /// inference fails. Takes the `Sendable` frame wrapper so nothing non-`Sendable` crosses in.
    func estimate(_ wrapper: PhotoCaptureClient.PixelBufferWrapper) async -> DepthMap? {
        guard let model = try? loadedModel() else { return nil }
        return await withCheckedContinuation { continuation in
            inferenceQueue.async {
                let request = VNCoreMLRequest(model: model)
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(cvPixelBuffer: wrapper.pixelBuffer, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let array =
                    (request.results?.first as? VNCoreMLFeatureValueObservation)?
                    .featureValue.multiArrayValue
                continuation.resume(returning: array.flatMap(Self.depthBuffer(from:)).map(DepthMap.init))
            }
        }
    }

    private func loadedModel() throws -> VNCoreMLModel {
        if let vnModel { return vnModel }

        guard
            let modelURL = Bundle.module.url(forResource: modelName, withExtension: "mlmodelc")
                ?? Bundle.module.url(forResource: modelName, withExtension: "mlpackage")
        else {
            throw ObjectDetectionClient.Error.modelLoadFailed(
                "Bundled model '\(modelName)' not found in resources"
            )
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine

        let mlModel: MLModel
        if modelURL.pathExtension == "mlmodelc" {
            mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        } else {
            let compiledURL = try MLModel.compileModel(at: modelURL)
            mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
        }
        let loaded = try VNCoreMLModel(for: mlModel)
        vnModel = loaded
        return loaded
    }

    /// Copies a `[1, 1, H, W]` float depth map into a DepthFloat32 pixel buffer row by row, honouring
    /// the buffer's own row padding.
    private static func depthBuffer(from array: MLMultiArray) -> CVPixelBuffer? {
        guard array.dataType == .float32, array.shape.count == 4 else { return nil }
        let height = array.shape[2].intValue
        let width = array.shape[3].intValue
        guard width > 0, height > 0 else { return nil }

        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_DepthFloat32,
            attributes,
            &created
        )
        guard status == kCVReturnSuccess, let buffer = created else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let destinationBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        array.withUnsafeBufferPointer(ofType: Float.self) { source in
            guard let sourceBase = source.baseAddress else { return }
            for row in 0..<height {
                let destinationRow = base.advanced(by: row * destinationBytesPerRow)
                    .assumingMemoryBound(to: Float.self)
                destinationRow.update(from: sourceBase.advanced(by: row * width), count: width)
            }
        }
        return buffer
    }
}
