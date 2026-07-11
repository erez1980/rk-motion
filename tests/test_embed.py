"""Test the ffmetadata builder (pure). The ffmpeg call itself is exercised
manually / in integration, not in the unit suite."""

from hebrew_chapters.embed import build_ffmetadata, _escape
from hebrew_chapters.generate import Chapter


def test_ffmetadata_chapter_blocks():
    ch = [Chapter(0.0, "Intro"), Chapter(35.0, "Topic")]
    meta = build_ffmetadata(ch, audio_end=100.0)
    assert meta.startswith(";FFMETADATA1")
    assert meta.count("[CHAPTER]") == 2
    # times in ms; first chapter ends where the second starts
    assert "START=0" in meta
    assert "END=35000" in meta
    # last chapter ends at audio_end
    assert "END=100000" in meta
    assert "title=Intro" in meta


def test_ffmetadata_escapes_special_chars():
    assert _escape("a=b;c#d") == "a\\=b\\;c\\#d"


def test_ffmetadata_min_length_chapter():
    # zero-length chapter still gets END > START (ffmpeg rejects equal)
    ch = [Chapter(5.0, "x")]
    meta = build_ffmetadata(ch, audio_end=5.0)
    assert "START=5000" in meta and "END=5001" in meta
