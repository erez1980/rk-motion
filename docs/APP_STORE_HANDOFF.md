# RK Motion App Store readiness — implementation handoff

## Authorization and invariant

Erez asked on 2026-10-12 to implement the App Store blockers first, then the
review findings from highest to lowest priority, and leave a durable handoff
so Claude can continue without repeating completed work. The target device
is iPhone 17 Pro. The app must remain standalone and process media locally.
Do not introduce a Mac server, cloud processing, account requirement or
YouTube downloader into the iPhone app. Do not publish to App Store or buy
membership without Erez's explicit instruction. A development branch/PR is
authorized. No Apple credentials are currently available.

## Starting point

- Base: main `f6aaae1a051e320ddb7d832e01656371a66cc270`.
- Branch: `codex/app-store-readiness`.
- Claude already fixed the AVFoundation instruction tail gap (`6928cd8`) and
  exact-frame fade test (`fa08ceb`). Do not revert these fixes.
- Main iPhone workflow 38204214516 passed; it used Xcode 16.4 / SDK 18.5,
  therefore successful compilation alone does not imply Store readiness.
- Current execution environment is Linux. Native Swift/AVFoundation tests
  require the GitHub macOS workflow; physical validation requires Erez's phone.

## Priority queue and findings

### P0: submission blockers (in progress)
- [ ] Select Xcode 26+ explicitly and assert SDK/toolchain requirements.
- [ ] Add bundled PrivacyInfo.xcprivacy for UserDefaults and disk-space APIs.
- [ ] Provide an opaque 1024px primary icon without changing desktop imagery.
- [ ] Add signed distribution archive/export + validation instructions; retain
      unsigned IPA for personal testing. Never commit credentials.
- [ ] In-app privacy/support screen and publishable privacy policy page.
      Public hosting URL and support contact require owner configuration.

### P1: reliability and editing
- [ ] Move debounced persistence off MainActor and flush before state changes.
      Do not silently continue import/export after failed persistence.
- [ ] Make whole-video mode apply to an already analyzed project with undo.
- [ ] Preview the actual composition before export; preserve exact export math.
- [ ] Add per-export deletion, storage information, orphan cleanup.
- [ ] Register background grace before work begins; continued processing on
      iOS 26 requires GPU capability/signing and physical validation.

### P2: performance, clarity and tests
- [ ] Reuse bounded frame generator; measure before claiming speedups.
- [ ] Merge padded activity overlaps and default to chronological order.
- [ ] Load source audio metadata once, not inside every clip iteration.
- [ ] Clarify resolution-only original option and actual SDR/30fps output.
- [ ] Split navigation into projects/editor/settings; improve trimming/preview.
- [ ] Localization/accessibility and actionable permission/error messages.
- [ ] Add focused native tests for new behavior; export CI logs/xcresult on failure.
- [ ] Track real on-device HEVC/HDR/long-clip/storage/background validation.

### Desktop-only review findings (lower priority)
- [ ] Empty analysis calls undefined queueSave instead of queueEditSave.
- [ ] Disk reservations race across projects (per-project lock is insufficient).

## Resume procedure

1. Read this file and `git status`, `git log -8`, open PR/workflow state.
2. Review completed changes before editing; respect concurrent owner work.
3. Continue the first unchecked item whose prerequisites are available.
4. Commit checkpoints, run meaningful checks, update this handoff with exact
   results and limitations. Never claim physical tests were performed here.

## Checkpoint log

- 2026-10-12: baseline reviewed; no implementation changes yet. Submission
  blockers confirmed: outdated SDK, missing manifest, RGBA transparent icon,
  unsigned-only distribution. Native CI passing on baseline.
