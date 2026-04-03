# Metal Camera Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace AVCaptureVideoPreviewLayer with a Metal-based camera preview renderer that displays camera frames at full framerate and supports bounding box overlay drawing for ObjectDetectionClient.

**Architecture:** The Metal renderer (`MetalPreviewRenderer`) receives CVPixelBuffers from the AVCaptureVideoDataOutput delegate at full camera framerate via a callback. It stores the latest texture atomically and uses MTKView's built-in display link (`isPaused = false`, `preferredFramesPerSecond = 60`) to drive rendering on the main thread — avoiding unsafe off-main-thread draw calls. It uses `CVMetalTextureCache` for zero-copy GPU texture creation from BGRA pixel buffers. The vertex shader applies aspect-fill cropping via a uniform buffer so the camera image is never stretched. Bounding box overlays use a pre-allocated reusable vertex buffer to avoid per-frame Metal allocations. The existing throttled `pixelBufferStream` (~5fps) remains unchanged for object detection inference. The public interface changes from `previewLayer() -> PreviewLayer` (CALayer) to `previewView() -> PreviewView` (UIView).

**Tech Stack:** Metal, MetalKit (MTKView), CVMetalTextureCache, AVFoundation, Swift 6.2

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `Sources/PhotoCaptureClientLive/MetalPreviewRenderer.swift` | UIView wrapping MTKView: Metal device setup, CVMetalTextureCache, render pipeline, display-link-driven frame rendering, aspect-fill, bounding box overlay with reusable vertex buffer |
| Create | `Sources/PhotoCaptureClientLive/Shaders.metal` | Metal vertex/fragment shaders: fullscreen quad with aspect-fill uniform, bounding box line rendering |
| Modify | `Sources/PhotoCaptureClient/Models.swift:125-141` | Replace `PreviewLayer` (CALayer wrapper) with `PreviewView` (UIView wrapper); add `OverlayRect` model |
| Modify | `Sources/PhotoCaptureClient/Interface.swift:55-57` | Replace `previewLayer` with `previewView`; add `updateOverlays` method |
| Modify | `Sources/PhotoCaptureClient/Mocks.swift` | Update all mocks to use `previewView` + `updateOverlays` |
| Modify | `Sources/PhotoCaptureClientLive/Actor.swift` | Remove AVCaptureVideoPreviewLayer; create MetalPreviewRenderer; add full-rate frame callback; configure BGRA pixel format; wire overlay updates |
| Modify | `Sources/PhotoCaptureClientLive/Live.swift:42-44` | Wire `previewView` and `updateOverlays` to actor |
| Modify | `Package.swift` | Add Metal/MetalKit linker settings + resources declaration for Shaders.metal |

---

## Task 1: Update PhotoCaptureClient interface (Models + Interface + Mocks atomically)

All three interface files are updated in a single commit to keep every commit compilable.

**Files:**
- Modify: `Sources/PhotoCaptureClient/Models.swift`
- Modify: `Sources/PhotoCaptureClient/Interface.swift`
- Modify: `Sources/PhotoCaptureClient/Mocks.swift`

- [ ] **Step 1: Add UIKit/AppKit and simd imports to Models.swift**

Add at the top of `Models.swift`, after the existing imports:

```swift
import simd
#if os(iOS)
import UIKit
#else
import AppKit
#endif
```

- [ ] **Step 2: Replace PreviewLayer with PreviewView in Models.swift**

Replace the entire `PreviewLayer` section (lines 125-141) with:

```swift
// MARK: - PreviewView

extension PhotoCaptureClient {
	/// A Sendable wrapper around a UIView (Metal-backed camera preview).
	/// UIView is not Sendable, so this wrapper enables crossing isolation boundaries.
	public final class PreviewView: @unchecked Sendable, Equatable {
		#if os(iOS)
		public let view: UIView
		#else
		public let view: NSView
		#endif

		#if os(iOS)
		public init(view: UIView) {
			self.view = view
		}
		#else
		public init(view: NSView) {
			self.view = view
		}
		#endif

		public static func == (lhs: PreviewView, rhs: PreviewView) -> Bool {
			lhs.view === rhs.view
		}
	}
}
```

- [ ] **Step 3: Add OverlayRect model after PixelBufferWrapper in Models.swift**

Add this after line 171 (end of PixelBufferWrapper), before the Error section:

```swift
// MARK: - OverlayRect

extension PhotoCaptureClient {
	/// A normalized overlay rectangle for drawing on the Metal preview.
	/// Coordinates are in 0.0-1.0 space (top-left origin).
	public struct OverlayRect: Sendable, Equatable {
		public let x: Float
		public let y: Float
		public let width: Float
		public let height: Float
		public let label: String?
		public let confidence: Float?
		public let color: SIMD4<Float>

		public init(
			x: Float,
			y: Float,
			width: Float,
			height: Float,
			label: String? = nil,
			confidence: Float? = nil,
			color: SIMD4<Float> = SIMD4<Float>(0, 1, 0, 1)
		) {
			self.x = x
			self.y = y
			self.width = width
			self.height = height
			self.label = label
			self.confidence = confidence
			self.color = color
		}
	}
}
```

- [ ] **Step 4: Update Interface.swift imports and replace previewLayer**

Add UIKit/AppKit import at the top of Interface.swift:

```swift
#if os(iOS)
import UIKit
#else
import AppKit
#endif
```

Remove `import QuartzCore`.

Replace line 57:
```swift
public var previewLayer: @Sendable () async -> PreviewLayer = { PreviewLayer(layer: CALayer()) }
```

With:
```swift
#if os(iOS)
public var previewView: @Sendable () async -> PreviewView = { PreviewView(view: UIView()) }
#else
public var previewView: @Sendable () async -> PreviewView = { PreviewView(view: NSView()) }
#endif

// MARK: - Overlay

/// Update bounding box overlays on the Metal preview. Pass empty array to clear.
/// Note: Updates are best-effort ordered (acceptable since each call fully replaces all overlays).
public var updateOverlays: @Sendable (_ overlays: [OverlayRect]) -> Void = { _ in }
```

- [ ] **Step 5: Update Mocks.swift**

Add UIKit/AppKit import at the top:

```swift
#if os(iOS)
import UIKit
#else
import AppKit
#endif
```

Remove `import QuartzCore`.

In the `noop` mock, replace:
```swift
previewLayer: { PreviewLayer(layer: CALayer()) }
```
With:
```swift
#if os(iOS)
previewView: { PreviewView(view: UIView()) },
#else
previewView: { PreviewView(view: NSView()) },
#endif
updateOverlays: { _ in }
```

Apply the same replacement in the `happy` mock (line 80) and `failing` mock (line 114).

- [ ] **Step 6: Build the interface module**

Run: `swift build --target PhotoCaptureClient 2>&1 | tail -5`
Expected: PASS — all three files updated atomically, no broken references.

- [ ] **Step 7: Commit**

```bash
git add Sources/PhotoCaptureClient/Models.swift Sources/PhotoCaptureClient/Interface.swift Sources/PhotoCaptureClient/Mocks.swift
git commit -m "refactor: replace PreviewLayer with PreviewView, add OverlayRect and updateOverlays"
```

---

## Task 2: Update Package.swift for Metal framework linking and shader resources

**Files:**
- Modify: `Package.swift`

Package.swift MUST be updated before creating MetalPreviewRenderer because the renderer uses `Bundle.module` to load the compiled Metal library. SPM only generates `Bundle.module` when the target has a `resources:` declaration.

- [ ] **Step 1: Update PhotoCaptureClientLive target**

Replace:

```swift
		.target(
			name: "PhotoCaptureClientLive",
			dependencies: [
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
				"PhotoCaptureClient"
			]
		),
```

With:

```swift
		.target(
			name: "PhotoCaptureClientLive",
			dependencies: [
				.product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
				"PhotoCaptureClient"
			],
			resources: [
				.process("Shaders.metal"),
			],
			linkerSettings: [
				.linkedFramework("Metal"),
				.linkedFramework("MetalKit"),
			]
		),
```

- [ ] **Step 2: Commit**

```bash
git add Package.swift
git commit -m "build: add Metal/MetalKit linker settings and shader resources for PhotoCaptureClientLive"
```

---

## Task 3: Create Metal shaders with aspect-fill support

**Files:**
- Create: `Sources/PhotoCaptureClientLive/Shaders.metal`

- [ ] **Step 1: Create the Metal shader file**

Create `Sources/PhotoCaptureClientLive/Shaders.metal`:

```metal
#include <metal_stdlib>
using namespace metal;

// MARK: - Aspect-Fill Uniform

/// Passed from CPU to adjust texture coordinates for aspect-fill cropping.
struct AspectFillUniforms {
    float2 uvScale;   // Scale factor to crop the texture (> 1.0 means crop)
    float2 uvOffset;  // Offset to center the cropped region
};

// MARK: - Camera Frame Rendering (fullscreen textured quad with aspect-fill)

struct CameraVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle that covers the viewport (no vertex buffer needed).
// Vertex IDs 0,1,2 produce a triangle larger than the screen; the rasterizer clips it.
vertex CameraVertexOut cameraVertex(uint vertexID [[vertex_id]],
                                     constant AspectFillUniforms& uniforms [[buffer(0)]]) {
    CameraVertexOut out;
    // Triangle covering [-1,-1] to [3,3] in clip space
    float2 pos = float2((vertexID << 1) & 2, vertexID & 2);
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    // Flip Y for top-left origin, then apply aspect-fill scale and offset
    float2 uv = float2(pos.x, 1.0 - pos.y);
    out.texCoord = uv * uniforms.uvScale + uniforms.uvOffset;
    return out;
}

fragment float4 cameraFragment(CameraVertexOut in [[stage_in]],
                                texture2d<float> cameraTexture [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear,
                                  address::clamp_to_edge);
    return cameraTexture.sample(texSampler, in.texCoord);
}

// MARK: - Bounding Box Overlay Rendering

struct BoxVertex {
    float2 position;
    float4 color;
};

struct BoxVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex BoxVertexOut boxVertex(uint vertexID [[vertex_id]],
                              const device BoxVertex* vertices [[buffer(0)]]) {
    BoxVertexOut out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 boxFragment(BoxVertexOut in [[stage_in]]) {
    return in.color;
}
```

- [ ] **Step 2: Commit**

```bash
git add Sources/PhotoCaptureClientLive/Shaders.metal
git commit -m "feat: add Metal shaders for camera preview with aspect-fill and bounding box overlay"
```

---

## Task 4: Create MetalPreviewRenderer

**Files:**
- Create: `Sources/PhotoCaptureClientLive/MetalPreviewRenderer.swift`

This is the core Metal rendering class. Key design decisions addressing review feedback:
- Uses `mtkView.isPaused = false` with display link to drive rendering on the main thread (not calling `draw()` from the background video queue).
- Computes aspect-fill UV uniforms in `mtkView(_:drawableSizeWillChange:)` so the camera image is never stretched.
- Pre-allocates a reusable vertex buffer for bounding box overlays to avoid per-frame Metal allocations.
- Flushes `CVMetalTextureCache` on memory warning.

- [ ] **Step 1: Create MetalPreviewRenderer.swift**

Create `Sources/PhotoCaptureClientLive/MetalPreviewRenderer.swift`:

```swift
#if os(iOS)
import UIKit
import MetalKit
import AVFoundation
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
	private let _currentFrame = OSAllocatedUnfairLock<(cv: CVMetalTexture, mtl: MTLTexture)?>(initialState: nil)

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

	init?() {
		guard let device = MTLCreateSystemDefaultDevice() else {
			return nil
		}

		guard let commandQueue = device.makeCommandQueue() else {
			return nil
		}

		// Create texture cache for zero-copy CVPixelBuffer → MTLTexture
		var cache: CVMetalTextureCache?
		let status = CVMetalTextureCacheCreate(
			kCFAllocatorDefault, nil, device, nil, &cache
		)
		guard status == kCVReturnSuccess, let textureCache = cache else {
			return nil
		}

		self.device = device
		self.commandQueue = commandQueue
		self.textureCache = textureCache

		// Create MTKView — display-link driven rendering on main thread
		let mtkView = MTKView()
		mtkView.device = device
		mtkView.framebufferOnly = true
		mtkView.colorPixelFormat = .bgra8Unorm
		mtkView.isPaused = false
		mtkView.enableSetNeedsDisplay = false
		mtkView.preferredFramesPerSecond = 60
		self.mtkView = mtkView

		// Build render pipelines from compiled Metal library
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

		// Pre-allocate reusable vertex buffer for bounding box overlays
		let bufferSize = maxBoxVertices * MemoryLayout<BoxVertex>.stride
		guard let boxVertexBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
			return nil
		}

		self.cameraPipeline = cameraPipeline
		self.boxPipeline = boxPipeline
		self.boxVertexBuffer = boxVertexBuffer

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

		// Flush texture cache on memory warning
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
		_currentFrame.withLock { $0 = (cv: cvTex, mtl: texture) }
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
		encoder.setFragmentTexture(frame.mtl, index: 0)
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
```

- [ ] **Step 2: Commit**

```bash
git add Sources/PhotoCaptureClientLive/MetalPreviewRenderer.swift
git commit -m "feat: add MetalPreviewRenderer with display-link rendering, aspect-fill, and overlay support"
```

---

## Task 5: Update Actor.swift — remove AVCaptureVideoPreviewLayer, wire Metal renderer

**Files:**
- Modify: `Sources/PhotoCaptureClientLive/Actor.swift`

This task makes all changes to Actor.swift in one commit: removes AVCaptureVideoPreviewLayer, adds full-rate frame callback, configures BGRA pixel format, creates MetalPreviewRenderer, and replaces `getPreviewLayer` with `getPreviewView`.

- [ ] **Step 1: Add MetalKit import**

At the top of Actor.swift, add after the existing imports:

```swift
#if os(iOS)
import UIKit
import MetalKit
#endif
```

- [ ] **Step 2: Add full-rate frame callback to PhotoCaptureDelegate**

Add after line 36 (`private var lastFrameTime: CFTimeInterval = 0`):

```swift
	// Metal renderer callback — receives every frame at full camera rate (no throttling)
	var onFrame: ((_ pixelBuffer: CVPixelBuffer) -> Void)?
```

- [ ] **Step 3: Remove AVCaptureVideoPreviewLayer property from delegate**

Remove line 43:
```swift
	private(set) var videoPreviewLayer: AVCaptureVideoPreviewLayer?
```

- [ ] **Step 4: Configure BGRA pixel format and remove preview layer in configureSession**

In `configureSession()`, add BGRA format setting after `videoOutput.alwaysDiscardsLateVideoFrames = true` (line 87):

```swift
		videoOutput.videoSettings = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
		]
```

Remove the preview layer creation block (lines 99-101):
```swift
		// Create preview layer
		let preview = AVCaptureVideoPreviewLayer(session: session)
		preview.videoGravity = .resizeAspectFill
```

And remove the preview layer assignment (line 107):
```swift
		self.videoPreviewLayer = preview
```

- [ ] **Step 5: Replace entire captureOutput method body**

Replace the entire `captureOutput(_:didOutput:from:)` method (lines 341-367) with:

```swift
	func captureOutput(
		_ output: AVCaptureOutput,
		didOutput sampleBuffer: CMSampleBuffer,
		from connection: AVCaptureConnection
	) {
		guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

		// Deliver every frame to Metal renderer at full camera rate
		onFrame?(pixelBuffer)

		// Throttle: only deliver frames for detection inference at ~5fps
		let now = CACurrentMediaTime()
		guard now - lastFrameTime >= frameIntervalSeconds else { return }
		lastFrameTime = now

		let width = CVPixelBufferGetWidth(pixelBuffer)
		let height = CVPixelBufferGetHeight(pixelBuffer)
		let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

		let wrapper = PhotoCaptureClient.PixelBufferWrapper(
			pixelBuffer: pixelBuffer,
			width: width,
			height: height,
			bytesPerRow: bytesPerRow,
			timestamp: .now
		)

		pixelBufferContinuation?.yield(wrapper)
	}
```

Note: The key change is that `pixelBuffer` extraction and `onFrame` delivery now happen BEFORE the throttle guard. Previously the throttle guard was first — we must reorder because the Metal renderer needs every frame.

- [ ] **Step 6: Remove videoPreviewLayer from teardown**

In the `teardown()` method, remove:
```swift
		videoPreviewLayer = nil
```

And add `onFrame = nil` cleanup (after `videoDataOutput = nil`):
```swift
		onFrame = nil
```

- [ ] **Step 7: Add MetalPreviewRenderer property to actor**

In `PhotoCaptureClientActor`, add after `private var currentFlashMode` (line 378):

```swift
	#if os(iOS)
	private var metalRenderer: MetalPreviewRenderer?
	#endif
```

- [ ] **Step 8: Create renderer in startSession**

In `startSession()`, after `delegate.registerNotificationObservers()` (line 412) and before `delegate.startRunning()` (line 414), add:

```swift
		#if os(iOS)
		let renderer = await MainActor.run { MetalPreviewRenderer() }
		self.metalRenderer = renderer
		delegate.onFrame = { [weak renderer] pixelBuffer in
			renderer?.enqueueFrame(pixelBuffer)
		}
		#endif
```

- [ ] **Step 9: Clean up renderer in stopSession**

In `stopSession()`, before `delegate.teardown()`, add:

```swift
		#if os(iOS)
		delegate.onFrame = nil
		metalRenderer = nil
		#endif
```

- [ ] **Step 10: Replace getPreviewLayer with getPreviewView and add updateOverlays**

Replace the `getPreviewLayer()` method (lines 515-520) with:

```swift
	#if os(iOS)
	func getPreviewView() -> PhotoCaptureClient.PreviewView {
		if let renderer = metalRenderer {
			return PhotoCaptureClient.PreviewView(view: renderer)
		}
		return PhotoCaptureClient.PreviewView(view: UIView())
	}

	func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {
		metalRenderer?.updateOverlays(overlays)
	}
	#else
	func getPreviewView() -> PhotoCaptureClient.PreviewView {
		return PhotoCaptureClient.PreviewView(view: NSView())
	}

	func updateOverlays(_ overlays: [PhotoCaptureClient.OverlayRect]) {}
	#endif
```

- [ ] **Step 11: Commit**

```bash
git add Sources/PhotoCaptureClientLive/Actor.swift
git commit -m "refactor: replace AVCaptureVideoPreviewLayer with Metal renderer, add BGRA format and full-rate frame delivery"
```

---

## Task 6: Update Live.swift to wire new interface

**Files:**
- Modify: `Sources/PhotoCaptureClientLive/Live.swift:42-44`

- [ ] **Step 1: Replace previewLayer with previewView and add updateOverlays**

Replace lines 42-44:
```swift
		previewLayer: {
			await actor.getPreviewLayer()
		}
```

With:
```swift
		previewView: {
			await actor.getPreviewView()
		},
		updateOverlays: { overlays in
			Task { await actor.updateOverlays(overlays) }
		}
```

- [ ] **Step 2: Build the full package**

Run: `swift build 2>&1 | tail -15`
Expected: PASS — all 4 library targets compile.

- [ ] **Step 3: Commit**

```bash
git add Sources/PhotoCaptureClientLive/Live.swift
git commit -m "feat: wire previewView and updateOverlays in live dependency"
```

---

## Task 7: Full integration build and test verification

**Files:** None (verification only)

- [ ] **Step 1: Clean build all targets**

Run: `swift package clean && swift build 2>&1 | tail -15`
Expected: All 4 library targets and 2 test targets compile, including Metal shader compilation.

- [ ] **Step 2: Run existing tests**

Run: `swift test 2>&1 | tail -15`
Expected: All existing tests pass (they use mocks, not live Metal rendering).

- [ ] **Step 3: Verify no AVCaptureVideoPreviewLayer references remain**

Run: `grep -rn "AVCaptureVideoPreviewLayer\|PreviewLayer\|previewLayer" Sources/ --include="*.swift"`
Expected: No matches. All references replaced with PreviewView/previewView.

- [ ] **Step 4: Verify Metal shader is bundled**

Run: `swift build --target PhotoCaptureClientLive -v 2>&1 | grep -i metal`
Expected: See metal compiler invocation for Shaders.metal → default.metallib.

- [ ] **Step 5: Final commit if any cleanup needed**

Only commit if there are actual changes from cleanup:
```bash
git status
# If changes exist:
git add -A && git commit -m "chore: final cleanup for Metal camera preview migration"
```

---

## Known Limitations / Future Work

These are explicitly out of scope for this plan but noted for awareness:

1. **Device rotation**: The video output is hard-coded to `videoRotationAngle = 90` (portrait). If the app supports landscape, the shader or video connection rotation should be updated on orientation change.
2. **Label text rendering**: The `OverlayRect.label` and `confidence` fields are defined but not rendered as text. Drawing text in Metal requires either a glyph atlas or Core Text rendering to a texture. A future task can add this.
3. **macOS support**: The Metal renderer is iOS-only (`#if os(iOS)`). macOS fallback returns a plain NSView. A future task can add an NSView + MTKView renderer for macOS if needed.
