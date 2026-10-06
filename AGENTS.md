# AGENTS.md -- PhotoCaptureClient

## What This Project Is

Gói SPM TCA bọc camera AVFoundation + preview Metal + phát hiện/bám vật thể YOLO
(CoreML/Vision) + độ sâu + tách nền, theo kiểu `@DependencyClient` interface-tách-Live.

The goal is not to maximize raw code output. The goal is to leave the repository in a
state where the next session can continue without guessing.

## Startup Sequence

Before writing any code, complete these in order:

1. Run `pwd` and confirm the repository root.
2. Read `claude-progress.md`.
3. Read `feature_list.json`.
4. Read the project's own docs if they exist -- `README`, `docs/PRODUCT.md`,
   `docs/ARCHITECTURE.md`. This file says how to work here; those say what is being built.
5. Review recent commits with `git log --oneline -5`.
6. Run `./init.sh`.
7. Run a baseline smoke or end-to-end path.
8. If the baseline is broken, fix that first -- before starting any new feature.
9. Select the highest-priority unfinished feature.
10. Work only on that feature until it is verified or explicitly blocked.

## Hard Rules (MUST / MUST NOT)

These are not preferences. A session that breaks one of them has failed, whatever else it
produced.

- Work on one feature at a time.
- Keep changes inside the selected feature's scope unless a blocker needs a narrow fix.
- Do not mark a feature done just because code was added.
- Do not silently change the verification rules while implementing.
- Do not rewrite the feature list to hide unfinished work.
- Do not delete or weaken tests to make a task look complete.

## Guidelines

- Prefer durable repo artifacts over chat summaries.

## Required Artifacts

Every file this harness installs is named here. A file the pack writes but this list does
not name is a file no session will ever open.

- `AGENTS.md` -- this file: how to work in this repo
- `feature_list.json` -- source of truth for feature status
- `claude-progress.md` -- session log and current verified state
- `init.sh` -- standard startup and verification path
- `CLAUDE.md` -- the short form of this file
- `session-handoff.md` -- what the last session left mid-flight
- `sprint-contract.md` -- scope, acceptance criteria and roles, agreed before a sprint starts
- `clean-state-checklist.md` -- run before every commit and at end of session
- `evaluator-rubric.md` -- the acceptance review; the reviewer is not the session that wrote the code
- `quality-document.md` -- per-domain grades, updated after a significant session

## Definition of Done

A feature is done only when all of these are true:

- the target behavior is implemented
- the required verification actually ran
- evidence is recorded in `feature_list.json` or `claude-progress.md`
- the repository still starts from the standard startup path

**Verification levels -- do not skip:**

1. Static: `xcode-build --scheme PhotoCaptureClient-Package --platform ios`
2. Runtime behavior (unit + integration): `swift-test`
3. End-to-end flow

Do not go to level 2 if level 1 fails. Do not go to level 3 if level 2 fails.

**A feature may move to `passing` only after the required verification succeeded and the
result was recorded as evidence.**

## Commands

| Purpose | Command |
|---------|---------|
| Install | `(none)` |
| Verify  | `xcode-build --scheme PhotoCaptureClient-Package --platform ios` |
| Start   | `(none)` |
| Init    | `./init.sh` |

## Escalation

`blocked` is a real status, not a failure. Use it -- and say what would unblock it -- when:

- **A design decision is needed** that the repo does not already answer. Check the
  project's own docs first; if they are silent, record the options in `claude-progress.md`
  under Decisions Made and ask.
- **The feature's intent is unclear.** Do not guess a behavior and verify your guess.
- **Verification fails for a reason outside this feature.** Fix the baseline first if it
  is small; otherwise record it under Known Issues and stop rather than working around it.
- **A dependency or credential is missing.** Name exactly what is missing. Do not stub it
  and mark the feature passing.

In every case: update the feature's status, write the blocker into `claude-progress.md`,
and leave the repo runnable.

## End of Session

Session completion = the task passed verification AND this section completed.
Missing either one means the session is not done.

1. Record progress in `claude-progress.md`.
2. Trim `## Session Log` there to the five most recent sessions -- every session reads that
   file at startup, so its length is the one that has to stay bounded. `git log` keeps the
   rest; Decisions Made and Known Issues are never trimmed.
3. Update feature status and evidence in `feature_list.json`.
4. Record any unresolved risk or blocker.
5. Remove debug leftovers -- stray logging, commented-out blocks, scratch files.
6. Commit safe work.
7. Leave the repo clean enough that the next session can run `./init.sh` immediately.

<!-- harness-init: template=1.5 pack=full generated=2026-10-06 -->
