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

**No API key?** If you have Claude Code (a Pro/Max subscription) installed and
logged in, pass `--titler claude-cli` to generate chapters through `claude -p`
using your subscription instead of a key. Slower per run and subject to your
Claude Code usage limits, but no per-episode API cost. The default (`--titler api`)
uses the Anthropic API and produces cleaner structured output.

`ffmpeg` is used as a fallback decoder for exotic containers — install it if you
hit a decode error (`brew install ffmpeg` / `apt install ffmpeg`).

## Usage

```bash
# Chapters to stdout
chapters episode.mp3

# From an RSS feed — processes the latest episode (item 1)
chapters https://feeds.example.com/show.xml --shownotes --out latest
chapters https://feeds.example.com/show.xml --episode 3      # a specific episode
chapters --list-episodes https://feeds.example.com/show.xml  # see the feed first
# From a YouTube URL (needs the youtube extra: pip install 'hebrew-chapters[youtube]')
chapters https://www.youtube.com/watch?v=VIDEO_ID --shownotes --out episode
# (a direct audio URL works too: chapters https://.../episode.mp3)

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
- **YouTube** — `--format youtube`, paste into the description. First chapter at
  `0:00`, ≥3 chapters, ≥10s apart (enforced).
- **Spotify (and Megaphone-hosted shows)** — `--format spotify`, paste into the
  episode description. Spotify parses description timestamps into chapters; it needs
  `0:00` first, ≥3 chapters, and **≥30s apart** (enforced — stricter than YouTube).
  Plain text, no emoji/HTML. Note: if the show uses dynamic ad insertion, mid-roll
  ads shift later timestamps out of sync.
- **Modern podcast apps** (Overcast, Fountain, Podcast Addict) — `--format podcast`
  produces a Podcasting 2.0 JSON; host it and add `<podcast:chapters>` to the RSS item.
  (Doesn't work through Megaphone, which controls its own feed.)
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

## Run it from an AI app (MCP)

An MCP server lets any MCP-capable client (Claude Desktop, Claude Code, Cursor…)
drive the tool in natural language.

```bash
pip install "hebrew-chapters[mcp]"     # adds the MCP server
```

Because transcription takes tens of minutes, it's split across three tools so no
single call blocks: **`transcribe_episode(path)`** starts it in the background,
**`transcription_status(path)`** reports `ready`/`running`, and
**`generate_kit(path, chapter_format, shownotes, quotes, …)`** returns the results
once the transcript is cached.

**Claude Desktop** — add to `claude_desktop_config.json` (use the absolute path to
the `chapters-mcp` binary if it's in a venv):

```json
{
  "mcpServers": {
    "hebrew-chapters": {
      "command": "/path/to/.venv/bin/chapters-mcp",
      "env": { "ANTHROPIC_API_KEY": "sk-ant-..." }
    }
  }
}
```

**Claude Code** — `claude mcp add hebrew-chapters -e ANTHROPIC_API_KEY=sk-ant-... -- /path/to/.venv/bin/chapters-mcp`

Then just ask: *"Transcribe ~/Downloads/ep.mp4"* → wait → *"Now give me Spotify
chapters and Hebrew show notes for it."*

## Notes

- Input: a local mp3/mp4 file, an RSS feed URL (add `--episode N`, default latest;
  `--list-episodes` to inspect), a YouTube URL (needs `pip install 'hebrew-chapters[youtube]'`),
  or a direct audio URL — all cached after first fetch.
- `--model` (default: ivrit-ai turbo), `--lang` (default `he`), `--max-chapters`,
  `--format {md,txt,youtube,spotify,podcast}`, `--embed-into AUDIO`,
  `--titler {api,claude-cli}`, `--shownotes`, `--quotes`, `--out`, `--no-cache`.
- Chapter timestamps come from Whisper, never the LLM — Claude only picks which
  segment a chapter starts on, and that choice is validated.

MIT licensed.
