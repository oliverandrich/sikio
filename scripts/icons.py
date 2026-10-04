# SPDX-License-Identifier: AGPL-3.0-or-later
# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools[woff]", "pillow"]
# ///
"""Draws Sikio's icons and README logo from the wordmark. Run it with `mise run icons`.

The letters come from the project's own IBM Plex Sans at weight 700, outlined, so no icon
depends on a web font. The geometry follows the wordmark component in Layouts: letter-spacing
-0.045em, a dot of 0.28em on the baseline 0.12em after the text, and a ring of 0.1em at 25 %
opacity. The favicon's s takes a 0.2em dot, a 0.1em gap and a 0.07em ring.

Chrome renders the PNGs from the SVGs. It is found through CHROME, then PATH, then its macOS
location. Pillow writes the ICO.
"""

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
STATIC = ROOT / "priv/static"
FONT = STATIC / "fonts/ibm-plex-sans/ibm-plex-sans-latin-wght-normal.woff2"

# Slate 900 and amber 500 on white; slate 100 and amber 400 for a dark background.
INK, AMBER = "#0f172a", "#f59e0b"
NIGHT_INK, NIGHT_AMBER = "#f1f5f9", "#fbbf24"

font = instantiateVariableFont(TTFont(FONT), {"wght": 700})
glyphs, cmap, hmtx = font.getGlyphSet(), font.getBestCmap(), font["hmtx"]
upm = font["head"].unitsPerEm


def outline(text, size, spacing, dot, gap, ring):
    """The letters of `text` at `size` px, baseline at y = 0, then the dot and its ring.

    Answers the path, the dot as (cx, cy, r, ring radius) and the ink's bounds.
    """
    scale = size / upm
    pen = SVGPathPen(glyphs, ntos=lambda n: f"{n:.2f}".rstrip("0").rstrip("."))
    bounds = BoundsPen(glyphs)
    x = 0.0
    for index, char in enumerate(text):
        name = cmap[ord(char)]
        # Font units point up and SVG units down.
        transform = (scale, 0, 0, -scale, x, 0)
        glyphs[name].draw(TransformPen(pen, transform))
        glyphs[name].draw(TransformPen(bounds, transform))
        x += hmtx[name][0] * scale + (spacing * size if index < len(text) - 1 else 0)
    x += spacing * size
    r = dot * size / 2
    cx, cy = x + gap * size + r, -r
    halo = r + ring * size
    left, top, right, bottom = bounds.bounds
    box = (min(left, cx - halo), min(top, cy - halo), max(right, cx + halo), max(bottom, cy + halo))
    return pen.getCommands(), (cx, cy, r, halo), box


def marks(path, dot, ink, amber, indent):
    cx, cy, r, halo = dot
    return (
        f'{indent}<path fill="{ink}" d="{path}"/>\n'
        f'{indent}<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{halo:.2f}" fill="{amber}" fill-opacity=".25"/>\n'
        f'{indent}<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{r:.2f}" fill="{amber}"/>\n'
    )


def icon(text, canvas, size, spacing, dot, gap, ring, radius, target):
    """`text` and its dot centred on a white square, the ring included in what is centred."""
    path, circle, (x0, y0, x1, y1) = outline(text, size, spacing, dot, gap, ring)
    dx, dy = (canvas - (x1 - x0)) / 2 - x0, (canvas - (y1 - y0)) / 2 - y0
    corner = f' rx="{radius}"' if radius else ""
    target.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {canvas} {canvas}">\n'
        f'  <rect width="{canvas}" height="{canvas}"{corner} fill="#ffffff"/>\n'
        f'  <g transform="translate({dx:.2f} {dy:.2f})">\n'
        + marks(path, circle, INK, AMBER, "    ")
        + "  </g>\n</svg>\n"
    )


def logo(ink, amber, target, size=96):
    """The wordmark alone, on nothing, cut to its ink."""
    path, circle, (x0, y0, x1, y1) = outline("sikio", size, -0.045, 0.28, 0.12, 0.1)
    w, h = x1 - x0, y1 - y0
    target.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{x0:.2f} {y0:.2f} {w:.2f} {h:.2f}" '
        f'width="{w:.0f}" height="{h:.0f}" role="img" aria-label="Sikio">\n'
        + marks(path, circle, ink, amber, "  ")
        + "</svg>\n"
    )


def chrome():
    found = os.environ.get("CHROME") or next(
        filter(None, map(shutil.which, ["google-chrome", "google-chrome-stable", "chromium", "chrome"])),
        None,
    )
    mac = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if not found and Path(mac).exists():
        found = mac
    if not found:
        raise SystemExit("No Chrome to render the PNGs with. Set CHROME to its path.")
    return found


def render(svg, px, target):
    """`svg` drawn at `px` square by Chrome, transparent around it."""
    with tempfile.TemporaryDirectory() as scratch:
        page = Path(scratch) / "page.html"
        page.write_text(
            "<!doctype html><style>html,body{margin:0;background:transparent}"
            f"img{{display:block;width:{px}px;height:{px}px}}</style>"
            f'<img src="{svg.as_uri()}">'
        )
        subprocess.run(
            [chrome(), "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--force-device-scale-factor=1", "--default-background-color=00000000",
             f"--window-size={px},{px}", f"--screenshot={target}", page.as_uri()],
            check=True, capture_output=True,
        )


app_icon, favicon = STATIC / "images/app-icon.svg", STATIC / "images/favicon.svg"

# The app icon is a full square: the platforms round it themselves.
icon("sikio", 1024, 1024 * 0.29, -0.045, 0.28, 0.12, 0.1, 0, app_icon)
# The favicon is a tile rounded like an app icon, its s large enough to read at 16 px.
icon("s", 64, 64 * 0.66, -0.04, 0.2, 0.1, 0.07, 14.4, favicon)
logo(INK, AMBER, ROOT / "docs/images/logo.svg")
logo(NIGHT_INK, NIGHT_AMBER, ROOT / "docs/images/logo-dark.svg")

render(app_icon, 180, STATIC / "apple-touch-icon.png")
render(app_icon, 192, STATIC / "images/icon-192.png")
render(app_icon, 512, STATIC / "images/icon-512.png")
with tempfile.TemporaryDirectory() as scratch:
    large = Path(scratch) / "favicon.png"
    render(favicon, 256, large)
    Image.open(large).save(STATIC / "favicon.ico", sizes=[(16, 16), (32, 32), (48, 48)])
