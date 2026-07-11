"""Offline tests for the generator logic — no ANTHROPIC_API_KEY needed.

We stub the Claude call to exercise the part the review flagged (and a live run
confirmed): Claude's segment indices drift over a long transcript, so chapters
are located by matching Claude's verbatim quote back to the transcript text, and
the timestamp comes from the located segment.
"""

import json

import pytest

import hebrew_chapters.generate as gen
from hebrew_chapters.generate import GenerationError, make_chapters
from hebrew_chapters.transcribe import Segment, Word


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


def test_empty_segments_returns_empty(monkeypatch):
    _stub_claude(monkeypatch, [])
    assert make_chapters([]) == []
