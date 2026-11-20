import DependenciesMacros
import Foundation
import HistogramKit

#if os(iOS)
    import UIKit
#endif

/// A dependency client wrapping AVFoundation's photo capture APIs for use with TCA.
///
/// `PhotoCaptureClient` provides a testable, injectable interface for camera session
/// management, photo capture, and device control.
///
/// ## Usage
///
/// ```swift
/// @Dependency(\.photoCapture) var photoCapture
///
/// let photo = try await photoCapture.capturePhoto(.init(flashMode: .auto))
/// ```
@DependencyClient
public struct PhotoCaptureClient: Sendable {

    // MARK: - Session Lifecycle

    public var startSession: @Sendable () async throws -> Void

    public var stopSession: @Sendable () async -> Void = {}

    // MARK: - Photo Capture

    public var capturePhoto: @Sendable (_ settings: PhotoSettings) async throws -> Photo

    // MARK: - Camera Control

    public var switchCamera: @Sendable (_ position: CameraPosition) async throws -> Void

    public var setFlashMode: @Sendable (_ mode: FlashMode) async -> Void = { _ in }

    public var focus: @Sendable (_ point: CGPoint) async throws -> Void

    public var setZoomFactor: @Sendable (_ factor: CGFloat) async throws -> Void

    /// Set visual zoom in the Metal shader (not AVFoundation).
    /// - Parameters:
    ///   - factor: Zoom level (1.0 = no zoom, max ~5.0)
    ///   - anchorX: Normalized screen X coordinate of the zoom center (0-1)
    ///   - anchorY: Normalized screen Y coordinate of the zoom center (0-1)
    public var setVisualZoom: @Sendable (_ factor: CGFloat, _ anchorX: CGFloat, _ anchorY: CGFloat) async -> Void = {
        _,
        _,
        _ in
    }

    // MARK: - Hardware Exposure / White Balance / Torch

    /// Set the exposure target bias (EV) on the active device via `setExposureTargetBias(_:)`,
    /// clamped to the device's `[minExposureTargetBias, maxExposureTargetBias]` range.
    public var setExposureBias: @Sendable (_ bias: Float) async throws -> Void

    /// The active device's supported exposure-bias range in EV; `defaultExposureBiasRange`
    /// when no device is active yet.
    public var exposureBiasRange: @Sendable () async -> ClosedRange<Float> = {
        PhotoCaptureClient.defaultExposureBiasRange
    }

    /// Lock white balance to a colour temperature in kelvin (tint held at 0), converting it to
    /// device gains and clamping them to `maxWhiteBalanceGain`. No-op when the device does not
    /// support a locked white-balance mode.
    public var setWhiteBalanceKelvin: @Sendable (_ kelvin: Float) async throws -> Void

    /// The active device's usable zoom range (`minAvailableVideoZoomFactor ... maxAvailableVideoZoomFactor`),
    /// capped at `10.0`. Falls back to `1.0...5.0` when no device is active yet.
    public var zoomFactorRange: @Sendable () async -> ClosedRange<CGFloat> = { 1.0...5.0 }

    /// Set the torch (video light) level in `0...1`. `<= 0` turns the torch off; otherwise the torch
    /// is switched on at `max(level, 0.01)`. No-op on devices without a torch (e.g. the front camera).
    public var setTorchLevel: @Sendable (_ level: Float) async throws -> Void

    // MARK: - Authorization

    public var requestAuthorization: @Sendable () async -> AuthorizationStatus = { .notDetermined }

    public var authorizationStatus: @Sendable () -> AuthorizationStatus = { .notDetermined }

    // MARK: - Observation

    public var events: @Sendable () async -> AsyncStream<Event> = { AsyncStream { _ in } }

    // MARK: - Frame Delivery

    /// Stream of pixel buffers from the camera. Used by ObjectDetectionClientLive for inference.
    public var pixelBufferStream: @Sendable () async -> AsyncStream<PixelBufferWrapper> = { AsyncStream { _ in } }

    // MARK: - Preview

    public var previewView: @Sendable () async -> PreviewView = {
        await MainActor.run {
            #if os(iOS)
                PreviewView(view: UIView())
            #endif
        }
    }

    // MARK: - Overlay

    /// Update bounding box overlays on the Metal preview. Pass empty array to clear.
    /// Note: Updates are best-effort ordered (acceptable since each call fully replaces all overlays).
    public var updateOverlays: @Sendable (_ overlays: [OverlayRect]) -> Void = { _ in }

    /// Replace the text drawn on the Metal preview; it follows the camera frame and eases between
    /// updates. Pass an empty array to clear.
    public var updateTextOverlays: @Sendable (_ overlays: [TextOverlay]) -> Void = { _ in }

    /// Show or hide detection labels (class name + confidence) drawn on the preview.
    /// Labels are derived from each `OverlayRect`'s `label` / `confidence`; boxes are unaffected.
    public var setLabelsVisible: @Sendable (_ visible: Bool) -> Void = { _ in }

    /// Choose how detection overlays are drawn on the live preview (boxes vs. a single
    /// animated center dot). Overlay data is still supplied via `updateOverlays`.
    public var setOverlayStyle: @Sendable (_ style: OverlayStyle) -> Void = { _ in }

    /// Show or hide the live RGB + luminance histogram drawn over the preview. It reflects
    /// the viewfinder in real time as an exposure aid; it does not alter the captured image.
    public var setHistogramVisible: @Sendable (_ visible: Bool) -> Void = { _ in }

    /// Adjust the live histogram's channels, on-screen frame, and opacity. Takes effect on the
    /// next drawn frame; independent of `setHistogramVisible`.
    public var setHistogramConfig: @Sendable (_ config: Histogram.Config) -> Void = { _ in }

    /// Per-channel RGBA gain on the live preview and the histogram reading it, not the captured photo;
    /// `(1,1,1,1)` leaves the feed untouched.
    public var setPreviewChannelGains: @Sendable (_ gains: SIMD4<Float>) -> Void = { _ in }

    /// Minimum gap between frames delivered on `pixelBufferStream` (default 0.333 s, ~3 fps).
    /// Lower it while a consumer needs more frames, e.g. live OCR; the preview is unaffected.
    public var setFrameDeliveryInterval: @Sendable (_ seconds: TimeInterval) async -> Void = { _ in }

    // MARK: - Preview Performance

    /// Lower (or restore) the live preview's running cost without tearing the session down —
    /// used when a result floats over the feed and the full viewfinder is not worth its heat.
    public var setPreviewPerformanceMode: @Sendable (_ mode: PreviewPerformanceMode) async -> Void = { _ in }
}

extension PhotoCaptureClient {
    /// The exposure-bias range in EV reported before any device is active.
    public static let defaultExposureBiasRange: ClosedRange<Float> = -2...2
}
