"""Feed/URL resolution tests. Network is stubbed — no real fetching."""

import pytest

from sofit import feed

RSS = b"""<?xml version="1.0"?>
<rss version="2.0"><channel>
  <title>WeeklySync</title>
  <item><title>Ep 3 (latest)</title><enclosure url="https://x/ep3.mp3" type="audio/mpeg"/></item>
  <item><title>Ep 2</title><enclosure url="https://x/ep2.mp3" type="audio/mpeg"/></item>
  <item><title>Ep 1 (no audio)</title></item>
</channel></rss>"""


def test_is_url():
    assert feed.is_url("https://x/feed.xml")
    assert feed.is_url("http://x/feed.xml")
    assert not feed.is_url("/Users/me/ep.mp3")
    assert not feed.is_url("ep.mp4")


def test_list_episodes_parses_enclosures(monkeypatch):
    monkeypatch.setattr(feed, "_fetch", lambda url, timeout=60: RSS)
    eps = feed.list_episodes("https://x/feed.xml")
    assert [e.title for e in eps] == ["Ep 3 (latest)", "Ep 2"]  # item with no enclosure dropped
    assert eps[0].url == "https://x/ep3.mp3"


def test_local_path_passes_through():
    assert feed.resolve("/Users/me/ep.mp3") == "/Users/me/ep.mp3"


def test_resolve_feed_picks_episode(monkeypatch):
    monkeypatch.setattr(feed, "_fetch", lambda url, timeout=60: RSS)
    monkeypatch.setattr(feed, "download_audio", lambda url: f"/cache/{url.rsplit('/', 1)[1]}")
    assert feed.resolve("https://x/feed.xml", episode=1) == "/cache/ep3.mp3"  # latest
    assert feed.resolve("https://x/feed.xml", episode=2) == "/cache/ep2.mp3"


def test_resolve_episode_out_of_range(monkeypatch):
    monkeypatch.setattr(feed, "_fetch", lambda url, timeout=60: RSS)
    with pytest.raises(feed.FeedError):
        feed.resolve("https://x/feed.xml", episode=9)


def test_is_youtube():
    assert feed.is_youtube("https://www.youtube.com/watch?v=abc123")
    assert feed.is_youtube("https://youtu.be/abc123")
    assert feed.is_youtube("https://music.youtube.com/watch?v=abc")
    assert not feed.is_youtube("https://feeds.example.com/show.xml")


def test_resolve_youtube_routes_to_downloader(monkeypatch):
    # A YouTube URL must go to download_youtube, not the feed parser or audio downloader.
    monkeypatch.setattr(feed, "_fetch", lambda *a, **k: pytest.fail("should not parse feed"))
    monkeypatch.setattr(feed, "download_youtube", lambda url: "/cache/yt.m4a")
    assert feed.resolve("https://www.youtube.com/watch?v=abc123") == "/cache/yt.m4a"


def test_youtube_without_ytdlp_raises(monkeypatch):
    # Simulate yt-dlp not installed → clear, actionable error.
    import builtins
    real_import = builtins.__import__

    def no_ytdlp(name, *a, **k):
        if name == "yt_dlp":
            raise ImportError("no yt_dlp")
        return real_import(name, *a, **k)

    monkeypatch.setattr(builtins, "__import__", no_ytdlp)
    with pytest.raises(feed.FeedError, match="yt-dlp"):
        feed.download_youtube("https://youtu.be/abc")


def test_resolve_direct_audio_url_skips_feed_parse(monkeypatch):
    # A direct audio URL must download without fetching/parsing a feed.
    monkeypatch.setattr(feed, "_fetch", lambda *a, **k: pytest.fail("should not parse feed"))
    monkeypatch.setattr(feed, "download_audio", lambda url: "/cache/direct.mp3")
    assert feed.resolve("https://x/show/episode.mp3") == "/cache/direct.mp3"


class _SlowBody:
    """A response that hands out its bytes slowly, so two downloads overlap."""

    def __init__(self, data: bytes, fail_after: int | None = None):
        self.data, self.sent, self.fail_after = data, 0, fail_after

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self, size):
        import time
        if self.fail_after is not None and self.sent >= self.fail_after:
            raise ConnectionResetError("connection dropped")
        time.sleep(0.01)
        piece = self.data[self.sent:self.sent + 4096]
        self.sent += len(piece)
        return piece


def test_concurrent_downloads_of_one_url_share_one_whole_file(tmp_path, monkeypatch):
    import threading
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    payload = bytes(range(256)) * 160  # 40 KB, ten slow reads
    calls = []
    monkeypatch.setattr(feed.urllib.request, "urlopen", lambda *a, **k: calls.append(1) or _SlowBody(payload))
    start, results, errors = threading.Barrier(2), [], []

    def fetch():
        start.wait()
        try:
            results.append(feed.download_audio("https://x/show/ep.mp3"))
        except Exception as error:  # noqa: BLE001 - the test reports any failure
            errors.append(error)

    threads = [threading.Thread(target=fetch) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == []
    assert len(set(results)) == 1
    with open(results[0], "rb") as f:
        assert f.read() == payload
    assert len(calls) == 1, "the second request should reuse the first download"
    assert not list((tmp_path / "sofit" / "downloads").glob("*.part"))


def test_an_interrupted_download_leaves_nothing_in_the_cache(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    payload = b"x" * 40000
    monkeypatch.setattr(feed.urllib.request, "urlopen", lambda *a, **k: _SlowBody(payload, fail_after=8192))
    with pytest.raises(ConnectionResetError):
        feed.download_audio("https://x/show/ep.mp3")
    cache = tmp_path / "sofit" / "downloads"
    assert [p.name for p in cache.iterdir() if not p.name.endswith(".lock")] == []
    monkeypatch.setattr(feed.urllib.request, "urlopen", lambda *a, **k: _SlowBody(payload))
    with open(feed.download_audio("https://x/show/ep.mp3"), "rb") as f:
        assert f.read() == payload


def test_concurrent_youtube_downloads_finish_one_file(tmp_path, monkeypatch):
    import sys
    import threading
    import time
    import types
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path))
    runs = []

    class FakeYDL:
        def __init__(self, opts):
            self.template = opts["outtmpl"]

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def extract_info(self, url, download):
            runs.append(url)
            target = self.template.replace("%(ext)s", "m4a")
            with open(target + ".part", "wb") as f:  # yt-dlp writes a .part, then renames it
                for _ in range(10):
                    f.write(b"a" * 1000)
                    time.sleep(0.01)
            import os
            os.replace(target + ".part", target)

    monkeypatch.setitem(sys.modules, "yt_dlp", types.SimpleNamespace(YoutubeDL=FakeYDL))
    start, results, errors = threading.Barrier(2), [], []

    def fetch():
        start.wait()
        try:
            results.append(feed.download_youtube("https://youtu.be/abc"))
        except Exception as error:  # noqa: BLE001
            errors.append(error)

    threads = [threading.Thread(target=fetch) for _ in range(2)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert errors == [] and len(set(results)) == 1 and len(runs) == 1
    with open(results[0], "rb") as f:
        assert f.read() == b"a" * 10000
    cache = tmp_path / "sofit" / "downloads"
    assert sorted(p.name for p in cache.iterdir() if not p.name.endswith(".lock")) == [results[0].rsplit("/", 1)[1]]
