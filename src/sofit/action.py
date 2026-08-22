"""Local, no-AI action-scene detection.

The detector intentionally does not try to decide whether a scene is *good*.
It ranks time ranges with sustained visual movement, hard shot changes and loud
audio, then lets the editor review the short list.  It uses only ffmpeg and the
Python standard library: source footage never leaves the machine.
"""
from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path


def _need_ffmpeg() -> None:
    if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
        raise RuntimeError("action detection needs ffmpeg and ffprobe on PATH")


def duration(path: str) -> float:
    _need_ffmpeg()
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", path],
        capture_output=True, text=True, check=True,
    )
    return float(result.stdout.strip())


def run_with_progress(cmd: list[str], total_seconds: float, progress=None) -> None:
    """Run an ffmpeg command, reporting a real 0..1 fraction as it works.

    ffmpeg knows exactly how far into the footage it is; asking it (via
    ``-progress``) beats guessing from elapsed time, which is what left long
    conversions sitting on a full bar with nothing to say.
    """
    if progress is None or total_seconds <= 0:
        subprocess.run(cmd, check=True, capture_output=True)
        return
    watched = [cmd[0], "-progress", "pipe:1", "-nostats", *cmd[1:]]
    proc = subprocess.Popen(watched, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert proc.stdout
    for line in proc.stdout:
        key, _, value = line.strip().partition("=")
        if key == "out_time_us" and value.isdigit():
            progress(min(1.0, int(value) / 1e6 / total_seconds))
    stderr = proc.stderr.read() if proc.stderr else ""
    if proc.wait() != 0:
        raise subprocess.CalledProcessError(proc.returncode, cmd, stderr=stderr)
    progress(1.0)


class _Stages:
    """Maps a sequence of ffmpeg passes onto one 0..1 bar.

    An export is several passes over the movie (cut every clip, mix music,
    fade the tail). Weighting them by relative cost keeps the bar moving at a
    steady speed instead of leaping between stages.
    """

    def __init__(self, progress, weights: list[float]) -> None:
        self._progress = progress
        self._weights = [max(w, 1e-6) for w in weights] or [1.0]
        self._total = sum(self._weights)
        self._index = -1

    def next(self):
        """Advance to the next pass and return its progress callback."""
        self._index = min(self._index + 1, len(self._weights) - 1)
        return None if self._progress is None else self._report

    def _report(self, fraction: float) -> None:
        fraction = min(1.0, max(0.0, fraction))
        done = sum(self._weights[:self._index]) + self._weights[self._index] * fraction
        self._progress(done / self._total)


# H.264 encoders that run on the GPU (or a dedicated media block), best first
# per platform. Left out on purpose: h264_vaapi, which needs a device and an
# hwupload filter chain this app does not build, so it could only ever fail.
HARDWARE_ENCODERS = {
    "darwin": ["h264_videotoolbox"],                   # Apple Silicon and Intel Macs
    "win32": ["h264_nvenc", "h264_qsv", "h264_amf"],   # NVIDIA, Intel, AMD
    "linux": ["h264_nvenc", "h264_qsv"],
}
SOFTWARE_ENCODE = ["-crf", "18", "-preset", "veryfast"]
_H264_ENCODER: str | None = None


def h264_encoder() -> str:
    """The fastest H.264 encoder that actually works on this machine.

    Re-encoding a long 4K ride with libx264 is by far the slowest thing the app
    does — minutes of pegged CPU. Every modern machine has a video encoder in
    its GPU, so probe the platform's candidates with a tiny real encode and
    take the first that produces frames. Being listed by ffmpeg is not enough:
    the driver can be missing, and ffmpeg only finds that out by trying.
    """
    global _H264_ENCODER
    if _H264_ENCODER is not None:
        return _H264_ENCODER
    _H264_ENCODER = "libx264"
    try:
        listed = subprocess.run(["ffmpeg", "-hide_banner", "-encoders"],
                                capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return _H264_ENCODER
    for name in HARDWARE_ENCODERS.get(sys.platform, []):
        if name not in listed:
            continue
        probe = subprocess.run(
            ["ffmpeg", "-v", "error", "-f", "lavfi",
             "-i", "testsrc2=size=320x240:rate=10:duration=0.5",
             "-c:v", name, "-pix_fmt", "yuv420p", "-f", "null", "-"], capture_output=True)
        if probe.returncode == 0:
            _H264_ENCODER = name
            break
    return _H264_ENCODER


def h264_args(width: int = 0, height: int = 0, source_bitrate: int = 0,
              bpp: float = .15, software: list[str] | None = None) -> list[str]:
    """Encoder settings for this machine's best H.264 encoder.

    GPU encoders have no CRF knob, so quality is held with a bitrate derived
    from the frame size — and, when converting, never below what the source
    already used, so the conversion is not the weak link.
    """
    encoder = h264_encoder()
    if encoder == "libx264":
        return ["-c:v", "libx264", *(software or SOFTWARE_ENCODE)]
    sized = int(width * height * 30 * bpp) if width and height else 12_000_000
    target = min(max(int(max(sized, source_bitrate * 1.25)), 2_000_000), 80_000_000)
    return ["-c:v", encoder, "-b:v", str(target),
            "-maxrate", str(int(target * 1.5)), "-bufsize", str(target * 2)]


def _software_encode(cmd: list[str]) -> list[str]:
    """Rewrite a GPU-encoder command to use libx264 instead."""
    out = list(cmd)
    index = out.index("-c:v")
    out[index + 1] = "libx264"
    tail = index + 2
    while tail < len(out) - 1 and out[tail] in {"-b:v", "-maxrate", "-bufsize"}:
        del out[tail:tail + 2]
    out[tail:tail] = SOFTWARE_ENCODE
    return out


def run_encode(cmd: list[str], total_seconds: float, progress=None) -> None:
    """Run an encode, retrying on the CPU if the GPU encoder gives up.

    GPU encoders are the flakiest part of ffmpeg — a driver can refuse a
    resolution the probe never tried — and losing a long export to that would
    be far worse than spending the extra minutes in software.
    """
    global _H264_ENCODER
    try:
        run_with_progress(cmd, total_seconds, progress)
    except subprocess.CalledProcessError:
        if not _H264_ENCODER or _H264_ENCODER == "libx264" or _H264_ENCODER not in cmd:
            raise
        _H264_ENCODER = "libx264"   # one failure is enough; stop trying this session
        run_with_progress(_software_encode(cmd), total_seconds, progress)


def _normalise(values: dict[int, float]) -> dict[int, float]:
    """Robust 0..1 normalisation; a single flash/explosion cannot dominate."""
    nonzero = sorted(v for v in values.values() if v > 0)
    if not nonzero:
        return {k: 0.0 for k in values}
    cap = nonzero[max(0, math.ceil(len(nonzero) * .95) - 1)]
    floor = nonzero[max(0, math.floor(len(nonzero) * .15) - 1)]
    span = max(cap - floor, 1e-9)
    return {k: max(0.0, min(1.0, (v - floor) / span)) for k, v in values.items()}


def _motion_per_second(path: str, fps: int = 2, width: int = 160, height: int = 90,
                       progress=None) -> dict[int, float]:
    """Average absolute luma-frame difference, sampled cheaply at low resolution."""
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-an", "-vf",
           f"fps={fps},scale={width}:{height}:flags=fast_bilinear,format=gray",
           "-f", "rawvideo", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout
    frame_size = width * height
    previous: bytes | None = None
    values: dict[int, list[float]] = defaultdict(list)
    index = 0
    while True:
        frame = proc.stdout.read(frame_size)
        if len(frame) != frame_size:
            break
        if previous is not None:
            # sum() on generator avoids a heavy CV dependency and is fine at 160x90.
            diff = sum(abs(a - b) for a, b in zip(frame, previous)) / (255 * frame_size)
            values[int(index / fps)].append(diff)
        previous = frame
        index += 1
        if progress and index % (fps * 2) == 0:
            progress(index / fps)
    stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
    if proc.wait() not in (0, None):
        raise RuntimeError(f"ffmpeg video analysis failed: {stderr[-500:]}")
    return {second: sum(samples) / len(samples) for second, samples in values.items()}


def _audio_per_second(path: str, sample_rate: int = 8000, progress=None) -> dict[int, float]:
    """RMS loudness per second from a small mono PCM stream."""
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar",
           str(sample_rate), "-f", "s16le", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert proc.stdout
    block = sample_rate * 2
    out: dict[int, float] = {}
    second = 0
    while True:
        raw = proc.stdout.read(block)
        if not raw:
            break
        samples = memoryview(raw).cast("h")
        if samples:
            out[second] = math.sqrt(sum(x * x for x in samples) / len(samples)) / 32768
        second += 1
        if progress and second % 5 == 0:
            progress(second)
    # Some silent/no-audio videos make ffmpeg exit 1; visual scoring still works.
    proc.wait()
    return out


def _ranges(scores: dict[int, float], threshold: float, min_duration: int,
            padding: int, total_duration: float, max_duration: float | None = None) -> list[dict]:
    active = [sec for sec in sorted(scores) if scores[sec] >= threshold]
    groups: list[list[int]] = []
    for sec in active:
        if groups and sec <= groups[-1][-1] + 2:  # tolerate one quiet second
            groups[-1].append(sec)
        else:
            groups.append([sec])
    clips = []
    for group in groups:
        start, end = max(0, group[0] - padding), min(total_duration, group[-1] + 1 + padding)
        if end - start < min_duration:
            continue
        clip_scores = [scores.get(sec, 0.0) for sec in range(group[0], group[-1] + 1)]
        score = round(sum(clip_scores) / len(clip_scores), 3)
        # A creator can ask for bite-size suggestions.  Split, don't discard,
        # so every detected action moment remains available for review.
        if max_duration and end - start > max_duration:
            cursor = start
            while cursor < end:
                chunk_end = min(end, cursor + max_duration)
                clips.append({"start": round(cursor, 2), "end": round(chunk_end, 2),
                              "duration": round(chunk_end - cursor, 2), "score": score})
                cursor = chunk_end
        else:
            clips.append({"start": round(start, 2), "end": round(end, 2),
                          "duration": round(end - start, 2), "score": score})
    return sorted(clips, key=lambda clip: clip["score"], reverse=True)


def analyse_action(path: str, threshold: float = .55, min_duration: int = 5,
                   padding: int = 2, max_duration: float | None = None,
                   progress=None) -> dict:
    """Return ranked, reviewable action candidates for ``path``.

    Score weights deliberately favor motion (65%) over sound (35%), so music
    or a loud monologue alone is not reported as an action scene.

    ``progress`` is called with a 0..1 fraction of the scan. The two passes
    read the same footage but the visual one costs several times more, which
    is why it owns most of the bar.
    """
    if not 0 < threshold <= 1:
        raise ValueError("threshold must be in the range 0..1")
    if min_duration < 1 or padding < 0:
        raise ValueError("min_duration must be >= 1 and padding must be >= 0")
    if max_duration is not None and max_duration < 1:
        raise ValueError("max_duration must be at least 1 second")
    total = duration(path)
    span = max(total, 1.0)
    def at(base: float, weight: float):
        return (lambda seconds: progress(base + weight * min(1.0, seconds / span))) if progress else None
    motion = _motion_per_second(path, progress=at(0.0, .8))
    audio = _audio_per_second(path, progress=at(.8, .2))
    motion_n, audio_n = _normalise(motion), _normalise(audio)
    all_seconds = range(max(1, math.ceil(total)))
    scores = {sec: .65 * motion_n.get(sec, 0.0) + .35 * audio_n.get(sec, 0.0)
              for sec in all_seconds}
    return {
        "source": str(Path(path).resolve()),
        "duration": round(total, 2),
        "detector": {"video_fps": 2, "score": "65% motion + 35% loudness",
                     "threshold": threshold, "min_duration": min_duration,
                     "padding": padding, "max_duration": max_duration},
        # Per-second combined scores let a client rebuild the clip list at any
        # threshold instantly, without re-analysing the video.
        "scores": [round(scores[sec], 3) for sec in all_seconds],
        "clips": _ranges(scores, threshold, min_duration, padding, total, max_duration),
    }


def write_action_report(path: str, output: str, **kwargs: object) -> dict:
    report = analyse_action(path, **kwargs)
    Path(output).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return report


def render_action_clips(path: str, clips: list[dict], output_dir: str) -> list[str]:
    """Export candidates as reviewable MP4s, preserving the original audio.

    Re-encoding (rather than ``-c copy``) makes requested boundaries accurate on
    footage whose keyframes are far apart, which is usually what an editor wants.
    """
    _need_ffmpeg()
    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    outputs = []
    for index, clip in enumerate(clips, 1):
        target = out / f"action-{index:02d}-{clip['start']:08.2f}-{clip['end']:08.2f}.mp4"
        cmd = ["ffmpeg", "-y", "-v", "error", "-ss", str(clip["start"]), "-i", path,
               "-t", str(clip["duration"]), "-map", "0:v:0", "-map", "0:a?",
               "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-c:a", "aac",
               "-movflags", "+faststart", str(target)]
        subprocess.run(cmd, check=True, capture_output=True)
        outputs.append(str(target))
    return outputs


TRANSITIONS = {"cut", "fade", "wipeleft", "slideright", "dissolve"}
MUSIC_FADE_OUT = 3.0  # seconds of fade at the end of the soundtrack

# Export quality profiles: max output height (None keeps the source size) and
# encoder settings. "whatsapp" trades quality for a small file that survives
# WhatsApp's own re-compression better than a huge one.
# `encode` is libx264's own quality knob; `bpp` (bits per pixel per second) is
# the same intent expressed for GPU encoders, which have no CRF.
QUALITY_PROFILES = {
    "720": {"max_height": 720, "bpp": .15, "encode": ["-crf", "18", "-preset", "medium"]},
    "1080": {"max_height": 1080, "bpp": .15, "encode": ["-crf", "18", "-preset", "medium"]},
    "original": {"max_height": None, "bpp": .15, "encode": ["-crf", "18", "-preset", "medium"]},
    "whatsapp": {"max_height": 720, "bpp": .06,
                 "encode": ["-crf", "26", "-preset", "medium",
                            "-maxrate", "2500k", "-bufsize", "5000k"]},
}


def _output_size(path: str, max_height: int | None, aspect: str) -> tuple[int, int]:
    """The frame this export will actually produce, for sizing the bitrate."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=width,height", "-of", "csv=p=0", path],
            capture_output=True, text=True, check=True)
        width, height = (int(value) for value in result.stdout.strip().split(",")[:2])
    except Exception:
        return 1920, 1080          # a sane middle when the source will not say
    if max_height and height > max_height:
        width, height = round(width * max_height / height), max_height
    if aspect == "9:16":
        width = height * 9 // 16   # the frame is cropped, not letterboxed
    return max(width, 2), max(height, 2)


def _encode_args(path: str, profile: dict, aspect: str) -> list[str]:
    """Encoder settings sized to what this export will actually produce."""
    width, height = _output_size(path, profile["max_height"], aspect)
    return h264_args(width, height, bpp=profile["bpp"], software=profile["encode"])


FADE_OUT_SECONDS = 1.0
ASPECTS = {"16:9", "9:16"}


def _scale_filter(max_height: int | None) -> str | None:
    """Downscale-only filter: small sources are never blown up."""
    if max_height is None:
        return None
    return f"scale=-2:'min({max_height},ih)'"


def _crop_filter(max_height: int | None) -> str:
    """Center-crop/scale to a 9:16 vertical frame for Stories/Reels."""
    height = max_height or 1920
    width = (height * 9 // 16) // 2 * 2  # even width, required by most encoders
    return f"scale=w={width}:h={height}:force_original_aspect_ratio=increase,crop={width}:{height}"


def _frame_filter(aspect: str, max_height: int | None) -> str | None:
    return _crop_filter(max_height) if aspect == "9:16" else _scale_filter(max_height)


def _has_audio(path: str) -> bool:
    result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                             "-show_entries", "stream=index", "-of", "csv=p=0", path],
                            capture_output=True, text=True, check=True)
    return bool(result.stdout.strip())


def export_edited_movie(path: str, clips: list[dict], output: str,
                        transition: str = "cut", transition_duration: float = .5,
                        music_paths: list[str] | None = None, music_start: float = 0,
                        speed: float = 1.0, remove_original_audio: bool = False,
                        quality: str = "1080", music_volume: float = .65,
                        aspect: str = "16:9", progress=None) -> str:
    """Join approved clips, optionally applying a video/audio transition.

    ``progress`` is called with a 0..1 fraction of the whole export, measured
    from ffmpeg's own position in each pass rather than from elapsed time.
    """
    if not clips:
        raise ValueError("select at least one clip before exporting")
    _need_ffmpeg()
    if transition not in TRANSITIONS:
        raise ValueError(f"unsupported transition: {transition}")
    if not .1 <= transition_duration <= 3:
        raise ValueError("transition duration must be between 0.1 and 3 seconds")
    profile = QUALITY_PROFILES.get(str(quality))
    if not profile:
        raise ValueError(f"unsupported quality: {quality}")
    if not 0 < music_volume <= 2:
        raise ValueError("music volume must be between 0 and 2")
    if aspect not in ASPECTS:
        raise ValueError(f"unsupported aspect: {aspect}")
    if speed not in {1.0, 1.25, 1.5, 2.0}:
        raise ValueError("speed must be 1, 1.25, 1.5 or 2")
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    # Relative cost of each remaining pass: re-encodes cost about one pass over
    # the movie each, mixing music only touches the audio.
    weights = [1.0]
    if speed != 1:
        weights.append(1.0)
    if music_paths:
        weights.append(.2)
    weights.append(1.0)                       # the closing fade re-encodes too
    stages = _Stages(progress, weights)
    if transition != "cut" and len(clips) > 1:
        _export_with_transitions(path, clips, target, transition, transition_duration,
                                 profile, aspect, stages.next())
    else:
        _export_hard_cuts(path, clips, target, profile, aspect, stages.next())
    if speed != 1:
        _speed_up_movie(target, speed, stages.next())
    if remove_original_audio:
        _strip_audio(target)
    if music_paths:
        _mix_music(target, music_paths, music_start, music_volume, stages.next())
    # Every export ends on a fade to black instead of a hard cut, whether or
    # not there is a soundtrack fading its own tail.
    _fade_out_movie(target, profile, progress=stages.next())
    if progress:
        progress(1.0)
    return str(target)


def _fade_out_movie(target: Path, profile: dict, fade: float = FADE_OUT_SECONDS,
                    progress=None) -> None:
    movie_duration = duration(str(target))
    fade = min(fade, movie_duration / 2)
    start = max(0, movie_duration - fade)
    faded = target.with_name(target.stem + ".faded.mp4")
    cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(target),
           "-vf", f"fade=t=out:st={start:.3f}:d={fade:.3f}", "-map", "0:v:0"]
    if _has_audio(str(target)):
        cmd.extend(["-af", f"afade=t=out:st={start:.3f}:d={fade:.3f}", "-map", "0:a:0", "-c:a", "aac"])
    cmd.extend([*_encode_args(str(target), profile, "16:9"),   # already the final frame
                "-movflags", "+faststart", str(faded)])
    run_encode(cmd, movie_duration, progress)
    faded.replace(target)


def _export_hard_cuts(path: str, clips: list[dict], target: Path, profile: dict,
                      aspect: str = "16:9", progress=None) -> None:
    frame = _frame_filter(aspect, profile["max_height"])
    lengths = [max(0.0, float(clip["end"]) - float(clip["start"])) for clip in clips]
    movie = sum(lengths) or 1.0
    with tempfile.TemporaryDirectory(prefix="rk-motion-") as tmp:
        parts = []
        cut = 0.0                      # movie seconds already written
        for index, clip in enumerate(clips, 1):
            start, end = float(clip["start"]), float(clip["end"])
            if end <= start or start < 0:
                raise ValueError("every clip needs a valid start and end time")
            part = Path(tmp) / f"part-{index:03d}.mp4"
            cmd = ["ffmpeg", "-y", "-v", "error", "-ss", str(start), "-i", path,
                   "-t", str(end - start), "-map", "0:v:0", "-map", "0:a?"]
            if frame:
                cmd.extend(["-vf", frame])
            cmd.extend([*_encode_args(path, profile, aspect), "-c:a", "aac",
                        "-movflags", "+faststart", str(part)])
            # Each clip advances the bar by its own share of the finished movie,
            # so a long clip does not look like a stall.
            done, length = cut, lengths[index - 1]
            run_encode(cmd, length,
                       (lambda f: progress((done + length * f) / movie)) if progress else None)
            cut += length
            parts.append(part)
        listing = Path(tmp) / "concat.txt"
        # Paths generated above are trusted local temp files. ffconcat quotes apostrophes.
        listing.write_text("".join("file '" + str(part).replace("'", "'\\\\''") + "'\n" for part in parts))
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
                        "-i", str(listing), "-c", "copy", "-movflags", "+faststart", str(target)],
                       check=True, capture_output=True)


def _speed_up_movie(target: Path, speed: float, progress=None) -> None:
    """Change video and its original sound together, before music is mixed."""
    fast = target.with_name(target.stem + ".fast.mp4")
    cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(target), "-filter:v", f"setpts=PTS/{speed}",
           "-map", "0:v:0"]
    if _has_audio(str(target)):
        cmd.extend(["-filter:a", f"atempo={speed}", "-map", "0:a:0", "-c:a", "aac"])
    cmd.extend([*h264_args(*_output_size(str(target), None, "16:9")),
                "-movflags", "+faststart", str(fast)])
    run_encode(cmd, duration(str(target)) / speed, progress)
    fast.replace(target)


def _strip_audio(target: Path) -> None:
    """Remove original camera/ride audio before optional music is mixed."""
    silent = target.with_name(target.stem + ".silent.mp4")
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", str(target), "-map", "0:v:0",
                    "-c:v", "copy", "-an", "-movflags", "+faststart", str(silent)],
                   check=True, capture_output=True)
    silent.replace(target)


def _mix_music(target: Path, music_paths: list[str], music_start: float,
               music_volume: float = .65, progress=None) -> None:
    """Mix music starting at ``music_start`` within the source track(s)."""
    music = [Path(item) for item in music_paths]
    if not music or any(not item.is_file() for item in music):
        raise ValueError("selected music file is unavailable")
    if music_start < 0:
        raise ValueError("music start must not be negative")
    movie_duration = duration(str(target))
    mixed = target.with_name(target.stem + ".with-music.mp4")
    cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(target)]
    if len(music) == 1:
        # Seek *inside* the MP3 before it is looped. The movie therefore gets
        # music immediately at t=0, rather than silence until music_start.
        cmd.extend(["-ss", str(music_start), "-stream_loop", "-1", "-i", str(music[0])])
        playlist = "[1:a]"
    else:
        for item in music:
            cmd.extend(["-i", str(item)])
        playlist = "".join(f"[{index}:a]" for index in range(1, len(music) + 1))
        # asetpts rebases the trimmed playlist to t=0; without it the kept
        # timestamps would delay the music by music_start seconds.
        playlist += (f"concat=n={len(music)}:v=0:a=1[playlist];"
                     f"[playlist]atrim=start={music_start},asetpts=PTS-STARTPTS,")
    # The soundtrack is cut at the movie's end, so always fade it out instead
    # of stopping mid-note.
    fade = min(MUSIC_FADE_OUT, movie_duration / 2)
    audio_filter = (f"{playlist}volume={music_volume},"
                    f"afade=t=out:st={max(0, movie_duration - fade):.3f}:d={fade:.3f}[music]")
    if _has_audio(str(target)):
        audio_filter += ";[0:a][music]amix=inputs=2:duration=first:dropout_transition=2[mixed]"
        maps = ["-map", "0:v:0", "-map", "[mixed]"]
    else:
        maps = ["-map", "0:v:0", "-map", "[music]"]
    cmd.extend(["-filter_complex", audio_filter, *maps, "-t", str(movie_duration),
                "-c:v", "copy", "-c:a", "aac", "-movflags", "+faststart", str(mixed)])
    run_with_progress(cmd, movie_duration, progress)
    mixed.replace(target)


def _export_with_transitions(path: str, clips: list[dict], target: Path,
                             transition: str, transition_duration: float,
                             profile: dict, aspect: str = "16:9", progress=None) -> str:
    """Use xfade/acrossfade directly from the source for smooth joined clips."""
    audio = _has_audio(path)
    durations: list[float] = []
    cmd = ["ffmpeg", "-y", "-v", "error"]
    for clip in clips:
        start, end = float(clip["start"]), float(clip["end"])
        if end <= start or start < 0:
            raise ValueError("every clip needs a valid start and end time")
        durations.append(end - start)
        cmd.extend(["-ss", str(start), "-t", str(end - start), "-i", path])
    filters: list[str] = []
    for index in range(len(clips)):
        filters.append(f"[{index}:v]setpts=PTS-STARTPTS[v{index}]")
        if audio:
            filters.append(f"[{index}:a]asetpts=PTS-STARTPTS[a{index}]")
    current_video, current_audio = "v0", "a0"
    timeline = durations[0]
    for index in range(1, len(clips)):
        # A transition cannot be longer than either side of its join.
        fade = min(transition_duration, durations[index] / 2, timeline / 2)
        next_video = f"vx{index}"
        filters.append(f"[{current_video}][v{index}]xfade=transition={transition}:duration={fade:.3f}:offset={timeline - fade:.3f}[{next_video}]")
        current_video = next_video
        if audio:
            next_audio = f"ax{index}"
            filters.append(f"[{current_audio}][a{index}]acrossfade=d={fade:.3f}[{next_audio}]")
            current_audio = next_audio
        timeline += durations[index] - fade
    frame = _frame_filter(aspect, profile["max_height"])
    if frame:
        # Every input is a cut of the same source, so one scale/crop on the
        # joined stream is enough.
        filters.append(f"[{current_video}]{frame}[vscaled]")
        current_video = "vscaled"
    cmd.extend(["-filter_complex", ";".join(filters), "-map", f"[{current_video}]"])
    if audio:
        cmd.extend(["-map", f"[{current_audio}]"])
    cmd.extend(_encode_args(path, profile, aspect))
    if audio:
        cmd.extend(["-c:a", "aac"])
    cmd.extend(["-movflags", "+faststart", str(target)])
    run_encode(cmd, timeline, progress)
    return str(target)
