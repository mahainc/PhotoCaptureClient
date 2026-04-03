import CoreGraphics
import Foundation
import MultiCamClient

/// Computes per-camera viewport rectangles from a layout configuration.
/// Pure value-type logic — no side effects, easily unit-testable.
struct LayoutEngine: Sendable {

	struct CameraViewport: Sendable, Equatable {
		let cameraID: MultiCamClient.CameraID
		/// Normalized rect in 0-1 space (origin = top-left).
		let rect: CGRect
		/// Draw order (higher = on top).
		let zOrder: Int
		/// Corner radius as fraction of the smaller dimension (0 = sharp, 0.5 = circular).
		let cornerRadius: CGFloat
	}

	func computeViewports(
		layout: MultiCamClient.Layout,
		cameras: [MultiCamClient.CameraID]
	) -> [CameraViewport] {
		guard !cameras.isEmpty else { return [] }

		switch layout {
		case .grid(let grid):
			return computeGrid(grid, cameras: cameras)
		case .pip(let pip):
			return computePiP(pip, cameras: cameras)
		case .custom(let custom):
			return computeCustom(custom, cameras: cameras)
		}
	}

	// MARK: - Grid Layout

	private func computeGrid(
		_ grid: MultiCamClient.GridLayout,
		cameras: [MultiCamClient.CameraID]
	) -> [CameraViewport] {
		let count = cameras.count
		let columns = max(1, min(grid.columns, count))
		let rows = Int(ceil(Double(count) / Double(columns)))

		let cellWidth = 1.0 / CGFloat(columns)
		let cellHeight = 1.0 / CGFloat(rows)

		return cameras.enumerated().map { index, cameraID in
			let col = index % columns
			let row = index / columns
			let rect = CGRect(
				x: CGFloat(col) * cellWidth,
				y: CGFloat(row) * cellHeight,
				width: cellWidth,
				height: cellHeight
			)
			return CameraViewport(
				cameraID: cameraID,
				rect: rect,
				zOrder: index,
				cornerRadius: 0
			)
		}
	}

	// MARK: - PiP Layout

	private func computePiP(
		_ pip: MultiCamClient.PiPLayout,
		cameras: [MultiCamClient.CameraID]
	) -> [CameraViewport] {
		var viewports: [CameraViewport] = []

		// Primary camera is fullscreen
		viewports.append(CameraViewport(
			cameraID: pip.primary,
			rect: CGRect(x: 0, y: 0, width: 1, height: 1),
			zOrder: 0,
			cornerRadius: 0
		))

		// Overlay camera
		let scale = pip.overlayScale
		let padding: CGFloat = 0.02
		let overlayOrigin: CGPoint

		switch pip.overlayPosition {
		case .topLeading:
			overlayOrigin = CGPoint(x: padding, y: padding)
		case .topTrailing:
			overlayOrigin = CGPoint(x: 1.0 - scale - padding, y: padding)
		case .bottomLeading:
			overlayOrigin = CGPoint(x: padding, y: 1.0 - scale * (4.0 / 3.0) - padding)
		case .bottomTrailing:
			overlayOrigin = CGPoint(x: 1.0 - scale - padding, y: 1.0 - scale * (4.0 / 3.0) - padding)
		case .custom(let x, let y):
			overlayOrigin = CGPoint(x: x, y: y)
		}

		// Overlay aspect ratio approximation (3:4 portrait)
		let overlayHeight = scale * (4.0 / 3.0)
		viewports.append(CameraViewport(
			cameraID: pip.overlay,
			rect: CGRect(x: overlayOrigin.x, y: overlayOrigin.y, width: scale, height: overlayHeight),
			zOrder: 1,
			cornerRadius: 0.06
		))

		// Include any additional cameras not in primary/overlay as small thumbnails
		for (index, camera) in cameras.enumerated() {
			if camera != pip.primary && camera != pip.overlay {
				let thumbScale: CGFloat = 0.15
				let thumbY = padding + CGFloat(index) * (thumbScale * (4.0 / 3.0) + padding)
				viewports.append(CameraViewport(
					cameraID: camera,
					rect: CGRect(x: padding, y: thumbY, width: thumbScale, height: thumbScale * (4.0 / 3.0)),
					zOrder: 2 + index,
					cornerRadius: 0.04
				))
			}
		}

		return viewports
	}

	// MARK: - Custom Layout

	private func computeCustom(
		_ custom: MultiCamClient.CustomLayout,
		cameras: [MultiCamClient.CameraID]
	) -> [CameraViewport] {
		cameras.enumerated().compactMap { index, cameraID in
			guard let rect = custom.frames[cameraID] else { return nil }
			return CameraViewport(
				cameraID: cameraID,
				rect: rect,
				zOrder: index,
				cornerRadius: custom.cornerRadii[cameraID] ?? 0
			)
		}
	}
}
