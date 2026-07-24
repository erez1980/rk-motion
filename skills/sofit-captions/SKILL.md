---
name: sofit-captions
description: Fix caption typos in already-made sofit clips without re-transcribing — edits the word text only, preserves karaoke timing, then re-renders the affected clips. Use when the user says a caption is wrong / misspelled, or an English brand name is mangled, in a Hebrew clip. Part of the sofit tool (see /sofit for the full pipeline).
---

# sofit-captions

Correct a caption's TEXT only — never the karaoke timing — then re-render. Episode-wide by
default (a recurring name is wrong in many clips); scope to one clip with a clip_id.

## Home
```
HC=/Users/navotv/src/hebrew-chapters          # repo dir (name kept; brand is "sofit")
PY="$HC/.venv/bin/python"                       # venv python
SOFIT="$HC/.venv/bin/sofit"                     # CLI
LOGO="/Users/navotv/Downloads/logo weekly-01.png"
```
<!-- If the repo/venv moves, update HC. -->

Operates on the saved `<episode>.clips.json` spec (written next to the `clip-N.mp4` files
when they were rendered). Multi-token find (e.g. OpenAI → אופן-איי-איי) merges the token span
so the highlight stays in sync; find matches punctuation/whitespace-insensitively.

## 1. Correct the spec
Use the MCP `correct_clip` tool (renders first, then atomically rewrites the spec), or the library:
```bash
"$PY" - <<'PY'
import json
from sofit import corrections
P="<episode>.clips.json"; d=json.load(open(P)); clips=d["clips"]
n,aff=corrections.correct_clips(clips,"<wrong text>","<right text>")   # +clip_id="clip-2" to scope
print("replaced",n,"in",aff)
if n: json.dump(d,open(P,"w"),ensure_ascii=False,indent=2)
PY
```

## 2. Re-render just the affected clip(s)
```bash
"$SOFIT" --render-from "<episode>.clips.json" --render-clips "<out_dir>" --only clip-N --logo "$LOGO"
```
`--render-from` is the ONLY correction-honoring render path (plain `--render-clips` regenerates
from the transcript and discards fixes — it warns when a clips.json is nearby).

**Always verify with a real rendered frame** (`ffmpeg -ss T -i clip.mp4 -frames:v 1 f.png`) —
a multi-word English brand (e.g. "Thoma Bravo") must stay in reading order, not reverse.
