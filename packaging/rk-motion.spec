# PyInstaller spec for the RK Motion desktop app.
#
# Build (from the repository root):
#   pyinstaller packaging/rk-motion.spec
#
# FFmpeg: place static `ffmpeg` and `ffprobe` binaries (plus `.exe` on
# Windows) in packaging/ffmpeg-bin/ before building and they are bundled and
# put on PATH by the launcher. Without them the app still builds but needs
# FFmpeg installed on the user's machine.
import sys
from pathlib import Path

ROOT = Path(SPECPATH).parent
SRC = ROOT / "src" / "sofit"

ffmpeg_bin = ROOT / "packaging" / "ffmpeg-bin"
binaries = [(str(item), "bin") for item in ffmpeg_bin.iterdir()] if ffmpeg_bin.is_dir() else []

datas = [
    (str(SRC / "assets" / "index.html"), "sofit/assets"),
    (str(SRC / "assets" / "rk-logo.png"), "sofit/assets"),
    (str(SRC / "data" / "fonts" / "Rubik.ttf"), "sofit/data/fonts"),
    (str(SRC / "data" / "fonts" / "OFL.txt"), "sofit/data/fonts"),
]

a = Analysis(
    [str(ROOT / "packaging" / "rk_motion_app.py")],
    pathex=[str(ROOT / "src")],
    binaries=binaries,
    datas=datas,
    # Lazily imported inside ui.py for the --lan / phone-access QR code.
    hiddenimports=["qrcode"],
    # The editor is stdlib-only; keep the podcast pipeline's heavy stacks out.
    excludes=["faster_whisper", "anthropic", "cv2", "numpy", "PIL", "bidi", "mcp", "pytest"],
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries if sys.platform != "darwin" else [],
    a.datas if sys.platform != "darwin" else [],
    exclude_binaries=sys.platform == "darwin",
    name="RK Motion",
    console=sys.platform not in ("darwin", "win32"),
    # PNG is converted to .icns/.ico at build time (needs Pillow in the build env).
    icon=str(SRC / "assets" / "rk-logo.png") if sys.platform in ("darwin", "win32") else None,
)

if sys.platform == "darwin":
    coll = COLLECT(exe, a.binaries, a.datas, name="rk-motion")
    app = BUNDLE(
        coll,
        name="RK Motion.app",
        icon=str(SRC / "assets" / "rk-logo.png"),
        bundle_identifier="com.rkmotion.editor",
        info_plist={
            "CFBundleDisplayName": "RK Motion",
            "NSHighResolutionCapable": True,
            "LSMinimumSystemVersion": "12.0",
        },
    )
