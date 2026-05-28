import Foundation

// MARK: - SessionConfiguration Convenience

extension MultiCamClient.SessionConfiguration {
	/// Default dual-camera configuration (front + back at 1080p30).
	public static let `default` = Self()

	/// Front + back cameras at 720p for lower resource usage.
	public static let lowPower = Self(
		cameras: [.frontWide, .backWide],
		preferredResolution: .hd720p,
		frameRate: 24
	)

	/// High quality configuration at 4K.
	public static let highQuality = Self(
		cameras: [.frontWide, .backWide],
		preferredResolution: .uhd4K,
		frameRate: 30
	)
}

// MARK: - RecordingConfiguration Convenience

extension MultiCamClient.RecordingConfiguration {
	/// Default recording settings (combined output, H.264, with audio).
	public static let `default` = Self()

	/// HEVC recording for smaller file sizes.
	public static let hevc = Self(
		outputMode: .combined,
		includeAudio: true,
		videoCodec: .hevc,
		videoBitRate: 8_000_000
	)

	/// Record individual files per camera (no combined output).
	public static let perCamera = Self(
		outputMode: .individual,
		includeAudio: true,
		videoCodec: .h264
	)

	/// Record both combined and individual outputs.
	public static let all = Self(
		outputMode: .both,
		includeAudio: true,
		videoCodec: .h264
	)
}

// MARK: - Layout Convenience

extension MultiCamClient.Layout {
	/// Side-by-side grid layout with 2 columns.
	public static let sideBySide = Self.grid(.init(columns: 2))

	/// Vertical stack layout.
	public static let verticalStack = Self.grid(.init(columns: 1))

	/// Standard PiP with back camera as primary and front camera as small overlay.
	public static let standardPiP = Self.pip(.init())
}

// MARK: - RecordingResult Convenience

extension MultiCamClient.RecordingResult {
	/// Whether the recording produced any output files.
	public var hasOutput: Bool {
		combinedURL != nil || !individualURLs.isEmpty
	}
}
