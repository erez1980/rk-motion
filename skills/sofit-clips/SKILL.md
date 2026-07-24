---
name: sofit-clips
description: Make captioned vertical (9:16) social clips from a Hebrew podcast episode (Weekly Sync) with sofit — suggest candidate moments, let the user pick, then render with speaker-tracking face crop, word-by-word Hebrew captions, and the Weekly Sync logo. Use when the user wants social clips / reels / shorts / TikToks from an episode. Part of the sofit tool (see /sofit for the full pipeline).
---

# sofit-clips

Episode → picked moments → captioned 9:16 clips. Suggest → user picks → render (never auto-render the whole pool).

## Home
```
HC=/Users/navotv/src/hebrew-chapters          # repo dir (name kept; brand is "sofit")
PY="$HC/.venv/bin/python"                       # venv python
SOFIT="$HC/.venv/bin/sofit"                     # CLI
SKILL=~/.claude/skills/sofit                    # holds clips.py (shared with /sofit)
LOGO="/Users/navotv/Downloads/logo weekly-01.png"   # Weekly Sync wordmark (transparent PNG)
```
<!-- If the repo/venv moves, update HC. -->

Needs the transcript cached (run `/sofit-transcribe` first if not).

## 1. Candidate pool → user picks
```bash
"$PY" "$SKILL/clips.py" pool "<episode.mp4>"          # writes <episode>.pool.json + a numbered table
```
Present the table; ask which numbers to render. Build the spec from the picks:
```bash
"$PY" "$SKILL/clips.py" build "<episode.mp4>" "<episode>.pool.json" --pick 2,4,7
```

## 2. Render the picked clips (slow — background)
```bash
"$SOFIT" --render-from "<episode>.clips.json" --render-clips "<out_dir>" --logo "$LOGO"
```
- Crop-to-fill 9:16, speaker-tracking face crop, bold Hebrew word-highlight captions, logo top-left.
- Output `<out_dir>/clip-N.mp4` (ids match the pool numbers). Copy to ~/Downloads as `WS<episode>_clip-N.mp4`.
- Per-frame Pillow caption pass ⇒ seconds+ per clip; run in background.
- Set-once logo: `export SOFIT_LOGO="$LOGO"` (then `--logo` optional). `--logo-pos {top-left,top-right,bottom-left,bottom-right}`.
- This `--render-from` path is the ONLY one that honors caption fixes (`/sofit-captions`); plain `--render-clips` regenerates from the transcript.

## Gotchas (learned the hard way)
- **Verify with a real rendered frame** — `ffmpeg -ss T -i clip.mp4 -frames:v 1 f.png` and look. Especially Hebrew RTL.
- **Face crop** needs the `crop` extra (opencv, installed); holds through rapid cuts (won't chase every camera cut); falls back to center if no face.
- **Two-person / wide shots**: only one person fits a 9:16 crop — set a clip's `focus` [0,1] in the clips.json to override.
- To fix a caption typo → `/sofit-captions`. To cut a moment out of a finished clip → `/sofit-trim`.
- Write the social copy in Navot's voice via `/nabot` (not here).
