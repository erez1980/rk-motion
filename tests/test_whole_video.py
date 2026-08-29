"""Keeping the footage whole, for a ride that is already edited.

The point of the app is finding the action in a long ride, but a video that
has already been cut only needs a soundtrack. That path skips the scan
entirely and hands the rest of the pipeline one clip covering everything, so
music, quality, aspect and the closing fade all behave exactly as they do for
a cut edit.
"""
import json
import shutil
import subprocess
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

from sofit import ui

needs_ffmpeg = pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="needs ffmpeg")


@pytest.fixture
def server():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), ui.RKMotionHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_port}"
    httpd.shutdown()


def _opener():
    return urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _post(base, path, body=b"", headers=None):
    request = urllib.request.Request(base + path, data=body, method="POST",
                                     headers=headers or {})
    with _opener().open(request, timeout=30) as response:
        return response.status, json.load(response)


def _get(base, path):
    with _opener().open(base + path, timeout=30) as response:
        return response.status, json.load(response)


def _ride(path: Path, seconds: int = 8) -> Path:
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", f"testsrc2=size=320x180:rate=15:duration={seconds}",
                    "-f", "lavfi", "-i", f"sine=frequency=200:duration={seconds}",
                    "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", str(path)], check=True)
    return path


def _finish(base, job_id, timeout=180):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _, status = _get(base, f"/api/analyse-status/{job_id}")
        if status["state"] != "running":
            return status
        time.sleep(0.1)
    raise AssertionError("analysis never finished")


@needs_ffmpeg
def test_the_whole_video_becomes_one_clip_and_nothing_is_scanned(server, tmp_path):
    ride = _ride(tmp_path / "edited.mp4", seconds=8)
    _, session = _post(server, "/api/prepare")
    job_id = session["job_id"]
    _post(server, f"/api/video/{job_id}", ride.read_bytes(),
          {"Content-Length": str(ride.stat().st_size), "X-Filename": "edited.mp4"})
    _post(server, f"/api/analyse-batch/{job_id}", b"", {"X-Whole-Video": "1"})

    report = _finish(server, job_id)["report"]
    assert report["whole"] is True
    assert len(report["clips"]) == 1
    clip = report["clips"][0]
    assert clip["start"] == 0
    assert abs(clip["end"] - report["duration"]) < 0.05, "the clip covers everything"
    # No per-second scores means the client hides the sensitivity slider, which
    # would have nothing to re-threshold.
    assert report["scores"] == []


@needs_ffmpeg
def test_the_normal_path_still_cuts(server, tmp_path):
    """The flag has to be opt-in: without it, the scan runs as before."""
    ride = _ride(tmp_path / "ride.mp4", seconds=8)
    _, session = _post(server, "/api/prepare")
    job_id = session["job_id"]
    _post(server, f"/api/video/{job_id}", ride.read_bytes(),
          {"Content-Length": str(ride.stat().st_size), "X-Filename": "ride.mp4"})
    _post(server, f"/api/analyse-batch/{job_id}", b"")

    report = _finish(server, job_id)["report"]
    assert not report.get("whole")
    assert report["scores"], "the scan should have produced per-second scores"


@needs_ffmpeg
def test_exporting_the_whole_video_keeps_its_full_length(tmp_path):
    """The soundtrack goes on without the footage losing a second of itself."""
    from sofit.action import export_edited_movie

    ride = _ride(tmp_path / "edited.mp4", seconds=10)
    music = tmp_path / "song.mp3"
    subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                    "-i", "sine=frequency=880:duration=30", "-c:a", "libmp3lame",
                    str(music)], check=True)

    whole = ui.RKMotionHandler._whole_video_report(ride)
    output = str(tmp_path / "with-music.mp4")
    export_edited_movie(str(ride), whole["clips"], output, quality="original",
                        music_paths=[str(music)], music_start=0)

    length = float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration",
         "-of", "default=noprint_wrappers=1:nokey=1", output],
        capture_output=True, text=True, check=True).stdout)
    assert abs(length - whole["duration"]) < 0.3, "nothing was cut off"


@needs_ffmpeg
def test_starting_over_takes_the_files_with_it(server, tmp_path):
    """Abandoning an edit should not leave its footage sitting in a temp
    folder until the app closes."""
    ride = _ride(tmp_path / "ride.mp4", seconds=4)
    _, session = _post(server, "/api/prepare")
    job_id = session["job_id"]
    _post(server, f"/api/video/{job_id}", ride.read_bytes(),
          {"Content-Length": str(ride.stat().st_size), "X-Filename": "ride.mp4"})
    folder = Path(ui.JOBS[job_id]["folder"])
    assert folder.is_dir() and any(folder.iterdir())

    status, body = _post(server, f"/api/reset/{job_id}")
    assert status == 200 and body["ok"]
    assert job_id not in ui.JOBS
    assert not folder.exists()

    # Resetting something already gone is not an error; the page reloads either way.
    assert _post(server, f"/api/reset/{job_id}")[0] == 200
