---
name: sofit-transcribe
description: Transcribe a Hebrew podcast episode (Weekly Sync) locally with faster-whisper (ivrit-ai model) for the sofit toolkit — audio never leaves the machine, cached by file hash. Use when the user wants to transcribe a Hebrew episode, or as the first step before chapters/show notes/clips. Part of the sofit tool (see the /sofit skill for the full pipeline).
---

# sofit-transcribe

Local, private transcription — the one-time slow step every other sofit service depends on.

## Home
```
HC=/Users/navotv/src/hebrew-chapters          # repo dir (name kept; brand is "sofit")
PY="$HC/.venv/bin/python"                       # venv python (faster-whisper, ivrit-ai)
```
<!-- If the repo/venv moves, update HC. -->

## Run (long — always background)
~real-time on CPU (a 60-min episode ≈ 20-35 min). Cached by file hash + model + version,
so it's one-time — re-runs and every downstream service (chapters, clips) are then instant.
```bash
nohup "$PY" -c "from sofit.transcribe import transcribe; import sys; print(len(transcribe(sys.argv[1])))" "<episode.mp4>" > /tmp/sofit_tx.log 2>&1 &
```
- Do NOT block on it — set a background wait, continue, and report when it lands.
- Progress/result: `tail /tmp/sofit_tx.log` (prints the segment count on success).
- Default model is the Hebrew-tuned `ivrit-ai/whisper-large-v3-turbo-ct2` (first run downloads ~1.6 GB).

Once cached, hand off to `/sofit-kit` (text) or `/sofit-clips` (social clips).
