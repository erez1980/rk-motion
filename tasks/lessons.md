
## 2026-08-08 — Clips must be edits, not windows
User: "don't just cut a clip in the right length around a hook, build a
narrative." A contiguous window around a hook keeps the filler between hook
and payoff (WS205 clip-2 shipped with 16s of banter that needed a manual
ffmpeg cut). The selection prompt must ask for BEATS (kept spans) and the
renderer must cut the gaps. Signal to watch for: any manual post-render
trim means the selector failed — feed that back into the pipeline instead
of repeating the manual fix.
