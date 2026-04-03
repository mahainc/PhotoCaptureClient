#if os(iOS)
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MultiCamClient
import os

/// Manages AVAssetWriter instances for multi-camera video recording.
/// Append methods are synchronous (called from AVCapture delegate queues).
/// Stop is async (needs to await finishWriting).
final class RecordingPipeline: @unchecked Sendable {

	// MARK: - Types

	private struct CameraWriter {
		let assetWriter: AVAssetWriter
		let videoInput: AVAssetWriterInput
		let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
		let audioInput: AVAssetWriterInput?
		let cameraID: MultiCamClient.CameraID
		var started: Bool = false
	}

	// MARK: - Thread-safe state

	private struct CombinedWriter {
		let assetWriter: AVAssetWriter
		let videoInput: AVAssetWriterInput
		let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor
		let audioInput: AVAssetWriterInput?
		var started: Bool = false
	}

	private struct State: @unchecked Sendable {
		var cameraWriters: [MultiCamClient.CameraID: CameraWriter] = [:]
		var combinedWriter: CombinedWriter?
		var isRecording: Bool = false
		var isPaused: Bool = false
		var recordingStartDate: Date?
		var pausedDuration: TimeInterval = 0
		var pauseStartDate: Date?
		/// Accumulated time offset from pauses — subtracted from all frame timestamps
		/// so the writer sees continuous time with no gaps.
		var timeOffset: CMTime = .zero
		/// Timestamp of the last written video frame (before pause).
		var lastWrittenTime: CMTime = .zero
		/// Whether we need to recalculate offset on the next frame after resume.
		var needsOffsetRecalc: Bool = false
	}

	private let state = OSAllocatedUnfairLock(initialState: State())

	var isRecording: Bool {
		state.withLock { $0.isRecording }
	}

	var isPaused: Bool {
		state.withLock { $0.isPaused }
	}

	func pause() {
		state.withLock { state in
			guard state.isRecording, !state.isPaused else { return }
			state.isPaused = true
			state.pauseStartDate = Date()
		}
	}

	func resume() {
		state.withLock { state in
			guard state.isRecording, state.isPaused else { return }
			if let pauseStart = state.pauseStartDate {
				state.pausedDuration += Date().timeIntervalSince(pauseStart)
			}
			state.isPaused = false
			state.pauseStartDate = nil
			state.needsOffsetRecalc = true
		}
	}

	// MARK: - Start Recording

	func startRecording(
		config: MultiCamClient.RecordingConfiguration,
		cameras: [MultiCamClient.CameraID],
		outputSize: CGSize
	) throws {
		try state.withLock { state in
			guard !state.isRecording else {
				throw MultiCamClient.Error.recordingAlreadyInProgress
			}

			let tempDir = FileManager.default.temporaryDirectory
			let timestamp = Int(Date().timeIntervalSince1970)

			for camera in cameras {
				let url = tempDir.appendingPathComponent("multicam-\(camera.rawValue)-\(timestamp).mp4")
				let writer = try createVideoWriter(
					url: url,
					size: outputSize,
					codec: config.videoCodec,
					bitRate: config.videoBitRate,
					includeAudio: config.includeAudio
				)
				state.cameraWriters[camera] = CameraWriter(
					assetWriter: writer.writer,
					videoInput: writer.videoInput,
					pixelBufferAdaptor: writer.adaptor,
					audioInput: writer.audioInput,
					cameraID: camera
				)
			}

			// Create combined writer for composited output
			let combinedURL = tempDir.appendingPathComponent("multicam-combined-\(timestamp).mp4")
			let combinedBundle = try createVideoWriter(
				url: combinedURL, size: outputSize,
				codec: config.videoCodec, bitRate: config.videoBitRate,
				includeAudio: config.includeAudio
			)
			state.combinedWriter = CombinedWriter(
				assetWriter: combinedBundle.writer,
				videoInput: combinedBundle.videoInput,
				pixelBufferAdaptor: combinedBundle.adaptor,
				audioInput: combinedBundle.audioInput
			)

			state.isRecording = true
			state.recordingStartDate = Date()
		}
	}

	// MARK: - Append Composed Frame (from Metal compositor)

	func appendComposedFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
		state.withLockUnchecked { state in
			guard state.isRecording, !state.isPaused, var writer = state.combinedWriter else { return }

			// Apply same time offset as video samples
			let adjustedTime = CMTimeSubtract(time, state.timeOffset)

			if !writer.started {
				guard writer.assetWriter.startWriting() else {
					print("📹 [RECORDING]: Combined writer startWriting failed: \(writer.assetWriter.error?.localizedDescription ?? "unknown")")
					return
				}
				writer.assetWriter.startSession(atSourceTime: adjustedTime)
				writer.started = true
				state.combinedWriter = writer
			}

			guard writer.assetWriter.status == .writing,
				  writer.videoInput.isReadyForMoreMediaData else { return }

			writer.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: adjustedTime)
		}
	}

	// MARK: - Append Samples (synchronous — called from delegate queue)

	func appendVideoSample(_ sampleBuffer: CMSampleBuffer, for camera: MultiCamClient.CameraID) {
		state.withLockUnchecked { state in
			guard state.isRecording, !state.isPaused, var writer = state.cameraWriters[camera] else { return }

			let rawTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

			// After resume: recalculate time offset from gap
			if state.needsOffsetRecalc {
				let gap = CMTimeSubtract(rawTime, state.lastWrittenTime)
				state.timeOffset = CMTimeAdd(state.timeOffset, gap)
				state.needsOffsetRecalc = false
			}

			// Adjust timestamp to remove paused gaps
			let time = CMTimeSubtract(rawTime, state.timeOffset)

			if !writer.started {
				guard writer.assetWriter.startWriting() else {
					print("📹 [RECORDING]: startWriting failed for \(camera.rawValue): \(writer.assetWriter.error?.localizedDescription ?? "unknown")")
					return
				}
				writer.assetWriter.startSession(atSourceTime: time)
				writer.started = true
				state.cameraWriters[camera] = writer
			}

			guard writer.assetWriter.status == .writing,
				  writer.videoInput.isReadyForMoreMediaData,
				  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

			writer.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: time)
			state.lastWrittenTime = rawTime
		}
	}

	func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
		state.withLockUnchecked { state in
			guard state.isRecording, !state.isPaused else { return }
			// Feed per-camera writers
			for (_, writer) in state.cameraWriters {
				guard writer.started,
					  writer.assetWriter.status == .writing,
					  let audioInput = writer.audioInput,
					  audioInput.isReadyForMoreMediaData else { continue }
				audioInput.append(sampleBuffer)
			}
			// Feed combined writer
			if let writer = state.combinedWriter,
			   writer.started,
			   writer.assetWriter.status == .writing,
			   let audioInput = writer.audioInput,
			   audioInput.isReadyForMoreMediaData {
				audioInput.append(sampleBuffer)
			}
		}
	}

	// MARK: - Stop Recording

	func stopRecording() async throws -> MultiCamClient.RecordingResult {
		// Snapshot and clear state synchronously
		let (writers, combined, duration) = state.withLock { state -> ([CameraWriter], CombinedWriter?, TimeInterval) in
			guard state.isRecording else { return ([], nil, 0) }
			state.isRecording = false
			state.isPaused = false
			var totalPaused = state.pausedDuration
			if let pauseStart = state.pauseStartDate {
				totalPaused += Date().timeIntervalSince(pauseStart)
			}
			let d = -(state.recordingStartDate?.timeIntervalSinceNow ?? 0) - totalPaused
			let w = Array(state.cameraWriters.values)
			let c = state.combinedWriter
			state.cameraWriters.removeAll()
			state.combinedWriter = nil
			state.recordingStartDate = nil
			state.pausedDuration = 0
			state.pauseStartDate = nil
			state.timeOffset = .zero
			state.lastWrittenTime = .zero
			state.needsOffsetRecalc = false
			return (w, c, max(0, d))
		}

		guard !writers.isEmpty else {
			throw MultiCamClient.Error.recordingNotInProgress
		}

		// Finish all writers asynchronously (no lock held)
		var individualURLs: [MultiCamClient.CameraID: URL] = [:]

		for writer in writers {
			if writer.assetWriter.status == .writing {
				writer.videoInput.markAsFinished()
				writer.audioInput?.markAsFinished()
				await writer.assetWriter.finishWriting()
			}
			if writer.assetWriter.status == .completed {
				individualURLs[writer.cameraID] = writer.assetWriter.outputURL
			}
		}

		// Finish combined writer
		var combinedURL: URL?
		if let cw = combined, cw.assetWriter.status == .writing {
			cw.videoInput.markAsFinished()
			cw.audioInput?.markAsFinished()
			await cw.assetWriter.finishWriting()
			if cw.assetWriter.status == .completed {
				combinedURL = cw.assetWriter.outputURL
			}
		}

		return MultiCamClient.RecordingResult(
			combinedURL: combinedURL,
			individualURLs: individualURLs,
			duration: duration,
			timestamp: .now
		)
	}

	// MARK: - Helpers

	private struct WriterBundle {
		let writer: AVAssetWriter
		let videoInput: AVAssetWriterInput
		let adaptor: AVAssetWriterInputPixelBufferAdaptor
		let audioInput: AVAssetWriterInput?
	}

	private func createVideoWriter(
		url: URL,
		size: CGSize,
		codec: MultiCamClient.VideoCodec,
		bitRate: Int,
		includeAudio: Bool = true
	) throws -> WriterBundle {
		try? FileManager.default.removeItem(at: url)

		let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
		let avCodec: AVVideoCodecType = codec == .hevc ? .hevc : .h264

		let videoSettings: [String: Any] = [
			AVVideoCodecKey: avCodec,
			AVVideoWidthKey: Int(size.width),
			AVVideoHeightKey: Int(size.height),
			AVVideoCompressionPropertiesKey: [
				AVVideoAverageBitRateKey: bitRate,
				AVVideoExpectedSourceFrameRateKey: 30,
			],
		]

		let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
		videoInput.expectsMediaDataInRealTime = true

		let adaptor = AVAssetWriterInputPixelBufferAdaptor(
			assetWriterInput: videoInput,
			sourcePixelBufferAttributes: [
				kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
				kCVPixelBufferWidthKey as String: Int(size.width),
				kCVPixelBufferHeightKey as String: Int(size.height),
			]
		)

		writer.add(videoInput)

		var audioInput: AVAssetWriterInput?
		if includeAudio {
			let audioSettings: [String: Any] = [
				AVFormatIDKey: kAudioFormatMPEG4AAC,
				AVSampleRateKey: 44100,
				AVNumberOfChannelsKey: 2,
				AVEncoderBitRateKey: 128_000,
			]
			let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
			aInput.expectsMediaDataInRealTime = true
			writer.add(aInput)
			audioInput = aInput
		}

		return WriterBundle(writer: writer, videoInput: videoInput, adaptor: adaptor, audioInput: audioInput)
	}
}
#endif
