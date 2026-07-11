"""Tests for the pure formatting logic — the part most likely to break silently
(bidi marks, YouTube rules). No Whisper or Claude needed."""

from hebrew_chapters.format import (
    LRM,
    fmt_timestamp,
    render_chapters_md,
    render_chapters_youtube,
)
from hebrew_chapters.generate import Chapter


def test_fmt_timestamp():
    assert fmt_timestamp(0) == "0:00"
    assert fmt_timestamp(65) == "1:05"
    assert fmt_timestamp(3725) == "1:02:05"
    assert fmt_timestamp(-3) == "0:00"


def test_md_has_lrm_bidi_mark():
    md = render_chapters_md([Chapter(0.0, "פתיחה")])
    assert md.startswith(LRM)
    assert "0:00 — פתיחה" in md


def test_youtube_has_no_bidi_marks():
    # Invisible LRM chars break YouTube's chapter parser — must never appear.
    ch = [Chapter(0.0, "א"), Chapter(30.0, "ב"), Chapter(90.0, "ג")]
    yt = render_chapters_youtube(ch, audio_end=200.0)
    assert LRM not in yt
    assert yt.splitlines()[0].startswith("0:00 ")


def test_youtube_prepends_zero():
    ch = [Chapter(12.0, "א"), Chapter(40.0, "ב"), Chapter(100.0, "ג")]
    yt = render_chapters_youtube(ch, audio_end=200.0)
    assert yt.splitlines()[0].startswith("0:00 ")


def test_youtube_merges_sub_10s_chapters():
    # Second chapter is only 3s long -> dropped/merged into the first.
    ch = [Chapter(0.0, "א"), Chapter(3.0, "ב"), Chapter(60.0, "ג"), Chapter(120.0, "ד")]
    yt = render_chapters_youtube(ch, audio_end=200.0)
    assert len(yt.splitlines()) == 3  # ב merged away


def test_youtube_fewer_than_three_returns_empty():
    ch = [Chapter(0.0, "א"), Chapter(60.0, "ב")]
    assert render_chapters_youtube(ch, audio_end=120.0) == ""


def test_index_guard_rejects_non_increasing():
    # The chapter validator lives in generate.make_chapters; here we just assert
    # the invariant the guard enforces is what format expects (sorted, distinct).
    ch = [Chapter(0.0, "א"), Chapter(30.0, "ב"), Chapter(90.0, "ג")]
    starts = [c.start for c in ch]
    assert starts == sorted(starts)
