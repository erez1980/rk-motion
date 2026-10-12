"""Explicit device pairing; LAN clients cannot access another client's jobs."""
from __future__ import annotations

import hashlib
import secrets
import threading
import time
from http.cookies import SimpleCookie
from pathlib import Path

from .storage import atomic_json


class Pairing:
    def __init__(self, path: Path | None = None):
        self.path = path
        self.lock = threading.RLock()
        self.clients = {}
        if path and path.exists():
            import json
            try:
                self.clients = json.loads(path.read_text())
            except (OSError, ValueError):
                pass
        self.attempts = {}
        self.rotate()

    def rotate(self):
        with self.lock:
            self.code = secrets.token_urlsafe(24)
            self.expires = time.time() + 600
            return self.code

    def pair(self, code, address):
        with self.lock:
            now = time.time()
            recent = [t for t in self.attempts.get(address, []) if now - t < 60]
            if len(recent) >= 6:
                raise ValueError("Too many pairing attempts. Wait one minute.")
            self.attempts[address] = recent + [now]
            if now > self.expires or not secrets.compare_digest(str(code), self.code):
                raise ValueError("Pairing link expired or invalid. Open a new link on the Mac.")
            token = secrets.token_urlsafe(32)
            client = secrets.token_hex(16)
            self.clients[hashlib.sha256(token.encode()).hexdigest()] = client
            if self.path:
                atomic_json(self.path, self.clients)
                self.path.chmod(0o600)
            return token, client

    def authenticate(self, headers):
        auth = headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        if not token:
            cookie = SimpleCookie()
            try:
                cookie.load(headers.get("Cookie", ""))
                token = cookie["rk_session"].value if "rk_session" in cookie else ""
            except Exception:
                return None
        with self.lock:
            return self.clients.get(hashlib.sha256(token.encode()).hexdigest()) if token else None
