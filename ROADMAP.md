# sofit roadmap

Feature ideas, grounded in what's actually working for short-form social video
(hooks, retention, captions). Research basis: `/last30days` run 2026-07-25 on
short-form hooks/retention/captions (raw: `~/Documents/Last30Days/short-form-video-hooks-retention-and-captions-raw-v3.md`).

The through-line from the research: **the first 1-3 seconds decide the clip, most
viewers watch on mute, and word-by-word captions are the retention tool.** sofit
already does the caption part; the gap is the hook.

## Already shipping (keeps us on the current meta)
- **Word-by-word / karaoke captions** - Rubik-Black, white + outline, lower-middle
  third, per-word highlight. This is the most-used 2026 style; no change needed.
- **Hook-aware clip selection** - `make_quotes` gates on a hook score and a length
  floor. Foundation for the upgrade below.
- **Speaker-tracking face crop + logo** - clean, un-flashy visual layer. Working
  editors say story + hard cuts beat flashy VFX, so this stays deliberately simple.

## Done (2026-07-25)

### 1. Caption-first hook card ✅
Each clip's `hook` is burned large, bold, high-contrast in the upper third for the
opening ~1.8s, so a muted scroller (~85% of short-form viewers) is stopped by the frame
rather than a spoken line. Rides the existing per-frame Pillow pass (no extra encode),
RTL-correct, wraps and caps at 12 words. On by default; `--no-hook-card` / `hook_card=False`
turns it off. Verified on a real WS203 render: card at t=0.6s, gone by t=3.5s with the
karaoke caption resuming.
- `render.py` (`_burn_captions_pillow`, `extract_clip`, `render_clips`), `cli.py`, `mcp_server.py`

### 2. Hook scorer: reward the unanswered question ✅
`make_quotes` now explicitly instructs and scores for a **curiosity gap** - a hook that
raises a question the clip has not yet answered - and scores highest when the hook is the
very first thing said rather than buried after throat-clearing. Payoff must close the gap.
- `generate.py` (`make_quotes` system prompt)

### 3. Default clip length 20-45s ✅
`max_sec` default 90s → 45s, matching the researched sweet spot (21-34s highest
engagement, 20-45s for podcast clips). Still overridable per call.
- `generate.py` (`make_quotes`)

### 4. Hook is a first-class, editable field ✅
Falls out of #1: the card renders from the clip spec's `hook`, so testing a different hook
is a one-line edit to the clips.json plus `--render-from ... --only clip-N` - no
re-selection, no re-transcription.

## Proposed (next)

### 5. Retention-shaped clip trimming
Nothing currently enforces that the *strongest line* is at t=0 after the moment is picked -
the hook sentence can start a beat late. Consider snapping `start` to the first word of the
hook sentence so second zero is the hook.

### 6. Hook variants
Generate 2-3 alternative hook lines per clip so a creator can A/B them against the
platform's retention curve (the research's core improvement loop). Would need a
`hook_variants` field in the spec plus a render flag to pick one.

## Explicitly NOT doing
- Flashy transitions / VFX / animated backgrounds. Multiple senior editors flag these
  as dating fast and distracting from story. Keep the visual layer minimal.
