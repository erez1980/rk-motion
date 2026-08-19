# RK Motion — UI/UX implementation review

Scope: first-time local user selecting a long ride video, reviewing detected
action suggestions, and exporting a short edit.

## Round 4 — native quality and a faster path to a finished movie (2026-08)

- **No more forced 720p.** The pipeline used to downscale everything to
  1280×720@30 before analysis — irreversible quality loss for 4K drone
  footage. A single H.264 file is now used as-is (zero re-encode); other
  codecs are converted once at native resolution; multiple files are
  normalised to the first file's size. Analysis already samples at 160×90, so
  it stays fast regardless of source size.
- **Export quality profiles.** 1080p (default), 720p, source quality, and a
  WhatsApp profile (720p + capped bitrate, ~6× smaller) applied at the
  cut/transition stage. Small sources are never upscaled.
- **Play the edit before exporting.** "נגן את הסרט" plays the selected clips
  in sequence inside the player, skipping between them, with a clip i/n
  indicator — no export needed to judge the edit.
- **Auto-select to a target length.** Pick 30s/60s/2m and one click selects
  the highest-scoring clips that fit, still editable by hand.
- **Sensitivity slider without re-analysis.** The report now carries
  per-second scores; the client rebuilds the clip list at any threshold
  instantly, preserving edits/selection/thumbnails of unchanged clips and
  never dropping manual clips.
- **Manual clip at the playhead** ("קטע מנקודה זו", t−3..t+4) for quiet
  moments the detector deliberately skips, marked ידני.
- **Music volume** (רקע/מאוזן/חזק) replacing the hardcoded 65%.
- **Export history.** Each export gets a versioned file; earlier versions
  stay downloadable in the session, survive page reloads, and are listed
  under the result player.
- Verified: quality caps/no-upscale and the untouched fast path have
  regression tests; sequence playback, slider, manual clips, auto-pick and
  history verified in a browser run (test Chromium lacks H.264 decode, so
  sequence advancing was driven via simulated timeupdate events).

## Round 3 — progress feedback anchored to the flow (2026-08)

- **Status next to the action.** The single global status bar became three
  anchored ones: below the upload area (upload + analysis), inside the music
  studio (uploads, YouTube downloads), and below the export bar (export +
  save). Feedback now appears where the user clicked, in reading order.
- **Real progress with time-remaining everywhere.** Analysis is now an async
  server job (like export) reporting stage messages ("normalising video 2/3",
  "analysing motion and sound") with a size-based estimate; uploads compute
  remaining time from measured throughput; music uploads gained real percent
  (they previously had no progress events at all); YouTube downloads show a
  running timer over an indeterminate bar.
- **The screen follows the flow.** Picking files scrolls to the upload bar,
  a finished analysis scrolls to the clips, adding/attaching music scrolls to
  export, clicking export scrolls to its progress bar, and the finished movie
  scrolls into view.
- **Always-visible busy signal.** The sticky step rail shows a spinning ring
  on the active step while anything runs, so scrolling away never hides that
  work is in progress.
- **Compact YouTube results.** One line per result — title (ellipsized),
  channel · duration, a small listen button and an add button — no thumbnail.
- Verified end-to-end with a synthetic ride video through the real server:
  staged analysis messages with ETA, export with ETA, result playback; browser
  run confirmed anchored bars, busy ring on/off, and no console errors.

## Round 2 — full design refresh (2026-08)

### Design system

- **Single token layer.** The stylesheet previously accumulated four override
  passes (light base → dark redesign → day-mode → contrast pass) with
  `!important` patches. It is now one set of CSS custom properties with a dark
  default and a `body.day` daylight override — every surface reads its color
  from the same tokens in both themes.
- **Local typography.** The broken mid-sheet `@import` of Google Fonts (invalid
  CSS position, and an external request that contradicted the "local
  processing" promise) was replaced by the Rubik variable font already bundled
  with the app, served at `/assets/rubik.ttf`.
- **Refreshed look.** Dark carbon surfaces with a volt-lime accent, pill step
  rail with done/active states, compact product-first hero, card grid
  workspace, and a celebratory result card after export.

### Fixed bugs

- **"Maximum scene length" was ignored:** the input existed but was never sent
  on the batch flow. The client now sends `X-Max-Scene-Length` and
  `/api/analyse-batch` forwards it to `analyse_action`.
- **Multiple music uploads overwrote each other:** every upload was written to
  the same `music.<ext>` path, so "N tracks in sequence" silently played the
  last file N times. Uploads now get unique names.
- **`hidden` attribute was overridden** by component `display` rules, showing
  the YouTube attach button and start slider before any music existed.
- **YouTube result titles were injected via `innerHTML`;** results are now
  built with `textContent` (a malicious video title could previously inject
  markup into the local page).

### UX improvements

- **Clip thumbnails**, captured locally from the already-uploaded source, so
  candidates can be recognised at a glance.
- **Drag-and-drop reordering** using the thumbnail as handle; arrow buttons
  remain for keyboard and touch.
- **Preview stops at the clip's end** instead of playing on into the video,
  and the timeline gained a live playhead, current/total time readout and
  click-to-seek.
- **Editing a clip's times regenerates its thumbnail** and invalidates the
  stale download.
- **Music track list** shows every added track with order, duration, source
  (computer/YouTube) and a pending state until a YouTube track is attached;
  the soundtrack start slider covers the total of all tracks.
- **Export result card** plays the finished movie inline next to the download
  action; export requests no longer carry thumbnail data.
- **Mobile:** single-column workspace, two-row clip layout with larger
  thumbnails, sticky export bar, full-width primary actions.
- **Accessibility:** status is a polite `role="status"` live region, Escape
  closes the YouTube modal, Enter submits the search, visible focus rings on
  all controls, and `prefers-reduced-motion` disables animation.

## Verification performed

- Full test suite: 106 passed, 10 skipped.
- Served page, logo and font locally; byte-range streaming unchanged.
- Screenshotted dark, day, workspace and mobile layouts via headless Chromium
  with a canned report (`window.__rkDebugLoad`); no console/page errors.
- Confirmed `hidden` elements stay hidden and the export button is enabled
  only with a selection.

This is an implementation review, not a replacement for usability testing with
real riders. The next validation should be a short session with 2–3 riders and
their own GoPro footage.
