# claude-progress.md -- PhotoCaptureClient

## Current Verified State

- Last updated: 2026-10-06
- Repo root: `/Users/thanhhaikhong/Documents/PhotoCaptureClient`
- Standard startup path: `./init.sh`
- Standard verification path: `xcode-build --scheme PhotoCaptureClient-Package --platform ios`
- Last verified commit: ba8f32e (docs: add ARCHITECTURE.md — flow and current state)
- Last verification result: PASS — `bash init.sh` exit 0 (iOS Simulator build succeeded) 2026-10-06
- Features passing: 2 / 3 -- preview-001, detection-001 passing; gestures-001 not started
- Highest-priority unfinished feature: gestures-001 (pinch-to-zoom + tap-to-focus gestures)
- Blockers: none
- Next best step: implement gestures-001 per docs/zoom-focus-gestures-design.md
- What must not change while doing it: the two-beat camera flow (preview full-rate, detection throttled ~3fps)

## Known Issues

<!-- One line each: the symptom, and the input or command that triggers it. An entry is
     deleted only when a verification run proves it fixed -- never because it stopped
     being mentioned. Anything here that blocks work is also named on Blockers above. -->

- Chưa tag v0.4.0 + push PhotoCaptureClient (còn treo để phát hành).
- App tiêu thụ (Lensy) `Features/Package.swift` đang local-path override tạm → cần đổi về `from: "0.4.0"` sau khi tag.
- clean-code gate đang hoãn tới bước tích hợp.
- Cần trim `DiagnosticLog` + bỏ log DEPTH verbose trước bản release thật.

## Decisions Made

<!-- What a later session would otherwise re-litigate from scratch. Not a design document.
     Entry shape -- copy, do not edit this block:
     ### 2026-10-06: <the decision, in one line>
     - Reason:
     - Rejected alternative:
     - Constraint it imposes: -->

### 2026-10-06: Model YOLO dùng AGPL-3.0; tách bạch khỏi stack tracker clean-room
- Reason: đã chấp nhận giấy phép AGPL của model Ultralytics YOLO.
- Rejected alternative: tự train/đổi model giấy phép khác.
- Constraint it imposes: `Sources/ObjectTracking` không được chứa code AGPL — xem `Sources/ObjectTracking/Attribution.swift`.

### 2026-10-06: Center-first khi chọn chủ thể cho center-dot
- Reason: người dùng hướng máy vào vật nào là có chủ đích.
- Rejected alternative: chọn theo vật gần nhất (depth-first).
- Constraint it imposes: depth chỉ là tiebreaker trong `centreTieBand`; có hysteresis + hold khi dropout.

### 2026-10-06: Ưu tiên depth phần cứng, monocular chỉ fallback
- Reason: depth cảm biến là mét và chính xác hơn; monocular là tương đối + model inference thứ hai.
- Rejected alternative: luôn chạy monocular `yolo26n-depth`.
- Constraint it imposes: `DepthEstimator` chỉ chạy khi `depthBuffer == nil`.

### 2026-10-06: Flow camera "hai nhịp" là nguyên tắc cốt lõi
- Reason: ML không được đè lên preview; preview phải full-rate và độc lập YOLO.
- Rejected alternative: một nhịp dùng chung cho cả preview lẫn inference.
- Constraint it imposes: preview gọi `onFrame?` mỗi frame; detection throttle ~3fps + `.bufferingNewest(1)`.

### 2026-10-06: "Đo, đừng đoán" cho giả thuyết nhiệt
- Reason: đo trên thiết bị cho thấy pipeline ML/depth/motion của gói KHÔNG phải nguồn nhiệt (CoreML 0,5% · depth 0,1% · motion 0,04% một core); thủ phạm ở phía app tiêu thụ (overlay SwiftUI animate ở display-rate).
- Rejected alternative: tối ưu depth/filtering trong gói để giảm nhiệt (đã đo là gần như vô ích).
- Constraint it imposes: trước khi tối ưu nhiệt phải đo (xctrace Time/Power/Core ML trên device).

## Session Log

<!-- Keep the five most recent sessions. Older blocks are deleted, not moved elsewhere:
     `git log` is already the complete record, and anything worth remembering longer than
     five sessions belongs under Decisions Made or Known Issues, which are never trimmed.
     Every session reads this file at startup, so it is the one artifact whose length has
     to stay bounded. -->

### Session 001 -- 2026-10-06

- Goal: initialize the harness + migrate di sản `docs/superpowers`
- Completed: AGENTS.md CLAUDE.md feature_list.json claude-progress.md init.sh session-handoff.md sprint-contract.md clean-state-checklist.md evaluator-rubric.md quality-document.md
- Verification run: `bash init.sh`
- Evidence recorded: migrate 2 plan đã-xong (metal preview, YOLO) → feature preview-001/detection-001 (passing); 1 spec gesture chưa-xong → feature gestures-001 (not_started) + chuyển spec ra `docs/zoom-focus-gestures-design.md`; xóa `docs/superpowers/`.
- Commit:
- Files updated: tạo harness; `git mv` spec gesture; `git rm -r docs/superpowers`
- Known risks or open questions: xem Known Issues (tag v0.4.0, Lensy override, clean-code gate, trim log)
- Next best step: implement gestures-001 per docs/zoom-focus-gestures-design.md

<!-- harness-init: template=1.5 pack=full generated=2026-10-06 -->
