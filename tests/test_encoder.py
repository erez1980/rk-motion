"""Picking (and surviving) the machine's video encoder.

Re-encoding is the slowest thing the app does, so it should use the GPU
encoder every platform ships — but only after proving that one actually works
here, and never at the cost of losing a long export when a driver refuses.
"""
import subprocess
import sys

import pytest

from sofit import action
from sofit.action import (HARDWARE_ENCODERS, QUALITY_PROFILES, _encode_args, _output_size,
                          _software_encode, h264_args, h264_encoder, run_encode)


@pytest.fixture(autouse=True)
def fresh_probe(monkeypatch):
    """Each test starts before the encoder has been chosen."""
    monkeypatch.setattr(action, "_H264_ENCODER", None)


def _fake_ffmpeg(listed: str, works: set[str]):
    def run(cmd, **kwargs):
        if "-encoders" in cmd:
            return subprocess.CompletedProcess(cmd, 0, stdout=listed, stderr="")
        name = cmd[cmd.index("-c:v") + 1]
        return subprocess.CompletedProcess(cmd, 0 if name in works else 1, stdout=b"", stderr=b"")
    return run


def test_every_desktop_platform_has_a_gpu_encoder_to_try():
    for platform in ("darwin", "win32", "linux"):
        assert HARDWARE_ENCODERS[platform], f"{platform} should have candidates"
    assert all(name.startswith("h264_") for names in HARDWARE_ENCODERS.values() for name in names)


def test_the_first_gpu_encoder_that_really_runs_wins(monkeypatch):
    """Being listed is not enough — the driver can be missing, and ffmpeg only
    finds out by trying."""
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(subprocess, "run",
                        _fake_ffmpeg("h264_nvenc h264_qsv h264_amf", works={"h264_qsv"}))
    assert h264_encoder() == "h264_qsv"


def test_falling_back_to_the_cpu_when_no_gpu_encoder_works(monkeypatch):
    monkeypatch.setattr(sys, "platform", "win32")
    monkeypatch.setattr(subprocess, "run", _fake_ffmpeg("h264_nvenc h264_amf", works=set()))
    assert h264_encoder() == "libx264"


def test_a_missing_ffmpeg_does_not_break_the_choice(monkeypatch):
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(OSError("no ffmpeg")))
    assert h264_encoder() == "libx264"


def test_gpu_settings_carry_a_bitrate_because_there_is_no_crf(monkeypatch):
    monkeypatch.setattr(action, "_H264_ENCODER", "h264_nvenc")
    args = h264_args(1920, 1080)
    assert args[:2] == ["-c:v", "h264_nvenc"]
    bitrate = int(args[args.index("-b:v") + 1])
    assert 6_000_000 < bitrate < 12_000_000, "1080p30 at visually-lossless quality"
    # A conversion must not come out worse than the file it started from.
    richer = h264_args(1920, 1080, source_bitrate=40_000_000)
    assert int(richer[richer.index("-b:v") + 1]) > 40_000_000


def test_cpu_settings_keep_each_profile_s_own_quality_knob(monkeypatch):
    monkeypatch.setattr(action, "_H264_ENCODER", "libx264")
    assert h264_args(1920, 1080, software=["-crf", "26"]) == ["-c:v", "libx264", "-crf", "26"]


def test_a_failed_gpu_encode_is_retried_on_the_cpu_and_not_tried_again(monkeypatch):
    """Losing a ten-minute export to a driver hiccup would be far worse than
    spending the extra minutes in software."""
    monkeypatch.setattr(action, "_H264_ENCODER", "h264_nvenc")
    attempts = []

    def flaky(cmd, total_seconds, progress=None):
        attempts.append(cmd)
        if "h264_nvenc" in cmd:
            raise subprocess.CalledProcessError(1, cmd, stderr="no capable devices")

    monkeypatch.setattr(action, "run_with_progress", flaky)
    run_encode(["ffmpeg", "-i", "a.mp4", "-c:v", "h264_nvenc", "-b:v", "9000000",
                "-maxrate", "1", "-bufsize", "2", "out.mp4"], 10)

    assert len(attempts) == 2
    assert "libx264" in attempts[1] and "-crf" in attempts[1]
    assert "-b:v" not in attempts[1], "the GPU-only bitrate trio has to go"
    assert action._H264_ENCODER == "libx264", "one failure is enough for this session"


def test_a_cpu_encode_that_fails_is_a_real_failure(monkeypatch):
    monkeypatch.setattr(action, "_H264_ENCODER", "libx264")

    def broken(cmd, total_seconds, progress=None):
        raise subprocess.CalledProcessError(1, cmd, stderr="bad input")

    monkeypatch.setattr(action, "run_with_progress", broken)
    with pytest.raises(subprocess.CalledProcessError):
        run_encode(["ffmpeg", "-i", "a.mp4", "-c:v", "libx264", "out.mp4"], 10)


def test_software_rewrite_leaves_the_rest_of_the_command_alone():
    rewritten = _software_encode(
        ["ffmpeg", "-i", "a.mp4", "-vf", "scale=-2:1080", "-c:v", "h264_videotoolbox",
         "-b:v", "9000000", "-maxrate", "1", "-bufsize", "2", "-c:a", "aac", "out.mp4"])
    assert rewritten[:5] == ["ffmpeg", "-i", "a.mp4", "-vf", "scale=-2:1080"]
    assert rewritten[-3:] == ["-c:a", "aac", "out.mp4"]
    assert "h264_videotoolbox" not in rewritten


@pytest.mark.skipif(not __import__("shutil").which("ffmpeg"), reason="needs ffmpeg")
def test_the_bitrate_is_sized_to_the_frame_the_export_will_produce(tmp_path, monkeypatch):
    tall = tmp_path / "tall.mp4"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "testsrc2=size=3840x2160:rate=10:duration=1",
                    "-c:v", "libx264", "-preset", "ultrafast", str(tall)], check=True)

    assert _output_size(str(tall), 1080, "16:9") == (1920, 1080)
    assert _output_size(str(tall), 1080, "9:16") == (607, 1080)
    assert _output_size(str(tall), None, "16:9") == (3840, 2160)

    monkeypatch.setattr(action, "_H264_ENCODER", "h264_nvenc")
    capped = _encode_args(str(tall), QUALITY_PROFILES["1080"], "16:9")
    full = _encode_args(str(tall), QUALITY_PROFILES["original"], "16:9")
    small = _encode_args(str(tall), QUALITY_PROFILES["whatsapp"], "16:9")
    rate = lambda args: int(args[args.index("-b:v") + 1])
    assert rate(full) > rate(capped) > rate(small), "bigger frame and richer profile cost more bits"


def test_the_page_keeps_its_action_bar_on_the_visual_viewport():
    """The iOS keyboard shrinks the visual viewport and can leave a fixed bar
    stranded mid-screen after it closes."""
    from sofit.ui import INDEX

    page = INDEX.read_text(encoding="utf-8")
    assert "visualViewport" in page
    assert "overflow-x:clip" in page, "hidden can turn body into a scroll container on iOS"
