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
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .transcribe import Segment

# Titling is cheap and quality-sensitive for Hebrew; tune this to taste.
# (Sonnet 5 is a good cost/quality default; bump to Opus for hardest cases.)
CLAUDE_MODEL = "claude-sonnet-5"

# `claude -p` wall clock. Generous by default: a 66-min episode asking for 8
# candidate clips with 2 hook variants each ran past the old 300s and died with a
# traceback mid-pipeline. Raised as TimeoutError (not GenerationError) so it fails
# fast instead of burning a second attempt on the retry path.
CLI_TIMEOUT = int(os.environ.get("SOFIT_CLI_TIMEOUT") or 900)


# What makes a good short-form clip, and what each JSON field means. Shared by the
# one-shot selector (`make_quotes`) and the skill's candidate-pool generator so the
# two prompts can't drift on the contract — they already did once, with the pool
# asking for 20-60s clips while the code clamped them at 45.
CLIP_RULES = (
    "Each clip MUST: (1) OPEN with a hook in its VERY FIRST sentence — a question, a "
    "bold or contrarian claim, a surprising fact, or a strong emotional moment — that "
    "stops the scroll within ~3 seconds. The strongest hooks open a CURIOSITY GAP: "
    "they raise a question in the viewer's mind that the clip has not yet answered, so "
    "they must keep watching to close it. Score highest when the hook is the first "
    "thing said, not buried after throat-clearing. (2) be a COMPLETE, self-contained "
    "thought with a payoff that closes that gap, not a fragment; (3) run about 20-45 "
    "seconds."
)

CLIP_FIELDS = (
    "title = a punchy Hebrew hook line for the clip. hook_variants = exactly 2 "
    "ALTERNATE Hebrew hook lines for the same moment, each taking a DIFFERENT angle "
    "from title (e.g. if title is a question, make one a bold claim and one a "
    "surprising number/fact) — they are for A/B testing which opener holds viewers. "
    "hook_type = one of question|bold_claim|surprise|emotion|story. score = 1-10 for "
    "how strongly the OPENING stops the scroll. quote_start = first ~4 words of the "
    "hook line, copied VERBATIM; quote_end = last ~4 words of the payoff, VERBATIM."
)


# Feedback loop: which posted clips actually held viewers.
# Kept OUTSIDE the repo — these are real business numbers and the repo is public.
PERF_LOG = os.environ.get("SOFIT_PERF_LOG") or str(
    Path.home() / "Documents" / "sofit-performance.jsonl")
MIN_PERF_ROWS = 8  # below this, "what worked" is noise, not signal


def _perf_rows(path: str | None = None) -> list[dict]:
    """Rows from the performance log that carry a hook and at least one metric."""
    p = Path(path or PERF_LOG)
    if not p.exists():
        return []
    rows = []
    for line in p.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            continue  # skip a malformed line rather than lose the whole log
        if r.get("hook") and (r.get("retention") is not None or r.get("views") is not None):
            rows.append(r)
    return rows


def performance_hint(path: str | None = None, n: int = 3,
                     min_rows: int = MIN_PERF_ROWS) -> str:
    """Prompt block naming the hooks that over- and under-performed on real posts,
    or "" when there isn't enough logged data for that to mean anything.

    Ranked by retention when logged, falling back to views — retention is the
    honest signal, since views are confounded by posting time and follower count.

    Deliberately dumb: the model just sees real examples. No scoring model, no
    weights to maintain. If the log grows enough that per-hook-type stats would
    beat few-shot examples, that's the time to build something smarter.
    """
    rows = _perf_rows(path)
    if len(rows) < min_rows:
        return ""
    rows.sort(key=lambda r: (r.get("retention") if r.get("retention") is not None else -1,
                             r.get("views") or 0), reverse=True)

    def fmt(r):
        m = f"{r['retention']}% retention" if r.get("retention") is not None \
            else f"{r['views']} views"
        return f'  - "{r["hook"]}" ({m})'

    best = "\n".join(fmt(r) for r in rows[:n])
    worst = "\n".join(fmt(r) for r in reversed(rows[-n:]))
    return (
        f"\n\nREAL PERFORMANCE from {len(rows)} posted clips of this show — weight "
        "these over your priors.\nHooks that held viewers:\n" + best +
        "\nHooks that lost them:\n" + worst +
        "\nFavour what the winners have in common; avoid what the losers share."
    )


@dataclass
class Chapter:
    start: float
    title: str


@dataclass
class Quote:
    start: float
    end: float
    text: str
    # Alternate hook lines for the same moment, to A/B against the retention
    # curve. `text` stays the primary. Tuple so the default is safely immutable.
    variants: tuple[str, ...] = ()


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
    try:
        proc = subprocess.run(
            ["claude", "-p", "--append-system-prompt", system, "--output-format", "text"],
            input=user, capture_output=True, text=True, timeout=CLI_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        # 300s was too tight for real work: a 66-min episode (981 segments) asking
        # for 8 clips x 3 hook lines each blew through it. Raise SOFIT_CLI_TIMEOUT
        # for longer episodes, or ask for fewer candidates.
        raise TimeoutError(
            f"claude CLI exceeded {CLI_TIMEOUT}s. Raise SOFIT_CLI_TIMEOUT, ask for "
            "fewer candidates (--n), or use --titler api."
        ) from None
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


def _hook_word_start(seg: Segment, quote: str) -> float | None:
    """Start time of the word where `quote` begins inside `seg`, or None.

    `_locate` resolves the segment; a segment often opens with throat-clearing
    ("אז...", "כן, אה") before the actual hook, so starting the clip at the
    segment start puts the hook a beat late — exactly what kills retention in the
    first seconds. Matching on the punctuation-stripped concatenation (same
    normalization as `_locate`) finds the hook's own first word.
    """
    needle = _norm(quote).replace(" ", "")
    if not needle or not seg.words:
        return None
    flat = ""
    owner: list[int] = []  # flat char position -> index in seg.words
    for i, w in enumerate(seg.words):
        t = _norm(w.text).replace(" ", "")
        flat += t
        owner.extend([i] * len(t))
    pos = flat.find(needle[:24])  # first few words are enough to place it
    if pos < 0:
        return None
    return seg.words[owner[pos]].start


def resolve_clip_item(item: dict, segments: list[Segment], audio_end: float,
                      min_sec: float = 18.0, max_sec: float = 45.0,
                      min_score: int = 7) -> Quote | None:
    """Turn one model-proposed clip into a timed `Quote`, or None if it misses the bar.

    Takes `{title, score, quote_start, quote_end, hook_variants}` and applies, in
    order: the hook-strength gate, quote->segment location, the hook-word snap (so
    second zero is the hook, not the throat-clearing before it), the length gates,
    and the variant cleanup.

    Shared by `make_quotes` and the skill's candidate-pool generator. Those two
    grew as parallel copies and silently drifted apart (the pool kept a 90s cap and
    never got the hook snap), so the selection rules live here, once.
    """
    try:
        score = int(item.get("score", 0))
    except (TypeError, ValueError):
        score = 0
    if score < min_score:
        return None  # weak hook — drop

    start_seg = _locate(item.get("quote_start", ""), segments, 0)
    if start_seg is None:
        return None  # can't place it; skip
    end_seg = _locate(item.get("quote_end", ""), segments, start_seg.index) or start_seg

    start = start_seg.words[0].start if start_seg.words else start_seg.start
    # Open ON the hook: skip any throat-clearing that precedes it in the same
    # segment. Only ever moves forward, never into the previous sentence.
    hooked = _hook_word_start(start_seg, item.get("quote_start", ""))
    if hooked is not None and hooked > start:
        start = hooked

    end = min(end_seg.words[-1].end if end_seg.words else end_seg.end, audio_end)
    if end - start < min_sec:
        return None  # too short for a hook + payoff
    if end - start > max_sec:
        # DROP it, don't clamp. Clamping kept the hook and cut the payoff off the
        # end, producing exactly what the prompt forbids: an opener with no
        # punchline. On WS204 three of four clips were clamped — clip-2 promised
        # "Fiverr is collapsing" and ended 40s before the $350M-vs-$600M-cash line
        # that made it interesting. If hook and payoff don't fit in max_sec, this
        # moment is not a short-form clip.
        return None

    title = (item.get("title") or "").strip()
    # Alternate hooks are optional and model-supplied: keep only non-empty strings
    # that differ from the primary, cap at 2.
    variants = tuple(
        v.strip() for v in (item.get("hook_variants") or [])
        if isinstance(v, str) and v.strip() and v.strip() != title
    )[:2]
    return Quote(start=start, end=end, text=title, variants=variants)


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


def make_quotes(
    segments: list[Segment],
    titler: str = "api",
    min_sec: float = 18.0,
    max_sec: float = 45.0,
    min_score: int = 7,
) -> list[Quote]:
    """Select scroll-stopping short-form clips. Each must open with a hook and be a
    complete, self-contained thought — the two things (per short-form research) that
    decide whether a clip holds past the first 3 seconds. Enforces a hook-strength
    score gate and a minimum length in code, so weak/fragment clips are dropped even
    if the model proposes them."""
    if not segments:
        return []
    audio_end = segments[-1].end
    system = (
        "You select scroll-stopping short-form clips from a Hebrew podcast (for "
        "Reels / TikTok / Shorts). " + CLIP_RULES + " Return ONLY a JSON array: "
        '[{"title": str, "hook_type": str, "score": int, "quote_start": str, '
        '"quote_end": str, "hook_variants": [str, str]}]. ' + CLIP_FIELDS +
        " Only include clips you would score 7 or higher." + performance_hint()
    )
    user = f"Transcript segments:\n{_numbered(segments)}"

    def validate(obj):
        if not isinstance(obj, list):
            raise GenerationError("expected an array")
        quotes = [q for q in (
            resolve_clip_item(item, segments, audio_end, min_sec, max_sec, min_score)
            for item in obj
        ) if q is not None]
        if not quotes:
            raise GenerationError("no clips met the hook-strength / length bar")
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
            "hook_variants": list(q.variants),
            "focus": None,
            "words": _clip_words(segments, q.start, q.end),
        })
    return clips
