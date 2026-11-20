import ComposableArchitecture
import PhotoCaptureClient

extension PhotoCaptureClient: DependencyKey {
    public static let liveValue: PhotoCaptureClient = {
        let actor = PhotoCaptureClientActor()

        return PhotoCaptureClient(
            startSession: {
                try await actor.startSession()
            },
            stopSession: {
                await actor.stopSession()
            },
            capturePhoto: { settings in
                try await actor.capturePhoto(settings: settings)
            },
            switchCamera: { position in
                try await actor.switchCamera(to: position)
            },
            setFlashMode: { mode in
                await actor.setFlashMode(mode)
            },
            focus: { point in
                try await actor.focus(at: point)
            },
            setZoomFactor: { factor in
                try await actor.setZoomFactor(factor)
            },
            setVisualZoom: { factor, anchorX, anchorY in
                await actor.setVisualZoom(factor: factor, anchorX: anchorX, anchorY: anchorY)
            },
            setExposureBias: { bias in
                try await actor.setExposureBias(bias)
            },
            exposureBiasRange: {
                await actor.exposureBiasRange()
            },
            setWhiteBalanceKelvin: { kelvin in
                try await actor.setWhiteBalanceKelvin(kelvin)
            },
            zoomFactorRange: {
                await actor.zoomFactorRange()
            },
            setTorchLevel: { level in
                try await actor.setTorchLevel(level)
            },
            requestAuthorization: {
                await actor.requestAuthorization()
            },
            authorizationStatus: {
                actor.authorizationStatus()
            },
            events: {
                await actor.observeEvents()
            },
            pixelBufferStream: {
                await actor.observePixelBuffers()
            },
            previewView: {
                await actor.getPreviewView()
            },
            updateOverlays: { overlays in
                Task { await actor.updateOverlays(overlays) }
            },
            updateTextOverlays: { overlays in
                Task { await actor.updateTextOverlays(overlays) }
            },
            setLabelsVisible: { visible in
                Task { await actor.setLabelsVisible(visible) }
            },
            setOverlayStyle: { style in
                Task { await actor.setOverlayStyle(style) }
            },
            setHistogramVisible: { visible in
                Task { await actor.setHistogramVisible(visible) }
            },
            setHistogramConfig: { config in
                Task { await actor.setHistogramConfig(config) }
            },
            setPreviewChannelGains: { gains in
                Task { await actor.setChannelGains(gains) }
            },
            setFrameDeliveryInterval: { seconds in
                await actor.setFrameDeliveryInterval(seconds)
            },
            setPreviewPerformanceMode: { mode in
                await actor.setPreviewPerformanceMode(mode)
            }
        )
    }()
}
