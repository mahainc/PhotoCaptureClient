#if os(iOS)
    import UIKit
    @preconcurrency import MetalKit
    @preconcurrency import AVFoundation
    import HistogramKit
    import MultiCamClient
    import PhotoCaptureClient
    import os

    // MARK: - UIGestureRecognizerDelegate

    extension MultiCamCompositor: UIGestureRecognizerDelegate {

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            let point = touch.location(in: self)
            guard let cam = cameraAtTouch(point) else { return false }
            return callbacks.isCameraInteractive(cam)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            // Allow our own pan + pinch to fire together on the same PiP overlay; reject
            // simultaneity with foreign recognizers (e.g., the parent container's lens-zoom
            // pinch). The parent restricts itself to the primary fullscreen viewport, so
            // in PiP mode the two never compete on the same touch anyway.
            return gestureRecognizer.view == self && other.view == self
        }
    }
#endif
