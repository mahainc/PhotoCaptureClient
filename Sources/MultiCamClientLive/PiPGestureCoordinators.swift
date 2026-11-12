#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    // MARK: - Gesture Coordinators

    /// Shared per-recognizer gesture state. Held by the compositor; isolated from the
    /// compositor's shared state so simultaneous gestures on different PiPs don't
    /// cross-talk. Subclassed by `PiPDragCoordinator` and `PiPPinchCoordinator`.
    @MainActor
    class PiPGestureCoordinator: NSObject {
        weak var compositor: MultiCamCompositor?
        var camera: MultiCamClient.CameraID?
        var startRect: CGRect = .zero
    }

    /// Per-recognizer drag state. Held by the compositor; isolated from compositor's
    /// shared state so simultaneous gestures on different PiPs don't cross-talk.
    @MainActor
    final class PiPDragCoordinator: PiPGestureCoordinator {
        @objc func handle(_ gr: UIPanGestureRecognizer) {
            guard let comp = compositor else { return }
            switch gr.state {
                case .began:
                    guard let cam = comp.cameraAtTouch(gr.location(in: comp)),
                        let vp = comp.currentViewport(for: cam)
                    else {
                        gr.state = .failed
                        return
                    }
                    camera = cam
                    startRect = vp.rect
                case .changed:
                    guard let cam = camera else { return }
                    guard comp.currentViewport(for: cam) != nil else {
                        // Camera disappeared mid-gesture (disconnect / mode switch). Cancel.
                        gr.state = .cancelled
                        return
                    }
                    let bounds = comp.bounds
                    guard bounds.width > 0, bounds.height > 0 else { return }
                    let t = gr.translation(in: comp)
                    let proposedOrigin = CGPoint(
                        x: startRect.origin.x + t.x / bounds.width,
                        y: startRect.origin.y + t.y / bounds.height
                    )
                    let proposed = CGRect(origin: proposedOrigin, size: startRect.size)
                    let clamped = comp.gestureCallbacks.clampFrame(cam, proposed)
                    comp.applyViewportRect(camera: cam, rect: clamped)
                    comp.gestureCallbacks.onLiveUpdate(cam, clamped, .drag)
                case .ended:
                    guard let cam = camera else { return }
                    let final = comp.currentViewport(for: cam)?.rect ?? startRect
                    comp.gestureCallbacks.onCommit(cam, final, .drag)
                    camera = nil
                case .cancelled, .failed:
                    camera = nil
                default:
                    break
            }
        }
    }

    /// Per-recognizer pinch state. Independent from drag coordinator; both can fire
    /// concurrently on the same PiP (combined drag + resize gesture).
    @MainActor
    final class PiPPinchCoordinator: PiPGestureCoordinator {
        /// Floor on the gesture's live scale factor, so a pinch-closed gesture can't
        /// collapse the PiP to a zero/negative-sized rect.
        private static let minimumPinchScale: CGFloat = 0.01

        @objc func handle(_ gr: UIPinchGestureRecognizer) {
            guard let comp = compositor else { return }
            switch gr.state {
                case .began:
                    guard let cam = comp.cameraAtTouch(gr.location(in: comp)),
                        let vp = comp.currentViewport(for: cam)
                    else {
                        gr.state = .failed
                        return
                    }
                    camera = cam
                    startRect = vp.rect
                case .changed:
                    guard let cam = camera else { return }
                    guard comp.currentViewport(for: cam) != nil else {
                        gr.state = .cancelled
                        return
                    }
                    let scale = max(Self.minimumPinchScale, gr.scale)
                    let newW = startRect.width * scale
                    let newH = startRect.height * scale
                    let cx = startRect.midX
                    let cy = startRect.midY
                    let proposed = CGRect(
                        x: cx - newW / 2,
                        y: cy - newH / 2,
                        width: newW,
                        height: newH
                    )
                    let clamped = comp.gestureCallbacks.clampFrame(cam, proposed)
                    comp.applyViewportRect(camera: cam, rect: clamped)
                    comp.gestureCallbacks.onLiveUpdate(cam, clamped, .pinch)
                case .ended:
                    guard let cam = camera else { return }
                    let final = comp.currentViewport(for: cam)?.rect ?? startRect
                    comp.gestureCallbacks.onCommit(cam, final, .pinch)
                    camera = nil
                case .cancelled, .failed:
                    camera = nil
                default:
                    break
            }
        }
    }
#endif
