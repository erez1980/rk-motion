# RK Motion App Store readiness — implementation handoff

## Latest verified checkpoint — read first

- Verified source commit: `9a5ece4cc965d5446cbf94e6ad9444209aed7221`.
- Native workflow **38207915542 PASSED** on Xcode 26.3: simulator build,
  **9 tests / 0 failures**, arm64 device archive and IPA publication.
- Python workflow **38207915515 PASSED**; the suite contains **209 tests**.
- IPA: https://github.com/erez1980/rk-motion/actions/runs/38207915542/artifacts/11728810168
- PR: https://github.com/erez1980/rk-motion/pull/2 (draft, unmerged).
- Subsequent checkpoint changes are documentation only; native code is the
  verified source above. Check diff/CI before deciding another build is needed.
- Next essential gates: owner Developer account/profile and actual iPhone
  testing. Code/configuration work is ready for those gates. No credentials,
  Store upload, on-device benchmark or physical validation was performed.

## Authorization and invariant

Erez asked on 2026-10-12 to implement the App Store blockers first, then the
review findings from highest to lowest priority, and leave a durable handoff
so Claude can continue without repeating completed work. The target device
is iPhone 17 Pro. The app must remain standalone and process media locally.
Do not introduce a Mac server, cloud processing or account requirement into
the iPhone app. YouTube music download: Erez decided on 2026-10-12 to allow it
in personal builds only (Xcode/unsigned/simulator). The code compiles under
`RK_YOUTUBE`, but turning that off is NOT enough: the package's object files
and Swift metadata still reached the binary (CI caught it). The store archive
is therefore built from `ios/RKMotion-Store.xcodeproj`, generated with
`RK_STORE_PROJECT=1` and holding no package at all; CI builds that project and
proves its binary has no YouTubeKit. Never let it into the store build:
guideline 5.2.3 bars it. Do not publish to App Store or buy
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

### P0: submission blockers (code prepared; account validation pending)
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
- [x] Hebrew String Catalog foundation, trim/progress accessibility labels and permission Settings action.
- [x] English localization: all interface text, every status and failure
      message, and the iOS Photos permission prompt. Enforced by the store
      check, so untranslated text cannot ship.
- [ ] Full VoiceOver/Dynamic Type/rotation validation (needs a device; code
      carries accessibility labels but nothing was seen on a screen).
- [x] Add focused native tests for new behavior; export CI logs/xcresult on failure.
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

- Checkpoint 4 (localization, Claude): the catalog held Hebrew only, so an
  English device read Hebrew everywhere, and the Photos prompt stayed Hebrew in
  every language because iOS reads it from Info.plist, which Localizable
  never covers. Added `InfoPlist.xcstrings` and wired it into the build.
  Status and failure messages were plain Swift strings; `AppError` now resolves
  its own description and the status line resolves on display, which covers
  every throw site and assignment without touching them. Assembled messages
  resolve their prefix separately. Interpolated text was rewritten as explicit
  format keys so the catalog key does not depend on how SwiftUI spells an
  interpolation. `"סיום"` was one key serving both the End label and the Done
  buttons, which no single English word can do, so the buttons read `"בוצע"` —
  the only Hebrew wording change, and Erez was told. Catalog: 76 -> 169 keys.
  `check-ios-store.py` now fails on a catalog key missing Hebrew or English, on
  a usage description with no catalog entry, and on any Hebrew literal in the
  Swift sources that is not a catalog key; all three were confirmed to fail on
  deliberately broken input. Native and Python CI passed on 6da47a9 and
  a29977c. No device, VoiceOver or Dynamic Type validation was performed.
- Codex review of 12363d9 (P2): the iOS 26 background Live Activity title and
  progress line reached `BGContinuedProcessingTaskRequest` and `updateTitle`
  as raw Hebrew, so an English device saw Hebrew there. Fixed at that boundary
  in `ContinuedProcessing.swift`. Limit of the guard, keep in mind: the store
  check proves every Hebrew literal has a translation; it cannot prove every
  path looks one up. Text handed to a system API leaves the app past every
  view that would localize it, so it must be localized where it is handed over.

- Checkpoint 5 (YouTube music, personal builds, Claude): yt-dlp cannot run on
  iOS (since 2025.11 it needs an external JavaScript runtime such as Deno), so
  the app uses YouTubeKit 0.4.9 (pinned exact; release 2026-08-18) with
  extraction forced to `.local`: its remote fallback would send the video to a
  third-party server. The audio stream is the highest-bitrate audio-only stream
  AVFoundation can play, fetched in 4 MB ranged requests because YouTube slows
  one long request to playback speed, then added through the existing
  `importMusic`, exactly like a Files import. UI: a link-paste alert beside
  "add music from Files"; no YouTube search in the app. Tests cover link
  detection (including lookalike hosts) and file naming only. Not verified
  anywhere: that extraction and download work against YouTube today. CI cannot
  check it (YouTube refuses data-centre clients); only a device can, and a
  YouTube change can break it until YouTubeKit is updated. First CI run showed
  a compile condition alone left YouTubeKit linked into a store-condition
  binary; fixed by generating the store project without the package. Residual: the
  translated strings for this screen ship in the store bundle as text
  resources; the code and the library do not.

## Current release limits and next steps

- PR remains draft; no merge, purchase, signed upload or public release occurred.
- Code uses new immutable `scores-<uuid>.json` references in project metadata.
  Legacy inline scores and earlier `scores.json` remain readable. Explicit
  cleanup removes unreferenced score generations and interrupted exports.
- `ContinuedProcessing` is opt-in via `RK_ENABLE_BACKGROUND_GPU=1` for the
  **store** build, matching app-ID capability/profile, supported GPU and iOS 26.
  Scheduler rejection falls back to foreground. Ordinary background grace must
  be ended when the continuous task launches, and not reintroduced by pause.
- Import from Photos is now an owned cancellable operation; cleanup cannot run
  while the picker is staging a file. Originals/edit metadata remain local.
- The main-branch privacy URL will become valid after merge. Verify policy,
  support contact, screenshots and Store privacy answers with the owner.
- Do NOT promise lossless/60fps/HDR export: current output is SDR/30fps.
- Do NOT claim measured speedups: generator reuse and audio metadata hoisting
  are implemented, but only device benchmarks can establish their benefit.
- Adaptive fast/detailed analysis and AVAssetReader comparison are deferred
  until representative ride footage benchmarks exist; preserve detection quality.
- UI now has library thumbnails and a visual trim sheet, not a complete
  multi-track thumbnail timeline. That richer editor remains a later enhancement.
- A real on-device smoke run is the next release gate after CI: import a local
  HEVC ride, trim, reorder, preview with music, export, save to Photos, relaunch.
  Then test long/HDR footage, low storage and signed-background locking/cancel.

## Validation record (latest checkpoint)

- P0 c9c28c3: native run 38206222424 passed all stages, Xcode 26.3.
- Reliability 391b413: native run 38206639216 and Python run 38206639230 passed.
- UI/background 925b088: native run 38207300070 compiled and was still running
  tests when this entry was written; Python run 38207300047 passed.
- Latest follow-up: serial Photos staging, visible permission Settings action,
  Hebrew catalog, accessibility/input validation, deletion error consistency,
  and concurrent disk-reservation regression test. Run latest-head CI before
  marking this checkpoint verified. `scripts/check-ios-store.py`, shell syntax,
  Python compile and whitespace checks pass locally. Local pytest unavailable;
  Python CI owns execution. No local Xcode/device runtime is available.

- CI follow-up: 38207300070 passed simulator tests for UI/background/storage,
  then its device archive was cancelled by the newer commit (not a code failure).
  5303d9a / 38207757193 failed compiling EditorModel because PhotosPickerItem
  needs SwiftUI imported alongside PhotosUI. Added SwiftUI; rerun latest head.

- FINAL verified checkpoint: native 38207915542 passed all stages and published
  artifact 11728810168. Native log: 9 tests, 0 failures; archive succeeded.
  Latest Python workflow 38207915515 passed. Final metadata/generator/shell/
  Python syntax/whitespace checks passed and working tree was clean before
  this documentation update. Continue with the release/device gates above;
  do not restart implementation or replay already-fixed failures.
