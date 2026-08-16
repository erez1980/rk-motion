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


def _normalise(values: dict[int, float]) -> dict[int, float]:
    """Robust 0..1 normalisation; a single flash/explosion cannot dominate."""
    nonzero = sorted(v for v in values.values() if v > 0)
    if not nonzero:
        return {k: 0.0 for k in values}
    cap = nonzero[max(0, math.ceil(len(nonzero) * .95) - 1)]
    floor = nonzero[max(0, math.floor(len(nonzero) * .15) - 1)]
    span = max(cap - floor, 1e-9)
    return {k: max(0.0, min(1.0, (v - floor) / span)) for k, v in values.items()}


def _motion_per_second(path: str, fps: int = 2, width: int = 160, height: int = 90) -> dict[int, float]:
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
    stderr = proc.stderr.read().decode("utf-8", "replace") if proc.stderr else ""
    if proc.wait() not in (0, None):
        raise RuntimeError(f"ffmpeg video analysis failed: {stderr[-500:]}")
    return {second: sum(samples) / len(samples) for second, samples in values.items()}


def _audio_per_second(path: str, sample_rate: int = 8000) -> dict[int, float]:
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
                   padding: int = 2, max_duration: float | None = None) -> dict:
    """Return ranked, reviewable action candidates for ``path``.

    Score weights deliberately favor motion (65%) over sound (35%), so music
    or a loud monologue alone is not reported as an action scene.
    """
    if not 0 < threshold <= 1:
        raise ValueError("threshold must be in the range 0..1")
    if min_duration < 1 or padding < 0:
        raise ValueError("min_duration must be >= 1 and padding must be >= 0")
    if max_duration is not None and max_duration < 1:
        raise ValueError("max_duration must be at least 1 second")
    total = duration(path)
    motion = _motion_per_second(path)
    audio = _audio_per_second(path)
    motion_n, audio_n = _normalise(motion), _normalise(audio)
    all_seconds = range(max(1, math.ceil(total)))
    scores = {sec: .65 * motion_n.get(sec, 0.0) + .35 * audio_n.get(sec, 0.0)
              for sec in all_seconds}
    return {
        "source": str(Path(path).resolve()),
        "duration": round(total, 2),
        "detector": {"video_fps": 2, "score": "65% motion + 35% loudness",
                     "threshold": threshold, "padding": padding,
                     "max_duration": max_duration},
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


def _has_audio(path: str) -> bool:
    result = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "a:0",
                             "-show_entries", "stream=index", "-of", "csv=p=0", path],
                            capture_output=True, text=True, check=True)
    return bool(result.stdout.strip())


def export_edited_movie(path: str, clips: list[dict], output: str,
                        transition: str = "cut", transition_duration: float = .5) -> str:
    """Join approved clips, optionally applying a video/audio transition."""
    if not clips:
        raise ValueError("select at least one clip before exporting")
    _need_ffmpeg()
    if transition not in TRANSITIONS:
        raise ValueError(f"unsupported transition: {transition}")
    if not .1 <= transition_duration <= 3:
        raise ValueError("transition duration must be between 0.1 and 3 seconds")
    target = Path(output)
    target.parent.mkdir(parents=True, exist_ok=True)
    if transition != "cut" and len(clips) > 1:
        return _export_with_transitions(path, clips, target, transition, transition_duration)
    with tempfile.TemporaryDirectory(prefix="rk-motion-") as tmp:
        parts = []
        for index, clip in enumerate(clips, 1):
            start, end = float(clip["start"]), float(clip["end"])
            if end <= start or start < 0:
                raise ValueError("every clip needs a valid start and end time")
            part = Path(tmp) / f"part-{index:03d}.mp4"
            subprocess.run(
                ["ffmpeg", "-y", "-v", "error", "-ss", str(start), "-i", path,
                 "-t", str(end - start), "-map", "0:v:0", "-map", "0:a?",
                 "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-c:a", "aac",
                 "-movflags", "+faststart", str(part)], check=True, capture_output=True,
            )
            parts.append(part)
        listing = Path(tmp) / "concat.txt"
        # Paths generated above are trusted local temp files. ffconcat quotes apostrophes.
        listing.write_text("".join("file '" + str(part).replace("'", "'\\\\''") + "'\n" for part in parts))
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
                        "-i", str(listing), "-c", "copy", "-movflags", "+faststart", str(target)],
                       check=True, capture_output=True)
    return str(target)


def _export_with_transitions(path: str, clips: list[dict], target: Path,
                             transition: str, transition_duration: float) -> str:
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
    cmd.extend(["-filter_complex", ";".join(filters), "-map", f"[{current_video}]"])
    if audio:
        cmd.extend(["-map", f"[{current_audio}]"])
    cmd.extend(["-c:v", "libx264", "-crf", "18", "-preset", "medium"])
    if audio:
        cmd.extend(["-c:a", "aac"])
    cmd.extend(["-movflags", "+faststart", str(target)])
    subprocess.run(cmd, check=True, capture_output=True)
    return str(target)
