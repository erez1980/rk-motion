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

---

## Round 5 — leave it alone, come back when it's done

Three problems reported from real use on a Mac and an iPhone.

- **Nothing told you the job had ended.** Analysing and exporting run for
  minutes on the server, so people kept the tab open and checked back every
  few minutes. The header now has a bell: when a job finishes (or fails) the
  page chimes, buzzes, flashes the tab title and — where the browser allows
  it — raises a system notification naming what finished. The chime and the
  title flash need no permission, so something always lands; the audio
  context and the permission prompt are armed from the tap that starts the
  job, which is the only moment a browser accepts either.
- **Saved to the iPhone home screen, the app had no icon.** There was no
  `apple-touch-icon` and no manifest, so iOS invented one from a screenshot.
  Added square, fully opaque 180/192/512px icons derived from the desktop
  icon (`packaging/make_web_icons.py`) plus a web manifest — transparency and
  rounded corners are left to the platform's own mask, otherwise the corners
  come back white. Launched from the home screen the page now runs
  full-screen, with the sticky header padded clear of the notch.
- **A "?" box sat next to the logo.** The theme toggle drew a sun/moon with
  `☀`/`☾`, symbol characters no bundled font covers, so they fell through to
  a missing-glyph box. Both toggles are inline SVG now, and a test fails if
  any symbol character reappears in the header.

## Verification performed

- Full test suite: 130 passed, 1 skipped.
- Drove a real analyse-then-export in headless Chromium against a generated
  ride video: both alerts fired with the right Hebrew text, the tab title
  flashed while the page was hidden, no console or page errors.
- Checked every `/assets/` path the page links resolves, and that anything
  outside the whitelist 404s.
- Header at 1280px, iPhone 13 and iPhone SE: SVG icons only, 46x44 tap
  targets on mobile, no horizontal overflow.

---

## Round 6 — "is it doing anything?"

Reported while converting an iPhone clip: *"is there a reason this step is
really long and has no progress time? I can't tell if it's doing anything."*
The message on screen was **"ממירה את הסרטון לפורמט תואם, באיכות מלאה… · עוד
רגע…"** — for minutes.

Both halves of that were real defects.

- **The bar was guessing.** Every long step drew `elapsed ÷ up-front-estimate`,
  clamped to 97%. Once the estimate ran out — which is exactly what happens on
  the footage that takes longest — the bar froze near full and the ETA
  degraded to "עוד רגע…" forever. It now asks ffmpeg where it actually is
  (`-progress`), and the motion/sound scan reports the second it is reading.
  Time left is re-measured from the step's own speed, so the number converges
  instead of expiring. Steps are weighted by their expected cost, so one bar
  covers preparing the source and scanning it without ever going backwards.
- **The step really was slow, and avoidably so.** iPhones record HEVC, so
  every iPhone upload hits a full libx264 re-encode of the whole ride — the
  single most expensive thing the app does. Macs have a dedicated encoder
  chip; a one-frame probe now picks `h264_videotoolbox` when it genuinely runs
  on this machine, with decode acceleration on the way in and libx264 as the
  fallback everywhere else. Quality is held by targeting above the source's
  own bitrate, since the hardware encoder has no CRF knob.

Exporting had the same defect one step later — a single message and the same
expiring guess — so it now reports a real fraction across all of its passes
(cut each clip, mix music, fade the tail), weighted by cost.

## Verification performed

- Full test suite: 137 passed, 1 skipped.
- Real HEVC ride through the browser: the bar climbed 1% → 100% with a
  countdown that converged (50s → 1s), across conversion and scan, no console
  errors. Same for a real export.
- Multi-clip batches keep one climbing bar instead of restarting per file.
- Checked the bar is monotonic in every path, and that a failed ffmpeg still
  surfaces its stderr for the status message.

---

## Round 7 — the stranded bar, and encoding on the GPU everywhere

- **The bottom action bar was sitting mid-screen** on an iPhone. It could not
  be reproduced in a desktop browser at any iPhone viewport or scroll
  position, but the screenshot's scroll indicator showed a live viewport, not
  a stitched full-page capture — so the bar really was stranded. The cause
  that fits is the iOS keyboard: tapping a clip's time field shrinks the
  *visual* viewport, which moves `position:fixed` elements, and iOS routinely
  leaves them where the keyboard put them after it closes. The bar now pins
  itself to the visual viewport, so it rides above the keyboard while typing
  and snaps back after. `body`'s horizontal-overflow guard also moved from
  `hidden` to `clip`, since `hidden` can turn the body into a scroll container
  on iOS and that is another way a fixed child stops tracking the viewport.
- **Encoding now uses the GPU on every platform**, not just macOS. The probe
  walks a per-platform candidate list — VideoToolbox on Macs, NVENC / Quick
  Sync / AMF on Windows, NVENC / Quick Sync on Linux — running a tiny real
  encode on each, because being listed by ffmpeg says nothing about whether
  the driver is there. It covers the export too, not only the source
  conversion: the quality profiles now carry a bits-per-pixel target next to
  their CRF, since GPU encoders have no CRF knob. If a GPU encode fails
  anyway — a driver refusing a resolution the probe never tried — that one
  command is retried on the CPU and the GPU is not used again this session,
  because losing a ten-minute export to a driver hiccup is far worse than
  spending the extra minutes in software. The chosen encoder is printed at
  launch and shown on hover over the version chip.

## Verification performed

- Full test suite: 149 passed, 1 skipped.
- Action bar measured through a simulated keyboard open/close cycle: rests at
  the bottom, lifts by exactly the keyboard height, snaps back cleanly, no
  leftover transform.
- Real exports at 1080p 16:9, original 9:16 and WhatsApp: correct frame sizes
  (including the 1080x1920 crop), correct duration, closing fade intact.
- Encoder selection, the software retry and the command rewrite are covered by
  unit tests with a mocked ffmpeg — this container has no GPU, so the hardware
  branch itself is exercised there rather than on real silicon.

---

## Round 8 — the movie could not get off the phone

Reported: *"after the encode finishes I press Download MP4 and nothing
happens, a browser opens with a white window."* Self-inflicted, in two steps.

Round 5 added **Add to Home Screen** with `display: standalone`, so the page
ran chrome-less on the phone. An installed iOS web app has no download
manager, so `<a download>` does nothing there — and the guard added for that
opened the file in a new tab instead. The export was served with
`Content-Disposition: attachment`, which a tab cannot render. Hence the white
window.

- **The home-screen app runs in Safari again** (`display: browser`, no
  `apple-mobile-web-app-capable`). The icon — which is what was actually
  asked for — still works; the browser chrome that comes with it is what makes
  saving the movie possible at all. Nothing is lost: notifications in an
  installed iOS app need a secure context, which plain http over the LAN was
  never going to be.
- **The movie is served inline.** `<a download>` already names the file for a
  real download; the attachment header only broke every other way of opening
  it.
- **Saving now tries the system share sheet first**, since its *Save Video* is
  the only route that reaches the photo gallery. It needs a secure context —
  present for the app on this computer, absent over plain http on the LAN —
  so the button names what it will actually do on this device, and the result
  card explains the Files → Photos step where that is the path.

## Verification performed

- Full test suite: 151 passed, 1 skipped.
- Real export driven to completion twice in a mobile browser: with file
  sharing available the finished 2.9MB MP4 reaches `navigator.share` as a
  typed `File` and the page stays put; without it, a normal download with the
  right filename, no new tab, no navigation.
- Checked the response carries `Content-Type: video/mp4` and no
  `Content-Disposition`.

---

## Round 9 — HTTPS for the phone

Saving a movie into the phone's camera roll goes through the system share
sheet, and browsers only offer that to a secure page. `http://127.0.0.1`
already counts as secure, so the app on this computer was fine; a phone
reaching the machine by its network address was not, and got a plain download
into Files instead.

LAN mode now serves HTTPS. The certificate is generated on this machine and
kept in `~/.rk-motion`, reused across launches so a phone that accepted it
once is not asked again, and regenerated when the network address changes or
it ages out. It names `localhost`, `127.0.0.1` and the current network
address, because Safari rejects a certificate that does not name the address
that was dialled before the accept-once prompt is ever shown, and it lives 397
days because Apple refuses server certificates valid for longer.

Two listeners rather than one: plain http bound to the loopback address for
this machine (no certificate warning where none is needed) and HTTPS bound to
the network address for phones — same port, different interface. Certificates
come from `openssl` where it exists, falling back to the `cryptography`
package, which is now bundled so Windows gets HTTPS too. If neither is
available the app still starts; only phone access is off, and it says so.

## Verification performed

- Full test suite: 158 passed, 1 skipped.
- A real dual-listener run: index, capabilities, manifest, icons and a
  **byte-range request** (206, which video playback needs) all served over TLS
  from the network address, while the loopback http listener kept working.
- **A page loaded over this certificate reports `isSecureContext: true`** —
  the open question when this was proposed, and the whole point of the change.
  Notifications and Wake Lock are exposed to it. The share sheet itself is
  Safari-on-iOS behaviour that cannot be exercised in this container; what is
  proven here is the secure context it is gated on.
- Certificate contents checked with `openssl x509`: right subject alternative
  names, right validity window, key written 0600.
- A deliberately broken `cryptography` install falls through to `openssl`
  instead of taking the app down — its Rust bindings raise something that does
  not derive from `Exception`, so the guard had to go wider.

---

## Round 10 — a downloader that is not part of the edit

Asked for: search YouTube, take it as MP3 or MP4, save it on the phone.
Deliberately separate from the soundtrack picker — that one attaches a track
to an edit and is buried in the music studio; this one hands back a file and
nothing else.

- Its own card on the main page, **folded away by default** so the three-step
  ride flow stays the first thing on screen, and hidden entirely without
  `yt-dlp`.
- Each result carries **MP3** and **MP4** buttons. The download runs as a
  background job with the same progress contract as everything else: a real
  percentage, read out of yt-dlp's own byte counts, and a chime at the end.
- Files are served **inline**, so the finished download goes through the same
  share-sheet save as an exported movie — a phone can put an MP4 straight in
  Photos. The shared file is typed from its extension, so an MP3 arrives as
  audio rather than pretending to be video.
- The result row now wraps on a narrow screen: two format buttons left a phone
  almost no room for the title, and picking the right video matters more here
  than it does for background music.
- The search itself is shared with the soundtrack picker rather than copied —
  the two differ only in what the buttons on the right of a row do.

## Verification performed

- Full test suite: 167 passed, 1 skipped.
- A stand-in `yt-dlp` on PATH exercises the real subprocess plumbing — the
  progress template, the client fallback chain, the file that comes out —
  since YouTube itself is not reachable from a test.
- Whole flow driven in a mobile browser: search, MP4, save (arrives at the
  share sheet as `video/mp4`), then MP3 of another result (`audio/mpeg`).
  Rights confirmation gates the request before anything is posted; a made-up
  video id never reaches the command line.
- Titles fully readable at 320px and 390px, no horizontal overflow.

---

## Round 11 — the save button, again

Still nothing on tap. The cause is a rule I got wrong: `navigator.share` only
runs while the tap is still "live", and the click handler awaited a `fetch`
for the file before calling it. That spends the activation, and WebKit then
refuses the sheet with `NotAllowedError` — after which the code fell through
to a navigation that looks, from the outside, like nothing happening.

The file is now pulled into memory the moment an export or a download
finishes, so the tap only has to hand over something already in hand and
`share` is reached with no `await` in front of it. A refused share no longer
disappears either: it names the error on screen and the next tap does a plain
browser download.

Chromium keeps activation alive across a short await, which is why the browser
test passed the first time and why one cannot catch this. The guard is on the
code's shape instead — nothing may be awaited between the tap and the sheet —
and it fails on the version that shipped.

## Verification performed

- Full test suite: 168 passed, 1 skipped.
- Share reached with `navigator.userActivation.isActive === true`, carrying the
  right file and type.
- A refused share shows its error name, relabels the button, and the next tap
  downloads the file for real.
- The shape guard fails when the awaited fetch is put back.

**Not verified here:** whether iOS Safari now opens the sheet. This container
has no WebKit, and Chromium does not enforce the rule that broke it. What is
proven is that the pattern WebKit requires is the one now in the code.
