"""Tests for timing-preserving caption correction (no ffmpeg/Pillow needed)."""

import pytest

from sofit.corrections import apply_correction, correct_clips


def _w(t, d, w):
    return {"t": t, "d": d, "w": w}


def test_single_word_fix_preserves_timing():
    words = [_w(0.0, 0.5, "שלום"), _w(0.6, 0.4, "עולמ"), _w(1.1, 0.5, "טוב")]
    out, n = apply_correction(words, "עולמ", "עולם")
    assert n == 1
    assert [x["w"] for x in out] == ["שלום", "עולם", "טוב"]
    # the fixed word keeps its exact t/d; neighbors untouched
    assert out[1]["t"] == 0.6 and out[1]["d"] == 0.4
    assert out[0] == words[0] and out[2] == words[2]


def test_multi_token_merge_hyphenated_find():
    # "OpenAI" transcribed as three tokens; find given hyphenated.
    words = [_w(2.0, 0.3, "אופן"), _w(2.3, 0.2, "איי"), _w(2.5, 0.3, "איי"), _w(3.0, 0.4, "עבד")]
    out, n = apply_correction(words, "אופן-איי-איי", "OpenAI")
    assert n == 1
    assert [x["w"] for x in out] == ["OpenAI", "עבד"]
    # one token spanning the merged window [2.0 .. 2.8]
    assert out[0]["t"] == 2.0
    assert out[0]["d"] == pytest.approx(0.8, abs=0.01)
    assert out[1] == words[3]  # trailing word untouched


def test_multi_token_merge_spaced_find_matches_too():
    words = [_w(2.0, 0.3, "אופן"), _w(2.3, 0.2, "איי"), _w(2.5, 0.3, "איי")]
    out, n = apply_correction(words, "אופן איי איי", "OpenAI")  # spaced, not hyphenated
    assert n == 1 and out[0]["w"] == "OpenAI"


def test_one_to_many_split_preserves_window():
    words = [_w(0.0, 1.2, "OpenAI")]
    out, n = apply_correction(words, "OpenAI", "open ai")
    assert n == 1
    assert [x["w"] for x in out] == ["open", "ai"]
    # the two tokens tile the original [0.0 .. 1.2] window with no gap/overhang
    assert out[0]["t"] == 0.0
    assert out[-1]["t"] + out[-1]["d"] == pytest.approx(1.2, abs=0.01)


def test_no_match_leaves_words_untouched():
    words = [_w(0.0, 0.5, "שלום"), _w(0.6, 0.5, "עולם")]
    out, n = apply_correction(words, "nothing", "x")
    assert n == 0 and out == words


def test_empty_replace_rejected():
    with pytest.raises(ValueError):
        apply_correction([_w(0.0, 0.5, "x")], "x", "   ")


def test_multiple_non_overlapping_occurrences():
    words = [_w(0.0, 0.3, "קטאר"), _w(0.4, 0.3, "מול"), _w(0.8, 0.3, "קטאר")]
    out, n = apply_correction(words, "קטאר", "Qatar")
    assert n == 2
    assert [x["w"] for x in out] == ["Qatar", "מול", "Qatar"]


def test_punctuation_token_absorbed_into_span():
    # a lone punctuation token between the pieces normalizes to "" and is merged.
    words = [_w(0.0, 0.3, "אופן"), _w(0.3, 0.05, "-"), _w(0.35, 0.3, "איי")]
    out, n = apply_correction(words, "אופןאיי", "OpenAI")
    assert n == 1
    assert out[0]["w"] == "OpenAI"
    assert out[0]["t"] == 0.0 and out[0]["d"] == pytest.approx(0.65, abs=0.01)


def test_correct_clips_episode_wide_by_default():
    clips = [
        {"id": "clip-1", "words": [_w(0.0, 0.3, "קטאר")]},
        {"id": "clip-2", "words": [_w(0.0, 0.3, "שלום")]},
        {"id": "clip-3", "words": [_w(0.0, 0.3, "קטאר")]},
    ]
    total, affected = correct_clips(clips, "קטאר", "Qatar")
    assert total == 2
    assert affected == ["clip-1", "clip-3"]
    assert clips[0]["words"][0]["w"] == "Qatar"


def test_correct_clips_scoped_to_one_id():
    clips = [
        {"id": "clip-1", "words": [_w(0.0, 0.3, "קטאר")]},
        {"id": "clip-3", "words": [_w(0.0, 0.3, "קטאר")]},
    ]
    total, affected = correct_clips(clips, "קטאר", "Qatar", clip_id="clip-3")
    assert total == 1 and affected == ["clip-3"]
    assert clips[0]["words"][0]["w"] == "קטאר"  # clip-1 untouched


def test_correct_clips_reaches_segment_words():
    # Narrative edits keep words per kept span; corrections must reach them.
    clips = [{
        "id": "clip-1",
        "segments": [
            {"start": 10.0, "end": 20.0,
             "words": [{"t": 0.0, "d": 0.5, "w": "שלום"}]},
            {"start": 60.0, "end": 70.0,
             "words": [{"t": 0.0, "d": 0.5, "w": "טעות"},
                       {"t": 0.5, "d": 0.5, "w": "סוף"}]},
        ],
    }]
    total, affected = correct_clips(clips, "טעות", "תיקון")
    assert total == 1 and affected == ["clip-1"]
    assert clips[0]["segments"][1]["words"][0]["w"] == "תיקון"
    # timings untouched
    assert clips[0]["segments"][1]["words"][0]["t"] == 0.0
