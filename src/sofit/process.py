"""Cancelable subprocesses with concurrent pipe draining and bounded waits."""
from __future__ import annotations

import contextlib
import os
import subprocess
import tempfile
import threading
import time

TIMEOUT = float(os.environ.get("RK_MOTION_PROCESS_TIMEOUT", "7200"))
_context = threading.local()


class Cancelled(RuntimeError):
    pass


class Worker:
    def __init__(self):
        self.event = threading.Event()
        self.lock = threading.Lock()
        self.processes = set()

    def cancel(self):
        self.event.set()
        with self.lock:
            for proc in list(self.processes):
                if proc.poll() is None:
                    proc.kill()

    def check(self):
        if self.event.is_set():
            raise Cancelled("The operation was canceled.")


@contextlib.contextmanager
def scope(worker):
    previous = getattr(_context, "worker", None)
    _context.worker = worker
    try:
        worker.check()
        yield
    finally:
        _context.worker = previous


class StreamProcess:
    """stderr goes to disk, so reading stdout cannot deadlock on an error pipe."""
    def __init__(self, cmd, *, text=False, timeout=TIMEOUT, stdin=False):
        self.worker = getattr(_context, "worker", None)
        if self.worker:
            self.worker.check()
        self.errors = tempfile.TemporaryFile(mode="w+" if text else "w+b")
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE if stdin else None, stdout=subprocess.PIPE, stderr=self.errors, text=text)
        self.stdin = self.proc.stdin
        self.stdout = self.proc.stdout
        self.expired = False
        self.timer = threading.Timer(timeout, self._expire)
        self.timer.daemon = True
        if self.worker:
            with self.worker.lock:
                self.worker.processes.add(self.proc)
                if self.worker.event.is_set():
                    self.proc.kill()
        self.timer.start()

    def _expire(self):
        if self.proc.poll() is None:
            self.expired = True
            self.proc.kill()

    @property
    def stderr(self):
        self.errors.seek(max(0, self.errors.seek(0, 2) - 65536))
        return self.errors

    def wait(self):
        try:
            code = self.proc.wait()
            if self.worker:
                self.worker.check()
            if self.expired:
                raise subprocess.TimeoutExpired(self.proc.args, TIMEOUT)
            return code
        finally:
            self.timer.cancel()
            if self.worker:
                with self.worker.lock:
                    self.worker.processes.discard(self.proc)

    def close(self):
        self.timer.cancel()
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait()
        if self.stdout:
            self.stdout.close()
        if self.stdin and not self.stdin.closed:
            self.stdin.close()
        self.errors.close()
        if self.worker:
            with self.worker.lock:
                self.worker.processes.discard(self.proc)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def run(cmd, *, timeout=TIMEOUT, **kwargs):
    """subprocess.run with cancellation inherited from the current worker."""
    worker = getattr(_context, "worker", None)
    if worker is None:
        return subprocess.run(cmd, timeout=timeout, **kwargs)
    worker.check()
    check = kwargs.pop("check", False)
    capture = kwargs.pop("capture_output", False)
    if capture:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    data = kwargs.pop("input", None)
    if data is not None:
        kwargs["stdin"] = subprocess.PIPE
    with subprocess.Popen(cmd, **kwargs) as proc:
        with worker.lock:
            worker.processes.add(proc)
            if worker.event.is_set():
                proc.kill()
        deadline = time.monotonic() + timeout
        try:
            while True:
                worker.check()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(cmd, timeout)
                try:
                    out, err = proc.communicate(data, timeout=min(.25, remaining))
                    break
                except subprocess.TimeoutExpired:
                    data = None
            worker.check()
            if check and proc.returncode:
                raise subprocess.CalledProcessError(proc.returncode, cmd, out, err)
            return subprocess.CompletedProcess(cmd, proc.returncode, out, err)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            with worker.lock:
                worker.processes.discard(proc)
