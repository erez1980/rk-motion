"""Output formatting. Pure functions — no I/O, no models — so they're fully
testable without Whisper or the Claude API.

Bidi note: md/txt output wraps the LTR "H:MM:SS —" prefix in a Left-to-Right
Mark so it doesn't visually reorder the RTL Hebrew title in terminals and
markdown renderers. The YouTube format is EXEMPT: YouTube's automatic chapter
detector parses the timestamp line, and invisible bidi control characters make
it silently fail to detect chapters.
"""

from __future__ import annotations

import json

from .generate import Chapter, Quote

LRM = "‎"  # Left-to-Right Mark


def fmt_timestamp(seconds: float) -> str:
    seconds = max(0, int(seconds))
    h, rem = divmod(seconds, 3600)
    m, s = divmod(rem, 60)
    if h:
        return f"{h}:{m:02d}:{s:02d}"
    return f"{m}:{s:02d}"


def render_chapters_md(chapters: list[Chapter]) -> str:
    # LRM before the timestamp keeps the line visually LTR-then-RTL.
    return "\n".join(f"{LRM}{fmt_timestamp(c.start)} — {c.title}" for c in chapters)


def render_chapters_youtube(chapters: list[Chapter], audio_end: float) -> str:
    """YouTube auto-chapters rules: first at 0:00, ascending, >=3 chapters,
    each >=10s. Returns "" if fewer than 3 chapters survive — caller should fall
    back to md and warn. Never emits bidi marks.
    """
    if not chapters:
        return ""
    ch = sorted(chapters, key=lambda c: c.start)
    if ch[0].start > 0:
        ch = [Chapter(start=0.0, title=ch[0].title)] + ch[1:]

    # Enforce >=10s spacing: keep a chapter only if it starts >=10s after the
    # last kept one. This folds any too-short chapter into its predecessor,
    # including one that lands right after the 0:00 opener.
    merged: list[Chapter] = []
    for c in ch:
        if merged and c.start - merged[-1].start < 10:
            continue
        merged.append(c)

    if len(merged) < 3:
        return ""  # YouTube needs >=3; signal fallback
    return "\n".join(f"{fmt_timestamp(c.start)} {c.title}" for c in merged)


def render_chapters_podcast_json(chapters: list[Chapter]) -> str:
    """Podcasting 2.0 chapters JSON. Host this file and point your RSS item at it
    with <podcast:chapters url="..." type="application/json+chapters" />. Read by
    Overcast, Fountain, Podcast Addict, and other modern podcast apps."""
    doc = {
        "version": "1.2.0",
        "chapters": [{"startTime": round(c.start, 3), "title": c.title} for c in chapters],
    }
    return json.dumps(doc, ensure_ascii=False, indent=2)


def render_shownotes_md(notes: dict) -> str:
    lines = [notes.get("summary", "").strip(), ""]
    lines += [f"- {b}" for b in notes.get("bullets", [])]
    return "\n".join(lines).strip()


def render_quotes_md(quotes: list[Quote]) -> str:
    return "\n".join(
        f"{LRM}{fmt_timestamp(q.start)}–{fmt_timestamp(q.end)} — {q.text}" for q in quotes
    )
