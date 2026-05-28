#if os(iOS)
import CoreGraphics
import Foundation
import MultiCamClient

/// Converts a `LayoutPreset` + camera configuration into a `MultiCamClient.Layout`.
/// Pure geometry — no side effects, no UIKit dependencies.
public struct LayoutPresetEngine: Sendable {

	public init() {}

	/// Convert a layout preset to a concrete layout with viewport rects.
	///
	/// - Parameters:
	///   - preset: The layout preset to apply.
	///   - cameras: Active cameras in order.
	///   - pipPositions: Per-camera drag positions for PiP overlays (CameraID.rawValue → normalized point).
	///   - pipCornerRadius: Corner radius for PiP overlay cameras (0 = sharp).
	///   - cameraRatios: Per-camera aspect ratios (CameraID.rawValue → ratio).
	///   - overlaySizes: Per-camera PiP overlay sizes (CameraID.rawValue → baseWidth fraction).
	///   - screenAspectRatio: Screen width / height ratio (e.g., ~0.46 for portrait iPhone).
	public func presetToLayout(
		_ preset: MultiCamClient.LayoutPreset,
		cameras: [MultiCamClient.CameraID],
		pipPositions: [String: CGPoint] = [:],
		pipCornerRadius: CGFloat = 0.06,
		pipForceSquare: Bool = false,
		pipForceLandscape: Bool = false,
		cameraRatios: [String: MultiCamClient.AspectRatio] = [:],
		overlaySizes: [String: CGFloat] = [:],
		screenAspectRatio: CGFloat = 0.46
	) -> MultiCamClient.Layout {
		let count = cameras.count
		guard count >= 2 else { return .grid(.init(columns: 1)) }

		var frames: [MultiCamClient.CameraID: CGRect] = [:]

		switch preset {
		case .equal:
			if count == 2 {
				frames[cameras[0]] = CGRect(x: 0, y: 0, width: 0.5, height: 1)
				frames[cameras[1]] = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
			} else if count == 3 {
				frames[cameras[0]] = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
				frames[cameras[1]] = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
				frames[cameras[2]] = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
			} else {
				let cols = 2
				let rows = Int(ceil(Double(count) / Double(cols)))
				let w = 1.0 / CGFloat(cols)
				let h = 1.0 / CGFloat(rows)
				for (i, cam) in cameras.enumerated() {
					frames[cam] = CGRect(x: CGFloat(i % cols) * w, y: CGFloat(i / cols) * h, width: w, height: h)
				}
			}

		case .stacked:
			let h = 1.0 / CGFloat(count)
			for (i, cam) in cameras.enumerated() {
				frames[cam] = CGRect(x: 0, y: CGFloat(i) * h, width: 1, height: h)
			}

		case .focusFirst:
			if count == 2 {
				frames[cameras[0]] = CGRect(x: 0, y: 0, width: 0.7, height: 1)
				frames[cameras[1]] = CGRect(x: 0.7, y: 0, width: 0.3, height: 1)
			} else {
				frames[cameras[0]] = CGRect(x: 0, y: 0, width: 0.6, height: 1)
				let others = Array(cameras.dropFirst())
				let h = 1.0 / CGFloat(others.count)
				for (i, cam) in others.enumerated() {
					frames[cam] = CGRect(x: 0.6, y: CGFloat(i) * h, width: 0.4, height: h)
				}
			}

		case .focusLast:
			if count == 2 {
				frames[cameras[0]] = CGRect(x: 0, y: 0, width: 0.3, height: 1)
				frames[cameras[1]] = CGRect(x: 0.3, y: 0, width: 0.7, height: 1)
			} else {
				let others = Array(cameras.dropLast())
				let h = 1.0 / CGFloat(others.count)
				for (i, cam) in others.enumerated() {
					frames[cam] = CGRect(x: 0, y: CGFloat(i) * h, width: 0.4, height: h)
				}
				frames[cameras.last!] = CGRect(x: 0.4, y: 0, width: 0.6, height: 1)
			}

		case .pip:
			frames[cameras[0]] = CGRect(x: 0, y: 0, width: 1, height: 1)
			let others = Array(cameras.dropFirst())
			let padding: CGFloat = 0.02
			let defaultBaseWidth: CGFloat = 0.35
			let sa = screenAspectRatio
			var radii: [MultiCamClient.CameraID: CGFloat] = [:]
			var yOffset: CGFloat = padding
			for cam in others {
				let bw = overlaySizes[cam.rawValue] ?? defaultBaseWidth
				let overlayW: CGFloat
				let overlayH: CGFloat
				if pipForceSquare {
					// Square / circle shapes require equal visual dimensions
					overlayW = bw
					overlayH = bw * sa
				} else if pipForceLandscape {
					// Landscape rectangle: wider than tall (16:9 landscape ratio)
					overlayW = bw * 1.5
					overlayH = bw * sa * (9.0 / 16.0) * 1.5
				} else {
					let ratio = cameraRatios[cam.rawValue] ?? .ratio9x16
					switch ratio {
					case .ratio9x16:
						overlayW = bw
						overlayH = bw * sa * (16.0 / 9.0)
					case .ratio16x9:
						overlayW = bw
						overlayH = bw * sa * (9.0 / 16.0)
					case .ratio1x1:
						overlayW = bw
						overlayH = bw * sa
					case .ratio4x3:
						overlayW = bw
						overlayH = bw * sa * (4.0 / 3.0)
					}
				}
				if let dragPos = pipPositions[cam.rawValue] {
					frames[cam] = CGRect(x: dragPos.x, y: dragPos.y, width: overlayW, height: overlayH)
				} else {
					// Position overlay at bottom 1/3, horizontally centered
					let centerX = (1.0 - overlayW) / 2.0
					let centerY = (2.0 / 3.0) - (overlayH / 2.0)
					frames[cam] = CGRect(x: centerX, y: centerY, width: overlayW, height: overlayH)
				}
				radii[cam] = pipCornerRadius
				yOffset += overlayH + padding
			}
			return .custom(.init(frames: frames, cornerRadii: radii))
		}

		return .custom(.init(frames: frames))
	}

	/// Compute viewport rects for SwiftUI overlay positioning.
	public func viewportRects(
		_ preset: MultiCamClient.LayoutPreset,
		cameras: [MultiCamClient.CameraID],
		pipPositions: [String: CGPoint] = [:],
		pipCornerRadius: CGFloat = 0.06,
		pipForceSquare: Bool = false,
		pipForceLandscape: Bool = false,
		cameraRatios: [String: MultiCamClient.AspectRatio] = [:],
		overlaySizes: [String: CGFloat] = [:],
		screenAspectRatio: CGFloat = 0.46
	) -> [(camera: MultiCamClient.CameraID, rect: CGRect)] {
		let layout = presetToLayout(preset, cameras: cameras, pipPositions: pipPositions, pipCornerRadius: pipCornerRadius, pipForceSquare: pipForceSquare, pipForceLandscape: pipForceLandscape, cameraRatios: cameraRatios, overlaySizes: overlaySizes, screenAspectRatio: screenAspectRatio)
		guard case .custom(let custom) = layout else { return [] }
		return cameras.compactMap { cam in
			guard let rect = custom.frames[cam] else { return nil }
			return (camera: cam, rect: rect)
		}
	}
}
#endif
