"""The page's app shell: home-screen icons, manifest and served assets.

Saved to an iPhone home screen the page becomes an app, so the icon and the
manifest have to be reachable and correctly shaped — a transparent or
non-square icon comes out with white corners, and a missing one makes iOS
fall back to a screenshot of the page.
"""
import json
import re
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from sofit import ui

ASSETS = ui.ASSETS
INDEX = ui.INDEX.read_text(encoding="utf-8")


@pytest.fixture(scope="module")
def base_url():
    server = ThreadingHTTPServer(("127.0.0.1", 0), ui.RKMotionHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{server.server_port}"
    server.shutdown()


def _get(url: str):
    with urllib.request.urlopen(url, timeout=10) as response:
        return response.status, response.headers.get("Content-Type"), response.read()


def test_every_asset_the_page_links_to_is_served(base_url):
    linked = set(re.findall(r'(?:href|src)="(/assets/[^"]+)"', INDEX))
    assert linked, "the page should link at least the icons and the manifest"
    for path in linked:
        status, _, body = _get(base_url + path)
        assert status == 200 and body, f"{path} is linked but not served"


def test_only_whitelisted_assets_are_reachable(base_url):
    with pytest.raises(urllib.error.HTTPError) as caught:
        _get(base_url + "/assets/ui.py")
    assert caught.value.code == 404


def test_manifest_describes_an_installable_app(base_url):
    status, content_type, body = _get(base_url + "/assets/manifest.webmanifest")
    assert status == 200
    assert content_type == "application/manifest+json"
    manifest = json.loads(body)
    assert manifest["display"] == "standalone"
    assert manifest["dir"] == "rtl" and manifest["lang"] == "he"
    # Chrome only offers to install with an icon of 192px or more.
    assert any(int(icon["sizes"].split("x")[0]) >= 192 for icon in manifest["icons"])
    for icon in manifest["icons"]:
        assert (ASSETS / icon["src"].removeprefix("/assets/")).is_file()


def test_home_screen_icons_are_square_and_opaque():
    """iOS masks the icon itself, so any transparency shows up as white corners."""
    png = pytest.importorskip("PIL.Image", reason="needs pillow to inspect the icons")
    for size in (180, 192, 512):
        image = png.open(ASSETS / f"icon-{size}.png")
        assert image.size == (size, size)
        assert "A" not in image.getbands(), f"icon-{size}.png must be fully opaque"


def test_the_page_points_ios_at_the_touch_icon():
    assert '<link rel="apple-touch-icon" href="/assets/icon-180.png">' in INDEX
    assert '<link rel="manifest" href="/assets/manifest.webmanifest">' in INDEX
    assert 'name="apple-mobile-web-app-title" content="RK Motion"' in INDEX


def test_the_header_draws_its_icons_as_svg_not_as_symbol_characters():
    """A symbol the installed fonts lack renders as an empty "?" box next to
    the logo, which is exactly what happened with the sun/moon toggle."""
    header = INDEX.split('<header class="top">')[1].split("</header>")[0]
    stray = {
        character for character in header
        if ord(character) > 0x7F and not 0x590 <= ord(character) <= 0x5FF
        and character not in "·—’"      # middot, em dash, apostrophe
    }
    assert not stray, f"header should use SVG icons, found symbol chars: {stray}"
    assert header.count("<svg") >= 4, "sun, moon and both bell states"


def test_both_long_jobs_announce_themselves_when_they_finish():
    """Analysing and exporting are the two multi-minute waits; the page is
    meant to be left alone, so each one has to raise an alert on its way out
    (success and failure alike) and arm the alerts from the starting tap."""
    assert INDEX.count("notifyDone(") >= 5     # definition + analyse/export, done + failed
    for gesture in ("$('#export').onclick = async () => {\n  armAlerts();",
                    "file.addEventListener('click', () => {\n  armAlerts();"):
        assert gesture in INDEX
