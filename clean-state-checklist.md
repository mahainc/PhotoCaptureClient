# Clean State Checklist -- PhotoCaptureClient

Run this before committing and at the end of every session.
Session completion = the task passed verification AND this checklist passes.
Missing one means the session is not done.

- [ ] The standard startup path still works (`./init.sh`).
- [ ] The standard verification path still runs (`xcode-build --scheme PhotoCaptureClient-Package --platform ios`).
- [ ] Current progress is recorded in `claude-progress.md`.
- [ ] Feature status reflects what actually passes versus what is unverified.
- [ ] No half-finished step is left behind undocumented.
- [ ] No debug leftovers (stray logging, commented-out blocks, scratch files).
- [ ] Nothing unintended is staged; no secrets or build output committed.
- [ ] The next session can continue without manual repair.
