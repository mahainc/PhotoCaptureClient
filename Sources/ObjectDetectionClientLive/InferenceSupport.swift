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

// MARK: - DepthSampler

/// Samples metric depth (metres) at a detection's centre from the depth map attached to the frame.
enum DepthSampler {
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
class ThresholdProvider: MLFeatureProvider {
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
