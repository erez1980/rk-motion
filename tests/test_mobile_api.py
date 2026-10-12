import json
import subprocess
import sys
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

from sofit import ui
from sofit.process import Cancelled, StreamProcess, Worker, run, scope
from sofit.security import Pairing
from sofit.storage import identifier, validate_clips


@pytest.fixture
def server(tmp_path, monkeypatch):
    monkeypatch.setattr(ui, "PROJECT_ROOT", tmp_path / "projects")
    monkeypatch.setattr(ui, "JOBS", {})
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), ui.RKMotionHandler)
    httpd.require_pairing = True
    httpd.pairing = Pairing(tmp_path / "clients.json")
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield httpd, f"http://127.0.0.1:{httpd.server_port}"
    for job in list(ui.JOBS.values()):
        if job.get("_worker"):
            job["_worker"].cancel()
        if job.get("_thread"):
            job["_thread"].join(5)
    httpd.shutdown()
    httpd.server_close()


def request(base, path, data=None, token=None, headers=None):
    hdr = dict(headers or {})
    if token:
        hdr["Authorization"] = "Bearer " + token
    if isinstance(data, dict):
        data = json.dumps(data).encode()
        hdr["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=data, headers=hdr)
    try:
        with urllib.request.urlopen(req, timeout=5) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)


def pair(httpd, base):
    return request(base, "/api/pair", {"code": httpd.pairing.code})[1]["token"]


def test_pairing_is_required_and_clients_cannot_read_each_others_project(server):
    httpd, base = server
    assert request(base, "/api/prepare", b"")[0] == 401
    alice, bob = pair(httpd, base), pair(httpd, base)
    status, project = request(base, "/api/prepare", b"", alice)
    assert status == 200
    assert request(base, "/api/projects", token=bob)[1]["projects"] == []
    jid = project["job_id"]
    ui.JOBS[jid]["report"] = {"job_id": jid, "duration": 20}
    assert request(base, "/api/session/" + jid, token=bob)[0] == 404
    assert request(base, "/api/reset/" + jid, b"", bob)[0] == 200
    assert jid in ui.JOBS  # a guessed/known ID grants no write access


def test_cross_origin_mutations_are_rejected_even_with_credentials(server):
    httpd, base = server
    token = pair(httpd, base)
    assert request(base, "/api/prepare", b"", token, {"Origin": "https://evil.example"})[0] == 403


def test_upload_resume_checks_offsets_and_survives_reload(server):
    httpd, base = server
    token = pair(httpd, base)
    jid = request(base, "/api/prepare", b"", token)[1]["job_id"]
    upload_id = request(base, "/api/uploads/" + jid, {"name": "ride.mov", "size": 6}, token)[1]["upload_id"]
    path = f"/api/chunk/{jid}/{upload_id}"
    assert request(base, path, b"abc", token, {"Upload-Offset": "0"})[1]["offset"] == 3
    assert request(base, path, b"abc", token, {"Upload-Offset": "0"})[0] == 409
    root = ui.PROJECT_ROOT
    ui.JOBS.clear()
    ui._load_projects(root)
    assert request(base, f"/api/uploads/{jid}/{upload_id}", token=token)[1]["offset"] == 3
    assert request(base, path, b"def", token, {"Upload-Offset": "3"})[1]["complete"]
    job = ui.JOBS[jid]
    assert Path(job["inputs"][0]).read_bytes() == b"abcdef"
    assert len(job["inputs"]) == 1


def test_edit_persistence_has_conflict_detection(server):
    httpd, base = server
    token = pair(httpd, base)
    jid = request(base, "/api/prepare", b"", token)[1]["job_id"]
    ui.JOBS[jid]["report"] = {"job_id": jid, "duration": 20}
    edit = {"clips": [{"start": 4, "end": 10, "selected": False}], "settings": {"speed": "1.5"}}
    assert request(base, "/api/edit/" + jid, {"edit": edit, "revision": 0}, token)[1]["revision"] == 1
    assert request(base, "/api/edit/" + jid, {"edit": edit, "revision": 0}, token)[0] == 409
    ui.JOBS.clear()
    ui._load_projects(ui.PROJECT_ROOT)
    session = request(base, "/api/session/" + jid, token=token)[1]
    assert session["edit"] == edit and session["revision"] == 1


def test_export_duplicate_rejected_and_retry_is_idempotent(server, monkeypatch):
    httpd, base = server
    token = pair(httpd, base)
    jid = request(base, "/api/prepare", b"", token)[1]["job_id"]
    job = ui.JOBS[jid]
    job.update(source="fake.mp4", report={"duration": 20, "job_id": jid})
    entered, release = threading.Event(), threading.Event()
    calls = []
    def export(*args):
        calls.append(args)
        entered.set()
        release.wait(5)
    monkeypatch.setattr(ui.RKMotionHandler, "_run_export", export)
    monkeypatch.setattr(ui.RKMotionHandler, "_video_meta", lambda path: ("h264", 320, 180))
    data = {"job_id": jid, "clips": [{"start": 0, "end": 2}]}
    try:
        assert request(base, "/api/export", data, token, {"Idempotency-Key": "one"})[0] == 202
        assert entered.wait(2)
        assert request(base, "/api/export", data, token, {"Idempotency-Key": "one"})[0] == 202
        assert request(base, "/api/export", data, token, {"Idempotency-Key": "two"})[0] == 409
        assert len(calls) == 1 and job["export_version"] == 1
    finally:
        release.set()


def test_expired_pairing_and_stored_client_identity(tmp_path):
    authority = Pairing(tmp_path / "clients.json")
    code = authority.code
    token, client = authority.pair(code, "phone")
    restored = Pairing(tmp_path / "clients.json")
    assert restored.authenticate({"Authorization": "Bearer " + token}) == client
    authority.expires = 0
    with pytest.raises(ValueError):
        authority.pair(code, "phone")


@pytest.mark.parametrize("value", ["../outside", "/tmp/outside", "x/y", ""])
def test_imported_ids_cannot_escape_output_directory(value):
    with pytest.raises(ValueError):
        identifier(value)


@pytest.mark.parametrize("start,end", [(0, 21), (-1, 3), (2, 2), (float("nan"), 3)])
def test_invalid_clip_ranges_fail_before_encoding(start, end):
    with pytest.raises(ValueError):
        validate_clips([{"start": start, "end": end}], 20)


def test_no_stderr_pipe_deadlock_and_stream_timeout():
    script = "import sys;sys.stderr.write('x'*200000);print('done')"
    with StreamProcess([sys.executable, "-c", script], text=True, timeout=3) as proc:
        assert proc.stdout.read().strip() == "done"
        assert proc.wait() == 0
        assert len(proc.stderr.read()) <= 65536
    with pytest.raises(subprocess.TimeoutExpired):
        with StreamProcess([sys.executable, "-c", "import time;time.sleep(10)"], timeout=.1) as proc:
            proc.wait()


def test_cancel_kills_a_running_child():
    worker = Worker()
    timer = threading.Timer(.1, worker.cancel)
    timer.start()
    with scope(worker), pytest.raises(Cancelled):
        run([sys.executable, "-c", "import time;time.sleep(10)"], capture_output=True)
    timer.join()
    assert not worker.processes


def test_invalid_export_does_not_leave_project_running(server):
    httpd, base = server
    token = pair(httpd, base)
    jid = request(base, '/api/prepare', b'', token)[1]['job_id']
    job = ui.JOBS[jid]
    job['report'] = {'job_id': jid, 'duration': 10}
    status, _ = request(base, '/api/export', {'job_id': jid, 'clips': [{'start': 0, 'end': 2}], 'speed': 'nan'}, token)
    assert status == 400
    assert 'export_status' not in job
    assert not job.get('_worker')


def test_phone_upload_analyse_edit_export_and_restart(server, tmp_path):
    import shutil
    import time
    if not shutil.which('ffmpeg'):
        pytest.skip('FFmpeg required')
    source = tmp_path / 'iphone.mov'
    subprocess.run(['ffmpeg', '-y', '-v', 'error', '-f', 'lavfi', '-i',
        'testsrc2=size=180x320:rate=30:duration=2', '-f', 'lavfi', '-i',
        'sine=frequency=440:duration=2', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
        '-c:a', 'pcm_s16le', str(source)], check=True)
    httpd, base = server
    token = pair(httpd, base)
    jid = request(base, '/api/prepare', b'', token)[1]['job_id']
    data = source.read_bytes()
    upload = request(base, '/api/uploads/' + jid, {'name': source.name, 'size': len(data)}, token)[1]['upload_id']
    assert request(base, f'/api/chunk/{jid}/{upload}', data, token, {'Upload-Offset': '0'})[1]['complete']
    assert request(base, '/api/analyse-batch/' + jid, b'', token, {'X-Whole-Video': '1'})[0] == 202
    def wait(path):
        until = time.monotonic() + 30
        while time.monotonic() < until:
            status = request(base, path, token=token)[1]
            if status['state'] != 'running':
                assert status['state'] == 'done', status
                return status
            time.sleep(.1)
        pytest.fail('worker timeout')
    report = wait('/api/analyse-status/' + jid)['report']
    clips = [{'start': 0.1, 'end': 1.5, 'selected': True}]
    assert request(base, '/api/edit/' + jid, {'edit': {'clips': clips, 'settings': {}}, 'revision': 0}, token)[0] == 200
    assert request(base, '/api/export', {'job_id': jid, 'clips': clips}, token)[0] == 202
    wait('/api/export-status/' + jid)
    job = ui.JOBS[jid]
    for path in [job['source'], job['proxy'], job['export']]:
        streams = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-of', 'json', str(path)]))['streams']
        assert next(s for s in streams if s['codec_type'] == 'video')['pix_fmt'] == 'yuv420p'
        assert next(s for s in streams if s['codec_type'] == 'audio')['codec_name'] == 'aac'
    req = urllib.request.Request(base + '/api/proxy/' + jid, headers={'Authorization': 'Bearer ' + token, 'Range': 'bytes=0-99'})
    with urllib.request.urlopen(req) as response:
        assert response.status == 206
        assert len(response.read()) == 100
    # Worker persistence happens in its finally block after status completion.
    job['_thread'].join(5)
    ui.JOBS.clear()
    ui._load_projects(ui.PROJECT_ROOT)
    session = request(base, '/api/session/' + jid, token=token)[1]
    assert session['revision'] == 1 and session['edit']['clips'] == clips
    assert len(session['exports']) == 1


def test_upload_space_is_reserved_across_projects(server, monkeypatch):
    """Hold the first disk check open while another project requests space."""
    from types import SimpleNamespace
    httpd, base = server
    token = pair(httpd, base)
    jobs = [request(base, '/api/prepare', b'', token)[1]['job_id'] for _ in range(2)]
    entered, release, concurrent = threading.Event(), threading.Event(), threading.Event()
    calls = []

    def disk_usage(_):
        calls.append(True)
        if len(calls) == 1:
            entered.set()
            assert release.wait(3)
        else:
            concurrent.set()
        return SimpleNamespace(free=512 * 1024**2 + 30 * 1024**2)

    monkeypatch.setattr(ui.shutil, 'disk_usage', disk_usage)
    results = []
    def upload(job):
        results.append(request(base, '/api/uploads/' + job,
                               {'name': 'ride.mov', 'size': 20 * 1024**2}, token)[0])
    first = threading.Thread(target=upload, args=(jobs[0],))
    second = threading.Thread(target=upload, args=(jobs[1],))
    try:
        first.start()
        assert entered.wait(2)
        second.start()
        # Without the global reservation lock both disk checks enter together
        # with reserved=0 and both uploads incorrectly fit.
        assert not concurrent.wait(.2)
    finally:
        release.set()
        first.join(4)
        if second.ident is not None:
            second.join(4)
    assert sorted(results) == [201, 400]
