"""Slow end-to-end: a corrected Latin token actually burns into an RTL Hebrew
caption. Skipped without ffmpeg or the render extra (so CI, which installs
neither, skips it; runs locally)."""

import os
import shutil
import subprocess

import pytest

pytest.importorskip("PIL")  # render extra
pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")


def test_corrected_latin_token_burns_into_caption(tmp_path):
    # Pixel-exact bidi ORDER via OCR is deferred; this proves the mixed
    # Hebrew+Latin caption renders into the band — which a file-exists check
    # (the thing the review flagged) cannot.
    from sofit import corrections, render

    src = tmp_path / "src.mp4"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-f", "lavfi",
         "-i", "color=c=teal:s=640x360:d=2", "-y", str(src)],
        check=True,
    )
    words = [
        {"t": 0.0, "d": 0.5, "w": "אצל"},
        {"t": 0.5, "d": 0.5, "w": "אופן"},
        {"t": 1.0, "d": 0.4, "w": "איי"},
        {"t": 1.4, "d": 0.4, "w": "איי"},
    ]
    words, n = corrections.apply_correction(words, "אופן-איי-איי", "OpenAI")
    assert n == 1 and any(w["w"] == "OpenAI" for w in words)

    clip = {"id": "clip-1", "start": 0.0, "end": 2.0, "hook": "x", "focus": None, "words": words}
    outs = render.render_clips(str(src), [clip], str(tmp_path / "out"), aspect="9:16")
    assert len(outs) == 1 and os.path.exists(outs[0])

    frame = tmp_path / "f.png"
    subprocess.run(
        ["ffmpeg", "-v", "error", "-ss", "0.8", "-i", outs[0], "-frames:v", "1", "-y", str(frame)],
        check=True,
    )
    from PIL import Image
    img = Image.open(frame).convert("L")
    w, h = img.size
    band = img.crop((0, int(h * 0.66), w, h))  # lower third — where captions sit
    px = band.tobytes()  # mode "L" -> one byte per pixel
    dark = sum(1 for p in px if p < 40)     # black outline
    bright = sum(1 for p in px if p > 210)  # white text
    assert dark > 200 and bright > 200, f"no caption drawn (dark={dark}, bright={bright})"
