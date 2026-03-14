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
			requestAuthorization: {
				await actor.requestAuthorization()
			},
			authorizationStatus: {
				actor.authorizationStatus()
			},
			events: {
				await actor.observeEvents()
			},
			previewLayer: {
				await actor.getPreviewLayer()
			}
		)
	}()
}
