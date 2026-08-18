"""RK Motion's local browser GUI.

It is deliberately stdlib-only: `sofit --ui` opens a local page, the selected
video is processed on the same Mac, and no request is made to an external host.
"""
from __future__ import annotations

import json
import mimetypes
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

from .action import analyse_action, duration, export_edited_movie

LOGO = Path(__file__).with_name("assets") / "rk-logo.png"
INDEX = Path(__file__).with_name("assets") / "index.html"
FONT = Path(__file__).with_name("data") / "fonts" / "Rubik.ttf"
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

    def _file(self, path: Path, content_type: str | None = None, attachment: bool = False) -> None:
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
        if attachment:
            self.send_header("Content-Disposition", f'attachment; filename="{path.name}"')
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
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    # Browsers routinely cancel an old byte-range request when
                    # the user seeks or a new preview starts. That is expected,
                    # not an application/export failure.
                    return
                remaining -= len(chunk)

    def do_GET(self) -> None:  # noqa: N802
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not parts:
            return self._file(INDEX, "text/html; charset=utf-8")
        if parts == ["assets", "rk-logo.png"]:
            return self._file(LOGO, "image/png")
        if parts == ["assets", "rubik.ttf"]:
            return self._file(FONT, "font/ttf")
        if len(parts) == 3 and parts[0] == "api" and parts[1] in {"video", "export"}:
            job = JOBS.get(parts[2])
            if not job:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            path = job["source"] if parts[1] == "video" else job.get("export")
            if not path:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            return self._file(Path(path), "video/mp4", attachment=parts[1] == "export")
        if len(parts) == 3 and parts[1] in {"export-status", "analyse-status"} and parts[0] == "api":
            job = JOBS.get(parts[2])
            key = parts[1].replace("-", "_")
            if not job or key not in job:
                return self._json(HTTPStatus.NOT_FOUND, {"error": "Job not found."})
            state = dict(job[key])
            started = state.get("started")
            if started:
                state["elapsed_seconds"] = round(time.monotonic() - started, 1)
                del state["started"]  # monotonic time is meaningless to the client
            return self._json(HTTPStatus.OK, state)
        if parts == ["api", "capabilities"]:
            return self._json(HTTPStatus.OK, {"youtube": bool(shutil.which("yt-dlp"))})
        if len(parts) == 3 and parts[:2] == ["api", "session"]:
            # Lets a page that was closed mid-job rebuild its state on return.
            job = JOBS.get(parts[2])
            if not job:
                return self._json(HTTPStatus.NOT_FOUND, {"error": "Session not found."})
            return self._json(HTTPStatus.OK, {
                "music": job.get("music_meta", []),
                "pending_music": job.get("pending_music_meta"),
                "exporting": "export_status" in job,
            })
        if len(parts) == 3 and parts[:2] == ["api", "music-preview"]:
            job = JOBS.get(parts[2])
            track = job.get("pending_music") if job else None
            if not track:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            return self._file(Path(track), "audio/mpeg")
        self.send_error(HTTPStatus.NOT_FOUND)

    def _read_json(self) -> dict:
        size = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(size) or b"{}")

    def do_POST(self) -> None:  # noqa: N802
        route = urlparse(self.path).path
        if route == "/api/analyse":
            return self._analyse_upload()
        if route == "/api/prepare":
            return self._prepare_batch()
        if route == "/api/youtube/search":
            return self._youtube_search()
        if route == "/api/export":
            return self._export()
        if route.startswith("/api/youtube/download/"):
            return self._youtube_download(route.rsplit("/", 1)[-1])
        if route.startswith("/api/music/attach/"):
            return self._attach_pending_music(route.rsplit("/", 1)[-1])
        if route.startswith("/api/music/"):
            return self._upload_music(route.rsplit("/", 1)[-1])
        if route.startswith("/api/video/"):
            return self._upload_video(route.rsplit("/", 1)[-1])
        if route.startswith("/api/analyse-batch/"):
            return self._analyse_batch(route.rsplit("/", 1)[-1])
        self.send_error(HTTPStatus.NOT_FOUND)

    def _youtube_search(self) -> None:
        try:
            query = str(self._read_json().get("query", "")).strip()
            if not query:
                raise ValueError("Enter a search query.")
            if not shutil.which("yt-dlp"):
                raise RuntimeError("YouTube search needs yt-dlp installed on this computer (https://github.com/yt-dlp/yt-dlp).")
            result = subprocess.run(["yt-dlp", "--flat-playlist", "--dump-single-json", f"ytsearch5:{query}"],
                                    capture_output=True, text=True, check=True, timeout=45)
            entries = json.loads(result.stdout).get("entries", [])
            items = [{"id": item.get("id"), "title": item.get("title", "Untitled"),
                      "channel": item.get("channel") or item.get("uploader", ""),
                      "duration": item.get("duration") or 0,
                      "thumbnail": item.get("thumbnail", "")}
                     for item in entries if item.get("id")]
            return self._json(HTTPStatus.OK, {"results": items})
        except Exception as exc:
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(exc)})

    def _youtube_download(self, job_id: str) -> None:
        try:
            job, request = JOBS.get(job_id), self._read_json()
            if not job:
                raise ValueError("Video session not found.")
            if not request.get("rights_confirmed"):
                raise ValueError("Confirm you have permission to download and use this track.")
            video_id = str(request.get("id", ""))
            if not video_id or not all(char.isalnum() or char in "-_" for char in video_id):
                raise ValueError("Invalid YouTube video.")
            if not shutil.which("yt-dlp"):
                raise RuntimeError("YouTube download needs yt-dlp installed on this computer (https://github.com/yt-dlp/yt-dlp).")
            output = str(Path(job["folder"]) / f"youtube-{video_id}.%(ext)s")
            subprocess.run(["yt-dlp", "--no-playlist", "--extractor-args", "youtube:player_client=android_vr,web_safari",
                            "-f", "bestaudio/best", "-x", "--audio-format", "mp3", "--audio-quality", "0",
                            "-o", output, f"https://www.youtube.com/watch?v={video_id}"],
                           capture_output=True, text=True, check=True, timeout=600)
            tracks = list(Path(job["folder"]).glob(f"youtube-{video_id}.mp3"))
            if not tracks:
                raise RuntimeError("MP3 conversion did not produce a file.")
            job["pending_music"] = tracks[0]
            track_duration = duration(str(tracks[0]))
            # Keep the display title so a reconnecting page can rebuild the list.
            job["pending_music_meta"] = {"name": str(request.get("title") or tracks[0].name),
                                         "duration": track_duration, "kind": "youtube"}
            return self._json(HTTPStatus.OK, {"name": tracks[0].name, "duration": track_duration})
        except subprocess.CalledProcessError as exc:
            detail = exc.stderr.strip().splitlines()[-1] if exc.stderr.strip() else "yt-dlp failed"
            if "HTTP Error 403" in detail or "Forbidden" in detail:
                detail = "YouTube blocked this download. Update yt-dlp to its latest version, then restart RK Motion."
            elif "Requested format is not available" in detail:
                detail = "No downloadable audio format was exposed by YouTube for this result. Try another result or update yt-dlp."
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": detail})
        except Exception as exc:
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": str(exc)})

    def _attach_pending_music(self, job_id: str) -> None:
        job = JOBS.get(job_id)
        if not job or not job.get("pending_music"):
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "No downloaded music is waiting to be added."})
        job.setdefault("music", []).append(job.pop("pending_music"))
        meta = job.pop("pending_music_meta", None)
        if meta:
            job.setdefault("music_meta", []).append(meta)
        return self._json(HTTPStatus.OK, {"ok": True})

    def _prepare_batch(self) -> None:
        job_id = uuid.uuid4().hex
        folder = Path(tempfile.mkdtemp(prefix="rk-motion-"))
        JOBS[job_id] = {"folder": folder, "inputs": []}
        return self._json(HTTPStatus.OK, {"job_id": job_id})

    def _upload_video(self, job_id: str) -> None:
        job = JOBS.get(job_id)
        size = int(self.headers.get("Content-Length", "0"))
        if not job:
            return self._json(HTTPStatus.NOT_FOUND, {"error": "Video session not found."})
        if not size or size > 30 * 1024 * 1024 * 1024:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "Choose video files smaller than 30GB."})
        suffix = Path(unquote(self.headers.get("X-Filename", "ride.mp4"))).suffix or ".mp4"
        target = Path(job["folder"]) / f"input-{len(job['inputs']):03d}{suffix}"
        remaining = size
        with target.open("wb") as handle:
            while remaining:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    return self._json(HTTPStatus.BAD_REQUEST, {"error": "Video upload ended early."})
                handle.write(chunk)
                remaining -= len(chunk)
        job["inputs"].append(target)
        return self._json(HTTPStatus.OK, {"index": len(job["inputs"])})

    def _analyse_batch(self, job_id: str) -> None:
        """Start analysis in the background; the client polls /api/analyse-status."""
        job = JOBS.get(job_id)
        if not job or not job.get("inputs"):
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "Add at least one video first."})
        raw_max = self.headers.get("X-Max-Scene-Length", "").strip()
        max_duration = float(raw_max) if raw_max else None
        # A conservative size-based estimate, presented to the user as one.
        total_mb = sum(item.stat().st_size for item in job["inputs"]) / 1e6
        estimate = max(15, round(total_mb * 0.5 + len(job["inputs"]) * 6))
        job["analyse_status"] = {"state": "running", "started": time.monotonic(),
                                 "estimated_seconds": estimate,
                                 "message": "מכינה את הסרטונים…"}
        threading.Thread(target=self._run_analyse, args=(job, job_id, max_duration), daemon=True).start()
        return self._json(HTTPStatus.ACCEPTED, {"status_url": f"/api/analyse-status/{job_id}"})

    @classmethod
    def _run_analyse(cls, job: dict, job_id: str, max_duration: float | None) -> None:
        status = job["analyse_status"]
        try:
            def progress(index: int, count: int) -> None:
                status["message"] = (f"מנרמלת סרטון {index + 1}/{count}…" if count > 1
                                     else "מכינה את הסרטון…")

            source = cls._combine_videos(job["inputs"], Path(job["folder"]), progress)
            job["source"] = source
            status["message"] = "מנתחת תנועה וסאונד…"
            report = analyse_action(str(source), max_duration=max_duration)
            report["job_id"] = job_id
            job["report"] = report
            status.update({"state": "done", "message": "הניתוח הושלם.", "report": report})
        except Exception as exc:
            detail = str(exc)
            stderr = getattr(exc, "stderr", None)
            if stderr:
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", "replace")
                detail = stderr.strip().splitlines()[-1] if stderr.strip() else detail
            status.update({"state": "error", "message": detail or "הניתוח נכשל."})

    @staticmethod
    def _combine_videos(inputs: list[Path], folder: Path, progress=None) -> Path:
        """Normalise clips then concatenate, preserving their drag/drop order."""
        from .action import _has_audio
        normalised = []
        for index, source in enumerate(inputs):
            if progress:
                progress(index, len(inputs))
            target = folder / f"normalised-{index:03d}.mp4"
            cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(source), "-f", "lavfi", "-i",
                   "anullsrc=r=48000:cl=stereo", "-vf",
                   "scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih),setsar=1,fps=30",
                   "-map", "0:v:0", "-map", "0:a:0" if _has_audio(str(source)) else "1:a:0",
                   "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-c:a", "aac", "-shortest", str(target)]
            subprocess.run(cmd, check=True, capture_output=True)
            normalised.append(target)
        listing = folder / "videos.txt"
        listing.write_text("".join("file '" + str(item).replace("'", "'\\''") + "'\n" for item in normalised))
        output = folder / "source.mp4"
        subprocess.run(["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", str(listing),
                        "-c", "copy", "-movflags", "+faststart", str(output)], check=True, capture_output=True)
        return output

    def _upload_music(self, job_id: str) -> None:
        job = JOBS.get(job_id)
        size = int(self.headers.get("Content-Length", "0"))
        if not job:
            return self._json(HTTPStatus.NOT_FOUND, {"error": "Video session not found."})
        if not size or size > 2 * 1024 * 1024 * 1024:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "Choose an audio file smaller than 2GB."})
        name = Path(unquote(self.headers.get("X-Filename", "music.mp3"))).name
        suffix = Path(name).suffix.lower() or ".mp3"
        if suffix not in {".mp3", ".m4a", ".aac", ".wav", ".ogg"}:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": "Choose an MP3, M4A, AAC, WAV or OGG file."})
        target = Path(job["folder"]) / f"music-{len(job.get('music', [])):02d}{suffix}"
        remaining = size
        with target.open("wb") as handle:
            while remaining:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    return self._json(HTTPStatus.BAD_REQUEST, {"error": "Music upload ended early."})
                handle.write(chunk)
                remaining -= len(chunk)
        job.setdefault("music", []).append(target)
        track_duration = duration(str(target))
        job.setdefault("music_meta", []).append({"name": name, "duration": track_duration, "kind": "file"})
        return self._json(HTTPStatus.OK, {"name": name, "duration": track_duration})

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
            raw_max = self.headers.get("X-Max-Scene-Length", "").strip()
            max_duration = float(raw_max) if raw_max else None
            report = analyse_action(str(source), max_duration=max_duration)
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
            if not clips:
                raise ValueError("select at least one clip before exporting")
            # A conservative local estimate. It is clearly presented as an
            # estimate; actual FFmpeg speed changes with codec and Mac model.
            edit_seconds = sum(float(clip["end"]) - float(clip["start"]) for clip in clips)
            estimate = max(12, round(edit_seconds * 1.25 + 8))
            job["export_status"] = {"state": "running", "started": time.monotonic(),
                                    "estimated_seconds": estimate,
                                    "message": "מכינה את קטעי הווידאו…"}
            threading.Thread(target=self._run_export,
                             args=(job, clips, request.get("transition", "cut"),
                                   float(request.get("transition_duration", .5)),
                                   bool(request.get("use_music")), float(request.get("music_start", 0)),
                                   float(request.get("speed", 1)), bool(request.get("remove_original_audio"))), daemon=True).start()
            return self._json(HTTPStatus.ACCEPTED, {"status_url": f"/api/export-status/{request['job_id']}"})
        except (KeyError, ValueError, TypeError) as exc:
            return self._json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except Exception as exc:
            detail = str(exc)
            stderr = getattr(exc, "stderr", None)
            if stderr:
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", "replace")
                detail = stderr.strip().splitlines()[-1] if stderr.strip() else detail
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY,
                              {"error": f"Export failed: {detail}"})

    @staticmethod
    def _run_export(job: dict, clips: list[dict], transition: str, transition_duration: float,
                    use_music: bool, music_start: float, speed: float,
                    remove_original_audio: bool) -> None:
        try:
            job["export_status"]["message"] = "מייצאת את הסרט הערוך…"
            output = Path(job["folder"]) / "RK-Motion-edit.mp4"
            export_edited_movie(str(job["source"]), clips, str(output),
                                transition=transition, transition_duration=transition_duration,
                                music_paths=[str(item) for item in job["music"]] if use_music and job.get("music") else None,
                                music_start=music_start, speed=speed,
                                remove_original_audio=remove_original_audio)
            job["export"] = output
            job["export_status"].update({"state": "done", "progress": 100,
                                         "message": "הסרט מוכן.", "download": f"/api/export/{job['report']['job_id']}"})
        except Exception as exc:
            detail = str(exc)
            stderr = getattr(exc, "stderr", None)
            if stderr:
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", "replace")
                detail = stderr.strip().splitlines()[-1] if stderr.strip() else detail
            job["export_status"].update({"state": "error", "message": f"Export failed: {detail}"})


def _lan_ip() -> str | None:
    """Best-effort local network address of this machine (no traffic is sent)."""
    import socket
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect(("192.0.2.1", 9))  # TEST-NET-1: routable-looking, never contacted
        ip = probe.getsockname()[0]
        return ip if not ip.startswith("127.") else None
    except OSError:
        return None
    finally:
        probe.close()


def _print_qr(text: str) -> bool:
    """Print a scannable QR code to the terminal. Returns False if unavailable."""
    try:
        import qrcode
    except ImportError:
        return False
    qr = qrcode.QRCode(border=1)
    qr.add_data(text)
    qr.make(fit=True)
    matrix = qr.get_matrix()
    # Two rows per line via half-block characters, so the code stays roughly square.
    for y in range(0, len(matrix), 2):
        line = []
        for x in range(len(matrix[0])):
            top = matrix[y][x]
            bottom = matrix[y + 1][x] if y + 1 < len(matrix) else False
            line.append("█" if top and bottom else "▀" if top else "▄" if bottom else " ")
        print("".join(line))
    return True


def launch_ui(port: int = 8787, lan: bool = False) -> int:
    """Start RK Motion and open it in the default browser.

    With ``lan=True`` the server also accepts connections from other devices on
    the same Wi-Fi (e.g. an iPhone), so a phone can drive the editor while this
    machine does the processing. Off by default: the server stays on localhost.
    """
    host = "0.0.0.0" if lan else "127.0.0.1"
    server = ThreadingHTTPServer((host, port), RKMotionHandler)
    url = f"http://127.0.0.1:{port}"
    print(f"RK Motion is running at {url} (Ctrl+C to stop)")
    if lan:
        ip = _lan_ip()
        if ip:
            lan_url = f"http://{ip}:{port}"
            print(f"\nOn your phone (same Wi-Fi), open: {lan_url}")
            print("Scan this QR code to open it directly:\n")
            if not _print_qr(lan_url):
                print("(Install 'qrcode' for a scannable code here — pip install qrcode)")
            print("\nAnyone on this Wi-Fi can reach the app while it runs.\n")
        else:
            print("\nLAN mode is on, but no network address was found. "
                  "Connect to Wi-Fi and restart to share with a phone.\n")
    threading.Timer(.3, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    finally:
        server.server_close()
        for job in JOBS.values():
            shutil.rmtree(job["folder"], ignore_errors=True)
