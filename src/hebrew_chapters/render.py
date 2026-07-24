"""Render vertical (or any-aspect) video clips with burned Hebrew captions.

Self-contained port of SocialClipper's clipper.py video-rendering path, adapted
for hebrew-chapters. No dependency on socialclipper.

The public entry point is `render_clips`. It takes a source video and a list of
clip dicts in the hebrew-chapters clips.json shape and writes one cropped-to-fill
mp4 per clip with the clip's Hebrew word timings burned in as captions.

Stack: stdlib + ffmpeg/ffprobe (external) + Pillow. python-bidi is used when
importable so mixed Hebrew/Latin captions render in correct visual order; if it
is missing the raw text is drawn instead (no crash).

Caption rendering has two paths:
  * libass -- used when the local ffmpeg was built with the `subtitles` filter.
  * Pillow per-frame overlay -- the fallback used when ffmpeg lacks libass. This
    is the path that runs on machines without libass and renders Hebrew
    correctly. Ported faithfully from SocialClipper.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

try:  # optional; captions still render (in logical order) without it
    from bidi.algorithm import get_display as _bidi_display
except Exception:  # pragma: no cover - depends on env
    _bidi_display = None


# ---------------------------------------------------------------------------
# ffmpeg capability probe
# ---------------------------------------------------------------------------

def _check_ffmpeg_subtitles_support() -> bool:
    """Check if ffmpeg was built with the subtitles filter (requires libass)."""
    try:
        result = subprocess.run(
            ["ffmpeg", "-filters"],
            capture_output=True, text=True, timeout=10,
        )
        return "subtitles" in result.stdout
    except Exception:
        return False


_HAS_SUBTITLES_FILTER = _check_ffmpeg_subtitles_support()


# ---------------------------------------------------------------------------
# Fonts (Hebrew-capable)
# ---------------------------------------------------------------------------

# macOS ships Arial variants with full Hebrew glyph coverage. These are tried in
# order for the Pillow path. `font` (a path) overrides this list.
_HEBREW_FONT_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/System/Library/Fonts/ArialHB.ttc",
    "/Library/Fonts/Arial.ttf",
    # Linux fallbacks
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansHebrew-Bold.ttf",
]

# Default family name for the libass force_style path. Arial carries Hebrew on
# macOS; libass resolves it via fontconfig.
_DEFAULT_LIBASS_FONT = "Arial"


def _resolve_pillow_font_path(font: str | None):
    """Return a font file path for Pillow, preferring an explicit override."""
    candidates = []
    if font and os.path.exists(font):
        candidates.append(font)
    candidates.extend(_HEBREW_FONT_CANDIDATES)
    for path in candidates:
        if Path(path).exists():
            return path
    return None


def _libass_font_name(font: str | None) -> str:
    """Family name to hand libass' force_style."""
    if not font:
        return _DEFAULT_LIBASS_FONT
    if os.path.exists(font):
        return Path(font).stem
    return font


def _shape_bidi(text: str) -> str:
    """Reorder a caption line for correct visual RTL/LTR display.

    Uses python-bidi when available; otherwise returns the text unchanged.
    """
    if _bidi_display is None:
        return text
    try:
        return _bidi_display(text)
    except Exception:
        return text


# ---------------------------------------------------------------------------
# Aspect / crop
# ---------------------------------------------------------------------------

ASPECT_RESOLUTIONS = {
    "16:9": (1920, 1080),
    "1:1": (1080, 1080),
    "9:16": (1080, 1920),
}


def _target_resolution(aspect_ratio: str) -> tuple[int, int]:
    """Resolve an aspect string like "9:16" to a concrete even (w, h)."""
    if aspect_ratio in ASPECT_RESOLUTIONS:
        return ASPECT_RESOLUTIONS[aspect_ratio]
    try:
        w_str, h_str = aspect_ratio.split(":")
        ratio = float(w_str) / float(h_str)
    except Exception:
        return ASPECT_RESOLUTIONS["9:16"]

    def _even(n: float) -> int:
        n = int(round(n))
        return n - (n % 2)

    if ratio < 1:          # portrait
        return (_even(1920 * ratio), 1920)
    if ratio > 1:          # landscape
        return (1920, _even(1920 / ratio))
    return (1080, 1080)    # square


def _build_crop_vf(aspect_ratio: str, crop_position: float = 0.5) -> str:
    """Build an ffmpeg -vf string that crops (instead of padding) to fill the frame.

    crop_position: 0.0 = left/top edge, 0.5 = center, 1.0 = right/bottom edge.
    Crop-to-fill for every aspect -- never letterbox.
    """
    tw, th = _target_resolution(aspect_ratio)
    target_ratio = tw / th
    cp = max(0.0, min(1.0, crop_position))

    if target_ratio > 1:
        # Target is landscape: crop height, keep full width
        crop = f"crop=iw:iw*{th}/{tw}:0:(ih-iw*{th}/{tw})*{cp}"
    elif target_ratio < 1:
        # Target is portrait: crop width, keep full height
        crop = f"crop=ih*{tw}/{th}:ih:(iw-ih*{tw}/{th})*{cp}:0"
    else:
        # Target is square: crop to the smaller dimension
        crop = f"crop=min(iw\\,ih):min(iw\\,ih):(iw-min(iw\\,ih))*{cp}:(ih-min(iw\\,ih))*{cp}"

    return f"{crop},scale={tw}:{th}"


# ---------------------------------------------------------------------------
# Face-aware crop position
# ---------------------------------------------------------------------------

_FACE_MODEL = Path(__file__).parent / "data" / "face_detection_yunet_2023mar.onnx"


def _crop_position_for_face(face_cx: float, crop_w_frac: float) -> float:
    """Map a face center-x fraction [0,1] to the crop_position [0,1] that centers
    a crop of width `crop_w_frac` (fraction of source width) on that face.

    crop_position places the crop's LEFT edge at (iw-crop_w)*cp, so to center the
    crop on face_cx we solve (iw-crop_w)*cp + crop_w/2 == face_cx*iw.
    """
    if not 0.0 < crop_w_frac < 1.0:
        return 0.5
    cp = (face_cx - crop_w_frac / 2) / (1.0 - crop_w_frac)
    return max(0.0, min(1.0, cp))


def _detect_face_center(video_path: Path, start: float, end: float,
                        samples: int = 8) -> tuple[float, float] | None:
    """Detect the dominant face across sampled frames of the clip.

    Returns (face_center_x_frac, source_aspect_h_over_w) or None when OpenCV /
    the model / ffmpeg is unavailable or no face is found. Frames are downscaled
    (fractions and the h/w ratio are scale-invariant) so detection is cheap.
    """
    try:
        import cv2  # optional: the `crop` extra (opencv-python-headless)
    except Exception:
        return None
    if not _FACE_MODEL.exists():
        return None

    span = max(end - start, 0.001)
    faces: list[tuple[float, float]] = []  # (center_x_frac, area*confidence weight)
    aspect_hw = 0.0
    with tempfile.TemporaryDirectory(prefix="hc_face_") as tmp:
        pattern = str(Path(tmp) / "f_%03d.png")
        cmd = [
            "ffmpeg", "-v", "error",
            "-ss", str(max(0.0, start)), "-t", str(span),
            "-i", str(video_path),
            "-vf", f"fps={samples}/{span},scale=640:-1",
            "-frames:v", str(samples), "-y", pattern,
        ]
        try:
            subprocess.run(cmd, capture_output=True, timeout=120, check=True)
        except Exception:
            return None

        detector = None
        for fp in sorted(Path(tmp).glob("f_*.png")):
            img = cv2.imread(str(fp))
            if img is None:
                continue
            h, w = img.shape[:2]
            aspect_hw = h / w
            if detector is None:
                detector = cv2.FaceDetectorYN.create(
                    str(_FACE_MODEL), "", (w, h), score_threshold=0.7,
                )
            else:
                detector.setInputSize((w, h))
            _, dets = detector.detect(img)
            if dets is None:
                continue
            for d in dets:
                fw, fh, conf = float(d[2]), float(d[3]), float(d[-1])
                cx = (float(d[0]) + fw / 2) / w
                faces.append((cx, fw * fh * conf))

    if not faces or not aspect_hw:
        return None

    # Cluster face centers by x; pick the cluster with the most total weight — so a
    # side-by-side two-shot resolves to the more prominent person, not their midpoint.
    faces.sort()
    clusters: list[list[tuple[float, float]]] = [[faces[0]]]
    for f in faces[1:]:
        if f[0] - clusters[-1][-1][0] > 0.12:
            clusters.append([f])
        else:
            clusters[-1].append(f)
    best = max(clusters, key=lambda c: sum(wt for _, wt in c))
    face_cx = sum(cx * wt for cx, wt in best) / sum(wt for _, wt in best)
    return face_cx, aspect_hw


def _smart_crop_position(video_path: Path, start: float, end: float,
                         aspect_ratio: str) -> float:
    """Crop center [0,1] that frames a detected face for a portrait/square target.

    Fixes the off-center-speaker misframe (a centered crop of a speaker sitting
    left/right of frame catches empty background beside them). Returns 0.5
    (center) for landscape targets, when OpenCV is unavailable, or when no face
    is found — so wide/no-face shots are unchanged.
    """
    tw, th = _target_resolution(aspect_ratio)
    if tw >= th:
        return 0.5
    found = _detect_face_center(video_path, start, end)
    if found is None:
        return 0.5
    face_cx, aspect_hw = found
    crop_w_frac = (tw / th) * aspect_hw  # crop width as a fraction of source width
    return _crop_position_for_face(face_cx, crop_w_frac)


# ---------------------------------------------------------------------------
# SRT generation from word timings
# ---------------------------------------------------------------------------

def generate_srt(transcript: dict, start_time: float, end_time: float, output_path: Path) -> Path:
    """Generate an SRT subtitle file from transcript segments within a time range.

    Timestamps are offset so the clip starts at 0:00.
    """
    word_entries = _subtitle_entries_from_words(transcript, start_time, end_time)
    if word_entries:
        lines = []
        for idx, entry in enumerate(word_entries, 1):
            lines.append(str(idx))
            lines.append(f"{_srt_time(entry['start'])} --> {_srt_time(entry['end'])}")
            lines.append(entry["text"])
            lines.append("")

        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text("\n".join(lines), encoding="utf-8")
        return output_path

    lines = []
    idx = 1

    for seg in transcript.get("segments", []):
        seg_start = seg["start"]
        seg_end = seg["end"]

        # Skip segments outside the clip range
        if seg_end <= start_time or seg_start >= end_time:
            continue

        # Clamp to clip boundaries
        s = max(seg_start, start_time) - start_time
        e = min(seg_end, end_time) - start_time

        text = seg["text"].strip()
        if not text:
            continue

        # Break long segments into shorter chunks (max ~10 words per subtitle)
        words = text.split()
        chunk_size = 10
        seg_duration = e - s
        word_count = len(words)

        if word_count <= chunk_size:
            lines.append(str(idx))
            lines.append(f"{_srt_time(s)} --> {_srt_time(e)}")
            lines.append(text)
            lines.append("")
            idx += 1
        else:
            # Split into chunks with proportional timing
            for i in range(0, word_count, chunk_size):
                chunk_words = words[i:i + chunk_size]
                chunk_start = s + (i / word_count) * seg_duration
                chunk_end = s + (min(i + chunk_size, word_count) / word_count) * seg_duration
                lines.append(str(idx))
                lines.append(f"{_srt_time(chunk_start)} --> {_srt_time(chunk_end)}")
                lines.append(" ".join(chunk_words))
                lines.append("")
                idx += 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines), encoding="utf-8")
    return output_path


def _subtitle_entries_from_words(
    transcript: dict,
    start_time: float,
    end_time: float,
) -> list[dict]:
    """Build subtitle entries from word-level timestamps when available."""
    words = []
    for segment in transcript.get("segments", []):
        for word in segment.get("words", []):
            word_start = word.get("start")
            word_end = word.get("end")
            text = (word.get("text") or "").strip()
            if word_start is None or word_end is None or not text:
                continue
            if word_end <= start_time or word_start >= end_time:
                continue
            words.append({
                "start": max(word_start, start_time) - start_time,
                "end": min(word_end, end_time) - start_time,
                "text": text,
            })

    if not words:
        return []

    entries = []
    chunk = []
    punctuation = (".", "!", "?", ",", ";", ":", "...")
    max_words = 7
    max_span = 3.0

    def flush_chunk() -> None:
        if not chunk:
            return
        entries.append({
            "start": chunk[0]["start"],
            "end": max(chunk[-1]["end"], chunk[0]["start"] + 0.25),
            "text": _join_word_tokens(item["text"] for item in chunk),
        })
        chunk.clear()

    for word in words:
        if not chunk:
            chunk.append(word)
            continue

        prospective_span = word["end"] - chunk[0]["start"]
        chunk.append(word)
        if (
            len(chunk) >= max_words
            or prospective_span >= max_span
            or word["text"].endswith(punctuation)
        ):
            flush_chunk()

    flush_chunk()
    return entries


def _join_word_tokens(tokens) -> str:
    text = ""
    for token in tokens:
        if not text:
            text = token
        elif token[:1] in ",.!?;:":
            text += token
        else:
            text += " " + token
    return text.strip()


def _srt_time(seconds: float) -> str:
    """Format seconds as SRT timestamp: HH:MM:SS,mmm"""
    h = int(seconds // 3600)
    m = int((seconds % 3600) // 60)
    s = int(seconds % 60)
    ms = int((seconds % 1) * 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


# ---------------------------------------------------------------------------
# SRT parsing (used by the Pillow burn path)
# ---------------------------------------------------------------------------

def _parse_srt(srt_path: Path) -> list[dict]:
    """Parse an SRT file into a list of {start, end, text} dicts (times in seconds)."""
    content = srt_path.read_text(encoding="utf-8").strip()
    if not content:
        return []

    entries = []
    blocks = content.split("\n\n")
    for block in blocks:
        lines = block.strip().splitlines()
        if len(lines) < 3:
            continue
        # Line 1: index, Line 2: timestamps, Line 3+: text
        time_line = lines[1]
        text = " ".join(lines[2:]).strip()
        if " --> " not in time_line or not text:
            continue

        start_str, end_str = time_line.split(" --> ")
        entries.append({
            "start": _parse_srt_time(start_str.strip()),
            "end": _parse_srt_time(end_str.strip()),
            "text": text,
        })
    return entries


def _parse_srt_time(ts: str) -> float:
    """Parse HH:MM:SS,mmm to seconds."""
    ts = ts.replace(",", ".")
    parts = ts.split(":")
    return int(parts[0]) * 3600 + int(parts[1]) * 60 + float(parts[2])


# ---------------------------------------------------------------------------
# Pillow per-frame subtitle burn (libass-free fallback)
# ---------------------------------------------------------------------------

def _burn_subtitles_pillow(video_path: Path, srt_path: Path, output_path: Path,
                           width: int, height: int, speed: float = 1.0,
                           font: str | None = None) -> Path:
    """Burn subtitles onto a video using Pillow to render text + ffmpeg overlay.

    Creates a transparent subtitle video track from the SRT, then composites it
    onto the input video. Works without libass/libfreetype in ffmpeg.

    Hebrew is reordered for display with python-bidi when available.
    """
    from PIL import Image, ImageDraw, ImageFont

    entries = _parse_srt(srt_path)
    if not entries:
        shutil.copy2(str(video_path), str(output_path))
        return output_path

    # Adjust subtitle timing for speed-up (video is already faster, so
    # subtitle timestamps need to be compressed by the same factor)
    if speed and speed != 1.0:
        for entry in entries:
            entry["start"] /= speed
            entry["end"] /= speed

    # Get video frame rate
    probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-select_streams", "v:0",
         "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0",
         str(video_path)],
        capture_output=True, text=True, timeout=10,
    )
    fps_str = probe.stdout.strip()
    if "/" in fps_str:
        num, den = fps_str.split("/")
        fps = float(num) / float(den)
    else:
        fps = float(fps_str) if fps_str else 30.0

    # Get video duration
    dur_probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(video_path)],
        capture_output=True, text=True, timeout=10,
    )
    total_duration = float(dur_probe.stdout.strip())
    total_frames = int(total_duration * fps)

    # Font setup -- prefer an explicit override, then Hebrew-capable candidates.
    font_size = max(22, height // 30)
    pil_font = None
    font_path = _resolve_pillow_font_path(font)
    if font_path:
        try:
            pil_font = ImageFont.truetype(font_path, font_size)
        except Exception:
            pil_font = None
    if pil_font is None:
        pil_font = ImageFont.load_default()

    outline_width = max(2, font_size // 11)
    margin_bottom = height // 10
    max_text_width = int(width * 0.85)

    def _wrap_text(text: str, draw: "ImageDraw.ImageDraw") -> list[str]:
        """Word-wrap text to fit within max_text_width (logical order)."""
        words = text.split()
        lines = []
        current = ""
        for word in words:
            test = f"{current} {word}".strip()
            bbox = draw.textbbox((0, 0), test, font=pil_font)
            if bbox[2] - bbox[0] > max_text_width and current:
                lines.append(current)
                current = word
            else:
                current = test
        if current:
            lines.append(current)
        return lines or [text]

    # Pre-compute the empty transparent frame (reused for all non-subtitle frames)
    _empty_frame = Image.new("RGBA", (width, height), (0, 0, 0, 0)).tobytes("raw", "RGBA")

    def _render_frame(text: str | None) -> bytes:
        """Render a single transparent frame with optional subtitle text."""
        if not text:
            return _empty_frame
        img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        draw = ImageDraw.Draw(img)
        # Pillow (with libraqm) already shapes RTL/bidi correctly, so we draw the
        # logical-order text as-is. Applying python-bidi here would double-reverse it.
        wrapped = _wrap_text(text, draw)
        line_height = font_size + 4
        block_height = len(wrapped) * line_height

        y = height - margin_bottom - block_height
        for line in wrapped:
            bbox = draw.textbbox((0, 0), line, font=pil_font)
            tw = bbox[2] - bbox[0]
            x = (width - tw) // 2

            # Draw outline
            for dx in range(-outline_width, outline_width + 1):
                for dy in range(-outline_width, outline_width + 1):
                    if dx != 0 or dy != 0:
                        draw.text((x + dx, y + dy), line, font=pil_font, fill=(0, 0, 0, 255))
            # Draw text
            draw.text((x, y), line, font=pil_font, fill=(255, 255, 255, 255))
            y += line_height

        return img.tobytes("raw", "RGBA")

    # Pipe rendered frames into ffmpeg as a second input and overlay
    overlay_cmd = [
        "ffmpeg",
        "-i", str(video_path),
        "-f", "rawvideo",
        "-pix_fmt", "rgba",
        "-s", f"{width}x{height}",
        "-r", str(fps),
        "-i", "pipe:0",
        "-filter_complex", "[0:v][1:v]overlay=0:0:format=auto",
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-preset", "medium",
        "-crf", "23",
        "-c:a", "copy",
        "-movflags", "+faststart",
        "-shortest",
        "-y",
        str(output_path),
    ]

    proc = subprocess.Popen(
        overlay_cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    # Generate frames and pipe them
    for frame_idx in range(total_frames):
        t = frame_idx / fps
        # Find active subtitle
        active_text = None
        for entry in entries:
            if entry["start"] <= t < entry["end"]:
                active_text = entry["text"]
                break
        proc.stdin.write(_render_frame(active_text))

    proc.stdin.close()
    _, stderr = proc.communicate(timeout=300)

    if proc.returncode != 0:
        raise RuntimeError(f"Subtitle overlay failed: {stderr.decode()[-500:]}")

    return output_path


# ---------------------------------------------------------------------------
# Social captions: heavy Hebrew font + word-by-word highlight (Pillow)
# ---------------------------------------------------------------------------

_BUNDLED_FONT = Path(__file__).parent / "data" / "fonts" / "Rubik.ttf"
_ACCENT = (255, 214, 10, 255)     # active word — punchy yellow
_WHITE = (255, 255, 255, 255)
_OUTLINE = (0, 0, 0, 255)


def _is_ltr_word(w: dict) -> bool:
    """A word is LTR if it has Latin letters/digits and no Hebrew — e.g. an
    English brand embedded in a Hebrew line ("OpenAI", "Thoma")."""
    text = w.get("text", "")
    has_hebrew = any("֐" <= c <= "׿" for c in text)
    has_latin = any(c.isascii() and c.isalnum() for c in text)
    return has_latin and not has_hebrew


def _bidi_word_order(words: list[dict]) -> list[dict]:
    """Reorder one caption line (logical order) into visual left-to-right for a
    base-RTL line: reverse the word sequence, but keep runs of consecutive LTR
    words (a multi-word English brand like "Thoma Bravo") in their own order so
    they don't come out reversed. Hebrew-only lines are simply reversed, as
    before. Internal glyph shaping of each word is still Pillow/libraqm's job.
    """
    runs: list[list] = []  # [is_ltr, [words]]
    for w in words:
        ltr = _is_ltr_word(w)
        if runs and runs[-1][0] == ltr:
            runs[-1][1].append(w)
        else:
            runs.append([ltr, [w]])
    out: list[dict] = []
    for ltr, run in reversed(runs):
        out.extend(run if ltr else list(reversed(run)))
    return out


def _load_caption_font(size: int, font: str | None = None):
    """Load a heavy Hebrew-capable caption font at `size`. Prefers an explicit
    override, then the bundled Rubik (pushed to its Black weight), then system
    Hebrew fonts, then Pillow's default."""
    from PIL import ImageFont

    candidates: list[str] = []
    if font and os.path.exists(font):
        candidates.append(font)
    if _BUNDLED_FONT.exists():
        candidates.append(str(_BUNDLED_FONT))
    candidates.extend(_HEBREW_FONT_CANDIDATES)
    for path in candidates:
        try:
            f = ImageFont.truetype(path, size)
        except Exception:
            continue
        try:  # Rubik is a variable font — go as heavy as possible for social
            f.set_variation_by_name("Black")
        except Exception:
            pass
        return f
    return ImageFont.load_default()


def _caption_entries(transcript: dict, start_time: float, end_time: float) -> list[dict]:
    """Group the clip's words into short caption chunks, KEEPING per-word timings
    (clip-relative) so the burn-in can highlight the word being spoken.

    Returns [{start, end, words: [{text, start, end}, ...]}, ...].
    """
    words: list[dict] = []
    for seg in transcript.get("segments", []):
        for w in seg.get("words", []):
            ws, we = w.get("start"), w.get("end")
            txt = (w.get("text") or "").strip()
            if ws is None or we is None or not txt:
                continue
            if we <= start_time or ws >= end_time:
                continue
            words.append({
                "text": txt,
                "start": max(ws, start_time) - start_time,
                "end": min(we, end_time) - start_time,
            })
    if not words:
        return []

    entries: list[dict] = []
    chunk: list[dict] = []
    punct = (".", "!", "?", ",", ";", ":", "…")
    max_words = 6      # short chunks read better in short-form
    max_span = 2.6

    def flush() -> None:
        if not chunk:
            return
        entries.append({
            "start": chunk[0]["start"],
            "end": max(chunk[-1]["end"], chunk[0]["start"] + 0.25),
            "words": [dict(c) for c in chunk],
        })
        chunk.clear()

    for w in words:
        chunk.append(w)
        span = w["end"] - chunk[0]["start"]
        if len(chunk) >= max_words or span >= max_span or w["text"].endswith(punct):
            flush()
    flush()
    return entries


def _probe_fps_frames(video_path: Path) -> tuple[float, int]:
    """Return (fps, total_frames) for a video via ffprobe."""
    probe = subprocess.run(
        ["ffprobe", "-v", "quiet", "-select_streams", "v:0",
         "-show_entries", "stream=r_frame_rate", "-of", "csv=p=0", str(video_path)],
        capture_output=True, text=True, timeout=10,
    )
    fps_str = probe.stdout.strip()
    if "/" in fps_str:
        num, den = fps_str.split("/")
        fps = float(num) / float(den) if float(den) else 30.0
    else:
        fps = float(fps_str) if fps_str else 30.0
    dur = subprocess.run(
        ["ffprobe", "-v", "quiet", "-show_entries", "format=duration",
         "-of", "csv=p=0", str(video_path)],
        capture_output=True, text=True, timeout=10,
    )
    total = float(dur.stdout.strip() or 0.0)
    return fps, int(total * fps)


def _overlay_pillow_frames(video_path: Path, output_path: Path, width: int,
                           height: int, make_frame) -> Path:
    """Composite Pillow-rendered transparent frames onto the video via ffmpeg.
    `make_frame(t)` returns raw RGBA bytes for the overlay at time t (seconds)."""
    fps, total_frames = _probe_fps_frames(video_path)
    cmd = [
        "ffmpeg", "-i", str(video_path),
        "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{width}x{height}",
        "-r", str(fps), "-i", "pipe:0",
        "-filter_complex", "[0:v][1:v]overlay=0:0:format=auto",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-preset", "medium", "-crf", "23",
        "-c:a", "copy", "-movflags", "+faststart", "-shortest", "-y", str(output_path),
    ]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE)
    for frame_idx in range(total_frames):
        proc.stdin.write(make_frame(frame_idx / fps))
    proc.stdin.close()
    _, stderr = proc.communicate(timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(f"Caption overlay failed: {stderr.decode()[-500:]}")
    return output_path


def _burn_captions_pillow(video_path: Path, entries: list[dict], output_path: Path,
                          width: int, height: int, font: str | None = None,
                          speed: float = 1.0) -> Path:
    """Burn word-highlighted Hebrew captions: heavy font, raised into the lower
    third, thick outline, the word being spoken popped in an accent colour.

    Words are laid out right-to-left (each word drawn in its own box, so Hebrew
    reads in the correct order and mixed digits/Latin stay upright), which also
    makes per-word colouring trivial.
    """
    from PIL import Image, ImageDraw

    if not entries:
        shutil.copy2(str(video_path), str(output_path))
        return output_path

    if speed and speed != 1.0:
        for e in entries:
            e["start"] /= speed
            e["end"] /= speed
            for w in e["words"]:
                w["start"] /= speed
                w["end"] /= speed

    font_size = max(28, height // 22)
    pil_font = _load_caption_font(font_size, font)
    outline = max(3, font_size // 8)
    line_h = int(font_size * 1.28)
    bottom_margin = int(height * 0.22)   # sit in the lower third, clear of the edge
    max_w = int(width * 0.90)

    measure = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    space_w = measure.textlength(" ", font=pil_font)

    def word_w(txt: str) -> float:
        return measure.textlength(txt, font=pil_font)

    def wrap(words: list[dict]) -> list[list[dict]]:
        lines: list[list[dict]] = []
        cur: list[dict] = []
        cur_w = 0.0
        for w in words:
            ww = word_w(w["text"])
            add = ww + (space_w if cur else 0)
            if cur and cur_w + add > max_w:
                lines.append(cur)
                cur, cur_w = [w], ww
            else:
                cur.append(w)
                cur_w += add
        if cur:
            lines.append(cur)
        return lines

    empty = Image.new("RGBA", (width, height), (0, 0, 0, 0)).tobytes("raw", "RGBA")

    def make_frame(t: float) -> bytes:
        active = None
        for e in entries:
            if e["start"] <= t < e["end"]:
                active = e
                break
        if active is None:
            return empty
        img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        lines = wrap(active["words"])
        y = height - bottom_margin - len(lines) * line_h
        for line in lines:
            order = _bidi_word_order(line)  # visual left-to-right (base RTL)
            lw = sum(word_w(w["text"]) for w in order) + space_w * (len(order) - 1)
            x = (width - lw) / 2  # left edge of the centered line
            for w in order:
                color = _ACCENT if (w["start"] <= t < w["end"]) else _WHITE
                d.text((x, y), w["text"], font=pil_font, fill=color,
                       stroke_width=outline, stroke_fill=_OUTLINE)
                x += word_w(w["text"]) + space_w
            y += line_h
        return img.tobytes("raw", "RGBA")

    return _overlay_pillow_frames(video_path, output_path, width, height, make_frame)


# ---------------------------------------------------------------------------
# Speaker-tracking crop (dynamic pan following the on-screen face)
# ---------------------------------------------------------------------------

def _face_track(video_path: Path, start: float, end: float,
                step: float = 0.25) -> tuple[list, float]:
    """Sample the dominant face x-fraction over the clip. Returns (samples,
    aspect_hw) where samples is [(t_rel_sec, cx_frac_or_None), ...], or ([], 0)
    if OpenCV / model / ffmpeg is unavailable or no face is ever found.

    Sampled ~4x/sec so a real ~0.6s shot registers as multiple samples (and gets
    followed) while a single-frame detector glitch stays a lone sample (ignored).
    """
    try:
        import cv2
    except Exception:
        return [], 0.0
    if not _FACE_MODEL.exists():
        return [], 0.0

    span = max(end - start, 0.001)
    n = max(3, min(int(span / step) + 1, 500))
    samples: list[tuple[float, float | None]] = []
    aspect_hw = 0.0
    with tempfile.TemporaryDirectory(prefix="hc_track_") as tmp:
        pattern = str(Path(tmp) / "f_%04d.png")
        cmd = [
            "ffmpeg", "-v", "error",
            "-ss", str(max(0.0, start)), "-t", str(span),
            "-i", str(video_path),
            "-vf", f"fps={n}/{span},scale=480:-1",
            "-frames:v", str(n), "-y", pattern,
        ]
        try:
            subprocess.run(cmd, capture_output=True, timeout=180, check=True)
        except Exception:
            return [], 0.0
        detector = None
        files = sorted(Path(tmp).glob("f_*.png"))
        for i, fp in enumerate(files):
            img = cv2.imread(str(fp))
            if img is None:
                continue
            h, w = img.shape[:2]
            aspect_hw = h / w
            if detector is None:
                detector = cv2.FaceDetectorYN.create(
                    str(_FACE_MODEL), "", (w, h), score_threshold=0.7,
                )
            else:
                detector.setInputSize((w, h))
            _, dets = detector.detect(img)
            t_rel = span * (i + 0.5) / n
            if dets is None or len(dets) == 0:
                samples.append((t_rel, None))
                continue
            best = max(dets, key=lambda d: float(d[2]) * float(d[3]) * float(d[-1]))
            cx = (float(best[0]) + float(best[2]) / 2) / w
            samples.append((t_rel, cx))

    if not aspect_hw or all(cx is None for _, cx in samples):
        return [], 0.0
    return samples, aspect_hw


def _dominant_position(values: list, prev: float, tol: float) -> float:
    """Dominant crop position among `values`: cluster by `tol`, pick the biggest
    cluster (ties broken toward the one nearest `prev` for continuity)."""
    import statistics
    s = sorted(values)
    groups: list[list[float]] = [[s[0]]]
    for v in s[1:]:
        if v - groups[-1][-1] <= tol:
            groups[-1].append(v)
        else:
            groups.append([v])
    best = max(groups, key=lambda g: (len(g), -abs(statistics.median(g) - prev)))
    return statistics.median(best)


def _pan_keyframes(samples: list, cut_delta: float = 0.12,
                   min_run: int = 2) -> list:
    """Turn raw face samples into (t, cx) keyframes for a stable pan.

    The crop should FOLLOW a genuine camera cut to another speaker, but must not
    chase isolated single-sample blips (detector noise, or a sub-second flash) —
    that was the jumpiness. So we group consecutive samples into runs at the same
    position and only COMMIT a move to a new position when its run lasts at least
    `min_run` samples (a real, sustained shot). Shorter runs are transient and
    inherit the last committed position (the crop holds). Committed positions are
    piecewise-constant with a near-instant snap between them.
    """
    import statistics

    ts = [t for t, _ in samples]
    xs: list = [cx for _, cx in samples]
    # forward then backward fill the None (no-face) gaps by holding
    last = None
    for i in range(len(xs)):
        if xs[i] is None:
            xs[i] = last
        else:
            last = xs[i]
    nxt = None
    for i in range(len(xs) - 1, -1, -1):
        if xs[i] is None:
            xs[i] = nxt
        else:
            nxt = xs[i]
    if any(v is None for v in xs):
        return []

    # Group consecutive samples into runs at (roughly) the same position.
    runs: list[list] = []  # [t_start, [values]]
    for t, x in zip(ts, xs):
        if runs and abs(x - statistics.median(runs[-1][1])) < cut_delta:
            runs[-1][1].append(x)
        else:
            runs.append([t, [x]])
    runs_r = [(t0, statistics.median(v), len(v)) for t0, v in runs]

    # Build committed positions. A run that persists as a clearly SUSTAINED shot
    # (>= stable_len samples, ~1.5s) is followed — the crop moves to frame that
    # speaker. Everything else is a BUSY region (rapid cuts / a multi-person
    # exchange): collapse the whole contiguous busy region to its DOMINANT face
    # position and hold that one value across it. This keeps the crop on a real
    # person (never the empty gap) without bouncing: clip-2's flurry collapses to
    # the main speaker, clip-6's exchange to its dominant participant. Busy regions
    # shorter than min_run samples are ignored as detector noise (hold).
    stable_len = 6
    committed: list[tuple[float, float]] = [(runs_r[0][0], runs_r[0][1])]
    i = 1
    while i < len(runs_r):
        t0, cx, cnt = runs_r[i]
        if cnt >= stable_len:
            if abs(cx - committed[-1][1]) >= cut_delta:
                committed.append((t0, cx))  # sustained shot -> follow it
            i += 1
            continue
        j = i
        bvals: list[float] = []
        while j < len(runs_r) and runs_r[j][2] < stable_len:
            bvals += [runs_r[j][1]] * runs_r[j][2]
            j += 1
        if len(bvals) >= min_run:
            dom = _dominant_position(bvals, committed[-1][1], cut_delta)
            if abs(dom - committed[-1][1]) >= cut_delta:
                committed.append((t0, dom))
        i = j

    # Piecewise-constant keyframes with a near-instant snap at each commit.
    kf: list[tuple[float, float]] = []
    for t, cx in committed:
        if kf:
            kf.append((max(t - 0.001, kf[-1][0] + 0.001), kf[-1][1]))  # hold, then snap
        kf.append((t, cx))
    kf.append((ts[-1], committed[-1][1]))
    return kf


def _piecewise_expr(kfs: list) -> str:
    """ffmpeg expression for cx(t): piecewise-linear through the keyframes."""
    kfs = sorted(kfs)
    expr = f"{kfs[-1][1]:.5f}"
    for (t0, c0), (t1, c1) in reversed(list(zip(kfs, kfs[1:]))):
        dt = max(t1 - t0, 1e-3)
        seg = f"({c0:.5f}+({(c1 - c0):.5f})*(t-{t0:.5f})/{dt:.5f})"
        expr = f"if(lt(t,{t1:.5f}),{seg},{expr})"
    return f"if(lt(t,{kfs[0][0]:.5f}),{kfs[0][1]:.5f},{expr})"


def _dynamic_crop_vf(aspect_ratio: str, keyframes: list) -> str:
    """Crop-to-fill vf whose x offset pans over time to follow the face track."""
    tw, th = _target_resolution(aspect_ratio)
    r = tw / th
    cw = f"ih*{r:.6f}"
    cx = _piecewise_expr(keyframes)
    # single-quote the expression values so their commas aren't parsed as filter
    # separators; eval=frame recomputes x every frame.
    # crop x/y expressions are evaluated per-frame (they can reference `t`), so the
    # window pans over time. Single-quote the values so their commas aren't parsed
    # as filtergraph separators.
    x = f"clip(({cx})*iw-({cw})/2,0,iw-({cw}))"
    crop = f"crop=w='{cw}':h=ih:x='{x}':y=0"
    return f"{crop},scale={tw}:{th}"


# ---------------------------------------------------------------------------
# ffmpeg runner + clip extraction
# ---------------------------------------------------------------------------

def _run_ffmpeg(cmd: list[str]) -> None:
    """Run an ffmpeg command and raise with a useful error on failure."""
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
    if result.returncode != 0:
        stderr = result.stderr.strip()
        error_lines = [
            line for line in stderr.splitlines()
            if not line.startswith((" ", "ffmpeg version", "  ", "lib"))
            and "Copyright" not in line
            and "configuration:" not in line
            and "built with" not in line
        ]
        error_msg = "\n".join(error_lines[-10:]) if error_lines else stderr[-500:]
        raise RuntimeError(f"ffmpeg failed: {error_msg}")


def extract_clip(
    source_video: Path,
    start_time: float,
    end_time: float,
    output_path: Path,
    aspect_ratio: str = "9:16",
    crop_position: float = 0.5,
    subtitles_path: Path | None = None,
    speed: float = 1.0,
    pad_seconds: float = 0.0,
    font: str | None = None,
    crop_vf: str | None = None,
    caption_entries: list | None = None,
    logo: str | None = None,
    logo_pos: str = "top-left",
) -> Path:
    """Extract a clip, crop-to-fill the target aspect, and burn captions.

    Crop-to-fill is always used (never letterbox). `crop_vf` overrides the crop
    filtergraph (used for the speaker-tracking dynamic pan); otherwise a static
    crop at `crop_position` is built.

    Captions: if `caption_entries` (word-level) is given, the word-highlight
    Pillow renderer is used (heavy font, active word popped). Else `subtitles_path`
    burns via libass when available, otherwise the plain Pillow fallback.

    pad_seconds defaults to 0: caption timestamps are relative to `start_time`,
    so any pre-roll pad would desync them.
    """
    padded_start = max(0, start_time - pad_seconds)
    padded_end = end_time + pad_seconds
    duration = padded_end - padded_start

    output_path.parent.mkdir(parents=True, exist_ok=True)

    tw, th = _target_resolution(aspect_ratio)

    # Crop-to-fill: dynamic pan (crop_vf) if given, else static at crop_position.
    vf = crop_vf if crop_vf else _build_crop_vf(aspect_ratio, crop_position)

    # Word-highlight captions render in a second Pillow pass over the cropped clip.
    burn_captions = bool(caption_entries)

    # Burn subtitles with libass BEFORE speed-up so subtitle timing matches
    # the original video timestamps (both get sped up together by setpts)
    _sub_symlink = None
    burn_with_pillow = False
    if not burn_captions and subtitles_path and subtitles_path.exists():
        if _HAS_SUBTITLES_FILTER:
            _sub_symlink = Path(tempfile.mktemp(suffix=".srt", prefix="hc_sub_"))
            _sub_symlink.symlink_to(subtitles_path.resolve())
            safe_sub_path = str(_sub_symlink).replace("\\", "\\\\").replace(":", "\\:")
            font_name = _libass_font_name(font)
            sub_style = (
                f"FontName={font_name},FontSize=22,PrimaryColour=&H00FFFFFF,"
                "OutlineColour=&H00000000,Outline=2,Bold=1"
            )
            vf += f",subtitles={safe_sub_path}:force_style='{sub_style}'"
        else:
            burn_with_pillow = True

    # Add speed-up filter AFTER subtitles (setpts for video)
    if speed and speed != 1.0:
        vf += f",setpts={1.0/speed}*PTS"
        af = f"atempo={speed}"
    else:
        af = None

    # Step 1: Extract and scale/crop the clip
    if burn_with_pillow or burn_captions:
        temp_clip = output_path.with_suffix(".tmp.mp4")
    else:
        temp_clip = output_path

    cmd = ["ffmpeg", "-ss", str(padded_start), "-i", str(source_video)]
    if logo and os.path.exists(logo):
        # Overlay a fixed logo AFTER the crop (so it doesn't pan with the face
        # track) and before captions. Sized to a fraction of frame width, inset
        # from the chosen corner; the logo PNG's aspect is preserved.
        lw = round(tw * 0.22)
        m = round(tw * 0.04)
        pos = {
            "top-left": f"{m}:{m}",
            "top-right": f"W-w-{m}:{m}",
            "bottom-left": f"{m}:H-h-{m}",
            "bottom-right": f"W-w-{m}:H-h-{m}",
        }.get(logo_pos, f"{m}:{m}")
        fc = (f"[0:v]{vf}[base];[1:v]scale={lw}:-1[lg];"
              f"[base][lg]overlay={pos}:format=auto[v]")
        cmd += ["-loop", "1", "-i", str(logo), "-t", str(duration),
                "-filter_complex", fc, "-map", "[v]", "-map", "0:a?"]
    else:
        cmd += ["-t", str(duration), "-vf", vf]
    if af:
        cmd += ["-af", af]
    cmd += [
        "-c:v", "libx264",
        "-pix_fmt", "yuv420p",
        "-preset", "medium",
        "-crf", "23",
        "-c:a", "aac",
        "-b:a", "128k",
        "-movflags", "+faststart",
        "-y",
        str(temp_clip),
    ]

    try:
        _run_ffmpeg(cmd)
    finally:
        if _sub_symlink and _sub_symlink.exists():
            _sub_symlink.unlink()

    # Step 2: Burn captions in a Pillow pass if needed
    if burn_captions:
        try:
            _burn_captions_pillow(temp_clip, caption_entries, output_path, tw, th,
                                  font=font, speed=speed)
        finally:
            if temp_clip.exists():
                temp_clip.unlink()
    elif burn_with_pillow:
        try:
            _burn_subtitles_pillow(temp_clip, subtitles_path, output_path, tw, th,
                                   speed=speed, font=font)
        finally:
            if temp_clip.exists():
                temp_clip.unlink()

    return output_path


# ---------------------------------------------------------------------------
# Transcript synthesis + public entry point
# ---------------------------------------------------------------------------

def _clip_transcript(clip: dict) -> dict:
    """Synthesize the transcript shape the caption functions expect from a clip.

    hebrew-chapters clips carry word timings relative to the clip start:
        {"t": <sec from clip start>, "d": <dur sec>, "w": <word text>}
    The caption code expects one segment with ABSOLUTE word start/end/text, so
    we offset each word by the clip's absolute start.
    """
    clip_start = float(clip["start"])
    words = []
    for w in clip.get("words", []):
        t = float(w["t"])
        d = float(w.get("d", 0.0))
        words.append({
            "start": clip_start + t,
            "end": clip_start + t + d,
            "text": w.get("w", ""),
        })
    seg_end = words[-1]["end"] if words else float(clip["end"])
    return {
        "segments": [
            {"start": clip_start, "end": seg_end, "words": words}
        ]
    }


def _prep_logo(logo_path: str, work_dir: str) -> str | None:
    """Trim a logo PNG to its opaque bounding box (the source often has big
    transparent margins) so it sits tight in the corner. Returns the trimmed
    path, or None if it can't be read."""
    try:
        from PIL import Image
    except Exception:
        return logo_path  # no Pillow: use as-is, ffmpeg still overlays it
    try:
        im = Image.open(logo_path).convert("RGBA")
    except Exception:
        return None
    bbox = im.getchannel("A").getbbox()  # bounds of non-transparent pixels
    if bbox:
        im = im.crop(bbox)
    out = Path(work_dir) / "_logo_trimmed.png"
    im.save(out)
    return str(out)


def render_clips(video_path: str, clips: list[dict], out_dir: str,
                 aspect: str = "9:16", subtitles: bool = True,
                 speed: float = 1.0, font: str | None = None,
                 logo: str | None = None, logo_pos: str = "top-left") -> list[str]:
    """Render each clip to out_dir/<id>.mp4, cropped-to-fill `aspect` with
    burned Hebrew captions from the clip's word timings. If `logo` is given, it's
    trimmed once and overlaid in the `logo_pos` corner of every clip. Returns the
    list of output paths."""
    source = Path(video_path)
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)

    # Env-var default so a logo can be set once and applied to every render
    # without passing --logo each time. An explicit logo always wins.
    logo = logo or os.environ.get("HEBREW_CHAPTERS_LOGO") or None
    logo_dir = None
    logo_ready = None
    if logo:
        logo_dir = tempfile.mkdtemp(prefix="hc_logo_")
        logo_ready = _prep_logo(logo, logo_dir)

    tw, th = _target_resolution(aspect)
    outputs: list[str] = []
    for clip in clips:
        clip_id = str(clip.get("id") or f"clip-{len(outputs) + 1}")
        start = float(clip["start"])
        end = float(clip["end"])
        output_path = out / f"{clip_id}.mp4"

        # Word-level caption entries (kept for the highlight burn-in).
        caption_entries = None
        if subtitles and clip.get("words"):
            caption_entries = _caption_entries(_clip_transcript(clip), start, end)

        # Framing: explicit `focus` [0,1] wins. Otherwise track the on-screen face
        # over the clip — pan the crop to follow it (fixes speakers going out of
        # frame when the camera cuts between people); if the face barely moves,
        # settle on a single face-centered crop; no face -> center.
        focus = clip.get("focus")
        crop_vf = None
        crop_position = 0.5
        if isinstance(focus, (int, float)):
            crop_position = float(focus)
        elif tw < th:
            samples, aspect_hw = _face_track(source, start, end)
            kf = _pan_keyframes(samples) if samples else []
            if kf:
                spread = max(c for _, c in kf) - min(c for _, c in kf)
                crop_w_frac = (tw / th) * aspect_hw
                if spread > 0.08:
                    crop_vf = _dynamic_crop_vf(aspect, kf)        # speaker-tracking pan
                else:
                    mid = sorted(c for _, c in kf)[len(kf) // 2]  # steady: face-centered
                    crop_position = _crop_position_for_face(mid, crop_w_frac)

        extract_clip(
            source_video=source,
            start_time=start,
            end_time=end,
            output_path=output_path,
            aspect_ratio=aspect,
            crop_position=crop_position,
            crop_vf=crop_vf,
            caption_entries=caption_entries,
            speed=speed,
            pad_seconds=0.0,
            font=font,
            logo=logo_ready,
            logo_pos=logo_pos,
        )
        outputs.append(str(output_path))

    if logo_dir:
        shutil.rmtree(logo_dir, ignore_errors=True)
    return outputs
