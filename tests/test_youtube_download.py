"""YouTube music download: client fallback chain and error messages.

The list of yt-dlp player clients that YouTube currently allows shifts often;
these tests cover the retry behaviour and messaging, not any specific client
combo (that part is exercised against real YouTube manually).
"""
import subprocess

from sofit import ui


class _FakeCompleted:
    def __init__(self, returncode=0):
        self.returncode = returncode
        self.stdout = ""
        self.stderr = ""


def test_youtube_download_falls_back_through_client_list(monkeypatch, tmp_path):
    """The default (unpinned) client is tried first; on failure the code
    walks the fallback list and succeeds on the first client that works,
    without ever needing a hardcoded client to be correct."""
    job_id = "job1"
    ui.JOBS[job_id] = {"folder": tmp_path}
    attempts = []

    def fake_run(cmd, **kwargs):
        clients = cmd[cmd.index("--extractor-args") + 1] if "--extractor-args" in cmd else None
        attempts.append(clients)
        if len(attempts) < 3:  # first two attempts fail like a real block
            raise subprocess.CalledProcessError(1, cmd, stderr="ERROR: HTTP Error 403: Forbidden")
        (tmp_path / "youtube-abc123ABC12.mp3").write_bytes(b"fake mp3")
        return _FakeCompleted()

    monkeypatch.setattr(subprocess, "run", fake_run)
    monkeypatch.setattr(ui.shutil, "which", lambda name: "/usr/bin/yt-dlp")
    monkeypatch.setattr(ui, "duration", lambda path: 12.3)

    handler = ui.RKMotionHandler.__new__(ui.RKMotionHandler)
    handler._read_json = lambda: {"id": "abc123ABC12", "title": "Test Song", "rights_confirmed": True}
    captured = {}
    handler._json = lambda status, data: captured.update(status=status, data=data)

    handler._youtube_download(job_id)

    assert len(attempts) == 3, "should stop at the first client that works"
    assert attempts[0] is None, "the default (yt-dlp-maintained) client goes first"
    assert captured["status"] == 200
    assert captured["data"]["name"] == "youtube-abc123ABC12.mp3"


def test_youtube_download_error_message_is_hebrew_and_actionable(monkeypatch, tmp_path):
    job_id = "job2"
    ui.JOBS[job_id] = {"folder": tmp_path}

    def always_blocked(cmd, **kwargs):
        raise subprocess.CalledProcessError(1, cmd, stderr="ERROR: HTTP Error 403: Forbidden")

    monkeypatch.setattr(subprocess, "run", always_blocked)
    monkeypatch.setattr(ui.shutil, "which", lambda name: "/usr/bin/yt-dlp")

    handler = ui.RKMotionHandler.__new__(ui.RKMotionHandler)
    handler._read_json = lambda: {"id": "abc123ABC12", "rights_confirmed": True}
    captured = {}
    handler._json = lambda status, data: captured.update(status=status, data=data)

    handler._youtube_download(job_id)

    assert captured["status"] == 422
    assert "עדכנו" not in captured["data"]["error"]  # no longer blames an outdated yt-dlp
    assert "חסמה" in captured["data"]["error"]


def test_youtube_download_tries_every_client_then_raises_last_error(monkeypatch, tmp_path):
    job_id = "job3"
    ui.JOBS[job_id] = {"folder": tmp_path}
    attempts = []

    def always_blocked(cmd, **kwargs):
        attempts.append(cmd)
        raise subprocess.CalledProcessError(1, cmd, stderr="ERROR: HTTP Error 403: Forbidden")

    monkeypatch.setattr(subprocess, "run", always_blocked)
    monkeypatch.setattr(ui.shutil, "which", lambda name: "/usr/bin/yt-dlp")

    handler = ui.RKMotionHandler.__new__(ui.RKMotionHandler)
    handler._read_json = lambda: {"id": "abc123ABC12", "rights_confirmed": True}
    captured = {}
    handler._json = lambda status, data: captured.update(status=status, data=data)

    handler._youtube_download(job_id)

    assert len(attempts) == len(ui.RKMotionHandler.YOUTUBE_CLIENT_ATTEMPTS)
    assert captured["status"] == 422
