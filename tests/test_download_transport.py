"""Serving a finished movie to a browser's download manager.

A download manager keeps a connection alive, opens more than one, and resumes
broken transfers. It needs HTTP/1.1 and a validator to do any of that, and
without them a large export comes back as "Failed - Network error" rather than
a file.
"""
import http.client
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

import pytest

from sofit import ui


@pytest.fixture
def served(tmp_path):
    """A job whose export is a real, multi-chunk file."""
    movie = tmp_path / "RK-Motion-edit-01.mp4"
    movie.write_bytes(bytes(range(256)) * 20_000)          # ~5MB, several read chunks
    job_id = "downloadjob"
    ui.JOBS[job_id] = {"folder": tmp_path, "source": movie, "export": movie,
                       "report": {"job_id": job_id},
                       "exports": [{"file": str(movie), "version": 1,
                                    "download": f"/api/export/{job_id}/1", "clips": 1,
                                    "duration": 1.0, "quality": "1080", "aspect": "16:9"}]}
    server = ThreadingHTTPServer(("127.0.0.1", 0), ui.RKMotionHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield server.server_port, f"/api/export/{job_id}/1", movie
    server.shutdown()
    ui.JOBS.pop(job_id, None)


def _request(port, path, headers=None, method="GET", conn=None):
    own = conn is None
    conn = conn or http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    conn.request(method, path, headers=headers or {})
    response = conn.getresponse()
    body = response.read()
    if own:
        conn.close()
    return response, body


def test_the_whole_file_arrives_in_one_piece(served):
    port, path, movie = served
    response, body = _request(port, path)
    assert response.status == 200
    assert len(body) == movie.stat().st_size
    assert body == movie.read_bytes()
    assert int(response.getheader("Content-Length")) == len(body)


def test_the_connection_speaks_http_1_1_and_stays_open(served):
    """HTTP/1.0 gives a download manager no way to keep a connection or resume."""
    port, path, _ = served
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    first, _ = _request(port, path, conn=conn)
    assert first.version == 11, "HTTP/1.1"
    second, body = _request(port, path, conn=conn)   # reuses the same socket
    assert second.status == 200 and body
    conn.close()


def test_a_download_manager_gets_something_to_validate_against(served):
    port, path, _ = served
    response, _ = _request(port, path, method="HEAD")
    assert response.getheader("Accept-Ranges") == "bytes"
    assert response.getheader("ETag"), "no validator means no safe resume"
    assert response.getheader("Last-Modified")


def test_resuming_returns_exactly_the_bytes_asked_for(served):
    port, path, movie = served
    whole = movie.read_bytes()
    response, body = _request(port, path, {"Range": "bytes=1000000-1999999"})
    assert response.status == 206
    assert body == whole[1000000:2000000]
    assert response.getheader("Content-Range") == f"bytes 1000000-1999999/{len(whole)}"

    tail, body = _request(port, path, {"Range": "bytes=-500"})
    assert tail.status == 206 and body == whole[-500:]


def test_resuming_a_file_that_changed_starts_over_instead_of_mixing_versions(served):
    """Exporting again replaces the file. Handing a download manager the new
    bytes at the old offsets is what surfaces as a network error."""
    port, path, movie = served
    tag = _request(port, path, method="HEAD")[0].getheader("ETag")

    fresh, body = _request(port, path, {"Range": "bytes=100-199", "If-Range": tag})
    assert fresh.status == 206 and len(body) == 100

    time.sleep(0.01)
    movie.write_bytes(b"\0" * 4096)      # a new export lands in the same place
    stale, body = _request(port, path, {"Range": "bytes=100-199", "If-Range": tag})
    assert stale.status == 200, "the old validator must not be honoured"
    assert len(body) == 4096, "the whole new file, not a slice of it"


def test_an_abandoned_upload_does_not_poison_the_next_request(served):
    """Rejecting an upload leaves its body unsent; on a kept-alive connection
    those bytes would be read as the request after it."""
    port, path, _ = served
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    conn.request("POST", "/api/video/no-such-job", body=b"x" * 4096,
                 headers={"Content-Length": "4096"})
    response = conn.getresponse()
    assert response.status == 404
    response.read()
    assert response.will_close, "a request whose body was never read has to end the connection"
    conn.close()

    # A fresh connection is unaffected.
    assert _request(port, path)[0].status == 200


def test_the_finished_movie_is_offered_at_a_version_that_cannot_move(served):
    """A download reading /api/export/<job> would switch files mid-transfer the
    moment a second export finished."""
    import inspect
    source = inspect.getsource(ui.RKMotionHandler._run_export)
    assert '"download": f"/api/export/{job_id}/{version}"' in source


def test_a_head_request_never_carries_a_body(served):
    """A body on a HEAD reply leaves the next request reading the tail of the
    last one — the whole point of keeping the connection alive is lost."""
    port, path, movie = served
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)

    for probe in (path, "/api/capabilities"):
        response, body = _request(port, probe, method="HEAD", conn=conn)
        assert response.status == 200
        assert body == b"", f"{probe} sent a body on HEAD"

    # The connection is still usable and answers the right thing.
    response, body = _request(port, path, conn=conn)
    assert response.status == 200 and len(body) == movie.stat().st_size
    conn.close()
