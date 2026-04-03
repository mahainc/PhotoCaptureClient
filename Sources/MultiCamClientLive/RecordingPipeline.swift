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
		let cameraID: MultiCamClient.CameraID
		var started: Bool = false
	}

	// MARK: - Thread-safe state

	private struct State: @unchecked Sendable {
		var cameraWriters: [MultiCamClient.CameraID: CameraWriter] = [:]
		var isRecording: Bool = false
		var recordingStartDate: Date?
	}

	private let state = OSAllocatedUnfairLock(initialState: State())

	var isRecording: Bool {
		state.withLock { $0.isRecording }
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
					bitRate: config.videoBitRate
				)
				state.cameraWriters[camera] = CameraWriter(
					assetWriter: writer.writer,
					videoInput: writer.videoInput,
					pixelBufferAdaptor: writer.adaptor,
					cameraID: camera
				)
			}

			state.isRecording = true
			state.recordingStartDate = Date()
		}
	}

	// MARK: - Append Samples (synchronous — called from delegate queue)

	func appendVideoSample(_ sampleBuffer: CMSampleBuffer, for camera: MultiCamClient.CameraID) {
		state.withLockUnchecked { state in
			guard state.isRecording, var writer = state.cameraWriters[camera] else { return }

			let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

			if !writer.started {
				writer.assetWriter.startWriting()
				writer.assetWriter.startSession(atSourceTime: time)
				writer.started = true
				state.cameraWriters[camera] = writer
			}

			guard writer.assetWriter.status == .writing,
				  writer.videoInput.isReadyForMoreMediaData,
				  let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

			writer.pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: time)
		}
	}

	func appendAudioSample(_ sampleBuffer: CMSampleBuffer) {
		// Currently individual writers don't have audio inputs.
		// Audio support can be added later.
	}

	// MARK: - Stop Recording

	func stopRecording() async throws -> MultiCamClient.RecordingResult {
		// Snapshot and clear state synchronously
		let (writers, duration) = state.withLock { state -> ([CameraWriter], TimeInterval) in
			guard state.isRecording else { return ([], 0) }
			state.isRecording = false
			let d = -(state.recordingStartDate?.timeIntervalSinceNow ?? 0)
			let w = Array(state.cameraWriters.values)
			state.cameraWriters.removeAll()
			state.recordingStartDate = nil
			return (w, d)
		}

		guard !writers.isEmpty else {
			throw MultiCamClient.Error.recordingNotInProgress
		}

		// Finish writers asynchronously (no lock held)
		var individualURLs: [MultiCamClient.CameraID: URL] = [:]

		for writer in writers {
			if writer.assetWriter.status == .writing {
				writer.videoInput.markAsFinished()
				await writer.assetWriter.finishWriting()
			}
			if writer.assetWriter.status == .completed {
				individualURLs[writer.cameraID] = writer.assetWriter.outputURL
			}
		}

		return MultiCamClient.RecordingResult(
			combinedURL: nil,
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
	}

	private func createVideoWriter(
		url: URL,
		size: CGSize,
		codec: MultiCamClient.VideoCodec,
		bitRate: Int
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
		return WriterBundle(writer: writer, videoInput: videoInput, adaptor: adaptor)
	}
}
#endif
