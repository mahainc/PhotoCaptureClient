import CoreGraphics
import CoreML
import Foundation
import ObjectDetectionClient
import Vision

#if canImport(UIKit)
    import UIKit
#endif

/// Runs YOLO instance segmentation on a single still and returns each subject cut out of the
/// frame with its background erased to transparency.
///
/// Deliberately a one-shot over a captured photo, not a per-frame pass: segmentation decodes a
/// prototype-mask bank per instance, far heavier than the realtime detector, so it stays off the
/// live `pixelBufferStream` path and runs only when the app asks for a cutout.
actor SegmentationEngine {
    private let modelName: String
    private var vnModel: VNCoreMLModel?
    private var labels: [String] = []

    init(modelName: String = SegmentationDecoder.defaultModelName) {
        self.modelName = modelName
    }

    func segment(_ imageData: Data) throws -> ObjectDetectionClient.SegmentationResult {
        #if canImport(UIKit)
            let model = try loadedModel()
            guard let sourceCG = SegmentationDecoder.orientedImage(from: imageData) else {
                throw ObjectDetectionClient.Error.inferenceFailed("Invalid image data")
            }

            let request = VNCoreMLRequest(model: model)
            request.imageCropAndScaleOption = .scaleFill
            let handler = VNImageRequestHandler(cgImage: sourceCG, options: [:])

            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request])
            let inferenceMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

            guard let tensors = SegmentationDecoder.tensors(from: request.results) else {
                return ObjectDetectionClient.SegmentationResult(inferenceTimeMs: inferenceMs)
            }
            let objects = SegmentationDecoder.objects(
                detections: tensors.detections,
                prototypes: tensors.prototypes,
                labels: labels,
                source: sourceCG
            )
            DiagnosticLog.shared.log(
                "SEG \(objects.count) obj ["
                    + objects.map { "\($0.label) c=\(String(format: "%.2f", $0.confidence))" }
                    .joined(separator: ", ")
                    + "] in \(Int(inferenceMs))ms")
            return ObjectDetectionClient.SegmentationResult(
                objects: objects,
                inferenceTimeMs: inferenceMs,
                timestamp: .now
            )
        #else
            throw ObjectDetectionClient.Error.inferenceFailed("Segmentation requires iOS")
        #endif
    }

    /// Loads and caches the segmentation model. Uses `.cpuAndNeuralEngine` like the detector, and
    /// installs no `ThresholdProvider`: the seg export is end-to-end and takes no threshold inputs.
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

        do {
            let mlModel: MLModel
            if modelURL.pathExtension == "mlmodelc" {
                mlModel = try MLModel(contentsOf: modelURL, configuration: config)
            } else {
                let compiledURL = try MLModel.compileModel(at: modelURL)
                mlModel = try MLModel(contentsOf: compiledURL, configuration: config)
            }
            let loaded = try VNCoreMLModel(for: mlModel)
            vnModel = loaded
            labels = ModelLabels.parse(mlModel)
            return loaded
        } catch {
            throw ObjectDetectionClient.Error.modelLoadFailed(
                "Segmentation model loading failed: \(error.localizedDescription)"
            )
        }
    }
}

// MARK: - Decoder

/// Turns a YOLO-seg Core ML export's two output tensors into background-removed cutouts.
///
/// The model emits `detections` of shape `[1, N, 4 + 1 + 1 + C]` — box `xyxy` in input pixels,
/// score, class id, then `C` mask coefficients — already NMS'd and sorted by descending score,
/// plus `prototypes` of shape `[1, C, D, D]`: `C` low-resolution mask bases. A subject's mask is
/// `sigmoid(Σ coeff·prototype)`, sampled back onto the source image as the cutout's alpha.
enum SegmentationDecoder {
    static let defaultModelName = "yolo26n-seg"

    /// Model input side in pixels; box coordinates come back in this space (Vision scale-fills to it).
    private static let inputSize: Float = 640
    /// Only cut out subjects at least this confident.
    private static let confidenceThreshold: Float = 0.4
    /// Alpha cutoff on the sigmoid mask — above is subject, below is erased.
    private static let maskThreshold: Float = 0.5

    struct Tensors {
        let detections: MLMultiArray
        let prototypes: MLMultiArray
    }

    #if canImport(UIKit)
        /// Renders image data into a CGImage with its orientation baked into the pixels, so Vision
        /// and the cutout crop share one coordinate space.
        static func orientedImage(from data: Data) -> CGImage? {
            guard let image = UIImage(data: data) else { return nil }
            let renderer = UIGraphicsImageRenderer(size: image.size)
            let oriented = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            return oriented.cgImage
        }
    #endif

    /// Picks the two output tensors out of the Vision results by shape (names are auto-generated MIL
    /// vars that change between exports): the 4-D tensor is the prototypes, the other the detections.
    static func tensors(from results: [VNObservation]?) -> Tensors? {
        let arrays = (results ?? [])
            .compactMap { ($0 as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue }
        let prototypes = arrays.first { $0.shape.count == 4 }
        let detections = arrays.first { $0.shape.count == 3 }
        guard let prototypes, let detections else { return nil }
        return Tensors(detections: detections, prototypes: prototypes)
    }

    static func objects(
        detections: MLMultiArray,
        prototypes: MLMultiArray,
        labels: [String],
        source: CGImage
    ) -> [ObjectDetectionClient.SegmentedObject] {
        guard detections.dataType == .float32, prototypes.dataType == .float32 else { return [] }

        let rowCount = detections.shape[1].intValue
        let columns = detections.shape[2].intValue
        let coefficientCount = prototypes.shape[1].intValue
        let maskDim = prototypes.shape[2].intValue
        let attributeCount = 6  // box(4) + score + class
        guard columns == attributeCount + coefficientCount else { return [] }

        return detections.withUnsafeBufferPointer(ofType: Float.self) { detection in
            prototypes.withUnsafeBufferPointer(ofType: Float.self) { prototype in
                var result: [ObjectDetectionClient.SegmentedObject] = []
                for row in 0..<rowCount {
                    let base = row * columns
                    let score = detection[base + 4]
                    // Rows are sorted by descending score, so the first miss ends the useful rows.
                    guard score >= confidenceThreshold else { break }

                    let box = normalizedBox(detection, at: base)
                    let classID = Int(detection[base + 5])
                    let mask = maskPlane(
                        prototype: prototype,
                        coefficients: detection,
                        coefficientBase: base + attributeCount,
                        coefficientCount: coefficientCount,
                        maskDim: maskDim
                    )
                    guard let cutout = cutoutPNG(source: source, mask: mask, dim: maskDim, box: box)
                    else { continue }

                    result.append(
                        ObjectDetectionClient.SegmentedObject(
                            label: labels[safe: classID] ?? "object",
                            confidence: score,
                            boundingBox: box,
                            cutoutPNG: cutout
                        )
                    )
                }
                return result
            }
        }
    }

    /// Top-left normalized box from the detection row's `xyxy` input-pixel coordinates.
    private static func normalizedBox(
        _ detection: UnsafeBufferPointer<Float>,
        at base: Int
    ) -> ObjectDetectionClient.BoundingBox {
        let x1 = clampUnit(detection[base + 0] / inputSize)
        let y1 = clampUnit(detection[base + 1] / inputSize)
        let x2 = clampUnit(detection[base + 2] / inputSize)
        let y2 = clampUnit(detection[base + 3] / inputSize)
        return ObjectDetectionClient.BoundingBox(
            x: x1,
            y: y1,
            width: max(0, x2 - x1),
            height: max(0, y2 - y1)
        )
    }

    /// `sigmoid(Σ coeff·prototype)` over the `dim × dim` grid, accumulated prototype-by-prototype so
    /// the inner loop walks memory sequentially.
    private static func maskPlane(
        prototype: UnsafeBufferPointer<Float>,
        coefficients: UnsafeBufferPointer<Float>,
        coefficientBase: Int,
        coefficientCount: Int,
        maskDim: Int
    ) -> [Float] {
        let planeSize = maskDim * maskDim
        var plane = [Float](repeating: 0, count: planeSize)
        for k in 0..<coefficientCount {
            let coefficient = coefficients[coefficientBase + k]
            let protoBase = k * planeSize
            for pixel in 0..<planeSize {
                plane[pixel] += coefficient * prototype[protoBase + pixel]
            }
        }
        for pixel in 0..<planeSize {
            plane[pixel] = 1 / (1 + exp(-plane[pixel]))
        }
        return plane
    }

    /// Crops the subject out of the source image, using the mask sampled back to full resolution as
    /// the alpha channel, and encodes it as PNG.
    private static func cutoutPNG(
        source: CGImage,
        mask: [Float],
        dim: Int,
        box: ObjectDetectionClient.BoundingBox
    ) -> Data? {
        #if canImport(UIKit)
            let width = source.width
            let height = source.height
            let x1 = Int((box.x * Float(width)).rounded())
            let y1 = Int((box.y * Float(height)).rounded())
            let cropWidth = max(1, Int((box.width * Float(width)).rounded()))
            let cropHeight = max(1, Int((box.height * Float(height)).rounded()))
            guard
                let crop = source.cropping(
                    to: CGRect(x: x1, y: y1, width: cropWidth, height: cropHeight))
            else {
                return nil
            }

            let bytesPerRow = cropWidth * 4
            var pixels = [UInt8](repeating: 0, count: cropHeight * bytesPerRow)
            let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
                guard
                    let context = CGContext(
                        data: raw.baseAddress,
                        width: cropWidth,
                        height: cropHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                // Flip so buffer row 0 is the image's top row, matching the top-left mask space.
                context.translateBy(x: 0, y: CGFloat(cropHeight))
                context.scaleBy(x: 1, y: -1)
                context.draw(crop, in: CGRect(x: 0, y: 0, width: cropWidth, height: cropHeight))
                return true
            }
            guard drawn else { return nil }

            applyMaskAsAlpha(
                to: &pixels,
                cropOrigin: (x1, y1),
                cropSize: (cropWidth, cropHeight),
                imageSize: (width, height),
                mask: mask,
                dim: dim
            )
            return pngData(from: pixels, width: cropWidth, height: cropHeight, bytesPerRow: bytesPerRow)
        #else
            return nil
        #endif
    }

    /// Multiplies each premultiplied RGBA pixel by its mask alpha, bilinearly sampling the low-res
    /// mask at the pixel's position in the full image.
    private static func applyMaskAsAlpha(
        to pixels: inout [UInt8],
        cropOrigin: (x: Int, y: Int),
        cropSize: (width: Int, height: Int),
        imageSize: (width: Int, height: Int),
        mask: [Float],
        dim: Int
    ) {
        let scaleX = Float(dim) / Float(imageSize.width)
        let scaleY = Float(dim) / Float(imageSize.height)
        for row in 0..<cropSize.height {
            let maskY = (Float(cropOrigin.y + row) + 0.5) * scaleY - 0.5
            for column in 0..<cropSize.width {
                let maskX = (Float(cropOrigin.x + column) + 0.5) * scaleX - 0.5
                let value = bilinear(mask, dim: dim, x: maskX, y: maskY)
                let alpha: Float = value >= maskThreshold ? value : 0
                let index = (row * cropSize.width + column) * 4
                pixels[index + 0] = UInt8(Float(pixels[index + 0]) * alpha)
                pixels[index + 1] = UInt8(Float(pixels[index + 1]) * alpha)
                pixels[index + 2] = UInt8(Float(pixels[index + 2]) * alpha)
                pixels[index + 3] = UInt8(alpha * 255)
            }
        }
    }

    private static func bilinear(_ mask: [Float], dim: Int, x: Float, y: Float) -> Float {
        let clampedX = min(max(x, 0), Float(dim - 1))
        let clampedY = min(max(y, 0), Float(dim - 1))
        let x0 = Int(clampedX)
        let y0 = Int(clampedY)
        let x1 = min(x0 + 1, dim - 1)
        let y1 = min(y0 + 1, dim - 1)
        let fx = clampedX - Float(x0)
        let fy = clampedY - Float(y0)
        let top = mask[y0 * dim + x0] * (1 - fx) + mask[y0 * dim + x1] * fx
        let bottom = mask[y1 * dim + x0] * (1 - fx) + mask[y1 * dim + x1] * fx
        return top * (1 - fy) + bottom * fy
    }

    #if canImport(UIKit)
        private static func pngData(
            from pixels: [UInt8],
            width: Int,
            height: Int,
            bytesPerRow: Int
        ) -> Data? {
            var buffer = pixels
            let image = buffer.withUnsafeMutableBytes { raw -> CGImage? in
                guard
                    let context = CGContext(
                        data: raw.baseAddress,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return nil }
                return context.makeImage()
            }
            guard let image else { return nil }
            return UIImage(cgImage: image).pngData()
        }
    #endif

    private static func clampUnit(_ value: Float) -> Float { min(max(value, 0), 1) }
}

// MARK: - Safe index

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
