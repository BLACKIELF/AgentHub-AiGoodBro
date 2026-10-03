#!/usr/bin/env python3
"""Derive macOS product icons from the user's approved AiGoodBro avatar PNG.

The source PNG is copied byte-for-byte from assets/0926v2 in the approved
design worktree. Do not replace it with the traced SVG: that changes details.
"""

from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Resources/AiGoodBro-approved-source-1254.png"
SOURCE_SHA256 = "3122ac4ef7d3e2b4a90d70ebcc848a6ddf90f474a38bd7ad51b8c30c513ca9e9"
ICONSET_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_size_and_color(path: Path) -> tuple[int, int, int, int]:
    data = path.read_bytes()
    if data[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR":
        raise RuntimeError(f"Not a PNG: {path}")
    width, height, depth, color, *_ = struct.unpack(">IIBBBBB", data[16:29])
    return width, height, depth, color


def require_rgba(path: Path, expected_size: int) -> None:
    if png_size_and_color(path) != (expected_size, expected_size, 8, 6):
        raise RuntimeError(f"Expected {expected_size}px RGBA PNG: {path}")


def run(*args: str) -> None:
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def resize(source: Path, destination: Path, size: int) -> None:
    run("sips", "-s", "format", "png", "-z", str(size), str(size),
        str(source), "--out", str(destination))
    require_rgba(destination, size)


def make_staged_icons(directory: Path) -> tuple[Path, Path]:
    png = directory / "AiGoodBro-icon.png"
    resize(SOURCE, png, 1024)
    iconset = directory / "AiGoodBro.iconset"
    iconset.mkdir()
    for name, size in ICONSET_SIZES.items():
        resize(png, iconset / name, size)
    icns = directory / "AiGoodBro.icns"
    run("iconutil", "-c", "icns", str(iconset), "-o", str(icns))
    if icns.stat().st_size < 1024:
        raise RuntimeError("Generated ICNS is unexpectedly small")
    # macOS must be able to read its own icon container, including the 1024px
    # representation used by the Dock and Finder at high pixel density.
    extracted = directory / "extracted.iconset"
    run("iconutil", "-c", "iconset", str(icns), "-o", str(extracted))
    if not (extracted / "icon_512x512@2x.png").is_file():
        raise RuntimeError("ICNS is missing its 1024px representation")
    return png, icns


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--resources-dir", type=Path, default=ROOT / "Resources")
    args = parser.parse_args()
    if sha256(SOURCE) != SOURCE_SHA256:
        raise RuntimeError("Approved avatar source SHA-256 changed")
    require_rgba(SOURCE, 1254)
    resources = args.resources_dir.resolve()
    resources.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="aigoodbro-approved-icon-") as temp:
        png, icns = make_staged_icons(Path(temp))
        if args.verify_only:
            for staged in (png, icns):
                installed = resources / staged.name
                if not installed.is_file() or sha256(staged) != sha256(installed):
                    raise RuntimeError(f"Installed product icon differs from approved source: {installed}")
        else:
            for staged in (png, icns):
                destination = resources / staged.name
                replacement = resources / f".{staged.name}.new"
                shutil.copyfile(staged, replacement)
                os.replace(replacement, destination)
    print(f"{'Verified' if args.verify_only else 'Prepared'} approved AiGoodBro macOS PNG/ICNS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
