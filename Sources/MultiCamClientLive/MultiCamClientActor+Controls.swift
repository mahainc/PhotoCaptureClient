#if os(iOS)
    @preconcurrency import AVFoundation
    import CoreMedia
    import Foundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import UIKit
    import os

    extension MultiCamClientActor {
        // MARK: - Layout

        func setLayout(_ layout: MultiCamClient.Layout) async {
            currentLayout = layout
            let comp = compositor
            await MainActor.run { comp?.setLayout(layout) }
            yieldEvent(.layoutChanged(layout))
        }

        func setCameraOrder(_ cameras: [MultiCamClient.CameraID]) async {
            activeCameras = cameras
            let comp = compositor
            let layout = currentLayout
            await MainActor.run {
                comp?.setCameras(cameras)
                comp?.setLayout(layout)
            }
        }

        func getLayout() -> MultiCamClient.Layout {
            currentLayout
        }

        // MARK: - Zoom

        func setPiPBorder(
            width: Float,
            color: SIMD4<Float>
        ) async {
            let comp = compositor
            await MainActor.run {
                comp?.borderWidth = width
                comp?.borderColor = color
            }
        }

        /// Fast-path live origin update for a PiP overlay during drag.
        /// Skips event broadcast and full layout recompute; canonical state is the caller's responsibility.
        func setPiPOverlayPosition(
            camera: MultiCamClient.CameraID,
            position: CGPoint
        ) async {
            let comp = compositor
            await MainActor.run {
                comp?.updateOverlayOrigin(camera: camera, origin: position)
            }
        }

        /// Install (or replace) the gesture-callback bundle the compositor uses for PiP
        /// drag/pinch. Persisted as actor state so it survives session restart — the new
        /// compositor created in `startSession` automatically picks them up.
        func setPiPGestureCallbacks(_ callbacks: MultiCamClient.PiPGestureCallbacks) async {
            pipGestureCallbacks = callbacks
            let comp = compositor
            await MainActor.run { comp?.setGestureCallbacks(callbacks) }
        }

        /// Show or hide the live histogram. Persisted as actor state so a compositor rebuilt in
        /// `startSession` restores it without the consumer re-installing it.
        func setHistogramVisible(_ visible: Bool) async {
            histogramVisible = visible
            let comp = compositor
            await MainActor.run { comp?.setHistogramVisible(visible) }
        }

        /// Update the live histogram's config. Persisted like `setHistogramVisible` so a
        /// compositor rebuilt in `startSession` restores it.
        func setHistogramConfig(_ config: Histogram.Config) async {
            histogramConfig = config
            let comp = compositor
            await MainActor.run { comp?.setHistogramConfig(config) }
        }

        func setTorch(mode: MultiCamClient.TorchMode) {
            delegate.setTorch(mode: mode)
            logger("Torch set to \(mode.rawValue)")
        }

        func setStabilization(
            camera: MultiCamClient.CameraID,
            mode: MultiCamClient.StabilizationMode
        ) {
            delegate.setStabilization(for: camera, mode: mode)
            logger("Stabilization set to \(mode.rawValue) for \(camera.rawValue)")
        }

        func setZoom(
            camera: MultiCamClient.CameraID,
            factor: CGFloat
        ) throws {
            try delegate.setZoom(for: camera, factor: factor)
            yieldEvent(.zoomChanged(camera, factor))
        }

        func zoomRange(camera: MultiCamClient.CameraID) -> (min: CGFloat, max: CGFloat) {
            delegate.zoomRange(for: camera)
        }
    }
#endif
