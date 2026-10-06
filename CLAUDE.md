# CLAUDE.md -- PhotoCaptureClient quick reference

Gói SPM TCA bọc camera AVFoundation + preview Metal + phát hiện/bám vật thể YOLO
(CoreML/Vision) + độ sâu + tách nền, theo kiểu `@DependencyClient` interface-tách-Live.

@AGENTS.md

Full rules live in `AGENTS.md`; the line above imports them. Claude Code loads `CLAUDE.md`
*or* `AGENTS.md` -- never both -- so in a repo that has the two files, the import is the only
thing that still carries the startup sequence, the hard rules, the commands table and the
escalation cases into the session. Other agents read that line as ordinary text and open the
file themselves. This file is the short form.

## Operating Loop

`pwd` -> `claude-progress.md` -> `feature_list.json` -> project docs -> `git log --oneline -5`
-> `./init.sh` -> baseline smoke -> **fix a broken baseline before anything else** -> pick
highest-priority unfinished feature -> work only on it.

## Rules

- One feature at a time.
- Do not rewrite the feature list to hide unfinished work.
- Do not delete or weaken tests to make a task look complete.
- Do not change the verification rules while implementing.
- Durable repo artifacts beat chat summaries.

## Required Files

`AGENTS.md`'s Required Artifacts section names every file this harness installed and what
each one is for. That list is the only one. A second copy here is a second thing to forget
when the user keeps a file of their own -- the same reason the commands table lives in one
file and not two.

## Completion Gate

A feature may move to `passing` only after the required verification succeeded and the
result was recorded as evidence.

## Commands

The commands table lives in `AGENTS.md` and that file is authoritative. Two files carrying
one build command is how they come to disagree. Start every session with `./init.sh`; it
runs install and verification for you.

## When Blocked

Set the feature to `blocked`, write what would unblock it into `claude-progress.md`, and
stop. Do not stub a missing dependency, guess an unclear requirement, or work around a
failing baseline. `AGENTS.md` has the four cases.

## Before You Stop

Session completion = the task passed verification AND the repo is clean.

Record progress -> update feature status + evidence -> note blockers -> remove debug
leftovers -> commit -> leave `./init.sh` working.

`clean-state-checklist.md` is that list in checkbox form; `evaluator-rubric.md` is the
acceptance review, and the reviewer must not be the session that wrote the code. It scores
against `sprint-contract.md`, which fixes the scope and the acceptance criteria before the
sprint starts.
