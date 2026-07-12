"""MCP server — run the episode kit from any MCP-capable AI app.

Transcription is ~real-time (tens of minutes for a full episode), far longer
than an MCP call should block. So the pipeline is split across tools: start
transcription in the background, poll its status, then generate the (fast) kit
once the transcript is cached.

Run:  chapters-mcp        (stdio transport)
Wire it into Claude Desktop / Claude Code as an MCP server (see README).
"""

from __future__ import annotations

import os
import threading

from mcp.server.fastmcp import FastMCP

from . import format as fmt
from . import generate, transcribe

mcp = FastMCP("hebrew-chapters")

# cache_key -> {"status": "running"|"done"|"error", "error": str|None}
_jobs: dict[str, dict] = {}
_lock = threading.Lock()


def _key(path: str, model: str) -> str:
    return transcribe.cache_key(path, model or transcribe.DEFAULT_MODEL, "he", "int8")


@mcp.tool()
def transcription_status(path: str, model: str = "") -> dict:
    """Is the transcript for this media file ready? Returns status:
    'ready' | 'running' | 'not_started' | 'error'."""
    if not os.path.exists(path):
        return {"status": "not_started", "error": f"file not found: {path}"}
    if transcribe.cached_segments(path, model or transcribe.DEFAULT_MODEL) is not None:
        return {"status": "ready"}
    with _lock:
        job = _jobs.get(_key(path, model))
    if job:
        return {"status": job["status"], "error": job.get("error")}
    return {"status": "not_started"}


@mcp.tool()
def transcribe_episode(path: str, model: str = "") -> dict:
    """Start transcribing a media file (mp3/mp4) in the background, or report that
    it is already cached. Poll transcription_status until it is 'ready', then call
    generate_kit. Transcription can take tens of minutes for a full episode."""
    if not os.path.exists(path):
        return {"status": "error", "error": f"file not found: {path}"}
    if transcribe.cached_segments(path, model or transcribe.DEFAULT_MODEL) is not None:
        return {"status": "ready", "message": "Transcript already cached."}
    key = _key(path, model)
    with _lock:
        if _jobs.get(key, {}).get("status") == "running":
            return {"status": "running", "message": "Transcription already in progress."}
        _jobs[key] = {"status": "running", "error": None}

    def _run():
        try:
            transcribe.transcribe(path, model=model or transcribe.DEFAULT_MODEL)
            with _lock:
                _jobs[key] = {"status": "done", "error": None}
        except Exception as e:  # noqa: BLE001 - report any failure back to the client
            with _lock:
                _jobs[key] = {"status": "error", "error": str(e)}

    threading.Thread(target=_run, daemon=True).start()
    return {"status": "running", "message": "Transcription started; poll transcription_status."}


@mcp.tool()
def generate_kit(
    path: str,
    chapter_format: str = "md",
    max_chapters: int = 12,
    shownotes: bool = False,
    quotes: bool = False,
    model: str = "",
) -> dict:
    """Generate chapters (and optionally Hebrew show notes + pull-quotes) for an
    already-transcribed episode. Requires the transcript to be cached — call
    transcribe_episode first. chapter_format: md|txt|youtube|spotify|podcast.
    Needs ANTHROPIC_API_KEY in the server's environment."""
    segs = transcribe.cached_segments(path, model or transcribe.DEFAULT_MODEL)
    if segs is None:
        return {"error": "not transcribed yet — call transcribe_episode(path) first"}
    audio_end = segs[-1].end
    out: dict = {}

    chapters = generate.make_chapters(segs, max_chapters=max_chapters)
    if chapter_format in ("youtube", "spotify"):
        gap = 30.0 if chapter_format == "spotify" else 10.0
        out["chapters"] = fmt.render_chapters_youtube(chapters, audio_end, min_gap=gap) \
            or fmt.render_chapters_md(chapters)
    elif chapter_format == "podcast":
        out["chapters"] = fmt.render_chapters_podcast_json(chapters)
    else:
        out["chapters"] = fmt.render_chapters_md(chapters)

    if shownotes:
        out["shownotes"] = fmt.render_shownotes_md(generate.make_shownotes(segs))
    if quotes:
        out["quotes"] = fmt.render_quotes_md(generate.make_quotes(segs))
    return out


@mcp.tool()
def render_clips(path: str, out_dir: str, aspect: str = "9:16", model: str = "") -> dict:
    """Render each pull-quote of an already-transcribed episode to a vertical
    (default 9:16) clip with burned Hebrew captions, written to out_dir. Requires
    the transcript cached (call transcribe_episode first), the [render] extra
    installed, and ffmpeg. Returns the output file paths."""
    segs = transcribe.cached_segments(path, model or transcribe.DEFAULT_MODEL)
    if segs is None:
        return {"error": "not transcribed yet — call transcribe_episode(path) first"}
    try:
        from . import render
    except ImportError:
        return {"error": "install the render extra: pip install 'hebrew-chapters[render]'"}
    clips = generate.make_clips(segs, titler="api")
    outs = render.render_clips(path, clips, out_dir, aspect=aspect)
    return {"clips": len(outs), "files": outs}


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
