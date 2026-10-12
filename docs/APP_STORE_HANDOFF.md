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
- [x] Select Xcode 26+ explicitly and assert SDK/toolchain requirements.
- [x] Add bundled PrivacyInfo.xcprivacy for UserDefaults and disk-space APIs.
- [x] Provide an opaque 1024px primary icon without changing desktop imagery.
- [x] Add signed distribution archive/export + validation instructions; retain
      unsigned IPA for personal testing. Never commit credentials.
- [x] In-app privacy/support screen and publishable privacy policy page.
      Public hosting URL and support contact require owner configuration.

### P1: reliability and editing
- [x] Move debounced persistence off MainActor and flush before state changes.
      Do not silently continue import/export after failed persistence.
- [x] Make whole-video mode apply to an already analyzed project with undo.
- [x] Preview the actual composition before export; preserve exact export math.
- [x] Add per-export deletion, storage information, orphan cleanup.
- [x] Register background grace before work begins; continued processing on
      iOS 26 requires GPU capability/signing and physical validation.

### P2: performance, clarity and tests
- [x] Reuse bounded frame generator; measure before claiming speedups.
- [x] Merge padded activity overlaps and default to chronological order.
- [x] Load source audio metadata once, not inside every clip iteration.
- [x] Clarify resolution-only original option and actual SDR/30fps output.
- [x] Split navigation into projects/editor/settings; improve trimming/preview.
- [ ] Localization/accessibility and actionable permission/error messages.
- [ ] Add focused native tests for new behavior; export CI logs/xcresult on failure.
- [ ] Track real on-device HEVC/HDR/long-clip/storage/background validation.

### Desktop-only review findings (lower priority)
- [x] Empty analysis calls undefined queueSave instead of queueEditSave.
- [x] Disk reservations race across projects (per-project lock is insufficient).

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

- 2026-10-12 checkpoint 1: PR #2 created at https://github.com/erez1980/rk-motion/pull/2.
  Remote P0 commit c9c28c39f852154d73703e7dc23dfc2e06abf279. CI run
  38206222424 compiled successfully with Xcode 26.3; simulator tests running.
  `scripts/check-ios-store.py`, shell syntax and diff checks passed locally.
  Public privacy link targets main and becomes live only after merge.
- Checkpoint 2 (native CI pending): ProjectPersistence serial actor + revision
  guards, debounced saves, split scores.json with legacy read compatibility,
  explicit flush gates, whole-video application/undo, per-export deletion/storage
  display, shared composition for preview/export, chronological merged activity
  windows, reused image generator and local-only performance logging. Added
  native regression tests. Signed export/account/physical checks remain unrun.
  iOS 26 background integration is added in the next checkpoint; disabled by default until signed GPU capability/device validation.

- Checkpoint 3 (native CI pending): project library with thumbnails, visual
  trim sheet + clip playback, keyboard dismissal, output duration/dimensions,
  explicit temporary cleanup and immutable score-file references (atomic
  metadata commit; legacy scores/inline scores remain readable).
  iOS 26 continuous-task integration reports progress/expiration, starts work
  through the scheduler handler and requests GPU only for opt-in paid signed
  builds. Unsigned/default builds use limited foreground grace. See release
  guide for capability/profile/flag setup. Device validation remains essential.
  Desktop empty-analysis typo and cross-project upload reservation race fixed.
  Checkpoint 2 CI 38206639216 PASSED native compile/tests/device IPA; Python
  CI 38206639230 PASSED. No performance speedup or physical testing claimed.
