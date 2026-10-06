#!/usr/bin/env bash
# init.sh -- standard startup and verification path.
# Run this after cloning, and at the start of every session.
set -euo pipefail
cd "$(dirname "$0")"

# A slot with no command for this stack is rendered as (:) -- the shell no-op --
# rather than an empty array, which is unbound under `set -u` on bash 3.2.
INSTALL_CMD=(:)
VERIFY_CMD=(xcode-build --scheme PhotoCaptureClient-Package --platform ios)
START_CMD=(:)

echo "=== PhotoCaptureClient init ==="
echo "repo root: $(pwd)"
echo ""

echo "[1/4] Installing dependencies..."
if [ "${INSTALL_CMD[0]}" = ":" ]; then
  echo "  (no install step for this stack)"
else
  "${INSTALL_CMD[@]}"
fi
echo ""

echo "[2/4] Baseline verification..."
# A verify slot that is the shell no-op would print this banner and pass without having
# proven anything. That is the "looks green, verified nothing" outcome the harness exists
# to prevent, so it is an error here rather than a silent success.
if [ "${VERIFY_CMD[0]}" = ":" ]; then
  echo "  ERROR: no verification command is configured for this repo."
  echo "  Set VERIFY_CMD above to a real command before trusting this script."
  exit 1
fi
# `false` is the OTHER honest empty slot: detection found a stack but could not name its
# verify command. Bare `false` under `set -e` would exit 1 with no output at all, leaving
# the session unable to tell "the tests failed" from "nobody ever filled this in".
if [ "${VERIFY_CMD[0]}" = "false" ]; then
  echo "  ERROR: the verification command for this repo was never resolved."
  echo "  init.sh fails here on purpose. Replace VERIFY_CMD above with the real command."
  exit 1
fi
"${VERIFY_CMD[@]}"
echo ""

echo "[3/4] Harness files..."
ok=true
# The files THIS run wrote -- not a fixed four. A --full pack has nine, and a repo whose
# progress log is called PROGRESS.md has that name here instead of claude-progress.md.
for f in AGENTS.md CLAUDE.md feature_list.json claude-progress.md init.sh session-handoff.md sprint-contract.md clean-state-checklist.md evaluator-rubric.md quality-document.md; do
  if [ -f "$f" ]; then
    echo "  OK: $f"
  else
    echo "  MISSING: $f"
    ok=false
  fi
done
echo ""

if [ "$ok" != true ]; then
  echo "=== Init complete with warnings: harness files are missing. ==="
  exit 1
fi

echo "[4/4] Harness score..."
# Optional: `harness-check` is a local wrapper, not something this repo ships. When it is
# absent the harness is still fine — it just goes unscored. Never make init.sh depend on
# a tool that only exists on one machine.
if command -v harness-check >/dev/null 2>&1; then
  harness-check score --min 70 . || echo "  (harness score below threshold -- see the failing checks above)"
else
  echo "  (harness-check not on PATH -- skipping the score)"
fi
echo ""

if [ "${START_CMD[0]}" = ":" ]; then
  echo "=== Init complete. ==="
else
  echo "=== Init complete. Start with: ${START_CMD[*]} ==="
  if [ "${RUN_START_COMMAND:-0}" = "1" ]; then
    exec "${START_CMD[@]}"
  fi
fi

# harness-init: template=1.5 pack=full
