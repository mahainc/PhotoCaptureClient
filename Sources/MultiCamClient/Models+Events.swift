import CasePaths
import CoreGraphics
import CoreVideo
import Foundation
import PhotoCaptureClient

#if os(iOS)
    import UIKit
#endif

// MARK: - Event

extension MultiCamClient {
    @CasePathable
    public enum Event: Sendable, Equatable {
        // Session lifecycle
        case sessionStarted
        case sessionStopped
        case sessionError(String)
        case sessionInterrupted(String)
        case sessionInterruptionEnded

        // Camera lifecycle
        case cameraConnected(CameraID)
        case cameraDisconnected(CameraID)

        // Recording lifecycle
        case recordingStarted
        case recordingPaused
        case recordingResumed
        case recordingStopped(RecordingResult)
        case recordingError(String)

        // Photo capture
        case photoCaptured(CameraID)

        // Layout
        case layoutChanged(Layout)

        // Zoom
        case zoomChanged(CameraID, CGFloat)

        // System pressure
        case systemPressureChanged(SystemPressureLevel)
        case hardwareCostUpdated(Float)
    }

    /// Maps to AVCaptureDevice.SystemPressureState.Level
    public enum SystemPressureLevel: String, Sendable, Equatable {
        case nominal
        case fair
        case serious
        case critical
        case shutdown
    }
}

// MARK: - Error

extension MultiCamClient {
    public enum Error: Swift.Error, Sendable, LocalizedError {
        case multiCamNotSupported
        case cameraSetNotSupported([CameraID])
        case sessionAlreadyRunning
        case sessionNotRunning
        case recordingAlreadyInProgress
        case recordingNotInProgress
        case recordingFailed(String)
        case exportFailed(String)
        case notAuthorized
        case audioDeviceUnavailable

        public var errorDescription: String? {
            switch self {
                case .multiCamNotSupported:
                    return "Multi-camera capture is not supported on this device"
                case .cameraSetNotSupported(let cameras):
                    return "Camera combination not supported: \(cameras.map(\.rawValue).joined(separator: ", "))"
                case .sessionAlreadyRunning:
                    return "Multi-cam session is already running"
                case .sessionNotRunning:
                    return "Multi-cam session is not running"
                case .recordingAlreadyInProgress:
                    return "Recording is already in progress"
                case .recordingNotInProgress:
                    return "No recording in progress"
                case .recordingFailed(let reason):
                    return "Recording failed: \(reason)"
                case .exportFailed(let reason):
                    return "Export failed: \(reason)"
                case .notAuthorized:
                    return "Camera or microphone access is not authorized"
                case .audioDeviceUnavailable:
                    return "Audio capture device is unavailable"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
                case .multiCamNotSupported:
                    return
                        "This device does not support simultaneous multi-camera capture. Use single-camera mode instead."
                case .notAuthorized:
                    return "Go to Settings > Privacy to grant camera and microphone access."
                default:
                    return nil
            }
        }
    }
}

// MARK: - PiP Gesture Callbacks

extension MultiCamClient {

    /// Distinguishes the kind of direct-manipulation gesture the compositor recognized.
    public enum PiPGestureKind: Sendable, Equatable {
        case drag
        case pinch
    }

    /// All hooks the compositor uses to coordinate PiP gestures with the host app.
    /// Pass into `setPiPGestureCallbacks`; defaults are no-ops so partial adoption is safe.
    ///
    /// All closures fire on the main actor (UIKit gesture recognizers run on the main
    /// thread), so consumers can synchronously read `@MainActor`-isolated state such as
    /// a TCA `Store.state` without hopping.
    public struct PiPGestureCallbacks: Sendable {

        /// Should this camera respond to drag/pinch gestures? Compositor calls on touch-began.
        /// Return `false` for the primary fullscreen camera and for non-PiP layouts.
        public var isCameraInteractive: @Sendable @MainActor (CameraID) -> Bool

        /// Clamp a proposed viewport rect (origin + size, normalized 0–1).
        /// Single source of truth for bounds; compositor calls this every gesture tick
        /// and on commit so live preview and final state stay consistent.
        public var clampFrame: @Sendable @MainActor (CameraID, CGRect) -> CGRect

        /// Live update — fires on every gesture tick. Compositor has already applied
        /// the clamped rect to its viewports for live preview. Consumer can mirror to
        /// UI state if useful (e.g., haptic feedback) but does NOT need to dispatch a
        /// layout rebuild — that's the compositor's job.
        public var onLiveUpdate: @Sendable @MainActor (CameraID, CGRect, PiPGestureKind) -> Void

        /// Final commit — fires on gesture-ended with the final clamped rect. Consumer
        /// should persist this to canonical state.
        public var onCommit: @Sendable @MainActor (CameraID, CGRect, PiPGestureKind) -> Void

        public init(
            isCameraInteractive: @escaping @Sendable @MainActor (CameraID) -> Bool = { _ in false },
            clampFrame: @escaping @Sendable @MainActor (CameraID, CGRect) -> CGRect = { _, r in r },
            onLiveUpdate: @escaping @Sendable @MainActor (CameraID, CGRect, PiPGestureKind) -> Void = { _, _, _ in },
            onCommit: @escaping @Sendable @MainActor (CameraID, CGRect, PiPGestureKind) -> Void = { _, _, _ in }
        ) {
            self.isCameraInteractive = isCameraInteractive
            self.clampFrame = clampFrame
            self.onLiveUpdate = onLiveUpdate
            self.onCommit = onCommit
        }

        /// No-op constant — restores default compositor behavior (no PiP gestures).
        public static let none = PiPGestureCallbacks()
    }
}
