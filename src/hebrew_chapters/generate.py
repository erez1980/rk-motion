"""Claude-backed generators over a cached transcript.

One shared helper (`call_claude_json`) does the model call + JSON parse + a
single retry + validation. Each generator supplies only its prompt and a
validator, so the parse/retry/error logic lives in exactly one place.

Chapter/quote timestamps come from Whisper, never the LLM: Claude returns a
segment INDEX and code maps it to that segment's start time. Because LLMs drift
on long numbered lists, we guard the returned indices (in-range + strictly
increasing + a min gap) and cross-check that Claude's echoed text prefix
actually matches the segment it selected.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass

from .transcribe import Segment

# Titling is cheap and quality-sensitive for Hebrew; tune this to taste.
# (Sonnet 5 is a good cost/quality default; bump to Opus for hardest cases.)
CLAUDE_MODEL = "claude-sonnet-5"


@dataclass
class Chapter:
    start: float
    title: str


@dataclass
class Quote:
    start: float
    end: float
    text: str


class GenerationError(RuntimeError):
    pass


def _client():
    import anthropic  # lazy import so tests / --help don't require the SDK

    return anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from the environment


def _call_api(system: str, user: str, model: str) -> str:
    """Transport: Anthropic API (per-token billing; needs ANTHROPIC_API_KEY)."""
    msg = _client().messages.create(
        model=model,
        max_tokens=4096,
        system=system,
        messages=[{"role": "user", "content": user}],
    )
    return "".join(b.text for b in msg.content if b.type == "text").strip()


def _call_claude_cli(system: str, user: str, model: str) -> str:
    """Transport: the `claude -p` CLI (uses your Claude Code / Pro/Max subscription,
    no API key). The large user text goes on stdin to dodge argv limits; the small
    system prompt rides on --append-system-prompt. Whatever model Claude Code is
    configured with is used, so `model` is ignored here."""
    import shutil
    import subprocess

    if not shutil.which("claude"):
        raise GenerationError("claude CLI not found — install Claude Code or use --titler api")
    proc = subprocess.run(
        ["claude", "-p", "--append-system-prompt", system, "--output-format", "text"],
        input=user, capture_output=True, text=True, timeout=300,
    )
    if proc.returncode != 0:
        raise GenerationError(f"claude CLI failed: {(proc.stderr or '').strip()[:200]}")
    return proc.stdout.strip()


def call_claude_json(system: str, user: str, validate, model: str = CLAUDE_MODEL, titler: str = "api"):
    """Call Claude, parse a JSON body, validate it, retry once on failure.

    `titler`: "api" (Anthropic API + key) or "claude-cli" (`claude -p`, subscription).
    `validate(obj)` must return the accepted value or raise GenerationError.
    Raises GenerationError after the retry is exhausted.
    """
    transport = _call_claude_cli if titler == "claude-cli" else _call_api
    last_err: Exception | None = None
    for _ in range(2):
        text = transport(system, user, model)
        try:
            return validate(json.loads(_strip_fences(text)))
        except (json.JSONDecodeError, GenerationError) as e:
            last_err = e
    raise GenerationError(f"Claude returned unusable output after retry: {last_err}")


def _strip_fences(text: str) -> str:
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        text = text.rsplit("```", 1)[0]
    return text.strip()


def _numbered(segments: list[Segment]) -> str:
    return "\n".join(f"[{s.index}] {s.text}" for s in segments)


def _norm(s: str) -> str:
    """Lowercase-ish normalize for matching: keep word chars (incl. Hebrew) and
    spaces, collapse whitespace. Punctuation and niqqud differences don't matter."""
    return re.sub(r"\s+", " ", re.sub(r"[^\w\s]", "", s)).strip()


def _locate(quote: str, segments: list[Segment], start_from: int) -> Segment | None:
    """Find the segment where `quote` occurs, at or after index `start_from`.

    LLMs drift badly when asked for a segment index over a 1000-line list, but
    they quote transcript text accurately. So we match on the quote's first few
    words instead of trusting any index Claude returns.
    """
    words = _norm(quote).split()
    if not words:
        return None
    phrase = " ".join(words[:4])
    for s in segments:
        if s.index < start_from:
            continue
        if phrase in _norm(s.text):
            return s
    return None


def make_chapters(segments: list[Segment], max_chapters: int = 12, titler: str = "api") -> list[Chapter]:
    if not segments:
        return []
    system = (
        "You split a Hebrew podcast transcript into chapters. Return ONLY a JSON "
        'array: [{"title": str, "quote": str}]. title is a concise, natural Hebrew '
        "chapter title. quote is the first 4-8 words of the transcript where that "
        "chapter begins, copied VERBATIM so it can be found in the text. Chapters "
        f"must be in chronological order. Return at most {max_chapters}."
    )
    user = f"Transcript segments:\n{_numbered(segments)}"

    def validate(obj):
        if not isinstance(obj, list) or not obj:
            raise GenerationError("expected a non-empty array")
        chapters: list[Chapter] = []
        cursor = 0
        for item in obj:
            seg = _locate(item.get("quote", ""), segments, cursor)
            if seg is None:
                continue  # drop unlocatable chapter rather than fail the batch
            chapters.append(Chapter(start=seg.start, title=item["title"].strip()))
            cursor = seg.index + 1
        if not chapters:
            raise GenerationError("no chapters could be located in the transcript")
        return chapters[:max_chapters]  # enforce the cap in code; the prompt alone isn't reliable

    return call_claude_json(system, user, validate, titler=titler)


def make_shownotes(segments: list[Segment], titler: str = "api") -> dict:
    if not segments:
        return {"summary": "", "bullets": []}
    system = (
        "You write Hebrew show notes for a podcast episode. Return ONLY JSON: "
        '{"summary": str, "bullets": [str, ...]}. summary is one Hebrew paragraph; '
        "bullets are 3-6 short Hebrew highlights."
    )
    user = " ".join(s.text for s in segments)

    def validate(obj):
        if not isinstance(obj, dict) or "summary" not in obj:
            raise GenerationError("expected {summary, bullets}")
        obj.setdefault("bullets", [])
        return obj

    return call_claude_json(system, user, validate, titler=titler)


def make_quotes(segments: list[Segment], titler: str = "api") -> list[Quote]:
    if not segments:
        return []
    audio_end = segments[-1].end
    system = (
        "You pick 3-5 clip-worthy moments from a Hebrew podcast. Return ONLY a JSON "
        'array: [{"title": str, "quote_start": str, "quote_end": str}]. quote_start '
        "and quote_end are the first ~4 words of the transcript where the moment "
        "begins and ends, copied VERBATIM. title is a short Hebrew label."
    )
    user = f"Transcript segments:\n{_numbered(segments)}"

    def validate(obj):
        if not isinstance(obj, list):
            raise GenerationError("expected an array")
        quotes: list[Quote] = []
        for item in obj:
            start_seg = _locate(item.get("quote_start", ""), segments, 0)
            if start_seg is None:
                continue  # can't place it; skip this quote
            end_seg = _locate(item.get("quote_end", ""), segments, start_seg.index)
            end_seg = end_seg or start_seg
            # snap to word boundaries when available; clamp end to the audio length
            start = start_seg.words[0].start if start_seg.words else start_seg.start
            end = end_seg.words[-1].end if end_seg.words else end_seg.end
            quotes.append(Quote(start=start, end=min(end, audio_end), text=item["title"].strip()))
        return quotes

    return call_claude_json(system, user, validate, titler=titler)


def _clip_words(segments: list[Segment], start: float, end: float) -> list[dict]:
    """Per-word caption timing for one clip, times RELATIVE to the clip start (t=0 at
    `start`). If a segment in range has no word timestamps, distribute its text evenly
    across the segment so the karaoke never gets null gaps (clips.json contract)."""
    out: list[dict] = []
    for s in segments:
        if s.end < start or s.start > end:  # segment fully outside the clip
            continue
        if s.words:
            for w in s.words:
                if start <= w.start <= end:
                    out.append({
                        "t": round(w.start - start, 3),
                        "d": round(max(w.end - w.start, 0.01), 3),
                        "w": w.text.strip(),
                    })
        else:
            toks = s.text.split()
            if not toks:
                continue
            seg_start, seg_end = max(s.start, start), min(s.end, end)
            step = max(seg_end - seg_start, 0.01) / len(toks)
            for i, tok in enumerate(toks):
                out.append({"t": round(seg_start - start + i * step, 3), "d": round(step, 3), "w": tok})
    return out


def make_clips(segments: list[Segment], titler: str = "api") -> list[dict]:
    """Clip specs for the social-clipper: reuse the pull-quote ranges + hooks, attach
    clip-relative per-word timings. Returns the `clips` array of the clips.json contract."""
    clips = []
    for i, q in enumerate(make_quotes(segments, titler=titler), 1):
        clips.append({
            "id": f"clip-{i}",
            "start": round(q.start, 3),
            "end": round(q.end, 3),
            "hook": q.text,
            "focus": None,
            "words": _clip_words(segments, q.start, q.end),
        })
    return clips
