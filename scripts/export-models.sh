#!/usr/bin/env bash
#
# export-models.sh — reproducibly export the Ultralytics YOLO CoreML models that
# ObjectDetectionClientLive bundles. This is the provenance for every *.mlpackage
# under Sources/ObjectDetectionClientLive/Resources/.
#
# All models are exported at imgsz=640, INT8, with NMS baked into the CoreML
# pipeline (nms=True) so the Swift side keeps decoding via Vision's
# VNRecognizedObjectObservation + ThresholdProvider (iouThreshold /
# confidenceThreshold inputs). Do NOT switch to the NMS-free head (nms=False)
# without also adding a manual tensor decoder in Swift.
#
# Usage:
#   scripts/export-models.sh detect        # YOLO26n detector (Phase A)
#   scripts/export-models.sh seg           # YOLO26n-seg segmenter (Phase B)
#   scripts/export-models.sh depth         # YOLO26 monocular depth (Phase C)
#   scripts/export-models.sh all           # all of the above
#   scripts/export-models.sh inspect PATH  # print a .mlpackage's I/O spec
#
# Env overrides:
#   DETECT_MODEL (default yolo26n.pt, fallback yolo11n.pt)
#   SEG_MODEL    (default yolo26n-seg.pt, fallback yolo11n-seg.pt)
#   DEPTH_MODEL  (default yolo26n-depth.pt — YOLO26 only; name verified in Phase 0)
#   IMGSZ (default 640)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RES_DIR="$REPO_ROOT/Sources/ObjectDetectionClientLive/Resources"
VENV="$REPO_ROOT/.venv-export"
IMGSZ="${IMGSZ:-640}"

activate() {
  if [[ ! -d "$VENV" ]]; then
    echo "error: venv not found at $VENV" >&2
    echo "  python3 -m venv $VENV && . $VENV/bin/activate && pip install ultralytics coremltools" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . "$VENV/bin/activate"
}

# export_one <checkpoint.pt> <extra yolo export args...>
export_one() {
  local ckpt="$1"; shift
  echo "=== exporting $ckpt (imgsz=$IMGSZ) ==="
  yolo export model="$ckpt" format=coreml int8=True imgsz="$IMGSZ" "$@"
  local out="${ckpt%.pt}.mlpackage"
  if [[ -d "$out" ]]; then
    mkdir -p "$RES_DIR"
    rm -rf "$RES_DIR/$(basename "$out")"
    mv "$out" "$RES_DIR/"
    echo "    -> $RES_DIR/$(basename "$out")"
    inspect_spec "$RES_DIR/$(basename "$out")"
  else
    echo "error: expected $out not produced" >&2
    exit 1
  fi
  rm -f "$ckpt"
}

# inspect_spec <path.mlpackage> — print inputs/outputs so Phase A can confirm the
# model still exposes iouThreshold/confidenceThreshold and a pipeline (NMS) output.
inspect_spec() {
  local pkg="$1"
  python - "$pkg" <<'PY'
import sys, coremltools as ct
m = ct.models.MLModel(sys.argv[1])
s = m.get_spec()
print("  spec type:", s.WhichOneof("Type"))
print("  inputs: ", [i.name for i in s.description.input])
print("  outputs:", [o.name for o in s.description.output])
PY
}

cmd="${1:-all}"
case "$cmd" in
  detect) activate; export_one "${DETECT_MODEL:-yolo26n.pt}"      nms=True ;;
  seg)    activate; export_one "${SEG_MODEL:-yolo26n-seg.pt}"     nms=True ;;
  depth)  activate; export_one "${DEPTH_MODEL:-yolo26n-depth.pt}"          ;;  # depth head has no NMS
  all)
    activate
    export_one "${DETECT_MODEL:-yolo26n.pt}"  nms=True
    export_one "${SEG_MODEL:-yolo26n-seg.pt}" nms=True
    export_one "${DEPTH_MODEL:-yolo26n-depth.pt}"
    ;;
  inspect) activate; inspect_spec "${2:?usage: export-models.sh inspect PATH.mlpackage}" ;;
  *) echo "usage: $0 {detect|seg|depth|all|inspect PATH}" >&2; exit 2 ;;
esac

echo "=== done ==="
