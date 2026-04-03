#if os(iOS)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MultiCamClient

/// Reusable video composition and export utilities for multi-camera recordings.
public enum VideoExporter {

	/// Layout orientation for compositing multiple videos.
	public enum CompositeLayout: Sendable {
		case vertical
		case horizontal
	}

	// MARK: - Composite with Custom Layout (matches preview)

	/// Composite multiple videos using per-camera viewport rects that match the live preview layout.
	///
	/// - Parameters:
	///   - urls: Video file URLs in camera order.
	///   - cameraOrder: Camera IDs in the same order as urls.
	///   - frames: Per-camera viewport rects in normalized 0-1 space (from CustomLayout).
	///   - outputSize: Target output resolution.
	///   - fileType: Output file type (.mp4 or .mov).
	/// - Returns: URL of the composited video file.
	public static func compositeWithLayout(
		_ urls: [URL],
		cameraOrder: [MultiCamClient.CameraID],
		frames: [MultiCamClient.CameraID: CGRect],
		outputSize: CGSize,
		fileType: AVFileType = .mp4
	) async throws -> URL {
		let assets = urls.map { AVURLAsset(url: $0) }
		guard assets.count >= 2 else { return urls[0] }

		// Batch-load properties
		var durations: [CMTime] = []
		var videoTracks: [AVAssetTrack] = []
		var sizes: [CGSize] = []
		var trackTransforms: [CGAffineTransform] = []

		for asset in assets {
			async let d = asset.load(.duration)
			async let tracks = asset.loadTracks(withMediaType: .video)
			let duration = try await d
			guard let track = try await tracks.first else { continue }
			let naturalSize = try await track.load(.naturalSize)
			let transform = try await track.load(.preferredTransform)
			let t = naturalSize.applying(transform)

			durations.append(duration)
			videoTracks.append(track)
			sizes.append(CGSize(width: abs(t.width), height: abs(t.height)))
			trackTransforms.append(transform)
		}

		guard videoTracks.count >= 2 else { return urls[0] }
		let minDuration = durations.min() ?? .zero

		let composition = AVMutableComposition()
		let timeRange = CMTimeRange(start: .zero, duration: minDuration)
		var compositionTracks: [AVMutableCompositionTrack] = []

		for (i, track) in videoTracks.enumerated() {
			guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(i + 1)) else { continue }
			try ct.insertTimeRange(timeRange, of: track, at: .zero)
			compositionTracks.append(ct)
		}

		// Add audio from first source
		for asset in assets {
			if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
			   let audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
				try? audioCompTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
				break
			}
		}

		let videoComposition = AVMutableVideoComposition()
		videoComposition.renderSize = outputSize
		videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

		let instruction = AVMutableVideoCompositionInstruction()
		instruction.timeRange = timeRange
		var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []

		for (i, ct) in compositionTracks.enumerated() {
			guard i < cameraOrder.count else { continue }
			let cameraID = cameraOrder[i]
			guard let vpRect = frames[cameraID] else { continue }

			let li = AVMutableVideoCompositionLayerInstruction(assetTrack: ct)
			let srcSize = sizes[i]
			let trackTransform = trackTransforms[i]

			// Convert viewport rect (0-1 normalized) to pixel coordinates
			let vpX = vpRect.origin.x * outputSize.width
			let vpY = vpRect.origin.y * outputSize.height
			let vpW = vpRect.width * outputSize.width
			let vpH = vpRect.height * outputSize.height

			// Aspect-fill: scale to fill the viewport while preserving aspect ratio
			let scaleX = vpW / srcSize.width
			let scaleY = vpH / srcSize.height
			let scale = max(scaleX, scaleY) // fill (not fit)
			let scaledW = srcSize.width * scale
			let scaledH = srcSize.height * scale
			let xOff = vpX + (vpW - scaledW) / 2
			let yOff = vpY + (vpH - scaledH) / 2

			let transform = trackTransform
				.concatenating(CGAffineTransform(scaleX: scale, y: scale))
				.concatenating(CGAffineTransform(translationX: xOff, y: yOff))

			li.setTransform(transform, at: .zero)
			layerInstructions.append(li)
		}

		instruction.layerInstructions = layerInstructions
		videoComposition.instructions = [instruction]

		let ext = fileType == .mov ? "mov" : "mp4"
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("multicam-composite-\(UUID().uuidString.prefix(8)).\(ext)")
		try? FileManager.default.removeItem(at: outputURL)

		guard let session = AVAssetExportSession(asset: composition, presetName: exportPreset(for: outputSize)) else {
			throw MultiCamClient.Error.exportFailed("Failed to create export session")
		}
		session.outputURL = outputURL
		session.outputFileType = fileType
		session.videoComposition = videoComposition
		session.shouldOptimizeForNetworkUse = true
		await session.export()
		guard session.status == .completed else {
			throw session.error ?? MultiCamClient.Error.exportFailed("Export failed")
		}
		return outputURL
	}

	// MARK: - Simple Composite (vertical/horizontal stack)

	/// Composite multiple videos in a simple stack layout.
	public static func compositeVideos(
		_ urls: [URL],
		layout: CompositeLayout,
		outputSize: CGSize,
		fileType: AVFileType = .mp4
	) async throws -> URL {
		let assets = urls.map { AVURLAsset(url: $0) }
		guard assets.count >= 2 else { return urls[0] }

		var durations: [CMTime] = []
		var videoTracks: [AVAssetTrack] = []
		var sizes: [CGSize] = []
		var transforms: [CGAffineTransform] = []

		for asset in assets {
			async let d = asset.load(.duration)
			async let tracks = asset.loadTracks(withMediaType: .video)
			let duration = try await d
			guard let track = try await tracks.first else { continue }
			let naturalSize = try await track.load(.naturalSize)
			let transform = try await track.load(.preferredTransform)
			let t = naturalSize.applying(transform)

			durations.append(duration)
			videoTracks.append(track)
			sizes.append(CGSize(width: abs(t.width), height: abs(t.height)))
			transforms.append(transform)
		}

		guard videoTracks.count >= 2 else { return urls[0] }
		let minDuration = durations.min() ?? .zero

		let composition = AVMutableComposition()
		let timeRange = CMTimeRange(start: .zero, duration: minDuration)
		var compositionTracks: [AVMutableCompositionTrack] = []
		for (i, track) in videoTracks.enumerated() {
			guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: CMPersistentTrackID(i + 1)) else { continue }
			try ct.insertTimeRange(timeRange, of: track, at: .zero)
			compositionTracks.append(ct)
		}

		for asset in assets {
			if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
			   let audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
				try? audioCompTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
				break
			}
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
			let trackTransform = transforms[i]

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

		let ext = fileType == .mov ? "mov" : "mp4"
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("multicam-\(layout == .vertical ? "9x16" : "16x9")-\(UUID().uuidString.prefix(8)).\(ext)")
		try? FileManager.default.removeItem(at: outputURL)

		guard let session = AVAssetExportSession(asset: composition, presetName: exportPreset(for: outputSize)) else {
			throw MultiCamClient.Error.exportFailed("Failed to create export session")
		}
		session.outputURL = outputURL
		session.outputFileType = fileType
		session.videoComposition = videoComposition
		session.shouldOptimizeForNetworkUse = true
		await session.export()
		guard session.status == .completed else {
			throw session.error ?? MultiCamClient.Error.exportFailed("Export failed")
		}
		return outputURL
	}

	// MARK: - Crop Single Video

	/// Crop/resize a single video to the target aspect ratio.
	public static func cropVideo(
		_ url: URL,
		toRatio ratio: MultiCamClient.AspectRatio,
		outputSize: CGSize,
		label: String = "cropped",
		cornerRadius: CGFloat = 0,
		fileType: AVFileType = .mp4
	) async throws -> URL {
		let asset = AVURLAsset(url: url)
		async let durationTask = asset.load(.duration)
		async let tracksTask = asset.loadTracks(withMediaType: .video)

		let duration = try await durationTask
		guard let track = try await tracksTask.first else { return url }

		let naturalSize = try await track.load(.naturalSize)
		let preferredTransform = try await track.load(.preferredTransform)
		let transformed = naturalSize.applying(preferredTransform)
		let srcW = abs(transformed.width)
		let srcH = abs(transformed.height)

		// Skip re-encoding if source ratio approximately matches target
		let srcRatio = srcW / srcH
		let targetRatio = outputSize.width / outputSize.height
		if abs(srcRatio - targetRatio) < 0.05 && cornerRadius == 0 {
			let ext = fileType == .mov ? "mov" : "mp4"
			let copyURL = FileManager.default.temporaryDirectory
				.appendingPathComponent("multicam-\(label)-copy-\(UUID().uuidString.prefix(8)).\(ext)")
			try? FileManager.default.removeItem(at: copyURL)
			try FileManager.default.copyItem(at: url, to: copyURL)
			return copyURL
		}

		let composition = AVMutableComposition()
		let timeRange = CMTimeRange(start: .zero, duration: duration)
		guard let compTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: 1) else { return url }
		try compTrack.insertTimeRange(timeRange, of: track, at: .zero)

		if let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first,
		   let audioCompTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
			try? audioCompTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
		}

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

		if cornerRadius > 0 {
			videoComposition.customVideoCompositorClass = RoundedRectCompositor.self
			let roundedInstruction = RoundedRectInstruction(
				timeRange: timeRange,
				sourceTrackID: compTrack.trackID,
				cornerRadius: cornerRadius
			)
			videoComposition.instructions = [roundedInstruction]
			compTrack.preferredTransform = transform
		} else {
			let instruction = AVMutableVideoCompositionInstruction()
			instruction.timeRange = timeRange
			let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compTrack)
			layerInstruction.setTransform(transform, at: .zero)
			instruction.layerInstructions = [layerInstruction]
			videoComposition.instructions = [instruction]
		}

		let ext = fileType == .mov ? "mov" : "mp4"
		let ratioStr = ratio.rawValue.replacingOccurrences(of: ":", with: "x")
		let outputURL = FileManager.default.temporaryDirectory
			.appendingPathComponent("multicam-\(label)-\(ratioStr)-\(UUID().uuidString.prefix(8)).\(ext)")
		try? FileManager.default.removeItem(at: outputURL)

		guard let session = AVAssetExportSession(asset: composition, presetName: exportPreset(for: outputSize)) else {
			throw MultiCamClient.Error.exportFailed("Failed to create export session for crop")
		}
		session.outputURL = outputURL
		session.outputFileType = fileType
		session.videoComposition = videoComposition
		session.shouldOptimizeForNetworkUse = true
		await session.export()

		guard session.status == .completed else {
			throw session.error ?? MultiCamClient.Error.exportFailed("Crop export failed")
		}
		return outputURL
	}

	// MARK: - Helpers

	private static func exportPreset(for outputSize: CGSize) -> String {
		let maxDim = max(outputSize.width, outputSize.height)
		if maxDim <= 1280 { return AVAssetExportPreset1280x720 }
		if maxDim <= 1920 { return AVAssetExportPreset1920x1080 }
		return AVAssetExportPreset3840x2160
	}
}
#endif
