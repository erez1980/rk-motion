"""Timing-preserving caption text correction.

Fix a typo in a clip's word stream by editing word TEXT only — never the
per-word timings that drive the karaoke highlight. A multi-token find (e.g. the
three tokens "OpenAI" transcribes into: אופן / איי / איי) collapses to the
replacement, merging the matched tokens' time span so the highlight stays
aligned. A one-word find can split into several replacement words, splitting the
span proportionally.

The word shape is the clips.json contract: {"t": clip-relative start seconds,
"d": duration seconds, "w": text}. Matching is on a whitespace-and-punctuation
-stripped, lowercased normalization of both sides, concatenated with NO
separator — so a hyphenated ("אופן-איי-איי") or spaced ("אופן איי איי") find both
match the stored tokens. Matching is on logical-order text (bidi reordering is a
draw-time concern in render.py), so `find` is never bidi-normalized.
"""

from __future__ import annotations

import re


def _strip(s: str) -> str:
    """Normalize for matching: drop everything but word chars (Hebrew, Latin,
    digits), lowercased, no whitespace or punctuation. `\\w` is Unicode-aware."""
    return re.sub(r"[^\w]", "", s, flags=re.UNICODE).lower()


def _match_run(words: list[dict], start: int, target: str) -> int:
    """Length of the shortest run of words starting at `start` whose stripped,
    concatenated text equals `target`. 0 if no run starting here matches.

    Pure-punctuation tokens (which strip to "") contribute nothing to the
    comparison but are still counted into the run so their time is absorbed into
    the merged span (this is what makes the hyphen token in אופן-איי-איי work)."""
    concat = ""
    j = start
    while j < len(words):
        concat += _strip(words[j].get("w", ""))
        j += 1
        if concat == target:
            return j - start
        if not target.startswith(concat):
            return 0
    return 0


def _split_replacement(replace: str, t0: float, end: float) -> list[dict]:
    """Turn `replace` into word dicts occupying the time window [t0, end].
    One token spans the whole window; several split it proportionally by
    character length so the karaoke advances at a natural pace."""
    toks = replace.split()
    span = max(end - t0, 0.0)
    total = sum(len(t) for t in toks) or 1
    out: list[dict] = []
    cursor = t0
    for k, tok in enumerate(toks):
        if k == len(toks) - 1:
            d = max(end - cursor, 0.01)  # last token soaks up any rounding drift
        else:
            d = span * (len(tok) / total)
        out.append({"t": round(cursor, 3), "d": round(d, 3), "w": tok})
        cursor += d
    return out


def apply_correction(words: list[dict], find: str, replace: str) -> tuple[list[dict], int]:
    """Return (new_words, n_replaced): every non-overlapping occurrence of `find`
    in the word stream replaced by `replace`, timings preserved. `find`/`replace`
    are plain text; `find` may span multiple stored tokens and `replace` may be
    multiple words. Timings outside a matched run are byte-identical.

    Raises ValueError on an empty `replace` (deletion is out of scope) or a `find`
    with no matchable characters.
    """
    if not replace or not replace.strip():
        raise ValueError("replace text must be non-empty (deletion is out of scope)")
    target = _strip(find)
    if not target:
        raise ValueError("find text has no matchable characters")

    out: list[dict] = []
    n = 0
    i = 0
    while i < len(words):
        run_len = _match_run(words, i, target)
        if run_len:
            run = words[i:i + run_len]
            t0 = float(run[0]["t"])
            end = float(run[-1]["t"]) + float(run[-1].get("d", 0.0))
            out.extend(_split_replacement(replace, t0, end))
            n += 1
            i += run_len
        else:
            out.append(words[i])
            i += 1
    return out, n


def correct_clips(clips: list[dict], find: str, replace: str,
                  clip_id: str | None = None) -> tuple[int, list[str]]:
    """Apply a correction across clips in place. `clip_id=None` corrects every
    clip (recurring brand names show up in many); a `clip_id` scopes to one.
    Returns (total_replacements, [affected_clip_ids]). Timings preserved."""
    total = 0
    affected: list[str] = []
    for clip in clips:
        if clip_id is not None and clip.get("id") != clip_id:
            continue
        n_clip = 0
        new_words, n = apply_correction(clip.get("words", []), find, replace)
        if n:
            clip["words"] = new_words
            n_clip += n
        # Narrative edits keep words per kept span. A find can't match across a
        # cut — merging a time span over removed material would corrupt timing —
        # and shouldn't: the cut is a hard boundary in the rendered clip too.
        for seg in clip.get("segments") or []:
            new_words, n = apply_correction(seg.get("words", []), find, replace)
            if n:
                seg["words"] = new_words
                n_clip += n
        if n_clip:
            total += n_clip
            affected.append(str(clip.get("id")))
    return total, affected
