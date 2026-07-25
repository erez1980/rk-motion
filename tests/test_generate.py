"""Offline tests for the generator logic — no ANTHROPIC_API_KEY needed.

We stub the Claude call to exercise the part the review flagged (and a live run
confirmed): Claude's segment indices drift over a long transcript, so chapters
are located by matching Claude's verbatim quote back to the transcript text, and
the timestamp comes from the located segment.
"""

import json

import pytest

import sofit.generate as gen
from sofit.generate import GenerationError, make_chapters
from sofit.transcribe import Segment, Word


def _seg(i, start, text):
    return Segment(index=i, start=start, end=start + 5, text=text, words=[Word(start, start + 1, text)])


SEGMENTS = [
    _seg(0, 0.0, "שלום וברוכים הבאים לפודקאסט"),
    _seg(1, 30.0, "היום נדבר על בינה מלאכותית"),
    _seg(2, 90.0, "עכשיו נעבור לנושא השני עתיד העבודה"),
]


def _stub_claude(monkeypatch, payload):
    class _Block:
        type = "text"
        text = json.dumps(payload, ensure_ascii=False)

    class _Msg:
        content = [_Block()]

    class _Client:
        class messages:
            @staticmethod
            def create(**kwargs):
                return _Msg()

    monkeypatch.setattr(gen, "_client", lambda: _Client())


def test_chapters_located_by_quote(monkeypatch):
    _stub_claude(monkeypatch, [
        {"title": "פתיחה", "quote": "שלום וברוכים הבאים"},
        {"title": "עתיד העבודה", "quote": "עכשיו נעבור לנושא"},
    ])
    chapters = make_chapters(SEGMENTS)
    # timestamps come from the located segments, not any LLM-supplied number
    assert [c.start for c in chapters] == [0.0, 90.0]
    assert chapters[1].title == "עתיד העבודה"


def test_quote_matches_despite_punctuation(monkeypatch):
    # Claude quotes with different punctuation; normalized match still locates it.
    _stub_claude(monkeypatch, [{"title": "x", "quote": "היום, נדבר. על בינה"}])
    chapters = make_chapters(SEGMENTS)
    assert chapters[0].start == 30.0


def test_unlocatable_chapter_is_dropped_not_fatal(monkeypatch):
    _stub_claude(monkeypatch, [
        {"title": "real", "quote": "שלום וברוכים"},
        {"title": "ghost", "quote": "משפט שלא נאמר מעולם בכלל"},
    ])
    chapters = make_chapters(SEGMENTS)
    assert len(chapters) == 1
    assert chapters[0].title == "real"


def test_all_unlocatable_raises(monkeypatch):
    _stub_claude(monkeypatch, [{"title": "x", "quote": "טקסט מומצא לחלוטין שאיננו"}])
    with pytest.raises(GenerationError):
        make_chapters(SEGMENTS)


def test_order_enforced_by_cursor(monkeypatch):
    # Second quote points backward (seg 0); cursor has advanced past it, so it's
    # dropped rather than producing an out-of-order chapter.
    _stub_claude(monkeypatch, [
        {"title": "second", "quote": "עכשיו נעבור לנושא"},
        {"title": "backward", "quote": "שלום וברוכים"},
    ])
    chapters = make_chapters(SEGMENTS)
    assert [c.start for c in chapters] == [90.0]


def test_max_chapters_cap_enforced(monkeypatch):
    # Claude ignores "at most N" and returns all 3; code must cap to max_chapters.
    _stub_claude(monkeypatch, [
        {"title": "a", "quote": "שלום וברוכים"},
        {"title": "b", "quote": "היום נדבר"},
        {"title": "c", "quote": "עכשיו נעבור"},
    ])
    assert len(make_chapters(SEGMENTS, max_chapters=2)) == 2


def test_empty_segments_returns_empty(monkeypatch):
    _stub_claude(monkeypatch, [])
    assert make_chapters([]) == []


def test_clip_words_relative_and_fallback():
    segs = [
        Segment(0, 10.0, 12.0, "a b", [Word(10.0, 10.5, "a"), Word(11.0, 11.4, "b")]),
        Segment(1, 20.0, 22.0, "x y", []),  # no word timestamps → even distribution
    ]
    words = gen._clip_words(segs, start=10.0, end=22.0)
    # word times are relative to clip start (10.0)
    assert words[0] == {"t": 0.0, "d": 0.5, "w": "a"}
    assert words[1]["t"] == 1.0
    # fallback: "x y" spread evenly over [20,22] → t=10.0 and t=11.0 (relative)
    assert [w["w"] for w in words[2:]] == ["x", "y"]
    assert words[2]["t"] == 10.0 and words[3]["t"] == 11.0


def test_make_clips_structure(monkeypatch):
    _stub_claude(monkeypatch, [
        {"title": "רגע מעניין", "hook_type": "question", "score": 9,
         "quote_start": "שלום וברוכים", "quote_end": "עכשיו נעבור"},
    ])
    clips = gen.make_clips(SEGMENTS)
    assert len(clips) == 1
    c = clips[0]
    assert c["id"] == "clip-1"
    assert c["hook"] == "רגע מעניין"
    assert c["focus"] is None
    assert c["start"] == 0.0
    assert c["words"][0]["t"] == 0.0  # first word at clip start


def test_make_quotes_drops_weak_and_short(monkeypatch):
    # Weak hook (score < 7) and a too-short clip must both be dropped; only the
    # strong, long-enough clip survives.
    _stub_claude(monkeypatch, [
        {"title": "חלש", "score": 4, "quote_start": "שלום וברוכים", "quote_end": "עכשיו נעבור"},
        {"title": "קצר", "score": 9, "quote_start": "היום נדבר", "quote_end": "היום נדבר"},
        {"title": "טוב", "score": 8, "quote_start": "שלום וברוכים", "quote_end": "עכשיו נעבור"},
    ])
    quotes = gen.make_quotes(SEGMENTS)
    assert len(quotes) == 1
    assert quotes[0].text == "טוב"


def test_make_quotes_keeps_hook_variants(monkeypatch):
    # Alternates are captured, capped at 2, and the primary is never duplicated
    # into the variant list (nor are blanks).
    _stub_claude(monkeypatch, [
        {"title": "טוב", "score": 8, "quote_start": "שלום וברוכים", "quote_end": "עכשיו נעבור",
         "hook_variants": ["גרסה א", "  ", "טוב", "גרסה ב", "גרסה ג"]},
    ])
    q = gen.make_quotes(SEGMENTS)[0]
    assert q.variants == ("גרסה א", "גרסה ב")


def test_make_quotes_variants_default_empty(monkeypatch):
    # A model that omits hook_variants must not break selection.
    _stub_claude(monkeypatch, [
        {"title": "טוב", "score": 8, "quote_start": "שלום וברוכים", "quote_end": "עכשיו נעבור"},
    ])
    assert gen.make_quotes(SEGMENTS)[0].variants == ()


def _wseg(i, start, tokens, step=0.5):
    """Segment with one Word per token (the real transcript shape)."""
    words = [Word(start + n * step, start + n * step + 0.4, t) for n, t in enumerate(tokens)]
    return Segment(index=i, start=start, end=words[-1].end, text=" ".join(tokens), words=words)


def test_make_quotes_opens_on_the_hook_not_the_throat_clearing(monkeypatch):
    # The hook sits mid-segment, after filler. Second zero must be the hook, so
    # the clip start snaps to the hook's own first word (11.5), not the segment
    # start (10.0) — otherwise the hook lands a beat late and retention dies.
    segs = [
        _wseg(0, 10.0, ["אז", "כן", "אה", "למה", "כולם", "טועים", "בזה"]),
        _wseg(1, 40.0, ["וזאת", "הסיבה", "האמיתית"]),
    ]
    _stub_claude(monkeypatch, [
        {"title": "הוק", "score": 9, "quote_start": "למה כולם טועים",
         "quote_end": "וזאת הסיבה האמיתית"},
    ])
    assert gen.make_quotes(segs)[0].start == pytest.approx(11.5)


def test_make_quotes_keeps_start_when_hook_is_already_first(monkeypatch):
    # No filler to skip: the start must not move (the snap only goes forward).
    segs = [
        _wseg(0, 10.0, ["למה", "כולם", "טועים", "בזה"]),
        _wseg(1, 40.0, ["וזאת", "הסיבה", "האמיתית"]),
    ]
    _stub_claude(monkeypatch, [
        {"title": "הוק", "score": 9, "quote_start": "למה כולם טועים",
         "quote_end": "וזאת הסיבה האמיתית"},
    ])
    assert gen.make_quotes(segs)[0].start == pytest.approx(10.0)


def test_hook_word_start_matches_across_punctuation():
    # Matching ignores punctuation (same normalization as _locate).
    seg = _wseg(0, 5.0, ["אז,", "טוב", "—", "למה", "כולם", "טועים?"])
    assert gen._hook_word_start(seg, "למה כולם טועים") == pytest.approx(6.5)


def test_hook_word_start_none_when_absent():
    seg = _wseg(0, 5.0, ["שלום", "עולם"])
    assert gen._hook_word_start(seg, "משהו אחר לגמרי") is None


def test_make_quotes_raises_when_none_qualify(monkeypatch):
    _stub_claude(monkeypatch, [
        {"title": "חלש", "score": 3, "quote_start": "שלום וברוכים", "quote_end": "עכשיו נעבור"},
    ])
    with pytest.raises(GenerationError):
        gen.make_quotes(SEGMENTS)


def test_titler_claude_cli_uses_cli_transport(monkeypatch):
    # titler="claude-cli" must route through _call_claude_cli, not the API client.
    import json as _json
    calls = {"api": 0, "cli": 0}

    def fake_cli(system, user, model):
        calls["cli"] += 1
        return _json.dumps([{"title": "פתיחה", "quote": "שלום וברוכים הבאים"}], ensure_ascii=False)

    def boom_api(*a, **k):
        calls["api"] += 1
        raise AssertionError("API transport must not be called for claude-cli")

    monkeypatch.setattr(gen, "_call_claude_cli", fake_cli)
    monkeypatch.setattr(gen, "_call_api", boom_api)
    chapters = make_chapters(SEGMENTS, titler="claude-cli")
    assert chapters[0].start == 0.0
    assert calls == {"api": 0, "cli": 1}


def test_claude_cli_missing_binary_raises(monkeypatch):
    import shutil
    monkeypatch.setattr(shutil, "which", lambda _: None)
    with pytest.raises(GenerationError):
        gen._call_claude_cli("sys", "user", "model")
