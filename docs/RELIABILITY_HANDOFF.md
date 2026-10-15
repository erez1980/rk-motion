# RK Motion reliability pass (F01–F11) — handoff

Separate from `APP_STORE_HANDOFF.md`, which records the earlier App Store work.
This file covers only the 2026-10-15 reliability review (findings F01–F11,
against main `268b2a1`, iOS 0.20.0). Branch `claude/project-thread-k63xed`,
PR #6. App version on the branch: **0.20.1**.

## Ground rules kept

- Every analysis, edit and export stays on the iPhone. Nothing moved to a Mac
  or a server; no account was added.
- Personal distribution with YouTube stays as is. No App Store work, no
  purchase, no Apple credentials.
- Earlier fixes kept intact: exact composition time coverage, the fade's
  last-frame check, atomic writes with separate scores files, chronological
  clip order, merged activity windows. The player fix is not a redesign.
- Simulator and Mac numbers are **not** iPhone measurements.

## Findings

| # | Status | Commit | Code | Regression tests |
|---|---|---|---|---|
| F01 one owner per AVPlayerItem, stable player | fixed | a31d8b2 | `ios/RKMotion/PreviewPlayback.swift`, `LocalEngine.previewEdit` | `PreviewPlaybackTests`, UI `testRepeatedTapsOnTheEditPreviewKeepTheAppAlive` |
| F02 lifecycle save resurrecting deleted exports/songs/projects | fixed | 95e3e6b | `ProjectPersistence.swift` (deleted/retired sets, test gate) | `LifecycleSaveTests` (barrier interleavings via `WriteGate`) |
| F03+F04 import ownership, cancellation, staging, recovery | fixed | bd5640f | `LocalStore.copy/ImportManifest/recoverImports`, `EditorModel.runImport` | `ImportTests` |
| F05 YouTube transport | fixed (transport); live download is a device gate | 46ed5d5 | `YouTubeMusic.fetch/contentRange/stream` | `YouTubeTransportTests` (mock URLProtocol, 10 cases) |
| F06 whole video, beat-edge policy, real length | fixed | 96d8938 | `LocalEngine.syncsToBeat/plannedLength`, `Beats.synced`, Export step length | `BeatPolicyTests` |
| F07 one clip limit | fixed | 168fbe9 | `Edit.clipLimit = 500` | `ClipLimitTests` |
| F08 thumbnails | fixed | 9cece70 | `Thumbnails.swift`, lazy Home list | `ThumbnailTests` |
| F09 layout direction by language | fixed | a0e28cf | `AppLanguage.swift` | `LanguageDirectionTests`, UI `testLayoutFollowsTheLanguage` |
| F10 action-render pixel format (desktop) | fixed | b6f0424 | `src/sofit/action.py` | `test_action_render_writes_yuv420p_from_a_444_source` |
| F11 concurrent download cache (desktop) | fixed | d51b177 | `src/sofit/feed.py` | three tests in `tests/test_feed.py` |

Also: 9613a5e makes the "New ride" and "From YouTube" tiles respond to a tap
anywhere on them (reported from the simulator).

### Policies worth knowing

- **Beat sync (F06).** Whole-video projects are never beat-synced. For clip
  edits a clip's start never moves; its end may grow only up to the next
  clip's start in the source (or the source end), and clips that already
  overlap may only shrink. The Export step shows the length that is really
  exported.
- **Interrupted imports (F04).** On launch, sources in folders without a
  `project.json` that still play are rescued into projects. Nothing is deleted
  blindly; leftover fragments are only reported, and removed when the user
  runs "clean temporary files" (which rescues first).
- **YouTube (F05).** Downloads stream to a file, capped at 512 MB. Each 206
  must match the requested offset and a consistent total; a 200 mid-download
  restarts the file from zero; anything else stops with a clear message and
  removes the partial file.

## Verification

- Python: `pip install -e '.[dev]' pytest 'mcp<2'` then `pytest` — passes
  (209 before this work, plus 4 new).
- Native: `.github/workflows/ios.yml` (Xcode 26.3, simulator) runs the unit
  tests, the UI tests in `ios/RKMotionUITests` and builds the unsigned IPA.
  See PR #6 checks for the latest run.
- UI tests launch with `-RKUITestFixture` (Debug only): the app makes its own
  4-second ride and imports it like a picked video, so tests need no Photos.

## Still needs a real iPhone

Nothing below was done; no device was available.

1. Install the IPA from the PR's `RK-Motion-unsigned-IPA` artifact (signing
   with the owner's own profile).
2. Smoke path: import → analyze → trim/reorder → music + preview → export →
   Photos → relaunch.
3. Cancel during import and during export; send to background mid-export;
   run with low free storage.
4. A live YouTube search + download on the device (F05 gate).
5. Hammer the edit preview (F01) and check memory/thermal on a long ride.
