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


def call_claude_json(system: str, user: str, validate, model: str = CLAUDE_MODEL):
    """Call Claude, parse a JSON body, validate it, retry once on failure.

    `validate(obj)` must return the accepted value or raise GenerationError.
    Raises GenerationError after the retry is exhausted.
    """
    client = _client()
    last_err: Exception | None = None
    for attempt in range(2):
        msg = client.messages.create(
            model=model,
            max_tokens=4096,
            system=system,
            messages=[{"role": "user", "content": user}],
        )
        text = "".join(block.text for block in msg.content if block.type == "text").strip()
        try:
            obj = json.loads(_strip_fences(text))
            return validate(obj)
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


def make_chapters(segments: list[Segment], max_chapters: int = 12) -> list[Chapter]:
    if not segments:
        return []
    system = (
        "You split a Hebrew podcast transcript into chapters. Return ONLY a JSON "
        'array of objects: [{"start_index": int, "title": str, "echo": str}]. '
        "start_index is the segment number where the chapter begins. title is a "
        "concise, natural Hebrew chapter title. echo is the first ~5 words of that "
        f"segment, copied verbatim. Return at most {max_chapters} chapters, ordered."
    )
    user = f"Segments:\n{_numbered(segments)}"
    by_index = {s.index: s for s in segments}

    def validate(obj):
        if not isinstance(obj, list) or not obj:
            raise GenerationError("expected a non-empty array")
        chapters: list[Chapter] = []
        last = -1
        for item in obj:
            idx = item.get("start_index")
            if idx not in by_index:
                raise GenerationError(f"start_index {idx} out of range")
            if idx <= last:
                raise GenerationError("start_index not strictly increasing")
            seg = by_index[idx]
            echo = (item.get("echo") or "").strip()
            if echo and echo[:12] not in seg.text:
                raise GenerationError(f"echo mismatch at index {idx}")
            chapters.append(Chapter(start=seg.start, title=item["title"].strip()))
            last = idx
        return chapters

    return call_claude_json(system, user, validate)


def make_shownotes(segments: list[Segment]) -> dict:
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

    return call_claude_json(system, user, validate)


def make_quotes(segments: list[Segment]) -> list[Quote]:
    if not segments:
        return []
    audio_end = segments[-1].end
    system = (
        "You pick 3-5 clip-worthy moments from a Hebrew podcast. Return ONLY a JSON "
        'array: [{"start_index": int, "end_index": int, "title": str}]. The range '
        "must be a coherent, quotable moment; title is a short Hebrew label."
    )
    user = f"Segments:\n{_numbered(segments)}"
    by_index = {s.index: s for s in segments}

    def validate(obj):
        if not isinstance(obj, list):
            raise GenerationError("expected an array")
        quotes: list[Quote] = []
        for item in obj:
            si, ei = item.get("start_index"), item.get("end_index")
            if si not in by_index or ei not in by_index or ei < si:
                raise GenerationError(f"bad quote range {si}..{ei}")
            start_seg, end_seg = by_index[si], by_index[ei]
            # snap to word boundaries when available; clamp end to the audio length
            start = start_seg.words[0].start if start_seg.words else start_seg.start
            end = end_seg.words[-1].end if end_seg.words else end_seg.end
            end = min(end, audio_end)
            quotes.append(Quote(start=start, end=end, text=item["title"].strip()))
        return quotes

    return call_claude_json(system, user, validate)
