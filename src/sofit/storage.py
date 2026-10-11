"""Atomic documents and safe identifiers for projects and imported clip specs."""
from __future__ import annotations

import json
import math
import os
import re
import tempfile
from pathlib import Path


def atomic_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, allow_nan=False, default=str)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(name, path)
    finally:
        Path(name).unlink(missing_ok=True)


def identifier(value):
    value = str(value)
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,127}", value):
        raise ValueError("Invalid identifier; use letters, numbers, underscores or hyphens.")
    return value


def validate_clips(clips, total):
    if not isinstance(clips, list) or not 1 <= len(clips) <= 500:
        raise ValueError("Select between 1 and 500 clips.")
    for clip in clips:
        if not isinstance(clip, dict):
            raise ValueError("Invalid clip.")
        start, end = float(clip["start"]), float(clip["end"])
        if not all(map(math.isfinite, (start, end))) or not 0 <= start < end <= total + .05:
            raise ValueError("Clip times must be inside the source video.")
    return clips
