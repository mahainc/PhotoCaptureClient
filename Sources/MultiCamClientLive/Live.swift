import ComposableArchitecture
import MultiCamClient
import PhotoCaptureClient

#if os(iOS)
extension MultiCamClient: DependencyKey {
	public static let liveValue: MultiCamClient = {
		let actor = MultiCamClientActor()

		return MultiCamClient(
			deviceCapability: {
				actor.queryCapability()
			},
			startSession: { configuration in
				try await actor.startSession(configuration)
			},
			stopSession: {
				await actor.stopSession()
			},
			setLayout: { layout in
				await actor.setLayout(layout)
			},
			currentLayout: {
				await actor.getLayout()
			},
			setZoom: { camera, factor in
				try await actor.setZoom(camera: camera, factor: factor)
			},
			zoomRange: { camera in
				await actor.zoomRange(camera: camera)
			},
			setStabilization: { camera, mode in
				await actor.setStabilization(camera: camera, mode: mode)
			},
			setPiPBorder: { width, r, g, b in
				await actor.setPiPBorder(width: width, r: r, g: g, b: b)
			},
			startRecording: { configuration in
				try await actor.startRecording(configuration)
			},
			pauseRecording: {
				await actor.pauseRecording()
			},
			resumeRecording: {
				await actor.resumeRecording()
			},
			stopRecording: {
				try await actor.stopRecording()
			},
			capturePhoto: { camera in
				try await actor.capturePhoto(camera: camera)
			},
			captureCompositePhoto: { outputSize in
				try await actor.captureCompositePhoto(outputSize: outputSize)
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
			previewView: {
				await actor.getPreviewView()
			},
			pixelBufferStream: { camera in
				await actor.observePixelBuffers(for: camera)
			}
		)
	}()
}
#else
extension MultiCamClient: DependencyKey {
	public static let liveValue: MultiCamClient = .noop
}
#endif
