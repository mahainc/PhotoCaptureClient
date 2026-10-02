# PhotoCaptureClient — Kiến trúc & Trạng thái hiện tại

Gói SPM `mahainc/PhotoCaptureClient`: camera chụp ảnh + phát hiện/bám vật thể
(Ultralytics YOLO qua CoreML/Vision) + độ sâu + tách nền, đóng theo kiểu TCA
`@DependencyClient` (interface tách khỏi Live). App tiêu thụ (vd Lensy) chỉ bump
version dependency, không chạm nội bộ.

> **Giấy phép:** các model YOLO là **AGPL-3.0** (đã chấp nhận). Giữ tách bạch khỏi
> stack tracker clean-room — xem `Sources/ObjectTracking/Attribution.swift`.

---

## 1. Target layout

| Target | Vai trò |
|---|---|
| `PhotoCaptureClient` | Interface camera: `@DependencyClient`, `PixelBufferWrapper`, `Photo`, `Event`, `PreviewView`, `OverlayRect`… |
| `PhotoCaptureClientLive` | AVFoundation thật: `PhotoCaptureClientActor` + `PhotoCaptureDelegate`, Metal preview, depth phần cứng, center-dot overlay |
| `ObjectDetectionClient` | Interface detect/seg: `Configuration`, `DetectionResult`, `DetectedObject`, `MaturedObject`, `SegmentationResult`, `detectInImage`, `segmentInImage` |
| `ObjectDetectionClientLive` | Inference thật: `ObjectDetectionClientActor` (Vision+CoreML), `DepthEstimator`, `SegmentationEngine`, `DepthSampler` |
| `ObjectTracking` | Tracker clean-room (ByteTrack/OC-SORT/BoT-SORT CMC, Kalman), `CameraMotionEstimator` — **không** code AGPL |
| `MultiCamClient` / `…Live` | Đa camera (ngoài phạm vi tài liệu này) |

Tests: `PhotoCaptureClientTests`, `ObjectDetectionClientTests`, `ObjectTrackingTests`,
`MultiCamClientTests`.

---

## 2. Flow camera "hai nhịp" (nguyên tắc cốt lõi — phải giữ)

Một callback `captureOutput(didOutput:)` phục vụ **hai nhịp tách biệt** để ML không đè
lên preview (`PhotoCaptureClientLive/Actor.swift`, trong `PhotoCaptureDelegate`):

1. **Preview = full camera rate (30/60fps).** Mỗi frame gọi `onFrame?(pixelBuffer)` →
   `MetalPreviewRenderer.enqueueFrame`. Renderer vẽ **on-demand** (texture zero-copy qua
   `CVMetalTextureCache`, 1 quad + overlay). Preview **không phụ thuộc YOLO**.
2. **Detection = throttle ~3fps.** Cùng callback chặn nhịp bằng `frameIntervalSeconds =
   0.333` rồi mới `pixelBufferContinuation.yield(wrapper)`. Tracker Kalman "coast" box
   giữa các lần suy luận nên dot không giật.

Chi tiết quan trọng:
- `alwaysDiscardsLateVideoFrames = true` — frame trễ bị bỏ, không dồn ứ.
- `observePixelBuffers()` dùng `AsyncStream(bufferingPolicy: .bufferingNewest(1))` — nếu
  inference tụt lại thì chỉ giữ frame mới nhất, không ăn backlog, không ghim buffer pool.
- Inference chạy **off-actor** trên `inferenceQueue` (userInitiated); actor chỉ làm phần
  tracker rẻ.
- Compute pinned `.cpuAndNeuralEngine` (tránh `.all` để ANE không tranh GPU với Metal
  preview — đúng khuyến nghị Ultralytics cho app camera).

---

## 3. Detection + tracking

`ObjectDetectionClientActor` (`ObjectDetectionClientLive/Actor.swift`):

1. `startDetection` nạp `yolo26n` qua `VNCoreMLModel` + `ThresholdProvider` (bơm
   `iouThreshold`/`confidenceThreshold`), labels đọc từ metadata model (`ModelLabels.parse`).
2. `processFrame` → `runInference` (off-actor): `VNImageRequestHandler` trên
   `CVPixelBuffer` → `VNRecognizedObjectObservation` (NMS nhúng sẵn trong pipeline model
   `nms=True`, Vision decode hộ). Đổi box bottom-left → top-left.
3. `CameraMotionEstimator` ước lượng chuyển động camera (Vision image registration) cho
   BoT-SORT CMC.
4. `MultiObjectTracker.update` gán ID ổn định, coast qua dropout → `DetectedObject` phát
   qua `observeResults`.
5. `cropMaturedObjects`: vật bám đủ lâu (`dwellSeconds`) được cắt JPEG một lần
   (`MaturedObject`) từ chính frame nhìn thấy nó.

---

## 4. Độ sâu (depth)

Hai nguồn, ưu tiên phần cứng (xem [YOLO vs depth camera](#9-yolo-depth-vs-depth-camera)):

- **Phần cứng** — `AVCaptureDepthDataOutput` (LiDAR / dual / TrueDepth) → chuẩn hóa
  `DepthFloat32` (mét, nhỏ = gần), xoay khớp video bằng `applyingExifOrientation`, gắn vào
  `PixelBufferWrapper.depthBuffer`.
- **Monocular (fallback)** — `DepthEstimator` chạy model `yolo26n-depth` **chỉ khi
  `depthBuffer == nil`** (máy không cảm biến), giãn nhịp mỗi `monocularDepthInterval = 3`
  frame. Depth **tương đối** (thứ tự gần/xa), không phải mét.

`DepthSampler.sample` lấy ~**percentile 20** trên lưới 5×5 ở ~60% trong box (bền với nền
lọt/che khuất) → gán `DetectedObject.depth`.

---

## 5. Segmentation (tách nền chủ thể)

`SegmentationEngine` + `SegmentationDecoder` (`ObjectDetectionClientLive/Segmentation.swift`),
qua `segmentInImage(_:)` — **chỉ chạy trên ảnh tĩnh sau khi chụp**, KHÔNG mỗi frame:

- Model `yolo26n-seg`: tensor detect `[1,300,38]` (4 box + score + class + 32 coeff) +
  prototype `[1,32,160,160]`.
- Mask = `sigmoid(Σ coeff·proto)` → upsample bilinear → threshold → alpha → PNG cutout.
- Trả `SegmentedObject { label, confidence, boundingBox, cutoutPNG }` cho luồng scan.

---

## 6. Chọn chủ thể — center-dot "center-first"

`DetectionDotOverlayView.decideTarget` (`PhotoCaptureClientLive/`):

- **Ưu tiên vật ở TRUNG TÂM khung trước**, bất kể depth xa hơn — vì người dùng hướng máy
  vào vật nào là có chủ đích.
- **Depth chỉ là tiebreaker** khi nhiều vật gần như cùng tâm (trong `centreTieBand = 0.08`).
- Có hysteresis (`switchProximityFloor`, `isClearlyBetter`) + hold khi dropout để dot không
  nhảy.

---

## 7. Models & export

- `yolo26n` (detect), `yolo26n-seg`, `yolo26n-depth` — COCO-80, imgsz 640, bundled trong
  `ObjectDetectionClientLive/Resources` (`Package.swift` `.copy(...)`).
- Detect/seg export `nms=True` (pipeline model giữ đường Vision `VNRecognizedObjectObservation`).
- Tái lập: **`scripts/export-models.sh`** (`yolo export … format=coreml int8=True nms=True
  imgsz=640`, kèm subcommand `inspect`).

---

## 8. Trạng thái hiện tại (cập nhật 2026-10-02)

**Nhánh `feat/yolo26-models`, HEAD `3573e21`** — đã commit (chưa tag, chưa push):
- YOLO11n → **YOLO26n** (detect), thêm **segmentation** (cutout) + **monocular depth**
  (Phase A/B/C), **center-first dot**, backpressure `.bufferingNewest(1)`, `ModelLabels`
  dùng chung, `DiagnosticLog`, `scripts/export-models.sh`; bỏ `yolo11n`.

**Chưa commit (phiên tối ưu nhiệt 2026-10-02)** — 4 file:
`ObjectDetectionClientLive/{Actor,DepthEstimator,DiagnosticLog}.swift`,
`PhotoCaptureClientLive/Actor.swift`:
- Throttle callback depth về nhịp detect; `isFilteringEnabled = false`; bỏ vòng quét MONO
  min/max; **logging gói hết vào `#if DEBUG`** (release không ghi file/không print).
- ⚠️ **Đo được: 3 chỉnh sửa depth gần như vô ích cho nhiệt** (depth ~0,1% CPU, CoreML-trên-
  CPU 0,73% một core). Chỉ "logging là debug" là đáng giữ (vệ sinh code). **Đang chờ quyết
  giữ hay revert.**

**Còn treo để phát hành:**
1. Tag **v0.4.0** + push PhotoCaptureClient.
2. Lensy: `Features/Package.swift` đang **local path override tạm** → đổi về `from: "0.4.0"`,
   refresh resolved, build lại.
3. clean-code gate đang **hoãn tới tích hợp** ("Hoãn gate tới tích hợp").
4. Trim `DiagnosticLog` + log DEPTH verbose trước bản release thật.

---

## 9. YOLO depth vs depth camera

YOLO26 **có** model depth đơn mắt (`yolo26n-depth`) → ra depth từ **1 ảnh RGB, không cần
cảm biến**, nhưng: (a) là **model riêng**, phải chạy inference thứ hai; (b) depth **tương
đối**, không phải mét; (c) kém chính xác hơn cảm biến. Hiện code **ưu tiên depth phần cứng**,
chỉ fallback monocular khi máy không có cảm biến. Với center-first, depth chỉ là tiebreaker
hiếm dùng.

---

## 10. Ghi chú hiệu năng (đo trên máy thật)

Điều tra "máy nóng khi dùng camera" (iPhone 11 Pro Max) cho thấy **pipeline ML/depth/motion
của gói này KHÔNG phải nguồn nhiệt** (CoreML 0,5% · Vision 0,5% · depth 0,1% · motion 0,04%
một core). Thủ phạm nằm **phía app tiêu thụ** (một overlay SwiftUI animate ở display rate),
không phải PhotoCaptureClient.

Runbook đo (xctrace Time/Power/Core ML trên device) + số liệu đầy đủ:
**`Lensy/docs/profiling-on-device.md`**. Nguyên tắc: **đo, đừng đoán** — đặc biệt với giả
thuyết "dual-camera depth gây nóng" vẫn **chưa được đo riêng**.
