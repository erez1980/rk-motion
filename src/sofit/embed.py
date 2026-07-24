"""Embed chapter markers directly into an audio file via ffmpeg.

Apple Podcasts and several other apps read chapters embedded in the media file
(ID3 chapter frames for mp3, native chapters for m4a/m4b) rather than the
Podcasting 2.0 feed JSON. This writes them in with a stream copy (no re-encode),
so it's fast even for a full episode.
"""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

from .generate import Chapter


def _escape(v: str) -> str:
    # ffmetadata: =, ;, #, \ and newlines must be backslash-escaped.
    for ch in ("\\", "=", ";", "#"):
        v = v.replace(ch, "\\" + ch)
    return v.replace("\n", " ").strip()


def build_ffmetadata(chapters: list[Chapter], audio_end: float) -> str:
    lines = [";FFMETADATA1"]
    for i, c in enumerate(chapters):
        start = int(round(c.start * 1000))
        nxt = chapters[i + 1].start if i + 1 < len(chapters) else audio_end
        end = max(int(round(nxt * 1000)), start + 1)
        lines += ["[CHAPTER]", "TIMEBASE=1/1000", f"START={start}", f"END={end}", f"title={_escape(c.title)}"]
    return "\n".join(lines) + "\n"


def embed_chapters(audio_in: str, chapters: list[Chapter], audio_end: float, audio_out: str) -> None:
    """Write `chapters` into a copy of `audio_in` at `audio_out` (stream copy).
    Raises RuntimeError if ffmpeg fails."""
    if not chapters:
        raise RuntimeError("no chapters to embed")
    with tempfile.NamedTemporaryFile("w", suffix=".ffmeta", delete=False, encoding="utf-8") as f:
        f.write(build_ffmetadata(chapters, audio_end))
        meta_path = f.name
    try:
        proc = subprocess.run(
            ["ffmpeg", "-y", "-i", audio_in, "-i", meta_path,
             "-map_metadata", "1", "-map_chapters", "1", "-codec", "copy", audio_out],
            capture_output=True, text=True,
        )
        if proc.returncode != 0:
            raise RuntimeError(f"ffmpeg failed: {proc.stderr.strip().splitlines()[-1] if proc.stderr else 'unknown'}")
    finally:
        Path(meta_path).unlink(missing_ok=True)
