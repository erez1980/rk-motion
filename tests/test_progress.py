"""Honest progress for the two long-running ffmpeg steps.

Converting a long 4K clip is the slowest thing the app does. It used to show a
bar derived from elapsed-time-over-a-guess, which pinned at 97% and said "עוד
רגע" for minutes once the guess ran out. These cover the replacement: a real
fraction read out of ffmpeg, and a time-left figure measured from the step's
own speed.
"""
import shutil
import subprocess

import pytest

from sofit.action import analyse_action, h264_args, h264_encoder, run_with_progress
from sofit.ui import _Phases


@pytest.fixture
def clip(tmp_path):
    path = tmp_path / "clip.mp4"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=160x90:rate=15:duration=6",
                    "-f", "lavfi", "-i", "sine=frequency=300:duration=6",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", str(path)], check=True)
    return path


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_run_with_progress_reports_real_ffmpeg_positions(clip, tmp_path):
    seen = []
    run_with_progress(
        ["ffmpeg", "-y", "-v", "error", "-i", str(clip), "-c:v", "libx264",
         "-preset", "ultrafast", str(tmp_path / "out.mp4")],
        total_seconds=6, progress=seen.append)

    assert seen, "ffmpeg should have reported where it was"
    assert all(0 <= value <= 1 for value in seen)
    assert seen == sorted(seen), "a progress bar must never go backwards"
    assert seen[-1] == 1.0
    assert (tmp_path / "out.mp4").exists()


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_run_with_progress_still_raises_when_ffmpeg_fails(tmp_path):
    with pytest.raises(subprocess.CalledProcessError) as caught:
        run_with_progress(["ffmpeg", "-y", "-v", "error", "-i", str(tmp_path / "nope.mp4"),
                           str(tmp_path / "out.mp4")], total_seconds=5, progress=lambda _: None)
    assert caught.value.stderr, "the ffmpeg error has to survive for the status message"


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_analyse_action_reports_progress_across_both_scans(clip):
    seen = []
    analyse_action(str(clip), progress=seen.append)

    assert seen == sorted(seen)
    assert all(0 <= value <= 1 for value in seen)
    assert max(seen) > .8, "the audio pass owns the last stretch of the bar"


def test_phases_weight_the_bar_and_measure_the_time_left(monkeypatch):
    """A slow first step must not let the bar sprint; the estimate comes from
    how fast the step is actually running, not from the up-front guess."""
    clock = [1000.0]
    monkeypatch.setattr("sofit.ui.time.monotonic", lambda: clock[0])

    status = {}
    phases = _Phases(status, [30.0, 10.0])   # convert is 3x the scan

    phases.start(0, "converting")
    assert status["message"] == "converting" and status["percent"] == 0

    clock[0] += 15
    phases.update(.5)                        # half of the first step
    assert status["percent"] == 38           # 15 of 40 weighted units
    # 15s bought half the conversion, so 15s of it are left plus the 10s scan.
    assert status["eta_seconds"] == 25

    phases.start(1, "scanning")
    clock[0] += 5
    phases.update(.5)
    assert status["percent"] == 88           # 35 of 40
    assert status["eta_seconds"] == 5

    phases.update(1.0)
    assert status["percent"] == 99           # only a finished job shows 100


def test_phases_stay_quiet_until_there_is_a_real_sample(monkeypatch):
    clock = [0.0]
    monkeypatch.setattr("sofit.ui.time.monotonic", lambda: clock[0])
    status = {}
    phases = _Phases(status, [10.0])
    phases.start(0, "working")

    clock[0] += 1
    phases.update(.01)
    assert "eta_seconds" not in status, "one second in, any estimate is noise"


def test_the_encoder_choice_matches_what_this_machine_can_run():
    """Hardware encoding is a macOS-only shortcut; everywhere else the quality
    knob stays CRF-based libx264."""
    encoder = h264_encoder()
    args = h264_args(3840, 2160, source_bitrate=45_000_000)
    if encoder == "libx264":
        assert args == ["-c:v", "libx264", "-crf", "18", "-preset", "veryfast"]
    else:
        assert args[:2] == ["-c:v", "h264_videotoolbox"]
        # Aim above the source so the conversion is not the weak link.
        assert int(args[args.index("-b:v") + 1]) > 45_000_000
    assert h264_encoder() is encoder, "the probe result is cached, not re-run per file"


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_a_multi_clip_batch_keeps_one_climbing_bar(tmp_path):
    """Dropping three rides in used to restart the bar at every file; each one
    now owns its own slice of the step."""
    from sofit.ui import RKMotionHandler

    inputs = []
    for index, size in enumerate(("320x180", "240x135")):
        path = tmp_path / f"input-{index:03d}.mp4"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                        "-i", f"testsrc2=size={size}:rate=15:duration=3",
                        "-c:v", "libx264", "-preset", "ultrafast", str(path)], check=True)
        inputs.append(path)

    seen = []
    RKMotionHandler._prepare_source(inputs, tmp_path, lambda message, fraction=0.0: seen.append(fraction))

    assert seen == sorted(seen), "the bar must never jump back to the start"
    assert max(seen) == 1.0


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")
def test_the_export_bar_climbs_across_all_of_its_passes(tmp_path):
    """Exporting is several passes over the movie — cut each clip, mix the
    music, fade the tail. All of them share one bar that only goes forward."""
    from sofit.action import export_edited_movie

    ride, music = tmp_path / "ride.mp4", tmp_path / "music.mp3"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=320x180:rate=15:duration=12",
                    "-f", "lavfi", "-i", "sine=frequency=200:duration=12",
                    "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", str(ride)], check=True)
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "sine=frequency=880:duration=20", "-c:a", "libmp3lame", str(music)], check=True)

    seen = []
    export_edited_movie(str(ride), [{"start": 0, "end": 4, "duration": 4},
                                    {"start": 6, "end": 10, "duration": 4}],
                        str(tmp_path / "edit.mp4"), music_paths=[str(music)],
                        progress=seen.append)

    assert seen == sorted(seen), "the bar must never jump back"
    assert all(0 <= value <= 1 for value in seen)
    assert seen[-1] == 1.0
    assert len([v for v in seen if 0 < v < 1]) >= 3, "the middle of the export should not be a dead zone"
