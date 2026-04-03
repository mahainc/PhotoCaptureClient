#if os(iOS)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MultiCamClient

/// Reusable video composition and export utilities for multi-camera recordings.
public enum VideoExporter {

	/// Layout orientation for compositing multiple videos.
	public enum CompositeLayout: Sendable {
		/// Cameras stacked vertically (top to bottom).
		case vertical
		/// Cameras placed side by side (left to right).
		case horizontal
	}

	/// Composite multiple video files into a single video with cameras arranged
	/// in the specified layout orientation.
	///
	/// - Parameters:
	///   - urls: Video file URLs to composite (order determines position).
	///   - layout: `.vertical` (stacked) or `.horizontal` (side-by-side).
	///   - outputSize: Target output resolution.
	/// - Returns: URL of the composited video file.
	public static func compositeVideos(
		_ urls: [URL],
		layout: CompositeLayout,
		outputSize: CGSize
	) async throws -> URL {
		let assets = urls.map { AVURLAsset(url: $0) }
		var durations: [CMTime] = []
		for asset in assets { durations.append(try await asset.load(.duration)) }
		let minDuration = durations.min() ?? .zero

		var videoTracks: [AVAssetTrack] = []
		for asset in assets {
			guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
			videoTracks.append(track)
		}
		guard videoTracks.count >= 2 else { return urls[0] }

		var sizes: [CGSize] = []
		for track in videoTracks {
			let s = try await track.load(.naturalSize)
			let t = s.applying(try await track.load(.preferredTransform))
			sizes.append(CGSize(width: abs(t.width), height: abs(t.height)))
		}

		let composition = AVMutableComposition()
		let timeRange = CMTimeRange(start: .zero, duration: minDuration)
		var compositionTracks: [AVMutableCompositionTrack] = []
		for (i, track) in videoTracks.enumerated() {
			guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(i + 1)) else { continue }
			try ct.insertTimeRange(timeRange, of: track, at: .zero)
			compositionTracks.append(ct)
		}

		let videoComposition = AVMutableVideoComposition()
		videoComposition.renderSize = outputSize
		videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

		let instruction = AVMutableVideoCompositionInstruction()
		instruction.timeRange = timeRange
		var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []

		for (i, ct) in compositionTracks.enumerated() {
			let li = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
			let srcSize = sizes[i]
			let trackTransform = try await videoTracks[i].load(.preferredTransform)

			let transform: CGAffineTransform
			switch layout {
			case .vertical:
				let slotH = outputSize.height / CGFloat(compositionTracks.count)
				let scale = min(outputSize.width / srcSize.width, slotH / srcSize.height)
				let xOff = (outputSize.width - srcSize.width * scale) / 2
				let yOff = slotH * CGFloat(i) + (slotH - srcSize.height * scale) / 2
				transform = trackTransform
					.concatenating(CGAffineTransform(scaleX: scale, y: scale))
					.concatenating(CGAffineTransform(translationX: xOff, y: yOff))
			case .horizontal:
				let slotW = outputSize.width / CGFloat(compositionTracks.count)
				let scale = min(slotW / srcSize.width, outputSize.height / srcSize.height)
				let xOff = slotW * CGFloat(i) + (slotW - srcSize.width * scale) / 2
				let yOff = (outputSize.height - srcSize.height * scale) / 2
				transform = trackTransform
					.concatenating(CGAffineTransform(scaleX: scale, y: scale))
					.concatenating(CGAffineTransform(translationX: xOff, y: yOff))
			}
			li.setTransform(transform, at: .zero)
			layerInstructions.append(li)
		}

		instruction.layerInstructions = layerInstructions
		videoComposition.instructions = [instruction]

		let suffix = layout == .vertical ? "9x16" : "16x9"
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("multicam-\(suffix)-\(Int(Date().timeIntervalSince1970)).mp4")
		try? FileManager.default.removeItem(at: outputURL)

		guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
			throw MultiCamClient.Error.exportFailed("Failed to create export session")
		}
		session.outputURL = outputURL
		session.outputFileType = .mp4
		session.videoComposition = videoComposition
		await session.export()
		guard session.status == .completed else {
			throw session.error ?? MultiCamClient.Error.exportFailed("Export failed")
		}
		return outputURL
	}

	/// Crop/resize a single video to the target aspect ratio using center-crop.
	///
	/// - Parameters:
	///   - url: Source video file URL.
	///   - ratio: Target aspect ratio.
	///   - outputSize: Target output resolution.
	///   - label: Optional label for the output filename.
	/// - Returns: URL of the cropped video file.
	public static func cropVideo(
		_ url: URL,
		toRatio ratio: MultiCamClient.AspectRatio,
		outputSize: CGSize,
		label: String = "cropped"
	) async throws -> URL {
		let asset = AVURLAsset(url: url)
		let duration = try await asset.load(.duration)
		guard let track = try await asset.loadTracks(withMediaType: .video).first else { return url }

		let naturalSize = try await track.load(.naturalSize)
		let preferredTransform = try await track.load(.preferredTransform)
		let transformed = naturalSize.applying(preferredTransform)
		let srcW = abs(transformed.width)
		let srcH = abs(transformed.height)

		let composition = AVMutableComposition()
		let timeRange = CMTimeRange(start: .zero, duration: duration)
		guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else { return url }
		try compTrack.insertTimeRange(timeRange, of: track, at: .zero)

		let scaleX = outputSize.width / srcW
		let scaleY = outputSize.height / srcH
		let scale = max(scaleX, scaleY)
		let scaledW = srcW * scale
		let scaledH = srcH * scale
		let xOff = (outputSize.width - scaledW) / 2
		let yOff = (outputSize.height - scaledH) / 2

		let transform = preferredTransform
			.concatenating(CGAffineTransform(scaleX: scale, y: scale))
			.concatenating(CGAffineTransform(translationX: xOff, y: yOff))

		let videoComposition = AVMutableVideoComposition()
		videoComposition.renderSize = outputSize
		videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

		let instruction = AVMutableVideoCompositionInstruction()
		instruction.timeRange = timeRange
		let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
		layerInstruction.setTransform(transform, at: .zero)
		instruction.layerInstructions = [layerInstruction]
		videoComposition.instructions = [instruction]

		let ratioStr = ratio.rawValue.replacingOccurrences(of: ":", with: "x")
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("multicam-\(label)-\(ratioStr)-\(Int(Date().timeIntervalSince1970)).mp4")
		try? FileManager.default.removeItem(at: outputURL)

		guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
			return url
		}
		session.outputURL = outputURL
		session.outputFileType = .mp4
		session.videoComposition = videoComposition
		await session.export()

		return session.status == .completed ? outputURL : url
	}
}
#endif
