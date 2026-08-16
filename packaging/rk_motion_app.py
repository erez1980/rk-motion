"""Desktop entry point for the packaged RK Motion app.

PyInstaller freezes this script. It puts the bundled FFmpeg on PATH, picks a
free local port, and starts the same local web UI that `sofit --ui` opens.
"""
from __future__ import annotations

import os
import socket
import sys


def main() -> int:
    bundle_dir = getattr(sys, "_MEIPASS", None)
    if bundle_dir:
        bundled_bin = os.path.join(bundle_dir, "bin")
        if os.path.isdir(bundled_bin):
            os.environ["PATH"] = bundled_bin + os.pathsep + os.environ.get("PATH", "")

    port = 8787
    for candidate in range(8787, 8817):
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", candidate))
            except OSError:
                continue
        port = candidate
        break

    # Set RK_MOTION_LAN=1 to let a phone on the same Wi-Fi drive the editor.
    lan = os.environ.get("RK_MOTION_LAN", "").strip().lower() in ("1", "true", "yes")

    from sofit.ui import launch_ui

    return launch_ui(port, lan=lan)


if __name__ == "__main__":
    raise SystemExit(main())
