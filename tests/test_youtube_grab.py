"""The standalone downloader: search a video, get an MP3 or MP4 back.

Separate from the soundtrack flow — this one attaches nothing to an edit, it
just hands a file back so it can be saved on the phone. YouTube itself is not
reachable from a test, so a stand-in yt-dlp on PATH exercises the real
subprocess plumbing: the progress template, the client fallback chain and the
file that comes out.
"""
import json
import os
import subprocess
import threading
import time
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from sofit import ui

FAKE = """#!/usr/bin/env python3
import os, sys, time
from pathlib import Path

args = sys.argv[1:]
if os.environ.get("FAKE_FAIL_UNTIL_CLIENT"):
    wanted = os.environ["FAKE_FAIL_UNTIL_CLIENT"]
    got = args[args.index("--extractor-args") + 1] if "--extractor-args" in args else ""
    Path(os.environ["FAKE_ATTEMPTS"]).open("a").write(got + "\\n")
    if wanted not in got:
        print("ERROR: HTTP Error 403: Forbidden", file=sys.stderr)
        sys.exit(1)
for done in (2500, 5000, 7500, 10000):
    print(f"rk:{done}/10000", flush=True)
    time.sleep(0.01)
template = args[args.index("-o") + 1]
suffix = "mp3" if "mp3" in args else "mp4"
target = Path(template).parent / f"Test Clip.{suffix}"
target.write_bytes(b"\\0" * 4096)
"""


@pytest.fixture
def fake_yt_dlp(tmp_path, monkeypatch):
    tool = tmp_path / "bin" / "yt-dlp"
    tool.parent.mkdir(parents=True, exist_ok=True)
    tool.write_text(FAKE, encoding="utf-8")
    tool.chmod(0o755)
    monkeypatch.setenv("PATH", f"{tool.parent}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setattr(ui, "_GRAB_ROOT", tmp_path / "grabs")
    ui.GRABS.clear()
    return tool


@pytest.fixture
def server():
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), ui.RKMotionHandler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_port}"
    httpd.shutdown()


def _post(base: str, path: str, body: dict):
    request = urllib.request.Request(
        base + path, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(request, timeout=15) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def _get(base: str, path: str):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(base + path, timeout=15) as response:
        return response.status, response.read(), dict(response.headers)


def _finish(base: str, token: str, timeout: float = 20) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _, raw, _ = _get(base, f"/api/grab-status/{token}")
        status = json.loads(raw)
        if status["state"] != "running":
            return status
        time.sleep(0.05)
    raise AssertionError("the download never finished")


@pytest.mark.parametrize("fmt, suffix", [("mp3", ".mp3"), ("mp4", ".mp4")])
def test_a_search_result_can_be_taken_as_audio_or_video(fake_yt_dlp, server, fmt, suffix):
    code, start = _post(server, "/api/youtube/grab",
                        {"id": "abc123ABC12", "title": "Test Clip", "format": fmt,
                         "rights_confirmed": True})
    assert code == 202 and start["token"]

    status = _finish(server, start["token"])
    assert status["state"] == "done", status
    assert status["name"].endswith(suffix)
    assert status["size"] > 0

    # Served inline, so a phone's share sheet and a player can both open it.
    code, body, headers = _get(server, status["download"])
    assert code == 200 and len(body) == status["size"]
    assert "Content-Disposition" not in headers


def test_the_bar_moves_while_the_bytes_arrive(fake_yt_dlp, server):
    _, start = _post(server, "/api/youtube/grab",
                     {"id": "abc123ABC12", "format": "mp4", "rights_confirmed": True})
    seen = set()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        status = json.loads(_get(server, f"/api/grab-status/{start['token']}")[1])
        seen.add(status.get("percent"))
        if status["state"] != "running":
            break
        time.sleep(0.02)
    assert max(seen) == 100, "a finished download ends on a full bar"
    assert all(0 <= value <= 100 for value in seen if value is not None)


def test_downloading_without_confirming_rights_is_refused(fake_yt_dlp, server):
    code, body = _post(server, "/api/youtube/grab",
                       {"id": "abc123ABC12", "format": "mp3"})
    assert code == 422 and "permission" in body["error"]
    assert not ui.GRABS, "nothing should have been started"


def test_only_mp3_and_mp4_are_offered(fake_yt_dlp, server):
    code, body = _post(server, "/api/youtube/grab",
                       {"id": "abc123ABC12", "format": "wav", "rights_confirmed": True})
    assert code == 422 and "MP3" in body["error"]


def test_a_made_up_video_id_never_reaches_the_command_line(fake_yt_dlp, server):
    code, body = _post(server, "/api/youtube/grab",
                       {"id": "../../etc/passwd", "format": "mp3", "rights_confirmed": True})
    assert code == 422 and "Invalid" in body["error"]


def test_a_blocked_client_is_retried_with_the_next_one(fake_yt_dlp, server, tmp_path, monkeypatch):
    """YouTube's blocking shifts around; the fallback chain is what carries it."""
    attempts = tmp_path / "attempts.txt"
    monkeypatch.setenv("FAKE_FAIL_UNTIL_CLIENT", "android_vr")
    monkeypatch.setenv("FAKE_ATTEMPTS", str(attempts))

    _, start = _post(server, "/api/youtube/grab",
                     {"id": "abc123ABC12", "format": "mp3", "rights_confirmed": True})
    status = _finish(server, start["token"])

    assert status["state"] == "done", status
    tried = attempts.read_text(encoding="utf-8").splitlines()
    assert tried[0] == "", "the yt-dlp-maintained default goes first"
    assert any("android_vr" in line for line in tried)


def test_a_download_that_never_works_reports_it_in_hebrew(fake_yt_dlp, server, tmp_path, monkeypatch):
    monkeypatch.setenv("FAKE_FAIL_UNTIL_CLIENT", "nothing-matches-this")
    monkeypatch.setenv("FAKE_ATTEMPTS", str(tmp_path / "attempts.txt"))

    _, start = _post(server, "/api/youtube/grab",
                     {"id": "abc123ABC12", "format": "mp4", "rights_confirmed": True})
    status = _finish(server, start["token"])

    assert status["state"] == "error"
    assert "חסמה" in status["message"], status
    assert "עדכנו" not in status["message"]


def test_an_unknown_token_is_not_found(server):
    with pytest.raises(urllib.error.HTTPError) as caught:
        _get(server, "/api/grab-status/nope")
    assert caught.value.code == 404
    with pytest.raises(urllib.error.HTTPError) as caught:
        _get(server, "/api/grab/nope")
    assert caught.value.code == 404
