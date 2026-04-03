#if os(iOS)
import UIKit
@preconcurrency import MetalKit
@preconcurrency import AVFoundation
import MultiCamClient
import PhotoCaptureClient
import os

// MARK: - Uniforms (must match Shaders.metal)

private struct MultiCamUniforms {
	var viewportRect: SIMD4<Float>  // (x, y, width, height) in 0-1 space
	var uvScale: SIMD2<Float>
	var uvOffset: SIMD2<Float>
	var cornerRadius: Float
	var _pad1: Float
	var _pad2: SIMD2<Float>        // Pad to 48 bytes (Metal float4 alignment)
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

		// For custom layouts, update camera list from the layout's frame keys
		if case .custom(let custom) = layout {
			let layoutCameras = Array(custom.frames.keys).sorted { $0.rawValue < $1.rawValue }
			_cameras.withLock { $0 = layoutCameras }
		}

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
				_pad1: 0,
				_pad2: .zero
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
							var u = MultiCamUniforms(
								viewportRect: SIMD4<Float>(
									Float(viewport.rect.origin.x), Float(viewport.rect.origin.y),
									Float(viewport.rect.size.width), Float(viewport.rect.size.height)
								),
								uvScale: uvS, uvOffset: uvO,
								cornerRadius: Float(viewport.cornerRadius),
								_pad1: 0, _pad2: .zero
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
