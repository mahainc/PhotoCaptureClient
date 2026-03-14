import Foundation

// MARK: - PhotoSettings Convenience

extension PhotoCaptureClient.PhotoSettings {
	/// Default settings with auto flash and balanced quality.
	public static let `default` = Self()

	/// High quality settings for maximum detail.
	public static let highQuality = Self(
		flashMode: .auto,
		qualityPrioritization: .quality
	)

	/// Fast capture settings prioritizing speed over quality.
	public static let fast = Self(
		flashMode: .off,
		qualityPrioritization: .speed
	)
}

// MARK: - Photo Convenience

extension PhotoCaptureClient.Photo {
	/// Whether the photo has valid image data.
	public var hasData: Bool {
		guard let data = fileDataRepresentation else { return false }
		return !data.isEmpty
	}
}
