"""Pure-logic tests for the render module. No ffmpeg / Pillow needed.

Covers the two things most likely to break silently:
  * crop-to-fill produces a CROP (not a pad/letterbox) for 9:16
  * clip-relative word timings convert to correct SRT times
"""

from hebrew_chapters.render import (
    _build_crop_vf,
    _clip_transcript,
    _parse_srt,
    _srt_time,
    _target_resolution,
    generate_srt,
)


# --- crop-to-fill --------------------------------------------------------

def test_crop_vf_9_16_is_crop_not_pad():
    vf = _build_crop_vf("9:16")
    assert "crop=" in vf
    assert "pad" not in vf  # must never letterbox
    assert vf.endswith("scale=1080:1920")


def test_crop_vf_9_16_crops_width_keeps_height():
    # Portrait target crops horizontally (keeps full height ih).
    vf = _build_crop_vf("9:16")
    assert "crop=ih*1080/1920:ih:" in vf


def test_crop_vf_center_by_default():
    # crop_position 0.5 -> the x offset is multiplied by 0.5.
    vf = _build_crop_vf("9:16")
    assert "*0.5:0" in vf


def test_crop_vf_landscape_and_square():
    assert _build_crop_vf("16:9").endswith("scale=1920:1080")
    assert _build_crop_vf("1:1").endswith("scale=1080:1080")


def test_target_resolution_arbitrary_aspect_is_even():
    w, h = _target_resolution("4:5")
    assert h == 1920
    assert w % 2 == 0 and h % 2 == 0
    assert w < h  # portrait


# --- SRT timing ----------------------------------------------------------

def test_srt_time_format():
    assert _srt_time(0) == "00:00:00,000"
    assert _srt_time(65.5) == "00:01:05,500"
    assert _srt_time(3725.25) == "01:02:05,250"


def test_clip_transcript_offsets_words_to_absolute():
    clip = {
        "id": "clip-1", "start": 100.0, "end": 105.0, "hook": "x",
        "words": [
            {"t": 0.0, "d": 0.5, "w": "שלום"},
            {"t": 1.0, "d": 0.5, "w": "עולם"},
        ],
    }
    tr = _clip_transcript(clip)
    words = tr["segments"][0]["words"]
    assert words[0]["start"] == 100.0 and words[0]["end"] == 100.5
    assert words[1]["start"] == 101.0 and words[1]["end"] == 101.5


def test_generate_srt_clip_relative_timing(tmp_path):
    # Words are relative to a clip starting at 100s; the SRT must be relative to
    # the clip (first word at 0:00), not to the source video.
    clip = {
        "id": "clip-1", "start": 100.0, "end": 105.0, "hook": "x",
        "words": [
            {"t": 0.0, "d": 0.4, "w": "אחת"},
            {"t": 0.5, "d": 0.4, "w": "שתיים"},
            {"t": 1.2, "d": 0.4, "w": "שלוש."},
        ],
    }
    tr = _clip_transcript(clip)
    srt = tmp_path / "clip-1.srt"
    generate_srt(tr, clip["start"], clip["end"], srt)

    entries = _parse_srt(srt)
    assert entries, "expected at least one caption entry"
    # First caption starts at the clip origin (0.0), NOT at 100s.
    assert abs(entries[0]["start"] - 0.0) < 0.01
    # Full text preserved, in clip-relative time.
    joined = " ".join(e["text"] for e in entries)
    assert "אחת" in joined and "שלוש" in joined
    # Last caption end is within the clip span (< 5s), proving the offset.
    assert entries[-1]["end"] <= 5.0


def test_generate_srt_punctuation_flush(tmp_path):
    # A word ending in sentence punctuation flushes the caption chunk.
    clip = {
        "id": "c", "start": 0.0, "end": 10.0,
        "words": [
            {"t": 0.0, "d": 0.3, "w": "היי"},
            {"t": 0.4, "d": 0.3, "w": "שם."},
            {"t": 2.0, "d": 0.3, "w": "עוד"},
            {"t": 2.4, "d": 0.3, "w": "משפט."},
        ],
    }
    tr = _clip_transcript(clip)
    srt = tmp_path / "c.srt"
    generate_srt(tr, 0.0, 10.0, srt)
    entries = _parse_srt(srt)
    assert len(entries) == 2  # split on the two sentence-final periods
