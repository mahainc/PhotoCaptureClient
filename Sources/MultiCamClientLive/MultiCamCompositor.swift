#if os(iOS)
import UIKit
@preconcurrency import MetalKit
@preconcurrency import AVFoundation
import MultiCamClient
import PhotoCaptureClient
import os

// MARK: - Uniforms (must match Shaders.metal)

/// Must match Metal struct `MultiCamUniforms` exactly (80 bytes).
private struct MultiCamUniforms {
	var viewportRect: SIMD4<Float>     // 16 bytes
	var uvScale: SIMD2<Float>          // 8 bytes
	var uvOffset: SIMD2<Float>         // 8 bytes
	var cornerRadius: Float            // 4 bytes
	var borderWidth: Float             // 4 bytes
	var borderColor: SIMD4<Float>      // 16 bytes
	var pixelAspectRatio: Float        // 4 bytes
	var _pad: SIMD3<Float>             // 12 bytes pad to 80
}

/// Wrapper to make CVMetalTexture + MTLTexture pair Sendable.
private struct CameraFrame: @unchecked Sendable {
	let cvTexture: CVMetalTexture
	let mtlTexture: MTLTexture
	let width: Int
	let height: Int
}

/// Metal-backed multi-camera compositor that renders N camera textures
/// into a single view according to the current layout.
final class MultiCamCompositor: UIView, @unchecked Sendable {

	// MARK: - Metal State

	private let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let textureCache: CVMetalTextureCache
	private let mtkView: MTKView
	private let cameraPipeline: MTLRenderPipelineState

	// MARK: - Frame State (combined under single lock to prevent torn renders)

	private struct RenderState: @unchecked Sendable {
		var cameraFrames: [MultiCamClient.CameraID: CameraFrame] = [:]
		var viewports: [LayoutEngine.CameraViewport] = []
	}
	private let _renderState = OSAllocatedUnfairLock(initialState: RenderState())

	/// Dirty flag.
	private let _needsDraw = OSAllocatedUnfairLock<Bool>(initialState: false)

	/// Layout engine.
	private let layoutEngine = LayoutEngine()

	/// Active cameras in order.
	private let _cameras = OSAllocatedUnfairLock<[MultiCamClient.CameraID]>(initialState: [])

	/// Current layout.
	private let _layout = OSAllocatedUnfairLock<MultiCamClient.Layout>(initialState: .grid(.init()))

	/// Back-reference to preview view.
	weak var previewViewRef: MultiCamClient.PreviewView?

	// MARK: - Recording Offscreen

	/// Callback for recording pipeline — receives composited frame synchronously.
	var onRecordingFrame: ((_ pixelBuffer: CVPixelBuffer, _ time: CMTime) -> Void)?
	private var recordingPixelBufferPool: CVPixelBufferPool?
	private var recordingOutputSize: CGSize = .zero
	private var recordingTextureCache: CVMetalTextureCache?
	private var _isRecording = OSAllocatedUnfairLock(initialState: false)

	var isRecording: Bool {
		get { _isRecording.withLock { $0 } }
		set { _isRecording.withLock { $0 = newValue } }
	}

	/// Border settings for PiP overlays (set from app layer)
	var borderWidth: Float = 0        // in normalized viewport space
	var borderColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)  // RGBA

	// MARK: - Init

	static func create() -> MultiCamCompositor? {
		guard let device = MTLCreateSystemDefaultDevice(),
			  let commandQueue = device.makeCommandQueue() else {
			return nil
		}

		var cache: CVMetalTextureCache?
		let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
		guard status == kCVReturnSuccess, let textureCache = cache else {
			return nil
		}

		guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
			return nil
		}

		// Camera pipeline
		let cameraDescriptor = MTLRenderPipelineDescriptor()
		cameraDescriptor.vertexFunction = library.makeFunction(name: "multiCamVertex")
		cameraDescriptor.fragmentFunction = library.makeFunction(name: "multiCamFragment")
		cameraDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
		guard let cameraPipeline = try? device.makeRenderPipelineState(descriptor: cameraDescriptor) else {
			return nil
		}

		return MultiCamCompositor(
			device: device,
			commandQueue: commandQueue,
			textureCache: textureCache,
			cameraPipeline: cameraPipeline
		)
	}

	private init(
		device: MTLDevice,
		commandQueue: MTLCommandQueue,
		textureCache: CVMetalTextureCache,
		cameraPipeline: MTLRenderPipelineState
	) {
		self.device = device
		self.commandQueue = commandQueue
		self.textureCache = textureCache
		self.cameraPipeline = cameraPipeline

		let mtkView = MTKView()
		mtkView.device = device
		mtkView.framebufferOnly = true
		mtkView.colorPixelFormat = .bgra8Unorm
		mtkView.isPaused = true
		mtkView.enableSetNeedsDisplay = true
		mtkView.isUserInteractionEnabled = false  // Let touches pass through to parent
		// Match the display's native refresh rate (120 Hz on ProMotion devices). The default
		// is 60 fps even on 120 Hz displays. Requires the host app to set
		// `CADisableMinimumFrameDurationOnPhone = true` in Info.plist to actually unlock 120 Hz.
		mtkView.preferredFramesPerSecond = 120
		self.mtkView = mtkView

		super.init(frame: .zero)

		mtkView.delegate = self
		addSubview(mtkView)
		mtkView.translatesAutoresizingMaskIntoConstraints = false
		NSLayoutConstraint.activate([
			mtkView.topAnchor.constraint(equalTo: topAnchor),
			mtkView.bottomAnchor.constraint(equalTo: bottomAnchor),
			mtkView.leadingAnchor.constraint(equalTo: leadingAnchor),
			mtkView.trailingAnchor.constraint(equalTo: trailingAnchor),
		])

		NotificationCenter.default.addObserver(
			forName: UIApplication.didReceiveMemoryWarningNotification,
			object: nil,
			queue: nil
		) { [weak self] _ in
			guard let self else { return }
			CVMetalTextureCacheFlush(self.textureCache, 0)
		}
	}

	@available(*, unavailable)
	required init?(coder: NSCoder) {
		fatalError("init(coder:) is not supported")
	}

	deinit {
		NotificationCenter.default.removeObserver(self)
	}

	// MARK: - Public API

	func enqueueFrame(_ pixelBuffer: CVPixelBuffer, for camera: MultiCamClient.CameraID) {
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)

		var cvTexture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(
			kCFAllocatorDefault, textureCache, pixelBuffer, nil,
			.bgra8Unorm, width, height, 0, &cvTexture
		)

		guard status == kCVReturnSuccess,
			  let cvTex = cvTexture,
			  let texture = CVMetalTextureGetTexture(cvTex) else { return }

		let frame = CameraFrame(cvTexture: cvTex, mtlTexture: texture, width: width, height: height)
		let shouldDispatch = _needsDraw.withLock { needsDraw -> Bool in
			let wasClean = !needsDraw
			needsDraw = true
			return wasClean  // Only dispatch if transitioning from clean → dirty
		}
		_renderState.withLock { $0.cameraFrames[camera] = frame }

		if shouldDispatch {
			DispatchQueue.main.async { [weak self] in
				self?.mtkView.setNeedsDisplay()
			}
		}
	}

	func setLayout(_ layout: MultiCamClient.Layout) {
		_layout.withLock { $0 = layout }

		let cameras = _cameras.withLock { $0 }
		let viewports = layoutEngine.computeViewports(layout: layout, cameras: cameras)
		_renderState.withLock { $0.viewports = viewports }
		_needsDraw.withLock { $0 = true }
		DispatchQueue.main.async { [weak self] in
			self?.mtkView.setNeedsDisplay()
		}
	}

	func setCameras(_ cameras: [MultiCamClient.CameraID]) {
		_cameras.withLock { $0 = cameras }
		let layout = _layout.withLock { $0 }
		let viewports = layoutEngine.computeViewports(layout: layout, cameras: cameras)
		_renderState.withLock { $0.viewports = viewports }
	}

	/// Fast-path: replace only the affected viewport's origin and request a redraw.
	/// Used by `MultiCamClient.setPiPOverlayPosition` for live drag updates without
	/// running the full layout pipeline. Must be called on the main thread.
	@MainActor
	func updateOverlayOrigin(camera: MultiCamClient.CameraID, origin: CGPoint) {
		_renderState.withLock { state in
			guard let idx = state.viewports.firstIndex(where: { $0.cameraID == camera }) else { return }
			let old = state.viewports[idx]
			state.viewports[idx] = LayoutEngine.CameraViewport(
				cameraID: old.cameraID,
				rect: CGRect(origin: origin, size: old.rect.size),
				zOrder: old.zOrder,
				cornerRadius: old.cornerRadius
			)
		}
		_needsDraw.withLock { $0 = true }
		mtkView.setNeedsDisplay()
	}

	func configureRecordingOutput(size: CGSize) {
		recordingOutputSize = size
		let attrs: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			kCVPixelBufferWidthKey as String: Int(size.width),
			kCVPixelBufferHeightKey as String: Int(size.height),
			kCVPixelBufferIOSurfacePropertiesKey as String: [:],
			kCVPixelBufferMetalCompatibilityKey as String: true,
		]
		var pool: CVPixelBufferPool?
		CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
		recordingPixelBufferPool = pool

		// Create a separate texture cache for recording pixel buffers
		var cache: CVMetalTextureCache?
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
		recordingTextureCache = cache
	}

	// MARK: - One-Shot Composite Photo Capture

	/// Renders all current camera frames into a single composited image matching the preview layout.
	/// Must be called on the main thread (UIView subclass).
	func captureCompositePhoto(outputSize: CGSize) -> PhotoCaptureClient.Photo? {
		let width = Int(outputSize.width)
		let height = Int(outputSize.height)
		guard width > 0 && height > 0 else { return nil }

		let (frames, viewports) = _renderState.withLock { ($0.cameraFrames, $0.viewports) }
		guard !frames.isEmpty, !viewports.isEmpty else { return nil }

		// Allocate a one-shot pixel buffer
		let attrs: [String: Any] = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
			kCVPixelBufferWidthKey as String: width,
			kCVPixelBufferHeightKey as String: height,
			kCVPixelBufferIOSurfacePropertiesKey as String: [:],
			kCVPixelBufferMetalCompatibilityKey as String: true,
		]
		var pixelBuffer: CVPixelBuffer?
		let pbStatus = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
		guard pbStatus == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

		// Create Metal texture from pixel buffer
		var texCache: CVMetalTextureCache?
		CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &texCache)
		guard let cache = texCache else { return nil }

		var cvTexture: CVMetalTexture?
		let texStatus = CVMetalTextureCacheCreateTextureFromImage(
			kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm, width, height, 0, &cvTexture
		)
		guard texStatus == kCVReturnSuccess, let cvTex = cvTexture, let offscreenTexture = CVMetalTextureGetTexture(cvTex) else { return nil }

		// Render
		let descriptor = MTLRenderPassDescriptor()
		descriptor.colorAttachments[0].texture = offscreenTexture
		descriptor.colorAttachments[0].loadAction = .clear
		descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		descriptor.colorAttachments[0].storeAction = .store

		guard let commandBuffer = commandQueue.makeCommandBuffer(),
			  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return nil }

		let sortedViewports = viewports.sorted { $0.zOrder < $1.zOrder }
		let offscreenSize = CGSize(width: width, height: height)

		for viewport in sortedViewports {
			guard let frame = frames[viewport.cameraID] else { continue }
			let (uvS, uvO) = computeAspectFill(
				viewportRect: viewport.rect, drawableSize: offscreenSize,
				textureWidth: frame.width, textureHeight: frame.height
			)
			let isFS = viewport.rect.width >= 0.99 && viewport.rect.height >= 0.99
			let vpPxW = Float(viewport.rect.width) * Float(width)
			let vpPxH = Float(viewport.rect.height) * Float(height)
			let pxAR = vpPxH > 0 ? vpPxW / vpPxH : Float(1)
			var u = MultiCamUniforms(
				viewportRect: SIMD4<Float>(
					Float(viewport.rect.origin.x), Float(viewport.rect.origin.y),
					Float(viewport.rect.size.width), Float(viewport.rect.size.height)
				),
				uvScale: uvS, uvOffset: uvO,
				cornerRadius: Float(viewport.cornerRadius),
				borderWidth: isFS ? 0 : borderWidth,
				borderColor: isFS ? .zero : borderColor,
				pixelAspectRatio: pxAR,
				_pad: .zero
			)
			encoder.setRenderPipelineState(cameraPipeline)
			encoder.setVertexBytes(&u, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
			encoder.setFragmentTexture(frame.mtlTexture, index: 0)
			encoder.setFragmentBytes(&u, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
			encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		}

		encoder.endEncoding()
		commandBuffer.commit()
		commandBuffer.waitUntilCompleted()

		// Convert pixel buffer → JPEG
		let ciImage = CIImage(cvPixelBuffer: pb)
		let context = CIContext()
		guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
		let uiImage = UIImage(cgImage: cgImage)
		guard let jpegData = uiImage.jpegData(compressionQuality: 0.92) else { return nil }

		return PhotoCaptureClient.Photo(
			fileDataRepresentation: jpegData,
			photoDimensions: outputSize,
			timestamp: .now,
			isRawPhoto: false
		)
	}

	// MARK: - Aspect-Fill for a Viewport

	private func computeAspectFill(
		viewportRect: CGRect,
		drawableSize: CGSize,
		textureWidth: Int,
		textureHeight: Int
	) -> (uvScale: SIMD2<Float>, uvOffset: SIMD2<Float>) {
		guard textureWidth > 0 && textureHeight > 0 else {
			return (SIMD2<Float>(1, 1), SIMD2<Float>(0, 0))
		}

		let vpAspect = Float(viewportRect.width * drawableSize.width) / Float(viewportRect.height * drawableSize.height)
		let texAspect = Float(textureWidth) / Float(textureHeight)

		var scaleX: Float = 1.0
		var scaleY: Float = 1.0

		if texAspect > vpAspect {
			scaleX = vpAspect / texAspect
		} else {
			scaleY = texAspect / vpAspect
		}

		let offsetX = (1.0 - scaleX) * 0.5
		let offsetY = (1.0 - scaleY) * 0.5

		return (SIMD2<Float>(scaleX, scaleY), SIMD2<Float>(offsetX, offsetY))
	}
}

// MARK: - MTKViewDelegate

extension MultiCamCompositor: MTKViewDelegate {
	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
		// Viewports are normalized, so no recomputation needed for size changes
	}

	func draw(in view: MTKView) {
		let needsDraw = _needsDraw.withLock { val in
			let current = val
			val = false
			return current
		}
		guard needsDraw else { return }

		guard let drawable = view.currentDrawable,
			  let passDescriptor = view.currentRenderPassDescriptor else { return }

		let (frames, viewports) = _renderState.withLock { ($0.cameraFrames, $0.viewports) }

		passDescriptor.colorAttachments[0].loadAction = .clear
		passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		passDescriptor.colorAttachments[0].storeAction = .store

		guard let commandBuffer = commandQueue.makeCommandBuffer(),
			  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }

		// Draw each camera by zOrder
		let sortedViewports = viewports.sorted { $0.zOrder < $1.zOrder }

		for viewport in sortedViewports {
			guard let frame = frames[viewport.cameraID] else { continue }

			let (uvScale, uvOffset) = computeAspectFill(
				viewportRect: viewport.rect,
				drawableSize: view.drawableSize,
				textureWidth: frame.width,
				textureHeight: frame.height
			)

			// Apply border only to non-fullscreen viewports (PiP overlays)
			let isFullscreen = viewport.rect.width >= 0.99 && viewport.rect.height >= 0.99
			let bw: Float = isFullscreen ? 0 : borderWidth
			let bc: SIMD4<Float> = isFullscreen ? .zero : borderColor

			// Pixel aspect ratio: viewport pixel width / viewport pixel height
			let vpPixelW = Float(viewport.rect.width) * Float(view.drawableSize.width)
			let vpPixelH = Float(viewport.rect.height) * Float(view.drawableSize.height)
			let pixelAR = vpPixelH > 0 ? vpPixelW / vpPixelH : 1.0

			var uniforms = MultiCamUniforms(
				viewportRect: SIMD4<Float>(
					Float(viewport.rect.origin.x),
					Float(viewport.rect.origin.y),
					Float(viewport.rect.size.width),
					Float(viewport.rect.size.height)
				),
				uvScale: uvScale,
				uvOffset: uvOffset,
				cornerRadius: Float(viewport.cornerRadius),
				borderWidth: bw,
				borderColor: bc,
				pixelAspectRatio: pixelAR,
				_pad: .zero
			)

			encoder.setRenderPipelineState(cameraPipeline)
			encoder.setVertexBytes(&uniforms, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
			encoder.setFragmentTexture(frame.mtlTexture, index: 0)
			encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
			encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
		}

		encoder.endEncoding()

		// Offscreen recording: encode into the SAME command buffer (no second GPU pass)
		if _isRecording.withLock({ $0 }),
		   let pool = recordingPixelBufferPool,
		   let recCache = recordingTextureCache,
		   let callback = onRecordingFrame {
			var pixelBuffer: CVPixelBuffer?
			let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
			if status == kCVReturnSuccess, let pb = pixelBuffer {
				let width = CVPixelBufferGetWidth(pb)
				let height = CVPixelBufferGetHeight(pb)

				var cvTexture: CVMetalTexture?
				let texStatus = CVMetalTextureCacheCreateTextureFromImage(
					kCFAllocatorDefault, recCache, pb, nil, .bgra8Unorm, width, height, 0, &cvTexture
				)
				if texStatus == kCVReturnSuccess, let cvTex = cvTexture, let offscreenTexture = CVMetalTextureGetTexture(cvTex) {
					let offscreenDescriptor = MTLRenderPassDescriptor()
					offscreenDescriptor.colorAttachments[0].texture = offscreenTexture
					offscreenDescriptor.colorAttachments[0].loadAction = .clear
					offscreenDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
					offscreenDescriptor.colorAttachments[0].storeAction = .store

					// Encode offscreen pass into the SAME command buffer
					if let offscreenEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: offscreenDescriptor) {
						let offscreenSize = CGSize(width: width, height: height)
						for viewport in sortedViewports {
							guard let frame = frames[viewport.cameraID] else { continue }
							let (uvS, uvO) = computeAspectFill(
								viewportRect: viewport.rect, drawableSize: offscreenSize,
								textureWidth: frame.width, textureHeight: frame.height
							)
							let isFS = viewport.rect.width >= 0.99 && viewport.rect.height >= 0.99
							let offVpPixelW = Float(viewport.rect.width) * Float(width)
							let offVpPixelH = Float(viewport.rect.height) * Float(height)
							let offPixelAR = offVpPixelH > 0 ? offVpPixelW / offVpPixelH : Float(1)
							var u = MultiCamUniforms(
								viewportRect: SIMD4<Float>(
									Float(viewport.rect.origin.x), Float(viewport.rect.origin.y),
									Float(viewport.rect.size.width), Float(viewport.rect.size.height)
								),
								uvScale: uvS, uvOffset: uvO,
								cornerRadius: Float(viewport.cornerRadius),
								borderWidth: isFS ? 0 : borderWidth,
								borderColor: isFS ? .zero : borderColor,
								pixelAspectRatio: offPixelAR,
								_pad: .zero
							)
							offscreenEncoder.setRenderPipelineState(cameraPipeline)
							offscreenEncoder.setVertexBytes(&u, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
							offscreenEncoder.setFragmentTexture(frame.mtlTexture, index: 0)
							offscreenEncoder.setFragmentBytes(&u, length: MemoryLayout<MultiCamUniforms>.stride, index: 0)
							offscreenEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
						}
						offscreenEncoder.endEncoding()
					}

					commandBuffer.addCompletedHandler { _ in
						callback(pb, CMTime(value: CMTimeValue(CACurrentMediaTime() * 1000), timescale: 1000))
					}
				}
			}
		}

		commandBuffer.present(drawable)
		commandBuffer.commit()
	}
}
#endif
