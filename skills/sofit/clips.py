#!/usr/bin/env python
"""Candidate-clip pool + pick→clips.json helper for the sofit skill.

Run with the sofit venv python so `import sofit` resolves:
    HC=/Users/navotv/src/hebrew-chapters
    "$HC/.venv/bin/python" clips.py pool  "<episode>"
    "$HC/.venv/bin/python" clips.py build "<episode>" <pool.json> --pick 2,4,7

`pool`  : from the CACHED transcript, ask Claude (via `claude -p`, no API key) for a
          ranked pool of scroll-stopping candidate clips; writes <episode>.pool.json
          next to the episode and prints a numbered table.
`build` : from picked candidate numbers, build a clips.json (ranges + hooks + per-word
          timings) ready for `sofit --render-from`. Writes <episode>.clips.json.

Everything else (transcribe, chapters/shownotes/quotes, render, --logo, correct_clip)
is in the CLI / MCP — see SKILL.md.
"""
import argparse
import json
import os
import sys

from sofit.transcribe import cached_segments
from sofit import generate as gen

POOL_SYSTEM = (
    "You are picking a POOL of candidate short-form clips from a Hebrew podcast "
    "(Reels/TikTok/Shorts) for a human to choose from. Find the {n} strongest, most "
    "DISTINCT moments across the whole episode. Each clip MUST: (1) OPEN with a hook "
    "in its first sentence — a question, a bold/contrarian claim, a surprising fact, "
    "or a strong emotional moment; (2) be a COMPLETE, self-contained thought with a "
    "payoff; (3) run about 20-45s. Return ONLY a JSON array "
    '[{{"title":str,"hook_type":str,"score":int,"reason":str,"quote_start":str,'
    '"quote_end":str,"hook_variants":[str,str]}}]. title = a punchy Hebrew hook line; '
    "hook_variants = exactly 2 ALTERNATE Hebrew hook lines for the same moment, each a "
    "DIFFERENT angle from title (for A/B testing which opener holds viewers); hook_type = one of "
    "question|bold_claim|surprise|emotion|story; score = 1-10 opening strength; "
    "reason = one short English line on why it would perform; quote_start = first ~4 "
    "words of the hook (verbatim); quote_end = last ~4 words of the payoff (verbatim). "
    "Cover different topics. Only include clips you would score 7 or higher."
)


def _segments(video):
    segs = cached_segments(video)
    if not segs:
        sys.exit(f"error: no cached transcript for {video} — transcribe it first "
                 f"(see SKILL.md step 1)")
    return segs


def cmd_pool(video, out, n, titler):
    segs = _segments(video)
    audio_end = segs[-1].end
    system = POOL_SYSTEM.format(n=n)
    user = f"Transcript segments:\n{gen._numbered(segs)}"

    def validate(obj):
        if not isinstance(obj, list):
            raise gen.GenerationError("expected an array")
        out_rows = []
        for it in obj:
            try:
                sc = int(it.get("score", 0))
            except (TypeError, ValueError):
                sc = 0
            if sc < 7:
                continue
            ss = gen._locate(it.get("quote_start", ""), segs, 0)
            if ss is None:
                continue
            es = gen._locate(it.get("quote_end", ""), segs, ss.index) or ss
            st = ss.words[0].start if ss.words else ss.start
            hooked = gen._hook_word_start(ss, it.get("quote_start", ""))
            if hooked is not None and hooked > st:
                st = hooked  # open ON the hook, not the filler before it
            en = es.words[-1].end if es.words else es.end
            en = min(en, audio_end)
            if en - st < 18:
                continue
            if en - st > 45:
                en = st + 45
            out_rows.append({
                "start": round(st, 3), "end": round(en, 3), "score": sc,
                "hook": it["title"].strip(), "type": it.get("hook_type", ""),
                "reason": (it.get("reason") or "").strip(),
                "hook_variants": [v.strip() for v in (it.get("hook_variants") or [])
                                  if isinstance(v, str) and v.strip()
                                  and v.strip() != it["title"].strip()][:2],
            })
        if not out_rows:
            raise gen.GenerationError("no candidates met the bar")
        return out_rows

    cands = gen.call_claude_json(system, user, validate, titler=titler)
    cands.sort(key=lambda c: -c["score"])
    kept = []
    for c in cands:
        if any(not (c["end"] <= k["start"] or c["start"] >= k["end"]) for k in kept):
            continue
        kept.append(c)
    kept.sort(key=lambda c: c["start"])
    out = out or os.path.splitext(video)[0] + ".pool.json"
    json.dump({"video": os.path.abspath(video), "candidates": kept},
              open(out, "w"), ensure_ascii=False, indent=2)
    print(f"wrote {out} ({len(kept)} candidates)\n")
    for i, c in enumerate(kept, 1):
        m, s = divmod(int(c["start"]), 60)
        print(f"{i:2d}. [{m}:{s:02d}] ({int(c['end']-c['start'])}s, {c['type']}, "
              f"score {c['score']}) {c['hook']}")
        print(f"      why: {c['reason']}")


def cmd_build(video, pool_path, pick, out):
    segs = _segments(video)
    pool = json.load(open(pool_path))
    cands = pool["candidates"]
    nums = [int(x) for x in pick.split(",") if x.strip()]
    clips = []
    for n in nums:
        c = cands[n - 1]  # 1-based, matches the pool table
        clips.append({
            "id": f"clip-{n}", "start": c["start"], "end": c["end"],
            "hook": c["hook"], "hook_variants": c.get("hook_variants") or [],
            "focus": None,
            "words": gen._clip_words(segs, c["start"], c["end"]),
        })
    out = out or os.path.splitext(video)[0] + ".clips.json"
    json.dump({"schema_version": 1, "source": {"video": os.path.abspath(video)},
               "clips": clips}, open(out, "w"), ensure_ascii=False, indent=2)
    print(f"wrote {out} ({len(clips)} clips: {nums})")


def main():
    p = argparse.ArgumentParser(prog="clips.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    pp = sub.add_parser("pool")
    pp.add_argument("video")
    pp.add_argument("--out")
    pp.add_argument("--n", type=int, default=12)
    pp.add_argument("--titler", default="claude-cli", choices=["api", "claude-cli"])
    bp = sub.add_parser("build")
    bp.add_argument("video")
    bp.add_argument("pool")
    bp.add_argument("--pick", required=True, help="comma-separated candidate numbers, e.g. 2,4,7")
    bp.add_argument("--out")
    a = p.parse_args()
    if a.cmd == "pool":
        cmd_pool(a.video, a.out, a.n, a.titler)
    else:
        cmd_build(a.video, a.pool, a.pick, a.out)


if __name__ == "__main__":
    main()
