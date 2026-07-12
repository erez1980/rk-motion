"""Feed/URL resolution tests. Network is stubbed — no real fetching."""

import pytest

from hebrew_chapters import feed

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


def test_resolve_direct_audio_url_skips_feed_parse(monkeypatch):
    # A direct audio URL must download without fetching/parsing a feed.
    monkeypatch.setattr(feed, "_fetch", lambda *a, **k: pytest.fail("should not parse feed"))
    monkeypatch.setattr(feed, "download_audio", lambda url: "/cache/direct.mp3")
    assert feed.resolve("https://x/show/episode.mp3") == "/cache/direct.mp3"
