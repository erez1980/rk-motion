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

from . import __version__
from .action import (analyse_action, duration, export_edited_movie, h264_args,
                     h264_encoder, run_encode)

ASSETS = Path(__file__).with_name("assets")
INDEX = ASSETS / "index.html"
# Everything the page may request from /assets/. The home-screen icons are
# square and opaque on purpose: iOS and Android apply their own rounded mask.
STATIC_ASSETS = {
    "rk-logo.png": "image/png",
    "app-icon.png": "image/png",
    "icon-180.png": "image/png",
    "icon-192.png": "image/png",
    "icon-512.png": "image/png",
    "manifest.webmanifest": "application/manifest+json",
}
FONT = Path(__file__).with_name("data") / "fonts" / "Rubik.ttf"
JOBS: dict[str, dict] = {}

# Time estimates learn this machine's real speed. Work is measured in
# megapixel-seconds (video duration x frame megapixels — a decode/encode cost
# proxy); rates are Mpx-s processed per wall second, refined after every run
# and kept in a tiny stats file (numbers only, no media or names).
PERF_FILE = Path.home() / ".rk-motion" / "perf.json"
DEFAULT_RATES = {"fast": 40.0, "encode": 8.0, "export": 5.0}


class _Phases:
    """One honest progress bar across the steps of a job.

    Every step reports its own 0..1 fraction. The bar weights the steps by how
    long this machine is expected to spend on each, and the time left is
    re-measured from the step's real speed — so a slow conversion no longer
    parks on a full bar with nothing left to say.
    """

    def __init__(self, status: dict, weights: list[float]) -> None:
        self._status = status
        self._weights = [max(w, 1e-6) for w in weights] or [1.0]
        self._total = sum(self._weights)
        self._index = 0
        self._started = time.monotonic()

    def start(self, index: int, message: str) -> None:
        """Move to the next step and restart the speed measurement."""
        self._index = min(index, len(self._weights) - 1)
        self._started = time.monotonic()
        self.note(message)
        self.update(0.0)

    def note(self, message: str) -> None:
        """Relabel the current step — several files can share one step, and
        restarting the clock for each of them would skew the time left."""
        self._status["message"] = message

    def update(self, fraction: float) -> None:
        fraction = min(1.0, max(0.0, fraction))
        weight = self._weights[self._index]
        done = sum(self._weights[:self._index]) + weight * fraction
        self._status["percent"] = min(99, round(done / self._total * 100))
        elapsed = time.monotonic() - self._started
        # Wait for a real sample before quoting a time; the first seconds of an
        # ffmpeg run are not representative.
        if fraction > .03 and elapsed > 3:
            per_unit = elapsed / fraction / weight
            left = sum(self._weights[self._index:]) - weight * fraction
            self._status["eta_seconds"] = round(left * per_unit)


def _perf_rates() -> dict:
    try:
        saved = json.loads(PERF_FILE.read_text())
        return {key: float(saved.get(key, value)) for key, value in DEFAULT_RATES.items()}
    except Exception:
        return dict(DEFAULT_RATES)


def _record_rate(kind: str, work: float, elapsed: float) -> None:
    """Blend the measured rate into the stored one (equal-weight EMA)."""
    if kind not in DEFAULT_RATES or work <= 0 or elapsed <= 1:
        return
    rates = _perf_rates()
    rates[kind] = round((rates[kind] + work / elapsed) / 2, 2)
    try:
        PERF_FILE.parent.mkdir(parents=True, exist_ok=True)
        PERF_FILE.write_text(json.dumps(rates))
    except OSError:
        pass  # estimates just stay at their previous accuracy


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
        if len(parts) == 2 and parts[0] == "assets" and parts[1] in STATIC_ASSETS:
            return self._file(ASSETS / parts[1], STATIC_ASSETS[parts[1]])
        if parts == ["assets", "rubik.ttf"]:
            return self._file(FONT, "font/ttf")
        if len(parts) == 4 and parts[:2] == ["api", "export"]:
            job = JOBS.get(parts[2])
            try:
                entry = job["exports"][int(parts[3]) - 1] if job else None
            except (KeyError, IndexError, ValueError):
                entry = None
            if not entry:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            return self._file(Path(entry["file"]), "video/mp4", attachment=True)
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
            state.pop("phase_weights", None)   # internal pacing, not the client's business
            started = state.get("started")
            if started:
                state["elapsed_seconds"] = round(time.monotonic() - started, 1)
                del state["started"]  # monotonic time is meaningless to the client
            return self._json(HTTPStatus.OK, state)
        if parts == ["api", "capabilities"]:
            encoder = h264_encoder()
            return self._json(HTTPStatus.OK, {"youtube": bool(shutil.which("yt-dlp")),
                                              "version": __version__, "encoder": encoder,
                                              "gpu": encoder != "libx264"})
        if len(parts) == 3 and parts[:2] == ["api", "session"]:
            # Lets a page that was closed mid-job rebuild its state on return.
            job = JOBS.get(parts[2])
            if not job:
                return self._json(HTTPStatus.NOT_FOUND, {"error": "Session not found."})
            return self._json(HTTPStatus.OK, {
                "music": job.get("music_meta", []),
                "pending_music": job.get("pending_music_meta"),
                "exporting": "export_status" in job,
                "exports": [{k: item[k] for k in ("version", "download", "clips", "duration", "quality", "aspect")}
                            for item in job.get("exports", [])],
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

    # Tried in order until one produces a file. YouTube's anti-bot rules shift
    # often, and yt-dlp's own default client choice (no override) is kept
    # current by its maintainers — so that goes first, not a client we pin
    # ourselves. The rest are fallbacks other client combos that have worked
    # historically when the default is blocked on a given network.
    YOUTUBE_CLIENT_ATTEMPTS = [None, "tv,web_safari", "android_vr,web_safari", "web_creator,mweb"]

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
            url = f"https://www.youtube.com/watch?v={video_id}"
            last_error = None
            for clients in self.YOUTUBE_CLIENT_ATTEMPTS:
                cmd = ["yt-dlp", "--no-playlist", "-f", "bestaudio/best", "-x",
                       "--audio-format", "mp3", "--audio-quality", "0", "-o", output]
                if clients:
                    cmd.extend(["--extractor-args", f"youtube:player_client={clients}"])
                cmd.append(url)
                try:
                    subprocess.run(cmd, capture_output=True, text=True, check=True, timeout=180)
                    last_error = None
                    break
                except subprocess.CalledProcessError as exc:
                    last_error = exc
                except subprocess.TimeoutExpired as exc:
                    last_error = exc
            if last_error is not None:
                raise last_error
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
            if "HTTP Error 403" in detail or "Forbidden" in detail or "Sign in to confirm" in detail:
                detail = "YouTube חסמה כרגע את ההורדה מהשיר הזה. נסו שוב בעוד כמה דקות, או בחרו תוצאה אחרת."
            elif "Requested format is not available" in detail:
                detail = "לא נמצא פורמט אודיו להורדה מהתוצאה הזו. נסו תוצאה אחרת."
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY, {"error": detail})
        except subprocess.TimeoutExpired:
            return self._json(HTTPStatus.UNPROCESSABLE_ENTITY,
                              {"error": "ההורדה ארכה יותר מדי זמן. נסו שוב או בחרו תוצאה אחרת."})
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
        # Estimate from the actual work (duration x resolution) at this
        # machine's learned speed, not from file size with a fixed constant.
        try:
            codec = self._video_meta(job["inputs"][0])[0]
        except Exception:
            codec = ""
        kind = "fast" if len(job["inputs"]) == 1 and codec == "h264" else "encode"
        work = 0.0
        for item in job["inputs"]:
            try:
                _, width, height = self._video_meta(item)
                work += duration(str(item)) * (width * height / 1e6)
            except Exception:
                work += item.stat().st_size / 3e6  # rough fallback when probing fails
        rates = _perf_rates()
        estimate = max(8, round(work / rates[kind] + 4))
        # Two steps share the bar: preparing the source (a re-encode, unless a
        # single H.264 file can be used as-is) and the motion/sound scan.
        prepare = 0.0 if kind == "fast" else work / rates["encode"]
        job["analyse_perf"] = {"kind": kind, "work": work}
        job["analyse_status"] = {"state": "running", "started": time.monotonic(),
                                 "estimated_seconds": estimate, "percent": 0,
                                 "phase_weights": [prepare, work / rates["fast"]],
                                 "message": "מכינה את הסרטונים…"}
        threading.Thread(target=self._run_analyse, args=(job, job_id, max_duration), daemon=True).start()
        return self._json(HTTPStatus.ACCEPTED, {"status_url": f"/api/analyse-status/{job_id}"})

    @classmethod
    def _run_analyse(cls, job: dict, job_id: str, max_duration: float | None) -> None:
        status = job["analyse_status"]
        try:
            phases = _Phases(status, status.get("phase_weights") or [0.0, 1.0])

            def prepared(message: str, fraction: float = 0.0) -> None:
                phases.note(message)
                phases.update(fraction)

            source = cls._prepare_source(job["inputs"], Path(job["folder"]), prepared)
            job["source"] = source
            phases.start(1, "מנתחת תנועה וסאונד…")
            report = analyse_action(str(source), max_duration=max_duration,
                                    progress=phases.update)
            report["job_id"] = job_id
            job["report"] = report
            perf = job.get("analyse_perf", {})
            _record_rate(perf.get("kind", ""), perf.get("work", 0),
                         time.monotonic() - status["started"])
            status.update({"state": "done", "message": "הניתוח הושלם.", "report": report,
                           "percent": 100, "eta_seconds": 0})
        except Exception as exc:
            detail = str(exc)
            stderr = getattr(exc, "stderr", None)
            if stderr:
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", "replace")
                detail = stderr.strip().splitlines()[-1] if stderr.strip() else detail
            status.update({"state": "error", "message": detail or "הניתוח נכשל."})

    @staticmethod
    def _video_meta(path: Path) -> tuple[str, int, int]:
        """(codec, width, height) of the first video stream."""
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v:0",
             "-show_entries", "stream=codec_name,width,height", "-of", "json", str(path)],
            capture_output=True, text=True, check=True)
        stream = json.loads(result.stdout)["streams"][0]
        return stream.get("codec_name", ""), int(stream.get("width", 0)), int(stream.get("height", 0))

    @staticmethod
    def _video_bitrate(path: Path) -> int:
        """Bits per second of the video stream, 0 when the container hides it."""
        try:
            result = subprocess.run(
                ["ffprobe", "-v", "error", "-select_streams", "v:0",
                 "-show_entries", "stream=bit_rate", "-of",
                 "default=noprint_wrappers=1:nokey=1", str(path)],
                capture_output=True, text=True, check=True)
            return int(result.stdout.strip())
        except (subprocess.CalledProcessError, ValueError):
            return 0

    @staticmethod
    def _safe_duration(path: Path) -> float:
        """Length in seconds, or 0 when it cannot be read (progress then just
        falls back to a message with no percentage)."""
        try:
            return duration(str(path))
        except Exception:
            return 0.0

    @classmethod
    def _prepare_source(cls, inputs: list[Path], folder: Path, progress=None) -> Path:
        """Build the editing source at the footage's native resolution.

        A single H.264 file is used as-is (no re-encode, no quality loss);
        other codecs are converted once at source resolution for browser
        preview; several files are normalised to the first file's size so they
        can be concatenated in drop order.

        ``progress(message, fraction)`` is called as the work advances, with a
        real 0..1 fraction taken from ffmpeg rather than a guess.
        """
        from .action import _has_audio
        codec, width, height = cls._video_meta(inputs[0])
        if len(inputs) == 1:
            if codec == "h264":
                return inputs[0]
            label = "ממירה את הסרטון לפורמט תואם, באיכות מלאה…"
            if progress:
                progress(label, 0.0)
            target = folder / "source.mp4"
            cmd = ["ffmpeg", "-y", "-v", "error", "-hwaccel", "auto", "-i", str(inputs[0]),
                   "-map", "0:v:0", "-map", "0:a?",
                   *h264_args(width, height, cls._video_bitrate(inputs[0])),
                   "-c:a", "aac", "-movflags", "+faststart", str(target)]
            run_encode(cmd, cls._safe_duration(inputs[0]),
                       (lambda done: progress(label, done)) if progress else None)
            return target
        width, height = max(2, width - width % 2), max(2, height - height % 2)
        normalised = []
        for index, source in enumerate(inputs):
            label = f"מנרמלת סרטון {index + 1}/{len(inputs)}…"
            # Each file owns its slice of the step, so the bar keeps climbing
            # across a multi-clip batch instead of restarting per file.
            span, base = 1 / len(inputs), index / len(inputs)
            if progress:
                progress(label, base)
            target = folder / f"normalised-{index:03d}.mp4"
            cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(source), "-f", "lavfi", "-i",
                   "anullsrc=r=48000:cl=stereo", "-vf",
                   f"scale={width}:{height}:force_original_aspect_ratio=decrease,"
                   f"pad={width}:{height}:(ow-iw)/2:(oh-ih),setsar=1,fps=30",
                   "-map", "0:v:0", "-map", "0:a:0" if _has_audio(str(source)) else "1:a:0",
                   *h264_args(width, height, cls._video_bitrate(source)),
                   "-c:a", "aac", "-shortest", str(target)]
            run_encode(cmd, cls._safe_duration(source),
                       (lambda done: progress(label, base + span * done)) if progress else None)
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
            # Work-based estimate at this machine's learned encode speed;
            # the output resolution cap bounds the real work.
            edit_seconds = sum(float(clip["end"]) - float(clip["start"]) for clip in clips)
            quality = str(request.get("quality", "1080"))
            aspect = str(request.get("aspect", "16:9"))
            try:
                _, width, height = self._video_meta(Path(job["source"]))
                cap = {"720": 720, "1080": 1080, "whatsapp": 720}.get(quality)
                if cap and height > cap:
                    width, height = round(width * cap / height), cap
                if aspect == "9:16":
                    width = (height * 9 // 16) // 2 * 2
                work = edit_seconds * (width * height / 1e6)
            except Exception:
                work = edit_seconds * 2
            estimate = max(10, round(work / _perf_rates()["export"] + 5))
            job["export_perf"] = {"work": work}
            job["export_status"] = {"state": "running", "started": time.monotonic(),
                                    "estimated_seconds": estimate, "percent": 0,
                                    "message": "מכינה את קטעי הווידאו…"}
            threading.Thread(target=self._run_export,
                             args=(job, clips, request.get("transition", "cut"),
                                   float(request.get("transition_duration", .5)),
                                   bool(request.get("use_music")), float(request.get("music_start", 0)),
                                   float(request.get("speed", 1)), bool(request.get("remove_original_audio")),
                                   quality, float(request.get("music_volume", .65)), aspect), daemon=True).start()
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
                    remove_original_audio: bool, quality: str = "1080",
                    music_volume: float = .65, aspect: str = "16:9") -> None:
        status = job["export_status"]
        try:
            status["message"] = "מייצאת את הסרט הערוך…"
            phases = _Phases(status, [1.0])
            version = len(job.get("exports", [])) + 1
            output = Path(job["folder"]) / f"RK-Motion-edit-{version:02d}.mp4"
            export_edited_movie(str(job["source"]), clips, str(output),
                                transition=transition, transition_duration=transition_duration,
                                music_paths=[str(item) for item in job["music"]] if use_music and job.get("music") else None,
                                music_start=music_start, speed=speed,
                                remove_original_audio=remove_original_audio,
                                quality=quality, music_volume=music_volume, aspect=aspect,
                                progress=phases.update)
            job["export"] = output
            job_id = job["report"]["job_id"]
            entry = {"file": str(output), "version": version,
                     "download": f"/api/export/{job_id}/{version}",
                     "clips": len(clips), "duration": round(duration(str(output)), 1),
                     "quality": quality, "aspect": aspect}
            job.setdefault("exports", []).append(entry)
            history = [{k: item[k] for k in ("version", "download", "clips", "duration", "quality", "aspect")}
                       for item in job["exports"]]
            _record_rate("export", job.get("export_perf", {}).get("work", 0),
                         time.monotonic() - job["export_status"]["started"])
            status.update({"state": "done", "percent": 100, "eta_seconds": 0,
                           "message": "הסרט מוכן.", "history": history,
                           "download": f"/api/export/{job_id}"})
        except Exception as exc:
            detail = str(exc)
            stderr = getattr(exc, "stderr", None)
            if stderr:
                if isinstance(stderr, bytes):
                    stderr = stderr.decode("utf-8", "replace")
                detail = stderr.strip().splitlines()[-1] if stderr.strip() else detail
            status.update({"state": "error", "message": f"Export failed: {detail}"})


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
    encoder = h264_encoder()
    hardware = "GPU" if encoder != "libx264" else "CPU"
    print(f"RK Motion v{__version__} is running at {url} (Ctrl+C to stop)")
    print(f"Video encoding: {encoder} ({hardware})")
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
