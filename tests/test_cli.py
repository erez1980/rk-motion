"""CLI --render-from tests: render from a saved clips.json without transcribing."""

import json

from hebrew_chapters import cli


def _doc(tmp_path):
    video = tmp_path / "ep.mp4"
    video.write_bytes(b"x")
    doc = {"schema_version": 1, "source": {"video": str(video)}, "clips": [
        {"id": "clip-1", "words": [{"t": 0, "d": 0.3, "w": "א"}]},
        {"id": "clip-2", "words": [{"t": 0, "d": 0.3, "w": "ב"}]},
    ]}
    p = tmp_path / "clips.json"
    p.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
    return p


def _no_transcribe(monkeypatch):
    import hebrew_chapters.transcribe as t

    def boom(*a, **k):
        raise AssertionError("transcription must not run for --render-from")
    monkeypatch.setattr(t, "transcribe", boom)


def test_render_from_skips_transcription(monkeypatch, tmp_path):
    p = _doc(tmp_path)
    _no_transcribe(monkeypatch)
    import hebrew_chapters.render as r
    rendered = {}
    monkeypatch.setattr(r, "render_clips",
                        lambda v, clips, out, aspect="9:16", **k:
                        (rendered.__setitem__("clips", clips)
                         or [f"{out}/{c['id']}.mp4" for c in clips]))
    rc = cli.main(["--render-from", str(p), "--render-clips", str(tmp_path / "out")])
    assert rc == 0
    assert {c["id"] for c in rendered["clips"]} == {"clip-1", "clip-2"}


def test_render_from_only_filters_one_clip(monkeypatch, tmp_path):
    p = _doc(tmp_path)
    _no_transcribe(monkeypatch)
    import hebrew_chapters.render as r
    rendered = {}
    monkeypatch.setattr(r, "render_clips",
                        lambda v, clips, out, aspect="9:16", **k:
                        (rendered.__setitem__("clips", clips) or []))
    rc = cli.main(["--render-from", str(p), "--only", "clip-2",
                   "--render-clips", str(tmp_path / "o")])
    assert rc == 0
    assert {c["id"] for c in rendered["clips"]} == {"clip-2"}


def test_render_from_only_missing_id_errors(tmp_path):
    p = _doc(tmp_path)
    assert cli.main(["--render-from", str(p), "--only", "clip-9"]) == 1


def test_media_required_without_render_from():
    assert cli.main([]) == 1
