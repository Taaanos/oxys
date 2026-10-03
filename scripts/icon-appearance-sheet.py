#!/usr/bin/env python3
"""Render AppIcon.icon in every appearance at 16 to 128 px on one sheet, to judge legibility (D-09).

One row per appearance (Default, Dark, Clear light, Clear dark, Tinted light, Tinted dark), one
column per size, each size rendered by Icon Composer's ictool at that size (not scaled down), on a
light and a dark backdrop. Needs pillow and Xcode. Usage: scripts/icon-appearance-sheet.py out.png [icon]
"""
import os, subprocess, sys, tempfile
from PIL import Image, ImageDraw

ICTOOL = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
RENDITIONS = ["Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"]
SIZES = [128, 64, 32, 16]
TINT = ("0.6", "0.7")                          # a blue tint, as the system offers

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
out = sys.argv[1]
icon = sys.argv[2] if len(sys.argv) > 2 else os.path.join(root, "App", "Oxys", "AppIcon.icon")
tmp = tempfile.mkdtemp()

def render(rendition, size):
    path = os.path.join(tmp, f"{rendition}-{size}.png")
    subprocess.run([ICTOOL, icon, "--export-image", "--output-file", path, "--platform", "macOS",
                    "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "1",
                    "--tint-color", TINT[0], "--tint-strength", TINT[1]], capture_output=True, check=True)
    return Image.open(path).convert("RGBA")

pad, label_w = 20, 110
col_w = [s + pad for s in SIZES]
half_w = label_w + sum(col_w) + pad
row_h = 128 + pad
sheet = Image.new("RGB", (2 * half_w, len(RENDITIONS) * row_h + pad))
for h, bg in enumerate([(236, 236, 240), (38, 38, 42)]):
    draw = ImageDraw.Draw(sheet)
    draw.rectangle((h * half_w, 0, (h + 1) * half_w, sheet.height), fill=bg)
    fg = (20, 20, 20) if h == 0 else (230, 230, 230)
    for r, name in enumerate(RENDITIONS):
        y = pad + r * row_h
        draw.text((h * half_w + pad, y + 56), name, fill=fg)
        x = h * half_w + label_w
        for s in SIZES:
            im = render(name, s)
            sheet.paste(im, (x, y + (128 - s) // 2), im)
            x += s + pad
sheet.save(out); print(out)
