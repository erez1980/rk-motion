"""Offline tests for the generator logic — no ANTHROPIC_API_KEY needed.

We stub the Claude call so we can exercise the part the review flagged as the
make-or-break: the chapter index-correctness guard (in-range + strictly
increasing + text-echo cross-check) and the index→Whisper-timestamp mapping.
"""

import json

import pytest

import hebrew_chapters.generate as gen
from hebrew_chapters.generate import GenerationError, make_chapters
from hebrew_chapters.transcribe import Segment, Word


def _seg(i, start, text):
    return Segment(index=i, start=start, end=start + 5, text=text, words=[Word(start, start + 1, text)])


SEGMENTS = [
    _seg(0, 0.0, "שלום וברוכים הבאים"),
    _seg(1, 30.0, "היום נדבר על בינה מלאכותית"),
    _seg(2, 90.0, "עכשיו לנושא השני עתיד העבודה"),
]


def _stub_claude(monkeypatch, payload):
    """Make call_claude_json return `payload` (a Python obj) as Claude's JSON."""
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


def test_chapters_map_index_to_whisper_start(monkeypatch):
    _stub_claude(monkeypatch, [
        {"start_index": 0, "title": "פתיחה", "echo": "שלום וברוכים"},
        {"start_index": 2, "title": "עתיד העבודה", "echo": "עכשיו לנושא"},
    ])
    chapters = make_chapters(SEGMENTS)
    # timestamps come from the segments, not the LLM
    assert [c.start for c in chapters] == [0.0, 90.0]
    assert chapters[1].title == "עתיד העבודה"


def test_rejects_out_of_range_index(monkeypatch):
    _stub_claude(monkeypatch, [{"start_index": 99, "title": "x", "echo": ""}])
    with pytest.raises(GenerationError):
        make_chapters(SEGMENTS)


def test_rejects_non_increasing_index(monkeypatch):
    _stub_claude(monkeypatch, [
        {"start_index": 2, "title": "b", "echo": ""},
        {"start_index": 1, "title": "a", "echo": ""},
    ])
    with pytest.raises(GenerationError):
        make_chapters(SEGMENTS)


def test_rejects_echo_mismatch(monkeypatch):
    # Claude claims segment 1 starts with text that isn't actually there.
    _stub_claude(monkeypatch, [{"start_index": 1, "title": "x", "echo": "טקסט לא קיים כלל"}])
    with pytest.raises(GenerationError):
        make_chapters(SEGMENTS)


def test_empty_segments_returns_empty(monkeypatch):
    _stub_claude(monkeypatch, [])
    assert make_chapters([]) == []
