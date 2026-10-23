# Automatic studio — engineering handoff

## Scope and baseline

Owner: Erez. Latest requirements: implement the entire 10 general + 20 AI
roadmap as one-tap, automatic actions; preserve all code and the complete plan
in GitHub so Claude Code can continue. The product must process on iPhone.
No prompt, music picker, face selection, trimming or output configuration is
a required step of the new flow. Initial media choice and OS permission are
unavoidable inputs, not editing steps.

Base: `b60e818` on main (0.32.0). Initial implementation commit: `4b9a15e`; later compatibility/validation commits are on the same branch.
PR: https://github.com/erez1980/rk-motion/pull/21. Branch: `codex/automatic-studio`, app 0.33.0.
The owner explicitly authorized merging when validation is complete on
2026-10-23. Keep the continuation branch available after merging. The main
branch's existing workflow publishes an unsigned IPA after a successful build;
that release is not proof of physical-device installation. The detailed 30-row status and
continuation order are in [AUTOMATIC_STUDIO_PLAN.md](AUTOMATIC_STUDIO_PLAN.md).
The historical full product research is also committed, including sources.

## Working implementation

- Project **Make my movie**: one owned cancellable operation, using existing
  local analysis or scanning when necessary, measured event selection,
  optional local image assessment, automatic dominant-person weighting,
  recipe, local soundtrack, deterministic critic, export, media validation,
  persistence and optional Photos save. Denied Photos permission leaves a
  usable movie in the project. No YouTube download or model download occurs.
- Home **Automatic movie from last month**: existing Recap chooses assets,
  imports/analyzes and chains directly into the movie action. It navigates to
  the project and skips the post-analysis explanation sheet automatically.
- **Three stories** produces distinct action/cinematic/family clip choices
  and recipes, not only three lengths. Generated soundtracks are per recipe.
  Completed outputs survive a later cancellation/error; Photos permission is
  requested once and the successful outputs are saved together.
- Existing local music is preferred. Otherwise `AutomaticMusic` generates a
  bounded-block PCM instrumental with chord changes/build-up/fades. This is
  procedural DSP, not an invented neural music-generation implementation.
- Manual source intervals are retained; whole measured event windows are
  selected. `preserveEvents` disables beat-end mutation. The new focus path
  is velocity limited; beat zoom currently takes precedence over that path.
- Preferences stay in UserDefaults. Explicit one-tap style choices teach a
  preferred style; a human-edited export can teach settings. Automatically
  generated output does not teach itself or implicitly act as positive feedback.
- Versions survive process restarts. One button restores the previous distinct
  edit; up to twenty snapshots are retained. There is no branch browser yet.
- Backup is a ZIP of sources, music, scores, edit, analysis and sidecars, with
  SHA-256 checksums. It intentionally omits rendered exports. Restore verifies
  paths, entry types, CRC, byte budgets and checksums, then publishes under a
  fresh UUID. Existing projects cannot be overwritten. Backup files live under
  the originating project so project deletion also removes internal copies.
  Backup enforces the same entry/byte/sidecar limits as restore before copying
  large sources and again before publishing, so it cannot knowingly produce
  a package that exceeds the restore contract.
- Visual replay uses a bounded number of native Vision feature prints, a
  distance threshold and an ambiguity margin. It exports a matched pair side
  by side. This is a heuristic visual comparison, not verified same-location
  reconstruction, route matching or a 3D ghost.
- Two-camera mode requires actual correlated source audio. It rejects silence,
  ambiguous periodic matches and unsupported sources. Supported first source
  duration is 3–600 seconds, start offset +/-30 seconds, at most five reference
  projects. It creates a short alternating-angle edit, retaining first-camera
  sound. It does not choose angles with a trained narrative/action model yet.
- Evidence notes contain source filenames, SOURCE time ranges and measured
  event labels. Joined/repeated source offsets are converted from the project
  timeline into each file's own time; this conversion leaves the edit unchanged. They are not movie-time SRT subtitles or speech transcripts.
  A coverage suggestion is generated from available event reasons.

## File map

| File | Responsibility |
|---|---|
| `AutomaticDirector.swift` | Recipes, typed events, selection, whole-event constraints, critic, focus smoothing, local taste |
| `AutomaticVision.swift` | Optional image-assisted boundary review; bounded visual matching |
| `AutomaticMusic.swift` | Original offline PCM composer, bounded buffers, cancellation |
| `AutomaticInsights.swift` | Evidence notes/coverage suggestion and conservative audio alignment |
| `AutomaticComparison.swift` | Real AVFoundation split-screen/alternating-angle export |
| `AutomaticMulticam.swift` | Find an audio-synchronized reference in local projects |
| `AutomaticStore.swift` | Run receipts, versions, offline preflight, hashing, ZIP package, media validation |
| `AutomaticPackage.swift` | Safe streaming extraction, integrity checking, new-ID restore |
| `AutomaticStudioView.swift` | One-tap actions and optional evidence/package sharing |
| `EditorModel.swift` extensions | Operation ownership, progress, save/rollback, Photos, gallery chaining |
| `LocalEngine.swift` | Preserve event boundaries; automatic focus path; source gain |
| `AutomaticDirectorTests.swift` | Selection/critic/taste/limits plus real media, cancellation and package roundtrip tests |
| `AutomaticStudioUITests.swift` | One-tap UI flow, no music/settings screen |

The generated Xcode project and Package.resolved are committed. The added
runtime dependency is ZIPFoundation **0.9.20**, pinned exactly; YouTubeKit
remains pinned at 0.4.9. Their complete MIT notices are included in the app
bundle as `ThirdPartyNotices.txt` through the generated resource build phase.

## Build and validation

Local environment: Xcode **27.1**, Swift **6.4**, iPhone 18 Pro **simulator**,
iOS **27.0**. No physical iPhone, thermal/battery benchmark or live on-device
Foundation Models image inference was used to certify this implementation.

Completed full run before the last bounded-import defensive guards:
**166 unit tests + 5 UI tests passed**. A further actual rendered-angle test
passed individually. The final focused automation rerun passed **19 tests**, including a sparse
32-GiB source, oversized-JSON rejection and joined/repeated-source evidence
time regressions; the Release device
archive and unsigned IPA packaging also passed. Results and IPA checksums are recorded in `docs/validation/automatic-studio-2026-10-23.txt`.
The added tests cover whole event retention, manual intervals, speech endings,
quiet aesthetic moments, invalid/duplicate repair, missing/nonfinite inputs,
focus velocity, preference feedback, score PCM/cancellation, real media export,
persistent versions, real ZIP roundtrip/corruption/path rejection and actual
side-by-side/alternating-angle rendering. The UI test taps Make my movie and
waits for the completion without visiting music or settings.

```sh
python3 scripts/generate-ios-project.py
python3 scripts/check-ios-store.py
xcodebuild -project ios/RKMotion.xcodeproj -scheme RKMotion \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  CODE_SIGNING_ALLOWED=NO test
bash scripts/build-ios.sh unsigned
```

Debug-only `-RKSkipAutomaticPhotos` skips Photos permission in the automatic
UI fixture test. It is not compiled into Release behavior. Existing
`-RKUITestFixture` creates synthetic footage and avoids personal media.

The new image attachment/guided assessment is conditional on compiler 6.4+
and iOS 27+, with `SystemLanguageModel.default.isAvailable`. Earlier Xcode/OS
builds use measured events without this optional assistance. A simulator pass
cannot prove that model inference works on a physical phone. The image model
is always the explicit system on-device model; there is no PCC fallback.

## Known limits and next work

- This does **not** complete all 30 research proposals. The active plan explicitly
  lists partial/research status; do not erase that distinction in release notes.
- Measured event windows are not a trained full temporal action graph. The
  optional model examines only three frames of up to four candidates; it may
  miss a jump or hallucinate a boundary. It can extend by at most two seconds
  and never cross a source boundary. Validate with real annotated footage.
- No new egomotion model, physiological analysis, neural source separation,
  Hebrew speech transcription, technique coach or live event-recording camera
  has been implemented. Those need dedicated assets/data/device verification.
- No HDR preservation, high-frame-rate output or complete progressive rough-cut
  pipeline has been added. Current automatic contract is SDR/30fps/1080p.
- Visual/audio thresholds are conservative experimental heuristics, not
  calibrated probabilities. Real group recordings, same-route footage and
  bad/absent audio need device datasets and quality measurement.
- Sparse person detections can miss subjects and do not preserve an obstacle's
  meaning. Auto framing should be tested across source seams and transitions.
- Library import/iCloud retrieval and OS permissions can still require network
  or user approval. Once media are local, the core flow is designed for offline.
- The package limit is 512 regular entries / 32 GiB total / 32 MiB per JSON
  sidecar. Duplicate basenames, symlinks, traversal and malformed layouts are
  rejected. Test device disk pressure and cross-device restore next.
- Do not add a fake working button for an unavailable research capability.
  Implement the capability, expose real eligibility, test failure behavior,
  and update the 30-row plan with proof.

## Required physical-device gate

Install a properly signed IPA, grant Photos permissions, make a monthly recap
and a movie from real action/family footage, verify Photos/playback/relaunch,
then cancellation, background interruption, low storage, offline operation,
4K/HEVC mixed input and long runs. Test paired cameras with shared sound and
truly repeated locations. Record iPhone model, OS, free storage, peak memory,
thermal state, elapsed time, battery change and quality failures. Retain all
originals. An unsigned archive is a build artifact, not proof of installation.

## CI toolchain compatibility

The first Xcode 26.3 CI run (`40017702228`) found a Swift 6.2 type-checking
complexity error in event ranking, despite successful Xcode 27.1 builds. The
map/sort tuple expression was split into a named RankedSecond and explicit
loop/sort with unchanged scoring. The branch contains this compatibility fix.
Latest CI status is visible on PR #21; do not treat the old failed SHA as the
current implementation.
