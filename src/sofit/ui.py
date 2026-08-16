"""RK Motion's local browser GUI.

It is deliberately stdlib-only: `sofit --ui` opens a local page, the selected
video is processed on the same Mac, and no request is made to an external host.
"""
from __future__ import annotations

import json
import mimetypes
import shutil
import tempfile
import threading
import uuid
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

from .action import analyse_action, export_edited_movie

LOGO = Path(__file__).with_name("assets") / "rk-logo.png"
INDEX = Path(__file__).with_name("assets") / "index.html"
JOBS: dict[str, dict] = {}


class RKMotionHandler(BaseHTTPRequestHandler):
    server_version = "RKMotion/0.1"

    def log_message(self, _format: str, *_args: object) -> None:
        return  # a desktop app should not fill the user's Terminal with HTTP logs

    def _json(self, status: int, data: dict) -> None:
        raw = json.dumps(data, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _file(self, path: Path, content_type: str | None = None) -> None:
        if not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        size = path.stat().st_size
        start, end = 0, size - 1
        range_header = self.headers.get("Range", "")
        if range_header.startswith("bytes="):
            try:
                first, last = range_header[6:].split("=", 1)[-1].split("-", 1)
                start = int(first) if first else max(0, size - int(last))
                end = int(last) if last else end
                if start < 0 or end < start or start >= size:
                    raise ValueError
                end = min(end, size - 1)
            except ValueError:
                self.send_error(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
                return
            self.send_response(HTTPStatus.PARTIAL_CONTENT)
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        else:
            self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type or mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = end - start + 1
            while remaining:
                chunk = handle.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def do_GET(self) -> None:  # noqa: N802
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not parts:
            return self._file(INDEX, "text/html; charset=utf-8")
        if parts == ["assets", "rk-logo.png"]:
            return self._file(LOGO, "image/png")
        if len(parts) == 3 and parts[0] == "api" and parts[1] in {"video", "export"}:
            job = JOBS.get(parts[2])
            if not job:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            path = job["source"] if parts[1] == "video" else job.get("export")
            if not path:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            return self._file(Path(path), "video/mp4")
        self.send_error(HTTPStatus.NOT_FOUND)

    def _read_json(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(size) or b"{}")

    def do_POST(self) -> None:  # noqa: N802
        route = urlparse(self.path).path
        if route == "/api/analyse":
            return self._analyse_upload()
        if route == "/api/export":
            return self._export()
        self.send_error(HTTPStatus.NOT_FOUND)

    def _analyse_upload(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        name = Path(unquote(self.headers.get("X-Filename", "ride.mp4"))).name
        if not length or length > 30 * 1024 * 1024 * 1024:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "Choose a video smaller than 30GB."})
        suffix = Path(name).suffix or ".mp4"
        job_id = uuid.uuid4().hex
        folder = Path(tempfile.mkdtemp(prefix="rk-motion-"))
        source = folder / f"source{suffix}"
        remaining = length
        with source.open("wb") as handle:
            while remaining:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    return self._json(HTTPStatus.BAD_REQUEST, {"error": "Upload ended early."})
                handle.write(chunk)
                remaining -= len(chunk)
        try:
            report = analyse_action(str(source))
        except Exception as exc:  # keep UI errors actionable, never crash its server
            shutil.rmtree(folder, ignore_errors=True)
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(exc)})
        JOBS[job_id] = {"folder": folder, "source": source, "report": report}
        report["job_id"] = job_id
        return self._json(HTTPStatus.OK, report)

    def _export(self) -> None:
        try:
            request = self._read_json()
            job = JOBS[request["job_id"]]
            clips = request["clips"]
            output = Path(job["folder"]) / "RK-Motion-edit.mp4"
            export_edited_movie(str(job["source"]), clips, str(output))
            job["export"] = output
            return self._json(HTTPStatus.OK, {"download": f"/api/export/{request['job_id']}"})
        except (KeyError, ValueError, TypeError) as exc:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except Exception as exc:
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(exc)})


def launch_ui(port: int = 8787) -> int:
    """Start RK Motion and open it in the default browser."""
    server = ThreadingHTTPServer(("127.0.0.1", port), RKMotionHandler)
    url = f"http://127.0.0.1:{port}"
    print(f"RK Motion is running at {url} (Ctrl+C to stop)")
    threading.Timer(.3, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
        for job in JOBS.values():
            shutil.rmtree(job["folder"], ignore_errors=True)
