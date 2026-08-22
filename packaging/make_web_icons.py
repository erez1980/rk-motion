"""Derive the web/home-screen icons from the master app icon.

The master (packaging/app-icon.png) has transparent rounded corners because
macOS and Windows expect to see the rounded shape. iOS and Android apply their
own mask instead, so the home-screen icons must be square and fully opaque —
otherwise the corners come out white (iOS) and the icon looks broken.

    python3 packaging/make_web_icons.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MASTER = ROOT / "packaging" / "app-icon.png"
ASSETS = ROOT / "src" / "sofit" / "assets"
BACKDROP = (12, 19, 14)  # the icon's own carbon body, so the fill is invisible
SIZES = (180, 192, 512)  # apple-touch-icon, Android/Chrome install, splash


def main() -> None:
    master = Image.open(MASTER).convert("RGBA")
    square = Image.new("RGB", master.size, BACKDROP)
    square.paste(master, mask=master.getchannel("A"))
    for size in SIZES:
        target = ASSETS / f"icon-{size}.png"
        square.resize((size, size), Image.LANCZOS).save(target, optimize=True)
        print("wrote", target.relative_to(ROOT))


if __name__ == "__main__":
    main()
