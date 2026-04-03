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
			startRecording: { configuration in
				try await actor.startRecording(configuration)
			},
			stopRecording: {
				try await actor.stopRecording()
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
