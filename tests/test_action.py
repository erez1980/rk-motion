import shutil
import subprocess

import pytest

from sofit.action import _normalise, _ranges, export_edited_movie


def test_normalise_limits_an_outlier():
    got = _normalise({0: 0.0, 1: 1.0, 2: 2.0, 3: 100.0})
    assert got[0] == 0.0
    assert got[3] == 1.0
    assert 0 < got[2] <= 1


def test_ranges_merges_a_single_quiet_second_and_applies_padding():
    clips = _ranges({0: 0, 1: .8, 2: .9, 3: 0, 4: .8, 5: .9, 6: 0},
                    threshold=.55, min_duration=4, padding=2, total_duration=10)
    assert len(clips) == 1
    assert clips[0]["start"] == 0
    assert clips[0]["end"] == 8


def test_ranges_can_split_long_suggestions_to_a_user_limit():
    clips = _ranges({second: .9 for second in range(10)}, threshold=.55,
                    min_duration=2, padding=0, total_duration=10, max_duration=3)
    assert [clip["duration"] for clip in clips] == [3, 3, 3, 1]


def _mean_volume(path: str, band: int, start: float, length: float = 1) -> float:
    """Mean dB of one frequency band over a window, via ffmpeg's volumedetect."""
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-ss", str(start), "-t", str(length), "-i", path,
         "-af", f"bandpass=f={band}:width_type=h:w={band // 10},volumedetect", "-f", "null", "-"],
        capture_output=True, text=True, check=True)
    line = [item for item in result.stderr.splitlines() if "mean_volume" in item][0]
    return float(line.split("mean_volume:")[1].strip().split(" ")[0])


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_music_fades_out_at_the_end_without_touching_the_ride_audio(tmp_path):
    """The soundtrack is cut at the movie's end, so it must fade, not stop dead."""
    ride, music = tmp_path / "ride.mp4", tmp_path / "music.mp3"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=320x180:rate=30:duration=12",
                    "-f", "lavfi", "-i", "sine=frequency=200:duration=12",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", str(ride)], check=True)
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "sine=frequency=880:duration=40", "-c:a", "libmp3lame", str(music)], check=True)

    output = str(tmp_path / "edit.mp4")
    export_edited_movie(str(ride), [{"start": 0, "end": 10, "duration": 10}], output,
                        music_paths=[str(music)], music_start=0)

    # The 880Hz music is much quieter at the end than at the start...
    assert _mean_volume(output, 880, 0) - _mean_volume(output, 880, 9) > 8
    # ...while the 200Hz ride audio keeps playing at the same level throughout.
    assert abs(_mean_volume(output, 200, 0) - _mean_volume(output, 200, 9)) < 2


def _frame_size(path: str) -> tuple[int, int]:
    result = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
         "stream=width,height", "-of", "csv=p=0", path],
        capture_output=True, text=True, check=True)
    width, height = result.stdout.strip().split(",")
    return int(width), int(height)


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_export_quality_caps_tall_sources_and_never_upscales(tmp_path):
    tall = tmp_path / "tall.mp4"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=320x1440:rate=30:duration=4",
                    "-c:v", "libx264", "-preset", "ultrafast", str(tall)], check=True)
    clips = [{"start": 0, "end": 3, "duration": 3}]

    capped = str(tmp_path / "capped.mp4")
    export_edited_movie(str(tall), clips, capped, quality="1080")
    assert _frame_size(capped)[1] == 1080

    original = str(tmp_path / "original.mp4")
    export_edited_movie(str(tall), clips, original, quality="original")
    assert _frame_size(original)[1] == 1440

    small = tmp_path / "small.mp4"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=320x180:rate=30:duration=4",
                    "-c:v", "libx264", "-preset", "ultrafast", str(small)], check=True)
    kept = str(tmp_path / "kept.mp4")
    export_edited_movie(str(small), clips, kept, quality="1080")
    assert _frame_size(kept) == (320, 180)  # never upscale a small source


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_prepare_source_uses_a_single_h264_file_without_reencoding(tmp_path):
    from sofit.ui import RKMotionHandler

    ride = tmp_path / "ride.mp4"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=320x180:rate=30:duration=3",
                    "-c:v", "libx264", "-preset", "ultrafast", str(ride)], check=True)
    before = ride.stat().st_mtime_ns
    source = RKMotionHandler._prepare_source([ride], tmp_path)
    assert source == ride
    assert ride.stat().st_mtime_ns == before  # untouched, zero quality loss
