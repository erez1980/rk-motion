# hebrew-chapters

Auto-generate **chapters**, **show notes**, and **pull-quotes** for Hebrew
podcasts (mp3 or mp4) — locally transcribed, so your audio never leaves your
machine.

Transcription runs on [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
(no file-size limit, free, private), defaulting to the Hebrew-tuned
[`ivrit-ai/whisper-large-v3-turbo-ct2`](https://huggingface.co/ivrit-ai) model —
which transcribes Hebrew far better than stock Whisper. A small text transcript then
goes to Claude, which writes the chapter titles and notes in natural Hebrew for
pennies per episode.

## Install

```bash
pip install hebrew-chapters
export ANTHROPIC_API_KEY=sk-ant-...
```

`ffmpeg` is used as a fallback decoder for exotic containers — install it if you
hit a decode error (`brew install ffmpeg` / `apt install ffmpeg`).

## Usage

```bash
# Chapters to stdout
chapters episode.mp3

# Video podcast + show notes + pull-quotes
chapters episode.mp4 --shownotes --quotes

# YouTube: paste the .txt into your video description (0:00-first, no bidi marks)
chapters episode.mp4 --format youtube --out episode

# Podcast apps via RSS: Podcasting 2.0 chapters JSON to host + reference in your feed
#   <podcast:chapters url="…/episode.chapters.json" type="application/json+chapters" />
chapters episode.mp4 --format podcast --out episode

# Podcast apps via the file (Apple Podcasts etc.): embed markers into the audio
chapters episode.mp4 --embed-into episode.m4a   # writes episode.chapters.m4a
```

### Making chapters show up everywhere
- **YouTube** — `--format youtube`, paste into the description. Needs first chapter
  at `0:00` and ≥3 chapters (the tool enforces both).
- **Modern podcast apps** (Overcast, Fountain, Podcast Addict) — `--format podcast`
  produces a Podcasting 2.0 JSON; host it and add `<podcast:chapters>` to the RSS item.
- **Apple Podcasts and file-based players** — `--embed-into audio.m4a|.mp3` writes
  chapter markers directly into a copy of the audio (stream copy, no re-encode).

Example output:

```
‎0:00 — פתיחה וברוכים הבאים
‎3:42 — האורח מספר על ההתחלה
‎18:05 — הטעות הכי גדולה שעשינו
```

## How it works

```
media ─▶ faster-whisper (local, cached) ─▶ transcript
                                              │
              ┌───────────────────────────────┼───────────────┐
              ▼                                ▼               ▼
        Claude: chapters            Claude: show notes   Claude: quotes
```

The transcript is cached (keyed by file hash + model + version), so re-runs and
prompt tweaks skip re-transcribing.

> First run downloads the model (~1.6 GB for the ivrit-ai turbo default). On CPU,
> transcription is roughly real-time; use a smaller `--model` (e.g. `base`) or a GPU
> to go faster. Pass any faster-whisper size name or HF ct2 repo id to `--model`.

## Notes

- `--model` (default: ivrit-ai turbo), `--lang` (default `he`), `--max-chapters`,
  `--format {md,txt,youtube,podcast}`, `--embed-into AUDIO`, `--shownotes`,
  `--quotes`, `--out`, `--no-cache`.
- Chapter timestamps come from Whisper, never the LLM — Claude only picks which
  segment a chapter starts on, and that choice is validated.

MIT licensed.
