import ComposableArchitecture
import ObjectDetectionClient
import PhotoCaptureClient

/// Note: ObjectDetectionClientLive has a runtime coupling to PhotoCaptureClient.
/// When `startDetection` is called, it resolves `@Dependency(\.photoCapture)` from the
/// current dependency context to access the pixel buffer stream.
extension ObjectDetectionClient: DependencyKey {
	public static let liveValue: ObjectDetectionClient = {
		let actor = ObjectDetectionClientActor()

		return ObjectDetectionClient(
			currentMode: {
				actor.currentMode()
			},
			startDetection: { configuration in
				@Dependency(\.photoCapture) var photoCapture
				try await actor.startDetection(
					configuration: configuration,
					pixelBufferStream: photoCapture.pixelBufferStream
				)
			},
			stopDetection: {
				await actor.stopDetection()
			},
			detectionResults: {
				await actor.observeResults()
			},
			detectInImage: { imageData in
				try await actor.detectInImage(imageData)
			}
		)
	}()
}
