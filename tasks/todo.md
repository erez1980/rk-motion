# Narrative clips (multi-segment edits)

Problem: clips are one contiguous window around a hook. Real short-form editing
removes filler INSIDE the moment (WS205 clip-2 needed a manual 16s banter cut).
The tool should build a story — hook beat → escalation → payoff — cutting the
dead air between beats.

## Plan

- [x] `generate.py`: CLIP_RULES/CLIP_FIELDS ask for `beats` (1-4 verbatim quote
      spans forming one story); `Quote.beats`; `resolve_clip_item` resolves each
      beat (hook-snap on first, chronological, merge <1s gaps, per-beat min 3s,
      total 20-45s); `make_clips` emits `segments` (each own words) when >1 beat.
- [x] `render.py`: `render_clips` renders each segment via the existing
      single-range path (hook card first segment only, face-track per segment),
      then losslessly concats. Extract `_render_one_range` helper.
- [x] `corrections.py`: `correct_clips` walks segment words too.
- [x] skill `clips.py`: pool schema + rows carry beats; build emits segments;
      table shows cuts.
- [x] Tests: resolve beats, corrections over segments, concat render smoke.
- [x] Verify on WS205: rebuild clip-2's moment as a narrative edit, frame-check.

## Review

- Spec: clip MAY carry `segments: [{start, end, words}, ...]` (absolute times,
  words relative to each segment's start). Legacy single-range clips unchanged;
  top-level start/end = envelope.
- Concat is stream-copy (segments share codec settings) — no quality loss.
- Hook card: first segment only. Face-track runs per segment (camera can move
  between beats).
- corrections: multi-token finds can't span a cut (span merge across segments
  would corrupt timing) — acceptable; typos live inside sentences.
