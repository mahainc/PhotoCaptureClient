#if os(iOS)
import UIKit
@preconcurrency import MetalKit
@preconcurrency import AVFoundation
import PhotoCaptureClient
import os

// MARK: - Aspect-Fill Uniforms (matches Metal struct layout)

/// Must match `AspectFillUniforms` in Shaders.metal exactly.
private struct AspectFillUniforms {
	var uvScale: SIMD2<Float>
	var uvOffset: SIMD2<Float>
}

// MARK: - Box Vertex (matches Metal struct layout)

/// Must match `BoxVertex` in Shaders.metal exactly.
private struct BoxVertex {
	var position: SIMD2<Float>
	var color: SIMD4<Float>
}

/// Wrapper to make CVMetalTexture + MTLTexture pair Sendable for use in OSAllocatedUnfairLock.
private struct CameraFrame: @unchecked Sendable {
	let cvTexture: CVMetalTexture
	let mtlTexture: MTLTexture
}

/// Metal-backed camera preview that renders CVPixelBuffers using the display link
/// and supports bounding box overlay drawing for object detection results.
final class MetalPreviewRenderer: UIView, @unchecked Sendable {

	// MARK: - Metal State

	private let device: MTLDevice
	private let commandQueue: MTLCommandQueue
	private let textureCache: CVMetalTextureCache
	private let mtkView: MTKView

	// Render pipelines
	private let cameraPipeline: MTLRenderPipelineState
	private let boxPipeline: MTLRenderPipelineState

	// Reusable vertex buffer for bounding box overlays (avoids per-frame allocation).
	// Sized for 100 boxes * 8 vertices per box = 800 vertices.
	private let maxBoxVertices = 800
	private let boxVertexBuffer: MTLBuffer

	// MARK: - Frame State

	/// Latest camera frame — stores both CVMetalTexture (to retain backing IOSurface) and MTLTexture (for rendering).
	/// CVMetalTextureGetTexture returns a texture only valid while the CVMetalTexture is alive,
	/// so we must retain the CVMetalTexture until the next frame replaces it.
	private let _currentFrame = OSAllocatedUnfairLock<CameraFrame?>(initialState: nil)

	/// Texture dimensions for aspect-fill computation.
	private let _textureSize = OSAllocatedUnfairLock<SIMD2<Float>>(initialState: .zero)

	/// Current overlay rectangles — written from any thread, read from main thread.
	private let _overlays = OSAllocatedUnfairLock<[PhotoCaptureClient.OverlayRect]>(initialState: [])

	/// Aspect-fill uniforms — recomputed when drawable size or texture size changes.
	private var aspectFillUniforms = AspectFillUniforms(
		uvScale: SIMD2<Float>(1, 1),
		uvOffset: SIMD2<Float>(0, 0)
	)
	private var lastTextureSize: SIMD2<Float> = .zero

	// MARK: - Init

	/// Factory method — returns nil if Metal is unavailable.
	static func create() -> MetalPreviewRenderer? {
		guard let device = MTLCreateSystemDefaultDevice(),
			  let commandQueue = device.makeCommandQueue() else {
			return nil
		}

		var cache: CVMetalTextureCache?
		let status = CVMetalTextureCacheCreate(
			kCFAllocatorDefault, nil, device, nil, &cache
		)
		guard status == kCVReturnSuccess, let textureCache = cache else {
			return nil
		}

		guard let library = try? device.makeDefaultLibrary(bundle: Bundle.module) else {
			return nil
		}

		// Camera pipeline
		let cameraDescriptor = MTLRenderPipelineDescriptor()
		cameraDescriptor.vertexFunction = library.makeFunction(name: "cameraVertex")
		cameraDescriptor.fragmentFunction = library.makeFunction(name: "cameraFragment")
		cameraDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
		guard let cameraPipeline = try? device.makeRenderPipelineState(descriptor: cameraDescriptor) else {
			return nil
		}

		// Box pipeline with alpha blending
		let boxDescriptor = MTLRenderPipelineDescriptor()
		boxDescriptor.vertexFunction = library.makeFunction(name: "boxVertex")
		boxDescriptor.fragmentFunction = library.makeFunction(name: "boxFragment")
		boxDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
		boxDescriptor.colorAttachments[0].isBlendingEnabled = true
		boxDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
		boxDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
		boxDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
		boxDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
		guard let boxPipeline = try? device.makeRenderPipelineState(descriptor: boxDescriptor) else {
			return nil
		}

		let bufferSize = 800 * MemoryLayout<BoxVertex>.stride
		guard let boxVertexBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
			return nil
		}

		return MetalPreviewRenderer(
			device: device,
			commandQueue: commandQueue,
			textureCache: textureCache,
			cameraPipeline: cameraPipeline,
			boxPipeline: boxPipeline,
			boxVertexBuffer: boxVertexBuffer
		)
	}

	private init(
		device: MTLDevice,
		commandQueue: MTLCommandQueue,
		textureCache: CVMetalTextureCache,
		cameraPipeline: MTLRenderPipelineState,
		boxPipeline: MTLRenderPipelineState,
		boxVertexBuffer: MTLBuffer
	) {
		self.device = device
		self.commandQueue = commandQueue
		self.textureCache = textureCache
		self.cameraPipeline = cameraPipeline
		self.boxPipeline = boxPipeline
		self.boxVertexBuffer = boxVertexBuffer

		let mtkView = MTKView()
		mtkView.device = device
		mtkView.framebufferOnly = true
		mtkView.colorPixelFormat = .bgra8Unorm
		mtkView.isPaused = false
		mtkView.enableSetNeedsDisplay = false
		mtkView.preferredFramesPerSecond = 60
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

	/// Called from the AVCaptureVideoDataOutput delegate queue with each camera frame.
	/// Creates a Metal texture from the pixel buffer (zero-copy via CVMetalTextureCache)
	/// and stores it for the next display-link-driven draw call.
	func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)

		var cvTexture: CVMetalTexture?
		let status = CVMetalTextureCacheCreateTextureFromImage(
			kCFAllocatorDefault,
			textureCache,
			pixelBuffer,
			nil,
			.bgra8Unorm,
			width,
			height,
			0,
			&cvTexture
		)

		guard status == kCVReturnSuccess,
			  let cvTex = cvTexture,
			  let texture = CVMetalTextureGetTexture(cvTex) else {
			return
		}

		// Retain CVMetalTexture alongside MTLTexture to keep backing IOSurface alive until next frame
		_currentFrame.withLock { $0 = CameraFrame(cvTexture: cvTex, mtlTexture: texture) }
		_textureSize.withLock { $0 = SIMD2<Float>(Float(width), Float(height)) }
	}

	/// Update the bounding box overlays displayed on the preview.
	func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {
		_overlays.withLock { $0 = overlays }
	}

	// MARK: - Aspect-Fill Computation

	/// Recomputes UV scale/offset so the camera texture fills the view
	/// without stretching (aspect-fill with center crop).
	private func recomputeAspectFill(drawableSize: CGSize, textureSize: SIMD2<Float>) {
		guard textureSize.x > 0 && textureSize.y > 0 else { return }

		let viewAspect = Float(drawableSize.width / drawableSize.height)
		let texAspect = textureSize.x / textureSize.y

		var scaleX: Float = 1.0
		var scaleY: Float = 1.0

		if texAspect > viewAspect {
			// Texture is wider than view — crop sides
			scaleX = viewAspect / texAspect
		} else {
			// Texture is taller than view — crop top/bottom
			scaleY = texAspect / viewAspect
		}

		aspectFillUniforms = AspectFillUniforms(
			uvScale: SIMD2<Float>(scaleX, scaleY),
			uvOffset: SIMD2<Float>((1.0 - scaleX) * 0.5, (1.0 - scaleY) * 0.5)
		)
	}
}

// MARK: - MTKViewDelegate

extension MetalPreviewRenderer: MTKViewDelegate {
	func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
		let texSize = _textureSize.withLock { $0 }
		recomputeAspectFill(drawableSize: size, textureSize: texSize)
		lastTextureSize = texSize
	}

	func draw(in view: MTKView) {
		guard let frame = _currentFrame.withLock({ $0 }),
			  let drawable = view.currentDrawable,
			  let passDescriptor = view.currentRenderPassDescriptor else {
			return
		}

		// Recompute aspect-fill if texture dimensions changed (e.g., camera switch)
		let texSize = _textureSize.withLock { $0 }
		if texSize != lastTextureSize {
			recomputeAspectFill(drawableSize: view.drawableSize, textureSize: texSize)
			lastTextureSize = texSize
		}

		passDescriptor.colorAttachments[0].loadAction = .clear
		passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
		passDescriptor.colorAttachments[0].storeAction = .store

		guard let commandBuffer = commandQueue.makeCommandBuffer(),
			  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
			return
		}

		// 1. Draw camera frame (fullscreen textured quad with aspect-fill)
		encoder.setRenderPipelineState(cameraPipeline)
		var uniforms = aspectFillUniforms
		encoder.setVertexBytes(&uniforms, length: MemoryLayout<AspectFillUniforms>.size, index: 0)
		encoder.setFragmentTexture(frame.mtlTexture, index: 0)
		encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

		// 2. Draw bounding box overlays
		let overlays = _overlays.withLock { $0 }
		if !overlays.isEmpty {
			drawOverlays(overlays, encoder: encoder)
		}

		encoder.endEncoding()
		commandBuffer.present(drawable)
		commandBuffer.commit()
	}

	// MARK: - Overlay Drawing

	/// Writes bounding box line vertices into the pre-allocated vertex buffer and draws them.
	private func drawOverlays(
		_ overlays: [PhotoCaptureClient.OverlayRect],
		encoder: MTLRenderCommandEncoder
	) {
		encoder.setRenderPipelineState(boxPipeline)

		// 4 edges * 2 vertices = 8 vertices per box
		let vertexCount = min(overlays.count * 8, maxBoxVertices)
		let maxBoxes = maxBoxVertices / 8

		let pointer = boxVertexBuffer.contents().bindMemory(to: BoxVertex.self, capacity: maxBoxVertices)

		var idx = 0
		for i in 0..<min(overlays.count, maxBoxes) {
			let overlay = overlays[i]
			// Convert from 0..1 normalized (top-left origin) to Metal clip space (-1..1, bottom-left origin)
			let left = overlay.x * 2.0 - 1.0
			let right = (overlay.x + overlay.width) * 2.0 - 1.0
			let top = 1.0 - overlay.y * 2.0
			let bottom = 1.0 - (overlay.y + overlay.height) * 2.0

			let color = overlay.color

			// Top edge
			pointer[idx] = BoxVertex(position: SIMD2(left, top), color: color); idx += 1
			pointer[idx] = BoxVertex(position: SIMD2(right, top), color: color); idx += 1
			// Right edge
			pointer[idx] = BoxVertex(position: SIMD2(right, top), color: color); idx += 1
			pointer[idx] = BoxVertex(position: SIMD2(right, bottom), color: color); idx += 1
			// Bottom edge
			pointer[idx] = BoxVertex(position: SIMD2(right, bottom), color: color); idx += 1
			pointer[idx] = BoxVertex(position: SIMD2(left, bottom), color: color); idx += 1
			// Left edge
			pointer[idx] = BoxVertex(position: SIMD2(left, bottom), color: color); idx += 1
			pointer[idx] = BoxVertex(position: SIMD2(left, top), color: color); idx += 1
		}

		guard idx > 0 else { return }

		encoder.setVertexBuffer(boxVertexBuffer, offset: 0, index: 0)
		encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: vertexCount)
	}
}
#endif
