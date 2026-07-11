"""MCP server tests. Skipped if the optional `mcp` dependency isn't installed."""

import pytest

pytest.importorskip("mcp")

from hebrew_chapters import mcp_server as m  # noqa: E402


def test_generate_kit_errors_when_not_transcribed(tmp_path):
    # No cached transcript and a nonexistent file -> clear error, no Claude call.
    res = m.generate_kit(str(tmp_path / "missing.mp3"))
    assert "error" in res and "transcribe" in res["error"]


def test_status_not_started_for_unknown(tmp_path):
    res = m.transcription_status(str(tmp_path / "missing.mp3"))
    assert res["status"] == "not_started"


def test_status_ready_when_cached(monkeypatch, tmp_path):
    # A real file that exists + stubbed cache lookup -> 'ready', no real transcript.
    f = tmp_path / "ep.mp3"
    f.write_bytes(b"x")
    monkeypatch.setattr(m.transcribe, "cached_segments", lambda *a, **k: [object()])
    assert m.transcription_status(str(f))["status"] == "ready"


def test_tools_registered():
    # The three tools are exposed on the FastMCP instance.
    import asyncio

    names = {t.name for t in asyncio.run(m.mcp.list_tools())}
    assert {"transcribe_episode", "transcription_status", "generate_kit"} <= names
