"""Pure-logic tests for the render module. No ffmpeg / Pillow needed.

Covers the two things most likely to break silently:
  * crop-to-fill produces a CROP (not a pad/letterbox) for 9:16
  * clip-relative word timings convert to correct SRT times
"""

import pytest

from sofit.render import (
    _bidi_word_order,
    _build_crop_vf,
    _prep_logo,
    _caption_entries,
    _clip_transcript,
    _crop_position_for_face,
    _dynamic_crop_vf,
    _pan_keyframes,
    _parse_srt,
    _srt_time,
    _target_resolution,
    generate_srt,
)


# --- bidi word order (visual left-to-right, base RTL) --------------------

def _t(*texts):
    return [{"text": s, "start": 0, "end": 1} for s in texts]


def test_bidi_pure_hebrew_reverses():
    # Hebrew-only line: visual L->R is the logical order reversed.
    out = [w["text"] for w in _bidi_word_order(_t("שלום", "עולם", "טוב"))]
    assert out == ["טוב", "עולם", "שלום"]


def test_bidi_keeps_multiword_latin_run_in_order():
    # "זה Thoma Bravo כזה" — the Latin run must NOT reverse to "Bravo Thoma".
    out = [w["text"] for w in _bidi_word_order(_t("זה", "Thoma", "Bravo", "כזה"))]
    # visual L->R: כזה, then the LTR run in order (Thoma, Bravo), then זה
    assert out == ["כזה", "Thoma", "Bravo", "זה"]


def test_bidi_single_latin_token_between_hebrew():
    out = [w["text"] for w in _bidi_word_order(_t("את", "OpenAI", "אהבתי"))]
    assert out == ["אהבתי", "OpenAI", "את"]


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


# --- face-aware crop mapping --------------------------------------------

def test_crop_position_centers_on_face():
    # A face at frame center maps to a centered crop.
    assert _crop_position_for_face(0.5, 0.316) == 0.5
    # A face left of center pulls the crop left (< 0.5); right pulls right.
    assert _crop_position_for_face(0.3, 0.316) < 0.5
    assert _crop_position_for_face(0.7, 0.316) > 0.5
    # Edges clamp to [0,1].
    assert _crop_position_for_face(0.0, 0.316) == 0.0
    assert _crop_position_for_face(1.0, 0.316) == 1.0


def test_crop_position_degenerate_widths_are_center():
    # A crop as wide as the source (or wider) can't recenter — stay centered.
    assert _crop_position_for_face(0.2, 1.0) == 0.5
    assert _crop_position_for_face(0.2, 1.5) == 0.5


# --- speaker-tracking pan ------------------------------------------------

def test_pan_keyframes_snaps_on_cut():
    # steady on the left, then a hard cut to the right (a camera switch).
    samples = [(i * 0.5, 0.30) for i in range(6)] + [(3.0 + i * 0.5, 0.75) for i in range(6)]
    kf = _pan_keyframes(samples)
    xs = [c for _, c in kf]
    assert min(xs) < 0.35 and max(xs) > 0.70  # both shots represented
    ts = [t for t, _ in kf]
    gaps = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
    assert any(g < 0.1 for g in gaps)  # a near-instant snap, not a slow pan


def test_pan_keyframes_steady_is_minimal():
    samples = [(i * 0.5, 0.5) for i in range(10)]
    assert len(_pan_keyframes(samples)) <= 2  # no spurious keyframes when static


def test_pan_keyframes_follows_isolated_sustained_cut():
    # long shot A, an isolated ~1.25s cut to B, then back to A -> B IS followed
    # (this is the clip-6 case: the crop must move to frame the other speaker).
    a = [(i * 0.25, 0.30) for i in range(20)]
    b = [(5.0 + i * 0.25, 0.75) for i in range(5)]
    a2 = [(6.25 + i * 0.25, 0.30) for i in range(20)]
    xs = [c for _, c in _pan_keyframes(a + b + a2)]
    assert max(xs) > 0.70  # followed the sustained cut to B


def test_pan_keyframes_burst_does_not_alternate():
    # A rapid A/B/A/B exchange must collapse to a single held position, never a
    # back-and-forth bounce (the jumpiness). At most one excursion up.
    a = [(i * 0.25, 0.20) for i in range(12)]
    ex = []
    t = 3.0
    for _ in range(5):  # 5 rapid A/B swaps, ~0.75s each
        for _ in range(3):
            ex.append((t, 0.85))
            t += 0.25
        for _ in range(3):
            ex.append((t, 0.20))
            t += 0.25
    a2 = [(t + i * 0.25, 0.20) for i in range(12)]
    xs = [c for _, c in _pan_keyframes(a + ex + a2)]
    ups = sum(1 for i in range(1, len(xs)) if xs[i] - xs[i - 1] > 0.1)
    assert ups <= 1  # no alternating bounce


def test_pan_keyframes_ignores_rapid_flicker():
    # 3s locked on the left, then a rapid A/B flicker every 0.3s. The crop must
    # NOT chase the flicker (that was the jumpy bug) — at most one settle.
    steady = [(i * 0.3, 0.30) for i in range(10)]
    flicker = [(3.0 + k * 0.3, 0.75 if k % 2 else 0.30) for k in range(7)]
    kf = _pan_keyframes(steady + flicker)
    xs = [c for _, c in kf]
    snaps = sum(1 for i in range(1, len(xs)) if abs(xs[i] - xs[i - 1]) > 0.1)
    assert snaps <= 1


def test_pan_keyframes_fills_gaps():
    # None = no face detected that frame; must be hold-filled, not dropped.
    kf = _pan_keyframes([(0.0, 0.4), (0.5, None), (1.0, None), (1.5, 0.6)])
    assert kf and all(c is not None for _, c in kf)


def test_dynamic_crop_vf_pans_over_time():
    vf = _dynamic_crop_vf("9:16", [(0.0, 0.3), (2.0, 0.7)])
    assert vf.startswith("crop=") and vf.endswith("scale=1080:1920")
    assert "t" in vf  # x expression references time -> the crop pans


# --- caption entries (word highlight) ------------------------------------

def test_caption_entries_keep_word_timings():
    clip = {
        "id": "c", "start": 10.0, "end": 20.0,
        "words": [
            {"t": 0.0, "d": 0.4, "w": "שלום"},
            {"t": 0.5, "d": 0.4, "w": "עולם"},
            {"t": 1.1, "d": 0.4, "w": "טוב."},
        ],
    }
    entries = _caption_entries(_clip_transcript(clip), 10.0, 20.0)
    assert entries
    words = [w for e in entries for w in e["words"]]
    assert [w["text"] for w in words] == ["שלום", "עולם", "טוב."]
    # times are clip-relative (first word at ~0), so highlighting lines up with t.
    assert abs(words[0]["start"]) < 0.01


# --- logo prep -----------------------------------------------------------

def test_prep_logo_trims_transparent_margins(tmp_path):
    PIL = pytest.importorskip("PIL")
    from PIL import Image
    # 200x200 fully transparent with a 40x20 opaque block at (30,50)
    im = Image.new("RGBA", (200, 200), (0, 0, 0, 0))
    for x in range(30, 70):
        for y in range(50, 70):
            im.putpixel((x, y), (255, 0, 0, 255))
    src = tmp_path / "logo.png"
    im.save(src)
    out = _prep_logo(str(src), str(tmp_path))
    trimmed = Image.open(out)
    assert trimmed.size == (40, 20)  # cropped to the opaque block


def test_render_clips_passes_hook_when_card_on(monkeypatch, tmp_path):
    # The clip's `hook` reaches extract_clip by default (caption-first hook card),
    # and is suppressed when hook_card=False.
    import sofit.render as r
    captured = []
    monkeypatch.setattr(r, "extract_clip", lambda **k: captured.append(k))
    clip = {"id": "clip-1", "hook": "בדיקה", "focus": 0.5, "start": 0, "end": 1, "words": []}
    r.render_clips("v.mp4", [clip], str(tmp_path), subtitles=False)
    assert captured[-1]["hook"] == "בדיקה"
    r.render_clips("v.mp4", [clip], str(tmp_path), subtitles=False, hook_card=False)
    assert captured[-1]["hook"] is None


def test_hook_card_shrinks_to_two_lines():
    # A whole-sentence hook must not blanket the speaker's face: the card shrinks
    # until it fits 2 lines. (The first WS203 batch rendered 4-line cards over the
    # face — this is that regression.)
    pytest.importorskip("PIL")
    from sofit.render import _fit_hook_card
    long_hook = "Lovable שווה 8 מיליארד. Wix שווה 2. איך זה הגיוני?"
    _, _, lines, size = _fit_hook_card(long_hook, 1920, int(1080 * 0.90))
    assert len(lines) <= 2
    assert size < max(34, 1920 // 16)  # shrank from the headline size

    # A short hook keeps the full headline size.
    _, _, short_lines, short_size = _fit_hook_card("למה כולם טועים?", 1920, int(1080 * 0.90))
    assert len(short_lines) == 1
    assert short_size == max(34, 1920 // 16)


def test_render_clips_hook_variant_picks_alt_and_suffixes_output(monkeypatch, tmp_path):
    # hook_variant=N uses hook_variants[N-1] and writes <id>.hookN.mp4, so A/B
    # renders of the same clip don't overwrite each other.
    import sofit.render as r
    captured = []
    monkeypatch.setattr(r, "extract_clip", lambda **k: captured.append(k))
    clip = {"id": "clip-1", "hook": "ראשי", "hook_variants": ["חלופה א", "חלופה ב"],
            "focus": 0.5, "start": 0, "end": 1, "words": []}

    outs = r.render_clips("v.mp4", [clip], str(tmp_path), subtitles=False, hook_variant=2)
    assert captured[-1]["hook"] == "חלופה ב"
    assert outs[0].endswith("clip-1.hook2.mp4")

    outs = r.render_clips("v.mp4", [clip], str(tmp_path), subtitles=False)  # primary
    assert captured[-1]["hook"] == "ראשי"
    assert outs[0].endswith("clip-1.mp4")


def test_render_clips_out_of_range_variant_falls_back_to_primary(monkeypatch, tmp_path):
    # Asking for a variant the clip doesn't have must render the primary hook,
    # not a silently card-less clip.
    import sofit.render as r
    captured = []
    monkeypatch.setattr(r, "extract_clip", lambda **k: captured.append(k))
    clip = {"id": "clip-1", "hook": "ראשי", "hook_variants": [],
            "focus": 0.5, "start": 0, "end": 1, "words": []}
    outs = r.render_clips("v.mp4", [clip], str(tmp_path), subtitles=False, hook_variant=3)
    assert captured[-1]["hook"] == "ראשי"
    assert outs[0].endswith("clip-1.mp4")  # no bogus .hook3 suffix


def test_render_clips_logo_env_default(monkeypatch, tmp_path):
    # SOFIT_LOGO applies a logo without passing --logo/logo=.
    import sofit.render as r
    monkeypatch.setenv("SOFIT_LOGO", "/tmp/mylogo.png")
    captured = {}
    monkeypatch.setattr(r, "_prep_logo", lambda p, d: captured.setdefault("logo", p))
    monkeypatch.setattr(r, "extract_clip", lambda **k: None)
    r.render_clips("v.mp4", [{"id": "clip-1", "focus": 0.5, "start": 0, "end": 1, "words": []}],
                   str(tmp_path), subtitles=False)
    assert captured["logo"] == "/tmp/mylogo.png"


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
