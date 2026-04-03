#if os(iOS)
@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Custom AVVideoCompositing that applies a rounded rectangle mask to video frames during export.
public final class RoundedRectCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {

	nonisolated public var sourcePixelBufferAttributes: [String: any Sendable]? {
		[kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
	}

	nonisolated public var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
		[kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
	}

	private var renderContext: AVVideoCompositionRenderContext?
	private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

	nonisolated public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
		renderContext = newRenderContext
	}

	nonisolated public func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
		guard let instruction = request.videoCompositionInstruction as? RoundedRectInstruction else {
			if let sourceID = request.sourceTrackIDs.first?.int32Value,
			   let sourceBuffer = request.sourceFrame(byTrackID: sourceID) {
				request.finish(withComposedVideoFrame: sourceBuffer)
			} else {
				request.finish(with: NSError(domain: "RoundedRectCompositor", code: 1, userInfo: nil))
			}
			return
		}

		guard let sourceID = (instruction.requiredSourceTrackIDs?.first as? NSNumber)?.int32Value,
			  let sourceBuffer = request.sourceFrame(byTrackID: sourceID),
			  let renderContext else {
			request.finish(with: NSError(domain: "RoundedRectCompositor", code: 2, userInfo: nil))
			return
		}

		let cornerRadius = instruction.cornerRadius
		guard cornerRadius > 0 else {
			request.finish(withComposedVideoFrame: sourceBuffer)
			return
		}

		guard let outputBuffer = renderContext.newPixelBuffer() else {
			request.finish(withComposedVideoFrame: sourceBuffer)
			return
		}

		let width = CVPixelBufferGetWidth(sourceBuffer)
		let height = CVPixelBufferGetHeight(sourceBuffer)
		let size = CGSize(width: width, height: height)
		let minDim = CGFloat(min(width, height))
		let radiusPixels = cornerRadius * minDim

		// Draw source with rounded rect clip using Core Graphics
		CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
		CVPixelBufferLockBaseAddress(outputBuffer, [])
		defer {
			CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
			CVPixelBufferUnlockBaseAddress(outputBuffer, [])
		}

		let colorSpace = CGColorSpaceCreateDeviceRGB()
		guard let outputCtx = CGContext(
			data: CVPixelBufferGetBaseAddress(outputBuffer),
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: CVPixelBufferGetBytesPerRow(outputBuffer),
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
		) else {
			request.finish(withComposedVideoFrame: sourceBuffer)
			return
		}

		// Clear to transparent
		outputCtx.clear(CGRect(origin: .zero, size: size))

		// Clip to rounded rect
		let path = CGPath(roundedRect: CGRect(origin: .zero, size: size),
						  cornerWidth: radiusPixels, cornerHeight: radiusPixels,
						  transform: nil)
		outputCtx.addPath(path)
		outputCtx.clip()

		// Draw source into clipped context
		guard let sourceCtx = CGContext(
			data: CVPixelBufferGetBaseAddress(sourceBuffer),
			width: width,
			height: height,
			bitsPerComponent: 8,
			bytesPerRow: CVPixelBufferGetBytesPerRow(sourceBuffer),
			space: colorSpace,
			bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
		), let sourceImage = sourceCtx.makeImage() else {
			request.finish(withComposedVideoFrame: sourceBuffer)
			return
		}

		outputCtx.draw(sourceImage, in: CGRect(origin: .zero, size: size))

		request.finish(withComposedVideoFrame: outputBuffer)
	}

	nonisolated public func cancelAllPendingVideoCompositionRequests() {}
}

// MARK: - Custom Instruction

public class RoundedRectInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
	public let timeRange: CMTimeRange
	public let enablePostProcessing: Bool = true
	public let containsTweening: Bool = false
	public let requiredSourceTrackIDs: [NSValue]?
	public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
	public let cornerRadius: CGFloat

	public init(timeRange: CMTimeRange, sourceTrackID: CMPersistentTrackID, cornerRadius: CGFloat) {
		self.timeRange = timeRange
		self.requiredSourceTrackIDs = [NSNumber(value: sourceTrackID)]
		self.cornerRadius = cornerRadius
		super.init()
	}
}
#endif
