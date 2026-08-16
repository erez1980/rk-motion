# RK Motion — UI/UX implementation review

Scope: first-time local user selecting a long ride video, reviewing detected
action suggestions, and exporting a short edit.

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
